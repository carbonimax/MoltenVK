// Copyright (c) 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
#include <utility>
#include "MVKSmallVector.h"
#import <Metal/Metal.h>
#include <cstdio>

// CPU doubles replace Metal/device objects, not the store/load decisions under test.
struct MVKBaseObject {
	static void reportError(MVKBaseObject*, VkResult, const char*, ...) { assert(false); }
};
struct MVKRenderPass;
struct MVKRenderSubpass;
struct MVKCommandEncoder;
using MVKMTLFmtCaps = uint32_t;
constexpr MVKMTLFmtCaps kMVKMTLFmtCapsResolve = 1;
struct MVKPixelFormats {
	uint32_t getCapabilities(MTLPixelFormat) { return kMVKMTLFmtCapsResolve; }
	bool isDepthFormat(MTLPixelFormat format) { return format == MTLPixelFormatDepth32Float; }
	bool isStencilFormat(MTLPixelFormat format) { return format == MTLPixelFormatStencil8; }
};
struct MVKImage {
	MTLStorageMode storage = MTLStorageModePrivate;
	MTLPixelFormat format = MTLPixelFormatRGBA8Unorm;
	MTLStorageMode getMTLStorageMode() { return storage; }
	MTLPixelFormat getMTLPixelFormat() { return format; }
};
struct MVKImageView {
	MVKImage image;
	MVKImage* getImage() { return &image; }
	MTLPixelFormat getMTLPixelFormat() { return image.format; }
	void populateMTLRenderPassAttachmentDescriptor(MTLRenderPassAttachmentDescriptor*) {}
};
struct MVKAttachmentDescription {
	MVKRenderPass* _renderPass = nullptr;
	VkAttachmentDescription2 _info{};
	bool isFirstUseOfAttachment(MVKRenderSubpass*) { return true; }
	bool isLastUseOfAttachment(MVKRenderSubpass*) { return true; }
	MTLStoreAction getMTLStoreAction(MVKRenderSubpass*, bool, bool, bool, bool, bool, bool);
	void encodeStoreAction(MVKCommandEncoder*, MVKRenderSubpass*, MVKImageView*, bool, bool, bool, uint32_t, bool, bool);
	bool populateMTLRenderPassAttachmentDescriptor(MTLRenderPassAttachmentDescriptor*, MVKRenderSubpass*, MVKImageView*, bool, bool, bool, bool, bool);
};
struct MVKRenderPass {
	struct Features { bool combinedStoreResolveAction = false; } features;
	VkRenderingFlags flags = 0;
	MVKPixelFormats formats;
	MVKSmallVector<MVKAttachmentDescription, 4> _attachments;
	Features& getMetalFeatures() { return features; }
	VkRenderingFlags getRenderingFlags() { return flags; }
	MVKPixelFormats* getPixelFormats() { return &formats; }
};
struct MVKRenderSubpass {
	MVKRenderPass* _renderPass = nullptr;
	MVKSmallVector<VkAttachmentReference2, 4> _colorAttachments, _resolveAttachments;
	VkAttachmentReference2 _depthAttachment{}, _stencilAttachment{}, _depthResolveAttachment{}, _stencilResolveAttachment{};
	VkResolveModeFlagBits _depthResolveMode = VK_RESOLVE_MODE_NONE, _stencilResolveMode = VK_RESOLVE_MODE_NONE;
	uint32_t getColorAttachmentCount() { return uint32_t(_colorAttachments.size()); }
	void encodeStoreActions(MVKCommandEncoder*, bool, MVKArrayRef<MVKImageView*const>, bool);
	unsigned softwareResolveCalls = 0;
	void resolveUnresolvableAttachments(MVKCommandEncoder*, MVKArrayRef<MVKImageView*>) { ++softwareResolveCalls; }
};
@interface StoreEncoder : NSObject {
@public
	MTLStoreAction colors[3], depth, stencil;
}
- (void)setColorStoreAction:(MTLStoreAction)action atIndex:(NSUInteger)index;
- (void)setDepthStoreAction:(MTLStoreAction)action;
- (void)setStencilStoreAction:(MTLStoreAction)action;
- (void)updateFence:(id)fence afterStages:(MTLRenderStages)stages;
@end
@implementation StoreEncoder
- (void)setColorStoreAction:(MTLStoreAction)action atIndex:(NSUInteger)index { colors[index] = action; }
- (void)setDepthStoreAction:(MTLStoreAction)action { depth = action; }
- (void)setStencilStoreAction:(MTLStoreAction)action { stencil = action; }
- (void)updateFence:(id)fence afterStages:(MTLRenderStages)stages {}
@end
struct MVKCommandEncoder {
	bool _isIndexedDraw = false, _isPerVertexRenderSplit = false;
	struct Pipeline { bool portable = false; bool usesPerVertexInputBuffer() { return portable; } } pipeline;
	Pipeline* getGraphicsPipeline() { return &pipeline; }
	struct CommandBuffer { bool _hasStageCounterTimestampCommand = false; } commandBuffer;
	CommandBuffer* _cmdBuffer = &commandBuffer;
	id<MTLFence> getStageCountersMTLFence() { return nil; }
	void encodeBarrierUpdates() {}
	void endMetalEncoding(StoreEncoder*& encoder) { encoder = nil; }
	void endCurrentMetalEncoding() { endMetalRenderEncoding(); }
	void endMetalRenderEncoding();
	MVKRenderSubpass subpass;
	StoreEncoder* _mtlRenderEncoder = nil;
	bool _isRenderingEntireAttachment = true;
	MVKSmallVector<MVKImageView*, 4> _attachments;
	MTLStoreAction atSplit[4]{};
	struct QueryState { void encode(StoreEncoder*, MVKCommandEncoder*) {} void endMetalRenderPass(MVKCommandEncoder*) {} } _occlusionQueryState;
	MVKRenderSubpass* getSubpass() { return &subpass; }
	MVKPixelFormats* getPixelFormats() { return subpass._renderPass->getPixelFormats(); }
	void prepareDraw() {}
	void prepareRenderDispatch(MVKGraphicsStage) {}
	void getMTLComputeEncoder(MVKCommandUse) {
		atSplit[0] = _mtlRenderEncoder->colors[0];
		atSplit[1] = _mtlRenderEncoder->colors[2];
		atSplit[2] = _mtlRenderEncoder->depth;
		atSplit[3] = _mtlRenderEncoder->stencil;
	}
	void encodeStoreActions(bool);
	void finalizeDrawState(MVKGraphicsStage);
};
#include "MultisampleStoreMethods.inc"

