/*-------------------------------------------------------------------------
 *
 * lance_arrow.c
 *	  Arrow schema -> PostgreSQL type mapping (DESIGN D8).
 *
 * A-tier is everything this block can hand to the executor without losing
 * information; B-tier is everything else, and B-tier is loud rather than
 * silent (I8): skipped with a NOTICE on import, refused with an error on scan.
 *
 * IDENTIFICATION
 *	  src/lance_arrow.c
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "lance_fdw.h"
#include "lance_arrow.h"

#include "catalog/pg_type_d.h"
#include "common/int.h"
#include "varatt.h"
#include "utils/array.h"
#include "utils/builtins.h"
#include "utils/date.h"
#include "utils/fmgrprotos.h"
#include "utils/lsyscache.h"
#include "utils/memutils.h"
#include "utils/timestamp.h"

#define LANCE_BLOB_METADATA_KEY "lance-encoding"
#define LANCE_BLOB_METADATA_VALUE "blob"

/*
 * PostgreSQL keeps microseconds, so every Arrow timestamp becomes a
 * timestamp(6); a coarser Arrow unit is exact in it and a finer one (ns) is
 * rejected value by value at scan time rather than silently rounded (I7).
 */
#define LANCE_TIMESTAMP_TYPMOD 6

/*
 * Arrow counts from 1970-01-01 and PostgreSQL from 2000-01-01; both epochs are
 * UTC, so the difference is a constant.
 */
#define LANCE_EPOCH_DIFF_USEC \
	(((int64) (POSTGRES_EPOCH_JDATE - UNIX_EPOCH_JDATE)) * SECS_PER_DAY * USECS_PER_SEC)

const char *
lance_arrow_format(const struct ArrowSchema *field)
{
	if (field == NULL || field->format == NULL)
		return "?";
	return field->format;
}

const char *
lance_arrow_type_name(const struct ArrowSchema *field)
{
	struct ArrowSchemaView view;
	struct ArrowError error;

	if (field == NULL || field->format == NULL)
		return NULL;

	memset(&error, 0, sizeof(error));
	if (ArrowSchemaViewInit(&view, field, &error) != NANOARROW_OK)
		return NULL;

	return ArrowTypeString(view.type);
}

/*
 * Look one key up in an Arrow field's metadata.  The metadata is the binary
 * key/value encoding of the C data interface, so it goes through nanoarrow's
 * reader rather than any string handling of ours.
 */
static bool
lance_arrow_metadata_lookup(const struct ArrowSchema *field, const char *key,
							struct ArrowStringView *value)
{
	struct ArrowMetadataReader reader;
	struct ArrowStringView wanted = ArrowCharView(key);
	struct ArrowStringView k;
	struct ArrowStringView v;

	if (field == NULL || field->metadata == NULL)
		return false;

	if (ArrowMetadataReaderInit(&reader, field->metadata) != NANOARROW_OK)
		return false;

	while (reader.remaining_keys > 0)
	{
		if (ArrowMetadataReaderRead(&reader, &k, &v) != NANOARROW_OK)
			return false;

		if (k.size_bytes == wanted.size_bytes &&
			(k.size_bytes == 0 ||
			 memcmp(k.data, wanted.data, (size_t) k.size_bytes) == 0))
		{
			*value = v;
			return true;
		}
	}

	return false;
}

bool
lance_arrow_is_blob_encoded(const struct ArrowSchema *field)
{
	struct ArrowStringView value;
	const size_t expected = sizeof(LANCE_BLOB_METADATA_VALUE) - 1;

	if (!lance_arrow_metadata_lookup(field, LANCE_BLOB_METADATA_KEY, &value))
		return false;

	return value.size_bytes == (int64) expected &&
		memcmp(value.data, LANCE_BLOB_METADATA_VALUE, expected) == 0;
}

/*
 * A-tier scalars.  Integers widen into the smallest PostgreSQL type that holds
 * every value of the Arrow type - uint32 goes to bigint, not integer, because
 * integer cannot hold 4294967295.
 */
