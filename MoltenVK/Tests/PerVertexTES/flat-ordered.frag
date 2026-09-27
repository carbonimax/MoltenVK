#version 450
// Copyright 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
// Order-sensitive and constant per triangle. SWAP exchanges the first two corners (negative control).
#extension GL_EXT_fragment_shader_barycentric : require
layout(location = 0) pervertexEXT in vec3 color[3];
layout(location = 0) out vec4 outputColor;
void main() {
#ifdef SWAP
	outputColor = vec4(color[1] * 0.2 + color[0] * 0.3 + color[2] * 0.5, 1.0);
#else
	outputColor = vec4(color[0] * 0.2 + color[1] * 0.3 + color[2] * 0.5, 1.0);
#endif
}
