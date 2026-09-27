// Copyright 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
#version 450
layout(triangles, equal_spacing, ccw) in;
layout(location = 0) out vec3 color;
layout(location = 1) out vec3 interpolatedColor;
void main() {
    gl_Position = gl_TessCoord.x * gl_in[0].gl_Position + gl_TessCoord.y * gl_in[1].gl_Position + gl_TessCoord.z * gl_in[2].gl_Position;
    color = gl_TessCoord + vec3(float(gl_PrimitiveID) * 2.0);
    interpolatedColor = gl_TessCoord + vec3(float(gl_PrimitiveID) * 2.0);
}
