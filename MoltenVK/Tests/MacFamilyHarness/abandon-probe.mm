// Copyright 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
// Metal only probe, without Vulkan or MoltenVK, of what MoltenVK assumes when it abandons a prefilled Metal command
// buffer (MVKDevice::abandonMTLCommandBuffer): a command buffer that was encoded, but never enqueued nor committed, is
// released. MoltenVK then runs its own completion handlers itself and never hands them to Metal, so it depends only on:
// - the release giving the command buffer's slot back to its queue (MoltenVK creates its queues with a
//   maxCommandBufferCount), otherwise a later acquisition blocks forever;
// - the encoded commands never executing.
// PASS: on a queue of 4 slots, 64 command buffers are acquired, encoded (a fill of 0xA5) and released in turn, each
// acquisition within 2 s; none of their fills reaches the buffer; a control command buffer committed on the same queue
// afterwards completes, and its fill (0x5A) does. Data, never the verdict: how many times Metal runs the completed
// handler of each abandoned command buffer at its release. Not probed: an enqueued command buffer released uncommitted,
// which MoltenVK never does, and which Metal API validation rejects. Exit 0 on PASS, 1 on FAIL. The iOS app calls runAbandonProbe() with ABANDON_PROBE_NO_MAIN defined.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <atomic>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <initializer_list>
#include <unistd.h>

static FILE* gAbandonProbeCopy = nullptr;	// the iOS app also writes the lines to a file

static void say(const char* format, ...) {
	for (FILE* out : {stdout, gAbandonProbeCopy}) {
		if (!out) continue;
		va_list args;
		va_start(args, format);
		std::vfprintf(out, format, args);
		va_end(args);
		std::fflush(out);
	}
}

// Acquires a command buffer on another thread, so that a queue without a free slot cannot block the probe.
static id<MTLCommandBuffer> acquire(id<MTLCommandQueue> queue, double seconds) {
	dispatch_semaphore_t acquired = dispatch_semaphore_create(0);
	__block id<MTLCommandBuffer> commandBuffer = nil;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		@autoreleasepool {
			MTLCommandBufferDescriptor* descriptor = [MTLCommandBufferDescriptor new];
			descriptor.retainedReferences = YES;	// as MoltenVK acquires its prefilled command buffers
			commandBuffer = [queue commandBufferWithDescriptor: descriptor];
		}
		dispatch_semaphore_signal(acquired);
	});
	if (dispatch_semaphore_wait(acquired, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)))) return nil;
	return commandBuffer;
}

static void fill(id<MTLCommandBuffer> commandBuffer, id<MTLBuffer> buffer, NSUInteger offset, uint8_t value) {
	id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
	[blit fillBuffer: buffer range: NSMakeRange(offset, 4) value: value];
	[blit endEncoding];
}

static bool bytesEqual(id<MTLBuffer> buffer, NSUInteger offset, uint8_t value) {
	const uint8_t* bytes = (const uint8_t*)buffer.contents + offset;
	return bytes[0] == value && bytes[1] == value && bytes[2] == value && bytes[3] == value;
}

int runAbandonProbe(FILE* copy) {
	gAbandonProbeCopy = copy;
	constexpr int kSlots = 4, kAbandoned = 64;
	id<MTLDevice> device = MTLCreateSystemDefaultDevice();
	if (!device) { say("ABANDON_PROBE FAIL: no Metal device\n"); return 1; }
	say("ABANDON_PROBE device=\"%s\" os=\"%s\"\n", device.name.UTF8String, NSProcessInfo.processInfo.operatingSystemVersionString.UTF8String);
	id<MTLBuffer> buffer = [device newBufferWithLength: 256 options: MTLResourceStorageModeShared];
	std::memset(buffer.contents, 0, 256);

	// 1. Abandoned command buffers: encoded, never enqueued nor committed, released.
	id<MTLCommandQueue> queue = [device newCommandQueueWithMaxCommandBufferCount: kSlots];
	static std::atomic<int> handlerCalls[kAbandoned];
	static std::atomic<int> completedStatusCalls{0};
	int acquired = 0;
	for (int i = 0; i < kAbandoned; ++i) {
		@autoreleasepool {
			id<MTLCommandBuffer> commandBuffer = acquire(queue, 2.0);
			if (!commandBuffer) break;
			++acquired;
			fill(commandBuffer, buffer, 0, 0xA5);
			[commandBuffer addCompletedHandler: ^(id<MTLCommandBuffer> completed) {
				handlerCalls[i]++;
				if (completed.status == MTLCommandBufferStatusCompleted) completedStatusCalls++;
			}];
		}	// the last reference goes here
	}
	say("ABANDON_PROBE acquired=%d/%d queue_slots=%d\n", acquired, kAbandoned, kSlots);

	// 2. Control: a committed command buffer on the same queue runs after any work committed before it.
	@autoreleasepool {
		id<MTLCommandBuffer> control = acquire(queue, 2.0);
		if (control) {
			fill(control, buffer, 4, 0x5A);
			[control commit];
			[control waitUntilCompleted];
		}
		// Handlers that Metal runs at release have had the whole control round trip to report.
		for (int wait = 0; wait < 100; ++wait) {
			int calls = 0;
			for (auto& count : handlerCalls) calls += count;
			if (calls >= acquired) break;
			usleep(10000);
		}
		bool abandonedRan = !bytesEqual(buffer, 0, 0);
		bool controlRan = control && control.status == MTLCommandBufferStatusCompleted && bytesEqual(buffer, 4, 0x5A);
		const uint8_t* bytes = (const uint8_t*)buffer.contents;
		say("ABANDON_PROBE abandoned_fill=%02x control_fill=%02x control_status=%ld\n", bytes[0], bytes[4], control ? (long)control.status : -1L);
		int once = 0, never = 0, multiple = 0;
		for (int i = 0; i < acquired; ++i) {
			int calls = handlerCalls[i];
			calls == 0 ? ++never : calls == 1 ? ++once : ++multiple;
		}
		say("ABANDON_PROBE DATA metal_handlers_at_release once=%d never=%d multiple=%d completed_status=%d\n", once, never, multiple, completedStatusCalls.load());

		if (acquired != kAbandoned) { say("ABANDON_PROBE FAIL: acquisition %d blocked for 2 s: a released uncommitted command buffer kept its slot\n", acquired + 1); return 1; }
		if (!controlRan) { say("ABANDON_PROBE FAIL: the control command buffer did not complete with its fill\n"); return 1; }
		if (abandonedRan) { say("ABANDON_PROBE FAIL: commands of a released uncommitted command buffer executed\n"); return 1; }
	}
	say("ABANDON_PROBE PASS: %d released uncommitted command buffers returned their slots and executed nothing\n", kAbandoned);
	return 0;
}

#ifndef ABANDON_PROBE_NO_MAIN
int main() {
	@autoreleasepool { return runAbandonProbe(nullptr); }
}
#endif
