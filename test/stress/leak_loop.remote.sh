# test/stress/leak_loop.remote.sh - the container half; see leak_loop.sh.
#
# Streamed in behind remote_common.sh, with ROUNDS, SAMPLE_EVERY,
# MAX_FD_GROWTH, MAX_RSS_GROWTH_MB, CHUNK_DEADLINE, SKIP_S3, DB and KEEP_DB set
# by the prelude.  Nothing here reads stdin: stdin is this script.

DID_SETUP=no
FAILURES=0
GP_SESSION_ID=
KINDS=3
if [ "$SKIP_S3" = yes ]; then
	KINDS=2
fi

teardown() {
	psql_run "$DB" <<SQL || true
DROP SERVER IF EXISTS lance_stress_files CASCADE;
DROP SERVER IF EXISTS lance_stress_nopath CASCADE;
DROP SERVER IF EXISTS lance_stress_badcreds CASCADE;
DROP SCHEMA IF EXISTS lance_regress CASCADE;
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
		die "no fixture directory $FIXTURE_DIR in the container; test/gate/gate.sh puts one there"
	for name in types_b frag_3; do
		[ -d "$FIXTURE_DIR/$name.lance" ] ||
			die "$FIXTURE_DIR/$name.lance is missing; run test/gate/gate.sh to sync the fixtures"
	done

	ensure_db "$DB"
	DID_SETUP=yes

	psql_run "$DB" <<SQL
DROP SERVER IF EXISTS lance_stress_files CASCADE;
DROP SERVER IF EXISTS lance_stress_nopath CASCADE;
DROP SERVER IF EXISTS lance_stress_badcreds CASCADE;
DROP SCHEMA IF EXISTS lance_regress CASCADE;
CREATE SCHEMA lance_regress;
CREATE EXTENSION IF NOT EXISTS lance_fdw;

CREATE SERVER lance_stress_files FOREIGN DATA WRAPPER lance_fdw
  OPTIONS (base_uri '$FIXTURE_DIR');
CREATE SERVER lance_stress_nopath FOREIGN DATA WRAPPER lance_fdw
  OPTIONS (base_uri 'file:///lance_fdw_no_such_directory');

-- A dataset that is there, read into a column the wrapper refuses: uint64 is
-- B-tier, so this one fails on the segments, after the coordinator has opened
-- the dataset and listed its fragments.
CREATE FOREIGN TABLE lance_regress.leak_btier (id integer, c_uint64 bigint)
  SERVER lance_stress_files OPTIONS (uri 'types_b.lance');
-- A uri that is not there: fails on the coordinator, before any segment is
-- involved.
CREATE FOREIGN TABLE lance_regress.leak_badpath (id integer, v text)
  SERVER lance_stress_nopath OPTIONS (uri 'nope.lance');
-- And one that has to work, at the end, in the same session.
CREATE FOREIGN TABLE lance_regress.leak_good (id integer, v text, n bigint)
  SERVER lance_stress_files OPTIONS (uri 'frag_3.lance');
SQL

	if [ "$SKIP_S3" != yes ]; then
		psql_run "$DB" <<SQL
CREATE SERVER lance_stress_badcreds FOREIGN DATA WRAPPER lance_fdw
  OPTIONS (base_uri 's3://$S3_BUCKET/fixtures',
           aws_endpoint '$S3_ENDPOINT',
           aws_region '$S3_REGION',
           allow_http 'true');
CREATE USER MAPPING FOR CURRENT_USER SERVER lance_stress_badcreds
  OPTIONS (aws_access_key_id 'lance-stress-not-a-key',
           aws_secret_access_key 'lance-stress-not-a-secret');
CREATE FOREIGN TABLE lance_regress.leak_badcreds (id integer, v text, n bigint)
  SERVER lance_stress_badcreds OPTIONS (uri 'frag_3.lance');
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
	fd=$(ls -1 "/proc/$SESS_PID/fd" 2>/dev/null | wc -l)
	rss=$(awk '/^VmRSS:/ { print $2 }' "/proc/$SESS_PID/status")
	threads=$(ls -1 "/proc/$SESS_PID/task" | wc -l)
	qe=$(qe_count)
	printf '%s %s %s %s %s\n' "$label" "$fd" "$rss" "$threads" "$qe" >>"$SESS_DIR/samples"
	printf '  %-9s fd %4s   VmRSS %9s kB   threads %3s   QE processes %3s\n' \
		"$label" "$fd" "$rss" "$threads" "$qe"
}

# One round: every statement in it has to fail.
send_round() {
	session_send 'SELECT * FROM lance_regress.leak_badpath;'
	if [ "$SKIP_S3" != yes ]; then
		session_send 'SELECT * FROM lance_regress.leak_badcreds;'
	fi
	session_send 'SELECT id, c_uint64 FROM lance_regress.leak_btier;'
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

# The baseline is taken after one round, not before it: the first failure is
# what loads lance-c into this backend and starts its threads, and that cost is
# not a leak.  Everything after it should be flat.
say "one round first, so that the baseline is taken with lance-c already loaded"
send_round
session_mark "$CHUNK_DEADLINE" || die "the warm-up round did not come back within ${CHUNK_DEADLINE}s"
sample baseline

say "$ROUNDS rounds of $KINDS failing statements, sampling every $SAMPLE_EVERY"
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
	say "all $ERRORS statements failed, as they were meant to; the three kinds read:"
	grep 'ERROR:' "$SESS_DIR/err" | head -"$KINDS" | sed 's/^/    /'
fi

# AC7's other clause: the session that took all that still works.
if GOOD=$(session_value 'SELECT count(*) FROM lance_regress.leak_good' 60); then
	say "the same session then read frag_3.lance: $GOOD rows"
	if [ "$GOOD" -le 0 ]; then
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
