#!/usr/bin/env bash
#
# test/gate/gate.sh - run the lance_fdw gate.
#
# This repository is not mounted into the Cloudberry container and the host has
# no server installation, so the gate is a bridge: it tars the working tree into
# a fixed path inside the container, builds and installs there, and runs
# pg_regress against the demo cluster on port 7000.  Build outputs (cargo's
# target/ and the PGXS objects) stay in the container between runs, which is
# what keeps a warm gate at minutes instead of the ~16 minutes lance-c needs
# from cold.
#
# Usage:
#   test/gate/gate.sh                 build, install and run every suite
#   test/gate/gate.sh --suite ddl     run only "install ddl"
#   test/gate/gate.sh --clean         make clean + cargo clean first (slow)
#   test/gate/gate.sh --no-sync       reuse whatever is already in the container
#   test/gate/gate.sh --no-fixtures   skip fixture generation/sync/upload
#
# Environment:
#   LANCE_GATE_CONTAINER   container name             (default cbdb-repro-1850)
#   LANCE_GATE_REMOTE      path inside the container  (default
#                          /home/gpadmin/cloudberry-lance)
#   test/gate/env.sh       MinIO endpoint, bucket, region and credentials; not
#                          in the repository, sourced here and passed to the
#                          regression suites through PGOPTIONS.
#
set -euo pipefail

CONTAINER=${LANCE_GATE_CONTAINER:-cbdb-repro-1850}
REMOTE=${LANCE_GATE_REMOTE:-/home/gpadmin/cloudberry-lance}
LANCE_SRC_DIR=${LANCE_GATE_LANCE_SRC:-/home/gpadmin/lance-src}
LANCE_REV=e934cc2c
QD_PORT=${LANCE_GATE_PORT:-7000}

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
ENV_FILE="$ROOT/test/gate/env.sh"
FIXTURE_DIR="$ROOT/test/fixtures/data"

DO_CLEAN=no
DO_SYNC=yes
DO_FIXTURES=yes
SUITE=

# The 21 lance crates lance-c takes from git.  The container cannot fetch them
# at any usable speed (GitHub is ~30 KB/s from there), so cargo is pointed at a
# source tree the host downloaded instead (PROBES, "build facts").
LANCE_PATCH_CRATES=(
	fsst
	lance
	lance-arrow
	lance-arrow-scalar
	lance-arrow-stats
	lance-bitpacking
	lance-core
	lance-datafusion
	lance-datagen
	lance-derive
	lance-encoding
	lance-file
	lance-geo
	lance-index
	lance-index-core
	lance-io
	lance-linalg
	lance-namespace
	lance-select
	lance-table
	lance-tokenizer
)

die() { echo "gate: $*" >&2; exit 1; }
say() { echo "gate: $*"; }

usage() {
	sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
	case "$1" in
		--clean) DO_CLEAN=yes ;;
		--no-sync) DO_SYNC=no ;;
		--no-fixtures) DO_FIXTURES=no ;;
		--suite)
			[ $# -ge 2 ] || die "--suite needs a suite name"
			SUITE=$2
			shift
			;;
		--suite=*) SUITE=${1#--suite=} ;;
		-h|--help) usage; exit 0 ;;
		*) die "unknown argument: $1 (try --help)" ;;
	esac
	shift
done

# Every suite depends on "install" having created the extension and the
# lance_regress schema, so a single suite always runs behind it.
if [ -z "$SUITE" ]; then
	SUITES="install ddl import errors_ddl"
elif [ "$SUITE" = install ]; then
	SUITES="install"
else
	SUITES="install $SUITE"
fi

command -v docker >/dev/null 2>&1 || die "docker is not on PATH"
[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || echo false)" = true ] ||
	die "container $CONTAINER is not running"

S3_ENDPOINT=
S3_BUCKET=
S3_REGION=
S3_KEY=
S3_SECRET=
if [ -f "$ENV_FILE" ]; then
	# shellcheck disable=SC1090
	. "$ENV_FILE"
	S3_ENDPOINT=${LANCE_S3_ENDPOINT_CONTAINER:-}
	S3_BUCKET=${LANCE_S3_BUCKET:-}
	S3_REGION=${LANCE_S3_REGION:-}
	S3_KEY=${LANCE_S3_KEY:-}
	S3_SECRET=${LANCE_S3_SECRET:-}
