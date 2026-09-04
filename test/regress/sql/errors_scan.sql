-- errors_scan: the scan half of AC7 and all of AC4.
--
-- Two shapes of failure live here.  The storage ones - a path that is not
-- there, a bucket that is not there, credentials that are wrong, an endpoint
-- nothing answers - quote paths and lance's own wording, so they go through
-- capture() and only the category is compared.  The type ones are the opposite:
-- the message is the point, so they go through message(), which returns the
-- wording without the segment suffix a QE error arrives with.
\pset format unaligned
DO $$
BEGIN
  EXECUTE format('CREATE SERVER errs_files FOREIGN DATA WRAPPER lance_fdw OPTIONS (base_uri %L)',
                 current_setting('regress.fixture_dir'));
END
$$;
-- A local path that is not there.
CREATE SERVER errs_missing FOREIGN DATA WRAPPER lance_fdw
  OPTIONS (base_uri 'file:///lance_fdw_no_such_directory');
CREATE FOREIGN TABLE lance_regress.errs_missing_t (id integer, v text)
  SERVER errs_missing OPTIONS (uri 'nope.lance');
SELECT lance_regress.capture($$SELECT * FROM lance_regress.errs_missing_t$$) AS missing_path;
SELECT lance_regress.capture($$SELECT count(*) FROM lance_regress.errs_missing_t$$) AS missing_path_count;
DO $$
BEGIN
  -- a bucket that does not exist, with working credentials
  EXECUTE format('CREATE SERVER errs_badbucket FOREIGN DATA WRAPPER lance_fdw '
                 'OPTIONS (base_uri %L, aws_endpoint %L, aws_region %L, allow_http %L)',
                 's3://lance-fdw-no-such-bucket/fixtures',
                 current_setting('regress.s3_endpoint'),
                 current_setting('regress.s3_region'), 'true');
  EXECUTE format('CREATE USER MAPPING FOR PUBLIC SERVER errs_badbucket '
                 'OPTIONS (aws_access_key_id %L, aws_secret_access_key %L)',
                 current_setting('regress.s3_key'),
                 current_setting('regress.s3_secret'));
  -- the real bucket, with credentials that are not
  EXECUTE format('CREATE SERVER errs_badcreds FOREIGN DATA WRAPPER lance_fdw '
                 'OPTIONS (base_uri %L, aws_endpoint %L, aws_region %L, allow_http %L)',
                 's3://' || current_setting('regress.s3_bucket') || '/fixtures',
                 current_setting('regress.s3_endpoint'),
                 current_setting('regress.s3_region'), 'true');
  EXECUTE 'CREATE USER MAPPING FOR PUBLIC SERVER errs_badcreds '
          'OPTIONS (aws_access_key_id ''wrong-key'', aws_secret_access_key ''wrong-secret'')';
  -- an endpoint nothing listens on; object_store retries a refused connection
  -- with backoff, so this one takes a few seconds to give up
  EXECUTE format('CREATE SERVER errs_badendpoint FOREIGN DATA WRAPPER lance_fdw '
                 'OPTIONS (base_uri %L, aws_endpoint %L, aws_region %L, allow_http %L)',
                 's3://' || current_setting('regress.s3_bucket') || '/fixtures',
                 'http://127.0.0.1:1',
                 current_setting('regress.s3_region'), 'true');
  EXECUTE format('CREATE USER MAPPING FOR PUBLIC SERVER errs_badendpoint '
                 'OPTIONS (aws_access_key_id %L, aws_secret_access_key %L)',
                 current_setting('regress.s3_key'),
                 current_setting('regress.s3_secret'));
END
$$;
CREATE FOREIGN TABLE lance_regress.errs_badbucket_t (id integer, v text, n bigint)
  SERVER errs_badbucket OPTIONS (uri 'frag_3.lance');
CREATE FOREIGN TABLE lance_regress.errs_badcreds_t (id integer, v text, n bigint)
  SERVER errs_badcreds OPTIONS (uri 'frag_3.lance');
CREATE FOREIGN TABLE lance_regress.errs_badendpoint_t (id integer, v text, n bigint)
  SERVER errs_badendpoint OPTIONS (uri 'frag_3.lance');
