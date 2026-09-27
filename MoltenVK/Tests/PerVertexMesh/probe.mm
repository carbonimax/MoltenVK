// Copyright 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
// Metal mesh probe for PerVertexKHR on the running GPU. Renders the probe.metal mesh (four vertices, two triangles
// (0,1,2) and (3,2,1)) with several fragments and checks every pixel away from edges against a CPU model:
// connectivity (which triangle covers the pixel), interpolated values, the per-primitive corner copies in index
// order, their consistency with [[barycentric_coord]], and [[primitive_id]]. A swapped-corner fragment must fail.
// The MSL 4 vertex_value fragment must work on Apple10 GPUs; elsewhere it must be refused or wrong (negative
// control). With --spvc, the same checks run on the SPIRV-Cross translation of mesh.mesh and its fragments.
// Usage: probe <output-dir> <probe.metal> <probe-vertex-value.metal> [--spvc <mesh.metal> <interp.metal> <native.metal>]
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <array>
#include <cmath>
#include <cstdio>
#include <fstream>
#include <string>
#include <vector>

static constexpr int kSize = 64;
static const float kPositions[4][2] = {{-0.75f, -0.75f}, {0.75f, -0.75f}, {-0.75f, 0.75f}, {0.75f, 0.75f}};
static const float kColors[4][3] = {{0.8f, 0.1f, 0.2f}, {0.1f, 0.7f, 0.3f}, {0.2f, 0.3f, 0.9f}, {0.6f, 0.5f, 0.4f}};
static const int kTriangles[2][3] = {{0, 1, 2}, {3, 2, 1}};

static int failures = 0;
static void verdict(bool ok, const std::string& what) { std::printf("  %s %s\n", ok ? "ok  " : "FAIL", what.c_str()); failures += !ok; }

// Barycentrics of the pixel centre in triangle t, in index order, or false outside with a margin.
static bool barycentrics(int t, int x, int y, float margin, float lambda[3]) {
	float px = (x + 0.5f) / (kSize / 2) - 1, py = 1 - (y + 0.5f) / (kSize / 2);
	const float* a = kPositions[kTriangles[t][0]]; const float* b = kPositions[kTriangles[t][1]]; const float* c = kPositions[kTriangles[t][2]];
	float area = (b[0] - a[0]) * (c[1] - a[1]) - (c[0] - a[0]) * (b[1] - a[1]);
	lambda[0] = ((b[0] - px) * (c[1] - py) - (c[0] - px) * (b[1] - py)) / area;
	lambda[1] = ((c[0] - px) * (a[1] - py) - (a[0] - px) * (c[1] - py)) / area;
	lambda[2] = 1 - lambda[0] - lambda[1];
	return lambda[0] > margin && lambda[1] > margin && lambda[2] > margin;
}
static int triangleAt(int x, int y, float lambda[3]) {
	for (int t = 0; t < 2; ++t) if (barycentrics(t, x, y, 0.03f, lambda)) return t;
	return -1;
}
static bool outside(int x, int y) {
	float px = (x + 0.5f) / (kSize / 2) - 1, py = 1 - (y + 0.5f) / (kSize / 2);
	return std::fabs(px) > 0.8f || std::fabs(py) > 0.8f;
}

struct Image { std::vector<uint8_t> rgba; std::string error; };

static Image render(id<MTLDevice> device, id<MTLFunction> meshFunction, id<MTLFunction> fragmentFunction, NSUInteger meshThreads, const std::string& output) {
	Image image;
	NSError* error = nil;
	MTLMeshRenderPipelineDescriptor* descriptor = [MTLMeshRenderPipelineDescriptor new];
	descriptor.meshFunction = meshFunction;
	descriptor.fragmentFunction = fragmentFunction;
	descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
	id<MTLRenderPipelineState> state = [device newRenderPipelineStateWithMeshDescriptor:descriptor options:MTLPipelineOptionNone reflection:nil error:&error];
	if (!state) { image.error = error ? error.localizedDescription.UTF8String : "no pipeline"; return image; }
	MTLTextureDescriptor* textureDescriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:kSize height:kSize mipmapped:NO];
	textureDescriptor.usage = MTLTextureUsageRenderTarget;
	textureDescriptor.storageMode = MTLStorageModePrivate;
	id<MTLTexture> texture = [device newTextureWithDescriptor:textureDescriptor];
	id<MTLBuffer> readback = [device newBufferWithLength:kSize * kSize * 4 options:MTLResourceStorageModeShared];
	id<MTLCommandQueue> queue = [device newCommandQueue];
	id<MTLCommandBuffer> commands = [queue commandBuffer];
	MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
	pass.colorAttachments[0].texture = texture;
	pass.colorAttachments[0].loadAction = MTLLoadActionClear;
	pass.colorAttachments[0].storeAction = MTLStoreActionStore;
	pass.colorAttachments[0].clearColor = MTLClearColorMake(1, 0, 1, 1);
	id<MTLRenderCommandEncoder> encoder = [commands renderCommandEncoderWithDescriptor:pass];
	[encoder setRenderPipelineState:state];
	[encoder drawMeshThreadgroups:MTLSizeMake(1, 1, 1) threadsPerObjectThreadgroup:MTLSizeMake(1, 1, 1) threadsPerMeshThreadgroup:MTLSizeMake(meshThreads, 1, 1)];
	[encoder endEncoding];
	id<MTLBlitCommandEncoder> blit = [commands blitCommandEncoder];
	[blit copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(kSize, kSize, 1) toBuffer:readback destinationOffset:0 destinationBytesPerRow:kSize * 4 destinationBytesPerImage:kSize * kSize * 4];
	[blit endEncoding];
	[commands commit];
	[commands waitUntilCompleted];
	if (commands.status != MTLCommandBufferStatusCompleted) { image.error = commands.error ? commands.error.localizedDescription.UTF8String : "command buffer failed"; return image; }
	auto* bytes = static_cast<const uint8_t*>(readback.contents);
	image.rgba.assign(bytes, bytes + kSize * kSize * 4);
	std::ofstream(output, std::ios::binary).write(reinterpret_cast<const char*>(image.rgba.data()), image.rgba.size());
	return image;
}

