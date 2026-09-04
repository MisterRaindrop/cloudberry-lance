# test/stress/cancel_loop.remote.sh - the container half; see cancel_loop.sh.
#
# Streamed in behind remote_common.sh, with ROUNDS, DATASET, MODE, DELAY_SPEC,
# DEADLINE, CAL_DEADLINE, MIN_PCT, MIN_THREADS, DB and KEEP_DB set by the
# prelude.  Nothing here reads stdin: stdin is this script.

TABLE="$DATASET.lance"
# A whole-row reference is what makes the wrapper read every column (D6), so
# this is a scan of the whole dataset whatever its schema turns out to be.
SCAN_SQL="SELECT sum(pg_column_size(t)) FROM lance_regress.stress_scan t;"

MIN_DELAY_MS=50
LONG_DELAY_MS=2000

DELAY_MS=0
DID_SETUP=no
FAILURES=0
INTERRUPTED=0
COMPLETED=0
ROUNDS_RUN=0
CAL_NOTE=

teardown() {
	psql_run "$DB" <<SQL || true
DROP SERVER IF EXISTS lance_stress_s3 CASCADE;
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

missing_dataset() {
	say "could not open s3://$S3_BUCKET/fixtures/$TABLE"
	say "generate the fixture and upload it, on the host:"
	if [ "$DATASET" = big ]; then
		say "    make -C test/fixtures gen GEN_FLAGS=--with-big"
	else
		say "    make -C test/fixtures gen"
	fi
	say "    make -C test/fixtures upload UPLOAD_FLAGS=\"--datasets $DATASET\""
	say "or run a smaller dry run with --dataset large_text"
	exit 2
}

setup() {
	ensure_db "$DB"
	DID_SETUP=yes

	psql_run "$DB" <<SQL
DROP SERVER IF EXISTS lance_stress_s3 CASCADE;
DROP SCHEMA IF EXISTS lance_regress CASCADE;
CREATE SCHEMA lance_regress;
CREATE EXTENSION IF NOT EXISTS lance_fdw;
CREATE SERVER lance_stress_s3 FOREIGN DATA WRAPPER lance_fdw
  OPTIONS (base_uri 's3://$S3_BUCKET/fixtures',
           aws_endpoint '$S3_ENDPOINT',
           aws_region '$S3_REGION',
           allow_http 'true');
CREATE USER MAPPING FOR CURRENT_USER SERVER lance_stress_s3
  OPTIONS (aws_access_key_id '$S3_KEY', aws_secret_access_key '$S3_SECRET');
SQL

	# IMPORT reads the dataset's schema, so it is also the check that the
	# fixture is in the bucket at all - and the only place where a missing one
	# can still be explained.
	if ! psql_run "$DB" <<SQL
IMPORT FOREIGN SCHEMA fixtures LIMIT TO ("$TABLE")
  FROM SERVER lance_stress_s3 INTO lance_regress;
SQL
	then
		missing_dataset
	fi

	psql_run "$DB" <<SQL
ALTER FOREIGN TABLE lance_regress."$TABLE" RENAME TO stress_scan;
SQL
}

# Which of the two interrupts a message is about, or none if the statement got
# through.  Anything else is a failure and the text goes into the report.
#
# The text arrives as a here-string rather than through a pipe on purpose: with
# pipefail, a `printf | grep -q` whose grep stops reading early can report the
# printf's broken pipe as the pipeline's status and turn a match into a miss.
classify() {
	if grep -qi 'statement timeout' <<<"$1"; then
		echo timeout
	elif grep -qiE 'canceling (statement|mpp operation|query)|due to user request|cancell?ed on user|query was cancel' <<<"$1"; then
		echo cancel
	elif grep -q 'ERROR:' <<<"$1"; then
		echo other
	else
		echo none
	fi
}

calibrate() {
	local t0 elapsed

	if [ "$DELAY_SPEC" != auto ]; then
		DELAY_MS=$DELAY_SPEC
		say "interrupting ${DELAY_MS} ms into each scan (--delay-ms)"
		return 0
	fi

	say "timing one uninterrupted scan of $DATASET (up to ${CAL_DEADLINE}s)"
	t0=$(now_ms)
	session_send "$SCAN_SQL"
	if session_mark "$CAL_DEADLINE"; then
		elapsed=$(( $(now_ms) - t0 ))
		DELAY_MS=$(( elapsed / 2 ))
		if [ "$DELAY_MS" -lt "$MIN_DELAY_MS" ]; then
			DELAY_MS=$MIN_DELAY_MS
		fi
		CAL_NOTE="an uninterrupted scan took ${elapsed} ms"
		say "$CAL_NOTE; interrupting ${DELAY_MS} ms into each round"
	else
		# Still running: cancel it to get the session back - which is already
		# one cancellation of a scan in flight - and stay well inside it.
		say "still running after ${CAL_DEADLINE}s; cancelling to get the session back"
		backend_signal "$SESS_PID" cancel >/dev/null
		session_mark "$DEADLINE" ||
			die "the session did not come back within ${DEADLINE}s after the calibration cancel"
		DELAY_MS=$LONG_DELAY_MS
		CAL_NOTE="an uninterrupted scan takes longer than ${CAL_DEADLINE}s"
		say "$CAL_NOTE; interrupting ${DELAY_MS} ms into each round"
	fi
}

# One round.  Returns non-zero only when the session did not come back, which
# is the one failure the loop cannot continue past.
round() {
	local n=$1 mode=$2 t0 t_int prev_lines latency new class

	prev_lines=$(session_err_lines)

	if [ "$mode" = timeout ]; then
		session_send "SET statement_timeout = $DELAY_MS;"
		t0=$(now_ms)
		session_send "$SCAN_SQL"
		session_send 'RESET statement_timeout;'
		# When the timeout is due, give or take the millisecond it takes psql
		# to get the SET across.
		t_int=$(( t0 + DELAY_MS ))
	else
		session_send "$SCAN_SQL"
		sleep_ms "$DELAY_MS"
		# The clock starts where pg_cancel_backend() returns, which is after
		# the signal went out; opening the connection it needs is not part of
		# how long the wrapper took to notice.
		if [ "$(backend_signal "$SESS_PID" cancel)" != t ]; then
			say "round $n: pg_cancel_backend($SESS_PID) did not return true"
			FAILURES=$(( FAILURES + 1 ))
		fi
		t_int=$(now_ms)
	fi

	if ! session_mark "$DEADLINE"; then
		say "round $n ($mode): nothing came back within ${DEADLINE}s"
		FAILURES=$(( FAILURES + 1 ))
		return 1
	fi
	ROUNDS_RUN=$(( ROUNDS_RUN + 1 ))

	latency=$(( $(now_ms) - t_int ))
	if [ "$latency" -lt 0 ]; then
		latency=0
	fi

	new=$(session_err_since "$prev_lines")
	class=$(classify "$new")
	case "$class" in
		timeout|cancel)
			INTERRUPTED=$(( INTERRUPTED + 1 ))
			echo "$latency" >>"$SESS_DIR/lat"
			echo "$latency" >>"$SESS_DIR/lat.$mode"
			printf '  round %3d %-7s interrupted (%s) after %6d ms\n' \
				"$n" "$mode" "$class" "$latency"
			;;
		none)
			COMPLETED=$(( COMPLETED + 1 ))
			printf '  round %3d %-7s finished before the interrupt reached it\n' "$n" "$mode"
			;;
		*)
			FAILURES=$(( FAILURES + 1 ))
			say "round $n ($mode): an error that is not a cancellation:"
			printf '%s\n' "$new" | head -5 || true
			;;
	esac
	return 0
}

