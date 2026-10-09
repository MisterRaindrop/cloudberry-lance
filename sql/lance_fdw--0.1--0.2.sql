/*
 * Licensed to the Apache Software Foundation (ASF) under one
 * or more contributor license agreements.  See the NOTICE file
 * distributed with this work for additional information
 * regarding copyright ownership.  The ASF licenses this file
 * to you under the Apache License, Version 2.0 (the
 * "License"); you may not use this file except in compliance
 * with the License.  You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an
 * "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 * KIND, either express or implied.  See the License for the
 * specific language governing permissions and limitations
 * under the License.
 *
 * sql/lance_fdw--0.1--0.2.sql
 *
 * 0.2 adds the vector distance operators.  Builds of 0.1 taken from the main
 * branch between the vector Top-K commit and this one already shipped them
 * under the version 0.1, so a database may report 0.1 and have them: each one
 * is created here only if the extension does not have it yet.
 */

-- complain if the script is sourced by psql instead of CREATE EXTENSION
\echo Use "ALTER EXTENSION lance_fdw UPDATE TO '0.2'" to load this file. \quit

/* See lance_fdw--0.2.sql for what these are. */
CREATE OR REPLACE FUNCTION lance_l2_distance(real[], real[])
RETURNS double precision
AS 'MODULE_PATHNAME', 'lance_vector_l2_distance'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE OR REPLACE FUNCTION lance_cosine_distance(real[], real[])
RETURNS double precision
AS 'MODULE_PATHNAME', 'lance_vector_cosine_distance'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE OR REPLACE FUNCTION lance_negative_inner_product(real[], real[])
RETURNS double precision
AS 'MODULE_PATHNAME', 'lance_vector_negative_inner_product'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

/*
 * CREATE OPERATOR has no IF NOT EXISTS.  The test is for a member of this
 * extension, not for any operator of that name: an operator <-> on real[] from
 * somewhere else in the schema has to stop the update, as CREATE EXTENSION
 * would stop on it, rather than be adopted.
 */
DO $$
DECLARE
  ext oid := (SELECT oid FROM pg_extension WHERE extname = 'lance_fdw');
  op record;
BEGIN
  FOR op IN SELECT * FROM (VALUES
      ('<->', 'lance_l2_distance'),
      ('<=>', 'lance_cosine_distance'),
      ('<#>', 'lance_negative_inner_product')) AS v(name, func)
  LOOP
    IF NOT EXISTS (
        SELECT 1 FROM pg_operator o
          JOIN pg_depend d ON d.classid = 'pg_operator'::regclass
                          AND d.objid = o.oid
                          AND d.refclassid = 'pg_extension'::regclass
                          AND d.refobjid = ext
                          AND d.deptype = 'e'
         WHERE o.oprname = op.name
           AND o.oprleft = 'real[]'::regtype
           AND o.oprright = 'real[]'::regtype) THEN
      EXECUTE format(
        'CREATE OPERATOR %s (LEFTARG = real[], RIGHTARG = real[], FUNCTION = %I, COMMUTATOR = %L)',
        op.name, op.func, op.name);
    END IF;
  END LOOP;
END
$$;

COMMENT ON OPERATOR <->(real[], real[]) IS 'Euclidean distance';
COMMENT ON OPERATOR <=>(real[], real[]) IS 'cosine distance, 1 - cos';
COMMENT ON OPERATOR <#>(real[], real[]) IS 'negative inner product';
