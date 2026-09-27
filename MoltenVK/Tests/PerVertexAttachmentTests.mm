// Copyright (c) 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
#include <utility>
#include "MVKSmallVector.h"
#include "MVKPerVertexReplay.h"
#include "MVKPerVertexScratch.h"
#include <cassert>
#include <cstdio>
#include <functional>

struct MVKImage {
	MTLStorageMode storage = MTLStorageModePrivate;
	MTLStorageMode getMTLStorageMode() { return storage; }
};
struct MVKImageView {
	MVKImage image;
	VkSampleCountFlagBits samples = VK_SAMPLE_COUNT_1_BIT;
	MVKImage* getImage() { return &image; }
	VkSampleCountFlagBits getSampleCount() { return samples; }
};
struct MVKFramebuffer {
	MVKSmallVector<MVKImageView*, 4> attachments;
	MVKArrayRef<MVKImageView*> getAttachments() { return attachments.contents(); }
};
struct MVKRenderSubpass {
	VkSampleCountFlagBits samples = VK_SAMPLE_COUNT_1_BIT;
	VkSampleCountFlagBits getSampleCount() { return samples; }
};
struct MVKRenderPass {
	MVKRenderSubpass subpass;
	MVKRenderSubpass* getSubpass(uint32_t) { return &subpass; }
};
struct MVKCurrentSubpassInfo {
	MVKRenderPass* renderpass = nullptr;
	uint32_t subpassIndex = 0;
	void beginRenderpass(MVKRenderPass* pass) { renderpass = pass; subpassIndex = 0; }
};
using MVKRenderingAttachmentInfoOperation = std::function<void(const VkRenderingAttachmentInfo*, VkImageAspectFlagBits, MVKImageView*, bool)>;
struct MVKRenderingAttachmentIterator {
	VkRenderingInfo _renderingInfo;
	MVKRenderingAttachmentIterator(const VkRenderingInfo*);
	void iterate(MVKRenderingAttachmentInfoOperation);
	void handleAttachment(const VkRenderingAttachmentInfo*, VkImageAspectFlagBits, MVKRenderingAttachmentInfoOperation);
};
enum class MVKRenderStateEnableFlag { PrimitiveRestart };
struct TestEnable { bool has(MVKRenderStateEnableFlag) const { return false; } };
struct TestState { TestEnable enable; };
struct TestLayout { uint32_t stride = 16; };
struct MVKGraphicsPipeline {
	TestState getStaticStateData() { return {}; }
	TestLayout getPerVertexCapturedLayout() { return {}; }
	VkPrimitiveTopology getVkPrimitiveTopology() { return VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST; }
	bool usesPortableBarycentrics() { return false; }
};
struct TestFeatures { bool indirectDrawing = true; uint64_t maxMTLBufferSize = 1 << 20; };
struct MVKCommandEncoder;
struct MVKCommand {
	MVKCommand* _next = nullptr;
	bool rejected = false;
	void encode(MVKCommandEncoder*);
};
struct MVKCommandBuffer {
	MVKCommand* _head = nullptr;
	bool _recordedAttachmentsKnown = false, _doesContinueRenderPass = false, _needsInheritedPerVertexAttachments = false;
	bool _needsVisibilityResultMTLBuffer = false, _hasStageCounterTimestampCommand = false, _hasSecondaryInheritanceRenderingInfo = false;
	bool _immediateCmdEncoder = false;
	const char* _recordedRenderingError = nullptr;
	VkIndexType _recordedIndexType = VK_INDEX_TYPE_UINT16;
	MVKGraphicsPipeline* _recordedPerVertexPipeline = nullptr;
	MVKCurrentSubpassInfo _currentSubpassInfo;
	VkCommandBufferInheritanceInfo _secondaryInheritanceInfo{};
	VkCommandBufferInheritanceRenderingInfo _secondaryInheritanceRenderingInfo{};
	std::vector<MVKPerVertexScratchRequest> _perVertexScratchRequests;
	TestFeatures getMetalFeatures() { return {}; }
	VkResult getConfigurationResult() { return VK_SUCCESS; }
	VkResult reportError(VkResult result, const char*, ...) { return result; }
	VkResult reservePrefilledPerVertexScratch(size_t) { return VK_SUCCESS; }
	void recordRenderPass(MVKArrayRef<MVKImageView*>, bool = true);
	void recordRendering(const VkRenderingInfo*);
	VkResult validateIndexedPerVertexAttachments();
	VkResult recordPerVertexDraw(uint32_t, uint32_t, bool = false);
	VkResult recordExecuteCommands(MVKArrayRef<MVKCommandBuffer*const>);
	void inherit();
	void beginSecondaryEncoding(MVKCommandEncoder*) {}
};
struct TestContext {
	MVKRenderPass* pass = nullptr;
	MVKFramebuffer* framebuffer = nullptr;
	void setRenderingContext(MVKRenderPass* rp, MVKFramebuffer* fb) { pass = rp; framebuffer = fb; }
	MVKFramebuffer* getFramebuffer() { return framebuffer; }
};
struct MVKCommandEncoder {
	TestContext context;
	TestContext* _pEncodingContext = &context;
	VkRect2D _renderArea{};
	bool _isRenderingEntireAttachment = false;
	MVKSmallVector<VkClearValue, 4> _clearValues;
	MVKSmallVector<MVKImageView*, 4> _attachments;
	bool isInRenderPass() { return context.pass != nullptr; }
	MVKRenderSubpass* getSubpass() { return context.pass->getSubpass(0); }
	VkExtent2D getFramebufferExtent() { return {32, 32}; }
	void setSubpass(MVKCommand*, VkSubpassContents, uint32_t, MVKCommandUse) {}
	const char* getIndexedPerVertexAttachmentError();
	void encodeSecondary(MVKCommandBuffer*);
	void beginRenderpass(MVKCommand*, VkSubpassContents, MVKRenderPass*, MVKFramebuffer*, const VkRect2D&, MVKArrayRef<VkClearValue>, MVKArrayRef<MVKImageView*>, MVKCommandUse);
};
struct MVKCmdBeginRenderPassBase {
	VkSubpassContents _contents;
	MVKRenderPass* _renderPass;
	MVKFramebuffer* _framebuffer;
	VkRect2D _renderArea;
	VkResult setContent(MVKCommandBuffer*, const VkRenderPassBeginInfo*, const VkSubpassBeginInfo*);
};
template <size_t N_CV, size_t N_A> struct MVKCmdBeginRenderPass : MVKCmdBeginRenderPassBase {
	MVKSmallVector<MVKImageView*, N_A> _attachments;
	MVKSmallVector<VkClearValue, N_CV> _clearValues;
	VkResult setContent(MVKCommandBuffer*, const VkRenderPassBeginInfo*, const VkSubpassBeginInfo*, MVKArrayRef<MVKImageView*>);
};
struct MVKCmdEndRenderPass { VkResult setContent(MVKCommandBuffer*); };
struct MVKCmdEndRendering { VkResult setContent(MVKCommandBuffer*); };
#include "AttachmentMethods.inc"

