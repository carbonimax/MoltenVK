// Copyright (c) 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
// Device loss oracles. The loss comes from mvkTestMarkDeviceLost(), which a MoltenVK test build exports
// (PerVertexTES/EnableTestDevice.mm) and which loses the device as an encoder does; the test chooses its moment.
// Every mode keeps a submission C whose Metal wait only the loss rescue satisfies.
//
// counter-race: a host thread reads a timeline semaphore while the device is lost. The read is held inside the
//   imported event's signaledValue getter until the rescue has raised the counter to a value no work signaled.
//   Exit 0 when vkGetSemaphoreCounterValue reports the loss, 1 when it reports success with that value.
// binary-generation: C waits an imported binary semaphore; an external Metal command buffer waits the event at the
//   next generation, which only a later Vulkan signal may reach. Exit 0 when the external work stays blocked after
//   the loss is reported and C completes, 1 when the rescue releases the external work.
// destroy-after-loss: C reads an application buffer with long GPU copies. When the host wait reports the loss, the
//   test destroys that buffer at once. Exit 0 when C either completed before the report or never ran, 1 when C had
//   started and not finished when the loss was reported.
// Exit 2 for a setup failure, 3 when the device lacks a capability.
#import <Metal/Metal.h>
#include <objc/runtime.h>
#include <vulkan/vulkan.h>
#include <vulkan/vulkan_metal.h>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <pthread.h>
#include <string>
#include <thread>
#include <vector>

namespace {

constexpr uint32_t kMarker = 0xA55A5AA5;

void check(VkResult result, const char* step) {
	if (result != VK_SUCCESS) { std::fprintf(stderr, "%s: %d\n", step, int(result)); std::exit(2); }
}

void sleepMs(int ms) { std::this_thread::sleep_for(std::chrono::milliseconds(ms)); }

struct Buffer {
	VkBuffer buffer = VK_NULL_HANDLE;
	VkDeviceMemory memory = VK_NULL_HANDLE;
	volatile uint32_t* mapped = nullptr;
};

struct Context {
	VkInstance instance = VK_NULL_HANDLE;
	VkPhysicalDevice physical = VK_NULL_HANDLE;
	VkDevice device = VK_NULL_HANDLE;
	VkQueue qa = VK_NULL_HANDLE, qb = VK_NULL_HANDLE;
	uint32_t familyA = 0, familyB = 0;
	id<MTLDevice> mtlDevice = nil;
	void (*markLost)(VkDevice) = nullptr;

