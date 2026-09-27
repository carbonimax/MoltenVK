#version 450
// Copyright 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
// Vulkan requires the PerVertexKHR vertex order to match the barycentric order: green if it does.
#extension GL_EXT_fragment_shader_barycentric : require
layout(location = 0) pervertexEXT in vec3 color[3];
layout(location = 1) in vec3 interpolatedColor;
layout(location = 0) out vec4 outputColor;
void main() {
	vec3 reconstructed = color[0] * gl_BaryCoordEXT.x + color[1] * gl_BaryCoordEXT.y + color[2] * gl_BaryCoordEXT.z;
	outputColor = all(lessThan(abs(reconstructed - interpolatedColor), vec3(0.01))) ? vec4(0, 1, 0, 1) : vec4(1, 0, 0, 1);
}
