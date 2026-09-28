// Copyright 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
// Standalone Vulkan test for portable PerVertexKHR vkCmdDraw[Indexed]Indirect[Count].
// Arguments, Count and indices start as host zeros and are written by the GPU before the draw,
// optionally in a separate submission and queue family joined by a semaphore. Each result is compared byte for
// byte with direct PerVertexKHR draws of the same parameters, and every vertex shader invocation is
// recorded to check DrawID, first/base values, instances and exactly-once side effects.
#define VK_ENABLE_BETA_EXTENSIONS 1 // VK_KHR_portability_subset
#include <vulkan/vulkan.h>
#include <dlfcn.h>

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <stdexcept>
#include <string>
#include <tuple>
#include <vector>

static void check(VkResult result, const char* operation) {
	if (result != VK_SUCCESS) throw std::runtime_error(std::string(operation) + ": " + std::to_string(result));
}

static std::vector<uint32_t> readSpirv(const std::string& path) {
	std::ifstream file(path, std::ios::binary | std::ios::ate);
	if (!file) throw std::runtime_error("Cannot open " + path);
	auto size = file.tellg();
	if (size <= 0 || size % 4) throw std::runtime_error("Invalid SPIR-V size");
	std::vector<uint32_t> words(size_t(size) / 4);
	file.seekg(0);
	file.read(reinterpret_cast<char*>(words.data()), size);
	return words;
}

static bool hasExtension(const std::vector<VkExtensionProperties>& extensions, const char* name) {
	for (const auto& extension : extensions) if (!strcmp(extension.extensionName, name)) return true;
	return false;
}

constexpr uint32_t kSide = 64;
constexpr VkDeviceSize kWorkSize = 512, kIndexOffset = 16, kArgsOffset = 256, kCountOffset = 384, kStride = 32;
constexpr uint32_t kMaxRecords = 1u << 18;

// first is firstVertex (non-indexed) or firstIndex (indexed); base is vertexOffset.
struct Draw { uint32_t count, instances, first; int32_t base; uint32_t firstInstance; };

struct Scenario {
	std::array<Draw, 2> draws;
	uint32_t gpuCount;
	bool expectLost;
};

struct Device {
	VkPhysicalDevice physical = VK_NULL_HANDLE;
	VkDevice device = VK_NULL_HANDLE;
	VkQueue queue = VK_NULL_HANDLE;
	VkQueue producerQueue = VK_NULL_HANDLE;
	uint32_t family = 0;
	uint32_t producerFamily = 0;
};

struct Buffer {
	VkBuffer buffer = VK_NULL_HANDLE;
	VkDeviceMemory memory = VK_NULL_HANDLE;
	uint8_t* data = nullptr;
	VkDeviceSize size = 0;
};

static uint32_t memoryType(VkPhysicalDevice device, uint32_t bits, VkMemoryPropertyFlags flags) {
	VkPhysicalDeviceMemoryProperties properties{};
	vkGetPhysicalDeviceMemoryProperties(device, &properties);
	for (uint32_t i = 0; i < properties.memoryTypeCount; ++i)
		if ((bits & (1u << i)) && (properties.memoryTypes[i].propertyFlags & flags) == flags) return i;
	throw std::runtime_error("No suitable memory type");
}