static bool
lance_arrow_map_scalar(const struct ArrowSchemaView *view, Oid *typid,
					   int32 *typmod)
{
	*typmod = -1;

	switch (view->type)
	{
		case NANOARROW_TYPE_BOOL:
			*typid = BOOLOID;
			return true;

		case NANOARROW_TYPE_INT8:
		case NANOARROW_TYPE_INT16:
		case NANOARROW_TYPE_UINT8:
			*typid = INT2OID;
			return true;

		case NANOARROW_TYPE_INT32:
		case NANOARROW_TYPE_UINT16:
			*typid = INT4OID;
			return true;

		case NANOARROW_TYPE_INT64:
		case NANOARROW_TYPE_UINT32:
			*typid = INT8OID;
			return true;

		case NANOARROW_TYPE_HALF_FLOAT:
		case NANOARROW_TYPE_FLOAT:
			*typid = FLOAT4OID;
			return true;

		case NANOARROW_TYPE_DOUBLE:
			*typid = FLOAT8OID;
			return true;

		case NANOARROW_TYPE_STRING:
		case NANOARROW_TYPE_LARGE_STRING:
			*typid = TEXTOID;
			return true;

		case NANOARROW_TYPE_BINARY:
		case NANOARROW_TYPE_LARGE_BINARY:
			*typid = BYTEAOID;
			return true;

		case NANOARROW_TYPE_DATE32:
			*typid = DATEOID;
			return true;

		case NANOARROW_TYPE_TIMESTAMP:

			/*
			 * The zone name is not kept: an Arrow timestamp with a zone is a
			 * UTC epoch, which is exactly what timestamptz stores (DESIGN
			 * Q14).
			 */
			*typid = (view->timezone != NULL && view->timezone[0] != '\0')
				? TIMESTAMPTZOID : TIMESTAMPOID;
			*typmod = LANCE_TIMESTAMP_TYPMOD;
			return true;

		case NANOARROW_TYPE_DECIMAL128:
			if (view->decimal_precision < 1 ||
				view->decimal_precision > 1000 ||
				view->decimal_scale < 0 ||
				view->decimal_scale > view->decimal_precision)
				return false;
			*typid = NUMERICOID;
			*typmod = (int32) (((view->decimal_precision << 16) |
								view->decimal_scale) + VARHDRSZ);
			return true;

		default:
			return false;
	}
}

/*
 * fixed_size_list is only A-tier over float32/float64, which is the embedding
 * shape this block is about; other element types stay B-tier until someone
 * needs them (DESIGN section 2).
 */
static bool
lance_arrow_fsl_element_ok(const struct ArrowSchemaView *element)
{
	return element->type == NANOARROW_TYPE_FLOAT ||
		element->type == NANOARROW_TYPE_DOUBLE;
}

bool
lance_arrow_map_type(const struct ArrowSchema *field, Oid *typid,
					 int32 *typmod, bool *is_b_tier)
{
	struct ArrowSchemaView view;
	struct ArrowError error;

	*is_b_tier = true;
	*typid = InvalidOid;
	*typmod = -1;

	if (field == NULL || field->format == NULL)
		ereport(ERROR,
				(errcode(ERRCODE_INTERNAL_ERROR),
				 errmsg("lance_fdw: Lance returned a field without a type")));

	/* Blob encoding overrides whatever the Arrow type claims (PROBES Q3). */
	if (lance_arrow_is_blob_encoded(field))
		return false;

	memset(&error, 0, sizeof(error));
	if (ArrowSchemaViewInit(&view, field, &error) != NANOARROW_OK)
		ereport(ERROR,
				(errcode(ERRCODE_FDW_INVALID_DATA_TYPE),
				 errmsg("lance_fdw: cannot parse Arrow type \"%s\" of column \"%s\"",
						lance_arrow_format(field),
						field->name != NULL ? field->name : "?"),
				 errdetail("%s", error.message)));

	if (view.type == NANOARROW_TYPE_LIST ||
		view.type == NANOARROW_TYPE_FIXED_SIZE_LIST)
	{
		struct ArrowSchema *child;
		struct ArrowSchemaView childview;
		Oid			elemtypid;
		int32		elemtypmod;
		Oid			arraytypid;

		if (field->n_children != 1 || field->children == NULL ||
			field->children[0] == NULL)
			return false;

		child = field->children[0];

		/* A blob element is a descriptor too, so the whole list is B-tier. */
		if (lance_arrow_is_blob_encoded(child))
			return false;

		memset(&error, 0, sizeof(error));
		if (ArrowSchemaViewInit(&childview, child, &error) != NANOARROW_OK)
			return false;

		if (!lance_arrow_map_scalar(&childview, &elemtypid, &elemtypmod))
			return false;

		if (view.type == NANOARROW_TYPE_FIXED_SIZE_LIST &&
			!lance_arrow_fsl_element_ok(&childview))
			return false;

		arraytypid = get_array_type(elemtypid);
		if (!OidIsValid(arraytypid))
			return false;

		*typid = arraytypid;
		*typmod = elemtypmod;
		*is_b_tier = false;
		return true;
	}

	if (!lance_arrow_map_scalar(&view, typid, typmod))
		return false;

	*is_b_tier = false;
	return true;
}

/*-------------------------------------------------------------------------
 * Value converters (DESIGN D7, D8)
 *
 * Every accessor below goes through nanoarrow's array view rather than through
 * offset arithmetic of our own: array->offset is routinely non-zero once a
 * fragment has a deletion file, large_utf8 counts its offsets in 64 bits, and
 * a validity bitmap is allowed to be absent.  Those are the four places a
 * hand-written decoder gets wrong.
 *-------------------------------------------------------------------------
 */

/*
 * A value bigger than a varlena can describe is an error, not a truncation
 * (I7).  Lance itself has no such limit, so this is reachable with a large
 * enough blob.
 */
static void
lance_check_varlena_size(LanceConverter *conv, int64 size)
{
	if (size < 0 || (uint64) size > (uint64) (MaxAllocSize - VARHDRSZ))
		ereport(ERROR,
				(errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
				 errmsg("lance_fdw: column \"%s\": value of " INT64_FORMAT " bytes is too large for %s",
						conv->colname, size,
						format_type_with_typemod(conv->pgtypid, conv->pgtypmod))));
}

