// Copyright 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
// Vulkan oracles for the first MoltenVK mesh path (VK_EXT_mesh_shader behind the test device adapter): a mesh
// shader and a fragment shader, no task shader, drawn with vkCmdDrawMeshTasksEXT. The mesh is the Metal probe's:
// four vertices with distinct values and triangles (0,1,2), (3,2,1). Every pixel away from edges must match a CPU
// model of the Vulkan rasterization (y down), outside pixels must keep the clear, and the refused forms must fail
// deterministically. The shipping library must expose neither the extension nor the feature.
// PerVertexKHR scenarios read the three corners of each triangle in index order: each image must match its own model
// and differ from a rival model (swapped weights, or the other index order) on at least 90% of the checked pixels.
// The form-* scenarios (forms.mesh, forms.frag) render into a 128-bit integer target and compare every checked pixel
// bit for bit with the folded corner values; each must also differ, on at least 90% of the checked pixels, from a
// rival with the corners rotated, from a rival with the values degraded as a type error would (32-bit integers
// through float, floats through half, half bits read as an integer, 16-bit integers with the other extension) and,
// on two workgroups, from a rival where each workgroup reads the other's values.
// The resource-* scenarios (forms.mesh with RESOURCE, resource.frag) check the fragment resources of a PerVertexKHR mesh
// pipeline the same way: a table read through a buffer device address from the push constants, a storage buffer from a
// descriptor set and a push constant salt, each indexed by the PerVertexKHR corners. resource-bda-other pushes the
// address of another table and must read it. resource-unresident is an opt-in witness with invalid usage, run only on
// request: it reads a table created without device address usage, which MoltenVK never makes resident, and reports
// whether its absence is visible.
// Usage: mesh-draw <shader-dir> <scenario>
//   draw | grid | twice | pervertex | pervertex-swapped | pervertex-permuted | pervertex-block-output | barycentric
//   | barycentric-permuted
//   | pervertex-consistency | form-uint | form-swapped | form-ivec2 | form-vec3 | form-uvec3 | form-components
//   | form-fewer | form-scalar | form-array1 | form-array2 | form-half | form-int16 | form-uint16 | form-mixed
//   | form-grid | resource-bda | resource-bda-other | resource-unresident | model-check | reject-task | reject-descriptor | reject-per-primitive | reject-pervertex-block
//   | reject-pervertex-matrix | reject-specialization | reject-indirect | reject-grid-limit | reject-draw-id | reject-draw-id-uint
//   | reject-buffer-address | no-adapter | public-device-gate
// The refusal scenarios only create pipelines: nothing they build is ever submitted.
#define VK_ENABLE_BETA_EXTENSIONS 1
#include <vulkan/vulkan.h>

#include <array>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <stdexcept>
#include <string>
#include <vector>

extern "C" void mvkEnableMeshTestDevice(VkPhysicalDevice device) __attribute__((weak_import));
extern "C" void mvkEnableTESFixtureDevice(VkPhysicalDevice device) __attribute__((weak_import));

static void check(VkResult result, const char* operation) {
	if (result != VK_SUCCESS) throw std::runtime_error(std::string(operation) + ": " + std::to_string(result));
}

static std::vector<uint32_t> readSpirv(const std::string& path) {
	std::ifstream file(path, std::ios::binary | std::ios::ate);
	if (!file) throw std::runtime_error("Cannot open " + path);
	auto size = file.tellg();
	std::vector<uint32_t> words(size_t(size) / 4);
	file.seekg(0);
	file.read(reinterpret_cast<char*>(words.data()), size);
	return words;
}

static bool hasExtension(VkPhysicalDevice physical, const char* name) {
	uint32_t count = 0;
	vkEnumerateDeviceExtensionProperties(physical, nullptr, &count, nullptr);
	std::vector<VkExtensionProperties> extensions(count);
	vkEnumerateDeviceExtensionProperties(physical, nullptr, &count, extensions.data());
	for (const auto& extension : extensions) if (!strcmp(extension.extensionName, name)) return true;
	return false;
}

static constexpr uint32_t kSize = 64;
static const float kPositions[4][2] = {{-0.75f, -0.75f}, {0.75f, -0.75f}, {-0.75f, 0.75f}, {0.75f, 0.75f}};
static const float kColors[4][3] = {{0.8f, 0.1f, 0.2f}, {0.1f, 0.7f, 0.3f}, {0.2f, 0.3f, 0.9f}, {0.6f, 0.5f, 0.4f}};
static const int kTriangles[2][3] = {{0, 1, 2}, {3, 2, 1}};
static const int kPermuted[2][3] = {{1, 2, 0}, {2, 1, 3}};  // The same triangles, index order rotated.

// Interpolated: the per-vertex colours weighted by the barycentrics. Ordered and Swapped: the corners in index order
// weighted by 0.2, 0.3, 0.5 and 0.3, 0.2, 0.5. Barycentric: the barycentrics themselves, in index order.
enum Model { None, Interpolated, Ordered, Swapped, Barycentric };

// Finds the triangle whose interior holds the pixel centre, away from its edges: its workgroup, its corners in index
// order (workgroups whose bit is set in permutedGroups use kPermuted) and their barycentrics. Returns false near an
// edge or outside; outside is set for pixels that must keep the clear.
static bool locate(int x, int y, uint32_t groups, uint32_t permutedGroups, uint32_t& group, const int*& corners, float lambda[3], bool& outside) {
	float px = (x + 0.5f) / (kSize / 2) - 1, py = (y + 0.5f) / (kSize / 2) - 1;  // Vulkan framebuffer: y down.
	outside = true;
	for (uint32_t g = 0; g < groups; ++g) {
		const auto& triangles = (permutedGroups >> g) & 1 ? kPermuted : kTriangles;
		float scale = groups == 1 ? 1.0f : 0.5f, offset = groups == 1 ? 0.0f : (g ? 0.5f : -0.5f);
		float left = -0.75f * scale + offset, right = 0.75f * scale + offset;
		if (px > left - 0.05f && px < right + 0.05f && std::fabs(py) < 0.8f) outside = false;
		for (int t = 0; t < 2; ++t) {
			float v[3][2];
			for (int c = 0; c < 3; ++c) { v[c][0] = kPositions[triangles[t][c]][0] * scale + offset; v[c][1] = kPositions[triangles[t][c]][1]; }
			float area = (v[1][0] - v[0][0]) * (v[2][1] - v[0][1]) - (v[2][0] - v[0][0]) * (v[1][1] - v[0][1]);
			float l0 = ((v[1][0] - px) * (v[2][1] - py) - (v[2][0] - px) * (v[1][1] - py)) / area;
			float l1 = ((v[2][0] - px) * (v[0][1] - py) - (v[0][0] - px) * (v[2][1] - py)) / area;
			float l2 = 1 - l0 - l1, margin = 0.04f;
			if (l0 > margin && l1 > margin && l2 > margin) {
				group = g;
				corners = triangles[t];
				lambda[0] = l0;
				lambda[1] = l1;
				lambda[2] = l2;
				return true;
			}
		}
	}
	return false;
}

