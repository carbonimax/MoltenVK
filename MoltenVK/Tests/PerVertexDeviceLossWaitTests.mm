// Copyright 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
// Standalone regression for device-loss waiter registration and persistent cancellation.
#include "MVKSync.h"
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <future>
#include <vector>

static void require(bool condition, const char* message) {
	if (!condition) { std::fprintf(stderr, "%s\n", message); std::abort(); }
}

int main() {
#ifndef MVK_TEST_OLD_LIBRARY
	MVKSemaphoreImpl pending(true, 2);
	auto blockerWaiter = std::async(std::launch::async, [&] { return pending.wait(UINT64_MAX); });
	require(blockerWaiter.wait_for(std::chrono::milliseconds(20)) == std::future_status::timeout, "Blocker was not pending");
	pending.cancel();
	require(blockerWaiter.wait_for(std::chrono::seconds(1)) == std::future_status::ready && blockerWaiter.get(), "Cancellation did not release the blocker");
	pending.reserve();
	require(pending.wait(0, true) && !pending.isReserved(), "Reservation after cancellation blocked");
#endif
	VkInstance instance = VK_NULL_HANDLE;
	VkInstanceCreateInfo instanceInfo{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
	require(vkCreateInstance(&instanceInfo, nullptr, &instance) == VK_SUCCESS, "Create instance failed");
	uint32_t deviceCount = 0;
	require(vkEnumeratePhysicalDevices(instance, &deviceCount, nullptr) == VK_SUCCESS && deviceCount, "No physical device");
	std::vector<VkPhysicalDevice> physicalDevices(deviceCount);
	require(vkEnumeratePhysicalDevices(instance, &deviceCount, physicalDevices.data()) == VK_SUCCESS, "Enumerate devices failed");
	uint32_t familyCount = 0;
	vkGetPhysicalDeviceQueueFamilyProperties(physicalDevices[0], &familyCount, nullptr);
	require(familyCount, "No queue family");
	std::vector<VkQueueFamilyProperties> families(familyCount);
	vkGetPhysicalDeviceQueueFamilyProperties(physicalDevices[0], &familyCount, families.data());
	uint32_t family = 0;
	while (family < familyCount && !families[family].queueCount) ++family;
	require(family < familyCount, "No usable queue family");
	float priority = 1;
	VkDeviceQueueCreateInfo queueInfo{VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};
	queueInfo.queueFamilyIndex = family;
	queueInfo.queueCount = 1;
	queueInfo.pQueuePriorities = &priority;
	VkDeviceCreateInfo deviceInfo{VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO};
	deviceInfo.queueCreateInfoCount = 1;
	deviceInfo.pQueueCreateInfos = &queueInfo;
	VkDevice device = VK_NULL_HANDLE;
	require(vkCreateDevice(physicalDevices[0], &deviceInfo, nullptr, &device) == VK_SUCCESS, "Create device failed");
	VkFenceCreateInfo fenceInfo{VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
	VkFence fences[2] = {};
	require(vkCreateFence(device, &fenceInfo, nullptr, &fences[0]) == VK_SUCCESS, "Create fence 0 failed");
	require(vkCreateFence(device, &fenceInfo, nullptr, &fences[1]) == VK_SUCCESS, "Create fence 1 failed");
	MVKFenceSitter active(true);
	for (auto fence : fences) ((MVKFence*)fence)->addSitter(&active);
	auto activeWaiter = std::async(std::launch::async, [&] { return active.wait(UINT64_MAX); });
	require(activeWaiter.wait_for(std::chrono::milliseconds(20)) == std::future_status::timeout, "Registered sitter was not pending");
	auto apiWaiter = std::async(std::launch::async, [&] { return vkWaitForFences(device, 2, fences, VK_TRUE, UINT64_MAX); });
	require(apiWaiter.wait_for(std::chrono::milliseconds(20)) == std::future_status::timeout, "Vulkan fence wait was not pending");
	auto* mvkDevice = MVKDevice::getMVKDevice(device);
	require(mvkDevice->markLost(false) == VK_ERROR_DEVICE_LOST, "Mark lost failed");
	require(activeWaiter.wait_for(std::chrono::seconds(1)) == std::future_status::ready && activeWaiter.get(), "Registered sitter did not finish");
	require(apiWaiter.wait_for(std::chrono::seconds(1)) == std::future_status::ready && apiWaiter.get() == VK_ERROR_DEVICE_LOST, "Vulkan fence wait did not report device loss");
	for (auto fence : fences) ((MVKFence*)fence)->removeSitter(&active);
	MVKSemaphoreImpl late(true, 0);
	mvkDevice->addSemaphore(&late);
	late.reserve();
	require(late.wait(0), "Registration after device loss blocked");
	mvkDevice->removeSemaphore(&late);
	for (auto fence : fences) vkDestroyFence(device, fence, nullptr);
	vkDestroyDevice(device, nullptr);
	vkDestroyInstance(instance, nullptr);
	std::puts("PERVERTEX_DEVICE_LOSS_WAIT PASS");
}
