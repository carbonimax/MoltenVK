#include "MVKPerVertexScratch.h"
#include "MVKSubmissionTransaction.h"
#include <cassert>
#include <cstdio>

static unsigned liveBuffers;

// These objects only implement selectors used by the reservation code. No Metal
// device, queue, command buffer, Vulkan instance, or GPU process is created.
@interface ScratchTestBuffer : NSObject {
@public
	NSUInteger _length;
	bool _visible;
	uint8_t _bytes[512];
}
@end
@implementation ScratchTestBuffer
- (NSUInteger)length { return _length; }
- (void*)contents { return _visible ? _bytes : nullptr; }
- (void)dealloc { --liveBuffers; [super dealloc]; }
@end

@interface ScratchTestDevice : NSObject {
@public
	unsigned calls;
	unsigned failAt;
	unsigned failureMode;
}
- (id<MTLBuffer>)newBufferWithLength:(NSUInteger)length options:(MTLResourceOptions)options;
@end
@implementation ScratchTestDevice
- (id<MTLBuffer>)newBufferWithLength:(NSUInteger)length options:(MTLResourceOptions)options {
	bool fail = ++calls == failAt;
	if (fail && failureMode == 0) { return nil; }
	auto* buffer = [ScratchTestBuffer new];
	++liveBuffers;
	buffer->_length = length - (fail && failureMode == 1 ? 1 : 0);
	buffer->_visible = options == MTLResourceStorageModeShared && !(fail && failureMode == 2);
	return (id<MTLBuffer>)buffer;
}
@end

static const std::vector<MVKPerVertexScratchRequest> requests = {{48, 24, 12}, {32, 0, 0}, {48, 24, 12}};

struct Submission {
	MVKPerVertexScratchReservations executions[2];
};

using Completion = void (^)(void);
static Completion makeCompletion(std::shared_ptr<MVKPerVertexScratch> scratch) {
	return [^{ assert(scratch->buffers[0].length == 48); } copy];
}

