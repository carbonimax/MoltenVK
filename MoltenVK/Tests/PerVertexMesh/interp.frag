#version 450
// Copyright 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
layout(location = 0) in vec4 color;
layout(location = 0) out vec4 outputColor;
void main() { outputColor = color; }
