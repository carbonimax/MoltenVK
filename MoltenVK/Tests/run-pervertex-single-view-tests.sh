#!/bin/bash
# Copyright (c) 2026 Jean-Philippe Meunier
# SPDX-License-Identifier: Apache-2.0
# CPU conversion and Metal syntax only; never creates a Metal device.
set -euo pipefail
test_dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$test_dir/../.." && pwd)
cross_source=${1:?SPIRV-Cross source required}
cross_build=${2:?SPIRV-Cross library build required}
output=${3:?Output directory required}
mkdir -p "$output"
python3 - "$root" "$output" <<'PY'
from pathlib import Path
import os, sys
root, output = map(Path, sys.argv[1:])
source = Path(os.environ.get('MVK_SINGLE_VIEW_PIPELINE_SOURCE', root / 'MoltenVK/MoltenVK/GPUObjects/MVKPipeline.mm')).read_text()
# Mutate only the generated test copy; every control must fail the CPU suite.
controls = {
    'slot': ('ids[MVKImplicitBuffer::ViewRange] = getImplicitBufferIndex(stage, 8)', 'ids[MVKImplicitBuffer::ViewRange] = extra'),
    'layered': ('!_usesPerVertexInputBuffer && getPhysicalDevice()->canUseInstancingForMultiview()', 'getPhysicalDevice()->canUseInstancingForMultiview()'),
    'replay': ('options.multiview = false;', 'options.multiview = true;'),
    'capacity': ('if (viewMask && !mvkPerVertexBufferIndexAvailable', 'if (false && !mvkPerVertexBufferIndexAvailable'),
}
control = os.environ.get('MVK_SINGLE_VIEW_NEGATIVE_CONTROL')
if control:
    old, new = controls[control]
    assert source.count(old) == 1
    source = source.replace(old, new)
def between(start, end, text=source):
    first = text.index(start)
    return text[first:text.index(end, first)]
admission = between('\tif (!pVertexSS ||', '\tif (pCreateInfo->pRasterizationState->polygonMode')
admission += between('\tinitReservedVertexAttributeBufferCount(pCreateInfo);', '\t// Replay is generated directly')
slots = between('\t// Set implicit buffer indices', '\n\tconst VkPipelineRenderingCreateInfo* pRendInfo')
start = source.index('    shaderConfig.options.mslOptions.multiview =')
options = source[start:source.index('    shaderConfig.options.mslOptions.view_index_from_device_index', start)]
replay = between('\t\toptions.capture_output_to_buffer = false;', '\t\t// PointSize is captured')
(output / 'SingleViewPipeline.inc').write_text('bool Pipeline::admit(const VkGraphicsPipelineCreateInfo* pCreateInfo) {\nconst void* pVertexSS = this;\nauto unsupported = [&](const char* message) { error = message; return false; };\n' + admission + '\nreturn true;\n}\nvoid Pipeline::slots(const VkGraphicsPipelineCreateInfo* pCreateInfo) {\n' + slots + '\n}\nvoid Pipeline::configure(SPIRVToMSLConversionConfiguration& shaderConfig) {\nconst auto* pRendInfo = &rendering;\n' + options + '\n}\nvoid replayOptions(CompilerMSL::Options& options) {\n' + replay + '\n}\n')
PY
for stage in vert frag; do
    glslangValidator -V --target-env vulkan1.1 "$test_dir/pervertex-single-view.$stage" -o "$output/$stage.spv"
    spirv-val --target-env vulkan1.1 "$output/$stage.spv"
done
glslangValidator -V --target-env vulkan1.1 -DCAPTURED=0 "$test_dir/pervertex-single-view.frag" -o "$output/bary.frag.spv"
spirv-val --target-env vulkan1.1 "$output/bary.frag.spv"
compiler_dir="$root/MoltenVKShaderConverter/MoltenVKShaderConverter"
xcrun clang++ -std=c++17 -O0 -g -DMVK_EXCLUDE_SPIRV_TOOLS=1 -DSPIRV_CROSS_NAMESPACE_OVERRIDE=MVK_spirv_cross \
    -I "$output" -I "$compiler_dir" -I "$root/Common" -I "$cross_source" -I "$root/External/Vulkan-Headers/include" -I "$root/MoltenVK/MoltenVK/Commands" \
    "$test_dir/PerVertexSingleViewTests.cpp" "$compiler_dir/SPIRVToMSLConverter.cpp" "$compiler_dir/SPIRVSupport.cpp" "$compiler_dir/FileSupport.mm" \
    "$cross_build/libspirv-cross-msl.a" "$cross_build/libspirv-cross-glsl.a" "$cross_build/libspirv-cross-reflect.a" "$cross_build/libspirv-cross-core.a" \
    -framework Foundation -o "$output/pervertex-single-view-tests"
"$output/pervertex-single-view-tests" "$output"
count=0
for shader in "$output"/*.metal; do
    xcrun metal -x metal -std=macos-metal2.4 -fno-modules -fsyntax-only "$shader"
    count=$((count + 1))
done
printf 'PASS: %s Metal 2.4 syntax checks; no GPU device or submission\n' "$count"