static Datum
lance_conv_bool(LanceConverter *conv, int64 row)
{
	return BoolGetDatum(ArrowArrayViewGetIntUnsafe(&conv->view, row) != 0);
}

/*
 * The three integer converters share one accessor: nanoarrow widens any Arrow
 * integer storage to int64, and the dispatch table only pairs an Arrow type
 * with a PostgreSQL type that holds every one of its values, so the narrowing
 * cast here cannot lose anything.
 */
static Datum
lance_conv_int2(LanceConverter *conv, int64 row)
{
	return Int16GetDatum((int16) ArrowArrayViewGetIntUnsafe(&conv->view, row));
}

static Datum
lance_conv_int4(LanceConverter *conv, int64 row)
{
	return Int32GetDatum((int32) ArrowArrayViewGetIntUnsafe(&conv->view, row));
}

static Datum
lance_conv_int8(LanceConverter *conv, int64 row)
{
	return Int64GetDatum(ArrowArrayViewGetIntUnsafe(&conv->view, row));
}

/*
 * float32 reaches this as a double that is exactly the float32 value, so the
 * cast back is lossless and NaN, the infinities and negative zero all survive.
 */
static Datum
lance_conv_float4(LanceConverter *conv, int64 row)
{
	return Float4GetDatum((float4) ArrowArrayViewGetDoubleUnsafe(&conv->view, row));
}

static Datum
lance_conv_float8(LanceConverter *conv, int64 row)
{
	return Float8GetDatum(ArrowArrayViewGetDoubleUnsafe(&conv->view, row));
}

static Datum
lance_conv_text(LanceConverter *conv, int64 row)
{
	struct ArrowStringView sv = ArrowArrayViewGetStringUnsafe(&conv->view, row);

	lance_check_varlena_size(conv, sv.size_bytes);

	/* A column of nothing but empty strings has no data buffer at all. */
	if (sv.size_bytes == 0)
		return PointerGetDatum(cstring_to_text_with_len("", 0));

	return PointerGetDatum(cstring_to_text_with_len(sv.data,
													(int) sv.size_bytes));
}

static Datum
lance_conv_bytea(LanceConverter *conv, int64 row)
{
	struct ArrowBufferView bv = ArrowArrayViewGetBytesUnsafe(&conv->view, row);
	bytea	   *result;

	lance_check_varlena_size(conv, bv.size_bytes);

	result = (bytea *) palloc(VARHDRSZ + bv.size_bytes);
	SET_VARSIZE(result, VARHDRSZ + bv.size_bytes);
	if (bv.size_bytes > 0)
		memcpy(VARDATA(result), bv.data.as_uint8, (size_t) bv.size_bytes);

	return PointerGetDatum(result);
}

/*
 * date32 is a day count from 1970-01-01 and PostgreSQL counts days from
 * 2000-01-01.  Arrow's range is the wider one at both ends, so a date that
 * PostgreSQL cannot represent is an error rather than a wrapped value (I7).
 */
static Datum
lance_conv_date(LanceConverter *conv, int64 row)
{
	int64		days = ArrowArrayViewGetIntUnsafe(&conv->view, row);
	int64		pgdays = days - (POSTGRES_EPOCH_JDATE - UNIX_EPOCH_JDATE);

	if (!IS_VALID_DATE(pgdays))
		ereport(ERROR,
				(errcode(ERRCODE_DATETIME_VALUE_OUT_OF_RANGE),
				 errmsg("lance_fdw: column \"%s\": date " INT64_FORMAT " days from 1970-01-01 is out of range for %s",
						conv->colname, days,
						format_type_with_typemod(conv->pgtypid, conv->pgtypmod))));

	return DateADTGetDatum((DateADT) pgdays);
}

static void lance_timestamp_out_of_range(LanceConverter *conv, int64 value,
										 const char *unit) pg_attribute_noreturn();

static void
lance_timestamp_out_of_range(LanceConverter *conv, int64 value, const char *unit)
{
	ereport(ERROR,
			(errcode(ERRCODE_DATETIME_VALUE_OUT_OF_RANGE),
			 errmsg("lance_fdw: column \"%s\": timestamp " INT64_FORMAT " %s from 1970-01-01 is out of range for %s",
					conv->colname, value, unit,
					format_type_with_typemod(conv->pgtypid, conv->pgtypmod))));
}

/*
 * The tail the four unit converters share: move the epoch and check the range.
 *
 * timestamp and timestamptz have the same representation - microseconds from
 * 2000-01-01 UTC - and an Arrow timestamp is a UTC epoch whether or not it
 * carries a zone name, so the name is dropped rather than applied (DESIGN Q14).
 * Which of the two the column is has already been settled in resolve().
 */
static Datum
lance_timestamp_datum(LanceConverter *conv, int64 usec, int64 value,
					  const char *unit)
{
	Timestamp	ts;

	if (pg_sub_s64_overflow(usec, LANCE_EPOCH_DIFF_USEC, &ts) ||
		!IS_VALID_TIMESTAMP(ts))
		lance_timestamp_out_of_range(conv, value, unit);

	return TimestampGetDatum(ts);
}