else
	say "warning: $ENV_FILE is missing; the s3:// cases will fail"
fi

# ---------------------------------------------------------------------------
# Running things in the container
#
# The script body arrives on stdin, never on the command line, so credentials
# do not show up in the host's process list.  bash -l picks up the greenplum
# environment for gpadmin.
# ---------------------------------------------------------------------------
remote() {
	local body=$1
	shift
	{
		printf 'set -euo pipefail\n'
		printf 'REMOTE=%q\n' "$REMOTE"
		printf 'LANCE_SRC_DIR=%q\n' "$LANCE_SRC_DIR"
		printf 'LANCE_REV=%q\n' "$LANCE_REV"
		printf 'QD_PORT=%q\n' "$QD_PORT"
		printf 'SUITES=%q\n' "$SUITES"
		printf 'S3_ENDPOINT=%q\n' "$S3_ENDPOINT"
		printf 'S3_BUCKET=%q\n' "$S3_BUCKET"
		printf 'S3_REGION=%q\n' "$S3_REGION"
		printf 'S3_KEY=%q\n' "$S3_KEY"
		printf 'S3_SECRET=%q\n' "$S3_SECRET"
		printf '%s\n' "$body"
	} | docker exec -i -u gpadmin "$CONTAINER" bash -l -s
}

remote_quiet() {
	docker exec -u gpadmin "$CONTAINER" bash -lc "$1"
}

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------
prepare_fixtures() {
	[ "$DO_FIXTURES" = yes ] || return 0

	if [ ! -d "$FIXTURE_DIR" ]; then
		say "generating fixtures on the host"
		make -C "$ROOT/test/fixtures" gen
	fi

	if [ -n "$S3_BUCKET" ]; then
		say "uploading fixtures to s3://$S3_BUCKET/fixtures/"
		make -C "$ROOT/test/fixtures" upload
	fi
}

sync_fixtures() {
	[ "$DO_FIXTURES" = yes ] || return 0
	[ -d "$FIXTURE_DIR" ] || die "$FIXTURE_DIR is missing"

	say "streaming fixtures into $CONTAINER:$REMOTE/test/fixtures/data"
	remote_quiet "mkdir -p '$REMOTE/test/fixtures/data'"
	tar -C "$ROOT/test/fixtures" -cf - data |
		docker exec -i -u gpadmin "$CONTAINER" tar -xf - -C "$REMOTE/test/fixtures"
}

# ---------------------------------------------------------------------------
# Source sync
#
# target/ and the PGXS objects live only in the container and must survive:
# extraction overlays, it never deletes.
# ---------------------------------------------------------------------------
sync_tree() {
	[ "$DO_SYNC" = yes ] || return 0

	say "streaming the working tree into $CONTAINER:$REMOTE"
	remote_quiet "mkdir -p '$REMOTE'"
	tar -C "$ROOT" -cf - \
		--exclude=./.git \
		--exclude=./.venv \
		--exclude=./.router \
		--exclude=./.pytest_cache \
		--exclude=__pycache__ \
		--exclude=./third_party/lance-c/.git \
		--exclude=./third_party/lance-c/target \
		--exclude=./test/fixtures/data \
		--exclude=./test/gate/env.sh \
		. | docker exec -i -u gpadmin "$CONTAINER" tar -xf - -C "$REMOTE"
}

