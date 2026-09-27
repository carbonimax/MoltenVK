/* Copyright (c) 2026 Jean-Philippe Meunier. Licensed under the Apache License, Version 2.0. */
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
	bool widenUint8 = false;
	// TES invocation ABI, VS output, TCS vertex and patch output, float32 levels, topology plan.
	NSUInteger tessSizes[6] = {};
};

// Individually owned allocations: the shared scratch pool cannot recover from a nil Metal buffer.
struct MVKPerVertexScratch {
	id<MTLBuffer> buffers[13] = {};
	id<MTLComputePipelineState> indexPipeline = nil;
	id<MTLComputePipelineState> widenUint8Pipeline = nil;
	id<MTLComputePipelineState> tessTopologyPipeline = nil;
	MVKPerVertexScratch() = default;
	MVKPerVertexScratch(const MVKPerVertexScratch&) = delete;
	MVKPerVertexScratch& operator=(const MVKPerVertexScratch&) = delete;
	~MVKPerVertexScratch() { for (auto buffer : buffers) { [buffer release]; } [indexPipeline release]; [widenUint8Pipeline release]; [tessTopologyPipeline release]; }

	bool reserve(id<MTLDevice> device, const MVKPerVertexScratchRequest& request) {
		// Indirect dispatch/draw arguments plus replay constants aligned to 256 bytes.
		NSUInteger lengths[] = {request.captureSize, sizeof(uint32_t), request.occurrenceSize, request.primitiveSize, request.cornerSize, request.indexSize, request.restart ? 68 * sizeof(uint32_t) : 0, request.tessSizes[0], request.tessSizes[1], request.tessSizes[2], request.tessSizes[3], request.tessSizes[4], request.tessSizes[5]};
		for (size_t i = 0; i < std::size(buffers); ++i) {
			if (!lengths[i]) { continue; }
			bool shared = (i > 0 && i < 5) || i == 7 || i == 12;
			id<MTLBuffer> buffer = [device newBufferWithLength:lengths[i] options:shared ? MTLResourceStorageModeShared : MTLResourceStorageModePrivate];
			if (!buffer || buffer.length < lengths[i] || (shared && !buffer.contents)) { [buffer release]; return false; }
			buffers[i] = buffer;
		}
		// The TES topology plan starts with a status word the GPU only ORs into.
		if (buffers[12]) { memset(buffers[12].contents, 0, buffers[12].length); }
		return true;
	}

	// Nonzero when the GPU refused a TES draw whose levels have no proven topology. Read after completion.
	uint32_t getTessEvalStatus() const { return buffers[12] ? *(volatile const uint32_t*)buffers[12].contents : 0; }
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
