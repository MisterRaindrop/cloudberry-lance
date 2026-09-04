# Testing lance_fdw: the gate, the container, and the stress scripts

This is the operational half of the README's "Testing" section: what the test
environment has to contain, what each check is worth, and what to record when
running the parts that a gate cannot run.

## The shape of it

Nothing here runs on a developer's machine alone. The wrapper links against a
Cloudberry server and needs a cluster with more than one segment to be worth
testing at all, so the test environment is a container (`cbdb-repro-1850` by
default) holding a three-segment demo cluster, coordinator on port 7000 and
segments on 7002-7004.

This repository is *not* mounted into that container. Everything that has to
run in there therefore travels the same way: a host-side script tars or pipes it
in over `docker exec -i ... bash -l -s`, with credentials arriving on stdin so
that they show up in neither machine's process list. `test/gate/gate.sh` does
that for the build and the suites; `test/stress/common.sh` does it for the
stress scripts.

Three kinds of check, in order of how much they prove:

| Check | Where | Proves |
|---|---|---|
| `make check-syntax`, `make check-scripts` | any host | that the C sources parse against the server headers and the shell scripts parse. Nothing else — no cluster is involved. |
| `make installcheck` through `test/gate/gate.sh` | the container | every suite in `test/regress/`: DDL, import, scanning, parallelism, snapshots, EXPLAIN, credentials, types, and every error message. This is the gate. |
| `test/stress/*.sh` | the container | the invariants that only show up under repetition: cancellation (AC7), the error path not leaking (AC7), and installing the extension changing nothing else (AC10). Run by hand, recorded by hand. |

## What the container needs before the gate can run

A Cloudberry installation as built from source is not enough to run a PGXS
extension's `make installcheck`. What follows had to be added to the test
container, all of it taken from the Cloudberry source tree that is mounted there
at `/opt/cloudberry` (same prefix, same configure options — anything else and
the results would not be comparable):

- **`pg_config` and `psql` are not on `PATH`,** not even in the login shell of
  the user that owns the cluster. Every script that runs `make` or `psql` in the
  container sources `/usr/local/cloudberry-db/greenplum_path.sh` first.
- **Four files missing from the installed PGXS tree**, copied from
  `/opt/cloudberry/src/`: `lib/postgresql/pgxs/src/Makefile.global`,
  `Makefile.shlib`, `Makefile.port` and `nls-global.mk`.
- **`pg_regress` is not installed.** It was built from
  `/opt/cloudberry/src/test/regress/{pg_regress.c,pg_regress_main.c}` against
  the installed `libpgcommon.a` and `libpgport.a` and put, together with the
  Perl helpers next to it (`gpdiff.pl`, `atmsort.pm`, `explain.pm`, ...) and
  `scan_flaky_fault_injectors.sh`, into
  `lib/postgresql/pgxs/src/test/regress/`.
- **Four extensions the harness assumes.** Cloudberry's `pgxs.mk` adds
  `--load-extension=gp_inject_fault` to `installcheck` (because the server was
  configured with `--enable-debug-extensions`), and its `pg_regress`
  unconditionally creates `gp_toolkit` and `pageinspect` in the test database.
  So `gpcontrib/gp_inject_fault`, `gpcontrib/gp_toolkit`,
  `gpcontrib/gp_internal_tools` (`gp_toolkit` needs its
  `gp_session_state_memory_stats.so`) and `contrib/pageinspect` were installed
  with `make USE_PGXS=1`.

Two harmless things it will say every run: `gpdiff.pl` prints `Duplicate
specification "verbose|Verbose"` under perl 5.40, and `pg_regress` reports
*"Optimizer disabled. Using planner answer files"* — which is also the honest
statement that only the PostgreSQL planner is covered here.

### cargo, and why the build configuration is generated

