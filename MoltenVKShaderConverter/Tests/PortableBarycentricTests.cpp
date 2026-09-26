// SPDX-License-Identifier: Apache-2.0
#include "SPIRVToMSLConverter.h"
#include "SPIRVReflection.h"
#include "MVKPerVertexReplay.h"
#include <cereal/archives/binary.hpp>
#include <cereal/types/map.hpp>
#include <cereal/types/string.hpp>
#include <cereal/types/vector.hpp>
#include "PipelineCacheSerializers.inc"
#include <fstream>
#include <iostream>
#include <sstream>
#include <stdexcept>
using namespace mvk;
using namespace SPIRV_CROSS_NAMESPACE;
static void check(bool value, const char* message) { if (!value) { throw std::runtime_error(message); } }
static std::vector<uint32_t> readSPIRV(const std::string& path) {
	std::ifstream stream(path, std::ios::binary | std::ios::ate);
	check(bool(stream), "Missing SPIR-V fixture");
	auto size = stream.tellg();
	check(size > 0 && size % 4 == 0, "Invalid fixture size");
	std::vector<uint32_t> result(size_t(size) / 4);
	stream.seekg(0);
	stream.read(reinterpret_cast<char*>(result.data()), size);
	check(bool(stream), "Failed fixture read");
	return result;
}
static void checkDraws() {
	struct Case { VkPrimitiveTopology topology; bool last; uint32_t count; std::vector<uint32_t> records; };
	const Case cases[] = {
		{VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, false, 7, {0, 1, 2, 3, 4, 5}},
		{VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, true, 7, {0, 1, 2, 3, 4, 5}},
		{VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP, false, 5, {0, 1, 2, 1, 3, 2, 2, 3, 4}},
		{VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP, true, 5, {0, 1, 2, 2, 1, 3, 2, 3, 4}},
		{VK_PRIMITIVE_TOPOLOGY_TRIANGLE_FAN, false, 5, {1, 2, 0, 2, 3, 0, 3, 4, 0}},
		{VK_PRIMITIVE_TOPOLOGY_TRIANGLE_FAN, true, 5, {0, 1, 2, 0, 2, 3, 0, 3, 4}}
	};
	for (const auto& c : cases) {
		size_t n = c.records.size();
		std::vector<uint32_t> pairs(n * 4, ~0u), indices(n * 2, ~0u), corners(n * 2, ~0u);
		mvkPopulatePerVertexReplay(c.count, 2, c.topology, c.last, pairs.data(), indices.data(), corners.data());
		for (size_t occurrence = 0; occurrence < 2 * n; ++occurrence) {
			check(pairs[2 * occurrence] == c.records[occurrence % n] + (occurrence / n) * c.count, "Wrong capture record or instance");
			check(pairs[2 * occurrence + 1] == occurrence / 3 && indices[occurrence] == pairs[2 * occurrence], "Primitive key/triplet mismatch");
			check(corners[occurrence] == occurrence % 3, "Corner basis does not match triplet order");
		}
		// Legacy path writes identical pairs/triplets without a corner buffer.
		auto original = pairs;
		mvkPopulatePerVertexReplay(c.count, 2, c.topology, c.last, pairs.data(), indices.data(), nullptr);
		check(pairs == original, "Optional basis changed legacy occurrence pairs");
	}
	uint32_t sentinel = 99;
	mvkPopulatePerVertexReplay(2, 2, VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP, false, &sentinel, &sentinel, &sentinel);
	check(sentinel == 99, "Incomplete primitive wrote payload");
	std::unordered_set<uint32_t> occupied{0, 2, 5};
	check(mvkAllocatePerVertexVaryingLocation(occupied, 6) == 1, "Private key collided with occupied location");
	check(mvkAllocatePerVertexVaryingLocation(occupied, 6) == 3, "Perspective basis collided with private key");
	check(mvkAllocatePerVertexVaryingLocation(occupied, 6) == 4, "Linear basis collided with perspective basis");
	check(mvkAllocatePerVertexVaryingLocation(occupied, 6) == ~0u, "Dense varying interface overflow accepted");
}
int main(int argc, char** argv) {
	try {
		check(argc == 2, "Usage: portable-barycentric-test output-directory");
		std::string directory = argv[1];
		checkDraws();
		auto producer = readSPIRV(directory + "/producer.spv");
		SPIRVToMSLConverter converter;
		SPIRVToMSLConversionConfiguration capture;
		capture.options.entryPointName = "main";
		capture.options.entryPointStage = spv::ExecutionModelVertex;
		capture.options.mslOptions.set_msl_version(2, 4);
		capture.options.mslOptions.capture_output_to_buffer = true;
		capture.exportCapturedVertexLayout = true;
		SPIRVToMSLConversionResult result;
		converter.setSPIRV(producer.data(), producer.size());
		check(converter.convert(capture, result), result.resultLog.c_str());
		auto layout = result.resultInfo.capturedVertexLayout;
		check(layout.stride > 0, "Capture layout absent");
		std::ofstream(directory + "/capture.metal") << result.msl;
		for (unsigned mask = 1; mask < 4; ++mask) {
			for (unsigned captured = 0; captured < 2; ++captured) {
				std::string name = std::to_string(mask) + "-" + std::to_string(captured);
				auto spirv = readSPIRV(directory + "/fragment-" + name + ".spv");
				SPIRVToMSLConversionConfiguration cfg;
				cfg.options.entryPointName = "main";
				cfg.options.entryPointStage = spv::ExecutionModelFragment;
				cfg.options.mslOptions.set_msl_version(2, 4);
				MSLFragmentBarycentricInputBinding binding{mask & 1 ? 2u : ~0u, mask & 2 ? 3u : ~0u};
				cfg.setFragmentBarycentricInput(binding);
				if (captured) { cfg.setPerVertexInputBuffer(layout, {28, 29, 1}); }
				converter.setSPIRV(spirv.data(), spirv.size());
				check(converter.convert(cfg, result), result.resultLog.c_str());
				check(result.resultInfo.needsPerVertexInputBuffer == bool(captured), "Barycentric-only conversion incorrectly requires captured inputs");
				check(result.msl.find("barycentric_coord") == std::string::npos, "Native barycentric attribute leaked into portable fragment");
				std::ofstream(directory + "/fragment-" + name + ".metal") << result.msl;
				CompilerMSL replay(producer);
				auto options = replay.get_msl_options(); options.set_msl_version(2, 4); replay.set_msl_options(options);
				auto source = replay.compile_captured_output_replay(layout, {0, 1, 2, 1}, {3, binding.perspective_location, binding.no_perspective_location});
				check(source.find("barycentric_coord") == std::string::npos, "Native attribute leaked into replay");
				std::ofstream(directory + "/replay-" + name + ".metal") << source;
				std::stringstream bytes;
				{ cereal::BinaryOutputArchive archive(bytes); archive(cfg); }
				SPIRVToMSLConversionConfiguration restored;
				{ cereal::BinaryInputArchive archive(bytes); archive(restored); }
				check(cfg.matches(restored) && restored.matches(cfg), "Production cache round-trip lost barycentric ABI");
				for (unsigned field = 0; field < 3; ++field) {
					auto changed = restored;
					if (field == 0) { changed.fragmentBarycentricInput.enabled = false; }
					if (field == 1) { changed.fragmentBarycentricInput.binding.perspective_location ^= 4; }
					if (field == 2) { changed.fragmentBarycentricInput.binding.no_perspective_location ^= 4; }
					check(!cfg.matches(changed) && !changed.matches(cfg), "Cache identity ignores opt-in or private location");
				}
				auto missing = cfg;
				missing.setFragmentBarycentricInput({});
				check(!converter.convert(missing, result), "Missing private locations accepted");
			}
		}
		// Capture explicit PointSize; the pinned replay API must not synthesize a default.
		auto pointProducer = readSPIRV(directory + "/point-producer.spv");
		auto pointCapture = capture;
		pointCapture.options.mslOptions.enable_point_size_builtin = true;
		pointCapture.options.mslOptions.enable_point_size_default = true;
		converter.setSPIRV(pointProducer.data(), pointProducer.size());
		check(converter.convert(pointCapture, result), result.resultLog.c_str());
		auto pointLayout = result.resultInfo.capturedVertexLayout;
		check(std::any_of(pointLayout.builtins.begin(), pointLayout.builtins.end(), [](const auto& field) { return field.builtin == spv::BuiltInPointSize; }), "PointSize missing from captured layout");
		std::ofstream(directory + "/point-capture.metal") << result.msl;
		for (unsigned index = 0; index < 2; ++index) {
			auto indexed = pointCapture;
			indexed.options.mslOptions.vertex_for_tessellation = true;
			indexed.options.mslOptions.vertex_index_type = index ? CompilerMSL::Options::IndexType::UInt32 : CompilerMSL::Options::IndexType::UInt16;
			check(converter.convert(indexed, result), result.resultLog.c_str());
			MSLPerVertexInputBuffer expected{true, pointLayout, {}}, actual{true, result.resultInfo.capturedVertexLayout, {}};
			check(expected.matches(actual), "Indexed point capture layout differs from nonindexed capture");
			std::ofstream(directory + "/point-indexed-" + std::to_string(index) + ".metal") << result.msl;
		}
		CompilerMSL pointReplay(pointProducer);
		auto pointOptions = pointCapture.options.mslOptions;
		pointOptions.capture_output_to_buffer = false;
		pointOptions.enable_point_size_default = false;
		pointReplay.set_msl_options(pointOptions);
		auto pointSource = pointReplay.compile_captured_output_replay(pointLayout, {0, 1, 2, 1}, {3, 2, 3});
		check(pointSource.find("[[point_size]]") != std::string::npos, "Replay lost PointSize raster attribute");
		check(pointSource.find("spvReplayCorners[spvReplayOccurrence]") != std::string::npos, "Point replay lost corner basis");
		std::ofstream(directory + "/point-replay.metal") << pointSource;
		auto explicitOnly = readSPIRV(directory + "/explicit-only.spv");
		std::vector<SPIRVShaderInterfaceVariable> inputs;
		std::string error;
		check(getShaderInputs(explicitOnly, spv::ExecutionModelFragment, "main", inputs, error), error.c_str());
		check(std::any_of(inputs.begin(), inputs.end(), [](const auto& i) { return i.builtin == spv::BuiltInBaryCoordKHR; }), "Explicit-only builtin absent from pipeline reflection");
		SPIRVToMSLConversionConfiguration cfg;
		cfg.options.entryPointName = "main"; cfg.options.entryPointStage = spv::ExecutionModelFragment; cfg.options.mslOptions.set_msl_version(2, 4);
		cfg.setFragmentBarycentricInput({2, 3});
		converter.setSPIRV(explicitOnly.data(), explicitOnly.size());
		check(converter.convert(cfg, result), result.resultLog.c_str());
		std::ofstream(directory + "/explicit-only.metal") << result.msl;
		SPIRVToMSLConversionConfiguration empty;
		auto disabled = empty;
		disabled.fragmentBarycentricInput.binding = {8, 9};
		check(empty.matches(disabled) && disabled.matches(empty), "Disabled binding changed cache identity");
		std::stringstream bytes;
		{ cereal::BinaryOutputArchive archive(bytes); archive(empty); }
		check(sizeof(empty) - bytes.str().size() == 156, "Pipeline archive padding expectation is stale");
		std::cout << "Configuration sizeof=" << sizeof(empty) << " empty archive=" << bytes.str().size() << "\n";
		std::cout << "PASS: six matching capture/replay/fragment variants, explicit-only reflection, production cache round-trip/mutations, list/strip/fan corners, instances, optional payload and incomplete primitives\n";
		return 0;
	} catch (const std::exception& e) { std::cerr << "FAIL: " << e.what() << '\n'; return 1; }
}
