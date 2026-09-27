#version 450
// Copyright 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
// Order-sensitive and constant per triangle: 0.2, 0.3 and 0.5 times the three PerVertexKHR corners.
// SWAPPED: the permuted witness, 0.3, 0.2 and 0.5. BARYCENTRIC: gl_BaryCoordEXT alone, no PerVertexKHR input.
// CONSISTENCY: the corners weighted by gl_BaryCoordEXT, which must equal the interpolated value. BLOCK and MATRIX
// read forms the mesh path refuses: a PerVertexKHR block and a PerVertexKHR matrix.
#extension GL_EXT_fragment_shader_barycentric : require
#if defined(BLOCK)
layout(location = 0) pervertexEXT in Corner { vec4 color; } corner[3];
#define CORNER(k) corner[k].color
#elif defined(MATRIX)
layout(location = 0) pervertexEXT in mat2 color[3];
#define CORNER(k) vec4(color[k][0], color[k][1])
#elif !defined(BARYCENTRIC)
layout(location = 0) pervertexEXT in vec4 color[3];
#define CORNER(k) color[k]
#endif
layout(location = 0) out vec4 outputColor;
void main() {
#if defined(BARYCENTRIC)
	outputColor = vec4(gl_BaryCoordEXT, 1.0);
#elif defined(CONSISTENCY)
	outputColor = vec4((gl_BaryCoordEXT.x * CORNER(0) + gl_BaryCoordEXT.y * CORNER(1) + gl_BaryCoordEXT.z * CORNER(2)).rgb, 1.0);
#elif defined(SWAPPED)
	outputColor = vec4((0.3 * CORNER(0) + 0.2 * CORNER(1) + 0.5 * CORNER(2)).rgb, 1.0);
#else
	outputColor = vec4((0.2 * CORNER(0) + 0.3 * CORNER(1) + 0.5 * CORNER(2)).rgb, 1.0);
#endif
}
