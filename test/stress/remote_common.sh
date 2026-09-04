# test/stress/remote_common.sh - the container half of the stress scripts.
#
# This file is not executed on the host.  common.sh's stress_remote() streams a
# prelude (which sets TAG, PGPORT, FIXTURE_DIR, SEG_PORTS, CORE_DIRS and the S3
# settings), then this file, then the body of one stress script into
# `docker exec -i ... bash -l -s`.
#
# Two rules follow from that, and breaking either one breaks the script in a way
# that is hard to see:
#
#   * the whole thing is one script arriving on stdin, so anything that reads
#     stdin eats the rest of it.  Every psql below therefore takes its SQL from
#     a here-document or a file, and every background command gets </dev/null.
#   * SQL carrying credentials goes in on stdin as well, never in -c, so it
#     stays out of the container's process list.

say() { echo "$TAG: $*"; }
die() { echo "$TAG: $*" >&2; exit 1; }

now_ms() {
	local t
	t=$(date +%s%3N)
	case "$t" in
		''|*[!0-9]*) echo $(( $(date +%s) * 1000 )) ;;
		*) echo "$t" ;;
	esac
}

sleep_ms() {
	local ms=$1
	sleep "$(( ms / 1000 )).$(printf '%03d' "$(( ms % 1000 ))")"
}

# min / median / max over the numbers on stdin, as one line.
distribution() {
	sort -n | awk '
		{ a[NR] = $1 }
		END {
			if (NR == 0) { print "n=0"; exit }
			m = (NR % 2) ? a[(NR + 1) / 2] : int((a[NR / 2] + a[NR / 2 + 1]) / 2)
			printf "n=%d min=%d median=%d max=%d\n", NR, a[1], m, a[NR]
		}'
}

# ---------------------------------------------------------------------------
# psql
#
# Both take the statements on stdin and stop at the first error, so a caller can
# test the exit status.  psql_val prints one bare value.
# ---------------------------------------------------------------------------
psql_run() { psql -p "$PGPORT" -d "$1" -qX -v ON_ERROR_STOP=1 -f -; }
psql_val() { psql -p "$PGPORT" -d "$1" -tAqX -v ON_ERROR_STOP=1 -f -; }

db_exists() {
	local n
	n=$(psql_val postgres <<SQL
SELECT count(*) FROM pg_database WHERE datname = '$1';
SQL
	)
	[ "$n" = 1 ]
}

# Creates the database if it is not there, and says so through CREATED_DB: the
# scripts drop only a database they made themselves.
CREATED_DB=no
ensure_db() {
	if db_exists "$1"; then
		say "using the existing database $1"
		return 0
	fi
	say "creating the database $1"
	psql_run postgres <<SQL
CREATE DATABASE "$1";
SQL
	CREATED_DB=yes
}

drop_db() {
	say "dropping the database $1"
	psql_run postgres <<SQL
DROP DATABASE IF EXISTS "$1";
SQL
}

# ---------------------------------------------------------------------------
# Cancelling somebody else's backend, from a connection of its own
# ---------------------------------------------------------------------------
backend_signal() {
	local pid=$1 fn=pg_cancel_backend
	if [ "${2:-cancel}" = terminate ]; then
		fn=pg_terminate_backend
	fi
	psql_val postgres <<SQL
SELECT $fn($pid);
SQL
}

# ---------------------------------------------------------------------------
# Is the cluster still all there?
#
# gp_segment_configuration is what the coordinator believes; pg_isready is what
# the processes themselves answer.  A segment that died and was not failed over
# shows up in the first, one that is wedged only in the second.
# ---------------------------------------------------------------------------
cluster_state() {
	local counts down total port unready=

	counts=$(psql_val postgres <<'SQL'
SELECT count(*) FILTER (WHERE status <> 'u') || ' ' || count(*) FROM gp_segment_configuration;
SQL
	) || { echo "the coordinator did not answer"; return 1; }
	down=${counts% *}
	total=${counts#* }

	for port in $PGPORT $SEG_PORTS; do
		if ! pg_isready -p "$port" -q </dev/null; then
			unready="$unready $port"
		fi
	done

	if [ "$down" != 0 ] || [ -n "$unready" ]; then
		echo "$down of $total gp_segment_configuration entries not up, ports not answering:${unready:- none}"
		return 1
	fi
	echo "$total gp_segment_configuration entries up, ports $PGPORT$(printf ' %s' $SEG_PORTS) answering"
	return 0
}

# ---------------------------------------------------------------------------
# Core files
# ---------------------------------------------------------------------------
core_list() {
	local d
	for d in $CORE_DIRS; do
		[ -d "$d" ] || continue
		find "$d" -maxdepth 1 -name 'core*' -printf '%p\n' 2>/dev/null || true
	done | sort
}

# ---------------------------------------------------------------------------
# I5: the threads lance-c starts must not be able to take the backend's signals
#
# lance_rt_init() creates them under a full pthread_sigmask, so every thread but
# the main one should have all of these blocked.  Linux will not let SIGKILL or
# SIGSTOP be masked, and glibc keeps two realtime signals for itself, so the
# mask is not all ones and comparing against one literal value would be wrong;
# what matters is that the signals a backend is driven by are in there.
#
# SIGHUP 1, SIGINT 2, SIGQUIT 3, SIGUSR1 10, SIGUSR2 12, SIGPIPE 13,
# SIGALRM 14, SIGTERM 15, SIGCHLD 17.
SIGBLK_REQUIRED=0x17a07

# Prints a report and returns non-zero if any thread could take those signals,
# or if there were too few threads for the check to mean anything.
sigblk_report() {
	local pid=$1 min_threads=${2:-4}
	local main threads=0 others=0 bad=0 t tid mask low

	[ -r "/proc/$pid/status" ] || { echo "no /proc/$pid/status - is the session still open?"; return 1; }
	main=$(awk '/^SigBlk:/ { print $2; exit }' "/proc/$pid/status")

	for t in "/proc/$pid/task"/*; do
		[ -r "$t/status" ] || continue
		tid=${t##*/}
		mask=$(awk '/^SigBlk:/ { print $2; exit }' "$t/status")
		[ -n "$mask" ] || continue
		threads=$(( threads + 1 ))
		if [ "$tid" = "$pid" ]; then
			continue
		fi
		others=$(( others + 1 ))
		# Only the low 32 bits are needed and they always fit a signed 64-bit
		# arithmetic context, which the full 16-digit mask does not.
		low=${mask: -8}
		if [ $(( 0x$low & SIGBLK_REQUIRED )) -ne $(( SIGBLK_REQUIRED )) ]; then
			bad=$(( bad + 1 ))
			echo "  thread $tid: SigBlk=$mask does not block everything the backend is driven by"
		fi
	done

	echo "  $threads threads, $others besides the main one; main SigBlk=$main"
	if [ "$others" -lt "$min_threads" ]; then
		echo "  only $others non-main threads: too few for this check to prove anything"
		return 1
	fi
	if [ "$bad" != 0 ]; then
		echo "  $bad of $others threads can take the backend's signals"
		return 1
	fi
	echo "  all $others block SIGHUP/INT/QUIT/USR1/USR2/PIPE/ALRM/TERM/CHLD"
	return 0
}

