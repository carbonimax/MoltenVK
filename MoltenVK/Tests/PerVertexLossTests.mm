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
//   specification requires both to return in finite time, with VK_SUCCESS or VK_ERROR_DEVICE_LOST. The wait starts on a
//   thread 50 ms before the loss, so that it is already blocked when the loss begins, and gets 2 s from the loss; the
//   outcomes and the exit code are those of external-queue-wait.
// shared-queue-block: a second VkDevice is created on the same physical device, and the test checks that its queue
//   exports the same MTLCommandQueue as queue B of the first. The application commits four command buffers that wait a
//   MTLSharedEvent to that Metal queue, and the first device is lost. The second device, healthy, then submits and waits
//   for a fence, on a thread given 2 s. Exit 0 when that submission completes; 1 with "SHARED_QUEUE BLOCKED" otherwise.
//   With MVK_CONFIG_MAX_ACTIVE_METAL_COMMAND_BUFFERS_PER_QUEUE=4 (the runner's setting), the four fill the Metal queue:
//   a synchronous vkQueueSubmit blocks acquiring a Metal command buffer. With more places, it returns, and the work waits
//   behind the first device's in the Metal queue's order. The line "submit_returned_in_2s" tells the two apart.
// timeline-listener-aba: no device loss. vkWaitSemaphores waits value n + 1 of an imported timeline semaphore for 10 ms
//   and times out, leaving its Metal event listener registered; a second vkWaitSemaphores from the same call site then
//   waits value n + 2, while another thread raises the event to n + 1 only. Each round raises the event past the
//   previous round's values, which fires their listeners while the next round's first wait is registered. Exit 0 when no
//   wait of 10 rounds reports success below its value; 1 when one does: a listener, keyed by the address of a waiter that
//   no longer exists, woke a later one.
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
// present-scheduled-after-destroy, present-destroy-race: no device loss. A swapchain on a CAMetalLayer detached from
//   any window (VK_EXT_metal_surface), whose first image is acquired with a binary semaphore imported from an
//   MTLSharedEvent that the test then holds only weakly. MoltenVK retains that semaphore until the presentation of the
//   image ends (MVKPresentableSwapchainImage::endPresentation()), so the event is freed only if every presentation ends.
//   Each image is presented; the test waits for the queue to be idle, which completes the presentations' command
//   buffers, then destroys the swapchain, as Vulkan allows. Metal may still deliver those command buffers' scheduled
//   handlers, which begin the presentations, after the command buffers complete: the handler hooks make them late.
//   Exit 0 when the event is freed once the swapchain, the semaphore and the work are gone; 1 when it leaks; or a crash:
//   - present-scheduled-after-destroy: every MoltenVK Metal handler runs 300 ms late, so that the scheduled handlers
//     run after the swapchain is destroyed;
//   - present-destroy-race: 20 rounds, the handlers 0 to 3 ms late, so that they race with the destruction.
//   Both pass on the current runtime: Metal runs a command buffer's scheduled handlers before it reports it complete.
// present-pending-destroy: the same, but each presentation waits, through a submission, for an event the test signals
//   only after destroying the swapchain. Without a device loss this is invalid usage (the presentations have not
//   completed); it is the situation that a loss reported in finite time would make legal (PerVertexExternalWait-DESIGN.md,
//   R5 and R6), where a scheduled handler begins a presentation after its swapchain is gone.
// free-imported-waits, free-imported-waits-late-commit, free-imported-waits-slow-handler: C fills a buffer bound to host memory the test imported
//   (VK_EXT_external_memory_host), queued behind the application's own Metal work on queue B, which waits for an event
//   (as in external-queue-wait), so that C stays pending after the loss. The device is lost, and vkFreeMemory on that
//   memory is called on another thread; the test releases its work 300 ms later. With -late-commit, C's encoding is
//   held 300 ms when it creates its first Metal encoder, so that MoltenVK commits C, and counts it, only after the loss
//   began: this passes only if the loss inventory closes once no encoding remains, not when the loss begins. Otherwise
//   vkFreeMemory returns while C encodes, and C may then crash binding the freed buffer. With -slow-handler, every
//   MoltenVK completed handler starts 200 ms late (PERVERTEX_LOSS_HANDLER_DELAY_US overrides it), and vkFreeMemory must
//   return at least that long after the release: C's GPU work ends a few ms after the release, but the inventory counts
//   it down only at the end of its completed handler. Exit 0 when vkFreeMemory
//   returns only after the release, with C's value in the pages; 1 when it returns before: the pages could then be
//   reused while C still writes them. Without a device loss reported, freeing memory that pending work uses is invalid;
//   it is the ordering that a loss reported in finite time would make legal (PerVertexExternalWait-DESIGN.md, R6 and
//   R8), and this mode checks the mechanism R8 adds for it, on the submission path.
// free-imported-late-allocation, free-imported-failed-allocation: the same, and 50 ms after the loss another thread
//   imports other host pages, which no work admitted before the loss can use. With -late-allocation the import succeeds
//   and is freed at once; with -failed-allocation, Metal buffers are limited to 64 KiB (mvkTestLimitMetalBufferSize),
//   and a 128 KiB import fails, which vkAllocateMemory cleans up through the path of vkFreeMemory. That thread must
//   return within 100 ms, well before the release, while freeing the memory imported before the loss still waits.
// host-sync-progress-invalidate, host-sync-progress-copy, host-sync-admission-invalidate, host-sync-admission-copy: a
//   synchronization of managed memory from the GPU, vkInvalidateMappedMemoryRanges (-invalidate) or vkCopyImageToMemoryEXT
//   from a linear image (-copy), on host memory the test imported into a host-visible, non-coherent memory type.
//   MoltenVK encodes it only on a Mac without unified memory, whose Metal resources of that type are managed; elsewhere
//   these modes exit 3 with "HOST_SYNC SKIP". PERVERTEX_HOST_SYNC_DRY=1 runs them anyway, on a coherent memory type:
//   that checks the Vulkan calls of the test, encodes nothing, and proves nothing about the Metal path.
//   - host-sync-progress-*: the application fills the Metal queue that MoltenVK acquires those command buffers from
//     (queue A, as MVKDevice::getAnyQueue() returns it, with MVK_CONFIG_MAX_ACTIVE_METAL_COMMAND_BUFFERS_PER_QUEUE=4, as
//     the runner sets it) with four command buffers that wait for an event. The synchronization, on a thread, blocks
//     acquiring its command buffer, and the device is lost. Exit 0 when, 100 ms later, it is still blocked in the
//     acquisition and no encoding holds the loss report back (mvkTestGetLossCounters); 1 when an encoding does.
//   - host-sync-admission-*: the synchronization's acquisition returns its command buffer only 300 ms after it began; the
//     device is lost 100 ms after the synchronization starts, and nothing else holds the loss report back. Once the loss
//     is reported, the same synchronization runs again. Exit 0 when neither commits a Metal command buffer once the loss
//     has begun; 1 otherwise. Without an admission check, the second one commits work that the closed loss inventory
//     no longer counts; the first one reaches the admission check with a command buffer already acquired.
// device-destroy-after-report, device-destroy-before-report: measurements for the design review of R5, not oracles.
//   The application's own Metal work on queue B waits for an event, C (a buffer fill) is queued behind it, and the device
//   is lost. -after-report: a host wait (vkDeviceWaitIdle) starts, the application releases its work 300 ms after the
//   loss, and once the wait reports the loss, the test destroys C's objects and the device, as Vulkan allows. Exit 0
//   when vkDestroyDevice returns within 50 ms. -before-report: the device alone is destroyed 100 ms after the loss, while
//   C is pending, which Vulkan allows only once a wait has reported the loss: invalid usage today, legal once the loss is
//   reported in finite time (R6). Always exit 0; the line "destroy_device" gives how long vkDestroyDevice took.
// query-wait-abandoned: a timestamp query whose command buffer never runs, waited for with VK_QUERY_RESULT_WAIT_BIT
//   across a device loss. Under deferred prefilling (MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS=1, as the runner sets it),
//   C resets the query and writes it, encoded at vkEndCommandBuffer. Submissions are asynchronous (forced by this
//   mode). A first submission, empty with a fence, holds the queue's worker: its Metal command buffer acquisition
//   returns only 300 ms later. C is submitted behind it and accepted; a thread then waits for the query's result; the
//   device is lost 100 ms later, so that C's execution is refused and its prefilled command buffer never runs. The
//   Lost Device section of the Vulkan specification requires the wait to return in finite time. Exit 0 when it returns
//   within 2 s of the loss report, with VK_SUCCESS or VK_ERROR_DEVICE_LOST, 1 otherwise (the process then exits without destroying the query pool the wait
//   still uses).
// drawable-wait-loss (O17, PerVertexExternalWait-DESIGN.md): an encoding that waits in nextDrawable across a device loss.
//   On a CAMetalLayer detached from any window, an old swapchain presents two images behind the application's blocked
//   work and keeps a third one acquired. A replacement of the same extent is created while those presentations wait
//   (they have not begun, so MoltenVK has none to force), then the application releases its work. The replacement's
//   three images are cleared, which takes and holds three drawables, and a clear of the kept image then asks for a
//   fourth: on macOS 27.2, Core Animation makes that call wait about one second. The device is lost 50 ms after the call
//   entered, if it has not returned. nextDrawable is timed through a swizzle, and mvkTestGetLossCounters gives the encodings in progress.
//   Exit 0 when nextDrawable was entered before the loss and returned after it, no encoding still waits 20 ms after the
//   loss, the loss is reported before nextDrawable returns, and the late drawable is released to the layer; 3 with
//   "DRAWABLE_WAIT SKIP" when nextDrawable did not wait across the loss (a system without this wait); 1 otherwise.
//   Before R10 an encoding waits in nextDrawable, and holds the loss report back until it returns.
// Exit 2 for a setup failure, 3 when the device lacks a capability.
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
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