static Datum
lance_conv_ts_second(LanceConverter *conv, int64 row)
{
	int64		value = ArrowArrayViewGetIntUnsafe(&conv->view, row);
	int64		usec;

	if (pg_mul_s64_overflow(value, USECS_PER_SEC, &usec))
		lance_timestamp_out_of_range(conv, value, "s");

	return lance_timestamp_datum(conv, usec, value, "s");
}

static Datum
lance_conv_ts_milli(LanceConverter *conv, int64 row)
{
	int64		value = ArrowArrayViewGetIntUnsafe(&conv->view, row);
	int64		usec;

	if (pg_mul_s64_overflow(value, INT64CONST(1000), &usec))
		lance_timestamp_out_of_range(conv, value, "ms");

	return lance_timestamp_datum(conv, usec, value, "ms");
}

static Datum
lance_conv_ts_micro(LanceConverter *conv, int64 row)
{
	int64		value = ArrowArrayViewGetIntUnsafe(&conv->view, row);

	return lance_timestamp_datum(conv, value, value, "us");
}

static Datum
lance_conv_ts_nano(LanceConverter *conv, int64 row)
{
	int64		value = ArrowArrayViewGetIntUnsafe(&conv->view, row);

	/*
	 * PostgreSQL keeps microseconds.  Rounding a nanosecond value that is not
	 * a whole microsecond is precisely the silent loss I7 forbids, so it is an
	 * error instead.  Nothing in test/fixtures reaches this: every timestamp
	 * there is microsecond-aligned on purpose, so the branch is implemented
	 * but is not covered by a test.
	 */
	if (value % 1000 != 0)
		ereport(ERROR,
				(errcode(ERRCODE_DATETIME_VALUE_OUT_OF_RANGE),
				 errmsg("lance_fdw: column \"%s\": nanosecond timestamp " INT64_FORMAT " is not a whole number of microseconds",
						conv->colname, value),
				 errdetail("%s keeps microseconds, and rounding the value would lose information.",
						   format_type_with_typemod(conv->pgtypid,
													conv->pgtypmod))));

	return lance_timestamp_datum(conv, value / 1000, value, "ns");
}

/*
 * decimal128 -> numeric.  The value is a 128-bit two's complement integer plus
 * a scale; nanoarrow renders that as a decimal string and numeric_in parses it
 * under the column's own typmod.  The text form is what keeps the scale Lance
 * stored - 0.0000000000 stays ten digits - and resolve() has already refused
 * any declaration numeric_in would have had to round to (I7).
 */
static Datum
lance_conv_numeric(LanceConverter *conv, int64 row)
{
	struct ArrowDecimal dec;
	struct ArrowBuffer buffer;

	/* 39 digits, a sign and a point fit in this with room to spare */
	char		digits[64];
	int64		size;

	ArrowDecimalInit(&dec, 128, conv->decimal_precision, conv->decimal_scale);
	ArrowArrayViewGetDecimalUnsafe(&conv->view, row, &dec);

	ArrowBufferInit(&buffer);
	if (ArrowDecimalAppendStringToBuffer(&dec, &buffer) != NANOARROW_OK)
	{
		ArrowBufferReset(&buffer);
		ereport(ERROR,
				(errcode(ERRCODE_OUT_OF_MEMORY),
				 errmsg("lance_fdw: column \"%s\": could not render a decimal value",
						conv->colname)));
	}

	size = buffer.size_bytes;
	if (size <= 0 || size >= (int64) sizeof(digits))
	{
		ArrowBufferReset(&buffer);
		ereport(ERROR,
				(errcode(ERRCODE_NUMERIC_VALUE_OUT_OF_RANGE),
				 errmsg("lance_fdw: column \"%s\": decimal value needs " INT64_FORMAT " characters, more than a decimal128 can have",
						conv->colname, size)));
	}

	memcpy(digits, buffer.data, (size_t) size);
	digits[size] = '\0';
	ArrowBufferReset(&buffer);

	return DirectFunctionCall3(numeric_in, CStringGetDatum(digits),
							   ObjectIdGetDatum(InvalidOid),
							   Int32GetDatum(conv->pgtypmod));
}

/*
 * One PostgreSQL array out of one Arrow list element.  Both list shapes end up
 * here and differ only in how the element window is found: a fixed_size_list
 * has its elements at a fixed stride, a list has an offsets buffer.
 *
 * Elements go through a converter of their own, so a NULL element stays NULL
 * and every element value is converted by exactly the code a scalar column of
 * that type would use.
 */
