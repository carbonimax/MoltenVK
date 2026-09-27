// Copyright 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
// Vulkan oracles for GPU-generated PerVertexKHR TES topology (triangles, equal spacing).
// Positions and tessellation levels reach the TCS through vertex attributes that the GPU copies into a
// host-zeroed buffer earlier in the same command buffer, so no level is available to MoltenVK's CPU.
// Each scenario compares the PerVertex replay with the ordinary hardware TES pipeline (coverage and
// interpolated values), with the barycentric-order consistency Vulkan requires, and with an independent
// CPU model of the ordered triangles; a corner-swapped fragment must fail that model.
#define VK_ENABLE_BETA_EXTENSIONS 1 // VK_KHR_portability_subset
#include <vulkan/vulkan.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <map>
#include <stdexcept>
#include <string>
#include <vector>

extern "C" void mvkEnableTESFixtureDevice(VkPhysicalDevice device) __attribute__((weak_import));

static void check(VkResult result, const char* operation) {
	if (result != VK_SUCCESS) throw std::runtime_error(std::string(operation) + ": " + std::to_string(result));
}

static std::vector<uint32_t> readSpirv(const std::string& path) {
	std::ifstream file(path, std::ios::binary | std::ios::ate);
	if (!file) throw std::runtime_error("Cannot open " + path);
	auto size = file.tellg();
	std::vector<uint32_t> words(size_t(size) / 4);
	file.seekg(0);
	file.read(reinterpret_cast<char*>(words.data()), size);
	return words;
}

static bool hasExtension(const std::vector<VkExtensionProperties>& extensions, const char* name) {
	for (const auto& extension : extensions) if (!strcmp(extension.extensionName, name)) return true;
	return false;
}

static uint32_t bits(float value) { uint32_t word; memcpy(&word, &value, 4); return word; }

constexpr uint32_t kWidth = 192, kHeight = 64, kCell = 64;

// Levels as exact float32 bits: outer[0..2], inner[0]. Mirrored patches reverse screen orientation.
struct Patch { std::array<uint32_t, 4> levels; bool mirrored = false; };

static Patch uniform(uint32_t level, bool mirrored = false) { return {{level, level, level, level}, mirrored}; }

struct Scenario {
	std::vector<Patch> patches;
	std::vector<Patch> reference;  // Ordinary pipeline input with the same Vulkan levels.
	bool expectLost = false;
	bool cull = false;
};

// Vulkan levels after clamp and round-up, or 0 for a discarded patch.
static uint32_t vulkanLevel(const Patch& patch) {
	float outer[3], inner;
	for (int i = 0; i < 3; ++i) memcpy(&outer[i], &patch.levels[i], 4);
	memcpy(&inner, &patch.levels[3], 4);
	for (float level : outer) if (!(level > 0.0f)) return 0;
	return uint32_t(std::ceil(std::min(std::max(outer[0], 1.0f), 64.0f)));
}

struct Point { double u, v, w; };
using Triangle = std::array<int, 3>;

// Metal topologies proven by the ordinary Vulkan oracles, listed with clockwise (u,v) corner order.
static void provenTopology(uint32_t level, std::vector<Point>& points, std::vector<Triangle>& triangles) {
	const Point a{1, 0, 0}, b{0, 1, 0}, c{0, 0, 1};
	if (level == 1) { points = {a, b, c}; triangles = {{0, 1, 2}}; }
	else if (level == 2) {
		points = {a, {.5, .5, 0}, b, {0, .5, .5}, c, {.5, 0, .5}, {1.0 / 3, 1.0 / 3, 1.0 / 3}};
		triangles = {{6, 0, 1}, {6, 1, 2}, {6, 2, 3}, {6, 3, 4}, {6, 4, 5}, {6, 5, 0}};
	} else if (level == 3) {
		const double t = 2.0 / 9.0;
		points = {a, {2.0 / 3, 1.0 / 3, 0}, {1.0 / 3, 2.0 / 3, 0}, b, {0, 2.0 / 3, 1.0 / 3}, {0, 1.0 / 3, 2.0 / 3}, c, {1.0 / 3, 0, 2.0 / 3}, {2.0 / 3, 0, 1.0 / 3}, {1 - 2 * t, t, t}, {t, 1 - 2 * t, t}, {t, t, 1 - 2 * t}};
		triangles = {{9, 8, 0}, {9, 0, 1}, {10, 2, 3}, {10, 3, 4}, {11, 5, 6}, {11, 6, 7}, {9, 10, 11}, {9, 1, 10}, {10, 1, 2}, {10, 4, 11}, {11, 4, 5}, {11, 7, 9}, {9, 7, 8}};
	} else { points.clear(); triangles.clear(); }
}

