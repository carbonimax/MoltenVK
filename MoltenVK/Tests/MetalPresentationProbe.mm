// Copyright 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
// Metal only probe, without Vulkan or MoltenVK, of the presentation paths the external Metal wait design relies on
// (PerVertexExternalWait-DESIGN.md, O15 and O17), on a CAMetalLayer detached from any window ("detached") or in an
// on-screen window ("window"):
// - drawables: whether nextDrawable vends drawables, and how long it takes;
// - presented handlers: presenting as MoltenVK does, from a command buffer's scheduled handler, whether the drawable's
//   presented handler runs, and with a presentation time;
// - forced completion: drawables presented as MoltenVK does, from the scheduled handler of command buffers that wait
//   on an event on the GPU, so that their presentations are pending behind blocked work; then the drawable size
//   changed as MVKSwapchain::forceUnpresentedImageCompletion() does: whether the pending presented handlers run before
//   the event is signalled, and after;
// - exhaustion: every drawable held unpresented, whether nextDrawable returns nil after its timeout, or blocks when
//   allowsNextDrawableTimeout is NO (checked on a helper thread for 3 s);
// - pending behind blocked work: every drawable presented from command buffers that wait on an event, whether
//   nextDrawable waits, with and without its timeout;
// - completed work (valid usage): presentations whose command buffers have completed, pending only on the display,
//   followed at once by the forced completion, and a control without it: whether the presented handlers run.
// Each section uses a new layer. The lines are data; exit 0 when the probe completed.
// Usage: MetalPresentationProbe detached|window
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstring>

static std::atomic<int> gPresented{0}, gPresentedWithTime{0}, gPendingPresented{0};

static double nowMs() { return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now().time_since_epoch()).count(); }

// Lets Core Animation run while waiting for a condition, up to a deadline.
static bool pumpUntil(bool (^done)(void), double ms) {
	double end = nowMs() + ms;
	while (!done() && nowMs() < end) {
		[[NSRunLoop currentRunLoop] runMode: NSDefaultRunLoopMode beforeDate: [NSDate dateWithTimeIntervalSinceNow: 0.005]];
	}
	return done();
}

static void clear(id<MTLCommandBuffer> commandBuffer, id<MTLTexture> texture) {
	MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
	pass.colorAttachments[0].texture = texture;
	pass.colorAttachments[0].loadAction = MTLLoadActionClear;
	pass.colorAttachments[0].storeAction = MTLStoreActionStore;
	pass.colorAttachments[0].clearColor = MTLClearColorMake(0.2, 0.4, 0.6, 1);
	[[commandBuffer renderCommandEncoderWithDescriptor: pass] endEncoding];
}

static NSWindow* gWindow = nil;

static CAMetalLayer* makeLayer(id<MTLDevice> device) {
	CAMetalLayer* layer = [CAMetalLayer layer];
	layer.device = device;
	layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
	layer.drawableSize = CGSizeMake(64, 64);
	layer.maximumDrawableCount = 3;
	if (gWindow) {
		gWindow.contentView.layer = layer;
		layer.frame = gWindow.contentView.bounds;
		pumpUntil(^{ return false; }, 100);
	}
	return layer;
}

