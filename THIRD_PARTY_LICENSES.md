# Third-party components

| Component | Version | License | Location | How it is used |
|---|---|---|---|---|
| lance-c (Lance C binding) | v0.1.9-4-gc43774c (commit c43774c) | Apache-2.0 | `third_party/lance-c` (git submodule) | Built from source into `liblance_c.so`, installed next to `lance_fdw.so`; the FDW calls it through `include/lance/lance.h` |
| nanoarrow | 0.7.0 | Apache-2.0 | `vendor/nanoarrow` (bundled single file, symbol namespace `LanceFdw`) | Arrow C Data Interface parsing and array views for Arrow → Datum conversion |

lance-c itself statically links the Lance Rust crates and their dependencies (Apache-2.0 / MIT
dual-licensed Rust ecosystem crates). Because `make` builds it from the submodule rather than
using an upstream release artifact, the notices under `share/licenses/lance-c` that ship with
those artifacts are not part of this build: the authoritative inventory of what ends up inside
`liblance_c.so` is `third_party/lance-c/Cargo.lock`, and `cargo license` over the submodule
reproduces the list. Apache Cloudberry itself is Apache-2.0.
