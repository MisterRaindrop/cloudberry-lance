# Third-party components

| Component | Version | License | Location | How it is used |
|---|---|---|---|---|
| lance-c (Lance C binding) | v0.1.9 (commit 6de5efc) | Apache-2.0 | `third_party/lance-c` (git submodule) | Built from source into `liblance_c.so`, installed next to `lance_fdw.so`; the FDW calls it through `include/lance/lance.h` |
| nanoarrow | 0.7.0 | Apache-2.0 | `vendor/nanoarrow` (bundled single file, symbol namespace `LanceFdw`) | Arrow C Data Interface parsing and array views for Arrow → Datum conversion |

lance-c itself statically links the Lance Rust crates and their dependencies (Apache-2.0 / MIT
dual-licensed Rust ecosystem crates); their notices ship inside the lance-c release artifacts
(`share/licenses/lance-c`). Apache Cloudberry itself is Apache-2.0.
