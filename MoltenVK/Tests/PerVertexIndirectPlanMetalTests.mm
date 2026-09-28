// Copyright 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
// Runs the production Metal helper and checks argument and Count snapshots across phases.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "MVKPerVertexScratch.h"
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

static void require(bool ok, const char* message) {
    if (!ok) { std::fprintf(stderr, "FAIL: %s\n", message); std::exit(1); }
}

int main(int argc, char** argv) {
    @autoreleasepool {
        require(argc == 2, "usage: pervertex-indirect-plan-metal factory.metal");
        NSError* error = nil;
        NSString* source = [NSString stringWithContentsOfFile:[NSString stringWithUTF8String:argv[1]] encoding:NSUTF8StringEncoding error:&error];
        require(source != nil, "read factory.metal");
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        require(device != nil, "Metal device");
        MTLCompileOptions* options = [MTLCompileOptions new];
        options.languageVersion = MTLLanguageVersion2_4;
        id<MTLLibrary> library = [device newLibraryWithSource:source options:options error:&error];
        require(library != nil, error ? error.localizedDescription.UTF8String : "Metal library");
        id<MTLFunction> function = [library newFunctionWithName:@"perVertexIndirect"];
        require(function != nil, "perVertexIndirect function");
        id<MTLComputePipelineState> pipeline = [device newComputePipelineStateWithFunction:function error:&error];
        require(pipeline != nil, error ? error.localizedDescription.UTF8String : "Metal pipeline");
        auto run = [&](std::array<uint32_t, 5> command, uint32_t indexBytes, uint32_t views, uint32_t capacity, bool counted, uint32_t count, bool resumeAfterMutation = false, bool secondDraw = false, bool mutateSecond = false) {
            id<MTLBuffer> args = [device newBufferWithLength:secondDraw ? 64 : 32 options:MTLResourceStorageModeShared];
            id<MTLBuffer> counts = [device newBufferWithLength:4 options:MTLResourceStorageModeShared];
            id<MTLBuffer> plan = [device newBufferWithLength:secondDraw ? 1064 : 1024 options:MTLResourceStorageModeShared];
            require(args && counts && plan, "Metal buffers");
            std::memset(args.contents, 0, args.length);
            std::memcpy(args.contents, command.data(), command.size() * sizeof(uint32_t));
            if (secondDraw) { uint32_t second[5] = {9, 1, indexBytes ? 3u : 0u, indexBytes ? uint32_t(-4) : 0u, indexBytes ? 7u : 0u}; std::memcpy(static_cast<uint8_t*>(args.contents) + 32, second, sizeof(second)); }
            std::memcpy(counts.contents, &count, sizeof(count));
            std::memset(plan.contents, 0, plan.length);
            uint32_t params[19] = {secondDraw ? 2u : 1u, 32, indexBytes, UINT32_MAX, 1, capacity, views, 3, 0, 0, uint32_t(counted), secondDraw ? 1u : 0u, 7, 5, 3, 0, 0, 0, secondDraw ? 256u : 48u};
            id<MTLCommandQueue> queue = [device newCommandQueue];
            auto dispatch = [&](uint32_t phase) {
                params[15] = phase;
                id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
                id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
                [encoder setComputePipelineState:pipeline];
                [encoder setBuffer:args offset:0 atIndex:0];
                [encoder setBuffer:counts offset:0 atIndex:1];
                [encoder setBuffer:plan offset:0 atIndex:2];
                for (NSUInteger binding = 3; binding <= 7; ++binding) { [encoder setBuffer:plan offset:0 atIndex:binding]; }
                [encoder setBuffer:plan offset:0 atIndex:9];  // one draw: its snapshot lives in the plan, at word 48
                [encoder setBytes:params length:sizeof(params) atIndex:8];
                [encoder dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(phase == 0 && secondDraw ? 2 : 1, 1, 1)];
                [encoder endEncoding];
                [commandBuffer commit];
                [commandBuffer waitUntilCompleted];
                require(commandBuffer.status == MTLCommandBufferStatusCompleted, commandBuffer.error ? commandBuffer.error.localizedDescription.UTF8String : "Metal dispatch");
            };
            dispatch(0);
            if (resumeAfterMutation) {
                std::array<uint32_t, 5> changed = {9, 1, 0, 0, 0};
                std::memcpy(args.contents, changed.data(), changed.size() * sizeof(uint32_t));
                if (mutateSecond) { uint32_t changedSecond[5] = {12, 1, 4, 5, 8}; std::memcpy(static_cast<uint8_t*>(args.contents) + 32, changedSecond, sizeof(changedSecond)); }
                if (counted) { uint32_t changedCount = count ? 0 : secondDraw ? 2 : 1; std::memcpy(counts.contents, &changedCount, sizeof(changedCount)); }
                dispatch(1);
            }
            std::array<uint32_t, 256> result;
            std::memcpy(result.data(), plan.contents, sizeof(result));
            return result;
        };
        auto small = run({6, 2, 4, 7, 0}, 0, 1, 5, false, 0);
        require(small[0] == 1 && small[48] == 6 && small[49] == 2 && small[50] == 4 && small[51] == 7 && small[53] == 12 && small[54] == 0 && small[55] == 1, "single draw beyond old capacity");
        // Plan alone with the representable record ceiling, then size and reserve actual replay scratch.
        auto planned = run({6, 1, 0, 0, 0}, 0, 1, UINT32_MAX, false, 0);
        MVKPerVertexScratchRequest replay{};
        NSUInteger gatheredOffset = 0;
        uint32_t scanSteps = 0;
        require(planned[0] == 0 && planned[53] == 6 && planned[54] == 0 && planned[55] == 1 && planned[56] == 1, "six-record GPU plan survives the old five-record cutoff");
        require(mvkSizePerVertexIndirectReplay(planned.data(), sizeof(planned), planned.data() + 48, sizeof(planned) - 48 * sizeof(uint32_t), 1, 1, 32, VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, false, false, false, device.maxBufferLength, replay, gatheredOffset, scanSteps), "size replay from frozen GPU plan");
        require(replay.captureSize == 192 && replay.occurrenceSize == 48 && replay.primitiveSize == 24 && !gatheredOffset && !scanSteps, "exact six-record replay sizes");
        MVKPerVertexScratch exact;
        require(exact.reserveReplay(device, replay) && exact.buffers[0].length >= replay.captureSize, "allocate exact Metal replay scratch after GPU plan");
        auto resumed = run({6, 2, 4, 7, 0}, 0, 1, 12, false, 0, true);
        require(resumed[4] == 6 && resumed[5] == 2 && resumed[6] == 4 && resumed[7] == 7, "phase 1 consumes GPU snapshot after source mutation");
        auto zero = run({6, 2, 4, 7, 0}, 0, 1, 5, true, 0, true);
        require(zero[0] == 0 && zero[55] == 0 && zero[53] == 0 && zero[4] == 0, "Count zero remains skipped after mutation");
        auto admittedCount = run({6, 2, 4, 7, 0}, 0, 1, 12, true, 1, true);
        require(admittedCount[55] == 1 && admittedCount[4] == 6 && admittedCount[5] == 2 && admittedCount[6] == 4, "admitted Count remains enabled after mutation");
        auto indexed = run({6, 2, 3, uint32_t(-4), 7}, 2, 1, 12, false, 0, true);
        require(indexed[0] == 0 && indexed[50] == 3 && indexed[51] == uint32_t(-4) && indexed[52] == 7 && indexed[53] == 12, "indexed argument snapshot");
        require(indexed[6] == uint32_t(-4) && indexed[7] == 7 && indexed[35] == 3, "indexed phase 1 uses the snapshot");
        auto wide = run({UINT32_MAX, 2, 0, 0, 0}, 0, 1, UINT32_MAX, false, 0);
        require(wide[53] == UINT32_MAX - 1 && wide[54] == 1, "exact high word");
        auto carry = run({UINT32_MAX, 2, 0, 0, 0}, 0, 2, UINT32_MAX, false, 0);
        require(carry[53] == UINT32_MAX - 3 && carry[54] == 3, "low-limb carry reaches the high word");
        auto overflow = run({UINT32_MAX, UINT32_MAX, 0, 0, 0}, 0, 32, UINT32_MAX, false, 0);
        require(overflow[53] == UINT32_MAX && overflow[54] == UINT32_MAX, "saturated record requirement");
        auto admittedMulti = run({6, 1, 0, 0, 0}, 0, 1, 20, true, 2, true, true);
        require(admittedMulti[4] == 9 && admittedMulti[56] == 2, "multi-draw Count remains admitted after source mutation");
        auto skippedMulti = run({6, 1, 0, 0, 0}, 0, 1, 20, true, 0, true, true);
        require(skippedMulti[4] == 0 && skippedMulti[56] == 0, "multi-draw Count remains skipped after source mutation");
        auto frozenMulti = run({6, 1, 0, 0, 0}, 0, 1, 20, false, 0, true, true, true);
        require(frozenMulti[4] == 9, "multi-draw arguments remain frozen after source mutation");
        auto frozenIndexedMulti = run({6, 1, 0, 0, 0}, 2, 1, 20, false, 0, true, true, true);
        require(frozenIndexedMulti[4] == 9 && frozenIndexedMulti[35] == 3 && frozenIndexedMulti[6] == uint32_t(-4) && frozenIndexedMulti[7] == 7, "indexed multi-draw retains all five argument words");
        std::puts("PASS: production Metal snapshots, GPU-plan replay sizing/allocation, indexed arguments and 64-bit bounds");
        return 0;
    }
}