static Datum
lance_conv_array(LanceConverter *conv, int64 row)
{
	LanceConverter *element = conv->element;
	int64		index = row + conv->view.offset;
	int64		start;
	int64		nelems;
	Datum	   *values;
	bool	   *nulls;
	int			dims[1];
	int			lbs[1];
	int64		i;

	if (conv->arrow_type == NANOARROW_TYPE_FIXED_SIZE_LIST)
	{
		start = index * conv->fixed_size;
		nelems = conv->fixed_size;
	}
	else
	{
		start = ArrowArrayViewListChildOffset(&conv->view, index);
		nelems = ArrowArrayViewListChildOffset(&conv->view, index + 1) - start;
	}

	if (start < 0 || nelems < 0 ||
		nelems > (int64) (MaxAllocSize / sizeof(Datum)))
		ereport(ERROR,
				(errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
				 errmsg("lance_fdw: column \"%s\": list of " INT64_FORMAT " elements at offset " INT64_FORMAT " cannot be read as %s",
						conv->colname, nelems, start,
						format_type_with_typemod(conv->pgtypid,
												 conv->pgtypmod))));

	/* An empty list is an empty array, which is not the same as NULL. */
	if (nelems == 0)
		return PointerGetDatum(construct_empty_array(conv->elemtypid));

	values = (Datum *) palloc(sizeof(Datum) * nelems);
	nulls = (bool *) palloc(sizeof(bool) * nelems);

	for (i = 0; i < nelems; i++)
	{
		int64		elemrow = start + i;

		nulls[i] = lance_arrow_converter_is_null(element, elemrow);
		values[i] = nulls[i] ? (Datum) 0 : element->convert(element, elemrow);
	}

	dims[0] = (int) nelems;
	lbs[0] = 1;

	return PointerGetDatum(construct_md_array(values, nulls, 1, dims, lbs,
											  conv->elemtypid, conv->elemlen,
											  conv->elembyval,
											  conv->elemalign));
}

/*
 * The dispatch table.  A row means "this Arrow type may be read into this
 * PostgreSQL type"; the absence of a row is what makes int64 into integer, or
 * utf8 into integer, an error at BeginForeignScan instead of a wrong value
 * later.  Widening within a family is present, narrowing never is.
 *
 * Adding a type is adding rows here plus the function they name.  Nothing else
 * in the scan path knows about types.
 *
 * Two things the table cannot say on its own, because they are not part of the
 * pair it is keyed by, are settled by resolve() below: a timestamp's unit and
 * zone, and how wide a numeric a decimal128 needs.  The list shapes have no
 * rows at all - their rule is their element's rule.
 */
typedef struct LanceConverterRule
{
	enum ArrowType arrow_type;
	Oid			pgtypid;
	LanceConvertFn convert;
} LanceConverterRule;

static const LanceConverterRule lance_converter_rules[] = {
	{NANOARROW_TYPE_BOOL, BOOLOID, lance_conv_bool},

	{NANOARROW_TYPE_INT8, INT2OID, lance_conv_int2},
	{NANOARROW_TYPE_INT8, INT4OID, lance_conv_int4},
	{NANOARROW_TYPE_INT8, INT8OID, lance_conv_int8},

	{NANOARROW_TYPE_INT16, INT2OID, lance_conv_int2},
	{NANOARROW_TYPE_INT16, INT4OID, lance_conv_int4},
	{NANOARROW_TYPE_INT16, INT8OID, lance_conv_int8},

	{NANOARROW_TYPE_INT32, INT4OID, lance_conv_int4},
	{NANOARROW_TYPE_INT32, INT8OID, lance_conv_int8},

	{NANOARROW_TYPE_INT64, INT8OID, lance_conv_int8},

	/* uint8 fits in smallint, uint16 in integer, uint32 in bigint */
	{NANOARROW_TYPE_UINT8, INT2OID, lance_conv_int2},
	{NANOARROW_TYPE_UINT8, INT4OID, lance_conv_int4},
	{NANOARROW_TYPE_UINT8, INT8OID, lance_conv_int8},

	{NANOARROW_TYPE_UINT16, INT4OID, lance_conv_int4},
	{NANOARROW_TYPE_UINT16, INT8OID, lance_conv_int8},

	{NANOARROW_TYPE_UINT32, INT8OID, lance_conv_int8},

	/*
	 * nanoarrow decodes a half float into the double it denotes, so float16
	 * needs no converter of its own; every value of it is exact in real.
	 */
	{NANOARROW_TYPE_HALF_FLOAT, FLOAT4OID, lance_conv_float4},
	{NANOARROW_TYPE_HALF_FLOAT, FLOAT8OID, lance_conv_float8},

	{NANOARROW_TYPE_FLOAT, FLOAT4OID, lance_conv_float4},
	{NANOARROW_TYPE_FLOAT, FLOAT8OID, lance_conv_float8},

	{NANOARROW_TYPE_DOUBLE, FLOAT8OID, lance_conv_float8},

	{NANOARROW_TYPE_STRING, TEXTOID, lance_conv_text},
	{NANOARROW_TYPE_STRING, VARCHAROID, lance_conv_text},
	{NANOARROW_TYPE_LARGE_STRING, TEXTOID, lance_conv_text},
	{NANOARROW_TYPE_LARGE_STRING, VARCHAROID, lance_conv_text},

	{NANOARROW_TYPE_BINARY, BYTEAOID, lance_conv_bytea},
	{NANOARROW_TYPE_LARGE_BINARY, BYTEAOID, lance_conv_bytea},

	{NANOARROW_TYPE_DATE32, DATEOID, lance_conv_date},

	/*
	 * The unit decides which of the four timestamp converters runs and the
	 * zone decides which of the two PostgreSQL types is the right one; both
	 * are read off the field in lance_resolve_timestamp().
	 */
	{NANOARROW_TYPE_TIMESTAMP, TIMESTAMPOID, lance_conv_ts_micro},
	{NANOARROW_TYPE_TIMESTAMP, TIMESTAMPTZOID, lance_conv_ts_micro},

	{NANOARROW_TYPE_DECIMAL128, NUMERICOID, lance_conv_numeric},

	{NANOARROW_TYPE_UNINITIALIZED, InvalidOid, NULL}
};