# ---------------------------------------------------------------------------
# cargo inputs: the vendored lance source tree and the registry replacement
# ---------------------------------------------------------------------------
write_cargo_config() {
	local config
	local crate

	config=$'[source.crates-io]\nreplace-with = "rsproxy-sparse"\n\n'
	config+=$'[source.rsproxy-sparse]\nregistry = "sparse+https://rsproxy.cn/index/"\n\n'
	config+=$'[net]\ngit-fetch-with-cli = true\n\n'
	config+=$'[patch."https://github.com/lance-format/lance.git"]\n'
	for crate in "${LANCE_PATCH_CRATES[@]}"; do
		config+="$crate = { path = \"$LANCE_SRC_DIR/lance-$LANCE_REV/rust/$crate\" }"$'\n'
	done

	say "writing $REMOTE/third_party/lance-c/.cargo/config.toml"
	remote_quiet "mkdir -p '$REMOTE/third_party/lance-c/.cargo'"
	printf '%s' "$config" |
		docker exec -i -u gpadmin "$CONTAINER" \
			tee "$REMOTE/third_party/lance-c/.cargo/config.toml" >/dev/null
}

fetch_lance_source() {
	local tmp
	tmp=$(mktemp)
	# shellcheck disable=SC2064
	trap "rm -f '$tmp'" RETURN

	say "downloading lance $LANCE_REV on the host (the container cannot)"
	curl -fsSL "https://codeload.github.com/lance-format/lance/tar.gz/$LANCE_REV" -o "$tmp" ||
		die "could not download the lance source tarball"

	remote_quiet "rm -rf '$LANCE_SRC_DIR/.incoming' && mkdir -p '$LANCE_SRC_DIR/.incoming'"
	docker exec -i -u gpadmin "$CONTAINER" \
		tar -xzf - -C "$LANCE_SRC_DIR/.incoming" <"$tmp"
	remote_quiet "set -e
		cd '$LANCE_SRC_DIR/.incoming'
		top=\$(ls -1)
		test -d \"\$top/rust\" || { echo 'unexpected tarball layout' >&2; exit 1; }
		rm -rf '$LANCE_SRC_DIR/lance-$LANCE_REV'
		mv \"\$top\" '$LANCE_SRC_DIR/lance-$LANCE_REV'
		rmdir '$LANCE_SRC_DIR/.incoming'"
}

ensure_cargo_inputs() {
	if ! remote_quiet "test -d '$LANCE_SRC_DIR/lance-$LANCE_REV/rust'" 2>/dev/null; then
		remote_quiet "mkdir -p '$LANCE_SRC_DIR'"
		fetch_lance_source
	fi
	if ! remote_quiet "test -s '$REMOTE/third_party/lance-c/.cargo/config.toml'" 2>/dev/null; then
		write_cargo_config
	fi
}

# ---------------------------------------------------------------------------
# Build, install, test
# ---------------------------------------------------------------------------
build_and_test() {
	local clean_step=""

	if [ "$DO_CLEAN" = yes ]; then
		clean_step='make clean; make clean-lance-c'
	fi

	remote "
export PATH=/usr/local/toolchain/bin:\$PATH
export CC=/usr/local/toolchain/bin/gcc
export CXX=/usr/local/toolchain/bin/g++
export PGPORT=\$QD_PORT

cd \"\$REMOTE\"
$clean_step

echo '== make =='
time make -s

echo '== make install =='
make -s install

echo \"== make installcheck (\$SUITES) ==\"
PGOPTIONS=\"-c regress.fixture_dir=\$REMOTE/test/fixtures/data\"
PGOPTIONS=\"\$PGOPTIONS -c regress.s3_endpoint=\$S3_ENDPOINT\"
PGOPTIONS=\"\$PGOPTIONS -c regress.s3_bucket=\$S3_BUCKET\"
PGOPTIONS=\"\$PGOPTIONS -c regress.s3_region=\$S3_REGION\"
PGOPTIONS=\"\$PGOPTIONS -c regress.s3_key=\$S3_KEY\"
PGOPTIONS=\"\$PGOPTIONS -c regress.s3_secret=\$S3_SECRET\"
export PGOPTIONS

if ! make installcheck REGRESS=\"\$SUITES\"; then
	echo '== regression.diffs =='
	sed -n '1,400p' test/regress/regression.diffs 2>/dev/null || true
	exit 1
fi
"
}

say "container=$CONTAINER remote=$REMOTE suites='$SUITES'"
prepare_fixtures
sync_tree
sync_fixtures
ensure_cargo_inputs
build_and_test
say "PASS"
