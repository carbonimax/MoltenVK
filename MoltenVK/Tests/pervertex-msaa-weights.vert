#version 450
// Copyright 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
// The vertex shader of the CTS weights test, with the identity transform of its rotation 0.
layout(location = 0) in vec4 position;
layout(location = 1) in vec4 inputColor;
layout(location = 0) out vec3 color;
void main() {
	color = inputColor.xyz;
	gl_Position = position;
}
