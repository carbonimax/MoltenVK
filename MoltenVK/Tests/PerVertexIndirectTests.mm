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
	bool recordedGraphicsPipelineUsesPerVertexInput() const { return portable; }
	auto& getMetalFeatures() { return features; }
	VkResult reportError(VkResult result, const char*) { ++errors; return result; }
};
#include "IndirectRecording.inc"

template<class Command> static void testRecording() {
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
				bool rejected = portable && count != 0;
				check(result == (rejected ? VK_ERROR_FEATURE_NOT_PRESENT : VK_SUCCESS), "indirect recording admission");
				check(buffer.errors == unsigned(rejected), "recording error reporting");
				if (rejected) {
					check(arguments.accesses == 0 && counter.accesses == 0, "reject before touching GPU argument/count buffers");
				} else {
					check(command._drawCount == count && command._mtlIndirectBufferOffset == 144 && command._mtlIndirectBufferStride == 32, "ordinary/no-op command metadata");
					check(command._mtlCountBufferOffset == (counted ? 132u : 0u), "pooled count-buffer offset reset");
					check(arguments.accesses == 2 && counter.accesses == (counted ? 2u : 0u), "only buffer metadata accessed");
				}
			}
		}
	}
	MVKCommandBuffer buffer;
	MVKBuffer arguments;
	buffer.features.indirectDrawing = false;
	check(command.setContent(&buffer, reinterpret_cast<VkBuffer>(&arguments), 0, 1, 16) == VK_ERROR_FEATURE_NOT_PRESENT, "ordinary indirect hardware capability rejection");
	buffer.features.indirectDrawing = true;
	buffer.features.indirectTessellationDrawing = false;
	buffer._lastTessellationPipeline = true;
	check(command.setContent(&buffer, reinterpret_cast<VkBuffer>(&arguments), 0, 1, 16) == VK_ERROR_FEATURE_NOT_PRESENT, "ordinary indirect tessellation capability rejection");
}

int main() {
	testRecording<MVKCmdDrawIndirect>();
	testRecording<MVKCmdDrawIndexedIndirect>();
	// Internal fan conversion can encode an earlier ordinary pipeline while the
	// recorded pipeline points at a later portable draw. It must stay admissible.
	MVKCommandBuffer buffer;
	buffer.portable = true;
	MVKCmdDrawIndexedIndirect internal;
	check(internal.setContent(&buffer, (id<MTLBuffer>)nil, 64, 2, 20) == VK_SUCCESS, "internal fan conversion ignores later recorded pipeline");
	check(internal._drawCount == 2 && internal._mtlIndirectBufferOffset == 64 && internal._mtlCountBufferOffset == 0, "internal fan metadata");
	std::printf("PASS: %u CPU checks; four Vulkan indirect recording paths, zero counts, early rejection, pooled reuse and ordinary/internal controls\n", checks);
}
