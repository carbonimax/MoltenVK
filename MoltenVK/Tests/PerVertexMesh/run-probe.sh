#!/bin/bash
# Copyright (c) 2026 Jean-Philippe Meunier
# SPDX-License-Identifier: Apache-2.0
# Builds the SPIRV-Cross CLI pinned by this checkout, translates the GLSL mesh probe, then runs the Metal mesh probe
# three times: without validation, with Metal API validation, and with API plus shader validation.
# Usage: run-probe.sh <output directory>
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
output=$(mkdir -p "${1:?output directory}" && cd "$1" && pwd)
cross=$(cd "$root/External/SPIRV-Cross" && pwd -P)
{
	sw_vers; xcodebuild -version; xcrun metal --version 2>&1 | head -1; glslangValidator --version | head -1
	echo "moltenvk_head=$(git -C "$root" rev-parse HEAD) spirv_cross=$(git -C "$cross" rev-parse HEAD) spirv_cross_dirty=$(git -C "$cross" status --porcelain --untracked-files=no | wc -l | tr -d ' ')"
} > "$output/PROVENANCE.txt" 2>&1
cat "$output/PROVENANCE.txt"
cmake -S "$cross" -B "$output/spirv-cross" -G Ninja -DCMAKE_BUILD_TYPE=Release -DSPIRV_CROSS_ENABLE_TESTS=OFF > "$output/spirv-cross-configure.log" 2>&1
cmake --build "$output/spirv-cross" --target spirv-cross > "$output/spirv-cross-build.log" 2>&1
spvc=$output/spirv-cross/spirv-cross
for shader in mesh.mesh interp.frag pervertex.frag; do
	glslangValidator -V --target-env vulkan1.3 "$here/$shader" -o "$output/$shader.spv" > /dev/null 2>&1
	spirv-val --target-env vulkan1.3 "$output/$shader.spv"
done
"$spvc" "$output/mesh.mesh.spv" --msl --msl-version 30000 --output "$output/mesh.metal"
# Before SPIRV-Cross 8cd36d69, a LocalSizeId mesh got a zero workgroup size and its output loops hung the GPU.
if grep -q 'gl_WorkGroupSize \[\[maybe_unused\]\] = uint3(0, 0, 0)' "$output/mesh.metal"; then echo "STOP: SPIRV-Cross lacks the LocalSizeId mesh fix (8cd36d69); the translated mesh would hang the GPU"; exit 1; fi
"$spvc" "$output/interp.frag.spv" --msl --msl-version 30000 --output "$output/interp.metal"
"$spvc" "$output/pervertex.frag.spv" --msl --msl-version 40000 --msl-supports-per-vertex-fragment-input --output "$output/pervertex-native.metal"
# Without the native capability or a captured producer layout, SPIRV-Cross has no PerVertexKHR path for this fragment.
if "$spvc" "$output/pervertex.frag.spv" --msl --msl-version 30000 --output "$output/pervertex-default.metal" > "$output/pervertex-default.log" 2>&1; then echo "UNEXPECTED: PerVertexKHR fragment translated without a PerVertex path"; exit 1; fi
echo "default PerVertexKHR translation refused: $(tail -1 "$output/pervertex-default.log")"
xcrun clang++ -std=c++17 -fobjc-arc -Wall -Wextra -Werror "$here/probe.mm" -framework Foundation -framework Metal -o "$output/probe"
status=0
for mode in plain api shader; do
	mkdir -p "$output/$mode"
	case $mode in plain) env=();; api) env=(MTL_DEBUG_LAYER=1);; shader) env=(MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1);; esac
	rc=0
	env ${env[@]+"${env[@]}"} "$output/probe" "$output/$mode" "$here/probe.metal" "$here/probe-vertex-value.metal" --spvc "$output/mesh.metal" "$output/interp.metal" "$output/pervertex-native.metal" > "$output/$mode.log" 2>&1 || rc=$?
	echo "$mode: exit=$rc $(grep MESH_PROBE "$output/$mode.log")"
	[[ $rc == 0 ]] || status=1
done
( cd "$output" && shasum -a 256 PROVENANCE.txt *.spv *.metal probe *.log */*.rgba > EVIDENCE.sha256 )
exit $status
