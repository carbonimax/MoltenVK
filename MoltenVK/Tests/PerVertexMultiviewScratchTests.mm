// Copyright (c) 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
#include "MVKPerVertexReplay.h"
#include "MVKPerVertexScratch.h"
#include <algorithm>
#include <cassert>
#include <cstdio>
#include <functional>
using std::max;

// CPU doubles only: production recording, grouping and cursor methods are included below.
struct PhysicalDevice { bool layered = true; bool canUseInstancingForMultiview() const { return layered; } };
struct MVKDevice {
    PhysicalDevice physical;
    PhysicalDevice* _physicalDevice = &physical;
    uint32_t getMultiviewMetalPassCount(uint32_t) const;
    uint32_t getViewCountInMetalPass(uint32_t, uint32_t) const;
    void makeResident(id<MTLBuffer>) {}
    void removeResidency(id<MTLBuffer>) {}
};
static MVKDevice device;
struct Features { bool indirectDrawing = true, layeredRendering = true, multisampleLayeredRendering = true; uint64_t maxMTLBufferSize = 1ull << 30; };
static Features features;
struct MVKCommandEncoder;
struct MVKRenderSubpass {
    uint32_t mask = 0;
    uint32_t getViewMask() { return mask; }
    uint32_t getMultiviewMetalPassCount() { return max(device.getMultiviewMetalPassCount(mask), 1u); }
    VkSampleCountFlagBits getSampleCount() { return VK_SAMPLE_COUNT_1_BIT; }
};
struct MVKRenderPass {
    MVKRenderSubpass subpasses[3];
    MVKRenderSubpass* getSubpass(uint32_t i) { return &subpasses[i]; }
    void encodeSubpassDependencyBarriers(MVKCommandEncoder*, uint32_t) {}
};
enum class MVKRenderStateEnableFlag { PrimitiveRestart };
struct State { struct { bool restart = false; bool has(MVKRenderStateEnableFlag) const { return restart; } } enable; };
struct MVKGraphicsPipeline {
    State state;
    const State& getStaticStateData() { return state; }
    struct Layout { uint32_t stride = 16; };
    Layout getPerVertexCapturedLayout() { return {}; }
    VkPrimitiveTopology getVkPrimitiveTopology() { return VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST; }
    bool usesPortableBarycentrics() { return true; }
};
template<typename T> using MVKArrayRef = std::vector<std::remove_const_t<T>>;
struct MVKCommand {
    MVKCommand* _next = nullptr;
    std::function<void(MVKCommandEncoder*)> action;
    void encode(MVKCommandEncoder* encoder) { action(encoder); }
};
struct MVKCommandBuffer {
    MVKGraphicsPipeline* _recordedPerVertexPipeline = nullptr;
    bool _doesContinueRenderPass = false, _needsInheritedPerVertexAttachments = false;
    bool _needsVisibilityResultMTLBuffer = false, _hasStageCounterTimestampCommand = false, _immediateCmdEncoder = false;
    VkIndexType _recordedIndexType = VK_INDEX_TYPE_UINT8;
    struct { uint32_t subpassViewMask = 0; } _currentSubpassInfo;
    VkCommandBufferInheritanceInfo _secondaryInheritanceInfo{};
    VkCommandBufferInheritanceRenderingInfo _secondaryInheritanceRenderingInfo{};
    std::vector<MVKPerVertexScratchRequest> _perVertexScratchRequests;
    std::vector<size_t> prefillStarts;
    MVKCommand* _head = nullptr;
    VkResult result = VK_SUCCESS;
    uint32_t getViewMask() const;
    uint32_t getViewCount() const;
    MVKDevice* getDevice() { return &device; }
    const Features& getMetalFeatures() { return features; }
    VkResult reportError(VkResult error, const char*) { return error; }
    VkResult getConfigurationResult() { return result; }
    void setConfigurationResult(VkResult error) { result = error; }
    VkResult validateIndexedPerVertexAttachments() { return VK_SUCCESS; }
    VkResult reservePrefilledPerVertexScratch(size_t first) { prefillStarts.push_back(first); return VK_SUCCESS; }
    VkResult recordPerVertexDraw(uint32_t, uint32_t, bool = false);
    VkResult recordExecuteCommands(MVKArrayRef<MVKCommandBuffer*const>);
    void beginSecondaryEncoding(MVKCommandEncoder*) {}
};
enum MVKCommandUse { kMVKCommandUseNextSubpass };
struct Context {
    MVKPerVertexScratchReservations* perVertexScratch = nullptr;
    size_t nextPerVertexScratch = 0;
    MVKRenderPass* pass = nullptr;
    MVKRenderPass* getRenderPass() { return pass; }
};
struct MVKCommandEncoder {
    Context* _pEncodingContext;
    MVKCommandBuffer* _cmdBuffer;
    id<MTLCommandBuffer> _mtlCmdBuffer = nil;
    MVKCommand* _lastMultiviewPassCmd = nullptr;
    size_t _firstSubpassPerVertexScratch = 0;
    uint32_t _multiviewPassIndex = 0, _renderSubpassIndex = 0;
    VkSubpassContents _subpassContents{};
    bool _canUseLayeredRendering = false;
    MVKDevice* getDevice() { return &device; }
    const Features& getMetalFeatures() { return features; }
    MVKRenderSubpass* getSubpass() { return _pEncodingContext->pass->getSubpass(_renderSubpassIndex); }
    void encodeStoreActions() {}
    void endCurrentMetalEncoding() {}
    void beginMetalRenderPass(MVKCommandUse) {}
    MVKPerVertexScratch* nextPerVertexScratch();
    void setSubpass(MVKCommand*, VkSubpassContents, uint32_t, MVKCommandUse);
    void beginNextMultiviewPass();
    void encodeCommandsImpl(MVKCommand*);
    void encodeSecondary(MVKCommandBuffer*);
};
uint32_t mvkGetNextViewMaskGroup(uint32_t, uint32_t*, uint32_t*, uint32_t* = nullptr);
#include "MultiviewScratchMethods.inc"

