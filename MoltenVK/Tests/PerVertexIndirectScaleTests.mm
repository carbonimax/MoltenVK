// Copyright 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
// Measures how portable PerVertexKHR vkCmdDrawIndirectCount encoding scales with the GPU count (bound B6 of
// PerVertexIndirectCount-ANALYSIS.md). One command draws with a large maxDrawCount and a small real Count; the same
// draws are also recorded as direct draws, which take the same portable capture and replay. Each command buffer is
// submitted twice (cold, then warm). Per submission it reports the vkQueueSubmit time (synchronous submits encode
// there), the Metal encoders and commits created, and the split around the GPU plan wait of the indirect path.
// Oracles: every vertex shader invocation is recorded exactly once (all draws executed, including those clipped
// off the 64x64 target), and the indirect image equals the direct image byte for byte.
// Usage: pervertex-indirect-scale <shader directory> <maxDrawCount> <count>
#import <Metal/Metal.h>
#include <objc/runtime.h>
#include <vulkan/vulkan.h>
#include <vulkan/vulkan_metal.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <fstream>
#include <mutex>
#include <string>
#include <vector>

using Clock = std::chrono::steady_clock;

static void check(VkResult result, const char* step) {
	if (result != VK_SUCCESS) { std::fprintf(stderr, "%s: %d\n", step, int(result)); std::exit(2); }
}

static std::vector<uint32_t> readSpirv(const std::string& path) {
	std::ifstream file(path, std::ios::binary | std::ios::ate);
	if (!file) { std::fprintf(stderr, "Cannot open %s\n", path.c_str()); std::exit(2); }
	std::vector<uint32_t> words(size_t(file.tellg()) / 4);
	file.seekg(0);
	file.read(reinterpret_cast<char*>(words.data()), words.size() * 4);
	return words;
}

static bool hasExtension(const std::vector<VkExtensionProperties>& extensions, const char* name) {
	for (const auto& extension : extensions) if (!strcmp(extension.extensionName, name)) return true;
	return false;
}

// Metal encoders and commits, timestamped, counted on the outermost command buffer class only.
enum Kind { kCompute, kRender, kBlit, kCommit };
struct Event { Kind kind; Clock::time_point at; };
static std::mutex gEventsLock;
static std::vector<Event> gEvents;
static thread_local int gDepth = 0;
static IMP gCompute, gRender, gBlit, gBlitDescriptor, gCommit;

static void note(Kind kind) {
	if (gDepth) return;  // a wrapper layer calling another hooked selector is one encoder
	std::lock_guard<std::mutex> lock(gEventsLock);
	gEvents.push_back({kind, Clock::now()});
}
static id computeCounted(id self, SEL command, NSUInteger type) {
	note(kCompute); ++gDepth; id result = reinterpret_cast<id (*)(id, SEL, NSUInteger)>(gCompute)(self, command, type); --gDepth; return result;
}
static id renderCounted(id self, SEL command, id descriptor) {
	note(kRender); ++gDepth; id result = reinterpret_cast<id (*)(id, SEL, id)>(gRender)(self, command, descriptor); --gDepth; return result;
}
static id blitCounted(id self, SEL command) {
	note(kBlit); ++gDepth; id result = reinterpret_cast<id (*)(id, SEL)>(gBlit)(self, command); --gDepth; return result;
}
static id blitDescriptorCounted(id self, SEL command, id descriptor) {
	note(kBlit); ++gDepth; id result = reinterpret_cast<id (*)(id, SEL, id)>(gBlitDescriptor)(self, command, descriptor); --gDepth; return result;
}
static void commitCounted(id self, SEL command) {
	note(kCommit); ++gDepth; reinterpret_cast<void (*)(id, SEL)>(gCommit)(self, command); --gDepth;
}
static IMP replace(Class cls, SEL selector, IMP imp) {
	Method method = class_getInstanceMethod(cls, selector);
	if (!method) { std::fprintf(stderr, "%s has no %s\n", class_getName(cls), sel_getName(selector)); std::exit(3); }
	IMP original = method_getImplementation(method);
	class_replaceMethod(cls, selector, imp, method_getTypeEncoding(method));
	return original;
}

static double ms(Clock::duration d) { return std::chrono::duration<double, std::milli>(d).count(); }

