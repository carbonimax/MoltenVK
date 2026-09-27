#!/bin/bash
# Copyright (c) 2026 Jean-Philippe Meunier
# SPDX-License-Identifier: Apache-2.0
# First MoltenVK mesh path (VK_EXT_mesh_shader behind the test device adapter) under Metal API and GPU validation.
# Builds from the committed HEAD of this checkout: a development library with the test adapter and a shipping
# library. Stops at the first unexpected result.
# Usage: run-pervertex-mesh-tests.sh <output directory>
set -euo pipefail
test_dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$test_dir/../.." && pwd)
output=$(mkdir -p "${1:?output directory}" && cd "$1" && pwd)
mkdir -p "$output/shaders" "$output/runs"
exec > >(tee "$output/run.log") 2>&1
head=$(git -C "$root" rev-parse HEAD)
git -C "$root" diff --quiet HEAD -- MoltenVK MoltenVKShaderConverter ExternalRevisions || { echo "Commit the sources first: libraries are built from HEAD"; exit 1; }
echo "moltenvk_head=$head spirv_cross_head=$(git -C "$root/External/SPIRV-Cross" rev-parse HEAD)"
mesh=$test_dir/PerVertexMesh
compile() { glslangValidator -V --target-env vulkan1.3 "${@:3}" "$mesh/$1" -o "$output/shaders/$2" > /dev/null 2>&1; spirv-val --target-env vulkan1.3 "$output/shaders/$2"; }
compile mesh.mesh mesh.mesh.spv
compile mesh.mesh grid.mesh.spv -DGRID
compile mesh.mesh descriptor.mesh.spv -DDESCRIPTOR
compile mesh.mesh per-primitive.mesh.spv -DPER_PRIMITIVE
compile task.task task.task.spv
compile interp.frag interp.frag.spv
for name in dev shipping; do
	tree=$output/$name/src
	rm -rf "$tree" && mkdir -p "$tree/External"
	git -C "$root" archive HEAD | tar -x -C "$tree"
	for dependency in SPIRV-Cross SPIRV-Tools Volk Vulkan-Headers Vulkan-Tools cereal; do ln -s "$(cd "$root/External/$dependency" && pwd -P)" "$tree/External/$dependency"; done
	device=$([[ $name == dev ]] && echo ON || echo OFF)
	bash "$tree/MoltenVK/Tests/PerVertexTES/build-library.sh" "$output/$name" OFF "$device" > /dev/null
	cat "$output/$name/PROVENANCE.txt"
	lib=$output/$name/build/moltenvk/MoltenVK
	xcrun clang++ -std=c++17 -arch arm64 -O1 -Wall -Wextra -Werror -Wno-missing-field-initializers -I"$root/External/Vulkan-Headers/include" "$mesh/mesh-draw.cpp" "$lib/libMoltenVK.1.4.3.dylib" -Wl,-rpath,"$lib" -Wl,-U,_mvkEnableMeshTestDevice -o "$output/$name/mesh-draw"
done
cases=0
run() { # library scenario
	local log=$output/runs/$1-$2.log rc=0 verdict=PASS
	(cd "$output/runs" && env -u DYLD_LIBRARY_PATH -u DYLD_INSERT_LIBRARIES MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 MVK_CONFIG_LOG_LEVEL=2 gtimeout -k 2 60 "$output/$1/mesh-draw" "$output/shaders" "$2") > "$log" 2>&1 || rc=$?
	[[ $rc == 0 ]] || verdict=FAIL
	grep -q 'Metal API Validation Enabled' "$log" || verdict=FAIL
	grep -q 'Metal GPU Validation Enabled' "$log" || verdict=FAIL
	if grep -qiE 'Shader Validation|validation error|Execution of the command buffer was aborted|execution failed' "$log"; then verdict=FAIL; fi
	grep -q "MESH_DRAW PASS" "$log" || verdict=FAIL
	cases=$((cases + 1))
	printf '%-36s exit=%s %s\n' "$1-$2" "$rc" "$verdict"
	grep -E '^  |^MESH_DRAW|^VK_EXT|^DEVICE' "$log" | sed 's/^/    /' | head -6
	if [[ $verdict != PASS ]]; then echo "STOP: inspect $log before any further GPU work"; exit 1; fi
}
for scenario in draw grid twice reject-task reject-descriptor reject-per-primitive reject-indirect no-adapter; do run dev "$scenario"; done
run shipping public-device-gate
rm -f "$output"/runs/*.rgba
( cd "$output" && shasum -a 256 shaders/* */PROVENANCE.txt runs/* dev/build/moltenvk/MoltenVK/libMoltenVK.1.4.3.dylib shipping/build/moltenvk/MoltenVK/libMoltenVK.1.4.3.dylib > EVIDENCE.sha256 )
git -C "$root" ls-files -s MoltenVK MoltenVKShaderConverter ExternalRevisions > "$output/SOURCE-INDEX.txt"
echo "PERVERTEX_MESH PASS: $cases cases on $head"
