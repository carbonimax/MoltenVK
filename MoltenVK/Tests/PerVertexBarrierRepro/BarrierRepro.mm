// Copyright (c) 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
// Metal-only reproducer of the in-pass ordering MoltenVK used before a564af04 for non-indexed portable PerVertexKHR
// draws: a capture draw whose pipeline has rasterization disabled writes one record per vertex into a Private buffer,
// memoryBarrierWithScope:Buffers afterStages:Vertex beforeStages:Vertex|Fragment follows, and a replay draw in the same
// render pass reads the records in its vertex function (positions) and its fragment function (flat colors). The
// record layout is MoltenVK's captured main0_out { float3 color; float4 gl_Position; float gl_PointSize; }.
//
// Each correctness variant runs several times and counts the runs whose replay saw the records:
// - vertex visibility: the quad covers exactly its 32x32 pixels (stale zero positions draw nothing);
// - fragment visibility: every covered pixel has its triangle's color (a stale record gives opaque black).
// The zero-filled records make a stale read deterministic. The capture spins on ALU work, so that the "none" control,
// which has no ordering at all, lets the replay overtake the capture. Exit 0 when the variant's Metal contract held
// in every run (or for the control, which has none), 2 when it did not, 1 when the variant could not run.
// The cost case times frames of K PerVertex draws on iPhone-sized RGBA8 + Depth32Float attachments, ordered by the
// barrier or by a render pass split (store, then load, of every attachment) as MoltenVK does since a564af04.
// Usage: pervertex-barrier-repro <variant|cost>; BARRIER_REPRO_WORK overrides the capture's ALU iterations.
#import <Metal/Metal.h>
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace {

const char* kSource = R"(
#include <metal_stdlib>
using namespace metal;
constant uint kStride = 48;  // sizeof(MoltenVK's captured main0_out)
struct Params { uint work; };
constant float2 kCorners[6] = { float2(-0.5, -0.5), float2(0.5, -0.5), float2(0.5, 0.5), float2(-0.5, -0.5), float2(0.5, 0.5), float2(-0.5, 0.5) };

static float4 capture_record(uint vid, uint work, device uchar* records) {
	float spin = float(vid);
	for (uint i = 0; i < work; ++i) { spin = fract(spin * 1.000123f + 0.37f); }
	device uchar* record = records + vid * kStride;
	float4 position = float4(kCorners[vid % 6], 0.0, 1.0);
	*reinterpret_cast<device float3*>(record) = vid < 3 ? float3(1, 0, 0) : float3(0, 1, 0);
	*reinterpret_cast<device float4*>(record + 16) = position;
	*reinterpret_cast<device float*>(record + 32) = spin;  // keeps the spin from being optimized away
	return position;
}

// The capture: rasterization disabled, as MoltenVK's direct capture pipeline.
vertex void capture(uint vid [[vertex_id]], constant Params& params [[buffer(1)]], device uchar* records [[buffer(0)]]) {
	capture_record(vid, params.work, records);
}

// The same capture with rasterization enabled: every primitive lies outside the clip volume.
vertex float4 capture_raster(uint vid [[vertex_id]], constant Params& params [[buffer(1)]], device uchar* records [[buffer(0)]]) {
	capture_record(vid, params.work, records);
	return float4(4.0, 4.0, 0.0, 1.0);
}

struct Replay { float4 position [[position]]; uint primitive [[flat]]; };

vertex Replay replay(uint vid [[vertex_id]], const device uchar* records [[buffer(0)]]) {
	Replay out;
	out.position = *reinterpret_cast<const device float4*>(records + vid * kStride + 16);
	out.primitive = vid / 3;
	return out;
}

// PerVertexKHR: the fragment reads its triangle's provoking record itself.
fragment float4 shade(Replay in [[stage_in]], const device uchar* records [[buffer(0)]]) {
	return float4(*reinterpret_cast<const device float3*>(records + in.primitive * 3 * kStride), 1.0);
}

// The cost frames start with incompressible attachments, as a rendered scene would leave them.
vertex float4 fullscreen(uint vid [[vertex_id]]) {
	return float4(float2((vid << 1) & 2, vid & 2) * 2.0 - 1.0, 0.0, 1.0);
}

struct Noise { float4 color [[color(0)]]; float depth [[depth(any)]]; };

fragment Noise noise(float4 position [[position]]) {
	uint2 pixel = uint2(position.xy);
	uint hash = pixel.x * 1664525u ^ pixel.y * 22695477u;
	hash ^= hash >> 13; hash *= 0x5bd1e995u; hash ^= hash >> 15;
	Noise out;
	out.color = unpack_unorm4x8_to_float(hash);
	out.depth = float(hash & 0xffffu) / 65535.0;
	return out;
}
)";

