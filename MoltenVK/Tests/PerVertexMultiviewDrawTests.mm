// Copyright (c) 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "MVKPerVertexReplay.h"
#include <cassert>
#include <cstdio>
#include <vector>
using uint = uint32_t;
using std::min;
#include "MultiviewRestartKernel.inc"
struct Trace {
    uint32_t directInstances = 0, replayInstances = 0, dispatchInstances = 0;
    uint32_t restartInstances = 0, restartBase = 0, drawBase = 0, replayBase = 0;
    uint64_t restartRecords = 0;
    MTLRegion region{};
    id directState = nil, indexedState = nil;
    uint64_t offsets[6]{};
    NSUInteger strides[6]{};
    uint32_t computeOffsets = 0, renderOffsets = 0;
    bool replay = false;
} trace;
@interface CPUBuffer : NSObject { @public std::vector<uint32_t> words; }
- (void*)contents;
- (NSUInteger)length;
@end
@implementation CPUBuffer
- (void*)contents { return words.data(); }
- (NSUInteger)length { return words.size() * sizeof(uint32_t); }
@end
@interface CPUState : NSObject
- (NSUInteger)threadExecutionWidth;
- (NSUInteger)maxTotalThreadsPerThreadgroup;
@end
@implementation CPUState
- (NSUInteger)threadExecutionWidth { return 4; }
- (NSUInteger)maxTotalThreadsPerThreadgroup { return 32; }
@end
static id mainState;
@interface CPUEncoder : NSObject
@end
@implementation CPUEncoder
- (void)setBufferOffset:(NSUInteger)offset atIndex:(NSUInteger)index { trace.offsets[index] = offset; trace.strides[index] = MTLAttributeStrideStatic; ++trace.computeOffsets; }
- (void)setBufferOffset:(NSUInteger)offset attributeStride:(NSUInteger)stride atIndex:(NSUInteger)index { trace.offsets[index] = offset; trace.strides[index] = stride; ++trace.computeOffsets; }
- (void)setVertexBufferOffset:(NSUInteger)offset atIndex:(NSUInteger)index { trace.offsets[index] = offset; trace.strides[index] = MTLAttributeStrideStatic; ++trace.renderOffsets; }
- (void)setVertexBufferOffset:(NSUInteger)offset attributeStride:(NSUInteger)stride atIndex:(NSUInteger)index { trace.offsets[index] = offset; trace.strides[index] = stride; ++trace.renderOffsets; }
- (void)setRenderPipelineState:(id)state { trace.replay = state == mainState; if (!trace.replay) trace.directState = state; }
- (void)drawPrimitives:(MTLPrimitiveType)type vertexStart:(NSUInteger)start vertexCount:(NSUInteger)count instanceCount:(NSUInteger)instances baseInstance:(NSUInteger)base {
    if (trace.replay) { trace.replayInstances = uint32_t(instances); trace.replayBase = uint32_t(base); }
    else { trace.directInstances = uint32_t(instances); trace.drawBase = uint32_t(base); }
}
- (void)drawPrimitives:(MTLPrimitiveType)type vertexStart:(NSUInteger)start vertexCount:(NSUInteger)count instanceCount:(NSUInteger)instances {
    [self drawPrimitives:type vertexStart:start vertexCount:count instanceCount:instances baseInstance:0];
}
- (void)drawPrimitives:(MTLPrimitiveType)type indirectBuffer:(id<MTLBuffer>)buffer indirectBufferOffset:(NSUInteger)offset {
    auto* args = reinterpret_cast<uint32_t*>(static_cast<char*>(buffer.contents) + offset);
    trace.replayInstances = args[1]; trace.replayBase = args[3];
}
- (void)memoryBarrierWithScope:(MTLBarrierScope)scope afterStages:(MTLRenderStages)after beforeStages:(MTLRenderStages)before {}
- (void)memoryBarrierWithScope:(MTLBarrierScope)scope {}
- (void)setStageInRegion:(MTLRegion)region { trace.region = region; }
- (void)dispatchThreads:(MTLSize)size threadsPerThreadgroup:(MTLSize)width { trace.dispatchInstances = uint32_t(size.height); }
- (void)dispatchThreadgroups:(MTLSize)size threadsPerThreadgroup:(MTLSize)width { if (size.height > 1) trace.dispatchInstances = uint32_t(size.height); }
- (void)dispatchThreadgroupsWithIndirectBuffer:(id<MTLBuffer>)buffer indirectBufferOffset:(NSUInteger)offset threadsPerThreadgroup:(MTLSize)width {
    trace.dispatchInstances = reinterpret_cast<uint32_t*>(buffer.contents)[1];
}
@end
struct MVKIndexMTLBufferBinding { id<MTLBuffer> mtlBuffer; VkIndexType vkIndexType; uint64_t offset = 0, size = 0; MTLIndexType mtlIndexType = MTLIndexTypeUInt16; };
enum Stage { kMVKShaderStageTessCtl, kMVKShaderStageVertex, kMVKGraphicsStageVertex, kMVKGraphicsStageRasterization };
using MVKGraphicsStage = Stage;
enum class MVKImplicitBuffer { Index, DrawId, EmulatedReversedDepthViewport };
struct Implicit { struct IDs { uint32_t operator[](MVKImplicitBuffer) const { return 10; } } ids; };
enum class MVKRenderStateFlag { VertexStride };
struct MVKGraphicsPipeline {
    struct Flags { bool dynamic = false; bool has(MVKRenderStateFlag) const { return dynamic; } } flags;
    const auto& getDynamicStateFlags() { return flags; }
    CPUState* states[4][3]{};
    std::vector<std::pair<uint32_t, uint32_t>> zeroDivisors{{0, 16}, {5, 16}};
    struct Translation { uint32_t binding = 0, translationBinding = 5, translationOffset = 64; };
    std::vector<Translation> translated{{}};
    const auto& getZeroDivisorVertexBindings() { return zeroDivisors; }
    const auto& getTranslatedVertexBindings() { return translated; }
    uint32_t getMetalBufferIndexForVertexAttributeBinding(uint32_t binding) { return binding; }
    struct Layout { uint32_t stride = 16; } layout;
    struct Binding { uint32_t vertex_buffer_index = 0, occurrence_buffer_index = 1, draw_parameters_buffer_index = 2, primitive_index_buffer_index = 3, corner_buffer_index = 4; } binding;
    VkPrimitiveTopology topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
    auto getPerVertexIndexedCapturePipelineState(bool index32, uint32_t views) { return (id<MTLComputePipelineState>)states[views][index32 ? 2 : 1]; }
    auto getTessVertexStageIndex16State() { return getPerVertexIndexedCapturePipelineState(false, 1); }
    auto getTessVertexStageIndex32State() { return getPerVertexIndexedCapturePipelineState(true, 1); }
    auto getPerVertexCapturePipelineState(uint32_t views = 1) { return (id<MTLRenderPipelineState>)states[views][0]; }
    auto getMainPipelineState() { return (id<MTLRenderPipelineState>)mainState; }
    const auto& getPerVertexCapturedLayout() { return layout; }
    VkPrimitiveTopology getVkPrimitiveTopology() { return topology; }
    bool usesPortableBarycentrics() { return true; }
    bool usesPerVertexInputBuffer() { return true; }
    id<MTLComputePipelineState> getTessVertexStageState() { return nil; }
    id<MTLComputePipelineState> getTessControlStageState() { return nil; }
    bool hasValidMTLPipelineStates() { return true; }
    bool needsDrawIdBuffer() { return false; }
    uint32_t getPerVertexCaptureBufferIndex() { return 9; }
    uint32_t getPerVertexCaptureParamsBufferIndex() { return 8; }
    Implicit getImplicitBuffers(Stage) { return {}; }
    const auto& getPerVertexReplayBinding() { return binding; }
    const auto& getPerVertexReplayBarycentricBinding() { return binding; }
    const auto& getPerVertexInputBinding() { return binding; }
};
struct Scratch { id<MTLBuffer> buffers[7]; id<MTLComputePipelineState> indexPipeline; };
struct MetalState {
    struct Reset { void reset() {} };
    struct Exists { Reset descriptorSetData; Exists& vertex() { return *this; } Exists& fragment() { return *this; } } _exists;
    void bindPipeline(id<MTLComputeCommandEncoder>, id<MTLComputePipelineState> state) { trace.indexedState = state; }
    void* bound[6]{};
    void bindBuffer(id<MTLComputeCommandEncoder>, id<MTLBuffer> buffer, uint64_t offset, uint32_t slot) {
        if (slot < 6) bound[slot] = static_cast<char*>(buffer.contents) + offset;
    }
    void bindBytes(id<MTLComputeCommandEncoder>, const void* data, size_t, uint32_t) {
        const auto* params = static_cast<const uint32_t*>(data);
        trace.restartInstances = params[1]; trace.restartBase = params[5];
        if (params[7] == 3) { trace.restartRecords = uint64_t(mvkPerVertexPrimitiveCount(params[0], VkPrimitiveTopology(params[3]))) * params[1]; }
        uint64_t count = params[7] == 3 ? trace.restartRecords : std::max(params[0], 1u);
        for (uint64_t i = 0; i < count; ++i) perVertexRestart((const uint8_t*)bound[0], (uint*)bound[1], (uint*)bound[2], (uint*)bound[3], (uint*)bound[4], (uint*)bound[5], params, uint(i));
    }
    void bindStructBytes(id<MTLComputeCommandEncoder>, const void*, uint32_t) {}
    void bindVertexBuffer(id<MTLRenderCommandEncoder>, id<MTLBuffer>, uint64_t, uint32_t) {}
    void bindFragmentBuffer(id<MTLRenderCommandEncoder>, id<MTLBuffer>, uint64_t, uint32_t) {}
    void bindVertexBytes(id<MTLRenderCommandEncoder>, const void*, size_t, uint32_t) {}
};
struct CommandBuffer {
    VkResult result = VK_SUCCESS;
    VkResult reportError(VkResult code, const char*, ...) { return code; }
    void setConfigurationResult(VkResult code) { result = code; }
};
enum Use { kMVKCommandUseTessellationVertexTessCtl, kMVKCommandUseRestartSubpass };
struct MVKCommandEncoder;
struct MVKCommandEncoderState {
    struct { struct { uint64_t offset = 0, stride = 24; } _vertexBuffers[6]; } _vkGraphics;
    void offsetZeroDivisorVertexBuffers(MVKCommandEncoder&, Stage, MVKGraphicsPipeline*, uint32_t);
};
struct MVKCommandEncoder {
    struct Features { bool indirectDrawing = true, nonUniformThreadgroups = true, baseVertexInstanceDrawing = true; uint64_t maxMTLBufferSize = 1ull << 30; } features;
    struct Subpass { uint32_t views = 2; bool isMultiview() { return true; } uint32_t getViewCountInMetalPass(uint32_t) { return views; } } subpass;
    struct Graphics {
        bool restart = false;
        MVKGraphicsPipeline* _pipeline = nullptr;
        MVKIndexMTLBufferBinding _indexBuffer{};
        bool isPrimitiveRestartEnabled() { return restart; }
        bool getProvokingVertexMode() { return false; }
        struct { uint32_t emulatedReversedDepthViewportMask = 0; } _implicitBufferData[2];
    } graphics;
    MVKCommandEncoderState state;
    struct Physical { bool shouldEmulateReversedDepthViewport() { return false; } } physical;
    CommandBuffer* _cmdBuffer;
    Scratch scratch;
    MetalState metal;
    id<MTLRenderCommandEncoder> _mtlRenderEncoder;
    bool _isIndexedDraw = false;
    Scratch* nextPerVertexScratch() { return &scratch; }
    auto& getMetalFeatures() { return features; }
    auto& getVkGraphics() { return graphics; }
    auto* getSubpass() { return &subpass; }
    uint32_t getMultiviewPassIndex() { return 0; }
    auto& getState() { return state; }
    auto* getPhysicalDevice() { return &physical; }
    const char* getIndexedPerVertexAttachmentError() { return nullptr; }
    void finalizeDrawState(Stage);
    id<MTLComputeCommandEncoder> getMTLComputeEncoder(Use) { return (id<MTLComputeCommandEncoder>)_mtlRenderEncoder; }
    auto& getMtlCompute() { return metal; }
    auto& getMtlGraphics() { return metal; }
    void beginMetalRenderPass(Use) {}
};
#include "MultiviewDrawMethods.inc"
int main() {
    @autoreleasepool {
        mainState = [CPUState new];
        MVKGraphicsPipeline pipeline;
        for (auto& group : pipeline.states) for (auto& state : group) state = [CPUState new];
        CommandBuffer buffer;
        MVKCommandEncoder encoder;
        encoder._cmdBuffer = &buffer;
        encoder.state._vkGraphics._vertexBuffers[0].offset = 32;
        encoder._mtlRenderEncoder = (id<MTLRenderCommandEncoder>)[CPUEncoder new];
        for (auto& buffer : encoder.scratch.buffers) { auto* b = [CPUBuffer new]; b->words.resize(1024, ~0u); buffer = (id<MTLBuffer>)b; }
        auto* input = [CPUBuffer new]; input->words.resize(1024);
        encoder.scratch.indexPipeline = (id<MTLComputePipelineState>)pipeline.states[0][0];
        for (uint32_t views : {2u, 1u, 3u}) for (uint32_t firstInstance : {0u, 7u}) for (bool nonUniform : {false, true}) {
            encoder.subpass.views = views;
            encoder.features.nonUniformThreadgroups = nonUniform;
            for (int indexKind : {-1, 0, 1, 2}) for (bool restart : {false, true}) {
                if (indexKind < 0 && restart) continue;
                for (auto b : encoder.scratch.buffers) std::fill_n((uint32_t*)b.contents, 1024, ~0u);
                trace = {};
                encoder.graphics.restart = restart;
                uint32_t physical = 2 * views;
                uint32_t vertexCount = restart ? 7 : 3;
                MVKIndexMTLBufferBinding binding{(id<MTLBuffer>)input, indexKind == 0 ? VK_INDEX_TYPE_UINT8 : indexKind == 1 ? VK_INDEX_TYPE_UINT16 : VK_INDEX_TYPE_UINT32, 0, 4096};
                uint32_t indexSize = mvkPerVertexIndexSize(binding.vkIndexType);
                uint32_t source[] = {11, 4, 9, ~0u, 6, 5, 6};
                auto* bytes = (uint8_t*)input.contents;
                for (uint32_t i = 0; i < vertexCount; ++i) for (uint32_t b = 0; b < indexSize; ++b) bytes[indexSize * i + b] = uint8_t(source[i] >> (8 * b));
                encoder.graphics._pipeline = &pipeline;
                encoder.graphics._indexBuffer = binding;
                encodePerVertexInput(&encoder, &pipeline, vertexCount, 2, 5, firstInstance, 0, indexKind < 0 ? nullptr : &binding, 0, -9);
                assert(buffer.result == VK_SUCCESS);
                assert(trace.replayInstances == physical && trace.replayBase == firstInstance);
                assert(trace.offsets[0] == 32 + uint64_t(firstInstance) * 16 && trace.offsets[5] == 32 + 64 + uint64_t(firstInstance) * 16);
                if (indexKind < 0) {
                    assert(trace.directInstances == physical && trace.drawBase == firstInstance);
                    assert(trace.directState == pipeline.states[views][0]);
                } else {
                    assert(trace.dispatchInstances == physical);
                    assert(trace.region.origin.x == uint32_t(-9) && trace.region.origin.y == firstInstance);
                    assert(trace.region.size.width == vertexCount && trace.region.size.height == physical);
                    assert(trace.indexedState == pipeline.states[views][restart || indexKind == 2 ? 2 : 1]);
                }
                if (restart) { assert(trace.restartInstances == physical && trace.restartBase == firstInstance && trace.restartRecords == 2 * physical); }
                {
                    auto* pairs = (uint32_t*)encoder.scratch.buffers[2].contents;
                    auto* indices = (uint32_t*)encoder.scratch.buffers[3].contents;
                    auto* corners = (uint32_t*)encoder.scratch.buffers[4].contents;
                    uint32_t replayVertices = restart ? 6 : 3;
                    for (uint32_t instance = 0; instance < physical; ++instance) for (uint32_t vertex = 0; vertex < replayVertices; ++vertex) {
                        uint32_t occurrence = instance * replayVertices + vertex;
                        uint32_t record = instance * vertexCount + vertex;
                        assert(pairs[occurrence * 2] == record && pairs[occurrence * 2 + 1] == occurrence / 3);
                        assert(indices[occurrence] == record && corners[occurrence] == vertex % 3);
                    }
                    assert(pairs[2 * replayVertices * physical] == ~0u && indices[replayVertices * physical] == ~0u);
                }
            }
        }
        trace = {};
        encoder.subpass.views = 2;
        encodePerVertexInput(&encoder, &pipeline, 3, UINT32_MAX, 0, 0, 0);
        assert(buffer.result == VK_ERROR_OUT_OF_DEVICE_MEMORY && trace.directInstances == 0 && trace.replayInstances == 0);
        for (bool dynamic : {false, true}) for (Stage stage : {kMVKGraphicsStageVertex, kMVKGraphicsStageRasterization}) for (uint32_t firstInstance : {0u, 7u, UINT32_MAX}) for (uint32_t boundStride : {0u, 24u, 48u}) {
            trace = {};
            pipeline.flags.dynamic = dynamic;
            encoder.state._vkGraphics._vertexBuffers[0].stride = boundStride;
            uint64_t stride = dynamic ? boundStride : 16;
            encoder.state.offsetZeroDivisorVertexBuffers(encoder, stage, &pipeline, firstInstance);
            assert(trace.offsets[0] == 32 + uint64_t(firstInstance) * stride && trace.offsets[5] == 32 + 64 + uint64_t(firstInstance) * stride);
            NSUInteger attributeStride = dynamic ? boundStride : MTLAttributeStrideStatic;
            assert(trace.strides[0] == attributeStride && trace.strides[5] == attributeStride);
            assert(trace.computeOffsets == (stage == kMVKGraphicsStageVertex ? 2u : 0u));
            assert(trace.renderOffsets == (stage == kMVKGraphicsStageRasterization ? 2u : 0u));
        }
        [input release];
        for (auto b : encoder.scratch.buffers) [b release];
        [(id)encoder._mtlRenderEncoder release];
        for (auto& group : pipeline.states) for (auto state : group) [state release];
        [mainState release];
    }
    puts("production direct/indexed/uint8/restart dispatch, occurrence/key/corner/replay, view variants and overflow: PASS (CPU doubles, no GPU)");
}
