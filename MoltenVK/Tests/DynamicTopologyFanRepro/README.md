# Triangle fans ignore a dynamic primitive topology

Standalone Vulkan reproducer for MoltenVK. It uses no extension beyond the portability ones and no barycentric input.

## Summary

MoltenVK draws triangle fans by converting them to indexed triangles. Its draw paths (`MVKCmdDraw.mm`: direct,
indexed, indirect, and the indexed indirect adjustments) decided whether to convert from the topology the pipeline
was created with, so they ignored a topology set with `vkCmdSetPrimitiveTopology` (`VK_DYNAMIC_STATE_PRIMITIVE_TOPOLOGY`):

- a pipeline created as a triangle list or strip draws a dynamic triangle fan as a triangle list;
- a pipeline created as a triangle fan draws a dynamic triangle list or strip through the fan conversion.

## What the program checks

One render pass draws the same six vertices once per topology of a class, with blending so that draw order matters.
The same draws go through one dynamic pipeline that changes topology between draws, and through one static pipeline
per topology. The dynamic image must equal the static image, and must differ from the dynamic pipeline kept at its
first topology, so that each change is applied. The vertex shader counts its invocations, and the dynamic count must
equal the static count.

| Class | Topologies, in draw order | Dynamic pipeline created as |
|---|---|---|
| `triangles` | list, strip, fan | triangle list |
| `triangles-fan-first` | fan, strip, list | triangle fan |
| `lines` (control, no fan) | line list, line strip | line list |

Each class runs with direct, indexed, indirect and indexed indirect draws: twelve cases. The device needs Vulkan 1.3,
`shaderDrawParameters`, `vertexPipelineStoresAndAtomics` and `drawIndirectFirstInstance`.

With these six vertices a triangle strip and a triangle list cover the same two triangles, so in the `triangles` class
the "differs from its first topology" check detects the fan draw only. The `lines` class is the list and strip control.

## Steps

Needs the Xcode command line tools, `glslangValidator` and `spirv-val`.

```
bash run.sh <path to libMoltenVK.dylib> <path to Vulkan-Headers/include> <output directory>
```

The script compiles the two shaders, builds `DynamicTopologyFan.mm` against the given library, runs the twelve cases
under Metal API and GPU validation (`MTL_DEBUG_LAYER=1`, `MTL_SHADER_VALIDATION=1`), prints one line per case, and exits
with 1 if any case does not pass. Each case's log is in `<output directory>/logs`.

## Results

Apple M4 Pro, macOS 27.2 (26B5091g), Xcode 27.1, MoltenVK built with CMake (Debug, arm64).

Before the fix (MoltenVK `a63d4863`), all triangle cases fail and the line cases pass:

```
triangles            direct            FAIL    covered=1488 pixel_mismatches=362 ...; dynamic differs from its first topology kept=0; VS invocations static=30 dynamic=24
triangles-fan-first  direct            FAIL    covered=1488 pixel_mismatches=730 ...; dynamic differs from its first topology kept=1; VS invocations static=30 dynamic=54
lines                direct            PASS    covered=159 pixel_mismatches=0 ...; dynamic differs from its first topology kept=1; VS invocations static=16 dynamic=16
```

The indexed, indirect and indexed indirect forms give the same numbers as the direct form in each class.

After the fix, all twelve cases pass, with `pixel_mismatches=0`, `kept=1`, and equal invocation counts (30 for
triangles, 16 for lines).
