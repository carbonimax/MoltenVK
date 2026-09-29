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
// event-wait: C waits a VkEvent that the host sets only after submission, which Vulkan allows. A host wait must
//   report the loss while the event is still unset, and vkGetEventStatus must never report the event set by the
//   loss. Exit 0 when both hold, 1 when the wait times out or the event is reported set; the host then sets the
//   event, as the application would, so that the lost submission can end.
// teardown, teardown-multi, teardown-nil: every completion and scheduled handler that MoltenVK adds to a Metal command
//   buffer is delayed (PERVERTEX_LOSS_HANDLER_DELAY_US, 50 ms by default), which widens the window between the first
//   and the last handler of a command buffer. When the host wait reports the loss, the test counts the handlers of
//   committed command buffers that have not finished, then destroys every object and the device at once, and counts
//   the handlers that start after vkDestroyDevice() returned. Exit 0 when the loss is reported and both counts are
//   zero, 1 otherwise (a crash in a late handler also shows the defect).
//   - teardown: C waits a binary semaphore that only the loss rescue releases;
//   - teardown-multi: also C2 on the other queue, a fence-only submission, two command buffers in C (several Metal
//     command buffers under MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS=1), and a recorded command buffer never submitted,
//     freed after the loss (its prefilled Metal command buffer is committed then);
//   The counts are read at the return of the host wait itself: with a MoltenVK test build, MoltenVK's own counts of
//   pending handlers and encodings (mvkTestGetLossCounters), otherwise the handlers this test saw end.
//   - teardown-nil: Metal returns no command buffer while C is submitted, which must lose the device;
//   - teardown-nil-transient: Metal returns no command buffer once, then does again: C's commands, encoded without a
//     Metal command buffer, never run, so the loss must be reported all the same (marker_C shows whether C ran).
// external-queue-wait: the application commits, on the Metal command queue exported from queue B, a command buffer X
//   that waits a MTLSharedEvent unknown to MoltenVK, then submits C to queue B, behind X. After the loss, the host
//   waits 2 s for C's fence, then signals the event as the application eventually would, and checks when C ran.
//   Exit 0 when the loss is reported within 2 s and C never runs after that report; 1 otherwise, with
//   "LOSS_NOT_REPORTED" when the wait timed out, or "RAN_AFTER_REPORT" when C ran after the loss was reported.
//   No safe runtime meets both today (see the report): this mode reproduces that blocker.
// external-queue-wait-idle, external-queue-wait-query: the same, but the host wait has no timeout: vkQueueWaitIdle, or
//   vkGetQueryPoolResults with VK_QUERY_RESULT_WAIT_BIT on a timestamp C writes. The Lost Device section of the Vulkan
//   specification requires both to return in finite time, with VK_SUCCESS or VK_ERROR_DEVICE_LOST. The wait runs on a
//   thread, given 2 s; the outcomes and the exit code are those of external-queue-wait.
// shared-queue-block: a second VkDevice is created on the same physical device, and the test checks that its queue
//   exports the same MTLCommandQueue as queue B of the first. The application commits four command buffers that wait a
//   MTLSharedEvent to that Metal queue, and the first device is lost. The second device, healthy, then submits and waits
//   for a fence, on a thread given 2 s. Exit 0 when that submission completes; 1 with "SHARED_QUEUE BLOCKED" otherwise.
//   With MVK_CONFIG_MAX_ACTIVE_METAL_COMMAND_BUFFERS_PER_QUEUE=4 (the runner's setting), the four fill the Metal queue:
//   a synchronous vkQueueSubmit blocks acquiring a Metal command buffer. With more places, it returns, and the work waits
//   behind the first device's in the Metal queue's order. The line "submit_returned_in_2s" tells the two apart.
// timeline-listener-aba: no device loss. vkWaitSemaphores waits value n + 1 of an imported timeline semaphore for 10 ms
//   and times out, leaving its Metal event listener registered; a second vkWaitSemaphores from the same call site then
//   waits value n + 2, while another thread raises the event to n + 1 only. Exit 0 when the second wait never reports
//   success below n + 2, over 5 rounds; 1 when it does: the first listener, keyed by the address of a waiter that no
//   longer exists, woke the second one.
// prefill-abandon-reset, -free, -pool, and the same with -lost: under MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS=1, a
//   command buffer recorded with vkCmdUpdateBuffer, whose data MoltenVK copies to a pooled Metal buffer, is never
//   submitted, then reset, freed, or destroyed with its pool (after a device loss with -lost). Exit 0 when the update
//   never runs and no Metal handler of it runs after the cleanup call returned (its pooled buffer and pool may be gone);
//   1 otherwise, or a crash. With a MoltenVK test build (mvkTestGetOutstandingCommandPoolAllocations), the reset and
//   free variants also require the pooled buffer to return to its pool exactly once: one allocation outstanding after
//   recording, none after the cleanup, and still none after the command buffer is freed and its pool reset.
// metal-error, metal-error-multi: C's Metal command buffer reports an error (a page fault) once complete, and Metal
//   runs its handlers in reverse order, so that a completion handler may run before the error handler. C signals an
//   imported binary semaphore and a fence. With -multi, C holds two Metal command buffers (deferred prefill): the first
//   fails, and its handlers run 200 ms after those of the second. Exit 0 when the fence reports the loss and the
//   semaphore is never signalled; 1 when the failed work is reported complete.
// metal-error-batches, -batches2, -calls: the failed Metal command buffer is batch 1 of a vkQueueSubmit with two
//   batches (vkQueueSubmit2 with -batches2), or of a first vkQueueSubmit call followed by a second one on the same
//   queue (-calls). Only batch 2 has the fence, and signals the imported binary semaphore. Batch 1's handlers run
//   200 ms after batch 2's. A fence covers every batch submitted before it to its queue: exit 0 when it reports the
//   loss and the semaphore is never signalled; 1 when batch 2 reports complete work that batch 1's failure precedes.
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

