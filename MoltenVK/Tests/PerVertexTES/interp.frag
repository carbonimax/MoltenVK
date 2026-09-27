#version 450
// Copyright 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
// The three original TES values weighted by the barycentrics must reproduce hardware interpolation.
#extension GL_EXT_fragment_shader_barycentric : require
layout(location = 0) pervertexEXT in vec3 color[3];
layout(location = 0) out vec4 outputColor;
#ifdef RESOURCES
layout(set = 0, binding = 1) uniform Scale { vec4 scale; } ubo;
#define SCALE * ubo.scale
#else
#define SCALE
#endif
void main() { outputColor = vec4(color[0] * gl_BaryCoordEXT.x + color[1] * gl_BaryCoordEXT.y + color[2] * gl_BaryCoordEXT.z, 1.0) SCALE; }
