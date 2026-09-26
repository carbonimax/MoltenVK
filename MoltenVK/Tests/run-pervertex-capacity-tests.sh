#!/bin/bash
# Copyright (c) 2026 Jean-Philippe Meunier
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
test_dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$test_dir/../.." && pwd)
cross_source=${1:?SPIRV-Cross source required}
cross_build=${2:?SPIRV-Cross library build required}
output=${3:?Output directory required}
mkdir -p "$output"
output=$(cd "$output" && pwd)
for locations in 15 31; do
    for density in sparse dense; do
        dense=0
        if [[ "$density" == dense ]]; then dense=1; fi
        name="$locations-$density"
        glslangValidator -V --target-env vulkan1.1 -DLOCATIONS="$locations" -DDENSE="$dense" "$test_dir/pervertex-capacity.vert" -o "$output/$name.vert.spv"
        for mask in 0 1 2 3; do
            for captured in 0 1; do
                if [[ "$mask-$captured" == 0-0 ]]; then continue; fi
                glslangValidator -V --target-env vulkan1.1 -DLOCATIONS="$locations" -DDENSE="$dense" -DCAPTURED="$captured" -DPERSPECTIVE=$((mask & 1)) -DLINEAR=$((mask & 2)) "$test_dir/pervertex-capacity.frag" -o "$output/$name-$mask-$captured.frag.spv"
            done
        done
    done
done
glslangValidator -V --target-env vulkan1.1 -DLOCATIONS=31 -DDENSE=0 -DCAPTURED=0 -DPERSPECTIVE=1 -DLINEAR=1 -DBUFFERS=31 "$test_dir/pervertex-capacity.frag" -o "$output/buffers.frag.spv"
for fixture in "$output"/*.spv; do spirv-val --target-env vulkan1.1 "$fixture"; done
compiler_dir="$root/MoltenVKShaderConverter/MoltenVKShaderConverter"
xcrun clang++ -arch arm64 -std=c++17 -O0 -g -DMVK_EXCLUDE_SPIRV_TOOLS=1 -DSPIRV_CROSS_NAMESPACE_OVERRIDE=MVK_spirv_cross \
    -I "$compiler_dir" -I "$root/Common" -I "$cross_source" -I "$root/External/Vulkan-Headers/include" -I "$root/MoltenVK/MoltenVK/Commands" \
    "$test_dir/PerVertexCapacityTests.cpp" "$compiler_dir/SPIRVToMSLConverter.cpp" "$compiler_dir/SPIRVSupport.cpp" "$compiler_dir/FileSupport.mm" \
    "$cross_build/libspirv-cross-msl.a" "$cross_build/libspirv-cross-glsl.a" "$cross_build/libspirv-cross-reflect.a" "$cross_build/libspirv-cross-core.a" \
    -framework Foundation -o "$output/pervertex-capacity-tests"
"$output/pervertex-capacity-tests" "$output"
for shader in "$output"/*.metal; do xcrun metal -x metal -std=macos-metal2.4 -fno-modules -c "$shader" -o "${shader%.metal}.air"; done
echo "PASS: SPIR-V validation, arm64 CPU conversion and Metal 2.4 AIR compilation; no GPU device or submission"