static std::array<std::array<double, 2>, 3> controlPoints(uint32_t patch, bool mirrored) {
	std::array<std::array<double, 2>, 3> points{{{4, 60}, {60, 60}, {32, 4}}};
	for (auto& point : points) point[0] += kCell * patch;
	if (mirrored) std::swap(points[1], points[2]);
	return points;
}

struct Image { std::vector<uint8_t> rgba; VkResult submit = VK_SUCCESS, wait = VK_SUCCESS; };

int main(int argc, char** argv) {
	try {
		if (argc != 5) throw std::runtime_error("Usage: topology shader-dir scenario ccw|cw output-prefix");
		const std::string shaders = argv[1], scenarioName = argv[2], winding = argv[3], prefix = argv[4];
		const bool ccw = winding == "ccw";
		if (!ccw && winding != "cw") throw std::runtime_error("winding must be ccw or cw");
		const uint32_t one = bits(1.0f), two = bits(2.0f), three = bits(3.0f), nan = 0x7fc00000u;
		std::map<std::string, Scenario> scenarios;
		scenarios["f1"] = {{uniform(one), uniform(one)}, {}};
		scenarios["f2"] = {{uniform(two), uniform(two)}, {}};
		scenarios["f3"] = {{uniform(three), uniform(three)}, {}};
		// nextafter(1, +inf) is level 2 in Vulkan; the ordinary half path renders level 1 (known defect).
		scenarios["next"] = {{uniform(0x3f800001u), uniform(0x3f800001u)}, {uniform(two), uniform(two)}};
		// Two patches with different levels around a patch discarded by a zero outer level.
		scenarios["mixed"] = {{uniform(two), {{0, three, three, three}}, uniform(three)}, {}};
		scenarios["nan"] = {{uniform(three), {{three, nan, three, three}}, uniform(two)}, {}};
		// Clamp and round up: 1.5 -> 2, 2.9 -> 3, 0.25 -> 1 (values exact in half for the ordinary pipeline).
		scenarios["fraction"] = {{uniform(bits(1.5f)), uniform(bits(2.9f)), uniform(bits(0.25f))}, {}};
		scenarios["cull"] = {{uniform(three), uniform(three, true), uniform(two)}, {}, false, true};
		scenarios["level4"] = {{uniform(bits(4.0f)), uniform(two)}, {}, true};
		scenarios["nonuniform"] = {{{{one, two, one, one}}}, {}, true};
		scenarios["inner-nan"] = {{{{two, two, two, nan}}}, {}, true};
		const bool rejection = scenarioName.rfind("reject-", 0) == 0 || scenarioName == "public-device-gate";
		if (!rejection && !scenarios.count(scenarioName)) throw std::runtime_error("Unknown scenario");
		Scenario scenario = rejection ? Scenario{{uniform(two)}, {}} : scenarios[scenarioName];
		if (scenario.reference.empty()) scenario.reference = scenario.patches;

		uint32_t count = 0;
		check(vkEnumerateInstanceExtensionProperties(nullptr, &count, nullptr), "Enumerate instance extensions");
		std::vector<VkExtensionProperties> instanceExtensions(count);
		check(vkEnumerateInstanceExtensionProperties(nullptr, &count, instanceExtensions.data()), "Read instance extensions");
		const bool portability = hasExtension(instanceExtensions, VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME);
		const char* portabilityName = VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME;
		VkApplicationInfo app{VK_STRUCTURE_TYPE_APPLICATION_INFO};
		app.pApplicationName = "PerVertexKHR TES topology";
		app.apiVersion = VK_API_VERSION_1_1;
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
		VkPhysicalDevice physical = physicals.at(0);
		if (scenarioName == "public-device-gate") {
			check(vkEnumerateDeviceExtensionProperties(physical, nullptr, &count, nullptr), "Enumerate device extensions");
			std::vector<VkExtensionProperties> extensions(count);
			check(vkEnumerateDeviceExtensionProperties(physical, nullptr, &count, extensions.data()), "Read device extensions");
			VkPhysicalDeviceFragmentShaderBarycentricFeaturesKHR barycentric{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FRAGMENT_SHADER_BARYCENTRIC_FEATURES_KHR};
			VkPhysicalDeviceFeatures2 features{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2};
			features.pNext = &barycentric;
			vkGetPhysicalDeviceFeatures2(physical, &features);
			bool closed = !hasExtension(extensions, VK_KHR_FRAGMENT_SHADER_BARYCENTRIC_EXTENSION_NAME) && !barycentric.fragmentShaderBarycentric && !mvkEnableTESFixtureDevice;
			std::printf("TES_TOPOLOGY %s public-device-gate: barycentric extension and feature closed, test adapter absent\n", closed ? "PASS" : "FAIL");
			return closed ? 0 : 2;
		}
		if (!mvkEnableTESFixtureDevice) throw std::runtime_error("Test device adapter was not linked");
		mvkEnableTESFixtureDevice(physical);
		check(vkEnumerateDeviceExtensionProperties(physical, nullptr, &count, nullptr), "Enumerate device extensions");
		std::vector<VkExtensionProperties> extensions(count);
		check(vkEnumerateDeviceExtensionProperties(physical, nullptr, &count, extensions.data()), "Read device extensions");
		VkPhysicalDeviceFragmentShaderBarycentricFeaturesKHR barycentric{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FRAGMENT_SHADER_BARYCENTRIC_FEATURES_KHR};
		VkPhysicalDeviceFeatures2 features{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2};
		features.pNext = &barycentric;
		vkGetPhysicalDeviceFeatures2(physical, &features);
		if (!barycentric.fragmentShaderBarycentric || !features.features.tessellationShader) throw std::runtime_error("Barycentric or tessellation feature unavailable");
		uint32_t family = 0;
		vkGetPhysicalDeviceQueueFamilyProperties(physical, &count, nullptr);
		std::vector<VkQueueFamilyProperties> families(count);
		vkGetPhysicalDeviceQueueFamilyProperties(physical, &count, families.data());
		while (!(families.at(family).queueFlags & VK_QUEUE_GRAPHICS_BIT)) ++family;
		features.features = {};
		features.features.tessellationShader = VK_TRUE;
		float priority = 1;
		VkDeviceQueueCreateInfo queueInfo{VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};
		queueInfo.queueFamilyIndex = family;
		queueInfo.queueCount = 1;
		queueInfo.pQueuePriorities = &priority;
		std::vector<const char*> deviceExtensions{VK_KHR_FRAGMENT_SHADER_BARYCENTRIC_EXTENSION_NAME, VK_KHR_MAINTENANCE_2_EXTENSION_NAME};
		if (hasExtension(extensions, VK_KHR_PORTABILITY_SUBSET_EXTENSION_NAME)) deviceExtensions.push_back(VK_KHR_PORTABILITY_SUBSET_EXTENSION_NAME);
		VkDeviceCreateInfo deviceInfo{VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO};
		deviceInfo.pNext = &features;
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
		std::printf("DEVICE=%s scenario=%s winding=%s maxTessellationGenerationLevel=%u\n", properties.deviceName, scenarioName.c_str(), winding.c_str(), properties.limits.maxTessellationGenerationLevel);

		auto memoryType = [&](uint32_t typeBits, VkMemoryPropertyFlags flags) {
			VkPhysicalDeviceMemoryProperties memory{};
			vkGetPhysicalDeviceMemoryProperties(physical, &memory);
			for (uint32_t i = 0; i < memory.memoryTypeCount; ++i)
				if ((typeBits & (1u << i)) && (memory.memoryTypes[i].propertyFlags & flags) == flags) return i;
			throw std::runtime_error("No suitable memory type");
		};
		struct Buffer { VkBuffer buffer; VkDeviceMemory memory; uint8_t* data; VkDeviceSize size; };
		auto makeBuffer = [&](VkDeviceSize size, VkBufferUsageFlags usage) {
			Buffer b{VK_NULL_HANDLE, VK_NULL_HANDLE, nullptr, size};
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
		constexpr uint32_t kVertexStride = 32;
		Buffer vertices = makeBuffer(3 * 3 * kVertexStride, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT);
		Buffer staging = makeBuffer(vertices.size, VK_BUFFER_USAGE_TRANSFER_SRC_BIT);
		Buffer readback = makeBuffer(kWidth * kHeight * 4, VK_BUFFER_USAGE_TRANSFER_DST_BIT);

		VkImageCreateInfo imageInfo{VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO};
		imageInfo.imageType = VK_IMAGE_TYPE_2D;
		imageInfo.format = VK_FORMAT_R8G8B8A8_UNORM;
		imageInfo.extent = {kWidth, kHeight, 1};
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
		check(vkCreateRenderPass(device, &passInfo, nullptr, &renderPass), "Create render pass");
		VkFramebufferCreateInfo framebufferInfo{VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO};
		framebufferInfo.renderPass = renderPass;
		framebufferInfo.attachmentCount = 1;
		framebufferInfo.pAttachments = &view;
		framebufferInfo.width = kWidth;
		framebufferInfo.height = kHeight;
		framebufferInfo.layers = 1;
		VkFramebuffer framebuffer = VK_NULL_HANDLE;
		check(vkCreateFramebuffer(device, &framebufferInfo, nullptr, &framebuffer), "Create framebuffer");

		// Descriptor layout used only by the descriptor refusal case.
		VkDescriptorSetLayoutBinding uniformBinding{0, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 1, VK_SHADER_STAGE_TESSELLATION_CONTROL_BIT, nullptr};
		VkDescriptorSetLayoutCreateInfo setLayoutInfo{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO};
		setLayoutInfo.bindingCount = 1;
		setLayoutInfo.pBindings = &uniformBinding;
		VkDescriptorSetLayout setLayout = VK_NULL_HANDLE;
		check(vkCreateDescriptorSetLayout(device, &setLayoutInfo, nullptr, &setLayout), "Create set layout");
		VkPipelineLayoutCreateInfo layoutInfo{VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};
		VkPipelineLayout emptyLayout = VK_NULL_HANDLE, uniformLayout = VK_NULL_HANDLE;
		check(vkCreatePipelineLayout(device, &layoutInfo, nullptr, &emptyLayout), "Create pipeline layout");
		layoutInfo.setLayoutCount = 1;
		layoutInfo.pSetLayouts = &setLayout;
		check(vkCreatePipelineLayout(device, &layoutInfo, nullptr, &uniformLayout), "Create uniform pipeline layout");

		std::map<std::string, VkShaderModule> modules;
		auto module = [&](const std::string& name) {
			auto found = modules.find(name);
			if (found != modules.end()) return found->second;
			auto code = readSpirv(shaders + "/" + name);
			VkShaderModuleCreateInfo info{VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO};
			info.codeSize = code.size() * 4;
			info.pCode = code.data();
			VkShaderModule result = VK_NULL_HANDLE;
			check(vkCreateShaderModule(device, &info, nullptr, &result), "Create shader module");
			return modules[name] = result;
		};
		struct PipelineOptions { std::string tesc = "topology.tesc.spv", tese, frag; bool cull = false, lowerLeft = false, cache = false, uniform = false; };
		auto createPipeline = [&](const PipelineOptions& o, VkPipeline& pipeline) {
			VkPipelineShaderStageCreateInfo stages[4]{};
			const VkShaderStageFlagBits stageBits[4] = {VK_SHADER_STAGE_VERTEX_BIT, VK_SHADER_STAGE_TESSELLATION_CONTROL_BIT, VK_SHADER_STAGE_TESSELLATION_EVALUATION_BIT, VK_SHADER_STAGE_FRAGMENT_BIT};
			const std::string names[4] = {"topology.vert.spv", o.tesc, o.tese, o.frag};
			for (int i = 0; i < 4; ++i) {
				stages[i].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
				stages[i].stage = stageBits[i];
				stages[i].module = module(names[i]);
				stages[i].pName = "main";
			}
			VkVertexInputBindingDescription binding{0, kVertexStride, VK_VERTEX_INPUT_RATE_VERTEX};
			VkVertexInputAttributeDescription attributes[2] = {{0, 0, VK_FORMAT_R32G32_SFLOAT, 0}, {1, 0, VK_FORMAT_R32G32B32A32_SFLOAT, 16}};
			VkPipelineVertexInputStateCreateInfo vertexInput{VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO};
			vertexInput.vertexBindingDescriptionCount = 1;
			vertexInput.pVertexBindingDescriptions = &binding;
			vertexInput.vertexAttributeDescriptionCount = 2;
			vertexInput.pVertexAttributeDescriptions = attributes;
			VkPipelineInputAssemblyStateCreateInfo assembly{VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO};
			assembly.topology = VK_PRIMITIVE_TOPOLOGY_PATCH_LIST;
			VkPipelineTessellationDomainOriginStateCreateInfo origin{VK_STRUCTURE_TYPE_PIPELINE_TESSELLATION_DOMAIN_ORIGIN_STATE_CREATE_INFO};
			origin.domainOrigin = VK_TESSELLATION_DOMAIN_ORIGIN_LOWER_LEFT;
			VkPipelineTessellationStateCreateInfo tessellation{VK_STRUCTURE_TYPE_PIPELINE_TESSELLATION_STATE_CREATE_INFO};
			tessellation.pNext = o.lowerLeft ? &origin : nullptr;
			tessellation.patchControlPoints = 3;
			VkViewport viewport{0, 0, float(kWidth), float(kHeight), 0, 1};
			VkRect2D scissor{{0, 0}, {kWidth, kHeight}};
			VkPipelineViewportStateCreateInfo viewportState{VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO};
			viewportState.viewportCount = 1;
			viewportState.pViewports = &viewport;
			viewportState.scissorCount = 1;
			viewportState.pScissors = &scissor;
			VkPipelineRasterizationStateCreateInfo raster{VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO};
			raster.polygonMode = VK_POLYGON_MODE_FILL;
			raster.cullMode = o.cull ? VK_CULL_MODE_BACK_BIT : VK_CULL_MODE_NONE;
			raster.frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE;
			raster.lineWidth = 1;
			VkPipelineMultisampleStateCreateInfo multisample{VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO};
			multisample.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;
			VkPipelineColorBlendAttachmentState blendAttachment{};
			blendAttachment.colorWriteMask = 0xF;
			VkPipelineColorBlendStateCreateInfo blend{VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO};
			blend.attachmentCount = 1;
			blend.pAttachments = &blendAttachment;
			VkGraphicsPipelineCreateInfo info{VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO};
			info.stageCount = 4;
			info.pStages = stages;
			info.pVertexInputState = &vertexInput;
			info.pInputAssemblyState = &assembly;
			info.pTessellationState = &tessellation;
			info.pViewportState = &viewportState;
			info.pRasterizationState = &raster;
			info.pMultisampleState = &multisample;
			info.pColorBlendState = &blend;
			info.layout = o.uniform ? uniformLayout : emptyLayout;
			info.renderPass = renderPass;
			VkPipelineCache cache = VK_NULL_HANDLE;
			if (o.cache) {
				VkPipelineCacheCreateInfo cacheInfo{VK_STRUCTURE_TYPE_PIPELINE_CACHE_CREATE_INFO};
				check(vkCreatePipelineCache(device, &cacheInfo, nullptr, &cache), "Create pipeline cache");
			}
			return vkCreateGraphicsPipelines(device, cache, 1, &info, nullptr, &pipeline);
		};

		VkCommandPoolCreateInfo poolInfo{VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};
		poolInfo.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
		poolInfo.queueFamilyIndex = family;
		VkCommandPool pool = VK_NULL_HANDLE;
		check(vkCreateCommandPool(device, &poolInfo, nullptr, &pool), "Create command pool");
		VkCommandBufferAllocateInfo commandInfo{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
		commandInfo.commandPool = pool;
		commandInfo.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
		commandInfo.commandBufferCount = 1;
		VkCommandBuffer command = VK_NULL_HANDLE;
		check(vkAllocateCommandBuffers(device, &commandInfo, &command), "Allocate command buffer");
		VkFenceCreateInfo fenceInfo{VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
		VkFence fence = VK_NULL_HANDLE;
		check(vkCreateFence(device, &fenceInfo, nullptr, &fence), "Create fence");

		// Records: host zeros the vertex buffer; the GPU copies positions and levels, then draws.
		auto record = [&](VkPipeline pipeline, const std::vector<Patch>& patches, uint32_t firstVertex, uint32_t instances) {
			memset(staging.data, 0, staging.size);
			for (uint32_t p = 0; p < patches.size(); ++p) {
				auto points = controlPoints(p, patches[p].mirrored);
				for (uint32_t c = 0; c < 3; ++c) {
					float position[2] = {float(points[c][0] * 2 / kWidth - 1), float(points[c][1] * 2 / kHeight - 1)};
					memcpy(staging.data + (3 * p + c) * kVertexStride, position, 8);
					memcpy(staging.data + (3 * p + c) * kVertexStride + 16, patches[p].levels.data(), 16);
				}
			}
			check(vkResetCommandBuffer(command, 0), "Reset command buffer");
			VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
			check(vkBeginCommandBuffer(command, &begin), "Begin command buffer");
			VkBufferCopy copy{0, 0, staging.size};
			vkCmdCopyBuffer(command, staging.buffer, vertices.buffer, 1, &copy);
			VkMemoryBarrier produced{VK_STRUCTURE_TYPE_MEMORY_BARRIER};
			produced.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
			produced.dstAccessMask = VK_ACCESS_VERTEX_ATTRIBUTE_READ_BIT;
			vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_VERTEX_INPUT_BIT, 0, 1, &produced, 0, nullptr, 0, nullptr);
			VkClearValue clear{};
			VkRenderPassBeginInfo pass{VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO};
			pass.renderPass = renderPass;
			pass.framebuffer = framebuffer;
			pass.renderArea = {{0, 0}, {kWidth, kHeight}};
			pass.clearValueCount = 1;
			pass.pClearValues = &clear;
			vkCmdBeginRenderPass(command, &pass, VK_SUBPASS_CONTENTS_INLINE);
			// An earlier write in the same render pass must survive the compute stages.
			VkClearAttachment prior{VK_IMAGE_ASPECT_COLOR_BIT, 0, {}};
			prior.clearValue.color.float32[0] = 1.0f;
			prior.clearValue.color.float32[2] = 1.0f;
			prior.clearValue.color.float32[3] = 1.0f;
			VkClearRect priorRect{{{0, 0}, {2, 2}}, 0, 1};
			vkCmdClearAttachments(command, 1, &prior, 1, &priorRect);
			vkCmdBindPipeline(command, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
			VkDeviceSize offset = 0;
			vkCmdBindVertexBuffers(command, 0, 1, &vertices.buffer, &offset);
			vkCmdDraw(command, uint32_t(3 * patches.size()), instances, firstVertex, 0);
			vkCmdEndRenderPass(command);
			VkImageMemoryBarrier toTransfer{VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER};
			toTransfer.srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
			toTransfer.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
			toTransfer.oldLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
			toTransfer.newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
			toTransfer.srcQueueFamilyIndex = toTransfer.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
			toTransfer.image = image;
			toTransfer.subresourceRange = viewInfo.subresourceRange;
			vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, nullptr, 0, nullptr, 1, &toTransfer);
			VkBufferImageCopy imageCopy{};
			imageCopy.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1};
			imageCopy.imageExtent = {kWidth, kHeight, 1};
			vkCmdCopyImageToBuffer(command, image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, readback.buffer, 1, &imageCopy);
			VkMemoryBarrier toHost{VK_STRUCTURE_TYPE_MEMORY_BARRIER};
			toHost.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
			toHost.dstAccessMask = VK_ACCESS_HOST_READ_BIT;
			vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &toHost, 0, nullptr, 0, nullptr);
			return vkEndCommandBuffer(command);
		};
		auto render = [&](const PipelineOptions& o, const std::vector<Patch>& patches, const std::string& name) {
			VkPipeline pipeline = VK_NULL_HANDLE;
			check(createPipeline(o, pipeline), ("Create pipeline " + name).c_str());
			check(record(pipeline, patches, 0, 1), ("Record " + name).c_str());
			memset(vertices.data, 0, vertices.size);
			memset(readback.data, 0, readback.size);
			check(vkResetFences(device, 1, &fence), "Reset fence");
			VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO};
			submit.commandBufferCount = 1;
			submit.pCommandBuffers = &command;
			Image result;
			result.submit = vkQueueSubmit(queue, 1, &submit, fence);
			result.wait = result.submit == VK_SUCCESS ? vkWaitForFences(device, 1, &fence, VK_TRUE, 20000000000ull) : result.submit;
			result.rgba.assign(readback.data, readback.data + readback.size);
			std::ofstream(prefix + "-" + name + ".rgba", std::ios::binary).write(reinterpret_cast<const char*>(result.rgba.data()), result.rgba.size());
			std::printf("render %s submit=%d wait=%d\n", name.c_str(), result.submit, result.wait);
			return result;
		};

		const std::string tese = ccw ? "ccw.tese.spv" : "cw.tese.spv";
		if (rejection) {
			// Every refusal is deterministic and happens before submission.
			PipelineOptions o{"topology.tesc.spv", tese, "interp.frag.spv"};
			VkResult expected = VK_ERROR_FEATURE_NOT_PRESENT, actual = VK_SUCCESS;
			VkPipeline pipeline = VK_NULL_HANDLE;
			if (scenarioName == "reject-quads") o.tese = "quads.tese.spv";
			else if (scenarioName == "reject-fractional") o.tese = "fractional.tese.spv";
			else if (scenarioName == "reject-point-mode") o.tese = "points.tese.spv";
			else if (scenarioName == "reject-lower-left") o.lowerLeft = true;
			else if (scenarioName == "reject-descriptor") { o.tesc = "descriptor.tesc.spv"; o.uniform = true; }
			else if (scenarioName == "reject-cache") o.cache = true;
			else if (scenarioName == "reject-no-admission") {}
			else if (scenarioName == "reject-first-vertex" || scenarioName == "reject-instances") {
				check(createPipeline(o, pipeline), "Create admitted pipeline");
				actual = record(pipeline, {uniform(two)}, scenarioName == "reject-first-vertex" ? 3 : 0, scenarioName == "reject-instances" ? 2 : 1);
				std::printf("TES_TOPOLOGY %s %s: vkEndCommandBuffer=%d expected=%d, nothing submitted\n", actual == expected ? "PASS" : "FAIL", scenarioName.c_str(), actual, expected);
				return actual == expected ? 0 : 2;
			} else throw std::runtime_error("Unknown refusal");
			actual = createPipeline(o, pipeline);
			// The same modes stay available to ordinary tessellation.
			PipelineOptions ordinary = o;
			ordinary.frag = "ordinary.frag.spv";
			VkPipeline ordinaryPipeline = VK_NULL_HANDLE;
			VkResult ordinaryResult = createPipeline(ordinary, ordinaryPipeline);
			// Ordinary point-mode TES pipelines already fail in MoltenVK (point size with a triangle input
			// topology), independently of this path; only the PerVertex refusal is asserted for that mode.
			bool pass = actual == expected && (ordinaryResult == VK_SUCCESS || scenarioName == "reject-point-mode");
			std::printf("TES_TOPOLOGY %s %s: PerVertex pipeline=%d expected=%d, ordinary pipeline=%d\n", pass ? "PASS" : "FAIL", scenarioName.c_str(), actual, expected, ordinaryResult);
			return pass ? 0 : 2;
		}

		auto covered = [](const std::vector<uint8_t>& rgba, uint32_t pixel) { return rgba[4 * pixel + 3] != 0 && pixel % kWidth >= 2; };
		bool pass = true;
		auto verdict = [&](bool ok, const char* what) { std::printf("  %s %s\n", ok ? "ok  " : "FAIL", what); pass &= ok; };
		auto prior = [](const std::vector<uint8_t>& rgba) { return rgba[0] == 255 && rgba[1] == 0 && rgba[2] == 255 && rgba[3] == 255; };

		if (scenario.expectLost) {
			Image lost = render({"topology.tesc.spv", tese, "interp.frag.spv"}, scenario.patches, "pervertex");
			uint32_t pixels = 0;
			for (uint32_t i = 0; i < kWidth * kHeight; ++i) pixels += covered(lost.rgba, i);
			verdict(lost.submit == VK_SUCCESS && lost.wait == VK_ERROR_DEVICE_LOST, "submission accepted, fence reports VK_ERROR_DEVICE_LOST");
			verdict(pixels == 0 && prior(lost.rgba), "no pixel of the refused draw, earlier attachment write preserved");
			std::printf("TES_TOPOLOGY %s %s %s\n", pass ? "PASS" : "FAIL", scenarioName.c_str(), winding.c_str());
			return pass ? 0 : 2;
		}

		Image ordinaryImage = render({"topology.tesc.spv", tese, "ordinary.frag.spv", scenario.cull}, scenario.reference, "ordinary");
		Image interp = render({"topology.tesc.spv", tese, "interp.frag.spv", scenario.cull}, scenario.patches, "interp");
		Image ordered = render({"topology.tesc.spv", tese, "ordered.frag.spv", scenario.cull}, scenario.patches, "ordered");
		Image swapped = render({"topology.tesc.spv", tese, "swapped.frag.spv", scenario.cull}, scenario.patches, "swapped");
		Image consistency = render({"topology.tesc.spv", tese, "consistency.frag.spv", scenario.cull}, scenario.patches, "consistency");
		for (const Image* image : {&ordinaryImage, &interp, &ordered, &swapped, &consistency}) pass &= image->submit == VK_SUCCESS && image->wait == VK_SUCCESS;
		verdict(pass, "all submissions and fences succeed");

		// 1. Coverage and interpolated values against the ordinary hardware TES pipeline.
		uint32_t coverageMismatch = 0, valueMismatch = 0, coveredPixels = 0, maxDifference = 0;
		for (uint32_t i = 0; i < kWidth * kHeight; ++i) {
			bool a = covered(ordinaryImage.rgba, i), b = covered(interp.rgba, i);
			coveredPixels += a;
			if (a != b) { ++coverageMismatch; continue; }
			if (!a) continue;
			uint32_t difference = 0;
			for (int c = 0; c < 3; ++c) difference = std::max<uint32_t>(difference, std::abs(int(ordinaryImage.rgba[4 * i + c]) - int(interp.rgba[4 * i + c])));
			maxDifference = std::max(maxDifference, difference);
			valueMismatch += difference > 2;
		}
		std::printf("  ordinary vs PerVertex: covered=%u coverage_mismatch=%u value_mismatch(>2)=%u max_difference=%u\n", coveredPixels, coverageMismatch, valueMismatch, maxDifference);
		verdict(coveredPixels > 0 && coverageMismatch == 0 && valueMismatch == 0, "PerVertex replay matches ordinary TES coverage and interpolation");
		// 2. Vulkan's barycentric-order consistency: every covered pixel green.
		uint32_t green = 0, red = 0;
		for (uint32_t i = 0; i < kWidth * kHeight; ++i) {
			if (!covered(consistency.rgba, i)) continue;
			const uint8_t* p = &consistency.rgba[4 * i];
			green += p[0] == 0 && p[1] == 255 && p[2] == 0;
			red += !(p[0] == 0 && p[1] == 255 && p[2] == 0);
		}
		std::printf("  barycentric consistency: green=%u other=%u\n", green, red);
		verdict(green > 0 && red == 0 && green == coveredPixels, "PerVertexKHR order matches BaryCoordKHR on every covered pixel");
		// 3. Ordered triangles against the independent CPU model, sampled at each triangle's centroid.
		uint32_t triangles = 0, culled = 0, orderedWrong = 0, swappedWrong = 0;
		for (uint32_t p = 0; p < scenario.patches.size(); ++p) {
			uint32_t level = vulkanLevel(scenario.patches[p]);
			std::vector<Point> points;
			std::vector<Triangle> topology;
			provenTopology(level, points, topology);
			auto control = controlPoints(p, scenario.patches[p].mirrored);
			for (auto triangle : topology) {
				if (ccw) std::swap(triangle[1], triangle[2]);
				double cx = 0, cy = 0, expected[3] = {};
				double screen[3][2];
				for (int c = 0; c < 3; ++c) {
					const Point& q = points[triangle[c]];
					double color[3] = {q.u * q.u, q.v * q.v, 0.5 * q.w * q.w + 0.25 * p};
					for (int k = 0; k < 3; ++k) expected[k] += color[k] * (c == 0 ? 0.2 : c == 1 ? 0.3 : 0.5);
					for (int d = 0; d < 2; ++d) screen[c][d] = q.u * control[0][d] + q.v * control[1][d] + q.w * control[2][d];
					cx += screen[c][0] / 3;
					cy += screen[c][1] / 3;
				}
				uint32_t x = uint32_t(cx), y = uint32_t(cy), pixel = y * kWidth + x;
				// With culling, the ordinary pipeline decides which faces remain (coverage is compared above).
				if (scenario.cull && !covered(ordinaryImage.rgba, pixel)) { ++culled; continue; }
				++triangles;
				for (int k = 0; k < 3; ++k) {
					orderedWrong += std::abs(int(ordered.rgba[4 * pixel + k]) - int(std::lround(expected[k] * 255))) > 1;
					swappedWrong += std::abs(int(swapped.rgba[4 * pixel + k]) - int(std::lround(expected[k] * 255))) > 1;
				}
			}
		}
		std::printf("  CPU model: triangles_sampled=%u culled=%u ordered_channel_mismatch=%u swapped_channel_mismatch=%u\n", triangles, culled, orderedWrong, swappedWrong);
		if (scenario.cull) verdict(culled > 0 && triangles > 0, "culling removes the back-facing patch and keeps the front-facing ones");
		verdict(triangles > 0 && orderedWrong == 0, "ordered PerVertex values match the CPU model at every triangle");
		verdict(swappedWrong > 0, "negative control: swapped corners fail the CPU model");
		verdict(prior(ordinaryImage.rgba) && prior(interp.rgba), "earlier attachment write preserved");
		if (scenarioName == "next") {
			// Same Vulkan level 2 as exact 2.0 for PerVertex; the ordinary half path renders level 1 instead.
			Image twoImage = render({"topology.tesc.spv", tese, "interp.frag.spv"}, {uniform(two), uniform(two)}, "interp-two");
			Image ordinaryNext = render({"topology.tesc.spv", tese, "ordinary.frag.spv"}, scenario.patches, "ordinary-next");
			Image ordinaryOne = render({"topology.tesc.spv", tese, "ordinary.frag.spv"}, {uniform(one), uniform(one)}, "ordinary-one");
			verdict(twoImage.rgba == interp.rgba, "PerVertex nextafter(1,+inf) image identical to PerVertex level 2.0");
			verdict(ordinaryNext.rgba == ordinaryOne.rgba && ordinaryNext.rgba != ordinaryImage.rgba, "ordinary half path still renders nextafter as level 1 (documented divergence)");
		}
		std::printf("TES_TOPOLOGY %s %s %s\n", pass ? "PASS" : "FAIL", scenarioName.c_str(), winding.c_str());
		vkDeviceWaitIdle(device);
		return pass ? 0 : 2;
	} catch (const std::exception& error) {
		std::fprintf(stderr, "ERROR: %s\n", error.what());
		return 1;
	}
}
