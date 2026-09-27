#!/bin/bash
# Copyright (c) 2026 Jean-Philippe Meunier
# SPDX-License-Identifier: Apache-2.0
# First MoltenVK mesh path (VK_EXT_mesh_shader behind the test device adapter) under Metal API and GPU validation.
# Builds from the committed HEAD of this checkout: a development library with the test adapter and a shipping
# library. Before any GPU work, a CPU preflight checks that the form models tell their rivals apart and that every
# PerVertexKHR pipeline links its corner varyings by name and type, in MSL that Metal accepts. Stops at the first
# unexpected result. --cpu-only stops after the preflight, without the shipping library and without any GPU work.
# Usage: run-pervertex-mesh-tests.sh <output directory> [--cpu-only]
set -euo pipefail
test_dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$test_dir/../.." && pwd)
output=$(mkdir -p "${1:?output directory}" && cd "$1" && pwd)
cpu_only=$([[ ${2:-} == --cpu-only ]] && echo 1 || true)
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
compile mesh.mesh draw-id.mesh.spv -DDRAW_ID
# glslang declares DrawIndex as int, which SPIRV-Cross cannot yet compile for a mesh; HLSL compilers declare it as
# uint, which compiles and would dereference the unbound spvDrawIndex: build that form too.
spirv-dis "$output/shaders/draw-id.mesh.spv" | perl -0pe 's/(%gl_DrawIDARB = OpVariable %_ptr_Input_)int/${1}uint/; if (s/(%\w+) = OpLoad %int %gl_DrawIDARB/$1 = OpLoad %uint %gl_DrawIDARB/) { my $id = $1; s/OpConvertSToF %float \Q$id\E\b/OpConvertUToF %float $id/; }' > "$output/shaders/draw-id-uint.spvasm"
spirv-as --target-env vulkan1.3 "$output/shaders/draw-id-uint.spvasm" -o "$output/shaders/draw-id-uint.mesh.spv"
spirv-val --target-env vulkan1.3 "$output/shaders/draw-id-uint.mesh.spv"
grep -q 'OpLoad %uint %gl_DrawIDARB' "$output/shaders/draw-id-uint.spvasm"
compile mesh.mesh buffer-address.mesh.spv -DBUFFER_ADDRESS
compile mesh.mesh permuted.mesh.spv -DPERMUTED
compile mesh.mesh block.mesh.spv -DBLOCK_OUTPUT
compile mesh.mesh matrix.mesh.spv -DMATRIX_OUTPUT
compile task.task task.task.spv
compile interp.frag interp.frag.spv
compile pervertex.frag pervertex.frag.spv
compile pervertex.frag pervertex-swapped.frag.spv -DSWAPPED
compile pervertex.frag barycentric.frag.spv -DBARYCENTRIC
compile pervertex.frag pervertex-consistency.frag.spv -DCONSISTENCY
compile pervertex.frag pervertex-block.frag.spv -DBLOCK
compile pervertex.frag pervertex-matrix.frag.spv -DMATRIX
compile forms.mesh forms.mesh.spv
compile forms.mesh forms16.mesh.spv -DSIXTEEN
compile forms.mesh forms-grid.mesh.spv -DGRID
compile forms.mesh forms-resource.mesh.spv -DRESOURCE
compile resource.frag resource.frag.spv
forms="uint swapped ivec2 vec3 uvec3 components fewer scalar array1 array2 half int16 uint16 mixed"
for form in $forms; do compile forms.frag "form-$form.frag.spv" "-D$(tr a-z A-Z <<< "$form")"; done
for name in dev $([[ $cpu_only ]] || echo shipping); do
	tree=$output/$name/src
	rm -rf "$tree" && mkdir -p "$tree/External"
	git -C "$root" archive HEAD | tar -x -C "$tree"
	for dependency in SPIRV-Cross SPIRV-Tools Volk Vulkan-Headers Vulkan-Tools cereal; do ln -s "$(cd "$root/External/$dependency" && pwd -P)" "$tree/External/$dependency"; done
	device=$([[ $name == dev ]] && echo ON || echo OFF)
	bash "$tree/MoltenVK/Tests/PerVertexTES/build-library.sh" "$output/$name" OFF "$device" > /dev/null
	cat "$output/$name/PROVENANCE.txt"
	lib=$output/$name/build/moltenvk/MoltenVK
	xcrun clang++ -std=c++17 -arch arm64 -O1 -Wall -Wextra -Werror -Wno-missing-field-initializers -I"$root/External/Vulkan-Headers/include" "$mesh/mesh-draw.cpp" "$lib/libMoltenVK.1.4.3.dylib" -Wl,-rpath,"$lib" -Wl,-U,_mvkEnableMeshTestDevice -Wl,-U,_mvkEnableTESFixtureDevice -o "$output/$name/mesh-draw"
done

