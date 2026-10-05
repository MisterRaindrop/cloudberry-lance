#!/usr/bin/env bash
#
# test/gate/reset.sh - put the gate's business state back, and nothing else.
#
# This is the only script in the tree that deletes anything, so it deletes as
# little as possible: the lance_regress schema in the regression databases, and
# the fixture objects under the bucket's fixtures/ prefix, which are then
# re-uploaded.  cargo's target/, the PGXS objects and the installed extension
# are build state and are left alone.
#
# Usage: test/gate/reset.sh [--no-upload]
#
set -euo pipefail

CONTAINER=${LANCE_GATE_CONTAINER:-cbdb-repro-1850}
QD_PORT=${LANCE_GATE_PORT:-7000}
DATABASES=${LANCE_GATE_DATABASES:-contrib_regression}
PG_ENV=${LANCE_GATE_PG_ENV:-/usr/local/cloudberry-db/greenplum_path.sh}

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
ENV_FILE="$ROOT/test/gate/env.sh"
DO_UPLOAD=yes

die() { echo "reset: $*" >&2; exit 1; }
say() { echo "reset: $*"; }

while [ $# -gt 0 ]; do
	case "$1" in
		--no-upload) DO_UPLOAD=no ;;
		-h|--help) sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) die "unknown argument: $1" ;;
	esac
	shift
done

command -v docker >/dev/null 2>&1 || die "docker is not on PATH"
[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || echo false)" = true ] ||
	die "container $CONTAINER is not running"

for db in $DATABASES; do
	say "dropping schema lance_regress in $db"
	docker exec -u gpadmin "$CONTAINER" bash -lc "
		set -e
		source $(printf %q "$PG_ENV")
		if psql -p $QD_PORT -d postgres -tAc \
			\"SELECT 1 FROM pg_database WHERE datname = '$db'\" | grep -q 1; then
			psql -p $QD_PORT -d '$db' -v ON_ERROR_STOP=1 \
				-c 'DROP SCHEMA IF EXISTS lance_regress CASCADE'
		else
			echo \"database $db does not exist yet, nothing to drop\"
		fi"
done

if [ "$DO_UPLOAD" = yes ]; then
	[ -f "$ENV_FILE" ] || die "$ENV_FILE is missing; cannot reach MinIO"
	[ -d "$ROOT/test/fixtures/data" ] || die "test/fixtures/data is missing; run make -C test/fixtures gen"
	say "re-uploading fixtures under the fixtures/ prefix"
	make -C "$ROOT/test/fixtures" upload
fi

say "done"
