# Internal TES PerVertex integration test

This is a compile-time fixture pilot, not generic Vulkan tessellation support. Production CMake and Xcode builds never define `MVK_TEST_TES_PERVERTEX_FIXTURE` or link `EnableTestDevice.mm`. The public pipeline gate and macOS barycentric device gate remain closed.

## Reproduce

From the MoltenVK root, on a Mac with Metal and non-uniform compute dispatch, with CMake/Ninja, Xcode Metal tools, glslangValidator and SPIR-V Tools on PATH:

```sh
bash MoltenVK/Tests/run-pervertex-tes-tests.sh /private/tmp/mvk-tes-repro
```

The runner builds arm64 from this checkout and its `External/SPIRV-Cross` link. It must run with access to Metal (the restricted agent sandbox exposes no device). It builds three variants sequentially: exact fixture admission + test device adapter; no fixture admission + test device adapter to test pipeline refusal; neither admission nor adapter to test the public device gate. It preserves each dylib and logs with Metal API/GPU validation. It never edits MVKDevice.mm.

## Fixture contract

The generated header compares complete SPIR-V word arrays for VS, TCS, TES and the three test fragments. No hash-only admission, specialization, alternate entry point, dynamic state, vertex attributes, multiview, multisampling or domain override is admitted. Vulkan pipeline caches are explicitly refused because the persistent options serialization does not yet include `tese_as_compute`; that format must be versioned before production use. The shader-module in-memory cache compares the complete MSL option struct and remains safe for this pilot.

One direct non-indexed `vkCmdDraw(6, 1, 0, 0)` emits two three-control-point patches. The actual VS generates two separated triangles, the actual TCS copies positions and writes all four triangle levels to 1, and the exact triangle/equal-spacing/ccw TES consumes TCS output and writes domain coordinates plus distinct patch identity. DrawID must be zero. Other nonempty draw shapes fail recording; zero-work commands retain Vulkan no-op behavior. Existing indirect guards remain intact.

CPU-generated invocation/replay tables are **test-only scaffolding**: exact TCS words, with no specialization or resources, establish factor 1. No general TCS-factor inference or production topology admission is implemented. TES reads real TCS buffers on the GPU. Compute barriers separate VS/TCS/TES, then ending compute makes tracked scratch visible to the restarted render pass.

For N=6, patch count=2: invocations use 16+32N bytes (208); header = count plus three zero words; record = float xyz bits, patch ID, dense output record ID, three zero words. Capture = N×TES stride; occurrences = 8N; primitive indices = 4N; optional barycentric corners = 4N. VS/TCS intermediate buffers use declared device component limits, computed in uint64 and checked against Metal buffer limits. All ten allocations are reserved before submission and released on any reservation failure. Slots 7..11 extend existing scratch with invocations, VS output, TCS vertex output, TCS patch output, TCS factors. TES implicit binding allocation and compiler collision checks are reused.

## Proof and limits

`evidence-20260927/README.md` records the passing M4 Pro run and source fingerprints. Four asymmetric pixels across both patches are green for `ordered.frag`; swapping corners produces red. Patch identity is independently checked from screen X, and the wrong-patch oracle produces red. Three pixels outside the triangles remain black. Ordinary hardware TES controls pass on both admission configurations.

Refusals cover changed factor-2 TCS, cache, specialization, patch size, count, instances, firstVertex and indexed draw; no rejected command buffer is submitted. With explicit prefill=0, the runner also binds the TES graphics pipeline followed by a valid compute pipeline before the render pass: valid draws still render green, while nonzero firstVertex or firstInstance fail at vkEndCommandBuffer. For each rejection, a separate GPU initialization/probe verifies all 1024 blue pixels survive the pending black clear, and the host readback sentinel remains untouched. `evidence-p2-compute-bind-20260927/README.md` records the failing-before/passing-after P2 regression and SHA evidence. Scratch fault injection covers every new allocation. Corrected SPIRV-Cross builtins/helper/PatchVertices regressions pass separately (3/3); the Vulkan fixture itself uses ordinary gl_PerVertex input and direct PrimitiveId. The converter's pre-existing TES-layout export WIP is required and was preserved.

Remaining: replace CPU fixture topology with GPU generation from actual TCS factors and establish supported modes/capacity semantics; compatible persistent cache serialization; wider shader resources/effects, domains, factors, draws, attachment combinations and GPU families. This test proves the bounded Vulkan connection, not any of those extensions.
