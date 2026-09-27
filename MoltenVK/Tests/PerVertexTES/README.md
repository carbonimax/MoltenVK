# TES PerVertex tests: GPU-generated triangle topology

This is a test-only admission, not generic Vulkan tessellation support. Production CMake and Xcode builds never define `MVK_TEST_TES_PERVERTEX_ADMISSION` or link `EnableTestDevice.mm`. The public pipeline gate and the macOS barycentric device gate stay closed.

## Admitted scope

A PerVertexKHR pipeline with tessellation is admitted only for:

- triangles, equal spacing, `cw` or `ccw`, no point mode;
- three input and output control points, and the default upper-left domain origin (no `VkPipelineTessellationDomainOriginStateCreateInfo`);
- TCS and TES without descriptor resources or push constants, because the float32 TessLevel ABI excludes Metal argument buffers (VS and fragment resources are allowed and use the pipeline's own binding model);
- vertex inputs without divisors, static state, a single view and a single sample;
- no pipeline cache and no specialization;
- direct non-indexed draws of one instance with `firstVertex`, `firstInstance` and DrawID equal to 0 (the VS reads a bound DrawID of 0).

Any other pipeline mode returns `VK_ERROR_FEATURE_NOT_PRESENT` at `vkCreateGraphicsPipelines`. Any other draw fails at `vkEndCommandBuffer`, before submission.

## Execution

1. **TCS.** VS and TCS run in compute. The TCS is compiled with SPIRV-Cross `tessellation_factors_float32`, so it writes the exact float32 levels (`outer[4]`, `inner[2]`, 24 bytes per patch). Metal's half factors would round `nextafter(1, +inf)` down to level 1.
2. **Topology.** `perVertexTessTopology` classifies each patch on the GPU:
   - a patch is discarded when one of its first three outer levels is ≤ 0 or NaN;
   - otherwise each level is clamped to `[1, maxTessellationGenerationLevel]` and rounded up;
   - uniform levels 1, 2 and 3 emit the Metal topologies (1, 6 and 13 triangles) that the ordinary Vulkan oracles proved on M4;
   - the corner order is clockwise in (u,v) and reversed for `ccw`, as Vulkan specifies for the upper-left origin;
   - a serial prefix assigns patch offsets.
3. **Refusal.** Any other level (non-uniform, above 3, NaN inner) refuses the whole draw: nothing is captured or replayed. The submission reports `VK_ERROR_DEVICE_LOST` in `finish()`, before signalling its fence. The VS and TCS of that draw have already run.
4. **Capture and replay.** TES runs in compute over the generated corner records, one per triangle corner. Vulkan allows more than one TES invocation per unique vertex. The replay draws the GPU-written count indirectly.
5. **Capacity.** Scratch is reserved before submission for the proven maximum of 39 records per patch, including the float32 levels and the plan buffer. Every allocation is transactional.
6. **Synchronization.** Compute buffer barriers separate VS, TCS, the generator phases and TES. Ending compute makes the tracked scratch visible to the restarted render pass.

## Oracles (`topology.cpp`)

Positions and levels are vertex attributes that the GPU copies into a host-zeroed buffer earlier in the command buffer. For each scenario the test checks:

- **Ordinary pipeline.** The PerVertex replay must match the ordinary hardware TES pipeline in coverage and interpolated nonlinear TES values (tolerance 2/255).
- **Barycentric order.** Every covered pixel must show that PerVertexKHR follows the BaryCoordKHR order, which is Vulkan's only ordering requirement for tessellation.
- **CPU model.** Every triangle is sampled against an independent CPU model of the ordered topology.
- **Negative control.** A corner-swapped fragment must fail that model.

Scenarios cover:

- levels 1, 2 and 3;
- `nextafter(1, +inf)`, rendered at level 2 like an exact 2.0 while the ordinary half path still renders level 1;
- a patch discarded by a zero or a NaN outer level, placed between patches with different levels;
- clamped fractional levels;
- back-face culling with a mirrored patch;
- `gl_DrawID` folded into the VS output;
- a VS storage-buffer counter and a fragment uniform scale under default argument buffers: the VS runs exactly once per vertex, discarded patches included;
- both windings;
- level 4, non-uniform levels and a NaN inner level, which must be refused with `VK_ERROR_DEVICE_LOST` and no pixel.

`main.cpp` keeps the earlier pilot checks that still apply: the factor-1 fixture with the ordered, swapped and wrong-patch fragments, the compute-bind recording guards, and the refusals for cache, patch size, specialization, instances, first vertex, indexed draws and the no-admission build.

## Reproduce

From the MoltenVK root, on a Mac with Metal, with the sources committed:

```sh
bash MoltenVK/Tests/run-pervertex-tes-tests.sh /private/tmp/mvk-tes-topology
```

The runner builds from `HEAD`:

- three Debug arm64 libraries: development, without admission, and shipping;
- three generator mutations that must be caught: reversed winding, a wrong level-3 interior, and ignored patch offsets.

It also checks that the float32 TessLevel ABI is live in the generated TCS and TES, and writes `EVIDENCE.sha256` and `SOURCE-INDEX.txt`.

## Limits

Proven on one Apple M4 Pro (macOS 27.2, Xcode 27.1) only. Not supported:

- other levels, spacings, domains or domain origins;
- point mode;
- descriptors or push constants in TCS/TES, instancing, multiview, indexed or indirect draws;
- pipeline caches;
- other GPU families.

Ordinary point-mode TES pipelines already fail in MoltenVK, independently of this path. The ordinary TES path keeps its half factors, so it diverges from the PerVertex path on levels that half cannot represent.
