# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.
#
# test/stability/leak_loop.remote.sh - the container half; see leak_loop.sh.
#
# Streamed in behind remote_common.sh, with ROUNDS, SAMPLE_EVERY,
# MAX_FD_GROWTH, MAX_RSS_GROWTH_MB, CHUNK_DEADLINE, SKIP_S3, DB and KEEP_DB set
# by the prelude.  Nothing here reads stdin: stdin is this script.

DID_SETUP=no
FAILURES=0
GP_SESSION_ID=
KINDS=4
if [ "$SKIP_S3" = yes ]; then
	KINDS=3
fi

teardown() {
	psql_run "$DB" <<SQL || true
DROP SERVER IF EXISTS lance_stability_files CASCADE;
DROP SERVER IF EXISTS lance_stability_nopath CASCADE;
DROP SERVER IF EXISTS lance_stability_badcreds CASCADE;
DROP SCHEMA IF EXISTS lance_feature CASCADE;
SQL
	if [ "$CREATED_DB" = yes ] && [ "$KEEP_DB" != yes ]; then
		drop_db "$DB" || true
	fi
}

cleanup() {
	local rc=$?
	trap - EXIT
	session_abort || true
	[ -z "${SESS_DIR:-}" ] || rm -rf "$SESS_DIR"
	if [ "$DID_SETUP" = yes ]; then
		say "cleaning up"
		teardown
	fi
	exit "$rc"
}
trap cleanup EXIT

setup() {
	[ -d "$FIXTURE_DIR" ] ||
		die "no fixture directory $FIXTURE_DIR in the container; test/run/run.sh puts one there"
	for name in types_b frag_3 vectors_idx; do
		[ -d "$FIXTURE_DIR/$name.lance" ] ||
			die "$FIXTURE_DIR/$name.lance is missing; run test/run/run.sh to sync the fixtures"
	done

	ensure_db "$DB"
	DID_SETUP=yes

	# 0.1 gained the vector operators without a new version, so a database
	# that installed the extension before them still has it without them, and
	# CREATE EXTENSION IF NOT EXISTS below would not add them.  Dropping the
	# extension here would take whatever else depends on it in a database this
	# script may not own, so say so instead.
	STALE=$(psql_val "$DB" <<'SQL'
SELECT count(*) FROM pg_extension e
 WHERE e.extname = 'lance_fdw'
   AND NOT EXISTS (SELECT 1 FROM pg_depend d
                    WHERE d.refobjid = e.oid AND d.deptype = 'e'
                      AND d.classid = 'pg_operator'::regclass);
SQL
	)
	[ "$STALE" = 0 ] ||
		die "lance_fdw in database $DB predates the vector operators; run DROP EXTENSION lance_fdw CASCADE there, or pass --db with a new database"

	psql_run "$DB" <<SQL
DROP SERVER IF EXISTS lance_stability_files CASCADE;
DROP SERVER IF EXISTS lance_stability_nopath CASCADE;
DROP SERVER IF EXISTS lance_stability_badcreds CASCADE;
DROP SCHEMA IF EXISTS lance_feature CASCADE;
CREATE SCHEMA lance_feature;
CREATE EXTENSION IF NOT EXISTS lance_fdw;

CREATE SERVER lance_stability_files FOREIGN DATA WRAPPER lance_fdw
  OPTIONS (base_uri '$FIXTURE_DIR');
CREATE SERVER lance_stability_nopath FOREIGN DATA WRAPPER lance_fdw
  OPTIONS (base_uri 'file:///lance_fdw_no_such_directory');

-- A dataset that is there, read into a column the wrapper refuses: uint64 is
-- B-tier, so this one fails on the segments, after the coordinator has opened
-- the dataset and listed its fragments.
CREATE FOREIGN TABLE lance_feature.leak_btier (id integer, c_uint64 bigint)
  SERVER lance_stability_files OPTIONS (uri 'types_b.lance');
-- A uri that is not there: fails on the coordinator, before any segment is
-- involved.
CREATE FOREIGN TABLE lance_feature.leak_badpath (id integer, v text)
  SERVER lance_stability_nopath OPTIONS (uri 'nope.lance');
-- And one that has to work, at the end, in the same session.
CREATE FOREIGN TABLE lance_feature.leak_good (id integer, v text, n bigint)
  SERVER lance_stability_files OPTIONS (uri 'frag_3.lance');
-- Vector Top-K (AC20).  Under 'coordinator' the nearest-neighbour search runs
-- in this very backend - the one being sampled - so the scanner, the statistics
-- callback and the converters of a search are all inside the measurement; on
-- the default 'all segments' they would run on a QE nobody samples.  This one
-- succeeds every round; the next one fails every round, at the open.
CREATE FOREIGN TABLE lance_feature.leak_topk (id integer, cat integer, emb real[])
  SERVER lance_stability_files OPTIONS (uri 'vectors_idx.lance', mpp_execute 'coordinator');
CREATE FOREIGN TABLE lance_feature.leak_topk_bad (id integer, cat integer, emb real[])
  SERVER lance_stability_nopath OPTIONS (uri 'nope.lance');
SQL

	if [ "$SKIP_S3" != yes ]; then
		psql_run "$DB" <<SQL
CREATE SERVER lance_stability_badcreds FOREIGN DATA WRAPPER lance_fdw
  OPTIONS (base_uri 's3://$S3_BUCKET/fixtures',
           aws_endpoint '$S3_ENDPOINT',
           aws_region '$S3_REGION',
           allow_http 'true');
CREATE USER MAPPING FOR CURRENT_USER SERVER lance_stability_badcreds
  OPTIONS (aws_access_key_id 'lance-stability-not-a-key',
           aws_secret_access_key 'lance-stability-not-a-secret');
CREATE FOREIGN TABLE lance_feature.leak_badcreds (id integer, v text, n bigint)
  SERVER lance_stability_badcreds OPTIONS (uri 'frag_3.lance');
SQL
	fi
}

