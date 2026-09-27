#version 450
// Copyright 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
// Linear position, nonlinear colour: interpolation exposes the triangulation; the patch shifts blue.
#if defined(QUADS)
layout(quads, equal_spacing, ccw) in;
#elif defined(FRACTIONAL)
layout(triangles, fractional_odd_spacing, ccw) in;
#elif defined(POINTS)
layout(triangles, equal_spacing, ccw, point_mode) in;
#elif defined(CW)
layout(triangles, equal_spacing, cw) in;
#else
layout(triangles, equal_spacing, ccw) in;
#endif
layout(location = 0) out vec3 color;
layout(location = 1) out vec3 interpolatedColor;
void main() {
	gl_Position = gl_TessCoord.x * gl_in[0].gl_Position + gl_TessCoord.y * gl_in[1].gl_Position + gl_TessCoord.z * gl_in[2].gl_Position;
	vec3 square = gl_TessCoord * gl_TessCoord;
	color = vec3(square.x, square.y, 0.5 * square.z + 0.25 * float(gl_PrimitiveID));
	interpolatedColor = color;
}
