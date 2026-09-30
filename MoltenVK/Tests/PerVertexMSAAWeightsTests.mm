// Copyright 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
// Portable PerVertexKHR barycentric weights under 4x MSAA, after the CTS weights test
// (dEQP-VK.fragment_shading_barycentric.weights.*.pipeline_topology_dynamic.msaa_*, perspective): the same vertices and
// colours, the right-hand vertices scaled by 16 in w, sample shading, 128 x 128. Each case renders four images: the
// PerVertexKHR fragment through a static pipeline and through a dynamic topology pipeline created with a triangle list,
// and the reference fragment (the colour interpolated at the sample, without PerVertexKHR) through the same two
// pipelines. Static and dynamic images must be identical. The PerVertexKHR image is then compared with the reference at
// the CTS threshold of 1 per channel.
// Exit 0: identical and within the threshold; 4: identical but above the threshold (the open defect); 2: static and
// dynamic differ. The four images are written as raw RGBA to the output directory.
// ordinary-offset-list replaces the PerVertexKHR fragment by interpolateAtOffset on an ordinary input, as a control.
// samples-list and samples-strip check the ordinary reference itself, without PerVertexKHR: its fragment stores every
// sample's unquantized colour and gl_SamplePosition. Each sample must sit at the Vulkan standard 4x location, and its
// colour must match the perspective-correct interpolation computed in double on the CPU at that location, within one
// 8-bit step (1/255). The geometry covers the whole image, so every one of the 128 x 128 x 4 samples must be written
// and inside a triangle. Exit 0: all samples within; 4: some above; 2: a position or coverage error.
// Usage: pervertex-msaa-weights <shader directory> offset-list|offset-strip|sample-strip|ordinary-offset-list|samples-list|
//        samples-strip <output directory>
#import <Metal/Metal.h>
#include <vulkan/vulkan.h>

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <fstream>
#include <string>
#include <vector>

