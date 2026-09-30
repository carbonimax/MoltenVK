#version 450
// Copyright 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
// PERVERTEX: the three vertex values weighted by BaryCoordKHR, through MoltenVK's portable capture and replay.
// Otherwise the ordinary interpolated colour. Both give the same image within rounding.
#ifdef PERVERTEX
#extension GL_EXT_fragment_shader_barycentric : require
layout(location = 0) pervertexEXT in vec3 color[3];
#else
layout(location = 0) in vec3 color;
#endif
layout(location = 0) out vec4 outputColor;
void main() {
#ifdef PERVERTEX
	outputColor = vec4(color[0] * gl_BaryCoordEXT.x + color[1] * gl_BaryCoordEXT.y + color[2] * gl_BaryCoordEXT.z, 1.0);
#else
	outputColor = vec4(color, 1.0);
#endif
}
