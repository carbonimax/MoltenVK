// Copyright 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
#version 450
layout(vertices = 3) out;
// LEVEL=4.0 gives levels without a proven PerVertex topology: the PerVertex draw must lose the device.
#ifndef LEVEL
#define LEVEL 1.0
#endif
void main() {
    gl_out[gl_InvocationID].gl_Position = gl_in[gl_InvocationID].gl_Position;
    if (gl_InvocationID == 0) {
        gl_TessLevelOuter[0] = LEVEL;
        gl_TessLevelOuter[1] = LEVEL;
        gl_TessLevelOuter[2] = LEVEL;
        gl_TessLevelInner[0] = LEVEL;
    }
}