int main() {
	@autoreleasepool {
		MVKRenderPass pass;
		MVKCommandEncoder encoder;
		encoder.subpass._renderPass = &pass;
		encoder._mtlRenderEncoder = [StoreEncoder new];
		auto reference = [](uint32_t index) { VkAttachmentReference2 ref{}; ref.attachment = index; return ref; };
		for (auto index : {0u, VK_ATTACHMENT_UNUSED, 1u}) { encoder.subpass._colorAttachments.push_back(reference(index)); }
		encoder.subpass._depthAttachment = reference(2);
		encoder.subpass._stencilAttachment = reference(3);
		encoder.subpass._depthResolveAttachment = encoder.subpass._stencilResolveAttachment = reference(VK_ATTACHMENT_UNUSED);
		MVKImageView images[4];
		images[2].image.format = MTLPixelFormatDepth32Float;
		images[3].image.format = MTLPixelFormatStencil8;
		for (auto& image : images) {
			encoder._attachments.push_back(&image);
			MVKAttachmentDescription attachment;
			attachment._renderPass = &pass;
			pass._attachments.push_back(attachment);
		}
		for (auto samples : {VK_SAMPLE_COUNT_2_BIT, VK_SAMPLE_COUNT_4_BIT, VK_SAMPLE_COUNT_8_BIT}) {
			for (bool combined : {false, true}) {
				pass.features.combinedStoreResolveAction = combined;
				for (auto storeOp : {VK_ATTACHMENT_STORE_OP_DONT_CARE, VK_ATTACHMENT_STORE_OP_STORE, VK_ATTACHMENT_STORE_OP_NONE}) {
					for (auto loadOp : {VK_ATTACHMENT_LOAD_OP_CLEAR, VK_ATTACHMENT_LOAD_OP_DONT_CARE, VK_ATTACHMENT_LOAD_OP_LOAD}) {
						for (auto& attachment : pass._attachments) {
							attachment._info.samples = samples;
							attachment._info.storeOp = attachment._info.stencilStoreOp = storeOp;
							attachment._info.loadOp = attachment._info.stencilLoadOp = loadOp;
						}
						encoder._mtlRenderEncoder->colors[0] = encoder._mtlRenderEncoder->colors[1] = encoder._mtlRenderEncoder->colors[2] = MTLStoreActionUnknown;
						encoder._mtlRenderEncoder->depth = encoder._mtlRenderEncoder->stencil = MTLStoreActionUnknown;
						encoder.finalizeDrawState(kMVKGraphicsStageVertex);
						// The production split must request Store for every active aspect BEFORE compute starts.
						// Store retains multisample image data, unlike MultisampleResolve or DontCare.
						for (auto action : encoder.atSplit) { assert(action == MTLStoreActionStore); }
						assert(encoder._mtlRenderEncoder->colors[1] == MTLStoreActionUnknown); // unused slot
						for (unsigned i = 0; i < 4; ++i) {
							auto* descriptor = [MTLRenderPassColorAttachmentDescriptor new];
							bool clear = pass._attachments[i].populateMTLRenderPassAttachmentDescriptor(descriptor, &encoder.subpass, &images[i], true, false, false, i == 3, true);
							assert(!clear && descriptor.loadAction == MTLLoadActionLoad);
							[descriptor release];
						}
						encoder.encodeStoreActions(false); // Actual end-of-pass is still allowed to discard.
						if (storeOp == VK_ATTACHMENT_STORE_OP_DONT_CARE) {
							assert(encoder._mtlRenderEncoder->colors[0] == MTLStoreActionDontCare);
							assert(encoder._mtlRenderEncoder->depth == MTLStoreActionDontCare && encoder._mtlRenderEncoder->stencil == MTLStoreActionDontCare);
						}
					}
				}
			}
		}
		// The unchanged selector alone would resolve too early, even with a store override.
		auto& attachment = pass._attachments[0];
		pass.features.combinedStoreResolveAction = false;
		assert(attachment.getMTLStoreAction(&encoder.subpass, true, false, true, true, false, true) == MTLStoreActionMultisampleResolve);
		pass.features.combinedStoreResolveAction = true;
		assert(attachment.getMTLStoreAction(&encoder.subpass, true, false, true, true, false, true) == MTLStoreActionStoreAndMultisampleResolve);
		assert(attachment.getMTLStoreAction(&encoder.subpass, true, true, false, false, false, true) == MTLStoreActionDontCare);
		// Active color + depth + stencil resolve attachments: store-only at each indexed split,
		// normal final resolve at the Vulkan boundary. Ordinary/tessellation splits stay unchanged.
		for (auto ref : {reference(0), reference(VK_ATTACHMENT_UNUSED), reference(1)}) { encoder.subpass._resolveAttachments.push_back(ref); }
		encoder.subpass._depthResolveAttachment = reference(2);
		encoder.subpass._stencilResolveAttachment = reference(3);
		encoder.subpass._depthResolveMode = encoder.subpass._stencilResolveMode = VK_RESOLVE_MODE_SAMPLE_ZERO_BIT;
		StoreEncoder* metal = encoder._mtlRenderEncoder;
		for (bool combined : {false, true}) {
			pass.features.combinedStoreResolveAction = combined;
			for (bool portable : {false, true}) {
				for (bool indexed : {false, true}) {
					encoder.pipeline.portable = portable;
					encoder._isIndexedDraw = indexed;
					bool deferred = portable && indexed;
					encoder.subpass.softwareResolveCalls = 0;
					for (unsigned split = 0; split < 2; ++split) {
						encoder._mtlRenderEncoder = metal;
						encoder.finalizeDrawState(kMVKGraphicsStageVertex);
						MTLStoreAction expected = deferred ? MTLStoreActionStore : combined ? MTLStoreActionStoreAndMultisampleResolve : MTLStoreActionMultisampleResolve;
						for (auto action : encoder.atSplit) { assert(action == expected); }
						encoder.endMetalRenderEncoding();
						assert(!encoder._isPerVertexRenderSplit && !encoder._mtlRenderEncoder);
						assert(encoder.subpass.softwareResolveCalls == (deferred ? 0 : split + 1));
						for (unsigned i = 0; i < 4; ++i) {
							auto* descriptor = [MTLRenderPassColorAttachmentDescriptor new];
							bool clear = pass._attachments[i].populateMTLRenderPassAttachmentDescriptor(descriptor, &encoder.subpass, &images[i], true, true, true, i == 3, true);
							assert(!clear && descriptor.loadAction == MTLLoadActionLoad);
							[descriptor release];
						}
						// Re-entrant/repeated endings and repeated compute-stage preparation cannot leak state.
						encoder.endMetalRenderEncoding();
					}
					unsigned finalEnds = 0;
					for (auto storeOp : {VK_ATTACHMENT_STORE_OP_STORE, VK_ATTACHMENT_STORE_OP_DONT_CARE}) {
						for (auto& description : pass._attachments) { description._info.storeOp = description._info.stencilStoreOp = storeOp; }
						encoder._mtlRenderEncoder = metal; // Replay restart; actual production Load was checked above.
						encoder.encodeStoreActions(false); // EndRenderPass/NextSubpass/EndRendering boundary.
						MTLStoreAction finalAction = combined && storeOp == VK_ATTACHMENT_STORE_OP_STORE ? MTLStoreActionStoreAndMultisampleResolve : MTLStoreActionMultisampleResolve;
						assert(metal->colors[0] == finalAction && metal->colors[2] == finalAction && metal->depth == finalAction && metal->stencil == finalAction);
						encoder.endMetalRenderEncoding();
						assert(encoder.subpass.softwareResolveCalls == (deferred ? 0 : 2) + ++finalEnds);
					}
				}
			}
		}
		[metal release];
		puts("PASS: production split Store and restart Load for all active MSAA color/depth/stencil aspects; final discard retained; PerVertex-only intermediate resolve suppression and final-boundary resolve; non-PerVertex unchanged (CPU only)");
	}
}
