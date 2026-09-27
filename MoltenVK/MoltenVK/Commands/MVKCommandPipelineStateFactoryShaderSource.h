/*
 * MVKCommandPipelineStateFactoryShaderSource.h
 *
 * Copyright (c) 2015-2026 The Brenwill Workshop Ltd. (http://www.brenwill.com)
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "MVKDevice.h"

#import <Foundation/Foundation.h>


/** This file contains static MSL source code for the MoltenVK command shaders. */

static NSString* _MVKStaticCmdShaderSource = @R"(
#include <metal_stdlib>
using namespace metal;

typedef struct {
	float2 a_position [[attribute(0)]];
	float3 a_texCoord [[attribute(1)]];
} AttributesPosTex;

typedef struct {
	float4 v_position [[position]];
	float3 v_texCoord;
} VaryingsPosTex;

typedef struct {
	float4 v_position [[position]];
	float3 v_texCoord;
	uint v_layer [[render_target_array_index]];
} VaryingsPosTexLayer;

typedef size_t VkDeviceSize;

typedef enum : uint32_t {
	VK_FORMAT_BC1_RGB_UNORM_BLOCK = 131,
	VK_FORMAT_BC1_RGB_SRGB_BLOCK = 132,
	VK_FORMAT_BC1_RGBA_UNORM_BLOCK = 133,
	VK_FORMAT_BC1_RGBA_SRGB_BLOCK = 134,
	VK_FORMAT_BC2_UNORM_BLOCK = 135,
	VK_FORMAT_BC2_SRGB_BLOCK = 136,
	VK_FORMAT_BC3_UNORM_BLOCK = 137,
	VK_FORMAT_BC3_SRGB_BLOCK = 138,
} VkFormat;

typedef struct {
	uint32_t width;
	uint32_t height;
} VkExtent2D;

typedef struct {
	uint32_t width;
	uint32_t height;
	uint32_t depth;
} __attribute__((packed)) VkExtent3D;

typedef struct {
	int32_t x;
	int32_t y;
	int32_t z;
} __attribute__((packed)) VkOffset3D;
)"
#define MVK_DECOMPRESS_CODE(...) #__VA_ARGS__
#include "MVKDXTnCodec.def"
#undef MVK_DECOMPRESS_CODE
R"(
vertex VaryingsPosTex vtxCmdBlitImage(AttributesPosTex attributes [[stage_in]]) {
	VaryingsPosTex varyings;
	varyings.v_position = float4(attributes.a_position, 0.0, 1.0);
	varyings.v_texCoord = attributes.a_texCoord;
	return varyings;
}

vertex VaryingsPosTexLayer vtxCmdBlitImageLayered(AttributesPosTex attributes [[stage_in]],
                                                  uint instanceID [[instance_id]],
                                                  constant float &zIncr [[buffer(0)]]) {
	VaryingsPosTexLayer varyings;
	varyings.v_position = float4(attributes.a_position, 0.0, 1.0);
	varyings.v_texCoord = float3(attributes.a_texCoord.xy, attributes.a_texCoord.z + (instanceID + 0.5) * zIncr);
	varyings.v_layer = instanceID;
	return varyings;
}

typedef struct {
	uint32_t srcOffset;
	uint32_t dstOffset;
	uint32_t size;
} CopyInfo;

kernel void cmdCopyBufferBytes(device uint8_t* src [[ buffer(0) ]],
                               device uint8_t* dst [[ buffer(1) ]],
                               constant CopyInfo& info [[ buffer(2) ]]) {
	for (size_t i = 0; i < info.size; i++) {
		dst[i + info.dstOffset] = src[i + info.srcOffset];
	}
}

kernel void cmdFillBuffer(device uint32_t* dst [[ buffer(0) ]],
                          constant uint32_t& fillValue [[ buffer(1) ]],
                          uint pos [[thread_position_in_grid]]) {
	dst[pos] = fillValue;
}

kernel void cmdClearColorImage2DFloat(texture2d<float, access::write> dst [[ texture(0) ]],
                                      constant float4& clearValue [[ buffer(0) ]],
                                      uint2 pos [[thread_position_in_grid]]) {
	dst.write(clearValue, pos);
}

kernel void cmdClearColorImage2DFloatArray(texture2d_array<float, access::write> dst [[ texture(0) ]],
                                           constant float4& clearValue [[ buffer(0) ]],
                                           uint2 pos [[thread_position_in_grid]]) {
	for (uint i = 0u; i < dst.get_array_size(); ++i) {
		dst.write(clearValue, pos, i);
	}
}

kernel void cmdClearColorImage2DUInt(texture2d<uint, access::write> dst [[ texture(0) ]],
                                     constant uint4& clearValue [[ buffer(0) ]],
                                     uint2 pos [[thread_position_in_grid]]) {
	dst.write(clearValue, pos);
}

