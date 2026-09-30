// Copyright 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
// Cost of the portable PerVertexKHR path against an ordinary draw of the same geometry, on one GPU, without Metal
// validation (the correctness of both arms is checked separately under validation by the runner).
// Workload: a 64 x 64 grid of quads (8192 triangles) over a 256 x 256 RGBA8 target, one draw per command buffer, direct
// (24576 vertices) or indexed (4225 vertices, 24576 uint32 indices). Arm "ordinary" interpolates a colour; arm
// "pervertex" weights the three PerVertexKHR values by BaryCoordKHR, which takes MoltenVK's capture and replay.
// Each command buffer: an anchor fill, timestamp A, the render pass, a copy to a host buffer, timestamp B. On Apple GPUs
// MoltenVK takes a Vulkan timestamp after the Metal encoder that is open when it is written (MVKCommandBuffer.mm,
// encodeTimestampStageCounterSamples); the anchor fill makes A follow that fill, not the render pass. With --no-anchor,
// A is written before any encoder and lands after the first one: that run calibrates what the timestamps measure.
// Per sample and per arm, after eight warm-up pairs, in an order that alternates at every pair:
//   submit_us       wall time of vkQueueSubmit (synchronous submits: MoltenVK encodes there);
//   completion_us   vkQueueSubmit plus the fence wait;
//   encode_us       MoltenVK's own commandBufferEncoding.latest (MVK_CONFIG_PERFORMANCE_TRACKING=1);
//   execution_us    MoltenVK's mtlCommandBufferExecution.latest, from commit to completion callback;
//   timestamp_us    timestamp B minus timestamp A;
//   mtl_buffers     Metal command buffers the submission completed (mtlCommandBufferExecution.count delta).
// Memory is measured before timing, in its own phase, so that one arm's retained allocations do not count for the
// other: four ordinary submissions, then four PerVertexKHR ones. VK_EXT_memory_budget heap usage (Metal
// currentAllocatedSize) is sampled before each submit, right after it returns (scratch is reserved at submission)
// and after completion; each arm reports its peak above the level measured before the phase, and the level left
// after the PerVertexKHR submissions (memory MoltenVK keeps).
// Every sample checks that its arm's image equals that arm's first image; the two arms must agree within 2/255.
// Usage: pervertex-cost-bench <shader directory> direct|indexed <samples 1..500> ordinary-first|pervertex-first [--no-anchor]
#import <Metal/Metal.h>
#include <vulkan/vulkan.h>
#include "mvk_private_api.h"

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <fstream>
#include <string>
#include <vector>

using Clock = std::chrono::steady_clock;

static void check(VkResult result, const char* step) {
	if (result != VK_SUCCESS) { std::fprintf(stderr, "%s: %d\n", step, int(result)); std::exit(1); }
}

static std::vector<uint32_t> readSpirv(const std::string& path) {
	std::ifstream file(path, std::ios::binary | std::ios::ate);
	if (!file) { std::fprintf(stderr, "Cannot open %s\n", path.c_str()); std::exit(1); }
	std::vector<uint32_t> words(size_t(file.tellg()) / 4);
	file.seekg(0);
	file.read(reinterpret_cast<char*>(words.data()), words.size() * 4);
	return words;
}

static bool hasExtension(const std::vector<VkExtensionProperties>& extensions, const char* name) {
	for (const auto& extension : extensions) if (!strcmp(extension.extensionName, name)) return true;
	return false;
}

constexpr uint32_t kSide = 256, kGrid = 64;
struct Buffer { VkBuffer buffer = VK_NULL_HANDLE; VkDeviceMemory memory = VK_NULL_HANDLE; uint8_t* data = nullptr; };

// Median, first and third quartiles, 95th percentile.
static void summarize(const char* arm, const char* what, std::vector<double> values) {
	if (values.empty()) return;
	std::sort(values.begin(), values.end());
	auto at = [&](double q) { return values[std::min(values.size() - 1, size_t(q * (values.size() - 1) + 0.5))]; };
	std::printf("BENCH %s %s median=%.1f q1=%.1f q3=%.1f p95=%.1f min=%.1f max=%.1f n=%zu\n", arm, what, at(0.5), at(0.25), at(0.75), at(0.95), values.front(), values.back(), values.size());
}

