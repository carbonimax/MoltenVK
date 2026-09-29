// Copyright 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
#include <vulkan/vulkan.h>

#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <stdexcept>
#include <string>
#include <vector>

static void check(VkResult result, const char* operation) {
    if (result != VK_SUCCESS) throw std::runtime_error(std::string(operation) + ": " + std::to_string(result));
}

static std::vector<uint32_t> readSpirv(const char* path) {
    std::ifstream file(path, std::ios::binary | std::ios::ate);
    if (!file) throw std::runtime_error(std::string("Cannot open ") + path);
    const auto size = file.tellg();
    if (size <= 0 || size % 4) throw std::runtime_error("Invalid SPIR-V size");
    std::vector<uint32_t> words(static_cast<size_t>(size) / 4);
    file.seekg(0);
    if (!file.read(reinterpret_cast<char*>(words.data()), size)) throw std::runtime_error("Cannot read SPIR-V");
    return words;
}

static bool hasExtension(const std::vector<VkExtensionProperties>& extensions, const char* name) {
    for (const auto& extension : extensions) if (strcmp(extension.extensionName, name) == 0) return true;
    return false;
}

static uint32_t memoryType(VkPhysicalDevice device, uint32_t bits, VkMemoryPropertyFlags flags) {
    VkPhysicalDeviceMemoryProperties properties{};
    vkGetPhysicalDeviceMemoryProperties(device, &properties);
    for (uint32_t i = 0; i < properties.memoryTypeCount; ++i) {
        if ((bits & (1u << i)) && (properties.memoryTypes[i].propertyFlags & flags) == flags) return i;
    }
    throw std::runtime_error("No suitable memory type");
}

extern "C" void mvkEnableTESFixtureDevice(VkPhysicalDevice device) __attribute__((weak_import));