The container cannot fetch the build's inputs at any usable speed: crates.io
comes in at ~58 KB/s and GitHub at ~30 KB/s from there, while `rsproxy.cn`
manages 2.2 MB/s. `gate.sh` therefore generates
`third_party/lance-c/.cargo/config.toml` **inside the container** — it is a
property of the machine you build on and is deliberately not in the repository —
which replaces the crates.io source with an rsproxy sparse registry and
`[patch]`es the 21 Lance crates lance-c takes from git to a source tree the host
downloads and streams in (`/home/gpadmin/lance-src/lance-<rev>`).

The compiler also has to be the toolchain one: `PATH=/usr/local/toolchain/bin`,
`CC`/`CXX` pointing there. The system gcc 4.8.5 cannot build PG16 code.

## Running the gate

```sh
bash test/gate/gate.sh                    # everything
bash test/gate/gate.sh --suite scan_core  # one suite, behind install
bash test/gate/gate.sh --clean            # make clean + cargo clean first
bash test/gate/gate.sh --no-sync          # reuse what is in the container
bash test/gate/gate.sh --no-fixtures      # skip fixture generation and upload
bash test/gate/gate.sh --stress           # and dry-run the stress scripts
bash test/gate/reset.sh                   # drop schema lance_regress, re-upload
```

Timings to expect, on 16 cores:

| Step | Cost |
|---|---|
| lance-c from a cold `target/` | ~16 minutes; `--clean` pays this every time |
| the 13 pg_regress suites | ~45 seconds |
| the two unreachable-endpoint cases inside that, in `errors_ddl` and `errors_scan` | ~10 seconds each, spent in the object store's retry backoff |

With a warm `target/` the rest of a round is the tar, the extension's own
objects, `make install` and the log grep, so a whole round is minutes rather
than the quarter of an hour a cold build costs. `--clean` is only for a change
to the build system itself: the extension's objects are rebuilt every round in
any case, since the run that checks the `LANCE_C_PREFIX` override (AC1) cleans
before and after itself.

`gate.sh` also greps the coordinator and segment logs for the fake secret the
`creds` suite puts in a user mapping (AC8). The only line allowed to contain it
is the `CREATE USER MAPPING` statement, which the server logs verbatim like any
other DDL.

The fixtures come from `test/fixtures/gen_fixtures.py`, run on the host in the
virtualenv (pylance cannot be installed in the container: its wheels are
cp310+). `gate.sh` generates them if `test/fixtures/data` is missing, uploads
them to MinIO, and streams them into the container. The `big` fixture is opt-in:

```sh
make -C test/fixtures gen GEN_FLAGS=--with-big          # ~1.5 GB, not deterministic
make -C test/fixtures upload UPLOAD_FLAGS="--datasets big"
```

## The stress scripts

They are not in the gate. Their subject is what happens after fifty
cancellations or a thousand errors, which takes minutes to hours and is
non-deterministic; a gate that ran them would be slow and flaky, and a gate that
ran two rounds of them would be claiming to have proved something it had not.
So `gate.sh --stress` dry-runs them to catch a script that has stopped working,
and the real runs are done by hand and their numbers written down.

All three take `--help`, work in a database of their own (`lance_stress`, created
if it is not there and dropped again if they created it), keep their objects in
schema `lance_regress`, and clean up after themselves on the error paths too.

### cancel_loop.sh — AC7, cancellation

```sh
bash test/stress/cancel_loop.sh --rounds 50 --dataset big
```

Fifty rounds, one session, one backend. Odd rounds are interrupted by
`statement_timeout`, even rounds by `pg_cancel_backend()` from another
connection. The scan is `sum(pg_column_size(t))` over the whole table, because a
whole-row reference is what makes the wrapper read every column.

How long a scan runs before being interrupted is calibrated: the script times
one uninterrupted scan and then interrupts halfway into it, or, if that scan
outlives `--calibration-deadline`, cancels it and interrupts 2 s into each round
instead. That is what lets the same script run against the 1.5 GB `big` fixture
and against a 1 MiB one.

What it asserts, and what to record:

- every round comes back inside `--deadline` (60 s) with a cancellation error.
  A round that finishes before the interrupt reaches it is counted separately
  and reported; `--min-interrupted-pct` (80 by default) is the share that has to
  have been really interrupted;
