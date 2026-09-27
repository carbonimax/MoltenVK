#!/bin/bash
# Copyright (c) 2026 Jean-Philippe Meunier
# SPDX-License-Identifier: Apache-2.0
# GPU-generated PerVertexKHR TES topology tests (test-only admission) with Metal API/GPU validation.
# Builds from the committed HEAD of this checkout: development, no-admission and shipping libraries, plus
# three generator mutations that must fail. Stops at the first unexpected result.
# Usage: run-pervertex-tes-tests.sh <output directory>
set -euo pipefail
test_dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$test_dir/../.." && pwd)
output=$(mkdir -p "${1:?output directory}" && cd "$1" && pwd)
mkdir -p "$output/shaders" "$output/runs"
exec > >(tee "$output/run.log") 2>&1
sw_vers
# Whole outputs: a closed pipe would trip pipefail.
xcodebuild -version > "$output/tools.txt"
glslangValidator --version >> "$output/tools.txt"
cat "$output/tools.txt"
head=$(git -C "$root" rev-parse HEAD)
git -C "$root" diff --quiet HEAD -- MoltenVK MoltenVKShaderConverter ExternalRevisions || { echo "Commit the sources first: libraries are built from HEAD"; exit 1; }
echo "moltenvk_head=$head spirv_cross_head=$(git -C "$root/External/SPIRV-Cross" rev-parse HEAD)"
tes=$test_dir/PerVertexTES
compile() { glslangValidator -V --target-env vulkan1.1 "${@:3}" "$tes/$1" -o "$output/shaders/$2" > /dev/null; spirv-val --target-env vulkan1.1 "$output/shaders/$2"; }
for name in triangle.vert triangle.tesc ordered.tese ordered.frag ordered-swapped.frag wrong-patch.frag control.frag noop.comp; do compile "$name" "$name.spv"; done
compile topology.vert topology.vert.spv
compile topology.vert drawid.vert.spv -DDRAWID
compile topology.vert resources.vert.spv -DRESOURCES
compile topology.tesc push.tesc.spv -DPUSH
compile topology.tesc topology.tesc.spv
compile topology.tesc descriptor.tesc.spv -DDESCRIPTOR
compile topology.tese ccw.tese.spv
compile topology.tese cw.tese.spv -DCW
compile topology.tese capture-ccw.tese.spv -DCAPTURE
compile topology.tese capture-cw.tese.spv -DCAPTURE -DCW
compile topology.tese quads.tese.spv -DQUADS
compile topology.tese fractional.tese.spv -DFRACTIONAL
compile topology.tese points.tese.spv -DPOINTS
compile ordinary.frag ordinary.frag.spv
compile ordinary.frag ordinary-resources.frag.spv -DRESOURCES
compile interp.frag interp.frag.spv
compile interp.frag interp-resources.frag.spv -DRESOURCES
compile flat-ordered.frag flat-ordered.frag.spv
compile flat-ordered.frag flat-swapped.frag.spv -DSWAP
compile consistency.frag consistency.frag.spv
compile coords.frag coords.frag.spv
compile primitive-id.frag primitive-id.frag.spv
compile primitive-id.frag primitive-id-ordinary.frag.spv -DORDINARY
# Host fault injection for the eleven TES scratch allocations.
xcrun clang++ -std=c++17 -fblocks -Wall -Wextra -Werror -Wno-return-type -I"$root/MoltenVK/MoltenVK/Commands" -I"$root/MoltenVK/MoltenVK/GPUObjects" -I"$root/External/Vulkan-Headers/include" "$tes/ScratchTests.mm" -framework Foundation -framework Metal -o "$output/tes-scratch"
"$output/tes-scratch" | tee "$output/scratch.log"

