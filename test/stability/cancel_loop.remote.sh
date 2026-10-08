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
# test/stability/cancel_loop.remote.sh - the container half; see cancel_loop.sh.
#
# Streamed in behind remote_common.sh, with ROUNDS, DATASET, SCAN,
# MAX_MEDIAN_PCT, MODE, DELAY_SPEC, DEADLINE, CAL_DEADLINE, MIN_PCT,
# MIN_THREADS, DB and KEEP_DB set by the prelude.  Nothing here reads stdin:
# stdin is this script.

TABLE="$DATASET.lance"
if [ "$SCAN" = topk ]; then
	# SCAN_SQL is written by setup(), once it knows how wide the vectors are.
	# The table's mpp_execute while the rounds run, and the other one that
	# the count after the loop is compared against.
	LOOP_EXEC=coordinator
	OTHER_EXEC="all segments"
else
	# A whole-row reference is what makes the wrapper read every column (D6),
	# so this is a scan of the whole dataset whatever its schema turns out to
	# be.
	SCAN_SQL="SELECT sum(pg_column_size(t)) FROM lance_feature.stability_scan t;"
	LOOP_EXEC="all segments"
	OTHER_EXEC=coordinator
fi

MIN_DELAY_MS=50
CAL_SAMPLES=3
LONG_DELAY_MS=2000

DELAY_MS=0
DID_SETUP=no
FAILURES=0
INTERRUPTED=0
COMPLETED=0
ROUNDS_RUN=0
CAL_NOTE=
FASTEST=

