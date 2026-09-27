# PerVertexKHR TES + indirect integration — M4, 2026-09-27

## Status

Base integration commit `2b9d3b2131b2afbbb65c28d3102d6345c81d8f07` descends from Claude's indirect prototype `b5a1caec0a226acc8b8ef635b109014ca08ad9cb`. It includes the main checkout's TES fixture and Cereal repair without modifying that dirty checkout. This is an isolated, bounded prototype; the public barycentric gate remains closed in committed source. Generic TES, mesh, unbounded indirect execution, M1/M3 and performance validation remain open.

The conflict found by Astra is resolved by retaining TES buffers 7–11 and moving the indirect plan/status to buffer 12. `getIndirectStatus()` also requires a nonzero indirect capacity, so a TES-only reservation cannot be read as an indirect failure. The host scratch regression writes 6 to TES invocation word 0 and 2 to the indirect status word and verifies the distinct results.

The test-only device adapter accepts an already enabled barycentric feature, allowing one library to run both fixtures. The indirect GPU harness has optional `PERVERTEX_TEST_INCLUDE_TES` and `PERVERTEX_TEST_TES_FIRST` modes; normal runs retain their prior behavior. The test library was built with the two-line macOS barycentric gate override used by the isolated indirect test. This override was restored before the separate shipping build and is absent from the integration commit.

## Evidence on this M4

| Check | Result | Evidence |
| --- | --- | --- |
| Fresh arm64 Debug TES runner, fixture/public/shipping variants | PASS, Metal API/GPU validation | `build/integration-final/tes-run/` |
| Indirect matrix on shared TES + indirect test library | 121/121 PASS; 372/372 manifest | `build/integration-final/indirect-matrix/` |
| Ordinary and direct PerVertex r12 controls on same library | 8/8 byte-identical; 19/19 manifest | `build/integration-final/r12-controls/` |
| TES ordered pixels on the exact indirect-matrix library | four green pixels, PASS | `build/integration-final/mixed/pervertex-integrated-tes-shared-lib.log` |
| Indirect Count then TES, one command buffer and submission | PASS; fence 0, 24/24 invocations, identical pixels, TES oracle 1, red 0 | `build/integration-final/mixed-p2/pervertex-mixed-after-p2.log` |
| TES then indexed indirect Count, one command buffer and submission | PASS; fence 0, 24/24 invocations, identical pixels, TES oracle 1, red 0 | `build/integration-final/mixed-p2/pervertex-mixed-before-p2.log` |
| Deliberately wrong TES patch shader | Expected FAIL; TES oracle 0, 336 red pixels, exit code 2 | `build/integration-final/mixed-p2/pervertex-mixed-negative-recheck.{log,exit}` |
| Host scratch/preflight regression | PASS, including separate TES and indirect scratch words | `build/integration-final/preflight/pervertex-preflight-p2.log` |
| TES/indirect scratch status and allocation | PASS | `build/integration-final/cereal/pervertex-integrated-scratch-test` |
| Shipping Cereal cache and compute dispatch | PASS; Metal API/GPU validation | `build/integration-final/cereal/pervertex-integrated-cereal.log` |
| `git diff --check` on integration code | PASS | commit `2b9d3b21` |

Test dylib SHA-256: `7f9e6cfa8b456065256d8eb7ee4624d96283c96296746104d02bf6e124b4d1cd`. Shipping dylib SHA-256: `a3a54dab5d2854887108dab4f3617db00f704804a0f18800c85f6f4fbfa1c559`. Linked SPIRV-Cross `spirv_msl.cpp` SHA-256: `db9ab6dc2c6123a6e71fcb2c2ecad696cd431208353c355db95b32d269b5bd4e` (working tree, float32 option OFF in GPU tests). The archived evidence has 472/472 verified entries in `build/integration-final/EVIDENCE.sha256`.

The final mixed tests record both draw types in one Vulkan command buffer and compare each image with a direct PerVertex + TES reference. They also require four known green TES pixels and no red pixels in the TES viewport, independently of the reference image. The opposite order uses indexed arguments copied on the GPU. A deliberately wrong patch shader produces 336 red pixels and exits 2, proving that the added oracle rejects it. The original mixed logs in `mixed/` predate this correction. The `mixed-p2/` and `preflight/` SHA-256 manifests verify 14/14 and 2/2 archived files. These tests retain the narrow TES fixture: triangles/equal spacing/factor 1/two patches.

## Remaining limits

- The indirect prototype reserves capacity R before submission. Exceeding it suppresses the entire offending command and marks the device lost at completion. This is not general support for all legal indirect counts.
- Status inspection in `finish()` precedes this submission's fence and emulated semaphore signal. Native Metal semaphore signals may occur before the CPU reads status; no broader ordering claim is made.
- No combined submission with secondary command buffers, cross-submission semaphores, multiple queues or concurrent queue activity was tested.
- The final upstream review must use the definitive MoltenVK and SPIRV-Cross SHAs, including tests and these proof limits. No push or PR was made.
