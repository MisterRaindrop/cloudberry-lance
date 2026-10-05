#!/usr/bin/env bash
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
# test/run/reset.sh - put the test run's business state back, and nothing else.
#
# This is the only script in the tree that deletes anything, so it deletes as
# little as possible: the lance_feature schema in the regression databases, and
# the fixture objects under the bucket's fixtures/ prefix, which are then
# re-uploaded.  cargo's target/, the PGXS objects and the installed extension
# are build state and are left alone.
#
# Usage: test/run/reset.sh [--no-upload]
#
set -euo pipefail

CONTAINER=${LANCE_TEST_CONTAINER:-cbdb-repro-1850}
QD_PORT=${LANCE_TEST_PORT:-7000}
DATABASES=${LANCE_TEST_DATABASES:-contrib_regression}
PG_ENV=${LANCE_TEST_PG_ENV:-/usr/local/cloudberry-db/greenplum_path.sh}

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
ENV_FILE="$ROOT/test/run/env.sh"
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
	say "dropping schema lance_feature in $db"
	docker exec -u gpadmin "$CONTAINER" bash -lc "
		set -e
		source $(printf %q "$PG_ENV")
		if psql -p $QD_PORT -d postgres -tAc \
			\"SELECT 1 FROM pg_database WHERE datname = '$db'\" | grep -q 1; then
			psql -p $QD_PORT -d '$db' -v ON_ERROR_STOP=1 \
				-c 'DROP SCHEMA IF EXISTS lance_feature CASCADE'
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