bool gPresentationModes = false;	// the present-* modes enable VK_EXT_metal_surface and VK_KHR_swapchain
bool gImportedMemoryModes = false;	// the free-imported-* modes enable VK_EXT_external_memory_host
uint64_t gMetalBufferLimit = 0;		// free-imported-failed-allocation limits Metal buffers before creating the device
bool gHostImageCopyModes = false;	// the host-sync-*-copy modes enable VK_EXT_host_image_copy, when the device has it
bool gHasHostImageCopy = false;		// whether it is enabled
bool gPreferDiscreteGPU = false;	// the host-sync modes use a discrete GPU when there is one

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
	const char* extensions[] = {VK_EXT_METAL_OBJECTS_EXTENSION_NAME, "VK_KHR_portability_subset",
		gImportedMemoryModes ? VK_EXT_EXTERNAL_MEMORY_HOST_EXTENSION_NAME : VK_KHR_SWAPCHAIN_EXTENSION_NAME, VK_EXT_HOST_IMAGE_COPY_EXTENSION_NAME};
	VkDeviceCreateInfo deviceInfo{VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO};
	deviceInfo.pNext = &timeline;
	deviceInfo.queueCreateInfoCount = c.familyA == c.familyB ? 1 : 2;
	deviceInfo.pQueueCreateInfos = queues;
	deviceInfo.enabledExtensionCount = gPresentationModes || gImportedMemoryModes ? 3 : 2;
	VkPhysicalDeviceHostImageCopyFeaturesEXT hostImageCopy{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_HOST_IMAGE_COPY_FEATURES_EXT};
	hostImageCopy.hostImageCopy = VK_TRUE;
	if (gHostImageCopyModes) {
		uint32_t count = 0;
		vkEnumerateDeviceExtensionProperties(c.physical, nullptr, &count, nullptr);
		std::vector<VkExtensionProperties> available(count);
		vkEnumerateDeviceExtensionProperties(c.physical, nullptr, &count, available.data());
		for (const auto& extension : available) { gHasHostImageCopy |= std::strcmp(extension.extensionName, VK_EXT_HOST_IMAGE_COPY_EXTENSION_NAME) == 0; }
		if (gHasHostImageCopy) {
			deviceInfo.enabledExtensionCount = 4;	// the host-sync modes also enable VK_EXT_external_memory_host
			synchronization2.pNext = &hostImageCopy;
		}
	}
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
	std::vector<const char*> enabled;
	if (hasPortability) { enabled.push_back(portability); }
	if (gPresentationModes) { enabled.push_back(VK_KHR_SURFACE_EXTENSION_NAME); enabled.push_back(VK_EXT_METAL_SURFACE_EXTENSION_NAME); }
	instanceInfo.enabledExtensionCount = uint32_t(enabled.size());
	instanceInfo.ppEnabledExtensionNames = enabled.data();
	check(vkCreateInstance(&instanceInfo, nullptr, &c.instance), "vkCreateInstance");
	uint32_t count = 0;
	vkEnumeratePhysicalDevices(c.instance, &count, nullptr);
	std::vector<VkPhysicalDevice> physicals(count);
	VkResult enumerated = vkEnumeratePhysicalDevices(c.instance, &count, physicals.data());
	if ((enumerated != VK_SUCCESS && enumerated != VK_INCOMPLETE) || !count) { std::fprintf(stderr, "No Vulkan device\n"); std::exit(3); }
	c.physical = physicals[0];
	// The host-sync modes need a GPU without unified memory: on a Mac with two GPUs, the discrete one.
	for (uint32_t i = 0; i < count && gPreferDiscreteGPU; ++i) {
		VkPhysicalDeviceProperties properties;
		vkGetPhysicalDeviceProperties(physicals[i], &properties);
		if (properties.deviceType == VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU) { c.physical = physicals[i]; break; }
	}
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
	if (gMetalBufferLimit) {
		auto limit = reinterpret_cast<void (*)(VkPhysicalDevice, uint64_t)>(dlsym(RTLD_DEFAULT, "mvkTestLimitMetalBufferSize"));
		if (!limit) { std::fprintf(stderr, "Needs a MoltenVK test build with mvkTestLimitMetalBufferSize\n"); std::exit(3); }
		limit(c.physical, gMetalBufferLimit);
	}
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
// host-sync-*: the acquisitions in progress, a one-shot delay before an acquisition returns, and the commits to
// gCountedQueue while gCountCommits is set.
std::atomic<int> gAcquiring{0}, gCommitsCounted{0};
std::atomic<useconds_t> gAcquireDelayUs{0};
std::atomic<bool> gCountCommits{false};
id gCountedQueue = nil;
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
	if (gCountCommits && [(id<MTLCommandBuffer>)self commandQueue] == gCountedQueue) { gCommitsCounted++; }
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
	gAcquiring++;
	id commandBuffer = reinterpret_cast<id (*)(id, SEL, id)>(gCommandBuffer)(self, command, descriptor);
	useconds_t delay = gAcquireDelayUs.exchange(0);
	if (delay) { usleep(delay); }
	gAcquiring--;
	return commandBuffer;
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
	VkResult report = VK_TIMEOUT;
	std::atomic<bool> waited{false};
	VkResult threadResult = VK_NOT_READY;
	uint64_t timestamp = 0;
	std::thread waiter;
	if (variant != "fence") {
		// Already waiting when the loss begins.
		waiter = std::thread([&] {
			threadResult = variant == "idle" ? vkQueueWaitIdle(c.qb)
				: vkGetQueryPoolResults(c.device, queries, 0, 1, sizeof(timestamp), &timestamp, sizeof(timestamp), VK_QUERY_RESULT_64_BIT | VK_QUERY_RESULT_WAIT_BIT);
			waited = true;
		});
		sleepMs(50);
	}
	bool waitedBeforeLoss = waited;
	c.markLost(c.device);
	auto start = std::chrono::steady_clock::now();
	if (variant == "fence") {
		report = vkWaitForFences(c.device, 1, &fence, VK_TRUE, 2000000000ull);
	} else {
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
	std::printf("C_before_loss: fence=%d marker=%08x%s; %s wait_after_loss=%d in %.0f ms marker_C=%08x; after external signal: wait=%d%s marker_C=%08x\n",
				int(fenceBeforeLoss), markerBeforeLoss, variant == "fence" ? "" : waitedBeforeLoss ? " host_wait_returned_before_loss=1" : " host_wait_blocked_before_loss=1",
				variant.c_str(), int(report), reportMs, markerAtReport, int(late),
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
	// A host wait that returned before the loss did not test the loss.
	return reported && !ranAfterReport && fenceBeforeLoss == VK_NOT_READY && !waitedBeforeLoss ? 0 : 1;
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
	// A wait that reports success must find the counter at its value or above.
	auto isSpurious = [&](VkResult result, uint64_t value) {
		uint64_t counter = 0;
		check(vkGetSemaphoreCounterValue(c.device, timeline, &counter), "vkGetSemaphoreCounterValue");
		return result == VK_SUCCESS && counter < value;
	};
	constexpr int kRounds = 10;
	int spurious = 0;
	for (int round = 0; round < kRounds; ++round) {
		uint64_t base = 2 * uint64_t(round);
		event.signaledValue = base;			// fires the listeners of the previous round's waits
		VkResult first = waitFor(base + 1, 10000000ull);		// base + 1 is not reached yet: times out, its listener stays
		bool firstSpurious = isSpurious(first, base + 1);
		std::thread signaler([&] { sleepMs(100); event.signaledValue = base + 1; });
		auto start = std::chrono::steady_clock::now();
		VkResult second = waitFor(base + 2, 1000000000ull);	// base + 2 is never reached in this round
		double secondMs = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
		signaler.join();
		bool secondSpurious = isSpurious(second, base + 2);
		spurious += firstSpurious + secondSpurious;
		std::printf("round=%d first=%d%s second=%d in %.0f ms%s\n", round, int(first), firstSpurious ? " SPURIOUS" : "",
					int(second), secondMs, secondSpurious ? " SPURIOUS" : "");
	}
	std::printf("spurious_waits=%d of %d\n", spurious, 2 * kRounds);
	std::printf("TIMELINE_LISTENER %s\n", spurious ? "FAIL: a wait reported success below its value, woken by an earlier wait's listener"
				: "PASS: no wait reported success below its value");
	vkDestroySemaphore(c.device, timeline, nullptr);
	[event release];
	return spurious ? 1 : 0;
}

// free-imported-waits-late-commit: the first Metal encoder created afterwards sleeps gEncoderDelayUs first.
std::atomic<useconds_t> gEncoderDelayUs{0};
IMP gBlitEncoder = nullptr, gComputeEncoder = nullptr, gComputeEncoderWithType = nullptr;

void delayEncoder() {
	useconds_t delay = gEncoderDelayUs.exchange(0);
	if (delay) { usleep(delay); }
}
id blitEncoderDelayed(id self, SEL command) { delayEncoder(); return reinterpret_cast<id (*)(id, SEL)>(gBlitEncoder)(self, command); }
id computeEncoderDelayed(id self, SEL command) { delayEncoder(); return reinterpret_cast<id (*)(id, SEL)>(gComputeEncoder)(self, command); }
id computeEncoderWithTypeDelayed(id self, SEL command, NSUInteger type) {
	delayEncoder();
	return reinterpret_cast<id (*)(id, SEL, NSUInteger)>(gComputeEncoderWithType)(self, command, type);
}

int freeImportedWaits(Context& c, const std::string& mode) {
	bool isLateCommit = mode == "free-imported-waits-late-commit", isSlowHandler = mode == "free-imported-waits-slow-handler";
	bool isLateAllocation = mode == "free-imported-late-allocation", isFailedAllocation = mode == "free-imported-failed-allocation";
	VkPhysicalDeviceExternalMemoryHostPropertiesEXT hostProperties{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_MEMORY_HOST_PROPERTIES_EXT};
	VkPhysicalDeviceProperties2 properties{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2};
	properties.pNext = &hostProperties;
	vkGetPhysicalDeviceProperties2(c.physical, &properties);
	size_t size = std::max<size_t>(size_t(hostProperties.minImportedHostPointerAlignment), 16384);
	// Pages the test owns and never unmaps, so that reading them after vkFreeMemory stays valid.
	void* pages = nullptr;
	if (posix_memalign(&pages, size, size)) { std::fprintf(stderr, "posix_memalign\n"); return 2; }
	std::memset(pages, 0, size);
	volatile uint32_t* words = static_cast<volatile uint32_t*>(pages);
	size_t lateSize = isFailedAllocation ? 2 * gMetalBufferLimit : size;
	void* latePages = nullptr;
	if (posix_memalign(&latePages, size, lateSize)) { std::fprintf(stderr, "posix_memalign\n"); return 2; }
	std::memset(latePages, 0, lateSize);
	VkMemoryHostPointerPropertiesEXT pointerProperties{VK_STRUCTURE_TYPE_MEMORY_HOST_POINTER_PROPERTIES_EXT};
	check(vkGetMemoryHostPointerPropertiesEXT(c.device, VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT, pages, &pointerProperties),
		  "vkGetMemoryHostPointerPropertiesEXT");
	VkExternalMemoryBufferCreateInfo externalBuffer{VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_BUFFER_CREATE_INFO};
	externalBuffer.handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT;
	VkBufferCreateInfo bufferInfo{VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO};
	bufferInfo.pNext = &externalBuffer;
	bufferInfo.size = size;
	bufferInfo.usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT;
	VkBuffer buffer;
	check(vkCreateBuffer(c.device, &bufferInfo, nullptr, &buffer), "vkCreateBuffer");
	VkMemoryRequirements requirements;
	vkGetBufferMemoryRequirements(c.device, buffer, &requirements);
	uint32_t types = requirements.memoryTypeBits & pointerProperties.memoryTypeBits, type = 0;
	while (type < 32 && !(types & (1u << type))) { ++type; }
	if (type == 32) { std::fprintf(stderr, "No memory type for imported host memory\n"); return 3; }
	VkImportMemoryHostPointerInfoEXT imported{VK_STRUCTURE_TYPE_IMPORT_MEMORY_HOST_POINTER_INFO_EXT};
	imported.handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT;
	imported.pHostPointer = pages;
	VkMemoryAllocateInfo allocation{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
	allocation.pNext = &imported;
	allocation.allocationSize = size;
	allocation.memoryTypeIndex = type;
	VkDeviceMemory memory;
	check(vkAllocateMemory(c.device, &allocation, nullptr, &memory), "vkAllocateMemory");
	check(vkBindBufferMemory(c.device, buffer, memory, 0), "vkBindBufferMemory");

	// The application's own Metal work, which only the test releases, ahead of C on queue B.
	installHandlerHooks(c);
	id<MTLCommandQueue> mtlQueue = exportedQueue(c.device, c.qb);
	if (!mtlQueue) { std::fprintf(stderr, "No exported MTLCommandQueue\n"); return 3; }
	id<MTLSharedEvent> unknown = [c.mtlDevice newSharedEvent];
	id<MTLCommandBuffer> external = [[mtlQueue commandBuffer] retain];
	[external encodeWaitForEvent: unknown value: 1];
	[external commit];
	VkCommandPool pool = commandPool(c);
	VkCommandBufferAllocateInfo commandInfo{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
	commandInfo.commandPool = pool;
	commandInfo.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
	commandInfo.commandBufferCount = 1;
	VkCommandBuffer commands;
	check(vkAllocateCommandBuffers(c.device, &commandInfo, &commands), "vkAllocateCommandBuffers");
	VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
	check(vkBeginCommandBuffer(commands, &begin), "vkBeginCommandBuffer");
	vkCmdFillBuffer(commands, buffer, 0, 4, kMarker);
	check(vkEndCommandBuffer(commands), "vkEndCommandBuffer");
	if (isLateCommit) {
		Class bufferClass = object_getClass(external);
		gBlitEncoder = replace(bufferClass, @selector(blitCommandEncoder), reinterpret_cast<IMP>(blitEncoderDelayed));
		gComputeEncoder = replace(bufferClass, @selector(computeCommandEncoder), reinterpret_cast<IMP>(computeEncoderDelayed));
		gComputeEncoderWithType = replace(bufferClass, @selector(computeCommandEncoderWithDispatchType:), reinterpret_cast<IMP>(computeEncoderWithTypeDelayed));
		gEncoderDelayUs = 300000;
	}
	const char* delay = getenv("PERVERTEX_LOSS_HANDLER_DELAY_US");
	gHandlerDelayUs = !isSlowHandler ? 0 : delay ? useconds_t(std::atoi(delay)) : 200000;
	auto start = std::chrono::steady_clock::now();
	auto sinceMs = [&](std::chrono::steady_clock::time_point t) { return std::chrono::duration<double, std::milli>(t - start).count(); };
	std::thread submitter([&] {
		VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO};
		submit.commandBufferCount = 1;
		submit.pCommandBuffers = &commands;
		vkQueueSubmit(c.qb, 1, &submit, VK_NULL_HANDLE);	// its result only reports a loss that began meanwhile
	});
	// With -late-commit, C is still encoding (held at its first Metal encoder) when the loss begins.
	sleepMs(isLateCommit ? 100 : 200);
	c.markLost(c.device);
	auto lost = std::chrono::steady_clock::now();
	sleepMs(50);
	// -late-allocation, -failed-allocation: an import during the loss, then its release, on another thread.
	std::atomic<bool> lateReturned{false};
	double lateMs = -1;
	VkResult lateResult = VK_SUCCESS;
	std::thread late;
	if (isLateAllocation || isFailedAllocation) {
		late = std::thread([&] {
			auto lateStart = std::chrono::steady_clock::now();
			VkImportMemoryHostPointerInfoEXT lateImport = imported;
			lateImport.pHostPointer = latePages;
			VkMemoryAllocateInfo lateAllocation = allocation;
			lateAllocation.pNext = &lateImport;
			lateAllocation.allocationSize = lateSize;
			VkDeviceMemory lateMemory = VK_NULL_HANDLE;
			lateResult = vkAllocateMemory(c.device, &lateAllocation, nullptr, &lateMemory);
			if (lateResult == VK_SUCCESS) { vkFreeMemory(c.device, lateMemory, nullptr); }
			lateMs = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - lateStart).count();
			lateReturned = true;
		});
	}
	std::atomic<bool> freed{false};
	std::chrono::steady_clock::time_point freedAt;
	uint32_t valueAtFree = 0;
	std::thread freer([&] {
		vkFreeMemory(c.device, memory, nullptr);
		freedAt = std::chrono::steady_clock::now();
		valueAtFree = words[0];
		freed = true;
		// Printed at once: if C then encodes with the freed buffer and crashes, the log still shows why.
		std::printf("vkFreeMemory returned at %.0f ms, value %08x\n", sinceMs(freedAt), valueAtFree);
		std::fflush(stdout);
	});
	sleepMs(300);
	bool freedBeforeRelease = freed, lateBeforeRelease = lateReturned;
	auto released = std::chrono::steady_clock::now();
	unknown.signaledValue = 1;	// the application releases its own work
	[external waitUntilCompleted];
	freer.join();
	submitter.join();
	if (late.joinable()) { late.join(); }
	vkQueueWaitIdle(c.qb);	// reports the loss
	bool isForced = !isLateCommit || gEncoderDelayUs.load() == 0;
	double freedAfterReleaseMs = sinceMs(freedAt) - sinceMs(released), handlerDelayMs = gHandlerDelayUs / 1000.0;
	bool waitedForHandler = freedAfterReleaseMs >= handlerDelayMs;
	bool isLate = isLateAllocation || isFailedAllocation;
	bool lateReturnedAtOnce = !isLate || (lateBeforeRelease && lateMs < 100 && (lateResult == VK_SUCCESS) == isLateAllocation);
	bool pass = isForced && !freedBeforeRelease && freedAt >= released && valueAtFree == kMarker && waitedForHandler && lateReturnedAtOnce;
	if (isLate) {
		std::printf("late_import=%s result=%d returned_in=%.0f ms before_release=%d\n", isLateAllocation ? "succeeds" : "fails", lateResult, lateMs,
					int(lateBeforeRelease));
	}
	std::printf("loss_at=%.0f ms freed_at=%.0f ms released_at=%.0f ms value_at_free=%08x handler_delay=%.0f ms freed_after_release=%.0f ms\n",
				sinceMs(lost), sinceMs(freedAt), sinceMs(released), valueAtFree, handlerDelayMs, freedAfterReleaseMs);
	std::printf("FREE_IMPORTED %s\n", pass ? "PASS: vkFreeMemory returned only after the work that writes the imported pages"
				: !isForced ? "FAIL: C created no Metal encoder, so its commit was not held after the loss"
				: !lateReturnedAtOnce ? (lateResult == VK_SUCCESS) != isLateAllocation ? "FAIL: the import during the loss did not end as expected"
					: "FAIL: an import made during the loss waited for work admitted before it"
				: !waitedForHandler && !freedBeforeRelease && valueAtFree == kMarker ? "FAIL: vkFreeMemory returned once C's work ended, before its completed handler did"
				: freedBeforeRelease ? "FAIL: vkFreeMemory returned while pending work could still write the imported pages"
				: "FAIL: vkFreeMemory returned after the release, but without the pending work's value in the pages");
	vkDestroyBuffer(c.device, buffer, nullptr);
	vkDestroyCommandPool(c.device, pool, nullptr);
	[external release];
	[unknown release];
	std::free(latePages);
	return pass ? 0 : 1;
}

int hostSync(Context& c, const std::string& mode) {
	bool isCopy = mode == "host-sync-progress-copy" || mode == "host-sync-admission-copy";
	bool isProgress = mode == "host-sync-progress-invalidate" || mode == "host-sync-progress-copy";
	bool isDry = getenv("PERVERTEX_HOST_SYNC_DRY") != nullptr;
	bool isUnified = c.mtlDevice.hasUnifiedMemory;
	VkPhysicalDeviceMemoryProperties memoryProperties;
	vkGetPhysicalDeviceMemoryProperties(c.physical, &memoryProperties);
	uint32_t managedType = UINT32_MAX, coherentType = UINT32_MAX;
	for (uint32_t i = 0; i < memoryProperties.memoryTypeCount; ++i) {
		VkMemoryPropertyFlags flags = memoryProperties.memoryTypes[i].propertyFlags;
		if (!(flags & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT)) { continue; }
		uint32_t& type = (flags & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) ? coherentType : managedType;
		if (type == UINT32_MAX) { type = i; }
	}
	bool isManaged = !isUnified && managedType != UINT32_MAX;
	std::printf("device=\"%s\" unified_memory=%d managed_type=%d host_image_copy=%d dry=%d\n", c.mtlDevice.name.UTF8String, int(isUnified),
				int(managedType), int(gHasHostImageCopy), int(isDry));
	if (!isManaged && !isDry) { std::printf("HOST_SYNC SKIP: MoltenVK synchronizes managed memory only on a Mac without unified memory\n"); return 3; }
	if (isCopy && !gHasHostImageCopy) { std::printf("HOST_SYNC SKIP: the device does not expose VK_EXT_host_image_copy\n"); return 3; }
	uint32_t type = isManaged ? managedType : coherentType;
	if (type == UINT32_MAX) { std::fprintf(stderr, "No host-visible memory type\n"); return 3; }

	// The synchronized resource: the mapped memory itself, or a linear image bound to it.
	VkPhysicalDeviceExternalMemoryHostPropertiesEXT hostProperties{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_MEMORY_HOST_PROPERTIES_EXT};
	VkPhysicalDeviceProperties2 properties{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2};
	properties.pNext = &hostProperties;
	vkGetPhysicalDeviceProperties2(c.physical, &properties);
	VkDeviceSize alignment = std::max<VkDeviceSize>(hostProperties.minImportedHostPointerAlignment, 16384);
	constexpr uint32_t kSide = 16;
	VkImage image = VK_NULL_HANDLE;
	VkDeviceSize size = alignment;
	if (isCopy) {
		VkImageCreateInfo imageInfo{VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO};
		imageInfo.imageType = VK_IMAGE_TYPE_2D;
		imageInfo.format = VK_FORMAT_R8G8B8A8_UNORM;
		imageInfo.extent = {kSide, kSide, 1};
		imageInfo.mipLevels = imageInfo.arrayLayers = 1;
		imageInfo.samples = VK_SAMPLE_COUNT_1_BIT;
		imageInfo.tiling = VK_IMAGE_TILING_LINEAR;
		imageInfo.usage = VK_IMAGE_USAGE_HOST_TRANSFER_BIT_EXT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
		imageInfo.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
		VkImageFormatProperties formatProperties;
		if (vkGetPhysicalDeviceImageFormatProperties(c.physical, imageInfo.format, imageInfo.imageType, imageInfo.tiling, imageInfo.usage, 0,
													 &formatProperties) != VK_SUCCESS) {
			std::printf("HOST_SYNC SKIP: no linear R8G8B8A8 image with host transfer\n");
			return 3;
		}
		check(vkCreateImage(c.device, &imageInfo, nullptr, &image), "vkCreateImage");
		VkMemoryRequirements requirements;
		vkGetImageMemoryRequirements(c.device, image, &requirements);
		if (!(requirements.memoryTypeBits & (1u << type))) { std::printf("HOST_SYNC SKIP: the image cannot use memory type %u\n", type); return 3; }
		size = (requirements.size + alignment - 1) / alignment * alignment;
	}
	void* pages = nullptr;
	if (posix_memalign(&pages, size_t(alignment), size_t(size))) { std::fprintf(stderr, "posix_memalign\n"); return 2; }
	std::memset(pages, 0, size_t(size));
	VkMemoryHostPointerPropertiesEXT pointerProperties{VK_STRUCTURE_TYPE_MEMORY_HOST_POINTER_PROPERTIES_EXT};
	check(vkGetMemoryHostPointerPropertiesEXT(c.device, VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT, pages, &pointerProperties),
		  "vkGetMemoryHostPointerPropertiesEXT");
	if (!(pointerProperties.memoryTypeBits & (1u << type))) { std::printf("HOST_SYNC SKIP: host memory cannot be imported as type %u\n", type); return 3; }
	VkImportMemoryHostPointerInfoEXT imported{VK_STRUCTURE_TYPE_IMPORT_MEMORY_HOST_POINTER_INFO_EXT};
	imported.handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT;
	imported.pHostPointer = pages;
	VkMemoryAllocateInfo allocation{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
	allocation.pNext = &imported;
	allocation.allocationSize = size;
	allocation.memoryTypeIndex = type;
	VkDeviceMemory memory;
	check(vkAllocateMemory(c.device, &allocation, nullptr, &memory), "vkAllocateMemory");
	void* mapped = nullptr;
	check(vkMapMemory(c.device, memory, 0, VK_WHOLE_SIZE, 0, &mapped), "vkMapMemory");
	std::vector<uint32_t> copied(kSide * kSide);
	auto transitionLayout = reinterpret_cast<PFN_vkTransitionImageLayoutEXT>(vkGetDeviceProcAddr(c.device, "vkTransitionImageLayoutEXT"));
	auto copyImageToMemory = reinterpret_cast<PFN_vkCopyImageToMemoryEXT>(vkGetDeviceProcAddr(c.device, "vkCopyImageToMemoryEXT"));
	if (isCopy) {
		if (!transitionLayout || !copyImageToMemory) { std::fprintf(stderr, "No VK_EXT_host_image_copy entry points\n"); return 2; }
		check(vkBindImageMemory(c.device, image, memory, 0), "vkBindImageMemory");
		VkHostImageLayoutTransitionInfoEXT transition{VK_STRUCTURE_TYPE_HOST_IMAGE_LAYOUT_TRANSITION_INFO_EXT};
		transition.image = image;
		transition.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
		transition.newLayout = VK_IMAGE_LAYOUT_GENERAL;
		transition.subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
		check(transitionLayout(c.device, 1, &transition), "vkTransitionImageLayoutEXT");
	}
	VkMappedMemoryRange range{VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE};
	range.memory = memory;
	range.size = VK_WHOLE_SIZE;
	auto synchronize = [&] {
		if (!isCopy) { return vkInvalidateMappedMemoryRanges(c.device, 1, &range); }
		VkImageToMemoryCopyEXT region{VK_STRUCTURE_TYPE_IMAGE_TO_MEMORY_COPY_EXT};
		region.pHostPointer = copied.data();
		region.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1};
		region.imageExtent = {kSide, kSide, 1};
		VkCopyImageToMemoryInfoEXT copy{VK_STRUCTURE_TYPE_COPY_IMAGE_TO_MEMORY_INFO_EXT};
		copy.srcImage = image;
		copy.srcImageLayout = VK_IMAGE_LAYOUT_GENERAL;
		copy.regionCount = 1;
		copy.pRegions = &region;
		return copyImageToMemory(c.device, &copy);
	};

	// MoltenVK acquires the synchronization's command buffer from queue A (MVKDevice::getAnyQueue()).
	installHandlerHooks(c);
	id<MTLCommandQueue> mtlQueue = exportedQueue(c.device, c.qa);
	if (!mtlQueue) { std::fprintf(stderr, "No exported MTLCommandQueue\n"); return 3; }
	gCountedQueue = mtlQueue;
	auto getLossCounters = reinterpret_cast<void (*)(VkDevice, int64_t*, uint32_t*)>(dlsym(RTLD_DEFAULT, "mvkTestGetLossCounters"));
	if (!getLossCounters) { std::fprintf(stderr, "Needs a MoltenVK test build with mvkTestGetLossCounters\n"); return 3; }
	int64_t pendingHandlers = 0;
	uint32_t activeEncodings = 0;
	bool pass = false;
	if (isProgress) {
		id<MTLSharedEvent> unknown = [c.mtlDevice newSharedEvent];
		std::vector<id<MTLCommandBuffer>> held;
		for (int i = 0; i < 4; ++i) {	// as many as MVK_CONFIG_MAX_ACTIVE_METAL_COMMAND_BUFFERS_PER_QUEUE, as the runner sets it
			id<MTLCommandBuffer> external = [[mtlQueue commandBuffer] retain];
			[external encodeWaitForEvent: unknown value: 1];
			[external commit];
			held.push_back(external);
		}
		std::atomic<bool> returned{false};
		VkResult result = VK_NOT_READY;
		std::thread synchronizer([&] { result = synchronize(); returned = true; });
		sleepMs(100);
		int acquiringBeforeLoss = gAcquiring.load();
		c.markLost(c.device);
		gCountCommits = true;
		sleepMs(100);
		getLossCounters(c.device, &pendingHandlers, &activeEncodings);
		int acquiring = gAcquiring.load();
		bool stillBlocked = !returned;
		unknown.signaledValue = 1;	// the application releases its own work
		for (id<MTLCommandBuffer> external : held) { [external waitUntilCompleted]; [external release]; }
		synchronizer.join();
		gCountCommits = false;
		std::printf("acquiring_before_loss=%d acquiring_100ms_after_loss=%d still_blocked=%d active_encodings=%u pending_handlers=%lld "
					"result=%d commits_after_loss=%d\n", acquiringBeforeLoss, acquiring, int(stillBlocked), activeEncodings, (long long)pendingHandlers,
					int(result), gCommitsCounted.load());
		bool forced = acquiring == 1 && stillBlocked;
		pass = forced && activeEncodings == 0;
		std::printf("HOST_SYNC %s\n", isDry ? "DRY: the calls ran on a coherent memory type; nothing was acquired, so this proves nothing"
					: pass ? "PASS: a synchronization blocked acquiring its command buffer does not hold the loss report back"
					: !forced ? "FAIL: the synchronization was not blocked in its acquisition, so the interleaving was not forced"
					: "FAIL: an encoding holds the loss report back while the synchronization is blocked acquiring its command buffer");
		[unknown release];
	} else {
		// The first synchronization acquires its command buffer before the loss, and gets it only after the loss began.
		gAcquireDelayUs = 300000;
		VkResult first = VK_NOT_READY;
		std::thread synchronizer([&] { first = synchronize(); });
		sleepMs(100);
		c.markLost(c.device);
		gCountCommits = true;
		synchronizer.join();
		int firstCommits = gCommitsCounted.exchange(0);
		bool consumed = gAcquireDelayUs.exchange(0) == 0;
		// Once the loss is reported, the second one begins after the loss inventory is closed. vkDeviceWaitIdle() itself
		// commits an empty command buffer to each queue (MVKQueue::waitIdle()), which is not a synchronization.
		VkResult waited = vkDeviceWaitIdle(c.device);
		gCommitsCounted = 0;
		VkResult second = synchronize();
		int secondCommits = gCommitsCounted.load();
		gCountCommits = false;
		std::printf("acquisition_delayed=%d first: result=%d commits_after_loss=%d; device_wait_idle=%d; second: result=%d commits=%d\n", int(consumed),
					int(first), firstCommits, int(waited), int(second), secondCommits);
		bool forced = consumed;
		pass = forced && waited == VK_ERROR_DEVICE_LOST && firstCommits == 0 && secondCommits == 0;
		std::printf("HOST_SYNC %s\n", isDry ? "DRY: the calls ran on a coherent memory type; nothing was acquired, so this proves nothing"
					: pass ? "PASS: no synchronization commits a Metal command buffer once the loss has begun"
					: !forced ? "FAIL: the synchronization did not acquire a command buffer, so the interleaving was not forced"
					: secondCommits ? "FAIL: a synchronization begun after the loss report commits work the closed inventory does not count"
					: firstCommits ? "FAIL: a synchronization admitted once the loss had begun commits its command buffer"
					: "FAIL: the loss was not reported");
	}
	gCountedQueue = nil;
	if (image) { vkDestroyImage(c.device, image, nullptr); }
	vkUnmapMemory(c.device, memory);
	vkFreeMemory(c.device, memory, nullptr);
	std::free(pages);
	return isDry ? 0 : pass ? 0 : 1;
}

// Destroys the device and the instance itself.
int deviceDestroy(Context& c, bool isAfterReport) {
	id<MTLCommandQueue> mtlQueue = exportedQueue(c.device, c.qb);
	if (!mtlQueue) { std::fprintf(stderr, "No exported MTLCommandQueue\n"); return 3; }
	id<MTLSharedEvent> unknown = [c.mtlDevice newSharedEvent];
	id<MTLCommandBuffer> external = [[mtlQueue commandBuffer] retain];
	[external encodeWaitForEvent: unknown value: 1];
	[external commit];
	Buffer target = c.buffer(4096, false);
	VkCommandPool pool = commandPool(c);
	VkCommandBufferAllocateInfo commandInfo{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
	commandInfo.commandPool = pool;
	commandInfo.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
	commandInfo.commandBufferCount = 1;
	VkCommandBuffer commands;
	check(vkAllocateCommandBuffers(c.device, &commandInfo, &commands), "vkAllocateCommandBuffers");
	VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
	check(vkBeginCommandBuffer(commands, &begin), "vkBeginCommandBuffer");
	vkCmdFillBuffer(commands, target.buffer, 0, 4096, kMarker);
	check(vkEndCommandBuffer(commands), "vkEndCommandBuffer");
	VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO};
	submit.commandBufferCount = 1;
	submit.pCommandBuffers = &commands;
	check(vkQueueSubmit(c.qb, 1, &submit, VK_NULL_HANDLE), "vkQueueSubmit");
	sleepMs(50);
	auto ms = [](std::chrono::steady_clock::time_point from) {
		return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - from).count();
	};
	c.markLost(c.device);
	auto lost = std::chrono::steady_clock::now();
	double reportMs = -1, destroyMs = -1, releaseMs = -1;
	VkResult waited = VK_NOT_READY;
	if (isAfterReport) {
		std::thread waiter([&] { waited = vkDeviceWaitIdle(c.device); reportMs = ms(lost); });
		sleepMs(300);
		releaseMs = ms(lost);
		unknown.signaledValue = 1;	// the application releases its own work
		waiter.join();
		[external waitUntilCompleted];
		// The loss is reported: Vulkan considers C complete, and lets the application destroy what it used.
		vkDestroyCommandPool(c.device, pool, nullptr);
		c.destroy(target);
		auto start = std::chrono::steady_clock::now();
		vkDestroyDevice(c.device, nullptr);
		destroyMs = ms(start);
	} else {
		std::atomic<bool> destroyed{false};
		std::thread destroyer([&] {
			sleepMs(100);
			auto start = std::chrono::steady_clock::now();
			vkDestroyDevice(c.device, nullptr);	// C's objects are leaked: destroying them could crash, which is R1's subject
			destroyMs = ms(start);
			destroyed = true;
		});
		sleepMs(300);
		releaseMs = ms(lost);
		unknown.signaledValue = 1;
		destroyer.join();
		[external waitUntilCompleted];
	}
	vkDestroyInstance(c.instance, nullptr);
	std::printf("loss_at=0 ms release_at=%.0f ms report_at=%.0f ms (wait=%d) destroy_device=%.1f ms\n", releaseMs, reportMs, int(waited), destroyMs);
	std::printf("DEVICE_DESTROY %s\n", isAfterReport
				? destroyMs < 50 ? "PASS: after the loss report, vkDestroyDevice returns at once" : "FAIL: after the loss report, vkDestroyDevice still waits"
				: "MEASURED: vkDestroyDevice before the loss report (invalid usage today)");
	[external release];
	[unknown release];
	return isAfterReport && destroyMs >= 50 ? 1 : 0;
}

