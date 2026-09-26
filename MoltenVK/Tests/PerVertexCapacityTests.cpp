// Copyright (c) 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
#include "MVKPerVertexCapacity.h"
#include "MVKPerVertexReplay.h"
#include "SPIRVToMSLConverter.h"
#include "SPIRVReflection.h"
#include <fstream>
#include <iostream>
#include <stdexcept>
using namespace mvk;
using namespace SPIRV_CROSS_NAMESPACE;

static void check(bool value, const char* message) { if (!value) { throw std::runtime_error(message); } }
static std::vector<uint32_t> readSPIRV(const std::string& path) {
	std::ifstream file(path, std::ios::binary | std::ios::ate);
	check(bool(file), "Missing SPIR-V fixture");
	auto size = file.tellg();
	check(size > 0 && size % 4 == 0, "Invalid SPIR-V size");
	std::vector<uint32_t> words(size_t(size) / 4);
	file.seekg(0);
	file.read(reinterpret_cast<char*>(words.data()), size);
	check(bool(file), "Failed SPIR-V read");
	return words;
}

static void checkBufferBounds() {
	for (uint32_t reserved = 0; reserved <= 32; ++reserved) {
		uint32_t slot = 31 - (reserved + 7); // Production capture parameter offset 6.
		for (uint32_t descriptors = 0; descriptors <= 32; ++descriptors) {
			check(mvkPerVertexBufferIndexAvailable(slot, descriptors, 31) == (reserved <= 24 && descriptors <= 24 - reserved), "Capture buffer boundary mismatch");
		}
	}
	check(mvkPerVertexBufferIndexAvailable(25, 25, 31), "Last fragment private slot rejected");
	check(!mvkPerVertexBufferIndexAvailable(25, 26, 31), "Fragment descriptor overlap accepted");
	check(!mvkPerVertexBufferIndexAvailable(31, 0, 31), "Out-of-range buffer accepted");
	check(!mvkPerVertexBufferIndexAvailable(uint8_t(~0u), 0, 31), "Narrowed wrapped index accepted");
	check(!mvkPerVertexBufferIndexAvailable(~0u, 0, 31), "Wrapped index accepted");
}