# ---------------------------------------------------------------------------
# One psql session that stays open for a whole run
#
# The point of a single session is that the assertions are about one backend:
# the same pid gets cancelled fifty times, or sampled every hundred rounds, and
# then has to answer a query at the end.  Statements go into a fifo; a round
# ends with a marker statement whose output file psql opens only once the
# statement before it has returned, which is a sync point that does not depend
# on psql's stdout buffering (a file, so block-buffered).  Errors do: psql
# writes those to stderr, which C leaves unbuffered.
# ---------------------------------------------------------------------------
SESS_DIR=
SESS_PSQL=
SESS_PID=

session_open() {
	local db=$1

	SESS_DIR=$(mktemp -d /tmp/lance_stress.XXXXXX)
	mkfifo "$SESS_DIR/in"
	psql -p "$PGPORT" -d "$db" -qX -f "$SESS_DIR/in" \
		>"$SESS_DIR/out" 2>"$SESS_DIR/err" </dev/null &
	SESS_PSQL=$!
	# Read-write on purpose: opening a fifo for writing alone blocks until a
	# reader shows up, and a psql that failed to connect never becomes one, so
	# that spelling turns a bad database name into a hang.  Closing this fd
	# still leaves no writer, so psql still sees the end of its input.
	exec 3<>"$SESS_DIR/in"

	session_send '\pset format unaligned'
	session_send '\pset tuples_only on'
	SESS_PID=$(session_value 'SELECT pg_backend_pid()' 30) ||
		die "the stress session did not open: $(cat "$SESS_DIR/err")"
	say "session backend pid $SESS_PID in database $db"
}

session_send() { printf '%s\n' "$1" >&3; }

# Waits for a file to have something in it, or for psql to have died.
session_wait() {
	local file=$1 deadline
	deadline=$(( $(now_ms) + ${2:-60} * 1000 ))
	while [ ! -s "$file" ]; do
		[ "$(now_ms)" -lt "$deadline" ] || return 1
		kill -0 "$SESS_PSQL" 2>/dev/null || return 1
		sleep 0.05
	done
	return 0
}

# Ends a round: everything sent before this has run by the time it returns.
session_mark() {
	rm -f "$SESS_DIR/mark"
	session_send "\\o $SESS_DIR/mark"
	session_send "SELECT 'mark';"
	session_send '\o'
	session_wait "$SESS_DIR/mark" "${1:-60}"
}

# Runs one statement that is expected to succeed and prints its single value.
session_value() {
	rm -f "$SESS_DIR/val"
	session_send "\\o $SESS_DIR/val"
	session_send "$1;"
	session_send '\o'
	session_wait "$SESS_DIR/val" "${2:-60}" || return 1
	cat "$SESS_DIR/val"
}

session_errors() { grep -c 'ERROR:' "$SESS_DIR/err" 2>/dev/null || true; }
session_err_lines() { wc -l <"$SESS_DIR/err" 2>/dev/null || echo 0; }
session_err_since() { tail -n "+$(( $1 + 1 ))" "$SESS_DIR/err" 2>/dev/null || true; }

session_close() {
	[ -n "$SESS_PSQL" ] || return 0
	exec 3>&- || true
	wait "$SESS_PSQL" 2>/dev/null || true
	SESS_PSQL=
}

# For the paths where the session is stuck: get the backend out of the way
# first, then the client.
session_abort() {
	[ -n "$SESS_PSQL" ] || return 0
	if [ -n "$SESS_PID" ]; then
		backend_signal "$SESS_PID" terminate >/dev/null 2>&1 || true
	fi
	exec 3>&- || true
	kill "$SESS_PSQL" 2>/dev/null || true
	wait "$SESS_PSQL" 2>/dev/null || true
	SESS_PSQL=
}