enum Order { kBarrier, kResourceBarrier, kSplit, kNone };
enum Contract { kVertexAndFragment, kVertexOnly, kObservation };

struct Variant {
	const char* name;
	Order order;
	MTLRenderStages before;
	bool rasterCapture;
	bool sharedRecords;
	bool indirectCapture;
	Contract contract;
};

const Variant kVariants[] = {
	{"barrier", kBarrier, MTLRenderStageVertex | MTLRenderStageFragment, false, false, false, kVertexAndFragment},
	{"barrier-indirect", kBarrier, MTLRenderStageVertex | MTLRenderStageFragment, false, false, true, kVertexAndFragment},
	{"split", kSplit, 0, false, false, false, kVertexAndFragment},
	{"none", kNone, 0, false, false, false, kObservation},
	{"barrier-raster", kBarrier, MTLRenderStageVertex | MTLRenderStageFragment, true, false, false, kVertexAndFragment},
	{"barrier-shared", kBarrier, MTLRenderStageVertex | MTLRenderStageFragment, false, true, false, kVertexAndFragment},
	{"barrier-resources", kResourceBarrier, MTLRenderStageVertex | MTLRenderStageFragment, false, false, false, kVertexAndFragment},
	{"barrier-v2v", kBarrier, MTLRenderStageVertex, false, false, false, kVertexOnly},
};

constexpr uint32_t kVertices = 6, kRecordStride = 48, kSize = 64, kRepeats = 5;

struct Context {
	id<MTLDevice> device;
	id<MTLCommandQueue> queue;
	id<MTLLibrary> library;
};

id<MTLRenderPipelineState> pipeline(Context& context, const char* vertex, const char* fragment, bool raster, bool depth) {
	MTLRenderPipelineDescriptor* descriptor = [MTLRenderPipelineDescriptor new];
	descriptor.vertexFunction = [context.library newFunctionWithName:@(vertex)];
	if (fragment) { descriptor.fragmentFunction = [context.library newFunctionWithName:@(fragment)]; }
	descriptor.rasterizationEnabled = raster;
	descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
	if (depth) { descriptor.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float; }
	NSError* error = nil;
	id<MTLRenderPipelineState> state = [context.device newRenderPipelineStateWithDescriptor:descriptor error:&error];
	if (!state) { printf("ERROR pipeline %s: %s\n", vertex, error.localizedDescription.UTF8String); }
	return state;
}

MTLRenderPassDescriptor* pass(id<MTLTexture> color, id<MTLTexture> depth, bool clear) {
	MTLRenderPassDescriptor* descriptor = [MTLRenderPassDescriptor renderPassDescriptor];
	descriptor.colorAttachments[0].texture = color;
	descriptor.colorAttachments[0].loadAction = clear ? MTLLoadActionClear : MTLLoadActionLoad;
	descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
	descriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
	if (depth) {
		descriptor.depthAttachment.texture = depth;
		descriptor.depthAttachment.loadAction = clear ? MTLLoadActionClear : MTLLoadActionLoad;
		descriptor.depthAttachment.storeAction = MTLStoreActionStore;
	}
	return descriptor;
}