# ---------------------------------------------------------------------------

CORES_BEFORE=$(core_list)
if ! STATE=$(cluster_state); then
	die "the cluster is not healthy before the loop even starts: $STATE"
fi
say "before: $STATE"

setup
session_open "$DB"
: >"$SESS_DIR/lat"
: >"$SESS_DIR/lat.timeout"
: >"$SESS_DIR/lat.cancel"

calibrate

for n in $(seq 1 "$ROUNDS"); do
	case "$MODE" in
		timeout|cancel) mode=$MODE ;;
		*) if [ $(( n % 2 )) -eq 1 ]; then mode=timeout; else mode=cancel; fi ;;
	esac
	round "$n" "$mode" || break
done

# AC7's last clause: the session that was interrupted $ROUNDS times answers.
# The two mpp_execute modes then have to agree on the count (I11), and the
# coordinator-side one is what puts lance-c's threads in *this* backend, which
# is what the signal masks are read from.
ROWS=
ROWS_QD=
if ROWS=$(session_value 'SELECT count(*) FROM lance_regress.stress_scan' "$CAL_DEADLINE"); then
	say "after the loop, the same session counted $ROWS rows across the segments"
else
	say "the session did not answer a plain count(*) after the loop"
	FAILURES=$(( FAILURES + 1 ))