constexpr uint32_t kSide = 64, kMaxRecords = 1u << 18, kStride = 16;
// Harness base draw: 6 vertices from firstVertex 4, 2 instances from firstInstance 2, so 12 records per draw.
constexpr uint32_t kVertices = 6, kInstances = 2, kFirstVertex = 4, kFirstInstance = 2;

struct Buffer { VkBuffer buffer = VK_NULL_HANDLE; VkDeviceMemory memory = VK_NULL_HANDLE; uint8_t* data = nullptr; };

int main(int argc, char** argv) {
	@autoreleasepool {
	if (argc != 4) { std::fprintf(stderr, "Usage: pervertex-indirect-scale shader-dir maxDrawCount count\n"); return 2; }
	const std::string shaders = argv[1];
	const uint32_t maxDrawCount = uint32_t(std::strtoul(argv[2], nullptr, 10)), drawCount = uint32_t(std::strtoul(argv[3], nullptr, 10));
	if (maxDrawCount < 2 || drawCount < 1 || drawCount > maxDrawCount || uint64_t(drawCount) * kVertices * kInstances > kMaxRecords) {
		std::fprintf(stderr, "Need 2 <= maxDrawCount, 1 <= count <= maxDrawCount and count x 12 <= %u records\n", kMaxRecords);
		return 2;
	}

	uint32_t count = 0;
	check(vkEnumerateInstanceExtensionProperties(nullptr, &count, nullptr), "Enumerate instance extensions");
	std::vector<VkExtensionProperties> instanceExtensions(count);
	check(vkEnumerateInstanceExtensionProperties(nullptr, &count, instanceExtensions.data()), "Read instance extensions");
	const bool portability = hasExtension(instanceExtensions, VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME);
	const char* portabilityName = VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME;
	VkApplicationInfo app{VK_STRUCTURE_TYPE_APPLICATION_INFO};
	app.pApplicationName = "PerVertexKHR indirect scale";
	app.apiVersion = VK_API_VERSION_1_1;
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
	std::vector<const char*> deviceExtensions{VK_KHR_FRAGMENT_SHADER_BARYCENTRIC_EXTENSION_NAME, VK_KHR_DRAW_INDIRECT_COUNT_EXTENSION_NAME, VK_EXT_METAL_OBJECTS_EXTENSION_NAME};
	for (const char* name : deviceExtensions) if (!hasExtension(extensions, name)) { std::fprintf(stderr, "Missing %s\n", name); return 3; }
	if (hasExtension(extensions, "VK_KHR_portability_subset")) deviceExtensions.push_back("VK_KHR_portability_subset");
	VkPhysicalDeviceShaderDrawParametersFeatures drawParameters{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SHADER_DRAW_PARAMETERS_FEATURES};
	VkPhysicalDeviceFragmentShaderBarycentricFeaturesKHR barycentric{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FRAGMENT_SHADER_BARYCENTRIC_FEATURES_KHR};
	barycentric.pNext = &drawParameters;
	VkPhysicalDeviceFeatures2 features{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2};
	features.pNext = &barycentric;
	vkGetPhysicalDeviceFeatures2(physical, &features);
	const auto& core = features.features;
	if (!barycentric.fragmentShaderBarycentric || !drawParameters.shaderDrawParameters || !core.drawIndirectFirstInstance || !core.multiDrawIndirect || !core.vertexPipelineStoresAndAtomics) { std::fprintf(stderr, "Required features are unavailable\n"); return 3; }
	VkPhysicalDeviceFeatures2 enabled{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2};
	enabled.pNext = &barycentric;
	enabled.features.drawIndirectFirstInstance = VK_TRUE;
	enabled.features.multiDrawIndirect = VK_TRUE;
	enabled.features.vertexPipelineStoresAndAtomics = VK_TRUE;
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

	// Hook the Metal command buffer class that MoltenVK's queue vends (outermost wrapper under the validation layers).
	VkExportMetalDeviceInfoEXT metalDevice{VK_STRUCTURE_TYPE_EXPORT_METAL_DEVICE_INFO_EXT};
	VkExportMetalCommandQueueInfoEXT metalQueue{VK_STRUCTURE_TYPE_EXPORT_METAL_COMMAND_QUEUE_INFO_EXT};
	metalQueue.queue = queue;
	metalDevice.pNext = &metalQueue;
	VkExportMetalObjectsInfoEXT exportInfo{VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECTS_INFO_EXT};
	exportInfo.pNext = &metalDevice;
	vkExportMetalObjectsEXT(device, &exportInfo);
	if (!metalDevice.mtlDevice || !metalQueue.mtlCommandQueue) { std::fprintf(stderr, "No exported Metal device or queue\n"); return 3; }
	MTLCommandBufferDescriptor* probeDescriptor = [MTLCommandBufferDescriptor new];
	Class bufferClass = object_getClass([metalQueue.mtlCommandQueue commandBufferWithDescriptor: probeDescriptor]);
	[probeDescriptor release];
	gCompute = replace(bufferClass, @selector(computeCommandEncoderWithDispatchType:), reinterpret_cast<IMP>(computeCounted));
	gRender = replace(bufferClass, @selector(renderCommandEncoderWithDescriptor:), reinterpret_cast<IMP>(renderCounted));
	gBlit = replace(bufferClass, @selector(blitCommandEncoder), reinterpret_cast<IMP>(blitCounted));
	gBlitDescriptor = replace(bufferClass, @selector(blitCommandEncoderWithDescriptor:), reinterpret_cast<IMP>(blitDescriptorCounted));
	gCommit = replace(bufferClass, @selector(commit), reinterpret_cast<IMP>(commitCounted));
	const char* synchronous = getenv("MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS");
	std::printf("DEVICE=%s command_buffer_class=%s max_draw_count=%u count=%u synchronous_submits=%s\n", properties.deviceName, class_getName(bufferClass), maxDrawCount, drawCount, synchronous ? synchronous : "default");

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

	// Arguments for maxDrawCount draws at offset 0 (the legal span); only the first count are the base draw.
	Buffer arguments = makeBuffer(VkDeviceSize(maxDrawCount) * kStride, VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT);
	for (uint32_t i = 0; i < drawCount; ++i) {
		uint32_t words[4] = {kVertices, kInstances, kFirstVertex, kFirstInstance};
		memcpy(arguments.data + uint64_t(i) * kStride, words, sizeof(words));
	}
	Buffer countBuffer = makeBuffer(4, VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT);
	memcpy(countBuffer.data, &drawCount, 4);
	Buffer effects = makeBuffer(16 + VkDeviceSize(kMaxRecords) * 16, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);
	Buffer readback = makeBuffer(kSide * kSide * 4, VK_BUFFER_USAGE_TRANSFER_DST_BIT);

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

	VkDescriptorSetLayoutBinding binding{0, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_VERTEX_BIT, nullptr};
	VkDescriptorSetLayoutCreateInfo setLayoutInfo{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO};
	setLayoutInfo.bindingCount = 1;
	setLayoutInfo.pBindings = &binding;
	VkDescriptorSetLayout setLayout = VK_NULL_HANDLE;
	check(vkCreateDescriptorSetLayout(device, &setLayoutInfo, nullptr, &setLayout), "Create set layout");
	VkDescriptorPoolSize poolSize{VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1};
	VkDescriptorPoolCreateInfo descriptorPoolInfo{VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO};
	descriptorPoolInfo.maxSets = 1;
	descriptorPoolInfo.poolSizeCount = 1;
	descriptorPoolInfo.pPoolSizes = &poolSize;
	VkDescriptorPool descriptorPool = VK_NULL_HANDLE;
	check(vkCreateDescriptorPool(device, &descriptorPoolInfo, nullptr, &descriptorPool), "Create descriptor pool");
	VkDescriptorSetAllocateInfo setInfo{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO};
	setInfo.descriptorPool = descriptorPool;
	setInfo.descriptorSetCount = 1;
	setInfo.pSetLayouts = &setLayout;
	VkDescriptorSet set = VK_NULL_HANDLE;
	check(vkAllocateDescriptorSets(device, &setInfo, &set), "Allocate descriptor set");
	VkDescriptorBufferInfo effectsInfo{effects.buffer, 0, VK_WHOLE_SIZE};
	VkWriteDescriptorSet write{VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET};
	write.dstSet = set;
	write.descriptorCount = 1;
	write.descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
	write.pBufferInfo = &effectsInfo;
	vkUpdateDescriptorSets(device, 1, &write, 0, nullptr);
	VkPushConstantRange pushRange{VK_SHADER_STAGE_VERTEX_BIT, 0, 4};
	VkPipelineLayoutCreateInfo layoutInfo{VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};
	layoutInfo.setLayoutCount = 1;
	layoutInfo.pSetLayouts = &setLayout;
	layoutInfo.pushConstantRangeCount = 1;
	layoutInfo.pPushConstantRanges = &pushRange;
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
	// The PORTABLE fragment also reads BaryCoordKHR, so both pipelines take the portable capture and replay on every GPU.
	VkShaderModule fragment = module("pervertex-portable.frag.spv");
	auto graphicsPipeline = [&](VkShaderModule vertex) {
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
		// Blending makes the order of the overlapping visible draws part of the result.
		VkPipelineColorBlendAttachmentState blendAttachment{};
		blendAttachment.blendEnable = VK_TRUE;
		blendAttachment.srcColorBlendFactor = blendAttachment.srcAlphaBlendFactor = VK_BLEND_FACTOR_SRC_ALPHA;
		blendAttachment.dstColorBlendFactor = blendAttachment.dstAlphaBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
		blendAttachment.colorBlendOp = blendAttachment.alphaBlendOp = VK_BLEND_OP_ADD;
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
		VkPipeline result = VK_NULL_HANDLE;
		check(vkCreateGraphicsPipelines(device, VK_NULL_HANDLE, 1, &info, nullptr, &result), "Create graphics pipeline");
		return result;
	};
	VkPipeline indirectPipeline = graphicsPipeline(module("indirect.vert.spv")), referencePipeline = graphicsPipeline(module("reference.vert.spv"));

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
	auto record = [&](VkCommandBuffer cb, bool indirect) {
		VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
		check(vkBeginCommandBuffer(cb, &begin), "Begin command buffer");
		VkClearValue clear{};
		VkRenderPassBeginInfo pass{VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO};
		pass.renderPass = renderPass;
		pass.framebuffer = framebuffer;
		pass.renderArea = {{0, 0}, {kSide, kSide}};
		pass.clearValueCount = 1;
		pass.pClearValues = &clear;
		vkCmdBeginRenderPass(cb, &pass, VK_SUBPASS_CONTENTS_INLINE);
		vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, indirect ? indirectPipeline : referencePipeline);
		vkCmdBindDescriptorSets(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, layout, 0, 1, &set, 0, nullptr);
		if (indirect) {
			vkCmdDrawIndirectCountKHR(cb, arguments.buffer, 0, countBuffer.buffer, 0, maxDrawCount, kStride);
		} else {
			for (uint32_t drawId = 0; drawId < drawCount; ++drawId) {
				vkCmdPushConstants(cb, layout, VK_SHADER_STAGE_VERTEX_BIT, 0, 4, &drawId);
				vkCmdDraw(cb, kVertices, kInstances, kFirstVertex, kFirstInstance);
			}
		}
		vkCmdEndRenderPass(cb);
		VkBufferImageCopy copy{};
		copy.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1};
		copy.imageExtent = {kSide, kSide, 1};
		vkCmdCopyImageToBuffer(cb, image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, readback.buffer, 1, &copy);
		VkMemoryBarrier toHost{VK_STRUCTURE_TYPE_MEMORY_BARRIER};
		toHost.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT | VK_ACCESS_SHADER_WRITE_BIT;
		toHost.dstAccessMask = VK_ACCESS_HOST_READ_BIT;
		vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TRANSFER_BIT | VK_PIPELINE_STAGE_VERTEX_SHADER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &toHost, 0, nullptr, 0, nullptr);
		check(vkEndCommandBuffer(cb), "End command buffer");
	};
	auto recordStart = Clock::now();
	record(commands[0], true);
	auto recordIndirect = Clock::now();
	record(commands[1], false);
	std::printf("record_ms indirect=%.3f direct=%.3f\n", ms(recordIndirect - recordStart), ms(Clock::now() - recordIndirect));

	// Every invocation of the base draw, sorted: (vertex, instance, drawId | firstInstance << 16, baseVertex).
	std::vector<std::array<uint32_t, 4>> expected;
	for (uint32_t drawId = 0; drawId < drawCount; ++drawId)
		for (uint32_t k = 0; k < kInstances; ++k)
			for (uint32_t j = 0; j < kVertices; ++j) expected.push_back({kFirstVertex + j, kFirstInstance + k, drawId | (kFirstInstance << 16), kFirstVertex});
	std::sort(expected.begin(), expected.end());

	VkFenceCreateInfo fenceInfo{VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
	VkFence fence = VK_NULL_HANDLE;
	check(vkCreateFence(device, &fenceInfo, nullptr, &fence), "Create fence");
	std::vector<uint8_t> images[2];
	bool pass = true;
	for (int which = 0; which < 2; ++which) {
		const char* name = which ? "direct" : "indirect";
		for (int round = 0; round < 2; ++round) {
			memset(effects.data, 0, 16);
			memset(readback.data, 0, kSide * kSide * 4);
			{ std::lock_guard<std::mutex> lock(gEventsLock); gEvents.clear(); }
			uint64_t allocatedBefore = [metalDevice.mtlDevice currentAllocatedSize];
			VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO};
			submit.commandBufferCount = 1;
			submit.pCommandBuffers = &commands[which];
			auto start = Clock::now();
			VkResult submitted = vkQueueSubmit(queue, 1, &submit, fence);
			auto afterSubmit = Clock::now();
			VkResult waited = submitted == VK_SUCCESS ? vkWaitForFences(device, 1, &fence, VK_TRUE, 60ull * 1000 * 1000 * 1000) : submitted;
			auto done = Clock::now();
			std::vector<Event> events;
			{ std::lock_guard<std::mutex> lock(gEventsLock); events = gEvents; }
			uint32_t kinds[4]{};
			for (const auto& e : events) ++kinds[e.kind];
			// The indirect path commits its GPU plan, waits for it, then encodes the replay in a new command buffer.
			double firstCommit = -1, resume = -1, lastCommit = -1;
			for (size_t i = 0; i < events.size(); ++i) {
				if (events[i].kind != kCommit) continue;
				lastCommit = ms(events[i].at - start);
				if (firstCommit < 0) {
					firstCommit = lastCommit;
					if (i + 1 < events.size()) resume = ms(events[i + 1].at - start);
				}
			}
			uint32_t records = 0;
			memcpy(&records, effects.data, 4);
			std::vector<std::array<uint32_t, 4>> recorded(std::min(records, kMaxRecords));
			if (!recorded.empty()) memcpy(recorded.data(), effects.data + 16, recorded.size() * 16);
			std::sort(recorded.begin(), recorded.end());
			const bool exactlyOnce = records == expected.size() && recorded == expected;
			if (round == 1) images[which].assign(readback.data, readback.data + kSide * kSide * 4);
			std::printf("run=%s round=%d submit=%d wait=%d submit_ms=%.3f wait_ms=%.3f compute_encoders=%u render_encoders=%u blit_encoders=%u commits=%u "
						"first_commit_ms=%.3f resume_ms=%.3f last_commit_ms=%.3f plan_wait_ms=%.3f replay_encode_ms=%.3f allocated_before=%llu allocated_after=%llu records=%u expected_records=%zu exactly_once=%d\n",
						name, round, int(submitted), int(waited), ms(afterSubmit - start), ms(done - afterSubmit), kinds[kCompute], kinds[kRender], kinds[kBlit], kinds[kCommit],
						firstCommit, resume, lastCommit, resume >= 0 ? resume - firstCommit : -1.0, resume >= 0 ? lastCommit - resume : -1.0,
						(unsigned long long)allocatedBefore, (unsigned long long)[metalDevice.mtlDevice currentAllocatedSize], records, expected.size(), int(exactlyOnce));
			if (submitted != VK_SUCCESS || waited != VK_SUCCESS || !exactlyOnce) pass = false;
			check(vkResetFences(device, 1, &fence), "Reset fence");
		}
	}
	uint32_t mismatches = 0, covered = 0;
	for (size_t i = 0; i < images[0].size(); i += 4) {
		if (memcmp(&images[0][i], &images[1][i], 4)) ++mismatches;
		if (images[1][i] | images[1][i + 1] | images[1][i + 2] | images[1][i + 3]) ++covered;
	}
	if (mismatches || !covered) pass = false;
	std::printf("pixel_mismatches=%u covered_pixels=%u\n", mismatches, covered);
	std::printf("PERVERTEX_SCALE %s max_draw_count=%u count=%u\n", pass ? "PASS" : "FAIL", maxDrawCount, drawCount);
	vkDestroyDevice(device, nullptr);
	vkDestroyInstance(instance, nullptr);
	return pass ? 0 : 1;
	}
}
