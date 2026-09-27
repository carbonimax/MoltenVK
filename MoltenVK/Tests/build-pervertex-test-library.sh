#!/bin/bash
# Copyright (c) 2026 Jean-Philippe Meunier
# SPDX-License-Identifier: Apache-2.0
# Builds an arm64 Release MoltenVK from one committed revision, with a single test-only change:
# the macOS KHR/NV barycentric extension gate is opened in the generated snapshot, never in the tree.
# Usage: build-pervertex-test-library.sh <git revision> <output directory>
set -euo pipefail
test_dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$test_dir/../.." && pwd)
revision=$(git -C "$root" rev-parse "${1:?revision}^{commit}")
output=$(mkdir -p "${2:?output directory}" && cd "$2" && pwd)
snapshot=$output/snapshot
external=$output/snapshot/External
rm -rf "$snapshot"
mkdir -p "$external"
git -C "$root" archive "$revision" | tar -x -C "$snapshot"
for dependency in SPIRV-Cross SPIRV-Tools Volk Vulkan-Headers Vulkan-Tools cereal; do
	ln -s "$(cd "$root/External/$dependency" && pwd -P)" "$external/$dependency"
done
# The SPIRV-Cross checkout must be the pinned commit without local changes.
cross=$external/SPIRV-Cross
test "$(git -C "$cross" rev-parse HEAD)" = "$(cat "$snapshot/ExternalRevisions/SPIRV-Cross_repo_revision")"
git -C "$cross" diff --quiet HEAD
device=$snapshot/MoltenVK/MoltenVK/GPUObjects/MVKDevice.mm
perl -0pi -e 's/if \(MVK_MACOS \|\| !_metalFeatures\.shaderBarycentricCoordinates\) \{\n\t\tpWritableExtns->vk_KHR_fragment_shader_barycentric\.enabled = false;/if (false) { \/\/ Test-only: expose the unfinished extension in this isolated source snapshot.\n\t\tpWritableExtns->vk_KHR_fragment_shader_barycentric.enabled = false;/' "$device"
git -C "$root" show "$revision:MoltenVK/MoltenVK/GPUObjects/MVKDevice.mm" | diff - "$device" > "$output/test-gate.diff" && { echo "Test gate not applied"; exit 1; } || true
test "$(grep -c '^[<>]' "$output/test-gate.diff")" = 2
cmake -S "$snapshot" -B "$output/arm64" -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
	-DCPM_SOURCE_CACHE="$output/cpm-cache" -DCPM_SPIRV-Cross_SOURCE="$cross" \
	-DCPM_SPIRV-Headers_SOURCE="$external/SPIRV-Tools/external/spirv-headers" -DCPM_SPIRV-Tools_SOURCE="$external/SPIRV-Tools" \
	-DCPM_cereal_SOURCE="$external/cereal" -DCPM_Vulkan-Headers_SOURCE="$external/Vulkan-Headers" > "$output/configure.log" 2>&1
cmake --build "$output/arm64" --target MoltenVK -j "$(sysctl -n hw.ncpu)" > "$output/build.log" 2>&1
library=$output/arm64/MoltenVK/libMoltenVK.1.4.3.dylib
{
	echo "moltenvk_revision=$revision"
	echo "spirv_cross_revision=$(git -C "$cross" rev-parse HEAD)"
	echo "library_sha256=$(shasum -a 256 "$library" | cut -d' ' -f1)"
} | tee "$output/PROVENANCE.txt"
