/* sql/lance_fdw--0.1.sql */

-- complain if the script is sourced by psql instead of CREATE EXTENSION
\echo Use "CREATE EXTENSION lance_fdw" to load this file. \quit

CREATE FUNCTION lance_fdw_handler()
RETURNS fdw_handler
AS 'MODULE_PATHNAME', 'lance_fdw_handler'
LANGUAGE C STRICT;

CREATE FUNCTION lance_fdw_validator(text[], oid)
RETURNS void
AS 'MODULE_PATHNAME', 'lance_fdw_validator'
LANGUAGE C STRICT;

/*
 * mpp_execute defaults to 'all segments' so that the planner puts the
 * ForeignScan on every segment and gives it a Strewn locus (DESIGN D1).  A
 * server or a table may still override it with 'coordinator' or 'any', in
 * which case the executing process reads every fragment by itself.
 */
CREATE FOREIGN DATA WRAPPER lance_fdw
  HANDLER lance_fdw_handler
  VALIDATOR lance_fdw_validator
  OPTIONS (mpp_execute 'all segments');

COMMENT ON FOREIGN DATA WRAPPER lance_fdw IS 'reads Lance datasets in parallel on all segments';
