// Copyright (c) 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
#include <utility>
#include "MVKSmallVector.h"
#include "MVKPerVertexReplay.h"
#include "MVKPerVertexScratch.h"
#include <cassert>
#include <cstdio>
#include <functional>

static MVKPhysicalDeviceMetalFeatures testFeatures = [] { MVKPhysicalDeviceMetalFeatures f{}; f.indirectDrawing = true; f.maxMTLBufferSize = 1 << 20; return f; }();
constexpr uint32_t kMVKMTLFmtCapsResolve = 1;
struct MVKPixelFormats {
	uint32_t getCapabilities(VkFormat format) { return format == VK_FORMAT_R8G8B8A8_UINT ? 0 : kMVKMTLFmtCapsResolve; }
};
static MVKPixelFormats testFormats;
struct MVKImage {
	MTLStorageMode storage = MTLStorageModePrivate;
	MTLStorageMode getMTLStorageMode() { return storage; }
};
struct MVKImageView {
	MVKImage image;
	MTLPixelFormat format = MTLPixelFormatRGBA8Unorm;
	MTLPixelFormat getMTLPixelFormat() { return format; }
	VkFormat getVkFormat() { return format == MTLPixelFormatRGBA8Uint ? VK_FORMAT_R8G8B8A8_UINT : VK_FORMAT_R8G8B8A8_UNORM; }
	VkSampleCountFlagBits samples = VK_SAMPLE_COUNT_1_BIT;
	MVKImage* getImage() { return &image; }
	VkSampleCountFlagBits getSampleCount() { return samples; }
};
struct MVKFramebuffer {
	MVKSmallVector<MVKImageView*, 4> attachments;
	MVKArrayRef<MVKImageView*> getAttachments() { return attachments.contents(); }
};
static VkAttachmentReference2 reference(uint32_t index) { VkAttachmentReference2 ref{}; ref.attachment = index; return ref; }
struct MVKRenderPass;
struct MVKRenderSubpass {
	bool _isDynamicRendering = false, _isDitheringEnabled = false;
	MVKRenderPass* _renderPass = nullptr;
	uint32_t _subpassIndex = 0;
	VkPipelineRenderingCreateInfo _pipelineRenderingCreateInfo{};
	VkAttachmentReference2 _unusedAttachment = reference(VK_ATTACHMENT_UNUSED);
	MVKSmallVector<VkAttachmentReference2, 4> _colorAttachments, _resolveAttachments, _inputAttachments;
	VkAttachmentReference2 _depthAttachment = _unusedAttachment, _stencilAttachment = _unusedAttachment;
	VkAttachmentReference2 _depthResolveAttachment = _unusedAttachment, _stencilResolveAttachment = _unusedAttachment;
	VkResolveModeFlagBits _depthResolveMode = VK_RESOLVE_MODE_NONE, _stencilResolveMode = VK_RESOLVE_MODE_NONE;
	bool isDepthAttachmentUsed() const { return _depthAttachment.attachment != VK_ATTACHMENT_UNUSED; }
	bool isStencilAttachmentUsed() const { return _stencilAttachment.attachment != VK_ATTACHMENT_UNUSED; }
	bool hasResolveAttachments() const;
	const char* getPerVertexResolveError();
	void initDynamic(MVKRenderPass*, const VkRenderingInfo*);
	void populatePipelineRenderingCreateInfo() {}
	VkSampleCountFlagBits samples = VK_SAMPLE_COUNT_1_BIT;
	VkSampleCountFlagBits getSampleCount() { return samples; }
};
struct MVKRenderPass {
	struct Attachment { VkFormat format; VkFormat getFormat() { return format; } };
	std::vector<Attachment> _attachments;
	MVKRenderSubpass subpass;
	std::vector<int> _subpasses;
	MVKRenderSubpass* getSubpass(uint32_t) { return &subpass; }
	const MVKPhysicalDeviceMetalFeatures& getMetalFeatures() { return testFeatures; }
	MVKPixelFormats* getPixelFormats() { return &testFormats; }
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
	const MVKPhysicalDeviceMetalFeatures& getMetalFeatures() { return testFeatures; }
	MVKPixelFormats* getPixelFormats() { return &testFormats; }
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
	bool isDynamicRendering() { return getSubpass()->_isDynamicRendering; }
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
	pass.subpass._renderPass = &pass;
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
	pass._attachments.clear();
	for (auto* view : beginViews(&info)) { pass._attachments.push_back({view ? view->getVkFormat() : VK_FORMAT_UNDEFINED}); }
	assert(cmd.setContent(&cb, &info, &subpass, beginViews(&info)) == VK_SUCCESS);
	encoder.beginRenderpass(nullptr, cmd._contents, cmd._renderPass, cmd._framebuffer, cmd._renderArea, cmd._clearValues.contents(), cmd._attachments.contents(), kMVKCommandUseBeginRenderPass);
}

