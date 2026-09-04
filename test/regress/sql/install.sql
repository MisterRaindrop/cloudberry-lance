-- install: the extension installs, ships exactly the objects its script
-- declares, and the wrapper carries the mpp_execute default that puts a
-- ForeignScan on every segment.  Every other suite assumes this one ran first.
--
-- Every suite here prints unaligned: the column widths of aligned output carry
-- no information these tests are about, and unaligned output has no trailing
-- whitespace, which keeps the expected files reviewable by eye.
\pset format unaligned
CREATE EXTENSION lance_fdw;
-- CREATE EXTENSION does not load the library; the GUCs appear once it is.
LOAD 'lance_fdw';
SELECT extname, extversion FROM pg_extension WHERE extname = 'lance_fdw';
SELECT pg_describe_object(d.classid, d.objid, 0) AS object
  FROM pg_depend d
  WHERE d.refclassid = 'pg_extension'::regclass
    AND d.refobjid = (SELECT oid FROM pg_extension WHERE extname = 'lance_fdw')
    AND d.deptype = 'e'
  ORDER BY 1;
SELECT fdwname, fdwoptions FROM pg_foreign_data_wrapper WHERE fdwname = 'lance_fdw';
SELECT name, setting FROM pg_settings WHERE name LIKE 'lance\_fdw.%' ORDER BY name;
CREATE SCHEMA lance_regress;
-- Errors that quote a path, a bucket or a lance message are not comparable
-- across environments, so the suites that provoke them run the statement
-- through this and compare the shape of the failure instead of its text.
CREATE FUNCTION lance_regress.capture(stmt text) RETURNS text
LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE stmt;
  RETURN 'no error';
EXCEPTION WHEN OTHERS THEN
  RETURN CASE
    WHEN SQLERRM LIKE 'lance: %' THEN 'lance error'
    WHEN SQLERRM LIKE 'lance_fdw: scan is not implemented%' THEN 'scan not implemented'
    ELSE 'other error: ' || SQLERRM
  END;
END;
$$;
