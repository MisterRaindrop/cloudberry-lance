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
#   test/gate/gate.sh --stress        afterwards, dry-run test/stress/*.sh
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
# The lance revision is a property of the submodule, not of this script: read it
# from there so that bumping third_party/lance-c cannot leave the gate building
# against a different version of lance than the extension asks for.  Getting
# that wrong is silent - cargo would happily build the old sources - which is
# why it is derived rather than written down twice.
LANCE_REV=$(sed -n 's/.*lance = { git = "[^"]*", rev = "\([^"]*\)".*/\1/p' \
	"$(dirname "${BASH_SOURCE[0]}")/../../third_party/lance-c/Cargo.toml" | head -1)
[ -n "$LANCE_REV" ] ||
	{ echo "gate: cannot read the lance rev from third_party/lance-c/Cargo.toml" >&2; exit 1; }
QD_PORT=${LANCE_GATE_PORT:-7000}
# gpadmin's login shell does not put pg_config/psql on PATH; the server ships the
# environment file, so every remote script sources it first (PROBES, P1 gate).
PG_ENV=${LANCE_GATE_PG_ENV:-/usr/local/cloudberry-db/greenplum_path.sh}

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
ENV_FILE="$ROOT/test/gate/env.sh"
FIXTURE_DIR="$ROOT/test/fixtures/data"

# The three fake credentials test/regress/sql/creds.sql puts in a user mapping:
# all of them are user-mapping options the wrapper reads, so all three are
# checked.  After the suites have run, one may appear in a server log only on
# the line that carries the CREATE USER MAPPING statement itself, which the
# server echoes like any other DDL (AC8).
CREDS_CANARIES="LANCE_CANARY_KEY_9f3a LANCE_CANARY_SECRET_9f3a LANCE_CANARY_TOKEN_9f3a"
CLUSTER_LOGS=(
	/home/gpadmin/demo/datadirs/qddir/demoDataDir-1/log
	/home/gpadmin/demo/datadirs/dbfast1/demoDataDir0/log
	/home/gpadmin/demo/datadirs/dbfast2/demoDataDir1/log
	/home/gpadmin/demo/datadirs/dbfast3/demoDataDir2/log
)

DO_CLEAN=no
DO_SYNC=yes
DO_FIXTURES=yes
DO_STRESS=no
SUITE=

# The 21 lance crates lance-c takes from git.  The container cannot fetch them
# at any usable speed (GitHub is ~30 KB/s from there), so cargo is pointed at a
# source tree the host downloaded instead (PROBES, "build facts").
# The crates to [patch] are whatever the lance tree at this revision actually
# contains.  They used to be listed here, and the list went stale the first time
# LANCE_REV moved: four of the names no longer existed, so cargo failed with
# "failed to load source for dependency fsst" on exactly the machines this
# vendoring path exists for.  Enumerating them costs one ls.
lance_patch_crates() {
	remote_quiet "cd '$LANCE_SRC_DIR/lance-$LANCE_REV/rust' &&
		for d in */Cargo.toml; do
			sed -n 's/^name *= *\"\\(.*\\)\"/\\1/p' \"\$d\" | head -1
		done"
}


die() { echo "gate: $*" >&2; exit 1; }
say() { echo "gate: $*"; }

usage() {
	sed -e '1d' -e '/^[^#]/,$d' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
	case "$1" in
		--clean) DO_CLEAN=yes ;;
		--no-sync) DO_SYNC=no ;;
		--no-fixtures) DO_FIXTURES=no ;;
		--stress) DO_STRESS=yes ;;
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
	SUITES="install ddl import errors_ddl scan_core parallel snapshot explain pushdown pushdown_errors creds errors_scan types types_errors types_nested types_nested_errors sigmask"
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
		printf 'source %q\n' "$PG_ENV"
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
	docker exec -u gpadmin "$CONTAINER" bash -lc "source $(printf %q "$PG_ENV") && $1"
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
	while read -r crate; do
		[ -n "$crate" ] || continue
		config+="$crate = { path = \"$LANCE_SRC_DIR/lance-$LANCE_REV/rust/$crate\" }"$'\n'
	done < <(lance_patch_crates)

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

