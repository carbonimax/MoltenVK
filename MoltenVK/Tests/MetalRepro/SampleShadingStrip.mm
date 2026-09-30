// Copyright 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
// Metal only, without MoltenVK: sample-rate shading of a two-triangle strip under 4x MSAA. The vertex and fragment
// shaders are the MSL MoltenVK generates for the reference of PerVertexMSAAWeightsTests.mm (sample-strip), compiled with
// the options MoltenVK uses (MathMode Fast, MathFloatingPointFunctions Fast, PreserveInvariance off). The geometry is
// the CTS weights test's: 128 x 128, right-hand vertices at w = 16, colours at the corners. The resolved image is
// compared with two models computed on the CPU in double at the standard 4x sample locations: interpolation at each
// sample, and interpolation at the pixel centre (each sample keeps the triangle that covers it).
// Fragment variants, to separate what restores sample-rate shading:
//   moltenvk        the MSL as generated: a sample_perspective input and an unused [[sample_id]] parameter;
//   no-sample-id    the same without the [[sample_id]] parameter;
//   sample-id-read  gl_SampleID read into the output through a constant buffer holding 0 (not foldable, no write);
//   buffer-write    an atomic increment of a device buffer, without reading gl_SampleID or the sample position;
//   oracle          what the Vulkan samples oracle does: colour and sample position written at [pixel, sample_id].
// Exit 0: the image matches the per-sample model within 1 everywhere; 4: it does not; 1 or 2: setup error.
// Topologies: strip (4 vertices); list (the two triangles as 6 vertices); indexed (the strip's 4 vertices drawn as an
// indexed triangle list, 0 1 2 1 2 3, so that the triangles share vertices without being a strip); fan-indexed (the CTS
// fan's 4 vertices, left top, left bottom, right bottom, right top, drawn as the indexed triangles MoltenVK converts a
// fan to, 1 2 0 2 3 0).
// Usage: sample-shading-strip <variant> strip|list|indexed|fan-indexed <output directory>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <fstream>
#include <string>
#include <vector>

static const char* kVertexSource = R"(#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct main0_out
{
    float3 color [[user(locn0)]];
    float4 gl_Position [[position]];
};

struct main0_in
{
    float4 position [[attribute(0)]];
    float4 inputColor [[attribute(1)]];
};

vertex main0_out main0(main0_in in [[stage_in]])
{
    main0_out out = {};
    out.color = in.inputColor.xyz;
    out.gl_Position = in.position;
    out.gl_Position.y = -(out.gl_Position.y);    // Invert Y-axis for Metal
    return out;
}
)";

static std::string fragmentSource(const std::string& variant) {
	std::string head = R"(#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct main0_out
{
    float4 outputColor [[color(0)]];
};

struct main0_in
{
    float3 color [[user(locn0), sample_perspective]];
};

)";
	if (variant == "moltenvk") return head + R"(fragment main0_out main0(main0_in in [[stage_in]], uint gl_SampleID [[sample_id]])
{
    main0_out out = {};
    out.outputColor = float4(in.color, 1.0);
    return out;
}
)";
	if (variant == "no-sample-id") return head + R"(fragment main0_out main0(main0_in in [[stage_in]])
{
    main0_out out = {};
    out.outputColor = float4(in.color, 1.0);
    return out;
}
)";
	if (variant == "sample-id-read") return head + R"(fragment main0_out main0(main0_in in [[stage_in]], uint gl_SampleID [[sample_id]], constant uint& zero [[buffer(0)]])
{
    main0_out out = {};
    out.outputColor = float4(in.color, 1.0 + float(gl_SampleID * zero));
    return out;
}
)";
	if (variant == "buffer-write") return head + R"(fragment main0_out main0(main0_in in [[stage_in]], device atomic_uint* counter [[buffer(1)]])
{
    main0_out out = {};
    atomic_fetch_add_explicit(counter, 1u, memory_order_relaxed);
    out.outputColor = float4(in.color, 1.0);
    return out;
}
)";
	if (variant == "oracle") return head + R"(fragment main0_out main0(main0_in in [[stage_in]], uint gl_SampleID [[sample_id]], float4 gl_FragCoord [[position]], device float4* samples [[buffer(1)]])
{
    main0_out out = {};
    uint2 pixel = uint2(gl_FragCoord.xy);
    uint slot = ((pixel.y * 128u + pixel.x) * 4u + gl_SampleID) * 2u;
    samples[slot] = float4(in.color, 1.0);
    samples[slot + 1u] = float4(get_sample_position(gl_SampleID), gl_FragCoord.xy);
    out.outputColor = float4(in.color, 1.0);
    return out;
}
)";
	return "";
}

