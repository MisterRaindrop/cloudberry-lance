#!/usr/bin/env bash
#
# test/stress/leak_loop.sh - AC7: a thousand failed scans in one session.
#
# One psql session, and in it three failing statements per round: a scan of a
# uri that is not there, a scan of an S3 dataset with credentials that are
# wrong, and a scan that refers to a B-tier column.  All three take the
# wrapper's error path, and the error path is where a dataset handle, an Arrow
# stream or a file descriptor would be left behind (I6).  Every so many rounds
# the session's backend is sampled through /proc: how many file descriptors it
# holds, how much resident memory it has, how many threads it runs and how many
# QE processes its session has.  The first and last samples are what decides
# the outcome; the whole curve is printed.
#
# A bad endpoint is deliberately not one of the three: object_store retries a
# refused connection for about ten seconds, which would make a thousand rounds
# take three hours.  Wrong credentials against a reachable endpoint fail at
# once and exercise the same path.
#
# Usage:
#   test/stress/leak_loop.sh [options]
#
#   --rounds N              rounds to run                    (default 1000)
#   --sample-every N        rounds between /proc samples      (default 100)
#   --max-fd-growth N       file descriptors the backend may gain (default 2)
#   --max-rss-growth-mb N   resident memory it may gain, MiB   (default 32)
#   --chunk-deadline S      seconds a batch of --sample-every rounds may take
#                                                             (default 300)
#   --skip-s3               leave out the wrong-credentials rounds
#   --db NAME               database to work in       (default lance_stress)
#   --keep-db               do not drop a database this run created
#
# Needs the fixtures in the container (test/gate/gate.sh syncs them there) and,
# unless --skip-s3, test/gate/env.sh for the endpoint and bucket.
#
set -euo pipefail

TAG=leak_loop
# shellcheck source=test/stress/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

ROUNDS=1000
SAMPLE_EVERY=100
MAX_FD_GROWTH=2
MAX_RSS_GROWTH_MB=32
CHUNK_DEADLINE=300
SKIP_S3=no
DB=lance_stress
KEEP_DB=no

need_arg() { [ "$2" -ge 2 ] || die "$1 needs a value"; }

while [ $# -gt 0 ]; do
	case "$1" in
		--rounds) need_arg "$1" $#; ROUNDS=$2; shift ;;
		--rounds=*) ROUNDS=${1#*=} ;;
		--sample-every) need_arg "$1" $#; SAMPLE_EVERY=$2; shift ;;
		--sample-every=*) SAMPLE_EVERY=${1#*=} ;;
		--max-fd-growth) need_arg "$1" $#; MAX_FD_GROWTH=$2; shift ;;
		--max-fd-growth=*) MAX_FD_GROWTH=${1#*=} ;;
		--max-rss-growth-mb) need_arg "$1" $#; MAX_RSS_GROWTH_MB=$2; shift ;;
		--max-rss-growth-mb=*) MAX_RSS_GROWTH_MB=${1#*=} ;;
		--chunk-deadline) need_arg "$1" $#; CHUNK_DEADLINE=$2; shift ;;
		--chunk-deadline=*) CHUNK_DEADLINE=${1#*=} ;;
		--skip-s3) SKIP_S3=yes ;;
		--db) need_arg "$1" $#; DB=$2; shift ;;
		--db=*) DB=${1#*=} ;;
		--keep-db) KEEP_DB=yes ;;
		-h|--help) usage_from_header "${BASH_SOURCE[0]}"; exit 0 ;;
		*) die "unknown argument: $1 (try --help)" ;;
	esac
	shift
done

case "$ROUNDS$SAMPLE_EVERY$MAX_FD_GROWTH$MAX_RSS_GROWTH_MB$CHUNK_DEADLINE" in
	*[!0-9]*) die "--rounds, --sample-every, --max-fd-growth, --max-rss-growth-mb and --chunk-deadline take numbers" ;;
esac
[ "$ROUNDS" -ge 1 ] || die "--rounds must be at least 1"
[ "$SAMPLE_EVERY" -ge 1 ] || die "--sample-every must be at least 1"

require_docker
if [ "$SKIP_S3" = yes ]; then
	load_env || say "note: $ENV_FILE is missing, which --skip-s3 makes harmless"
else
	require_s3
fi

say "container=$CONTAINER rounds=$ROUNDS sample-every=$SAMPLE_EVERY db=$DB skip-s3=$SKIP_S3"
stress_remote "$STRESS_DIR/leak_loop.remote.sh" \
	"ROUNDS=$ROUNDS" \
	"SAMPLE_EVERY=$SAMPLE_EVERY" \
	"MAX_FD_GROWTH=$MAX_FD_GROWTH" \
	"MAX_RSS_GROWTH_MB=$MAX_RSS_GROWTH_MB" \
	"CHUNK_DEADLINE=$CHUNK_DEADLINE" \
	"SKIP_S3=$SKIP_S3" \
	"DB=$DB" \
	"KEEP_DB=$KEEP_DB"