int main(int argc, char** argv) {
	try {
		check(argc == 2, "Usage: pervertex-capacity-tests output-directory");
		checkBufferBounds();
		std::string directory = argv[1];
		for (uint32_t limit : {60u, 124u}) {
			uint32_t locations = limit / 4;
			for (bool dense : {false, true}) {
				std::string name = std::to_string(locations) + (dense ? "-dense" : "-sparse");
				auto producer = readSPIRV(directory + "/" + name + ".vert.spv");
				SPIRVToMSLConverter converter;
				SPIRVToMSLConversionConfiguration capture;
				capture.options.entryPointName = "main";
				capture.options.entryPointStage = spv::ExecutionModelVertex;
				capture.options.mslOptions.set_msl_version(2, 4);
				capture.options.mslOptions.capture_output_to_buffer = true;
				capture.exportCapturedVertexLayout = true;
				converter.setSPIRV(producer.data(), producer.size());
				SPIRVToMSLConversionResult result;
				check(converter.convert(capture, result), result.resultLog.c_str());
				auto layout = result.resultInfo.capturedVertexLayout;
				uint32_t userComponents = dense ? limit - 6 : locations;
				check(layout.components.size() == userComponents, "Unexpected physical capture layout");
				check(userComponents + 4 <= limit && userComponents + 6 <= limit, "Fixture exceeds Vulkan limits including Position/barycentric builtins");
				std::ofstream(directory + "/" + name + "-capture.metal") << result.msl;
				std::unordered_set<uint32_t> occupied;
				for (const auto& field : layout.components) { occupied.insert(field.location); }
				check(occupied.size() == locations, "Fixture did not occupy every Vulkan Location");
				check(mvkAllocatePerVertexVaryingLocation(occupied, locations) == ~0u, "Baseline namespace exhaustion not reproduced");
				for (uint32_t mask = 0; mask < 4; ++mask) {
					bool perspective = mask & 1, linear = mask & 2;
					uint64_t components = mvkPerVertexReplayVaryingComponents(layout, perspective, linear);
					check(components == userComponents + 1 + 3 * perspective + 3 * linear, "Private varying budget mismatch");
					check((components <= limit) == !(dense && mask == 3), "Legal dense interface with both bases must reject; other fixtures must fit");
					if (components > limit) { continue; }
					auto names = occupied;
					uint32_t key = mvkAllocatePerVertexVaryingLocation(names, locations + 3);
					MSLFragmentBarycentricInputBinding basis;
					if (perspective) { basis.perspective_location = mvkAllocatePerVertexVaryingLocation(names, locations + 3); }
					if (linear) { basis.no_perspective_location = mvkAllocatePerVertexVaryingLocation(names, locations + 3); }
					check(key == locations && (!perspective || basis.perspective_location > key) && (!linear || basis.no_perspective_location > key), "Private names collide with the public interface");
					CompilerMSL replay(producer);
					auto options = replay.get_msl_options();
					options.set_msl_version(2, 4);
					replay.set_msl_options(options);
					auto source = replay.compile_captured_output_replay(layout, {0, 1, 2, key}, {mask ? 3u : ~0u, basis.perspective_location, basis.no_perspective_location});
					check(source.find("user(locn" + std::to_string(key) + ")") != std::string::npos, "Replay omitted private name outside Vulkan range");
					std::ofstream(directory + "/" + name + "-replay-" + std::to_string(mask) + ".metal") << source;
					for (bool captured : {false, true}) {
						if (!captured && !mask) { continue; }
						std::string fragmentName = name + "-" + std::to_string(mask) + "-" + std::to_string(captured);
						auto fragment = readSPIRV(directory + "/" + fragmentName + ".frag.spv");
						std::vector<SPIRVShaderInterfaceVariable> inputs;
						std::string error;
						check(getShaderInputs(fragment, spv::ExecutionModelFragment, "main", inputs, error), error.c_str());
						std::unordered_set<uint32_t> inputLocations;
						for (const auto& input : inputs) { if (input.builtin == spv::BuiltInMax) { inputLocations.insert(input.location); check(input.perVertex == captured, "Wrong fixture interpolation"); } }
						check(inputLocations == occupied, "Fragment does not fill the producer interface");
						SPIRVToMSLConversionConfiguration cfg;
						cfg.options.entryPointName = "main";
						cfg.options.entryPointStage = spv::ExecutionModelFragment;
						cfg.options.mslOptions.set_msl_version(2, 4);
						if (mask) { cfg.setFragmentBarycentricInput(basis); }
						if (captured) { cfg.setPerVertexInputBuffer(layout, {26, 25, key}); }
						converter.setSPIRV(fragment.data(), fragment.size());
						check(converter.convert(cfg, result), result.resultLog.c_str());
						check(result.resultInfo.needsPerVertexInputBuffer == captured, "Barycentric-only fragment must not require private buffers");
						std::ofstream(directory + "/" + fragmentName + ".metal") << result.msl;
					}
				}
				if (dense) {
					auto boundary = layout;
					boundary.components.pop_back();
					check(mvkPerVertexReplayVaryingComponents(boundary, true, true) == limit, "Exact physical component boundary rejected");
				}
				std::cout << name << ": baseline namespace rejected; bounded replay " << (dense ? "accepts key/one basis; rejects two bases (physical capacity)" : "accepts all four basis masks") << '\n';
			}
		}
		MSLCapturedVertexLayout padded;
		MSLCapturedVertexComponent lane;
		lane.location = 30; lane.component = 3;
		padded.components.push_back(lane);
		check(mvkPerVertexReplayVaryingComponents(padded, true, true) == 11, "Component padding undercounted");
		auto fragment = readSPIRV(directory + "/buffers.frag.spv");
		SPIRVToMSLConverter converter;
		converter.setSPIRV(fragment.data(), fragment.size());
		SPIRVToMSLConversionConfiguration cfg;
		cfg.options.entryPointName = "main";
		cfg.options.entryPointStage = spv::ExecutionModelFragment;
		cfg.options.mslOptions.set_msl_version(2, 4);
		cfg.setFragmentBarycentricInput({32, 33});
		mvk::MSLResourceBinding buffers;
		buffers.resourceBinding.stage = spv::ExecutionModelFragment;
		buffers.resourceBinding.count = 31;
		cfg.resourceBindings.push_back(buffers);
		SPIRVToMSLConversionResult result;
		check(converter.convert(cfg, result), result.resultLog.c_str());
		check(!result.resultInfo.needsPerVertexInputBuffer && !result.resultInfo.needsBufferSizeBuffer && !result.resultInfo.needsDynamicOffsetBuffer && !result.resultInfo.needsSwizzleBuffer, "Barycentric-only fragment unexpectedly needs private buffers");
		for (uint32_t slot = 0; slot < 31; ++slot) { check(result.msl.find("[[buffer(" + std::to_string(slot) + ")]]") != std::string::npos, "Missing discrete descriptor"); }
		check(result.msl.find("[[buffer(31)]]") == std::string::npos, "Discrete descriptor capacity exceeded");
		std::ofstream(directory + "/buffers.metal") << result.msl;
		std::cout << "PASS: dense/sparse full interfaces, component boundaries, private namespace, hidden-buffer bounds\n";
		return 0;
	} catch (const std::exception& error) { std::cerr << "FAIL: " << error.what() << '\n'; return 1; }
}
