#version 450
// Copyright 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
// Reads one PerVertexKHR form written by forms.mesh and writes, for each corner in index order, the bit patterns of
// its scalars folded by rotate-and-xor (fold in mesh-draw.cpp), plus a tag: uvec4(corner0, corner1, corner2, tag).
// Corners beyond the array size read as zero. One macro selects the form:
//   UINT, IVEC2, VEC3, UVEC3: 32-bit integers and floats; COMPONENTS: float, vec2 and float sharing Location 3;
//   FEWER: vec2 read from a vec4 output; SCALAR, ARRAY1, ARRAY2: float read as 3, 1 and 2 corners;
//   HALF, INT16, UINT16: 16-bit forms, HALF at Component 2, UINT16 at Location 30; MIXED: UINT, VEC3, COMPONENTS and SCALAR together;
//   SWAPPED: the UINT form with corners 0 and 1 written in each other's place, a witness that must match the swapped
//   model and not the ordered one.
#extension GL_EXT_fragment_shader_barycentric : require
#if defined(HALF) || defined(INT16) || defined(UINT16)
#extension GL_EXT_shader_explicit_arithmetic_types : require
#endif
#if defined(UINT) || defined(SWAPPED) || defined(MIXED)
layout(location = 0) pervertexEXT in uint u1[3];
#endif
#ifdef IVEC2
layout(location = 1) pervertexEXT in ivec2 i2[3];
#endif
#if defined(VEC3) || defined(MIXED)
layout(location = 2) pervertexEXT in vec3 f3[3];
#endif
#if defined(COMPONENTS) || defined(MIXED)
layout(location = 3, component = 0) pervertexEXT in float c0[3];
layout(location = 3, component = 1) pervertexEXT in vec2 c12[3];
layout(location = 3, component = 3) pervertexEXT in float c3[3];
#endif
#ifdef FEWER
layout(location = 4) pervertexEXT in vec2 wide[3];
#endif
#ifdef UVEC3
layout(location = 5) pervertexEXT in uvec3 u3[3];
#endif
#if defined(SCALAR) || defined(MIXED)
layout(location = 6) pervertexEXT in float s1[3];
#elif defined(ARRAY1)
layout(location = 6) pervertexEXT in float s1[1];
#elif defined(ARRAY2)
layout(location = 6) pervertexEXT in float s1[2];
#endif
#ifdef HALF
layout(location = 7, component = 2) pervertexEXT in f16vec2 h2[3];
#endif
#ifdef INT16
layout(location = 8) pervertexEXT in i16vec3 s3[3];
#endif
#ifdef UINT16
layout(location = 30) pervertexEXT in uint16_t w1[3];
#endif
layout(location = 0) out uvec4 result;

uint h;
void add(uint bits) { h = ((h << 5) | (h >> 27)) ^ bits; }
void add(float value) { add(floatBitsToUint(value)); }

uint fold(int k)
{
	h = 0u;
#if defined(UINT) || defined(SWAPPED) || defined(MIXED)
	add(u1[k]);
#endif
#ifdef IVEC2
	add(uint(i2[k].x));
	add(uint(i2[k].y));
#endif
#if defined(VEC3) || defined(MIXED)
	add(f3[k].x);
	add(f3[k].y);
	add(f3[k].z);
#endif
#if defined(COMPONENTS) || defined(MIXED)
	add(c0[k]);
	add(c12[k].x);
	add(c12[k].y);
	add(c3[k]);
#endif
#ifdef FEWER
	add(wide[k].x);
	add(wide[k].y);
#endif
#ifdef UVEC3
	add(u3[k].x);
	add(u3[k].y);
	add(u3[k].z);
#endif
#if defined(SCALAR) || defined(MIXED) || defined(ARRAY1) || defined(ARRAY2)
	add(s1[k]);
#endif
#ifdef HALF
	add(float(h2[k].x));
	add(float(h2[k].y));
#endif
#ifdef INT16
	add(uint(int(s3[k].x)));
	add(uint(int(s3[k].y)));
	add(uint(int(s3[k].z)));
#endif
#ifdef UINT16
	add(uint(w1[k]));
#endif
	return h;
}

void main()
{
	const uint tag = 0x600DF00Du;
#if defined(ARRAY1)
	result = uvec4(fold(0), 0u, 0u, tag);
#elif defined(ARRAY2)
	result = uvec4(fold(0), fold(1), 0u, tag);
#elif defined(SWAPPED)
	result = uvec4(fold(1), fold(0), fold(2), tag);
#else
	result = uvec4(fold(0), fold(1), fold(2), tag);
#endif
}
