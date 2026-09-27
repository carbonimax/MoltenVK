#!/bin/bash
# Copyright (c) 2026 Jean-Philippe Meunier
# SPDX-License-Identifier: Apache-2.0
# Builds an arm64 Debug MoltenVK from this checkout for the TES topology tests.
# Usage: build-library.sh <output> <admission ON|OFF> <test device ON|OFF> [extra CMake source define]
# ADMISSION defines MVK_TEST_TES_PERVERTEX_ADMISSION; TEST_DEVICE links EnableTestDevice.mm. Neither is
# ever part of shipping CMake/Xcode targets, and the public extension gate is not edited.
set -euo pipefail
test_dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$test_dir/../../.." && pwd)
output=$(mkdir -p "$1" && cd "$1" && pwd)
admission=$2 device=$3 extra=${4:-}
mkdir -p "$output/driver"
cat > "$output/driver/CMakeLists.txt" <<CMAKE
cmake_minimum_required(VERSION 3.21)
project(PerVertexTESTopology LANGUAGES C CXX OBJC OBJCXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(SPIRV_CROSS_NAMESPACE_OVERRIDE MVK_spirv_cross CACHE STRING "" FORCE)
set(SPIRV_CROSS_CLI OFF CACHE BOOL "" FORCE)
set(SPIRV_CROSS_ENABLE_TESTS OFF CACHE BOOL "" FORCE)
set(SPIRV_CROSS_SKIP_INSTALL ON CACHE BOOL "" FORCE)
add_subdirectory("$root/External/SPIRV-Cross" spirv-cross EXCLUDE_FROM_ALL)
add_library(SPRIV-Cross INTERFACE)
add_library(SPRIV-Cross::SPRIV-Cross ALIAS SPRIV-Cross)
target_link_libraries(SPRIV-Cross INTERFACE spirv-cross-core spirv-cross-reflect spirv-cross-glsl spirv-cross-msl)
add_library(cereal INTERFACE)
add_library(cereal::cereal ALIAS cereal)
target_include_directories(cereal INTERFACE "$root/External/cereal/include")
add_library(Vulkan-Headers INTERFACE)
add_library(Vulkan::Headers ALIAS Vulkan-Headers)
target_include_directories(Vulkan-Headers INTERFACE "$root/External/Vulkan-Headers/include")
set(MVK_EXCLUDE_SPIRV_TOOLS ON CACHE BOOL "" FORCE)
set(MOLTEN_VK_WITH_CCACHE OFF CACHE BOOL "" FORCE)
add_subdirectory("$root" moltenvk)
if($device)
  target_sources(MoltenVK PRIVATE "$root/MoltenVK/Tests/PerVertexTES/EnableTestDevice.mm")
endif()
if($admission)
  target_compile_definitions(MoltenVK PRIVATE MVK_TEST_TES_PERVERTEX_ADMISSION=1)
endif()
CMAKE
if [[ -n "$extra" ]]; then echo "target_compile_definitions(MoltenVK PRIVATE $extra)" >> "$output/driver/CMakeLists.txt"; fi
cross=$(cd "$root/External/SPIRV-Cross" && pwd -P)
test "$(git -C "$cross" rev-parse HEAD)" = "$(cat "$root/ExternalRevisions/SPIRV-Cross_repo_revision")"
git -C "$cross" diff --quiet HEAD
cmake -S "$output/driver" -B "$output/build" -G Ninja -DCMAKE_BUILD_TYPE=Debug -DCMAKE_OSX_ARCHITECTURES=arm64 > "$output/configure.log" 2>&1
cmake --build "$output/build" --target MoltenVK -j "$(sysctl -n hw.ncpu)" > "$output/build.log" 2>&1
library=$output/build/moltenvk/MoltenVK/libMoltenVK.1.4.3.dylib
{
	echo "moltenvk_head=$(git -C "$root" rev-parse HEAD) dirty_files=$(git -C "$root" status --porcelain --untracked-files=no | wc -l | tr -d ' ')"
	echo "spirv_cross_head=$(git -C "$cross" rev-parse HEAD)"
	echo "admission=$admission test_device=$device extra=${extra:-none}"
	echo "library_sha256=$(shasum -a 256 "$library" | cut -d' ' -f1)"
} | tee "$output/PROVENANCE.txt"