int main(int argc, char** argv) {
	@autoreleasepool {
	if (argc != 5 && argc != 6) { std::fprintf(stderr, "Usage: pervertex-cost-bench shader-dir direct|indexed samples ordinary-first|pervertex-first [--no-anchor]\n"); return 1; }
	const std::string shaders = argv[1], form = argv[2], order = argv[4];
	const unsigned long samples = std::strtoul(argv[3], nullptr, 10);
	const bool anchor = argc == 5 || std::string(argv[5]) != "--no-anchor";
	if ((form != "direct" && form != "indexed") || samples < 1 || samples > 500 || (order != "ordinary-first" && order != "pervertex-first") || (argc == 6 && anchor)) { std::fprintf(stderr, "Unknown case\n"); return 1; }
	const bool indexed = form == "indexed";

	uint32_t count = 0;
	check(vkEnumerateInstanceExtensionProperties(nullptr, &count, nullptr), "Enumerate instance extensions");
	std::vector<VkExtensionProperties> instanceExtensions(count);
	check(vkEnumerateInstanceExtensionProperties(nullptr, &count, instanceExtensions.data()), "Read instance extensions");
	const bool portability = hasExtension(instanceExtensions, VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME);
	const char* portabilityName = VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME;
	VkApplicationInfo app{VK_STRUCTURE_TYPE_APPLICATION_INFO};
	app.pApplicationName = "PerVertexKHR cost";
	app.apiVersion = VK_API_VERSION_1_2;
	VkInstanceCreateInfo instanceInfo{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
	instanceInfo.pApplicationInfo = &app;
	instanceInfo.flags = portability ? VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR : 0;
	instanceInfo.enabledExtensionCount = portability ? 1 : 0;
	instanceInfo.ppEnabledExtensionNames = portability ? &portabilityName : nullptr;
	VkInstance instance = VK_NULL_HANDLE;
	check(vkCreateInstance(&instanceInfo, nullptr, &instance), "Create instance");
	count = 1;
	VkPhysicalDevice physical = VK_NULL_HANDLE;
	VkResult enumerated = vkEnumeratePhysicalDevices(instance, &count, &physical);
	if (enumerated != VK_SUCCESS && enumerated != VK_INCOMPLETE) check(enumerated, "Enumerate devices");
	// The combined test library exposes an adapter; shipping libraries have no such symbol.
	if (auto enable = reinterpret_cast<void (*)(VkPhysicalDevice)>(dlsym(RTLD_DEFAULT, "mvkEnableTESFixtureDevice"))) enable(physical);
	check(vkEnumerateDeviceExtensionProperties(physical, nullptr, &count, nullptr), "Enumerate device extensions");
	std::vector<VkExtensionProperties> extensions(count);
	check(vkEnumerateDeviceExtensionProperties(physical, nullptr, &count, extensions.data()), "Read device extensions");
	std::vector<const char*> deviceExtensions{VK_KHR_FRAGMENT_SHADER_BARYCENTRIC_EXTENSION_NAME, VK_EXT_MEMORY_BUDGET_EXTENSION_NAME};
	for (const char* name : deviceExtensions) if (!hasExtension(extensions, name)) { std::fprintf(stderr, "Missing %s\n", name); return 3; }
	if (hasExtension(extensions, "VK_KHR_portability_subset")) deviceExtensions.push_back("VK_KHR_portability_subset");
	VkPhysicalDeviceFragmentShaderBarycentricFeaturesKHR barycentric{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FRAGMENT_SHADER_BARYCENTRIC_FEATURES_KHR};
	VkPhysicalDeviceFeatures2 features{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2};
	features.pNext = &barycentric;
	vkGetPhysicalDeviceFeatures2(physical, &features);
	if (!barycentric.fragmentShaderBarycentric) { std::fprintf(stderr, "Required features are unavailable\n"); return 3; }
	vkGetPhysicalDeviceQueueFamilyProperties(physical, &count, nullptr);
	std::vector<VkQueueFamilyProperties> families(count);
	vkGetPhysicalDeviceQueueFamilyProperties(physical, &count, families.data());
	uint32_t family = 0;
	while (family < count && !(families[family].queueFlags & VK_QUEUE_GRAPHICS_BIT)) ++family;
	float priority = 1;
	VkDeviceQueueCreateInfo queueInfo{VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};
	queueInfo.queueFamilyIndex = family;
	queueInfo.queueCount = 1;
	queueInfo.pQueuePriorities = &priority;
	VkPhysicalDeviceFeatures2 enabled{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2};
	enabled.pNext = &barycentric;
	VkDeviceCreateInfo deviceInfo{VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO};
	deviceInfo.pNext = &enabled;
	deviceInfo.queueCreateInfoCount = 1;
	deviceInfo.pQueueCreateInfos = &queueInfo;
	deviceInfo.enabledExtensionCount = uint32_t(deviceExtensions.size());
	deviceInfo.ppEnabledExtensionNames = deviceExtensions.data();
	VkDevice device = VK_NULL_HANDLE;
	check(vkCreateDevice(physical, &deviceInfo, nullptr, &device), "Create device");
	VkQueue queue = VK_NULL_HANDLE;
	vkGetDeviceQueue(device, family, 0, &queue);
	VkPhysicalDeviceProperties properties{};
	vkGetPhysicalDeviceProperties(physical, &properties);
	const uint32_t timestampBits = families[family].timestampValidBits;
	if (!properties.limits.timestampComputeAndGraphics || !timestampBits) { std::fprintf(stderr, "No timestamps\n"); return 3; }
	auto stats = reinterpret_cast<PFN_vkGetPerformanceStatisticsMVK>(dlsym(RTLD_DEFAULT, "vkGetPerformanceStatisticsMVK"));
	if (!stats) { std::fprintf(stderr, "No vkGetPerformanceStatisticsMVK\n"); return 3; }
	std::printf("DEVICE=%s form=%s samples=%lu order=%s anchor=%d timestamp_bits=%u period_ns=%.3f\n", properties.deviceName, form.c_str(), samples, order.c_str(), int(anchor), timestampBits, properties.limits.timestampPeriod);

	auto memoryType = [&](uint32_t bits, VkMemoryPropertyFlags flags) {
		VkPhysicalDeviceMemoryProperties memory{};
		vkGetPhysicalDeviceMemoryProperties(physical, &memory);
		for (uint32_t i = 0; i < memory.memoryTypeCount; ++i)
			if ((bits & (1u << i)) && (memory.memoryTypes[i].propertyFlags & flags) == flags) return i;
		std::fprintf(stderr, "No suitable memory type\n");
		std::exit(3);
	};
	auto makeBuffer = [&](VkDeviceSize size, VkBufferUsageFlags usage) {
		Buffer b;
		VkBufferCreateInfo info{VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO};
		info.size = size;
		info.usage = usage;
		check(vkCreateBuffer(device, &info, nullptr, &b.buffer), "Create buffer");
		VkMemoryRequirements requirements{};
		vkGetBufferMemoryRequirements(device, b.buffer, &requirements);
		VkMemoryAllocateInfo allocation{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
		allocation.allocationSize = requirements.size;
		allocation.memoryTypeIndex = memoryType(requirements.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
		check(vkAllocateMemory(device, &allocation, nullptr, &b.memory), "Allocate buffer");
		check(vkBindBufferMemory(device, b.buffer, b.memory, 0), "Bind buffer");
		void* mapped = nullptr;
		check(vkMapMemory(device, b.memory, 0, size, 0, &mapped), "Map buffer");
		b.data = static_cast<uint8_t*>(mapped);
		memset(b.data, 0, size);
		return b;
	};
	auto heapUsage = [&]() {
		VkPhysicalDeviceMemoryBudgetPropertiesEXT budget{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MEMORY_BUDGET_PROPERTIES_EXT};
		VkPhysicalDeviceMemoryProperties2 memory{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MEMORY_PROPERTIES_2};
		memory.pNext = &budget;
		vkGetPhysicalDeviceMemoryProperties2(physical, &memory);
		VkDeviceSize total = 0;
		for (uint32_t i = 0; i < memory.memoryProperties.memoryHeapCount; ++i) total += budget.heapUsage[i];
		return total;
	};

	// Indices of the 64 x 64 grid over a 65 x 65 lattice, two triangles per quad in the non-indexed corner order.
	const uint32_t vertexCount = kGrid * kGrid * 6;
	Buffer indices = makeBuffer(vertexCount * sizeof(uint32_t), VK_BUFFER_USAGE_INDEX_BUFFER_BIT);
	for (uint32_t quad = 0, i = 0; quad < kGrid * kGrid; ++quad) {
		const uint32_t x = quad % kGrid, y = quad / kGrid, a = y * (kGrid + 1) + x;
		for (uint32_t index : {a, a + 1, a + kGrid + 2, a + kGrid + 2, a + kGrid + 1, a}) reinterpret_cast<uint32_t*>(indices.data)[i++] = index;
	}
	Buffer anchorBuffer = makeBuffer(256, VK_BUFFER_USAGE_TRANSFER_DST_BIT);
	Buffer readbacks[2] = {makeBuffer(kSide * kSide * 4, VK_BUFFER_USAGE_TRANSFER_DST_BIT), makeBuffer(kSide * kSide * 4, VK_BUFFER_USAGE_TRANSFER_DST_BIT)};

	VkImageCreateInfo imageInfo{VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO};
	imageInfo.imageType = VK_IMAGE_TYPE_2D;
	imageInfo.format = VK_FORMAT_R8G8B8A8_UNORM;
	imageInfo.extent = {kSide, kSide, 1};
	imageInfo.mipLevels = 1;
	imageInfo.arrayLayers = 1;
	imageInfo.samples = VK_SAMPLE_COUNT_1_BIT;
	imageInfo.tiling = VK_IMAGE_TILING_OPTIMAL;
	imageInfo.usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
	VkImage image = VK_NULL_HANDLE;
	check(vkCreateImage(device, &imageInfo, nullptr, &image), "Create image");
	VkMemoryRequirements imageRequirements{};
	vkGetImageMemoryRequirements(device, image, &imageRequirements);
	VkMemoryAllocateInfo imageAllocation{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
	imageAllocation.allocationSize = imageRequirements.size;
	imageAllocation.memoryTypeIndex = memoryType(imageRequirements.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
	VkDeviceMemory imageMemory = VK_NULL_HANDLE;
	check(vkAllocateMemory(device, &imageAllocation, nullptr, &imageMemory), "Allocate image");
	check(vkBindImageMemory(device, image, imageMemory, 0), "Bind image");
	VkImageViewCreateInfo viewInfo{VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO};
	viewInfo.image = image;
	viewInfo.viewType = VK_IMAGE_VIEW_TYPE_2D;
	viewInfo.format = imageInfo.format;
	viewInfo.subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
	VkImageView view = VK_NULL_HANDLE;
	check(vkCreateImageView(device, &viewInfo, nullptr, &view), "Create image view");
	VkAttachmentDescription attachment{};
	attachment.format = imageInfo.format;
	attachment.samples = VK_SAMPLE_COUNT_1_BIT;
	attachment.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR;
	attachment.storeOp = VK_ATTACHMENT_STORE_OP_STORE;
	attachment.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
	attachment.finalLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
	VkAttachmentReference reference{0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};
	VkSubpassDescription subpass{};
	subpass.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS;
	subpass.colorAttachmentCount = 1;
	subpass.pColorAttachments = &reference;
	VkSubpassDependency toTransfer{0, VK_SUBPASS_EXTERNAL, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT, VK_ACCESS_TRANSFER_READ_BIT, 0};
	VkRenderPassCreateInfo passInfo{VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO};
	passInfo.attachmentCount = 1;
	passInfo.pAttachments = &attachment;
	passInfo.subpassCount = 1;
	passInfo.pSubpasses = &subpass;
	passInfo.dependencyCount = 1;
	passInfo.pDependencies = &toTransfer;
	VkRenderPass renderPass = VK_NULL_HANDLE;
	check(vkCreateRenderPass(device, &passInfo, nullptr, &renderPass), "Create render pass");
	VkFramebufferCreateInfo framebufferInfo{VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO};
	framebufferInfo.renderPass = renderPass;
	framebufferInfo.attachmentCount = 1;
	framebufferInfo.pAttachments = &view;
	framebufferInfo.width = kSide;
	framebufferInfo.height = kSide;
	framebufferInfo.layers = 1;
	VkFramebuffer framebuffer = VK_NULL_HANDLE;
	check(vkCreateFramebuffer(device, &framebufferInfo, nullptr, &framebuffer), "Create framebuffer");
	VkPipelineLayoutCreateInfo layoutInfo{VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};
	VkPipelineLayout layout = VK_NULL_HANDLE;
	check(vkCreatePipelineLayout(device, &layoutInfo, nullptr, &layout), "Create pipeline layout");

	auto module = [&](const std::string& name) {
		auto code = readSpirv(shaders + "/" + name);
		VkShaderModuleCreateInfo info{VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO};
		info.codeSize = code.size() * 4;
		info.pCode = code.data();
		VkShaderModule result = VK_NULL_HANDLE;
		check(vkCreateShaderModule(device, &info, nullptr, &result), "Create shader module");
		return result;
	};
	VkShaderModule vertex = module(indexed ? "cost-indexed.vert.spv" : "cost.vert.spv");
	auto graphicsPipeline = [&](VkShaderModule fragment) {
		VkPipelineShaderStageCreateInfo stages[2]{{VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO}, {VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO}};
		stages[0].stage = VK_SHADER_STAGE_VERTEX_BIT;
		stages[0].module = vertex;
		stages[0].pName = "main";
		stages[1].stage = VK_SHADER_STAGE_FRAGMENT_BIT;
		stages[1].module = fragment;
		stages[1].pName = "main";
		VkPipelineVertexInputStateCreateInfo vertexInput{VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO};
		VkPipelineInputAssemblyStateCreateInfo assembly{VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO};
		assembly.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
		VkViewport viewport{0, 0, float(kSide), float(kSide), 0, 1};
		VkRect2D scissor{{0, 0}, {kSide, kSide}};
		VkPipelineViewportStateCreateInfo viewportState{VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO};
		viewportState.viewportCount = 1;
		viewportState.pViewports = &viewport;
		viewportState.scissorCount = 1;
		viewportState.pScissors = &scissor;
		VkPipelineRasterizationStateCreateInfo raster{VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO};
		raster.polygonMode = VK_POLYGON_MODE_FILL;
		raster.cullMode = VK_CULL_MODE_NONE;
		raster.lineWidth = 1;
		VkPipelineMultisampleStateCreateInfo multisample{VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO};
		multisample.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;
		VkPipelineColorBlendAttachmentState blendAttachment{};
		blendAttachment.colorWriteMask = 0xF;
		VkPipelineColorBlendStateCreateInfo blend{VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO};
		blend.attachmentCount = 1;
		blend.pAttachments = &blendAttachment;
		VkGraphicsPipelineCreateInfo info{VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO};
		info.stageCount = 2;
		info.pStages = stages;
		info.pVertexInputState = &vertexInput;
		info.pInputAssemblyState = &assembly;
		info.pViewportState = &viewportState;
		info.pRasterizationState = &raster;
		info.pMultisampleState = &multisample;
		info.pColorBlendState = &blend;
		info.layout = layout;
		info.renderPass = renderPass;
		VkPipeline pipeline = VK_NULL_HANDLE;
		check(vkCreateGraphicsPipelines(device, VK_NULL_HANDLE, 1, &info, nullptr, &pipeline), "Create pipeline");
		return pipeline;
	};
	const VkPipeline pipelines[2] = {graphicsPipeline(module("cost-ordinary.frag.spv")), graphicsPipeline(module("cost-pervertex.frag.spv"))};
	const char* armNames[2] = {"ordinary", "pervertex"};

	VkQueryPoolCreateInfo queryInfo{VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO};
	queryInfo.queryType = VK_QUERY_TYPE_TIMESTAMP;
	queryInfo.queryCount = 4;
	VkQueryPool timestamps = VK_NULL_HANDLE;
	check(vkCreateQueryPool(device, &queryInfo, nullptr, &timestamps), "Create timestamp pool");
	VkCommandPoolCreateInfo poolInfo{VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};
	poolInfo.queueFamilyIndex = family;
	VkCommandPool pool = VK_NULL_HANDLE;
	check(vkCreateCommandPool(device, &poolInfo, nullptr, &pool), "Create command pool");
	VkCommandBufferAllocateInfo commandInfo{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
	commandInfo.commandPool = pool;
	commandInfo.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
	commandInfo.commandBufferCount = 2;
	VkCommandBuffer commands[2]{};
	check(vkAllocateCommandBuffers(device, &commandInfo, commands), "Allocate command buffers");
	for (int arm = 0; arm < 2; ++arm) {
		VkCommandBuffer cb = commands[arm];
		VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
		check(vkBeginCommandBuffer(cb, &begin), "Begin command buffer");
		vkCmdResetQueryPool(cb, timestamps, 2 * arm, 2);
		if (anchor) vkCmdFillBuffer(cb, anchorBuffer.buffer, 0, 256, 0);
		vkCmdWriteTimestamp(cb, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, timestamps, 2 * arm);
		VkClearValue clear{};
		VkRenderPassBeginInfo pass{VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO};
		pass.renderPass = renderPass;
		pass.framebuffer = framebuffer;
		pass.renderArea = {{0, 0}, {kSide, kSide}};
		pass.clearValueCount = 1;
		pass.pClearValues = &clear;
		vkCmdBeginRenderPass(cb, &pass, VK_SUBPASS_CONTENTS_INLINE);
		vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, pipelines[arm]);
		if (indexed) {
			vkCmdBindIndexBuffer(cb, indices.buffer, 0, VK_INDEX_TYPE_UINT32);
			vkCmdDrawIndexed(cb, vertexCount, 1, 0, 0, 0);
		} else vkCmdDraw(cb, vertexCount, 1, 0, 0);
		vkCmdEndRenderPass(cb);
		VkBufferImageCopy copy{};
		copy.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1};
		copy.imageExtent = {kSide, kSide, 1};
		vkCmdCopyImageToBuffer(cb, image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, readbacks[arm].buffer, 1, &copy);
		vkCmdWriteTimestamp(cb, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, timestamps, 2 * arm + 1);
		VkMemoryBarrier toHost{VK_STRUCTURE_TYPE_MEMORY_BARRIER};
		toHost.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
		toHost.dstAccessMask = VK_ACCESS_HOST_READ_BIT;
		vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &toHost, 0, nullptr, 0, nullptr);
		check(vkEndCommandBuffer(cb), "End command buffer");
	}
	VkFenceCreateInfo fenceInfo{VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
	VkFence fence = VK_NULL_HANDLE;
	check(vkCreateFence(device, &fenceInfo, nullptr, &fence), "Create fence");

	struct Series { std::vector<double> submit, completion, encode, execution, timestamp, mtlBuffers; VkDeviceSize peak = 0; std::vector<uint8_t> first; };
	Series series[2];
	uint32_t executions = 0;
	auto run = [&](int arm, bool measured) {
		MVKPerformanceStatistics perf{};
		size_t perfSize = sizeof(perf);
		check(vkResetFences(device, 1, &fence), "Reset fence");
		VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO};
		submit.commandBufferCount = 1;
		submit.pCommandBuffers = &commands[arm];
		Series& s = series[arm];
		const VkDeviceSize before = heapUsage();
		const auto start = Clock::now();
		check(vkQueueSubmit(queue, 1, &submit, fence), "Submit");
		const auto submitted = Clock::now();
		const VkDeviceSize inFlight = heapUsage();
		check(vkWaitForFences(device, 1, &fence, VK_TRUE, 20ull * 1000 * 1000 * 1000), "Wait");
		const auto completed = Clock::now();
		s.peak = std::max({s.peak, before, inFlight, heapUsage()});
		uint64_t ticks[2]{};
		check(vkGetQueryPoolResults(device, timestamps, 2 * arm, 2, sizeof(ticks), ticks, sizeof(uint64_t), VK_QUERY_RESULT_64_BIT | VK_QUERY_RESULT_WAIT_BIT), "Read timestamps");
		check(stats(device, &perf, &perfSize), "Read MoltenVK statistics");
		const uint32_t mtlBuffers = perf.queue.mtlCommandBufferExecution.count - executions;
		executions = perf.queue.mtlCommandBufferExecution.count;
		const uint8_t* pixels = readbacks[arm].data;
		if (s.first.empty()) s.first.assign(pixels, pixels + kSide * kSide * 4);
		else if (memcmp(pixels, s.first.data(), s.first.size())) { std::printf("BENCH_FAIL %s image changed between samples\n", armNames[arm]); std::exit(2); }
		if (!measured) return;
		uint64_t elapsed = ticks[1] - ticks[0];
		if (timestampBits < 64) elapsed &= (uint64_t(1) << timestampBits) - 1;
		s.submit.push_back(std::chrono::duration<double, std::micro>(submitted - start).count());
		s.completion.push_back(std::chrono::duration<double, std::micro>(completed - start).count());
		s.encode.push_back(perf.queue.commandBufferEncoding.latest * 1000);
		s.execution.push_back(perf.queue.mtlCommandBufferExecution.latest * 1000);
		s.timestamp.push_back(double(elapsed) * properties.limits.timestampPeriod / 1000);
		s.mtlBuffers.push_back(mtlBuffers);
	};
	const VkDeviceSize baseline = heapUsage();
	for (int arm = 0; arm < 2; ++arm)
		for (int i = 0; i < 4; ++i) run(arm, false);
	const VkDeviceSize retained = heapUsage();
	const VkDeviceSize peaks[2] = {series[0].peak, series[1].peak};
	const int firstArm = order == "ordinary-first" ? 0 : 1;
	for (unsigned long pair = 0; pair < samples + 8; ++pair) {
		const int a = (pair & 1) ? 1 - firstArm : firstArm;
		run(a, pair >= 8);
		run(1 - a, pair >= 8);
	}
	uint32_t covered = 0, differing = 0, worst = 0;
	for (uint32_t p = 0; p < kSide * kSide; ++p) {
		covered += series[0].first[4 * p + 3] != 0;
		uint32_t d = 0;
		for (int c = 0; c < 4; ++c) d = std::max<uint32_t>(d, uint32_t(std::abs(int(series[0].first[4 * p + c]) - int(series[1].first[4 * p + c]))));
		worst = std::max(worst, d);
		differing += d > 2;
	}
	std::printf("images: covered=%u above_2=%u max_channel_difference=%u\n", covered, differing, worst);
	for (int arm = 0; arm < 2; ++arm) {
		Series& s = series[arm];
		summarize(armNames[arm], "submit_us", s.submit);
		summarize(armNames[arm], "completion_us", s.completion);
		summarize(armNames[arm], "encode_us", s.encode);
		summarize(armNames[arm], "execution_us", s.execution);
		summarize(armNames[arm], "timestamp_us", s.timestamp);
		summarize(armNames[arm], "mtl_buffers", s.mtlBuffers);
		std::printf("BENCH %s memory_peak_above_baseline_kib=%.1f\n", armNames[arm], double(peaks[arm] > baseline ? peaks[arm] - baseline : 0) / 1024);
	}
	std::printf("BENCH memory baseline_kib=%.1f retained_after_both_arms_kib=%.1f\n", double(baseline) / 1024, double(retained > baseline ? retained - baseline : 0) / 1024);
	const bool pass = covered == kSide * kSide && differing == 0;
	std::printf("PERVERTEX_COST %s form=%s order=%s anchor=%d\n", pass ? "PASS" : "FAIL", form.c_str(), order.c_str(), int(anchor));
	vkDeviceWaitIdle(device);
	vkDestroyDevice(device, nullptr);
	vkDestroyInstance(instance, nullptr);
	return pass ? 0 : 2;
	}
}
