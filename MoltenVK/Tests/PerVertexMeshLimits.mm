// Copyright (c) 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
// Metal-only probe of the mesh limits behind VkPhysicalDeviceMeshShaderPropertiesEXT. Each case compiles a mesh
// pipeline, draws it, and checks what the GPU actually executed or rendered: a pipeline that compiles but renders
// wrong values fails. It reports, per limit, the minimum Vulkan requires of VK_EXT_mesh_shader and whether this GPU
// meets it. It never uses Vulkan or MoltenVK. Exit 0 once every case ran; the verdicts are data.
#import <Metal/Metal.h>
#include <cstdio>
#include <string>
#include <vector>

static id<MTLDevice> device;
static id<MTLCommandQueue> queue;

struct Outcome { bool created = false, executed = false, correct = false; NSUInteger maxThreads = 0, maxGrid = 0; std::string detail; };

static std::string header(uint32_t attributes) {
	std::string s = "#include <metal_stdlib>\nusing namespace metal;\nstruct V { float4 position [[position]];";
	for (uint32_t i = 0; i < attributes; ++i) { s += " float4 a" + std::to_string(i) + " [[user(locn" + std::to_string(i) + ")]];"; }
	return s + " };\nstruct F { float4 position [[position]];" + (attributes ? std::string(" float4 a0 [[user(locn0)]];") : "") + " };\n";
}

static id<MTLRenderPipelineState> pipeline(const std::string& source, MTLPixelFormat format, Outcome& o) {
	NSError* error = nil;
	id<MTLLibrary> library = [device newLibraryWithSource:@(source.c_str()) options:nil error:&error];
	if (!library) { o.detail = std::string("compile: ") + error.localizedDescription.UTF8String; return nil; }
	MTLMeshRenderPipelineDescriptor* desc = [MTLMeshRenderPipelineDescriptor new];
	desc.meshFunction = [library newFunctionWithName:@"meshMain"];
	desc.fragmentFunction = [library newFunctionWithName:@"fragmentMain"];
	desc.colorAttachments[0].pixelFormat = format;
	id<MTLRenderPipelineState> state = [device newRenderPipelineStateWithMeshDescriptor:desc options:MTLPipelineOptionNone reflection:nil error:&error];
	if (!state) { o.detail = std::string("pipeline: ") + error.localizedDescription.UTF8String; return nil; }
	o.created = true;
	o.maxThreads = state.maxTotalThreadsPerMeshThreadgroup;
	o.maxGrid = state.maxTotalThreadgroupsPerMeshGrid;
	return state;
}

// Draws the mesh grid into a cleared width x height x layers texture; returns the texture, or nil on a GPU error.
static id<MTLTexture> draw(id<MTLRenderPipelineState> state, MTLSize grid, MTLSize threads, id<MTLBuffer> buffer, id<MTLBuffer> fragmentBuffer, uint32_t width, uint32_t height, uint32_t layers, MTLPixelFormat format, Outcome& o) {
	if (threads.width * threads.height * threads.depth > o.maxThreads) { o.detail = "threadgroup exceeds maxTotalThreadsPerMeshThreadgroup " + std::to_string(o.maxThreads); return nil; }
	MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:width height:height mipmapped:NO];
	if (layers > 1) { td.textureType = MTLTextureType2DArray; td.arrayLength = layers; }
	td.usage = MTLTextureUsageRenderTarget;
	td.storageMode = MTLStorageModeShared;
	id<MTLTexture> target = [device newTextureWithDescriptor:td];
	MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
	pass.colorAttachments[0].texture = target;
	pass.colorAttachments[0].loadAction = MTLLoadActionClear;
	pass.colorAttachments[0].storeAction = MTLStoreActionStore;
	pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
	if (layers > 1) { pass.renderTargetArrayLength = layers; }
	id<MTLCommandBuffer> cb = [queue commandBuffer];
	id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:pass];
	[enc setRenderPipelineState:state];
	if (buffer) { [enc setMeshBuffer:buffer offset:0 atIndex:0]; }
	if (fragmentBuffer) { [enc setFragmentBuffer:fragmentBuffer offset:0 atIndex:0]; }
	[enc drawMeshThreadgroups:grid threadsPerObjectThreadgroup:MTLSizeMake(1, 1, 1) threadsPerMeshThreadgroup:threads];
	[enc endEncoding];
	[cb commit];
	[cb waitUntilCompleted];
	if (cb.status != MTLCommandBufferStatusCompleted) { o.detail = std::string("GPU: ") + (cb.error ? cb.error.localizedDescription.UTF8String : "not completed"); return nil; }
	o.executed = true;
	return target;
}