int main(int argc, char** argv) {
    try {
        if (argc != 6 && argc != 7) throw std::runtime_error("Usage: test vertex.spv control.spv evaluation.spv fragment.spv mode [compute.spv]");
        const std::string mode = argv[5];
        const bool bindCompute = mode == "ordered-compute" || mode == "reject-instance-compute";
        const bool rejectCompute = bindCompute && mode != "ordered-compute";
        if (bindCompute && argc != 7) throw std::runtime_error("Compute-bind test requires compute.spv");
        if (bindCompute && (!getenv("MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS") || strcmp(getenv("MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS"), "0"))) throw std::runtime_error("Compute-bind test requires explicit prefill=0");
        std::array<int, 3> expected = mode == "swapped" || mode == "wrong-patch" ? std::array<int, 3>{255, 0, 0} : mode == "control" ? std::array<int, 3>{85, 85, 85} : std::array<int, 3>{0, 255, 0};
        constexpr uint32_t side = 32;
        constexpr VkFormat format = VK_FORMAT_R8G8B8A8_UNORM;
        uint32_t extensionCount = 0;
        check(vkEnumerateInstanceExtensionProperties(nullptr, &extensionCount, nullptr), "Enumerate instance extensions");
        std::vector<VkExtensionProperties> instanceExtensions(extensionCount);
        check(vkEnumerateInstanceExtensionProperties(nullptr, &extensionCount, instanceExtensions.data()), "Read instance extensions");
        const bool portabilityEnumeration = hasExtension(instanceExtensions, VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME);
        const char* instanceExtension = VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME;
        VkApplicationInfo app{VK_STRUCTURE_TYPE_APPLICATION_INFO};
        app.pApplicationName = "PerVertexKHR Vulkan reproducer";
        app.apiVersion = VK_API_VERSION_1_1;
        VkInstanceCreateInfo instanceInfo{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
        instanceInfo.pApplicationInfo = &app;
        instanceInfo.flags = portabilityEnumeration ? VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR : 0;
        instanceInfo.enabledExtensionCount = portabilityEnumeration ? 1 : 0;
        instanceInfo.ppEnabledExtensionNames = portabilityEnumeration ? &instanceExtension : nullptr;
        VkInstance instance = VK_NULL_HANDLE;
        check(vkCreateInstance(&instanceInfo, nullptr, &instance), "Create instance");
        uint32_t deviceCount = 0;
        check(vkEnumeratePhysicalDevices(instance, &deviceCount, nullptr), "Enumerate devices");
        if (!deviceCount) throw std::runtime_error("No Vulkan physical device");
        std::vector<VkPhysicalDevice> devices(deviceCount);
        check(vkEnumeratePhysicalDevices(instance, &deviceCount, devices.data()), "Read devices");
        VkPhysicalDevice physicalDevice = VK_NULL_HANDLE;
        uint32_t queueFamily = 0;
        bool portabilitySubset = false;
        for (auto candidate : devices) {
            if (mode != "public-device-gate") {
                if (!mvkEnableTESFixtureDevice) throw std::runtime_error("Test device adapter was not linked");
                // Test-only device override; asserts the public extension is closed first.
                mvkEnableTESFixtureDevice(candidate);
            }
            uint32_t count = 0;
            check(vkEnumerateDeviceExtensionProperties(candidate, nullptr, &count, nullptr), "Enumerate device extensions");
            std::vector<VkExtensionProperties> extensions(count);
            check(vkEnumerateDeviceExtensionProperties(candidate, nullptr, &count, extensions.data()), "Read device extensions");
            if (mode == "public-device-gate") {
                VkPhysicalDeviceFragmentShaderBarycentricFeaturesKHR barycentric{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FRAGMENT_SHADER_BARYCENTRIC_FEATURES_KHR};
                VkPhysicalDeviceFeatures2 features{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2};
                features.pNext = &barycentric;
                vkGetPhysicalDeviceFeatures2(candidate, &features);
                bool closed = !hasExtension(extensions, VK_KHR_FRAGMENT_SHADER_BARYCENTRIC_EXTENSION_NAME) && !barycentric.fragmentShaderBarycentric && !mvkEnableTESFixtureDevice;
                std::printf("Shipping build: barycentric extension/feature closed; test adapter absent: %s\n", closed ? "PASS" : "FAIL");
                vkDestroyInstance(instance, nullptr);
                return closed ? 0 : 2;
            }
            if (!hasExtension(extensions, VK_KHR_FRAGMENT_SHADER_BARYCENTRIC_EXTENSION_NAME)) continue;
            uint32_t familyCount = 0;
            vkGetPhysicalDeviceQueueFamilyProperties(candidate, &familyCount, nullptr);
            std::vector<VkQueueFamilyProperties> families(familyCount);
            vkGetPhysicalDeviceQueueFamilyProperties(candidate, &familyCount, families.data());
            for (uint32_t i = 0; i < familyCount; ++i) {
                if (!(families[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) || (bindCompute && !(families[i].queueFlags & VK_QUEUE_COMPUTE_BIT))) continue;
                physicalDevice = candidate;
                queueFamily = i;
                portabilitySubset = hasExtension(extensions, VK_KHR_PORTABILITY_SUBSET_EXTENSION_NAME);
                break;
            }
            if (physicalDevice) break;
        }
        if (!physicalDevice) throw std::runtime_error("No graphics device with VK_KHR_fragment_shader_barycentric");
        VkPhysicalDeviceFragmentShaderBarycentricFeaturesKHR barycentric{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FRAGMENT_SHADER_BARYCENTRIC_FEATURES_KHR};
        VkPhysicalDeviceFeatures2 features{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2};
        features.pNext = &barycentric;
        vkGetPhysicalDeviceFeatures2(physicalDevice, &features);
        if (!barycentric.fragmentShaderBarycentric) throw std::runtime_error("fragmentShaderBarycentric feature is unavailable");
        if (!features.features.tessellationShader) throw std::runtime_error("tessellationShader feature is unavailable");
        features.features = {};
        features.features.tessellationShader = VK_TRUE;
        barycentric.fragmentShaderBarycentric = VK_TRUE;
        float priority = 1;
        VkDeviceQueueCreateInfo queueInfo{VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};
        queueInfo.queueFamilyIndex = queueFamily;
        queueInfo.queueCount = 1;
        queueInfo.pQueuePriorities = &priority;
        std::array<const char*, 2> deviceExtensions{VK_KHR_FRAGMENT_SHADER_BARYCENTRIC_EXTENSION_NAME, VK_KHR_PORTABILITY_SUBSET_EXTENSION_NAME};
        VkDeviceCreateInfo deviceInfo{VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO};
        features.pNext = &barycentric;
        deviceInfo.pNext = &features;
        deviceInfo.queueCreateInfoCount = 1;
        deviceInfo.pQueueCreateInfos = &queueInfo;
        deviceInfo.enabledExtensionCount = portabilitySubset ? 2 : 1;
        deviceInfo.ppEnabledExtensionNames = deviceExtensions.data();
        VkDevice device = VK_NULL_HANDLE;
        check(vkCreateDevice(physicalDevice, &deviceInfo, nullptr, &device), "Create device");
        VkQueue queue = VK_NULL_HANDLE;
        vkGetDeviceQueue(device, queueFamily, 0, &queue);
        VkImageCreateInfo imageInfo{VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO};
        imageInfo.imageType = VK_IMAGE_TYPE_2D;
        imageInfo.format = format;
        imageInfo.extent = {side, side, 1};
        imageInfo.mipLevels = 1;
        imageInfo.arrayLayers = 1;
        imageInfo.samples = VK_SAMPLE_COUNT_1_BIT;
        imageInfo.tiling = VK_IMAGE_TILING_OPTIMAL;
        imageInfo.usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
        imageInfo.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
        VkImage image = VK_NULL_HANDLE;
        check(vkCreateImage(device, &imageInfo, nullptr, &image), "Create image");
        VkMemoryRequirements imageRequirements{};
        vkGetImageMemoryRequirements(device, image, &imageRequirements);
        VkMemoryAllocateInfo imageAllocation{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
        imageAllocation.allocationSize = imageRequirements.size;
        imageAllocation.memoryTypeIndex = memoryType(physicalDevice, imageRequirements.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        VkDeviceMemory imageMemory = VK_NULL_HANDLE;
        check(vkAllocateMemory(device, &imageAllocation, nullptr, &imageMemory), "Allocate image");
        check(vkBindImageMemory(device, image, imageMemory, 0), "Bind image");
        VkImageViewCreateInfo viewInfo{VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO};
        viewInfo.image = image;
        viewInfo.viewType = VK_IMAGE_VIEW_TYPE_2D;
        viewInfo.format = format;
        viewInfo.subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
        VkImageView imageView = VK_NULL_HANDLE;
        check(vkCreateImageView(device, &viewInfo, nullptr, &imageView), "Create image view");
        VkBufferCreateInfo bufferInfo{VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO};
        bufferInfo.size = side * side * 4;
        bufferInfo.usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT | VK_BUFFER_USAGE_INDEX_BUFFER_BIT;
        VkBuffer buffer = VK_NULL_HANDLE;
        check(vkCreateBuffer(device, &bufferInfo, nullptr, &buffer), "Create readback buffer");
        VkMemoryRequirements bufferRequirements{};
        vkGetBufferMemoryRequirements(device, buffer, &bufferRequirements);
        VkMemoryAllocateInfo bufferAllocation{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
        bufferAllocation.allocationSize = bufferRequirements.size;
        bufferAllocation.memoryTypeIndex = memoryType(physicalDevice, bufferRequirements.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
        VkDeviceMemory bufferMemory = VK_NULL_HANDLE;
        check(vkAllocateMemory(device, &bufferAllocation, nullptr, &bufferMemory), "Allocate readback buffer");
        check(vkBindBufferMemory(device, buffer, bufferMemory, 0), "Bind readback buffer");
        VkAttachmentDescription attachment{};
        attachment.format = format;
        attachment.samples = VK_SAMPLE_COUNT_1_BIT;
        attachment.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR;
        attachment.storeOp = VK_ATTACHMENT_STORE_OP_STORE;
        attachment.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
        attachment.finalLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
        VkAttachmentReference attachmentReference{0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};
        VkSubpassDescription subpass{};
        subpass.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS;
        subpass.colorAttachmentCount = 1;
        subpass.pColorAttachments = &attachmentReference;
        VkRenderPassCreateInfo renderPassInfo{VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO};
        renderPassInfo.attachmentCount = 1;
        renderPassInfo.pAttachments = &attachment;
        renderPassInfo.subpassCount = 1;
        renderPassInfo.pSubpasses = &subpass;
        VkRenderPass renderPass = VK_NULL_HANDLE;
        check(vkCreateRenderPass(device, &renderPassInfo, nullptr, &renderPass), "Create render pass");
        VkFramebufferCreateInfo framebufferInfo{VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO};
        framebufferInfo.renderPass = renderPass;
        framebufferInfo.attachmentCount = 1;
        framebufferInfo.pAttachments = &imageView;
        framebufferInfo.width = side;
        framebufferInfo.height = side;
        framebufferInfo.layers = 1;
        VkFramebuffer framebuffer = VK_NULL_HANDLE;
        check(vkCreateFramebuffer(device, &framebufferInfo, nullptr, &framebuffer), "Create framebuffer");
        auto vertexCode = readSpirv(argv[1]);
        auto controlCode = readSpirv(argv[2]);
        auto evaluationCode = readSpirv(argv[3]);
        auto fragmentCode = readSpirv(argv[4]);
        VkShaderModuleCreateInfo shaderInfo{VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO};
        shaderInfo.codeSize = vertexCode.size() * 4;
        shaderInfo.pCode = vertexCode.data();
        VkShaderModule vertexShader = VK_NULL_HANDLE;
        check(vkCreateShaderModule(device, &shaderInfo, nullptr, &vertexShader), "Create vertex shader");
        shaderInfo.codeSize = controlCode.size() * 4;
        shaderInfo.pCode = controlCode.data();
        VkShaderModule controlShader = VK_NULL_HANDLE;
        check(vkCreateShaderModule(device, &shaderInfo, nullptr, &controlShader), "Create tessellation control shader");
        shaderInfo.codeSize = evaluationCode.size() * 4;
        shaderInfo.pCode = evaluationCode.data();
        VkShaderModule evaluationShader = VK_NULL_HANDLE;
        check(vkCreateShaderModule(device, &shaderInfo, nullptr, &evaluationShader), "Create tessellation evaluation shader");
        shaderInfo.codeSize = fragmentCode.size() * 4;
        shaderInfo.pCode = fragmentCode.data();
        VkShaderModule fragmentShader = VK_NULL_HANDLE;
        check(vkCreateShaderModule(device, &shaderInfo, nullptr, &fragmentShader), "Create fragment shader");
        VkPipelineLayoutCreateInfo layoutInfo{VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};
        VkPipelineLayout pipelineLayout = VK_NULL_HANDLE;
        check(vkCreatePipelineLayout(device, &layoutInfo, nullptr, &pipelineLayout), "Create pipeline layout");
        VkPipelineShaderStageCreateInfo stages[4]{};
        for (auto& stage : stages) stage.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        stages[0].stage = VK_SHADER_STAGE_VERTEX_BIT;
        stages[0].module = vertexShader;
        stages[0].pName = "main";
        stages[1].stage = VK_SHADER_STAGE_TESSELLATION_CONTROL_BIT;
        stages[1].module = controlShader;
        stages[1].pName = "main";
        stages[2].stage = VK_SHADER_STAGE_TESSELLATION_EVALUATION_BIT;
        stages[2].module = evaluationShader;
        stages[2].pName = "main";
        stages[3].stage = VK_SHADER_STAGE_FRAGMENT_BIT;
        stages[3].module = fragmentShader;
        stages[3].pName = "main";
        VkPipelineVertexInputStateCreateInfo vertexInput{VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO};
        VkPipelineInputAssemblyStateCreateInfo assembly{VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO};
        assembly.topology = VK_PRIMITIVE_TOPOLOGY_PATCH_LIST;
        VkPipelineTessellationStateCreateInfo tessellation{VK_STRUCTURE_TYPE_PIPELINE_TESSELLATION_STATE_CREATE_INFO};
        tessellation.patchControlPoints = 3;
        VkViewport viewport{0, 0, float(side), float(side), 0, 1};
        VkRect2D scissor{{0, 0}, {side, side}};
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
        multisample.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;
        VkPipelineColorBlendAttachmentState blendAttachment{};
        blendAttachment.colorWriteMask = VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT | VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT;
        VkPipelineColorBlendStateCreateInfo blend{VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO};
        blend.attachmentCount = 1;
        blend.pAttachments = &blendAttachment;
        VkGraphicsPipelineCreateInfo pipelineInfo{VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO};
        pipelineInfo.stageCount = 4;
        pipelineInfo.pStages = stages;
        pipelineInfo.pVertexInputState = &vertexInput;
        pipelineInfo.pInputAssemblyState = &assembly;
        pipelineInfo.pTessellationState = &tessellation;
        pipelineInfo.pViewportState = &viewportState;
        pipelineInfo.pRasterizationState = &raster;
        pipelineInfo.pMultisampleState = &multisample;
        pipelineInfo.pColorBlendState = &blend;
        pipelineInfo.layout = pipelineLayout;
        pipelineInfo.renderPass = renderPass;
        VkPipeline pipeline = VK_NULL_HANDLE;
        VkPipelineCache cache = VK_NULL_HANDLE;
        if (mode == "reject-cache") {
            VkPipelineCacheCreateInfo info{VK_STRUCTURE_TYPE_PIPELINE_CACHE_CREATE_INFO};
            check(vkCreatePipelineCache(device, &info, nullptr, &cache), "Create cache");
        }
        if (mode == "reject-patch-size") tessellation.patchControlPoints = 4;
        VkSpecializationInfo specialization{};
        if (mode == "reject-specialization") stages[1].pSpecializationInfo = &specialization;
        VkResult pipelineResult = vkCreateGraphicsPipelines(device, cache, 1, &pipelineInfo, nullptr, &pipeline);
        if (mode == "reject-public" || mode == "reject-cache" || mode == "reject-patch-size" || mode == "reject-specialization") {
            std::printf("pipeline rejection: %d (expected %d)\n", pipelineResult, VK_ERROR_FEATURE_NOT_PRESENT);
            if (pipeline) vkDestroyPipeline(device, pipeline, nullptr);
            if (cache) vkDestroyPipelineCache(device, cache, nullptr);
            vkDestroyDevice(device, nullptr);
            vkDestroyInstance(instance, nullptr);
            return pipelineResult == VK_ERROR_FEATURE_NOT_PRESENT ? 0 : 2;
        }
        check(pipelineResult, "Create graphics pipeline");
        VkShaderModule computeShader = VK_NULL_HANDLE;
        VkPipeline computePipeline = VK_NULL_HANDLE;
        if (bindCompute) {
            auto computeCode = readSpirv(argv[6]);
            shaderInfo.codeSize = computeCode.size() * sizeof(uint32_t);
            shaderInfo.pCode = computeCode.data();
            check(vkCreateShaderModule(device, &shaderInfo, nullptr, &computeShader), "Create compute shader");
            VkComputePipelineCreateInfo computeInfo{VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO};
            computeInfo.stage.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
            computeInfo.stage.stage = VK_SHADER_STAGE_COMPUTE_BIT;
            computeInfo.stage.module = computeShader;
            computeInfo.stage.pName = "main";
            computeInfo.layout = pipelineLayout;
            check(vkCreateComputePipelines(device, VK_NULL_HANDLE, 1, &computeInfo, nullptr, &computePipeline), "Create compute pipeline");
        }
        VkCommandPoolCreateInfo poolInfo{VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};
        poolInfo.queueFamilyIndex = queueFamily;
        VkCommandPool pool = VK_NULL_HANDLE;
        check(vkCreateCommandPool(device, &poolInfo, nullptr, &pool), "Create command pool");
        VkCommandBufferAllocateInfo commandInfo{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
        commandInfo.commandPool = pool;
        commandInfo.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        commandInfo.commandBufferCount = 1;
        VkCommandBuffer command = VK_NULL_HANDLE;
        check(vkAllocateCommandBuffers(device, &commandInfo, &command), "Allocate command buffer");
        VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
        VkClearValue clear{};
        VkRenderPassBeginInfo pass{VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO};
        pass.renderPass = renderPass;
        pass.framebuffer = framebuffer;
        pass.renderArea = scissor;
        pass.clearValueCount = 1;
        pass.pClearValues = &clear;
        uint32_t housekeepingSubmissions = 0, rejectedBufferSubmissions = 0;
        auto submitAndWait = [&](VkCommandBuffer bufferToSubmit) {
            VkSubmitInfo info{VK_STRUCTURE_TYPE_SUBMIT_INFO};
            info.commandBufferCount = 1;
            info.pCommandBuffers = &bufferToSubmit;
            check(vkQueueSubmit(queue, 1, &info, VK_NULL_HANDLE), "Submit sentinel command");
            if (bufferToSubmit == command) ++rejectedBufferSubmissions; else ++housekeepingSubmissions;
            check(vkQueueWaitIdle(queue), "Wait for sentinel command");
        };
        if (rejectCompute) {
            // Establish actual GPU image contents before recording the rejected buffer.
            VkCommandBuffer initialize = VK_NULL_HANDLE;
            check(vkAllocateCommandBuffers(device, &commandInfo, &initialize), "Allocate sentinel initialization");
            check(vkBeginCommandBuffer(initialize, &begin), "Begin sentinel initialization");
            clear.color.float32[2] = clear.color.float32[3] = 1;
            vkCmdBeginRenderPass(initialize, &pass, VK_SUBPASS_CONTENTS_INLINE);
            vkCmdEndRenderPass(initialize);
            check(vkEndCommandBuffer(initialize), "End sentinel initialization");
            submitAndWait(initialize);
            clear = {}; // A partial commit would replace blue with black.
            void* sentinel = nullptr;
            check(vkMapMemory(device, bufferMemory, 0, bufferInfo.size, 0, &sentinel), "Map readback sentinel");
            memset(sentinel, 0xa5, bufferInfo.size);
            vkUnmapMemory(device, bufferMemory);
        }
        check(vkBeginCommandBuffer(command, &begin), "Begin command buffer");
        if (bindCompute) {
            vkCmdBindPipeline(command, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
            vkCmdBindPipeline(command, VK_PIPELINE_BIND_POINT_COMPUTE, computePipeline);
        }
        vkCmdBeginRenderPass(command, &pass, VK_SUBPASS_CONTENTS_INLINE);
        if (!bindCompute) vkCmdBindPipeline(command, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
        if (mode == "reject-indexed") {
            vkCmdBindIndexBuffer(command, buffer, 0, VK_INDEX_TYPE_UINT16);
            vkCmdDrawIndexed(command, 6, 1, 0, 0, 0);
        } else {
            vkCmdDraw(command, 6, mode == "reject-instance" || mode == "reject-instance-compute" ? 2 : 1, 0, 0);
        }
        vkCmdEndRenderPass(command);
        VkImageMemoryBarrier imageBarrier{VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER};
        imageBarrier.srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
        imageBarrier.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
        imageBarrier.oldLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
        imageBarrier.newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
        imageBarrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        imageBarrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        imageBarrier.image = image;
        imageBarrier.subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
        vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, nullptr, 0, nullptr, 1, &imageBarrier);
        VkBufferImageCopy copy{};
        copy.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1};
        copy.imageExtent = {side, side, 1};
        vkCmdCopyImageToBuffer(command, image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, buffer, 1, &copy);
        VkBufferMemoryBarrier bufferBarrier{VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER};
        bufferBarrier.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        bufferBarrier.dstAccessMask = VK_ACCESS_HOST_READ_BIT;
        bufferBarrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        bufferBarrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        bufferBarrier.buffer = buffer;
        bufferBarrier.size = VK_WHOLE_SIZE;
        vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 0, nullptr, 1, &bufferBarrier, 0, nullptr);
        VkResult recorded = vkEndCommandBuffer(command);
        if (rejectCompute) {
            // Never submit this buffer, even if the regression makes End succeed.
            // The test must fail on late rejection rather than trigger an invalid submission.
            check(vkQueueWaitIdle(queue), "Drain queue before sentinel verification");
            void* sentinel = nullptr;
            check(vkMapMemory(device, bufferMemory, 0, bufferInfo.size, 0, &sentinel), "Map untouched readback");
            bool untouched = true;
            for (VkDeviceSize i = 0; i < bufferInfo.size; ++i) untouched &= static_cast<uint8_t*>(sentinel)[i] == 0xa5;
            vkUnmapMemory(device, bufferMemory);
            VkCommandBuffer probe = VK_NULL_HANDLE;
            check(vkAllocateCommandBuffers(device, &commandInfo, &probe), "Allocate independent image probe");
            check(vkBeginCommandBuffer(probe, &begin), "Begin independent image probe");
            vkCmdPipelineBarrier(probe, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, nullptr, 0, nullptr, 1, &imageBarrier);
            vkCmdCopyImageToBuffer(probe, image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, buffer, 1, &copy);
            vkCmdPipelineBarrier(probe, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 0, nullptr, 1, &bufferBarrier, 0, nullptr);
            check(vkEndCommandBuffer(probe), "End independent image probe");
            submitAndWait(probe);
            check(vkMapMemory(device, bufferMemory, 0, bufferInfo.size, 0, &sentinel), "Map independent image probe");
            bool blue = true;
            for (uint32_t i = 0; i < side * side; ++i) {
                const auto* pixel = static_cast<uint8_t*>(sentinel) + 4 * i;
                blue &= pixel[0] == 0 && pixel[1] == 0 && pixel[2] == 255 && pixel[3] == 255;
            }
            vkUnmapMemory(device, bufferMemory);
            std::printf("TES -> compute -> render pass -> draw: End=%d (expected %d); rejected-buffer submissions=%u; housekeeping submissions=%u; readback untouched=%s; all %u blue pixels preserved=%s\n", recorded, VK_ERROR_FEATURE_NOT_PRESENT, rejectedBufferSubmissions, housekeepingSubmissions, untouched ? "yes" : "NO", side * side, blue ? "yes" : "NO");
            vkDestroyDevice(device, nullptr);
            vkDestroyInstance(instance, nullptr);
            return recorded == VK_ERROR_FEATURE_NOT_PRESENT && untouched && blue && rejectedBufferSubmissions == 0 && housekeepingSubmissions == 2 ? 0 : 2;
        }
        if (mode == "reject-instance" || mode == "reject-indexed") {
            std::printf("recording rejection: %d (expected %d); no submission\n", recorded, VK_ERROR_FEATURE_NOT_PRESENT);
            vkDestroyDevice(device, nullptr);
            vkDestroyInstance(instance, nullptr);
            return recorded == VK_ERROR_FEATURE_NOT_PRESENT ? 0 : 2;
        }
        check(recorded, "End command buffer");
        VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO};
        submit.commandBufferCount = 1;
        submit.pCommandBuffers = &command;
        check(vkQueueSubmit(queue, 1, &submit, VK_NULL_HANDLE), "Submit");
        check(vkQueueWaitIdle(queue), "Wait for draw");
        void* mapped = nullptr;
        check(vkMapMemory(device, bufferMemory, 0, bufferInfo.size, 0, &mapped), "Map readback");
        const auto* pixels = static_cast<const uint8_t*>(mapped);
        bool correct = true;
        for (uint32_t x : {7u, 9u, 23u, 25u}) {
            const auto* pixel = pixels + (16 * side + x) * 4;
            std::printf("pixel (%u,16): %u %u %u %u; expected %d %d %d 255\n", x, pixel[0], pixel[1], pixel[2], pixel[3], expected[0], expected[1], expected[2]);
            correct &= pixel[0] == expected[0] && pixel[1] == expected[1] && pixel[2] == expected[2] && pixel[3] == 255;
        }
        for (uint32_t x : {0u, 16u, 31u}) {
            const auto* pixel = pixels + (16 * side + x) * 4;
            correct &= pixel[0] == 0 && pixel[1] == 0 && pixel[2] == 0;
        }
        vkUnmapMemory(device, bufferMemory);
        vkDestroyCommandPool(device, pool, nullptr);
        if (computePipeline) vkDestroyPipeline(device, computePipeline, nullptr);
        if (computeShader) vkDestroyShaderModule(device, computeShader, nullptr);
        vkDestroyPipeline(device, pipeline, nullptr);
        vkDestroyPipelineLayout(device, pipelineLayout, nullptr);
        vkDestroyShaderModule(device, fragmentShader, nullptr);
        vkDestroyShaderModule(device, evaluationShader, nullptr);
        vkDestroyShaderModule(device, controlShader, nullptr);
        vkDestroyShaderModule(device, vertexShader, nullptr);
        vkDestroyFramebuffer(device, framebuffer, nullptr);
        vkDestroyRenderPass(device, renderPass, nullptr);
        vkDestroyImageView(device, imageView, nullptr);
        vkDestroyBuffer(device, buffer, nullptr);
        vkFreeMemory(device, bufferMemory, nullptr);
        vkDestroyImage(device, image, nullptr);
        vkFreeMemory(device, imageMemory, nullptr);
        vkDestroyDevice(device, nullptr);
        vkDestroyInstance(instance, nullptr);
        return correct ? 0 : 2;
    } catch (const std::exception& error) {
        std::fprintf(stderr, "%s\n", error.what());
        return 1;
    }
}
