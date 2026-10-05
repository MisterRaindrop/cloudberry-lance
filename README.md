# lance_fdw

A foreign-data wrapper that lets [Apache Cloudberry](https://cloudberry.apache.org/)
read [Lance](https://lancedb.github.io/lance/) datasets in place — no COPY, no
Python in the middle — with the scan running in parallel on every segment.

The wrapper is read-only. It talks to Lance through
[lance-c](https://github.com/lance-format/lance-c), the official C binding, and
decodes the Arrow batches it returns with a vendored copy of
[nanoarrow](https://github.com/apache/arrow-nanoarrow).

**State of this build: the DDL surface only.** Servers, user mappings, foreign
tables and `IMPORT FOREIGN SCHEMA` all work; `SELECT` stops with

```
ERROR:  lance_fdw: scan is not implemented in this build
```

The MPP scan lands in the next change.

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
git submodule update --init            # third_party/lance-c, pinned to v0.1.9
make
make install
psql -c 'CREATE EXTENSION lance_fdw'
```

`make` builds `third_party/lance-c` with cargo (about 16 minutes on 16 cores
from cold, seconds afterwards) and links `lance_fdw.so` against it. `make
install` puts a stripped `liblance_c.so` next to `lance_fdw.so` in `$(pg_config
--pkglibdir)`, and `lance_fdw.so` carries an rpath pointing there, so nothing
has to be added to `ld.so.conf`. Expect about 230 MiB after stripping (305 MB
before): lance-c statically links the whole Lance Rust stack.

To use a lance-c that already exists instead of building the submodule:

```sh
make LANCE_C_PREFIX=/opt/lance-c              # expects include/ and lib/
make LANCE_C_INCDIR=... LANCE_C_LIBDIR=...    # override either half
make USE_PKGCONFIG_LANCE_C=1                  # ask pkg-config for lance-c
```

In that case nothing is installed for lance-c and the rpath points at the
library where it already lives.

Other targets:

| Target | What it does |
|---|---|
| `make check-syntax` | `gcc -fsyntax-only` over `src/*.c`; needs no server installation, only a configured source tree in `PG_INCLUDE_DIR` (default `/opt/cloudberry/src/include`) |
| `make check-scripts` | `bash -n` over the gate scripts |
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

### Options

**Foreign data wrapper**

| Option | Meaning |
|---|---|
| `mpp_execute` | `all segments` (the default the extension installs), `coordinator` or `any`. Under `all segments` the coordinator enumerates fragments and each segment reads its own share; the other two make one process read everything. |

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
| `aws_access_key_id` | |
| `aws_secret_access_key` | |
| `aws_session_token` | For temporary credentials. |

Credentials are read from the user mapping in whichever process needs them and
are never put into a plan, an `EXPLAIN`, or a log line.

**Foreign table**

| Option | Meaning |
|---|---|
| `uri` | Required. Either absolute (`s3://...`, `file:///...`, `/abs/path`) or relative to the server's `base_uri`. |
| `version` | Dataset version to read. `0`, the default, means the latest at the time the statement runs. |
| `batch_size` | Rows per Arrow batch. Default is lance's own, 8192. Lower it for datasets with large binary columns. |
| `rows_hint` | Row estimate for the planner. Default 100000. Planning does no I/O, so this is the only way the planner can know better. |
| `mpp_execute` | Overrides the server's setting. |

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

All four are read once per backend, before its first call into lance-c, so
changing them mid-session has no effect on that session.

A backend that opens a dataset grows to roughly 18 threads and about 34 once it
scans, independent of how many datasets it opens. On a coordinator with many
concurrent sessions, that is the number to plan around: lower `cpu_threads` and
`io_threads` if it matters more than per-query throughput.

### Types

`IMPORT FOREIGN SCHEMA` writes these; a hand-written foreign table may also
declare a wider type of the same family (an Arrow `int32` may be read into
`bigint`, for instance).

| Arrow | PostgreSQL |
|---|---|
| `bool` | `boolean` |
| `int8`, `int16`, `uint8` | `smallint` |
| `int32`, `uint16` | `integer` |
| `int64`, `uint32` | `bigint` |
| `float16`, `float32` | `real` |
| `float64` | `double precision` |
| `utf8`, `large_utf8` | `text` |
| `binary`, `large_binary` | `bytea` |
| `date32` | `date` |
| `timestamp(s\|ms\|us\|ns)` without a zone | `timestamp(6)` |
| `timestamp(s\|ms\|us\|ns)` with a zone | `timestamptz(6)` — the value is a UTC epoch and the zone name is not kept |
| `decimal128(p,s)` | `numeric(p,s)` |
| `fixed_size_list<float32, N>` | `real[]` |
| `fixed_size_list<float64, N>` | `double precision[]` |
| `list<T>` where T is a scalar above | that type's one-dimensional array |

Everything else is B-tier: `uint64`, `struct`, `map`, `dictionary`,
`duration` and the interval types, `time32`/`time64`, `date64`, `decimal256`,
`large_list`, lists of anything but a scalar, `fixed_size_binary`, the view
types, unions — and any field carrying Lance's `lance-encoding: blob`
metadata, whatever its Arrow type says, because the scanner returns a
`struct{position, size}` descriptor for those rather than the bytes.

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
bash test/gate/gate.sh              # everything
bash test/gate/gate.sh --suite ddl  # one suite, behind install
bash test/gate/gate.sh --clean      # after a build-system change
bash test/gate/reset.sh             # drop schema lance_regress, re-upload fixtures
```

The gate needs `test/gate/env.sh` (not in the repository) to export
`LANCE_S3_ENDPOINT_HOST`, `LANCE_S3_ENDPOINT_CONTAINER`, `LANCE_S3_BUCKET`,
`LANCE_S3_REGION`, `LANCE_S3_KEY` and `LANCE_S3_SECRET` for the MinIO the
`s3://` cases use.

## Known limits

- No scan yet, as above.
- No filter, limit or vector-search pushdown; every qualifier is evaluated by
  PostgreSQL.
- Fragments are handed to segments round-robin. lance-c exposes no per-fragment
  row count, so a dataset whose fragments differ wildly in size will skew.
- Only the PostgreSQL planner is covered. The test cluster is built
  `--disable-orca`, so the ORCA path is unverified.
- A panic inside lance-c is reported as an error where lance-c can catch it,
  but a double panic or a stack overflow still takes the backend down.

## Licence

Apache-2.0. See `LICENSE`, and `THIRD_PARTY_LICENSES.md` for lance-c and
nanoarrow.