kernel void cmdClearColorImage2DUIntArray(texture2d_array<uint, access::write> dst [[ texture(0) ]],
                                          constant uint4& clearValue [[ buffer(0) ]],
                                          uint2 pos [[thread_position_in_grid]]) {
	for (uint i = 0u; i < dst.get_array_size(); ++i) {
		dst.write(clearValue, pos, i);
	}
}

kernel void cmdClearColorImage2DInt(texture2d<int, access::write> dst [[ texture(0) ]],
                                    constant int4& clearValue [[ buffer(0) ]],
                                    uint2 pos [[thread_position_in_grid]]) {
	dst.write(clearValue, pos);
}

kernel void cmdClearColorImage2DIntArray(texture2d_array<int, access::write> dst [[ texture(0) ]],
                                         constant int4& clearValue [[ buffer(0) ]],
                                         uint2 pos [[thread_position_in_grid]]) {
	for (uint i = 0u; i < dst.get_array_size(); ++i) {
		dst.write(clearValue, pos, i);
	}
}

kernel void cmdResolveColorImage2DFloat(texture2d<float, access::write> dst [[ texture(0) ]],
                                        texture2d_ms<float, access::read> src [[ texture(1) ]],
                                        uint2 pos [[thread_position_in_grid]]) {
	dst.write(src.read(pos, 0), pos);
}

#if __HAVE_TEXTURE_2D_MS_ARRAY__
kernel void cmdResolveColorImage2DFloatArray(texture2d_array<float, access::write> dst [[ texture(0) ]],
                                             texture2d_ms_array<float, access::read> src [[ texture(1) ]],
                                             uint2 pos [[thread_position_in_grid]]) {
	for (uint i = 0u; i < src.get_array_size(); ++i) {
		dst.write(src.read(pos, i, 0), pos, i);
	}
}
#endif

kernel void cmdResolveColorImage2DUInt(texture2d<uint, access::write> dst [[ texture(0) ]],
                                       texture2d_ms<uint, access::read> src [[ texture(1) ]],
                                       uint2 pos [[thread_position_in_grid]]) {
	dst.write(src.read(pos, 0), pos);
}

#if __HAVE_TEXTURE_2D_MS_ARRAY__
kernel void cmdResolveColorImage2DUIntArray(texture2d_array<uint, access::write> dst [[ texture(0) ]],
                                            texture2d_ms_array<uint, access::read> src [[ texture(1) ]],
                                            uint2 pos [[thread_position_in_grid]]) {
	for (uint i = 0u; i < src.get_array_size(); ++i) {
		dst.write(src.read(pos, i, 0), pos, i);
	}
}
#endif

kernel void cmdResolveColorImage2DInt(texture2d<int, access::write> dst [[ texture(0) ]],
                                      texture2d_ms<int, access::read> src [[ texture(1) ]],
                                      uint2 pos [[thread_position_in_grid]]) {
	dst.write(src.read(pos, 0), pos);
}

#if __HAVE_TEXTURE_2D_MS_ARRAY__
kernel void cmdResolveColorImage2DIntArray(texture2d_array<int, access::write> dst [[ texture(0) ]],
                                           texture2d_ms_array<int, access::read> src [[ texture(1) ]],
                                           uint2 pos [[thread_position_in_grid]]) {
	for (uint i = 0u; i < src.get_array_size(); ++i) {
		dst.write(src.read(pos, i, 0), pos, i);
	}
}
#endif

// This structure is missing from the MSL headers. :/
struct MTLStageInRegionIndirectArguments {
	uint32_t stageInOrigin[3];
	uint32_t stageInSize[3];
};

typedef enum : uint8_t {
	MTLIndexTypeUInt16 = 0,
	MTLIndexTypeUInt32 = 1,
} MTLIndexType;

typedef struct MVKVtxAdj {
	MTLIndexType idxType;
	bool isMultiView;
	bool isTriFan;
	bool isPrimRestart;
	bool isUint8Index;
	bool isProvokingVertexLast;
} MVKVtxAdj;

// Populates triangle vertex indexes for a triangle fan.
template<typename T>
static inline void populateTriIndxsFromTriFan(device T* triIdxs,
                                              constant T* triFanIdxs,
                                              uint32_t triFanIdxCnt,
                                              constant MVKVtxAdj& vtxAdj) {
	T primRestartSentinel = vtxAdj.isUint8Index ? (T)0xFF : (T)0xFFFFFFFF;
	uint32_t triIdxIdx = 0;
	uint32_t triFanBaseIdx = 0;
	uint32_t triFanIdxIdx = triFanBaseIdx + 2;
	while (triFanIdxIdx < triFanIdxCnt) {
		uint32_t triFanBaseIdxCurr = triFanBaseIdx;

		// Detect primitive restart on any index, to catch possible consecutive restarts
		T triIdx0 = triFanIdxs[triFanBaseIdx];
		if (vtxAdj.isPrimRestart && triIdx0 == primRestartSentinel)
			triFanBaseIdx++;

		T triIdx1 = triFanIdxs[triFanIdxIdx - 1];
		if (vtxAdj.isPrimRestart && triIdx1 == primRestartSentinel)
			triFanBaseIdx = triFanIdxIdx;

		T triIdx2 = triFanIdxs[triFanIdxIdx];
		if (vtxAdj.isPrimRestart && triIdx2 == primRestartSentinel)
			triFanBaseIdx = triFanIdxIdx + 1;

		if (triFanBaseIdx != triFanBaseIdxCurr) {    // Restart the triangle fan
			triFanIdxIdx = triFanBaseIdx + 2;
		} else {
			// Provoking vertex is 1 in triangle fan but 0 in triangle list
			triIdxs[triIdxIdx++] = vtxAdj.isProvokingVertexLast ? triIdx0 : triIdx1;
			triIdxs[triIdxIdx++] = vtxAdj.isProvokingVertexLast ? triIdx1 : triIdx2;
			triIdxs[triIdxIdx++] = vtxAdj.isProvokingVertexLast ? triIdx2 : triIdx0;
			triFanIdxIdx++;
		}
	}
}