// Expected colour of the pixel centre, or false near an edge; outside is set for pixels that must keep the clear.
static bool expected(int x, int y, uint32_t groups, Model model, bool permuted, float rgb[3], bool& outside) {
	static const float kOrdered[3] = {0.2f, 0.3f, 0.5f}, kSwapped[3] = {0.3f, 0.2f, 0.5f};
	uint32_t group = 0;
	const int* corners = nullptr;
	float lambda[3];
	if (!locate(x, y, groups, permuted ? ~0u : 0u, group, corners, lambda, outside)) return false;
	const float* weights = model == Ordered ? kOrdered : model == Swapped ? kSwapped : lambda;
	for (int k = 0; k < 3; ++k) {
		rgb[k] = model == Barycentric ? lambda[k] : 0;
		for (int c = 0; c < 3 && model != Barycentric; ++c) rgb[k] += weights[c] * kColors[corners[c]][k];
	}
	return true;
}

// The scalars of forms.mesh, as the fragment turns them into 32-bit patterns: n = vertex + 1 + 4 * workgroup,
// k = 8 * Location + Component. degrade applies the conversion a type error would: 32-bit integers through float,
// floats through half, half bits read as an integer, 16-bit integers with the other extension.
enum Kind { U32, I32, F32, F16, I16, U16 };
static uint32_t floatBits(float value) { uint32_t bits; memcpy(&bits, &value, 4); return bits; }
static uint32_t scalarBits(Kind kind, uint32_t n, uint32_t k, bool degrade) {
	switch (kind) {
		case U32: { uint32_t v = n * 0x9E3779B9u + k * 0x01000193u; return degrade ? uint32_t(uint64_t(float(v))) : v; }
		case I32: { int32_t v = -int32_t(n * 0x01000193u) - int32_t(k); return uint32_t(degrade ? int32_t(float(v)) : v); }
		case F32: { float v = float(n) + float(k) * 0.25f + float(n) * 0.0009765625f; return floatBits(degrade ? float(_Float16(v)) : v); }
		case F16: {
			_Float16 v = _Float16(float(n) + float(k) * 0.25f);
			uint16_t bits;
			memcpy(&bits, &v, 2);
			return degrade ? bits : floatBits(float(v));
		}
		case I16: { int16_t v = int16_t(-1000 * int32_t(n) - int32_t(k)); return degrade ? uint32_t(uint16_t(v)) : uint32_t(int32_t(v)); }
		case U16: { uint16_t v = uint16_t(0x8000u + n * 0x111u + k); return degrade ? uint32_t(int32_t(int16_t(v))) : uint32_t(v); }
	}
	return 0;
}

// A form reads count scalars of kind from each Read, in this order, and folds them per corner as forms.frag does.
struct Read { uint32_t location, component, count; Kind kind; };
struct Form { const char *name, *mesh, *fragment; uint32_t corners; std::vector<Read> reads; bool swapped, grid; };
static const uint32_t kTag = 0x600DF00Du, kClear = 0xDEADBEEFu;
static uint32_t fold(const Form& form, uint32_t n, bool degrade) {
	uint32_t h = 0;
	for (const auto& read : form.reads) {
		for (uint32_t c = 0; c < read.count; ++c) h = ((h << 5) | (h >> 27)) ^ scalarBits(read.kind, n, 8 * read.location + read.component + c, degrade);
	}
	return h;
}
// The form-* scenarios; reads follow the fold order of forms.frag.
static const std::vector<Form> kForms = {
	{"form-uint", "forms.mesh.spv", "form-uint.frag.spv", 3, {{0, 0, 1, U32}}, false, false},
	{"form-swapped", "forms.mesh.spv", "form-swapped.frag.spv", 3, {{0, 0, 1, U32}}, true, false},
	{"form-ivec2", "forms.mesh.spv", "form-ivec2.frag.spv", 3, {{1, 0, 2, I32}}, false, false},
	{"form-vec3", "forms.mesh.spv", "form-vec3.frag.spv", 3, {{2, 0, 3, F32}}, false, false},
	{"form-uvec3", "forms.mesh.spv", "form-uvec3.frag.spv", 3, {{5, 0, 3, U32}}, false, false},
	{"form-components", "forms.mesh.spv", "form-components.frag.spv", 3, {{3, 0, 1, F32}, {3, 1, 2, F32}, {3, 3, 1, F32}}, false, false},
	{"form-fewer", "forms.mesh.spv", "form-fewer.frag.spv", 3, {{4, 0, 2, F32}}, false, false},
	{"form-scalar", "forms.mesh.spv", "form-scalar.frag.spv", 3, {{6, 0, 1, F32}}, false, false},
	{"form-array1", "forms.mesh.spv", "form-array1.frag.spv", 1, {{6, 0, 1, F32}}, false, false},
	{"form-array2", "forms.mesh.spv", "form-array2.frag.spv", 2, {{6, 0, 1, F32}}, false, false},
	{"form-half", "forms16.mesh.spv", "form-half.frag.spv", 3, {{7, 2, 2, F16}}, false, false},
	{"form-int16", "forms16.mesh.spv", "form-int16.frag.spv", 3, {{8, 0, 3, I16}}, false, false},
	{"form-uint16", "forms16.mesh.spv", "form-uint16.frag.spv", 3, {{30, 0, 1, U16}}, false, false},
	{"form-mixed", "forms.mesh.spv", "form-mixed.frag.spv", 3, {{0, 0, 1, U32}, {2, 0, 3, F32}, {3, 0, 1, F32}, {3, 1, 2, F32}, {3, 3, 1, F32}, {6, 0, 1, F32}}, false, false},
	{"form-grid", "forms-grid.mesh.spv", "form-mixed.frag.spv", 3, {{0, 0, 1, U32}, {2, 0, 3, F32}, {3, 0, 1, F32}, {3, 1, 2, F32}, {3, 3, 1, F32}, {6, 0, 1, F32}}, false, true},
};

// Expected pixel for the triangle corners of a workgroup: order selects which corner each output word holds.
static void formExpected(const Form& form, uint32_t group, const int* corners, const int order[3], bool degrade, bool otherGroup, uint32_t out[4]) {
	uint32_t g = otherGroup ? group ^ 1 : group;
	for (uint32_t j = 0; j < 3; ++j) out[j] = j < form.corners ? fold(form, uint32_t(corners[order[j]]) + 1 + 4 * g, degrade) : 0;
	out[3] = kTag;
}