static uint32_t countCovered(id<MTLTexture> t, uint32_t width, uint32_t height, uint32_t layer, float expected) {
	std::vector<float> texels(size_t(width) * height * 4);
	[t getBytes:texels.data() bytesPerRow:width * 16 bytesPerImage:width * height * 16 fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0 slice:layer];
	uint32_t n = 0;
	for (size_t i = 0; i < size_t(width) * height; ++i) { n += texels[4 * i] == expected && texels[4 * i + 3] == 1; }
	return n;
}

// Every thread of every mesh threadgroup counts itself; thread 0 of each threadgroup emits nothing.
static Outcome countThreads(MTLSize grid, MTLSize threads, uint32_t sharedFloats) {
	Outcome o;
	std::string s = header(0) + "[[mesh]] void meshMain(mesh<V, void, 3, 1, topology::triangle> m, device atomic_uint* counter [[buffer(0)]], uint t [[thread_index_in_threadgroup]], uint n [[threads_per_threadgroup]]) {\n";
	if (sharedFloats) {
		// Each thread fills a strided part of the shared array, then thread 0 checks every element.
		s += "  threadgroup float shared[" + std::to_string(sharedFloats) + "];\n  for (uint i = t; i < " + std::to_string(sharedFloats) + "; i += n) shared[i] = float(i);\n  threadgroup_barrier(mem_flags::mem_threadgroup);\n";
		s += "  if (t == 0) { uint bad = 0; for (uint i = 0; i < " + std::to_string(sharedFloats) + "; ++i) bad += shared[i] != float(i); if (bad) atomic_fetch_add_explicit(counter + 1, bad, memory_order_relaxed); }\n";
	}
	s += "  atomic_fetch_add_explicit(counter, 1, memory_order_relaxed);\n  if (t == 0) m.set_primitive_count(0);\n}\nfragment float4 fragmentMain(F in [[stage_in]]) { return float4(1); }\n";
	id<MTLRenderPipelineState> state = pipeline(s, MTLPixelFormatRGBA32Float, o);
	if (!state) { return o; }
	id<MTLBuffer> counter = [device newBufferWithLength:8 options:MTLResourceStorageModeShared];
	memset(counter.contents, 0, 8);
	if (!draw(state, grid, threads, counter, nil, 1, 1, 1, MTLPixelFormatRGBA32Float, o)) { return o; }
	uint64_t expected = uint64_t(grid.width) * grid.height * grid.depth * threads.width * threads.height * threads.depth;
	uint32_t got = ((uint32_t*)counter.contents)[0], bad = ((uint32_t*)counter.contents)[1];
	o.correct = got == expected && !bad;
	o.detail = "threads=" + std::to_string(got) + " expected=" + std::to_string(expected) + (sharedFloats ? " shared_mismatches=" + std::to_string(bad) : "");
	return o;
}