# AC1: building against a lance-c that is supplied from outside has to work
# too.  Point the override at the submodule's own artefacts: no cargo run, no
# liblance_c.so installed, and the rpath goes to where the library already is.
if [ -f third_party/lance-c/target/release/liblance_c.so ]; then
	echo '== make with the LANCE_C_PREFIX override =='
	make -s clean
	make -s \\
		LANCE_C_INCDIR=\"\$REMOTE/third_party/lance-c/include\" \\
		LANCE_C_LIBDIR=\"\$REMOTE/third_party/lance-c/target/release\" \\
		LANCE_C_PREFIX=\"\$REMOTE/third_party/lance-c\"
	make -s clean
fi

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

# ---------------------------------------------------------------------------
# AC8: the user mapping secret must not have reached a server log
#
# The suite itself checks the plan; only the server can say what ended up in
# its log, and only after the statements that could have put it there have run.
# ---------------------------------------------------------------------------
check_credential_leak() {
	case " $SUITES " in
		*" creds "*) ;;
		*)
			say "skipping the credential log check (the creds suite did not run)"
			return 0
			;;
	esac

	say "checking the coordinator and segment logs for the user mapping credentials"
	remote "
found=no
leaked=no
for dir in ${CLUSTER_LOGS[*]}; do
	[ -d \"\$dir\" ] || continue
	for f in \"\$dir\"/*.csv; do
		[ -f \"\$f\" ] || continue
		found=yes
		for canary in ${CREDS_CANARIES}; do
			# The CREATE USER MAPPING statement is logged verbatim and is
			# written on one line for exactly this reason; anything else is a
			# leak.
			hits=\$(grep -h \"\$canary\" \"\$f\" | grep -v 'CREATE USER MAPPING' || true)
			if [ -n \"\$hits\" ]; then
				leaked=yes
				echo \"leak of \$canary in \$f:\"
				printf '%s\\n' \"\$hits\" | head -5
			fi
		done
	done
done
if [ \"\$found\" = no ]; then
	echo 'no server log files found - the credential check did not run' >&2
	exit 1
fi
if [ \"\$leaked\" = yes ]; then
	echo 'AC8: a user mapping credential reached a server log' >&2
	exit 1
fi
echo 'credential check: all three credentials appear only in the CREATE USER MAPPING statement'
"
}

# ---------------------------------------------------------------------------
# --stress: prove the stress scripts run, not that the invariants hold
#
# The full runs are minutes to hours and their subject is behaviour under
# repetition, so they are not part of a gate: WORKPLAN T7 has the main session
# run them by hand and record the numbers.  What a gate can do is catch a stress
# script that no longer works, which is what these dry runs are.  cancel_loop
# gets --min-interrupted-pct 0 for that reason: on a 1 MiB dataset a scan can
# finish before the interrupt reaches it, which says nothing about the wrapper
# and everything about the size of the fixture.
# ---------------------------------------------------------------------------
run_stress() {
	[ "$DO_STRESS" = yes ] || return 0

	local common=(
		"LANCE_GATE_CONTAINER=$CONTAINER"
		"LANCE_GATE_REMOTE=$REMOTE"
		"LANCE_GATE_PORT=$QD_PORT"
		"LANCE_GATE_PG_ENV=$PG_ENV"
	)

	say "dry-running test/stress/cancel_loop.sh"
	env "${common[@]}" bash "$ROOT/test/stress/cancel_loop.sh" \
		--rounds 2 --dataset large_text --min-interrupted-pct 0

	say "dry-running test/stress/leak_loop.sh"
	env "${common[@]}" bash "$ROOT/test/stress/leak_loop.sh" --rounds 20

	say "dry-running test/stress/noregress.sh"
	env "${common[@]}" bash "$ROOT/test/stress/noregress.sh"
}

say "container=$CONTAINER remote=$REMOTE suites='$SUITES' stress=$DO_STRESS"
prepare_fixtures
sync_tree
sync_fixtures
ensure_cargo_inputs
build_and_test
check_credential_leak
run_stress
say "PASS"