# Libraries from the committed sources; mutations patch an archived copy only.
source_tree() {
	local destination=$1
	rm -rf "$destination" && mkdir -p "$destination/External"
	git -C "$root" archive HEAD | tar -x -C "$destination"
	for dependency in SPIRV-Cross SPIRV-Tools Volk Vulkan-Headers Vulkan-Tools cereal; do ln -s "$(cd "$root/External/$dependency" && pwd -P)" "$destination/External/$dependency"; done
}
library() { # name admission device [sed expression]
	local name=$1 tree=$output/$1/src
	source_tree "$tree"
	if [[ -n ${4:-} ]]; then
		local shader=$tree/MoltenVK/MoltenVK/Commands/MVKCommandPipelineStateFactoryShaderSource.h
		cp "$shader" "$output/$name/original.h"
		perl -pi -e "$4" "$shader"
		diff "$output/$name/original.h" "$shader" > "$output/$name/mutation.diff" && { echo "Mutation $name did not apply"; exit 1; } || true
	fi
	bash "$tree/MoltenVK/Tests/PerVertexTES/build-library.sh" "$output/$name" "$2" "$3" > /dev/null
	cat "$output/$name/PROVENANCE.txt"
	local lib=$output/$name/build/moltenvk/MoltenVK
	for program in topology main; do
		xcrun clang++ -std=c++17 -arch arm64 -O1 -Wall -Wextra -Werror -Wno-missing-field-initializers -DVK_ENABLE_BETA_EXTENSIONS -I"$root/External/Vulkan-Headers/include" "$tes/$program.cpp" "$lib/libMoltenVK.1.4.3.dylib" -Wl,-rpath,"$lib" -Wl,-U,_mvkEnableTESFixtureDevice -o "$output/$name/$program" 2> "$output/$name/$program-build.log" || { cat "$output/$name/$program-build.log"; exit 1; }
	done
}
library dev ON ON
library no-admission OFF ON
library shipping OFF OFF
library mutation-winding ON ON 's/uint slot = p\[2\] && corner \? 3 - corner : corner;/uint slot = !p[2] && corner ? 3 - corner : corner;/'
library mutation-interior ON ON 's/14563 \* q/16384 * q/g'
library mutation-offset ON ON 's/uint key = offsets\[i\] \+ triangle;/uint key = triangle;/'
library mutation-helper-missing ON ON 's/kernel void tessLevelsToHalfFactors\(/kernel void tessLevelsToHalfFactorsUnavailable(/'

cases=0
check_log() { # log expected-exit actual-exit required...
	local log=$1 expected=$2 actual=$3 verdict=PASS; shift 3
	[[ $actual == "$expected" ]] || verdict=FAIL
	grep -q 'Metal API Validation Enabled' "$log" || verdict=FAIL
	[[ ${SHADER_VALIDATION:-1} == 0 ]] || grep -q 'Metal GPU Validation Enabled' "$log" || verdict=FAIL
	if grep -qiE 'Shader Validation|GPU Address Sanitizer|validation error|Execution of the command buffer was aborted|execution failed' "$log"; then verdict=FAIL; fi
	for required in "$@"; do grep -qE -- "$required" "$log" || { verdict=FAIL; echo "    missing: $required"; }; done
	cases=$((cases + 1))
	printf '%-52s exit=%s %s\n' "$(basename "$log" .log)" "$actual" "$verdict"
	grep -E '^  (ordinary vs|barycentric|CPU model|tessellation coordinates|seam|fragment gl_PrimitiveID|VS storage|case|info)|^pipeline rejection|^Pixel|PASS|FAIL' "$log" | grep -v 'Validation Enabled' | sed 's/^/    /' | head -12 || true
	if [[ $verdict != PASS ]]; then echo "STOP: inspect $log before any further GPU work"; exit 1; fi
}
env_run() { env -u DYLD_LIBRARY_PATH -u DYLD_INSERT_LIBRARIES MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION="${SHADER_VALIDATION:-1}" MVK_CONFIG_LOG_LEVEL=2 MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS="${PREFILL:-0}" MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS="${SYNC:-1}" "$@"; }
topology() { # library scenario winding expected-exit required...
	local name=$1-$2-$3${PREFILL:+-prefill$PREFILL}${SYNC:+-sync$SYNC} rc=0
	(cd "$output/runs" && env_run gtimeout -k 2 60 "$output/$1/topology" "$output/shaders" "$2" "$3" "$name") > "$output/runs/$name.log" 2>&1 || rc=$?
	check_log "$output/runs/$name.log" "$4" "$rc" "${@:5}"
}
pilot() { # library mode fragment [control]
	local name=$1-pilot-$2 rc=0
	(cd "$output/runs" && env_run gtimeout -k 2 60 "$output/$1/main" "$output/shaders/triangle.vert.spv" "$output/shaders/${4:-triangle.tesc}.spv" "$output/shaders/ordered.tese.spv" "$output/shaders/$3.spv" "$2" "$output/shaders/noop.comp.spv") > "$output/runs/$name.log" 2>&1 || rc=$?
	check_log "$output/runs/$name.log" 0 "$rc"
}
# 1. Topology from GPU-written float32 levels, both windings, against ordinary TES, the CPU model, the hardware
# tessellation coordinates and Vulkan's fragment gl_PrimitiveID; seams share an edge between two patches.
for winding in ccw cw; do
	for scenario in f1 f2 f3 next mixed nan fraction cull drawid seam1 seam2 seam3; do topology dev "$scenario" "$winding" 0 "TES_TOPOLOGY PASS"; done
	topology dev resources "$winding" 0 "TES_TOPOLOGY PASS" "VS storage counter: expected=9 ordinary=9 pervertex=9"
	for count in 1 2 4 5; do topology dev "vertices$count" "$winding" 0 "TES_TOPOLOGY PASS" "VS storage counter: expected=$count ordinary=$count pervertex=$count"; done
	for scenario in level4 nonuniform inner-nan; do topology dev "$scenario" "$winding" 0 "TES_TOPOLOGY PASS" "PerVertex TES draw was not rendered"; done