// One threadgroup emits `primitives` triangles over `vertices` vertices: primitive p joins its own vertex p % (vertices - 2)
// to two shared anchors, so every vertex and primitive is used and every triangle covers pixels. Each vertex carries
// `attributes` float4 outputs of known values; the fragment checks their interpolated sum and marks its primitive.
// With layers, primitive p renders into layer p % layers, which must then hold covered pixels.
static Outcome renderPrimitives(uint32_t vertices, uint32_t primitives, uint32_t attributes, uint32_t layers) {
	Outcome o;
	const uint32_t side = 16;
	std::string V = std::to_string(vertices), N = std::to_string(primitives), unique = std::to_string(vertices - 2);
	std::string s = header(attributes);
	// Each primitive carries its index as flat per-primitive data: the fragment primitive_id proved unreliable.
	s += std::string("struct P { uint id [[user(pid)]];") + (layers > 1 ? " uint layer [[render_target_array_index]];" : "") + " };\n";
	s += "[[mesh]] void meshMain(mesh<V, P, " + V + ", " + N + ", topology::triangle> m, uint t [[thread_index_in_threadgroup]]) {\n";
	s += "  if (t != 0) return;\n  m.set_primitive_count(" + N + ");\n";
	s += "  for (uint i = 0; i < " + V + "; ++i) { V v;\n";
	s += "    v.position = i == " + std::to_string(vertices - 2) + " ? float4(-1, -1, 0, 1) : i == " + std::to_string(vertices - 1) + " ? float4(1, -1, 0, 1) : float4(float(i) / " + unique + ".0 - 0.5, 1, 0, 1);\n";
	for (uint32_t a = 0; a < attributes; ++a) { s += "    v.a" + std::to_string(a) + " = float4(" + std::to_string(a + 1) + ", 0, 0, 0);\n"; }
	s += "    m.set_vertex(i, v); }\n";
	s += "  for (uint p = 0; p < " + N + "; ++p) { m.set_index(3 * p, p % " + unique + "); m.set_index(3 * p + 1, " + std::to_string(vertices - 2) + "); m.set_index(3 * p + 2, " + std::to_string(vertices - 1) + ");";
	s += " P prim; prim.id = p;";
	if (layers > 1) { s += " prim.layer = p % " + std::to_string(layers) + ";"; }
	s += " m.set_primitive(p, prim);";
	s += " }\n}\n";
	// The fragment reads every attribute, so that none can be eliminated, and reports per primitive.
	s += "struct FA { float4 position [[position]]; uint id [[user(pid)]] [[flat]];";
	for (uint32_t a = 0; a < attributes; ++a) { s += " float4 a" + std::to_string(a) + " [[user(locn" + std::to_string(a) + ")]];"; }
	s += " };\nfragment float4 fragmentMain(FA in [[stage_in]], device atomic_uint* flags [[buffer(0)]]) { uint prim = in.id; float sum = 0;";
	for (uint32_t a = 0; a < attributes; ++a) { s += " sum += in.a" + std::to_string(a) + ".x;"; }
	s += " bool ok = abs(sum - " + std::to_string(attributes * (attributes + 1) / 2) + ".0) < 0.01;";
	s += " atomic_fetch_or_explicit(flags + min(prim, " + std::to_string(primitives) + "u), ok ? 1u : 2u, memory_order_relaxed); return float4(1, 0, 0, 1); }\n";
	id<MTLRenderPipelineState> state = pipeline(s, MTLPixelFormatRGBA32Float, o);
	if (!state) { return o; }
	id<MTLBuffer> flags = [device newBufferWithLength:4 * (primitives + 1) options:MTLResourceStorageModeShared];
	memset(flags.contents, 0, flags.length);
	id<MTLTexture> target = draw(state, MTLSizeMake(1, 1, 1), MTLSizeMake(1, 1, 1), nil, flags, side, side, layers, MTLPixelFormatRGBA32Float, o);
	if (!target) { return o; }
	const uint32_t* f = (const uint32_t*)flags.contents;
	uint32_t good = 0, wrong = 0, missing = 0;
	for (uint32_t p = 0; p < primitives; ++p) { good += f[p] == 1; wrong += (f[p] & 2) != 0; missing += f[p] == 0; }
	uint32_t emptyLayers = 0;
	for (uint32_t l = 0; l < layers; ++l) { emptyLayers += countCovered(target, side, side, l, 1) == 0; }
	o.correct = good == primitives && !f[primitives] && !emptyLayers;
	o.detail = "primitives_ok=" + std::to_string(good) + "/" + N + " wrong_values=" + std::to_string(wrong) + " missing=" + std::to_string(missing) + " out_of_range=" + std::to_string(f[primitives]) + (layers > 1 ? " empty_layers=" + std::to_string(emptyLayers) : "");
	return o;
}

static void report(const char* limit, const char* vulkanMinimum, const char* value, const Outcome& o) {
	std::printf("MESH_LIMIT %-34s vulkan_min=%-10s probe=%-24s created=%d executed=%d correct=%d max_threads=%lu max_grid=%lu %s %s\n", limit, vulkanMinimum, value,
				int(o.created), int(o.executed), int(o.correct), (unsigned long)o.maxThreads, (unsigned long)o.maxGrid, o.correct ? "MEETS" : "BELOW", o.detail.c_str());
}