// Host-visible so that any CPU read of the arguments during encoding would see the host zeros.
static Buffer makeBuffer(const Device& d, VkDeviceSize size, VkBufferUsageFlags usage) {
	Buffer b;
	b.size = size;
	VkBufferCreateInfo info{VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO};
	info.size = size;
	info.usage = usage;
	uint32_t families[2] = {d.family, d.producerFamily};
	if (d.producerFamily != d.family) {
		info.sharingMode = VK_SHARING_MODE_CONCURRENT;
		info.queueFamilyIndexCount = 2;
		info.pQueueFamilyIndices = families;
	}
	check(vkCreateBuffer(d.device, &info, nullptr, &b.buffer), "Create buffer");
	VkMemoryRequirements requirements{};
	vkGetBufferMemoryRequirements(d.device, b.buffer, &requirements);
	VkMemoryAllocateInfo allocation{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
	allocation.allocationSize = requirements.size;
	allocation.memoryTypeIndex = memoryType(d.physical, requirements.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
	check(vkAllocateMemory(d.device, &allocation, nullptr, &b.memory), "Allocate buffer");
	check(vkBindBufferMemory(d.device, b.buffer, b.memory, 0), "Bind buffer");
	void* mapped = nullptr;
	check(vkMapMemory(d.device, b.memory, 0, size, 0, &mapped), "Map buffer");
	b.data = static_cast<uint8_t*>(mapped);
	memset(b.data, 0, size);
	return b;
}

int main(int argc, char** argv) {
	try {
		if (argc != 7) throw std::runtime_error("Usage: pervertex-indirect-gpu shader-dir draw|indexed|draw-count|indexed-count u8|u16|u32 decisive|single|zero|two|repeat|overflow|overflow-second|huge|index-oob|restart|restart-two|restart-overflow|restart-dynamic-on|restart-dynamic-off|stress update|copy|compute output-prefix");
		const std::string shaders = argv[1], form = argv[2], indexName = argv[3], scenarioName = argv[4], producer = argv[5], prefix = argv[6];
		const bool withTES = getenv("PERVERTEX_TEST_INCLUDE_TES") != nullptr;
		const bool tesFirst = getenv("PERVERTEX_TEST_TES_FIRST") != nullptr;
		const bool tessWrongPatch = getenv("PERVERTEX_TEST_TES_WRONG_PATCH") != nullptr;
		const bool splitProducer = getenv("PERVERTEX_TEST_SPLIT_PRODUCER") != nullptr;
		const bool lateSignal = getenv("PERVERTEX_TEST_LATE_SIGNAL") != nullptr;
		const bool dependentSubmission = getenv("PERVERTEX_TEST_DEPENDENT_SUBMISSION") != nullptr;
		const bool dependentSameQueue = getenv("PERVERTEX_TEST_DEPENDENT_SAME_QUEUE") != nullptr;
		const bool waitIdleProbe = getenv("PERVERTEX_TEST_WAIT_IDLE") != nullptr;
		if (dependentSubmission && (!splitProducer || !lateSignal)) throw std::runtime_error("dependent submission requires split producer and late signal");
		if (dependentSameQueue && !dependentSubmission) throw std::runtime_error("same-queue dependent submission requires dependent submission");
		const bool indexed = form == "indexed" || form == "indexed-count";
		const bool counted = form == "draw-count" || form == "indexed-count";
		if (!indexed && form != "draw" && !counted) throw std::runtime_error("Unknown form");
		if (producer != "update" && producer != "copy" && producer != "compute") throw std::runtime_error("Unknown producer");
		if (scenarioName == "repeat" && producer == "update") throw std::runtime_error("repeat changes host staging between submissions; use copy or compute");
		if (splitProducer && (producer != "compute" || scenarioName == "repeat")) throw std::runtime_error("split producer requires compute and a single scenario");
		if (lateSignal && !splitProducer) throw std::runtime_error("late host signal requires a split producer");
		const uint32_t indexSize = indexName == "u8" ? 1 : indexName == "u16" ? 2 : indexName == "u32" ? 4 : 0;
		if (!indexSize) throw std::runtime_error("Unknown index type");
		const VkIndexType indexType = indexSize == 1 ? VK_INDEX_TYPE_UINT8_KHR : indexSize == 2 ? VK_INDEX_TYPE_UINT16 : VK_INDEX_TYPE_UINT32;
		// Restart scenarios draw an indexed triangle strip split by the index type's restart marker.
		const bool restart = scenarioName.rfind("restart", 0) == 0;
		// PERVERTEX_TEST_TOPOLOGY selects another portable topology for non-restart scenarios.
		const char* topologyName = getenv("PERVERTEX_TEST_TOPOLOGY");
		const std::string topologyText = topologyName ? topologyName : "triangle-list";
		const VkPrimitiveTopology topology = restart ? VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP : topologyText == "point-list" ? VK_PRIMITIVE_TOPOLOGY_POINT_LIST : topologyText == "line-list" ? VK_PRIMITIVE_TOPOLOGY_LINE_LIST : topologyText == "line-strip" ? VK_PRIMITIVE_TOPOLOGY_LINE_STRIP : topologyText == "triangle-strip" ? VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP : topologyText == "triangle-fan" ? VK_PRIMITIVE_TOPOLOGY_TRIANGLE_FAN : VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
		if (topology == VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST && topologyText != "triangle-list") throw std::runtime_error("Unknown topology");
		if (scenarioName == "single" && topology != VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST) throw std::runtime_error("single requires a triangle-list draw");
		// Dynamic restart state: the pipeline may restart, so restart scratch is reserved either way.
		const bool dynamicRestart = scenarioName.rfind("restart-dynamic", 0) == 0, restartOn = scenarioName != "restart-dynamic-off";
		if (restart && !indexed) throw std::runtime_error("restart scenarios need an indexed form");
		const std::vector<uint32_t> sources = restart ? std::vector<uint32_t>{10, 11, 13, 12, UINT32_MAX, 10, 11, 12} : std::vector<uint32_t>{10, 11, 12, 12, 13, 10};
		const uint32_t marker = indexSize == 1 ? 0xFFu : indexSize == 2 ? 0xFFFFu : 0xFFFFFFFFu;
		// Nonzero first/base values everywhere; uint16 also exercises a negative vertexOffset.
		const Draw base = indexed ? Draw{uint32_t(sources.size()), 2, 2, indexSize == 2 ? -3 : 3, 2} : Draw{6, 2, 4, 0, 2};
		auto scenarioFor = [&](const std::string& name) {
			Draw empty = base;
			empty.instances = 0;
			Scenario s{{base, counted ? base : empty}, 1, false};
			if (name == "single") { Draw one = base; one.instances = 1; s.draws = {one, empty}; s.gpuCount = 1; }
			else if (name == "zero") { s.draws = {counted ? base : empty, counted ? base : empty}; s.gpuCount = 0; }
			else if (name == "two" || name == "overflow-second" || name == "restart-two") { s.draws = {base, base}; s.gpuCount = 7; }
			else if (name == "restart-overflow") { s.expectLost = true; }
			// Two heavy overlapping draws: draw 1 reuses the scratch that draw 0's replay reads, with different values.
			else if (name == "stress") { s.draws = {base, base}; s.draws[0].instances = s.draws[1].instances = 20000; s.gpuCount = 2; }
			else if (name == "huge") { s.draws[0].instances = UINT32_MAX; s.expectLost = true; }
			else if (name == "index-oob") { if (!indexed) throw std::runtime_error("index-oob needs an indexed form"); s.draws[0].first = 100000; s.expectLost = true; }
			else if (name == "overflow") { s.expectLost = true; }
			else if (name != "decisive" && name != "repeat" && name != "restart" && !dynamicRestart) throw std::runtime_error("Unknown scenario");
			// Only the second draw exceeds a capacity of 11 records: the whole command must still do nothing.
			if (name == "overflow-second") { s.draws[0].instances = 1; s.expectLost = true; }
			return s;
		};
		std::vector<Scenario> submissions{scenarioFor(scenarioName)};
		if (scenarioName == "repeat") { submissions.push_back(scenarioFor("two")); submissions.push_back(scenarioFor("zero")); }

		uint32_t count = 0;
		check(vkEnumerateInstanceExtensionProperties(nullptr, &count, nullptr), "Enumerate instance extensions");
		std::vector<VkExtensionProperties> instanceExtensions(count);
		check(vkEnumerateInstanceExtensionProperties(nullptr, &count, instanceExtensions.data()), "Read instance extensions");
		const bool portability = hasExtension(instanceExtensions, VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME);
		const char* portabilityName = VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME;
		VkApplicationInfo app{VK_STRUCTURE_TYPE_APPLICATION_INFO};
		app.pApplicationName = "PerVertexKHR indirect test";
		app.apiVersion = lateSignal ? VK_API_VERSION_1_2 : VK_API_VERSION_1_1;
		VkInstanceCreateInfo instanceInfo{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
		instanceInfo.pApplicationInfo = &app;
		instanceInfo.flags = portability ? VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR : 0;
		instanceInfo.enabledExtensionCount = portability ? 1 : 0;
		instanceInfo.ppEnabledExtensionNames = portability ? &portabilityName : nullptr;
		VkInstance instance = VK_NULL_HANDLE;
		check(vkCreateInstance(&instanceInfo, nullptr, &instance), "Create instance");
		check(vkEnumeratePhysicalDevices(instance, &count, nullptr), "Enumerate devices");
		std::vector<VkPhysicalDevice> physicals(count);
		check(vkEnumeratePhysicalDevices(instance, &count, physicals.data()), "Read devices");
		Device d;
		std::vector<const char*> deviceExtensions{VK_KHR_FRAGMENT_SHADER_BARYCENTRIC_EXTENSION_NAME, VK_KHR_DRAW_INDIRECT_COUNT_EXTENSION_NAME};
		if (dynamicRestart) deviceExtensions.push_back(VK_EXT_EXTENDED_DYNAMIC_STATE_2_EXTENSION_NAME);
		for (auto candidate : physicals) {
			// The combined test library exposes an adapter; shipping libraries have no such symbol.
			if (auto enable = reinterpret_cast<void (*)(VkPhysicalDevice)>(dlsym(RTLD_DEFAULT, "mvkEnableTESFixtureDevice"))) { enable(candidate); }
			check(vkEnumerateDeviceExtensionProperties(candidate, nullptr, &count, nullptr), "Enumerate device extensions");
			std::vector<VkExtensionProperties> extensions(count);
			check(vkEnumerateDeviceExtensionProperties(candidate, nullptr, &count, extensions.data()), "Read device extensions");
			if (!hasExtension(extensions, VK_KHR_FRAGMENT_SHADER_BARYCENTRIC_EXTENSION_NAME) || !hasExtension(extensions, VK_KHR_DRAW_INDIRECT_COUNT_EXTENSION_NAME)) continue;
			if (indexSize == 1 && !hasExtension(extensions, VK_KHR_INDEX_TYPE_UINT8_EXTENSION_NAME)) continue;
			vkGetPhysicalDeviceQueueFamilyProperties(candidate, &count, nullptr);
			std::vector<VkQueueFamilyProperties> families(count);
			vkGetPhysicalDeviceQueueFamilyProperties(candidate, &count, families.data());
			for (uint32_t i = 0; i < count && !d.physical; ++i) {
				if (!(families[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) || !(families[i].queueFlags & VK_QUEUE_COMPUTE_BIT)) continue;
				d.physical = candidate;
				d.family = i;
				d.producerFamily = i;
				if (splitProducer) for (uint32_t j = 0; j < count; ++j) if (j != i && (families[j].queueFlags & VK_QUEUE_COMPUTE_BIT)) { d.producerFamily = j; break; }
				if (hasExtension(extensions, VK_KHR_PORTABILITY_SUBSET_EXTENSION_NAME)) deviceExtensions.push_back(VK_KHR_PORTABILITY_SUBSET_EXTENSION_NAME);
			}
			if (d.physical) break;
		}
		if (!d.physical) throw std::runtime_error("No device with barycentric, indirect count and required index type");
		if (indexSize == 1) deviceExtensions.push_back(VK_KHR_INDEX_TYPE_UINT8_EXTENSION_NAME);
		// Feature chain: barycentric -> draw parameters [-> uint8 indices] [-> dynamic restart].
		VkPhysicalDeviceIndexTypeUint8FeaturesKHR uint8Features{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_INDEX_TYPE_UINT8_FEATURES_KHR};
		VkPhysicalDeviceExtendedDynamicState2FeaturesEXT dynamicState2{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTENDED_DYNAMIC_STATE_2_FEATURES_EXT};
		VkPhysicalDeviceTimelineSemaphoreFeatures timeline{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TIMELINE_SEMAPHORE_FEATURES};
		VkPhysicalDeviceShaderDrawParametersFeatures drawParameters{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SHADER_DRAW_PARAMETERS_FEATURES};
		VkPhysicalDeviceFragmentShaderBarycentricFeaturesKHR barycentric{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FRAGMENT_SHADER_BARYCENTRIC_FEATURES_KHR};
		barycentric.pNext = &drawParameters;
		void** tail = &drawParameters.pNext;
		if (indexSize == 1) { *tail = &uint8Features; tail = &uint8Features.pNext; }
		if (dynamicRestart) { *tail = &dynamicState2; tail = &dynamicState2.pNext; }
		if (lateSignal) { *tail = &timeline; }
		VkPhysicalDeviceFeatures2 supported{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2};
		supported.pNext = &barycentric;
		vkGetPhysicalDeviceFeatures2(d.physical, &supported);
		const auto& core = supported.features;
		if (!barycentric.fragmentShaderBarycentric || !drawParameters.shaderDrawParameters || !core.drawIndirectFirstInstance || !core.multiDrawIndirect || !core.vertexPipelineStoresAndAtomics || (withTES && !core.tessellationShader) || (indexSize == 1 && !uint8Features.indexTypeUint8) || (dynamicRestart && !dynamicState2.extendedDynamicState2) || (lateSignal && !timeline.timelineSemaphore))
			throw std::runtime_error("Required features are unavailable");
		VkPhysicalDeviceFeatures2 enabled{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2};
		enabled.pNext = &barycentric;
		enabled.features.drawIndirectFirstInstance = VK_TRUE;
		enabled.features.multiDrawIndirect = VK_TRUE;
		enabled.features.vertexPipelineStoresAndAtomics = VK_TRUE;
		enabled.features.tessellationShader = withTES ? VK_TRUE : VK_FALSE;
		float priority = 1;
		VkDeviceQueueCreateInfo queueInfo{VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};
		queueInfo.queueFamilyIndex = d.family;
		queueInfo.queueCount = 1;
		queueInfo.pQueuePriorities = &priority;
		VkDeviceQueueCreateInfo producerQueueInfo = queueInfo;
		producerQueueInfo.queueFamilyIndex = d.producerFamily;
		VkDeviceQueueCreateInfo queues[2] = {queueInfo, producerQueueInfo};
		VkDeviceCreateInfo deviceInfo{VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO};
		deviceInfo.pNext = &enabled;
		deviceInfo.queueCreateInfoCount = d.producerFamily == d.family ? 1 : 2;
		deviceInfo.pQueueCreateInfos = queues;
		deviceInfo.enabledExtensionCount = uint32_t(deviceExtensions.size());
		deviceInfo.ppEnabledExtensionNames = deviceExtensions.data();
		check(vkCreateDevice(d.physical, &deviceInfo, nullptr, &d.device), "Create device");
		vkGetDeviceQueue(d.device, d.family, 0, &d.queue);
		vkGetDeviceQueue(d.device, d.producerFamily, 0, &d.producerQueue);
		VkPhysicalDeviceProperties properties{};
		vkGetPhysicalDeviceProperties(d.physical, &properties);
		std::printf("DEVICE=%s form=%s index=%s scenario=%s producer=%s topology=%s draw_family=%u producer_family=%u\n", properties.deviceName, form.c_str(), indexName.c_str(), scenarioName.c_str(), producer.c_str(), restart ? "triangle-strip" : topologyText.c_str(), d.family, d.producerFamily);

		// Colour attachment and readback.
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
		check(vkCreateImage(d.device, &imageInfo, nullptr, &image), "Create image");
		VkMemoryRequirements imageRequirements{};
		vkGetImageMemoryRequirements(d.device, image, &imageRequirements);
		VkMemoryAllocateInfo imageAllocation{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
		imageAllocation.allocationSize = imageRequirements.size;
		imageAllocation.memoryTypeIndex = memoryType(d.physical, imageRequirements.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
		VkDeviceMemory imageMemory = VK_NULL_HANDLE;
		check(vkAllocateMemory(d.device, &imageAllocation, nullptr, &imageMemory), "Allocate image");
		check(vkBindImageMemory(d.device, image, imageMemory, 0), "Bind image");
		VkImageViewCreateInfo viewInfo{VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO};
		viewInfo.image = image;
		viewInfo.viewType = VK_IMAGE_VIEW_TYPE_2D;
		viewInfo.format = imageInfo.format;
		viewInfo.subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
		VkImageView view = VK_NULL_HANDLE;
		check(vkCreateImageView(d.device, &viewInfo, nullptr, &view), "Create image view");
		Buffer readback = makeBuffer(d, kSide * kSide * 4, VK_BUFFER_USAGE_TRANSFER_DST_BIT);
		Buffer work = makeBuffer(d, kWorkSize, VK_BUFFER_USAGE_INDEX_BUFFER_BIT | VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT | VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT);
		Buffer staging = makeBuffer(d, kWorkSize, VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);
		Buffer effects = makeBuffer(d, 16 + kMaxRecords * 16, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);

		VkAttachmentDescription attachment{};
		attachment.format = imageInfo.format;
		attachment.samples = VK_SAMPLE_COUNT_1_BIT;
		attachment.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR;
		attachment.storeOp = VK_ATTACHMENT_STORE_OP_STORE;
		attachment.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
		attachment.finalLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
		VkAttachmentReference reference{0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};
		VkSubpassDescription subpass{};
		subpass.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS;
		subpass.colorAttachmentCount = 1;
		subpass.pColorAttachments = &reference;
		VkRenderPassCreateInfo passInfo{VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO};
		passInfo.attachmentCount = 1;
		passInfo.pAttachments = &attachment;
		passInfo.subpassCount = 1;
		passInfo.pSubpasses = &subpass;
		VkRenderPass renderPass = VK_NULL_HANDLE;
		check(vkCreateRenderPass(d.device, &passInfo, nullptr, &renderPass), "Create render pass");
		VkFramebufferCreateInfo framebufferInfo{VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO};
		framebufferInfo.renderPass = renderPass;
		framebufferInfo.attachmentCount = 1;
		framebufferInfo.pAttachments = &view;
		framebufferInfo.width = kSide;
		framebufferInfo.height = kSide;
		framebufferInfo.layers = 1;
		VkFramebuffer framebuffer = VK_NULL_HANDLE;
		check(vkCreateFramebuffer(d.device, &framebufferInfo, nullptr, &framebuffer), "Create framebuffer");

		// Descriptors: effects for graphics; staging -> work for the compute producer.
		VkDescriptorSetLayoutBinding bindings[2]{};
		bindings[0] = {0, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_COMPUTE_BIT, nullptr};
		bindings[1] = {1, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT, nullptr};
		VkDescriptorSetLayoutCreateInfo setLayoutInfo{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO};
		setLayoutInfo.bindingCount = 1;
		setLayoutInfo.pBindings = bindings;
		VkDescriptorSetLayout graphicsSetLayout = VK_NULL_HANDLE, computeSetLayout = VK_NULL_HANDLE;
		check(vkCreateDescriptorSetLayout(d.device, &setLayoutInfo, nullptr, &graphicsSetLayout), "Create graphics set layout");
		setLayoutInfo.bindingCount = 2;
		check(vkCreateDescriptorSetLayout(d.device, &setLayoutInfo, nullptr, &computeSetLayout), "Create compute set layout");
		VkDescriptorPoolSize poolSize{VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 3};
		VkDescriptorPoolCreateInfo descriptorPoolInfo{VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO};
		descriptorPoolInfo.maxSets = 2;
		descriptorPoolInfo.poolSizeCount = 1;
		descriptorPoolInfo.pPoolSizes = &poolSize;
		VkDescriptorPool descriptorPool = VK_NULL_HANDLE;
		check(vkCreateDescriptorPool(d.device, &descriptorPoolInfo, nullptr, &descriptorPool), "Create descriptor pool");
		VkDescriptorSetLayout setLayouts[2] = {graphicsSetLayout, computeSetLayout};
		VkDescriptorSetAllocateInfo setInfo{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO};
		setInfo.descriptorPool = descriptorPool;
		setInfo.descriptorSetCount = 2;
		setInfo.pSetLayouts = setLayouts;
		VkDescriptorSet sets[2]{};
		check(vkAllocateDescriptorSets(d.device, &setInfo, sets), "Allocate descriptor sets");
		VkDescriptorBufferInfo bufferInfos[3] = {{effects.buffer, 0, VK_WHOLE_SIZE}, {staging.buffer, 0, VK_WHOLE_SIZE}, {work.buffer, 0, VK_WHOLE_SIZE}};
		VkWriteDescriptorSet writes[3]{};
		for (uint32_t i = 0; i < 3; ++i) {
			writes[i].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
			writes[i].dstSet = sets[i ? 1 : 0];
			writes[i].dstBinding = i ? i - 1 : 0;
			writes[i].descriptorCount = 1;
			writes[i].descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
			writes[i].pBufferInfo = &bufferInfos[i];
		}
		vkUpdateDescriptorSets(d.device, 3, writes, 0, nullptr);
		VkPushConstantRange pushRange{VK_SHADER_STAGE_VERTEX_BIT, 0, 4};
		VkPipelineLayoutCreateInfo layoutInfo{VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};
		layoutInfo.setLayoutCount = 1;
		layoutInfo.pSetLayouts = &graphicsSetLayout;
		layoutInfo.pushConstantRangeCount = 1;
		layoutInfo.pPushConstantRanges = &pushRange;
		VkPipelineLayout graphicsLayout = VK_NULL_HANDLE, computeLayout = VK_NULL_HANDLE;
		check(vkCreatePipelineLayout(d.device, &layoutInfo, nullptr, &graphicsLayout), "Create graphics layout");
		layoutInfo.pSetLayouts = &computeSetLayout;
		layoutInfo.pushConstantRangeCount = 0;
		check(vkCreatePipelineLayout(d.device, &layoutInfo, nullptr, &computeLayout), "Create compute layout");

		auto module = [&](const std::string& name) {
			auto code = readSpirv(shaders + "/" + name);
			VkShaderModuleCreateInfo info{VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO};
			info.codeSize = code.size() * 4;
			info.pCode = code.data();
			VkShaderModule result = VK_NULL_HANDLE;
			check(vkCreateShaderModule(d.device, &info, nullptr, &result), "Create shader module");
			return result;
		};
		VkShaderModule indirectVertex = module("indirect.vert.spv"), referenceVertex = module("reference.vert.spv"), fragment = module("pervertex.frag.spv"), producerShader = module("args.comp.spv");
		auto graphicsPipeline = [&](VkShaderModule vertex) {
			// Restart needs a strip here: list restart would require primitiveTopologyListRestart.
			VkPipelineShaderStageCreateInfo stages[2]{{VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO}, {VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO}};
			stages[0].stage = VK_SHADER_STAGE_VERTEX_BIT;
			stages[0].module = vertex;
			stages[0].pName = "main";
			stages[1].stage = VK_SHADER_STAGE_FRAGMENT_BIT;
			stages[1].module = fragment;
			stages[1].pName = "main";
			VkPipelineVertexInputStateCreateInfo vertexInput{VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO};
			VkPipelineInputAssemblyStateCreateInfo assembly{VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO};
			assembly.topology = topology;
			assembly.primitiveRestartEnable = restart && !dynamicRestart;
			VkDynamicState dynamicState = VK_DYNAMIC_STATE_PRIMITIVE_RESTART_ENABLE;
			VkPipelineDynamicStateCreateInfo dynamic{VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO};
			dynamic.dynamicStateCount = dynamicRestart ? 1 : 0;
			dynamic.pDynamicStates = &dynamicState;
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
			// Blending makes the order of overlapping draws visible in the result.
			VkPipelineColorBlendAttachmentState blendAttachment{};
			blendAttachment.blendEnable = VK_TRUE;
			blendAttachment.srcColorBlendFactor = VK_BLEND_FACTOR_SRC_ALPHA;
			blendAttachment.dstColorBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
			blendAttachment.colorBlendOp = VK_BLEND_OP_ADD;
			blendAttachment.srcAlphaBlendFactor = VK_BLEND_FACTOR_SRC_ALPHA;
			blendAttachment.dstAlphaBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
			blendAttachment.alphaBlendOp = VK_BLEND_OP_ADD;
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
			info.pDynamicState = &dynamic;
			info.layout = graphicsLayout;
			info.renderPass = renderPass;
			VkPipeline result = VK_NULL_HANDLE;
			check(vkCreateGraphicsPipelines(d.device, VK_NULL_HANDLE, 1, &info, nullptr, &result), "Create graphics pipeline");
			return result;
		};
		VkPipeline referencePipeline = graphicsPipeline(referenceVertex);
		// PERVERTEX_TEST_SWAP_FRAGMENT=1 is a negative control: only the indirect pipeline permutes corners.
		const char* swap = getenv("PERVERTEX_TEST_SWAP_FRAGMENT");
		if (swap && !strcmp(swap, "1")) fragment = module("pervertex-swap.frag.spv");
		VkPipeline indirectPipeline = graphicsPipeline(indirectVertex);
		VkPipeline tessPipeline = VK_NULL_HANDLE;
		if (withTES) {
			VkShaderModule tessVertex = module("tes-triangle.vert.spv"), tessControl = module("tes-triangle.tesc.spv"), tessEvaluation = module("tes-ordered.tese.spv"), tessFragment = module(tessWrongPatch ? "tes-wrong-patch.frag.spv" : "tes-ordered.frag.spv");
			VkPipelineShaderStageCreateInfo stages[4]{};
			VkShaderStageFlagBits kinds[4] = {VK_SHADER_STAGE_VERTEX_BIT, VK_SHADER_STAGE_TESSELLATION_CONTROL_BIT, VK_SHADER_STAGE_TESSELLATION_EVALUATION_BIT, VK_SHADER_STAGE_FRAGMENT_BIT};
			VkShaderModule modules[4] = {tessVertex, tessControl, tessEvaluation, tessFragment};
			for (uint32_t i = 0; i < 4; ++i) { stages[i].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO; stages[i].stage = kinds[i]; stages[i].module = modules[i]; stages[i].pName = "main"; }
			VkPipelineVertexInputStateCreateInfo vertexInput{VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO};
			VkPipelineInputAssemblyStateCreateInfo assembly{VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO};
			assembly.topology = VK_PRIMITIVE_TOPOLOGY_PATCH_LIST;
			VkPipelineTessellationStateCreateInfo tessellation{VK_STRUCTURE_TYPE_PIPELINE_TESSELLATION_STATE_CREATE_INFO};
			tessellation.patchControlPoints = 3;
			// Keep the fixed TES fixture's 32x32 viewport and patch split at x=16.
			VkViewport viewport{0, 0, 32, 32, 0, 1};
			VkRect2D scissor{{0, 0}, {32, 32}};
			VkPipelineViewportStateCreateInfo viewportState{VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO};
			viewportState.viewportCount = 1; viewportState.pViewports = &viewport; viewportState.scissorCount = 1; viewportState.pScissors = &scissor;
			VkPipelineRasterizationStateCreateInfo raster{VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO};
			raster.polygonMode = VK_POLYGON_MODE_FILL; raster.cullMode = VK_CULL_MODE_NONE; raster.frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE; raster.lineWidth = 1;
			VkPipelineMultisampleStateCreateInfo multisample{VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO};
			multisample.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;
			VkPipelineColorBlendAttachmentState blendAttachment{};
			blendAttachment.colorWriteMask = 0xF;
			VkPipelineColorBlendStateCreateInfo blend{VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO};
			blend.attachmentCount = 1; blend.pAttachments = &blendAttachment;
			VkGraphicsPipelineCreateInfo info{VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO};
			info.stageCount = 4; info.pStages = stages; info.pVertexInputState = &vertexInput; info.pInputAssemblyState = &assembly; info.pTessellationState = &tessellation;
			info.pViewportState = &viewportState; info.pRasterizationState = &raster; info.pMultisampleState = &multisample; info.pColorBlendState = &blend;
			info.layout = graphicsLayout; info.renderPass = renderPass;
			check(vkCreateGraphicsPipelines(d.device, VK_NULL_HANDLE, 1, &info, nullptr, &tessPipeline), "Create merged TES pipeline");
		}
		VkComputePipelineCreateInfo computeInfo{VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO};
		computeInfo.stage = {VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, nullptr, 0, VK_SHADER_STAGE_COMPUTE_BIT, producerShader, "main", nullptr};
		computeInfo.layout = computeLayout;
		VkPipeline computePipeline = VK_NULL_HANDLE;
		check(vkCreateComputePipelines(d.device, VK_NULL_HANDLE, 1, &computeInfo, nullptr, &computePipeline), "Create compute pipeline");

		VkCommandPoolCreateInfo poolInfo{VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};
		poolInfo.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
		poolInfo.queueFamilyIndex = d.family;
		VkCommandPool pool = VK_NULL_HANDLE;
		check(vkCreateCommandPool(d.device, &poolInfo, nullptr, &pool), "Create command pool");
		VkCommandBufferAllocateInfo commandInfo{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
		commandInfo.commandPool = pool;
		commandInfo.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
		commandInfo.commandBufferCount = 2;
		VkCommandBuffer commands[2]{};
		check(vkAllocateCommandBuffers(d.device, &commandInfo, commands), "Allocate command buffers");
		VkCommandBuffer referenceCommands = commands[0], indirectCommands = commands[1], producerCommands = VK_NULL_HANDLE, dependentCommands = VK_NULL_HANDLE;
		VkCommandPool producerPool = pool;
		Buffer dependentMarker;
		if (dependentSubmission) dependentMarker = makeBuffer(d, sizeof(uint32_t), VK_BUFFER_USAGE_TRANSFER_DST_BIT);
		if (splitProducer) {
			if (d.producerFamily != d.family) {
				poolInfo.queueFamilyIndex = d.producerFamily;
				check(vkCreateCommandPool(d.device, &poolInfo, nullptr, &producerPool), "Create producer command pool");
			}
			commandInfo.commandPool = producerPool;
			commandInfo.commandBufferCount = 1;
			check(vkAllocateCommandBuffers(d.device, &commandInfo, &producerCommands), "Allocate producer command buffer");
			if (dependentSubmission) {
				commandInfo.commandPool = dependentSameQueue ? pool : producerPool;
				check(vkAllocateCommandBuffers(d.device, &commandInfo, &dependentCommands), "Allocate dependent command buffer");
			}
		}

		// Staging layout: indices from byte 16, arguments at 256 (stride 32), Count at 384.
		auto fillStaging = [&](const Scenario& s) {
			memset(staging.data, 0, kWorkSize);
			for (uint32_t i = 0; i < sources.size() && indexed; ++i) {
				uint32_t index = sources[i] == UINT32_MAX ? marker : uint32_t(int32_t(sources[i]) - base.base);
				memcpy(staging.data + kIndexOffset + (base.first + i) * indexSize, &index, indexSize);
			}
			for (uint32_t i = 0; i < 2; ++i) {
				const Draw& a = s.draws[i];
				uint32_t words[5] = {a.count, a.instances, a.first, uint32_t(a.base), a.firstInstance};
				if (!indexed) { words[3] = a.firstInstance; }
				memcpy(staging.data + kArgsOffset + i * kStride, words, indexed ? 20 : 16);
			}
			memcpy(staging.data + kCountOffset, &s.gpuCount, 4);
		};
		// Draws Vulkan executes, with their DrawID; empty draws are skipped.
		auto executed = [&](const Scenario& s) {
			std::vector<std::pair<uint32_t, Draw>> draws;
			uint32_t limit = counted ? std::min(2u, s.gpuCount) : 2u;
			if (s.expectLost) { return draws; }
			for (uint32_t i = 0; i < limit; ++i) if (s.draws[i].count && s.draws[i].instances) draws.push_back({i, s.draws[i]});
			return draws;
		};
		auto expectedRecords = [&](const Scenario& s) {
			std::vector<std::array<uint32_t, 4>> records;
			// A restart marker never invokes the vertex shader.
			for (auto& [drawId, a] : executed(s))
				for (uint32_t k = 0; k < a.instances; ++k)
					for (uint32_t j = 0; j < a.count; ++j)
						if (!indexed || sources[j] != UINT32_MAX || !restartOn) records.push_back({indexed ? (sources[j] == UINT32_MAX ? marker + uint32_t(a.base) : sources[j]) : a.first + j, a.firstInstance + k, drawId | (a.firstInstance << 16), indexed ? uint32_t(a.base) : a.first});
			std::sort(records.begin(), records.end());
			return records;
		};

		auto encodeProducer = [&](VkCommandBuffer cb, const std::string& how, bool barrier) {
			VkPipelineStageFlags producerStage = VK_PIPELINE_STAGE_TRANSFER_BIT;
			VkAccessFlags producerAccess = VK_ACCESS_TRANSFER_WRITE_BIT;
			if (how == "update") {
				vkCmdUpdateBuffer(cb, work.buffer, 0, kWorkSize, staging.data);
			} else if (how == "copy") {
				VkBufferCopy copy{0, 0, kWorkSize};
				vkCmdCopyBuffer(cb, staging.buffer, work.buffer, 1, &copy);
			} else {
				vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_COMPUTE, computePipeline);
				vkCmdBindDescriptorSets(cb, VK_PIPELINE_BIND_POINT_COMPUTE, computeLayout, 0, 1, &sets[1], 0, nullptr);
				vkCmdDispatch(cb, 2, 1, 1);
				producerStage = VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT;
				producerAccess = VK_ACCESS_SHADER_WRITE_BIT;
			}
			if (barrier) {
				VkMemoryBarrier produced{VK_STRUCTURE_TYPE_MEMORY_BARRIER};
				produced.srcAccessMask = producerAccess;
				produced.dstAccessMask = VK_ACCESS_INDIRECT_COMMAND_READ_BIT | VK_ACCESS_INDEX_READ_BIT;
				vkCmdPipelineBarrier(cb, producerStage, VK_PIPELINE_STAGE_DRAW_INDIRECT_BIT | VK_PIPELINE_STAGE_VERTEX_INPUT_BIT, 0, 1, &produced, 0, nullptr, 0, nullptr);
			}
		};
		auto record = [&](VkCommandBuffer cb, bool referenceRun, const Scenario& s) {
			check(vkResetCommandBuffer(cb, 0), "Reset command buffer");
			VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
			check(vkBeginCommandBuffer(cb, &begin), "Begin command buffer");
			if (referenceRun || !splitProducer) encodeProducer(cb, referenceRun ? "copy" : producer, true);
			VkClearValue clear{};
			VkRenderPassBeginInfo pass{VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO};
			pass.renderPass = renderPass;
			pass.framebuffer = framebuffer;
			pass.renderArea = {{0, 0}, {kSide, kSide}};
			pass.clearValueCount = 1;
			pass.pClearValues = &clear;
			vkCmdBeginRenderPass(cb, &pass, VK_SUBPASS_CONTENTS_INLINE);
			// An earlier write in the same render pass must survive the planning passes.
			VkClearAttachment prior{VK_IMAGE_ASPECT_COLOR_BIT, 0, {}};
			prior.clearValue.color.float32[0] = 1.0f;
			prior.clearValue.color.float32[2] = 1.0f;
			prior.clearValue.color.float32[3] = 1.0f;
			VkClearRect priorRect{{{0, 0}, {2, 2}}, 0, 1};
			vkCmdClearAttachments(cb, 1, &prior, 1, &priorRect);
			if (withTES && tesFirst) { vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, tessPipeline); vkCmdDraw(cb, 6, 1, 0, 0); }
			vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, referenceRun ? referencePipeline : indirectPipeline);
			vkCmdBindDescriptorSets(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, graphicsLayout, 0, 1, &sets[0], 0, nullptr);
			if (indexed) vkCmdBindIndexBuffer(cb, work.buffer, kIndexOffset, indexType);
			if (dynamicRestart) vkCmdSetPrimitiveRestartEnableEXT(cb, restartOn);
			if (referenceRun) {
				for (auto& [drawId, a] : executed(s)) {
					vkCmdPushConstants(cb, graphicsLayout, VK_SHADER_STAGE_VERTEX_BIT, 0, 4, &drawId);
					if (indexed) vkCmdDrawIndexed(cb, a.count, a.instances, a.first, a.base, a.firstInstance);
					else vkCmdDraw(cb, a.count, a.instances, a.first, a.firstInstance);
				}
			} else if (form == "draw") {
				vkCmdDrawIndirect(cb, work.buffer, kArgsOffset, scenarioName == "single" ? 1 : 2, kStride);
			} else if (form == "indexed") {
				vkCmdDrawIndexedIndirect(cb, work.buffer, kArgsOffset, scenarioName == "single" ? 1 : 2, kStride);
			} else if (form == "draw-count") {
				vkCmdDrawIndirectCountKHR(cb, work.buffer, kArgsOffset, work.buffer, kCountOffset, scenarioName == "single" ? 1 : 2, kStride);
			} else {
				vkCmdDrawIndexedIndirectCountKHR(cb, work.buffer, kArgsOffset, work.buffer, kCountOffset, scenarioName == "single" ? 1 : 2, kStride);
			}
			if (withTES && !tesFirst) { vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, tessPipeline); vkCmdDraw(cb, 6, 1, 0, 0); }
			vkCmdEndRenderPass(cb);
			VkImageMemoryBarrier toTransfer{VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER};
			toTransfer.srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
			toTransfer.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
			toTransfer.oldLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
			toTransfer.newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
			toTransfer.srcQueueFamilyIndex = toTransfer.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
			toTransfer.image = image;
			toTransfer.subresourceRange = viewInfo.subresourceRange;
			vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, nullptr, 0, nullptr, 1, &toTransfer);
			VkBufferImageCopy copy{};
			copy.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1};
			copy.imageExtent = {kSide, kSide, 1};
			vkCmdCopyImageToBuffer(cb, image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, readback.buffer, 1, &copy);
			VkMemoryBarrier toHost{VK_STRUCTURE_TYPE_MEMORY_BARRIER};
			toHost.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT | VK_ACCESS_SHADER_WRITE_BIT;
			toHost.dstAccessMask = VK_ACCESS_HOST_READ_BIT;
			vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TRANSFER_BIT | VK_PIPELINE_STAGE_VERTEX_SHADER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &toHost, 0, nullptr, 0, nullptr);
			VkResult end = vkEndCommandBuffer(cb);
			std::printf("%s vkEndCommandBuffer=%d\n", referenceRun ? "reference" : "indirect", int(end));
			check(end, "End command buffer");
		};
		if (splitProducer) {
			VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
			check(vkBeginCommandBuffer(producerCommands, &begin), "Begin producer command buffer");
			encodeProducer(producerCommands, producer, false);
			check(vkEndCommandBuffer(producerCommands), "End producer command buffer");
			if (dependentSubmission) {
				check(vkBeginCommandBuffer(dependentCommands, &begin), "Begin dependent command buffer");
				vkCmdFillBuffer(dependentCommands, dependentMarker.buffer, 0, sizeof(uint32_t), 0xA55A5AA5);
				check(vkEndCommandBuffer(dependentCommands), "End dependent command buffer");
			}
		}
		VkFenceCreateInfo fenceInfo{VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
		VkFence fence = VK_NULL_HANDLE;
		check(vkCreateFence(d.device, &fenceInfo, nullptr, &fence), "Create fence");
		VkFence producerFence = VK_NULL_HANDLE;
		if (lateSignal) check(vkCreateFence(d.device, &fenceInfo, nullptr, &producerFence), "Create producer fence");
		VkFence dependentFence = VK_NULL_HANDLE;
		if (dependentSubmission) check(vkCreateFence(d.device, &fenceInfo, nullptr, &dependentFence), "Create dependent fence");
		VkSemaphore semaphore = VK_NULL_HANDLE;
		VkSemaphore hostGate = VK_NULL_HANDLE;
		VkSemaphore dependentSignal = VK_NULL_HANDLE;
		if (dependentSubmission) {
			VkSemaphoreCreateInfo signalInfo{VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
			check(vkCreateSemaphore(d.device, &signalInfo, nullptr, &dependentSignal), "Create dependent semaphore");
		}
		if (splitProducer) {
			VkSemaphoreCreateInfo semaphoreInfo{VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
			check(vkCreateSemaphore(d.device, &semaphoreInfo, nullptr, &semaphore), "Create producer semaphore");
			if (lateSignal) {
				VkSemaphoreTypeCreateInfo typeInfo{VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO};
				typeInfo.semaphoreType = VK_SEMAPHORE_TYPE_TIMELINE;
				semaphoreInfo.pNext = &typeInfo;
				check(vkCreateSemaphore(d.device, &semaphoreInfo, nullptr, &hostGate), "Create host gate");
			}
		}
		struct Result { VkResult submit, wait, dependentSubmit = VK_NOT_READY, dependentBeforeSignal = VK_NOT_READY, dependentWait = VK_NOT_READY; std::vector<uint8_t> image; std::vector<std::array<uint32_t, 4>> records; uint32_t invocations; bool produced; uint32_t dependentMarkerValue = 0; };
		auto run = [&](VkCommandBuffer cb, bool split = false) {
			// Host zeros: a CPU read of arguments, Count or indices while encoding would see an empty draw.
			memset(work.data, 0, kWorkSize);
			memset(effects.data, 0, effects.size);
			memset(readback.data, 0, readback.size);
			if (dependentSubmission) memset(dependentMarker.data, 0, dependentMarker.size);
			check(vkResetFences(d.device, 1, &fence), "Reset fence");
			VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO};
			submit.commandBufferCount = 1;
			submit.pCommandBuffers = &cb;
			if (dependentSubmission && split) { submit.signalSemaphoreCount = 1; submit.pSignalSemaphores = &dependentSignal; }
			Result r{};
			VkResult producerSubmit = VK_SUCCESS;
			VkPipelineStageFlags waitStage = VK_PIPELINE_STAGE_DRAW_INDIRECT_BIT | VK_PIPELINE_STAGE_VERTEX_INPUT_BIT;
			if (split) {
				VkSubmitInfo source{VK_STRUCTURE_TYPE_SUBMIT_INFO};
				VkPipelineStageFlags sourceWaitStage = VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT;
				uint64_t sourceWaitValue = 1, sourceSignalValue = 0;
				VkTimelineSemaphoreSubmitInfo timelineSubmit{VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO};
				source.commandBufferCount = 1;
				source.pCommandBuffers = &producerCommands;
				source.signalSemaphoreCount = 1;
				source.pSignalSemaphores = &semaphore;
				if (lateSignal) {
					timelineSubmit.waitSemaphoreValueCount = timelineSubmit.signalSemaphoreValueCount = 1;
					timelineSubmit.pWaitSemaphoreValues = &sourceWaitValue;
					timelineSubmit.pSignalSemaphoreValues = &sourceSignalValue;
					source.pNext = &timelineSubmit;
					source.waitSemaphoreCount = 1;
					source.pWaitSemaphores = &hostGate;
					source.pWaitDstStageMask = &sourceWaitStage;
				}
				producerSubmit = vkQueueSubmit(d.producerQueue, 1, &source, producerFence);
				submit.waitSemaphoreCount = 1;
				submit.pWaitSemaphores = &semaphore;
				submit.pWaitDstStageMask = &waitStage;
				std::printf("producer submit=%d\n", producerSubmit);
			}
			r.submit = producerSubmit == VK_SUCCESS ? vkQueueSubmit(d.queue, 1, &submit, fence) : producerSubmit;
			if (dependentSubmission && split && r.submit == VK_SUCCESS) {
				VkPipelineStageFlags dependentStage = VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT;
				VkSubmitInfo dependent{VK_STRUCTURE_TYPE_SUBMIT_INFO};
				dependent.waitSemaphoreCount = 1;
				dependent.pWaitSemaphores = &dependentSignal;
				dependent.pWaitDstStageMask = &dependentStage;
				dependent.commandBufferCount = 1;
				dependent.pCommandBuffers = &dependentCommands;
				r.dependentSubmit = vkQueueSubmit(dependentSameQueue ? d.queue : d.producerQueue, 1, &dependent, dependentFence);
				r.dependentBeforeSignal = vkGetFenceStatus(d.device, dependentFence);
				std::printf("dependent queue=%s submit=%d fence before host signal=%d\n", dependentSameQueue ? "draw" : "producer", r.dependentSubmit, r.dependentBeforeSignal);
				if (r.dependentSubmit != VK_SUCCESS || r.dependentBeforeSignal != VK_NOT_READY) throw std::runtime_error("Dependent submission was not pending before host timeline signal");
			}
			if (lateSignal && split && r.submit == VK_SUCCESS) {
				VkResult beforeSignal = vkGetFenceStatus(d.device, producerFence);
				std::printf("both queue submits returned; producer fence before host signal=%d\n", beforeSignal);
				if (beforeSignal != VK_NOT_READY) throw std::runtime_error("Producer completed before host timeline signal");
				VkSemaphoreSignalInfo signal{VK_STRUCTURE_TYPE_SEMAPHORE_SIGNAL_INFO};
				signal.semaphore = hostGate;
				signal.value = 1;
				check(vkSignalSemaphore(d.device, &signal), "Host signal timeline");
			}
			r.wait = r.submit == VK_SUCCESS ? vkWaitForFences(d.device, 1, &fence, VK_TRUE, 20000000000ull) : r.submit;
			if (dependentSubmission && split) {
				r.dependentWait = r.dependentSubmit == VK_SUCCESS ? vkWaitForFences(d.device, 1, &dependentFence, VK_TRUE, 5000000000ull) : r.dependentSubmit;
				memcpy(&r.dependentMarkerValue, dependentMarker.data, sizeof(uint32_t));
				std::printf("dependent wait=%d fence status=%d marker=%08x\n", r.dependentWait, vkGetFenceStatus(d.device, dependentFence), r.dependentMarkerValue);
				if (r.wait == VK_SUCCESS && (r.dependentWait != VK_SUCCESS || r.dependentMarkerValue != 0xA55A5AA5)) throw std::runtime_error("Dependent submission did not complete after the indirect draw");
			}
			if (waitIdleProbe && split) {
				VkResult expectedIdle = r.wait == VK_SUCCESS ? VK_SUCCESS : VK_ERROR_DEVICE_LOST;
				VkResult drawIdle = vkQueueWaitIdle(d.queue);
				VkResult producerIdle = vkQueueWaitIdle(d.producerQueue);
				std::printf("queue idle after indirect draw: draw=%d producer=%d expected=%d\n", drawIdle, producerIdle, expectedIdle);
				if (drawIdle != expectedIdle || producerIdle != expectedIdle) throw std::runtime_error("Queue retirement did not match the indirect outcome");
			}
			r.image.assign(readback.data, readback.data + readback.size);
			memcpy(&r.invocations, effects.data, 4);
			for (uint32_t i = 0; i < std::min(r.invocations, kMaxRecords); ++i) {
				std::array<uint32_t, 4> entry;
				memcpy(entry.data(), effects.data + 16 + i * 16, 16);
				r.records.push_back(entry);
			}
			std::sort(r.records.begin(), r.records.end());
			r.produced = !memcmp(work.data, staging.data, kWorkSize);
			return r;
		};

		// Independent CPU oracle for a lone draw: each triangle is flat, 0.2/0.3/0.5 of its three
		// original vertex colours in order, blended at alpha 0.5 over the zero clear.
		auto sampleOracle = [&](const Scenario& s, const std::vector<uint8_t>& image, uint32_t& samples) {
			auto draws = executed(s);
			if (draws.size() != 1 || restart || topology != VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST) { return true; }
			auto& [drawId, a] = draws[0];
			const float corners[14][2] = {{4, 4}, {4, 4}, {4, 4}, {4, 4}, {-0.8f, -0.8f}, {0.8f, -0.8f}, {0.8f, 0.8f}, {0.8f, 0.8f}, {-0.8f, 0.8f}, {-0.8f, -0.8f}, {-0.8f, -0.8f}, {0.8f, -0.8f}, {0.8f, 0.8f}, {-0.8f, 0.8f}};
			bool ok = true;
			for (uint32_t k = 0; k < a.instances; ++k) {
				uint32_t instance = a.firstInstance + k, baseVertex = indexed ? uint32_t(a.base) : a.first;
				for (uint32_t t = 0; t < 2; ++t) {
					float rgb[3] = {}, x = 0, y = 0;
					for (uint32_t c = 0; c < 3; ++c) {
						uint32_t v = indexed ? sources[3 * t + c] : a.first + 3 * t + c;
						float color[3] = {float(v % 5) * 0.2f, float(v % 3) * 0.4f + 0.1f * float(drawId), 0.25f * float(baseVertex & 3) + 0.05f * float(a.firstInstance)};
						if (instance == 3) { float r = color[0]; color[0] = color[1]; color[1] = color[2]; color[2] = r; }
						for (uint32_t i = 0; i < 3; ++i) rgb[i] += color[i] * (c == 0 ? 0.2f : c == 1 ? 0.3f : 0.5f);
						x += (corners[v][0] * 0.45f + (instance == 2 ? -0.5f : 0.5f)) / 3;
						y += (corners[v][1] * 0.6f - 0.2f + 0.25f * float(drawId)) / 3;
					}
					uint32_t px = uint32_t((x + 1) * 0.5f * kSide), py = uint32_t((y + 1) * 0.5f * kSide);
					const uint8_t* pixel = image.data() + (py * kSide + px) * 4;
					int want[4] = {int(rgb[0] * 0.5f * 255 + 0.5f), int(rgb[1] * 0.5f * 255 + 0.5f), int(rgb[2] * 0.5f * 255 + 0.5f), 64};
					for (uint32_t i = 0; i < 4; ++i) ok &= std::abs(int(pixel[i]) - want[i]) <= 1;
					std::printf("  sample instance=%u triangle=%u pixel=(%u,%u) RGBA=%u,%u,%u,%u expected=%d,%d,%d,%d\n", instance, t, px, py, pixel[0], pixel[1], pixel[2], pixel[3], want[0], want[1], want[2], want[3]);
					++samples;
				}
			}
			return ok;
		};
		bool pass = true;
		for (size_t n = 0; n < submissions.size(); ++n) {
			const Scenario& s = submissions[n];
			fillStaging(s);
			auto expected = expectedRecords(s);
			record(referenceCommands, true, s);
			Result ref = run(referenceCommands);
			bool refOk = ref.submit == VK_SUCCESS && ref.wait == VK_SUCCESS && ref.records == expected && ref.invocations == expected.size();
			// Direct draws are the pixel reference; their recorded invocations must also match the CPU oracle.
			std::printf("submission=%zu reference submit=%d wait=%d invocations=%u expected=%zu records_match=%d\n", n, ref.submit, ref.wait, ref.invocations, expected.size(), int(ref.records == expected));
			if (!n || scenarioName != "repeat") record(indirectCommands, false, s);
			Result got = run(indirectCommands, splitProducer);
			VkResult wantWait = s.expectLost ? VK_ERROR_DEVICE_LOST : VK_SUCCESS;
			size_t mismatches = 0;
			for (size_t i = 0; i < got.image.size(); ++i) mismatches += got.image[i] != ref.image[i];
			bool magenta = got.image[0] == 255 && got.image[1] == 0 && got.image[2] == 255 && got.image[3] == 255;
			// Pixels touched by draws: anything other than the zero clear or the 2x2 prior write.
			uint32_t covered = 0, samples = 0;
			for (uint32_t i = 0; i < kSide * kSide; ++i) covered += (i % kSide >= 2 || i / kSide >= 2) && (got.image[4 * i] | got.image[4 * i + 1] | got.image[4 * i + 2] | got.image[4 * i + 3]);
			bool coverage = expected.empty() ? covered == 0 : covered > 0;
			bool oracle = sampleOracle(s, got.image, samples);
			bool tessOracle = true;
			uint32_t tessRed = 0;
			if (withTES) {
				for (uint32_t x : {7u, 9u, 23u, 25u}) {
					// The indirect draw can cover y=16 when TES runs first; y=4 remains visible.
					const uint8_t* pixel = got.image.data() + (4 * kSide + x) * 4;
					tessOracle &= pixel[0] == 0 && pixel[1] == 255 && pixel[2] == 0 && pixel[3] == 255;
				}
				for (uint32_t y = 0; y < 32; ++y) for (uint32_t x = 0; x < 32; ++x) {
					const uint8_t* pixel = got.image.data() + (y * kSide + x) * 4;
					tessRed += pixel[0] == 255 && pixel[1] == 0 && pixel[2] == 0 && pixel[3] == 255;
				}
				tessOracle &= tessRed == 0;
			}
			bool ok = refOk && got.submit == VK_SUCCESS && got.wait == wantWait && got.produced && !mismatches && magenta && coverage && oracle && tessOracle && got.records == expected && got.invocations == expected.size();
			std::printf("submission=%zu indirect submit=%d wait=%d expected_wait=%d gpu_written_arguments=%d pixel_mismatches=%zu prior_write=%d covered_pixels=%u cpu_samples=%u/%d tess_oracle=%d tess_red=%u invocations=%u expected=%zu records_match=%d %s\n",
				n, got.submit, got.wait, wantWait, int(got.produced), mismatches, int(magenta), covered, samples, int(oracle), int(tessOracle), tessRed, got.invocations, expected.size(), int(got.records == expected), ok ? "PASS" : "FAIL");
			std::ofstream(prefix + "-" + std::to_string(n) + "-indirect.rgba", std::ios::binary).write(reinterpret_cast<const char*>(got.image.data()), got.image.size());
			std::ofstream(prefix + "-" + std::to_string(n) + "-reference.rgba", std::ios::binary).write(reinterpret_cast<const char*>(ref.image.data()), ref.image.size());
			pass &= ok;
			if (s.expectLost) break;  // A lost device accepts no further submissions.
		}
		std::printf("PERVERTEX_INDIRECT %s form=%s index=%s scenario=%s producer=%s\n", pass ? "PASS" : "FAIL", form.c_str(), indexName.c_str(), scenarioName.c_str(), producer.c_str());
		vkDeviceWaitIdle(d.device);
		vkDestroyDevice(d.device, nullptr);
		vkDestroyInstance(instance, nullptr);
		return pass ? 0 : 2;
	} catch (const std::exception& error) {
		std::fprintf(stderr, "ERROR: %s\n", error.what());
		return 1;
	}
}