kernel void cmdDrawIndirectPopulateIndexes(const device char* srcBuff [[buffer(0)]],
                                           device MTLDrawIndexedPrimitivesIndirectArguments* destBuff [[buffer(1)]],
                                           constant uint32_t& srcStride [[buffer(2)]],
                                           constant uint32_t& drawCount [[buffer(3)]],
                                           device uint32_t* idxBuff [[buffer(4)]],
                                           uint idx [[thread_position_in_grid]]) {
	if (idx >= drawCount) { return; }
	const device auto& src = *reinterpret_cast<const device MTLDrawPrimitivesIndirectArguments*>(srcBuff + idx * srcStride);
	device auto& dst = destBuff[idx];
	dst.indexCount = src.vertexCount;
	dst.indexStart = src.vertexStart;
	dst.baseVertex = 0;
	dst.instanceCount = src.instanceCount;
	dst.baseInstance = src.baseInstance;

	for (uint32_t idxIdx = 0; idxIdx < dst.indexCount; idxIdx++) {
		uint32_t idxBuffIdx = dst.indexStart + idxIdx;
		idxBuff[idxBuffIdx] = idxBuffIdx;
	}
}

kernel void cmdDrawIndirectConvertBuffers(const device char* srcBuff [[buffer(0)]],
                                          device MTLDrawPrimitivesIndirectArguments* destBuff [[buffer(1)]],
                                          constant uint32_t& srcStride [[buffer(2)]],
                                          constant uint32_t& drawCount [[buffer(3)]],
                                          constant uint32_t& viewCount [[buffer(4)]],
                                          uint idx [[thread_position_in_grid]]) {
	if (idx >= drawCount) { return; }
	const device auto& src = *reinterpret_cast<const device MTLDrawPrimitivesIndirectArguments*>(srcBuff + idx * srcStride);
	destBuff[idx] = src;
	destBuff[idx].instanceCount *= viewCount;
}

kernel void cmdDrawIndirectCountConvertBuffers(const device char* srcBuff [[buffer(0)]],
                                               device MTLDrawPrimitivesIndirectArguments* destBuff [[buffer(1)]],
                                               constant uint32_t& srcStride [[buffer(2)]],
                                               constant uint32_t& drawCount [[buffer(3)]],
                                               const device uint32_t* countBuff [[buffer(4)]],
                                               uint idx [[thread_position_in_grid]]) {
	if (idx >= drawCount) { return; }
	const device auto& src = *reinterpret_cast<const device MTLDrawPrimitivesIndirectArguments*>(srcBuff + idx * srcStride);
	destBuff[idx] = src;
	if (idx >= countBuff[0]) {
		destBuff[idx].instanceCount = 0;
	}
}

kernel void cmdDrawIndexedIndirectConvertBuffers(const device char* srcBuff [[buffer(0)]],
                                                 device MTLDrawIndexedPrimitivesIndirectArguments* destBuff [[buffer(1)]],
                                                 constant uint32_t& srcStride [[buffer(2)]],
                                                 constant uint32_t& drawCount [[buffer(3)]],
                                                 constant uint32_t& viewCount [[buffer(4)]],
                                                 constant MVKVtxAdj& vtxAdj [[buffer(5)]],
                                                 device void* triIdxs [[buffer(6)]],
                                                 constant void* triFanIdxs [[buffer(7)]],
                                                 uint idx [[thread_position_in_grid]]) {
	if (idx >= drawCount) { return; }
	const device auto& src = *reinterpret_cast<const device MTLDrawIndexedPrimitivesIndirectArguments*>(srcBuff + idx * srcStride);
	destBuff[idx] = src;

	device auto& dst = destBuff[idx];
	if (vtxAdj.isMultiView) {
		dst.instanceCount *= viewCount;
	}
	if (vtxAdj.isTriFan) {
		dst.indexCount = (src.indexCount - 2) * 3;
		switch (vtxAdj.idxType) {
			case MTLIndexTypeUInt16:
				populateTriIndxsFromTriFan(&((device uint16_t*)triIdxs)[dst.indexStart],
				                           &((constant uint16_t*)triFanIdxs)[src.indexStart],
				                           src.indexCount,
				                           vtxAdj);
				break;
			case MTLIndexTypeUInt32:
				populateTriIndxsFromTriFan(&((device uint32_t*)triIdxs)[dst.indexStart],
				                           &((constant uint32_t*)triFanIdxs)[src.indexStart],
				                           src.indexCount,
				                           vtxAdj);
				break;
		}
	}
}