// Fragment resources of resource.frag: value(tag, i) fills entry i of a buffer, with tags A for the pushed table,
// B for another addressable table, C for the storage buffer and D for the table without device address usage.
static uint32_t resourceValue(uint32_t tag, uint32_t i) { return tag ? (tag << 28 | (i + 1) * 0x00012345u) : 0; }
static const uint32_t kSalt = 0x5A17C0DEu;
struct Resource { const char* name; uint32_t table, rival; bool unresident; };
static const std::vector<Resource> kResources = {
	{"resource-bda", 0xA, 0xB, false},
	{"resource-bda-other", 0xB, 0xA, false},
	{"resource-unresident", 0xD, 0xA, true},
};
static void resourceExpected(uint32_t table, uint32_t storage, uint32_t salt, const int* corners, const int order[3], uint32_t out[4]) {
	for (uint32_t j = 0; j < 3; ++j) out[j] = resourceValue(table, uint32_t(corners[order[j]]));
	out[3] = resourceValue(storage, uint32_t(corners[order[2]])) ^ salt;
}

// Compares a resource-* image with its model and with rivals that must each match at most 10% of the checked pixels:
// rotated corners, the other table, resources read as zeros, and a missing push constant salt. A null image checks
// that the model tells its rivals apart.
static bool checkResource(const Resource& resource, const uint32_t* image) {
	static const int kOrder[3] = {0, 1, 2}, kRotate[3] = {1, 2, 0};
	uint32_t checked = 0, mismatch = 0, background = 0, rivals[4] = {};
	for (uint32_t y = 0; y < kSize; ++y) for (uint32_t x = 0; x < kSize; ++x) {
		uint32_t group = 0, want[4], rival[4][4];
		const int* corners = nullptr;
		float lambda[3];
		bool outside = false;
		const uint32_t* p = image ? &image[4 * (y * kSize + x)] : nullptr;
		if (!locate(int(x), int(y), 1, 0u, group, corners, lambda, outside)) {
			if (outside && p) background += p[0] != kClear || p[1] != kClear || p[2] != kClear || p[3] != kClear;
			continue;
		}
		++checked;
		resourceExpected(resource.table, 0xC, kSalt, corners, kOrder, want);
		resourceExpected(resource.table, 0xC, kSalt, corners, kRotate, rival[0]);
		resourceExpected(resource.rival, 0xC, kSalt, corners, kOrder, rival[1]);
		resourceExpected(0, 0, kSalt, corners, kOrder, rival[2]);
		resourceExpected(resource.table, 0xC, 0, corners, kOrder, rival[3]);
		if (!p) p = want;
		if (memcmp(p, want, sizeof(want)) && !mismatch++) {
			std::printf("  first mismatch at (%u,%u): got %08x %08x %08x %08x, expected %08x %08x %08x %08x\n", x, y, p[0], p[1], p[2], p[3], want[0], want[1], want[2], want[3]);
		}
		for (int r = 0; r < 4; ++r) rivals[r] += !memcmp(p, rival[r], sizeof(want));
	}
	bool pass = checked > 0 && !mismatch && !background;
	for (uint32_t matches : rivals) pass &= matches * 10 <= checked;
	std::printf("  %s exact resources: checked=%u mismatch=%u background_changed=%u rival_matches corner=%u other_table=%u zeros=%u no_salt=%u (at most %u)\n",
	            resource.name, checked, mismatch, background, rivals[0], rivals[1], rivals[2], rivals[3], checked / 10);
	return pass;
}

// Compares a form-* image with its model and with the rivals, which must each match at most 10% of the checked pixels.
// With a null image, compares the model with itself: the CPU check that every rival is told apart before any GPU run.
static bool checkForm(const Form& form, const uint32_t* image) {
	static const int kOrder[3] = {0, 1, 2}, kSwap[3] = {1, 0, 2}, kRotate[3] = {1, 2, 0};
	const int* order = form.swapped ? kSwap : kOrder;
	const int* rivalOrder = form.swapped ? kOrder : kRotate;
	uint32_t checked = 0, mismatch = 0, background = 0, cornerRival = 0, typeRival = 0, groupRival = 0;
	for (uint32_t y = 0; y < kSize; ++y) for (uint32_t x = 0; x < kSize; ++x) {
		uint32_t group = 0, want[4], rival[4];
		const int* corners = nullptr;
		float lambda[3];
		bool outside = false;
		const uint32_t* p = image ? &image[4 * (y * kSize + x)] : nullptr;
		if (!locate(int(x), int(y), form.grid ? 2 : 1, form.grid ? 2u : 0u, group, corners, lambda, outside)) {
			if (outside && p) background += p[0] != kClear || p[1] != kClear || p[2] != kClear || p[3] != kClear;
			continue;
		}
		++checked;
		formExpected(form, group, corners, order, false, false, want);
		if (!p) p = want;
		auto same = [&](const uint32_t* words) { return !memcmp(p, words, sizeof(want)); };
		if (!same(want) && !mismatch++) {
			std::printf("  first mismatch at (%u,%u): got %08x %08x %08x %08x, expected %08x %08x %08x %08x\n", x, y, p[0], p[1], p[2], p[3], want[0], want[1], want[2], want[3]);
		}
		formExpected(form, group, corners, rivalOrder, false, false, rival);
		cornerRival += same(rival);
		formExpected(form, group, corners, order, true, false, rival);
		typeRival += same(rival);
		if (form.grid) {
			formExpected(form, group, corners, order, false, true, rival);
			groupRival += same(rival);
		}
	}
	bool pass = checked > 0 && !mismatch && !background && cornerRival * 10 <= checked && typeRival * 10 <= checked && groupRival * 10 <= checked;
	std::printf("  %s exact corners: checked=%u mismatch=%u background_changed=%u rival_matches corner=%u type=%u group=%u (at most %u)\n",
	            form.name, checked, mismatch, background, cornerRival, typeRival, groupRival, checked / 10);
	return pass;
}

