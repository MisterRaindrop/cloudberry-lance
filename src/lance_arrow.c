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
#include "varatt.h"
#include "utils/builtins.h"
#include "utils/lsyscache.h"
#include "utils/memutils.h"

#define LANCE_BLOB_METADATA_KEY "lance-encoding"
#define LANCE_BLOB_METADATA_VALUE "blob"

/*
 * PostgreSQL keeps microseconds, so every Arrow timestamp becomes a
 * timestamp(6); a coarser Arrow unit is exact in it and a finer one (ns) is
 * rejected value by value at scan time rather than silently rounded (I7).
 */
#define LANCE_TIMESTAMP_TYPMOD 6

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
 * The dispatch table.  A row means "this Arrow type may be read into this
 * PostgreSQL type"; the absence of a row is what makes int64 into integer, or
 * utf8 into integer, an error at BeginForeignScan instead of a wrong value
 * later.  Widening within a family is present, narrowing never is.
 *
 * Adding a type is adding rows here plus the function they name.  Nothing else
 * in the scan path knows about types.
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

	{NANOARROW_TYPE_FLOAT, FLOAT4OID, lance_conv_float4},
	{NANOARROW_TYPE_FLOAT, FLOAT8OID, lance_conv_float8},

	{NANOARROW_TYPE_DOUBLE, FLOAT8OID, lance_conv_float8},

	{NANOARROW_TYPE_STRING, TEXTOID, lance_conv_text},
	{NANOARROW_TYPE_STRING, VARCHAROID, lance_conv_text},
	{NANOARROW_TYPE_LARGE_STRING, TEXTOID, lance_conv_text},
	{NANOARROW_TYPE_LARGE_STRING, VARCHAROID, lance_conv_text},

	{NANOARROW_TYPE_BINARY, BYTEAOID, lance_conv_bytea},
	{NANOARROW_TYPE_LARGE_BINARY, BYTEAOID, lance_conv_bytea},

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

/*
 * Does this build know how to read the Arrow type at all?  An A-tier type with
 * no rule anywhere is one this build has not implemented yet, which is a
 * different message from one that simply does not fit the declared column.
 */
static bool
lance_converter_type_known(enum ArrowType arrow_type)
{
	const LanceConverterRule *rule;

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
				 errmsg("lance_fdw: column \"%s\": Lance type \"%s\" (%s) is not supported",
						colname, lance_arrow_format(field),
						lance_arrow_name_or(field, "unparsable")),
				 errdetail("The foreign table declares this column %s.",
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

	out->arrow_type = view.type;
	out->decimal_precision = view.decimal_precision;
	out->decimal_scale = view.decimal_scale;
	out->fixed_size = view.fixed_size;

	out->convert = lance_converter_lookup(view.type, pgtypid);

	if (out->convert == NULL && !lance_converter_type_known(view.type))
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("lance_fdw: column \"%s\": Lance type \"%s\" (%s) is not supported in this build",
						colname, lance_arrow_format(field),
						lance_arrow_name_or(field, "unparsable")),
				 errdetail("The foreign table declares this column %s.",
						   format_type_with_typemod(pgtypid, pgtypmod))));

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
	 * A length-limited character type would need the length enforced on every
	 * value, and silently keeping a longer one is exactly what I7 forbids.
	 */
	if ((pgtypid == VARCHAROID || pgtypid == BPCHAROID) && pgtypmod >= 0)
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
}

void
lance_arrow_converter_reset(LanceConverter *conv)
{
	/*
	 * Nothing outside palloc is held for the scalar types this build reads -
	 * ArrowArrayViewInitFromSchema only allocates for nested ones - but the
	 * call is the contract, and a nested converter added later must not have to
	 * change the scan.
	 */
	ArrowArrayViewReset(&conv->view);
}
