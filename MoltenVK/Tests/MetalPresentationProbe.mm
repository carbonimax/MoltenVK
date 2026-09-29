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
//   followed at once by the forced completion, and a control without it: whether the presented handlers run;
// - future presentation (valid usage, VK_GOOGLE_display_timing): every drawable presented with presentAtTime: 4 s
//   ahead, from the scheduled handler as MoltenVK does, its command buffer completed: whether the next nextDrawable
//   waits, with and without its timeout, and when it returns, and when the drawables were presented;
// - held unpresented: how many drawables nextDrawable vends while all are held, up to 8, small and 4K;
// - reuse after forced completion: the recipe that once blocked nextDrawable, 3 rounds on fresh layers;
// - presentation ahead: 3 drawables presented 0.1, 0.5, 1 and 2 s ahead, whether Core Animation honours the time, and
//   how long a nextDrawable made meanwhile takes;
// - tight loop: 120 frames presented without waiting, display sync on: how long nextDrawable waits;
// - recipes: the forced completion of pending presentations, then 3 drawables held, and a fourth nextDrawable, with
//   controls; then, as MoltenVK retains them, the dropped drawables kept, and 6 drawables requested one at a time.
// The window is that of a regular, launched and active application; its visibility is printed. Each section uses a new
// layer. The lines are data; exit 0 when the probe completed.
// Usage: MetalPresentationProbe detached|window
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

static std::atomic<int> gPresented{0}, gPresentedWithTime{0}, gPendingPresented{0};

static double nowMs() { return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now().time_since_epoch()).count(); }

