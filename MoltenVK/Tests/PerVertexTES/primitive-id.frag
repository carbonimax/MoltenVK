#version 450
// Copyright 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
// Red carries the fragment gl_PrimitiveID exactly. Without a geometry shader, Vulkan requires the value the
// TES received: the patch index within the draw, not the index of a tessellated triangle.
#ifdef ORDINARY
layout(location = 0) in vec3 color;
#define USE color.x
#else
#extension GL_EXT_fragment_shader_barycentric : require
layout(location = 0) pervertexEXT in vec3 color[3];
#define USE color[0].x
#endif
layout(location = 0) out vec4 outputColor;
void main() { outputColor = vec4(float(gl_PrimitiveID) / 255.0, USE >= 0.0 ? 1.0 : 0.5, 0.0, 1.0); }