done
PREFILL=1 topology dev mixed ccw 0 "TES_TOPOLOGY PASS"
PREFILL=2 topology dev mixed cw 0 "TES_TOPOLOGY PASS"
# 2. Deterministic refusals before submission; ordinary tessellation keeps these modes.
for scenario in reject-quads reject-fractional reject-point-mode reject-lower-left reject-descriptor reject-push-constant reject-cache reject-first-vertex reject-instances; do topology dev "$scenario" ccw 0 "TES_TOPOLOGY PASS"; done
for scenario in reject-indirect-tes reject-indexed-indirect-tes; do topology dev "$scenario" ccw 0 "TES_TOPOLOGY PASS" "vkEndCommandBuffer=-8"; done
topology no-admission reject-no-admission ccw 0 "TES_TOPOLOGY PASS"
topology shipping public-device-gate ccw 0 "TES_TOPOLOGY PASS"
# 2b. Ordinary tessellation keeps float32 TCS levels until Vulkan classification, in every draw command, on the
# shipping library too: the image, tessellation and TES-visible levels match the Vulkan level representative.
# Metal shader validation makes ordinary indirect tessellation draw nothing, before and after this change
# (the VS runs, no TES does): indirect commands run under Metal API validation only.
for library in dev shipping; do
	for command in direct indexed; do topology "$library" "ordinary-levels-$command" ccw 0 "TES_TOPOLOGY PASS"; done
	for command in indirect indexed-indirect; do SHADER_VALIDATION=0 topology "$library" "ordinary-levels-$command" ccw 0 "TES_TOPOLOGY PASS"; done
	topology "$library" ordinary-levels-direct cw 0 "TES_TOPOLOGY PASS"
done
# An ordinary float32 draw beyond the advertised Metal buffer limit must fail during prefill,
# before a GPU submission or an undersized scratch allocation.
# Without prefill, recording must still refuse it, directly or in a secondary: encoding happens after vkQueueSubmit,
# which may already have returned. Both synchronous and asynchronous queue submissions.
for scenario in ordinary-levels-scratch-limit ordinary-levels-indexed-scratch-limit ordinary-levels-secondary-scratch-limit ordinary-levels-indexed-secondary-scratch-limit; do
	PREFILL=1 topology shipping "$scenario" ccw 0 "TES_TOPOLOGY PASS" "nothing submitted"
	for sync in 1 0; do SYNC=$sync topology shipping "$scenario" ccw 0 "TES_TOPOLOGY PASS" "nothing submitted"; done