id<MTLTexture> target(Context& context, MTLPixelFormat format, uint32_t width, uint32_t height) {
	MTLTextureDescriptor* descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:width height:height mipmapped:NO];
	descriptor.usage = MTLTextureUsageRenderTarget;
	descriptor.storageMode = MTLStorageModePrivate;
	return [context.device newTextureWithDescriptor:descriptor];
}

struct Draws {
	id<MTLRenderPipelineState> capture, replay;
	id<MTLBuffer> records, indirect;
	uint32_t work;
};

// Encodes one PerVertex draw, capture then replay, ordered as the variant says; returns the encoder the replay used.
id<MTLRenderCommandEncoder> encodeDraw(id<MTLCommandBuffer> commands, id<MTLRenderCommandEncoder> encoder, const Variant& variant, const Draws& draws,
									   id<MTLTexture> color, id<MTLTexture> depth) {
	[encoder setRenderPipelineState:draws.capture];
	[encoder setVertexBuffer:draws.records offset:0 atIndex:0];
	[encoder setVertexBytes:&draws.work length:sizeof(draws.work) atIndex:1];
	if (variant.indirectCapture) { [encoder drawPrimitives:MTLPrimitiveTypeTriangle indirectBuffer:draws.indirect indirectBufferOffset:0]; }
	else { [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:kVertices]; }
	id<MTLResource> records = draws.records;
	switch (variant.order) {
		case kBarrier: [encoder memoryBarrierWithScope:MTLBarrierScopeBuffers afterStages:MTLRenderStageVertex beforeStages:variant.before]; break;
		case kResourceBarrier: [encoder memoryBarrierWithResources:&records count:1 afterStages:MTLRenderStageVertex beforeStages:variant.before]; break;
		case kSplit:
			[encoder endEncoding];
			encoder = [commands renderCommandEncoderWithDescriptor:pass(color, depth, false)];
			break;
		case kNone: break;
	}
	[encoder setRenderPipelineState:draws.replay];
	[encoder setVertexBuffer:draws.records offset:0 atIndex:0];
	[encoder setFragmentBuffer:draws.records offset:0 atIndex:0];
	[encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:kVertices];
	return encoder;
}

bool finished(id<MTLCommandBuffer> commands) {
	[commands commit];
	[commands waitUntilCompleted];
	if (commands.status == MTLCommandBufferStatusCompleted) { return true; }
	printf("ERROR command buffer status=%ld: %s\n", long(commands.status), commands.error.localizedDescription.UTF8String ?: "none");
	return false;
}

Draws makeDraws(Context& context, const Variant& variant, bool depth, uint32_t work) {
	Draws draws;
	draws.capture = variant.rasterCapture ? pipeline(context, "capture_raster", nullptr, true, depth) : pipeline(context, "capture", nullptr, false, depth);
	draws.replay = pipeline(context, "replay", "shade", true, depth);
	draws.records = [context.device newBufferWithLength:kVertices * kRecordStride options:variant.sharedRecords ? MTLResourceStorageModeShared : MTLResourceStorageModePrivate];
	MTLDrawPrimitivesIndirectArguments arguments = {kVertices, 1, 0, 0};
	draws.indirect = [context.device newBufferWithBytes:&arguments length:sizeof(arguments) options:MTLResourceStorageModeShared];
	draws.work = work;
	return draws;
}

