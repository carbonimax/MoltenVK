#!/bin/bash
# Copyright (c) 2026 Jean-Philippe Meunier
# SPDX-License-Identifier: Apache-2.0
# Ordinary tessellation draws beyond the float32 level scratch limit, recorded directly or in a secondary command buffer,
# with prefill (encoded while recording) and without (encoded during vkQueueSubmit, synchronously or asynchronously).
# Each must be refused while recording, or by vkQueueSubmit without side effects. The draws never reach the GPU: the
# only GPU work is a clear and a copy per case. Builds the shipping library from the committed HEAD of this checkout.
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
for scenario in ordinary-levels-scratch-limit ordinary-levels-indexed-scratch-limit ordinary-levels-secondary-scratch-limit ordinary-levels-indexed-secondary-scratch-limit; do
	for mode in prefill1 prefill0-sync1 prefill0-sync0; do
		prefill=${mode:7:1} sync=1
		[[ $mode == *sync0 ]] && sync=0
		log=$output/runs/$scenario-$mode.log rc=0 verdict=PASS
		(cd "$output/runs" && env -u DYLD_LIBRARY_PATH -u DYLD_INSERT_LIBRARIES MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 MVK_CONFIG_LOG_LEVEL=2 \
			MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS=$prefill MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=$sync \
			gtimeout -k 2 60 "$output/shipping/topology" "$output/shaders" "$scenario" ccw "$scenario-$mode") > "$log" 2>&1 || rc=$?
		[[ $rc == 0 ]] || verdict=FAIL
		grep -q 'Metal API Validation Enabled' "$log" || verdict=FAIL
		grep -q 'Metal GPU Validation Enabled' "$log" || verdict=FAIL
		if grep -qiE 'Shader Validation|validation error|Execution of the command buffer was aborted|execution failed' "$log"; then verdict=FAIL; fi
		[[ $verdict == PASS ]] && pass=$((pass + 1)) || fail=$((fail + 1))
		printf '%-60s exit=%s %s\n' "$scenario-$mode" "$rc" "$verdict"
		grep -E '^secondary|^TES_TOPOLOGY|mvk-error' "$log" | sed 's/^/    /'
	done
done
( cd "$output" && shasum -a 256 shaders/* shipping/PROVENANCE.txt shipping/topology runs/* shipping/build/moltenvk/MoltenVK/libMoltenVK.1.4.3.dylib > EVIDENCE.sha256 )
echo "SCRATCH_SUBMIT pass=$pass fail=$fail on $head"