int main() {
	@autoreleasepool {
		auto* device = [ScratchTestDevice new];
		// Three batches, two executions each, including repeated secondary draws
		// and a short draw needing capture but no replay. Ten allocations/execution.
		constexpr unsigned allocationCount = 60;
		for (unsigned mode = 0; mode < 2; ++mode) {
			for (unsigned fail = 1; fail <= allocationCount; ++fail) {
				device->calls = 0; device->failAt = fail; device->failureMode = mode;
				unsigned dispatched = 0;
				VkResult result = mvkSubmitTransaction<Submission>(3, [](uint32_t) { return new Submission; }, [&](Submission& submission) {
					for (auto& execution : submission.executions) {
						if (!mvkReservePerVertexScratch((id<MTLDevice>)device, requests, execution)) { return VK_ERROR_OUT_OF_DEVICE_MEMORY; }
					}
					return VK_SUCCESS;
				}, [&](Submission* submission) {
					++dispatched; delete submission; return VK_SUCCESS;
				});
				assert(result == VK_ERROR_OUT_OF_DEVICE_MEMORY);
				assert(device->calls == fail && liveBuffers == 0 && dispatched == 0);
			}
		}
		// The optional corner allocation belongs to the same pre-submit transaction.
		for (unsigned mode = 0; mode < 3; ++mode) {
			device->calls = 0; device->failAt = 5; device->failureMode = mode;
			MVKPerVertexScratchReservations corners;
			assert(!mvkReservePerVertexScratch((id<MTLDevice>)device, {{48, 24, 12, 12}}, corners));
			assert(corners.empty() && liveBuffers == 0 && device->calls == 5);
		}
		device->calls = 0; device->failAt = 0;
		{
			MVKPerVertexScratchReservations corners;
			assert(mvkReservePerVertexScratch((id<MTLDevice>)device, {{48, 24, 12, 12}}, corners));
			assert(corners[0]->buffers[4].length == 12 && corners[0]->buffers[4].contents);
		}
		assert(liveBuffers == 0);
		// UINT8 widening is private GPU scratch and participates in the same transaction.
		for (unsigned mode = 0; mode < 2; ++mode) {
			device->calls = 0; device->failAt = 6; device->failureMode = mode;
			MVKPerVertexScratchReservations widened;
			assert(!mvkReservePerVertexScratch((id<MTLDevice>)device, {{48, 24, 12, 12, 6}}, widened));
			assert(widened.empty() && liveBuffers == 0 && device->calls == 6);
		}
		device->calls = 0; device->failAt = 0;
		{
			MVKPerVertexScratchReservations widened;
			assert(mvkReservePerVertexScratch((id<MTLDevice>)device, {{48, 24, 12, 12, 6}}, widened));
			assert(widened[0]->buffers[5].length == 6 && !widened[0]->buffers[5].contents);
		}
		assert(liveBuffers == 0);
		// Reject a real-looking shared buffer with no CPU mapping.
		device->calls = 0; device->failAt = 2; device->failureMode = 2;
		MVKPerVertexScratchReservations unmapped;
		assert(!mvkReservePerVertexScratch((id<MTLDevice>)device, requests, unmapped));
		assert(unmapped.empty() && liveBuffers == 0);

		// Failure of a later batch releases temporary references to a prefill but
		// preserves the recorded reservation, so retry does not consume it.
		device->calls = 0; device->failAt = 0;
		MVKPerVertexScratchReservations prefilled;
		assert(mvkReservePerVertexScratch((id<MTLDevice>)device, requests, prefilled));
		device->failAt = device->calls + 2;
		unsigned prepared = 0;
		assert(mvkSubmitTransaction<Submission>(2, [](uint32_t) { return new Submission; }, [&](Submission& submission) {
			if (!prepared++) { submission.executions[0] = prefilled; return VK_SUCCESS; }
			return mvkReservePerVertexScratch((id<MTLDevice>)device, requests, submission.executions[0]) ? VK_SUCCESS : VK_ERROR_OUT_OF_DEVICE_MEMORY;
		}, [](Submission*) { assert(false); return VK_SUCCESS; }) == VK_ERROR_OUT_OF_DEVICE_MEMORY);
		assert(liveBuffers == 10 && prefilled[0].use_count() == 1);
		prefilled.clear();
		assert(liveBuffers == 0);

		// Successful retry reserves every batch before the first dispatch. Reusable
		// and simultaneous executions must never share their writable scratch.
		device->calls = 0; device->failAt = 0;
		std::vector<std::unique_ptr<Submission>> inFlight;
		assert(mvkSubmitTransaction<Submission>(3, [](uint32_t) { return new Submission; }, [&](Submission& submission) {
			for (auto& execution : submission.executions) { assert(mvkReservePerVertexScratch((id<MTLDevice>)device, requests, execution)); }
			return VK_SUCCESS;
		}, [&](Submission* submission) {
			assert(device->calls == allocationCount);
			inFlight.emplace_back(submission); return VK_SUCCESS;
		}) == VK_SUCCESS);
		for (const auto& first : inFlight) {
			for (const auto& second : inFlight) {
				for (const auto& a : first->executions) {
					for (const auto& b : second->executions) {
						if (&a != &b) { assert(a[0]->buffers[0] != b[0]->buffers[0]); }
					}
				}
			}
		}
		// The same C++ shared ownership captured by production's Metal completion
		// block survives deletion/reset of submission and recorded-command owners.
		Completion completion = makeCompletion(inFlight[0]->executions[0][0]);
		inFlight.clear();
		assert(liveBuffers == 4);
		completion();
		[completion release];
		assert(liveBuffers == 0);

		// Host allocation failure during preparation also rolls back earlier batches.
		assert(mvkSubmitTransaction<Submission>(2, [](uint32_t i) { if (i) { throw std::bad_alloc(); } return new Submission; }, [&](Submission& submission) {
			assert(mvkReservePerVertexScratch((id<MTLDevice>)device, requests, submission.executions[0])); return VK_SUCCESS;
		}, [](Submission*) { assert(false); return VK_SUCCESS; }) == VK_ERROR_OUT_OF_HOST_MEMORY);
		assert(liveBuffers == 0);
		[device release];
	}
	std::puts("PASS: 120 allocation failures, optional corner allocation failures/success, unmapped buffer, whole-call rollback, prefill retry, independent executions, completion ownership, host OOM (CPU only)");
}
