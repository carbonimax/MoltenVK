#!/bin/bash
# Copyright (c) 2026 Jean-Philippe Meunier
# SPDX-License-Identifier: Apache-2.0
# Ordinary tessellation draws beyond the float32 level scratch limit, recorded directly, in a secondary command buffer
# or with dynamic patch control points,
# with prefill (encoded while recording) and without (encoded during vkQueueSubmit, synchronously or asynchronously).
# Each must be refused while recording, or by vkQueueSubmit without side effects. The draws never reach the GPU: the
# only GPU work is a clear and a copy per case. Then ordinary tessellation draws within the limit, direct, indexed and
# indirect, must still render: the check must not refuse them. Builds the shipping library from the committed HEAD.
# Usage: run-scratch-submit.sh <output directory>
set -euo pipefail
tes=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$tes/../../.." && pwd)
output=$(mkdir -p "${1:?output directory}" && cd "$1" && pwd)
mkdir -p "$output/shaders" "$output/runs"
exec > >(tee "$output/run.log") 2>&1
head=$(git -C "$root" rev-parse HEAD)
git -C "$root" diff --quiet HEAD -- MoltenVK MoltenVKShaderConverter ExternalRevisions || { echo "Commit the sources first: the library is built from HEAD"; exit 1; }
echo "moltenvk_head=$head spirv_cross_head=$(git -C "$root/External/SPIRV-Cross" rev-parse HEAD)"
compile() { glslangValidator -V --target-env vulkan1.1 "${@:3}" "$tes/$1" -o "$output/shaders/$2" > /dev/null; spirv-val --target-env vulkan1.1 "$output/shaders/$2"; }
compile topology.vert topology.vert.spv
compile topology.tesc topology.tesc.spv
compile topology.tese ccw.tese.spv
compile topology.tese cw.tese.spv -DCW
compile topology.tese capture-ccw.tese.spv -DCAPTURE
compile topology.tese capture-cw.tese.spv -DCAPTURE -DCW
compile ordinary.frag ordinary.frag.spv
tree=$output/shipping/src
rm -rf "$tree" && mkdir -p "$tree/External"
git -C "$root" archive HEAD | tar -x -C "$tree"
for dependency in SPIRV-Cross SPIRV-Tools Volk Vulkan-Headers Vulkan-Tools cereal; do ln -s "$(cd "$root/External/$dependency" && pwd -P)" "$tree/External/$dependency"; done
bash "$tree/MoltenVK/Tests/PerVertexTES/build-library.sh" "$output/shipping" OFF OFF > /dev/null
cat "$output/shipping/PROVENANCE.txt"
lib=$output/shipping/build/moltenvk/MoltenVK
xcrun clang++ -std=c++17 -arch arm64 -O1 -Wall -Wextra -Werror -Wno-missing-field-initializers -DVK_ENABLE_BETA_EXTENSIONS -I"$root/External/Vulkan-Headers/include" "$tes/topology.cpp" "$lib/libMoltenVK.1.4.3.dylib" -Wl,-rpath,"$lib" -Wl,-U,_mvkEnableTESFixtureDevice -o "$output/shipping/topology"
pass=0 fail=0
run() { # scenario winding prefill sync shader-validation
	local name=$1-$2-prefill$3-sync$4 rc=0 verdict=PASS
	local log=$output/runs/$name.log
	(cd "$output/runs" && env -u DYLD_LIBRARY_PATH -u DYLD_INSERT_LIBRARIES MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=$5 MVK_CONFIG_LOG_LEVEL=2 \
		MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS=$3 MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=$4 \
		gtimeout -k 2 60 "$output/shipping/topology" "$output/shaders" "$1" "$2" "$name") > "$log" 2>&1 || rc=$?
	[[ $rc == 0 ]] || verdict=FAIL
	grep -q 'Metal API Validation Enabled' "$log" || verdict=FAIL
	[[ $5 == 0 ]] || grep -q 'Metal GPU Validation Enabled' "$log" || verdict=FAIL
	if grep -qiE 'Shader Validation|validation error|Execution of the command buffer was aborted|execution failed' "$log"; then verdict=FAIL; fi
	grep -q 'TES_TOPOLOGY PASS' "$log" || verdict=FAIL
	[[ $verdict == PASS ]] && pass=$((pass + 1)) || fail=$((fail + 1))
	last=$verdict
	printf '%-66s exit=%s %s\n' "$name" "$rc" "$verdict"
	grep -E '^secondary|^TES_TOPOLOGY|mvk-error' "$log" | sed 's/^/    /' || true
}
# Prefill first: it encodes while recording and submits nothing, so it shows that encoding omits the draw before any
# case can submit it.
for scenario in ordinary-levels-scratch-limit ordinary-levels-indexed-scratch-limit ordinary-levels-secondary-scratch-limit ordinary-levels-indexed-secondary-scratch-limit ordinary-levels-dynamic-scratch-limit; do
	run "$scenario" ccw 1 1 1
	if [[ $last != PASS ]]; then echo "    SKIP no-prefill runs of $scenario: encoding did not refuse the draw"; continue; fi
	for sync in 1 0; do run "$scenario" ccw 0 "$sync" 1; done
done
# Within the limit, without prefill: the recording check must not refuse these draws. The indirect scenarios
# run without shader validation, as in the TES runner.
for command in direct indexed; do run "ordinary-levels-$command" ccw 0 1 1; done
for command in indirect indexed-indirect; do run "ordinary-levels-$command" ccw 0 1 0; done
run ordinary-levels-direct cw 0 1 1
( cd "$output" && shasum -a 256 shaders/* shipping/PROVENANCE.txt shipping/topology runs/* shipping/build/moltenvk/MoltenVK/libMoltenVK.1.4.3.dylib > EVIDENCE.sha256 )
echo "SCRATCH_SUBMIT pass=$pass fail=$fail on $head"