static LanceConvertFn
lance_converter_lookup(enum ArrowType arrow_type, Oid pgtypid)
{
	const LanceConverterRule *rule;

	for (rule = lance_converter_rules; rule->convert != NULL; rule++)
	{
		if (rule->arrow_type == arrow_type && rule->pgtypid == pgtypid)
			return rule->convert;
	}
	return NULL;
}

static bool
lance_arrow_is_list_type(enum ArrowType arrow_type)
{
	return arrow_type == NANOARROW_TYPE_LIST ||
		arrow_type == NANOARROW_TYPE_FIXED_SIZE_LIST;
}

/*
 * Does this build know how to read the Arrow type at all?  An A-tier type with
 * no rule anywhere is one this build has not implemented yet, which is a
 * different message from one that simply does not fit the declared column.
 *
 * The list shapes are named here rather than in the table because they have no
 * rows of their own; their rule is the rule of their element.
 */
static bool
lance_converter_type_known(enum ArrowType arrow_type)
{
	const LanceConverterRule *rule;

	if (lance_arrow_is_list_type(arrow_type))
		return true;

	for (rule = lance_converter_rules; rule->convert != NULL; rule++)
	{
		if (rule->arrow_type == arrow_type)
			return true;
	}
	return false;
}

static const char *
lance_arrow_name_or(const struct ArrowSchema *field, const char *fallback)
{
	const char *name = lance_arrow_type_name(field);

	return name != NULL ? name : fallback;
}

/*
 * A length-limited character type would need the length enforced on every
 * value, and silently keeping a longer one is exactly what I7 forbids.
 */
static bool
lance_type_length_limited(Oid pgtypid, int32 pgtypmod)
{
	return (pgtypid == VARCHAROID || pgtypid == BPCHAROID) && pgtypmod >= 0;
}

/*
 * Is a decimal128(p,s) readable into the declared numeric?
 *
 * numeric(P,S) keeps S digits after the point and P-S before it, where the
 * Arrow type needs s and p-s; both halves have to fit.  A declaration that is
 * too narrow would have numeric_in round the value away or reject it value by
 * value, and I7 wants that refused before the scan starts.  Plain numeric
 * constrains nothing and always fits.
 */
static bool
lance_decimal_fits(const struct ArrowSchemaView *view, int32 pgtypmod)
{
	int32		precision;
	int32		scale;

	if (pgtypmod < (int32) VARHDRSZ)
		return true;

	/*
	 * The inverse of the encoding lance_arrow_map_type() writes, with the
	 * scale sign-extended out of its 11-bit field: PostgreSQL 15 and up allow
	 * a numeric to be declared with a negative scale.
	 */
	precision = (int32) (((pgtypmod - VARHDRSZ) >> 16) & 0xffff);
	scale = (int32) (((((pgtypmod - VARHDRSZ) & 0x7ff) ^ 1024) - 1024));

	return scale >= view->decimal_scale &&
		(precision - scale) >= (view->decimal_precision - view->decimal_scale);
}

/*
 * A timestamp's unit and zone are not part of its ArrowType, so the pair the
 * dispatch table is keyed by cannot settle three things on its own:
 *
 *	- a zone means the column is a timestamptz and no zone means it is a
 *	  timestamp; reading either as the other is refused rather than silently
 *	  reinterpreted (DESIGN D8),
 *	- the declared precision has to hold microseconds, because a timestamp(3)
 *	  would truncate every value PostgreSQL stored in it (I7), and
 *	- the converter itself depends on the unit.
 *
 * NULL means the declaration does not fit, which the caller reports as the one
 * type-mismatch error.
 */
static LanceConvertFn
lance_resolve_timestamp(const struct ArrowSchemaView *view, Oid pgtypid,
						int32 pgtypmod)
{
	bool		has_zone = (view->timezone != NULL && view->timezone[0] != '\0');

	if (pgtypid != (has_zone ? TIMESTAMPTZOID : TIMESTAMPOID))
		return NULL;

	/* -1 is "no precision given", which keeps all six digits. */
	if (pgtypmod >= 0 && pgtypmod < LANCE_TIMESTAMP_TYPMOD)
		return NULL;

	switch (view->time_unit)
	{
		case NANOARROW_TIME_UNIT_SECOND:
			return lance_conv_ts_second;
		case NANOARROW_TIME_UNIT_MILLI:
			return lance_conv_ts_milli;
		case NANOARROW_TIME_UNIT_MICRO:
			return lance_conv_ts_micro;
		case NANOARROW_TIME_UNIT_NANO:
			return lance_conv_ts_nano;
	}

	return NULL;
}