void MVKCommand::encode(MVKCommandEncoder* encoder) { rejected = encoder->getIndexedPerVertexAttachmentError() != nullptr; }

static void begin(MVKCommandBuffer& cb, MVKCommandEncoder& encoder, MVKRenderPass& pass, MVKFramebuffer& framebuffer, MVKArrayRef<MVKImageView*> views, bool imageless) {
	VkRenderPassAttachmentBeginInfo viewInfo{};
	viewInfo.sType = VK_STRUCTURE_TYPE_RENDER_PASS_ATTACHMENT_BEGIN_INFO;
	viewInfo.attachmentCount = uint32_t(views.size());
	viewInfo.pAttachments = reinterpret_cast<const VkImageView*>(views.data());
	VkRenderPassBeginInfo info{};
	info.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
	info.pNext = imageless ? &viewInfo : nullptr;
	info.renderPass = reinterpret_cast<VkRenderPass>(&pass);
	info.framebuffer = reinterpret_cast<VkFramebuffer>(&framebuffer);
	info.renderArea.extent = {32, 32};
	VkSubpassBeginInfo subpass{};
	subpass.sType = VK_STRUCTURE_TYPE_SUBPASS_BEGIN_INFO;
	MVKCmdBeginRenderPass<1, 4> cmd;
	assert(cmd.setContent(&cb, &info, &subpass, beginViews(&info)) == VK_SUCCESS);
	encoder.beginRenderpass(nullptr, cmd._contents, cmd._renderPass, cmd._framebuffer, cmd._renderArea, cmd._clearValues.contents(), cmd._attachments.contents(), kMVKCommandUseBeginRenderPass);
}