# The QE processes of this session carry con<sess_id> in their process title.
# Counting them is an observation, not an assertion: an error tears the gang
# down and the next statement builds a new one, so the number moves around by
# design.  A number that climbed with the round count would still be worth
# seeing.
qe_count() {
	if [ -z "$GP_SESSION_ID" ]; then
		echo 0
		return 0
	fi
	ps -u gpadmin -o args= | grep -cE "con$GP_SESSION_ID"'(\b|$)' || true
}

sample() {
	local label=$1 fd rss threads qe
	[ -r "/proc/$SESS_PID/status" ] ||
		die "backend $SESS_PID is gone: the session did not survive the loop"
	fd=$(ls -1 "/proc/$SESS_PID/fd" 2>/dev/null | wc -l)
	rss=$(awk '/^VmRSS:/ { print $2 }' "/proc/$SESS_PID/status")
	threads=$(ls -1 "/proc/$SESS_PID/task" | wc -l)
	qe=$(qe_count)
	printf '%s %s %s %s %s\n' "$label" "$fd" "$rss" "$threads" "$qe" >>"$SESS_DIR/samples"
	printf '  %-9s fd %4s   VmRSS %9s kB   threads %3s   QE processes %3s\n' \
		"$label" "$fd" "$rss" "$threads" "$qe"
}

# One round: every statement in it but the vector search has to fail.
send_round() {
	session_send "SELECT id FROM lance_feature.leak_topk WHERE cat = 2 ORDER BY emb <-> '{1,2,3,4,5,6,7,8}' LIMIT 5;"
	session_send "SELECT id FROM lance_feature.leak_topk_bad ORDER BY emb <-> '{1,2,3,4,5,6,7,8}' LIMIT 5;"
	session_send 'SELECT * FROM lance_feature.leak_badpath;'
	if [ "$SKIP_S3" != yes ]; then
		session_send 'SELECT * FROM lance_feature.leak_badcreds;'
	fi
	session_send 'SELECT id, c_uint64 FROM lance_feature.leak_btier;'
}

# ---------------------------------------------------------------------------

CORES_BEFORE=$(core_list)
if ! STATE=$(cluster_state); then
	die "the cluster is not healthy before the loop even starts: $STATE"
fi
say "before: $STATE"

setup
session_open "$DB"
: >"$SESS_DIR/samples"
GP_SESSION_ID=$(session_value "SELECT coalesce(current_setting('gp_session_id', true), '')" 30 || true)

# The search in every round has to be a search, not the plain scan it falls
# back to, or the loop would not be measuring the search at all.
if ! PLAN=$(session_value "EXPLAIN SELECT id FROM lance_feature.leak_topk WHERE cat = 2 ORDER BY emb <-> '{1,2,3,4,5,6,7,8}' LIMIT 5" 60) ||
	! printf '%s\n' "$PLAN" | grep -q 'Lance Vector Search: emb <->'; then
	die "the vector search of the loop is not pushed down: $PLAN"
