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
   - the tessellation coordinates are those of the M4 tessellator, in 1/65536 steps: `1.0 - x` is exact and every edge vertex `(x, 1-x)` has its exact mirror, as Vulkan invariance rules 3, 4 and 8 require, so patches sharing an edge give bitwise-equal positions on it;
   - the corner order is clockwise in (u,v) and reversed for `ccw`, as Vulkan specifies for the upper-left origin;
   - a serial prefix assigns patch offsets;
   - each generated triangle records its patch index, which the fragment reads as `gl_PrimitiveID` (without a geometry shader, Vulkan gives the fragment the TES patch index, not the index of a tessellated triangle).
3. **Refusal.** Any other level (non-uniform, above 3, NaN inner) refuses the whole draw: nothing is captured or replayed. The submission reports `VK_ERROR_DEVICE_LOST` in `finish()`, before signalling its fence. The VS and TCS of that draw have already run.
4. **Capture and replay.** TES runs in compute over the generated corner records, one per triangle corner. Vulkan allows more than one TES invocation per unique vertex. The replay draws the GPU-written count indirectly.
5. **Incomplete patches.** Vertices that complete no patch are not tessellated, but the VS still runs once for each of them, including draws of one or two vertices.
6. **Capacity.** Scratch is reserved before submission for the proven maximum of 39 records per patch, including the float32 levels and the plan buffer. Every allocation is transactional.
7. **Synchronization.** Compute buffer barriers separate VS, TCS, the generator phases and TES. Ending compute makes the tracked scratch visible to the restarted render pass.

## Ordinary tessellation levels

This part is not test-only: it changes the ordinary tessellation path of every build. Metal's tessellator reads only half factors, and the TCS used to write its levels through `half()`, so `nextafter(1, +inf)` tessellated at level 1 and a positive level below the half range discarded the patch.

For ordinary pipelines with triangles, equal spacing, no point mode, the upper-left origin and one view:

- the TCS writes float32 levels;
- a compute kernel classifies them as Vulkan does (discard, clamp, round up) into the half factors Metal reads;
- the TES reads the float32 levels, which Vulkan defines as the values the TCS wrote.

The four draw commands (direct, indexed, indirect, indexed indirect) use the same kernel. Eligibility comes from SPIRV-Cross's shape query at pipeline creation: a TCS/TES pair that float32 cannot express, and every other mode, keeps the half path unchanged.

## Oracles (`topology.cpp`)

Positions and levels are vertex attributes that the GPU copies into a host-zeroed buffer earlier in the command buffer. For each scenario the test checks:

- **Ordinary pipeline.** The PerVertex replay must match the ordinary hardware TES pipeline in coverage and interpolated nonlinear TES values (tolerance 2/255).
- **Barycentric order.** Every covered pixel must show that PerVertexKHR follows the BaryCoordKHR order, which is Vulkan's only ordering requirement for tessellation.
- **CPU model.** Every triangle is sampled against an independent CPU model of the ordered topology.
- **Negative control.** A corner-swapped fragment must fail that model.
- **Tessellation coordinates.** A fragment stores the raw bits of its three PerVertex TES vertices per pixel; an ordinary TES appends the hardware coordinates to a storage buffer. The PerVertex coordinates must satisfy rules 3 and 8 and equal the hardware ones bit for bit, positions included, with the full vertex set of every rendered patch. The TES evaluates positions from integer pixel control points, so products and sums are exact and a shared edge is compared independently of the evaluation order.
- **Fragment `gl_PrimitiveID`.** It must equal the TES patch index on every covered pixel.

Scenarios cover:

- levels 1, 2 and 3;
- `nextafter(1, +inf)`, rendered at level 2 like an exact 2.0 while the ordinary half path still renders level 1;
- a patch discarded by a zero or a NaN outer level, placed between patches with different levels;
- clamped fractional levels;
- back-face culling with a mirrored patch;
- `gl_DrawID` folded into the VS output;
- a VS storage-buffer counter and a fragment uniform scale under default argument buffers: the VS runs exactly once per vertex, discarded patches included;
- both windings;
- seams: two patches of level 1, 2 or 3 sharing an edge, which is the `u = 0` edge of one and the `w = 0` edge of the other (rule 4);
- draws of 1, 2, 4 and 5 vertices, counted by the VS storage counter;
- level 4, non-uniform levels and a NaN inner level, which must be refused with `VK_ERROR_DEVICE_LOST` and no pixel;
- ordinary-only draws (`ordinary-levels-*`, also on the shipping library, through each draw command) where levels that half would change must render, tessellate and reach the TES exactly like their Vulkan representative: `nextafter(1, +inf)` as 2, `nextafter(2, +inf)` as 3, `1e-30` as 1 on outer and inner levels, with `+inf`, `-0` and NaN as controls.

`main.cpp` keeps the earlier pilot checks that still apply: the factor-1 fixture with the ordered, swapped and wrong-patch fragments, the compute-bind recording guards, and the refusals for cache, patch size, specialization, instances, first vertex, indexed draws and the no-admission build.

## Reproduce

From the MoltenVK root, on a Mac with Metal, with the sources committed:

```sh
bash MoltenVK/Tests/run-pervertex-tes-tests.sh /private/tmp/mvk-tes-topology
```

The runner builds from `HEAD`:

- three Debug arm64 libraries: development, without admission, and shipping;
- three generator mutations that must be caught: reversed winding, moved level-3 interior coordinates, and ignored patch offsets.

It also checks that the float32 TessLevel ABI is live in the generated TCS and TES, that ordinary fractional and quad pipelines keep the half ABI, and writes `EVIDENCE.sha256` and `SOURCE-INDEX.txt`.

Metal shader validation makes ordinary indirect tessellation draw nothing on M4, with or without this change (the VS runs, no TES does, nothing is reported). The runner therefore runs the indirect ordinary cases under Metal API validation only.

## Limits

Proven on one Apple M4 Pro (macOS 27.2, Xcode 27.1) only. Not supported:

- other levels, spacings, domains or domain origins;
- point mode;
- descriptors or push constants in TCS/TES, instancing, multiview, indexed or indirect draws;
- pipeline caches;
- other GPU families. The coordinates are copied from the M4 tessellator; on another GPU they still satisfy the Vulkan rules, but need not match that GPU's ordinary TES bit for bit.

A TES PerVertex pipeline also needs one more free fragment buffer slot, for the patch-index table.

Ordinary point-mode TES pipelines already fail in MoltenVK, independently of this path. Ordinary fractional spacing, quads, point mode and the lower-left origin still go through half factors: there, levels that half cannot represent still diverge from Vulkan.