/*
 * Pick the converter for a scalar column: the table decides which pairs are
 * allowed at all, and the two types whose rule depends on more than the pair
 * get their say afterwards.  NULL means the declaration does not fit.
 */
static LanceConvertFn
lance_resolve_scalar(const struct ArrowSchemaView *view, Oid pgtypid,
					 int32 pgtypmod)
{
	LanceConvertFn convert = lance_converter_lookup(view->type, pgtypid);

	if (convert == NULL)
		return NULL;

	switch (view->type)
	{
		case NANOARROW_TYPE_TIMESTAMP:
			return lance_resolve_timestamp(view, pgtypid, pgtypmod);
		case NANOARROW_TYPE_DECIMAL128:
			return lance_decimal_fits(view, pgtypmod) ? convert : NULL;
		default:
			return convert;
	}
}

/* The state a converter reads out of the Arrow type it was resolved against. */
static void
lance_converter_set_arrow_state(LanceConverter *conv,
								const struct ArrowSchemaView *view)
{
	conv->arrow_type = view->type;
	conv->decimal_precision = view->decimal_precision;
	conv->decimal_scale = view->decimal_scale;
	conv->fixed_size = view->fixed_size;
}

/*
 * A list-shaped column has no row in the dispatch table: its rule is its
 * element's rule.  That is what lets list<int64> be read as bigint[] and
 * refuses it as integer[], with the same widening the element type would get
 * as a column of its own, without a row per (list type, array type) pair.
 *
 * On success *out gains an element converter with a view of its own, which
 * set_array() then points at the child array.  NULL means the declared type is
 * not an array of anything the element can be read as, which the caller
 * reports as the one type-mismatch error.
 */
static LanceConvertFn
lance_resolve_list(const struct ArrowSchema *field,
				   const struct ArrowSchemaView *view, Oid pgtypid,
				   int32 pgtypmod, LanceConverter *out)
{
	Oid			elemtypid = get_element_type(pgtypid);
	struct ArrowSchema *child;
	struct ArrowSchemaView childview;
	struct ArrowError error;
	LanceConverter *element;
	LanceConvertFn elemconvert;

	/*
	 * An array column carries its element's typmod, so numeric(10,2)[] and
	 * varchar(4)[] constrain their elements exactly as the scalar columns do.
	 */
	if (!OidIsValid(elemtypid) || lance_type_length_limited(elemtypid, pgtypmod))
		return NULL;

	/* map_type() accepted the field, so it has exactly one A-tier child. */
	child = field->children[0];

	memset(&error, 0, sizeof(error));
	if (ArrowSchemaViewInit(&childview, child, &error) != NANOARROW_OK)
		return NULL;

	elemconvert = lance_resolve_scalar(&childview, elemtypid, pgtypmod);
	if (elemconvert == NULL)
		return NULL;

	element = (LanceConverter *) palloc0(sizeof(LanceConverter));
	element->convert = elemconvert;

	/* Errors about an element name the column, not the Arrow child's "item". */
	element->colname = out->colname;
	element->pgtypid = elemtypid;
	element->pgtypmod = pgtypmod;
	lance_converter_set_arrow_state(element, &childview);

	/*
	 * Hang the element off *out before its view is initialised: from here on
	 * the scan's cleanup can reach it, so an error below gives back whatever
	 * the half-built view had allocated (I6).
	 */
	out->element = element;

	memset(&error, 0, sizeof(error));
	if (ArrowArrayViewInitFromSchema(&element->view, child, &error) != NANOARROW_OK)
		ereport(ERROR,
				(errcode(ERRCODE_FDW_INVALID_DATA_TYPE),
				 errmsg("lance_fdw: cannot read the elements of column \"%s\" of Arrow type \"%s\"",
						out->colname, lance_arrow_format(field)),
				 errdetail("%s", error.message)));

	out->elemtypid = elemtypid;
	get_typlenbyvalalign(elemtypid, &out->elemlen, &out->elembyval,
						 &out->elemalign);

	return lance_conv_array;
}