int main(int argc, char** argv) {
	try {
		if (argc != 3) throw std::runtime_error("Usage: mesh-draw <shader-dir> <scenario>");
		const std::string shaders = argv[1], scenario = argv[2];
		if (scenario == "model-check") {  // CPU only: no Vulkan instance, no GPU.
			bool pass = true;
			for (const auto& form : kForms) pass &= checkForm(form, nullptr);
			for (const auto& resource : kResources) pass &= checkResource(resource, nullptr);
			std::printf("MESH_DRAW %s model-check: %zu form and %zu resource models tell their rivals apart\n", pass ? "PASS" : "FAIL", kForms.size(), kResources.size());
			return pass ? 0 : 2;
		}
		const Form* form = nullptr;
		for (const auto& candidate : kForms) if (scenario == candidate.name) form = &candidate;
		const Resource* resource = nullptr;
		for (const auto& candidate : kResources) if (scenario == candidate.name) resource = &candidate;
		const bool exact = form || resource;
		VkApplicationInfo app{VK_STRUCTURE_TYPE_APPLICATION_INFO};
		app.pApplicationName = "PerVertexKHR mesh draw";
		app.apiVersion = VK_API_VERSION_1_3;
		VkInstanceCreateInfo instanceInfo{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
		instanceInfo.pApplicationInfo = &app;
		VkInstance instance = VK_NULL_HANDLE;
		check(vkCreateInstance(&instanceInfo, nullptr, &instance), "Create instance");
		uint32_t count = 1;
		VkPhysicalDevice physical = VK_NULL_HANDLE;
		vkEnumeratePhysicalDevices(instance, &count, &physical);
		if (!physical) throw std::runtime_error("No physical device");
		auto meshFeatureSupported = [&]() {
			VkPhysicalDeviceMeshShaderFeaturesEXT mesh{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MESH_SHADER_FEATURES_EXT};
			VkPhysicalDeviceFeatures2 features{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2};
			features.pNext = &mesh;
			vkGetPhysicalDeviceFeatures2(physical, &features);
			return mesh;
		};
		if (scenario == "public-device-gate" || scenario == "no-adapter") {
			auto mesh = meshFeatureSupported();
			bool closed = !hasExtension(physical, VK_EXT_MESH_SHADER_EXTENSION_NAME) && !mesh.meshShader && !mesh.taskShader;
			closed &= !hasExtension(physical, VK_KHR_FRAGMENT_SHADER_BARYCENTRIC_EXTENSION_NAME);
			if (scenario == "public-device-gate") closed &= !mvkEnableMeshTestDevice && !mvkEnableTESFixtureDevice;
			std::printf("MESH_DRAW %s %s: VK_EXT_mesh_shader, meshShader and VK_KHR_fragment_shader_barycentric closed%s\n", closed ? "PASS" : "FAIL", scenario.c_str(), scenario == "public-device-gate" ? ", test adapters absent" : " without the test adapters");
			return closed ? 0 : 2;
		}
		if (!mvkEnableMeshTestDevice || !mvkEnableTESFixtureDevice) throw std::runtime_error("Test device adapters were not linked");
		mvkEnableMeshTestDevice(physical);
		mvkEnableTESFixtureDevice(physical);  // Exposes VK_KHR_fragment_shader_barycentric, closed publicly.
		auto supported = meshFeatureSupported();
		const bool exposed = hasExtension(physical, VK_EXT_MESH_SHADER_EXTENSION_NAME);
		std::printf("VK_EXT_mesh_shader exposed=%d meshShader=%d taskShader=%d multiviewMeshShader=%d\n", exposed, supported.meshShader, supported.taskShader, supported.multiviewMeshShader);
		if (!exposed || !supported.meshShader) { std::printf("MESH_DRAW FAIL %s: VK_EXT_mesh_shader is not exposed through the test adapter\n", scenario.c_str()); return 2; }
		VkPhysicalDeviceMeshShaderPropertiesEXT meshProperties{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MESH_SHADER_PROPERTIES_EXT};
		VkPhysicalDeviceProperties2 properties{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2};
		properties.pNext = &meshProperties;
		vkGetPhysicalDeviceProperties2(physical, &properties);
		std::printf("DEVICE=%s maxMeshWorkGroupInvocations=%u maxMeshOutputVertices=%u maxMeshOutputPrimitives=%u maxMeshWorkGroupCount=(%u,%u,%u) maxMeshWorkGroupTotalCount=%u\n",
		            properties.properties.deviceName, meshProperties.maxMeshWorkGroupInvocations, meshProperties.maxMeshOutputVertices, meshProperties.maxMeshOutputPrimitives,
		            meshProperties.maxMeshWorkGroupCount[0], meshProperties.maxMeshWorkGroupCount[1], meshProperties.maxMeshWorkGroupCount[2], meshProperties.maxMeshWorkGroupTotalCount);

		VkPhysicalDeviceFragmentShaderBarycentricFeaturesKHR supportedBarycentric{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FRAGMENT_SHADER_BARYCENTRIC_FEATURES_KHR};
		VkPhysicalDeviceVulkan12Features supported12{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES};
		supported12.pNext = &supportedBarycentric;
		VkPhysicalDeviceVulkan11Features supported11{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES};
		supported11.pNext = &supported12;
		VkPhysicalDeviceFeatures2 supportedFeatures{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2};
		supportedFeatures.pNext = &supported11;
		vkGetPhysicalDeviceFeatures2(physical, &supportedFeatures);
		if (!supported11.shaderDrawParameters || !supported12.bufferDeviceAddress) throw std::runtime_error("shaderDrawParameters or bufferDeviceAddress unavailable");
		if (!hasExtension(physical, VK_KHR_FRAGMENT_SHADER_BARYCENTRIC_EXTENSION_NAME) || !supportedBarycentric.fragmentShaderBarycentric) throw std::runtime_error("fragmentShaderBarycentric unavailable through the test adapter");
		// The 16-bit forms need 16-bit stage I/O and arithmetic.
		const bool sixteen = supported11.storageInputOutput16 && supported12.shaderFloat16 && supportedFeatures.features.shaderInt16;
		if (form && !strcmp(form->mesh, "forms16.mesh.spv") && !sixteen) throw std::runtime_error("storageInputOutput16, shaderFloat16 or shaderInt16 unavailable");
		// gl_DrawID and device addresses must be legal in the device, so that only the mesh path refuses them.
		VkPhysicalDeviceFragmentShaderBarycentricFeaturesKHR enableBarycentric{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FRAGMENT_SHADER_BARYCENTRIC_FEATURES_KHR};
		enableBarycentric.fragmentShaderBarycentric = VK_TRUE;
		VkPhysicalDeviceVulkan12Features enable12{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES};
		enable12.bufferDeviceAddress = VK_TRUE;
		enable12.shaderFloat16 = sixteen;
		enable12.pNext = &enableBarycentric;
		VkPhysicalDeviceVulkan11Features enable11{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES};
		enable11.shaderDrawParameters = VK_TRUE;
		enable11.storageInputOutput16 = sixteen;
		VkPhysicalDeviceFeatures enableCore{};
		enableCore.shaderInt16 = sixteen;
		enable11.pNext = &enable12;
		VkPhysicalDeviceMeshShaderFeaturesEXT enableMesh{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MESH_SHADER_FEATURES_EXT};
		enableMesh.meshShader = VK_TRUE;
		enableMesh.pNext = &enable11;
		float priority = 1;
		VkDeviceQueueCreateInfo queueInfo{VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};
		queueInfo.queueCount = 1;
		queueInfo.pQueuePriorities = &priority;
		std::vector<const char*> extensions{VK_EXT_MESH_SHADER_EXTENSION_NAME, VK_KHR_FRAGMENT_SHADER_BARYCENTRIC_EXTENSION_NAME};
		if (hasExtension(physical, VK_KHR_PORTABILITY_SUBSET_EXTENSION_NAME)) extensions.push_back(VK_KHR_PORTABILITY_SUBSET_EXTENSION_NAME);
		VkDeviceCreateInfo deviceInfo{VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO};
		deviceInfo.pNext = &enableMesh;
		deviceInfo.pEnabledFeatures = &enableCore;
		deviceInfo.queueCreateInfoCount = 1;
		deviceInfo.pQueueCreateInfos = &queueInfo;
		deviceInfo.enabledExtensionCount = uint32_t(extensions.size());
		deviceInfo.ppEnabledExtensionNames = extensions.data();
		VkDevice device = VK_NULL_HANDLE;
		check(vkCreateDevice(physical, &deviceInfo, nullptr, &device), "Create device");
		VkQueue queue = VK_NULL_HANDLE;
		vkGetDeviceQueue(device, 0, 0, &queue);
		auto drawMeshTasks = reinterpret_cast<PFN_vkCmdDrawMeshTasksEXT>(vkGetDeviceProcAddr(device, "vkCmdDrawMeshTasksEXT"));
		auto drawMeshTasksIndirect = reinterpret_cast<PFN_vkCmdDrawMeshTasksIndirectEXT>(vkGetDeviceProcAddr(device, "vkCmdDrawMeshTasksIndirectEXT"));
		auto drawMeshTasksIndirectCount = reinterpret_cast<PFN_vkCmdDrawMeshTasksIndirectCountEXT>(vkGetDeviceProcAddr(device, "vkCmdDrawMeshTasksIndirectCountEXT"));
		if (!drawMeshTasks || !drawMeshTasksIndirect || !drawMeshTasksIndirectCount) throw std::runtime_error("Mesh draw entry points do not resolve");

		auto memoryType = [&](uint32_t bits, VkMemoryPropertyFlags flags) {
			VkPhysicalDeviceMemoryProperties memory{};
			vkGetPhysicalDeviceMemoryProperties(physical, &memory);
			for (uint32_t i = 0; i < memory.memoryTypeCount; ++i) if ((bits & (1u << i)) && (memory.memoryTypes[i].propertyFlags & flags) == flags) return i;
			throw std::runtime_error("No memory type");
		};
		VkBufferCreateInfo bufferInfo{VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO};
		const uint32_t pixelBytes = exact ? 16 : 4;
		bufferInfo.size = kSize * kSize * 16;
		bufferInfo.usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT | VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT;
		VkBuffer readback = VK_NULL_HANDLE;
		check(vkCreateBuffer(device, &bufferInfo, nullptr, &readback), "Create buffer");
		VkMemoryRequirements requirements{};
		vkGetBufferMemoryRequirements(device, readback, &requirements);
		VkMemoryAllocateInfo allocation{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
		allocation.allocationSize = requirements.size;
		allocation.memoryTypeIndex = memoryType(requirements.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
		VkDeviceMemory readbackMemory = VK_NULL_HANDLE;
		check(vkAllocateMemory(device, &allocation, nullptr, &readbackMemory), "Allocate buffer");
		check(vkBindBufferMemory(device, readback, readbackMemory, 0), "Bind buffer");
		void* mapped = nullptr;
		check(vkMapMemory(device, readbackMemory, 0, VK_WHOLE_SIZE, 0, &mapped), "Map buffer");

		VkImageCreateInfo imageInfo{VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO};
		imageInfo.imageType = VK_IMAGE_TYPE_2D;
		imageInfo.format = exact ? VK_FORMAT_R32G32B32A32_UINT : VK_FORMAT_R8G8B8A8_UNORM;
		imageInfo.extent = {kSize, kSize, 1};
		imageInfo.mipLevels = imageInfo.arrayLayers = 1;
		imageInfo.samples = VK_SAMPLE_COUNT_1_BIT;
		imageInfo.usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
		VkImage image = VK_NULL_HANDLE;
		check(vkCreateImage(device, &imageInfo, nullptr, &image), "Create image");
		vkGetImageMemoryRequirements(device, image, &requirements);
		allocation.allocationSize = requirements.size;
		allocation.memoryTypeIndex = memoryType(requirements.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
		VkDeviceMemory imageMemory = VK_NULL_HANDLE;
		check(vkAllocateMemory(device, &allocation, nullptr, &imageMemory), "Allocate image");
		check(vkBindImageMemory(device, image, imageMemory, 0), "Bind image");
		VkImageViewCreateInfo viewInfo{VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO};
		viewInfo.image = image;
		viewInfo.viewType = VK_IMAGE_VIEW_TYPE_2D;
		viewInfo.format = imageInfo.format;
		viewInfo.subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
		VkImageView view = VK_NULL_HANDLE;
		check(vkCreateImageView(device, &viewInfo, nullptr, &view), "Create view");
		VkAttachmentDescription attachment{};
		attachment.format = imageInfo.format;
		attachment.samples = VK_SAMPLE_COUNT_1_BIT;
		attachment.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR;
		attachment.storeOp = VK_ATTACHMENT_STORE_OP_STORE;
		attachment.finalLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
		VkAttachmentReference reference{0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};
		VkSubpassDescription subpass{};
		subpass.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS;
		subpass.colorAttachmentCount = 1;
		subpass.pColorAttachments = &reference;
		VkRenderPassCreateInfo passInfo{VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO};
		passInfo.attachmentCount = 1;
		passInfo.pAttachments = &attachment;
		passInfo.subpassCount = 1;
		passInfo.pSubpasses = &subpass;
		VkRenderPass renderPass = VK_NULL_HANDLE;
		check(vkCreateRenderPass(device, &passInfo, nullptr, &renderPass), "Create render pass");
		VkFramebufferCreateInfo framebufferInfo{VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO};
		framebufferInfo.renderPass = renderPass;
		framebufferInfo.attachmentCount = 1;
		framebufferInfo.pAttachments = &view;
		framebufferInfo.width = framebufferInfo.height = kSize;
		framebufferInfo.layers = 1;
		VkFramebuffer framebuffer = VK_NULL_HANDLE;
		check(vkCreateFramebuffer(device, &framebufferInfo, nullptr, &framebuffer), "Create framebuffer");

		VkDescriptorSetLayoutBinding uniform{0, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 1, VK_SHADER_STAGE_MESH_BIT_EXT, nullptr};
		VkDescriptorSetLayoutCreateInfo setLayoutInfo{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO};
		setLayoutInfo.bindingCount = 1;
		setLayoutInfo.pBindings = &uniform;
		VkDescriptorSetLayout setLayout = VK_NULL_HANDLE;
		check(vkCreateDescriptorSetLayout(device, &setLayoutInfo, nullptr, &setLayout), "Create set layout");
		VkPipelineLayoutCreateInfo layoutInfo{VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};
		VkPipelineLayout emptyLayout = VK_NULL_HANDLE, uniformLayout = VK_NULL_HANDLE;
		check(vkCreatePipelineLayout(device, &layoutInfo, nullptr, &emptyLayout), "Create layout");
		layoutInfo.setLayoutCount = 1;
		layoutInfo.pSetLayouts = &setLayout;
		check(vkCreatePipelineLayout(device, &layoutInfo, nullptr, &uniformLayout), "Create uniform layout");
		// resource.frag: a fragment storage buffer at set 0, binding 0, and 16 bytes of fragment push constants.
		VkDescriptorSetLayoutBinding storageBinding{0, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_FRAGMENT_BIT, nullptr};
		setLayoutInfo.pBindings = &storageBinding;
		VkDescriptorSetLayout storageSetLayout = VK_NULL_HANDLE;
		check(vkCreateDescriptorSetLayout(device, &setLayoutInfo, nullptr, &storageSetLayout), "Create storage set layout");
		struct Push { VkDeviceAddress table; uint32_t salt, pad; };
		VkPushConstantRange pushRange{VK_SHADER_STAGE_FRAGMENT_BIT, 0, sizeof(Push)};
		layoutInfo.pSetLayouts = &storageSetLayout;
		layoutInfo.pushConstantRangeCount = 1;
		layoutInfo.pPushConstantRanges = &pushRange;
		VkPipelineLayout resourceLayout = VK_NULL_HANDLE;
		check(vkCreatePipelineLayout(device, &layoutInfo, nullptr, &resourceLayout), "Create resource layout");

		auto module = [&](const std::string& name) {
			auto code = readSpirv(shaders + "/" + name);
			VkShaderModuleCreateInfo info{VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO};
			info.codeSize = code.size() * 4;
			info.pCode = code.data();
			VkShaderModule result = VK_NULL_HANDLE;
			check(vkCreateShaderModule(device, &info, nullptr, &result), "Create shader module");
			return result;
		};
		// A specialization map on the mesh stage could change its workgroup size: the first path refuses it.
		const uint32_t specializationValue = 1;
		const VkSpecializationMapEntry specializationEntry{0, 0, sizeof(uint32_t)};
		const VkSpecializationInfo specialization{1, &specializationEntry, sizeof(uint32_t), &specializationValue};
		auto createPipeline = [&](const std::string& mesh, bool task, VkPipelineLayout layout, VkPipeline& pipeline, const std::string& fragment = "interp.frag.spv", bool specialize = false) {
			std::vector<VkPipelineShaderStageCreateInfo> stages;
			auto stage = [&](VkShaderStageFlagBits bit, const std::string& name) {
				VkPipelineShaderStageCreateInfo info{VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO};
				info.stage = bit;
				info.module = module(name);
				info.pName = "main";
				stages.push_back(info);
			};
			if (task) stage(VK_SHADER_STAGE_TASK_BIT_EXT, "task.task.spv");
			stage(VK_SHADER_STAGE_MESH_BIT_EXT, mesh);
			if (specialize) stages.back().pSpecializationInfo = &specialization;
			stage(VK_SHADER_STAGE_FRAGMENT_BIT, fragment);
			VkViewport viewport{0, 0, float(kSize), float(kSize), 0, 1};
			VkRect2D scissor{{0, 0}, {kSize, kSize}};
			VkPipelineViewportStateCreateInfo viewportState{VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO};
			viewportState.viewportCount = viewportState.scissorCount = 1;
			viewportState.pViewports = &viewport;
			viewportState.pScissors = &scissor;
			VkPipelineRasterizationStateCreateInfo raster{VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO};
			raster.polygonMode = VK_POLYGON_MODE_FILL;
			raster.cullMode = VK_CULL_MODE_NONE;
			raster.lineWidth = 1;
			VkPipelineMultisampleStateCreateInfo multisample{VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO};
			multisample.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;
			VkPipelineColorBlendAttachmentState blendAttachment{};
			blendAttachment.colorWriteMask = 0xF;
			VkPipelineColorBlendStateCreateInfo blend{VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO};
			blend.attachmentCount = 1;
			blend.pAttachments = &blendAttachment;
			VkGraphicsPipelineCreateInfo info{VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO};
			info.stageCount = uint32_t(stages.size());
			info.pStages = stages.data();
			info.pViewportState = &viewportState;
			info.pRasterizationState = &raster;
			info.pMultisampleState = &multisample;
			info.pColorBlendState = &blend;
			info.layout = layout;
			info.renderPass = renderPass;
			return vkCreateGraphicsPipelines(device, VK_NULL_HANDLE, 1, &info, nullptr, &pipeline);
		};

		if (scenario == "reject-task" || scenario == "reject-descriptor" || scenario == "reject-per-primitive" || scenario == "reject-pervertex-block" || scenario == "reject-pervertex-matrix" ||
		    scenario == "reject-specialization" || scenario == "reject-draw-id" || scenario == "reject-draw-id-uint" || scenario == "reject-buffer-address") {
			VkPipeline pipeline = VK_NULL_HANDLE;
			VkResult result = scenario == "reject-task" ? createPipeline("mesh.mesh.spv", true, emptyLayout, pipeline)
			                : scenario == "reject-descriptor" ? createPipeline("descriptor.mesh.spv", false, uniformLayout, pipeline)
			                : scenario == "reject-pervertex-block" ? createPipeline("block.mesh.spv", false, emptyLayout, pipeline, "pervertex-block.frag.spv")
			                : scenario == "reject-pervertex-matrix" ? createPipeline("matrix.mesh.spv", false, emptyLayout, pipeline, "pervertex-matrix.frag.spv")
			                : scenario == "reject-specialization" ? createPipeline("mesh.mesh.spv", false, emptyLayout, pipeline, "interp.frag.spv", true)
			                : scenario == "reject-draw-id" ? createPipeline("draw-id.mesh.spv", false, emptyLayout, pipeline)
			                : scenario == "reject-draw-id-uint" ? createPipeline("draw-id-uint.mesh.spv", false, emptyLayout, pipeline)
			                : scenario == "reject-buffer-address" ? createPipeline("buffer-address.mesh.spv", false, emptyLayout, pipeline)
			                : createPipeline("per-primitive.mesh.spv", false, emptyLayout, pipeline);
			bool pass = result == VK_ERROR_FEATURE_NOT_PRESENT;
			std::printf("MESH_DRAW %s %s: vkCreateGraphicsPipelines=%d expected=%d\n", pass ? "PASS" : "FAIL", scenario.c_str(), result, VK_ERROR_FEATURE_NOT_PRESENT);
			return pass ? 0 : 2;
		}

		struct Render { const char *name, *mesh, *fragment; Model model; bool permuted; Model rival; bool rivalPermuted; };
		static const Render renders[] = {
			{"draw", "mesh.mesh.spv", "interp.frag.spv", Interpolated, false, None, false},
			{"grid", "grid.mesh.spv", "interp.frag.spv", Interpolated, false, None, false},
			{"twice", "grid.mesh.spv", "interp.frag.spv", Interpolated, false, None, false},
			{"reject-indirect", "mesh.mesh.spv", "interp.frag.spv", Interpolated, false, None, false},
			{"reject-grid-limit", "mesh.mesh.spv", "interp.frag.spv", Interpolated, false, None, false},
			{"pervertex", "mesh.mesh.spv", "pervertex.frag.spv", Ordered, false, Swapped, false},
			{"pervertex-swapped", "mesh.mesh.spv", "pervertex-swapped.frag.spv", Swapped, false, Ordered, false},
			{"pervertex-permuted", "permuted.mesh.spv", "pervertex.frag.spv", Ordered, true, Ordered, false},
			{"pervertex-block-output", "block.mesh.spv", "pervertex.frag.spv", Ordered, false, Swapped, false},
			{"barycentric", "mesh.mesh.spv", "barycentric.frag.spv", Barycentric, false, Barycentric, true},
			{"barycentric-permuted", "permuted.mesh.spv", "barycentric.frag.spv", Barycentric, true, Barycentric, false},
			{"pervertex-consistency", "permuted.mesh.spv", "pervertex-consistency.frag.spv", Interpolated, true, None, false},
		};
		const Render* render = nullptr;
		for (const auto& candidate : renders) if (scenario == candidate.name) render = &candidate;
		if (!render && !exact) throw std::runtime_error("Unknown scenario");
		const bool grid = scenario == "grid" || (form && form->grid), twice = scenario == "twice", indirect = scenario == "reject-indirect", gridLimit = scenario == "reject-grid-limit";
		VkPipeline pipeline = VK_NULL_HANDLE;
		if (resource) check(createPipeline("forms-resource.mesh.spv", false, resourceLayout, pipeline, "resource.frag.spv"), "Create mesh pipeline");
		else check(createPipeline(form ? form->mesh : render->mesh, false, emptyLayout, pipeline, form ? form->fragment : render->fragment), "Create mesh pipeline");
		// resource-*: tables A and B with device address usage, storage buffer C, and for the witness table D without
		// device address usage. Each buffer has its own allocation, so that none is resident through another.
		auto tableBuffer = [&](uint32_t tag, bool addressable) {
			VkBufferCreateInfo info{VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO};
			info.size = 16 * sizeof(uint32_t);
			info.usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | (addressable ? VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT : 0);
			VkBuffer buffer = VK_NULL_HANDLE;
			check(vkCreateBuffer(device, &info, nullptr, &buffer), "Create table buffer");
			VkMemoryRequirements tableRequirements{};
			vkGetBufferMemoryRequirements(device, buffer, &tableRequirements);
			VkMemoryAllocateFlagsInfo flags{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_FLAGS_INFO};
			flags.flags = VK_MEMORY_ALLOCATE_DEVICE_ADDRESS_BIT;
			VkMemoryAllocateInfo tableAllocation{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
			tableAllocation.pNext = addressable ? &flags : nullptr;
			tableAllocation.allocationSize = tableRequirements.size;
			tableAllocation.memoryTypeIndex = memoryType(tableRequirements.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
			VkDeviceMemory memory = VK_NULL_HANDLE;
			check(vkAllocateMemory(device, &tableAllocation, nullptr, &memory), "Allocate table");
			check(vkBindBufferMemory(device, buffer, memory, 0), "Bind table");
			void* data = nullptr;
			check(vkMapMemory(device, memory, 0, VK_WHOLE_SIZE, 0, &data), "Map table");
			for (uint32_t i = 0; i < 16; ++i) static_cast<uint32_t*>(data)[i] = resourceValue(tag, i);
			vkUnmapMemory(device, memory);
			return buffer;
		};
		VkDescriptorSet storageSet = VK_NULL_HANDLE;
		Push push{0, kSalt, 0};
		if (resource) {
			VkBuffer tableA = tableBuffer(0xA, true), tableB = tableBuffer(0xB, true), storage = tableBuffer(0xC, false);
			VkBuffer pushed = resource->unresident ? tableBuffer(0xD, false) : resource->table == 0xA ? tableA : tableB;
			VkBufferDeviceAddressInfo addressInfo{VK_STRUCTURE_TYPE_BUFFER_DEVICE_ADDRESS_INFO};
			addressInfo.buffer = pushed;
			push.table = vkGetBufferDeviceAddress(device, &addressInfo);  // Invalid usage for table D, on purpose.
			VkDescriptorPoolSize poolSize{VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1};
			VkDescriptorPoolCreateInfo descriptorPoolInfo{VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO};
			descriptorPoolInfo.maxSets = 1;
			descriptorPoolInfo.poolSizeCount = 1;
			descriptorPoolInfo.pPoolSizes = &poolSize;
			VkDescriptorPool descriptorPool = VK_NULL_HANDLE;
			check(vkCreateDescriptorPool(device, &descriptorPoolInfo, nullptr, &descriptorPool), "Create descriptor pool");
			VkDescriptorSetAllocateInfo setAllocation{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO};
			setAllocation.descriptorPool = descriptorPool;
			setAllocation.descriptorSetCount = 1;
			setAllocation.pSetLayouts = &storageSetLayout;
			check(vkAllocateDescriptorSets(device, &setAllocation, &storageSet), "Allocate descriptor set");
			VkDescriptorBufferInfo storageInfo{storage, 0, VK_WHOLE_SIZE};
			VkWriteDescriptorSet write{VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET};
			write.dstSet = storageSet;
			write.descriptorCount = 1;
			write.descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
			write.pBufferInfo = &storageInfo;
			vkUpdateDescriptorSets(device, 1, &write, 0, nullptr);
			std::printf("RESOURCE table=%X address=0x%llx storage=C salt=%08x\n", resource->unresident ? 0xDu : resource->table, (unsigned long long)push.table, kSalt);
		}
		VkCommandPoolCreateInfo poolInfo{VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};
		VkCommandPool pool = VK_NULL_HANDLE;
		check(vkCreateCommandPool(device, &poolInfo, nullptr, &pool), "Create command pool");
		VkCommandBufferAllocateInfo commandInfo{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
		commandInfo.commandPool = pool;
		commandInfo.commandBufferCount = 1;
		VkCommandBuffer command = VK_NULL_HANDLE;
		check(vkAllocateCommandBuffers(device, &commandInfo, &command), "Allocate command buffer");
		VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
		check(vkBeginCommandBuffer(command, &begin), "Begin command buffer");
		VkClearValue clear{};
		clear.color.float32[0] = clear.color.float32[2] = clear.color.float32[3] = 1.0f;
		if (exact) for (auto& word : clear.color.uint32) word = kClear;
		VkRenderPassBeginInfo passBegin{VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO};
		passBegin.renderPass = renderPass;
		passBegin.framebuffer = framebuffer;
		passBegin.renderArea = {{0, 0}, {kSize, kSize}};
		passBegin.clearValueCount = 1;
		passBegin.pClearValues = &clear;
		vkCmdBeginRenderPass(command, &passBegin, VK_SUBPASS_CONTENTS_INLINE);
		vkCmdBindPipeline(command, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
		if (resource) {
			vkCmdBindDescriptorSets(command, VK_PIPELINE_BIND_POINT_GRAPHICS, resourceLayout, 0, 1, &storageSet, 0, nullptr);
			vkCmdPushConstants(command, resourceLayout, VK_SHADER_STAGE_FRAGMENT_BIT, 0, sizeof(push), &push);
		}
		if (indirect) drawMeshTasksIndirect(command, readback, 0, 1, sizeof(VkDrawMeshTasksIndirectCommandEXT));
		else if (twice) { drawMeshTasks(command, 1, 1, 1); drawMeshTasks(command, 2, 1, 1); }  // The second draw repaints group 0.
		// 2^22 workgroups, Vulkan's minimum maxMeshWorkGroupTotalCount: above every grid limit Metal documents (at most
		// 4,194,303 threadgroups), where Metal draws nothing and reports no error. It must be refused, never omitted.
		else if (gridLimit) drawMeshTasks(command, 2048, 2048, 1);
		else drawMeshTasks(command, grid ? 2 : 1, 1, 1);
		vkCmdEndRenderPass(command);
		VkBufferImageCopy copy{};
		copy.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1};
		copy.imageExtent = {kSize, kSize, 1};
		vkCmdCopyImageToBuffer(command, image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, readback, 1, &copy);
		VkResult ended = vkEndCommandBuffer(command);
		if (indirect || gridLimit) {
			bool pass = ended == VK_ERROR_FEATURE_NOT_PRESENT;
			std::printf("MESH_DRAW %s %s: vkEndCommandBuffer=%d expected=%d, nothing submitted\n", pass ? "PASS" : "FAIL", scenario.c_str(), ended, VK_ERROR_FEATURE_NOT_PRESENT);
			return pass ? 0 : 2;
		}
		check(ended, "End command buffer");
		memset(mapped, 0, kSize * kSize * pixelBytes);
		VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO};
		submit.commandBufferCount = 1;
		submit.pCommandBuffers = &command;
		VkResult submitted = vkQueueSubmit(queue, 1, &submit, VK_NULL_HANDLE);
		VkResult waited = submitted == VK_SUCCESS ? vkQueueWaitIdle(queue) : submitted;
		if (resource && resource->unresident && waited != VK_SUCCESS) {
			std::printf("ABSENT_WITNESS detected %s: the queue failed (%d) reading the non-resident table\n", scenario.c_str(), waited);
			return 0;
		}
		check(submitted, "Submit");
		check(waited, "Wait");
		std::ofstream(scenario + ".rgba", std::ios::binary).write(static_cast<const char*>(mapped), kSize * kSize * pixelBytes);
		if (resource) {
			bool pass = checkResource(*resource, static_cast<const uint32_t*>(mapped));
			vkDeviceWaitIdle(device);
			if (resource->unresident) {
				// The witness detects the absent table unless it read back exactly the values of D.
				std::printf("ABSENT_WITNESS %s %s: %s\n", pass ? "NOT-detected" : "detected", scenario.c_str(),
				            pass ? "the non-resident table read back its values; check the Metal validation log" : "the non-resident table did not read back its values");
				return pass ? 3 : 0;
			}
			std::printf("MESH_DRAW %s %s\n", pass ? "PASS" : "FAIL", scenario.c_str());
			return pass ? 0 : 2;
		}
		if (form) {
			bool pass = checkForm(*form, static_cast<const uint32_t*>(mapped));
			std::printf("MESH_DRAW %s %s\n", pass ? "PASS" : "FAIL", scenario.c_str());
			vkDeviceWaitIdle(device);
			return pass ? 0 : 2;
		}

		const auto* rgba = static_cast<const uint8_t*>(mapped);
		uint32_t checked = 0, mismatch = 0, background = 0, rivalMatch = 0;
		auto differs = [](const uint8_t* p, const float rgb[3]) {
			bool bad = p[3] != 255;
			for (int k = 0; k < 3; ++k) bad |= std::fabs(p[k] / 255.0f - rgb[k]) > 2.0f / 255;
			return bad;
		};
		const uint32_t groups = grid || twice ? 2 : 1;
		for (uint32_t y = 0; y < kSize; ++y) for (uint32_t x = 0; x < kSize; ++x) {
			const uint8_t* p = &rgba[4 * (y * kSize + x)];
			float rgb[3];
			bool outside = false;
			if (!expected(int(x), int(y), groups, render->model, render->permuted, rgb, outside)) {
				if (outside) background += !(p[0] == 255 && p[1] == 0 && p[2] == 255 && p[3] == 255);
				continue;
			}
			++checked;
			mismatch += differs(p, rgb);
			if (render->rival != None && expected(int(x), int(y), groups, render->rival, render->rivalPermuted, rgb, outside)) rivalMatch += !differs(p, rgb);
		}
		// The rival model must be told apart: otherwise this image would not prove the order.
		bool pass = checked > 0 && mismatch == 0 && background == 0 && (render->rival == None || rivalMatch * 10 <= checked);
		std::printf("  %s: checked=%u mismatch=%u background_changed=%u", render->model == Interpolated ? "interpolated per-vertex values" : render->model == Barycentric ? "barycentrics in index order" : "PerVertexKHR corners in index order", checked, mismatch, background);
		if (render->rival != None) std::printf(" rival_matches=%u (at most %u)", rivalMatch, checked / 10);
		std::printf("\n");
		std::printf("MESH_DRAW %s %s\n", pass ? "PASS" : "FAIL", scenario.c_str());
		vkDeviceWaitIdle(device);
		return pass ? 0 : 2;
	} catch (const std::exception& error) {
		std::fprintf(stderr, "ERROR: %s\n", error.what());
		return 1;
	}
}
