// Copyright 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
// Regression oracles for a legal two-queue binary semaphore order and reuse after an external Metal signal.
// Import an MTLSharedEvent so a failed Metal wait can be released during teardown. PERVERTEX_BINARY_NO_IMPORT=1 keeps
// the semaphore MoltenVK's own, for semaphore styles that refuse an imported event (CPU callbacks).
#import <Metal/Metal.h>
#include <vulkan/vulkan.h>
#include <vulkan/vulkan_metal.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

static void check(VkResult result, const char* step) {
    if (result != VK_SUCCESS) { std::fprintf(stderr, "%s: %d\n", step, int(result)); std::exit(2); }
}

static VkResult submit(VkQueue queue, std::vector<VkSemaphore> waits, std::vector<uint64_t> waitValues,
                       std::vector<VkSemaphore> signals, std::vector<uint64_t> signalValues, VkFence fence = VK_NULL_HANDLE) {
    std::vector<VkPipelineStageFlags> stages(waits.size(), VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT);
    VkTimelineSemaphoreSubmitInfo values{VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO};
    values.waitSemaphoreValueCount = uint32_t(waitValues.size());
    values.pWaitSemaphoreValues = waitValues.data();
    values.signalSemaphoreValueCount = uint32_t(signalValues.size());
    values.pSignalSemaphoreValues = signalValues.data();
    VkSubmitInfo info{VK_STRUCTURE_TYPE_SUBMIT_INFO};
    info.pNext = &values;
    info.waitSemaphoreCount = uint32_t(waits.size());
    info.pWaitSemaphores = waits.data();
    info.pWaitDstStageMask = stages.data();
    info.signalSemaphoreCount = uint32_t(signals.size());
    info.pSignalSemaphores = signals.data();
    return vkQueueSubmit(queue, 1, &info, fence);
}

