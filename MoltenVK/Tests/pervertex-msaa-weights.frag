#version 450
// Copyright 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
// The fragments of the CTS weights test (dEQP-VK.fragment_shading_barycentric.weights.*.msaa_interpolate_at_offset and
// msaa_interpolate_at_sample), perspective. OFFSET or SAMPLE: the PerVertexKHR values weighted by BaryCoordKHR at the
// sample position or at the sample. ORDINARY_OFFSET: interpolateAtOffset on an ordinary input, without PerVertexKHR, to
// separate the offset lowering from PerVertexKHR. Otherwise the reference, the colour interpolated at the sample.
#if defined(OFFSET) || defined(SAMPLE)
#extension GL_EXT_fragment_shader_barycentric : require
layout(location = 0) pervertexEXT in vec3 color[3];
#elif defined(ORDINARY_OFFSET)
layout(location = 0) in vec3 color;
#else
layout(location = 0) sample in vec3 color;
#endif
layout(location = 0) out vec4 outputColor;
void main() {
#if defined(OFFSET)
	vec3 weights = interpolateAtOffset(gl_BaryCoordEXT, vec2(gl_SamplePosition - vec2(0.5)));
#elif defined(SAMPLE)
	vec3 weights = interpolateAtSample(gl_BaryCoordEXT, gl_SampleID);
#endif
#if defined(ORDINARY_OFFSET)
	outputColor = vec4(interpolateAtOffset(color, vec2(gl_SamplePosition - vec2(0.5))), 1.0);
#elif defined(OFFSET) || defined(SAMPLE)
	outputColor = vec4(color[0] * weights.x + color[1] * weights.y + color[2] * weights.z, 1.0);
#else
	outputColor = vec4(color, 1.0);
#endif
}
