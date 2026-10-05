/*-------------------------------------------------------------------------
 *
 * lance_arrow.h
 *	  Arrow <-> PostgreSQL type bridge.
 *
 * Two directions live here.  The schema direction answers what PostgreSQL type
 * IMPORT FOREIGN SCHEMA writes for an Arrow field, and whether the field is
 * A-tier (readable) or B-tier (skipped on import, refused on scan).  The value
 * direction is the converter: one function pointer plus per-column state,
 * resolved once per scan against the column's declared PostgreSQL type.
 *
 * IDENTIFICATION
 *	  src/lance_arrow.h
 *
 *-------------------------------------------------------------------------
 */
#ifndef LANCE_ARROW_H
#define LANCE_ARROW_H

#include "lance_fdw.h"

/*
 * Decide the tier of an Arrow field and, for A-tier fields, the PostgreSQL
 * type to declare for it.
 *
 * The decision reads two things (DESIGN D8): the Arrow type, and the field
 * metadata - a field carrying "lance-encoding" = "blob" is B-tier whatever its
 * Arrow type says, because lance-c's scanner hands out a
 * struct{position,size} descriptor for it rather than the bytes (PROBES Q3).
 *
 * Returns true when the field is A-tier, in which case *typid and *typmod are
 * set; *is_b_tier is always set and is the inverse of the return value.
 * Raises an error only if the Arrow schema itself cannot be parsed.
 */
extern bool lance_arrow_map_type(const struct ArrowSchema *field,
								 Oid *typid,
								 int32 *typmod,
								 bool *is_b_tier);

/* Is this field stored with Lance's blob encoding? */
extern bool lance_arrow_is_blob_encoded(const struct ArrowSchema *field);

/* Field format string, for error and notice messages; never NULL. */
extern const char *lance_arrow_format(const struct ArrowSchema *field);

/*
 * Readable name of the field's Arrow type ("uint64", "dictionary", ...), for
 * messages where the format string alone would be cryptic - a dictionary
 * column, for one, has the format string of its index type.  NULL when the
 * schema does not parse.
 */
extern const char *lance_arrow_type_name(const struct ArrowSchema *field);

/*
 * Value conversion (DESIGN D7, D8)
 *
 * One LanceConverter per projected column.  The scan resolves the whole set
 * once, in BeginForeignScan, from the schema the Arrow stream reports and the
 * types the foreign table declares; after that each batch only re-points the
 * views and each row calls one function pointer.
 *
 * The per-type state below is deliberately a flat struct rather than a void *:
 * a converter is looked up in a dispatch table keyed by (Arrow type, PostgreSQL
 * type), and adding a type means adding a row to that table and a function,
 * not touching this struct or the scan loop.
 */
typedef struct LanceConverter LanceConverter;

/*
 * Convert row `row` of the converter's current batch into a Datum.  Never
 * called for a NULL element - the scan checks that first.  Anything the
 * converter allocates comes from the caller's memory context, which the scan
 * resets at every batch boundary.
 */
typedef Datum (*LanceConvertFn) (LanceConverter *conv, int64 row);

struct LanceConverter
{
	LanceConvertFn convert;		/* NULL only before the converter is resolved */
	char	   *colname;		/* Lance column name, for messages */
	Oid			pgtypid;		/* what the foreign table declares */
	int32		pgtypmod;
	enum ArrowType arrow_type;	/* storage type behind the format string */

	/* Re-pointed at one column of the current batch by set_array() below. */
	struct ArrowArrayView view;

	/* Per-type state; a converter reads only the fields it set up. */
	int32		decimal_precision;
	int32		decimal_scale;
	int64		fixed_size;		/* fixed_size_list width */
	Oid			elemtypid;		/* array element type */
	int16		elemlen;
	bool		elembyval;
	char		elemalign;
	LanceConverter *element;	/* element converter for list-shaped columns */
};

/*
 * Decide how to read `field` into a column declared (pgtypid, pgtypmod), and
 * fill *out.  Widening inside a family is allowed (int32 into bigint, float32
 * into double precision); anything that would truncate, wrap or reinterpret is
 * an error here rather than a wrong value later (I7).
 *
 * Every error names the column, the Arrow format string and the PostgreSQL
 * type, because those three are what a user needs to fix the table definition.
 */
extern void lance_arrow_resolve_converter(const struct ArrowSchema *field,
										  Oid pgtypid,
										  int32 pgtypmod,
										  LanceConverter *out);

/* Point a resolved converter at one column of the current batch. */
extern void lance_arrow_converter_set_array(LanceConverter *conv,
											const struct ArrowArray *array);

/* Give back whatever the converter's array view owns.  Idempotent. */
extern void lance_arrow_converter_reset(LanceConverter *conv);

/*
 * Is element `row` of the converter's current batch NULL?  `row` is an index
 * into the column, so the caller has already added the record batch's own
 * offset (the C data interface makes a struct's offset apply to its children,
 * and nanoarrow does not propagate it).
 */
static inline bool
lance_arrow_converter_is_null(const LanceConverter *conv, int64 row)
{
	return ArrowArrayViewIsNull(&conv->view, row) != 0;
}

#endif							/* LANCE_ARROW_H */
