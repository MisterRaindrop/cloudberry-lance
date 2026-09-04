# test/stress/noregress.remote.sh - the container half; see noregress.sh.
#
# Streamed in behind remote_common.sh, with DB, KEEP_DB and KEEP_OUTPUT set by
# the prelude.  Nothing here reads stdin: stdin is this script.
#
# The three runs have to differ in nothing but the state of the extension, so
# they all read the same fixed.sql from the same path: psql puts the script name
# and line number in front of every message it prints, and a different path
# would be a difference all by itself.

MARKER=LANCE_NOREGRESS_BEGIN
WEB_ROW=lance-fdw-noregress-row
WORK=
DID_SETUP=no
FAILURES=0

teardown() {
	psql_run "$DB" <<SQL || true
DROP SERVER IF EXISTS lance_noregress CASCADE;
DROP SCHEMA IF EXISTS lance_regress CASCADE;
SQL
	if [ "$CREATED_DB" = yes ] && [ "$KEEP_DB" != yes ]; then
		drop_db "$DB" || true
	fi
}

cleanup() {
	local rc=$?
	trap - EXIT
	if [ "$DID_SETUP" = yes ]; then
		say "cleaning up"
		teardown
	fi
	if [ -n "$WORK" ]; then
		if [ "$KEEP_OUTPUT" = yes ]; then
			say "the captured output is left in the container, under $WORK"
		else
			rm -rf "$WORK"
		fi
	fi
	exit "$rc"
}
trap cleanup EXIT

write_scripts() {
	# The control script.  Deliberately boring: every statement is ordered,
	# every number exact, EXPLAIN is COSTS OFF, and nothing in it mentions
	# lance_fdw.
	cat >"$WORK/fixed.sql" <<'SQL'
\pset format unaligned
SET search_path = lance_regress, public;
CREATE TABLE nr_customers (id int, region text) DISTRIBUTED BY (id);
CREATE TABLE nr_orders (id int, customer_id int, amount numeric(10,2)) DISTRIBUTED BY (id);
INSERT INTO nr_customers SELECT g, 'r' || (g % 4) FROM generate_series(1, 40) g;
INSERT INTO nr_orders SELECT g, 1 + (g % 40), ((g * 7) % 991)::numeric / 100
  FROM generate_series(1, 400) g;
ANALYZE nr_customers;
ANALYZE nr_orders;
SELECT count(*) AS orders, count(DISTINCT customer_id) AS customers, sum(amount) AS total
  FROM nr_orders;
-- The join key is the distribution key on neither side, so the rows have to
-- move between segments for this one.
SELECT c.region, count(*) AS orders, round(sum(o.amount), 2) AS total
  FROM nr_orders o JOIN nr_customers c ON c.id = o.customer_id
  GROUP BY c.region ORDER BY c.region;
-- Which segment holds what, which is the distribution itself.
SELECT gp_execution_segment() AS seg, count(*) FROM nr_orders GROUP BY 1 ORDER BY 1;
-- The other foreign-data wrapper in this cluster.
CREATE READABLE EXTERNAL WEB TABLE nr_web (line text)
  EXECUTE 'echo lance-fdw-noregress-row' ON COORDINATOR FORMAT 'TEXT';
SELECT line FROM nr_web;
EXPLAIN (COSTS OFF)
SELECT c.region, count(*) FROM nr_orders o JOIN nr_customers c ON c.id = o.customer_id
  GROUP BY c.region;
SQL

	# The three preludes.  Their own output is not compared, so they keep
	# quiet - and they put client_min_messages back before the control script
	# runs, because that setting is part of what its output looks like.
	cat >"$WORK/pre_absent.sql" <<'SQL'
SET client_min_messages = warning;
DROP SERVER IF EXISTS lance_noregress CASCADE;
DROP EXTENSION IF EXISTS lance_fdw CASCADE;
DROP SCHEMA IF EXISTS lance_regress CASCADE;
CREATE SCHEMA lance_regress;
RESET client_min_messages;
SQL

	cat >"$WORK/pre_installed.sql" <<'SQL'
SET client_min_messages = warning;
DROP SERVER IF EXISTS lance_noregress CASCADE;
DROP SCHEMA IF EXISTS lance_regress CASCADE;
CREATE SCHEMA lance_regress;
CREATE EXTENSION IF NOT EXISTS lance_fdw;
RESET client_min_messages;
SQL

	# The third state runs in the same session as the control script, so its
	# output has to be separable from it: the scan's rows go to a file of their
	# own and the two markers say where the compared part starts.
	cat >"$WORK/pre_scanned.sql" <<SQL
SET client_min_messages = warning;
DROP SERVER IF EXISTS lance_noregress CASCADE;
DROP SCHEMA IF EXISTS lance_regress CASCADE;
CREATE SCHEMA lance_regress;
CREATE EXTENSION IF NOT EXISTS lance_fdw;
CREATE SERVER lance_noregress FOREIGN DATA WRAPPER lance_fdw
  OPTIONS (base_uri '$FIXTURE_DIR');
CREATE FOREIGN TABLE lance_regress.nr_lance (id integer, v text, n bigint)
  SERVER lance_noregress OPTIONS (uri 'frag_3.lance');
\\o $WORK/warmup.out
SELECT count(*) AS rows, sum(n) AS sum_n FROM lance_regress.nr_lance;
\\o
RESET client_min_messages;
\\echo $MARKER
\\warn $MARKER
SQL
}

