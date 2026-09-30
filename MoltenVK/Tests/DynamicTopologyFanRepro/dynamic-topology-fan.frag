#version 450
// Copyright 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
// The colour interpolated by the rasterizer, with no barycentric input. Alpha 0.5 exposes draw order when blending.
layout(location = 0) out vec4 outputColor;
layout(location = 0) in vec3 color;
void main() { outputColor = vec4(color, 0.5); }