- the same session then answers a `count(*)`, and `mpp_execute 'all segments'`
  and `'coordinator'` agree on the answer (I11);
- every thread of that backend besides the main one blocks SIGHUP, SIGINT,
  SIGQUIT, SIGUSR1, SIGUSR2, SIGPIPE, SIGALRM, SIGTERM and SIGCHLD (I5). The
  masks are read from `/proc/<pid>/task/*/status`. Linux refuses to mask
  SIGKILL and SIGSTOP and glibc keeps two realtime signals for itself, so the
  mask is not all ones and the check is for the signals a backend is actually
  driven by. Fewer than `--min-threads` non-main threads fails the check rather
  than passing it: with no threads there is nothing to prove;
- no core file appeared under the data directories or `/home/gpadmin`, and
  `gp_segment_configuration` plus `pg_isready` still show four live processes;
- the interrupt-to-error distribution (min/median/max, in ms) is printed. It has
  no threshold — Design sets none — but it is the number to write down, because
  it is how long a batch boundary is away when the object store is slow.

### leak_loop.sh — AC7, the error path

```sh
bash test/stress/leak_loop.sh --rounds 1000
```

Three failing statements per round in one session: a uri that is not there
(fails on the coordinator), an S3 dataset with wrong credentials (same, through
the object store), and a B-tier column (fails on the segments, after the
coordinator has opened the dataset and listed its fragments). A bad *endpoint*
is deliberately not among them — object_store retries a refused connection for
about ten seconds, which would turn a thousand rounds into hours — and wrong
credentials against a reachable endpoint fail at once down the same path.

Every `--sample-every` rounds the backend is read out of `/proc`: descriptor
count, `VmRSS`, thread count, and how many QE processes the session has. The
first sample is taken after a warm-up round, so that lance-c's own startup is
not counted as growth, and it is first-against-last that decides:

- descriptors may grow by at most `--max-fd-growth` (2 — an error tears down the
  gang and the next statement builds a new one, so the count wobbles);
- resident memory by less than `--max-rss-growth-mb` (32 MiB);
- and the number of errors has to equal rounds times kinds. A statement that
  stopped failing would otherwise make the loop pass by doing nothing.

Thread and QE counts are printed as observations, not asserted: tokio grows and
retires blocking threads by design, and a torn-down gang is rebuilt on demand.
A count that climbed *with the round number* would still be a finding.

Record the first and last sample and the curve between them.

### noregress.sh — AC10

```sh
bash test/stress/noregress.sh
```

One fixed SQL script that never mentions Lance — two distributed heap tables, an
insert, a join across segments, an aggregate, a per-segment count, a read from a
`gp_exttable_fdw` external web table, and an `EXPLAIN (COSTS OFF)` — run three
times in the same database: with `lance_fdw` absent (`DROP EXTENSION IF EXISTS
... CASCADE`), with it installed, and with it installed *and* this session's
backend and its segments having run a Lance scan, so that lance-c and its
threads are loaded underneath the queries being compared.

The three outputs are compared byte for byte, stdout and stderr separately (a
merged stream can interleave differently between runs). Any difference fails:
it would mean the wrapper changes the behaviour of a query that never mentions
it, which I10 forbids.

Two details worth knowing before changing the script: all three runs read the
same `fixed.sql` from the same path, because psql prints the script name and
line number in front of every message; and each run has to show the external
table's row before it counts, since two empty outputs also compare equal.

## What none of this covers

- **Line coverage.** There is no C coverage in this setup: the container's gcc
  has gcov, but collecting it across PGXS and multiple QE processes was not
  built. That changed lines were executed is argued from the suites, not
  measured.
- **ORCA.** The test cluster is `--disable-orca`. Everything here is the
  PostgreSQL planner.
- **A panic inside lance-c.** It is compiled `panic = "abort"`, and we could not
  construct a panic to watch it happen.
- **Mutation testing.** There is no tool for it here. The stand-in is that every
  suite ran red before the code that makes it green existed, and that the stress
  scripts fail rather than pass when their subject is absent (too few threads,
  too few errors, no output to compare).
