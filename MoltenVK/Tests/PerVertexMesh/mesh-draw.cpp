// Copyright 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
// Vulkan oracles for the first MoltenVK mesh path (VK_EXT_mesh_shader behind the test device adapter): a mesh
// shader and a fragment shader, no task shader, drawn with vkCmdDrawMeshTasksEXT. The mesh is the Metal probe's:
// four vertices with distinct values and triangles (0,1,2), (3,2,1). Every pixel away from edges must match a CPU
// model of the Vulkan rasterization (y down), outside pixels must keep the clear, and the refused forms must fail
// deterministically. The shipping library must expose neither the extension nor the feature.
// PerVertexKHR scenarios read the three corners of each triangle in index order: each image must match its own model
// and differ from a rival model (swapped weights, or the other index order) on at least 90% of the checked pixels.
// Usage: mesh-draw <shader-dir> <scenario>
//   draw | grid | twice | pervertex | pervertex-swapped | pervertex-permuted | barycentric | barycentric-permuted
//   | pervertex-consistency | reject-task | reject-descriptor | reject-per-primitive | reject-pervertex-block
//   | reject-pervertex-matrix | reject-specialization | reject-indirect | reject-draw-id | reject-draw-id-uint
//   | reject-buffer-address | no-adapter | public-device-gate
// The refusal scenarios only create pipelines: nothing they build is ever submitted.
#define VK_ENABLE_BETA_EXTENSIONS 1
#include <vulkan/vulkan.h>

#include <array>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <stdexcept>
#include <string>
#include <vector>

extern "C" void mvkEnableMeshTestDevice(VkPhysicalDevice device) __attribute__((weak_import));
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

static bool hasExtension(VkPhysicalDevice physical, const char* name) {
	uint32_t count = 0;
	vkEnumerateDeviceExtensionProperties(physical, nullptr, &count, nullptr);
	std::vector<VkExtensionProperties> extensions(count);
	vkEnumerateDeviceExtensionProperties(physical, nullptr, &count, extensions.data());
	for (const auto& extension : extensions) if (!strcmp(extension.extensionName, name)) return true;
	return false;
}

static constexpr uint32_t kSize = 64;
static const float kPositions[4][2] = {{-0.75f, -0.75f}, {0.75f, -0.75f}, {-0.75f, 0.75f}, {0.75f, 0.75f}};
static const float kColors[4][3] = {{0.8f, 0.1f, 0.2f}, {0.1f, 0.7f, 0.3f}, {0.2f, 0.3f, 0.9f}, {0.6f, 0.5f, 0.4f}};
static const int kTriangles[2][3] = {{0, 1, 2}, {3, 2, 1}};
static const int kPermuted[2][3] = {{1, 2, 0}, {2, 1, 3}};  // The same triangles, index order rotated.

// Interpolated: the per-vertex colours weighted by the barycentrics. Ordered and Swapped: the corners in index order
// weighted by 0.2, 0.3, 0.5 and 0.3, 0.2, 0.5. Barycentric: the barycentrics themselves, in index order.
enum Model { None, Interpolated, Ordered, Swapped, Barycentric };