// Compares each pixel away from edges with expected(t, lambda) (RGB in [0,1]); outside pixels must keep the clear.
template <typename Expected>
static void compare(const Image& image, const std::string& name, float tolerance, Expected expected, int* mismatchOut = nullptr) {
	if (!image.error.empty()) { verdict(false, name + ": " + image.error); return; }
	int checked = 0, mismatch = 0, background = 0;
	for (int y = 0; y < kSize; ++y) for (int x = 0; x < kSize; ++x) {
		const uint8_t* p = &image.rgba[4 * (y * kSize + x)];
		float lambda[3];
		int t = triangleAt(x, y, lambda);
		if (t < 0) {
			if (outside(x, y)) background += !(p[0] == 255 && p[1] == 0 && p[2] == 255);
			continue;
		}
		std::array<float, 3> e = expected(t, lambda);
		++checked;
		bool bad = false;
		for (int k = 0; k < 3; ++k) bad |= std::fabs(p[k] / 255.0f - e[k]) > tolerance;
		mismatch += bad;
	}
	if (mismatchOut) { *mismatchOut = mismatch; std::printf("  %s: checked=%d mismatch=%d background_changed=%d\n", name.c_str(), checked, mismatch, background); return; }
	verdict(checked > 0 && mismatch == 0 && background == 0, name + ": checked=" + std::to_string(checked) + " mismatch=" + std::to_string(mismatch) + " background_changed=" + std::to_string(background));
}

static std::array<float, 3> interpolated(int t, const float lambda[3]) {
	std::array<float, 3> e{};
	for (int c = 0; c < 3; ++c) for (int k = 0; k < 3; ++k) e[k] += lambda[c] * kColors[kTriangles[t][c]][k];
	return e;
}
static std::array<float, 3> ordered(int t, const float*) {
	std::array<float, 3> e{};
	const float w[3] = {0.2f, 0.3f, 0.5f};
	for (int c = 0; c < 3; ++c) for (int k = 0; k < 3; ++k) e[k] += w[c] * kColors[kTriangles[t][c]][k];
	return e;
}

static id<MTLLibrary> library(id<MTLDevice> device, const char* path, MTLLanguageVersion version, std::string& error) {
	NSError* nsError = nil;
	NSString* source = [NSString stringWithContentsOfFile:[NSString stringWithUTF8String:path] encoding:NSUTF8StringEncoding error:&nsError];
	if (!source) { error = "cannot read " + std::string(path); return nil; }
	MTLCompileOptions* options = [MTLCompileOptions new];
	options.languageVersion = version;
	id<MTLLibrary> result = [device newLibraryWithSource:source options:options error:&nsError];
	if (!result) error = nsError ? nsError.localizedDescription.UTF8String : "compile failed";
	return result;
}

