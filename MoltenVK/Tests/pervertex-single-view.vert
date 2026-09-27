// Copyright (c) 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
#version 450
#extension GL_EXT_multiview : require
layout(location = 0) in vec4 position;
layout(location = 1) in vec4 instanceValue;
layout(location = 0) out vec4 value;
layout(location = 1) out vec2 ordinary;
void main() {
    gl_Position = position;
    value = instanceValue + vec4(float(gl_ViewIndex), float(gl_InstanceIndex), float(gl_VertexIndex), 0.0);
    ordinary = vec2(gl_ViewIndex, gl_InstanceIndex);
}