int main() {
    @autoreleasepool {
        MVKGraphicsPipeline pipeline;
        MVKRenderPass pass;
        pass.subpasses[0].mask = 0x13; // Two contiguous views, then one sparse view.
        pass.subpasses[1].mask = 0x80000001;
        MVKCommandBuffer primary, secondary;
        primary._recordedPerVertexPipeline = secondary._recordedPerVertexPipeline = &pipeline;
        primary._currentSubpassInfo.subpassViewMask = 0x13;
        secondary._doesContinueRenderPass = true;
        secondary._secondaryInheritanceRenderingInfo.viewMask = 0x13;
        assert(secondary.recordPerVertexDraw(6, 2, true) == VK_SUCCESS);
        assert(secondary.getViewCount() == 3);
        assert(primary.recordPerVertexDraw(3, 2) == VK_SUCCESS);
        assert(primary.recordExecuteCommands({&secondary, &secondary}) == VK_SUCCESS);
        assert(primary.recordPerVertexDraw(9, 2) == VK_SUCCESS);
        // Baseline has four requests, so later passes consume another draw's buffers.
        assert(primary._perVertexScratchRequests.size() == 8 && "one distinct reservation per draw and Metal view group");
        const auto& requests = primary._perVertexScratchRequests;
        assert(requests[0].captureSize == 3 * 2 * 2 * 16 && requests[1].captureSize == 3 * 2 * 16);
        assert(requests[2].captureSize == 6 * 2 * 2 * 16 && requests[3].captureSize == 6 * 2 * 16);
        assert(requests[2].occurrenceSize == 6 * 2 * 2 * 8 && requests[2].cornerSize == 6 * 2 * 2 * 4);
        assert(requests[2].indexSize == 6 * 2); // Widen source indices once per group, not per view.
        primary._currentSubpassInfo.subpassViewMask = pass.subpasses[1].mask;
        assert(primary.recordPerVertexDraw(12, 2) == VK_SUCCESS);
        primary._currentSubpassInfo.subpassViewMask = 0;
        assert(primary.recordPerVertexDraw(3, 1) == VK_SUCCESS);
        assert(primary._perVertexScratchRequests.size() == 11);
        for (int submission = 0; submission < 2; ++submission) {
            MVKPerVertexScratchReservations reservations;
            for (size_t i = 0; i < requests.size(); ++i) { reservations.push_back(std::make_shared<MVKPerVertexScratch>()); }
            Context context{&reservations, 0, &pass};
            MVKCommandEncoder encoder{&context, &primary};
            std::vector<size_t> selected;
            auto draw = [&](MVKCommandEncoder* e) {
                auto* scratch = e->nextPerVertexScratch();
                assert(scratch);
                auto found = std::find_if(reservations.begin(), reservations.end(), [&](const auto& r) { return r.get() == scratch; });
                selected.push_back(found - reservations.begin());
            };
            MVKCommand secondaryDraw{nullptr, draw};
            secondary._head = &secondaryDraw;
            MVKCommand commands[8];
            for (size_t i = 0; i < 7; ++i) { commands[i]._next = &commands[i + 1]; }
            commands[0].action = [&](auto* e) { e->setSubpass(&commands[0], VK_SUBPASS_CONTENTS_INLINE, 0, kMVKCommandUseNextSubpass); };
            commands[1].action = draw;
            commands[2].action = [&](auto* e) { e->encodeSecondary(&secondary); e->encodeSecondary(&secondary); };
            commands[3].action = draw;
            commands[4].action = [&](auto* e) {
                if (e->_multiviewPassIndex + 1 < e->getSubpass()->getMultiviewMetalPassCount()) { e->beginNextMultiviewPass(); }
                else { e->setSubpass(&commands[4], VK_SUBPASS_CONTENTS_INLINE, 1, kMVKCommandUseNextSubpass); }
            };
            commands[5].action = draw;
            commands[6].action = [&](auto* e) {
                if (e->_multiviewPassIndex + 1 < e->getSubpass()->getMultiviewMetalPassCount()) { e->beginNextMultiviewPass(); }
                else { e->setSubpass(&commands[6], VK_SUBPASS_CONTENTS_INLINE, 2, kMVKCommandUseNextSubpass); }
            };
            commands[7].action = draw;
            encoder.encodeCommandsImpl(commands);
            assert((selected == std::vector<size_t>{0, 2, 4, 6, 1, 3, 5, 7, 8, 9, 10}));
            assert(context.nextPerVertexScratch == reservations.size());
            assert(!encoder.nextPerVertexScratch() && primary.result == VK_ERROR_INITIALIZATION_FAILED);
            primary.result = VK_SUCCESS;
        }
        // Reject a product that fits per application instance but not after view expansion.
        primary._currentSubpassInfo.subpassViewMask = 3;
        size_t saved = requests.size();
        assert(primary.recordPerVertexDraw(1, UINT32_MAX / 2 + 1) == VK_ERROR_OUT_OF_DEVICE_MEMORY);
        assert(requests.size() == saved);
        primary._currentSubpassInfo.subpassViewMask = 0xd; // First group fits; second must fail transactionally.
        features.maxMTLBufferSize = 64;
        assert(primary.recordPerVertexDraw(3, 1) == VK_ERROR_OUT_OF_DEVICE_MEMORY);
        assert(requests.size() == saved);
        features.maxMTLBufferSize = 1ull << 30;
        primary._currentSubpassInfo.subpassViewMask = 0x13;
        primary._immediateCmdEncoder = true;
        assert(primary.recordPerVertexDraw(3, 1) == VK_SUCCESS);
        assert(primary.prefillStarts.back() == saved);
        assert(requests.size() == saved + 2);
        saved = requests.size();
        assert(primary.recordPerVertexDraw(0, 2) == VK_SUCCESS);
        assert(primary.recordPerVertexDraw(3, 0) == VK_SUCCESS);
        primary._recordedPerVertexPipeline = nullptr;
        assert(primary.recordPerVertexDraw(3, 2) == VK_SUCCESS && requests.size() == saved);
        // Traditional render-pass inheritance and non-layered one-view-per-pass devices.
        secondary._secondaryInheritanceInfo.renderPass = (VkRenderPass)&pass;
        device.physical.layered = false;
        secondary._perVertexScratchRequests.clear();
        assert(secondary.recordPerVertexDraw(3, 2) == VK_SUCCESS);
        assert(secondary._perVertexScratchRequests.size() == 3);
        for (auto& r : secondary._perVertexScratchRequests) { assert(r.captureSize == 3 * 2 * 16); }
        puts("PASS: production multiview scratch recording, sparse/high views, secondary reuse, subpass replay, repeat submission, expanded bounds and prefill reservation start (CPU ASan/UBSan)");
    }
}
