#version 450
// Copyright 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
// Order-sensitive and constant per triangle: 0.2, 0.3 and 0.5 times the three PerVertexKHR corners.
#extension GL_EXT_fragment_shader_barycentric : require
layout(location = 0) pervertexEXT in vec4 color[3];
layout(location = 0) out vec4 outputColor;
void main() { outputColor = vec4((0.2 * color[0] + 0.3 * color[1] + 0.5 * color[2]).rgb, 1.0); }
