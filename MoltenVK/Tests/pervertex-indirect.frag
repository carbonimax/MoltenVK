#version 450
// Copyright 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
// Order-sensitive weights of the three original vertex values; alpha 0.5 exposes draw order when blending.
#extension GL_EXT_fragment_shader_barycentric : require
layout(location = 0) pervertexEXT in vec3 color[3];
layout(location = 0) out vec4 outputColor;
#ifdef SWAP
// Negative control: the first two corners exchanged must no longer match the reference.
void main() { outputColor = vec4(color[1] * 0.2 + color[0] * 0.3 + color[2] * 0.5, 0.5); }
#else
void main() { outputColor = vec4(color[0] * 0.2 + color[1] * 0.3 + color[2] * 0.5, 0.5); }
#endif
