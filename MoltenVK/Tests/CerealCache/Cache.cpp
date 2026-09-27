// Copyright 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
#include <vulkan/vulkan.h>
#include <cassert>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <vector>

static void check(VkResult result) { assert(result == VK_SUCCESS); }
static std::vector<uint8_t> data(VkDevice device, VkPipelineCache cache) {
    size_t size = 0;
    check(vkGetPipelineCacheData(device, cache, &size, nullptr));
    std::vector<uint8_t> bytes(size);
    check(vkGetPipelineCacheData(device, cache, &size, bytes.data()));
    bytes.resize(size);
    return bytes;
}
static VkPipelineCache load(VkDevice device, const std::vector<uint8_t>& bytes) {
    VkPipelineCacheCreateInfo info{VK_STRUCTURE_TYPE_PIPELINE_CACHE_CREATE_INFO};
    info.initialDataSize = bytes.size();
    info.pInitialData = bytes.data();
    VkPipelineCache cache;
    check(vkCreatePipelineCache(device, &info, nullptr, &cache));
    return cache;
}
int main(int argc, char** argv) {
    assert(argc == 2);
    VkApplicationInfo app{VK_STRUCTURE_TYPE_APPLICATION_INFO};
    app.apiVersion = VK_API_VERSION_1_1;
    VkInstanceCreateInfo instanceInfo{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
    instanceInfo.pApplicationInfo = &app;
    VkInstance instance;
    check(vkCreateInstance(&instanceInfo, nullptr, &instance));
    puts("PASS vkCreateInstance: actual Debug Cereal validator");
    uint32_t count = 0;
    check(vkEnumeratePhysicalDevices(instance, &count, nullptr));
    assert(count);
    std::vector<VkPhysicalDevice> devices(count);
    check(vkEnumeratePhysicalDevices(instance, &count, devices.data()));
    vkGetPhysicalDeviceQueueFamilyProperties(devices[0], &count, nullptr);
    std::vector<VkQueueFamilyProperties> queues(count);
    vkGetPhysicalDeviceQueueFamilyProperties(devices[0], &count, queues.data());
    uint32_t family = 0;
    while (family < count && !(queues[family].queueFlags & VK_QUEUE_COMPUTE_BIT)) ++family;
    assert(family < count);
    float priority = 1;
    VkDeviceQueueCreateInfo queueInfo{VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};
    queueInfo.queueFamilyIndex = family;
    queueInfo.queueCount = 1;
    queueInfo.pQueuePriorities = &priority;
    const char* extension = VK_KHR_PORTABILITY_SUBSET_EXTENSION_NAME;
    VkDeviceCreateInfo deviceInfo{VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO};
    deviceInfo.queueCreateInfoCount = 1;
    deviceInfo.pQueueCreateInfos = &queueInfo;
    deviceInfo.enabledExtensionCount = 1;
    deviceInfo.ppEnabledExtensionNames = &extension;
    VkDevice device;
    check(vkCreateDevice(devices[0], &deviceInfo, nullptr, &device));
    VkPipelineCache cache = load(device, {});
    auto empty = data(device, cache);
    std::ifstream file(argv[1], std::ios::binary | std::ios::ate);
    assert(file && file.tellg() > 0 && file.tellg() % 4 == 0);
    std::vector<uint32_t> words(size_t(file.tellg()) / 4);
    file.seekg(0);
    assert(file.read(reinterpret_cast<char*>(words.data()), words.size() * 4));
    VkShaderModuleCreateInfo shaderInfo{VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO};
    shaderInfo.codeSize = words.size() * 4;
    shaderInfo.pCode = words.data();
    VkShaderModule shader;
    check(vkCreateShaderModule(device, &shaderInfo, nullptr, &shader));
    VkPipelineLayoutCreateInfo layoutInfo{VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};
    VkPipelineLayout layout;
    check(vkCreatePipelineLayout(device, &layoutInfo, nullptr, &layout));
    VkComputePipelineCreateInfo pipelineInfo{VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO};
    pipelineInfo.layout = layout;
    pipelineInfo.stage = {VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO};
    pipelineInfo.stage.stage = VK_SHADER_STAGE_COMPUTE_BIT;
    pipelineInfo.stage.module = shader;
    pipelineInfo.stage.pName = "main";
    VkPipeline pipeline;
    check(vkCreateComputePipelines(device, cache, 1, &pipelineInfo, nullptr, &pipeline));
    auto populated = data(device, cache);
    assert(populated.size() > empty.size());
    VkPipelineCache restored = load(device, populated);
    assert(data(device, restored) == populated);
    // A fresh shader module ensures the second creation exercises the restored cache.
    vkDestroyShaderModule(device, shader, nullptr);
    check(vkCreateShaderModule(device, &shaderInfo, nullptr, &shader));
    pipelineInfo.stage.module = shader;
    VkPipeline second;
    check(vkCreateComputePipelines(device, restored, 1, &pipelineInfo, nullptr, &second));
    assert(data(device, restored) == populated);
    VkCommandPoolCreateInfo poolInfo{VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};
    poolInfo.queueFamilyIndex = family;
    VkCommandPool pool;
    check(vkCreateCommandPool(device, &poolInfo, nullptr, &pool));
    VkCommandBufferAllocateInfo allocation{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
    allocation.commandPool = pool;
    allocation.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    allocation.commandBufferCount = 1;
    VkCommandBuffer command;
    check(vkAllocateCommandBuffers(device, &allocation, &command));
    VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
    check(vkBeginCommandBuffer(command, &begin));
    vkCmdBindPipeline(command, VK_PIPELINE_BIND_POINT_COMPUTE, second);
    vkCmdDispatch(command, 1, 1, 1);
    check(vkEndCommandBuffer(command));
    VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO};
    submit.commandBufferCount = 1;
    submit.pCommandBuffers = &command;
    VkFenceCreateInfo fenceInfo{VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
    VkFence fence;
    check(vkCreateFence(device, &fenceInfo, nullptr, &fence));
    VkQueue queue;
    vkGetDeviceQueue(device, family, 0, &queue);
    check(vkQueueSubmit(queue, 1, &submit, fence));
    check(vkWaitForFences(device, 1, &fence, VK_TRUE, 5000000000));
    vkDestroyFence(device, fence, nullptr);
    vkDestroyCommandPool(device, pool, nullptr);
    printf("PASS populated cache reload and Metal compute dispatch: %zu bytes\n", populated.size());
    uint32_t headerSize = 0;
    memcpy(&headerSize, empty.data(), 4);
    assert(headerSize == 32 && empty.size() == headerSize + 8);
    auto reject = [&](std::vector<uint8_t> bytes, const char* label) {
        VkPipelineCache ignored = load(device, bytes);
        assert(data(device, ignored) == empty);
        vkDestroyPipelineCache(device, ignored, nullptr);
        printf("PASS ignored %s\n", label);
    };
    auto legacyEmpty = empty;
    legacyEmpty.erase(legacyEmpty.begin() + headerSize, legacyEmpty.begin() + headerSize + 4);
    reject(legacyEmpty, "unversioned empty cache");
    auto legacyEntry = populated;
    legacyEntry.erase(legacyEntry.begin() + headerSize, legacyEntry.begin() + headerSize + 4);
    // Poison the old entry: the new reader must return before reading its body.
    legacyEntry.resize(headerSize + 12, 0xff);
    reject(legacyEntry, "unversioned library entry before payload parsing");
    auto future = populated;
    future[headerSize] ^= 0x80;
    reject(future, "unknown future schema");
    auto shortHeader = empty;
    shortHeader.resize(headerSize + 4);
    reject(shortHeader, "schema without first entry");
    vkDestroyPipeline(device, second, nullptr);
    vkDestroyPipeline(device, pipeline, nullptr);
    vkDestroyShaderModule(device, shader, nullptr);
    vkDestroyPipelineLayout(device, layout, nullptr);
    vkDestroyPipelineCache(device, restored, nullptr);
    vkDestroyPipelineCache(device, cache, nullptr);
    vkDestroyDevice(device, nullptr);
    vkDestroyInstance(instance, nullptr);
}
