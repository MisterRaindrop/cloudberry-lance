-- scan_core: reading rows.  The values here are the ones pylance read back out
-- of the same fixtures, in test/fixtures/expected/*.jsonl; every query below is
-- that file seen through the wrapper.
--
-- Text columns are printed through to_json() because two of the fixture values
-- carry a tab and a newline, which would otherwise break the expected file into
-- pieces, and because it tells an empty string from a NULL.  Binary columns are
-- printed as they come, which is bytea's hex output.
\pset format unaligned
DO $$
BEGIN
  EXECUTE format('CREATE SERVER scan_files FOREIGN DATA WRAPPER lance_fdw OPTIONS (base_uri %L)',
                 current_setting('regress.fixture_dir'));
END
$$;
-- Written by hand rather than imported: this is also the case where a foreign
-- table declares a subset of the dataset's columns.
CREATE FOREIGN TABLE lance_regress.sc_types (
  id integer,
  c_bool boolean,
  c_int8 smallint,
  c_int16 smallint,
  c_int32 integer,
  c_int64 bigint,
  c_uint8 smallint,
  c_uint16 integer,
  c_uint32 bigint,
  c_float32 real,
  c_float64 double precision,
  c_utf8 text,
  c_large_utf8 text,
  c_binary bytea,
  c_large_binary bytea
) SERVER scan_files OPTIONS (uri 'types_all.lance');
SELECT id, c_bool, c_int8, c_int16, c_int32, c_int64, c_uint8, c_uint16, c_uint32
  FROM lance_regress.sc_types ORDER BY id;
SELECT id, c_float32, c_float64 FROM lance_regress.sc_types ORDER BY id;
SELECT id, to_json(c_utf8) AS utf8, to_json(c_large_utf8) AS large_utf8
  FROM lance_regress.sc_types ORDER BY id;
SELECT id, c_binary, c_large_binary FROM lance_regress.sc_types ORDER BY id;
-- count(*) reads no column at all: the scan projects nothing and counts the
-- length of each Arrow batch.
SELECT count(*) FROM lance_regress.sc_types;
-- A projection that does not start at the first column.
SELECT count(*), count(c_int16), min(c_int16), max(c_int16) FROM lance_regress.sc_types;
-- A column referenced only in WHERE still has to be read.
SELECT id FROM lance_regress.sc_types WHERE c_int32 = 424242 ORDER BY id;
-- Widening inside a family: the same dataset read into the widest types.
CREATE FOREIGN TABLE lance_regress.sc_wide (
  id bigint,
  c_int8 bigint,
  c_int16 integer,
  c_int32 bigint,
  c_uint8 integer,
  c_uint16 bigint,
  c_float32 double precision
) SERVER scan_files OPTIONS (uri 'types_all.lance');
SELECT id, c_int8, c_int16, c_int32, c_uint8, c_uint16, c_float32
  FROM lance_regress.sc_wide WHERE id IN (1, 3, 11) ORDER BY id;
-- A batch size that straddles both batch and fragment boundaries must not
-- change a single row.
CREATE FOREIGN TABLE lance_regress.sc_types_b3 (
  id integer,
  c_bool boolean,
  c_int8 smallint,
  c_int16 smallint,
  c_int32 integer,
  c_int64 bigint,
  c_uint8 smallint,
  c_uint16 integer,
  c_uint32 bigint,
  c_float32 real,
  c_float64 double precision,
  c_utf8 text,
  c_large_utf8 text,
  c_binary bytea,
  c_large_binary bytea
) SERVER scan_files OPTIONS (uri 'types_all.lance', batch_size '3');
SELECT count(*) AS batch3_only FROM (
  SELECT * FROM lance_regress.sc_types_b3
  EXCEPT SELECT * FROM lance_regress.sc_types) d;
SELECT count(*) AS default_only FROM (
  SELECT * FROM lance_regress.sc_types
  EXCEPT SELECT * FROM lance_regress.sc_types_b3) d;
SELECT count(*) AS rows_b3 FROM lance_regress.sc_types_b3;
-- Deleted rows do not come back, and the batches that follow a deletion file
-- start at a non-zero offset.
CREATE FOREIGN TABLE lance_regress.sc_deleted (id integer, v text, n bigint)
  SERVER scan_files OPTIONS (uri 'deleted.lance');
SELECT count(*) AS rows, sum(n) AS sum_n FROM lance_regress.sc_deleted;
SELECT id, v, n FROM lance_regress.sc_deleted ORDER BY id;
-- Nothing to read at all.
CREATE FOREIGN TABLE lance_regress.sc_empty (id integer, v text, n bigint)
  SERVER scan_files OPTIONS (uri 'empty.lance');
SELECT count(*) AS rows FROM lance_regress.sc_empty;
SELECT * FROM lance_regress.sc_empty;
-- Fragment ids with a hole in them: nothing may assume they run 0..N-1.
CREATE FOREIGN TABLE lance_regress.sc_gap (id integer, v text, n bigint)
  SERVER scan_files OPTIONS (uri 'frag_gap.lance');
SELECT id, v, n FROM lance_regress.sc_gap ORDER BY id;
-- Schema evolution: v10 and vup were added later and live in data files of
-- their own, so one fragment's columns come from three files.
CREATE FOREIGN TABLE lance_regress.sc_evolved
  (id integer, v text, n bigint, v10 integer, vup text)
  SERVER scan_files OPTIONS (uri 'evolved.lance');
SELECT id, v, n, v10, vup FROM lance_regress.sc_evolved ORDER BY id;
SELECT count(*) AS wrong_rows FROM lance_regress.sc_evolved
  WHERE v10 <> id * 10 OR vup <> upper(v);
-- Joins.  The local side is replicated so that the join needs no motion and
-- the planner is free to pick either shape.
CREATE FOREIGN TABLE lance_regress.sc_frag3 (id integer, v text, n bigint)
  SERVER scan_files OPTIONS (uri 'frag_3.lance');
CREATE TABLE lance_regress.sc_local (id integer, label text) DISTRIBUTED REPLICATED;
INSERT INTO lance_regress.sc_local VALUES (2, 'two'), (7, 'seven'), (11, 'eleven'), (99, 'none');
SET enable_hashjoin = on;
SET enable_nestloop = off;
SET enable_mergejoin = off;
SELECT l.label, f.v, f.n FROM lance_regress.sc_frag3 f
  JOIN lance_regress.sc_local l USING (id) ORDER BY l.label;
SELECT lance_regress.plan_mentions(
  'SELECT l.label FROM lance_regress.sc_frag3 f JOIN lance_regress.sc_local l USING (id)',
  'COSTS OFF', 'Hash Join') AS hash_join;
-- The same join as a nested loop.  rows_hint is what makes the foreign side
-- look small enough for the planner to put it on the inside, which is the case
-- that rescans it; without the hint every foreign table is the same constant
-- size and the local four-row table wins the inside.
CREATE FOREIGN TABLE lance_regress.sc_frag3_tiny (id integer, v text, n bigint)
  SERVER scan_files OPTIONS (uri 'frag_3.lance', rows_hint '1');
SET enable_hashjoin = off;
SET enable_nestloop = on;
SET enable_material = off;
SELECT l.label, f.v, f.n FROM lance_regress.sc_frag3_tiny f
  JOIN lance_regress.sc_local l USING (id) ORDER BY l.label;
SELECT lance_regress.plan_mentions(
  'SELECT l.label FROM lance_regress.sc_frag3_tiny f JOIN lance_regress.sc_local l USING (id)',
  'COSTS OFF', 'Nested Loop') AS nested_loop;
RESET enable_hashjoin;
RESET enable_nestloop;
RESET enable_mergejoin;
RESET enable_material;
-- The same datasets over s3://, with the credentials coming from the user
-- mapping.  The rows are compared against the file:// tables that were just
-- checked value by value, in both directions.
DO $$
BEGIN
  EXECUTE format('CREATE SERVER scan_s3 FOREIGN DATA WRAPPER lance_fdw '
                 'OPTIONS (base_uri %L, aws_endpoint %L, aws_region %L, allow_http %L)',
                 's3://' || current_setting('regress.s3_bucket') || '/fixtures',
                 current_setting('regress.s3_endpoint'),
                 current_setting('regress.s3_region'),
                 'true');
  EXECUTE format('CREATE USER MAPPING FOR PUBLIC SERVER scan_s3 '
                 'OPTIONS (aws_access_key_id %L, aws_secret_access_key %L)',
                 current_setting('regress.s3_key'),
                 current_setting('regress.s3_secret'));
END
$$;
CREATE FOREIGN TABLE lance_regress.sc_types_s3 (
  id integer,
  c_bool boolean,
  c_int8 smallint,
  c_int16 smallint,
  c_int32 integer,
  c_int64 bigint,
  c_uint8 smallint,
  c_uint16 integer,
  c_uint32 bigint,
  c_float32 real,
  c_float64 double precision,
  c_utf8 text,
  c_large_utf8 text,
  c_binary bytea,
  c_large_binary bytea
) SERVER scan_s3 OPTIONS (uri 'types_all.lance');
SELECT count(*) AS rows_s3 FROM lance_regress.sc_types_s3;
SELECT count(*) AS s3_only FROM (
  SELECT * FROM lance_regress.sc_types_s3
  EXCEPT SELECT * FROM lance_regress.sc_types) d;
SELECT count(*) AS file_only FROM (
  SELECT * FROM lance_regress.sc_types
  EXCEPT SELECT * FROM lance_regress.sc_types_s3) d;
CREATE FOREIGN TABLE lance_regress.sc_frag3_s3 (id integer, v text, n bigint)
  SERVER scan_s3 OPTIONS (uri 'frag_3.lance');
SELECT id, v, n FROM lance_regress.sc_frag3_s3 ORDER BY id;