fi

psql_run "$DB" <<SQL
ALTER FOREIGN TABLE lance_regress.stress_scan OPTIONS (ADD mpp_execute 'coordinator');
SQL
if ROWS_QD=$(session_value 'SELECT count(*) FROM lance_regress.stress_scan' "$CAL_DEADLINE"); then
	say "the same session read it on the coordinator alone: $ROWS_QD rows"
	if [ -n "$ROWS" ] && [ "$ROWS" != "$ROWS_QD" ]; then
		say "the two mpp_execute modes disagree: $ROWS vs $ROWS_QD (I11)"
		FAILURES=$(( FAILURES + 1 ))
	fi
else
	say "the coordinator-side scan did not come back"
	FAILURES=$(( FAILURES + 1 ))
fi

say "signal masks of the threads in backend $SESS_PID (I5):"
if ! sigblk_report "$SESS_PID" "$MIN_THREADS"; then
	FAILURES=$(( FAILURES + 1 ))
fi

# The session is done; close it before anything else looks at the cluster.
session_close

CORES_AFTER=$(core_list)
NEW_CORES=$(comm -13 <(printf '%s\n' "$CORES_BEFORE") <(printf '%s\n' "$CORES_AFTER") || true)
if [ -n "$NEW_CORES" ]; then
	say "new core files:"
	printf '%s\n' "$NEW_CORES"
	FAILURES=$(( FAILURES + 1 ))
else
	say "no core file appeared under: $CORE_DIRS"
fi

if STATE=$(cluster_state); then
	say "after: $STATE"
else
	say "the cluster is not healthy after the loop: $STATE"
	FAILURES=$(( FAILURES + 1 ))
fi

REQUIRED=$(( (ROUNDS * MIN_PCT + 99) / 100 ))
if [ "$INTERRUPTED" -lt "$REQUIRED" ]; then
	say "only $INTERRUPTED of $ROUNDS rounds were interrupted; --min-interrupted-pct $MIN_PCT wants $REQUIRED"
	FAILURES=$(( FAILURES + 1 ))
fi

say "rounds run $ROUNDS_RUN of $ROUNDS: interrupted $INTERRUPTED, finished first $COMPLETED"
[ -z "$CAL_NOTE" ] || say "calibration: $CAL_NOTE, interrupt after ${DELAY_MS} ms"
# Two different measurements, so also reported apart: for a timeout round the
# clock starts when the timeout was due, for a cancel round where
# pg_cancel_backend() returned.
say "interrupt to error, in ms: $(distribution <"$SESS_DIR/lat")"
say "  statement_timeout, overshoot: $(distribution <"$SESS_DIR/lat.timeout")"
say "  pg_cancel_backend, latency:   $(distribution <"$SESS_DIR/lat.cancel")"

if [ "$FAILURES" != 0 ]; then
	say "FAIL ($FAILURES problems)"
	exit 1
fi
say "PASS"