void
lance_arrow_resolve_converter(const struct ArrowSchema *field, Oid pgtypid,
							  int32 pgtypmod, LanceConverter *out)
{
	struct ArrowSchemaView view;
	struct ArrowError error;
	Oid			natural_typid;
	int32		natural_typmod;
	bool		is_b_tier;
	const char *colname;

	memset(out, 0, sizeof(*out));

	colname = (field != NULL && field->name != NULL) ? field->name : "?";
	out->colname = pstrdup(colname);
	out->pgtypid = pgtypid;
	out->pgtypmod = pgtypmod;

	/*
	 * The tier decision comes first and is independent of what the table
	 * declares: a B-tier column is unreadable whatever the user wrote (I8).
	 */
	if (!lance_arrow_map_type(field, &natural_typid, &natural_typmod,
							  &is_b_tier))
		ereport(ERROR,
				(errcode(ERRCODE_FDW_INVALID_DATA_TYPE),
				 errmsg("lance_fdw: column \"%s\": Lance type \"%s\" (%s) is not supported and cannot be read as %s",
						colname, lance_arrow_format(field),
						lance_arrow_name_or(field, "unparsable"),
						format_type_with_typemod(pgtypid, pgtypmod)),
				 errhint("Drop the column from the foreign table, or read it "
						 "with a tool that understands the type.")));

	memset(&error, 0, sizeof(error));
	if (ArrowSchemaViewInit(&view, field, &error) != NANOARROW_OK)
		ereport(ERROR,
				(errcode(ERRCODE_FDW_INVALID_DATA_TYPE),
				 errmsg("lance_fdw: cannot parse Arrow type \"%s\" of column \"%s\"",
						lance_arrow_format(field), colname),
				 errdetail("%s", error.message)));

	lance_converter_set_arrow_state(out, &view);

	if (lance_arrow_is_list_type(view.type))
		out->convert = lance_resolve_list(field, &view, pgtypid, pgtypmod, out);
	else
		out->convert = lance_resolve_scalar(&view, pgtypid, pgtypmod);

	/*
	 * Every A-tier type has an implementation as of P3, so nothing reaches
	 * this today; it stays as the honest message should map_type() ever gain a
	 * type before the dispatch table does.
	 */
	if (out->convert == NULL && !lance_converter_type_known(view.type))
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("lance_fdw: column \"%s\": Lance type \"%s\" (%s) is not supported in this build and cannot be read as %s",
						colname, lance_arrow_format(field),
						lance_arrow_name_or(field, "unparsable"),
						format_type_with_typemod(pgtypid, pgtypmod)),
				 errdetail("This Arrow type maps to %s, but no converter for it "
						   "is compiled in yet.",
						   format_type_with_typemod(natural_typid,
													natural_typmod))));

	if (out->convert == NULL)
		ereport(ERROR,
				(errcode(ERRCODE_FDW_INVALID_DATA_TYPE),
				 errmsg("lance_fdw: column \"%s\": Lance type \"%s\" (%s) cannot be read as %s",
						colname, lance_arrow_format(field),
						lance_arrow_name_or(field, "unparsable"),
						format_type_with_typemod(pgtypid, pgtypmod)),
				 errhint("Declare the column %s.",
						 format_type_with_typemod(natural_typid,
												  natural_typmod))));

	/*
	 * The same refusal lance_resolve_list() makes for an element, with the
	 * detail a column of its own can carry.
	 */
	if (lance_type_length_limited(pgtypid, pgtypmod))
		ereport(ERROR,
				(errcode(ERRCODE_FDW_INVALID_DATA_TYPE),
				 errmsg("lance_fdw: column \"%s\": Lance type \"%s\" (%s) cannot be read as %s",
						colname, lance_arrow_format(field),
						lance_arrow_name_or(field, "unparsable"),
						format_type_with_typemod(pgtypid, pgtypmod)),
				 errdetail("A length limit would have to truncate values."),
				 errhint("Declare the column text.")));

	memset(&error, 0, sizeof(error));
	if (ArrowArrayViewInitFromSchema(&out->view, field, &error) != NANOARROW_OK)
		ereport(ERROR,
				(errcode(ERRCODE_FDW_INVALID_DATA_TYPE),
				 errmsg("lance_fdw: cannot read column \"%s\" of Arrow type \"%s\"",
						colname, lance_arrow_format(field)),
				 errdetail("%s", error.message)));
}

void
lance_arrow_converter_set_array(LanceConverter *conv,
								const struct ArrowArray *array)
{
	struct ArrowError error;

	memset(&error, 0, sizeof(error));
	if (ArrowArrayViewSetArray(&conv->view, array, &error) != NANOARROW_OK)
		ereport(ERROR,
				(errcode(ERRCODE_FDW_INVALID_DATA_TYPE),
				 errmsg("lance_fdw: column \"%s\": Lance returned a batch this build cannot read",
						conv->colname),
				 errdetail("%s", error.message)));

	/*
	 * A list column's element converter keeps a view of its own so that the
	 * scalar converters work on an element unchanged.  It is pointed at the
	 * child array, whose own offset its accessors then apply.
	 */
	if (conv->element != NULL)
	{
		if (array->n_children != 1 || array->children == NULL ||
			array->children[0] == NULL)
			ereport(ERROR,
					(errcode(ERRCODE_FDW_INVALID_DATA_TYPE),
					 errmsg("lance_fdw: column \"%s\": Lance returned a list of " INT64_FORMAT " children, expected 1",
							conv->colname, array->n_children)));

		lance_arrow_converter_set_array(conv->element, array->children[0]);
	}
}

void
lance_arrow_converter_reset(LanceConverter *conv)
{
	/*
	 * A list column's views are the ones with something outside palloc to give
	 * back: ArrowArrayViewInitFromSchema allocates a child view per level, in
	 * the parent's own view and again in the element converter's (I6).  The
	 * converters themselves are palloc'd and go with the scan's context.
	 */
	if (conv->element != NULL)
	{
		lance_arrow_converter_reset(conv->element);
		conv->element = NULL;
	}

	ArrowArrayViewReset(&conv->view);
}