constexpr int kSide = 128;
struct Vertex { float position[4], color[4]; };

int main(int argc, char** argv) {
	@autoreleasepool {
	if (argc != 4) { std::fprintf(stderr, "Usage: sample-shading-strip moltenvk|no-sample-id|sample-id-read|buffer-write|oracle strip|list|indexed|fan-indexed output-dir\n"); return 1; }
	const std::string variant = argv[1], topology = argv[2], output = argv[3];
	const std::string fragment = fragmentSource(variant);
	if (fragment.empty() || (topology != "strip" && topology != "list" && topology != "indexed" && topology != "fan-indexed")) { std::fprintf(stderr, "Unknown case\n"); return 1; }
	const bool strip = topology == "strip" || topology == "indexed", fan = topology == "fan-indexed", indexed = topology == "indexed" || fan;
	id<MTLDevice> device = MTLCreateSystemDefaultDevice();
	std::printf("DEVICE=%s variant=%s topology=%s\n", device.name.UTF8String, variant.c_str(), topology.c_str());

	MTLCompileOptions* options = [MTLCompileOptions new];
	options.mathMode = MTLMathModeFast;
	options.mathFloatingPointFunctions = MTLMathFloatingPointFunctionsFast;
	options.preserveInvariance = NO;
	NSError* error = nil;
	id<MTLLibrary> vertexLibrary = [device newLibraryWithSource:@(kVertexSource) options:options error:&error];
	id<MTLLibrary> fragmentLibrary = [device newLibraryWithSource:@(fragment.c_str()) options:options error:&error];
	if (!vertexLibrary || !fragmentLibrary) { std::fprintf(stderr, "Compile: %s\n", error.localizedDescription.UTF8String); return 1; }
	std::ofstream(output + "/fragment.metal") << fragment;

	MTLRenderPipelineDescriptor* pipelineDescriptor = [MTLRenderPipelineDescriptor new];
	pipelineDescriptor.vertexFunction = [vertexLibrary newFunctionWithName:@"main0"];
	pipelineDescriptor.fragmentFunction = [fragmentLibrary newFunctionWithName:@"main0"];
	pipelineDescriptor.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
	pipelineDescriptor.rasterSampleCount = 4;
	pipelineDescriptor.inputPrimitiveTopology = MTLPrimitiveTopologyClassTriangle;
	MTLVertexDescriptor* vertexDescriptor = [MTLVertexDescriptor vertexDescriptor];
	for (int a = 0; a < 2; ++a) {
		vertexDescriptor.attributes[a].format = MTLVertexFormatFloat4;
		vertexDescriptor.attributes[a].offset = a * 16;
		vertexDescriptor.attributes[a].bufferIndex = 30;
	}
	vertexDescriptor.layouts[30].stride = sizeof(Vertex);
	pipelineDescriptor.vertexDescriptor = vertexDescriptor;
	id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithDescriptor:pipelineDescriptor error:&error];
	if (!pipeline) { std::fprintf(stderr, "Pipeline: %s\n", error.localizedDescription.UTF8String); return 1; }

	MTLTextureDescriptor* msDescriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:kSide height:kSide mipmapped:NO];
	msDescriptor.textureType = MTLTextureType2DMultisample;
	msDescriptor.sampleCount = 4;
	msDescriptor.usage = MTLTextureUsageRenderTarget;
	msDescriptor.storageMode = MTLStorageModePrivate;
	id<MTLTexture> multisample = [device newTextureWithDescriptor:msDescriptor];
	MTLTextureDescriptor* resolveDescriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:kSide height:kSide mipmapped:NO];
	resolveDescriptor.usage = MTLTextureUsageRenderTarget;
	resolveDescriptor.storageMode = MTLStorageModePrivate;
	id<MTLTexture> resolve = [device newTextureWithDescriptor:resolveDescriptor];

	// The CTS weights vertices (Vulkan clip space; the vertex shader inverts y as MoltenVK does).
	const float s = 16;
	const Vertex leftTop{{-1, -1, 0, 1}, {1, 0, 0, 1}}, leftBottom{{-1, 1, 0, 1}, {0, 0, 0, 1}};
	const Vertex rightBottom{{s, s, 0, s}, {0, 0, 1, 1}}, rightTop{{s, -s, 0, s}, {0, 1, 0, 1}};
	const std::vector<Vertex> vertices = strip ? std::vector<Vertex>{leftBottom, leftTop, rightBottom, rightTop}
	                                   : fan ? std::vector<Vertex>{leftTop, leftBottom, rightBottom, rightTop}
	                                         : std::vector<Vertex>{leftTop, leftBottom, rightBottom, rightBottom, rightTop, leftTop};
	id<MTLBuffer> vertexBuffer = [device newBufferWithBytes:vertices.data() length:vertices.size() * sizeof(Vertex) options:MTLResourceStorageModeShared];
	const uint32_t zero = 0;
	id<MTLBuffer> zeroBuffer = [device newBufferWithBytes:&zero length:sizeof(zero) options:MTLResourceStorageModeShared];
	const size_t samplesLength = size_t(kSide) * kSide * 4 * 2 * 16;
	id<MTLBuffer> sideBuffer = [device newBufferWithLength:samplesLength options:MTLResourceStorageModeShared];
	memset(sideBuffer.contents, 0, samplesLength);
	id<MTLBuffer> readback = [device newBufferWithLength:kSide * kSide * 4 options:MTLResourceStorageModeShared];

	id<MTLCommandQueue> queue = [device newCommandQueue];
	id<MTLCommandBuffer> commands = [queue commandBuffer];
	MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
	pass.colorAttachments[0].texture = multisample;
	pass.colorAttachments[0].resolveTexture = resolve;
	pass.colorAttachments[0].loadAction = MTLLoadActionClear;
	pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
	pass.colorAttachments[0].storeAction = MTLStoreActionMultisampleResolve;
	id<MTLRenderCommandEncoder> encoder = [commands renderCommandEncoderWithDescriptor:pass];
	[encoder setRenderPipelineState:pipeline];
	[encoder setViewport:(MTLViewport){0, 0, double(kSide), double(kSide), 0, 1}];
	[encoder setCullMode:MTLCullModeNone];
	[encoder setVertexBuffer:vertexBuffer offset:0 atIndex:30];
	[encoder setFragmentBuffer:zeroBuffer offset:0 atIndex:0];
	[encoder setFragmentBuffer:sideBuffer offset:0 atIndex:1];
	const uint16_t stripIndices[6] = {0, 1, 2, 1, 2, 3}, fanIndices[6] = {1, 2, 0, 2, 3, 0};
	const uint16_t* indices = fan ? fanIndices : stripIndices;
	id<MTLBuffer> indexBuffer = [device newBufferWithBytes:indices length:6 * sizeof(uint16_t) options:MTLResourceStorageModeShared];
	if (indexed) [encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:6 indexType:MTLIndexTypeUInt16 indexBuffer:indexBuffer indexBufferOffset:0];
	else [encoder drawPrimitives:strip ? MTLPrimitiveTypeTriangleStrip : MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:vertices.size()];
	[encoder endEncoding];
	id<MTLBlitCommandEncoder> blit = [commands blitCommandEncoder];
	[blit copyFromTexture:resolve sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(kSide, kSide, 1)
	             toBuffer:readback destinationOffset:0 destinationBytesPerRow:kSide * 4 destinationBytesPerImage:kSide * kSide * 4];
	[blit endEncoding];
	[commands commit];
	[commands waitUntilCompleted];
	if (commands.status != MTLCommandBufferStatusCompleted) { std::fprintf(stderr, "Command buffer status %d\n", int(commands.status)); return 1; }
	const uint8_t* image = static_cast<const uint8_t*>(readback.contents);
	std::ofstream(output + "/resolved.rgba", std::ios::binary).write(reinterpret_cast<const char*>(image), kSide * kSide * 4);
	if (variant == "buffer-write" || variant == "oracle") std::ofstream(output + "/side.bin", std::ios::binary).write(static_cast<const char*>(sideBuffer.contents), variant == "oracle" ? samplesLength : 4);

	// CPU models, in Vulkan window coordinates (y down), at the standard 4x locations.
	const double locations[4][2] = {{0.375, 0.125}, {0.875, 0.375}, {0.125, 0.625}, {0.625, 0.875}};
	const std::vector<int> triangles = strip ? std::vector<int>{0, 1, 2, 1, 2, 3} : fan ? std::vector<int>{1, 2, 0, 2, 3, 0} : std::vector<int>{0, 1, 2, 3, 4, 5};
	auto window = [&](const Vertex& v, int axis) { return (double(v.position[axis]) / double(v.position[3]) + 1.0) * 0.5 * kSide; };
	auto weights = [&](size_t t, double px, double py, double l[3]) {
		double x[3], y[3];
		for (int i = 0; i < 3; ++i) { x[i] = window(vertices[triangles[t + i]], 0); y[i] = window(vertices[triangles[t + i]], 1); }
		const double area = (x[1] - x[0]) * (y[2] - y[0]) - (x[2] - x[0]) * (y[1] - y[0]);
		l[0] = ((x[1] - px) * (y[2] - py) - (x[2] - px) * (y[1] - py)) / area;
		l[1] = ((x[2] - px) * (y[0] - py) - (x[0] - px) * (y[2] - py)) / area;
		l[2] = 1 - l[0] - l[1];
	};
	auto owner = [&](double px, double py) {
		size_t best = 0;
		double bestInside = -1e30;
		for (size_t t = 0; t < triangles.size(); t += 3) {
			double l[3];
			weights(t, px, py, l);
			const double inside = std::min(l[0], std::min(l[1], l[2]));
			if (inside > bestInside) { bestInside = inside; best = t; }
		}
		return best;
	};
	auto colour = [&](size_t t, double px, double py, int c) {
		double l[3], b[3], sum = 0;
		weights(t, px, py, l);
		for (int i = 0; i < 3; ++i) { b[i] = l[i] / double(vertices[triangles[t + i]].position[3]); sum += b[i]; }
		return (b[0] * vertices[triangles[t]].color[c] + b[1] * vertices[triangles[t + 1]].color[c] + b[2] * vertices[triangles[t + 2]].color[c]) / sum;
	};
	auto quantize = [](double v) { return int(std::lround(std::min(1.0, std::max(0.0, v)) * 255)); };
	int matchSample = 0, matchCentre = 0, worstSample = 0, worstX = 0, worstY = 0;
	for (int y = 0; y < kSide; ++y) {
		for (int x = 0; x < kSide; ++x) {
			int perSample[3] = {}, atCentre[3] = {};
			for (int k = 0; k < 4; ++k) {
				const size_t t = owner(x + locations[k][0], y + locations[k][1]);
				for (int c = 0; c < 3; ++c) {
					perSample[c] += quantize(colour(t, x + locations[k][0], y + locations[k][1], c));
					atCentre[c] += quantize(colour(t, x + 0.5, y + 0.5, c));
				}
			}
			int dSample = 0, dCentre = 0;
			for (int c = 0; c < 3; ++c) {
				const int pixel = image[(y * kSide + x) * 4 + c];
				dSample = std::max(dSample, std::abs(pixel - (perSample[c] + 2) / 4));
				dCentre = std::max(dCentre, std::abs(pixel - (atCentre[c] + 2) / 4));
			}
			matchSample += dSample <= 1;
			matchCentre += dCentre <= 1;
			if (dSample > worstSample) { worstSample = dSample; worstX = x; worstY = y; }
		}
	}
	std::printf("resolved image vs per-sample model: %d/%d pixels within 1, worst %d at (%d, %d)\n", matchSample, kSide * kSide, worstSample, worstX, worstY);
	std::printf("resolved image vs pixel-centre model: %d/%d pixels within 1\n", matchCentre, kSide * kSide);
	if (variant == "buffer-write") std::printf("fragment invocations counted: %u (samples: %d)\n", *static_cast<const uint32_t*>(sideBuffer.contents), kSide * kSide * 4);
	const int exitCode = matchSample == kSide * kSide ? 0 : 4;
	std::printf("METAL_SAMPLE_SHADING %s %s %s\n", exitCode ? "PIXEL_RATE_MATCH" : "PER_SAMPLE_MATCH", variant.c_str(), topology.c_str());
	return exitCode;
	}
}