preflight=$output/preflight
mkdir -p "$preflight"
build=$output/dev/build
xcrun clang++ -std=c++17 -arch arm64 -O1 -Wall -Wextra -Werror -DMVK_EXCLUDE_SPIRV_TOOLS=1 -DSPIRV_CROSS_NAMESPACE_OVERRIDE=MVK_spirv_cross \
	-I"$root/MoltenVKShaderConverter/MoltenVKShaderConverter" -I"$root/Common" -I"$root/External/SPIRV-Cross" -I"$root/External/cereal/include" "$mesh/corner-link.cpp" \
	"$build/moltenvk/MoltenVKShaderConverter/MoltenVKShaderConverter/libMoltenVK_ShaderConverter.a" "$build/moltenvk/Common/libMoltenVK_Common.a" \
	"$build/spirv-cross/libspirv-cross-reflect.a" "$build/spirv-cross/libspirv-cross-msl.a" "$build/spirv-cross/libspirv-cross-glsl.a" "$build/spirv-cross/libspirv-cross-core.a" \
	-framework Foundation -o "$output/dev/corner-link"
# CPU only: mesh-draw computes its models without creating a Vulkan instance.
"$output/dev/mesh-draw" "$output/shaders" model-check > "$preflight/model-check.log" 2>&1 || { cat "$preflight/model-check.log"; echo "STOP: form models before any GPU work"; exit 1; }
tail -1 "$preflight/model-check.log"
link() { # name mesh fragment [expected status: 3 for a refused form]
	local log=$preflight/$1.log rc=0
	(cd "$preflight" && "$output/dev/corner-link" "$output/shaders/$2" "$output/shaders/$3" "$1") > "$log" 2>&1 || rc=$?
	if [[ $rc != "${4:-0}" ]]; then cat "$log"; echo "STOP: corner-link $1 exit=$rc before any GPU work"; exit 1; fi
	tail -1 "$log" | sed 's/^/    /'
}
link pervertex mesh.mesh.spv pervertex.frag.spv
link pervertex-swapped mesh.mesh.spv pervertex-swapped.frag.spv
link pervertex-permuted permuted.mesh.spv pervertex.frag.spv
link pervertex-block-output block.mesh.spv pervertex.frag.spv
link pervertex-consistency permuted.mesh.spv pervertex-consistency.frag.spv
link reject-pervertex-block block.mesh.spv pervertex-block.frag.spv 3
link reject-pervertex-matrix matrix.mesh.spv pervertex-matrix.frag.spv 3
for form in $forms; do
	case $form in half|int16|uint16) link "form-$form" forms16.mesh.spv "form-$form.frag.spv" ;; *) link "form-$form" forms.mesh.spv "form-$form.frag.spv" ;; esac
done
link form-grid forms-grid.mesh.spv form-mixed.frag.spv
link resource forms-resource.mesh.spv resource.frag.spv
# A mesh translated with a zero workgroup size never leaves its output loops (SPIRV-Cross before 8cd36d69).
if grep -l 'gl_WorkGroupSize \[\[maybe_unused\]\] = uint3(0, 0, 0)' "$preflight"/*.mesh.metal; then echo "STOP: zero mesh workgroup size would hang the GPU"; exit 1; fi
syntax=0
for msl in "$preflight"/*.metal; do
	xcrun metal -x metal -std=metal3.2 -fsyntax-only "$msl" > "$msl.syntax.log" 2>&1 || { cat "$msl.syntax.log"; echo "STOP: Metal syntax of $msl before any GPU work"; exit 1; }
	syntax=$((syntax + 1))
done
echo "PREFLIGHT PASS: form models, corner links and $syntax Metal 3.2 syntax checks (CPU only)"
git -C "$root" ls-files -s MoltenVK MoltenVKShaderConverter ExternalRevisions > "$output/SOURCE-INDEX.txt"
if [[ $cpu_only ]]; then
	( cd "$output" && shasum -a 256 shaders/* dev/PROVENANCE.txt preflight/* dev/build/moltenvk/MoltenVK/libMoltenVK.1.4.3.dylib > EVIDENCE.sha256 )
	echo "PERVERTEX_MESH CPU-ONLY PASS on $head: no GPU work"
	exit 0
fi

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
for scenario in draw grid twice pervertex pervertex-swapped pervertex-permuted pervertex-block-output barycentric barycentric-permuted pervertex-consistency \
	$(for form in $forms grid; do echo "form-$form"; done) resource-bda resource-bda-other reject-task reject-descriptor reject-per-primitive reject-pervertex-block reject-pervertex-matrix reject-specialization reject-indirect \
	reject-draw-id reject-draw-id-uint reject-buffer-address no-adapter; do run dev "$scenario"; done
run shipping public-device-gate
rm -f "$output"/runs/*.rgba
( cd "$output" && shasum -a 256 shaders/* */PROVENANCE.txt preflight/* runs/* dev/build/moltenvk/MoltenVK/libMoltenVK.1.4.3.dylib shipping/build/moltenvk/MoltenVK/libMoltenVK.1.4.3.dylib > EVIDENCE.sha256 )
echo "PERVERTEX_MESH PASS: $cases cases on $head"