teardown() {
	psql_run "$DB" <<SQL || true
DROP SERVER IF EXISTS lance_stability_s3 CASCADE;
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

missing_dataset() {
	say "could not open s3://$S3_BUCKET/fixtures/$TABLE - the error above says why"
	say "if it was never uploaded, generate it and upload it on the host:"
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
DROP SERVER IF EXISTS lance_stability_s3 CASCADE;
DROP SCHEMA IF EXISTS lance_feature CASCADE;
CREATE SCHEMA lance_feature;
CREATE EXTENSION IF NOT EXISTS lance_fdw;
CREATE SERVER lance_stability_s3 FOREIGN DATA WRAPPER lance_fdw
  OPTIONS (base_uri 's3://$S3_BUCKET/fixtures',
           aws_endpoint '$S3_ENDPOINT',
           aws_region '$S3_REGION',
           allow_http 'true');
CREATE USER MAPPING FOR CURRENT_USER SERVER lance_stability_s3
  OPTIONS (aws_access_key_id '$S3_KEY', aws_secret_access_key '$S3_SECRET');
SQL

	# IMPORT reads the dataset's schema, so it is also the check that the
	# fixture is in the bucket at all - and the only place where a missing one
	# can still be explained.
	if ! psql_run "$DB" <<SQL
IMPORT FOREIGN SCHEMA fixtures LIMIT TO ("$TABLE")
  FROM SERVER lance_stability_s3 INTO lance_feature;
SQL
	then
		missing_dataset
	fi

	psql_run "$DB" <<SQL
ALTER FOREIGN TABLE lance_feature."$TABLE" RENAME TO stability_scan;
SQL

	[ "$SCAN" = topk ] || return 0

	local dim plan
	psql_run "$DB" <<SQL
ALTER FOREIGN TABLE lance_feature.stability_scan OPTIONS (ADD mpp_execute '$LOOP_EXEC');
SQL
	dim=$(psql_val "$DB" <<SQL
SELECT array_length(emb, 1) FROM lance_feature.stability_scan WHERE emb IS NOT NULL LIMIT 1;
SQL
	)
	case "$dim" in
		''|*[!0-9]*) die "could not read the width of $TABLE's emb column (got '$dim')" ;;
	esac

	# array_fill() is immutable, so the planner folds it into the constant a
	# search needs.  A rounds-long loop of plain scans would pass every check
	# below, so the plan is checked before the first round.
	SCAN_SQL="SELECT id FROM lance_feature.stability_scan ORDER BY emb <-> array_fill(0.5::real, ARRAY[$dim]) LIMIT 10;"
	plan=$(psql_val "$DB" <<<"EXPLAIN $SCAN_SQL")
	if ! grep -q 'Lance Vector Search: emb' <<<"$plan"; then
		printf '%s\n' "$plan"
		die "the statement is not a vector search, so there is nothing to test"
	fi
	say "a ${dim}-d vector search, run on the coordinator: $SCAN_SQL"
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

# The calibration scan is still running when its deadline passes: cancel it to
# get the session back - which is itself one cancellation of a scan in flight -
# and interrupt well inside a scan that long.
calibration_too_slow() {
	say "still running after ${CAL_DEADLINE}s; cancelling to get the session back"
	backend_signal "$SESS_PID" cancel >/dev/null
	session_mark "$DEADLINE" ||
		die "the session did not come back within ${DEADLINE}s after the calibration cancel"
	DELAY_MS=$LONG_DELAY_MS
	CAL_NOTE="an uninterrupted scan takes longer than ${CAL_DEADLINE}s"
	say "$CAL_NOTE; interrupting ${DELAY_MS} ms into each round"
}

calibrate() {
	local t0 elapsed fastest="" i

	if [ "$DELAY_SPEC" != auto ]; then
		DELAY_MS=$DELAY_SPEC
		say "interrupting ${DELAY_MS} ms into each scan (--delay-ms)"
		return 0
	fi

	# One scan to warm up, then $CAL_SAMPLES timed, and it is the fastest of
	# those that is halved.  Every round below runs warm - lance's metadata
	# cache filled, the object store's caches hot - so the figure has to be a
	# warm one, and warming takes more than one scan: against MinIO on a
	# docker network the big fixture read in 719 ms, then 514, then settled
	# at 412-463 ms for the next eighteen.  Timing only the second scan
	# landed on that tail once at 774 ms; half of it, 387 ms, is about what a
	# settled scan takes in full, and once the interrupt's own latency was
	# added (up to 164 ms measured) 36 of 50 rounds finished first.  The
	# fastest sample is the one that bounds how early a round can end, and
	# halving it leaves room for the interrupt to land.
	say "warming up with one scan of $DATASET (up to ${CAL_DEADLINE}s)"
	session_send "$SCAN_SQL"
	if ! session_mark "$CAL_DEADLINE"; then
		calibration_too_slow
		return 0
	fi

	say "timing $CAL_SAMPLES uninterrupted scans of $DATASET (up to ${CAL_DEADLINE}s each)"
	for (( i = 1; i <= CAL_SAMPLES; i++ )); do
		t0=$(now_ms)
		session_send "$SCAN_SQL"
		if ! session_mark "$CAL_DEADLINE"; then
			calibration_too_slow
			return 0
		fi
		elapsed=$(( $(now_ms) - t0 ))
		say "  sample $i: ${elapsed} ms"
		if [ -z "$fastest" ] || [ "$elapsed" -lt "$fastest" ]; then
			fastest=$elapsed
		fi
	done

	FASTEST=$fastest
	DELAY_MS=$(( fastest / 2 ))
	if [ "$DELAY_MS" -lt "$MIN_DELAY_MS" ]; then
		DELAY_MS=$MIN_DELAY_MS
	fi
	CAL_NOTE="the fastest of $CAL_SAMPLES warm uninterrupted scans took ${fastest} ms"
	say "$CAL_NOTE; interrupting ${DELAY_MS} ms into each round"
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
if ROWS=$(session_value 'SELECT count(*) FROM lance_feature.stability_scan' "$CAL_DEADLINE"); then
	say "after the loop, the same session counted $ROWS rows with mpp_execute '$LOOP_EXEC'"
else
	say "the session did not answer a plain count(*) after the loop"
	FAILURES=$(( FAILURES + 1 ))
fi

if [ "$SCAN" = topk ]; then
	EXEC_OPT="SET mpp_execute '$OTHER_EXEC'"
else
	EXEC_OPT="ADD mpp_execute '$OTHER_EXEC'"
fi
psql_run "$DB" <<SQL
ALTER FOREIGN TABLE lance_feature.stability_scan OPTIONS ($EXEC_OPT);
SQL
if ROWS_QD=$(session_value 'SELECT count(*) FROM lance_feature.stability_scan' "$CAL_DEADLINE"); then
	say "the same session read it with mpp_execute '$OTHER_EXEC': $ROWS_QD rows"
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

# An interrupt that only lands when the work is done would still pass every
# check above, as long as the delay leaves the round unfinished; this is the
# check that it lands sooner.  Waiting the work out puts the median near half
# the fastest scan, which is where the rounds are interrupted.
if [ "$MAX_MEDIAN_PCT" -gt 0 ]; then
	MEDIAN=$(sort -n "$SESS_DIR/lat" | awk '{ a[NR] = $1 } END { if (NR) print a[int((NR + 1) / 2)] }')
	if [ -z "$FASTEST" ]; then
		say "no calibration to compare the latency against: $CAL_NOTE"
		FAILURES=$(( FAILURES + 1 ))
	elif [ -z "$MEDIAN" ]; then
		say "no round was interrupted, so there is no latency to check"
		FAILURES=$(( FAILURES + 1 ))
	else
		LIMIT_MS=$(( FASTEST * MAX_MEDIAN_PCT / 100 ))
		if [ "$MEDIAN" -gt "$LIMIT_MS" ]; then
			say "median interrupt latency ${MEDIAN} ms is over ${MAX_MEDIAN_PCT}% of the fastest uninterrupted scan (${FASTEST} ms): ${LIMIT_MS} ms"
			FAILURES=$(( FAILURES + 1 ))
		else
			say "median interrupt latency ${MEDIAN} ms, within ${MAX_MEDIAN_PCT}% of the fastest uninterrupted scan (${FASTEST} ms): ${LIMIT_MS} ms"
		fi
	fi
fi

if [ "$FAILURES" != 0 ]; then
	say "FAIL ($FAILURES problems)"
	exit 1
fi
say "PASS"