kernel void cmdDrawIndexedIndirectCountConvertBuffers(const device char* srcBuff [[buffer(0)]],
                                                      device MTLDrawIndexedPrimitivesIndirectArguments* destBuff [[buffer(1)]],
                                                      constant uint32_t& srcStride [[buffer(2)]],
                                                      constant uint32_t& drawCount [[buffer(3)]],
                                                      const device uint32_t* countBuff [[buffer(4)]],
                                                      uint idx [[thread_position_in_grid]]) {
	if (idx >= drawCount) { return; }
	const device auto& src = *reinterpret_cast<const device MTLDrawIndexedPrimitivesIndirectArguments*>(srcBuff + idx * srcStride);
	destBuff[idx] = src;
	if (idx >= countBuff[0]) {
		destBuff[idx].instanceCount = 0;
	}
}

kernel void cmdDrawIndirectCopyZeroDivisorVertexBuffers(const device char* indirectBuff [[buffer(0)]],
                                                         const device char* srcBuff [[buffer(1)]],
                                                         device char* destBuff [[buffer(2)]],
                                                         constant uint32_t& indirectStride [[buffer(3)]],
                                                         constant uint32_t& drawCount [[buffer(4)]],
                                                         constant uint32_t& vertexStride [[buffer(5)]],
                                                         constant uint32_t& baseInstanceOffset [[buffer(6)]],
                                                         uint idx [[thread_position_in_grid]]) {
	uint32_t drawIdx = idx / vertexStride;
	if (drawIdx >= drawCount) { return; }
	uint32_t byteIdx = idx % vertexStride;
	size_t drawOffset = (size_t)drawIdx * indirectStride;
	const device auto& instanceCount = *reinterpret_cast<const device uint32_t*>(indirectBuff + drawOffset + sizeof(uint32_t));
	if (instanceCount == 0) { return; }
	const device auto& baseInstance = *reinterpret_cast<const device uint32_t*>(indirectBuff + drawOffset + baseInstanceOffset);
	destBuff[idx] = srcBuff[(size_t)baseInstance * vertexStride + byteIdx];
}

kernel void cmdDrawIndirectTessConvertBuffers(const device char* srcBuff [[buffer(0)]],
                                              device char* destBuff [[buffer(1)]],
                                              device char* paramsBuff [[buffer(2)]],
                                              constant uint32_t& srcStride [[buffer(3)]],
                                              constant uint32_t& inControlPointCount [[buffer(4)]],
                                              constant uint32_t& outControlPointCount [[buffer(5)]],
                                              constant uint32_t& drawCount [[buffer(6)]],
                                              constant uint32_t& vtxThreadExecWidth [[buffer(7)]],
                                              constant uint32_t& tcWorkgroupSize [[buffer(8)]],
                                              uint idx [[thread_position_in_grid]]) {
	if (idx >= drawCount) { return; }
	const device auto& src = *reinterpret_cast<const device MTLDrawPrimitivesIndirectArguments*>(srcBuff + idx * srcStride);
	device char* dest;
	device auto* params = reinterpret_cast<device uint32_t*>(paramsBuff + idx * 256);
	dest = destBuff + idx * (sizeof(MTLStageInRegionIndirectArguments) + sizeof(MTLDispatchThreadgroupsIndirectArguments) * 2 + sizeof(MTLDrawPatchIndirectArguments));
	device auto& destSI = *(device MTLStageInRegionIndirectArguments*)dest;
	dest += sizeof(MTLStageInRegionIndirectArguments);
	device auto& destVtx = *(device MTLDispatchThreadgroupsIndirectArguments*)dest;
	device auto& destTC = *(device MTLDispatchThreadgroupsIndirectArguments*)(dest + sizeof(MTLDispatchThreadgroupsIndirectArguments));
	device auto& destTE = *(device MTLDrawPatchIndirectArguments*)(dest + sizeof(MTLDispatchThreadgroupsIndirectArguments) * 2);
	uint32_t patchCount = (src.vertexCount * src.instanceCount + inControlPointCount - 1) / inControlPointCount;
	params[0] = inControlPointCount;
	params[1] = patchCount;
	destVtx.threadgroupsPerGrid[0] = (src.vertexCount + vtxThreadExecWidth - 1) / vtxThreadExecWidth;
	destVtx.threadgroupsPerGrid[1] = src.instanceCount;
	destVtx.threadgroupsPerGrid[2] = 1;
	destTC.threadgroupsPerGrid[0] = (patchCount * outControlPointCount + tcWorkgroupSize - 1) / tcWorkgroupSize;
	destTC.threadgroupsPerGrid[1] = destTC.threadgroupsPerGrid[2] = 1;
	destTE.patchCount = patchCount;
	destTE.instanceCount = 1;
	destTE.patchStart = destTE.baseInstance = 0;
	destSI.stageInOrigin[0] = src.vertexStart;
	destSI.stageInOrigin[1] = src.baseInstance;
	destSI.stageInOrigin[2] = 0;
	destSI.stageInSize[0] = src.vertexCount;
	destSI.stageInSize[1] = src.instanceCount;
	destSI.stageInSize[2] = 1;
}

