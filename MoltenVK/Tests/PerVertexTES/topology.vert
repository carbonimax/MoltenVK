#version 450
// Copyright 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
// Positions and tessellation levels arrive as vertex attributes the GPU wrote earlier in the command buffer.
layout(location = 0) in vec2 position;
layout(location = 1) in vec4 levels;
layout(location = 0) out vec4 vLevels;
void main() {
	gl_Position = vec4(position, 0.0, 1.0);
	vLevels = levels;
}
