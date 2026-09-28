# Render encoder memory barriers have no effect under Metal shader validation on iOS and iPadOS 27

## Summary

On iOS and iPadOS 27, `MTL_SHADER_VALIDATION=1` makes
`-[MTLRenderCommandEncoder memoryBarrierWithScope:afterStages:beforeStages:]` and
`memoryBarrierWithResources:count:afterStages:beforeStages:` behave as if they were absent. Buffer stores made by the
vertex function of one draw are not visible to the vertex function of the next draw in the same render pass. That
draw then produces no fragments, so whether its fragment function would see the stores cannot be observed here.

Shader validation reports nothing, even with `MTL_SHADER_VALIDATION_ENABLE_ERROR_REPORTING=1` and
`MTL_SHADER_VALIDATION_REPORT_TO_STDERR=1`. With `MTL_SHADER_VALIDATION_FAIL_MODE=allow` the result is the same, so
this is not the zero-fill of an access that validation considers invalid. Both checks were run on the iPad Pro M4.

The same code orders the draws correctly:
- without shader validation, on the same devices;
- with Metal API validation alone (`MTL_DEBUG_LAYER=1`), on the iPad Pro M4;
- with or without shader validation, on macOS 27.2 (M4 Pro).

The barrier used is allowed on these GPUs. For the Apple3 through Apple10 families, the Metal Feature Set Tables
(page 6, note 3) exclude only barriers with the fragment or tile stage in `after`, or the `renderTargets` scope. This
barrier uses the `Buffers` scope, `after: .vertex` and `before: [.vertex, .fragment]`.

## Steps to reproduce

1. Open `BarrierRepro.xcodeproj`, select your development team, and run the `BarrierRepro` scheme on an iPhone or iPad
   running iOS 27.
2. Every variant prints `BARRIER_REPRO PASS`. The summary reads 6 of 6.
3. Run the `BarrierRepro-ShaderValidation` scheme. It differs only by the environment variable
   `MTL_SHADER_VALIDATION=1`. Alternatively, run the `BarrierRepro` scheme with Edit Scheme > Run > Diagnostics > Shader
   Validation checked; this gives the same result.

## Expected result

Step 3 prints the same results as step 2: 6 of 6 barrier variants order the capture before the replay.

## Actual result

With shader validation, every barrier variant prints `BARRIER_REPRO FAIL ... vertex_visible=0 fragment_visible=0`, and
the summary reads 0 of 6. The replay reads the zeros that a blit wrote before the render pass, so it draws nothing. The
`split` variant, which ends the render encoder and starts a new one, still passes.

The `none` control has no barrier, and shows `vertex_visible=0` in both configurations. It prints PASS because it has no
contract to check. It shows that the capture is slow enough for an unordered replay to overtake it.

## What each variant does (`BarrierRepro.mm`)

Each variant renders into a 64×64 RGBA8 target, 5 times:
1. **Capture.** A render pipeline with `rasterizationEnabled = NO` draws 6 vertices. Its vertex function spins on ALU
   work, then writes one 48-byte record per vertex into a `Private` buffer.
2. **Ordering.** The variant's barrier, render pass split, or nothing.
3. **Replay.** A second draw in the same render pass reads the records: its vertex function reads the positions, and
   its fragment function reads each triangle's color.
4. **Check.** A result passes when the 1024 pixels of the quad have their triangles' colors.

| Variant | Ordering between capture and replay |
| --- | --- |
| `barrier` | `memoryBarrierWithScope:MTLBarrierScopeBuffers afterStages:Vertex beforeStages:Vertex\|Fragment` |
| `barrier-indirect` | the same, with the capture drawn by `drawPrimitives:indirectBuffer:indirectBufferOffset:` |
| `barrier-resources` | `memoryBarrierWithResources:` on the records buffer, same stages |
| `barrier-v2v` | the same barrier with `beforeStages:Vertex` only (only the vertex reads are checked) |
| `barrier-raster` | the same barrier, with a capture pipeline that rasterizes (its primitives are outside the clip volume) |
| `barrier-shared` | the same barrier, with a `Shared` records buffer |
| `split` | `endEncoding`, then a new render encoder that loads the attachment |
| `none` | nothing (control) |

## Observed configurations

Built with Xcode 27.1 (27A9269).

| Device | GPU | OS | No validation | `MTL_DEBUG_LAYER=1` only | `MTL_SHADER_VALIDATION=1` only | Both |
| --- | --- | --- | --- | --- | --- | --- |
| iPhone 15 Pro (iPhone16,1) | A17 Pro | iOS 27.0 (24A437) | 6/6 | not run | not run | 0/6 |
| iPhone 18 Pro (iPhone19,2) | A20 Pro | iOS 27.2 (24B5089g) | 6/6 | not run | not run | 0/6 |
| iPad Pro 11-inch M4 (iPad16,3) | M4 | iPadOS 27.2 (24B5089g) | 6/6 | 6/6 | 0/6 | 0/6 |
| Mac (M4 Pro) | M4 Pro | macOS 27.2 (26B5091g) | 6/6 | not run | not run | 6/6 |

Where the results come from:
- **iOS table:** the same `BarrierRepro.mm`, run inside a test app launched with these environment variables.
- **This project:** launched with `devicectl device process launch -e` on all three iOS devices: 6/6 without validation
  and 0/6 with `MTL_SHADER_VALIDATION=1`.
- **macOS:** a command-line build of the same file (`-DBARRIER_REPRO_STANDALONE`).

The Shader Validation diagnostic of the Xcode scheme gives the same result as the environment variable. This was
checked on the iPad Pro M4 from Xcode 27.1: 0/6 with the diagnostic checked, and 6/6 without. Xcode saves the checked
diagnostic as `enableGPUShaderValidationMode = "2"` on the scheme's `LaunchAction`.

## Impact

A renderer that orders draws inside a render pass with these barriers renders wrongly while a developer debugs with
shader validation, with no diagnostic. Of the orderings tried, only ending the render pass works under shader
validation.

That workaround has a cost. Without validation, a render pass split cost 27 to 62 µs per split on the iPhones and the
iPad listed above. The measurement used RGBA8 and Depth32Float attachments of 2556×1179. To run it, pass `cost` as the
variant to `pervertexBarrierMain`. The app does not run it by default.

## Files

- `BarrierRepro.mm` — the reproducer (Metal only).
- `App/main.mm` — the app that runs every variant and prints the results.
- `project.yml` — the XcodeGen spec from which `BarrierRepro.xcodeproj` was generated.
