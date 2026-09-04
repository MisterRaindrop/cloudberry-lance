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
#include "utils/lsyscache.h"

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