// Expected colour of the pixel centre, or false near an edge; outside is set for pixels that must keep the clear.
static bool expected(int x, int y, uint32_t groups, Model model, bool permuted, float rgb[3], bool& outside) {
	static const float kOrdered[3] = {0.2f, 0.3f, 0.5f}, kSwapped[3] = {0.3f, 0.2f, 0.5f};
	const auto& triangles = permuted ? kPermuted : kTriangles;
	float px = (x + 0.5f) / (kSize / 2) - 1, py = (y + 0.5f) / (kSize / 2) - 1;  // Vulkan framebuffer: y down.
	outside = true;
	for (uint32_t g = 0; g < groups; ++g) {
		float scale = groups == 1 ? 1.0f : 0.5f, offset = groups == 1 ? 0.0f : (g ? 0.5f : -0.5f);
		float left = -0.75f * scale + offset, right = 0.75f * scale + offset;
		if (px > left - 0.05f && px < right + 0.05f && std::fabs(py) < 0.8f) outside = false;
		for (int t = 0; t < 2; ++t) {
			float v[3][2];
			for (int c = 0; c < 3; ++c) { v[c][0] = kPositions[triangles[t][c]][0] * scale + offset; v[c][1] = kPositions[triangles[t][c]][1]; }
			float area = (v[1][0] - v[0][0]) * (v[2][1] - v[0][1]) - (v[2][0] - v[0][0]) * (v[1][1] - v[0][1]);
			float l0 = ((v[1][0] - px) * (v[2][1] - py) - (v[2][0] - px) * (v[1][1] - py)) / area;
			float l1 = ((v[2][0] - px) * (v[0][1] - py) - (v[0][0] - px) * (v[2][1] - py)) / area;
			float l2 = 1 - l0 - l1, margin = 0.04f;
			if (l0 > margin && l1 > margin && l2 > margin) {
				const float lambda[3] = {l0, l1, l2};
				const float* weights = model == Ordered ? kOrdered : model == Swapped ? kSwapped : lambda;
				for (int k = 0; k < 3; ++k) {
					rgb[k] = model == Barycentric ? lambda[k] : 0;
					for (int c = 0; c < 3 && model != Barycentric; ++c) rgb[k] += weights[c] * kColors[triangles[t][c]][k];
				}
				return true;
			}
		}
	}
	return false;
}