int correctness(Context& context, const Variant& variant) {
	const char* override = getenv("BARRIER_REPRO_WORK");
	Draws draws = makeDraws(context, variant, false, override ? uint32_t(strtoul(override, nullptr, 10)) : 1u << 16);
	if (!draws.capture || !draws.replay) { return 1; }
	id<MTLTexture> color = target(context, MTLPixelFormatRGBA8Unorm, kSize, kSize);
	id<MTLBuffer> pixels = [context.device newBufferWithLength:kSize * kSize * 4 options:MTLResourceStorageModeShared];
	uint32_t vertexVisible = 0, fragmentVisible = 0;
	std::string sample;
	for (uint32_t run = 0; run < kRepeats; ++run) {
		id<MTLCommandBuffer> commands = [context.queue commandBuffer];
		id<MTLBlitCommandEncoder> blit = [commands blitCommandEncoder];
		[blit fillBuffer:draws.records range:NSMakeRange(0, draws.records.length) value:0];
		[blit endEncoding];
		id<MTLRenderCommandEncoder> encoder = [commands renderCommandEncoderWithDescriptor:pass(color, nil, true)];
		encoder = encodeDraw(commands, encoder, variant, draws, color, nil);
		[encoder endEncoding];
		blit = [commands blitCommandEncoder];
		[blit copyFromTexture:color sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(kSize, kSize, 1)
					 toBuffer:pixels destinationOffset:0 destinationBytesPerRow:kSize * 4 destinationBytesPerImage:kSize * kSize * 4];
		[blit endEncoding];
		if (!finished(commands)) { return 1; }
		uint32_t red = 0, green = 0, clear = 0, stale = 0, other = 0;
		const uint8_t* p = (const uint8_t*)pixels.contents;
		for (uint32_t i = 0; i < kSize * kSize; ++i, p += 4) {
			uint32_t rgba = uint32_t(p[0]) << 24 | uint32_t(p[1]) << 16 | uint32_t(p[2]) << 8 | p[3];
			if (rgba == 0xff0000ffu) { ++red; } else if (rgba == 0x00ff00ffu) { ++green; } else if (rgba == 0) { ++clear; }
			else if (rgba == 0x000000ffu) { ++stale; } else { ++other; }
		}
		// The quad spans pixels 16..47 on both axes: 1024 covered pixels, each drawn once by one of its triangles.
		uint32_t covered = red + green + stale + other;
		bool vertex = covered == 1024 && clear == kSize * kSize - 1024;
		bool fragment = vertex && red && green && red + green == 1024;
		vertexVisible += vertex;
		fragmentVisible += fragment;
		if (sample.empty() || !vertex || !fragment) {
			char line[160];
			snprintf(line, sizeof(line), "run=%u red=%u green=%u clear=%u stale_fragment=%u other=%u", run, red, green, clear, stale, other);
			sample = line;
		}
	}
	bool held = variant.contract == kObservation || (vertexVisible == kRepeats && (variant.contract == kVertexOnly || fragmentVisible == kRepeats));
	const char* contract = variant.contract == kObservation ? "none" : variant.contract == kVertexOnly ? "vertex" : "vertex+fragment";
	printf("BARRIER_REPRO %s variant=%s work=%u repeats=%u vertex_visible=%u fragment_visible=%u contract=%s %s\n", held ? "PASS" : "FAIL", variant.name,
		   draws.work, kRepeats, vertexVisible, fragmentVisible, contract, sample.c_str());
	return held ? 0 : 2;
}

