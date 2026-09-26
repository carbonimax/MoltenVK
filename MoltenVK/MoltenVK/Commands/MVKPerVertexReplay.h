/* Copyright (c) 2026 The Brenwill Workshop Ltd. Licensed under the Apache License, Version 2.0. */
#pragma once
#include <vulkan/vulkan.h>
#include <algorithm>
#include <cstdint>
#include <unordered_set>

// Caller checks counts and buffer bounds with mvkCanEncodePerVertexDraw before allocating.
// Records are dense (instance, input occurrence); corners follow the primitive's PerVertexKHR order.
static inline void mvkPopulatePerVertexReplay(uint32_t vertexCount, uint32_t instanceCount, VkPrimitiveTopology topology, bool provokingLast, uint32_t* pairs, uint32_t* indices, uint32_t* corners) {
	uint32_t triangleCount = topology == VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST ? vertexCount / 3 : (vertexCount > 2 ? vertexCount - 2 : 0);
	for (uint32_t instance = 0; instance < instanceCount; instance++) {
		for (uint32_t triangle = 0; triangle < triangleCount; triangle++) {
			uint32_t key = instance * uint32_t(triangleCount) + triangle;
			uint32_t vertices[] = {triangle * 3, triangle * 3 + 1, triangle * 3 + 2};
			// Vulkan primsrast-barycentric-order-table and -last-vertex. MoltenVK
			// advertises triStripVertexOrderIndependentOfProvokingVertex = false.
			// These orders also preserve winding and the replay triangle's provoking vertex.
			if (topology == VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP) {
				vertices[0] = triangle; vertices[1] = triangle + 1; vertices[2] = triangle + 2;
				if (triangle & 1) { std::swap(vertices[provokingLast ? 0 : 1], vertices[provokingLast ? 1 : 2]); }
			} else if (topology == VK_PRIMITIVE_TOPOLOGY_TRIANGLE_FAN) {
				vertices[0] = provokingLast ? 0 : triangle + 1;
				vertices[1] = provokingLast ? triangle + 1 : triangle + 2;
				vertices[2] = provokingLast ? triangle + 2 : 0;
			}
			for (uint32_t vertex = 0; vertex < 3; vertex++) {
				uint32_t occurrence = key * 3 + vertex;
				uint32_t record = instance * vertexCount + vertices[vertex];
				pairs[2 * occurrence] = record;
				pairs[2 * occurrence + 1] = key;
				indices[occurrence] = record;
				if (corners) { corners[occurrence] = vertex; }
			}
		}
	}
}

// Reserve whole locations: a private float3 must not share an application's Component lanes.
static inline uint32_t mvkAllocatePerVertexVaryingLocation(std::unordered_set<uint32_t>& locations, uint32_t maxLocations) {
	for (uint32_t location = 0; location < maxLocations; ++location) {
		if (locations.insert(location).second) { return location; }
	}
	return ~0u;
}
