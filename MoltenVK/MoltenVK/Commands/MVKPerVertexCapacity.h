/* Copyright (c) 2026 The Brenwill Workshop Ltd. Licensed under the Apache License, Version 2.0. */
#pragma once
#include <spirv_msl.hpp>
#include <algorithm>
#include <cstdint>
#include <map>

// Component decorations can make Metal pad a location up to its highest occupied lane.
// Replay currently emits all captured outputs, even those read through fragment buffers.
static inline uint64_t mvkPerVertexReplayVaryingComponents(const SPIRV_CROSS_NAMESPACE::MSLCapturedVertexLayout& layout, bool perspective, bool noPerspective) {
	std::map<uint32_t, uint32_t> widths;
	for (const auto& field : layout.components) { widths[field.location] = std::max(widths[field.location], field.component + 1); }
	uint64_t count = 1 + 3 * uint32_t(perspective) + 3 * uint32_t(noPerspective);
	for (const auto& width : widths) { count += width.second; }
	// Position has a dedicated rasterizer output. Conservatively charge other captured builtins.
	for (const auto& field : layout.builtins) { if (field.builtin != spv::BuiltInPosition) { ++count; } }
	return count;
}

static inline bool mvkPerVertexBufferIndexAvailable(uint32_t index, uint32_t descriptorCount, uint32_t bufferCount) { return index >= descriptorCount && index < bufferCount; }
