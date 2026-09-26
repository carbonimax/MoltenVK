/* Copyright (c) 2026 The Brenwill Workshop Ltd. Licensed under the Apache License, Version 2.0. */
#pragma once

#import <Metal/Metal.h>
#include <memory>
#include <vector>

struct MVKPerVertexScratchRequest {
	NSUInteger captureSize;
	NSUInteger occurrenceSize;
	NSUInteger primitiveSize;
	NSUInteger cornerSize = 0;
	NSUInteger indexSize = 0;
	bool restart = false;
};

// Individually owned allocations: the shared scratch pool cannot recover from a nil Metal buffer.
struct MVKPerVertexScratch {
	id<MTLBuffer> buffers[7] = {};
	id<MTLComputePipelineState> indexPipeline = nil;
	MVKPerVertexScratch() = default;
	MVKPerVertexScratch(const MVKPerVertexScratch&) = delete;
	MVKPerVertexScratch& operator=(const MVKPerVertexScratch&) = delete;
	~MVKPerVertexScratch() { for (auto buffer : buffers) { [buffer release]; } [indexPipeline release]; }

	bool reserve(id<MTLDevice> device, const MVKPerVertexScratchRequest& request) {
		// Indirect dispatch/draw arguments plus replay constants aligned to 256 bytes.
		NSUInteger lengths[] = {request.captureSize, sizeof(uint32_t), request.occurrenceSize, request.primitiveSize, request.cornerSize, request.indexSize, request.restart ? 68 * sizeof(uint32_t) : 0};
		for (size_t i = 0; i < 7; ++i) {
			if (!lengths[i]) { continue; }
			bool shared = i != 0 && i != 5 && i != 6;
			id<MTLBuffer> buffer = [device newBufferWithLength:lengths[i] options:shared ? MTLResourceStorageModeShared : MTLResourceStorageModePrivate];
			if (!buffer || buffer.length < lengths[i] || (shared && !buffer.contents)) { [buffer release]; return false; }
			buffers[i] = buffer;
		}
		return true;
	}
};

using MVKPerVertexScratchReservations = std::vector<std::shared_ptr<MVKPerVertexScratch>>;

// Publish only a complete reservation. Failure releases all allocations made by this attempt.
static inline bool mvkReservePerVertexScratch(id<MTLDevice> device, const std::vector<MVKPerVertexScratchRequest>& requests, MVKPerVertexScratchReservations& reservations) {
	MVKPerVertexScratchReservations pending;
	pending.reserve(requests.size());
	for (const auto& request : requests) {
		auto scratch = std::make_shared<MVKPerVertexScratch>();
		if (!scratch->reserve(device, request)) { return false; }
		pending.push_back(std::move(scratch));
	}
	reservations = std::move(pending);
	return true;
}