static void check(VkResult result, const char* step) {
	if (result != VK_SUCCESS) { std::fprintf(stderr, "%s: %d\n", step, int(result)); std::exit(1); }
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

constexpr uint32_t kSide = 128;
constexpr float kSlope = 16;  // WEIGHT_TEST_SLOPE

struct Buffer { VkBuffer buffer = VK_NULL_HANDLE; VkDeviceMemory memory = VK_NULL_HANDLE; uint8_t* data = nullptr; };
struct Vertex { float position[4], color[4]; };

int main(int argc, char** argv) {
	@autoreleasepool {
	if (argc != 4) { std::fprintf(stderr, "Usage: pervertex-msaa-weights shader-dir offset-list|offset-strip|sample-strip|ordinary-offset-list|samples-list|samples-strip output-dir\n"); return 2; }
	const std::string shaders = argv[1], name = argv[2], output = argv[3];
	const bool samplesCase = name == "samples-list" || name == "samples-strip";
	if (name != "offset-list" && name != "offset-strip" && name != "sample-strip" && name != "ordinary-offset-list" && !samplesCase) { std::fprintf(stderr, "Unknown case\n"); return 2; }
	const bool strip = name == "offset-strip" || name == "sample-strip" || name == "samples-strip";
	const VkPrimitiveTopology topology = strip ? VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP : VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;

	uint32_t count = 0;
	check(vkEnumerateInstanceExtensionProperties(nullptr, &count, nullptr), "Enumerate instance extensions");
	std::vector<VkExtensionProperties> instanceExtensions(count);
	check(vkEnumerateInstanceExtensionProperties(nullptr, &count, instanceExtensions.data()), "Read instance extensions");
	const bool portability = hasExtension(instanceExtensions, VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME);
	const char* portabilityName = VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME;
	VkApplicationInfo app{VK_STRUCTURE_TYPE_APPLICATION_INFO};
	app.pApplicationName = "PerVertexKHR MSAA weights";
	app.apiVersion = VK_API_VERSION_1_3;  // vkCmdSetPrimitiveTopology is core
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
	std::vector<const char*> deviceExtensions{VK_KHR_FRAGMENT_SHADER_BARYCENTRIC_EXTENSION_NAME};
	if (!hasExtension(extensions, deviceExtensions[0])) { std::fprintf(stderr, "Missing %s\n", deviceExtensions[0]); return 3; }
	if (hasExtension(extensions, "VK_KHR_portability_subset")) deviceExtensions.push_back("VK_KHR_portability_subset");
	VkPhysicalDeviceFragmentShaderBarycentricFeaturesKHR barycentric{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FRAGMENT_SHADER_BARYCENTRIC_FEATURES_KHR};
	VkPhysicalDeviceFeatures2 features{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2};
	features.pNext = &barycentric;
	vkGetPhysicalDeviceFeatures2(physical, &features);
	if (!barycentric.fragmentShaderBarycentric || !features.features.sampleRateShading || (samplesCase && !features.features.fragmentStoresAndAtomics)) { std::fprintf(stderr, "Required features are unavailable\n"); return 3; }
	VkPhysicalDeviceFeatures2 enabled{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2};
	enabled.pNext = &barycentric;
	enabled.features.sampleRateShading = VK_TRUE;
	enabled.features.fragmentStoresAndAtomics = samplesCase;
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
	std::printf("DEVICE=%s case=%s\n", properties.deviceName, name.c_str());

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
	auto makeImage = [&](VkSampleCountFlagBits samples, VkImageUsageFlags usage, VkImageView& view) {
		VkImageCreateInfo imageInfo{VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO};
		imageInfo.imageType = VK_IMAGE_TYPE_2D;
		imageInfo.format = VK_FORMAT_R8G8B8A8_UNORM;
		imageInfo.extent = {kSide, kSide, 1};
		imageInfo.mipLevels = 1;
		imageInfo.arrayLayers = 1;
		imageInfo.samples = samples;
		imageInfo.tiling = VK_IMAGE_TILING_OPTIMAL;
		imageInfo.usage = usage;
		VkImage image = VK_NULL_HANDLE;
		check(vkCreateImage(device, &imageInfo, nullptr, &image), "Create image");
		VkMemoryRequirements requirements{};
		vkGetImageMemoryRequirements(device, image, &requirements);
		VkMemoryAllocateInfo allocation{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
		allocation.allocationSize = requirements.size;
		allocation.memoryTypeIndex = memoryType(requirements.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
		VkDeviceMemory memory = VK_NULL_HANDLE;
		check(vkAllocateMemory(device, &allocation, nullptr, &memory), "Allocate image");
		check(vkBindImageMemory(device, image, memory, 0), "Bind image");
		VkImageViewCreateInfo viewInfo{VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO};
		viewInfo.image = image;
		viewInfo.viewType = VK_IMAGE_VIEW_TYPE_2D;
		viewInfo.format = imageInfo.format;
		viewInfo.subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
		check(vkCreateImageView(device, &viewInfo, nullptr, &view), "Create image view");
		return image;
	};

	// The CTS vertices: left top red, left bottom black, right bottom blue, right top green; right-hand w = 16.
	const Vertex leftTop{{-1, -1, 0, 1}, {1, 0, 0, 1}}, leftBottom{{-1, 1, 0, 1}, {0, 0, 0, 1}};
	const Vertex rightBottom{{kSlope, kSlope, 0, kSlope}, {0, 0, 1, 1}}, rightTop{{kSlope, -kSlope, 0, kSlope}, {0, 1, 0, 1}};
	const std::vector<Vertex> vertices = strip ? std::vector<Vertex>{leftBottom, leftTop, rightBottom, rightTop}
	                                           : std::vector<Vertex>{leftTop, leftBottom, rightBottom, rightBottom, rightTop, leftTop};
	Buffer vertexBuffer = makeBuffer(vertices.size() * sizeof(Vertex), VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
	memcpy(vertexBuffer.data, vertices.data(), vertices.size() * sizeof(Vertex));
	Buffer readback = makeBuffer(kSide * kSide * 4, VK_BUFFER_USAGE_TRANSFER_DST_BIT);
	VkImageView multisampleView = VK_NULL_HANDLE, resolveView = VK_NULL_HANDLE;
	makeImage(VK_SAMPLE_COUNT_4_BIT, VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT, multisampleView);
	VkImage resolveImage = makeImage(VK_SAMPLE_COUNT_1_BIT, VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT, resolveView);

	VkAttachmentDescription attachments[2]{};
	attachments[0].format = attachments[1].format = VK_FORMAT_R8G8B8A8_UNORM;
	attachments[0].samples = VK_SAMPLE_COUNT_4_BIT;
	attachments[0].loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR;
	attachments[0].storeOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
	attachments[0].finalLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
	attachments[1].samples = VK_SAMPLE_COUNT_1_BIT;
	attachments[1].loadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
	attachments[1].storeOp = VK_ATTACHMENT_STORE_OP_STORE;
	attachments[1].finalLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
	VkAttachmentReference colorReference{0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL}, resolveReference{1, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};
	VkSubpassDescription subpass{};
	subpass.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS;
	subpass.colorAttachmentCount = 1;
	subpass.pColorAttachments = &colorReference;
	subpass.pResolveAttachments = &resolveReference;
	VkSubpassDependency toTransfer{0, VK_SUBPASS_EXTERNAL, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT, VK_ACCESS_TRANSFER_READ_BIT, 0};
	VkRenderPassCreateInfo passInfo{VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO};
	passInfo.attachmentCount = 2;
	passInfo.pAttachments = attachments;
	passInfo.subpassCount = 1;
	passInfo.pSubpasses = &subpass;
	passInfo.dependencyCount = 1;
	passInfo.pDependencies = &toTransfer;
	VkRenderPass renderPass = VK_NULL_HANDLE;
	check(vkCreateRenderPass(device, &passInfo, nullptr, &renderPass), "Create render pass");
	VkImageView views[2] = {multisampleView, resolveView};
	VkFramebufferCreateInfo framebufferInfo{VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO};
	framebufferInfo.renderPass = renderPass;
	framebufferInfo.attachmentCount = 2;
	framebufferInfo.pAttachments = views;
	framebufferInfo.width = kSide;
	framebufferInfo.height = kSide;
	framebufferInfo.layers = 1;
	VkFramebuffer framebuffer = VK_NULL_HANDLE;
	check(vkCreateFramebuffer(device, &framebufferInfo, nullptr, &framebuffer), "Create framebuffer");
	VkPipelineLayoutCreateInfo layoutInfo{VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};
	VkPipelineLayout layout = VK_NULL_HANDLE;
	check(vkCreatePipelineLayout(device, &layoutInfo, nullptr, &layout), "Create pipeline layout");
	// The samples cases: two vec4 per sample (colour; gl_SamplePosition and gl_FragCoord.xy), in a set of their own.
	const VkDeviceSize samplesSize = VkDeviceSize(kSide) * kSide * 4 * 2 * 16;
	Buffer samples = makeBuffer(samplesCase ? samplesSize : 16, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);
	VkDescriptorSet set = VK_NULL_HANDLE;
	if (samplesCase) {
		VkDescriptorSetLayoutBinding binding{0, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_FRAGMENT_BIT, nullptr};
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
		check(vkAllocateDescriptorSets(device, &setInfo, &set), "Allocate descriptor set");
		VkDescriptorBufferInfo samplesInfo{samples.buffer, 0, VK_WHOLE_SIZE};
		VkWriteDescriptorSet write{VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET};
		write.dstSet = set;
		write.descriptorCount = 1;
		write.descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
		write.pBufferInfo = &samplesInfo;
		vkUpdateDescriptorSets(device, 1, &write, 0, nullptr);
		layoutInfo.setLayoutCount = 1;
		layoutInfo.pSetLayouts = &setLayout;
		check(vkCreatePipelineLayout(device, &layoutInfo, nullptr, &layout), "Create samples pipeline layout");
	}

	auto module = [&](const std::string& file) {
		auto code = readSpirv(shaders + "/" + file);
		VkShaderModuleCreateInfo info{VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO};
		info.codeSize = code.size() * 4;
		info.pCode = code.data();
		VkShaderModule result = VK_NULL_HANDLE;
		check(vkCreateShaderModule(device, &info, nullptr, &result), "Create shader module");
		return result;
	};
	VkShaderModule vertex = module("msaa-weights.vert.spv");
	VkShaderModule test = samplesCase ? VK_NULL_HANDLE : module(name == "sample-strip" ? "msaa-sample.frag.spv" : name == "ordinary-offset-list" ? "msaa-ordinary-offset.frag.spv" : "msaa-offset.frag.spv");
	VkShaderModule reference = module(samplesCase ? "msaa-samples.frag.spv" : "msaa-reference.frag.spv");
	// A dynamic topology pipeline is created with a triangle list, as the CTS does (primitiveTopologyCastToList).
	auto graphicsPipeline = [&](VkShaderModule fragment, bool dynamicTopology) {
		VkPipelineShaderStageCreateInfo stages[2]{{VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO}, {VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO}};
		stages[0].stage = VK_SHADER_STAGE_VERTEX_BIT;
		stages[0].module = vertex;
		stages[0].pName = "main";
		stages[1].stage = VK_SHADER_STAGE_FRAGMENT_BIT;
		stages[1].module = fragment;
		stages[1].pName = "main";
		VkVertexInputBindingDescription binding{0, sizeof(Vertex), VK_VERTEX_INPUT_RATE_VERTEX};
		VkVertexInputAttributeDescription attributes[2]{{0, 0, VK_FORMAT_R32G32B32A32_SFLOAT, 0}, {1, 0, VK_FORMAT_R32G32B32A32_SFLOAT, offsetof(Vertex, color)}};
		VkPipelineVertexInputStateCreateInfo vertexInput{VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO};
		vertexInput.vertexBindingDescriptionCount = 1;
		vertexInput.pVertexBindingDescriptions = &binding;
		vertexInput.vertexAttributeDescriptionCount = 2;
		vertexInput.pVertexAttributeDescriptions = attributes;
		VkPipelineInputAssemblyStateCreateInfo assembly{VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO};
		assembly.topology = dynamicTopology ? VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST : topology;
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
		raster.frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE;
		raster.lineWidth = 1;
		VkPipelineMultisampleStateCreateInfo multisample{VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO};
		multisample.rasterizationSamples = VK_SAMPLE_COUNT_4_BIT;
		multisample.sampleShadingEnable = VK_TRUE;
		multisample.minSampleShading = 1;
		VkPipelineColorBlendAttachmentState blendAttachment{};
		blendAttachment.colorWriteMask = 0xF;
		VkPipelineColorBlendStateCreateInfo blend{VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO};
		blend.attachmentCount = 1;
		blend.pAttachments = &blendAttachment;
		const VkDynamicState dynamicState = VK_DYNAMIC_STATE_PRIMITIVE_TOPOLOGY;
		VkPipelineDynamicStateCreateInfo dynamic{VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO};
		dynamic.dynamicStateCount = 1;
		dynamic.pDynamicStates = &dynamicState;
		VkGraphicsPipelineCreateInfo info{VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO};
		info.stageCount = 2;
		info.pStages = stages;
		info.pVertexInputState = &vertexInput;
		info.pInputAssemblyState = &assembly;
		info.pViewportState = &viewportState;
		info.pRasterizationState = &raster;
		info.pMultisampleState = &multisample;
		info.pColorBlendState = &blend;
		info.pDynamicState = dynamicTopology ? &dynamic : nullptr;
		info.layout = layout;
		info.renderPass = renderPass;
		VkPipeline pipeline = VK_NULL_HANDLE;
		check(vkCreateGraphicsPipelines(device, VK_NULL_HANDLE, 1, &info, nullptr, &pipeline), "Create pipeline");
		return pipeline;
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
	VkCommandBuffer cb = VK_NULL_HANDLE;
	check(vkAllocateCommandBuffers(device, &commandInfo, &cb), "Allocate command buffer");
	VkFenceCreateInfo fenceInfo{VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
	VkFence fence = VK_NULL_HANDLE;
	check(vkCreateFence(device, &fenceInfo, nullptr, &fence), "Create fence");

	auto render = [&](VkShaderModule fragment, bool dynamicTopology, const char* file) {
		VkPipeline pipeline = graphicsPipeline(fragment, dynamicTopology);
		check(vkResetCommandBuffer(cb, 0), "Reset command buffer");
		VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
		check(vkBeginCommandBuffer(cb, &begin), "Begin command buffer");
		if (dynamicTopology) vkCmdSetPrimitiveTopology(cb, topology);
		VkClearValue clear{};
		VkRenderPassBeginInfo pass{VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO};
		pass.renderPass = renderPass;
		pass.framebuffer = framebuffer;
		pass.renderArea = {{0, 0}, {kSide, kSide}};
		pass.clearValueCount = 1;
		pass.pClearValues = &clear;
		vkCmdBeginRenderPass(cb, &pass, VK_SUBPASS_CONTENTS_INLINE);
		vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
		if (samplesCase) vkCmdBindDescriptorSets(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, layout, 0, 1, &set, 0, nullptr);
		VkDeviceSize offset = 0;
		vkCmdBindVertexBuffers(cb, 0, 1, &vertexBuffer.buffer, &offset);
		vkCmdDraw(cb, uint32_t(vertices.size()), 1, 0, 0);
		vkCmdEndRenderPass(cb);
		VkBufferImageCopy copy{};
		copy.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1};
		copy.imageExtent = {kSide, kSide, 1};
		vkCmdCopyImageToBuffer(cb, resolveImage, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, readback.buffer, 1, &copy);
		VkMemoryBarrier toHost{VK_STRUCTURE_TYPE_MEMORY_BARRIER};
		toHost.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT | VK_ACCESS_SHADER_WRITE_BIT;
		toHost.dstAccessMask = VK_ACCESS_HOST_READ_BIT;
		vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TRANSFER_BIT | VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &toHost, 0, nullptr, 0, nullptr);
		check(vkEndCommandBuffer(cb), "End command buffer");
		memset(readback.data, 0, kSide * kSide * 4);
		check(vkResetFences(device, 1, &fence), "Reset fence");
		VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO};
		submit.commandBufferCount = 1;
		submit.pCommandBuffers = &cb;
		check(vkQueueSubmit(queue, 1, &submit, fence), "Submit");
		check(vkWaitForFences(device, 1, &fence, VK_TRUE, 20ull * 1000 * 1000 * 1000), "Wait");
		std::vector<uint8_t> rgba(readback.data, readback.data + kSide * kSide * 4);
		std::ofstream(output + "/" + file, std::ios::binary).write(reinterpret_cast<const char*>(rgba.data()), std::streamsize(rgba.size()));
		vkDestroyPipeline(device, pipeline, nullptr);
		return rgba;
	};
	if (samplesCase) {
		memset(samples.data, 0, samplesSize);
		render(reference, false, "reference-static.rgba");
		std::ofstream(output + "/samples.bin", std::ios::binary).write(reinterpret_cast<const char*>(samples.data), std::streamsize(samplesSize));
		// Vulkan standard sample locations for 4 samples (VkPhysicalDeviceLimits::standardSampleLocations).
		const double locations[4][2] = {{0.375, 0.125}, {0.875, 0.375}, {0.125, 0.625}, {0.625, 0.875}};
		// Triangles as the topology assembles them; each vertex in window coordinates, with its w and colour.
		std::vector<uint32_t> triangles = strip ? std::vector<uint32_t>{0, 1, 2, 1, 2, 3} : std::vector<uint32_t>{0, 1, 2, 3, 4, 5};
		auto window = [&](const Vertex& v, int axis) { return (double(v.position[axis]) / double(v.position[3]) + 1.0) * 0.5 * kSide; };
		const float* data = reinterpret_cast<const float*>(samples.data);
		uint32_t written = 0, misplaced = 0, outside = 0, above = 0, onDiagonal = 0;
		double worst = 0;
		uint32_t worstPixel = 0, worstSample = 0;
		for (uint32_t pixel = 0; pixel < kSide * kSide; ++pixel) {
			for (uint32_t sample = 0; sample < 4; ++sample) {
				const float* value = data + (size_t(pixel) * 4 + sample) * 8;
				if (value[3] != 1.0f) continue;
				++written;
				if (std::abs(double(value[4]) - locations[sample][0]) > 1e-6 || std::abs(double(value[5]) - locations[sample][1]) > 1e-6) ++misplaced;
				const double px = pixel % kSide + locations[sample][0], py = pixel / kSide + locations[sample][1];
				// The triangle that contains the sample, or the nearest one; on the strip's shared edge both give the same value.
				double best = -1e30, expected[3] = {};
				for (size_t t = 0; t < triangles.size(); t += 3) {
					const Vertex* v[3] = {&vertices[triangles[t]], &vertices[triangles[t + 1]], &vertices[triangles[t + 2]]};
					double x[3], y[3], l[3];
					for (int i = 0; i < 3; ++i) { x[i] = window(*v[i], 0); y[i] = window(*v[i], 1); }
					const double area = (x[1] - x[0]) * (y[2] - y[0]) - (x[2] - x[0]) * (y[1] - y[0]);
					l[0] = ((x[1] - px) * (y[2] - py) - (x[2] - px) * (y[1] - py)) / area;
					l[1] = ((x[2] - px) * (y[0] - py) - (x[0] - px) * (y[2] - py)) / area;
					l[2] = 1 - l[0] - l[1];
					const double inside = std::min(l[0], std::min(l[1], l[2]));
					if (inside <= best) continue;
					best = inside;
					double sum = 0, b[3];
					for (int i = 0; i < 3; ++i) { b[i] = l[i] / double(v[i]->position[3]); sum += b[i]; }
					for (int c = 0; c < 3; ++c) expected[c] = (b[0] * v[0]->color[c] + b[1] * v[1]->color[c] + b[2] * v[2]->color[c]) / sum;
				}
				outside += best < -1e-9;
				double error = 0;
				for (int c = 0; c < 3; ++c) error = std::max(error, std::abs(double(value[c]) - expected[c]));
				if (error > worst) { worst = error; worstPixel = pixel; worstSample = sample; }
				if (error > 1.0 / 255) { ++above; onDiagonal += pixel % kSide == pixel / kSide; }
			}
		}
		std::printf("samples: written=%u of %u, off the standard location=%u, outside every triangle=%u\n", written, kSide * kSide * 4, misplaced, outside);
		std::printf("samples vs CPU interpolation: above_1/255=%u (on the diagonal %u), max_error=%.6f (%.2f/255) at pixel (%u, %u) sample %u\n",
		            above, onDiagonal, worst, worst * 255, worstPixel % kSide, worstPixel / kSide, worstSample);
		const int exitCode = written != kSide * kSide * 4 || misplaced || outside ? 2 : above ? 4 : 0;
		std::printf("PERVERTEX_MSAA_WEIGHTS %s %s\n", exitCode == 0 ? "PASS" : exitCode == 4 ? "ABOVE_ONE_STEP" : "FAIL", name.c_str());
		vkDeviceWaitIdle(device);
		vkDestroyDevice(device, nullptr);
		vkDestroyInstance(instance, nullptr);
		return exitCode;
	}
	const auto testStatic = render(test, false, "test-static.rgba"), testDynamic = render(test, true, "test-dynamic.rgba");
	const auto referenceStatic = render(reference, false, "reference-static.rgba"), referenceDynamic = render(reference, true, "reference-dynamic.rgba");

	// Pixels above the threshold, the largest channel difference, and the bounding box of the pixels above it.
	auto compare = [&](const std::vector<uint8_t>& a, const std::vector<uint8_t>& b, uint32_t threshold, const char* what) {
		uint32_t above = 0, worst = 0, x0 = kSide, y0 = kSide, x1 = 0, y1 = 0, diagonal = 0;
		for (uint32_t p = 0; p < kSide * kSide; ++p) {
			uint32_t d = 0;
			for (uint32_t c = 0; c < 4; ++c) d = std::max<uint32_t>(d, uint32_t(std::abs(int(a[4 * p + c]) - int(b[4 * p + c]))));
			worst = std::max(worst, d);
			if (d <= threshold) continue;
			const uint32_t x = p % kSide, y = p / kSide;
			++above;
			diagonal += x == y;
			x0 = std::min(x0, x); y0 = std::min(y0, y); x1 = std::max(x1, x); y1 = std::max(y1, y);
		}
		if (above) std::printf("%s: above_%u=%u max_channel_difference=%u box=(%u..%u, %u..%u) on_diagonal=%u\n", what, threshold, above, worst, x0, x1, y0, y1, diagonal);
		else std::printf("%s: above_%u=0 max_channel_difference=%u\n", what, threshold, worst);
		return above;
	};
	uint32_t covered = 0;
	for (uint32_t p = 0; p < kSide * kSide; ++p) covered += testStatic[4 * p + 3] != 0;
	std::printf("covered=%u\n", covered);
	const bool identical = compare(testStatic, testDynamic, 0, "test static vs dynamic") == 0 && compare(referenceStatic, referenceDynamic, 0, "reference static vs dynamic") == 0;
	const bool withinThreshold = compare(testStatic, referenceStatic, 1, "test vs reference (CTS threshold 1)") == 0;
	const int exitCode = covered == 0 || !identical ? 2 : withinThreshold ? 0 : 4;
	std::printf("PERVERTEX_MSAA_WEIGHTS %s %s\n", exitCode == 0 ? "PASS" : exitCode == 4 ? "ABOVE_CTS_THRESHOLD" : "FAIL", name.c_str());
	vkDeviceWaitIdle(device);
	vkDestroyDevice(device, nullptr);
	vkDestroyInstance(instance, nullptr);
	return exitCode;
	}
}
