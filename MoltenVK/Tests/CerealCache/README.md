# Cereal options and pipeline cache repair — 2026-09-27

## Result and scope

Only `MoltenVK/MoltenVK/GPUObjects/MVKPipeline.mm` and this test directory changed by this task. The entire source preceding its cache implementation is byte-identical to the captured WIP, including all TES guards. No commits, push, PR, edits to SPIRV-Cross, indirect checkout access, production float32 assignment, fixture admission, or test device adapter.

Both `tessellation_factors_float32` and `tese_as_compute` are now serialized. Default float32 remains false. The private cache payload begins with schema `0x4D564B02` after the unchanged Vulkan header/UUID. Unversioned and unknown-schema blobs return an empty successful cache before reading entries. Previous readers encounter an unknown entry type and stop. Cache merges are in-memory and require no format translation. Any subsequent incompatible serialization change must change this schema value.

The startup size validation remains active. After adding the two bools, Options is 164 bytes / 157 archived / 7 padding; conversion options 208 / 179 / 29; configuration 424 / 262 / 162. These padding values are verified on macOS arm64/libc++; other platforms were not built.

## Before / after evidence

- Historical `../PerVertexTES/evidence-float32-off-relink-20260927T114727Z/control.log`: SIGABRT at `vkCreateInstance`, before GPU, with 4/8/8 missing bytes. Its compiler source `fa1c6acf...` is historical.
- `evidence-20260927/before.log`: the new CPU regression using the captured original serializer fails loading false over true. It uses the newly built converter for constructors/matches; this isolates the old serializer and does not claim a historical full binary build.
- `final.log`: all four float32/compute combinations roundtrip through actual Cereal Options and conversion configurations, preserve stream position and following sentinel, and differ in cache identity when either option changes. Default OFF confirmed.
- Fresh arm64 Debug build: 67 Ninja steps, no NDEBUG, TES_FIXTURE=OFF and TES_TEST_DEVICE=OFF. Forced final P2 rebuild/relink is recorded in `final-relink.log`; all final tests ran after this relink.
- Actual Debug `vkCreateInstance` now passes the complete archive validator. A no-op compute pipeline populates a 591-byte Vulkan cache; reloading preserves identical bytes. A new shader module/pipeline consumes this restored cache and executes a GPU dispatch, completing a fence within five seconds. Metal API and GPU validation active, no validation errors.
- Unversioned empty cache, poisoned unversioned library entry, unknown future schema, and schema without an entry all become empty successful caches. The poisoned legacy entry verifies rejection before parsing, rather than dependence on old option values. This is a constructed legacy-format fixture, not a historical populated GPU cache.
- Scoped diff check and shell syntax pass. `scope-check.log` proves preserved pilot code and build gates.

## Provenance

- MoltenVK HEAD `d608d84c507099909d735843e0af4993aac92661` + existing WIP.
- SPIRV-Cross HEAD `4308267dfae1dfc13fc94ebbdcaa624ede6396e6` + coordinated P2 WIP.
- Final `spirv_msl.cpp`: `db9ab6dc2c6123a6e71fcb2c2ecad696cd431208353c355db95b32d269b5bd4e`.
- `spirv_msl.hpp`: `7a75e9aca13d7d8d26736bdb38c67d1a9fb86df66bee8cd80014c68ef68a69b2`.
- Final `MVKPipeline.mm`: `4d42f3668a125ed05d1679b5cced7672448dd237428b9f5475d563189e575537`.
- Final linked MoltenVK dylib: `e6b6488acbb5fe7bb4a6f98c4a012a57a001b9b1a44756b48599f80d4c6d3a1f`.
- Coordinator-provided SPIRV-Cross CLI SHA `4fd9f1fe68d9902d0bc85f74b364c3e3d6a6214c77a779c71b556e6f586af5ea` is context only: this test links its own freshly compiled SPIRV-Cross library, not that CLI binary.

`validated.sha256` lists source and executable fingerprints. Source snapshots and the isolated incremental patch are retained here. Build tree, binaries, complete compile commands and intermediate diagnostic attempts remain at `/private/tmp/mvk-cereal-fix-20260927`. SPIRV-Cross changed concurrently from historical fa1c to coordinated db9 before its first object compiled; final forced rebuild uses verified db9 sources.

## Reproduction

From the MoltenVK root, with a Debug dylib built against the current headers and Cereal enabled:

```sh
bash MoltenVK/Tests/CerealCache/run.sh /private/tmp/mvk-cereal-rerun /private/tmp/mvk-cereal-fix-20260927/build/moltenvk/MoltenVK/libMoltenVK.1.4.3.dylib MoltenVK/Tests/PerVertexTES/evidence-float32-off-relink-20260927T114727Z/shaders/noop.comp.spv
```

The runner extracts the actual archive definitions and configured padding from MVKPipeline.mm into a temporary header; C++ performs all serialization and assertions. A fourth argument selects a saved MVKPipeline.mm (use evidence-20260927/MVKPipeline.before.mm to reproduce failure). Run outside a sandbox that hides Metal. The initial restricted attempt reached the corrected validator but could not enumerate a Metal device; successful GPU results are the final unrestricted run.

## Limits

Float32=true and tese_as_compute=true are covered by CPU archive/configuration roundtrip and identity checks only. Actual Vulkan startup, cache and Metal dispatch use default false. No TES rendering, topology correctness, float32 production enablement, old-reader executable compatibility, x86/iOS validation, or comprehensive malformed-cache fuzzing is claimed. The existing public-gate harness could not link without its absent weak test adapter; the gates are instead proven unchanged by source comparison and compile-command checks. No adapter was enabled to work around that limit. The normal TES renderer was deliberately not opened for this cache fix.
