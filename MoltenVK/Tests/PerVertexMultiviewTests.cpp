// Copyright (c) 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
#include "SPIRVToMSLConverter.h"
#include <fstream>
#include <iostream>
#include <stdexcept>
using namespace mvk;
using namespace SPIRV_CROSS_NAMESPACE;

static void check(bool value, const char* message) { if (!value) { throw std::runtime_error(message); } }
static std::vector<uint32_t> readSPIRV(const std::string& path) {
    std::ifstream file(path, std::ios::binary | std::ios::ate);
    check(bool(file), "Cannot open SPIR-V");
    auto bytes = file.tellg();
    check(bytes > 0 && bytes % 4 == 0, "Invalid SPIR-V size");
    std::vector<uint32_t> words(size_t(bytes) / 4);
    file.seekg(0);
    file.read(reinterpret_cast<char*>(words.data()), bytes);
    check(bool(file), "Cannot read SPIR-V");
    return words;
}
static void writeMSL(const std::string& path, const std::string& source) {
    std::ofstream file(path);
    file << source;
    check(bool(file), "Cannot write MSL");
}

int main(int argc, char** argv) {
    try {
        check(argc == 2 || (argc == 3 && std::string(argv[2]) == "--require-multiview"), "Usage: pervertex-multiview-tests output-directory [--require-multiview]");
        std::string directory = argv[1];
        auto vertex = readSPIRV(directory + "/vert.spv");
        auto fragment = readSPIRV(directory + "/frag.spv");
        SPIRVToMSLConverter converter;
        uint32_t rejected = 0;
        for (bool layered : {false, true}) {
            for (auto indexType : {CompilerMSL::Options::IndexType::None, CompilerMSL::Options::IndexType::UInt16, CompilerMSL::Options::IndexType::UInt32}) {
                std::string name = std::to_string(layered) + "-" + std::to_string(unsigned(indexType));
                SPIRVToMSLConversionConfiguration config;
                config.options.entryPointName = "main";
                config.options.entryPointStage = spv::ExecutionModelVertex;
                config.exportCapturedVertexLayout = true;
                auto& options = config.options.mslOptions;
                options.set_msl_version(2, 4);
                options.multiview = true;
                options.multiview_layered_rendering = layered;
                options.capture_output_to_buffer = true;
                options.disable_rasterization = true;
                options.shader_output_buffer_index = 28;
                options.indirect_params_buffer_index = 24;
                options.view_mask_buffer_index = 22;
                options.shader_index_buffer_index = 25;
                options.vertex_for_tessellation = indexType != CompilerMSL::Options::IndexType::None;
                options.vertex_index_type = indexType;
                converter.setSPIRV(vertex.data(), vertex.size());
                SPIRVToMSLConversionResult capture;
                if (!converter.convert(config, capture)) { throw std::runtime_error(capture.resultLog); }
                check(capture.resultInfo.needsViewRangeBuffer && capture.resultInfo.capturedVertexLayout.stride, "Missing capture ViewRange/layout");
                writeMSL(directory + "/capture-" + name + ".metal", capture.msl);
                if (!layered) {
                    check(capture.msl.find("gl_ViewIndex = spvViewMask[0]") != std::string::npos, "Selected-view capture contract changed");
                }
                if (indexType == CompilerMSL::Options::IndexType::None) {
                    check(capture.msl.find("(gl_InstanceIndex - gl_BaseInstance) * spvIndirectParams[0] + gl_VertexIndex - gl_BaseVertex") != std::string::npos, "Direct dense occurrence addressing changed");
                    if (layered) {
                        check(capture.msl.find("device main0_out& out") < capture.msl.find("gl_InstanceIndex = ("), "Capture no longer addresses physical instances before remapping");
                    }
                } else {
                    check(capture.msl.find("gl_GlobalInvocationID.y * spvStageInputSize.x + gl_GlobalInvocationID.x") != std::string::npos, "Indexed dense occurrence addressing changed");
                    check(capture.msl.find("spvIndices[gl_GlobalInvocationID.x] + spvDispatchBase.x") != std::string::npos, "Indexed signed base-vertex contract changed");
                    if (layered) {
                        check(capture.msl.find("gl_ViewIndex =") < capture.msl.find("uint gl_InstanceIndex ="), "Indexed layered declaration-order boundary changed");
                    }
                }
                SPIRVToMSLConversionConfiguration frag;
                frag.options.entryPointName = "main";
                frag.options.entryPointStage = spv::ExecutionModelFragment;
                frag.options.mslOptions.set_msl_version(2, 4);
                frag.options.mslOptions.multiview = true;
                frag.options.mslOptions.multiview_layered_rendering = layered;
                frag.options.mslOptions.view_mask_buffer_index = 27;
                frag.setPerVertexInputBuffer(capture.resultInfo.capturedVertexLayout, {26, 25, 2});
                frag.setFragmentBarycentricInput({3, 4});
                converter.setSPIRV(fragment.data(), fragment.size());
                SPIRVToMSLConversionResult consumer;
                if (!converter.convert(frag, consumer)) { throw std::runtime_error(consumer.resultLog); }
                check(consumer.resultInfo.needsPerVertexInputBuffer, "Fragment did not consume captured inputs");
                writeMSL(directory + "/fragment-" + name + ".metal", consumer.msl);
                CompilerMSL replay(vertex);
                auto replayOptions = options;
                replayOptions.capture_output_to_buffer = false;
                replayOptions.disable_rasterization = false;
                replayOptions.vertex_for_tessellation = false;
                replayOptions.enable_point_size_default = false;
                replay.set_msl_options(replayOptions);
                try {
                    replay.compile_captured_output_replay(capture.resultInfo.capturedVertexLayout, {0, 1, 2, 2}, {3, 3, 4}, {1});
                } catch (const CompilerError& error) {
                    check(std::string(error.what()).find("does not support multiview") != std::string::npos, error.what());
                    std::cout << "REPRODUCED replay " << name << ": " << error.what() << '\n';
                    rejected++;
                }
                // Simply clearing replay's multiview option also loses the synthetic layer,
                // even when the direct capture layout contains BuiltInLayer.
                CompilerMSL unlayeredReplay(vertex);
                replayOptions.multiview = false;
                replayOptions.multiview_layered_rendering = false;
                unlayeredReplay.set_msl_options(replayOptions);
                auto unlayered = unlayeredReplay.compile_captured_output_replay(capture.resultInfo.capturedVertexLayout, {0, 1, 2, 2}, {3, 3, 4}, {1});
                check(unlayered.find("render_target_array_index") == std::string::npos, "Replay layer transport changed; revisit multiview integration");
                writeMSL(directory + "/replay-disabled-" + name + ".metal", unlayered);
            }
        }
        check(rejected == 6, "Multiview replay boundary changed; implement and validate the complete draw contract before lifting admission");
        if (argc == 3) { throw std::runtime_error("UNSUPPORTED: real SPIRV-Cross replay rejects multiview for direct/uint16/uint32 capture; zero GPU submissions"); }
        std::cout << "PASS: six multiview replay rejections reproduced with real Vulkan SPIR-V; this is a boundary regression, not multi-view support\n";
    } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