int main(int argc, char** argv) {
    const bool externalReuse = argc == 2 && std::strcmp(argv[1], "--imported-reuse") == 0;
    if (argc > 2 || (argc == 2 && !externalReuse)) {
        std::fprintf(stderr, "usage: %s [--imported-reuse]\n", argv[0]);
        return 64;
    }
    const char* extension = VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME;
    uint32_t extensionCount = 0;
    check(vkEnumerateInstanceExtensionProperties(nullptr, &extensionCount, nullptr), "instance extensions(count)");
    std::vector<VkExtensionProperties> extensions(extensionCount);
    check(vkEnumerateInstanceExtensionProperties(nullptr, &extensionCount, extensions.data()), "instance extensions");
    bool portability = false;
    for (const auto& available : extensions) portability |= std::strcmp(available.extensionName, extension) == 0;
    VkApplicationInfo app{VK_STRUCTURE_TYPE_APPLICATION_INFO};
    app.apiVersion = VK_API_VERSION_1_2;
    VkInstanceCreateInfo instanceInfo{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
    instanceInfo.flags = portability ? VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR : 0;
    instanceInfo.pApplicationInfo = &app;
    instanceInfo.enabledExtensionCount = portability ? 1 : 0;
    instanceInfo.ppEnabledExtensionNames = portability ? &extension : nullptr;
    VkInstance instance;
    check(vkCreateInstance(&instanceInfo, nullptr, &instance), "vkCreateInstance");
    uint32_t deviceCount = 0;
    check(vkEnumeratePhysicalDevices(instance, &deviceCount, nullptr), "vkEnumeratePhysicalDevices(count)");
    if (!deviceCount) { std::fprintf(stderr, "No Vulkan device\n"); return 3; }
    std::vector<VkPhysicalDevice> devices(deviceCount);
    check(vkEnumeratePhysicalDevices(instance, &deviceCount, devices.data()), "vkEnumeratePhysicalDevices");
    VkPhysicalDevice physical = devices[0];
    uint32_t deviceExtensionCount = 0;
    check(vkEnumerateDeviceExtensionProperties(physical, nullptr, &deviceExtensionCount, nullptr), "device extensions(count)");
    std::vector<VkExtensionProperties> deviceExtensions(deviceExtensionCount);
    check(vkEnumerateDeviceExtensionProperties(physical, nullptr, &deviceExtensionCount, deviceExtensions.data()), "device extensions");
    uint32_t familyCount = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(physical, &familyCount, nullptr);
    std::vector<VkQueueFamilyProperties> families(familyCount);
    vkGetPhysicalDeviceQueueFamilyProperties(physical, &familyCount, families.data());
    uint32_t familyA = UINT32_MAX, familyB = UINT32_MAX;
    for (uint32_t i = 0; i < familyCount; ++i) {
        if (!families[i].queueCount) continue;
        if (familyA == UINT32_MAX) familyA = i;
        else { familyB = i; break; }
    }
    if (familyB == UINT32_MAX && familyA != UINT32_MAX && families[familyA].queueCount >= 2) familyB = familyA;
    if (familyB == UINT32_MAX) { std::fprintf(stderr, "Need two Vulkan queues\n"); return 3; }
    float priorities[] = {1.0f, 1.0f};
    VkDeviceQueueCreateInfo queueInfoA{VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};
    queueInfoA.queueFamilyIndex = familyA;
    queueInfoA.queueCount = familyA == familyB ? 2 : 1;
    queueInfoA.pQueuePriorities = priorities;
    VkDeviceQueueCreateInfo queueInfoB = queueInfoA;
    queueInfoB.queueFamilyIndex = familyB;
    queueInfoB.queueCount = 1;
    VkPhysicalDeviceTimelineSemaphoreFeatures timeline{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TIMELINE_SEMAPHORE_FEATURES};
    VkPhysicalDeviceFeatures2 featureQuery{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2};
    featureQuery.pNext = &timeline;
    vkGetPhysicalDeviceFeatures2(physical, &featureQuery);
    if (!timeline.timelineSemaphore) { std::fprintf(stderr, "Timeline semaphores unavailable\n"); return 3; }
    const char* subset = "VK_KHR_portability_subset";
    const char* metalObjects = VK_EXT_METAL_OBJECTS_EXTENSION_NAME;
    bool portabilitySubset = false;
    for (const auto& available : deviceExtensions) portabilitySubset |= std::strcmp(available.extensionName, subset) == 0;
    bool metalObjectsAvailable = false;
    for (const auto& available : deviceExtensions) metalObjectsAvailable |= std::strcmp(available.extensionName, metalObjects) == 0;
    if (!metalObjectsAvailable) { std::fprintf(stderr, "VK_EXT_metal_objects unavailable\n"); return 3; }
    VkDeviceCreateInfo deviceInfo{VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO};
    deviceInfo.pNext = &timeline;
    deviceInfo.queueCreateInfoCount = familyA == familyB ? 1 : 2;
    VkDeviceQueueCreateInfo queueInfos[] = {queueInfoA, queueInfoB};
    deviceInfo.pQueueCreateInfos = queueInfos;
    const char* enabledExtensions[] = {metalObjects, subset};
    deviceInfo.enabledExtensionCount = portabilitySubset ? 2 : 1;
    deviceInfo.ppEnabledExtensionNames = enabledExtensions;
    VkDevice device;
    check(vkCreateDevice(physical, &deviceInfo, nullptr, &device), "vkCreateDevice");
    VkQueue qa, qb;
    vkGetDeviceQueue(device, familyA, 0, &qa);
    vkGetDeviceQueue(device, familyB, familyA == familyB ? 1 : 0, &qb);
    VkExportMetalDeviceInfoEXT metalInfo{VK_STRUCTURE_TYPE_EXPORT_METAL_DEVICE_INFO_EXT};
    VkExportMetalObjectsInfoEXT exportInfo{VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECTS_INFO_EXT};
    exportInfo.pNext = &metalInfo;
    vkExportMetalObjectsEXT(device, &exportInfo);
    if (!metalInfo.mtlDevice) { std::fprintf(stderr, "No exported MTLDevice\n"); return 3; }
    id<MTLSharedEvent> sharedEvent = [metalInfo.mtlDevice newSharedEvent];
    if (!sharedEvent) { std::fprintf(stderr, "MTLSharedEvent unavailable\n"); return 3; }
    if (externalReuse) sharedEvent.signaledValue = 40;
    VkImportMetalSharedEventInfoEXT imported{VK_STRUCTURE_TYPE_IMPORT_METAL_SHARED_EVENT_INFO_EXT};
    imported.mtlSharedEvent = sharedEvent;
    VkSemaphoreCreateInfo binaryInfo{VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
    const bool noImport = getenv("PERVERTEX_BINARY_NO_IMPORT") != nullptr;
    if (!noImport) binaryInfo.pNext = &imported;
    VkSemaphoreTypeCreateInfo timelineType{VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO};
    timelineType.semaphoreType = VK_SEMAPHORE_TYPE_TIMELINE;
    VkSemaphoreCreateInfo timelineInfo{VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
    timelineInfo.pNext = &timelineType;
    VkSemaphore s, t, gate;
    check(vkCreateSemaphore(device, &binaryInfo, nullptr, &s), "binary semaphore");
    check(vkCreateSemaphore(device, &timelineInfo, nullptr, &t), "timeline T");
    check(vkCreateSemaphore(device, &timelineInfo, nullptr, &gate), "timeline gate");
    VkFenceCreateInfo fenceInfo{VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
    VkFence fb, fc, fd;
    check(vkCreateFence(device, &fenceInfo, nullptr, &fb), "fence B");
    check(vkCreateFence(device, &fenceInfo, nullptr, &fc), "fence C");
    check(vkCreateFence(device, &fenceInfo, nullptr, &fd), "fence D");

    if (externalReuse) {
        // The imported event starts at 40. Metal satisfies the first Vulkan wait at 41;
        // a later Vulkan signal must satisfy a second wait on the same binary semaphore.
        sharedEvent.signaledValue = 41;
        check(submit(qa, {s}, {0}, {}, {}, fc), "submit external wait");
        VkResult first = vkWaitForFences(device, 1, &fc, VK_TRUE, 2000000000ull);
        if (first != VK_SUCCESS) {
            sharedEvent.signaledValue = 1024; // Teardown only: release a stuck native wait.
            vkWaitForFences(device, 1, &fc, VK_TRUE, 1000000000ull);
            std::fprintf(stderr, "external wait failed: %d\n", int(first));
            return 1;
        }
        check(submit(qa, {}, {}, {s}, {0}, fb), "submit Vulkan signal");
        VkResult signalDone = vkWaitForFences(device, 1, &fb, VK_TRUE, 2000000000ull);
        if (signalDone != VK_SUCCESS) { std::fprintf(stderr, "Vulkan signal failed: %d\n", int(signalDone)); return 1; }
        check(submit(qa, {s}, {0}, {}, {}, fd), "submit Vulkan reuse wait");
        VkResult second = vkWaitForFences(device, 1, &fd, VK_TRUE, 500000000ull);
        bool rescued = second != VK_SUCCESS;
        if (rescued) {
            sharedEvent.signaledValue = 1024; // Teardown only; rescue is a test failure.
            second = vkWaitForFences(device, 1, &fd, VK_TRUE, 2000000000ull);
        }
        std::printf("external_wait=%d signal=%d reuse_wait=%d rescued=%d metal_value=%llu\n",
                    int(first), int(signalDone), int(second), int(rescued), (unsigned long long)sharedEvent.signaledValue);
        std::fflush(stdout);
        if (second != VK_SUCCESS) return 1; // Avoid an unbounded device-idle wait.
        check(vkDeviceWaitIdle(device), "vkDeviceWaitIdle");
        vkDestroyFence(device, fd, nullptr);
        vkDestroyFence(device, fc, nullptr);
        vkDestroyFence(device, fb, nullptr);
        vkDestroySemaphore(device, gate, nullptr);
        vkDestroySemaphore(device, t, nullptr);
        vkDestroySemaphore(device, s, nullptr);
        vkDestroyDevice(device, nullptr);
        [sharedEvent release];
        vkDestroyInstance(instance, nullptr);
        return rescued ? 1 : 0;
    }

    // Host order B,A,C,D. GPU order must be A,C,B,D. B stays behind the host gate
    // while D is checked: A's signal must not satisfy D's second wait on S.
    check(submit(qb, {t, gate}, {1, 1}, {s}, {0}, fb), "submit B");
    check(submit(qa, {}, {}, {s}, {0}), "submit A");
    check(submit(qa, {s}, {0}, {t}, {1}, fc), "submit C");
    check(submit(qa, {s}, {0}, {}, {}, fd), "submit D");
    VkResult c = vkWaitForFences(device, 1, &fc, VK_TRUE, 2000000000ull);
    bool rescuedC = c != VK_SUCCESS;
    if (rescuedC) {
        sharedEvent.signaledValue = 1024;
        c = vkWaitForFences(device, 1, &fc, VK_TRUE, 1000000000ull);
        if (c != VK_SUCCESS) { std::fprintf(stderr, "C remains blocked after rescue: %d\n", int(c)); return 1; }
    }
    VkResult dBeforeB = vkWaitForFences(device, 1, &fd, VK_TRUE, 500000000ull);
    VkResult bBeforeGate = vkGetFenceStatus(device, fb);
    std::printf("C=%d D_before_B=%d B_before_gate=%d (expected D timeout, B not ready)\n", int(c), int(dBeforeB), int(bBeforeGate));
    VkSemaphoreSignalInfo signal{VK_STRUCTURE_TYPE_SEMAPHORE_SIGNAL_INFO};
    signal.semaphore = gate;
    signal.value = 1;
    check(vkSignalSemaphore(device, &signal), "open gate");
    VkResult b = vkWaitForFences(device, 1, &fb, VK_TRUE, 2000000000ull);
    VkResult d = vkWaitForFences(device, 1, &fd, VK_TRUE, 500000000ull);
    bool rescued = d != VK_SUCCESS;
    if (rescued) {
        // Teardown only: release a stuck native Metal wait before it hits the GPU watchdog.
        sharedEvent.signaledValue = 1024;
        d = vkWaitForFences(device, 1, &fd, VK_TRUE, 2000000000ull);
    }
    std::printf("B=%d D_after_B=%d rescued=%d\n", int(b), int(d), int(rescued));
    std::fflush(stdout);
    if (b != VK_SUCCESS || d != VK_SUCCESS) return 1; // Avoid an unbounded device-idle wait.
    check(vkDeviceWaitIdle(device), "vkDeviceWaitIdle");
    vkDestroyFence(device, fd, nullptr);
    vkDestroyFence(device, fc, nullptr);
    vkDestroyFence(device, fb, nullptr);
    vkDestroySemaphore(device, gate, nullptr);
    vkDestroySemaphore(device, t, nullptr);
    vkDestroySemaphore(device, s, nullptr);
    vkDestroyDevice(device, nullptr);
    [sharedEvent release];
    vkDestroyInstance(instance, nullptr);
    return !rescuedC && dBeforeB == VK_TIMEOUT && bBeforeGate == VK_NOT_READY && !rescued ? 0 : 1;
}