kernel void cmdDrawIndexedIndirectTessConvertBuffers(const device char* srcBuff [[buffer(0)]],
                                                     device char* destBuff [[buffer(1)]],
                                                     device char* paramsBuff [[buffer(2)]],
                                                     constant uint32_t& srcStride [[buffer(3)]],
                                                     constant uint32_t& inControlPointCount [[buffer(4)]],
                                                     constant uint32_t& outControlPointCount [[buffer(5)]],
                                                     constant uint32_t& drawCount [[buffer(6)]],
                                                     constant uint32_t& vtxThreadExecWidth [[buffer(7)]],
                                                     constant uint32_t& tcWorkgroupSize [[buffer(8)]],
                                                     uint idx [[thread_position_in_grid]]) {
	if (idx >= drawCount) { return; }
	const device auto& src = *reinterpret_cast<const device MTLDrawIndexedPrimitivesIndirectArguments*>(srcBuff + idx * srcStride);
	device char* dest;
	device auto* params = reinterpret_cast<device uint32_t*>(paramsBuff + idx * 256);
	dest = destBuff + idx * (sizeof(MTLStageInRegionIndirectArguments) + sizeof(MTLDispatchThreadgroupsIndirectArguments) * 2 + sizeof(MTLDrawPatchIndirectArguments));
	device auto& destSI = *(device MTLStageInRegionIndirectArguments*)dest;
	dest += sizeof(MTLStageInRegionIndirectArguments);
	device auto& destVtx = *(device MTLDispatchThreadgroupsIndirectArguments*)dest;
	device auto& destTC = *(device MTLDispatchThreadgroupsIndirectArguments*)(dest + sizeof(MTLDispatchThreadgroupsIndirectArguments));
	device auto& destTE = *(device MTLDrawPatchIndirectArguments*)(dest + sizeof(MTLDispatchThreadgroupsIndirectArguments) * 2);
	uint32_t patchCount = (src.indexCount * src.instanceCount + inControlPointCount - 1) / inControlPointCount;
	params[0] = inControlPointCount;
	params[1] = patchCount;
	destVtx.threadgroupsPerGrid[0] = (src.indexCount + vtxThreadExecWidth - 1) / vtxThreadExecWidth;
	destVtx.threadgroupsPerGrid[1] = src.instanceCount;
	destVtx.threadgroupsPerGrid[2] = 1;
	destTC.threadgroupsPerGrid[0] = (patchCount * outControlPointCount + tcWorkgroupSize - 1) / tcWorkgroupSize;
	destTC.threadgroupsPerGrid[1] = destTC.threadgroupsPerGrid[2] = 1;
	destTE.patchCount = patchCount;
	destTE.instanceCount = 1;
	destTE.patchStart = destTE.baseInstance = 0;
	destSI.stageInOrigin[0] = src.baseVertex;
	destSI.stageInOrigin[1] = src.baseInstance;
	destSI.stageInOrigin[2] = 0;
	destSI.stageInSize[0] = src.indexCount;
	destSI.stageInSize[1] = src.instanceCount;
	destSI.stageInSize[2] = 1;
}

kernel void cmdDrawIndexedCopyIndex16Buffer(const device uint16_t* srcBuff [[buffer(0)]],
                                            device uint16_t* destBuff [[buffer(1)]],
                                            const device MTLDrawIndexedPrimitivesIndirectArguments& params [[buffer(2)]],
                                            uint i [[thread_position_in_grid]]) {
	destBuff[i] = srcBuff[params.indexStart + i];
}

kernel void cmdDrawIndexedCopyIndex32Buffer(const device uint32_t* srcBuff [[buffer(0)]],
                                            device uint32_t* destBuff [[buffer(1)]],
                                            const device MTLDrawIndexedPrimitivesIndirectArguments& params [[buffer(2)]],
                                            uint i [[thread_position_in_grid]]) {
	destBuff[i] = srcBuff[params.indexStart + i];
}

typedef struct alignas(8) {
	uint32_t count;
	uint32_t countHigh;
} VisibilityBuffer;

typedef struct alignas(8) {
	atomic_uint count;
	atomic_uint countHigh;
} AtomicVisibilityBuffer;

typedef struct alignas(8) {
	uint32_t dst;
	uint32_t src;
} QueryResultOffsets;

typedef enum {
	Initial,
	DeviceAvailable,
	Available
} QueryStatus;

