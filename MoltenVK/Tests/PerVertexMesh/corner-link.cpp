// Copyright 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
// CPU check of a mesh pipeline interface, before any GPU work. Converts the mesh and the fragment shader with the
// MoltenVK converter as initMeshPipelineState does: the PerVertexKHR Location mask from
// getMeshPerVertexCornerLocations on both stages, and fragment input remaps from the mesh outputs. Then every
// fragment [[user(...)]] input must match a mesh output of the same name and MSL type, as Metal links them.
// Writes <prefix>.mesh.metal and <prefix>.frag.metal for syntax checks.
// Usage: corner-link <mesh.spv> <fragment.spv> <prefix>
// Exit status: 0 linked, 1 mismatch or conversion failure, 3 the pipeline refuses the PerVertexKHR form.
#include "SPIRVReflection.h"
#include "SPIRVToMSLConverter.h"
#include <cstdio>
#include <fstream>
#include <map>
#include <regex>
#include <stdexcept>

using namespace mvk;
using namespace SPIRV_CROSS_NAMESPACE;

static std::vector<uint32_t> readSPIRV(const std::string& path) {
	std::ifstream file(path, std::ios::binary | std::ios::ate);
	if (!file) { throw std::runtime_error("Cannot open " + path); }
	auto size = file.tellg();
	std::vector<uint32_t> words(size_t(size) / 4);
	file.seekg(0);
	file.read(reinterpret_cast<char*>(words.data()), size);
	return words;
}

// Mirrors mvkInterfaceFormatFromBaseType in MVKPipeline.mm.
static MSLShaderVariableFormat interfaceFormat(SPIRType::BaseType baseType) {
	switch (baseType) {
		case SPIRType::UByte:	return MSL_SHADER_VARIABLE_FORMAT_UINT8;
		case SPIRType::UShort:	return MSL_SHADER_VARIABLE_FORMAT_UINT16;
		case SPIRType::Short:
		case SPIRType::Half:	return MSL_SHADER_VARIABLE_FORMAT_ANY16;
		case SPIRType::Int:
		case SPIRType::UInt:
		case SPIRType::Float:	return MSL_SHADER_VARIABLE_FORMAT_ANY32;
		default:				return MSL_SHADER_VARIABLE_FORMAT_OTHER;
	}
}

// The [[user(...)]] members of an MSL struct, by attribute name, with their MSL type.
static std::map<std::string, std::string> userMembers(const std::string& msl, const std::string& name) {
	std::map<std::string, std::string> members;
	auto start = msl.find("struct " + name + "\n{");
	if (start == std::string::npos) { return members; }
	auto end = msl.find("\n};", start);
	static const std::regex member("\\n\\s+(\\S+) \\S+ \\[\\[user\\(([^)]+)\\)");
	for (std::sregex_iterator it(msl.begin() + start, msl.begin() + end, member), last; it != last; ++it) { members[(*it)[2]] = (*it)[1]; }
	return members;
}

int main(int argc, char** argv) {
	try {
		if (argc != 4) { throw std::runtime_error("Usage: corner-link <mesh.spv> <fragment.spv> <prefix>"); }
		auto mesh = readSPIRV(argv[1]), fragment = readSPIRV(argv[2]);
		std::string prefix = argv[3], error;
		bool usesPerVertex = false;
		if (!getFragmentShaderUsesPerVertexInput(fragment, "main", usesPerVertex, error)) { throw std::runtime_error(error); }
		uint32_t locations = usesPerVertex ? getMeshPerVertexCornerLocations(fragment, "main") : 0;
		if (usesPerVertex && !locations) {
			std::printf("CORNER_LINK REFUSED %s: unsupported PerVertexKHR form, as vkCreateGraphicsPipelines\n", prefix.c_str());
			return 3;
		}
		SPIRVToMSLConverter converter;
		SPIRVToMSLConversionConfiguration config;
		config.options.entryPointName = "main";
		config.options.entryPointStage = spv::ExecutionModelMeshEXT;
		config.options.mslOptions.set_msl_version(3, 2);
		config.options.mslOptions.mesh_per_vertex_corner_locations = locations;
		SPIRVToMSLConversionResult meshResult, fragmentResult;
		converter.setSPIRV(mesh.data(), mesh.size());
		if (!converter.convert(config, meshResult)) { throw std::runtime_error("Mesh conversion: " + meshResult.resultLog); }
		std::vector<SPIRVShaderOutput> outputs;
		if (!getShaderOutputs(mesh, spv::ExecutionModelMeshEXT, "main", outputs, error)) { throw std::runtime_error(error); }
		for (const auto& output : outputs) {  // As addPrevStageOutputToShaderConversionConfig.
			if (!output.isUsed) { continue; }
			mvk::MSLShaderInput input;
			input.shaderVar.location = output.location;
			input.shaderVar.component = output.component;
			input.shaderVar.builtin = output.builtin;
			input.shaderVar.vecsize = output.vecWidth;
			input.shaderVar.format = interfaceFormat(output.baseType);
			config.shaderInputs.push_back(input);
		}
		config.options.entryPointStage = spv::ExecutionModelFragment;
		converter.setSPIRV(fragment.data(), fragment.size());
		if (!converter.convert(config, fragmentResult)) { throw std::runtime_error("Fragment conversion: " + fragmentResult.resultLog); }
		std::ofstream(prefix + ".mesh.metal") << meshResult.msl;
		std::ofstream(prefix + ".frag.metal") << fragmentResult.msl;

		auto produced = userMembers(meshResult.msl, "spvPerVertex");
		for (const auto& member : userMembers(meshResult.msl, "spvPerPrimitive")) { produced.insert(member); }
		auto consumed = userMembers(fragmentResult.msl, "main0_in");
		uint32_t corners = 0, bad = 0;
		for (const auto& [name, type] : consumed) {
			auto it = produced.find(name);
			bool linked = it != produced.end() && it->second == type;
			corners += name.find("_corner") != std::string::npos;
			bad += !linked;
			std::printf("  %-18s fragment %-8s mesh %-8s %s\n", name.c_str(), type.c_str(), it == produced.end() ? "-" : it->second.c_str(), linked ? "ok" : "MISMATCH");
		}
		bool pass = !bad && (!usesPerVertex || corners);
		std::printf("CORNER_LINK %s %s: mask=0x%x corner_inputs=%u user_inputs=%zu mismatches=%u\n", pass ? "PASS" : "FAIL", prefix.c_str(), locations, corners, consumed.size(), bad);
		return pass ? 0 : 1;
	} catch (const std::exception& error) {
		std::fprintf(stderr, "CORNER_LINK FAIL: %s\n", error.what());
		return 1;
	}
}
