#!/bin/bash
# Copyright (c) 2026 Jean-Philippe Meunier
# SPDX-License-Identifier: Apache-2.0
# Portable PerVertexKHR barycentric weights under MSAA, static against dynamic topology, one case at a time. The mode is
# validated (Metal API and GPU validation) or plain (none). The MSL MoltenVK generates is dumped per case
# (MVK_CONFIG_SHADER_DUMP_DIR), so that two modes can be compared image by image and shader by shader.
# Exit 4 of a case is the open defect: static and dynamic identical, PerVertexKHR above the CTS threshold.
# Usage: run-pervertex-msaa-weights-tests.sh <libMoltenVK> <output directory> <validated|plain> <expected exit> <case>...
set -euo pipefail
test_dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$test_dir/../.." && pwd)
library=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
output=$(mkdir -p "$2" && cd "$2" && pwd)
mode=$3 expected=$4
[[ $mode == validated || $mode == plain ]] || { echo "Unknown mode $mode"; exit 2; }
shaders=$output/shaders
program=$output/pervertex-msaa-weights
mkdir -p "$shaders" "$output/runs"
exec > >(tee -a "$output/run.log") 2>&1
if [[ ! -x $program ]]; then
	sw_vers
	echo "test_tree=$(git -C "$root" rev-parse HEAD) dirty_tests=$(git -C "$root" status --porcelain -- "$test_dir/PerVertexMSAAWeightsTests.mm" "$test_dir/pervertex-msaa-weights.vert" "$test_dir/pervertex-msaa-weights.frag" "$0" | wc -l | tr -d ' ')"
	[[ -f $(dirname "$library")/PROVENANCE.txt ]] && cat "$(dirname "$library")/PROVENANCE.txt"
	compile() { glslangValidator -V --target-env vulkan1.1 "${@:3}" "$test_dir/$1" -o "$shaders/$2" > /dev/null; spirv-val --target-env vulkan1.1 "$shaders/$2"; }
	compile pervertex-msaa-weights.vert msaa-weights.vert.spv
	compile pervertex-msaa-weights.frag msaa-offset.frag.spv -DOFFSET
	compile pervertex-msaa-weights.frag msaa-sample.frag.spv -DSAMPLE
	compile pervertex-msaa-weights.frag msaa-reference.frag.spv
	xcrun clang++ -arch arm64 -std=c++17 -O2 -Wall -Wextra -Werror -Wno-missing-field-initializers -I"$root/External/Vulkan-Headers/include" \
		"$test_dir/PerVertexMSAAWeightsTests.mm" "$library" -Wl,-rpath,"$(dirname "$library")" -framework Metal -framework Foundation -o "$program"
	shasum -a 256 "$library" "$shaders"/*.spv "$program" "$test_dir/PerVertexMSAAWeightsTests.mm" "$test_dir/pervertex-msaa-weights.vert" "$test_dir/pervertex-msaa-weights.frag" > "$output/INPUTS.sha256"
fi
validation=()
[[ $mode == plain ]] || validation=(MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1)
for name in "${@:5}"; do
	run=$output/runs/$mode-$name
	if [[ -e $run ]]; then echo "STOP: $run already exists"; exit 1; fi
	mkdir -p "$run"
	rc=0
	(cd "$run" && env -u DYLD_LIBRARY_PATH -u DYLD_INSERT_LIBRARIES -u MTL_DEBUG_LAYER -u MTL_SHADER_VALIDATION ${validation[@]+"${validation[@]}"} \
		MVK_CONFIG_LOG_LEVEL=2 MVK_CONFIG_SHADER_DUMP_DIR="$run/msl" gtimeout -k 2 60 "$program" "$shaders" "$name" "$run") > "$run/run.log" 2>&1 || rc=$?
	verdict=PASS
	[[ $rc == "$expected" ]] || verdict=FAIL
	if [[ $mode == validated ]]; then
		grep -q 'Metal API Validation Enabled' "$run/run.log" || verdict=FAIL
		grep -q 'Metal GPU Validation Enabled' "$run/run.log" || verdict=FAIL
	elif grep -q 'Validation Enabled' "$run/run.log"; then verdict=FAIL; fi
	if grep -qiE 'Shader Validation|GPU Address Sanitizer|validation error|Execution of the command buffer was aborted|execution failed' "$run/run.log"; then verdict=FAIL; fi
	printf '%s:%s exit=%s %s\n' "$mode" "$name" "$rc" "$verdict"
	grep -E '^(covered|PerVertexKHR|reference|PERVERTEX_MSAA)|mvk-error' "$run/run.log" | sed 's/^/    /' | cut -c1-200 || true
	if [[ $verdict != PASS ]]; then echo "STOP: inspect $run/run.log before any further GPU work"; exit 1; fi
done