int main(int argc, char** argv) {
	setvbuf(stdout, nullptr, _IOLBF, 0);
	@autoreleasepool {
		bool isWindow = argc == 2 && !std::strcmp(argv[1], "window");
		if (argc != 2 || (!isWindow && std::strcmp(argv[1], "detached"))) { std::printf("usage: %s detached|window\n", argv[0]); return 64; }
		id<MTLDevice> device = MTLCreateSystemDefaultDevice();
		id<MTLCommandQueue> queue = [device newCommandQueue];
		if (isWindow) {
			[NSApplication sharedApplication];
			[NSApp setActivationPolicy: NSApplicationActivationPolicyAccessory];
			gWindow = [[NSWindow alloc] initWithContentRect: NSMakeRect(40, 40, 64, 64) styleMask: NSWindowStyleMaskBorderless
													backing: NSBackingStoreBuffered defer: NO];
			gWindow.releasedWhenClosed = NO;	// ARC owns it
			gWindow.contentView.wantsLayer = YES;
			[gWindow orderFrontRegardless];
		}
		CAMetalLayer* layer = makeLayer(device);
		std::printf("PRESENT_PROBE mode=%s device=\"%s\" os=\"%s\" allowsNextDrawableTimeout_default=%d\n", argv[1], device.name.UTF8String,
					NSProcessInfo.processInfo.operatingSystemVersionString.UTF8String, int(layer.allowsNextDrawableTimeout));

		// 1. Drawables and presented handlers.
		constexpr int kFrames = 6;
		int vended = 0;
		double maxNextMs = 0;
		for (int frame = 0; frame < kFrames; ++frame) {
			@autoreleasepool {
				double start = nowMs();
				id<CAMetalDrawable> drawable = [layer nextDrawable];
				double took = nowMs() - start;
				if (took > maxNextMs) { maxNextMs = took; }
				if (!drawable) { continue; }
				++vended;
				[drawable addPresentedHandler: ^(id<MTLDrawable> presentedDrawable) {
					gPresented++;
					if (presentedDrawable.presentedTime > 0) { gPresentedWithTime++; }
				}];
				id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
				clear(commandBuffer, drawable.texture);
				[commandBuffer addScheduledHandler: ^(id<MTLCommandBuffer>) { [drawable present]; }];
				[commandBuffer commit];
				pumpUntil(^{ return commandBuffer.status >= MTLCommandBufferStatusCompleted; }, 1000);
			}
		}
		bool allPresented = pumpUntil(^{ return gPresented.load() >= vended; }, 2000);
		std::printf("PRESENT_PROBE DATA drawables vended=%d/%d max_next_drawable_ms=%.1f presented_handlers=%d/%d with_presented_time=%d all_within_2s=%d\n",
					vended, kFrames, maxNextMs, gPresented.load(), vended, gPresentedWithTime.load(), int(allPresented));

		// 2. Forced completion of pending presentations.
		layer = makeLayer(device);
		id<MTLSharedEvent> gate = [device newSharedEvent];
		int pendingCount = 0;
		NSMutableArray* blocked = [NSMutableArray array];
		for (int frame = 0; frame < 2; ++frame) {
			id<CAMetalDrawable> drawable = [layer nextDrawable];
			if (!drawable) { continue; }
			++pendingCount;
			[drawable addPresentedHandler: ^(id<MTLDrawable>) { gPendingPresented++; }];
			id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
			[commandBuffer encodeWaitForEvent: gate value: 1];
			clear(commandBuffer, drawable.texture);
			[commandBuffer addScheduledHandler: ^(id<MTLCommandBuffer>) { [drawable present]; }];
			[commandBuffer commit];
			[blocked addObject: commandBuffer];
		}
		pumpUntil(^{ return false; }, 200);
		int beforeForce = gPendingPresented.load();
		layer.drawableSize = CGSizeMake(1, 1);	// as MVKSwapchain::forceUnpresentedImageCompletion()
		bool forced = pumpUntil(^{ return gPendingPresented.load() >= pendingCount; }, 2000);
		int afterForce = gPendingPresented.load();
		gate.signaledValue = 1;
		for (id<MTLCommandBuffer> commandBuffer in blocked) { [commandBuffer waitUntilCompleted]; }
		bool afterSignal = pumpUntil(^{ return gPendingPresented.load() >= pendingCount; }, 5000);
		std::printf("PRESENT_PROBE DATA forced_completion pending=%d presented_before_force=%d presented_within_2s_of_force=%d all=%d presented_within_5s_of_event_signal=%d all=%d\n",
					pendingCount, beforeForce, afterForce, int(forced), gPendingPresented.load(), int(afterSignal));

		// 2b. Control: the same pending presentations, released by the event without any change of drawable size.
		layer = makeLayer(device);
		id<MTLSharedEvent> control = [device newSharedEvent];
		__block std::atomic<int>* controlPresented = new std::atomic<int>(0);
		int controlCount = 0;
		NSMutableArray* controlBlocked = [NSMutableArray array];
		for (int frame = 0; frame < 2; ++frame) {
			id<CAMetalDrawable> drawable = [layer nextDrawable];
			if (!drawable) { continue; }
			++controlCount;
			[drawable addPresentedHandler: ^(id<MTLDrawable>) { (*controlPresented)++; }];
			id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
			[commandBuffer encodeWaitForEvent: control value: 1];
			clear(commandBuffer, drawable.texture);
			[commandBuffer addScheduledHandler: ^(id<MTLCommandBuffer>) { [drawable present]; }];
			[commandBuffer commit];
			[controlBlocked addObject: commandBuffer];
		}
		pumpUntil(^{ return false; }, 200);
		int controlBefore = controlPresented->load();
		control.signaledValue = 1;
		for (id<MTLCommandBuffer> commandBuffer in controlBlocked) { [commandBuffer waitUntilCompleted]; }
		bool controlAll = pumpUntil(^{ return controlPresented->load() >= controlCount; }, 5000);
		std::printf("PRESENT_PROBE DATA control_without_force pending=%d presented_before_signal=%d presented_within_5s_of_event_signal=%d all=%d\n",
					controlCount, controlBefore, controlPresented->load(), int(controlAll));

		// 3. Exhaustion, with and without the next drawable timeout.
		for (int timeoutAllowed = 1; timeoutAllowed >= 0; --timeoutAllowed) {
			layer = makeLayer(device);
			layer.allowsNextDrawableTimeout = timeoutAllowed;
			NSMutableArray* held = [NSMutableArray array];
			for (int i = 0; i < 3; ++i) { id drawable = [layer nextDrawable]; if (drawable) { [held addObject: drawable]; } }
			dispatch_semaphore_t returned = dispatch_semaphore_create(0);
			__block double tookMs = -1;
			__block bool gotDrawable = false;
			__block id<MTLTexture> fourthTexture = nil;
			dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
				double start = nowMs();
				id<CAMetalDrawable> drawable = [layer nextDrawable];
				tookMs = nowMs() - start;
				gotDrawable = drawable != nil;
				fourthTexture = drawable.texture;
				dispatch_semaphore_signal(returned);
			});
			bool didReturn = !dispatch_semaphore_wait(returned, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
			// Does the fourth drawable reuse the texture, or the IOSurface, of a drawable still held?
			bool reusesTexture = false, reusesSurface = false;
			for (id<CAMetalDrawable> drawable in held) {
				reusesTexture |= drawable.texture == fourthTexture;
				reusesSurface |= fourthTexture && drawable.texture.iosurface == fourthTexture.iosurface;
			}
			std::printf("PRESENT_PROBE DATA exhaustion allowsNextDrawableTimeout=%d held=%lu next_drawable_returned_within_3s=%d%s took_ms=%.0f got_drawable=%d reuses_held_texture=%d reuses_held_iosurface=%d\n",
						timeoutAllowed, (unsigned long)held.count, int(didReturn), didReturn ? "" : " (blocked)", tookMs, int(gotDrawable),
						int(reusesTexture), int(reusesSurface));
			[held removeAllObjects];	// releasing the held drawables lets a blocked nextDrawable return
			if (!didReturn) { dispatch_semaphore_wait(returned, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)); }
		}
		// 4. Every drawable pending presentation behind blocked work, as in the design's O17: does nextDrawable wait?
		for (int timeoutAllowed = 1; timeoutAllowed >= 0; --timeoutAllowed) {
			layer = makeLayer(device);
			layer.allowsNextDrawableTimeout = timeoutAllowed;
			id<MTLSharedEvent> stuck = [device newSharedEvent];
			NSMutableArray* stuckWork = [NSMutableArray array];
			for (int frame = 0; frame < 3; ++frame) {
				id<CAMetalDrawable> drawable = [layer nextDrawable];
				if (!drawable) { continue; }
				id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
				[commandBuffer encodeWaitForEvent: stuck value: 1];
				clear(commandBuffer, drawable.texture);
				[commandBuffer addScheduledHandler: ^(id<MTLCommandBuffer>) { [drawable present]; }];
				[commandBuffer commit];
				[stuckWork addObject: commandBuffer];
			}
			pumpUntil(^{ return false; }, 200);
			dispatch_semaphore_t returned = dispatch_semaphore_create(0);
			__block double tookMs = -1;
			__block bool gotDrawable = false;
			dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
				double start = nowMs();
				id drawable = [layer nextDrawable];
				tookMs = nowMs() - start;
				gotDrawable = drawable != nil;
				dispatch_semaphore_signal(returned);
			});
			bool didReturn = !dispatch_semaphore_wait(returned, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
			std::printf("PRESENT_PROBE DATA pending_behind_blocked_work allowsNextDrawableTimeout=%d pending=%lu next_drawable_returned_within_3s=%d%s took_ms=%.0f got_drawable=%d\n",
						timeoutAllowed, (unsigned long)stuckWork.count, int(didReturn), didReturn ? "" : " (blocked)", tookMs, int(gotDrawable));
			stuck.signaledValue = 1;
			for (id<MTLCommandBuffer> commandBuffer in stuckWork) { [commandBuffer waitUntilCompleted]; }
			if (!didReturn) {
				bool late = pumpUntil(^{ return tookMs >= 0; }, 3000);
				std::printf("PRESENT_PROBE DATA pending_behind_blocked_work allowsNextDrawableTimeout=%d returned_after_release=%d took_ms=%.0f got_drawable=%d\n",
							timeoutAllowed, int(late), tookMs, int(gotDrawable));
			}
		}
		// 5. Valid usage: presentations whose command buffers have completed, pending only on the display, then the forced
		// completion at once (as when an application recreates its swapchain), and a control without it.
		static std::atomic<int> gDisplayPresented{0};
		for (int forced = 1; forced >= 0; --forced) {
			layer = makeLayer(device);
			gDisplayPresented = 0;
			int presentedCount = 0;
			for (int frame = 0; frame < 3; ++frame) {
				id<CAMetalDrawable> drawable = [layer nextDrawable];
				if (!drawable) { continue; }
				++presentedCount;
				[drawable addPresentedHandler: ^(id<MTLDrawable>) { gDisplayPresented++; }];
				id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
				clear(commandBuffer, drawable.texture);
				[commandBuffer addScheduledHandler: ^(id<MTLCommandBuffer>) { [drawable present]; }];
				[commandBuffer commit];
				[commandBuffer waitUntilCompleted];
			}
			int beforeForce = gDisplayPresented.load();
			if (forced) { layer.drawableSize = CGSizeMake(1, 1); }
			bool all = pumpUntil(^{ return gDisplayPresented.load() >= presentedCount; }, 2000);
			std::printf("PRESENT_PROBE DATA completed_work forced=%d presented=%d presented_when_work_completed=%d presented_within_2s=%d all=%d\n",
						forced, presentedCount, beforeForce, gDisplayPresented.load(), int(all));
		}
		std::printf("PRESENT_PROBE DONE mode=%s\n", argv[1]);
		[gWindow close];
		return 0;
	}
}
