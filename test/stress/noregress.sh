#!/usr/bin/env bash
#
# test/stress/noregress.sh - AC10: installing lance_fdw changes nothing else.
#
# A fixed SQL script that has nothing to do with Lance - a distributed heap
# table pair, an insert, a join across segments, an aggregate, a per-segment
# count, a read from a gp_exttable_fdw external web table and an EXPLAIN - is
# run three times in three states of the same database:
#
#   absent      lance_fdw is not installed (DROP EXTENSION IF EXISTS CASCADE)
#   installed   the extension is there
#   scanned     the extension is there and this backend, and its segments, have
#               run a Lance scan, so lance-c and its threads are loaded
#
# The three outputs are compared byte for byte, stdout and stderr separately.
# Any difference fails: it would mean the wrapper changes the behaviour of a
# query that never mentions it, which I10 forbids.
#
# Usage:
#   test/stress/noregress.sh [options]
#
#   --db NAME        database to work in           (default lance_stress)
#   --keep-db        do not drop a database this run created
#   --keep-output    leave the captured output in the container and say where
#
# Needs the fixtures in the container for the third state's scan;
# test/gate/gate.sh syncs them there.  Needs no S3.
#
set -euo pipefail

TAG=noregress
# shellcheck source=test/stress/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

DB=lance_stress
KEEP_DB=no
KEEP_OUTPUT=no

need_arg() { [ "$2" -ge 2 ] || die "$1 needs a value"; }

while [ $# -gt 0 ]; do
	case "$1" in
		--db) need_arg "$1" $#; DB=$2; shift ;;
		--db=*) DB=${1#*=} ;;
		--keep-db) KEEP_DB=yes ;;
		--keep-output) KEEP_OUTPUT=yes ;;
		-h|--help) usage_from_header "${BASH_SOURCE[0]}"; exit 0 ;;
		*) die "unknown argument: $1 (try --help)" ;;
	esac
	shift
done

require_docker

say "container=$CONTAINER db=$DB"
stress_remote "$STRESS_DIR/noregress.remote.sh" \
	"DB=$DB" \
	"KEEP_DB=$KEEP_DB" \
	"KEEP_OUTPUT=$KEEP_OUTPUT"
