#version 450
// Copyright 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
// ORDINARY: the colour interpolated by the rasterizer, without PerVertexKHR, so that the pipeline takes MoltenVK's
// ordinary draw path. Alpha 0.5 exposes draw order when blending.
layout(location = 0) in vec3 color;
layout(location = 0) out vec4 outputColor;
void main() { outputColor = vec4(color, 0.5); }
