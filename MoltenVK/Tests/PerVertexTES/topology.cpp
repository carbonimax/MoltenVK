// Copyright 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
// Vulkan oracles for GPU-generated PerVertexKHR TES topology (triangles, equal spacing).
// Positions and tessellation levels reach the TCS through vertex attributes that the GPU copies into a
// host-zeroed buffer earlier in the same command buffer, so no level is available to MoltenVK's CPU.
// Each scenario compares the PerVertex replay with the ordinary hardware TES pipeline (coverage and
// interpolated values), with the barycentric-order consistency Vulkan requires, and with an independent
// CPU model of the ordered triangles; a corner-swapped fragment must fail that model.
// Every rendered scenario also checks Vulkan's fragment gl_PrimitiveID (the TES patch index) and the
// tessellation coordinates the fragment receives: invariance rules 3, 4 and 8 and bitwise equality with the
// coordinates the hardware tessellator gives the ordinary TES. Seam scenarios share one edge between patches.
// "ordinary-levels-*" scenarios need neither the barycentric extension nor the test adapter, so they also run on
// the shipping library: for TCS levels that half precision would change (nextafter(1,+inf), underflow, infinity),
// the ordinary pipeline must render and tessellate exactly like the Vulkan level representative computed on the
// host, and its TES must read the levels exactly as the TCS wrote them. Each Vulkan draw command is covered, as
// one draw and as two draws in the same render pass (two indirect commands for the indirect variants).
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
#include <set>
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
	std::string vertex = "topology.vert.spv";
	bool resources = false;  // VS storage-buffer counter and fragment uniform scale.
	uint32_t vertexCount = 0;  // Draw size when it is not three vertices per patch.
	bool seam = false;  // The second patch shares an edge with the first one.
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

// Integer pixel positions. A seam pair shares the edge (60,60)-(32,4): the u = 0 edge of the first patch is
// the w = 0 edge of the second one, traversed in the opposite direction (invariance rules 3 and 4).
static std::array<std::array<double, 2>, 3> controlPoints(uint32_t patch, bool mirrored, bool seam) {
	if (seam && patch == 1) return {{{32, 4}, {60, 60}, {88, 4}}};
	std::array<std::array<double, 2>, 3> points{{{4, 60}, {60, 60}, {32, 4}}};
	for (auto& point : points) point[0] += kCell * patch;
	if (mirrored) std::swap(points[1], points[2]);
	return points;
}

// One tessellated vertex: patch, then u, v, w bits, mapped to its pixel-position bits.
using CoordinateKey = std::array<uint32_t, 4>;
using Coordinates = std::map<CoordinateKey, std::array<uint32_t, 2>>;

static float asFloat(uint32_t word) { float value; memcpy(&value, &word, 4); return value; }

// Capture TES record: patch, u, v, w, pixel x, pixel y, then outer[0..2] and inner[0] as the TES read them.
constexpr uint32_t kCaptureWords = 10;

