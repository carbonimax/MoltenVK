#!/bin/bash
# Copyright (c) 2026 Jean-Philippe Meunier
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
test_dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$test_dir/../.." && pwd)
output=${1:?Output directory required}
mkdir -p "$output/driver" "$output/shaders"
output=$(cd "$output" && pwd)
for name in triangle.vert triangle.tesc ordered.tese ordered.frag ordered-swapped.frag wrong-patch.frag control.frag noop.comp; do
    glslangValidator -V --target-env vulkan1.1 "$test_dir/PerVertexTES/$name" -o "$output/shaders/$name.spv"
    spirv-val --target-env vulkan1.1 "$output/shaders/$name.spv"
done
sed 's/= 1.0;/= 2.0;/g' "$test_dir/PerVertexTES/triangle.tesc" > "$output/shaders/factor2.tesc"
glslangValidator -V --target-env vulkan1.1 "$output/shaders/factor2.tesc" -o "$output/shaders/factor2.tesc.spv"
spirv-val --target-env vulkan1.1 "$output/shaders/factor2.tesc.spv"
python3 - "$output" "$root" <<'PY'
from pathlib import Path
import sys,struct
out,root=map(Path,sys.argv[1:])
header=['#pragma once', '#include <algorithm>', 'template<class C, size_t N> static bool mvkMatchesTESFixture(const C& words, const uint32_t (&fixture)[N]) { return words.size() == N && std::equal(words.begin(), words.end(), fixture); }']
for name,symbol in [('triangle.vert','Vertex'),('triangle.tesc','Control'),('ordered.tese','Evaluation'),('ordered.frag','Ordered'),('ordered-swapped.frag','Swapped'),('wrong-patch.frag','WrongPatch')]:
 data=(out/'shaders'/f'{name}.spv').read_bytes();words=struct.unpack('<'+'I'*(len(data)//4),data)
 header.append('static constexpr uint32_t mvkTES'+symbol+'[] = {'+','.join(hex(x) for x in words)+'};')
(out/'fixture.h').write_text('\n'.join(header)+'\n')
(out/'driver/CMakeLists.txt').write_text('''cmake_minimum_required(VERSION 3.21)
project(PerVertexTESIntegration LANGUAGES C CXX OBJC OBJCXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(SPIRV_CROSS_NAMESPACE_OVERRIDE MVK_spirv_cross CACHE STRING "" FORCE)
set(SPIRV_CROSS_CLI OFF CACHE BOOL "" FORCE)
set(SPIRV_CROSS_ENABLE_TESTS OFF CACHE BOOL "" FORCE)
set(SPIRV_CROSS_SKIP_INSTALL ON CACHE BOOL "" FORCE)
add_subdirectory("'''+str(root/ 'External/SPIRV-Cross')+'''" spirv-cross EXCLUDE_FROM_ALL)
add_library(SPRIV-Cross INTERFACE)
add_library(SPRIV-Cross::SPRIV-Cross ALIAS SPRIV-Cross)
target_link_libraries(SPRIV-Cross INTERFACE spirv-cross-core spirv-cross-reflect spirv-cross-glsl spirv-cross-msl)
add_library(cereal INTERFACE)
add_library(cereal::cereal ALIAS cereal)
target_include_directories(cereal INTERFACE "'''+str(root/'External/cereal/include')+'''")
add_library(Vulkan-Headers INTERFACE)
add_library(Vulkan::Headers ALIAS Vulkan-Headers)
target_include_directories(Vulkan-Headers INTERFACE "'''+str(root/'External/Vulkan-Headers/include')+'''")
set(MVK_EXCLUDE_SPIRV_TOOLS ON CACHE BOOL "" FORCE)
set(MOLTEN_VK_WITH_CCACHE OFF CACHE BOOL "" FORCE)
add_subdirectory("'''+str(root)+'''" moltenvk)
option(TES_TEST_DEVICE "Link internal test device adapter" ON)
if(TES_TEST_DEVICE)
  target_sources(MoltenVK PRIVATE "'''+str(root/'MoltenVK/Tests/PerVertexTES/EnableTestDevice.mm')+'''")
endif()
option(TES_FIXTURE "Enable only the exact TES integration test fixture" ON)
if(TES_FIXTURE)
  target_compile_definitions(MoltenVK PRIVATE MVK_TEST_TES_PERVERTEX_FIXTURE="'''+str(out/'fixture.h')+'''")
endif()
''')
PY
xcrun clang++ -std=c++17 -fblocks -Wall -Wextra -Werror -Wno-return-type -I"$root/MoltenVK/MoltenVK/Commands" -I"$root/MoltenVK/MoltenVK/GPUObjects" -I"$root/External/Vulkan-Headers/include" "$test_dir/PerVertexTES/ScratchTests.mm" -framework Foundation -framework Metal -o "$output/tes-scratch"
"$output/tes-scratch" > "$output/scratch.log"
shasum -a 256 "$root/External/SPIRV-Cross/spirv_msl.cpp" "$root/External/SPIRV-Cross/spirv_msl.hpp" > "$output/compiler-before.sha256"
cmake -S "$output/driver" -B "$output/build" -G Ninja -DCMAKE_BUILD_TYPE=Debug -DCMAKE_OSX_ARCHITECTURES=arm64 -DTES_FIXTURE=ON -DTES_TEST_DEVICE=ON > "$output/configure.log" 2>&1
cmake --build "$output/build" --target MoltenVK -j 4 > "$output/build.log" 2>&1
lib="$output/build/moltenvk/MoltenVK/libMoltenVK.1.4.3.dylib"
xcrun clang++ -std=c++17 -arch arm64 -DVK_ENABLE_BETA_EXTENSIONS -I"$root/External/Vulkan-Headers/include" "$test_dir/PerVertexTES/main.cpp" "$lib" -Wl,-rpath,"$(dirname "$lib")" -o "$output/tes-vulkan"
run() {
    local mode=$1 fragment=$2 control=${3:-triangle.tesc}
    MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 MVK_CONFIG_LOG_LEVEL=1 MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS=0 "$output/tes-vulkan" "$output/shaders/triangle.vert.spv" "$output/shaders/$control.spv" "$output/shaders/ordered.tese.spv" "$output/shaders/$fragment.spv" "$mode" "$output/shaders/noop.comp.spv" > "$output/$mode.log" 2>&1
    cat "$output/$mode.log"
}
run control control.frag
mv "$output/control.log" "$output/control-fixture-build.log"
run ordered ordered.frag
for mode in ordered-compute reject-first-compute reject-first-instance-compute; do run "$mode" ordered.frag; done
run swapped ordered-swapped.frag
run wrong-patch wrong-patch.frag
run reject-factor ordered.frag factor2.tesc
for mode in reject-cache reject-patch-size reject-specialization reject-count reject-instance reject-first reject-indexed; do run "$mode" ordered.frag; done
cp "$lib" "$output/libMoltenVK-fixture.dylib"
# Same sources, shipping admission: rebuild without the fixture macro.
cmake -S "$output/driver" -B "$output/build" -DTES_FIXTURE=OFF > "$output/public-configure.log" 2>&1
cmake --build "$output/build" --target MoltenVK -j 4 > "$output/public-build.log" 2>&1
run reject-public ordered.frag
run control control.frag
cp "$lib" "$output/libMoltenVK-public-gate.dylib"
shasum -a 256 "$root/External/SPIRV-Cross/spirv_msl.cpp" "$root/External/SPIRV-Cross/spirv_msl.hpp" > "$output/compiler-after.sha256"
cmp "$output/compiler-before.sha256" "$output/compiler-after.sha256"
cmake -S "$output/driver" -B "$output/build" -DTES_FIXTURE=OFF -DTES_TEST_DEVICE=OFF > "$output/shipping-configure.log" 2>&1
cmake --build "$output/build" --target MoltenVK -j 4 > "$output/shipping-build.log" 2>&1
run public-device-gate ordered.frag
cp "$lib" "$output/libMoltenVK-shipping.dylib"
