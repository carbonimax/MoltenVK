// Copyright 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
// Negative control: the native MSL 4 per-vertex fragment input (vertex_value), with the same mesh function.
#include <metal_stdlib>
using namespace metal;

struct MeshVertex {
	float4 position [[position]];
	float4 color [[user(color)]];
};

using ProbeMesh = mesh<MeshVertex, void, 4, 2, topology::triangle>;

constant float2 kPositions[4] = {float2(-0.75, -0.75), float2(0.75, -0.75), float2(-0.75, 0.75), float2(0.75, 0.75)};
constant float4 kColors[4] = {float4(0.8, 0.1, 0.2, 1), float4(0.1, 0.7, 0.3, 1), float4(0.2, 0.3, 0.9, 1), float4(0.6, 0.5, 0.4, 1)};
constant uint3 kTriangles[2] = {uint3(0, 1, 2), uint3(3, 2, 1)};

[[mesh]] void probeMesh(ProbeMesh output, uint tid [[thread_index_in_threadgroup]]) {
	if (tid == 0) { output.set_primitive_count(2); }
	if (tid < 4) {
		MeshVertex v;
		v.position = float4(kPositions[tid], 0, 1);
		v.color = kColors[tid];
		output.set_vertex(tid, v);
	}
	if (tid < 2) {
		uint3 corners = kTriangles[tid];
		output.set_index(3 * tid, corners.x);
		output.set_index(3 * tid + 1, corners.y);
		output.set_index(3 * tid + 2, corners.z);
	}
}

struct NativeCorners { vertex_value<float4> color [[user(color)]]; };

fragment float4 probeVertexValue(NativeCorners in [[stage_in]]) {
	float4 value = 0.2 * in.color.get(vertex_index::first) + 0.3 * in.color.get(vertex_index::second) + 0.5 * in.color.get(vertex_index::third);
	return float4(value.rgb, 1);
}