struct Image { std::vector<uint8_t> rgba; VkResult submit = VK_SUCCESS, wait = VK_SUCCESS; uint32_t invocations = 0; std::vector<uint32_t> tesCapture, fragmentCapture; };

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
		// nextafter(1, +inf) is level 2 in Vulkan, on the PerVertex and the ordinary path alike.
		scenarios["next"] = {{uniform(0x3f800001u), uniform(0x3f800001u)}, {}};
		// Two patches with different levels around a patch discarded by a zero outer level.
		scenarios["mixed"] = {{uniform(two), {{0, three, three, three}}, uniform(three)}, {}};
		scenarios["nan"] = {{uniform(three), {{three, nan, three, three}}, uniform(two)}, {}};
		// Clamp and round up: 1.5 -> 2, 2.9 -> 3, 0.25 -> 1 (values exact in half for the ordinary pipeline).
		scenarios["fraction"] = {{uniform(bits(1.5f)), uniform(bits(2.9f)), uniform(bits(0.25f))}, {}};
		scenarios["cull"] = {{uniform(three), uniform(three, true), uniform(two)}, {}, false, true};
		scenarios["level4"] = {{uniform(bits(4.0f)), uniform(two)}, {}, true};
		scenarios["nonuniform"] = {{{{one, two, one, one}}}, {}, true};
		scenarios["drawid"] = {{uniform(two), uniform(three)}, {}, false, false, "drawid.vert.spv"};
		scenarios["resources"] = {{uniform(two), {{0, three, three, three}}, uniform(three)}, {}, false, false, "resources.vert.spv", true};
		scenarios["inner-nan"] = {{{{two, two, two, nan}}}, {}, true};
		for (uint32_t level : {1u, 2u, 3u}) {
			Scenario seam{{uniform(bits(float(level))), uniform(bits(float(level)))}};
			seam.seam = true;
			scenarios["seam" + std::to_string(level)] = seam;
		}
		// Vulkan runs the VS for every vertex of a draw, including vertices that do not complete a patch.
		for (uint32_t vertexCount : {1u, 2u, 4u, 5u}) {
			Scenario partial{vertexCount < 3 ? std::vector<Patch>{} : std::vector<Patch>{uniform(two)}, {}, false, false, "resources.vert.spv", true};
			partial.vertexCount = vertexCount;
			scenarios["vertices" + std::to_string(vertexCount)] = partial;
		}
		const bool rejection = scenarioName.rfind("reject-", 0) == 0 || scenarioName == "public-device-gate";
		// Ordinary-only scenarios select the draw command: direct, indexed, indirect or indexed-indirect.
		const std::string ordinaryPrefix = "ordinary-levels-";
		const bool ordinaryOnly = scenarioName.rfind(ordinaryPrefix, 0) == 0;
		// Scratch-limit draws, direct or indexed, recorded in the primary or in a secondary command buffer.
		const bool secondaryScratchLimit = scenarioName == "ordinary-levels-secondary-scratch-limit" || scenarioName == "ordinary-levels-indexed-secondary-scratch-limit";
		const bool indexedScratchLimit = scenarioName == "ordinary-levels-indexed-scratch-limit" || scenarioName == "ordinary-levels-indexed-secondary-scratch-limit";
		const bool scratchLimit = scenarioName == "ordinary-levels-scratch-limit" || indexedScratchLimit || secondaryScratchLimit;
		std::string drawMode = scratchLimit ? (indexedScratchLimit ? "indexed" : "direct") : ordinaryOnly ? scenarioName.substr(ordinaryPrefix.size()) : "direct";
		if (scenarioName == "reject-indirect-tes") drawMode = "indirect";
		if (scenarioName == "reject-indexed-indirect-tes") drawMode = "indexed-indirect";
		if (drawMode != "direct" && drawMode != "indexed" && drawMode != "indirect" && drawMode != "indexed-indirect") throw std::runtime_error("Unknown draw command");
		if (ordinaryOnly) scenarios[scenarioName] = {{uniform(two)}, {}};
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
		if (!ordinaryOnly) {
			if (!mvkEnableTESFixtureDevice) throw std::runtime_error("Test device adapter was not linked");
			mvkEnableTESFixtureDevice(physical);
		}
		check(vkEnumerateDeviceExtensionProperties(physical, nullptr, &count, nullptr), "Enumerate device extensions");
		std::vector<VkExtensionProperties> extensions(count);
		check(vkEnumerateDeviceExtensionProperties(physical, nullptr, &count, extensions.data()), "Read device extensions");
		VkPhysicalDeviceFragmentShaderBarycentricFeaturesKHR barycentric{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FRAGMENT_SHADER_BARYCENTRIC_FEATURES_KHR};
		VkPhysicalDeviceFeatures2 features{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2};
		features.pNext = &barycentric;
		vkGetPhysicalDeviceFeatures2(physical, &features);
		if ((!ordinaryOnly && !barycentric.fragmentShaderBarycentric) || !features.features.tessellationShader) throw std::runtime_error("Barycentric or tessellation feature unavailable");
		uint32_t family = 0;
		vkGetPhysicalDeviceQueueFamilyProperties(physical, &count, nullptr);
		std::vector<VkQueueFamilyProperties> families(count);
		vkGetPhysicalDeviceQueueFamilyProperties(physical, &count, families.data());
		while (!(families.at(family).queueFlags & VK_QUEUE_GRAPHICS_BIT)) ++family;
		VkPhysicalDeviceShaderDrawParametersFeatures drawParameters{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SHADER_DRAW_PARAMETERS_FEATURES};
		barycentric.pNext = &drawParameters;
		if (ordinaryOnly) features.pNext = &drawParameters;
		vkGetPhysicalDeviceFeatures2(physical, &features);
		if (!drawParameters.shaderDrawParameters || !features.features.vertexPipelineStoresAndAtomics || !features.features.fragmentStoresAndAtomics || !features.features.multiDrawIndirect) throw std::runtime_error("Draw parameters, multi-draw indirect, vertex or fragment stores unavailable");
		features.features = {};
		features.features.tessellationShader = VK_TRUE;
		features.features.vertexPipelineStoresAndAtomics = VK_TRUE;
		features.features.fragmentStoresAndAtomics = VK_TRUE;
		features.features.multiDrawIndirect = VK_TRUE;
		float priority = 1;
		VkDeviceQueueCreateInfo queueInfo{VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};
		queueInfo.queueFamilyIndex = family;
		queueInfo.queueCount = 1;
		queueInfo.pQueuePriorities = &priority;
		std::vector<const char*> deviceExtensions{VK_KHR_MAINTENANCE_2_EXTENSION_NAME};
		if (!ordinaryOnly) deviceExtensions.push_back(VK_KHR_FRAGMENT_SHADER_BARYCENTRIC_EXTENSION_NAME);
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
		Buffer counter = makeBuffer(256, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);
		Buffer scale = makeBuffer(256, VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT);
		// Tessellation coordinates: every ordinary TES invocation appends six words; the PerVertex fragment
		// stores three vertices of six words per pixel.
		constexpr uint32_t kTesCaptureSlots = 1 << 16;
		Buffer tesCapture = makeBuffer(4 + 4 * kCaptureWords * kTesCaptureSlots, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);
		// Identity indices and one indirect command for the indexed and indirect draw commands.
		Buffer indices = makeBuffer(9 * sizeof(uint32_t), VK_BUFFER_USAGE_INDEX_BUFFER_BIT);
		for (uint32_t i = 0; i < 9; ++i) reinterpret_cast<uint32_t*>(indices.data)[i] = i;
		Buffer indirect = makeBuffer(2 * sizeof(VkDrawIndexedIndirectCommand), VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT);
		bool splitDraw = false;  // Ordinary-only: first patch, then the others, in the same render pass.
		Buffer fragmentCapture = makeBuffer(kWidth * kHeight * 18 * 4, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);
		const float scaleValue[4] = {1.0f, 0.5f, 1.0f, 1.0f};
		memcpy(scale.data, scaleValue, sizeof(scaleValue));

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
		// VS storage counter and fragment uniform scale, bound through the default Metal argument buffers.
		VkDescriptorSetLayoutBinding resourceBindings[2] = {{0, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_VERTEX_BIT, nullptr}, {1, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 1, VK_SHADER_STAGE_FRAGMENT_BIT, nullptr}};
		setLayoutInfo.bindingCount = 2;
		setLayoutInfo.pBindings = resourceBindings;
		VkDescriptorSetLayout resourceSetLayout = VK_NULL_HANDLE;
		check(vkCreateDescriptorSetLayout(device, &setLayoutInfo, nullptr, &resourceSetLayout), "Create resource set layout");
		// Coordinate captures: an ordinary TES storage buffer and a PerVertex fragment storage buffer.
		VkDescriptorSetLayoutBinding tesCaptureBinding{0, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_TESSELLATION_EVALUATION_BIT, nullptr};
		VkDescriptorSetLayoutBinding fragmentCaptureBinding{0, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_FRAGMENT_BIT, nullptr};
		setLayoutInfo.bindingCount = 1;
		setLayoutInfo.pBindings = &tesCaptureBinding;
		VkDescriptorSetLayout tesCaptureSetLayout = VK_NULL_HANDLE, fragmentCaptureSetLayout = VK_NULL_HANDLE;
		check(vkCreateDescriptorSetLayout(device, &setLayoutInfo, nullptr, &tesCaptureSetLayout), "Create TES capture set layout");
		setLayoutInfo.pBindings = &fragmentCaptureBinding;
		check(vkCreateDescriptorSetLayout(device, &setLayoutInfo, nullptr, &fragmentCaptureSetLayout), "Create fragment capture set layout");
		VkDescriptorPoolSize poolSizes[2] = {{VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 3}, {VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 1}};
		VkDescriptorPoolCreateInfo descriptorPoolInfo{VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO};
		descriptorPoolInfo.maxSets = 3;
		descriptorPoolInfo.poolSizeCount = 2;
		descriptorPoolInfo.pPoolSizes = poolSizes;
		VkDescriptorPool descriptorPool = VK_NULL_HANDLE;
		check(vkCreateDescriptorPool(device, &descriptorPoolInfo, nullptr, &descriptorPool), "Create descriptor pool");
		VkDescriptorSetAllocateInfo setAllocation{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO};
		setAllocation.descriptorPool = descriptorPool;
		setAllocation.descriptorSetCount = 1;
		setAllocation.pSetLayouts = &resourceSetLayout;
		VkDescriptorSet resourceSet = VK_NULL_HANDLE;
		check(vkAllocateDescriptorSets(device, &setAllocation, &resourceSet), "Allocate descriptor set");
		VkDescriptorBufferInfo bufferInfos[2] = {{counter.buffer, 0, VK_WHOLE_SIZE}, {scale.buffer, 0, VK_WHOLE_SIZE}};
		VkWriteDescriptorSet writes[2]{};
		for (uint32_t i = 0; i < 2; ++i) {
			writes[i].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
			writes[i].dstSet = resourceSet;
			writes[i].dstBinding = i;
			writes[i].descriptorCount = 1;
			writes[i].descriptorType = i ? VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER : VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
			writes[i].pBufferInfo = &bufferInfos[i];
		}
		vkUpdateDescriptorSets(device, 2, writes, 0, nullptr);
		VkDescriptorSet tesCaptureSet = VK_NULL_HANDLE, fragmentCaptureSet = VK_NULL_HANDLE;
		setAllocation.pSetLayouts = &tesCaptureSetLayout;
		check(vkAllocateDescriptorSets(device, &setAllocation, &tesCaptureSet), "Allocate TES capture set");
		setAllocation.pSetLayouts = &fragmentCaptureSetLayout;
		check(vkAllocateDescriptorSets(device, &setAllocation, &fragmentCaptureSet), "Allocate fragment capture set");
		VkDescriptorBufferInfo captureInfos[2] = {{tesCapture.buffer, 0, VK_WHOLE_SIZE}, {fragmentCapture.buffer, 0, VK_WHOLE_SIZE}};
		const VkDescriptorSet captureSets[2] = {tesCaptureSet, fragmentCaptureSet};
		for (uint32_t i = 0; i < 2; ++i) {
			writes[i].dstSet = captureSets[i];
			writes[i].dstBinding = 0;
			writes[i].descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
			writes[i].pBufferInfo = &captureInfos[i];
		}
		vkUpdateDescriptorSets(device, 2, writes, 0, nullptr);
		VkPipelineLayoutCreateInfo layoutInfo{VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};
		VkPipelineLayout emptyLayout = VK_NULL_HANDLE, uniformLayout = VK_NULL_HANDLE, resourceLayout = VK_NULL_HANDLE, pushLayout = VK_NULL_HANDLE, tesCaptureLayout = VK_NULL_HANDLE, fragmentCaptureLayout = VK_NULL_HANDLE;
		check(vkCreatePipelineLayout(device, &layoutInfo, nullptr, &emptyLayout), "Create pipeline layout");
		layoutInfo.setLayoutCount = 1;
		layoutInfo.pSetLayouts = &setLayout;
		check(vkCreatePipelineLayout(device, &layoutInfo, nullptr, &uniformLayout), "Create uniform pipeline layout");
		layoutInfo.pSetLayouts = &resourceSetLayout;
		check(vkCreatePipelineLayout(device, &layoutInfo, nullptr, &resourceLayout), "Create resource pipeline layout");
		layoutInfo.pSetLayouts = &tesCaptureSetLayout;
		check(vkCreatePipelineLayout(device, &layoutInfo, nullptr, &tesCaptureLayout), "Create TES capture pipeline layout");
		layoutInfo.pSetLayouts = &fragmentCaptureSetLayout;
		check(vkCreatePipelineLayout(device, &layoutInfo, nullptr, &fragmentCaptureLayout), "Create fragment capture pipeline layout");
		VkPushConstantRange pushRange{VK_SHADER_STAGE_TESSELLATION_CONTROL_BIT, 0, 4};
		layoutInfo.setLayoutCount = 0;
		layoutInfo.pushConstantRangeCount = 1;
		layoutInfo.pPushConstantRanges = &pushRange;
		check(vkCreatePipelineLayout(device, &layoutInfo, nullptr, &pushLayout), "Create push-constant pipeline layout");

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
		struct PipelineOptions { std::string tesc = "topology.tesc.spv", tese, frag; bool cull = false, lowerLeft = false, cache = false, uniform = false, resources = false, push = false; std::string vert = "topology.vert.spv"; int capture = 0; };
		auto pipelineLayout = [&](const PipelineOptions& o) { return o.capture == 1 ? tesCaptureLayout : o.capture == 2 ? fragmentCaptureLayout : o.uniform ? uniformLayout : o.resources ? resourceLayout : o.push ? pushLayout : emptyLayout; };
		auto descriptorSet = [&](const PipelineOptions& o) { return o.capture == 1 ? tesCaptureSet : o.capture == 2 ? fragmentCaptureSet : o.resources ? resourceSet : VK_NULL_HANDLE; };
		auto createPipeline = [&](const PipelineOptions& o, VkPipeline& pipeline) {
			VkPipelineShaderStageCreateInfo stages[4]{};
			const VkShaderStageFlagBits stageBits[4] = {VK_SHADER_STAGE_VERTEX_BIT, VK_SHADER_STAGE_TESSELLATION_CONTROL_BIT, VK_SHADER_STAGE_TESSELLATION_EVALUATION_BIT, VK_SHADER_STAGE_FRAGMENT_BIT};
			const std::string names[4] = {o.vert, o.tesc, o.tese, o.frag};
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
			info.layout = pipelineLayout(o);
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

		// Records: host zeros the vertex buffer; the GPU copies pixel positions and levels, then draws. With a secondary
		// command buffer, the render pass contents are recorded there and executed by the primary.
		auto record = [&](VkPipeline pipeline, const std::vector<Patch>& patches, uint32_t firstVertex, uint32_t instances, const PipelineOptions& o, VkCommandBuffer secondary = VK_NULL_HANDLE) {
			memset(staging.data, 0, staging.size);
			for (uint32_t p = 0; p < patches.size(); ++p) {
				auto points = controlPoints(p, patches[p].mirrored, scenario.seam);
				for (uint32_t c = 0; c < 3; ++c) {
					float position[2] = {float(points[c][0]), float(points[c][1])};
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
			vkCmdBeginRenderPass(command, &pass, secondary ? VK_SUBPASS_CONTENTS_SECONDARY_COMMAND_BUFFERS : VK_SUBPASS_CONTENTS_INLINE);
			VkCommandBuffer target = secondary ? secondary : command;
			if (secondary) {
				VkCommandBufferInheritanceInfo inheritance{VK_STRUCTURE_TYPE_COMMAND_BUFFER_INHERITANCE_INFO};
				inheritance.renderPass = renderPass;
				inheritance.framebuffer = framebuffer;
				VkCommandBufferBeginInfo continueInfo{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
				continueInfo.flags = VK_COMMAND_BUFFER_USAGE_RENDER_PASS_CONTINUE_BIT;
				continueInfo.pInheritanceInfo = &inheritance;
				check(vkBeginCommandBuffer(secondary, &continueInfo), "Begin secondary command buffer");
			}
			// An earlier write in the same render pass must survive the compute stages.
			VkClearAttachment prior{VK_IMAGE_ASPECT_COLOR_BIT, 0, {}};
			prior.clearValue.color.float32[0] = 1.0f;
			prior.clearValue.color.float32[2] = 1.0f;
			prior.clearValue.color.float32[3] = 1.0f;
			VkClearRect priorRect{{{0, 0}, {2, 2}}, 0, 1};
			vkCmdClearAttachments(target, 1, &prior, 1, &priorRect);
			vkCmdBindPipeline(target, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
			VkDescriptorSet set = descriptorSet(o);
			if (set) vkCmdBindDescriptorSets(target, VK_PIPELINE_BIND_POINT_GRAPHICS, pipelineLayout(o), 0, 1, &set, 0, nullptr);
			VkDeviceSize offset = 0;
			vkCmdBindVertexBuffers(target, 0, 1, &vertices.buffer, &offset);
			const uint32_t drawCount = scenario.vertexCount ? scenario.vertexCount : uint32_t(3 * patches.size());
			const uint32_t parts = splitDraw ? 2 : 1, counts[2] = {splitDraw ? 3 : drawCount, drawCount - 3}, starts[2] = {0, 3};
			if (drawMode == "direct") for (uint32_t part = 0; part < parts; ++part) vkCmdDraw(target, counts[part], instances, firstVertex + starts[part], 0);
			else {
				if (drawMode != "indirect") vkCmdBindIndexBuffer(target, indices.buffer, 0, VK_INDEX_TYPE_UINT32);
				if (drawMode == "indexed") for (uint32_t part = 0; part < parts; ++part) vkCmdDrawIndexed(target, counts[part], instances, starts[part], int32_t(firstVertex), 0);
				else if (drawMode == "indirect") {
					const VkDrawIndirectCommand arguments[2] = {{counts[0], instances, firstVertex, 0}, {counts[1], instances, firstVertex + 3, 0}};
					memcpy(indirect.data, arguments, sizeof(arguments));
					vkCmdDrawIndirect(target, indirect.buffer, 0, parts, sizeof(VkDrawIndirectCommand));
				} else {
					const VkDrawIndexedIndirectCommand arguments[2] = {{counts[0], instances, 0, int32_t(firstVertex), 0}, {counts[1], instances, 3, int32_t(firstVertex), 0}};
					memcpy(indirect.data, arguments, sizeof(arguments));
					vkCmdDrawIndexedIndirect(target, indirect.buffer, 0, parts, sizeof(VkDrawIndexedIndirectCommand));
				}
			}
			if (secondary) {
				// An application stops at a secondary that failed to record.
				VkResult ended = vkEndCommandBuffer(secondary);
				std::printf("secondary vkEndCommandBuffer=%d\n", ended);
				if (ended != VK_SUCCESS) return ended;
				vkCmdExecuteCommands(command, 1, &secondary);
			}
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
			toHost.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT | VK_ACCESS_SHADER_WRITE_BIT;
			toHost.dstAccessMask = VK_ACCESS_HOST_READ_BIT;
			vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_TRANSFER_BIT | VK_PIPELINE_STAGE_VERTEX_SHADER_BIT | VK_PIPELINE_STAGE_TESSELLATION_EVALUATION_SHADER_BIT | VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &toHost, 0, nullptr, 0, nullptr);
			return vkEndCommandBuffer(command);
		};
		auto render = [&](const PipelineOptions& o, const std::vector<Patch>& patches, const std::string& name) {
			VkPipeline pipeline = VK_NULL_HANDLE;
			check(createPipeline(o, pipeline), ("Create pipeline " + name).c_str());
			check(record(pipeline, patches, 0, 1, o), ("Record " + name).c_str());
			memset(vertices.data, 0, vertices.size);
			memset(counter.data, 0, counter.size);
			memset(tesCapture.data, 0, tesCapture.size);
			memset(fragmentCapture.data, 0, fragmentCapture.size);
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
			memcpy(&result.invocations, counter.data, 4);
			result.tesCapture.resize(tesCapture.size / 4);
			memcpy(result.tesCapture.data(), tesCapture.data, tesCapture.size);
			result.fragmentCapture.resize(fragmentCapture.size / 4);
			memcpy(result.fragmentCapture.data(), fragmentCapture.data, fragmentCapture.size);
			std::printf("render %s submit=%d wait=%d vs_counter=%u\n", name.c_str(), result.submit, result.wait, result.invocations);
			return result;
		};

		const std::string tese = ccw ? "ccw.tese.spv" : "cw.tese.spv";
		const std::string captureTese = ccw ? "capture-ccw.tese.spv" : "capture-cw.tese.spv";
		if (scratchLimit) {
			// One patch per instance. Exceed the advertised Metal-backed allocation limit: the draw must be refused before
			// the application can submit it, or at vkQueueSubmit without side effects. When recording succeeds, submit as an
			// application would and report what became of the draw. Every MoltenVK revision tested checks the same limit
			// when encoding and omits the draw there, so these patches never reach the GPU.
			VkPhysicalDeviceVulkan11Properties props11{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_PROPERTIES};
			VkPhysicalDeviceProperties2 props2{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2};
			props2.pNext = &props11;
			vkGetPhysicalDeviceProperties2(physical, &props2);
			constexpr uint64_t levelBytesPerPatch = 6 * sizeof(float);
			uint64_t instances = props11.maxMemoryAllocationSize / levelBytesPerPatch + 1;
			if (instances > UINT32_MAX) { std::printf("TES_TOPOLOGY SKIP %s: buffer limit exceeds addressable patch count\n", scenarioName.c_str()); return 0; }
			PipelineOptions o{"topology.tesc.spv", tese, "ordinary.frag.spv"};
			VkPipeline pipeline = VK_NULL_HANDLE;
			check(createPipeline(o, pipeline), "Create ordinary float32 pipeline");
			VkCommandBuffer secondary = VK_NULL_HANDLE;
			if (secondaryScratchLimit) {
				commandInfo.level = VK_COMMAND_BUFFER_LEVEL_SECONDARY;
				check(vkAllocateCommandBuffers(device, &commandInfo, &secondary), "Allocate secondary command buffer");
			}
			VkResult actual = record(pipeline, {uniform(two)}, 0, uint32_t(instances), o, secondary);
			if (actual != VK_SUCCESS) {
				bool pass = actual == VK_ERROR_OUT_OF_DEVICE_MEMORY;
				std::printf("TES_TOPOLOGY %s %s: vkEndCommandBuffer=%d expected=%d, patches=%llu limit=%llu, nothing submitted\n", pass ? "PASS" : "FAIL", scenarioName.c_str(), actual, VK_ERROR_OUT_OF_DEVICE_MEMORY, (unsigned long long)instances, (unsigned long long)props11.maxMemoryAllocationSize);
				return pass ? 0 : 2;
			}
			memset(readback.data, 0, readback.size);
			check(vkResetFences(device, 1, &fence), "Reset fence");
			VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO};
			submit.commandBufferCount = 1;
			submit.pCommandBuffers = &command;
			VkResult submitted = vkQueueSubmit(queue, 1, &submit, fence);
			// Bounded wait: a refused submission leaves the fence unsignalled.
			VkResult waited = vkWaitForFences(device, 1, &fence, VK_TRUE, 2000000000ull);
			vkDeviceWaitIdle(device);
			// The batch clears the image, writes the 2x2 prior block, then draws: count the pixels the draw wrote.
			uint32_t rendered = 0;
			bool prior = true;
			for (uint32_t y = 0; y < kHeight; ++y) for (uint32_t x = 0; x < kWidth; ++x) {
				const uint8_t* p = readback.data + 4 * (y * kWidth + x);
				if (x < 2 && y < 2) prior &= p[0] == 255 && p[1] == 0 && p[2] == 255 && p[3] == 255;
				else rendered += p[0] || p[1] || p[2] || p[3];
			}
			bool executed = waited == VK_SUCCESS;
			bool pass = submitted != VK_SUCCESS && !executed;
			const char* outcome = submitted == VK_SUCCESS ? (rendered ? "the draw ran" : "the draw was omitted and the submission accepted")
			                    : executed ? "vkQueueSubmit failed after the batch executed and signalled its fence" : "vkQueueSubmit refused the batch without side effects";
			std::printf("TES_TOPOLOGY %s %s: vkEndCommandBuffer=0 vkQueueSubmit=%d fence=%s prior_block=%s rendered_pixels=%u, %s, patches=%llu limit=%llu\n", pass ? "PASS" : "FAIL", scenarioName.c_str(),
			            submitted, executed ? "signalled" : "unsignalled", prior ? "present" : "absent", rendered, outcome, (unsigned long long)instances, (unsigned long long)props11.maxMemoryAllocationSize);
			return pass ? 0 : 2;
		}
		if (ordinaryOnly) {
			// Vulkan discards a patch when a relevant outer level is <= 0 or NaN; equal spacing otherwise clamps every
			// level to [1, maxTessellationGenerationLevel] and rounds it up. Each case pairs float32 TCS levels with
			// their Vulkan representative: both must render and tessellate identically, and the TES must read the
			// levels exactly as the TCS wrote them.
			const uint32_t next1 = 0x3f800001u, next2 = 0x40000001u, tiny = 0x0da24260u /* 1e-30 */, inf = 0x7f800000u, negativeZero = 0x80000000u;
			const uint32_t max = bits(float(properties.limits.maxTessellationGenerationLevel));
			struct Case { const char* name; std::vector<Patch> levels, representative; };
			const std::vector<Case> cases = {
				{"uniform nextafter(1), nextafter(2), 1e-30", {uniform(next1), uniform(next2), uniform(tiny)}, {uniform(two), uniform(three), uniform(one)}},
				{"inner nextafter(1), one outer nextafter(1), inner 1e-30", {{{one, one, one, next1}}, {{next1, one, one, one}}, {{two, two, two, tiny}}}, {{{one, one, one, two}}, {{two, one, one, one}}, {{two, two, two, one}}}},
				{"controls: +inf, -0 and NaN outer", {uniform(inf), {{negativeZero, two, two, two}}, {{two, nan, two, two}}}, {uniform(max), {{0, two, two, two}}, {{0, two, two, two}}}},
			};
			bool pass = true;
			auto verdict = [&](bool ok, const char* what) { std::printf("  %s %s\n", ok ? "ok  " : "FAIL", what); pass &= ok; };
			// TES records keyed by their position too: gl_PrimitiveID restarts with each draw of a split draw.
			using Records = std::set<std::array<uint32_t, 6>>;
			auto records = [&](const Image& image, bool primitive) {
				Records result;
				for (uint32_t slot = 0; slot < std::min(image.tesCapture[0], kTesCaptureSlots); ++slot) {
					const uint32_t* w = &image.tesCapture[1 + kCaptureWords * slot];
					result.insert({primitive ? w[0] : 0u, w[1], w[2], w[3], w[4], w[5]});
				}
				return result;
			};
			auto alpha = [](const Image& image) { std::vector<uint8_t> result; for (size_t i = 3; i < image.rgba.size(); i += 4) result.push_back(image.rgba[i]); return result; };
			std::printf("draw command: %s\n", drawMode.c_str());
			for (size_t c = 0; c < cases.size(); ++c) {
				const Case& test = cases[c];
				Image single, singleCaptured;
				for (bool split : {false, true}) {
					splitDraw = split;
					const std::string name = "case" + std::to_string(c) + (split ? "-split" : "");
					PipelineOptions o{"topology.tesc.spv", tese, "ordinary.frag.spv"};
					Image image = render(o, test.levels, name + "-levels"), reference = render(o, test.representative, name + "-representative");
					o.tese = captureTese;
					o.capture = 1;
					Image captured = render(o, test.levels, name + "-levels-capture"), referenceCaptured = render(o, test.representative, name + "-representative-capture");
					bool submitted = true;
					for (const Image* i : {&image, &reference, &captured, &referenceCaptured}) submitted &= i->submit == VK_SUCCESS && i->wait == VK_SUCCESS;
					uint32_t pixels = 0;
					for (uint32_t i = 0; i < kWidth * kHeight; ++i) pixels += image.rgba[4 * i + 3] != 0;
					// The TES must see the TCS values, not their half conversion nor their Vulkan rounding. The patch is
					// the cell of the vertex, since gl_PrimitiveID restarts with each draw.
					uint32_t levelMismatch = 0, invocations = std::min(captured.tesCapture[0], kTesCaptureSlots);
					for (uint32_t slot = 0; slot < invocations; ++slot) {
						const uint32_t* w = &captured.tesCapture[1 + kCaptureWords * slot];
						uint32_t patch = uint32_t(asFloat(w[4])) / kCell;
						for (int k = 0; k < 4; ++k) levelMismatch += patch >= test.levels.size() || w[6 + k] != test.levels[patch].levels[k];
					}
					Records mine = records(captured, true), theirs = records(referenceCaptured, true);
					std::printf("  case %zu%s (%s): covered=%u image_equal=%d vertices=%zu representative_vertices=%zu coordinates_equal=%d tes_invocations=%u tes_level_mismatch=%u\n",
					            c, split ? " split" : "", test.name, pixels, image.rgba == reference.rgba, mine.size(), theirs.size(), mine == theirs, invocations, levelMismatch);
					verdict(submitted && captured.tesCapture[0] <= kTesCaptureSlots, "submissions succeed and the TES capture fits");
					verdict(pixels > 0 && image.rgba == reference.rgba, "image identical to the Vulkan level representative");
					verdict(!mine.empty() && mine == theirs, "tessellation coordinates and positions identical to the representative's");
					verdict(invocations > 0 && levelMismatch == 0, "TES reads every level exactly as the TCS wrote it");
					if (!split) { single = image; singleCaptured = captured; continue; }
					bool complete = alpha(image) == alpha(single) && records(captured, false) == records(singleCaptured, false);
					std::printf("  case %zu split vs one draw: coverage_equal=%d vertices_equal=%d\n", c, alpha(image) == alpha(single), records(captured, false) == records(singleCaptured, false));
					verdict(complete, "two draws in one render pass cover and tessellate exactly like one draw");
				}
			}
			splitDraw = false;
			// Information only: Vulkan treats an inner level of 1 as 1 + epsilon when an outer level exceeds 1.
			PipelineOptions o{"topology.tesc.spv", tese, "ordinary.frag.spv"};
			Image innerOne = render(o, {{{two, two, two, one}}}, "inner-one"), innerTwo = render(o, {{{two, two, two, two}}}, "inner-two");
			std::printf("  info: outer 2 with inner 1 renders like inner 2 (Vulkan 1 + epsilon rule): %s\n", innerOne.rgba == innerTwo.rgba ? "yes" : "no");
			std::printf("TES_TOPOLOGY %s %s %s\n", pass ? "PASS" : "FAIL", scenarioName.c_str(), winding.c_str());
			vkDeviceWaitIdle(device);
			return pass ? 0 : 2;
		}
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
			else if (scenarioName == "reject-push-constant") { o.tesc = "push.tesc.spv"; o.push = true; }
			else if (scenarioName == "reject-no-admission") {}
			else if (scenarioName == "reject-indirect-tes" || scenarioName == "reject-indexed-indirect-tes") {
				check(createPipeline(o, pipeline), "Create admitted pipeline");
				actual = record(pipeline, {uniform(two)}, 0, 1, o);
				std::printf("TES_TOPOLOGY %s %s: vkEndCommandBuffer=%d expected=%d, nothing submitted\n", actual == expected ? "PASS" : "FAIL", scenarioName.c_str(), actual, expected);
				return actual == expected ? 0 : 2;
			}
			else if (scenarioName == "reject-first-vertex" || scenarioName == "reject-instances") {
				check(createPipeline(o, pipeline), "Create admitted pipeline");
				actual = record(pipeline, {uniform(two)}, scenarioName == "reject-first-vertex" ? 3 : 0, scenarioName == "reject-instances" ? 2 : 1, o);
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

		auto options = [&](const std::string& frag) {
			PipelineOptions o{"topology.tesc.spv", tese, frag, scenario.cull};
			o.vert = scenario.vertex;
			o.resources = scenario.resources;
			return o;
		};
		const std::string suffix = scenario.resources ? "-resources.frag.spv" : ".frag.spv";
		if (scenario.patches.empty()) {
			// One or two vertices form no patch: nothing is tessellated, yet Vulkan runs the VS for each vertex.
			Image ordinaryImage = render(options("ordinary" + suffix), {}, "ordinary");
			Image interp = render(options("interp" + suffix), {}, "interp");
			uint32_t ordinaryPixels = 0, pixels = 0;
			for (uint32_t i = 0; i < kWidth * kHeight; ++i) { ordinaryPixels += covered(ordinaryImage.rgba, i); pixels += covered(interp.rgba, i); }
			verdict(ordinaryImage.submit == VK_SUCCESS && ordinaryImage.wait == VK_SUCCESS && interp.submit == VK_SUCCESS && interp.wait == VK_SUCCESS, "all submissions and fences succeed");
			std::printf("  VS storage counter: expected=%u ordinary=%u pervertex=%u\n", scenario.vertexCount, ordinaryImage.invocations, interp.invocations);
			verdict(ordinaryImage.invocations == scenario.vertexCount && interp.invocations == scenario.vertexCount, "VS side effects run once per vertex in ordinary and PerVertex pipelines without a complete patch");
			std::printf("  covered pixels: ordinary=%u pervertex=%u\n", ordinaryPixels, pixels);
			verdict(pixels == 0 && prior(interp.rgba), "no PerVertex pixel, earlier attachment write preserved");
			std::printf("TES_TOPOLOGY %s %s %s\n", pass ? "PASS" : "FAIL", scenarioName.c_str(), winding.c_str());
			vkDeviceWaitIdle(device);
			return pass ? 0 : 2;
		}
		Image ordinaryImage = render(options("ordinary" + suffix), scenario.reference, "ordinary");
		Image interp = render(options("interp" + suffix), scenario.patches, "interp");
		Image ordered = render(options("flat-ordered.frag.spv"), scenario.patches, "ordered");
		Image swapped = render(options("flat-swapped.frag.spv"), scenario.patches, "swapped");
		Image consistency = render(options("consistency.frag.spv"), scenario.patches, "consistency");
		for (const Image* image : {&ordinaryImage, &interp, &ordered, &swapped, &consistency}) pass &= image->submit == VK_SUCCESS && image->wait == VK_SUCCESS;
		verdict(pass, "all submissions and fences succeed");
		if (scenario.resources) {
			// Vulkan runs the VS for every vertex, discarded patches included; MoltenVK runs it exactly once.
			uint32_t vertexCount = scenario.vertexCount ? scenario.vertexCount : uint32_t(3 * scenario.patches.size());
			bool exact = true;
			for (const Image* image : {&ordinaryImage, &interp, &ordered, &swapped, &consistency}) exact &= image->invocations == vertexCount;
			std::printf("  VS storage counter: expected=%u ordinary=%u pervertex=%u\n", vertexCount, ordinaryImage.invocations, interp.invocations);
			verdict(exact, "VS side effects run once per vertex in ordinary and PerVertex pipelines, discarded patch included");
		}

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
			auto control = controlPoints(p, scenario.patches[p].mirrored, scenario.seam);
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

		// 4. Tessellation coordinates: the PerVertex fragment stores its three TES vertices per pixel and an
		// ordinary TES appends the hardware coordinates. Fragment gl_PrimitiveID is checked on the same pixels.
		PipelineOptions extra = options("coords.frag.spv");
		extra.vert = scenario.resources ? "topology.vert.spv" : scenario.vertex;
		extra.resources = false;
		extra.capture = 2;
		Image fragmentCoordinates = render(extra, scenario.patches, "coords");
		extra.frag = "ordinary.frag.spv";
		extra.tese = captureTese;
		extra.capture = 1;
		Image hardwareCoordinates = render(extra, scenario.reference, "hardware-coords");
		extra.tese = tese;
		extra.capture = 0;
		extra.frag = "primitive-id.frag.spv";
		Image primitive = render(extra, scenario.patches, "primitive-id");
		extra.frag = "primitive-id-ordinary.frag.spv";
		Image ordinaryPrimitive = render(extra, scenario.reference, "ordinary-primitive-id");
		bool submitted = true;
		for (const Image* image : {&fragmentCoordinates, &hardwareCoordinates, &primitive, &ordinaryPrimitive}) submitted &= image->submit == VK_SUCCESS && image->wait == VK_SUCCESS;
		verdict(submitted, "coordinate and gl_PrimitiveID submissions succeed");
		Coordinates perVertex, hardware;
		for (uint32_t i = 0; i < kWidth * kHeight; ++i)
			for (uint32_t k = 0; k < 3; ++k) {
				const uint32_t* w = &fragmentCoordinates.fragmentCapture[18 * i + 6 * k];
				if (w[1] || w[2] || w[3]) perVertex[{uint32_t(asFloat(w[0])), w[1], w[2], w[3]}] = {w[4], w[5]};
			}
		const uint32_t tesInvocations = hardwareCoordinates.tesCapture[0];
		for (uint32_t slot = 0; slot < std::min(tesInvocations, kTesCaptureSlots); ++slot) {
			const uint32_t* w = &hardwareCoordinates.tesCapture[1 + kCaptureWords * slot];
			hardware[{w[0], w[1], w[2], w[3]}] = {w[4], w[5]};
		}
		// Rule 8: 1.0 - x is exact for every component. Rule 3: an edge vertex (x, 1-x) has its exact mirror (1-x, x).
		auto invariance = [](const Coordinates& set, uint32_t& inexact, uint32_t& asymmetric) {
			inexact = asymmetric = 0;
			for (const auto& entry : set) {
				const CoordinateKey& key = entry.first;
				for (int c = 1; c <= 3; ++c) {
					float x = asFloat(key[c]);
					inexact += !(x >= 0.0f && x <= 1.0f && double(1.0f - x) == 1.0 - double(x));
				}
				for (int zero = 1; zero <= 3; ++zero) {
					int a = zero == 1 ? 2 : 1, b = zero == 3 ? 2 : 3;
					if (key[zero] || !key[a] || !key[b]) continue;
					CoordinateKey mirror = key;
					std::swap(mirror[a], mirror[b]);
					asymmetric += bits(1.0f - asFloat(key[a])) != key[b] || !set.count(mirror);
				}
			}
		};
		uint32_t inexact = 0, asymmetric = 0, hardwareInexact = 0, hardwareAsymmetric = 0;
		invariance(perVertex, inexact, asymmetric);
		invariance(hardware, hardwareInexact, hardwareAsymmetric);
		// Every rendered patch has its full vertex set, identical to the hardware coordinates of that patch.
		uint32_t countMismatch = 0, coordinateMismatch = 0, positionMismatch = 0;
		for (uint32_t p = 0; p < scenario.patches.size(); ++p) {
			uint32_t level = vulkanLevel(scenario.patches[p]);
			// Back-face culling keeps the mirrored patch with ccw and the others with cw.
			bool culled = scenario.cull && scenario.patches[p].mirrored != ccw;
			uint32_t expected = culled ? 0 : level == 1 ? 3 : level == 2 ? 7 : level == 3 ? 12 : 0;
			Coordinates mine, theirs;
			for (const auto& entry : perVertex) if (entry.first[0] == p) mine.insert(entry);
			for (const auto& entry : hardware) if (entry.first[0] == p) theirs.insert(entry);
			countMismatch += mine.size() != expected;
			if (culled) continue;
			for (const auto& entry : theirs) {
				auto found = mine.find(entry.first);
				if (found == mine.end()) ++coordinateMismatch;
				else positionMismatch += found->second != entry.second;
			}
			coordinateMismatch += mine.size() > theirs.size() ? uint32_t(mine.size() - theirs.size()) : 0;
		}
		std::printf("  tessellation coordinates: pervertex_vertices=%zu inexact_complement=%u asymmetric_edge=%u count_mismatch=%u; hardware_vertices=%zu tes_invocations=%u inexact_complement=%u asymmetric_edge=%u; coordinate_mismatch=%u position_mismatch=%u\n",
		            perVertex.size(), inexact, asymmetric, countMismatch, hardware.size(), tesInvocations, hardwareInexact, hardwareAsymmetric, coordinateMismatch, positionMismatch);
		verdict(!perVertex.empty() && inexact == 0, "rule 8: 1.0 - x is exact for every PerVertex tessellation coordinate");
		verdict(asymmetric == 0, "rule 3: every PerVertex edge vertex (x, 1-x) has the exact mirror (1-x, x)");
		verdict(countMismatch == 0, "every rendered patch shows its full vertex set");
		verdict(tesInvocations <= kTesCaptureSlots && coordinateMismatch == 0 && positionMismatch == 0, "PerVertex coordinates and positions bitwise equal to the hardware tessellator's");
		if (scenario.seam) {
			// Rule 4: the u = 0 edge of the first patch and the w = 0 edge of the second give the same vertices.
			auto edge = [](const Coordinates& set, uint32_t patch, int zero) {
				std::set<std::array<uint32_t, 2>> pixels;
				for (const auto& entry : set) if (entry.first[0] == patch && !entry.first[zero]) pixels.insert(entry.second);
				return pixels;
			};
			auto first = edge(perVertex, 0, 1), second = edge(perVertex, 1, 3);
			auto hardwareFirst = edge(hardware, 0, 1), hardwareSecond = edge(hardware, 1, 3);
			std::printf("  seam: pervertex first=%zu second=%zu equal=%d; hardware first=%zu second=%zu equal=%d\n", first.size(), second.size(), first == second, hardwareFirst.size(), hardwareSecond.size(), hardwareFirst == hardwareSecond);
			verdict(first.size() == vulkanLevel(scenario.patches[0]) + 1 && first == second, "rule 4: both patches give bitwise-equal positions on the shared edge");
			verdict(hardwareFirst == hardwareSecond, "reference: the hardware tessellator is watertight on the same edge");
		}
		uint32_t primitivePixels = 0, primitiveWrong = 0, uncaptured = 0, ordinaryPrimitiveWrong = 0;
		for (uint32_t i = 0; i < kWidth * kHeight; ++i) {
			if (!covered(primitive.rgba, i)) continue;
			const uint32_t* w = &fragmentCoordinates.fragmentCapture[18 * i];
			if (!w[1] && !w[2] && !w[3]) { ++uncaptured; continue; }
			uint32_t patch = uint32_t(asFloat(w[0]));
			++primitivePixels;
			primitiveWrong += primitive.rgba[4 * i] != patch;
			ordinaryPrimitiveWrong += covered(ordinaryPrimitive.rgba, i) && ordinaryPrimitive.rgba[4 * i] != patch;
		}
		std::printf("  fragment gl_PrimitiveID: pixels=%u pervertex_wrong=%u uncaptured=%u ordinary_wrong=%u (ordinary informative)\n", primitivePixels, primitiveWrong, uncaptured, ordinaryPrimitiveWrong);
		verdict(primitivePixels > 0 && primitiveWrong == 0 && uncaptured == 0, "PerVertex fragment gl_PrimitiveID is the TES patch index on every covered pixel");
		if (scenarioName == "next") {
			// Same Vulkan level 2 as exact 2.0 for PerVertex; the ordinary half path renders level 1 instead.
			Image twoImage = render({"topology.tesc.spv", tese, "interp.frag.spv"}, {uniform(two), uniform(two)}, "interp-two");
			Image ordinaryTwo = render({"topology.tesc.spv", tese, "ordinary.frag.spv"}, {uniform(two), uniform(two)}, "ordinary-two");
			Image ordinaryOne = render({"topology.tesc.spv", tese, "ordinary.frag.spv"}, {uniform(one), uniform(one)}, "ordinary-one");
			verdict(twoImage.rgba == interp.rgba, "PerVertex nextafter(1,+inf) image identical to PerVertex level 2.0");
			verdict(ordinaryImage.rgba == ordinaryTwo.rgba && ordinaryImage.rgba != ordinaryOne.rgba, "ordinary nextafter(1,+inf) image identical to ordinary level 2.0, not level 1");
		}
		std::printf("TES_TOPOLOGY %s %s %s\n", pass ? "PASS" : "FAIL", scenarioName.c_str(), winding.c_str());
		vkDeviceWaitIdle(device);
		return pass ? 0 : 2;
	} catch (const std::exception& error) {
		std::fprintf(stderr, "ERROR: %s\n", error.what());
		return 1;
	}
}