// A device with queues A and B as createContext() chooses them; queue B has the same family and index on every device.
VkDevice createLogicalDevice(const Context& c, VkQueue* qa, VkQueue* qb) {
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
	VkPhysicalDeviceSynchronization2Features synchronization2{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SYNCHRONIZATION_2_FEATURES};
	synchronization2.synchronization2 = VK_TRUE;
	timeline.pNext = &synchronization2;	// vkQueueSubmit2 in the metal-error-batches2 mode
	const char* extensions[] = {VK_EXT_METAL_OBJECTS_EXTENSION_NAME, "VK_KHR_portability_subset"};
	VkDeviceCreateInfo deviceInfo{VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO};
	deviceInfo.pNext = &timeline;
	deviceInfo.queueCreateInfoCount = c.familyA == c.familyB ? 1 : 2;
	deviceInfo.pQueueCreateInfos = queues;
	deviceInfo.enabledExtensionCount = 2;
	deviceInfo.ppEnabledExtensionNames = extensions;
	VkDevice device;
	check(vkCreateDevice(c.physical, &deviceInfo, nullptr, &device), "vkCreateDevice");
	vkGetDeviceQueue(device, c.familyA, 0, qa);
	vkGetDeviceQueue(device, c.familyB, c.familyA == c.familyB ? 1 : 0, qb);
	return device;
}

id<MTLCommandQueue> exportedQueue(VkDevice device, VkQueue queue) {
	VkExportMetalCommandQueueInfoEXT queueInfo{VK_STRUCTURE_TYPE_EXPORT_METAL_COMMAND_QUEUE_INFO_EXT};
	queueInfo.queue = queue;
	VkExportMetalObjectsInfoEXT exportInfo{VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECTS_INFO_EXT};
	exportInfo.pNext = &queueInfo;
	vkExportMetalObjectsEXT(device, &exportInfo);
	return queueInfo.mtlCommandQueue;
}

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
	app.apiVersion = VK_API_VERSION_1_3;
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
	c.device = createLogicalDevice(c, &c.qa, &c.qb);
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

// A submission on queue B that waits the semaphore, if any (at waitValue for a timeline), then records its commands.
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
	values.waitSemaphoreValueCount = semaphore ? 1 : 0;
	values.pWaitSemaphoreValues = &waitValue;
	VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO};
	submit.pNext = &values;
	submit.waitSemaphoreCount = semaphore ? 1 : 0;
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

int eventWait(Context& c) {
	VkEventCreateInfo eventInfo{VK_STRUCTURE_TYPE_EVENT_CREATE_INFO};
	VkEvent event;
	check(vkCreateEvent(c.device, &eventInfo, nullptr, &event), "vkCreateEvent");
	Buffer marker = c.buffer(64, true);
	VkCommandPool pool = commandPool(c);
	VkFence fence = submitWaiting(c, pool, VK_NULL_HANDLE, 0, [&](VkCommandBuffer cb) {
		vkCmdWaitEvents(cb, 1, &event, VK_PIPELINE_STAGE_HOST_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, nullptr, 0, nullptr, 0, nullptr);
		vkCmdFillBuffer(cb, marker.buffer, 0, 4, kMarker);
	});
	sleepMs(100);
	VkResult fenceBeforeLoss = vkGetFenceStatus(c.device, fence);
	// Reads the event status until the loss is reported, or until the first host wait returns.
	std::atomic<bool> stop{false};
	int setSeen = 0, reads = 0;
	VkResult lastStatus = VK_EVENT_RESET;
	std::thread poller([&] {
		while (!stop && lastStatus != VK_ERROR_DEVICE_LOST) {
			lastStatus = vkGetEventStatus(c.device, event);
			setSeen += lastStatus == VK_EVENT_SET;
			++reads;
		}
	});
	sleepMs(10);
	c.markLost(c.device);
	auto start = std::chrono::steady_clock::now();
	VkResult lossResult = vkWaitForFences(c.device, 1, &fence, VK_TRUE, 3000000000ull);
	double waitMs = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
	uint32_t markerAtReport = marker.mapped[0];
	stop = true;
	poller.join();
	vkSetEvent(c.device, event);
	VkResult lateResult = vkWaitForFences(c.device, 1, &fence, VK_TRUE, 5000000000ull);
	std::printf("fence_before_loss=%d wait_after_loss=%d in %.0f ms marker_C_at_report=%08x status_reads=%d set_seen=%d last_status=%d wait_after_set=%d\n",
				int(fenceBeforeLoss), int(lossResult), waitMs, markerAtReport, reads, setSeen, int(lastStatus), int(lateResult));
	bool reported = lossResult == VK_ERROR_DEVICE_LOST;
	std::printf("EVENT_WAIT %s: %s, %s\n", reported && !setSeen ? "PASS" : "FAIL",
				reported ? "loss reported while the event was unset" : "loss not reported while the event was unset",
				setSeen ? "event reported set by the loss" : "event never reported set");
	vkDestroyFence(c.device, fence, nullptr);
	vkDestroyCommandPool(c.device, pool, nullptr);
	c.destroy(marker);
	vkDestroyEvent(c.device, event, nullptr);
	return reported && !setSeen && fenceBeforeLoss == VK_NOT_READY ? 0 : 1;
}

// teardown, prefill-abandon, metal-error: handler bookkeeping, through the command buffer and queue classes that
// MoltenVK receives from Metal. The handlers added to a command buffer are collected, then given to Metal as one handler
// at commit, which runs them in order (in reverse order with gReverseHandlers), each after gHandlerDelayUs. A command
// buffer claimed by gFailNextCommits reports MTLCommandBufferStatusError once complete, with a page fault error, and
// its handlers start only after gFailedDispatchDelayUs.
std::atomic<int> gHandlersCommitted{0}, gHandlersStarted{0}, gHandlersFinished{0}, gHandlersLate{0}, gFailCommandBuffers{0}, gFailNextCommits{0};
std::atomic<bool> gDeviceDestroyed{false}, gCleanupReturned{false};
useconds_t gHandlerDelayUs = 0, gFailedDispatchDelayUs = 0;
bool gReverseHandlers = false;
IMP gAddCompletedHandler = nullptr, gAddScheduledHandler = nullptr, gCommit = nullptr, gCommandBuffer = nullptr, gStatus = nullptr, gError = nullptr;
char gCompletedKey, gScheduledKey, gFailedKey;

