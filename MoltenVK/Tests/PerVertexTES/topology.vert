#version 460
// Copyright 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
// Positions and tessellation levels arrive as vertex attributes the GPU wrote earlier in the command buffer.
layout(location = 0) in vec2 position;
layout(location = 1) in vec4 levels;
layout(location = 0) out vec4 vLevels;
#ifdef RESOURCES
// Side effect: one increment per vertex, including vertices of discarded patches.
#ifdef FIRST
layout(set = 0, binding = 0) buffer Counter { uint count; uint vertexSum; uint instanceSum; } counter;
#else
layout(set = 0, binding = 0) buffer Counter { uint count; } counter;
#endif
#endif
void main() {
	gl_Position = vec4(position, 0.0, 1.0);
	vLevels = levels;
#ifdef DRAWID
	vLevels += vec4(float(gl_DrawID));  // DrawID is 0 for the admitted direct draws.
#endif
#ifdef FIRST
	vLevels += vec4(float(gl_InstanceIndex) - 1.0);  // Drawn with firstInstance 1: the levels are exact only from there.
#endif
#ifdef RESOURCES
	atomicAdd(counter.count, 1u);
#ifdef FIRST
	atomicAdd(counter.vertexSum, uint(gl_VertexIndex));
	atomicAdd(counter.instanceSum, uint(gl_InstanceIndex));
#endif
#endif
}