typedef enum {
	VK_QUERY_RESULT_64_BIT                = 0x00000001,
	VK_QUERY_RESULT_WAIT_BIT              = 0x00000002,
	VK_QUERY_RESULT_WITH_AVAILABILITY_BIT = 0x00000004,
	VK_QUERY_RESULT_PARTIAL_BIT           = 0x00000008,
} VkQueryResultFlagBits;

kernel void cmdCopyQueryPoolResultsToBuffer(const device VisibilityBuffer* src [[buffer(0)]],
                                            device uint8_t* dest [[buffer(1)]],
                                            constant uint& stride [[buffer(2)]],
                                            constant uint& numQueries [[buffer(3)]],
                                            constant uint& flags [[buffer(4)]],
                                            constant QueryStatus* availability [[buffer(5)]],
                                            uint query [[thread_position_in_grid]]) {
	if (query >= numQueries) { return; }
	device uint32_t* destCount = (device uint32_t*)(dest + stride * query);
	if (availability[query] != Initial || flags & VK_QUERY_RESULT_PARTIAL_BIT) {
		destCount[0] = src[query].count;
		if (flags & VK_QUERY_RESULT_64_BIT) { destCount[1] = src[query].countHigh; }
	}
	if (flags & VK_QUERY_RESULT_WITH_AVAILABILITY_BIT) {
		if (flags & VK_QUERY_RESULT_64_BIT) {
			destCount[2] = availability[query] != Initial ? 1 : 0;
			destCount[3] = 0;
		} else {
			destCount[1] = availability[query] != Initial ? 1 : 0;
		}
	}
}

kernel void accumulateOcclusionQueryResults(uint pos [[thread_position_in_grid]],
                                            const device QueryResultOffsets* offsets  [[buffer(0)]],
                                            device AtomicVisibilityBuffer* dst_buffer [[buffer(1)]],
                                            const device VisibilityBuffer* src_buffer [[buffer(2)]])
{
	VisibilityBuffer src = src_buffer[offsets[pos].src];
	device AtomicVisibilityBuffer& dst = dst_buffer[offsets[pos].dst];
	uint32_t prev_lo = atomic_fetch_add_explicit(&dst.count, src.count, memory_order_relaxed);
	uint32_t next_lo = prev_lo + src.count;
	atomic_fetch_add_explicit(&dst.countHigh, src.countHigh, memory_order_relaxed);
	if (next_lo < prev_lo)
		atomic_fetch_add_explicit(&dst.countHigh, 1, memory_order_relaxed);
}

kernel void convertUint8Indices(device uint8_t* src [[ buffer(0) ]],
                                device uint16_t* dst [[ buffer(1) ]],
                                uint pos [[thread_position_in_grid]]) {
	uint8_t idx = src[pos];
	dst[pos] = idx == 0xFF ? 0xFFFF : idx;
}

