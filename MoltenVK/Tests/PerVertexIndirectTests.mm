/* Copyright (c) 2026 Jean-Philippe Meunier. Licensed under the Apache License, Version 2.0. */
#import <Metal/Metal.h>
#include <vulkan/vulkan.h>
#include <cstdio>
#include <cstdlib>
#include <initializer_list>

static unsigned checks = 0;
static void check(bool condition, const char* message) {
	++checks;
	if (!condition) { std::fprintf(stderr, "FAIL: %s\n", message); std::exit(1); }
}

// Metadata-only double: deliberately offers no host pointer or argument read API.
struct MVKBuffer {
	unsigned accesses = 0;
	id<MTLBuffer> getMTLBuffer() { ++accesses; return nil; }
	VkDeviceSize getMTLBufferOffset() { ++accesses; return 128; }
};
struct MVKCommandBuffer {
	bool portable = false;
	bool _lastTessellationPipeline = false;
	struct { bool indirectDrawing = true; bool indirectTessellationDrawing = true; } features;
	unsigned errors = 0;
	unsigned reservations = 0;
	int indexedReservation = -1;
	VkResult reservationResult = VK_SUCCESS;
	bool recordedGraphicsPipelineUsesPerVertexInput() const { return portable; }
	auto& getMetalFeatures() { return features; }
	VkResult reportError(VkResult result, const char*) { ++errors; return result; }
	// Mirrors production: ordinary pipelines reserve nothing; portable ones reserve bounded scratch.
	VkResult recordPerVertexIndirectDraw(bool indexed) {
		if (!portable) { return VK_SUCCESS; }
		++reservations;
		indexedReservation = indexed;
		return reservationResult;
	}
};
#include "IndirectRecording.inc"

template<class Command> static void testRecording(bool indexed) {
	Command command;
	// Reuse the same command object to exercise pooled-command count-buffer resets.
	for (bool portable : {false, true}) {
		for (bool counted : {true, false}) {
			for (uint32_t count : {0u, 1u, 2u, UINT32_MAX}) {
				MVKCommandBuffer buffer;
				buffer.portable = portable;
				MVKBuffer arguments, counter;
				VkBuffer args = reinterpret_cast<VkBuffer>(&arguments), counts = reinterpret_cast<VkBuffer>(&counter);
				VkResult result = counted ? command.setContent(&buffer, args, 16, counts, 4, count, 32) : command.setContent(&buffer, args, 16, count, 32);
				bool reserved = portable && count != 0;
				check(result == VK_SUCCESS && buffer.errors == 0, "portable and ordinary indirect recording admission");
				check(buffer.reservations == unsigned(reserved), "portable indirect reserves scratch once, zero counts reserve nothing");
				if (reserved) { check(buffer.indexedReservation == int(indexed), "reservation matches the indexed form"); }
				check(command._drawCount == count && command._mtlIndirectBufferOffset == 144 && command._mtlIndirectBufferStride == 32, "command metadata");
				check(command._mtlCountBufferOffset == (counted ? 132u : 0u), "pooled count-buffer offset reset");
				// Arguments and Count are GPU data: recording only resolves their Metal buffers and offsets.
				check(arguments.accesses == 2 && counter.accesses == (counted ? 2u : 0u), "only buffer metadata accessed");
			}
		}
	}
	for (bool counted : {true, false}) {
		MVKCommandBuffer buffer;
		buffer.portable = true;
		buffer.reservationResult = VK_ERROR_OUT_OF_DEVICE_MEMORY;
		MVKBuffer arguments, counter;
		VkBuffer args = reinterpret_cast<VkBuffer>(&arguments), counts = reinterpret_cast<VkBuffer>(&counter);
		VkResult result = counted ? command.setContent(&buffer, args, 0, counts, 0, 3, 32) : command.setContent(&buffer, args, 0, 3, 32);
		check(result == VK_ERROR_OUT_OF_DEVICE_MEMORY && buffer.reservations == 1, "reservation failure fails recording");
	}
	MVKCommandBuffer buffer;
	MVKBuffer arguments;
	buffer.portable = true;
	buffer.features.indirectDrawing = false;
	check(command.setContent(&buffer, reinterpret_cast<VkBuffer>(&arguments), 0, 1, 16) == VK_ERROR_FEATURE_NOT_PRESENT && buffer.reservations == 0, "hardware capability rejection precedes reservation");
	buffer.features.indirectDrawing = true;
	buffer.features.indirectTessellationDrawing = false;
	buffer._lastTessellationPipeline = true;
	check(command.setContent(&buffer, reinterpret_cast<VkBuffer>(&arguments), 0, 1, 16) == VK_ERROR_FEATURE_NOT_PRESENT && buffer.reservations == 0, "tessellation capability rejection precedes reservation");
}

int main() {
	testRecording<MVKCmdDrawIndirect>(false);
	testRecording<MVKCmdDrawIndexedIndirect>(true);
	// Internal fan conversion can encode an earlier ordinary pipeline while the
	// recorded pipeline points at a later portable draw. It must stay admissible.
	MVKCommandBuffer buffer;
	buffer.portable = true;
	MVKCmdDrawIndexedIndirect internal;
	check(internal.setContent(&buffer, (id<MTLBuffer>)nil, 64, 2, 20) == VK_SUCCESS, "internal fan conversion ignores later recorded pipeline");
	check(internal._drawCount == 2 && internal._mtlIndirectBufferOffset == 64 && internal._mtlCountBufferOffset == 0 && buffer.reservations == 0, "internal fan metadata without reservation");
	std::printf("PASS: %u CPU checks; four Vulkan indirect recording paths reserve bounded GPU-planned scratch, zero counts, reservation failure, pooled reuse and ordinary/internal controls\n", checks);
}