int main() {
	@autoreleasepool {
		device = MTLCreateSystemDefaultDevice();
		if (!device || ![device supportsFamily:MTLGPUFamilyMetal3]) { std::printf("MESH_LIMITS no Metal 3 device\n"); return 1; }
		queue = [device newCommandQueue];
		std::printf("DEVICE=%s metal3=1 apple7=%d apple8=%d apple9=%d apple10=%d max_threadgroup_memory=%lu\n", device.name.UTF8String,
					int([device supportsFamily:MTLGPUFamilyApple7]), int([device supportsFamily:MTLGPUFamilyApple8]), int([device supportsFamily:MTLGPUFamilyApple9]),
					int([device supportsFamily:(MTLGPUFamily)1010]), (unsigned long)device.maxThreadgroupMemoryLength);
		// Workgroup size and invocations (Vulkan minimum 128, 128/128/128).
		report("maxMeshWorkGroupInvocations", "128", "128x1x1", countThreads(MTLSizeMake(1, 1, 1), MTLSizeMake(128, 1, 1), 0));
		report("maxMeshWorkGroupSize[1]", "128", "1x128x1", countThreads(MTLSizeMake(1, 1, 1), MTLSizeMake(1, 128, 1), 0));
		report("maxMeshWorkGroupSize[2]", "128", "1x1x128", countThreads(MTLSizeMake(1, 1, 1), MTLSizeMake(1, 1, 128), 0));
		// Workgroup counts (Vulkan minimum 65535 each, 2^22 in total).
		report("maxMeshWorkGroupCount[0]", "65535", "65535x1x1", countThreads(MTLSizeMake(65535, 1, 1), MTLSizeMake(1, 1, 1), 0));
		report("maxMeshWorkGroupCount[1]", "65535", "1x65535x1", countThreads(MTLSizeMake(1, 65535, 1), MTLSizeMake(1, 1, 1), 0));
		report("maxMeshWorkGroupCount[2]", "65535", "1x1x65535", countThreads(MTLSizeMake(1, 1, 65535), MTLSizeMake(1, 1, 1), 0));
		report("maxMeshWorkGroupTotalCount", "4194304", "4096x1024x1", countThreads(MTLSizeMake(4096, 1024, 1), MTLSizeMake(1, 1, 1), 0));
		// Shared memory (Vulkan minimum 28 KiB, also the payload-and-shared limit without task shaders).
		report("maxMeshSharedMemorySize", "28672", "7168 floats", countThreads(MTLSizeMake(1, 1, 1), MTLSizeMake(32, 1, 1), 7168));
		// Output vertices and primitives (Vulkan minimum 256 and 256).
		report("maxMeshOutputVertices+Primitives", "256/256", "256v 256p", renderPrimitives(256, 256, 0, 1));
		// Output components (Vulkan minimum 128): 32 float4 user outputs, read by the fragment.
		report("maxMeshOutputComponents", "128", "3v 1p 32xfloat4", renderPrimitives(3, 1, 32, 1));
		// Output memory (32 KiB): 248 vertices of position + 7 float4 (31,744 B) and 248 primitives of 4 B = 32,736 B.
		report("maxMeshOutputMemorySize", "32768", "248v 248p 8xfloat4", renderPrimitives(248, 248, 7, 1));
		// Output layers (Vulkan minimum 8): per-primitive render target array index over an 8-layer target.
		report("maxMeshOutputLayers", "8", "10v 8p 8 layers", renderPrimitives(10, 8, 0, 8));
		// Beyond the Vulkan minimums, informational: where Metal stops.
		report("info: 1024 invocations", "-", "1024x1x1", countThreads(MTLSizeMake(1, 1, 1), MTLSizeMake(1024, 1, 1), 0));
		// Where the total workgroup count stops executing: around the documented 1024 (Apple7, Apple8), 1,048,575 (Apple9)
		// and 4,194,303 (Apple10) threadgroups per mesh grid.
		for (MTLSize grid : {MTLSizeMake(2, 2, 1), MTLSizeMake(16, 16, 1), MTLSizeMake(256, 256, 1), MTLSizeMake(512, 512, 1), MTLSizeMake(32, 32, 1), MTLSizeMake(25, 41, 1), MTLSizeMake(1023, 1024, 1), MTLSizeMake(1023, 1025, 1), MTLSizeMake(1024, 1024, 1),
							 MTLSizeMake(2047, 2049, 1), MTLSizeMake(2048, 2048, 1),
							 MTLSizeMake(65535, 2, 1), MTLSizeMake(2, 65535, 1), MTLSizeMake(16, 16, 16), MTLSizeMake(64, 64, 64), MTLSizeMake(65535, 32, 1), MTLSizeMake(4096, 1024, 1)}) {
			std::string g = std::to_string(grid.width) + "x" + std::to_string(grid.height) + "x" + std::to_string(grid.depth);
			report("info: total count", "-", g.c_str(), countThreads(grid, MTLSizeMake(1, 1, 1), 0));
		}
		report("info: 33,792 B of mesh output", "-", "256v 256p 8xfloat4", renderPrimitives(256, 256, 7, 1));
		report("info: 257 vertices", "-", "257v 256p", renderPrimitives(257, 256, 0, 1));
		for (uint32_t k : {8u, 16u, 24u, 28u, 29u, 30u, 31u}) {
			std::string c = std::to_string(4 * k) + " components";
			report(("info: " + c).c_str(), "-", ("3v 1p " + std::to_string(k) + "xfloat4").c_str(), renderPrimitives(3, 1, k, 1));
		}
		for (int repeat = 0; repeat < 3; ++repeat) { report("info: 512 primitives", "-", "256v 512p", renderPrimitives(256, 512, 0, 1)); }
		std::printf("MESH_LIMITS DONE\n");
	}
	return 0;
}