int main(int argc, char** argv) {
	@autoreleasepool {
		if (argc != 4 && argc != 8) { std::fprintf(stderr, "Usage: probe <output-dir> <probe.metal> <probe-vertex-value.metal> [--spvc <mesh.metal> <interp.metal> <native.metal>]\n"); return 1; }
		std::string out = argv[1];
		id<MTLDevice> device = MTLCreateSystemDefaultDevice();
		const bool nativePerVertex = [device supportsFamily:MTLGPUFamilyApple10];
		// Native per-vertex inputs: correct on Apple10, refused or wrong elsewhere.
		auto native = [&](const Image& image, const std::string& name) {
			int mismatch = 0;
			if (image.error.empty()) compare(image, name, 1.0f / 255, ordered, &mismatch);
			if (nativePerVertex) verdict(image.error.empty() && mismatch == 0, name + ": correct on Apple10");
			else verdict(!image.error.empty() || mismatch > 0, name + ": unusable without Apple10 (" + (image.error.empty() ? "pipeline created, values wrong" : "refused: " + image.error) + ")");
		};
		std::printf("DEVICE=%s apple7=%d apple9=%d apple10=%d metal3=%d metal4=%d barycentric=%d\n", device.name.UTF8String,
		            [device supportsFamily:MTLGPUFamilyApple7], [device supportsFamily:MTLGPUFamilyApple9], [device supportsFamily:MTLGPUFamilyApple10],
		            [device supportsFamily:MTLGPUFamilyMetal3], [device supportsFamily:MTLGPUFamilyMetal4], device.supportsShaderBarycentricCoordinates);

		std::printf("A. handwritten MSL 3.0 mesh, per-primitive corner copies\n");
		std::string error;
		id<MTLLibrary> probe = library(device, argv[2], MTLLanguageVersion3_0, error);
		if (!probe) { verdict(false, "probe.metal compiles: " + error); return 2; }
		id<MTLFunction> mesh = [probe newFunctionWithName:@"probeMesh"];
		auto fragment = [&](const char* name) { return [probe newFunctionWithName:[NSString stringWithUTF8String:name]]; };
		Image tag = render(device, mesh, fragment("probeTag"), 4, out + "/tag.rgba");
		compare(tag, "connectivity: each pixel covered by its CPU triangle, background kept", 1.0f / 255, [](int t, const float*) { return t ? std::array<float, 3>{1, 0, 0.5f} : std::array<float, 3>{0, 1, 0.5f}; });
		Image interp = render(device, mesh, fragment("probeInterp"), 4, out + "/interp.rgba");
		compare(interp, "interpolated per-vertex value matches the CPU model", 2.0f / 255, interpolated);
		Image corners = render(device, mesh, fragment("probeOrdered"), 4, out + "/ordered.rgba");
		compare(corners, "per-primitive corner copies arrive in index order", 1.0f / 255, ordered);
		int swappedMismatch = 0;
		Image swapped = render(device, mesh, fragment("probeSwapped"), 4, out + "/swapped.rgba");
		compare(swapped, "negative control: swapped corners", 1.0f / 255, ordered, &swappedMismatch);
		verdict(swapped.error.empty() && swappedMismatch > 0, "negative control: swapped corners fail the model");
		Image consistency = render(device, mesh, fragment("probeConsistency"), 4, out + "/consistency.rgba");
		compare(consistency, "[[barycentric_coord]] weights the corner copies to the interpolated value", 0, [](int, const float*) { return std::array<float, 3>{0, 1, 0}; });
		Image bary = render(device, mesh, fragment("probeBarycentric"), 4, out + "/barycentric.rgba");
		compare(bary, "[[barycentric_coord]] components follow index order", 2.0f / 255, [](int, const float* lambda) { return std::array<float, 3>{lambda[0], lambda[1], lambda[2]}; });
		Image primitive = render(device, mesh, fragment("probePrimitiveId"), 4, out + "/primitive-id.rgba");
		compare(primitive, "[[primitive_id]] is the mesh primitive index", 0.5f / 255, [](int t, const float*) { return std::array<float, 3>{t / 255.0f, 0, 0}; });

		std::printf("A'. MSL 4.0 vertex_value fragment (native PerVertexKHR)\n");
		id<MTLLibrary> nativeLibrary = library(device, argv[3], MTLLanguageVersion4_0, error);
		if (!nativeLibrary) native(Image{{}, "library: " + error}, "vertex_value");
		else native(render(device, [nativeLibrary newFunctionWithName:@"probeMesh"], [nativeLibrary newFunctionWithName:@"probeVertexValue"], 4, out + "/vertex-value.rgba"), "vertex_value");

		if (argc == 8) {
			std::printf("B. SPIRV-Cross translation of mesh.mesh\n");
			id<MTLLibrary> spvcMesh = library(device, argv[5], MTLLanguageVersion3_0, error);
			if (!spvcMesh) { verdict(false, "translated mesh compiles: " + error); }
			id<MTLLibrary> spvcInterp = library(device, argv[6], MTLLanguageVersion3_0, error);
			if (!spvcInterp) { verdict(false, "translated fragment compiles: " + error); }
			if (spvcMesh && spvcInterp) {
				Image translated = render(device, [spvcMesh newFunctionWithName:@"main0"], [spvcInterp newFunctionWithName:@"main0"], 4, out + "/spvc-interp.rgba");
				compare(translated, "translated mesh: interpolated values match the CPU model", 2.0f / 255, interpolated);
				verdict(translated.error.empty() && translated.rgba == interp.rgba, "translated mesh image identical to the handwritten mesh image");
			}
			id<MTLLibrary> spvcNative = library(device, argv[7], MTLLanguageVersion4_0, error);
			if (!spvcNative) native(Image{{}, "library: " + error}, "translated native PerVertex fragment");
			else if (spvcMesh) native(render(device, [spvcMesh newFunctionWithName:@"main0"], [spvcNative newFunctionWithName:@"main0"], 4, out + "/spvc-native.rgba"), "translated native PerVertex fragment");
		}
		std::printf("MESH_PROBE %s: %d failure(s)\n", failures ? "FAIL" : "PASS", failures);
		return failures ? 2 : 0;
	}
}
