#version 450
// Copyright 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
// Stores the three PerVertexKHR TES vertices of each covered pixel: patch, tessellation coordinates and
// pixel position, as raw bits. Captured values reach the fragment unchanged, without interpolation.
#extension GL_EXT_fragment_shader_barycentric : require
layout(location = 2) pervertexEXT in vec3 tessCoord[3];
layout(location = 3) pervertexEXT in vec3 patchPixel[3];
layout(set = 0, binding = 0) buffer Capture { uint words[]; } capture;
layout(location = 0) out vec4 outputColor;
void main() {
	uint base = (uint(gl_FragCoord.y) * 192u + uint(gl_FragCoord.x)) * 18u;
	for (uint k = 0u; k < 3u; ++k) {
		capture.words[base + 6u * k] = floatBitsToUint(patchPixel[k].x);
		capture.words[base + 6u * k + 1u] = floatBitsToUint(tessCoord[k].x);
		capture.words[base + 6u * k + 2u] = floatBitsToUint(tessCoord[k].y);
		capture.words[base + 6u * k + 3u] = floatBitsToUint(tessCoord[k].z);
		capture.words[base + 6u * k + 4u] = floatBitsToUint(patchPixel[k].y);
		capture.words[base + 6u * k + 5u] = floatBitsToUint(patchPixel[k].z);
	}
	outputColor = vec4(1.0);
}