fi

# The baseline is taken after one round, not before it: the first failure is
# what loads lance-c into this backend and starts its threads, and that cost is
# not a leak.  Everything after it should be flat.
say "one round first, so that the baseline is taken with lance-c already loaded"
send_round
session_mark "$CHUNK_DEADLINE" || die "the warm-up round did not come back within ${CHUNK_DEADLINE}s"
sample baseline

say "$ROUNDS rounds of $KINDS failing statements and one vector search, sampling every $SAMPLE_EVERY"
round=0
while [ "$round" -lt "$ROUNDS" ]; do
	round=$(( round + 1 ))
	send_round
	if [ $(( round % SAMPLE_EVERY )) -eq 0 ] || [ "$round" -eq "$ROUNDS" ]; then
		session_mark "$CHUNK_DEADLINE" ||
			die "round $round did not come back within ${CHUNK_DEADLINE}s"
		sample "$round"
	fi
done

# Every statement in every round must have failed.  If the count is short,
# something succeeded that was meant to fail and the loop proved nothing.
ERRORS=$(session_errors)
EXPECTED=$(( (ROUNDS + 1) * KINDS ))
if [ "$ERRORS" != "$EXPECTED" ]; then
	say "expected $EXPECTED errors from $(( ROUNDS + 1 )) rounds of $KINDS, saw $ERRORS"
	FAILURES=$(( FAILURES + 1 ))
else
	say "all $ERRORS statements failed, as they were meant to; the first round read:"
	# head closes the pipe on grep long before it is done, which is not a
	# failure of this script.
	grep 'ERROR:' "$SESS_DIR/err" | head -"$KINDS" | sed 's/^/    /' || true
fi

# AC7's other clause: the session that took all that still works.
if GOOD=$(session_value 'SELECT count(*) FROM lance_feature.leak_good' 60); then
	say "the same session then read frag_3.lance: $GOOD rows"
	if ! [ "$GOOD" -gt 0 ] 2>/dev/null; then
		say "that scan should have returned rows"
		FAILURES=$(( FAILURES + 1 ))
	fi
else
	say "the session did not answer a working query after the loop"
	FAILURES=$(( FAILURES + 1 ))
fi

session_close

read -r _ FD_FIRST RSS_FIRST _ _ <<<"$(head -1 "$SESS_DIR/samples")"
read -r _ FD_LAST RSS_LAST _ _ <<<"$(tail -1 "$SESS_DIR/samples")"

FD_GROWTH=$(( FD_LAST - FD_FIRST ))
RSS_GROWTH_KB=$(( RSS_LAST - RSS_FIRST ))
say "file descriptors $FD_FIRST -> $FD_LAST (${FD_GROWTH}), allowed +$MAX_FD_GROWTH"
say "VmRSS $RSS_FIRST kB -> $RSS_LAST kB (${RSS_GROWTH_KB} kB), allowed +$(( MAX_RSS_GROWTH_MB * 1024 )) kB"

if [ "$FD_GROWTH" -gt "$MAX_FD_GROWTH" ]; then
	say "the backend gained $FD_GROWTH file descriptors over $ROUNDS rounds"
	FAILURES=$(( FAILURES + 1 ))
fi
if [ "$RSS_GROWTH_KB" -ge $(( MAX_RSS_GROWTH_MB * 1024 )) ]; then
	say "the backend gained $RSS_GROWTH_KB kB of resident memory over $ROUNDS rounds"
	FAILURES=$(( FAILURES + 1 ))
fi

CORES_AFTER=$(core_list)
NEW_CORES=$(comm -13 <(printf '%s\n' "$CORES_BEFORE") <(printf '%s\n' "$CORES_AFTER") || true)
if [ -n "$NEW_CORES" ]; then
	say "new core files:"
	printf '%s\n' "$NEW_CORES"
	FAILURES=$(( FAILURES + 1 ))
fi

if STATE=$(cluster_state); then
	say "after: $STATE"
else
	say "the cluster is not healthy after the loop: $STATE"
	FAILURES=$(( FAILURES + 1 ))
fi

if [ "$FAILURES" != 0 ]; then
	say "FAIL ($FAILURES problems)"
	exit 1
fi
say "PASS"