setup() {
	[ -d "$FIXTURE_DIR/frag_3.lance" ] ||
		die "$FIXTURE_DIR/frag_3.lance is missing; run test/gate/gate.sh to sync the fixtures"

	ensure_db "$DB"
	DID_SETUP=yes

	# External web tables need gp_exttable_fdw.  initdb normally leaves it in
	# template1, so a new database has it; making sure of it here keeps it out
	# of the compared runs either way.
	if [ "$(psql_val "$DB" <<'SQL'
SELECT count(*) FROM pg_foreign_data_wrapper WHERE fdwname = 'gp_exttable_fdw';
SQL
	)" = 0 ]; then
		say "installing gp_exttable_fdw in $DB"
		if ! psql_run "$DB" <<'SQL'
CREATE EXTENSION gp_exttable_fdw;
SQL
		then
			die "external web tables need gp_exttable_fdw, which $DB does not have and cannot install"
		fi
	fi
}

cut_after() {
	grep -q "^$MARKER\$" "$1" || die "the $MARKER marker never reached $1"
	sed -n "/^$MARKER\$/,\$p" "$1" | tail -n +2
}

# Runs the control script once, in the state its prelude puts the database in.
run_state() {
	local label=$1 pre=$2 rc=0

	say "running the control script with lance_fdw $label"
	if [ "$label" = scanned ]; then
		psql -p "$PGPORT" -d "$DB" -qX -v ON_ERROR_STOP=1 \
			-f "$pre" -f "$WORK/fixed.sql" \
			>"$WORK/raw.out" 2>"$WORK/raw.err" </dev/null || rc=$?
		if [ "$rc" != 0 ]; then
			sed 's/^/    /' "$WORK/raw.err"
			die "the $label run failed (psql exit $rc)"
		fi
		cut_after "$WORK/raw.out" >"$WORK/out.$label"
		cut_after "$WORK/raw.err" >"$WORK/err.$label"
		[ -s "$WORK/warmup.out" ] || die "the Lance scan in the $label prelude returned nothing"
		say "  the warm-up scan read: $(tr '\n' ' ' <"$WORK/warmup.out")"
	else
		psql -p "$PGPORT" -d "$DB" -qX -v ON_ERROR_STOP=1 -f "$pre" \
			>/dev/null 2>"$WORK/pre.err" </dev/null || rc=$?
		if [ "$rc" != 0 ]; then
			sed 's/^/    /' "$WORK/pre.err"
			die "the $label prelude failed (psql exit $rc)"
		fi
		psql -p "$PGPORT" -d "$DB" -qX -v ON_ERROR_STOP=1 -f "$WORK/fixed.sql" \
			>"$WORK/out.$label" 2>"$WORK/err.$label" </dev/null || rc=$?
		if [ "$rc" != 0 ]; then
			sed 's/^/    /' "$WORK/err.$label"
			die "the $label run failed (psql exit $rc)"
		fi
	fi

	# A run that produced nothing would compare equal to another one that
	# produced nothing, so check there is something to compare.
	grep -q "^$WEB_ROW\$" "$WORK/out.$label" ||
		die "the $label run did not read the external web table"
	say "  $(wc -l <"$WORK/out.$label") lines of output, $(wc -l <"$WORK/err.$label") of messages"
}

compare() {
	local a=$1 b=$2 stream
	for stream in out err; do
		if cmp -s "$WORK/$stream.$a" "$WORK/$stream.$b"; then
			continue
		fi
		say "$stream differs between '$a' and '$b':"
		diff -u "$WORK/$stream.$a" "$WORK/$stream.$b" | head -40 | sed 's/^/    /'
		FAILURES=$(( FAILURES + 1 ))
	done
}

# ---------------------------------------------------------------------------

WORK=$(mktemp -d /tmp/lance_noregress.XXXXXX)
setup
write_scripts

run_state absent "$WORK/pre_absent.sql"
run_state installed "$WORK/pre_installed.sql"
run_state scanned "$WORK/pre_scanned.sql"

# Byte equality is transitive, so these two comparisons cover all three states.
compare absent installed
compare installed scanned

if [ "$FAILURES" != 0 ]; then
	say "FAIL: the control script does not behave the same in all three states"
	exit 1
fi
say "PASS: absent, installed and scanned are byte for byte the same, out and err"