int main() {
	MVKGraphicsPipeline pipeline;
	MVKImageView stored, memoryless, msaa;
	memoryless.image.storage = MTLStorageModeMemoryless;
	msaa.samples = VK_SAMPLE_COUNT_4_BIT;
	MVKImageView* safe[] = {&stored};
	MVKImageView* unsafe[] = {&memoryless};
	MVKCommandBuffer cb;
	cb._recordedPerVertexPipeline = &pipeline;
	MVKCommandEncoder encoder;
	MVKRenderPass pass;
	MVKFramebuffer framebuffer;
	// Unknown state is not a known empty render pass.
	assert(cb.recordPerVertexDraw(3, 1, true) == VK_ERROR_FEATURE_NOT_PRESENT);
	assert(encoder.getIndexedPerVertexAttachmentError());
	// The actual imageless view list, not the framebuffer's empty list, decides admission.
	begin(cb, encoder, pass, framebuffer, safe, true);
	assert(cb.recordPerVertexDraw(3, 1, true) == VK_SUCCESS);
	assert(!encoder.getIndexedPerVertexAttachmentError());
	begin(cb, encoder, pass, framebuffer, unsafe, true);
	assert(cb.recordPerVertexDraw(3, 1, true) == VK_ERROR_FEATURE_NOT_PRESENT);
	assert(encoder.getIndexedPerVertexAttachmentError());
	// Known zero attachments, both conventional and imageless, clear prior errors.
	for (bool imageless : {false, true}) {
		begin(cb, encoder, pass, framebuffer, {}, imageless);
		assert(cb._recordedAttachmentsKnown);
		assert(cb.recordPerVertexDraw(3, 1, true) == VK_SUCCESS);
		assert(!encoder.getIndexedPerVertexAttachmentError());
	}
	framebuffer.attachments.push_back(&stored);
	begin(cb, encoder, pass, framebuffer, {}, false);
	assert(cb.recordPerVertexDraw(3, 1, true) == VK_SUCCESS);
	assert(!encoder.getIndexedPerVertexAttachmentError());
	pass.subpass.samples = VK_SAMPLE_COUNT_4_BIT;
	assert(cb.recordPerVertexDraw(3, 1, true) == VK_ERROR_FEATURE_NOT_PRESENT);
	assert(encoder.getIndexedPerVertexAttachmentError());
	pass.subpass.samples = VK_SAMPLE_COUNT_1_BIT;
	framebuffer.attachments.clear();
	// Null-framebuffer, imageless-framebuffer, and dynamic-rendering inheritance all defer views.
	for (unsigned mode = 0; mode < 3; ++mode) {
		MVKCommandBuffer secondary;
		secondary._doesContinueRenderPass = true;
		secondary._recordedPerVertexPipeline = &pipeline;
		secondary._secondaryInheritanceInfo.renderPass = mode == 2 ? VK_NULL_HANDLE : reinterpret_cast<VkRenderPass>(&pass);
		secondary._secondaryInheritanceInfo.framebuffer = mode == 1 ? reinterpret_cast<VkFramebuffer>(&framebuffer) : VK_NULL_HANDLE;
		secondary._hasSecondaryInheritanceRenderingInfo = mode == 2;
		secondary._secondaryInheritanceRenderingInfo.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;
		secondary.inherit();
		assert(!secondary._recordedAttachmentsKnown);
		assert(secondary.recordPerVertexDraw(3, 1, true) == VK_SUCCESS);
		assert(secondary._needsInheritedPerVertexAttachments);
		MVKCommandBuffer* secondaries[] = {&secondary};
		MVKCommand draw;
		secondary._head = &draw;
		begin(cb, encoder, pass, framebuffer, safe, true);
		assert(cb.recordExecuteCommands(secondaries) == VK_SUCCESS);
		encoder.encodeSecondary(&secondary);
		assert(!draw.rejected);
		begin(cb, encoder, pass, framebuffer, unsafe, true);
		assert(cb.recordExecuteCommands(secondaries) == VK_ERROR_FEATURE_NOT_PRESENT);
		encoder.encodeSecondary(&secondary);
		assert(draw.rejected);
		begin(cb, encoder, pass, framebuffer, {}, false);
		assert(cb.recordExecuteCommands(secondaries) == VK_SUCCESS);
		encoder.encodeSecondary(&secondary);
		assert(!draw.rejected);
		pass.subpass.samples = VK_SAMPLE_COUNT_4_BIT;
		assert(cb.recordExecuteCommands(secondaries) == VK_ERROR_FEATURE_NOT_PRESENT);
		pass.subpass.samples = VK_SAMPLE_COUNT_1_BIT;
		// Dynamic inheritance's sample count is checked even while its views are unknown.
		if (mode == 2) {
			secondary._secondaryInheritanceRenderingInfo.rasterizationSamples = VK_SAMPLE_COUNT_4_BIT;
			secondary.inherit();
			assert(secondary.recordPerVertexDraw(3, 1, true) == VK_ERROR_FEATURE_NOT_PRESENT);
		}
	}
	// A conventional inherited framebuffer is inspectable while recording the secondary.
	MVKCommandBuffer inherited;
	inherited._doesContinueRenderPass = true;
	inherited._recordedPerVertexPipeline = &pipeline;
	inherited._secondaryInheritanceInfo.renderPass = reinterpret_cast<VkRenderPass>(&pass);
	inherited._secondaryInheritanceInfo.framebuffer = reinterpret_cast<VkFramebuffer>(&framebuffer);
	framebuffer.attachments.push_back(&memoryless);
	inherited.inherit();
	assert(inherited._recordedAttachmentsKnown);
	assert(inherited.recordPerVertexDraw(3, 1, true) == VK_ERROR_FEATURE_NOT_PRESENT);
	framebuffer.attachments[0] = &stored;
	inherited.inherit();
	assert(inherited.recordPerVertexDraw(3, 1, true) == VK_SUCCESS);
	VkRenderingInfo rendering{};
	rendering.sType = VK_STRUCTURE_TYPE_RENDERING_INFO;
	cb._currentSubpassInfo = {};
	cb.recordRendering(&rendering);
	assert(cb._recordedAttachmentsKnown && cb.recordPerVertexDraw(3, 1, true) == VK_SUCCESS);
	VkRenderingAttachmentInfo color{};
	color.sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO;
	rendering.colorAttachmentCount = 1;
	rendering.pColorAttachments = &color;
	cb.recordRendering(&rendering); // Explicit null imageView is also valid empty rendering.
	assert(cb.recordPerVertexDraw(3, 1, true) == VK_SUCCESS);
	color.imageView = reinterpret_cast<VkImageView>(&memoryless);
	cb.recordRendering(&rendering);
	assert(cb.recordPerVertexDraw(3, 1, true) == VK_ERROR_FEATURE_NOT_PRESENT);
	color.imageView = reinterpret_cast<VkImageView>(&msaa);
	color.resolveMode = VK_RESOLVE_MODE_AVERAGE_BIT;
	color.resolveImageView = reinterpret_cast<VkImageView>(&stored);
	cb.recordRendering(&rendering);
	assert(cb.recordPerVertexDraw(3, 1, true) == VK_ERROR_FEATURE_NOT_PRESENT);
	// End commands must not leave a previously valid empty rendering scope known.
	MVKCmdEndRenderPass{}.setContent(&cb);
	assert(!cb._recordedAttachmentsKnown && cb.recordPerVertexDraw(3, 1, true) == VK_ERROR_FEATURE_NOT_PRESENT);
	cb.recordRendering(&rendering);
	MVKCmdEndRendering{}.setContent(&cb);
	assert(!cb._recordedAttachmentsKnown && !cb._recordedRenderingError);
	puts("PASS: production attachment flow/admission; imageless and zero views; inherited primary revalidation; memoryless and MSAA/resolve rejection (CPU only)");
}