done
# 3. Pilot guarantees kept: fixture pixels, compute-bind recording guards, refusals.
pilot dev ordered ordered.frag
pilot dev swapped ordered-swapped.frag
pilot dev wrong-patch wrong-patch.frag
pilot dev control control.frag
for mode in ordered-compute reject-first-compute reject-first-instance-compute reject-cache reject-patch-size reject-specialization reject-instance reject-first reject-indexed; do pilot dev "$mode" ordered.frag; done
pilot no-admission reject-public ordered.frag
pilot no-admission control control.frag
# 4. Generator mutations must be caught: reversed winding, moved level-3 interior coordinates, patch offsets ignored.
topology mutation-winding cull ccw 2 "FAIL PerVertex replay matches ordinary TES coverage"
topology mutation-winding f3 ccw 2 "FAIL ordered PerVertex values match the CPU model"
topology mutation-interior f3 ccw 2 "FAIL PerVertex coordinates and positions bitwise equal to the hardware tessellator's"
topology mutation-offset mixed ccw 2 "FAIL PerVertex replay matches ordinary TES coverage"
topology mutation-helper-missing ordinary-levels-direct ccw 1 "Could not find support compute shader function tessLevelsToHalfFactors" "ERROR: Create pipeline case0-levels: -3"
# 5. The float32 level ABI is live in the PerVertex TCS and TES compute kernels.
mkdir -p "$output/dump"
(cd "$output/runs" && env_run MVK_CONFIG_SHADER_DUMP_DIR="$output/dump" "$output/dev/topology" "$output/shaders" next ccw dump-next) > "$output/runs/dump-next.log" 2>&1
grep -l 'device spvTessellationFactorsFloat\* spvTessLevel' "$output"/dump/shader-tcs-*.metal > "$output/float32-tcs.txt"
grep -l 'spvTessellationFactorsFloat' "$output"/dump/shader-tes-*.metal > "$output/float32-tes.txt"
grep -h 'spvTessLevel\[gl_PrimitiveID\]\.outer\[0\]' "$output"/dump/shader-tcs-*.metal | tee "$output/float32-store.txt"
if grep -q 'half(' "$output/float32-store.txt"; then echo "FAIL: TCS level store still converts to half"; exit 1; fi
echo "float32 TessLevel ABI: TCS $(wc -l < "$output/float32-tcs.txt" | tr -d ' ') file(s), TES $(wc -l < "$output/float32-tes.txt" | tr -d ' ') file(s)"
# Unproven ordinary modes keep the half factors: fractional spacing and quads compile their TCS without float32.
for mode in fractional quads; do
	mkdir -p "$output/dump-$mode"
	(cd "$output/runs" && env_run MVK_CONFIG_SHADER_DUMP_DIR="$output/dump-$mode" "$output/dev/topology" "$output/shaders" "reject-$mode" ccw "dump-$mode") > "$output/runs/dump-$mode.log" 2>&1
	grep -l 'TessellationFactorsHalf\* spvTessLevel' "$output/dump-$mode"/shader-tcs-*.metal > "$output/half-$mode.txt"
	if grep -l 'spvTessellationFactorsFloat' "$output/dump-$mode"/shader-tcs-*.metal; then echo "FAIL: unproven $mode TCS uses float32 levels"; exit 1; fi
	echo "half TessLevel ABI kept for ordinary $mode: TCS $(wc -l < "$output/half-$mode.txt" | tr -d ' ') file(s)"
done
( cd "$output" && shasum -a 256 shaders/* */PROVENANCE.txt */mutation.diff runs/* dump/* dump-*/* scratch.log float32-*.txt half-*.txt dev/build/moltenvk/MoltenVK/libMoltenVK.1.4.3.dylib > EVIDENCE.sha256 )
git -C "$root" ls-files -s MoltenVK MoltenVKShaderConverter ExternalRevisions > "$output/SOURCE-INDEX.txt"
echo "PERVERTEX_TES_TOPOLOGY PASS: $cases cases on $head"
