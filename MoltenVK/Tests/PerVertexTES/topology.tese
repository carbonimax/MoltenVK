#version 450
// Copyright 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
// Linear position, nonlinear colour: interpolation exposes the triangulation; the patch shifts blue.
// Control points are integer pixel positions, so with dyadic tessellation coordinates every product and sum
// below is exact and a shared edge yields bitwise-equal positions whatever the evaluation order.
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
layout(location = 2) out vec3 tessCoord;
layout(location = 3) out vec3 patchPixel;  // TES gl_PrimitiveID, then the pixel position.
#ifdef CAPTURE
// Ordinary pipelines only: records the hardware tessellation coordinates of every TES invocation.
layout(set = 0, binding = 0) buffer Capture { uint count; uint words[]; } capture;
#endif
void main() {
	vec2 pixel = gl_TessCoord.x * gl_in[0].gl_Position.xy + gl_TessCoord.y * gl_in[1].gl_Position.xy + gl_TessCoord.z * gl_in[2].gl_Position.xy;
	gl_Position = vec4(pixel / vec2(96.0, 32.0) - 1.0, 0.0, 1.0);
	vec3 square = gl_TessCoord * gl_TessCoord;
	color = vec3(square.x, square.y, 0.5 * square.z + 0.25 * float(gl_PrimitiveID));
	interpolatedColor = color;
	tessCoord = gl_TessCoord;
	patchPixel = vec3(float(gl_PrimitiveID), pixel);
#ifdef CAPTURE
	uint slot = atomicAdd(capture.count, 1u);
	if (6u * slot + 6u <= uint(capture.words.length())) {
		capture.words[6u * slot] = uint(gl_PrimitiveID);
		capture.words[6u * slot + 1u] = floatBitsToUint(gl_TessCoord.x);
		capture.words[6u * slot + 2u] = floatBitsToUint(gl_TessCoord.y);
		capture.words[6u * slot + 3u] = floatBitsToUint(gl_TessCoord.z);
		capture.words[6u * slot + 4u] = floatBitsToUint(pixel.x);
		capture.words[6u * slot + 5u] = floatBitsToUint(pixel.y);
	}
#endif
}
