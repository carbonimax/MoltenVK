// Copyright 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
// Metal only probe, without Vulkan or MoltenVK: when does a committed command buffer give its place back to a queue
// created with newCommandQueueWithMaxCommandBufferCount:1? MoltenVK's slot count would return its credit from the
// command buffer's completed handler (design R2); a new acquisition that follows that credit blocks if Metal frees the
// place only after the handlers.
// Each round commits a command buffer A on a one-place queue. From A's completed handler, a helper thread tries to
// acquire a command buffer B on the same queue, and the handler waits up to 200 ms for it before returning. The probe
// prints whether B was acquired while A's handler still ran, and how long after the handler returned it was acquired.
// Exit 0 when the measurement completed (the lines are data), 1 when an acquisition never completed within 2 s.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <atomic>
#include <chrono>
#include <cstdio>

static double nowMs() {
	return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

int main() {
	@autoreleasepool {
		id<MTLDevice> device = MTLCreateSystemDefaultDevice();
		if (!device) { std::printf("SLOT_RELEASE FAIL: no Metal device\n"); return 1; }
		id<MTLCommandQueue> queue = [device newCommandQueueWithMaxCommandBufferCount: 1];
		std::printf("SLOT_RELEASE device=\"%s\" os=\"%s\"\n", device.name.UTF8String, NSProcessInfo.processInfo.operatingSystemVersionString.UTF8String);
		constexpr int kRounds = 20;
		int duringHandler = 0, afterHandler = 0, never = 0;
		double maxAfterMs = 0;
		for (int round = 0; round < kRounds; ++round) {
			@autoreleasepool {
				dispatch_semaphore_t acquired = dispatch_semaphore_create(0), handlerDone = dispatch_semaphore_create(0);
				__block id<MTLCommandBuffer> second = nil;
				__block double acquiredAtMs = 0, handlerEndMs = 0;
				__block bool acquiredInHandler = false;
				id<MTLCommandBuffer> first = [queue commandBuffer];
				[first addCompletedHandler: ^(id<MTLCommandBuffer>) {
					dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
						id<MTLCommandBuffer> next = [queue commandBuffer];		// blocks while the only place is taken
						acquiredAtMs = nowMs();
						second = next;
						dispatch_semaphore_signal(acquired);
					});
					acquiredInHandler = !dispatch_semaphore_wait(acquired, dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC));
					handlerEndMs = nowMs();
					dispatch_semaphore_signal(handlerDone);
				}];
				[first commit];
				dispatch_semaphore_wait(handlerDone, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
				bool acquiredLater = acquiredInHandler || !dispatch_semaphore_wait(acquired, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
				double afterMs = acquiredLater && !acquiredInHandler ? acquiredAtMs - handlerEndMs : 0;
				if (acquiredInHandler) { ++duringHandler; }
				else if (acquiredLater) { ++afterHandler; if (afterMs > maxAfterMs) { maxAfterMs = afterMs; } }
				else { ++never; }
				std::printf("round=%d acquired_during_handler=%d acquired_after_handler=%d ms_after_handler=%.2f\n", round,
							int(acquiredInHandler), int(!acquiredInHandler && acquiredLater), afterMs);
				second = nil;	// never enqueued nor committed: released, it gives its place back
			}
		}
		std::printf("SLOT_RELEASE DATA rounds=%d during_handler=%d after_handler=%d never=%d max_ms_after_handler=%.2f\n",
					kRounds, duringHandler, afterHandler, never, maxAfterMs);
		std::printf("SLOT_RELEASE %s\n", never ? "FAIL: an acquisition did not complete within 2 s after the handler" : "DONE");
		return never ? 1 : 0;
	}
}
