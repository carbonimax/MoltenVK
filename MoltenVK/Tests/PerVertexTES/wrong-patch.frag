// Copyright 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
#version 450
#extension GL_EXT_fragment_shader_barycentric : require
layout(location=0) pervertexEXT in vec3 corner[3];
layout(location=1) in vec3 interpolatedColor;
layout(location=0) out vec4 outputColor;
void main() {
    vec3 reconstructed = corner[0] * gl_BaryCoordEXT.x + corner[1] * gl_BaryCoordEXT.y + corner[2] * gl_BaryCoordEXT.z;
    float wrongBase = gl_FragCoord.x < 16.0 ? 2.0 : 0.0;
    bool patchOK = abs(dot(corner[0], vec3(1.0)) - (1.0 + 3.0 * wrongBase)) < 0.01;
    outputColor = patchOK && all(lessThan(abs(reconstructed - interpolatedColor), vec3(0.01))) ? vec4(0,1,0,1) : vec4(1,0,0,1);
}
