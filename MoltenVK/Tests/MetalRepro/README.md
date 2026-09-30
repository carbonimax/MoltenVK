# Sample-rate shading is not applied to a side-effect-free fragment on a triangle strip

Draft report for Apple (Feedback Assistant), prepared on 2026-09-30. Not submitted.

## Summary

With 4x MSAA and a fragment function that makes it run per sample (a `sample_perspective` input, with or without a
`[[sample_id]]` parameter), a two-triangle **triangle strip** is shaded as if interpolation happened at the pixel
centre on the pixels its two triangles share. The same geometry drawn as a triangle list is shaded per sample. Under
Metal API and shader validation (`MTL_DEBUG_LAYER=1`, `MTL_SHADER_VALIDATION=1`), or when the fragment writes to a
device buffer, the strip is shaded per sample too.

## Environment

- Apple M4 Pro, macOS 27.2 (26B5091g), Metal 4.
- Standalone Metal program, no Vulkan layer. The shaders are the MSL that MoltenVK generates for the Vulkan CTS test
  `dEQP-VK.fragment_shading_barycentric.weights.*.msaa_sample_qualifier.triangle_strip`, compiled with
  `MTLMathModeFast`, `MTLMathFloatingPointFunctionsFast`, `preserveInvariance = NO`.

## Steps

```
bash run-sample-shading-strip.sh <output directory>
```

The program (`SampleShadingStrip.mm`) renders 128 x 128, `MTLPixelFormatRGBA8Unorm`, `rasterSampleCount = 4`,
`MTLStoreActionMultisampleResolve`, one draw:
- strip: 4 vertices, `MTLPrimitiveTypeTriangleStrip`;
- list: the same two triangles as 6 vertices, `MTLPrimitiveTypeTriangle`.

The right-hand vertices have w = 16, so interpolation is strongly perspective. The resolved image is compared with two
models computed on the CPU in double at the standard 4x sample locations:
- interpolation at each sample;
- interpolation at the pixel centre, where each sample keeps the triangle that covers it.

## Expected

The resolved image matches the per-sample model within 1 everywhere, for the strip as for the list.

## Actual

| Fragment | Strip, no validation | List, no validation | Strip or list, validation on |
| --- | --- | --- | --- |
| `sample_perspective` input, unused `[[sample_id]]` (as generated) | 25 pixels off, up to 5/255, on the shared edge; matches the pixel-centre model on 16384/16384 pixels | per-sample | per-sample |
| same, without `[[sample_id]]` | same 25 pixels | per-sample | per-sample |
| `[[sample_id]]` read into the output through a constant buffer holding 0 | same 25 pixels | per-sample | per-sample |
| an atomic increment of a device buffer (no sample id or position read) | per-sample; 65536 invocations counted | per-sample | per-sample |
| colour and `get_sample_position` written per sample to a device buffer | per-sample | per-sample | per-sample |

Away from the shared edge, the two models agree within 1, so the image cannot tell whether pixel-rate interpolation
also happens elsewhere.

## Impact

Vulkan requires sample-rate shading here: `sampleShadingEnable` with `minSampleShading = 1`, and an input with the
`sample` qualifier. Through MoltenVK, the CTS weights tests for triangle strips and fans fail without validation and
pass with it. Tests that observe the samples (for example with a buffer write) see correct values and cannot detect
the problem.
