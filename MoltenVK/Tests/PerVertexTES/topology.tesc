#version 450
// Copyright 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
// Writes the levels of each patch exactly as received: outer[0..2] = xyz, inner[0] = w.
layout(vertices = 3) out;
layout(location = 0) in vec4 vLevels[];
#ifdef DESCRIPTOR
layout(set = 0, binding = 0) uniform Scale { float scale; } ubo;
#endif
void main() {
	gl_out[gl_InvocationID].gl_Position = gl_in[gl_InvocationID].gl_Position;
	if (gl_InvocationID == 0) {
		vec4 levels = vLevels[0];
#ifdef DESCRIPTOR
		levels *= ubo.scale;
#endif
		gl_TessLevelOuter[0] = levels.x;
		gl_TessLevelOuter[1] = levels.y;
		gl_TessLevelOuter[2] = levels.z;
		gl_TessLevelOuter[3] = 0.0;
		gl_TessLevelInner[0] = levels.w;
		gl_TessLevelInner[1] = 0.0;
	}
}
