-- ddl: the option surface of DESIGN section 2 - what is accepted, what is
-- rejected, and where - plus a pg_dump round trip and a clean uninstall.
-- Every uri here is synthetic and no statement reaches an object store, which
-- is also what shows that DDL does no I/O (I13).
\pset format unaligned
CREATE SERVER lance_ddl_srv FOREIGN DATA WRAPPER lance_fdw
  OPTIONS (base_uri 'file:///lance/base',
           aws_endpoint 'http://minio.invalid:9000',
           aws_region 'us-east-1',
           allow_http 'true',
           virtual_hosted_style_request 'false');
-- Not a credential: this suite never reaches an object store.
CREATE USER MAPPING FOR PUBLIC SERVER lance_ddl_srv
  OPTIONS (aws_access_key_id 'AKIA_EXAMPLE',
           aws_secret_access_key 'example-only',
           aws_session_token 'example-token');
CREATE FOREIGN TABLE lance_regress.ddl_all (
  id integer,
  v text OPTIONS (column_name 'renamed_v')
) SERVER lance_ddl_srv
  OPTIONS (uri 'ds.lance', version '3', batch_size '128', rows_hint '4200');
SELECT o.opt AS server_option
  FROM pg_foreign_server s, unnest(s.srvoptions) AS o(opt)
  WHERE s.srvname = 'lance_ddl_srv' ORDER BY 1;
-- Names only: the values are credentials, and credentials do not belong in an
-- expected file even when they are made up.
SELECT split_part(o.opt, '=', 1) AS user_mapping_option
  FROM pg_user_mappings u, unnest(u.umoptions) AS o(opt)
  WHERE u.srvname = 'lance_ddl_srv' ORDER BY 1;
SELECT o.opt AS table_option
  FROM pg_foreign_table t, unnest(t.ftoptions) AS o(opt)
  WHERE t.ftrelid = 'lance_regress.ddl_all'::regclass ORDER BY 1;
SELECT format('%s: %s', a.attname, o.opt) AS column_option
  FROM pg_attribute a, unnest(a.attfdwoptions) AS o(opt)
  WHERE a.attrelid = 'lance_regress.ddl_all'::regclass ORDER BY 1;
-- mpp_execute may be overridden on a server and on a table.
CREATE SERVER lance_coord_srv FOREIGN DATA WRAPPER lance_fdw
  OPTIONS (base_uri 'file:///lance/base', mpp_execute 'coordinator');
ALTER FOREIGN TABLE lance_regress.ddl_all OPTIONS (ADD mpp_execute 'any');
SELECT o.opt AS mpp_option
  FROM pg_foreign_table t, unnest(t.ftoptions) AS o(opt)
  WHERE t.ftrelid = 'lance_regress.ddl_all'::regclass AND o.opt LIKE 'mpp%';
-- Rejected: an option that belongs on another object, or a value that is not
-- what it claims to be.
CREATE SERVER lance_bad FOREIGN DATA WRAPPER lance_fdw OPTIONS (bogus 'x');
CREATE SERVER lance_bad FOREIGN DATA WRAPPER lance_fdw OPTIONS (uri 'x');
CREATE SERVER lance_bad FOREIGN DATA WRAPPER lance_fdw OPTIONS (allow_http 'maybe');
CREATE SERVER lance_bad FOREIGN DATA WRAPPER lance_fdw OPTIONS (mpp_execute 'sideways');
CREATE USER MAPPING FOR PUBLIC SERVER lance_coord_srv OPTIONS (password 'x');
CREATE FOREIGN TABLE lance_regress.bad (id integer) SERVER lance_ddl_srv
  OPTIONS (version '1');
CREATE FOREIGN TABLE lance_regress.bad (id integer) SERVER lance_ddl_srv
  OPTIONS (uri 'x', version 'HEAD');
CREATE FOREIGN TABLE lance_regress.bad (id integer) SERVER lance_ddl_srv
  OPTIONS (uri 'x', version '-1');
CREATE FOREIGN TABLE lance_regress.bad (id integer) SERVER lance_ddl_srv
  OPTIONS (uri 'x', batch_size '0');
CREATE FOREIGN TABLE lance_regress.bad (id integer) SERVER lance_ddl_srv
  OPTIONS (uri 'x', rows_hint 'lots');
CREATE FOREIGN TABLE lance_regress.bad (id integer) SERVER lance_ddl_srv
  OPTIONS (uri 'x', base_uri 'y');
CREATE FOREIGN TABLE lance_regress.bad (id integer OPTIONS (nope 'x')) SERVER lance_ddl_srv
  OPTIONS (uri 'x');
-- The scan is not in this build yet and says so instead of returning rows.
SELECT lance_regress.capture($$SELECT * FROM lance_regress.ddl_all$$) AS scan;
-- pg_dump round trip: the dumped definition rebuilds the same foreign table.
\! pg_dump --schema-only --no-owner --table=lance_regress.ddl_all contrib_regression > test/regress/results/ddl_dump.sql 2>&1
\! grep -c '^CREATE FOREIGN TABLE lance_regress.ddl_all (' test/regress/results/ddl_dump.sql
DROP FOREIGN TABLE lance_regress.ddl_all;
\! psql -X -q -d contrib_regression -f test/regress/results/ddl_dump.sql 2>&1
SELECT o.opt AS table_option
  FROM pg_foreign_table t, unnest(t.ftoptions) AS o(opt)
  WHERE t.ftrelid = 'lance_regress.ddl_all'::regclass ORDER BY 1;
SELECT format('%s: %s', a.attname, o.opt) AS column_option
  FROM pg_attribute a, unnest(a.attfdwoptions) AS o(opt)
  WHERE a.attrelid = 'lance_regress.ddl_all'::regclass ORDER BY 1;
-- DROP EXTENSION CASCADE takes every lance object with it.  The notice lists
-- the cascaded objects in dependency order, which is not worth pinning down,
-- so it is silenced rather than compared.
SET client_min_messages = warning;
DROP EXTENSION lance_fdw CASCADE;
RESET client_min_messages;
SELECT count(*) AS lance_servers FROM pg_foreign_server WHERE srvname LIKE 'lance%';
SELECT count(*) AS lance_foreign_tables
  FROM pg_foreign_table t
  JOIN pg_class c ON c.oid = t.ftrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'lance_regress';
SELECT count(*) AS wrappers FROM pg_foreign_data_wrapper WHERE fdwname = 'lance_fdw';
-- and back, for the suites that follow
CREATE EXTENSION lance_fdw;
