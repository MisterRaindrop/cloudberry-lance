-- upgrade: ALTER EXTENSION lance_fdw UPDATE from 0.1 to 0.2 ends with the
-- objects CREATE EXTENSION gives 0.2, keeps the foreign tables built on 0.1,
-- and also works on a database whose 0.1 already had the vector operators -
-- the 0.1 that main shipped between the vector Top-K commit and 0.2.  Runs
-- right after install and leaves the extension as install left it.
\pset format unaligned
-- What an extension version consists of, to compare one install against another.
CREATE FUNCTION lance_feature.members() RETURNS SETOF text
LANGUAGE sql AS $$
  SELECT pg_describe_object(d.classid, d.objid, 0)
    FROM pg_depend d
   WHERE d.refclassid = 'pg_extension'::regclass
     AND d.refobjid = (SELECT oid FROM pg_extension WHERE extname = 'lance_fdw')
     AND d.deptype = 'e'
   ORDER BY 1;
$$;
SELECT version FROM pg_available_extension_versions WHERE name = 'lance_fdw' ORDER BY 1;
SELECT default_version FROM pg_available_extensions WHERE name = 'lance_fdw';
SELECT source, target, path FROM pg_extension_update_paths('lance_fdw') WHERE path IS NOT NULL ORDER BY 1, 2;
CREATE TEMP TABLE fresh_02 AS SELECT lance_feature.members() AS object;
SELECT extversion FROM pg_extension WHERE extname = 'lance_fdw';

-- 0.1 as it was released: no vector operators.
DROP EXTENSION lance_fdw;
CREATE EXTENSION lance_fdw VERSION '0.1';
SELECT lance_feature.members();
-- A foreign table made on 0.1 has to survive the update and then push down.
DO $$
BEGIN
  EXECUTE format('CREATE SERVER up_files FOREIGN DATA WRAPPER lance_fdw OPTIONS (base_uri %L)',
                 current_setting('regress.fixture_dir'));
END
$$;
CREATE FOREIGN TABLE lance_feature.up_vec (id integer, cat integer, emb real[])
  SERVER up_files OPTIONS (uri 'vectors.lance');
SELECT lance_feature.message($$SELECT id FROM lance_feature.up_vec ORDER BY emb <-> '{1,2,3,4,5,6,7,8}' LIMIT 3$$) AS before_update;
ALTER EXTENSION lance_fdw UPDATE;
SELECT extversion FROM pg_extension WHERE extname = 'lance_fdw';
SELECT object AS only_in_fresh FROM fresh_02 EXCEPT SELECT lance_feature.members();
SELECT lance_feature.members() EXCEPT SELECT object FROM fresh_02 AS only_in_updated;
SELECT lance_feature.plan_mentions(
  $$SELECT id FROM lance_feature.up_vec ORDER BY emb <-> '{1,2,3,4,5,6,7,8}' LIMIT 3$$,
  'COSTS OFF', 'Lance Vector Search:') AS pushed_after_update;
SELECT id FROM lance_feature.up_vec WHERE cat = 2 ORDER BY emb <-> '{1,2,3,4,5,6,7,8}' LIMIT 3;
-- Updating again is a no-op.
ALTER EXTENSION lance_fdw UPDATE;
DROP SERVER up_files CASCADE;

-- 0.1 from main between the vector Top-K commit and 0.2: the same objects as
-- 0.2 under the version 0.1.  Built here from the released 0.1 by adding them,
-- and the update has to keep them rather than fail on them.
DROP EXTENSION lance_fdw;
CREATE EXTENSION lance_fdw VERSION '0.1';
CREATE FUNCTION lance_l2_distance(real[], real[]) RETURNS double precision
  AS '$libdir/lance_fdw', 'lance_vector_l2_distance' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION lance_cosine_distance(real[], real[]) RETURNS double precision
  AS '$libdir/lance_fdw', 'lance_vector_cosine_distance' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION lance_negative_inner_product(real[], real[]) RETURNS double precision
  AS '$libdir/lance_fdw', 'lance_vector_negative_inner_product' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE OPERATOR <-> (LEFTARG = real[], RIGHTARG = real[], FUNCTION = lance_l2_distance, COMMUTATOR = '<->');
CREATE OPERATOR <=> (LEFTARG = real[], RIGHTARG = real[], FUNCTION = lance_cosine_distance, COMMUTATOR = '<=>');
CREATE OPERATOR <#> (LEFTARG = real[], RIGHTARG = real[], FUNCTION = lance_negative_inner_product, COMMUTATOR = '<#>');
ALTER EXTENSION lance_fdw ADD FUNCTION lance_l2_distance(real[], real[]);
ALTER EXTENSION lance_fdw ADD FUNCTION lance_cosine_distance(real[], real[]);
ALTER EXTENSION lance_fdw ADD FUNCTION lance_negative_inner_product(real[], real[]);
ALTER EXTENSION lance_fdw ADD OPERATOR <->(real[], real[]);
ALTER EXTENSION lance_fdw ADD OPERATOR <=>(real[], real[]);
ALTER EXTENSION lance_fdw ADD OPERATOR <#>(real[], real[]);
CREATE TEMP TABLE ops_before AS
  SELECT oprname, oid FROM pg_operator WHERE oprleft = 'real[]'::regtype AND oprname IN ('<->', '<=>', '<#>');
ALTER EXTENSION lance_fdw UPDATE;
SELECT extversion FROM pg_extension WHERE extname = 'lance_fdw';
SELECT object AS only_in_fresh FROM fresh_02 EXCEPT SELECT lance_feature.members();
SELECT lance_feature.members() EXCEPT SELECT object FROM fresh_02 AS only_in_updated;
-- Kept, not dropped and made again.
SELECT b.oprname, b.oid = o.oid AS same_operator
  FROM ops_before b JOIN pg_operator o
    ON o.oprname = b.oprname AND o.oprleft = 'real[]'::regtype AND o.oprright = 'real[]'::regtype
 ORDER BY 1;
SELECT obj_description(oid, 'pg_operator') AS comment FROM pg_operator
 WHERE oprleft = 'real[]'::regtype AND oprname IN ('<->', '<=>', '<#>') ORDER BY oprname;

-- An operator of the same name that is not the extension's stops the update,
-- as it would stop CREATE EXTENSION; it is not adopted.  Run at the top level:
-- caught inside a PL/pgSQL exception block, the failed update leaves this
-- session's segments taking the extension for one still being modified, and
-- the DROP below would fail on them until the session ends.
DROP EXTENSION lance_fdw;
CREATE EXTENSION lance_fdw VERSION '0.1';
CREATE FUNCTION public.not_lance_l2(real[], real[]) RETURNS double precision
  LANGUAGE sql IMMUTABLE AS 'SELECT 0::double precision';
CREATE OPERATOR public.<-> (LEFTARG = real[], RIGHTARG = real[], FUNCTION = public.not_lance_l2);
ALTER EXTENSION lance_fdw UPDATE;
SELECT extversion FROM pg_extension WHERE extname = 'lance_fdw';
DROP OPERATOR public.<->(real[], real[]);
DROP FUNCTION public.not_lance_l2(real[], real[]);

-- Back to what install left: 0.2, freshly created.
DROP EXTENSION lance_fdw;
CREATE EXTENSION lance_fdw;
SELECT extversion FROM pg_extension WHERE extname = 'lance_fdw';
SELECT object AS only_in_fresh FROM fresh_02 EXCEPT SELECT lance_feature.members();
DROP FUNCTION lance_feature.members();