// Lets Core Animation and the window server's events run while waiting for a condition, up to a deadline.
static bool pumpUntil(bool (^done)(void), double ms) {
	double end = nowMs() + ms;
	while (!done() && nowMs() < end) {
		NSEvent* event = NSApp ? [NSApp nextEventMatchingMask: NSEventMaskAny untilDate: [NSDate dateWithTimeIntervalSinceNow: 0.005]
													  inMode: NSDefaultRunLoopMode dequeue: YES] : nil;
		if (event) { [NSApp sendEvent: event]; }
		else if (!NSApp) { [[NSRunLoop currentRunLoop] runMode: NSDefaultRunLoopMode beforeDate: [NSDate dateWithTimeIntervalSinceNow: 0.005]]; }
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
			// A regular, launched and active application, so that the window server composites its window.
			[NSApplication sharedApplication];
			[NSApp setActivationPolicy: NSApplicationActivationPolicyRegular];
			[NSApp finishLaunching];
			gWindow = [[NSWindow alloc] initWithContentRect: NSMakeRect(80, 80, 400, 300) styleMask: NSWindowStyleMaskTitled
													backing: NSBackingStoreBuffered defer: NO];
			gWindow.releasedWhenClosed = NO;	// ARC owns it
			gWindow.title = @"MetalPresentationProbe";
			gWindow.contentView.wantsLayer = YES;
			gWindow.level = NSStatusWindowLevel;	// above other applications' windows, since a tool cannot take the focus
			[gWindow orderFrontRegardless];
			[NSApp activateIgnoringOtherApps: YES];
			pumpUntil(^{ return (gWindow.occlusionState & NSWindowOcclusionStateVisible) != 0; }, 2000);
		}
		CAMetalLayer* layer = makeLayer(device);
		std::printf("PRESENT_PROBE mode=%s device=\"%s\" os=\"%s\" allowsNextDrawableTimeout_default=%d displaySyncEnabled=%d window_visible=%d\n", argv[1],
					device.name.UTF8String, NSProcessInfo.processInfo.operatingSystemVersionString.UTF8String, int(layer.allowsNextDrawableTimeout),
					int(layer.displaySyncEnabled), gWindow ? int((gWindow.occlusionState & NSWindowOcclusionStateVisible) != 0) : -1);

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
		// 6. Presentations requested at a future time, as MoltenVK does for VK_GOOGLE_display_timing (presentAtTime: from the
		// scheduled handler): the command buffers complete, the drawables wait for their display time. Does the next
		// nextDrawable wait for them?
		constexpr double kFutureSeconds = 4;
		for (int timeoutAllowed = 1; timeoutAllowed >= 0; --timeoutAllowed) {
			layer = makeLayer(device);
			layer.allowsNextDrawableTimeout = timeoutAllowed;
			__block std::atomic<int>* futurePresented = new std::atomic<int>(0);
			__block double* earliestPresentedTime = new double(0);
			int presented = 0;
			double presentAt = CACurrentMediaTime() + kFutureSeconds;
			for (int frame = 0; frame < 3; ++frame) {
				id<CAMetalDrawable> drawable = [layer nextDrawable];
				if (!drawable) { continue; }
				++presented;
				[drawable addPresentedHandler: ^(id<MTLDrawable> presentedDrawable) {
					if (presentedDrawable.presentedTime > 0 && (*earliestPresentedTime == 0 || presentedDrawable.presentedTime < *earliestPresentedTime)) {
						*earliestPresentedTime = presentedDrawable.presentedTime;
					}
					(*futurePresented)++;
				}];
				id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
				clear(commandBuffer, drawable.texture);
				[commandBuffer addScheduledHandler: ^(id<MTLCommandBuffer>) { [drawable presentAtTime: presentAt]; }];
				[commandBuffer commit];
				[commandBuffer waitUntilCompleted];
			}
			dispatch_semaphore_t returned = dispatch_semaphore_create(0);
			__block double tookMs = -1;
			__block bool gotDrawable = false;
			double start = nowMs();
			dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
				double begin = nowMs();
				id drawable = [layer nextDrawable];
				tookMs = nowMs() - begin;
				gotDrawable = drawable != nil;
				dispatch_semaphore_signal(returned);
			});
			bool within3s = pumpUntil(^{ return tookMs >= 0; }, 3000);
			int presentedBefore = futurePresented->load();
			bool eventually = within3s || pumpUntil(^{ return tookMs >= 0; }, (kFutureSeconds + 3) * 1000);
			std::printf("PRESENT_PROBE DATA future_presentation allowsNextDrawableTimeout=%d presented=%d present_in_s=%.0f next_drawable_returned_within_3s=%d%s "
						"presented_handlers_at_3s=%d returned=%d took_ms=%.0f got_drawable=%d presented_handlers=%d elapsed_ms=%.0f "
						"earliest_presented_time_minus_requested_ms=%.0f\n",
						timeoutAllowed, presented, kFutureSeconds, int(within3s), within3s ? "" : " (blocked)", presentedBefore, int(eventually), tookMs,
						int(gotDrawable), futurePresented->load(), nowMs() - start, *earliestPresentedTime ? (*earliestPresentedTime - presentAt) * 1000 : -1.0);
			if (!eventually) { dispatch_semaphore_wait(returned, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)); }
			pumpUntil(^{ return futurePresented->load() >= 3; }, 2000);
		}
		// 7. How many drawables can be held unpresented before nextDrawable stops vending: up to 8, with the timeout, for
		// small and for 4K drawables.
		for (int large = 0; large <= 1; ++large) {
			layer = makeLayer(device);
			if (large) { layer.drawableSize = CGSizeMake(3840, 2160); }
			NSMutableArray* held = [NSMutableArray array];
			std::string timings;
			for (int i = 0; i < 8; ++i) {
				double begin = nowMs();
				id drawable = [layer nextDrawable];
				char entry[48];
				std::snprintf(entry, sizeof(entry), "%s%d:%.0fms%s", i ? "," : "", i + 1, nowMs() - begin, drawable ? "" : "(nil)");
				timings += entry;
				if (!drawable) { break; }
				[held addObject: drawable];
			}
			std::printf("PRESENT_PROBE DATA held_unpresented drawable_size=%.0fx%.0f maximumDrawableCount=%lu vended=%lu next_drawable=%s\n",
						layer.drawableSize.width, layer.drawableSize.height, (unsigned long)layer.maximumDrawableCount, (unsigned long)held.count, timings.c_str());
		}
		// 8. The one recipe that once blocked nextDrawable (§3.13 of the design): a layer reused after the forced completion
		// of presentations pending behind blocked work. Repeated on fresh layers, to measure how often it blocks.
		for (int round = 0; round < 3; ++round) {
			layer = makeLayer(device);
			id<MTLSharedEvent> held = [device newSharedEvent];
			NSMutableArray* heldWork = [NSMutableArray array];
			for (int frame = 0; frame < 2; ++frame) {
				id<CAMetalDrawable> drawable = [layer nextDrawable];
				if (!drawable) { continue; }
				id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
				[commandBuffer encodeWaitForEvent: held value: 1];
				clear(commandBuffer, drawable.texture);
				[commandBuffer addScheduledHandler: ^(id<MTLCommandBuffer>) { [drawable present]; }];
				[commandBuffer commit];
				[heldWork addObject: commandBuffer];
			}
			pumpUntil(^{ return false; }, 200);
			layer.drawableSize = CGSizeMake(1, 1);
			pumpUntil(^{ return false; }, 200);
			held.signaledValue = 1;
			for (id<MTLCommandBuffer> commandBuffer in heldWork) { [commandBuffer waitUntilCompleted]; }
			layer.drawableSize = CGSizeMake(64, 64);	// the layer is reused, as by a recreated swapchain
			std::string timings;
			for (int i = 0; i < 4; ++i) {
				@autoreleasepool {	// each drawable is released at once
					double begin = nowMs();
					id drawable = [layer nextDrawable];
					char entry[48];
					std::snprintf(entry, sizeof(entry), "%s%.0fms%s", i ? "," : "", nowMs() - begin, drawable ? "" : "(nil)");
					timings += entry;
				}
			}
			std::printf("PRESENT_PROBE DATA reuse_after_forced_completion round=%d next_drawable=%s\n", round, timings.c_str());
		}
		// 9. Presentation times closer ahead: which ones Core Animation honours (presented time against requested), and
		// whether a nextDrawable made while the three drawables wait for them waits too.
		for (double ahead : {0.1, 0.5, 1.0, 2.0}) {
			layer = makeLayer(device);
			__block std::atomic<int>* aheadPresented = new std::atomic<int>(0);
			__block double* latestPresentedTime = new double(0);
			double presentAt = CACurrentMediaTime() + ahead;
			for (int frame = 0; frame < 3; ++frame) {
				id<CAMetalDrawable> drawable = [layer nextDrawable];
				if (!drawable) { continue; }
				[drawable addPresentedHandler: ^(id<MTLDrawable> presentedDrawable) {
					if (presentedDrawable.presentedTime > *latestPresentedTime) { *latestPresentedTime = presentedDrawable.presentedTime; }
					(*aheadPresented)++;
				}];
				id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
				clear(commandBuffer, drawable.texture);
				[commandBuffer addScheduledHandler: ^(id<MTLCommandBuffer>) { [drawable presentAtTime: presentAt]; }];
				[commandBuffer commit];
				[commandBuffer waitUntilCompleted];
			}
			double begin = nowMs();
			@autoreleasepool { [layer nextDrawable]; }
			double tookMs = nowMs() - begin;
			pumpUntil(^{ return aheadPresented->load() >= 3; }, (ahead + 2) * 1000);
			std::printf("PRESENT_PROBE DATA presentation_ahead ahead_ms=%.0f next_drawable_ms=%.1f presented_handlers=%d latest_presented_minus_requested_ms=%.0f\n",
						ahead * 1000, tookMs, aheadPresented->load(), *latestPresentedTime ? (*latestPresentedTime - presentAt) * 1000 : -1.0);
		}
		// 10. A tight loop of 120 frames presented from the scheduled handler, display sync on: how long nextDrawable waits
		// once the display queue is full.
		{
			layer = makeLayer(device);
			std::vector<double> waits;
			for (int frame = 0; frame < 120; ++frame) {
				@autoreleasepool {
					double begin = nowMs();
					id<CAMetalDrawable> drawable = [layer nextDrawable];
					waits.push_back(nowMs() - begin);
					if (!drawable) { continue; }
					id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
					clear(commandBuffer, drawable.texture);
					[commandBuffer addScheduledHandler: ^(id<MTLCommandBuffer>) { [drawable present]; }];
					[commandBuffer commit];
				}
			}
			std::sort(waits.begin(), waits.end());
			std::printf("PRESENT_PROBE DATA tight_loop frames=%zu next_drawable_ms median=%.1f p95=%.1f max=%.1f\n", waits.size(), waits[waits.size() / 2],
						waits[waits.size() * 95 / 100], waits.back());
		}
		// 11. The exact recipe of the one blocked nextDrawable (first run, when sections shared a layer): the forced completion
		// of presentations pending behind blocked work, then 3 drawables held on the same layer, and a fourth nextDrawable.
		// Variants isolate the cause: with and without the timeout; the 1x1 size alone, without the forced completion;
		// the forced completion with the size restored. 3 rounds each, on fresh layers.
		struct Recipe { const char* name; bool force; bool restoreSize; bool timeout; };
		for (Recipe recipe : {Recipe{"forced_then_hold", true, false, true}, Recipe{"forced_then_hold_no_timeout", true, false, false},
							  Recipe{"size_1x1_only", false, false, true}, Recipe{"forced_then_size_restored", true, true, true}}) {
			for (int round = 0; round < 3; ++round) {
				layer = makeLayer(device);
				if (recipe.force) {
					id<MTLSharedEvent> held = [device newSharedEvent];
					NSMutableArray* heldWork = [NSMutableArray array];
					for (int frame = 0; frame < 2; ++frame) {
						id<CAMetalDrawable> drawable = [layer nextDrawable];
						if (!drawable) { continue; }
						id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
						[commandBuffer encodeWaitForEvent: held value: 1];
						clear(commandBuffer, drawable.texture);
						[commandBuffer addScheduledHandler: ^(id<MTLCommandBuffer>) { [drawable present]; }];
						[commandBuffer commit];
						[heldWork addObject: commandBuffer];
					}
					pumpUntil(^{ return false; }, 200);
					layer.drawableSize = CGSizeMake(1, 1);
					pumpUntil(^{ return false; }, 200);
					held.signaledValue = 1;
					for (id<MTLCommandBuffer> commandBuffer in heldWork) { [commandBuffer waitUntilCompleted]; }
					if (recipe.restoreSize) { layer.drawableSize = CGSizeMake(64, 64); }
				} else {
					layer.drawableSize = CGSizeMake(1, 1);
				}
				layer.allowsNextDrawableTimeout = recipe.timeout;
				NSMutableArray* heldDrawables = [NSMutableArray array];
				for (int i = 0; i < 3; ++i) { id drawable = [layer nextDrawable]; if (drawable) { [heldDrawables addObject: drawable]; } }
				dispatch_semaphore_t returned = dispatch_semaphore_create(0);
				__block double tookMs = -1;
				__block bool gotDrawable = false;
				dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
					double begin = nowMs();
					id drawable = [layer nextDrawable];
					tookMs = nowMs() - begin;
					gotDrawable = drawable != nil;
					dispatch_semaphore_signal(returned);
				});
				bool within3s = !dispatch_semaphore_wait(returned, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
				std::printf("PRESENT_PROBE DATA recipe=%s round=%d held=%lu next_drawable_returned_within_3s=%d%s took_ms=%.0f got_drawable=%d\n", recipe.name,
							round, (unsigned long)heldDrawables.count, int(within3s), within3s ? "" : " (blocked)", tookMs, int(gotDrawable));
				[heldDrawables removeAllObjects];
				if (!within3s) {
					bool late = !dispatch_semaphore_wait(returned, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
					std::printf("PRESENT_PROBE DATA recipe=%s round=%d returned_after_release=%d took_ms=%.0f\n", recipe.name, round, int(late), tookMs);
				}
			}
		}
		// 12. As MoltenVK does: the drawables whose presentations the forced completion dropped stay retained, since the
		// presented handler that would release them never runs. The size is restored, as a replacement swapchain of the
		// same extent does. Then 6 drawables requested one at a time, each held: which requests wait, and how long each;
		// then the dropped drawables released, and one more request. With and without the timeout, 3 rounds each.
		for (int timeoutAllowed = 1; timeoutAllowed >= 0; --timeoutAllowed) {
			for (int round = 0; round < 3; ++round) {
				layer = makeLayer(device);
				NSMutableArray* dropped = [NSMutableArray array];
				id<MTLSharedEvent> gate = [device newSharedEvent];
				NSMutableArray* gateWork = [NSMutableArray array];
				for (int frame = 0; frame < 2; ++frame) {
					id<CAMetalDrawable> drawable = [layer nextDrawable];
					if (!drawable) { continue; }
					[dropped addObject: drawable];
					id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
					[commandBuffer encodeWaitForEvent: gate value: 1];
					clear(commandBuffer, drawable.texture);
					[commandBuffer addScheduledHandler: ^(id<MTLCommandBuffer>) { [drawable present]; }];
					[commandBuffer commit];
					[gateWork addObject: commandBuffer];
				}
				pumpUntil(^{ return false; }, 200);
				layer.drawableSize = CGSizeMake(1, 1);
				pumpUntil(^{ return false; }, 200);
				gate.signaledValue = 1;
				for (id<MTLCommandBuffer> commandBuffer in gateWork) { [commandBuffer waitUntilCompleted]; }
				layer.drawableSize = CGSizeMake(64, 64);
				layer.allowsNextDrawableTimeout = timeoutAllowed;
				NSMutableArray* held = [NSMutableArray array];
				std::string timings;
				for (int i = 0; i < 6; ++i) {
					double begin = nowMs();
					id drawable = [layer nextDrawable];
					char entry[48];
					std::snprintf(entry, sizeof(entry), "%s%.0f%s", i ? "," : "", nowMs() - begin, drawable ? "" : "(nil)");
					timings += entry;
					if (drawable) { [held addObject: drawable]; }
				}
				[dropped removeAllObjects];
				double begin = nowMs();
				@autoreleasepool { [layer nextDrawable]; }
				double afterRelease = nowMs() - begin;
				std::printf("PRESENT_PROBE DATA dropped_retained allowsNextDrawableTimeout=%d round=%d next_drawable_ms=%s after_dropped_released_ms=%.0f\n",
							timeoutAllowed, round, timings.c_str(), afterRelease);
			}
		}
		std::printf("PRESENT_PROBE DONE mode=%s\n", argv[1]);
		[gWindow close];
		return 0;
	}
}
