// Copyright (c) 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
#version 450
#extension GL_EXT_fragment_shader_barycentric : require
#if DENSE
#define VALUE vec4
#define COUNT (LOCATIONS - 3)
#else
#define VALUE float
#define COUNT LOCATIONS
#endif
#if CAPTURED
layout(location = 0) pervertexEXT in VALUE values[][COUNT];
#if DENSE
layout(location = LOCATIONS - 3) pervertexEXT in vec2 tail[][3];
#endif
#else
layout(location = 0) in VALUE values[COUNT];
#if DENSE
layout(location = LOCATIONS - 3) in vec2 tail[3];
#endif
#endif
layout(location = 0) out vec4 color;
#if BUFFERS
layout(set = 0, binding = 0) uniform Buffer { vec4 value; } buffers[BUFFERS];
#endif
void main() {
    color = vec4(0.0);
    for (int i = 0; i < COUNT; ++i) {
#if CAPTURED
        color += vec4(values[0][i]) + vec4(values[1][i]) + vec4(values[2][i]);
#else
        color += vec4(values[i]);
#endif
    }
#if DENSE
    for (int i = 0; i < 3; ++i) {
#if CAPTURED
        color.xy += tail[0][i] + tail[1][i] + tail[2][i];
#else
        color.xy += tail[i];
#endif
    }
#endif
#if PERSPECTIVE
    color.xyz += gl_BaryCoordEXT;
#endif
#if LINEAR
    color.xyz += gl_BaryCoordNoPerspEXT;
#endif
#if BUFFERS
    for (int i = 0; i < BUFFERS; ++i) { color += buffers[i].value; }
#endif
}
