// Copyright (c) 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
#include "MVKPerVertexCapacity.h"
#include "MVKPerVertexReplay.h"
#include "SPIRVToMSLConverter.h"
#include "SPIRVReflection.h"
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <cerrno>
#include <spawn.h>
#include <sys/wait.h>

extern char** environ;
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

// Generate the dense mixed interface here so the existing standalone runner covers it.
static void runTool(std::vector<std::string> arguments) {
	std::vector<char*> argv;
	for (auto& argument : arguments) { argv.push_back(&argument[0]); }
	argv.push_back(nullptr);
	pid_t pid;
	check(posix_spawnp(&pid, argv[0], nullptr, nullptr, argv.data(), environ) == 0, "Could not launch fixture compiler/validator");
	int status = 0;
	pid_t waited;
	do { waited = waitpid(pid, &status, 0); } while (waited == -1 && errno == EINTR);
	check(waited == pid && WIFEXITED(status) && WEXITSTATUS(status) == 0, "Fixture compiler/validator failed");
}

static void checkSelectedDenseReplay(const std::string& directory) {
	std::string vertex = "#version 450\n", fragment = "#version 450\n#extension GL_EXT_fragment_shader_barycentric : require\n";
	std::string stores = "void main() { gl_Position = vec4(0, 0, 0, 1);\n";
	std::string reads = "void main() { color = v0; color.xyz += gl_BaryCoordEXT + gl_BaryCoordNoPerspEXT;\n";
	for (uint32_t location = 0; location < 30; ++location) {
		std::string name = "v" + std::to_string(location), prefix = "layout(location = " + std::to_string(location) + ") ";
		vertex += prefix + "out vec4 " + name + ";\n";
		stores += name + " = vec4(float(gl_VertexIndex + " + std::to_string(location) + "));\n";
		// Location 29 is declared but inactive, keeping active fragment components + bases <= 124.
		fragment += prefix + (location && location != 29 ? "pervertexEXT in vec4 " + name + "[3];\n" : "in vec4 " + name + ";\n");
		if (location && location != 29) { reads += "color += " + name + "[0] + " + name + "[1] + " + name + "[2];\n"; }
	}
	vertex += stores + "}\n";
	fragment += "layout(location = 0) out vec4 color;\n" + reads + "}\n";
	for (const auto& fixture : {std::make_pair("vert", vertex), std::make_pair("frag", fragment)}) {
		std::string path = directory + "/selected-dense." + fixture.first;
		std::ofstream(path) << fixture.second;
		runTool({"glslangValidator", "-V", "--target-env", "vulkan1.1", path, "-o", path + ".spv"});
		runTool({"spirv-val", "--target-env", "vulkan1.1", path + ".spv"});
	}
	auto producer = readSPIRV(directory + "/selected-dense.vert.spv");
	auto consumer = readSPIRV(directory + "/selected-dense.frag.spv");
	std::vector<SPIRVShaderInterfaceVariable> inputs;
	std::string error;
	check(getShaderInputs(consumer, spv::ExecutionModelFragment, "main", inputs, error), error.c_str());
	auto selected = mvkPerVertexReplayUserLocations(inputs);
	check(selected == std::vector<uint32_t>{0}, "Replay selected PerVertexKHR or inactive fragment inputs");
	check(std::count_if(inputs.begin(), inputs.end(), [](const auto& input) { return input.isUsed && input.perVertex; }) == 28, "Dense fixture lost its active captured inputs");
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
	check(layout.components.size() == 120 && layout.builtins.size() == 4, "Dense producer must capture 30 vec4 Locations and Position");
	std::ofstream(directory + "/selected-dense-capture.metal") << result.msl;
	uint64_t oldBudget = mvkPerVertexReplayVaryingComponents(layout, true, true);
	uint64_t selectedBudget = mvkPerVertexReplayVaryingComponents(layout, true, true, selected);
	check(oldBudget == 127 && oldBudget > 124, "All-output replay must exceed the physical budget");
	check(selectedBudget == 11 && selectedBudget <= 124, "Selected dense replay should fit the physical budget");
	std::unordered_set<uint32_t> occupied;
	for (const auto& field : layout.components) { occupied.insert(field.location); }
	for (const auto& input : inputs) { if (input.builtin == spv::BuiltInMax) { occupied.insert(input.location); } }
	uint32_t key = mvkAllocatePerVertexVaryingLocation(occupied, 34);
	MSLFragmentBarycentricInputBinding basis;
	basis.perspective_location = mvkAllocatePerVertexVaryingLocation(occupied, 34);
	basis.no_perspective_location = mvkAllocatePerVertexVaryingLocation(occupied, 34);
	check(key == 30 && basis.perspective_location == 31 && basis.no_perspective_location == 32, "Private names collided with omitted captured Locations");
	CompilerMSL replay(producer);
	auto options = replay.get_msl_options();
	options.set_msl_version(2, 4);
	replay.set_msl_options(options);
	auto source = replay.compile_captured_output_replay(layout, {0, 1, 2, key}, {3, basis.perspective_location, basis.no_perspective_location}, selected);
	for (uint32_t location = 0; location < 33; ++location) { check((source.find("user(locn" + std::to_string(location) + ")") != std::string::npos) == (location == 0 || location >= 30), "Replay emitted the wrong raster interface"); }
	check(source.find("[[position]]") != std::string::npos && source.find("spvReplayRecord + 480ul") != std::string::npos, "Selection shifted or omitted captured Position");
	std::ofstream(directory + "/selected-dense-replay.metal") << source;
	SPIRVToMSLConversionConfiguration cfg;
	cfg.options.entryPointName = "main";
	cfg.options.entryPointStage = spv::ExecutionModelFragment;
	cfg.options.mslOptions.set_msl_version(2, 4);
	cfg.setFragmentBarycentricInput(basis);
	cfg.setPerVertexInputBuffer(layout, {26, 25, key});
	converter.setSPIRV(consumer.data(), consumer.size());
	check(converter.convert(cfg, result), result.resultLog.c_str());
	check(result.resultInfo.needsPerVertexInputBuffer, "Dense fragment lost captured input buffer");
	for (uint32_t location = 1; location < 30; ++location) { check(result.msl.find("user(locn" + std::to_string(location) + ")") == std::string::npos, "Captured or inactive fragment input became a raster varying"); }
	std::ofstream(directory + "/selected-dense-fragment.metal") << result.msl;
	// Shared Component lanes select the entire Location once, regardless of reflection order.
	SPIRVShaderInterfaceVariable ordinary{SPIRType::Float, 1, 0, 3, 0, spv::BuiltInMax, false, true, false};
	auto captured = ordinary; captured.perVertex = true;
	auto inactive = ordinary; inactive.location = 29; inactive.isUsed = false;
	check(mvkPerVertexReplayUserLocations(std::vector<SPIRVShaderInterfaceVariable>{captured, ordinary, inactive, ordinary}) == selected, "Shared Component lanes or duplicate inputs changed selected Locations");
	std::cout << "PASS: selected dense replay 11/124 components; all-output replay rejected at 127/124; unchanged 120-field capture\n";
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
		checkSelectedDenseReplay(directory);
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
					if (components <= limit) { std::ofstream(directory + "/" + name + "-replay-" + std::to_string(mask) + ".metal") << source; }
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
						auto selected = mvkPerVertexReplayUserLocations(inputs);
						check(selected.size() == (captured ? 0 : locations), "Wrong selected full-interface Locations");
						uint64_t selectedComponents = mvkPerVertexReplayVaryingComponents(layout, perspective, linear, selected);
						check(selectedComponents == (captured ? 0 : userComponents) + 1 + 3 * perspective + 3 * linear, "Selected varying budget mismatch");
						if (selectedComponents > limit) { check(!captured && dense && mask == 3, "Unexpected selected replay budget rejection"); continue; }
						CompilerMSL selectedReplay(producer);
						selectedReplay.set_msl_options(options);
						auto selectedSource = selectedReplay.compile_captured_output_replay(layout, {0, 1, 2, key}, {mask ? 3u : ~0u, basis.perspective_location, basis.no_perspective_location}, selected);
						if (!captured) { check(selectedSource == source, "Full ordinary selection changed previously valid replay source"); }
						for (uint32_t location = 0; location < locations; ++location) { check((selectedSource.find("user(locn" + std::to_string(location) + ")") != std::string::npos) == !captured, "Selected replay widened or dropped the full interface"); }
						std::ofstream(directory + "/" + fragmentName + "-selected-replay.metal") << selectedSource;
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
					std::vector<uint32_t> selected(occupied.begin(), occupied.end());
					check(mvkPerVertexReplayVaryingComponents(boundary, true, true, selected) == limit && mvkPerVertexReplayVaryingComponents(layout, true, true, selected) == limit + 1, "Selected physical component boundary mismatch");
				}
				// Selecting a non-base array Location cannot silently omit the requested varying.
				bool rejected = false;
				try {
					CompilerMSL partial(producer);
					auto options = partial.get_msl_options(); options.set_msl_version(2, 4); partial.set_msl_options(options);
					partial.compile_captured_output_replay(layout, {0, 1, 2, locations}, {}, std::vector<uint32_t>{1});
				} catch (const CompilerError& error) { rejected = std::string(error.what()).find("selected replay") != std::string::npos; }
				check(rejected, "Unrepresentable partial array selection was silently accepted");
				std::cout << name << ": all captured-only masks fit; ordinary " << (dense ? "two-basis interface still rejects above physical capacity" : "interface fits all masks") << "; partial composite safely rejected\n";
			}
		}
		MSLCapturedVertexLayout padded;
		MSLCapturedVertexComponent lane;
		lane.location = 30; lane.component = 3;
		padded.components.push_back(lane);
		check(mvkPerVertexReplayVaryingComponents(padded, true, true) == 11, "Component padding undercounted");
		check(mvkPerVertexReplayVaryingComponents(padded, true, true, {30}) == 11, "Selected Component padding undercounted");
		check(mvkPerVertexReplayVaryingComponents(padded, true, true, {}) == 7, "Omitted Location still charged physical components");
		MSLCapturedVertexBuiltin builtin;
		builtin.builtin = spv::BuiltInPosition;
		for (uint32_t component = 0; component < 4; ++component) { builtin.component = component; padded.builtins.push_back(builtin); }
		builtin.component = 0;
		for (auto kind : {spv::BuiltInPointSize, spv::BuiltInClipDistance, spv::BuiltInLayer, spv::BuiltInViewportIndex}) { builtin.builtin = kind; padded.builtins.push_back(builtin); }
		check(mvkPerVertexReplayVaryingComponents(padded, true, true, {}) == 11 && mvkPerVertexReplayVaryingComponents(padded, true, true, {30}) == 15, "Selection dropped fixed builtin costs or charged dedicated Position");
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