int queryWaitAbandoned(Context& c) {
	installHandlerHooks(c);
	VkQueryPoolCreateInfo queryInfo{VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO};
	queryInfo.queryType = VK_QUERY_TYPE_TIMESTAMP;
	queryInfo.queryCount = 1;
	VkQueryPool queries;
	check(vkCreateQueryPool(c.device, &queryInfo, nullptr, &queries), "vkCreateQueryPool");
	VkCommandPool pool = commandPool(c);
	VkCommandBufferAllocateInfo allocation{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
	allocation.commandPool = pool;
	allocation.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
	allocation.commandBufferCount = 1;
	VkCommandBuffer commands;
	check(vkAllocateCommandBuffers(c.device, &allocation, &commands), "vkAllocateCommandBuffers");
	VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
	check(vkBeginCommandBuffer(commands, &begin), "vkBeginCommandBuffer");
	vkCmdResetQueryPool(commands, queries, 0, 1);
	vkCmdWriteTimestamp(commands, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, queries, 0);
	check(vkEndCommandBuffer(commands), "vkEndCommandBuffer");	// prefilled: the query is encoded now
	// The queue's worker is held by an empty submission whose Metal command buffer acquisition returns 300 ms later.
	gAcquireDelayUs = 300000;
	VkFenceCreateInfo fenceInfo{VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
	VkFence fence;
	check(vkCreateFence(c.device, &fenceInfo, nullptr, &fence), "vkCreateFence");
	check(vkQueueSubmit(c.qb, 0, nullptr, fence), "vkQueueSubmit (holder)");
	VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO};
	submit.commandBufferCount = 1;
	submit.pCommandBuffers = &commands;
	VkResult submitted = vkQueueSubmit(c.qb, 1, &submit, VK_NULL_HANDLE);
	auto start = std::chrono::steady_clock::now();
	auto ms = [&] { return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count(); };
	std::atomic<bool> returned{false};
	std::atomic<double> returnedAt{-1};
	VkResult waitResult = VK_NOT_READY;
	uint64_t timestamp = 0;
	std::thread waiter([&] {
		waitResult = vkGetQueryPoolResults(c.device, queries, 0, 1, sizeof(timestamp), &timestamp, sizeof(timestamp),
										   VK_QUERY_RESULT_64_BIT | VK_QUERY_RESULT_WAIT_BIT);
		returnedAt = ms();
		returned = true;
	});
	sleepMs(100);
	bool returnedBeforeLoss = returned;
	c.markLost(c.device);
	double lostAt = ms();
	VkResult idle = vkDeviceWaitIdle(c.device);	// returns once the loss is reported
	double reportedAt = ms();
	bool consumed = gAcquireDelayUs.exchange(0) == 0;
	while (!returned && ms() < reportedAt + 2000) { sleepMs(5); }
	bool reportsLoss = waitResult == VK_ERROR_DEVICE_LOST || waitResult == VK_SUCCESS;	// VK_NOT_READY is not allowed with WAIT_BIT
	bool pass = returned && !returnedBeforeLoss && submitted == VK_SUCCESS && consumed && reportsLoss;
	std::printf("submit=%d holder_delayed=%d waited_before_loss=%d loss_at=%.0f ms reported_at=%.0f ms (idle=%d) wait_returned=%d at=%.0f ms result=%d\n",
				int(submitted), int(consumed), int(!returnedBeforeLoss), lostAt, reportedAt, int(idle), int(returned.load()), returnedAt.load(), int(waitResult));
	std::printf("QUERY_WAIT %s\n", pass ? "PASS: the query wait returned once the loss was reported"
				: !consumed || submitted != VK_SUCCESS ? "FAIL: the interleaving was not forced"
				: returnedBeforeLoss ? "FAIL: the query wait returned before the loss"
				: returned ? "FAIL: the query wait returned neither VK_SUCCESS nor VK_ERROR_DEVICE_LOST"
				: "FAIL: the query wait still waits 2 s after the loss report, for a query that no command buffer will write");
	std::fflush(stdout);
	if (!returned) { std::_Exit(1); }	// the wait still uses the query pool: do not destroy it
	waiter.join();
	vkDestroyFence(c.device, fence, nullptr);
	vkDestroyCommandPool(c.device, pool, nullptr);
	vkDestroyQueryPool(c.device, queries, nullptr);
	return pass ? 0 : 1;
}

// A swapchain of 3 images on a CAMetalLayer detached from any window.
struct Presentation {
	CAMetalLayer* layer = nil;
	VkSurfaceKHR surface = VK_NULL_HANDLE;
	VkSwapchainKHR swapchain = VK_NULL_HANDLE;
	uint32_t imageCount = 0;
};

Presentation createPresentation(Context& c) {
	Presentation p;
	p.layer = [[CAMetalLayer layer] retain];
	p.layer.device = c.mtlDevice;
	p.layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
	p.layer.drawableSize = CGSizeMake(64, 64);
	VkMetalSurfaceCreateInfoEXT surfaceInfo{VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT};
	surfaceInfo.pLayer = p.layer;
	check(vkCreateMetalSurfaceEXT(c.instance, &surfaceInfo, nullptr, &p.surface), "vkCreateMetalSurfaceEXT");
	VkBool32 supported = VK_FALSE;
	check(vkGetPhysicalDeviceSurfaceSupportKHR(c.physical, c.familyB, p.surface, &supported), "vkGetPhysicalDeviceSurfaceSupportKHR");
	if (!supported) { std::fprintf(stderr, "Queue B cannot present\n"); std::exit(3); }
	VkSwapchainCreateInfoKHR info{VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR};
	info.surface = p.surface;
	info.minImageCount = 3;
	info.imageFormat = VK_FORMAT_B8G8R8A8_UNORM;
	info.imageColorSpace = VK_COLOR_SPACE_SRGB_NONLINEAR_KHR;
	info.imageExtent = {64, 64};
	info.imageArrayLayers = 1;
	info.imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
	info.imageSharingMode = VK_SHARING_MODE_EXCLUSIVE;
	info.preTransform = VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR;
	info.compositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
	info.presentMode = VK_PRESENT_MODE_FIFO_KHR;
	info.clipped = VK_TRUE;
	check(vkCreateSwapchainKHR(c.device, &info, nullptr, &p.swapchain), "vkCreateSwapchainKHR");
	check(vkGetSwapchainImagesKHR(c.device, p.swapchain, &p.imageCount, nullptr), "vkGetSwapchainImagesKHR");
	return p;
}

// One round: every image presented, the first one acquired with the watched semaphore, then the queue idle and the
// swapchain destroyed. Reports how many presentations had begun when the swapchain was destroyed
// (mvkTestGetUnpresentedImageCount, -1 without it), and whether the watched event was freed within 5 s.
struct PresentRound {
	int begunAtDestroy = -1;
	bool eventFreed = false;
};

PresentRound presentRound(Context& c, Presentation& p, bool gated) {
	PresentRound round;
	auto unpresented = reinterpret_cast<uint32_t (*)(VkSwapchainKHR)>(dlsym(RTLD_DEFAULT, "mvkTestGetUnpresentedImageCount"));
	id<MTLSharedEvent> watchedEvent = [c.mtlDevice newSharedEvent];
	VkSemaphore watched = importedSemaphore(c, watchedEvent, false);
	id weakEvent = nil;
	objc_storeWeak(&weakEvent, watchedEvent);
	[watchedEvent release];		// only MoltenVK's semaphore keeps it now
	VkFenceCreateInfo fenceInfo{VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
	VkFence acquired;
	check(vkCreateFence(c.device, &fenceInfo, nullptr, &acquired), "vkCreateFence");
	id<MTLSharedEvent> gate = [c.mtlDevice newSharedEvent];
	gate.signaledValue = 0;
	VkSemaphore timeline = gated ? importedSemaphore(c, gate, true) : VK_NULL_HANDLE;
	VkCommandPool pool = commandPool(c);
	std::vector<VkSemaphore> rendered(p.imageCount, VK_NULL_HANDLE);
	for (uint32_t i = 0; i < p.imageCount; ++i) {
		uint32_t index = 0;
		// A layer outside any window is suboptimal, which still acquires the image.
		VkResult acquire = vkAcquireNextImageKHR(c.device, p.swapchain, UINT64_MAX, i == 0 ? watched : VK_NULL_HANDLE, acquired, &index);
		if (acquire != VK_SUCCESS && acquire != VK_SUBOPTIMAL_KHR) { std::fprintf(stderr, "vkAcquireNextImageKHR: %d\n", int(acquire)); std::exit(2); }
		check(vkWaitForFences(c.device, 1, &acquired, VK_TRUE, UINT64_MAX), "acquire fence");
		check(vkResetFences(c.device, 1, &acquired), "vkResetFences");
		VkPresentInfoKHR present{VK_STRUCTURE_TYPE_PRESENT_INFO_KHR};
		present.swapchainCount = 1;
		present.pSwapchains = &p.swapchain;
		present.pImageIndices = &index;
		if (gated) {
			VkSemaphoreCreateInfo semaphoreInfo{VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
			check(vkCreateSemaphore(c.device, &semaphoreInfo, nullptr, &rendered[i]), "vkCreateSemaphore");
			VkCommandBufferAllocateInfo allocation{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
			allocation.commandPool = pool;
			allocation.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
			allocation.commandBufferCount = 1;
			VkCommandBuffer commands;
			check(vkAllocateCommandBuffers(c.device, &allocation, &commands), "vkAllocateCommandBuffers");
			VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
			check(vkBeginCommandBuffer(commands, &begin), "vkBeginCommandBuffer");
			check(vkEndCommandBuffer(commands), "vkEndCommandBuffer");
			uint64_t waitValue = 1, signalValue = 0;
			VkTimelineSemaphoreSubmitInfo values{VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO};
			values.waitSemaphoreValueCount = 1;
			values.pWaitSemaphoreValues = &waitValue;
			values.signalSemaphoreValueCount = 1;
			values.pSignalSemaphoreValues = &signalValue;
			VkPipelineStageFlags stage = VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT;
			VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO};
			submit.pNext = &values;
			submit.waitSemaphoreCount = 1;
			submit.pWaitSemaphores = &timeline;
			submit.pWaitDstStageMask = &stage;
			submit.commandBufferCount = 1;
			submit.pCommandBuffers = &commands;
			submit.signalSemaphoreCount = 1;
			submit.pSignalSemaphores = &rendered[i];
			check(vkQueueSubmit(c.qb, 1, &submit, VK_NULL_HANDLE), "vkQueueSubmit");
			present.waitSemaphoreCount = 1;
			present.pWaitSemaphores = &rendered[i];
		}
		VkResult presented = vkQueuePresentKHR(c.qb, &present);
		if (presented != VK_SUCCESS && presented != VK_SUBOPTIMAL_KHR) { std::fprintf(stderr, "vkQueuePresentKHR: %d\n", int(presented)); std::exit(2); }
	}
	if (gated) {
		sleepMs(200);
	} else {
		// Every presentation's command buffer has completed: destroying the swapchain is now valid.
		check(vkQueueWaitIdle(c.qb), "vkQueueWaitIdle");
	}
	if (unpresented) { round.begunAtDestroy = int(unpresented(p.swapchain)); }
	vkDestroySwapchainKHR(c.device, p.swapchain, nullptr);
	p.swapchain = VK_NULL_HANDLE;
	vkDestroySemaphore(c.device, watched, nullptr);
	if (gated) {
		gate.signaledValue = 1;
		check(vkQueueWaitIdle(c.qb), "vkQueueWaitIdle");
	}
	for (VkSemaphore semaphore : rendered) { if (semaphore) { vkDestroySemaphore(c.device, semaphore, nullptr); } }
	if (timeline) { vkDestroySemaphore(c.device, timeline, nullptr); }
	vkDestroyCommandPool(c.device, pool, nullptr);
	vkDestroyFence(c.device, acquired, nullptr);
	[gate release];
	// Late handlers, delayed by the hooks, may still release it: wait up to 5 s.
	auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
	do {
		@autoreleasepool { round.eventFreed = objc_loadWeak(&weakEvent) == nil; }
		if (!round.eventFreed) { sleepMs(10); }
	} while (!round.eventFreed && std::chrono::steady_clock::now() < deadline);
	objc_storeWeak(&weakEvent, nil);
	return round;
}

// drawable-wait-loss: nextDrawable, as MoltenVK calls it on the layer of a swapchain, is timed through a swizzle.
std::atomic<int> gNextDrawableCalls{0}, gNextDrawableInside{0};
std::atomic<double> gNextDrawableEnteredMs{-1}, gNextDrawableReturnedMs{-1};
std::atomic<uint64_t> gNextDrawableThread{0};
std::chrono::steady_clock::time_point gDrawableClock = std::chrono::steady_clock::now();
id gLateDrawable = nil;		// weak: the drawable the timed call returned
int gTimedNextDrawableCall = 0;	// the call to time, counted from 1
IMP gNextDrawable = nullptr;

double drawableClockMs() { return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - gDrawableClock).count(); }

id nextDrawableTimed(id self, SEL command) {
	int call = ++gNextDrawableCalls;
	bool isTimed = call == gTimedNextDrawableCall;
	if (isTimed) {
		uint64_t thread = 0;
		pthread_threadid_np(nullptr, &thread);
		gNextDrawableThread = thread;
		gNextDrawableEnteredMs = drawableClockMs();
		gNextDrawableInside = 1;
	}
	id drawable = reinterpret_cast<id (*)(id, SEL)>(gNextDrawable)(self, command);
	if (isTimed) {
		objc_storeWeak(&gLateDrawable, drawable);
		gNextDrawableReturnedMs = drawableClockMs();
		gNextDrawableInside = 0;
	}
	// PERVERTEX_DRAWABLE_NIL=1: from the timed call on, every call returns nil, as when every attempt of MoltenVK times
	// out, to exercise its nil path.
	if (gTimedNextDrawableCall && call >= gTimedNextDrawableCall && getenv("PERVERTEX_DRAWABLE_NIL")) { return nil; }
	return drawable;
}

VkSwapchainKHR createSwapchain(Context& c, VkSurfaceKHR surface, VkSwapchainKHR oldSwapchain) {
	VkSwapchainCreateInfoKHR info{VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR};
	info.surface = surface;
	info.minImageCount = 3;
	info.imageFormat = VK_FORMAT_B8G8R8A8_UNORM;
	info.imageColorSpace = VK_COLOR_SPACE_SRGB_NONLINEAR_KHR;
	info.imageExtent = {64, 64};	// the same extent, so that MoltenVK forces the old swapchain's presentations to complete
	info.imageArrayLayers = 1;
	info.imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT;
	info.imageSharingMode = VK_SHARING_MODE_EXCLUSIVE;
	info.preTransform = VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR;
	info.compositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
	info.presentMode = VK_PRESENT_MODE_FIFO_KHR;
	info.clipped = VK_TRUE;
	info.oldSwapchain = oldSwapchain;
	VkSwapchainKHR swapchain;
	check(vkCreateSwapchainKHR(c.device, &info, nullptr, &swapchain), "vkCreateSwapchainKHR");
	return swapchain;
}

uint32_t acquireImage(Context& c, VkSwapchainKHR swapchain, VkFence fence) {
	uint32_t index = 0;
	// A layer outside any window is suboptimal, which still acquires the image. A finite timeout lets the application
	// hold more images than the swapchain has beyond its minimum count.
	VkResult acquired = vkAcquireNextImageKHR(c.device, swapchain, 1000000000, VK_NULL_HANDLE, fence, &index);
	if (acquired != VK_SUCCESS && acquired != VK_SUBOPTIMAL_KHR) { std::fprintf(stderr, "vkAcquireNextImageKHR: %d\n", int(acquired)); std::exit(2); }
	check(vkWaitForFences(c.device, 1, &fence, VK_TRUE, UINT64_MAX), "acquire fence");
	check(vkResetFences(c.device, 1, &fence), "vkResetFences");
	return index;
}

// Records a command buffer that clears the given images, which makes MoltenVK take each one's drawable while encoding.
VkCommandBuffer clearImages(Context& c, VkCommandPool pool, const std::vector<VkImage>& images) {
	VkCommandBufferAllocateInfo allocation{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
	allocation.commandPool = pool;
	allocation.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
	allocation.commandBufferCount = 1;
	VkCommandBuffer commands;
	check(vkAllocateCommandBuffers(c.device, &allocation, &commands), "vkAllocateCommandBuffers");
	VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
	check(vkBeginCommandBuffer(commands, &begin), "vkBeginCommandBuffer");
	VkImageSubresourceRange range{VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
	for (VkImage image : images) {
		VkImageMemoryBarrier barrier{VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER};
		barrier.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
		barrier.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
		barrier.newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
		barrier.srcQueueFamilyIndex = barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
		barrier.image = image;
		barrier.subresourceRange = range;
		vkCmdPipelineBarrier(commands, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, nullptr, 0, nullptr, 1, &barrier);
		VkClearColorValue color{{0.2f, 0.4f, 0.6f, 1.0f}};
		vkCmdClearColorImage(commands, image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &color, 1, &range);
	}
	check(vkEndCommandBuffer(commands), "vkEndCommandBuffer");
	return commands;
}

int drawableWaitLoss(Context& c) {
	auto getLossCounters = reinterpret_cast<void (*)(VkDevice, int64_t*, uint32_t*)>(dlsym(RTLD_DEFAULT, "mvkTestGetLossCounters"));
	auto unpresented = reinterpret_cast<uint32_t (*)(VkSwapchainKHR)>(dlsym(RTLD_DEFAULT, "mvkTestGetUnpresentedImageCount"));
	if (!getLossCounters || !unpresented) { std::fprintf(stderr, "Needs a MoltenVK test build with mvkTestGetLossCounters and mvkTestGetUnpresentedImageCount\n"); return 3; }
	gNextDrawable = replace([CAMetalLayer class], @selector(nextDrawable), reinterpret_cast<IMP>(nextDrawableTimed));
	CAMetalLayer* layer = [[CAMetalLayer layer] retain];	// detached from any window
	layer.device = c.mtlDevice;
	layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
	layer.drawableSize = CGSizeMake(64, 64);
	VkMetalSurfaceCreateInfoEXT surfaceInfo{VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT};
	surfaceInfo.pLayer = layer;
	VkSurfaceKHR surface;
	check(vkCreateMetalSurfaceEXT(c.instance, &surfaceInfo, nullptr, &surface), "vkCreateMetalSurfaceEXT");
	VkBool32 supported = VK_FALSE;
	check(vkGetPhysicalDeviceSurfaceSupportKHR(c.physical, c.familyB, surface, &supported), "vkGetPhysicalDeviceSurfaceSupportKHR");
	if (!supported) { std::fprintf(stderr, "Queue B cannot present\n"); return 3; }
	VkFenceCreateInfo fenceInfo{VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
	VkFence fence;
	check(vkCreateFence(c.device, &fenceInfo, nullptr, &fence), "vkCreateFence");
	VkCommandPool pool = commandPool(c);

	// 1. The old swapchain: two images presented behind the application's blocked work, a third acquired and kept.
	VkSwapchainKHR oldSwapchain = createSwapchain(c, surface, VK_NULL_HANDLE);
	uint32_t count = 0;
	check(vkGetSwapchainImagesKHR(c.device, oldSwapchain, &count, nullptr), "vkGetSwapchainImagesKHR");
	std::vector<VkImage> oldImages(count);
	check(vkGetSwapchainImagesKHR(c.device, oldSwapchain, &count, oldImages.data()), "vkGetSwapchainImagesKHR");
	if (count < 3) { std::fprintf(stderr, "The swapchain has fewer than 3 images\n"); return 3; }
	id<MTLSharedEvent> gate = [c.mtlDevice newSharedEvent];
	VkSemaphore timeline = importedSemaphore(c, gate, true);
	VkSemaphoreCreateInfo semaphoreInfo{VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
	std::vector<VkSemaphore> rendered(2, VK_NULL_HANDLE);
	VkCommandBufferAllocateInfo allocation{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
	allocation.commandPool = pool;
	allocation.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
	allocation.commandBufferCount = 1;
	VkCommandBuffer empty;
	check(vkAllocateCommandBuffers(c.device, &allocation, &empty), "vkAllocateCommandBuffers");
	VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
	check(vkBeginCommandBuffer(empty, &begin), "vkBeginCommandBuffer");
	check(vkEndCommandBuffer(empty), "vkEndCommandBuffer");
	for (int i = 0; i < 2; ++i) {
		uint32_t index = acquireImage(c, oldSwapchain, fence);
		check(vkCreateSemaphore(c.device, &semaphoreInfo, nullptr, &rendered[i]), "vkCreateSemaphore");
		uint64_t waitValue = 1, signalValue = 0;
		VkTimelineSemaphoreSubmitInfo values{VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO};
		values.waitSemaphoreValueCount = 1;
		values.pWaitSemaphoreValues = &waitValue;
		values.signalSemaphoreValueCount = 1;
		values.pSignalSemaphoreValues = &signalValue;
		VkPipelineStageFlags stage = VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT;
		VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO};
		submit.pNext = &values;
		submit.waitSemaphoreCount = 1;
		submit.pWaitSemaphores = &timeline;
		submit.pWaitDstStageMask = &stage;
		submit.commandBufferCount = 1;
		submit.pCommandBuffers = &empty;
		submit.signalSemaphoreCount = 1;
		submit.pSignalSemaphores = &rendered[i];
		check(vkQueueSubmit(c.qb, 1, &submit, VK_NULL_HANDLE), "vkQueueSubmit");
		VkPresentInfoKHR present{VK_STRUCTURE_TYPE_PRESENT_INFO_KHR};
		present.waitSemaphoreCount = 1;
		present.pWaitSemaphores = &rendered[i];
		present.swapchainCount = 1;
		present.pSwapchains = &oldSwapchain;
		present.pImageIndices = &index;
		VkResult presented = vkQueuePresentKHR(c.qb, &present);
		if (presented != VK_SUCCESS && presented != VK_SUBOPTIMAL_KHR) { std::fprintf(stderr, "vkQueuePresentKHR: %d\n", int(presented)); return 2; }
	}
	uint32_t keptIndex = acquireImage(c, oldSwapchain, fence);
	sleepMs(200);
	uint32_t pendingAtRecreate = unpresented(oldSwapchain);

	// 2. The replacement, of the same extent: MoltenVK forces the old swapchain's pending presentations to complete, then
	// the application releases its work. The dropped presentations keep their drawables.
	VkSwapchainKHR newSwapchain = createSwapchain(c, surface, oldSwapchain);
	gate.signaledValue = 1;
	check(vkQueueWaitIdle(c.qb), "vkQueueWaitIdle");

	// 3. Three drawables held: every image of the new swapchain cleared, none presented.
	check(vkGetSwapchainImagesKHR(c.device, newSwapchain, &count, nullptr), "vkGetSwapchainImagesKHR");
	std::vector<VkImage> newImages(count);
	check(vkGetSwapchainImagesKHR(c.device, newSwapchain, &count, newImages.data()), "vkGetSwapchainImagesKHR");
	std::vector<VkImage> held;
	for (uint32_t i = 0; i < count; ++i) { held.push_back(newImages[acquireImage(c, newSwapchain, fence)]); }
	VkCommandBuffer clearHeld = clearImages(c, pool, held);
	VkSubmitInfo submitHeld{VK_STRUCTURE_TYPE_SUBMIT_INFO};
	submitHeld.commandBufferCount = 1;
	submitHeld.pCommandBuffers = &clearHeld;
	check(vkQueueSubmit(c.qb, 1, &submitHeld, VK_NULL_HANDLE), "vkQueueSubmit (held)");
	check(vkQueueWaitIdle(c.qb), "vkQueueWaitIdle");
	int callsBefore = gNextDrawableCalls.load();

	// 4. The kept image of the old swapchain cleared: its encoding asks for the next drawable. The device is lost 50 ms
	// after that call entered, if it has not returned by then.
	gTimedNextDrawableCall = callsBefore + 1;
	VkCommandBuffer clearKept = clearImages(c, pool, {oldImages[keptIndex]});
	double lossMs = -1, reportMs = -1;
	uint32_t activeEncodingsAtLoss = 0, activeEncodingsAfterLoss = 0;
	int insideAtLoss = 0, insideAfterLoss = 0;
	int64_t pendingHandlers = 0;
	VkResult reported = VK_NOT_READY;
	uint64_t submitterThread = 0;
	std::thread watcher([&] {
		auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
		while (std::chrono::steady_clock::now() < deadline
			   && !(gNextDrawableInside && gNextDrawableEnteredMs >= 0 && drawableClockMs() - gNextDrawableEnteredMs >= 50)) { sleepMs(1); }
		insideAtLoss = gNextDrawableInside;
		getLossCounters(c.device, &pendingHandlers, &activeEncodingsAtLoss);
		lossMs = drawableClockMs();
		c.markLost(c.device);
		sleepMs(20);
		insideAfterLoss = gNextDrawableInside;
		getLossCounters(c.device, &pendingHandlers, &activeEncodingsAfterLoss);
		reported = vkDeviceWaitIdle(c.device);
		reportMs = drawableClockMs();
	});
	pthread_threadid_np(nullptr, &submitterThread);
	VkSubmitInfo submitKept{VK_STRUCTURE_TYPE_SUBMIT_INFO};
	submitKept.commandBufferCount = 1;
	submitKept.pCommandBuffers = &clearKept;
	VkResult submitted = vkQueueSubmit(c.qb, 1, &submitKept, VK_NULL_HANDLE);
	watcher.join();
	auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
	while (gNextDrawableInside && std::chrono::steady_clock::now() < deadline) { sleepMs(1); }
	// The drawable the late call returned goes back to the layer once nothing retains it.
	bool lateReleased = false;
	deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
	do {
		@autoreleasepool { lateReleased = objc_loadWeak(&gLateDrawable) == nil; }
		if (!lateReleased) { sleepMs(10); }
	} while (!lateReleased && std::chrono::steady_clock::now() < deadline);
	double enteredMs = gNextDrawableEnteredMs, returnedMs = gNextDrawableReturnedMs;
	bool isSubmitterThread = gNextDrawableThread == submitterThread;
	bool forced = enteredMs >= 0 && enteredMs < lossMs && insideAtLoss;	// entered before the loss, not returned at it
	bool encodingWaits = insideAfterLoss && activeEncodingsAfterLoss > 0;
	bool reportedBeforeReturn = reportMs >= 0 && (returnedMs < 0 || reportMs < returnedMs);
	bool pass = forced && !encodingWaits && reportedBeforeReturn && lateReleased;
	bool skip = !forced && (enteredMs < 0 || returnedMs < lossMs);	// nextDrawable did not wait: this system has no such wait
	std::printf("pending_at_recreate=%u next_drawable_calls=%d timed_call=%d entered=%.0f ms loss=%.0f ms returned=%.0f ms reported=%.0f ms (wait=%d) "
				"submit=%d\n", pendingAtRecreate, gNextDrawableCalls.load(), gTimedNextDrawableCall, enteredMs, lossMs, returnedMs, reportMs, int(reported),
				int(submitted));
	std::printf("at_loss: inside_next_drawable=%d active_encodings=%u; 20_ms_later: inside_next_drawable=%d active_encodings=%u; "
				"next_drawable_on_submitting_thread=%d late_drawable_released=%d\n", insideAtLoss, activeEncodingsAtLoss, insideAfterLoss,
				activeEncodingsAfterLoss, int(isSubmitterThread), int(lateReleased));
	std::printf("DRAWABLE_WAIT %s\n", pass ? "PASS: no encoding waits in nextDrawable; the loss is reported before it returns, and the late drawable is released"
				: skip ? "SKIP: nextDrawable did not wait across the loss on this system, so the interleaving cannot be forced"
				: !forced ? "FAIL: the interleaving was not forced: nextDrawable did not wait across the loss"
				: encodingWaits ? "FAIL: an encoding waits in nextDrawable after the loss began, and holds the loss report back"
				: !reportedBeforeReturn ? "FAIL: the loss was reported only after nextDrawable returned"
				: "FAIL: the late drawable was not released to the layer");
	vkDestroySwapchainKHR(c.device, newSwapchain, nullptr);
	vkDestroySwapchainKHR(c.device, oldSwapchain, nullptr);
	vkDestroySurfaceKHR(c.instance, surface, nullptr);
	for (VkSemaphore semaphore : rendered) { vkDestroySemaphore(c.device, semaphore, nullptr); }
	vkDestroySemaphore(c.device, timeline, nullptr);
	vkDestroyCommandPool(c.device, pool, nullptr);
	vkDestroyFence(c.device, fence, nullptr);
	[gate release];
	[layer release];
	return pass ? 0 : skip ? 3 : 1;
}

int presentation(Context& c, const std::string& mode) {
	bool isGated = mode == "present-pending-destroy";
	if (!isGated) { installHandlerHooks(c); }
	bool isRace = mode == "present-destroy-race";
	int rounds = isRace ? 20 : 1, leaks = 0;
	for (int i = 0; i < rounds; ++i) {
		gHandlerDelayUs = isGated ? 0 : isRace ? useconds_t((i * 157) % 3000) : 300000;
		Presentation p = createPresentation(c);
		PresentRound round = presentRound(c, p, isGated);
		leaks += !round.eventFreed;
		std::printf("round=%d handler_delay_us=%u begun_at_destroy=%d watched_event_freed=%d\n", i, unsigned(gHandlerDelayUs), round.begunAtDestroy,
					int(round.eventFreed));
		vkDestroySurfaceKHR(c.instance, p.surface, nullptr);
		[p.layer release];
	}
	std::printf("PRESENTATION %s\n", leaks ? "FAIL: a presentation never ended: its image and acquire semaphore stayed retained"
				: "PASS: every presentation ended, and released its image and acquire semaphore");
	return leaks ? 1 : 0;
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
	bool isPresentation = mode == "present-scheduled-after-destroy" || mode == "present-destroy-race" || mode == "present-pending-destroy";
	gPresentationModes = isPresentation || mode == "drawable-wait-loss";
	bool isFreeImported = mode == "free-imported-waits" || mode == "free-imported-waits-late-commit" || mode == "free-imported-waits-slow-handler"
		|| mode == "free-imported-late-allocation" || mode == "free-imported-failed-allocation";
	gImportedMemoryModes = isFreeImported;
	gMetalBufferLimit = mode == "free-imported-failed-allocation" ? 65536 : 0;
	bool isHostSync = mode == "host-sync-progress-invalidate" || mode == "host-sync-progress-copy" || mode == "host-sync-admission-invalidate"
		|| mode == "host-sync-admission-copy";
	gImportedMemoryModes |= isHostSync;
	gHostImageCopyModes = mode == "host-sync-progress-copy" || mode == "host-sync-admission-copy";
	gPreferDiscreteGPU = isHostSync;
	if (mode == "query-wait-abandoned") { setenv("MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS", "0", 1); }	// before MoltenVK reads its configuration
	if (mode != "counter-race" && mode != "binary-generation" && mode != "destroy-after-loss" && mode != "event-wait" && !isExternalWait
		&& mode != "shared-queue-block" && mode != "timeline-listener-aba" && !isPresentation && !isFreeImported && !isTeardown && !isPrefill && !isMetalError
		&& !isMetalErrorBatches && !isHostSync && mode != "device-destroy-after-report" && mode != "device-destroy-before-report"
		&& mode != "query-wait-abandoned" && mode != "drawable-wait-loss") {
		std::fprintf(stderr, "usage: %s counter-race|binary-generation|destroy-after-loss|event-wait|external-queue-wait[-idle|-query]|shared-queue-block"
					 "|timeline-listener-aba|teardown[-multi|-nil|-nil-transient]|prefill-abandon-{reset,free,pool}[-lost]"
					 "|metal-error[-multi|-batches|-batches2|-calls]|present-scheduled-after-destroy|present-destroy-race|present-pending-destroy|free-imported-waits[-late-commit|-slow-handler]|free-imported-{late,failed}-allocation"
					 "|host-sync-{progress,admission}-{invalidate,copy}|device-destroy-{after,before}-report|query-wait-abandoned"
					 "|drawable-wait-loss\n", argv[0]);
		return 64;
	}
	@autoreleasepool {
		Context c = createContext();
		if (mode == "device-destroy-after-report" || mode == "device-destroy-before-report") {	// the same
			int rc = deviceDestroy(c, mode == "device-destroy-after-report");
			std::fflush(stdout);
			return rc;
		}
		if (isTeardown) {	// destroys the device and the instance itself
			int rc = teardown(c, mode);
			std::fflush(stdout);
			return rc;
		}
		int rc = mode == "counter-race" ? counterRace(c) : mode == "binary-generation" ? binaryGeneration(c)
			: mode == "event-wait" ? eventWait(c)
			: isExternalWait ? externalQueueWait(c, mode == "external-queue-wait" ? "fence" : mode.substr(std::strlen("external-queue-wait-")))
			: mode == "shared-queue-block" ? sharedQueueBlock(c) : mode == "timeline-listener-aba" ? timelineListenerAba(c)
			: isPresentation ? presentation(c, mode) : isFreeImported ? freeImportedWaits(c, mode) : isHostSync ? hostSync(c, mode)
			: mode == "query-wait-abandoned" ? queryWaitAbandoned(c) : mode == "drawable-wait-loss" ? drawableWaitLoss(c)
			: isPrefill ? prefillAbandon(c, mode) : isMetalError ? metalError(c, mode)
			: isMetalErrorBatches ? metalErrorBatches(c, mode) : destroyAfterLoss(c);
		std::fflush(stdout);
		// The device is lost: destroying it is still valid, idle waits would only report the loss.
		vkDestroyDevice(c.device, nullptr);
		vkDestroyInstance(c.instance, nullptr);
		return rc;
	}
}