static void checkMultisampleAdmission() {
	MVKGraphicsPipeline pipeline;
	MVKCommandBuffer cb, secondary;
	cb._recordedPerVertexPipeline = secondary._recordedPerVertexPipeline = &pipeline;
	secondary._doesContinueRenderPass = true;
	secondary._secondaryInheritanceRenderingInfo.rasterizationSamples = VK_SAMPLE_COUNT_4_BIT;
	secondary._hasSecondaryInheritanceRenderingInfo = true;
	secondary.inherit();
	assert(secondary.recordPerVertexDraw(3, 1, true) == VK_SUCCESS);
	MVKCommand draw;
	secondary._head = &draw;
	MVKCommandBuffer* secondaries[] = {&secondary};
	MVKCommandEncoder encoder;
	MVKRenderPass pass;
	MVKFramebuffer framebuffer;
	MVKImageView source, target;
	MVKImageView* views[] = {&source};
	MVKImageView* resolved[] = {&source, &target};
	auto check = [&](bool accepted) {
		VkResult expected = accepted ? VK_SUCCESS : VK_ERROR_FEATURE_NOT_PRESENT;
		assert(cb.recordPerVertexDraw(3, 1, true) == expected);
		assert(cb.recordExecuteCommands(secondaries) == expected);
		assert((encoder.getIndexedPerVertexAttachmentError() == nullptr) == accepted);
		encoder.encodeSecondary(&secondary);
		assert(draw.rejected != accepted);
	};
	pass.subpass._colorAttachments.push_back(reference(0));
	for (auto samples : {VK_SAMPLE_COUNT_2_BIT, VK_SAMPLE_COUNT_4_BIT, VK_SAMPLE_COUNT_8_BIT}) {
		source.samples = pass.subpass.samples = samples;
		for (bool imageless : {false, true}) {
			framebuffer.attachments.clear();
			if (!imageless) { framebuffer.attachments.push_back(&source); }
			begin(cb, encoder, pass, framebuffer, views, imageless);
			check(true);
			source.image.storage = MTLStorageModeMemoryless;
			begin(cb, encoder, pass, framebuffer, views, imageless);
			check(false);
			source.image.storage = MTLStorageModePrivate;
			if (!imageless) { framebuffer.attachments.push_back(&target); }
			begin(cb, encoder, pass, framebuffer, resolved, imageless);
			check(true); // An unused 1x view is not a resolve target.
			pass.subpass._inputAttachments.push_back(reference(1));
			check(true); // Neither is a 1x input-only view.
			pass.subpass._inputAttachments.clear();
			pass.subpass._resolveAttachments.push_back(reference(1));
			check(false);
			testFeatures.combinedStoreResolveAction = true;
			check(true);
			target.format = MTLPixelFormatRGBA8Uint;
			begin(cb, encoder, pass, framebuffer, resolved, imageless);
			check(false); // Software color resolves remain excluded.
			target.format = MTLPixelFormatRGBA8Unorm;
			target.image.storage = MTLStorageModeMemoryless;
			begin(cb, encoder, pass, framebuffer, resolved, imageless);
			check(false);
			target.image.storage = MTLStorageModePrivate;
			begin(cb, encoder, pass, framebuffer, resolved, imageless);
			check(true);
			testFeatures.combinedStoreResolveAction = false;
			// Resolve detection must not depend on the first color attachment's sample count.
			pass.subpass.samples = VK_SAMPLE_COUNT_1_BIT;
			check(false);
			pass.subpass.samples = samples;
			pass.subpass._colorAttachments[0] = reference(VK_ATTACHMENT_UNUSED);
			check(true); // A resolve reference with no active source cannot trigger a resolve.
			pass.subpass._colorAttachments[0] = reference(0);
			pass.subpass._resolveAttachments[0] = reference(VK_ATTACHMENT_UNUSED);
			check(true);
			pass.subpass._resolveAttachments.clear();
		}
	}
	// Static inherited metadata is sufficient even when the secondary has no framebuffer/views.
	pass.subpass._resolveAttachments.push_back(reference(1));
	secondary._secondaryInheritanceInfo.renderPass = reinterpret_cast<VkRenderPass>(&pass);
	secondary.inherit();
	assert(!secondary._recordedAttachmentsKnown);
	assert(secondary.recordPerVertexDraw(3, 1, true) == VK_ERROR_FEATURE_NOT_PRESENT);
	testFeatures.combinedStoreResolveAction = true;
	assert(secondary.recordPerVertexDraw(3, 1, true) == VK_SUCCESS);
	pass.subpass._resolveAttachments[0] = reference(uint32_t(pass._attachments.size()));
	assert(secondary.recordPerVertexDraw(3, 1, true) == VK_ERROR_FEATURE_NOT_PRESENT);
	assert(encoder.getIndexedPerVertexAttachmentError()); // Bounds-checked metadata, no view dereference.
	pass.subpass._resolveAttachments.clear();
	testFeatures.combinedStoreResolveAction = false;
	secondary._secondaryInheritanceInfo.renderPass = VK_NULL_HANDLE;
	secondary.inherit();
	// Dynamic rendering's iterator includes source/resolve pairs for color, depth, and stencil.
	pass.subpass._colorAttachments.clear();
	for (bool stencil : {false, true}) {
		auto& sourceRef = stencil ? pass.subpass._stencilAttachment : pass.subpass._depthAttachment;
		auto& resolveRef = stencil ? pass.subpass._stencilResolveAttachment : pass.subpass._depthResolveAttachment;
		auto& mode = stencil ? pass.subpass._stencilResolveMode : pass.subpass._depthResolveMode;
		sourceRef = reference(0);
		resolveRef = reference(1);
		mode = VK_RESOLVE_MODE_SAMPLE_ZERO_BIT;
		check(false);
		testFeatures.combinedStoreResolveAction = true;
		check(false); // Depth/stencil capabilities are independently required.
		testFeatures.depthResolve = testFeatures.stencilResolve = true;
		check(true);
		mode = VK_RESOLVE_MODE_MIN_BIT;
		check(!stencil);
		mode = VK_RESOLVE_MODE_MAX_BIT;
		check(!stencil);
		mode = VK_RESOLVE_MODE_AVERAGE_BIT;
		check(false);
		testFeatures.combinedStoreResolveAction = testFeatures.depthResolve = testFeatures.stencilResolve = false;
		mode = VK_RESOLVE_MODE_NONE;
		check(true);
		mode = VK_RESOLVE_MODE_SAMPLE_ZERO_BIT;
		sourceRef = reference(VK_ATTACHMENT_UNUSED);
		check(true);
		sourceRef = reference(0);
		resolveRef = reference(VK_ATTACHMENT_UNUSED);
		check(true);
		sourceRef = reference(VK_ATTACHMENT_UNUSED);
		mode = VK_RESOLVE_MODE_NONE;
	}
	VkRenderingAttachmentInfo color{}, depth{}, stencil{};
	color.imageView = depth.imageView = stencil.imageView = reinterpret_cast<VkImageView>(&source);
	VkRenderingInfo info{};
	info.colorAttachmentCount = 1;
	info.pColorAttachments = &color;
	info.pDepthAttachment = &depth;
	info.pStencilAttachment = &stencil;
	auto beginDynamic = [&] {
		cb._currentSubpassInfo = {};
		cb.recordRendering(&info);
		pass.subpass._colorAttachments.clear();
		pass.subpass._resolveAttachments.clear();
		pass.subpass.initDynamic(&pass, &info);
		pass._attachments.clear();
		MVKSmallVector<MVKImageView*, 8> dynamicViews;
		MVKRenderingAttachmentIterator(&info).iterate([&](const VkRenderingAttachmentInfo*, VkImageAspectFlagBits, MVKImageView* view, bool) { dynamicViews.push_back(view); pass._attachments.push_back({view ? view->getVkFormat() : VK_FORMAT_UNDEFINED}); });
		encoder.beginRenderpass(nullptr, VK_SUBPASS_CONTENTS_INLINE, &pass, &framebuffer, {{0, 0}, {32, 32}}, {}, dynamicViews.contents(), kMVKCommandUseBeginRendering);
	};
	beginDynamic();
	check(true);
	for (auto* attachment : {&color, &depth, &stencil}) {
		for (auto mode : {VK_RESOLVE_MODE_AVERAGE_BIT, VK_RESOLVE_MODE_NONE}) {
			attachment->resolveMode = mode;
			attachment->resolveImageView = reinterpret_cast<VkImageView>(&target);
			beginDynamic();
			check(attachment != &color && mode == VK_RESOLVE_MODE_NONE); // Color currently resolves a non-null view even with NONE.
			testFeatures.combinedStoreResolveAction = testFeatures.depthResolve = testFeatures.stencilResolve = true;
			attachment->resolveMode = attachment == &color ? VK_RESOLVE_MODE_AVERAGE_BIT : VK_RESOLVE_MODE_SAMPLE_ZERO_BIT;
			beginDynamic();
			check(true);
			// Recording re-evaluates device-dependent resolve support at beginRendering.
			testFeatures.combinedStoreResolveAction = testFeatures.depthResolve = testFeatures.stencilResolve = false;
		}
		attachment->resolveImageView = VK_NULL_HANDLE;
		attachment->resolveMode = VK_RESOLVE_MODE_NONE;
	}
	// Begin-rendering mode validation is necessary: the dynamic subpass stores color references, not modes.
	testFeatures.combinedStoreResolveAction = testFeatures.depthResolve = testFeatures.stencilResolve = true;
	color.resolveImageView = reinterpret_cast<VkImageView>(&target);
	for (auto mode : {VK_RESOLVE_MODE_NONE, VK_RESOLVE_MODE_SAMPLE_ZERO_BIT, VK_RESOLVE_MODE_MIN_BIT, VK_RESOLVE_MODE_MAX_BIT}) {
		color.resolveMode = mode;
		beginDynamic();
		assert(cb.recordPerVertexDraw(3, 1, true) == VK_ERROR_FEATURE_NOT_PRESENT);
		assert(cb.recordExecuteCommands(secondaries) == VK_ERROR_FEATURE_NOT_PRESENT);
	}
	color.resolveMode = VK_RESOLVE_MODE_AVERAGE_BIT;
	target.format = MTLPixelFormatRGBA8Uint;
	beginDynamic();
	check(false);
	target.format = MTLPixelFormatRGBA8Unorm;
	color.resolveImageView = VK_NULL_HANDLE;
	testFeatures.combinedStoreResolveAction = testFeatures.depthResolve = testFeatures.stencilResolve = false;
	// Null color pairs must not shift the depth/stencil resolve indexes.
	color.imageView = VK_NULL_HANDLE;
	stencil.resolveImageView = reinterpret_cast<VkImageView>(&target);
	stencil.resolveMode = VK_RESOLVE_MODE_SAMPLE_ZERO_BIT;
	beginDynamic();
	check(false);
	stencil.resolveImageView = VK_NULL_HANDLE;
	beginDynamic();
	check(true);
	source.image.storage = MTLStorageModeMemoryless;
	beginDynamic();
	check(false);
}

int main() {
	checkMultisampleAdmission();
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
	assert(cb.recordPerVertexDraw(3, 1, true) == VK_SUCCESS);
	assert(!encoder.getIndexedPerVertexAttachmentError());
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
		assert(cb.recordExecuteCommands(secondaries) == VK_SUCCESS); // Known empty, even with MSAA.
		pass.subpass.samples = VK_SAMPLE_COUNT_1_BIT;
		// Dynamic inheritance's sample count does not identify resolve/storage semantics.
		if (mode == 2) {
			secondary._secondaryInheritanceRenderingInfo.rasterizationSamples = VK_SAMPLE_COUNT_4_BIT;
			secondary.inherit();
			assert(secondary.recordPerVertexDraw(3, 1, true) == VK_SUCCESS);
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
	puts("PASS: production attachment flow/admission; imageless and zero views; inherited primary revalidation; persistent MSAA/native resolve admission; memoryless/software/noncombined/unsupported-mode rejection (CPU only)");
}
