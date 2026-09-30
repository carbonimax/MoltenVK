# Multiview pass grouping: view masks with gaps, and view 31

Host test for MoltenVK. It needs no GPU.

## Summary

Two defects in MoltenVK's multiview pass grouping:

1. When layered rendering is unavailable (`canUseInstancingForMultiview()` is false, on iOS and tvOS GPUs before
   Apple5), each Metal pass renders one enabled view. `MVKDevice::getFirstViewIndexInMetalPass` walked the view groups
   and decremented the pass index inside each group, so it skipped the gaps between groups: for view mask `0b101`,
   pass 0 started at view 3 instead of view 0.
2. `mvkGetNextViewMaskGroup` shifted a signed `1` by the running end position. With view 31 enabled, which
   `maxMultiviewViewCount = 32` allows, the loop reached a shift by 32, which is undefined behavior. This function also
   serves the layered path.

## What the test checks

`run.sh` extracts `mvkGetNextViewMaskGroup`, `MVKDevice::getMultiviewMetalPassCount`, `getFirstViewIndexInMetalPass`,
`getViewCountInMetalPass` and `MVKRenderSubpass::getViewMaskGroupForMetalPass` as they are in the given MoltenVK
checkout, and compiles them with `MultiviewGroupingTests.cpp`, which provides stubs for the device and render pass,
under AddressSanitizer and UndefinedBehaviorSanitizer. For every pass, the test compares the pass count, first view,
view count and group mask with a reference, with and without layered rendering: every 16-bit mask, sparse and
high-bit 32-bit masks, and 4096 pseudo-random masks. It does not exercise the callers of these functions.

## Steps

Needs the Xcode command line tools and `python3`.

```
bash run.sh <MoltenVK checkout> <output directory>
```

The script runs the full test, then masks `0x5`, `0x80000000` and `0xffffffff` alone, prints one line per run, and
exits with 1 if any run fails. Each run's log is in the output directory.

## Results

Apple clang 21 (Xcode 27.1), macOS 27.2, Apple M4 Pro.

Before the fix (MoltenVK `a63d4863`):

```
all         exit=1   mask=5 layered=0 pass=0 actual={3,1} expected={0,1}
0x5         exit=1   mask=5 layered=0 pass=0 actual={3,1} expected={0,1}
0x80000000  exit=134 runtime error: shift exponent 32 is too large for 32-bit type 'int'
0xffffffff  exit=134 runtime error: shift exponent 32 is too large for 32-bit type 'int'
```

The sanitizer aborts also make the shell print an `Abort trap` notice.

After the fix:

```
all         exit=0   PASS: 901970 production ViewRanges, layered and multipass, exhaustive 16-bit and sparse/high-bit 32-bit masks
0x5         exit=0   ok
0x80000000  exit=0   ok
0xffffffff  exit=0   ok
```
