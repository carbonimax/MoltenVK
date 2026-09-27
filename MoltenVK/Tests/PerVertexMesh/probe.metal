// Copyright 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
// Smallest Metal mesh probe for PerVertexKHR: one threadgroup emits four vertices with distinct values and two
// triangles whose index orders are not rotations of each other. Each primitive also carries a copy of its three
// corner values, taken in index order from the vertices the mesh function just wrote: the fragment can then read
// the per-corner values of its own triangle, and [[barycentric_coord]] must weight them in the same order.
#include <metal_stdlib>
using namespace metal;

struct MeshVertex {
	float4 position [[position]];
	float4 color [[user(color)]];
};

struct MeshPrimitive {
	float4 c0 [[user(c0)]];
	float4 c1 [[user(c1)]];
	float4 c2 [[user(c2)]];
	float4 tag [[user(tag)]];
};

using ProbeMesh = mesh<MeshVertex, MeshPrimitive, 4, 2, topology::triangle>;

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
		MeshPrimitive p;
		p.c0 = kColors[corners.x];
		p.c1 = kColors[corners.y];
		p.c2 = kColors[corners.z];
		p.tag = tid ? float4(1, 0, 0.5, 1) : float4(0, 1, 0.5, 1);
		output.set_primitive(tid, p);
	}
}

struct Interpolated { float4 color [[user(color)]]; };
struct Tagged { float4 tag [[user(tag), flat]]; };
struct Corners {
	float4 color [[user(color)]];
	float4 c0 [[user(c0), flat]];
	float4 c1 [[user(c1), flat]];
	float4 c2 [[user(c2), flat]];
};

fragment float4 probeInterp(Interpolated in [[stage_in]]) { return in.color; }
fragment float4 probeTag(Tagged in [[stage_in]]) { return in.tag; }
fragment float4 probeOrdered(Corners in [[stage_in]]) { return float4((0.2 * in.c0 + 0.3 * in.c1 + 0.5 * in.c2).rgb, 1); }
fragment float4 probeSwapped(Corners in [[stage_in]]) { return float4((0.2 * in.c1 + 0.3 * in.c0 + 0.5 * in.c2).rgb, 1); }
fragment float4 probeConsistency(Corners in [[stage_in]], float3 bary [[barycentric_coord]]) {
	float4 reconstructed = bary.x * in.c0 + bary.y * in.c1 + bary.z * in.c2;
	return all(abs(reconstructed - in.color) < 0.01) ? float4(0, 1, 0, 1) : float4(1, 0, 0, 1);
}
fragment float4 probeBarycentric(Interpolated in [[stage_in]], float3 bary [[barycentric_coord]]) { return float4(bary, 1); }
fragment float4 probePrimitiveId(Interpolated in [[stage_in]], uint primitive [[primitive_id]]) { return float4(float(primitive) / 255.0, 0, 0, 1); }
