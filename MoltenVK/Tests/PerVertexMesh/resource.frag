#version 450
// Copyright 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
// Fragment resources of a PerVertexKHR mesh pipeline, indexed by the vertex index of each corner (forms.mesh with
// RESOURCE): a table read through a buffer device address taken from the push constants, a storage buffer bound
// through a descriptor set, and a push constant salt. Writes uvec4(table[corner 0], table[corner 1],
// table[corner 2], storage[corner 2] ^ salt). A table that is not resident, or not the one whose address was pushed,
// changes the value; mesh-draw.cpp compares every checked pixel bit for bit.
#extension GL_EXT_fragment_shader_barycentric : require
#extension GL_EXT_buffer_reference : require
layout(buffer_reference, std430, buffer_reference_align = 4) readonly buffer Table { uint values[16]; };
layout(push_constant, std430) uniform Push { Table table; uint salt; } push;
layout(set = 0, binding = 0, std430) readonly buffer Storage { uint values[16]; } storage;
layout(location = 10) pervertexEXT in uint vid[3];
layout(location = 0) out uvec4 result;

void main()
{
	result = uvec4(push.table.values[vid[0]], push.table.values[vid[1]], push.table.values[vid[2]], storage.values[vid[2]] ^ push.salt);
}
