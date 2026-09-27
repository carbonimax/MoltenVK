// Copyright (c) 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
#include "SPIRVToMSLConverter.h"
#include "MVKPerVertexCapacity.h"
#include "MVKPerVertexReplay.h"
#include <fstream>
#include <iostream>
#include <stdexcept>
using namespace mvk;
using namespace SPIRV_CROSS_NAMESPACE;
static void check(bool value, const char* message) { if (!value) { throw std::runtime_error(message); } }
// CPU doubles for the production admission, slot assignment and conversion-option blocks.
// Shader conversion itself uses the real converter and compiler, never a Metal device.
enum MVKShaderStage { kMVKShaderStageVertex, kMVKShaderStageTessCtl, kMVKShaderStageTessEval, kMVKShaderStageFragment };
enum MVKImplicitBuffer { DynamicOffset, BufferSize, Swizzle, Output, EmulatedReversedDepthViewport, ViewRange, Index, DrawId, IndirectParams, PatchOutput, TessLevel, Count };
enum class MVKRenderStateFlag { PrimitiveTopology, PrimitiveRestartEnable };
struct Pipeline {
    struct Flags { bool has(MVKRenderStateFlag) { return false; } } _dynamicStateFlags;
    struct Module { std::vector<uint32_t> words{1}; const auto& getSPIRV() { return words; } } module;
    Module* _vertexModule = &module;
    bool _isTessellationPipeline = false, _usesPerVertexInputBuffer = true, _hasPerVertexInputs = true;
    VkPipelineCreateFlags2 _flags = 0;
    struct Counts { uint32_t stages[4] = {}; } _descriptorBufferCounts;
    struct Resource { struct Buffers { uint32_t ids[size_t(MVKImplicitBuffer::Count)] = {}; } implicitBuffers; } _stageResources[4];
    struct Features { uint32_t mslVersion = CompilerMSL::Options::make_msl_version(2, 4), maxPerStageBufferCount = 31; } features;
    struct Physical { bool layered = true; bool canUseInstancingForMultiview() { return layered; } } physical;
    MSLPerVertexInputBinding _perVertexInputBinding;
    VkPipelineRenderingCreateInfo rendering{};
    uint32_t reserved = 0;
    std::string error;
    auto& getMetalFeatures() { return features; }
    auto* getPhysicalDevice() { return &physical; }
    const auto* getRenderingCreateInfo(const VkGraphicsPipelineCreateInfo*) { return &rendering; }
    void initReservedVertexAttributeBufferCount(const VkGraphicsPipelineCreateInfo*) {}
    uint32_t getImplicitBufferIndex(MVKShaderStage stage, uint32_t offset) { return 30u - (stage == kMVKShaderStageVertex ? reserved : 0u) - offset; }
    bool admit(const VkGraphicsPipelineCreateInfo*);
    void slots(const VkGraphicsPipelineCreateInfo*);
    void configure(SPIRVToMSLConversionConfiguration&);
    uint32_t slot(MVKImplicitBuffer buffer) { return _stageResources[kMVKShaderStageVertex].implicitBuffers.ids[size_t(buffer)]; }
};
static bool mvkIsAnyFlagEnabled(uint64_t flags, uint64_t mask) { return (flags & mask) != 0; }
static bool mvkIsMultiview(uint32_t mask) { return mask != 0; }
#include "SingleViewPipeline.inc"
static std::vector<uint32_t> readSPIRV(const std::string& path) {
    std::ifstream file(path, std::ios::binary | std::ios::ate);
    check(bool(file), "Cannot open fixture");
    auto size = file.tellg();
    check(size > 0 && size % 4 == 0, "Invalid fixture");
    std::vector<uint32_t> words(size_t(size) / 4);
    file.seekg(0);
    file.read(reinterpret_cast<char*>(words.data()), size);
    check(bool(file), "Cannot read fixture");
    return words;
}
static void writeMSL(const std::string& path, const std::string& source) {
    std::ofstream file(path);
    file << source;
    check(bool(file), "Cannot write Metal source");
}
static void checkAdmission() {
    VkPipelineInputAssemblyStateCreateInfo assembly{};
    assembly.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
    VkGraphicsPipelineCreateInfo info{};
    info.stageCount = 2;
    info.pInputAssemblyState = &assembly;
    for (uint32_t mask : {1u, 32u, 0x80000000u, 0u}) {
        Pipeline pipeline;
        pipeline.rendering.viewMask = mask;
        check(pipeline.admit(&info), "Zero/single view rejected");
        pipeline.slots(&info);
        check(!mask || pipeline.slot(MVKImplicitBuffer::ViewRange) != pipeline.slot(MVKImplicitBuffer::Index), "ViewRange aliases indexed capture");
        for (bool layered : {false, true}) {
            pipeline.physical.layered = layered;
            SPIRVToMSLConversionConfiguration config;
            pipeline.configure(config);
            check(config.options.mslOptions.multiview == bool(mask), "ViewIndex enable lost");
            check(!config.options.mslOptions.multiview_layered_rendering, "Capture remaps instance index");
        }
        pipeline._flags = VK_PIPELINE_CREATE_2_VIEW_INDEX_FROM_DEVICE_INDEX_BIT;
        check(!pipeline.admit(&info), "Device-index views accepted");
        pipeline._flags = 0;
        pipeline._isTessellationPipeline = true;
        check(!pipeline.admit(&info), "TES accepted");
    }
    for (uint32_t mask : {3u, 5u, 33u, 0xc0000000u, ~0u}) {
        Pipeline pipeline;
        pipeline.rendering.viewMask = mask;
        check(!pipeline.admit(&info), "Multiple views accepted");
    }
    for (uint32_t reserved : {0u, 16u, 22u}) {
        Pipeline pipeline;
        pipeline.rendering.viewMask = 32;
        pipeline.reserved = reserved;
        pipeline._descriptorBufferCounts.stages[0] = 22 - reserved;
        check(pipeline.admit(&info), "Exact view buffer capacity rejected");
        pipeline._descriptorBufferCounts.stages[0]++;
        check(!pipeline.admit(&info), "ViewRange overlaps descriptor buffers");
    }
    Pipeline wrapped;
    wrapped.rendering.viewMask = 32;
    wrapped.reserved = 23;
    check(!wrapped.admit(&info), "Wrapped ViewRange index accepted");
    Pipeline ordinary;
    ordinary._usesPerVertexInputBuffer = false;
    ordinary.rendering.viewMask = 3;
    SPIRVToMSLConversionConfiguration config;
    ordinary.configure(config);
    check(config.options.mslOptions.multiview_layered_rendering, "Ordinary multiview changed");
    std::cout << "PASS: production admission rejects multibit/device-index/TES and exhausted/wrapped slots; single-bit masks and ordinary options preserved\n";
}
static void checkConversion(const std::string& directory) {
    auto vertex = readSPIRV(directory + "/vert.spv");
    SPIRVToMSLConverter converter;
    for (uint32_t mask : {0u, 1u, 32u}) {
        Pipeline pipeline;
        pipeline.rendering.viewMask = mask;
        pipeline.slots(nullptr);
        SPIRVToMSLConversionConfiguration capture;
        pipeline.configure(capture);
        capture.options.entryPointName = "main";
        capture.options.entryPointStage = spv::ExecutionModelVertex;
        auto& options = capture.options.mslOptions;
        options.set_msl_version(2, 4);
        options.capture_output_to_buffer = true;
        options.disable_rasterization = true;
        options.shader_output_buffer_index = pipeline.slot(MVKImplicitBuffer::Output);
        options.indirect_params_buffer_index = pipeline.slot(MVKImplicitBuffer::IndirectParams);
        options.view_mask_buffer_index = pipeline.slot(MVKImplicitBuffer::ViewRange);
        options.shader_index_buffer_index = pipeline.slot(MVKImplicitBuffer::Index);
        capture.exportCapturedVertexLayout = true;
        MSLCapturedVertexLayout layout;
        for (auto indexType : {CompilerMSL::Options::IndexType::None, CompilerMSL::Options::IndexType::UInt16, CompilerMSL::Options::IndexType::UInt32}) {
            options.vertex_for_tessellation = indexType != CompilerMSL::Options::IndexType::None;
            options.vertex_index_type = indexType;
            converter.setSPIRV(vertex.data(), vertex.size());
            SPIRVToMSLConversionResult result;
            auto config = capture;
            check(converter.convert(config, result), result.resultLog.c_str());
            check(result.resultInfo.needsViewRangeBuffer == bool(mask), "Producer ViewRange binding missing or unnecessary");
            check(result.msl.find("render_target_array_index") == std::string::npos, "Capture emits a layered output");
            check(result.msl.find("spvViewMask[1]") == std::string::npos, "Capture divides/remaps application instances");
            check(!mask || result.msl.find("gl_ViewIndex = spvViewMask[0]") != std::string::npos, "Capture ViewIndex is not the selected view");
            if (indexType == CompilerMSL::Options::IndexType::None) {
                check(result.msl.find("(gl_InstanceIndex - gl_BaseInstance) * spvIndirectParams[0] + gl_VertexIndex - gl_BaseVertex") != std::string::npos, "Direct capture lost base-instance/base-vertex normalization");
            } else {
                check(result.msl.find("gl_GlobalInvocationID.y * spvStageInputSize.x + gl_GlobalInvocationID.x") != std::string::npos, "Indexed capture lost dense occurrence addressing");
                check(result.msl.find("gl_GlobalInvocationID.y + spvDispatchBase.y") != std::string::npos && result.msl.find("spvIndices[gl_GlobalInvocationID.x] + spvDispatchBase.x") != std::string::npos, "Indexed capture lost application instance/vertex indices");
            }
            check(result.resultInfo.capturedVertexLayout.stride > 0, "Missing capture ABI");
            if (indexType == CompilerMSL::Options::IndexType::None) { layout = result.resultInfo.capturedVertexLayout; }
            else { check(MSLPerVertexInputBuffer{true, layout, {}}.matches(MSLPerVertexInputBuffer{true, result.resultInfo.capturedVertexLayout, {}}), "Direct/indexed ABI differs"); }
            writeMSL(directory + "/capture-" + std::to_string(mask) + "-" + std::to_string(unsigned(indexType)) + ".metal", result.msl);
        }
        for (bool captured : {false, true}) {
            auto words = readSPIRV(directory + (captured ? "/frag.spv" : "/bary.frag.spv"));
            converter.setSPIRV(words.data(), words.size());
            SPIRVToMSLConversionConfiguration fragment;
            pipeline.configure(fragment);
            fragment.options.entryPointStage = spv::ExecutionModelFragment;
            fragment.options.entryPointName = "main";
            fragment.options.mslOptions.set_msl_version(2, 4);
            fragment.options.mslOptions.view_mask_buffer_index = 27;
            if (captured) { fragment.setPerVertexInputBuffer(layout, {26, 25, 2}); }
            fragment.setFragmentBarycentricInput({3, 4});
            SPIRVToMSLConversionResult result;
            check(converter.convert(fragment, result), result.resultLog.c_str());
            check(result.resultInfo.needsViewRangeBuffer == bool(mask), "Fragment ViewRange missing");
            check(result.resultInfo.needsPerVertexInputBuffer == captured, "Fragment captured-input mode lost");
            check(!mask || result.msl.find("gl_ViewIndex = spvViewMask[0]") != std::string::npos, "Fragment ViewIndex is not selected view");
            check(result.msl.find("render_target_array_index") == std::string::npos, "Fragment requires missing replay layer");
            writeMSL(directory + "/fragment-" + std::to_string(mask) + "-" + std::to_string(captured) + ".metal", result.msl);
        }
        CompilerMSL replay(vertex);
        auto replayConfig = capture.options.mslOptions;
        replayConfig.vertex_for_tessellation = false;
        replayOptions(replayConfig);
        replay.set_msl_options(replayConfig);
        auto replayMSL = replay.compile_captured_output_replay(layout, {0, 1, 2, 2}, {3, 3, 4}, {1});
        check(replayMSL.find("spvViewMask") == std::string::npos && replayMSL.find("render_target_array_index") == std::string::npos, "Replay reevaluates multiview");
        writeMSL(directory + "/replay-" + std::to_string(mask) + ".metal", replayMSL);
    }
    std::cout << "PASS: 9 direct/indexed captures, 6 PerVertex/barycentric fragments, 3 replay shaders; ViewIndex constant and capture ABI identical\n";
}
int main(int argc, char** argv) {
    try {
        check(argc == 2, "Usage: pervertex-single-view-tests output-directory");
        checkAdmission();
        checkConversion(argv[1]);
        return 0;
    } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