void collectHandler(id commandBuffer, MTLCommandBufferHandler block, char* key) {
	NSMutableArray* handlers = objc_getAssociatedObject(commandBuffer, key);
	if (!handlers) {
		handlers = [NSMutableArray array];
		objc_setAssociatedObject(commandBuffer, key, handlers, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	}
	[handlers addObject: [[block copy] autorelease]];
}

void addCompletedHandlerCollected(id self, SEL, MTLCommandBufferHandler block) { collectHandler(self, block, &gCompletedKey); }
void addScheduledHandlerCollected(id self, SEL, MTLCommandBufferHandler block) { collectHandler(self, block, &gScheduledKey); }

void runHandlers(NSArray* handlers, id<MTLCommandBuffer> mtlCmdBuff) {
	for (MTLCommandBufferHandler handler in (gReverseHandlers ? handlers.reverseObjectEnumerator : handlers.objectEnumerator)) {
		gHandlersStarted++;
		if (gDeviceDestroyed || gCleanupReturned) { gHandlersLate++; }
		if (gHandlerDelayUs) { usleep(gHandlerDelayUs); }
		handler(mtlCmdBuff);
		gHandlersFinished++;
	}
}

// Metal delivers the handlers of the command buffers of one queue one after the other: a failed command buffer's
// handlers are moved to another thread, so that those of the next command buffer can run first.
MTLCommandBufferHandler dispatchHandlers(NSArray* handlers, bool isFailed) {
	return [[^(id<MTLCommandBuffer> mtlCmdBuff) {
		if (isFailed && gFailedDispatchDelayUs) {
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, int64_t(gFailedDispatchDelayUs) * 1000), dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
				runHandlers(handlers, mtlCmdBuff);
			});
		} else {
			runHandlers(handlers, mtlCmdBuff);
		}
	} copy] autorelease];
}

