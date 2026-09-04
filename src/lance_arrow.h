/*-------------------------------------------------------------------------
 *
 * lance_arrow.h
 *	  Arrow <-> PostgreSQL type bridge.
 *
 * This block only carries the schema direction: given an Arrow field, what
 * PostgreSQL type does IMPORT FOREIGN SCHEMA write, and is the field A-tier
 * (readable) or B-tier (skipped on import, refused on scan)?  The value
 * converters land on top of this in a later change.
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

#endif							/* LANCE_ARROW_H */
