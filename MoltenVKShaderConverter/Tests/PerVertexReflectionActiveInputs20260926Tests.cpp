// Copyright (c) 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
#include "SPIRVReflection.h"
#include <fstream>
#include <initializer_list>
#include <iostream>
#include <stdexcept>

static void check(bool value, const char* message) {
	if (!value) { throw std::runtime_error(message); }
}

static std::vector<uint32_t> readSPIRV(const char* path) {
	std::ifstream file(path, std::ios::binary | std::ios::ate);
	check(bool(file), "Cannot open fixture");
	auto size = file.tellg();
	check(size > 0 && size % 4 == 0, "Invalid fixture size");
	std::vector<uint32_t> words(size_t(size) / 4);
	file.seekg(0);
	file.read(reinterpret_cast<char*>(words.data()), size);
	check(bool(file), "Cannot read fixture");
	return words;
}

// Two fragment entry points share the declared input. Only "other" always accesses it.
// The block variant puts PerVertexKHR on its array member instead of the variable.
static std::vector<uint32_t> fixture(bool member, bool active) {
	std::vector<uint32_t> words{spv::MagicNumber, 0x00010000, 0, 24, 0};
	auto emit = [&](spv::Op op, std::initializer_list<uint32_t> operands) {
		words.push_back((uint32_t(operands.size() + 1) << 16) | uint32_t(op));
		words.insert(words.end(), operands);
	};
	emit(spv::OpCapability, {spv::CapabilityShader});
	emit(spv::OpCapability, {spv::CapabilityFragmentBarycentricKHR});
	// "SPV_KHR_fragment_shader_barycentric", including its NUL terminator.
	const std::string extension = "SPV_KHR_fragment_shader_barycentric";
	std::vector<uint32_t> encoded((extension.size() + 4) / 4, 0);
	for (size_t i = 0; i < extension.size(); i++) { encoded[i / 4] |= uint32_t(uint8_t(extension[i])) << (8 * (i % 4)); }
	words.push_back((uint32_t(encoded.size() + 1) << 16) | uint32_t(spv::OpExtension));
	words.insert(words.end(), encoded.begin(), encoded.end());
	emit(spv::OpMemoryModel, {spv::AddressingModelLogical, spv::MemoryModelGLSL450});
	emit(spv::OpEntryPoint, {spv::ExecutionModelFragment, 16, 0x6e69616d, 0, 12, 13}); // main
	emit(spv::OpEntryPoint, {spv::ExecutionModelFragment, 20, 0x6568746f, 0x72, 12, 13}); // other
	emit(spv::OpExecutionMode, {16, spv::ExecutionModeOriginUpperLeft});
	emit(spv::OpExecutionMode, {20, spv::ExecutionModeOriginUpperLeft});
	if (member) {
		emit(spv::OpDecorate, {8, spv::DecorationBlock});
		emit(spv::OpMemberDecorate, {8, 0, spv::DecorationLocation, 0});
		emit(spv::OpMemberDecorate, {8, 0, spv::DecorationPerVertexKHR});
	} else {
		emit(spv::OpDecorate, {12, spv::DecorationLocation, 0});
		emit(spv::OpDecorate, {12, spv::DecorationPerVertexKHR});
	}
	emit(spv::OpDecorate, {13, spv::DecorationLocation, 0});
	emit(spv::OpTypeVoid, {1});
	emit(spv::OpTypeFunction, {2, 1});
	emit(spv::OpTypeFloat, {3, 32});
	emit(spv::OpTypeInt, {4, 32, 0});
	emit(spv::OpConstant, {4, 5, 3});
	emit(spv::OpConstant, {4, 6, 0});
	emit(spv::OpTypeArray, {7, 3, 5});
	if (member) { emit(spv::OpTypeStruct, {8, 7}); }
	emit(spv::OpTypePointer, {9, spv::StorageClassInput, member ? 8u : 7u});
	emit(spv::OpTypePointer, {10, spv::StorageClassInput, 3});
	emit(spv::OpTypePointer, {11, spv::StorageClassOutput, 3});
	emit(spv::OpVariable, {9, 12, spv::StorageClassInput});
	emit(spv::OpVariable, {11, 13, spv::StorageClassOutput});
	emit(spv::OpConstant, {3, 14, 0});
	for (uint32_t function : {16u, 20u}) {
		emit(spv::OpFunction, {1, function, spv::FunctionControlMaskNone, 2});
		emit(spv::OpLabel, {function + 1});
		if (active || function == 20) {
			if (member) { emit(spv::OpAccessChain, {10, function + 2, 12, 6, 6}); }
			else { emit(spv::OpAccessChain, {10, function + 2, 12, 6}); }
			emit(spv::OpLoad, {3, function + 3, function + 2});
			emit(spv::OpStore, {13, function + 3});
		} else { emit(spv::OpStore, {13, 14}); }
		emit(spv::OpReturn, {});
		emit(spv::OpFunctionEnd, {});
	}
	return words;
}

static void expect(const std::vector<uint32_t>& words, const std::string& entry, bool expected, bool success = true) {
	const auto original = words;
	bool usesPerVertex = !expected;
	std::string error = "stale diagnostic";
	bool result = mvk::getFragmentShaderUsesPerVertexInput(words, entry, usesPerVertex, error);
	check(result == success, error.c_str());
	check(usesPerVertex == expected, "Incorrect PerVertexKHR use or stale output");
	check(success ? error.empty() : !error.empty(), "Incorrect reflection diagnostic");
	check(words == original, "Reflection modified input SPIR-V");
}

int main(int argc, char** argv) {
	try {
		check(argc == 3, "Usage: pervertex-reflection-test pervertex.frag.spv control.frag.spv");
		expect(readSPIRV(argv[1]), "main", true);
		expect(readSPIRV(argv[2]), "main", false);
		for (bool member : {false, true}) {
			for (bool active : {false, true}) {
				auto words = fixture(member, active);
				expect(words, "main", active);
				expect(words, "", active);
				expect(words, "other", true);
				expect(words, "missing", false, false);
				for (const std::string entry : {"main", "other"}) {
					std::vector<mvk::SPIRVShaderInterfaceVariable> inputs;
					std::string error;
					check(mvk::getShaderInputs(words, spv::ExecutionModelFragment, entry, inputs, error), error.c_str());
					bool used = active || entry == "other";
					check(inputs.size() == (used ? 1u : 0u), "Inactive input or PerVertex vertex dimension consumed a location");
					if (used) { check(inputs[0].perVertex && inputs[0].location == 0, "Variable/member PerVertex leaf metadata lost"); }
				}
			}
		}
		auto vertex = fixture(false, false);
		for (size_t offset = 5; offset < vertex.size(); offset += vertex[offset] >> 16) {
			if ((vertex[offset] & 0xffff) == spv::OpEntryPoint) { vertex[offset + 1] = spv::ExecutionModelVertex; }
		}
		expect(vertex, "main", false, false);
		expect(vertex, "", false, false);
#ifndef SPIRV_CROSS_EXCEPTIONS_TO_ASSERTIONS
		expect({}, "main", false, false);
		auto truncated = readSPIRV(argv[1]);
		truncated.resize(6);
		expect(truncated, "main", false, false);
		expect({0, 0, 0, 0, 0}, "main", false, false);
#endif
		std::cout << "PASS: reproducer, control, active/inactive variable and block, entry-point isolation, errors, immutable input\n";
		return 0;
	} catch (const std::exception& error) {
		std::cerr << error.what() << '\n';
		return 1;
	}
}
