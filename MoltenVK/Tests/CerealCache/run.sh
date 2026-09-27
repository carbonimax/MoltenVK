#!/bin/bash
# Copyright 2026 Jean-Philippe Meunier
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
test_dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$test_dir/../../.." && pwd)
output=${1:?Output directory required}
lib=${2:?Debug MoltenVK dylib required}
shader=${3:?No-op compute SPIR-V required}
source=${4:-$root/MoltenVK/MoltenVK/GPUObjects/MVKPipeline.mm}
mkdir -p "$output"
# Use the real serializer and padding declarations; do not maintain a copied archive.
python3 - "$source" "$output/ArchiveDefinitions.h" <<'PY'
from pathlib import Path
import re, sys
source = Path(sys.argv[1]).read_text()
start = source.index('namespace SPIRV_CROSS_NAMESPACE {', source.index('#pragma mark Cereal archive definitions'))
end = source.index('template<class Archive>\nvoid serialize(Archive & archive, MVKShaderModuleKey&', start)
header = source[start:end]
for name, type_name in [('options', 'SPIRV_CROSS_NAMESPACE::CompilerMSL::Options'), ('conversion', 'mvk::SPIRVToMSLConversionOptions'), ('configuration', 'mvk::SPIRVToMSLConversionConfiguration')]:
    padding = re.search(r'mvkValidateCerealArchiveSize<' + re.escape(type_name) + r'>\((\d+)\)', source).group(1)
    header += f'constexpr size_t {name}Padding = {padding};\n'
Path(sys.argv[2]).write_text(header)
PY
xcrun clang++ -std=c++17 -arch arm64 -DSPIRV_CROSS_NAMESPACE_OVERRIDE=MVK_spirv_cross -I"$output" -I"$root/External/SPIRV-Cross" -I"$root/External/cereal/include" -I"$root/MoltenVKShaderConverter/MoltenVKShaderConverter" "$test_dir/Options.cpp" "$lib" -Wl,-rpath,"$(dirname "$lib")" -o "$output/options"
"$output/options"
xcrun clang++ -std=c++17 -arch arm64 -DVK_ENABLE_BETA_EXTENSIONS -I"$root/External/Vulkan-Headers/include" "$test_dir/Cache.cpp" "$lib" -Wl,-rpath,"$(dirname "$lib")" -o "$output/cache"
MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 MVK_CONFIG_LOG_LEVEL=1 "$output/cache" "$shader"
