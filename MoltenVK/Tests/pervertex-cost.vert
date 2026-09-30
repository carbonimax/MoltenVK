#version 450
// Copyright 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
// A 64 x 64 grid of quads covering the target, without vertex buffers. Non-indexed: vertex v is corner v % 6 of quad
// v / 6. INDEXED: vertex v is grid point v of a 65 x 65 lattice, addressed by the index buffer.
layout(location = 0) out vec3 color;
const uint kGrid = 64u;
void main() {
	uint v = uint(gl_VertexIndex);
#ifdef INDEXED
	uvec2 point = uvec2(v % (kGrid + 1u), v / (kGrid + 1u));
#else
	const uvec2 corners[6] = uvec2[6](uvec2(0, 0), uvec2(1, 0), uvec2(1, 1), uvec2(1, 1), uvec2(0, 1), uvec2(0, 0));
	uint quad = v / 6u;
	uvec2 point = uvec2(quad % kGrid, quad / kGrid) + corners[v % 6u];
#endif
	vec2 p = vec2(point) / float(kGrid);
	color = vec3(p, fract(p.x * 7.0 + p.y * 3.0));
	gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}