int main(int argc, char** argv) {
	try {
		if (argc != 3) throw std::runtime_error("Usage: mesh-draw <shader-dir> <scenario>");
		const std::string shaders = argv[1], scenario = argv[2];
		VkApplicationInfo app{VK_STRUCTURE_TYPE_APPLICATION_INFO};
		app.pApplicationName = "PerVertexKHR mesh draw";
		app.apiVersion = VK_API_VERSION_1_3;
		VkInstanceCreateInfo instanceInfo{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
		instanceInfo.pApplicationInfo = &app;
		VkInstance instance = VK_NULL_HANDLE;
		check(vkCreateInstance(&instanceInfo, nullptr, &instance), "Create instance");
		uint32_t count = 1;
		VkPhysicalDevice physical = VK_NULL_HANDLE;
		vkEnumeratePhysicalDevices(instance, &count, &physical);
		if (!physical) throw std::runtime_error("No physical device");
		auto meshFeatureSupported = [&]() {
			VkPhysicalDeviceMeshShaderFeaturesEXT mesh{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MESH_SHADER_FEATURES_EXT};
			VkPhysicalDeviceFeatures2 features{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2};
			features.pNext = &mesh;
			vkGetPhysicalDeviceFeatures2(physical, &features);
			return mesh;
		};
		if (scenario == "public-device-gate" || scenario == "no-adapter") {
			auto mesh = meshFeatureSupported();
			bool closed = !hasExtension(physical, VK_EXT_MESH_SHADER_EXTENSION_NAME) && !mesh.meshShader && !mesh.taskShader;
			closed &= !hasExtension(physical, VK_KHR_FRAGMENT_SHADER_BARYCENTRIC_EXTENSION_NAME);
			if (scenario == "public-device-gate") closed &= !mvkEnableMeshTestDevice && !mvkEnableTESFixtureDevice;
			std::printf("MESH_DRAW %s %s: VK_EXT_mesh_shader, meshShader and VK_KHR_fragment_shader_barycentric closed%s\n", closed ? "PASS" : "FAIL", scenario.c_str(), scenario == "public-device-gate" ? ", test adapters absent" : " without the test adapters");
			return closed ? 0 : 2;
		}
		if (!mvkEnableMeshTestDevice || !mvkEnableTESFixtureDevice) throw std::runtime_error("Test device adapters were not linked");
		mvkEnableMeshTestDevice(physical);
		mvkEnableTESFixtureDevice(physical);  // Exposes VK_KHR_fragment_shader_barycentric, closed on macOS.
		auto supported = meshFeatureSupported();
		const bool exposed = hasExtension(physical, VK_EXT_MESH_SHADER_EXTENSION_NAME);
		std::printf("VK_EXT_mesh_shader exposed=%d meshShader=%d taskShader=%d multiviewMeshShader=%d\n", exposed, supported.meshShader, supported.taskShader, supported.multiviewMeshShader);
		if (!exposed || !supported.meshShader) { std::printf("MESH_DRAW FAIL %s: VK_EXT_mesh_shader is not exposed through the test adapter\n", scenario.c_str()); return 2; }
		VkPhysicalDeviceMeshShaderPropertiesEXT meshProperties{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MESH_SHADER_PROPERTIES_EXT};
		VkPhysicalDeviceProperties2 properties{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2};
		properties.pNext = &meshProperties;
		vkGetPhysicalDeviceProperties2(physical, &properties);
		std::printf("DEVICE=%s maxMeshWorkGroupInvocations=%u maxMeshOutputVertices=%u maxMeshOutputPrimitives=%u maxMeshWorkGroupCount=(%u,%u,%u) maxMeshWorkGroupTotalCount=%u\n",
		            properties.properties.deviceName, meshProperties.maxMeshWorkGroupInvocations, meshProperties.maxMeshOutputVertices, meshProperties.maxMeshOutputPrimitives,
		            meshProperties.maxMeshWorkGroupCount[0], meshProperties.maxMeshWorkGroupCount[1], meshProperties.maxMeshWorkGroupCount[2], meshProperties.maxMeshWorkGroupTotalCount);

		VkPhysicalDeviceFragmentShaderBarycentricFeaturesKHR supportedBarycentric{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FRAGMENT_SHADER_BARYCENTRIC_FEATURES_KHR};
		VkPhysicalDeviceVulkan12Features supported12{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES};
		supported12.pNext = &supportedBarycentric;
		VkPhysicalDeviceVulkan11Features supported11{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES};
		supported11.pNext = &supported12;
		VkPhysicalDeviceFeatures2 supportedFeatures{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2};
		supportedFeatures.pNext = &supported11;
		vkGetPhysicalDeviceFeatures2(physical, &supportedFeatures);
		if (!supported11.shaderDrawParameters || !supported12.bufferDeviceAddress) throw std::runtime_error("shaderDrawParameters or bufferDeviceAddress unavailable");
		if (!hasExtension(physical, VK_KHR_FRAGMENT_SHADER_BARYCENTRIC_EXTENSION_NAME) || !supportedBarycentric.fragmentShaderBarycentric) throw std::runtime_error("fragmentShaderBarycentric unavailable through the test adapter");
		// gl_DrawID and device addresses must be legal in the device, so that only the mesh path refuses them.
		VkPhysicalDeviceFragmentShaderBarycentricFeaturesKHR enableBarycentric{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FRAGMENT_SHADER_BARYCENTRIC_FEATURES_KHR};
		enableBarycentric.fragmentShaderBarycentric = VK_TRUE;
		VkPhysicalDeviceVulkan12Features enable12{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES};
		enable12.bufferDeviceAddress = VK_TRUE;
		enable12.pNext = &enableBarycentric;
		VkPhysicalDeviceVulkan11Features enable11{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES};
		enable11.shaderDrawParameters = VK_TRUE;
		enable11.pNext = &enable12;
		VkPhysicalDeviceMeshShaderFeaturesEXT enableMesh{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MESH_SHADER_FEATURES_EXT};
		enableMesh.meshShader = VK_TRUE;
		enableMesh.pNext = &enable11;
		float priority = 1;
		VkDeviceQueueCreateInfo queueInfo{VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};
		queueInfo.queueCount = 1;
		queueInfo.pQueuePriorities = &priority;
		std::vector<const char*> extensions{VK_EXT_MESH_SHADER_EXTENSION_NAME, VK_KHR_FRAGMENT_SHADER_BARYCENTRIC_EXTENSION_NAME};
		if (hasExtension(physical, VK_KHR_PORTABILITY_SUBSET_EXTENSION_NAME)) extensions.push_back(VK_KHR_PORTABILITY_SUBSET_EXTENSION_NAME);
		VkDeviceCreateInfo deviceInfo{VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO};
		deviceInfo.pNext = &enableMesh;
		deviceInfo.queueCreateInfoCount = 1;
		deviceInfo.pQueueCreateInfos = &queueInfo;
		deviceInfo.enabledExtensionCount = uint32_t(extensions.size());
		deviceInfo.ppEnabledExtensionNames = extensions.data();
		VkDevice device = VK_NULL_HANDLE;
		check(vkCreateDevice(physical, &deviceInfo, nullptr, &device), "Create device");
		VkQueue queue = VK_NULL_HANDLE;
		vkGetDeviceQueue(device, 0, 0, &queue);
		auto drawMeshTasks = reinterpret_cast<PFN_vkCmdDrawMeshTasksEXT>(vkGetDeviceProcAddr(device, "vkCmdDrawMeshTasksEXT"));
		auto drawMeshTasksIndirect = reinterpret_cast<PFN_vkCmdDrawMeshTasksIndirectEXT>(vkGetDeviceProcAddr(device, "vkCmdDrawMeshTasksIndirectEXT"));
		auto drawMeshTasksIndirectCount = reinterpret_cast<PFN_vkCmdDrawMeshTasksIndirectCountEXT>(vkGetDeviceProcAddr(device, "vkCmdDrawMeshTasksIndirectCountEXT"));
		if (!drawMeshTasks || !drawMeshTasksIndirect || !drawMeshTasksIndirectCount) throw std::runtime_error("Mesh draw entry points do not resolve");

		auto memoryType = [&](uint32_t bits, VkMemoryPropertyFlags flags) {
			VkPhysicalDeviceMemoryProperties memory{};
			vkGetPhysicalDeviceMemoryProperties(physical, &memory);
			for (uint32_t i = 0; i < memory.memoryTypeCount; ++i) if ((bits & (1u << i)) && (memory.memoryTypes[i].propertyFlags & flags) == flags) return i;
			throw std::runtime_error("No memory type");
		};
		VkBufferCreateInfo bufferInfo{VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO};
		bufferInfo.size = kSize * kSize * 4;
		bufferInfo.usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT | VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT;
		VkBuffer readback = VK_NULL_HANDLE;
		check(vkCreateBuffer(device, &bufferInfo, nullptr, &readback), "Create buffer");
		VkMemoryRequirements requirements{};
		vkGetBufferMemoryRequirements(device, readback, &requirements);
		VkMemoryAllocateInfo allocation{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
		allocation.allocationSize = requirements.size;
		allocation.memoryTypeIndex = memoryType(requirements.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
		VkDeviceMemory readbackMemory = VK_NULL_HANDLE;
		check(vkAllocateMemory(device, &allocation, nullptr, &readbackMemory), "Allocate buffer");
		check(vkBindBufferMemory(device, readback, readbackMemory, 0), "Bind buffer");
		void* mapped = nullptr;
		check(vkMapMemory(device, readbackMemory, 0, VK_WHOLE_SIZE, 0, &mapped), "Map buffer");

		VkImageCreateInfo imageInfo{VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO};
		imageInfo.imageType = VK_IMAGE_TYPE_2D;
		imageInfo.format = VK_FORMAT_R8G8B8A8_UNORM;
		imageInfo.extent = {kSize, kSize, 1};
		imageInfo.mipLevels = imageInfo.arrayLayers = 1;
		imageInfo.samples = VK_SAMPLE_COUNT_1_BIT;
		imageInfo.usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
		VkImage image = VK_NULL_HANDLE;
		check(vkCreateImage(device, &imageInfo, nullptr, &image), "Create image");
		vkGetImageMemoryRequirements(device, image, &requirements);
		allocation.allocationSize = requirements.size;
		allocation.memoryTypeIndex = memoryType(requirements.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
		VkDeviceMemory imageMemory = VK_NULL_HANDLE;
		check(vkAllocateMemory(device, &allocation, nullptr, &imageMemory), "Allocate image");
		check(vkBindImageMemory(device, image, imageMemory, 0), "Bind image");
		VkImageViewCreateInfo viewInfo{VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO};
		viewInfo.image = image;
		viewInfo.viewType = VK_IMAGE_VIEW_TYPE_2D;
		viewInfo.format = imageInfo.format;
		viewInfo.subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
		VkImageView view = VK_NULL_HANDLE;
		check(vkCreateImageView(device, &viewInfo, nullptr, &view), "Create view");
		VkAttachmentDescription attachment{};
		attachment.format = imageInfo.format;
		attachment.samples = VK_SAMPLE_COUNT_1_BIT;
		attachment.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR;
		attachment.storeOp = VK_ATTACHMENT_STORE_OP_STORE;
		attachment.finalLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
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
		framebufferInfo.width = framebufferInfo.height = kSize;
		framebufferInfo.layers = 1;
		VkFramebuffer framebuffer = VK_NULL_HANDLE;
		check(vkCreateFramebuffer(device, &framebufferInfo, nullptr, &framebuffer), "Create framebuffer");

		VkDescriptorSetLayoutBinding uniform{0, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 1, VK_SHADER_STAGE_MESH_BIT_EXT, nullptr};
		VkDescriptorSetLayoutCreateInfo setLayoutInfo{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO};
		setLayoutInfo.bindingCount = 1;
		setLayoutInfo.pBindings = &uniform;
		VkDescriptorSetLayout setLayout = VK_NULL_HANDLE;
		check(vkCreateDescriptorSetLayout(device, &setLayoutInfo, nullptr, &setLayout), "Create set layout");
		VkPipelineLayoutCreateInfo layoutInfo{VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};
		VkPipelineLayout emptyLayout = VK_NULL_HANDLE, uniformLayout = VK_NULL_HANDLE;
		check(vkCreatePipelineLayout(device, &layoutInfo, nullptr, &emptyLayout), "Create layout");
		layoutInfo.setLayoutCount = 1;
		layoutInfo.pSetLayouts = &setLayout;
		check(vkCreatePipelineLayout(device, &layoutInfo, nullptr, &uniformLayout), "Create uniform layout");

		auto module = [&](const std::string& name) {
			auto code = readSpirv(shaders + "/" + name);
			VkShaderModuleCreateInfo info{VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO};
			info.codeSize = code.size() * 4;
			info.pCode = code.data();
			VkShaderModule result = VK_NULL_HANDLE;
			check(vkCreateShaderModule(device, &info, nullptr, &result), "Create shader module");
			return result;
		};
		// A specialization map on the mesh stage could change its workgroup size: the first path refuses it.
		const uint32_t specializationValue = 1;
		const VkSpecializationMapEntry specializationEntry{0, 0, sizeof(uint32_t)};
		const VkSpecializationInfo specialization{1, &specializationEntry, sizeof(uint32_t), &specializationValue};
		auto createPipeline = [&](const std::string& mesh, bool task, VkPipelineLayout layout, VkPipeline& pipeline, const std::string& fragment = "interp.frag.spv", bool specialize = false) {
			std::vector<VkPipelineShaderStageCreateInfo> stages;
			auto stage = [&](VkShaderStageFlagBits bit, const std::string& name) {
				VkPipelineShaderStageCreateInfo info{VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO};
				info.stage = bit;
				info.module = module(name);
				info.pName = "main";
				stages.push_back(info);
			};
			if (task) stage(VK_SHADER_STAGE_TASK_BIT_EXT, "task.task.spv");
			stage(VK_SHADER_STAGE_MESH_BIT_EXT, mesh);
			if (specialize) stages.back().pSpecializationInfo = &specialization;
			stage(VK_SHADER_STAGE_FRAGMENT_BIT, fragment);
			VkViewport viewport{0, 0, float(kSize), float(kSize), 0, 1};
			VkRect2D scissor{{0, 0}, {kSize, kSize}};
			VkPipelineViewportStateCreateInfo viewportState{VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO};
			viewportState.viewportCount = viewportState.scissorCount = 1;
			viewportState.pViewports = &viewport;
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
			info.stageCount = uint32_t(stages.size());
			info.pStages = stages.data();
			info.pViewportState = &viewportState;
			info.pRasterizationState = &raster;
			info.pMultisampleState = &multisample;
			info.pColorBlendState = &blend;
			info.layout = layout;
			info.renderPass = renderPass;
			return vkCreateGraphicsPipelines(device, VK_NULL_HANDLE, 1, &info, nullptr, &pipeline);
		};

		if (scenario == "reject-task" || scenario == "reject-descriptor" || scenario == "reject-per-primitive" || scenario == "reject-pervertex-block" || scenario == "reject-pervertex-matrix" ||
		    scenario == "reject-specialization" || scenario == "reject-draw-id" || scenario == "reject-draw-id-uint" || scenario == "reject-buffer-address") {
			VkPipeline pipeline = VK_NULL_HANDLE;
			VkResult result = scenario == "reject-task" ? createPipeline("mesh.mesh.spv", true, emptyLayout, pipeline)
			                : scenario == "reject-descriptor" ? createPipeline("descriptor.mesh.spv", false, uniformLayout, pipeline)
			                : scenario == "reject-pervertex-block" ? createPipeline("block.mesh.spv", false, emptyLayout, pipeline, "pervertex-block.frag.spv")
			                : scenario == "reject-pervertex-matrix" ? createPipeline("matrix.mesh.spv", false, emptyLayout, pipeline, "pervertex-matrix.frag.spv")
			                : scenario == "reject-specialization" ? createPipeline("mesh.mesh.spv", false, emptyLayout, pipeline, "interp.frag.spv", true)
			                : scenario == "reject-draw-id" ? createPipeline("draw-id.mesh.spv", false, emptyLayout, pipeline)
			                : scenario == "reject-draw-id-uint" ? createPipeline("draw-id-uint.mesh.spv", false, emptyLayout, pipeline)
			                : scenario == "reject-buffer-address" ? createPipeline("buffer-address.mesh.spv", false, emptyLayout, pipeline)
			                : createPipeline("per-primitive.mesh.spv", false, emptyLayout, pipeline);
			bool pass = result == VK_ERROR_FEATURE_NOT_PRESENT;
			std::printf("MESH_DRAW %s %s: vkCreateGraphicsPipelines=%d expected=%d\n", pass ? "PASS" : "FAIL", scenario.c_str(), result, VK_ERROR_FEATURE_NOT_PRESENT);
			return pass ? 0 : 2;
		}

		struct Render { const char *name, *mesh, *fragment; Model model; bool permuted; Model rival; bool rivalPermuted; };
		static const Render renders[] = {
			{"draw", "mesh.mesh.spv", "interp.frag.spv", Interpolated, false, None, false},
			{"grid", "grid.mesh.spv", "interp.frag.spv", Interpolated, false, None, false},
			{"twice", "grid.mesh.spv", "interp.frag.spv", Interpolated, false, None, false},
			{"reject-indirect", "mesh.mesh.spv", "interp.frag.spv", Interpolated, false, None, false},
			{"pervertex", "mesh.mesh.spv", "pervertex.frag.spv", Ordered, false, Swapped, false},
			{"pervertex-swapped", "mesh.mesh.spv", "pervertex-swapped.frag.spv", Swapped, false, Ordered, false},
			{"pervertex-permuted", "permuted.mesh.spv", "pervertex.frag.spv", Ordered, true, Ordered, false},
			{"barycentric", "mesh.mesh.spv", "barycentric.frag.spv", Barycentric, false, Barycentric, true},
			{"barycentric-permuted", "permuted.mesh.spv", "barycentric.frag.spv", Barycentric, true, Barycentric, false},
			{"pervertex-consistency", "permuted.mesh.spv", "pervertex-consistency.frag.spv", Interpolated, true, None, false},
		};
		const Render* render = nullptr;
		for (const auto& candidate : renders) if (scenario == candidate.name) render = &candidate;
		if (!render) throw std::runtime_error("Unknown scenario");
		const bool grid = scenario == "grid", twice = scenario == "twice", indirect = scenario == "reject-indirect";
		VkPipeline pipeline = VK_NULL_HANDLE;
		check(createPipeline(render->mesh, false, emptyLayout, pipeline, render->fragment), "Create mesh pipeline");
		VkCommandPoolCreateInfo poolInfo{VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};
		VkCommandPool pool = VK_NULL_HANDLE;
		check(vkCreateCommandPool(device, &poolInfo, nullptr, &pool), "Create command pool");
		VkCommandBufferAllocateInfo commandInfo{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
		commandInfo.commandPool = pool;
		commandInfo.commandBufferCount = 1;
		VkCommandBuffer command = VK_NULL_HANDLE;
		check(vkAllocateCommandBuffers(device, &commandInfo, &command), "Allocate command buffer");
		VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
		check(vkBeginCommandBuffer(command, &begin), "Begin command buffer");
		VkClearValue clear{};
		clear.color.float32[0] = clear.color.float32[2] = clear.color.float32[3] = 1.0f;
		VkRenderPassBeginInfo passBegin{VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO};
		passBegin.renderPass = renderPass;
		passBegin.framebuffer = framebuffer;
		passBegin.renderArea = {{0, 0}, {kSize, kSize}};
		passBegin.clearValueCount = 1;
		passBegin.pClearValues = &clear;
		vkCmdBeginRenderPass(command, &passBegin, VK_SUBPASS_CONTENTS_INLINE);
		vkCmdBindPipeline(command, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
		if (indirect) drawMeshTasksIndirect(command, readback, 0, 1, sizeof(VkDrawMeshTasksIndirectCommandEXT));
		else if (twice) { drawMeshTasks(command, 1, 1, 1); drawMeshTasks(command, 2, 1, 1); }  // The second draw repaints group 0.
		else drawMeshTasks(command, grid ? 2 : 1, 1, 1);
		vkCmdEndRenderPass(command);
		VkBufferImageCopy copy{};
		copy.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1};
		copy.imageExtent = {kSize, kSize, 1};
		vkCmdCopyImageToBuffer(command, image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, readback, 1, &copy);
		VkResult ended = vkEndCommandBuffer(command);
		if (indirect) {
			bool pass = ended == VK_ERROR_FEATURE_NOT_PRESENT;
			std::printf("MESH_DRAW %s reject-indirect: vkEndCommandBuffer=%d expected=%d, nothing submitted\n", pass ? "PASS" : "FAIL", ended, VK_ERROR_FEATURE_NOT_PRESENT);
			return pass ? 0 : 2;
		}
		check(ended, "End command buffer");
		memset(mapped, 0, kSize * kSize * 4);
		VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO};
		submit.commandBufferCount = 1;
		submit.pCommandBuffers = &command;
		check(vkQueueSubmit(queue, 1, &submit, VK_NULL_HANDLE), "Submit");
		check(vkQueueWaitIdle(queue), "Wait");
		std::ofstream(scenario + ".rgba", std::ios::binary).write(static_cast<const char*>(mapped), kSize * kSize * 4);

		const auto* rgba = static_cast<const uint8_t*>(mapped);
		uint32_t checked = 0, mismatch = 0, background = 0, rivalMatch = 0;
		auto differs = [](const uint8_t* p, const float rgb[3]) {
			bool bad = p[3] != 255;
			for (int k = 0; k < 3; ++k) bad |= std::fabs(p[k] / 255.0f - rgb[k]) > 2.0f / 255;
			return bad;
		};
		const uint32_t groups = grid || twice ? 2 : 1;
		for (uint32_t y = 0; y < kSize; ++y) for (uint32_t x = 0; x < kSize; ++x) {
			const uint8_t* p = &rgba[4 * (y * kSize + x)];
			float rgb[3];
			bool outside = false;
			if (!expected(int(x), int(y), groups, render->model, render->permuted, rgb, outside)) {
				if (outside) background += !(p[0] == 255 && p[1] == 0 && p[2] == 255 && p[3] == 255);
				continue;
			}
			++checked;
			mismatch += differs(p, rgb);
			if (render->rival != None && expected(int(x), int(y), groups, render->rival, render->rivalPermuted, rgb, outside)) rivalMatch += !differs(p, rgb);
		}
		// The rival model must be told apart: otherwise this image would not prove the order.
		bool pass = checked > 0 && mismatch == 0 && background == 0 && (render->rival == None || rivalMatch * 10 <= checked);
		std::printf("  %s: checked=%u mismatch=%u background_changed=%u", render->model == Interpolated ? "interpolated per-vertex values" : render->model == Barycentric ? "barycentrics in index order" : "PerVertexKHR corners in index order", checked, mismatch, background);
		if (render->rival != None) std::printf(" rival_matches=%u (at most %u)", rivalMatch, checked / 10);
		std::printf("\n");
		std::printf("MESH_DRAW %s %s\n", pass ? "PASS" : "FAIL", scenario.c_str());
		vkDeviceWaitIdle(device);
		return pass ? 0 : 2;
	} catch (const std::exception& error) {
		std::fprintf(stderr, "ERROR: %s\n", error.what());
		return 1;
	}
}
