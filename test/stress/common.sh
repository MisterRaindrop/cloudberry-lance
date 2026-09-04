#!/usr/bin/env bash
#
# test/stress/common.sh - the host half of the stress scripts.  Sourced, not run.
#
# The cluster lives in a container this repository is not mounted into, so each
# stress script is a bridge in the same shape as test/gate/gate.sh: it streams a
# body script into the container over stdin and relays what that prints.  The
# loops themselves run inside the container, because the clock, /proc and the
# server logs that the assertions are about are all in there.
#
# Environment (the same names test/gate/gate.sh uses):
#   LANCE_GATE_CONTAINER      container name             (default cbdb-repro-1850)
#   LANCE_GATE_REMOTE         path inside the container  (default
#                             /home/gpadmin/cloudberry-lance)
#   LANCE_GATE_PORT           coordinator port           (default 7000)
#   LANCE_GATE_PG_ENV         greenplum_path.sh to source in the container
#   LANCE_STRESS_SEG_PORTS    segment ports to probe     (default 7002 7003 7004)
#   LANCE_STRESS_CORE_DIRS    where a core file would land
#   LANCE_STRESS_FIXTURE_DIR  fixture directory in the container
#   test/gate/env.sh          MinIO endpoint, bucket, region and credentials;
#                             not in the repository.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	echo "common.sh is meant to be sourced by the stress scripts" >&2
	exit 1
fi

STRESS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$STRESS_DIR/../.." && pwd)
ENV_FILE=$ROOT/test/gate/env.sh

CONTAINER=${LANCE_GATE_CONTAINER:-cbdb-repro-1850}
REMOTE=${LANCE_GATE_REMOTE:-/home/gpadmin/cloudberry-lance}
QD_PORT=${LANCE_GATE_PORT:-7000}
PG_ENV=${LANCE_GATE_PG_ENV:-/usr/local/cloudberry-db/greenplum_path.sh}
SEG_PORTS=${LANCE_STRESS_SEG_PORTS:-"7002 7003 7004"}
FIXTURE_DIR=${LANCE_STRESS_FIXTURE_DIR:-$REMOTE/test/fixtures/data}

# A core file lands either in the data directory of the process that dumped it
# or, for anything started from gpadmin's home, in the home directory.
CORE_DIRS=${LANCE_STRESS_CORE_DIRS:-"\
/home/gpadmin/demo/datadirs/qddir/demoDataDir-1 \
/home/gpadmin/demo/datadirs/dbfast1/demoDataDir0 \
/home/gpadmin/demo/datadirs/dbfast2/demoDataDir1 \
/home/gpadmin/demo/datadirs/dbfast3/demoDataDir2 \
/home/gpadmin"}

TAG=${TAG:-stress}

S3_ENDPOINT=
S3_BUCKET=
S3_REGION=
S3_KEY=
S3_SECRET=

say() { echo "$TAG: $*"; }
die() { echo "$TAG: $*" >&2; exit 1; }

# The usage block of the calling script: its comment header, minus the '#'.
usage_from_header() {
	sed -n "2,${2:-30}p" "$1" | sed 's/^# \{0,1\}//'
}

require_docker() {
	command -v docker >/dev/null 2>&1 || die "docker is not on PATH"
	[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || echo false)" = true ] ||
		die "container $CONTAINER is not running"
}

load_env() {
	if [ ! -f "$ENV_FILE" ]; then
		return 1
	fi
	# shellcheck disable=SC1090
	. "$ENV_FILE"
	S3_ENDPOINT=${LANCE_S3_ENDPOINT_CONTAINER:-}
	S3_BUCKET=${LANCE_S3_BUCKET:-}
	S3_REGION=${LANCE_S3_REGION:-}
	S3_KEY=${LANCE_S3_KEY:-}
	S3_SECRET=${LANCE_S3_SECRET:-}
	return 0
}

# The setup SQL puts the credentials in single-quoted literals, so one that
# contains a quote of its own would break the statement rather than the test.
require_s3() {
	load_env || die "$ENV_FILE is missing; the s3:// cases cannot run without it"
	[ -n "$S3_BUCKET" ] || die "$ENV_FILE sets no LANCE_S3_BUCKET"
	[ -n "$S3_ENDPOINT" ] || die "$ENV_FILE sets no LANCE_S3_ENDPOINT_CONTAINER"
	case "$S3_KEY$S3_SECRET" in
		*"'"*) die "a credential in $ENV_FILE contains a single quote; the SQL these scripts generate cannot carry that" ;;
	esac
}

# ---------------------------------------------------------------------------
# Running a body script in the container
#
# The prelude and the body arrive on stdin, never on the command line, so
# credentials do not show up in the process list of either machine.  Anything
# the caller passes as NAME=VALUE becomes a shell variable in the body, quoted.
# ---------------------------------------------------------------------------
stress_remote() {
	local body=$1
	shift

	[ -f "$body" ] || die "missing body script $body"

	local kv
	{
		printf 'set -euo pipefail\n'
		printf 'source %q\n' "$PG_ENV"
		printf 'TAG=%q\n' "$TAG"
		printf 'PGPORT=%q\nexport PGPORT\n' "$QD_PORT"
		printf 'REMOTE=%q\n' "$REMOTE"
		printf 'FIXTURE_DIR=%q\n' "$FIXTURE_DIR"
		printf 'SEG_PORTS=%q\n' "$SEG_PORTS"
		printf 'CORE_DIRS=%q\n' "$CORE_DIRS"
		printf 'S3_ENDPOINT=%q\n' "$S3_ENDPOINT"
		printf 'S3_BUCKET=%q\n' "$S3_BUCKET"
		printf 'S3_REGION=%q\n' "$S3_REGION"
		printf 'S3_KEY=%q\n' "$S3_KEY"
		printf 'S3_SECRET=%q\n' "$S3_SECRET"
		for kv in "$@"; do
			printf '%s=%q\n' "${kv%%=*}" "${kv#*=}"
		done
		cat "$STRESS_DIR/remote_common.sh"
		printf '\n'
		cat "$body"
	} | docker exec -i -u gpadmin "$CONTAINER" bash -l -s
}