	Buffer buffer(VkDeviceSize size, bool hostVisible) {
		Buffer b;
		VkBufferCreateInfo info{VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO};
		info.size = size;
		info.usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT;
		check(vkCreateBuffer(device, &info, nullptr, &b.buffer), "vkCreateBuffer");
		VkMemoryRequirements requirements;
		vkGetBufferMemoryRequirements(device, b.buffer, &requirements);
		VkPhysicalDeviceMemoryProperties properties;
		vkGetPhysicalDeviceMemoryProperties(physical, &properties);
		VkMemoryPropertyFlags wanted = hostVisible ? VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT : VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT;
		uint32_t type = UINT32_MAX;
		for (uint32_t i = 0; i < properties.memoryTypeCount && type == UINT32_MAX; ++i) {
			if ((requirements.memoryTypeBits & (1u << i)) && (properties.memoryTypes[i].propertyFlags & wanted) == wanted) { type = i; }
		}
		if (type == UINT32_MAX) { std::fprintf(stderr, "No memory type\n"); std::exit(3); }
		VkMemoryAllocateInfo allocation{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
		allocation.allocationSize = requirements.size;
		allocation.memoryTypeIndex = type;
		check(vkAllocateMemory(device, &allocation, nullptr, &b.memory), "vkAllocateMemory");
		check(vkBindBufferMemory(device, b.buffer, b.memory, 0), "vkBindBufferMemory");
		if (hostVisible) {
			void* data = nullptr;
			check(vkMapMemory(device, b.memory, 0, VK_WHOLE_SIZE, 0, &data), "vkMapMemory");
			b.mapped = static_cast<volatile uint32_t*>(data);
			std::memset(data, 0, size);
		}
		return b;
	}

	void destroy(Buffer& b) {
		if (b.mapped) { vkUnmapMemory(device, b.memory); }
		vkDestroyBuffer(device, b.buffer, nullptr);
		vkFreeMemory(device, b.memory, nullptr);
		b = Buffer{};
	}
};

Context createContext() {
	Context c;
	const char* portability = VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME;
	uint32_t extensionCount = 0;
	check(vkEnumerateInstanceExtensionProperties(nullptr, &extensionCount, nullptr), "instance extensions(count)");
	std::vector<VkExtensionProperties> instanceExtensions(extensionCount);
	check(vkEnumerateInstanceExtensionProperties(nullptr, &extensionCount, instanceExtensions.data()), "instance extensions");
	bool hasPortability = false;
	for (const auto& available : instanceExtensions) { hasPortability |= std::strcmp(available.extensionName, portability) == 0; }
	VkApplicationInfo app{VK_STRUCTURE_TYPE_APPLICATION_INFO};
	app.apiVersion = VK_API_VERSION_1_2;
	VkInstanceCreateInfo instanceInfo{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
	instanceInfo.flags = hasPortability ? VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR : 0;
	instanceInfo.pApplicationInfo = &app;
	instanceInfo.enabledExtensionCount = hasPortability ? 1 : 0;
	instanceInfo.ppEnabledExtensionNames = hasPortability ? &portability : nullptr;
	check(vkCreateInstance(&instanceInfo, nullptr, &c.instance), "vkCreateInstance");
	uint32_t count = 1;
	VkResult enumerated = vkEnumeratePhysicalDevices(c.instance, &count, &c.physical);
	if ((enumerated != VK_SUCCESS && enumerated != VK_INCOMPLETE) || !count) { std::fprintf(stderr, "No Vulkan device\n"); std::exit(3); }
	uint32_t familyCount = 0;
	vkGetPhysicalDeviceQueueFamilyProperties(c.physical, &familyCount, nullptr);
	std::vector<VkQueueFamilyProperties> families(familyCount);
	vkGetPhysicalDeviceQueueFamilyProperties(c.physical, &familyCount, families.data());
	c.familyA = c.familyB = UINT32_MAX;
	for (uint32_t i = 0; i < familyCount && c.familyB == UINT32_MAX; ++i) {
		if (!families[i].queueCount) { continue; }
		if (c.familyA == UINT32_MAX) { c.familyA = i; } else { c.familyB = i; }
	}
	if (c.familyB == UINT32_MAX && c.familyA != UINT32_MAX && families[c.familyA].queueCount >= 2) { c.familyB = c.familyA; }
	if (c.familyB == UINT32_MAX) { std::fprintf(stderr, "Need two Vulkan queues\n"); std::exit(3); }
	float priorities[] = {1.0f, 1.0f};
	VkDeviceQueueCreateInfo queues[2] = {{VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO}, {VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO}};
	queues[0].queueFamilyIndex = c.familyA;
	queues[0].queueCount = c.familyA == c.familyB ? 2 : 1;
	queues[0].pQueuePriorities = priorities;
	queues[1].queueFamilyIndex = c.familyB;
	queues[1].queueCount = 1;
	queues[1].pQueuePriorities = priorities;
	VkPhysicalDeviceTimelineSemaphoreFeatures timeline{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TIMELINE_SEMAPHORE_FEATURES};
	timeline.timelineSemaphore = VK_TRUE;
	const char* extensions[] = {VK_EXT_METAL_OBJECTS_EXTENSION_NAME, "VK_KHR_portability_subset"};
	VkDeviceCreateInfo deviceInfo{VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO};
	deviceInfo.pNext = &timeline;
	deviceInfo.queueCreateInfoCount = c.familyA == c.familyB ? 1 : 2;
	deviceInfo.pQueueCreateInfos = queues;
	deviceInfo.enabledExtensionCount = 2;
	deviceInfo.ppEnabledExtensionNames = extensions;
	check(vkCreateDevice(c.physical, &deviceInfo, nullptr, &c.device), "vkCreateDevice");
	vkGetDeviceQueue(c.device, c.familyA, 0, &c.qa);
	vkGetDeviceQueue(c.device, c.familyB, c.familyA == c.familyB ? 1 : 0, &c.qb);
	VkExportMetalDeviceInfoEXT metalDevice{VK_STRUCTURE_TYPE_EXPORT_METAL_DEVICE_INFO_EXT};
	VkExportMetalObjectsInfoEXT exportInfo{VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECTS_INFO_EXT};
	exportInfo.pNext = &metalDevice;
	vkExportMetalObjectsEXT(c.device, &exportInfo);
	c.mtlDevice = metalDevice.mtlDevice;
	c.markLost = reinterpret_cast<void (*)(VkDevice)>(dlsym(RTLD_DEFAULT, "mvkTestMarkDeviceLost"));
	if (!c.mtlDevice || !c.markLost) { std::fprintf(stderr, "Needs a MoltenVK test build with mvkTestMarkDeviceLost\n"); std::exit(3); }
	return c;
}

VkSemaphore importedSemaphore(Context& c, id<MTLSharedEvent> event, bool timeline) {
	VkImportMetalSharedEventInfoEXT imported{VK_STRUCTURE_TYPE_IMPORT_METAL_SHARED_EVENT_INFO_EXT};
	imported.mtlSharedEvent = event;
	VkSemaphoreTypeCreateInfo type{VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO};
	type.semaphoreType = VK_SEMAPHORE_TYPE_TIMELINE;
	type.initialValue = event.signaledValue;
	if (timeline) { imported.pNext = &type; }
	VkSemaphoreCreateInfo info{VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
	info.pNext = &imported;
	VkSemaphore semaphore;
	check(vkCreateSemaphore(c.device, &info, nullptr, &semaphore), "vkCreateSemaphore");
	return semaphore;
}

// A submission on queue B that waits the semaphore (at waitValue for a timeline), then records its commands.
template <typename Record>
VkFence submitWaiting(Context& c, VkCommandPool pool, VkSemaphore semaphore, uint64_t waitValue, Record record) {
	VkCommandBufferAllocateInfo allocation{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
	allocation.commandPool = pool;
	allocation.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
	allocation.commandBufferCount = 1;
	VkCommandBuffer commands;
	check(vkAllocateCommandBuffers(c.device, &allocation, &commands), "vkAllocateCommandBuffers");
	VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
	check(vkBeginCommandBuffer(commands, &begin), "vkBeginCommandBuffer");
	record(commands);
	check(vkEndCommandBuffer(commands), "vkEndCommandBuffer");
	VkFenceCreateInfo fenceInfo{VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
	VkFence fence;
	check(vkCreateFence(c.device, &fenceInfo, nullptr, &fence), "vkCreateFence");
	VkPipelineStageFlags stage = VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT;
	VkTimelineSemaphoreSubmitInfo values{VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO};
	values.waitSemaphoreValueCount = 1;
	values.pWaitSemaphoreValues = &waitValue;
	VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO};
	submit.pNext = &values;
	submit.waitSemaphoreCount = 1;
	submit.pWaitSemaphores = &semaphore;
	submit.pWaitDstStageMask = &stage;
	submit.commandBufferCount = 1;
	submit.pCommandBuffers = &commands;
	check(vkQueueSubmit(c.qb, 1, &submit, fence), "vkQueueSubmit C");
	return fence;
}

VkCommandPool commandPool(Context& c) {
	VkCommandPoolCreateInfo info{VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};
	info.queueFamilyIndex = c.familyB;	// C runs on queue B
	VkCommandPool pool;
	check(vkCreateCommandPool(c.device, &info, nullptr, &pool), "vkCreateCommandPool");
	return pool;
}

// counter-race: hold the reader inside the event's signaledValue getter until the rescue raised it.
id gHeldEvent = nil;
uint64_t gHeldTarget = 0;
std::atomic<bool> gHeldArmed{false}, gHeldInside{false};
pthread_t gHeldReader;
uint64_t (*gOriginalSignaledValue)(id, SEL) = nullptr;

uint64_t heldSignaledValue(id self, SEL command) {
	if (self == gHeldEvent && pthread_equal(pthread_self(), gHeldReader) && gHeldArmed.exchange(false)) {
		gHeldInside = true;
		auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
		while (gOriginalSignaledValue(self, command) < gHeldTarget && std::chrono::steady_clock::now() < deadline) { sleepMs(1); }
	}
	return gOriginalSignaledValue(self, command);
}

int counterRace(Context& c) {
	constexpr uint64_t kNeverSignaled = 5;
	id<MTLSharedEvent> event = [c.mtlDevice newSharedEvent];
	event.signaledValue = 0;
	VkSemaphore timeline = importedSemaphore(c, event, true);
	Buffer marker = c.buffer(64, true);
	VkCommandPool pool = commandPool(c);
	// C waits a value that no work signals: only the loss rescue can raise the counter there.
	VkFence fence = submitWaiting(c, pool, timeline, kNeverSignaled, [&](VkCommandBuffer cb) { vkCmdFillBuffer(cb, marker.buffer, 0, 4, kMarker); });
	sleepMs(100);
	uint64_t before = 0;
	check(vkGetSemaphoreCounterValue(c.device, timeline, &before), "counter before loss");

	Method getter = class_getInstanceMethod(object_getClass(event), @selector(signaledValue));
	gOriginalSignaledValue = reinterpret_cast<uint64_t (*)(id, SEL)>(method_getImplementation(getter));
	gHeldEvent = event;
	gHeldTarget = kNeverSignaled;
	method_setImplementation(getter, reinterpret_cast<IMP>(heldSignaledValue));
	VkResult readResult = VK_NOT_READY;
	uint64_t readValue = 0;
	std::thread reader([&] {
		gHeldReader = pthread_self();
		gHeldArmed = true;
		readResult = vkGetSemaphoreCounterValue(c.device, timeline, &readValue);
	});
	auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
	while (!gHeldInside && std::chrono::steady_clock::now() < deadline) { sleepMs(1); }
	if (!gHeldInside) {
		// The reader never read the counter before the loss (it reported the loss beforehand): nothing was held.
		std::fprintf(stderr, "reader did not reach the counter read\n");
	}
	c.markLost(c.device);
	reader.join();
	method_setImplementation(getter, reinterpret_cast<IMP>(gOriginalSignaledValue));
	VkResult fenceResult = vkWaitForFences(c.device, 1, &fence, VK_TRUE, 5000000000ull);
	std::printf("counter_before=%llu held=%d read=%d value=%llu metal_value=%llu fence_C=%d marker_C=%08x\n",
				(unsigned long long)before, int(gHeldInside.load()), int(readResult), (unsigned long long)readValue,
				(unsigned long long)event.signaledValue, int(fenceResult), marker.mapped[0]);
	bool reportedRescuedValue = readResult == VK_SUCCESS && readValue >= kNeverSignaled;
	if (reportedRescuedValue) { std::printf("COUNTER_RACE FAIL: success reported for a value no work signaled\n"); }
	else if (readResult == VK_ERROR_DEVICE_LOST) { std::printf("COUNTER_RACE PASS: loss reported\n"); }
	else { std::printf("COUNTER_RACE FAIL: unexpected result\n"); }
	vkDestroyFence(c.device, fence, nullptr);
	vkDestroyCommandPool(c.device, pool, nullptr);
	c.destroy(marker);
	vkDestroySemaphore(c.device, timeline, nullptr);
	[event release];
	return readResult == VK_ERROR_DEVICE_LOST && gHeldInside ? 0 : 1;
}

int binaryGeneration(Context& c) {
	id<MTLSharedEvent> event = [c.mtlDevice newSharedEvent];
	event.signaledValue = 40;
	VkSemaphore binary = importedSemaphore(c, event, false);
	Buffer marker = c.buffer(64, true);
	VkCommandPool pool = commandPool(c);
	// C's wait is at 41, the value after the imported one; no Vulkan signal of this semaphore follows.
	VkFence fence = submitWaiting(c, pool, binary, 0, [&](VkCommandBuffer cb) { vkCmdFillBuffer(cb, marker.buffer, 0, 4, kMarker); });
	sleepMs(100);
	// An external Metal client waits the next generation, 42: the value of the next Vulkan signal of this semaphore.
	id<MTLBuffer> externalMarker = [c.mtlDevice newBufferWithLength:64 options:MTLResourceStorageModeShared];
	std::memset(externalMarker.contents, 0, 64);
	id<MTLCommandQueue> externalQueue = [c.mtlDevice newCommandQueue];
	id<MTLCommandBuffer> external = [externalQueue commandBuffer];
	[external encodeWaitForEvent:event value:42];
	id<MTLBlitCommandEncoder> blit = [external blitCommandEncoder];
	[blit fillBuffer:externalMarker range:NSMakeRange(0, 4) value:0xA5];
	[blit endEncoding];
	std::atomic<bool> externalDone{false};
	std::atomic<bool>* done = &externalDone;
	[external addCompletedHandler:^(id<MTLCommandBuffer>) { *done = true; }];
	[external commit];
	sleepMs(100);
	uint32_t externalBefore = static_cast<const uint32_t*>(externalMarker.contents)[0];
	c.markLost(c.device);
	VkResult fenceResult = vkWaitForFences(c.device, 1, &fence, VK_TRUE, 5000000000ull);
	sleepMs(300);
	uint32_t externalAfter = static_cast<const uint32_t*>(externalMarker.contents)[0];
	uint64_t metalValue = event.signaledValue;
	std::printf("external_before=%08x fence_C=%d marker_C=%08x metal_value=%llu external_after_loss=%08x\n",
				externalBefore, int(fenceResult), marker.mapped[0], (unsigned long long)metalValue, externalAfter);
	bool released = externalAfter != 0;
	bool completedC = marker.mapped[0] == kMarker;
	std::printf("BINARY_GENERATION %s: external next generation %s, C %s\n", !released && completedC ? "PASS" : "FAIL",
				released ? "released by the rescue" : "still blocked", completedC ? "released and completed" : "not completed");
	// Teardown: release the external client, as a later Vulkan signal would.
	if (event.signaledValue < 42) { event.signaledValue = 42; }
	auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
	while (!externalDone && std::chrono::steady_clock::now() < deadline) { sleepMs(1); }
	vkDestroyFence(c.device, fence, nullptr);
	vkDestroyCommandPool(c.device, pool, nullptr);
	c.destroy(marker);
	vkDestroySemaphore(c.device, binary, nullptr);
	[externalQueue release];	// the command buffer is autoreleased
	[externalMarker release];
	[event release];
	return !released && completedC && fenceResult == VK_ERROR_DEVICE_LOST ? 0 : 1;
}

int destroyAfterLoss(Context& c) {
	constexpr VkDeviceSize kSize = 256ull << 20;
	constexpr int kCopies = 48;
	id<MTLSharedEvent> event = [c.mtlDevice newSharedEvent];
	event.signaledValue = 0;
	VkSemaphore binary = importedSemaphore(c, event, false);
	Buffer source = c.buffer(kSize, false);
	Buffer target = c.buffer(kSize, false);
	Buffer markers = c.buffer(64, true);
	VkCommandPool pool = commandPool(c);
	VkFence fence = submitWaiting(c, pool, binary, 0, [&](VkCommandBuffer cb) {
		vkCmdFillBuffer(cb, markers.buffer, 0, 4, kMarker);
		VkMemoryBarrier barrier{VK_STRUCTURE_TYPE_MEMORY_BARRIER};
		barrier.srcAccessMask = barrier.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT | VK_ACCESS_TRANSFER_READ_BIT;
		VkBufferCopy region{0, 0, kSize};
		for (int i = 0; i < kCopies; ++i) {
			vkCmdCopyBuffer(cb, source.buffer, target.buffer, 1, &region);
			vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 1, &barrier, 0, nullptr, 0, nullptr);
		}
		vkCmdFillBuffer(cb, markers.buffer, 4, 4, kMarker);
	});
	sleepMs(100);
	uint32_t startBeforeLoss = markers.mapped[0];
	c.markLost(c.device);
	VkResult fenceResult = vkWaitForFences(c.device, 1, &fence, VK_TRUE, 10000000000ull);
	uint32_t startAtReport = markers.mapped[0], endAtReport = markers.mapped[1];
	// The application may destroy what the lost submission used once a host wait reported the loss.
	c.destroy(source);
	uint32_t startLater = startAtReport, endLater = endAtReport;
	for (int i = 0; i < 200; ++i) {
		sleepMs(10);
		startLater = markers.mapped[0];
		endLater = markers.mapped[1];
	}
	bool inFlightAtReport = endAtReport != kMarker && startLater == kMarker;
	std::printf("start_before_loss=%08x fence_C=%d at_report: start=%08x end=%08x later: start=%08x end=%08x\n",
				startBeforeLoss, int(fenceResult), startAtReport, endAtReport, startLater, endLater);
	std::printf("DESTROY_AFTER_LOSS %s: C %s when the loss was reported\n", inFlightAtReport ? "FAIL" : "PASS",
				inFlightAtReport ? "was still running" : endAtReport == kMarker ? "had completed" : "never ran");
	vkDestroyFence(c.device, fence, nullptr);
	vkDestroyCommandPool(c.device, pool, nullptr);
	c.destroy(target);
	c.destroy(markers);
	vkDestroySemaphore(c.device, binary, nullptr);
	[event release];
	return !inFlightAtReport && fenceResult == VK_ERROR_DEVICE_LOST ? 0 : 1;
}

}  // namespace

int main(int argc, char** argv) {
	std::string mode = argc == 2 ? argv[1] : "";
	if (mode != "counter-race" && mode != "binary-generation" && mode != "destroy-after-loss") {
		std::fprintf(stderr, "usage: %s counter-race|binary-generation|destroy-after-loss\n", argv[0]);
		return 64;
	}
	@autoreleasepool {
		Context c = createContext();
		int rc = mode == "counter-race" ? counterRace(c) : mode == "binary-generation" ? binaryGeneration(c) : destroyAfterLoss(c);
		std::fflush(stdout);
		// The device is lost: destroying it is still valid, idle waits would only report the loss.
		vkDestroyDevice(c.device, nullptr);
		vkDestroyInstance(c.instance, nullptr);
		return rc;
	}
}