kernel void convertUint8IndicesRaw(device uint8_t* src [[ buffer(0) ]],
                                   device uint16_t* dst [[ buffer(1) ]],
                                   uint pos [[thread_position_in_grid]]) {
	uint8_t idx = src[pos];
	dst[pos] = idx;
}
uint perVertexRestartPrimitiveCount(uint count, uint topology) {
    return topology == 0 ? count : topology == 1 ? count / 2 : topology == 2 ? (count > 1 ? count - 1 : 0) : topology == 3 ? count / 3 : (count > 2 ? count - 2 : 0);
}
// Parallel prefix over contiguous segments: (valid indices, leading run, trailing run, primitives).
// Merging adjacent intervals only changes primitives where their boundary runs join.
// p: indexCount, instances, indexBytes, topology, provokingLast, firstInstance, corners, phase, scanStep, scanSource.
// Phases: initialize, ping-pong prefix, compact/base triplets, expand instances. Barrier between every dispatch.
// args: capture dispatch at byte 0, replay draw at byte 16, replay constants at byte 256.
kernel void perVertexRestart(const device uint8_t* source [[buffer(0)]], device uint* compact [[buffer(1)]], device uint* pairs [[buffer(2)]], device uint* triplets [[buffer(3)]], device uint* corners [[buffer(4)]], device uint* args [[buffer(5)]], constant uint* p [[buffer(6)]], uint i [[thread_position_in_grid]]) {
    uint topology = p[3], rasterVertices = topology == 0 ? 1 : topology <= 2 ? 2 : 3;
    if (!p[0]) {
        if (i) { return; }
        args[0] = 0; args[1] = 0; args[2] = 1; args[3] = 0;
        args[4] = 0; args[5] = 0; args[6] = 0; args[7] = p[5];
        args[64] = 0; args[65] = 0; args[66] = p[5]; args[67] = 0;
        return;
    }
    if (p[7] == 3) {
        uint primitives = args[4] / rasterVertices;
        if (i >= primitives * p[1]) { return; }
        uint instance = i / primitives, primitive = i % primitives;
        for (uint corner = 0; corner < 3; ++corner) {
            // Capture's grid_size is the original stage-in region, not the compact dispatch size.
            uint record = instance * p[0] + triplets[3 * primitive + corner];
            // Keep the base triplets read-only while other instances read them.
            if (instance) { triplets[3 * i + corner] = record; }
            if (corner >= rasterVertices) { continue; }
            uint occurrence = i * rasterVertices + corner;
            pairs[2 * occurrence] = record;
            pairs[2 * occurrence + 1] = i;
            if (p[6]) { corners[occurrence] = corner; }
        }
        return;
    }
    if (i >= p[0]) { return; }
    uint64_t offset = uint64_t(p[0]) + uint64_t(p[9]) * p[0] * 4 + uint64_t(i) * 4;
    if (p[7] == 0) {
        uint index = 0;
        for (uint b = 0; b < p[2]; ++b) { index |= uint(source[uint64_t(i) * p[2] + b]) << (8 * b); }
        uint sentinel = p[2] == 1 ? 255u : p[2] == 2 ? 65535u : 0xffffffffu;
        uint valid = uint(index != sentinel);
        compact[offset] = valid; compact[offset + 1] = valid; compact[offset + 2] = valid;
        compact[offset + 3] = perVertexRestartPrimitiveCount(valid, topology);
        return;
    }
    uint captured = compact[offset], head = compact[offset + 1], tail = compact[offset + 2], primitives = compact[offset + 3];
    if (p[7] == 1) {
        uint step = p[8];
        if (i >= step) {
            uint64_t left = offset - uint64_t(step) * 4;
            uint leftCaptured = compact[left], leftHead = compact[left + 1], leftTail = compact[left + 2];
            primitives += compact[left + 3] - perVertexRestartPrimitiveCount(leftTail, topology);
            primitives -= perVertexRestartPrimitiveCount(head, topology);
            primitives += perVertexRestartPrimitiveCount(leftTail + head, topology);
            tail = captured == step ? leftTail + tail : tail;
            head = leftCaptured == min(step, i - step + 1) ? leftHead + head : leftHead;
            captured += leftCaptured;
        }
        uint64_t destination = uint64_t(p[0]) + uint64_t(p[9] ^ 1) * p[0] * 4 + uint64_t(i) * 4;
        compact[destination] = captured; compact[destination + 1] = head; compact[destination + 2] = tail; compact[destination + 3] = primitives;
        return;
    }
    if (i == p[0] - 1) {
        args[0] = captured; args[1] = captured ? p[1] : 0; args[2] = 1; args[3] = 0;
        args[4] = primitives * rasterVertices; args[5] = primitives ? p[1] : 0; args[6] = 0; args[7] = p[5];
        args[64] = 0; args[65] = 0; args[66] = p[5]; args[67] = primitives * rasterVertices;
    }
    if (!tail) { return; } // Restart marker: never invoke the application's vertex shader for it.
    uint index = 0;
    for (uint b = 0; b < p[2]; ++b) { index |= uint(source[uint64_t(i) * p[2] + b]) << (8 * b); }
    compact[captured - 1] = index;
    if (perVertexRestartPrimitiveCount(tail, topology) == perVertexRestartPrimitiveCount(tail - 1, topology)) { return; }
    uint a = captured - 1, b = a, c = a;
    if (rasterVertices == 2) { a = captured - 2; }
    if (rasterVertices == 3) { a = captured - 3; b = captured - 2; }
    if (topology == 4 && ((tail - 3) & 1)) {
        if (p[4]) { uint tmp = a; a = b; b = tmp; }
        else { uint tmp = b; b = c; c = tmp; }
    }
    if (topology == 5) {
        a = p[4] ? captured - tail : captured - 2;
        b = p[4] ? captured - 2 : captured - 1;
        c = p[4] ? captured - 1 : captured - tail;
    }
    triplets[3 * (primitives - 1)] = a;
    triplets[3 * (primitives - 1) + 1] = b;
    triplets[3 * (primitives - 1) + 2] = c;
}
// Portable PerVertexKHR TES topology for triangles with equal spacing, generated from the float32 levels
// (outer[4], inner[2] per patch) the TCS actually wrote. Vulkan discards a patch whose first three outer
// levels include one <= 0 or NaN, then clamps levels to [1, maxLevel] and rounds them up. Uniform levels 1,
// 2 and 3 use the Metal topologies proven by the Vulkan oracles; any other level refuses the whole draw.
// Levels are decoded from their bits, so NaN and sign tests survive fast math.
// p: patches, maxLevel bits, reverse corners (counter-clockwise winding), corners output, phase.
// Plan words: 0 status, 4 replay draw, 64 replay constants (byte 256), 128 counts, then offsets.
uint perVertexTessLevel(uint bits, float maxLevel) {
    if ((bits & 0x7fffffffu) > 0x7f800000u) { return 0; }  // NaN
    if ((bits & 0x80000000u) || !(bits & 0x7fffffffu)) { return 1; }  // <= 0 clamps to 1
    if (bits >= 0x7f800000u) { return uint(maxLevel); }
    return uint(ceil(min(max(as_type<float>(bits), 1.0f), maxLevel)));
}
kernel void perVertexTessTopology(const device uint* levels [[buffer(0)]], device uint* plan [[buffer(1)]], device uint* invocations [[buffer(2)]], device uint* pairs [[buffer(3)]], device uint* triplets [[buffer(4)]], device uint* corners [[buffer(5)]], constant uint* p [[buffer(6)]], uint i [[thread_position_in_grid]]) {
    uint patches = p[0];
    device uint* counts = plan + 128;
    device uint* offsets = plan + 128 + patches;
    if (p[4] == 0) {
        if (i >= patches) { return; }
        const device uint* f = levels + 6 * ulong(i);
        bool discarded = false;
        for (uint k = 0; k < 3; ++k) { discarded |= (f[k] & 0x80000000u) || !(f[k] & 0x7fffffffu) || (f[k] & 0x7fffffffu) > 0x7f800000u; }
        uint triangles = 0;
        if (!discarded) {
            float maxLevel = as_type<float>(p[1]);
            uint n = perVertexTessLevel(f[0], maxLevel);
            bool uniform = n && perVertexTessLevel(f[1], maxLevel) == n && perVertexTessLevel(f[2], maxLevel) == n && perVertexTessLevel(f[4], maxLevel) == n;
            triangles = !uniform ? 0 : n == 1 ? 1 : n == 2 ? 6 : n == 3 ? 13 : 0;
            if (!triangles) { atomic_fetch_or_explicit(reinterpret_cast<device atomic_uint*>(plan), 1u, memory_order_relaxed); }
        }
        counts[i] = triangles;
        return;
    }
    if (p[4] == 1) {
        if (i) { return; }
        // ponytail: serial prefix over patches; a parallel scan is needed for very large patch counts.
        uint total = 0;
        for (uint patch = 0; patch < patches; ++patch) { offsets[patch] = total; total += counts[patch]; }
        uint records = plan[0] ? 0 : 3 * total;
        invocations[0] = records; invocations[1] = 0; invocations[2] = 0; invocations[3] = 0;
        plan[4] = records; plan[5] = records ? 1 : 0; plan[6] = 0; plan[7] = 0;
        plan[64] = 0; plan[65] = 0; plan[66] = 0; plan[67] = records;
        return;
    }
    if (i >= patches || plan[0] || !counts[i]) { return; }
    // Clockwise (u,v) corner orders of the proven Metal topologies; counter-clockwise swaps corners 1 and 2.
    const float t = 2.0f / 9.0f;
    const float3 points[12] = {
        float3(1, 0, 0), float3(2.0f / 3.0f, 1.0f / 3.0f, 0), float3(1.0f / 3.0f, 2.0f / 3.0f, 0), float3(0, 1, 0),
        float3(0, 2.0f / 3.0f, 1.0f / 3.0f), float3(0, 1.0f / 3.0f, 2.0f / 3.0f), float3(0, 0, 1),
        float3(1.0f / 3.0f, 0, 2.0f / 3.0f), float3(2.0f / 3.0f, 0, 1.0f / 3.0f),
        float3(1.0f - 2.0f * t, t, t), float3(t, 1.0f - 2.0f * t, t), float3(t, t, 1.0f - 2.0f * t)};
    const uint3 level3[13] = {uint3(9, 8, 0), uint3(9, 0, 1), uint3(10, 2, 3), uint3(10, 3, 4), uint3(11, 5, 6), uint3(11, 6, 7), uint3(9, 10, 11),
        uint3(9, 1, 10), uint3(10, 1, 2), uint3(10, 4, 11), uint3(11, 4, 5), uint3(11, 7, 9), uint3(9, 7, 8)};
    const float3 level2[7] = {float3(1, 0, 0), float3(0.5f, 0.5f, 0), float3(0, 1, 0), float3(0, 0.5f, 0.5f), float3(0, 0, 1), float3(0.5f, 0, 0.5f), float3(1.0f / 3.0f)};
    uint triangles = counts[i];
    for (uint triangle = 0; triangle < triangles; ++triangle) {
        uint key = offsets[i] + triangle;
        for (uint corner = 0; corner < 3; ++corner) {
            uint slot = p[2] && corner ? 3 - corner : corner;
            float3 coordinate = triangles == 1 ? points[slot == 0 ? 0 : slot == 1 ? 3 : 6] : triangles == 6 ? level2[slot ? (triangle + slot - 1) % 6 : 6] : points[level3[triangle][slot]];
            uint record = 3 * key + corner;
            device uint* words = invocations + 4 + 8 * ulong(record);
            words[0] = as_type<uint>(coordinate.x); words[1] = as_type<uint>(coordinate.y); words[2] = as_type<uint>(coordinate.z);
            words[3] = i; words[4] = record; words[5] = 0; words[6] = 0; words[7] = 0;
            pairs[2 * record] = record;
            pairs[2 * record + 1] = key;
            triplets[3 * key + corner] = record;
            if (p[3]) { corners[record] = corner; }
        }
    }
}
)";