void commitCounted(id self, SEL command) {
	NSArray* completed = objc_getAssociatedObject(self, &gCompletedKey);
	NSArray* scheduled = objc_getAssociatedObject(self, &gScheduledKey);
	int claim = gFailNextCommits.load();
	while (claim > 0 && !gFailNextCommits.compare_exchange_weak(claim, claim - 1)) {}
	bool isFailed = claim > 0;
	if (isFailed) { objc_setAssociatedObject(self, &gFailedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
	gHandlersCommitted += int(completed.count + scheduled.count);
	auto add = [&](IMP imp, SEL selector, NSArray* handlers, bool failed) {
		if (handlers.count) { reinterpret_cast<void (*)(id, SEL, MTLCommandBufferHandler)>(imp)(self, selector, dispatchHandlers(handlers, failed)); }
	};
	add(gAddScheduledHandler, @selector(addScheduledHandler:), scheduled, false);
	add(gAddCompletedHandler, @selector(addCompletedHandler:), completed, isFailed);
	reinterpret_cast<void (*)(id, SEL)>(gCommit)(self, command);
}

MTLCommandBufferStatus statusOrFailed(id self, SEL command) {
	MTLCommandBufferStatus status = reinterpret_cast<MTLCommandBufferStatus (*)(id, SEL)>(gStatus)(self, command);
	return status == MTLCommandBufferStatusCompleted && objc_getAssociatedObject(self, &gFailedKey) ? MTLCommandBufferStatusError : status;
}

id errorOrFailed(id self, SEL command) {
	if (objc_getAssociatedObject(self, &gFailedKey)) {
		return [NSError errorWithDomain: MTLCommandBufferErrorDomain code: MTLCommandBufferErrorPageFault userInfo: nil];
	}
	return reinterpret_cast<id (*)(id, SEL)>(gError)(self, command);
}

id commandBufferOrNil(id self, SEL command, id descriptor) {
	int remaining = gFailCommandBuffers.load();
	while (remaining > 0 && !gFailCommandBuffers.compare_exchange_weak(remaining, remaining - 1)) {}
	if (remaining > 0) { return nil; }
	return reinterpret_cast<id (*)(id, SEL, id)>(gCommandBuffer)(self, command, descriptor);
}

IMP replace(Class cls, SEL selector, IMP imp) {
	Method method = class_getInstanceMethod(cls, selector);
	IMP original = method_getImplementation(method);
	class_replaceMethod(cls, selector, imp, method_getTypeEncoding(method));
	return original;
}

void installHandlerHooks(Context& c) {
	VkExportMetalCommandQueueInfoEXT queueInfo{VK_STRUCTURE_TYPE_EXPORT_METAL_COMMAND_QUEUE_INFO_EXT};
	queueInfo.queue = c.qb;
	VkExportMetalObjectsInfoEXT exportInfo{VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECTS_INFO_EXT};
	exportInfo.pNext = &queueInfo;
	vkExportMetalObjectsEXT(c.device, &exportInfo);
	if (!queueInfo.mtlCommandQueue) { std::fprintf(stderr, "No exported MTLCommandQueue\n"); std::exit(3); }
	MTLCommandBufferDescriptor* descriptor = [MTLCommandBufferDescriptor new];
	id<MTLCommandBuffer> probe = [queueInfo.mtlCommandQueue commandBufferWithDescriptor: descriptor];
	[descriptor release];
	Class bufferClass = object_getClass(probe), queueClass = object_getClass(queueInfo.mtlCommandQueue);
	std::printf("command_buffer_class=%s queue_class=%s\n", class_getName(bufferClass), class_getName(queueClass));
	gAddCompletedHandler = replace(bufferClass, @selector(addCompletedHandler:), reinterpret_cast<IMP>(addCompletedHandlerCollected));
	gAddScheduledHandler = replace(bufferClass, @selector(addScheduledHandler:), reinterpret_cast<IMP>(addScheduledHandlerCollected));
	gCommit = replace(bufferClass, @selector(commit), reinterpret_cast<IMP>(commitCounted));
	gStatus = replace(bufferClass, @selector(status), reinterpret_cast<IMP>(statusOrFailed));
	gError = replace(bufferClass, @selector(error), reinterpret_cast<IMP>(errorOrFailed));
	gCommandBuffer = replace(queueClass, @selector(commandBufferWithDescriptor:), reinterpret_cast<IMP>(commandBufferOrNil));
}

int teardown(Context& c, const std::string& variant) {
	bool multi = variant == "teardown-multi", nilPath = variant == "teardown-nil" || variant == "teardown-nil-transient";
	VkResult submitResult = VK_SUCCESS;
	installHandlerHooks(c);
	const char* delay = getenv("PERVERTEX_LOSS_HANDLER_DELAY_US");
	gHandlerDelayUs = delay ? useconds_t(std::atoi(delay)) : 50000;
	VkSemaphoreCreateInfo semaphoreInfo{VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
	VkSemaphore s1, s2;
	check(vkCreateSemaphore(c.device, &semaphoreInfo, nullptr, &s1), "vkCreateSemaphore");
	check(vkCreateSemaphore(c.device, &semaphoreInfo, nullptr, &s2), "vkCreateSemaphore");
	Buffer marker = c.buffer(64, true);
	VkCommandPool poolB = commandPool(c), poolA = VK_NULL_HANDLE;
	VkCommandPoolCreateInfo poolInfo{VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};
	poolInfo.queueFamilyIndex = c.familyA;
	check(vkCreateCommandPool(c.device, &poolInfo, nullptr, &poolA), "vkCreateCommandPool A");
	auto record = [&](VkCommandPool pool, uint32_t offset) {
		VkCommandBufferAllocateInfo allocation{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
		allocation.commandPool = pool;
		allocation.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
		allocation.commandBufferCount = 1;
		VkCommandBuffer commands;
		check(vkAllocateCommandBuffers(c.device, &allocation, &commands), "vkAllocateCommandBuffers");
		VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
		check(vkBeginCommandBuffer(commands, &begin), "vkBeginCommandBuffer");
		vkCmdFillBuffer(commands, marker.buffer, offset, 4, kMarker);
		check(vkEndCommandBuffer(commands), "vkEndCommandBuffer");
		return commands;
	};
	auto submit = [&](VkQueue queue, VkSemaphore wait, std::vector<VkCommandBuffer> commands) {
		VkFenceCreateInfo fenceInfo{VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
		VkFence fence;
		check(vkCreateFence(c.device, &fenceInfo, nullptr, &fence), "vkCreateFence");
		VkPipelineStageFlags stage = VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT;
		VkSubmitInfo info{VK_STRUCTURE_TYPE_SUBMIT_INFO};
		info.waitSemaphoreCount = wait ? 1 : 0;
		info.pWaitSemaphores = &wait;
		info.pWaitDstStageMask = &stage;
		info.commandBufferCount = uint32_t(commands.size());
		info.pCommandBuffers = commands.data();
		VkResult result = vkQueueSubmit(queue, commands.empty() && !wait ? 0 : 1, &info, fence);
		// Synchronous submits return the error of a missing Metal command buffer.
		if (result != VK_SUCCESS && result != VK_ERROR_DEVICE_LOST && !nilPath) { check(result, "vkQueueSubmit"); }
		if (submitResult == VK_SUCCESS) { submitResult = result; }
		return fence;
	};
	std::vector<VkFence> fences;
	if (nilPath) { gFailCommandBuffers = variant == "teardown-nil" ? 1000 : 1; }
	std::vector<VkCommandBuffer> c1 = {record(poolB, 0)};
	if (multi) { c1.push_back(record(poolB, 4)); }
	fences.push_back(submit(c.qb, nilPath ? VK_NULL_HANDLE : s1, c1));
	if (multi) {
		fences.push_back(submit(c.qa, s2, {record(poolA, 8)}));
		fences.push_back(submit(c.qa, VK_NULL_HANDLE, {}));
		record(poolB, 12);	// never submitted: freed with its pool after the loss
	}
	sleepMs(100);
	if (!nilPath) { c.markLost(c.device); }
	VkResult result = vkWaitForFences(c.device, uint32_t(fences.size()), fences.data(), VK_TRUE, 10000000000ull);
	// Read at the return itself. A MoltenVK test build gives its own counts: each handler decrements the pending one as
	// its last use of the device, so both must be zero. Otherwise, count the handlers this test saw end.
	int64_t pendingAtReturn = -1;
	uint32_t encodingsAtReturn = 0;
	auto getLossCounters = reinterpret_cast<void (*)(VkDevice, int64_t*, uint32_t*)>(dlsym(RTLD_DEFAULT, "mvkTestGetLossCounters"));
	if (getLossCounters) { getLossCounters(c.device, &pendingAtReturn, &encodingsAtReturn); }
	int committed = gHandlersCommitted, finished = gHandlersFinished, started = gHandlersStarted;
	gFailCommandBuffers = 0;
	int unfinished = getLossCounters ? int(pendingAtReturn) + int(encodingsAtReturn) : committed - finished;
	// Printed before the teardown, which a pending handler may crash.
	std::printf("submit=%d wait=%d marker_C=%08x committed_handlers=%d started=%d finished=%d mvk_pending_handlers=%lld mvk_encodings=%u unfinished_at_report=%d\n",
				int(submitResult), int(result), marker.mapped[0], committed, started, finished, (long long)pendingAtReturn, encodingsAtReturn, unfinished);
	std::fflush(stdout);
	for (auto fence : fences) { vkDestroyFence(c.device, fence, nullptr); }
	vkDestroySemaphore(c.device, s1, nullptr);
	vkDestroySemaphore(c.device, s2, nullptr);
	c.destroy(marker);
	vkDestroyCommandPool(c.device, poolA, nullptr);
	vkDestroyCommandPool(c.device, poolB, nullptr);
	vkDestroyDevice(c.device, nullptr);
	gDeviceDestroyed = true;
	sleepMs(int(gHandlerDelayUs / 1000) * 8 + 200);
	vkDestroyInstance(c.instance, nullptr);
	int late = gHandlersLate;
	std::printf("late_after_destroy=%d committed_after_report=%d\n", late, int(gHandlersCommitted) - committed);
	bool pass = result == VK_ERROR_DEVICE_LOST && unfinished == 0 && late == 0;
	std::printf("TEARDOWN %s: %s\n", pass ? "PASS" : "FAIL",
				result != VK_ERROR_DEVICE_LOST ? "loss not reported" : unfinished ? "handlers still pending when the loss was reported"
				: late ? "handlers started after vkDestroyDevice returned" : "no handler outlived the report or the device");
	return pass ? 0 : 1;
}

int prefillAbandon(Context& c, const std::string& variant) {
	const char* prefill = getenv("MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS");
	if (!prefill || std::strcmp(prefill, "1")) { std::fprintf(stderr, "Needs MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS=1\n"); return 3; }
	bool lost = variant.size() > 5 && variant.compare(variant.size() - 5, 5, "-lost") == 0;
	std::string cleanup = variant.substr(std::strlen("prefill-abandon-"), lost ? variant.size() - std::strlen("prefill-abandon-") - 5 : std::string::npos);
	installHandlerHooks(c);
	gHandlerDelayUs = 50000;
	Buffer target = c.buffer(64, true);
	VkCommandPoolCreateInfo poolInfo{VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};
	poolInfo.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
	poolInfo.queueFamilyIndex = c.familyB;
	VkCommandPool pool;
	check(vkCreateCommandPool(c.device, &poolInfo, nullptr, &pool), "vkCreateCommandPool");
	VkCommandBufferAllocateInfo allocation{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
	allocation.commandPool = pool;
	allocation.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
	allocation.commandBufferCount = 1;
	VkCommandBuffer commands;
	check(vkAllocateCommandBuffers(c.device, &allocation, &commands), "vkAllocateCommandBuffers");
	VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
	check(vkBeginCommandBuffer(commands, &begin), "vkBeginCommandBuffer");
	auto outstanding = reinterpret_cast<uint64_t (*)(VkCommandPool)>(dlsym(RTLD_DEFAULT, "mvkTestGetOutstandingCommandPoolAllocations"));
	// Counts are unsigned: a second return of the same allocation wraps below zero.
	bool measured = outstanding && cleanup != "pool";
	uint64_t beforeRecord = outstanding ? outstanding(pool) : 0;
	uint32_t data[4] = {kMarker, kMarker, kMarker, kMarker};
	vkCmdUpdateBuffer(commands, target.buffer, 0, sizeof(data), data);
	check(vkEndCommandBuffer(commands), "vkEndCommandBuffer");
	uint64_t afterRecord = outstanding ? outstanding(pool) : 0;
	if (lost) { c.markLost(c.device); sleepMs(50); }
	int committedBefore = gHandlersCommitted;
	if (cleanup == "reset") {
		vkResetCommandBuffer(commands, 0);
	} else if (cleanup == "free") {
		vkFreeCommandBuffers(c.device, pool, 1, &commands);
	} else {
		vkDestroyCommandPool(c.device, pool, nullptr);
	}
	gCleanupReturned = true;
	int committedByCleanup = gHandlersCommitted - committedBefore;
	uint64_t afterCleanup = measured ? outstanding(pool) : 0;
	sleepMs(int(gHandlerDelayUs / 1000) * 8 + 300);
	uint64_t afterWait = measured ? outstanding(pool) : 0;
	// Later cleanups of the same command buffer and pool must not return the allocation again.
	if (cleanup == "reset") { vkFreeCommandBuffers(c.device, pool, 1, &commands); }
	if (cleanup != "pool") { vkResetCommandPool(c.device, pool, 0); }
	uint64_t afterLaterCleanups = measured ? outstanding(pool) : 0;
	uint32_t written = target.mapped[0];
	int late = gHandlersLate;
	bool executed = written == kMarker;
	bool exactlyOnce = !measured || (afterRecord == beforeRecord + 1 && afterCleanup == beforeRecord && afterWait == beforeRecord
									  && afterLaterCleanups == beforeRecord);
	std::printf("cleanup=%s lost=%d handlers_committed_by_cleanup=%d late_handlers=%d target=%08x outstanding_allocations(measured=%d): "
				"before_record=%llu after_record=%llu after_cleanup=%llu after_wait=%llu after_later_cleanups=%llu\n",
				cleanup.c_str(), int(lost), committedByCleanup, late, written, int(measured), (unsigned long long)beforeRecord,
				(unsigned long long)afterRecord, (unsigned long long)afterCleanup, (unsigned long long)afterWait, (unsigned long long)afterLaterCleanups);
	bool pass = !executed && !late && exactlyOnce;
	std::printf("PREFILL_ABANDON %s: %s\n", pass ? "PASS" : "FAIL",
				executed ? "the abandoned vkCmdUpdateBuffer ran" : late ? "handlers ran after the cleanup returned"
				: !exactlyOnce ? "the pooled buffer did not return to its pool exactly once"
				: measured ? "the abandoned command never ran, its buffer returned to its pool exactly once, no handler outlived the cleanup"
				: "the abandoned command never ran, and no handler outlived the cleanup");
	if (cleanup != "pool") { vkDestroyCommandPool(c.device, pool, nullptr); }
	c.destroy(target);
	return pass ? 0 : 1;
}

int metalErrorBatches(Context& c, const std::string& variant) {
	installHandlerHooks(c);
	gFailedDispatchDelayUs = 200000;
	id<MTLSharedEvent> event = [c.mtlDevice newSharedEvent];
	VkSemaphore binary = importedSemaphore(c, event, false);
	Buffer marker = c.buffer(64, true);
	VkCommandPool pool = commandPool(c);
	VkCommandBuffer commands[2];
	VkCommandBufferAllocateInfo allocation{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
	allocation.commandPool = pool;
	allocation.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
	allocation.commandBufferCount = 2;
	check(vkAllocateCommandBuffers(c.device, &allocation, commands), "vkAllocateCommandBuffers");
	for (uint32_t i = 0; i < 2; ++i) {
		VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
		check(vkBeginCommandBuffer(commands[i], &begin), "vkBeginCommandBuffer");
		vkCmdFillBuffer(commands[i], marker.buffer, 4 * i, 4, kMarker);
		check(vkEndCommandBuffer(commands[i]), "vkEndCommandBuffer");
	}
	VkFenceCreateInfo fenceInfo{VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
	VkFence fence;
	check(vkCreateFence(c.device, &fenceInfo, nullptr, &fence), "vkCreateFence");
	gFailNextCommits = 1;	// batch 1's Metal command buffer fails
	if (variant == "metal-error-batches2") {
		auto submit2 = reinterpret_cast<PFN_vkQueueSubmit2>(vkGetDeviceProcAddr(c.device, "vkQueueSubmit2"));
		if (!submit2) { std::fprintf(stderr, "vkQueueSubmit2 unavailable\n"); return 3; }
		VkCommandBufferSubmitInfo buffers[2] = {{VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO}, {VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO}};
		buffers[0].commandBuffer = commands[0];
		buffers[1].commandBuffer = commands[1];
		VkSemaphoreSubmitInfo signal{VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO};
		signal.semaphore = binary;
		signal.stageMask = VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT;
		VkSubmitInfo2 batches[2] = {{VK_STRUCTURE_TYPE_SUBMIT_INFO_2}, {VK_STRUCTURE_TYPE_SUBMIT_INFO_2}};
		batches[0].commandBufferInfoCount = 1;
		batches[0].pCommandBufferInfos = &buffers[0];
		batches[1].commandBufferInfoCount = 1;
		batches[1].pCommandBufferInfos = &buffers[1];
		batches[1].signalSemaphoreInfoCount = 1;
		batches[1].pSignalSemaphoreInfos = &signal;
		check(submit2(c.qb, 2, batches, fence), "vkQueueSubmit2");
	} else {
		VkSubmitInfo batches[2] = {{VK_STRUCTURE_TYPE_SUBMIT_INFO}, {VK_STRUCTURE_TYPE_SUBMIT_INFO}};
		batches[0].commandBufferCount = 1;
		batches[0].pCommandBuffers = &commands[0];
		batches[1].commandBufferCount = 1;
		batches[1].pCommandBuffers = &commands[1];
		batches[1].signalSemaphoreCount = 1;
		batches[1].pSignalSemaphores = &binary;
		if (variant == "metal-error-calls") {
			check(vkQueueSubmit(c.qb, 1, &batches[0], VK_NULL_HANDLE), "vkQueueSubmit batch 1");
			check(vkQueueSubmit(c.qb, 1, &batches[1], fence), "vkQueueSubmit batch 2");
		} else {
			check(vkQueueSubmit(c.qb, 2, batches, fence), "vkQueueSubmit");
		}
	}
	VkResult report = vkWaitForFences(c.device, 1, &fence, VK_TRUE, 5000000000ull);
	uint64_t eventAtReport = event.signaledValue;
	sleepMs(400);
	std::printf("wait=%d semaphore_event_at_report=%llu semaphore_event_later=%llu marker_batches=%08x %08x\n", int(report),
				(unsigned long long)eventAtReport, (unsigned long long)event.signaledValue, marker.mapped[0], marker.mapped[1]);
	bool pass = report == VK_ERROR_DEVICE_LOST && !eventAtReport && !event.signaledValue;
	std::printf("METAL_ERROR %s: %s\n", pass ? "PASS" : "FAIL",
				report == VK_SUCCESS ? "batch 2's fence reported complete work that batch 1's failure precedes"
				: eventAtReport || event.signaledValue ? "batch 2 signalled the binary semaphore after batch 1 failed"
				: report != VK_ERROR_DEVICE_LOST ? "unexpected wait result" : "the failure was reported as a loss, and nothing as complete");
	vkDestroyFence(c.device, fence, nullptr);
	vkDestroyCommandPool(c.device, pool, nullptr);
	c.destroy(marker);
	vkDestroySemaphore(c.device, binary, nullptr);
	[event release];
	return pass ? 0 : 1;
}

int metalError(Context& c, const std::string& variant) {
	bool multi = variant == "metal-error-multi";
	const char* prefill = getenv("MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS");
	if (multi && (!prefill || std::strcmp(prefill, "1"))) { std::fprintf(stderr, "Needs MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS=1\n"); return 3; }
	installHandlerHooks(c);
	gReverseHandlers = true;
	gFailedDispatchDelayUs = multi ? 200000 : 0;
	id<MTLSharedEvent> event = [c.mtlDevice newSharedEvent];
	VkSemaphore binary = importedSemaphore(c, event, false);
	Buffer marker = c.buffer(64, true);
	VkCommandPool pool = commandPool(c);
	std::vector<VkCommandBuffer> commands(multi ? 2 : 1);
	VkCommandBufferAllocateInfo allocation{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
	allocation.commandPool = pool;
	allocation.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
	allocation.commandBufferCount = uint32_t(commands.size());
	check(vkAllocateCommandBuffers(c.device, &allocation, commands.data()), "vkAllocateCommandBuffers");
	for (size_t i = 0; i < commands.size(); ++i) {
		VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
		check(vkBeginCommandBuffer(commands[i], &begin), "vkBeginCommandBuffer");
		vkCmdFillBuffer(commands[i], marker.buffer, 4 * i, 4, kMarker);
		check(vkEndCommandBuffer(commands[i]), "vkEndCommandBuffer");
	}
	VkFenceCreateInfo fenceInfo{VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
	VkFence fence;
	check(vkCreateFence(c.device, &fenceInfo, nullptr, &fence), "vkCreateFence");
	VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO};
	submit.commandBufferCount = uint32_t(commands.size());
	submit.pCommandBuffers = commands.data();
	submit.signalSemaphoreCount = 1;
	submit.pSignalSemaphores = &binary;
	gFailNextCommits = 1;	// C's first Metal command buffer fails
	check(vkQueueSubmit(c.qb, 1, &submit, fence), "vkQueueSubmit C");
	VkResult report = vkWaitForFences(c.device, 1, &fence, VK_TRUE, 5000000000ull);
	uint64_t eventAtReport = event.signaledValue;
	sleepMs(400);
	std::printf("wait=%d semaphore_event_at_report=%llu semaphore_event_later=%llu marker_C=%08x %08x\n", int(report),
				(unsigned long long)eventAtReport, (unsigned long long)event.signaledValue, marker.mapped[0], marker.mapped[1]);
	bool pass = report == VK_ERROR_DEVICE_LOST && !eventAtReport && !event.signaledValue;
	std::printf("METAL_ERROR %s: %s\n", pass ? "PASS" : "FAIL",
				report == VK_SUCCESS ? "the fence reported a failed Metal command buffer complete"
				: eventAtReport || event.signaledValue ? "the binary semaphore was signalled for a failed Metal command buffer"
				: report != VK_ERROR_DEVICE_LOST ? "unexpected wait result" : "the failure was reported as a loss, and nothing as complete");
	vkDestroyFence(c.device, fence, nullptr);
	vkDestroyCommandPool(c.device, pool, nullptr);
	c.destroy(marker);
	vkDestroySemaphore(c.device, binary, nullptr);
	[event release];
	return pass ? 0 : 1;
}

// variant: "fence" (vkWaitForFences bounded at 2 s), "idle" (vkQueueWaitIdle) or "query" (vkGetQueryPoolResults with
// VK_QUERY_RESULT_WAIT_BIT), the last two without a timeout of their own, on a thread given 2 s.
int externalQueueWait(Context& c, const std::string& variant) {
	id<MTLCommandQueue> mtlQueue = exportedQueue(c.device, c.qb);
	if (!mtlQueue) { std::fprintf(stderr, "No exported MTLCommandQueue\n"); return 3; }
	id<MTLSharedEvent> unknown = [c.mtlDevice newSharedEvent];
	id<MTLBuffer> externalMarker = [c.mtlDevice newBufferWithLength: 64 options: MTLResourceStorageModeShared];
	std::memset(externalMarker.contents, 0, 64);
	id<MTLCommandBuffer> external = [mtlQueue commandBuffer];
	[external encodeWaitForEvent: unknown value: 1];
	id<MTLBlitCommandEncoder> blit = [external blitCommandEncoder];
	[blit fillBuffer: externalMarker range: NSMakeRange(0, 4) value: 0xA5];
	[blit endEncoding];
	[external commit];
	Buffer marker = c.buffer(64, true);
	VkCommandPool pool = commandPool(c);
	VkCommandBufferAllocateInfo allocation{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
	allocation.commandPool = pool;
	allocation.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
	allocation.commandBufferCount = 1;
	VkCommandBuffer commands;
	check(vkAllocateCommandBuffers(c.device, &allocation, &commands), "vkAllocateCommandBuffers");
	VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
	check(vkBeginCommandBuffer(commands, &begin), "vkBeginCommandBuffer");
	VkQueryPool queries = VK_NULL_HANDLE;
	if (variant == "query") {
		VkQueryPoolCreateInfo queryInfo{VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO};
		queryInfo.queryType = VK_QUERY_TYPE_TIMESTAMP;
		queryInfo.queryCount = 1;
		check(vkCreateQueryPool(c.device, &queryInfo, nullptr, &queries), "vkCreateQueryPool");
		vkCmdResetQueryPool(commands, queries, 0, 1);
	}
	vkCmdFillBuffer(commands, marker.buffer, 0, 4, kMarker);
	if (queries) { vkCmdWriteTimestamp(commands, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, queries, 0); }
	check(vkEndCommandBuffer(commands), "vkEndCommandBuffer");
	VkFenceCreateInfo fenceInfo{VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
	VkFence fence;
	check(vkCreateFence(c.device, &fenceInfo, nullptr, &fence), "vkCreateFence");
	VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO};
	submit.commandBufferCount = 1;
	submit.pCommandBuffers = &commands;
	check(vkQueueSubmit(c.qb, 1, &submit, fence), "vkQueueSubmit C");
	sleepMs(200);
	uint32_t markerBeforeLoss = marker.mapped[0];
	VkResult fenceBeforeLoss = vkGetFenceStatus(c.device, fence);
	c.markLost(c.device);
	auto start = std::chrono::steady_clock::now();
	VkResult report = VK_TIMEOUT;
	std::atomic<bool> waited{false};
	VkResult threadResult = VK_NOT_READY;
	uint64_t timestamp = 0;
	std::thread waiter;
	if (variant == "fence") {
		report = vkWaitForFences(c.device, 1, &fence, VK_TRUE, 2000000000ull);
	} else {
		waiter = std::thread([&] {
			threadResult = variant == "idle" ? vkQueueWaitIdle(c.qb)
				: vkGetQueryPoolResults(c.device, queries, 0, 1, sizeof(timestamp), &timestamp, sizeof(timestamp), VK_QUERY_RESULT_64_BIT | VK_QUERY_RESULT_WAIT_BIT);
			waited = true;
		});
		while (!waited && std::chrono::steady_clock::now() - start < std::chrono::seconds(2)) { sleepMs(1); }
		if (waited) { report = threadResult; }
	}
	double reportMs = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
	uint32_t markerAtReport = marker.mapped[0];
	// The application releases its own work, as it eventually would.
	unknown.signaledValue = 1;
	[external waitUntilCompleted];
	if (waiter.joinable()) { waiter.join(); }
	VkResult late = vkWaitForFences(c.device, 1, &fence, VK_TRUE, 5000000000ull);
	sleepMs(100);
	uint32_t markerLater = marker.mapped[0];
	bool reported = report == VK_ERROR_DEVICE_LOST;
	bool ranAfterReport = reported && markerAtReport != kMarker && markerLater == kMarker;
	std::printf("C_before_loss: fence=%d marker=%08x; %s wait_after_loss=%d in %.0f ms marker_C=%08x; after external signal: wait=%d%s marker_C=%08x\n",
				int(fenceBeforeLoss), markerBeforeLoss, variant.c_str(), int(report), reportMs, markerAtReport, int(late),
				variant == "fence" ? "" : (" host_wait=" + std::to_string(int(threadResult))).c_str(), markerLater);
	std::printf("EXTERNAL_QUEUE_WAIT %s\n", !reported ? "LOSS_NOT_REPORTED: the loss waits for C, which waits for the application's Metal work"
				: ranAfterReport ? "RAN_AFTER_REPORT: C ran after the loss was reported, on resources the application could destroy"
				: "PASS: the loss was reported and C did not run after it");
	vkDestroyFence(c.device, fence, nullptr);
	if (queries) { vkDestroyQueryPool(c.device, queries, nullptr); }
	vkDestroyCommandPool(c.device, pool, nullptr);
	c.destroy(marker);
	[externalMarker release];
	[unknown release];
	return reported && !ranAfterReport && fenceBeforeLoss == VK_NOT_READY ? 0 : 1;
}

int sharedQueueBlock(Context& c) {
	constexpr int kHeld = 4;	// as many as MVK_CONFIG_MAX_ACTIVE_METAL_COMMAND_BUFFERS_PER_QUEUE, as the runner sets it
	VkQueue otherQa, otherQb;
	VkDevice other = createLogicalDevice(c, &otherQa, &otherQb);
	id<MTLCommandQueue> mtlQueue = exportedQueue(c.device, c.qb), otherMTLQueue = exportedQueue(other, otherQb);
	if (!mtlQueue || !otherMTLQueue) { std::fprintf(stderr, "No exported MTLCommandQueue\n"); return 3; }
	bool isShared = mtlQueue == otherMTLQueue;
	// The application holds every place of the first device's Metal queue B.
	id<MTLSharedEvent> unknown = [c.mtlDevice newSharedEvent];
	std::vector<id<MTLCommandBuffer>> held;
	for (int i = 0; i < kHeld; ++i) {
		id<MTLCommandBuffer> external = [[mtlQueue commandBuffer] retain];
		[external encodeWaitForEvent: unknown value: 1];
		[external commit];
		held.push_back(external);
	}
	c.markLost(c.device);
	// The second device, which nothing lost, submits to its own queue B.
	VkCommandPoolCreateInfo poolInfo{VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};
	poolInfo.queueFamilyIndex = c.familyB;
	VkCommandPool pool;
	check(vkCreateCommandPool(other, &poolInfo, nullptr, &pool), "vkCreateCommandPool");
	VkCommandBufferAllocateInfo allocation{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
	allocation.commandPool = pool;
	allocation.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
	allocation.commandBufferCount = 1;
	VkCommandBuffer commands;
	check(vkAllocateCommandBuffers(other, &allocation, &commands), "vkAllocateCommandBuffers");
	VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
	check(vkBeginCommandBuffer(commands, &begin), "vkBeginCommandBuffer");
	check(vkEndCommandBuffer(commands), "vkEndCommandBuffer");
	VkFenceCreateInfo fenceInfo{VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
	VkFence fence;
	check(vkCreateFence(other, &fenceInfo, nullptr, &fence), "vkCreateFence");
	std::atomic<bool> done{false}, hasSubmitted{false};
	VkResult submitted = VK_NOT_READY, waitedResult = VK_NOT_READY;
	auto start = std::chrono::steady_clock::now();
	std::thread submitter([&] {
		VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO};
		submit.commandBufferCount = 1;
		submit.pCommandBuffers = &commands;
		submitted = vkQueueSubmit(otherQb, 1, &submit, fence);
		hasSubmitted = true;
		waitedResult = vkWaitForFences(other, 1, &fence, VK_TRUE, UINT64_MAX);
		done = true;
	});
	while (!done && std::chrono::steady_clock::now() - start < std::chrono::seconds(2)) { sleepMs(1); }
	bool completedInTime = done, submittedInTime = hasSubmitted;
	double elapsedMs = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
	// The application releases its own work, as it eventually would.
	unknown.signaledValue = 1;
	for (id<MTLCommandBuffer> external : held) { [external waitUntilCompleted]; [external release]; }
	submitter.join();
	std::printf("shared_mtl_queue=%d external_command_buffers=%d first_device_lost=1 second_device: submit_returned_in_2s=%d completed_in_2s=%d after %.0f ms, submit=%d wait=%d (after release)\n",
				int(isShared), kHeld, int(submittedInTime), int(completedInTime), elapsedMs, int(submitted), int(waitedResult));
	std::printf("SHARED_QUEUE %s\n", completedInTime ? "PASS: the second device's submission completed"
				: !isShared ? "BLOCKED: the second device's submission did not complete, on a Metal queue of its own"
				: submittedInTime ? "BLOCKED: the second device's work waits behind the first device's in the Metal queue they share"
				: "BLOCKED: the second device waits for places of the Metal queue it shares with the first device");
	vkDestroyFence(other, fence, nullptr);
	vkDestroyCommandPool(other, pool, nullptr);
	vkDestroyDevice(other, nullptr);
	[unknown release];
	return completedInTime ? 0 : 1;
}

int timelineListenerAba(Context& c) {
	id<MTLSharedEvent> event = [c.mtlDevice newSharedEvent];
	event.signaledValue = 0;
	VkSemaphore timeline = importedSemaphore(c, event, true);
	// Both waits come from this call site, so that MoltenVK's waiter object is at the same stack address each time.
	auto waitFor = [&](uint64_t value, uint64_t timeout) {
		VkSemaphoreWaitInfo info{VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO};
		info.semaphoreCount = 1;
		info.pSemaphores = &timeline;
		info.pValues = &value;
		return vkWaitSemaphores(c.device, &info, timeout);
	};
	constexpr int kRounds = 5;
	int spurious = 0;
	for (int round = 0; round < kRounds; ++round) {
		uint64_t base = 2 * uint64_t(round);
		event.signaledValue = base;
		VkResult first = waitFor(base + 1, 10000000ull);		// times out, its listener stays registered at base + 1
		std::thread signaler([&] { sleepMs(100); event.signaledValue = base + 1; });
		auto start = std::chrono::steady_clock::now();
		VkResult second = waitFor(base + 2, 1000000000ull);	// base + 2 is never reached in this round
		double secondMs = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
		signaler.join();
		uint64_t counter = 0;
		check(vkGetSemaphoreCounterValue(c.device, timeline, &counter), "vkGetSemaphoreCounterValue");
		bool isSpurious = second == VK_SUCCESS && counter < base + 2;
		spurious += isSpurious;
		std::printf("round=%d first=%d second=%d in %.0f ms counter=%llu%s\n", round, int(first), int(second), secondMs,
					(unsigned long long)counter, isSpurious ? " SPURIOUS" : "");
	}
	std::printf("TIMELINE_LISTENER %s\n", spurious ? "FAIL: a wait reported success below its value, woken by an earlier wait's listener"
				: "PASS: no wait reported success below its value");
	vkDestroySemaphore(c.device, timeline, nullptr);
	[event release];
	return spurious ? 1 : 0;
}

}  // namespace

int main(int argc, char** argv) {
	std::string mode = argc == 2 ? argv[1] : "";
	bool isTeardown = mode == "teardown" || mode == "teardown-multi" || mode == "teardown-nil" || mode == "teardown-nil-transient";
	bool isPrefill = false;
	for (const char* cleanup : {"reset", "free", "pool"}) {
		isPrefill |= mode == std::string("prefill-abandon-") + cleanup || mode == std::string("prefill-abandon-") + cleanup + "-lost";
	}
	bool isMetalError = mode == "metal-error" || mode == "metal-error-multi";
	bool isMetalErrorBatches = mode == "metal-error-batches" || mode == "metal-error-batches2" || mode == "metal-error-calls";
	bool isExternalWait = mode == "external-queue-wait" || mode == "external-queue-wait-idle" || mode == "external-queue-wait-query";
	if (mode != "counter-race" && mode != "binary-generation" && mode != "destroy-after-loss" && mode != "event-wait" && !isExternalWait
		&& mode != "shared-queue-block" && mode != "timeline-listener-aba" && !isTeardown && !isPrefill && !isMetalError && !isMetalErrorBatches) {
		std::fprintf(stderr, "usage: %s counter-race|binary-generation|destroy-after-loss|event-wait|external-queue-wait[-idle|-query]|shared-queue-block"
					 "|timeline-listener-aba|teardown[-multi|-nil|-nil-transient]|prefill-abandon-{reset,free,pool}[-lost]"
					 "|metal-error[-multi|-batches|-batches2|-calls]\n", argv[0]);
		return 64;
	}
	@autoreleasepool {
		Context c = createContext();
		if (isTeardown) {	// destroys the device and the instance itself
			int rc = teardown(c, mode);
			std::fflush(stdout);
			return rc;
		}
		int rc = mode == "counter-race" ? counterRace(c) : mode == "binary-generation" ? binaryGeneration(c)
			: mode == "event-wait" ? eventWait(c)
			: isExternalWait ? externalQueueWait(c, mode == "external-queue-wait" ? "fence" : mode.substr(std::strlen("external-queue-wait-")))
			: mode == "shared-queue-block" ? sharedQueueBlock(c) : mode == "timeline-listener-aba" ? timelineListenerAba(c)
			: isPrefill ? prefillAbandon(c, mode) : isMetalError ? metalError(c, mode)
			: isMetalErrorBatches ? metalErrorBatches(c, mode) : destroyAfterLoss(c);
		std::fflush(stdout);
		// The device is lost: destroying it is still valid, idle waits would only report the loss.
		vkDestroyDevice(c.device, nullptr);
		vkDestroyInstance(c.instance, nullptr);
		return rc;
	}
}
