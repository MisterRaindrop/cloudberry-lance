# lance_fdw

A foreign-data wrapper that lets [Apache Cloudberry](https://cloudberry.apache.org/)
read [Lance](https://lancedb.github.io/lance/) datasets in place — no COPY, no
Python in the middle — with the scan running in parallel on every segment.

The wrapper is read-only. It talks to Lance through
[lance-c](https://github.com/lance-format/lance-c), the official C binding, and
decodes the Arrow batches it returns with a vendored copy of
[nanoarrow](https://github.com/apache/arrow-nanoarrow).

**State of this build: the MPP scan, over every A-tier type.** Servers, user
mappings, foreign tables, `IMPORT FOREIGN SCHEMA` and `SELECT` all work, the
scan runs on every segment, and the value converters cover the whole A-tier
list — booleans, the integer family, the three float widths, the string and
binary families, `date32`, `timestamp` in all four units with and without a
zone, `decimal128`, `fixed_size_list<float>` embeddings, one-dimensional
`list`s, `struct`s as composite types that the import creates, and
`map<utf8, ...>` as `jsonb`. Everything else is refused by name rather than
guessed at; see [Types](#types).

## Building

Prerequisites, in addition to a Cloudberry installation and its `pg_config`:

| What | Why | Note |
|---|---|---|
| Rust >= 1.91.0 | lance-c pins `rust-version = "1.91.0"` | `rustup toolchain install 1.91.0` |
| protoc | the Lance crates compile protobuf definitions | 3.x, 24.3 is known to work |
| A C toolchain that built your server | the extension links into the backend | on CentOS 7 the system gcc 4.8.5 is too old; use the same compiler `pg_config --cc` reports |
| Network access to a crates registry | the first build downloads a few hundred crates | see "Offline and slow networks" below |
| glibc >= 2.16 | what the built `liblance_c.so` requires | the prebuilt lance-c releases need 2.39 and cannot be used on CentOS 7 |

Then:

```sh
source /usr/local/cloudberry-db/greenplum_path.sh   # puts pg_config on PATH
git submodule update --init                         # third_party/lance-c, at v0.1.9
make
make install
psql -c 'CREATE EXTENSION lance_fdw'
```

A Cloudberry installation does not put `pg_config` on anyone's `PATH` — not even
in the login shell of the user that runs the cluster — so either source the
environment file the server ships, as above, or build with
`make PG_CONFIG=/usr/local/cloudberry-db/bin/pg_config`.

`make` builds `third_party/lance-c` with cargo (about 16 minutes on 16 cores
from cold, seconds afterwards) and links `lance_fdw.so` against it. `make
install` puts a stripped `liblance_c.so` next to `lance_fdw.so` in `$(pg_config
--pkglibdir)`, and `lance_fdw.so` carries an rpath pointing there, so nothing
has to be added to `ld.so.conf`. Expect about 230 MiB after stripping (305 MB
before): lance-c statically links the whole Lance Rust stack.

To use a lance-c that already exists instead of building the submodule:

```sh
make LANCE_C_PREFIX=/opt/lance-c              # expects include/ and lib/
make LANCE_C_INCDIR=... LANCE_C_LIBDIR=...    # name the two directories
make USE_PKGCONFIG_LANCE_C=1                  # ask pkg-config for lance-c
```

In every one of those cases nothing is installed for lance-c and the rpath
points at the library where it already lives. Naming only `LANCE_C_INCDIR`
leaves `LANCE_C_LIBDIR` pointing into the submodule's build directory, and the
rpath then points there too, so pass both or use `LANCE_C_PREFIX`.

Other targets:

| Target | What it does |
|---|---|
| `make check-syntax` | `gcc -fsyntax-only` over `src/*.c`; needs no server installation, only a configured source tree in `PG_INCLUDE_DIR` (default `/opt/cloudberry/src/include`) |
| `make check-scripts` | `bash -n` over `test/gate/*.sh` and `test/stress/*.sh` |
| `make installcheck` | the pg_regress suites; see "Testing" |
| `make clean-lance-c` | `cargo clean` in the submodule; deliberately not part of `make clean` |

### Offline and slow networks

The cargo build needs crates.io and, for the Lance crates lance-c takes from
git, GitHub. Where those are slow or blocked, put a `.cargo/config.toml` in
`third_party/lance-c/` that replaces the registry and points the git
dependencies at a local source tree — `test/gate/gate.sh` generates exactly
such a file for the test container, and its `write_cargo_config` function is
the worked example. That file is not part of the repository: it is a property
of the machine you build on.

## Using it

```sql
CREATE SERVER lance_local FOREIGN DATA WRAPPER lance_fdw
  OPTIONS (base_uri '/data/lance');

IMPORT FOREIGN SCHEMA lance LIMIT TO ("events.lance")
  FROM SERVER lance_local INTO public;

SELECT count(*) FROM public."events.lance";
```

Over S3 (or MinIO, or anything S3-compatible):

```sql
CREATE SERVER lance_s3 FOREIGN DATA WRAPPER lance_fdw
  OPTIONS (base_uri 's3://my-bucket/datasets',
           aws_endpoint 'http://minio.internal:9000',
           aws_region 'us-east-1',
           allow_http 'true');

CREATE USER MAPPING FOR CURRENT_USER SERVER lance_s3
  OPTIONS (aws_access_key_id '...', aws_secret_access_key '...');
```

MinIO needs both a region and an endpoint, and `allow_http` unless the endpoint
is HTTPS.

### How a scan runs

A Lance dataset is a set of *fragments*, and a fragment is the unit of
parallelism. Under the default `mpp_execute 'all segments'`:

- the coordinator opens the dataset once, pins the version it finds, lists the
  fragment ids and puts uri, version, ids and the planned segment count into
  the plan it dispatches. It reads no data itself;
- every segment takes its own share of that list — fragment `i` belongs to
  segment `(i + session_id % N + command_count) % N` — and opens the dataset at
  the version the coordinator pinned. The shares are disjoint and together
  complete, and no segment has to talk to any other to know that;
- `N` is that planned segment count, not the size of the cluster: a foreign
  table or its server may set `num_segments`, and Cloudberry then runs the scan
  on that many segments only, so the split has to use the same number. A
  `num_segments` larger than the cluster is refused, because such a gang
  repeats a segment and the two copies cannot tell themselves apart;
- a segment whose share is empty opens nothing at all, which is what a dataset
  with fewer fragments than segments costs.

Pinning the version is what makes one statement see one snapshot even while the
dataset is being appended to. Two statements are two snapshots: this is
statement-level, not transaction-level, unless the table names a `version`.

Only the columns a query refers to are read, including columns that appear only
in a `WHERE` clause — the wrapper pushes no filter down, so the qualifier is
evaluated by PostgreSQL but the column still has to arrive. A `count(*)` refers
to no column and reads none; it counts the rows Lance reports per batch.

`EXPLAIN` adds the resolved uri and the version to the plan, and `EXPLAIN
ANALYZE` adds the fragment count, since by then the coordinator has looked:

```
 Gather Motion 3:1  (slice1; segments: 3)
   ->  Foreign Scan on events
         Lance URI: s3://my-bucket/datasets/events.lance
         Lance Version: latest
         Lance Fragments: 12
```

A plain `EXPLAIN` opens nothing, so it costs no round trip to the object store
and works even against a server whose credentials are wrong.

### Options

**Foreign data wrapper**

| Option | Meaning |
|---|---|
| `mpp_execute` | `all segments` (the default the extension installs), `coordinator` or `any`; `master` is accepted as an older spelling of `coordinator`. Under `all segments` the coordinator enumerates fragments and each segment reads its own share; the other two make one process read everything. |

**Server**

| Option | Meaning |
|---|---|
| `base_uri` | Prefix that relative dataset names resolve against. Optional: a table may give an absolute uri instead. |
| `aws_endpoint` | Object store endpoint, for S3-compatible services. |
| `aws_region` | Region to sign with. |
| `allow_http` | Boolean; allow a plain-HTTP endpoint. |
| `virtual_hosted_style_request` | Boolean; use virtual-hosted-style addressing instead of path style. |
| `mpp_execute` | Overrides the wrapper's setting. |

**User mapping**

| Option | Meaning |
|---|---|
| `aws_access_key_id` | The access key identifier to sign requests with. |
| `aws_secret_access_key` | The secret half of that key pair. |
| `aws_session_token` | For temporary credentials. |

Credentials are read from the user mapping in whichever process needs them.
`lance_fdw` never puts them into a plan, an `EXPLAIN`, its own log lines or its
error messages. The one place they do appear is the `CREATE USER MAPPING`
statement itself, which PostgreSQL echoes into the server log like any other
DDL when `log_statement` is `ddl` or `all`. No wrapper can prevent that, and
the gate's credential check allows exactly that one line and nothing else.

**Foreign table**

| Option | Meaning |
|---|---|
| `uri` | Required. Either absolute (`s3://...`, `file:///...`, `/abs/path`) or relative to the server's `base_uri`. |
| `version` | Dataset version to read. `0`, the default, means the latest at the time the statement runs. |
| `batch_size` | Rows per Arrow batch. Unset means lance-c decides, which is 8192 rows unless its own `LANCE_DEFAULT_BATCH_SIZE` says otherwise. Lower it for datasets with large binary columns. |
| `rows_hint` | Row estimate for the planner. Default 100000. Planning does no I/O, so this is the only way the planner can know better. |
| `mpp_execute` | Overrides the server's setting. |
| `num_segments` | Read by Cloudberry rather than by this wrapper, and it matters only under `mpp_execute 'all segments'`: there it narrows how many segments run the scan, the fragment split follows it, and a value above the number of segments in the cluster is refused, because such a gang repeats a segment and the two copies cannot be told apart. Under `coordinator` or `any` it has no effect and nothing is refused — one process reads every fragment, so there is no split to narrow. |

**Column**

| Option | Meaning |
|---|---|
| `column_name` | The Lance column this PostgreSQL column reads, when the two names differ. |

### GUCs

| Name | Default | Meaning |
|---|---|---|
| `lance_fdw.cpu_threads` | 0 | `LANCE_CPU_THREADS` for the Lance runtime; 0 leaves it at its own default, which scales with the core count. |
| `lance_fdw.io_threads` | 0 | `LANCE_IO_THREADS`; same. |
| `lance_fdw.index_cache_size_mb` | 64 | Per-backend Lance index cache. lance's own default is 6 GiB, which is far too much for one cache per backend. |
| `lance_fdw.metadata_cache_size_mb` | 32 | Per-backend Lance metadata cache. lance's own default is 1 GiB. |

All four are `SUSET` and are read once per backend, before its first call into
lance-c, so changing them mid-session has no effect on that session.

### Deploying

**Threads.** A backend that opens a dataset grows to roughly 18 threads, and to
about 34 once it scans — measured on 16 cores. The count follows the core count
rather than the number of datasets, and it then stays put. One query on a
three-segment cluster pays it four times over: the coordinator opens the dataset
to list its fragments, and each of the three segments scans. With many
concurrent sessions this is the first thing to run out of, so set
`lance_fdw.cpu_threads` and `lance_fdw.io_threads` to something small (2 and 4,
say) if concurrency matters more to you than the throughput of one query.

**Caches.** `index_cache_size_mb` and `metadata_cache_size_mb` are per-backend
ceilings, not reservations: a backend grows into them as it reads manifests, and
100 sessions can hold 100 of them. That is why the defaults are 64 and 32 MiB
against lance's own 6 GiB and 1 GiB — one cache per backend is a different
proposition from one cache per process. This block never asks Lance for an
index, so the index cache has almost nothing to hold yet; the GUC is there for
when it does.

**Batches.** `batch_size` is in rows, and lance-c exposes no byte budget, so a
dataset with MiB-sized `binary` or `large_binary` values needs the row count
lowered by hand: the default of 8192 rows times a 1 MiB value is 8 GiB in
flight. A few dozen rows is a reasonable starting point for blob-like columns.

**Row estimates.** Planning does no I/O, so the planner starts from 100000 rows
for every Lance table. Where that is wrong enough to pick the wrong join order,
set `rows_hint` on the table.

### Types

`IMPORT FOREIGN SCHEMA` writes these; a hand-written foreign table may also
declare a wider type of the same family (an Arrow `int32` may be read into
`bigint`, for instance). "Readable" is whether this build can produce values
for the column — the rest import and plan, but refuse at scan time with a
message naming the column, the Arrow type and the declared type.

| Arrow | PostgreSQL | Readable |
|---|---|---|
| `bool` | `boolean` | yes |
| `int8`, `int16`, `uint8` | `smallint` | yes |
| `int32`, `uint16` | `integer` | yes |
| `int64`, `uint32` | `bigint` | yes |
| `float16`, `float32` | `real` | yes |
| `float64` | `double precision` | yes |
| `utf8`, `large_utf8` | `text` | yes |
| `binary`, `large_binary` | `bytea` | yes |
| `date32` | `date` | yes |
| `timestamp(s\|ms\|us\|ns)` without a zone | `timestamp(6)` | yes |
| `timestamp(s\|ms\|us\|ns)` with a zone | `timestamptz(6)` — the value is a UTC epoch and the zone name is not kept | yes |
| `decimal128(p,s)` | `numeric(p,s)` | yes |
| `fixed_size_list<float32, N>` | `real[]` | yes |
| `fixed_size_list<float64, N>` | `double precision[]` | yes |
| `list<T>` where T is anything below a list | that type's one-dimensional array | yes |
| `struct<...>` where every subfield is readable | a composite type `IMPORT FOREIGN SCHEMA` creates, named `lance_<table>_<field path>` | yes |
| `map<utf8\|large_utf8, T>` where T is a scalar above | `jsonb` | yes |

Widening is allowed only where it cannot lose anything, and a declaration that
would cost information is refused at the start of the scan rather than turned
into a wrong value. Four rules follow from that:

- **No narrowing.** `int32` into `bigint` yes, `int64` into `integer` no;
  `uint32` needs `bigint` for the same reason, `float64` does not fit `real`,
  and a length-limited `varchar(n)` is refused because enforcing the limit
  would mean truncating. A list gets these rules on its element, so
  `list<int64>` is `bigint[]` and not `integer[]`.
- **No loss of precision.** A `timestamp` column has to be able to hold
  microseconds, so `timestamp(6)` and a bare `timestamp` are accepted and
  `timestamp(3)` is not. A `decimal128(p,s)` needs a `numeric(P,S)` with
  `S >= s` and `P - S >= p - s`, or a plain `numeric`, which constrains
  nothing.
- **No crossing between the two timestamp types.** A zone on the Arrow type
  means `timestamptz` and no zone means `timestamp`; reading either as the
  other would reinterpret the instant, so both crossings are errors.
- **No rounding of nanoseconds.** PostgreSQL keeps microseconds, so a
  nanosecond value that is not a whole microsecond is an error on that value
  rather than a rounded result. A value outside PostgreSQL's date or timestamp
  range is an error for the same reason.

The two nested shapes have a rule each on top of those:

- **A struct is read as a whole or not at all.** Every subfield has to be
  readable, recursively; one B-tier subfield makes the whole column B-tier, and
  the message names it. There is no partial projection, because a composite
  value with fields missing for reasons the user cannot see is worse than a
  refusal. `IMPORT FOREIGN SCHEMA` creates one composite type per struct and
  one more per level of nesting, named `lance_<table>_<field path>` in lower
  case with everything outside `[a-z0-9_]` replaced by `_`; a nested struct's
  path is `<parent path>_<subfield>`, and a list of structs uses the column's
  own path. A name that is already taken is reused when the type is field for
  field the same and is an error when it is not.
- **A map is read as `jsonb`, and only with string keys.** A JSON object has no
  other kind of key, so `map<int32, ...>` is refused rather than printed into
  one, and a map whose values are themselves containers is refused rather than
  flattened. An absent key, a key whose value is JSON `null` and an empty map
  are three different things and stay that way.

Everything else is B-tier: `uint64`, `dictionary`, `duration` and the interval
types, `time32`/`time64`, `date64`, `decimal256`, `large_list`, lists of lists,
`fixed_size_binary`, the view types, unions — and any field carrying Lance's
`lance-encoding: blob` metadata, whatever its Arrow type says, because the
scanner returns a `struct{position, size}` descriptor for those rather than the
bytes. A Lance Blob v2 column is refused by a rule of its own for the same
reason: what a scan returns for it is a descriptor of offsets, not the payload,
and it is a struct of ordinary scalars that would otherwise be read as one.

B-tier is loud, never silent: `IMPORT FOREIGN SCHEMA` skips the column and says
so with a `NOTICE`, and referring to one from a hand-written foreign table is
an error. A dataset with no A-tier column at all cannot be imported.

`IMPORT FOREIGN SCHEMA` requires `LIMIT TO`. Lance has no catalog that lists
the datasets under a uri, and listing an S3 prefix by hand would be a second
dependency; naming the datasets is the honest version of that.

## Testing

`test/fixtures/` generates the Lance datasets the suites read, using pylance on
the host; `test/regress/` holds the pg_regress suites; `test/gate/gate.sh`
bridges the two into the Cloudberry container, since the repository is not
mounted there:

```sh
bash test/gate/gate.sh                    # everything
bash test/gate/gate.sh --suite scan_core  # one suite, behind install
bash test/gate/gate.sh --clean            # after a build-system change
bash test/gate/reset.sh                   # drop schema lance_regress, re-upload fixtures
```

The suites, in the order they run:

| Suite | What it covers |
|---|---|
| `install` | the extension's objects, the wrapper's `mpp_execute` default, the GUCs, and the helper functions the other suites use |
| `ddl` | every option accepted and every bad value rejected, `pg_dump` round trip, `DROP EXTENSION CASCADE` |
| `import` | `IMPORT FOREIGN SCHEMA` over `file://` and `s3://`, including the B-tier skips |
| `errors_ddl` | bad path, bucket, credentials and endpoint, seen from `IMPORT` |
| `scan_core` | values against the pylance reference output, deletions, empty and gapped fragment lists, schema evolution, `batch_size`, `count(*)`, joins both ways, `file://` and `s3://` |
| `parallel` | the split is complete and disjoint for 1, 2, 3, 7 and 100 fragments; `coordinator` and `any` agree with `all segments` |
| `snapshot` | version pinning, in both the rows and the fragment count, including a version whose successor deleted rows from existing fragments — the case an append-only history cannot tell apart on the segments |
| `explain` | what `EXPLAIN` and `EXPLAIN ANALYZE` say, and that a plain `EXPLAIN` needs no working credentials |
| `creds` | none of the three user mapping credentials is in a plan; the gate then greps the server logs for all three |
| `errors_scan` | storage failures during a scan, and every shape of type mismatch |
| `types` | all 31 columns of `types_all` against the pylance reference output, twice over at two batch sizes, plus the MiB-sized text and binary values |
| `types_errors` | the four strictness rules above, one case each, and the declarations they must not refuse |
| `types_nested` | the four struct shapes and the map column against the pylance reference output, under both execution modes and at a batch size that straddles a fragment, plus the composite types the import creates and their reuse on a second import |
| `types_nested_errors` | the refusals: a map with non-string keys, a struct with one B-tier subfield, a Blob v2 descriptor under both execution modes, and composite declarations that do not match |
| `sigmask` | I5, read back from `/proc`: after a scan in this backend every lance-c thread blocks the signals a backend is driven by, and the main thread does not |

After the suites, the gate greps the coordinator and segment logs for the three
fake credentials the `creds` suite puts in a user mapping. The only line allowed to
contain it is the `CREATE USER MAPPING` statement itself, which the server logs
verbatim like any other DDL.

The gate needs `test/gate/env.sh` (not in the repository) to export
`LANCE_S3_ENDPOINT_HOST`, `LANCE_S3_ENDPOINT_CONTAINER`, `LANCE_S3_BUCKET`,
`LANCE_S3_REGION`, `LANCE_S3_KEY` and `LANCE_S3_SECRET` for the MinIO the
`s3://` cases use. It also expects a container that can run `make installcheck`
at all, which is more than a bare Cloudberry installation provides —
`docs/testing.md` lists what has to be there and where it comes from.

### Stress and control scripts

`test/stress/` holds three scripts that are not part of the gate, because what
they are about is behaviour under repetition and comparison rather than the
result of one query. Each one is a host-side driver that streams its body into
the container, the same bridge `gate.sh` uses.

| Script | What it asserts |
|---|---|
| `cancel_loop.sh` | An S3 scan interrupted round after round, half by `statement_timeout` and half by `pg_cancel_backend()`, comes back every time inside a deadline; the session then still works, both `mpp_execute` modes agree on the row count, every thread of that backend blocks the signals a backend is driven by, nothing dumped core and the cluster is whole. Prints the interrupt-to-error distribution. |
| `leak_loop.sh` | A thousand rounds of three failing scans in one session leave the backend's descriptor count and resident memory where they started. Prints the whole curve, plus thread and QE-process counts as observations. |
| `noregress.sh` | A fixed SQL script with no Lance in it — distributed tables, a cross-segment join, an external web table through `gp_exttable_fdw`, an `EXPLAIN` — produces byte-identical output with the extension absent, installed, and installed after a scan. |

```sh
bash test/stress/cancel_loop.sh --rounds 50 --dataset big
bash test/stress/leak_loop.sh --rounds 1000
bash test/stress/noregress.sh
bash test/gate/gate.sh --stress          # after the suites, dry-run all three
```

`--help` on any of them lists its options. The `big` fixture the cancellation
loop wants by default is about 1.5 GB and is not generated unless asked for:

```sh
make -C test/fixtures gen GEN_FLAGS=--with-big
make -C test/fixtures upload UPLOAD_FLAGS="--datasets big"
```

`--dataset large_text` runs the same loop against a 1 MiB dataset instead, which
exercises the script rather than the wrapper: a scan that small can finish
before the interrupt reaches it. `gate.sh --stress` uses exactly that, with two
rounds, twenty leak rounds and one `noregress` pass, so that a gate catches a
stress script that has stopped working without pretending to have proved the
invariant. `docs/testing.md` has the rest, including what the numbers mean.

## Known limits

- The A-tier list in the type table above is complete; everything outside it is
  refused rather than guessed at.
- Lance's two blob encodings are both B-tier whatever the Arrow type says, but
  for two different reasons. A field carrying `lance-encoding: blob` metadata
  (Lance's v1 encoding) is a `large_binary` whose bytes **do** arrive with the
  scan — measured on values of 1, 2 and 4 MiB — so refusing it is a policy
  choice this block has not revisited, not a technical limit. A field carrying
  `ARROW:extension:name = lance.blob.v2` reaches the scanner as a five-field
  descriptor struct (`kind`, `position`, `size`, `blob_id`, `blob_uri`) with
  the extension name stripped, and lance-c v0.1.9 exposes no call that turns a
  descriptor back into a payload; it is refused by a rule of its own, which
  since struct columns became readable is what keeps it refused.
- **How a Blob v2 column is recognised on a scan is fragile.** The two schemas
  differ: `lance_dataset_schema()`, which `IMPORT FOREIGN SCHEMA` and the
  coordinator's projection check read, keeps the Arrow extension name, and that
  half of the rule is exact. The scanner's schema does not keep it, so a scan
  can only match the descriptor's five child names — and if Lance renames one
  or adds a sixth, the rule stops matching, in the direction that reads the
  descriptor as an ordinary struct and hands out file offsets as if they were
  data. Whether the stream schema can keep the extension name is open with
  upstream (issue #76). Today the descriptor's `position` child is `uint64`,
  which is B-tier on its own, so the column is refused even if the name match
  fails; that is a property of this version of the descriptor and not something
  to depend on.
- **A composite type created by `IMPORT FOREIGN SCHEMA` outlives the foreign
  table.** Dropping the table does not drop the types made for its struct
  columns — they are ordinary database objects, and PostgreSQL records no
  dependency that would take them with it. Re-importing reuses a type whose
  definition still matches, so the usual cycle leaves no debris; a dataset whose
  struct has changed shape leaves the old type behind, to be dropped by hand.
- The refusal of a nanosecond timestamp that is not a whole microsecond is
  implemented but untested: every timestamp in `test/fixtures` is
  microsecond-aligned, and the fixtures are not this package's to change.
- `IMPORT FOREIGN SCHEMA` requires `LIMIT TO`. Nothing in lance-c lists the
  datasets under a uri, so the names have to come from you.
- Snapshots are statement-level, not transaction-level: two statements in one
  transaction can read two versions of a dataset that is being appended to,
  unless the table names a `version`.
- No filter, limit or vector-search pushdown; every qualifier is evaluated by
  PostgreSQL.
- Rows are decoded one at a time into `Datum`s. Arrow batches are not handed to
  the executor as they are, so a scan is correct rather than fast.
- Fragments are handed to segments round-robin. lance-c exposes no per-fragment
  row count, so a dataset whose fragments differ wildly in size will skew.
- Cancellation takes effect at a batch boundary, so a single slow read from an
  object store delays it by however long that read takes.
- Storage errors can take seconds to arrive: the object store retries a refused
  connection with backoff, so an endpoint nothing listens on takes about ten
  seconds to fail rather than failing at once.
- Only the PostgreSQL planner is covered. The test cluster is built
  `--disable-orca`, so the ORCA path is unverified.
- lance-c is compiled with `panic = "abort"`. An error it catches becomes a
  `lance:` error like any other, but a panic that reaches the runtime takes the
  whole backend down with it — and that path is unverified, because we could not
  construct one.

## Licence

Apache-2.0. See `LICENSE`, and `THIRD_PARTY_LICENSES.md` for lance-c and
nanoarrow.