// Alternates barrier and split frames in one continuous stream, so that GPU clock changes weigh on both alike.
int cost(Context& context) {
	// An iPhone 15 Pro / 18 Pro native portrait framebuffer, rendered in landscape.
	constexpr uint32_t width = 2556, height = 1179, draws = 16, warmup = 20, pairs = 100;
	const Variant* variants[] = {&kVariants[0], &kVariants[2]};  // barrier, split
	Draws perVertex[] = {makeDraws(context, *variants[0], true, 0), makeDraws(context, *variants[1], true, 0)};
	id<MTLTexture> color = target(context, MTLPixelFormatRGBA8Unorm, width, height);
	id<MTLTexture> depth = target(context, MTLPixelFormatDepth32Float, width, height);
	id<MTLRenderPipelineState> background = pipeline(context, "fullscreen", "noise", true, true);
	MTLDepthStencilDescriptor* depthDescriptor = [MTLDepthStencilDescriptor new];
	depthDescriptor.depthCompareFunction = MTLCompareFunctionAlways;
	depthDescriptor.depthWriteEnabled = YES;
	id<MTLDepthStencilState> writeDepth = [context.device newDepthStencilStateWithDescriptor:depthDescriptor];
	depthDescriptor.depthWriteEnabled = NO;  // as the encoder's default state, which a split pass starts with
	id<MTLDepthStencilState> keepDepth = [context.device newDepthStencilStateWithDescriptor:depthDescriptor];
	if (!background || !perVertex[0].capture || !perVertex[0].replay || !perVertex[1].capture || !perVertex[1].replay) { return 1; }
	std::vector<id<MTLCommandBuffer>> frames;
	for (uint32_t frame = 0; frame < warmup + 2 * pairs; ++frame) {
		uint32_t which = frame % 2;
		id<MTLCommandBuffer> commands = [context.queue commandBuffer];
		id<MTLRenderCommandEncoder> encoder = [commands renderCommandEncoderWithDescriptor:pass(color, depth, true)];
		[encoder setRenderPipelineState:background];
		[encoder setDepthStencilState:writeDepth];
		[encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
		[encoder setDepthStencilState:keepDepth];
		for (uint32_t draw = 0; draw < draws; ++draw) { encoder = encodeDraw(commands, encoder, *variants[which], perVertex[which], color, depth); }
		[encoder endEncoding];
		[commands commit];
		frames.push_back(commands);
	}
	std::vector<double> milliseconds[2], differences;
	for (uint32_t frame = 0; frame < frames.size(); ++frame) {
		[frames[frame] waitUntilCompleted];
		if (frames[frame].status != MTLCommandBufferStatusCompleted) {
			printf("ERROR frame %u status=%ld: %s\n", frame, long(frames[frame].status), frames[frame].error.localizedDescription.UTF8String ?: "none");
			return 1;
		}
		if (frame < warmup) { continue; }
		milliseconds[frame % 2].push_back((frames[frame].GPUEndTime - frames[frame].GPUStartTime) * 1000.0);
		if (frame % 2) { differences.push_back(milliseconds[1].back() - milliseconds[0].back()); }
	}
	auto median = [](std::vector<double> values) { std::sort(values.begin(), values.end()); return values[values.size() / 2]; };
	double splitBytes = double(width) * height * (4 + 4) * 2;  // store then load of color and depth
	printf("BARRIER_COST PASS width=%u height=%u draws_per_frame=%u pairs=%u barrier_gpu_ms_median=%.3f split_gpu_ms_median=%.3f "
		   "paired_difference_ms_median=%.3f per_split_us=%.1f split_bytes_each=%.0f\n", width, height, draws, pairs, median(milliseconds[0]),
		   median(milliseconds[1]), median(differences), median(differences) * 1000.0 / draws, splitBytes);
	return 0;
}

}  // namespace

extern "C" int pervertexBarrierMain(int argc, char** argv) {
	@autoreleasepool {
		if (argc < 2) { printf("usage: %s <variant|cost>\n", argv[0]); return 1; }
		std::string name = argv[1];
		const Variant* variant = nullptr;
		for (const auto& candidate : kVariants) { if (name == candidate.name) { variant = &candidate; } }
		if (!variant && name != "cost") { printf("ERROR unknown variant %s\n", argv[1]); return 1; }
		Context context;
		context.device = MTLCreateSystemDefaultDevice();
		if (!context.device) { printf("ERROR no Metal device\n"); return 1; }
		printf("DEVICE=%s\n", context.device.name.UTF8String);
		context.queue = [context.device newCommandQueue];
		NSError* error = nil;
		context.library = [context.device newLibraryWithSource:@(kSource) options:[MTLCompileOptions new] error:&error];
		if (!context.library) { printf("ERROR library: %s\n", error.localizedDescription.UTF8String); return 1; }
		return variant ? correctness(context, *variant) : cost(context);
	}
}

#ifdef BARRIER_REPRO_STANDALONE
int main(int argc, char** argv) { return pervertexBarrierMain(argc, argv); }
#endif