SELECT lance_regress.capture($$SELECT * FROM lance_regress.errs_badbucket_t$$) AS missing_bucket;
SELECT lance_regress.capture($$SELECT * FROM lance_regress.errs_badcreds_t$$) AS bad_credentials;
SELECT lance_regress.capture($$SELECT * FROM lance_regress.errs_badendpoint_t$$) AS unreachable_endpoint;
-- A version the dataset does not have.
CREATE FOREIGN TABLE lance_regress.errs_badversion (id integer, v text, n bigint)
  SERVER errs_files OPTIONS (uri 'frag_3.lance', version '999');
SELECT lance_regress.capture($$SELECT * FROM lance_regress.errs_badversion$$) AS missing_version;
-- Type checking (AC4).  Every message names the column, the Arrow format
-- string and the PostgreSQL type, because those three are what it takes to fix
-- the table definition.
CREATE FOREIGN TABLE lance_regress.errs_narrow (c_int64 integer)
  SERVER errs_files OPTIONS (uri 'types_all.lance');
SELECT lance_regress.message($$SELECT * FROM lance_regress.errs_narrow$$) AS int64_into_integer;
CREATE FOREIGN TABLE lance_regress.errs_uint32 (c_uint32 integer)
  SERVER errs_files OPTIONS (uri 'types_all.lance');
SELECT lance_regress.message($$SELECT * FROM lance_regress.errs_uint32$$) AS uint32_into_integer;
CREATE FOREIGN TABLE lance_regress.errs_text_int (c_utf8 integer)
  SERVER errs_files OPTIONS (uri 'types_all.lance');
SELECT lance_regress.message($$SELECT * FROM lance_regress.errs_text_int$$) AS utf8_into_integer;
CREATE FOREIGN TABLE lance_regress.errs_double_real (c_float64 real)
  SERVER errs_files OPTIONS (uri 'types_all.lance');
SELECT lance_regress.message($$SELECT * FROM lance_regress.errs_double_real$$) AS float64_into_real;
CREATE FOREIGN TABLE lance_regress.errs_varchar (c_utf8 varchar(4))
  SERVER errs_files OPTIONS (uri 'types_all.lance');
SELECT lance_regress.message($$SELECT * FROM lance_regress.errs_varchar$$) AS utf8_into_varchar4;
-- An A-tier type this build has no converter for yet.
CREATE FOREIGN TABLE lance_regress.errs_fsl (c_fsl_f32_4 text)
  SERVER errs_files OPTIONS (uri 'types_all.lance');
SELECT lance_regress.message($$SELECT * FROM lance_regress.errs_fsl$$) AS fsl_into_text;
-- A B-tier type, which no declaration makes readable (I8).
CREATE FOREIGN TABLE lance_regress.errs_struct (c_struct text)
  SERVER errs_files OPTIONS (uri 'types_b.lance');
SELECT lance_regress.message($$SELECT * FROM lance_regress.errs_struct$$) AS struct_into_text;
CREATE FOREIGN TABLE lance_regress.errs_uint64 (c_uint64 bigint)
  SERVER errs_files OPTIONS (uri 'types_b.lance');
SELECT lance_regress.message($$SELECT * FROM lance_regress.errs_uint64$$) AS uint64_into_bigint;
-- A column the dataset does not have at all: lance-c refuses the projection.
CREATE FOREIGN TABLE lance_regress.errs_nocolumn (id integer, no_such_column text)
  SERVER errs_files OPTIONS (uri 'frag_3.lance');
SELECT lance_regress.capture($$SELECT * FROM lance_regress.errs_nocolumn$$) AS unknown_column;
-- A column that is only in the way is not read, so the same table works as
-- long as nothing selects it.
SELECT count(*) AS rows_without_it FROM lance_regress.errs_nocolumn;
-- After all of that the same backend still reads a real dataset.
CREATE FOREIGN TABLE lance_regress.errs_ok (id integer, v text, n bigint)
  SERVER errs_files OPTIONS (uri 'frag_3.lance');
SELECT count(*) AS rows, sum(n) AS sum_n FROM lance_regress.errs_ok;
