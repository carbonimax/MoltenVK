#!/bin/bash
# Copyright (c) 2026 Jean-Philippe Meunier
# SPDX-License-Identifier: Apache-2.0
# Short, sequential scaling runs of portable PerVertexKHR vkCmdDrawIndirectCount (bound B6), with Metal API and GPU
# validation. Each step is maxDrawCount:count; each writes its own log and stops the list on an unexpected result.
# The output directory can be reused for later steps: the program is built once, and no existing log is overwritten.
# Usage: run-pervertex-indirect-scale-tests.sh <libMoltenVK> <output directory> <maxDrawCount:count>...
set -euo pipefail
test_dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$test_dir/../.." && pwd)
library=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
output=$(mkdir -p "$2" && cd "$2" && pwd)
shaders=$output/shaders
program=$output/pervertex-indirect-scale
mkdir -p "$shaders" "$output/runs"
exec > >(tee -a "$output/scale.log") 2>&1
if [[ ! -x $program ]]; then
	sw_vers
	uname -m
	echo "test_tree=$(git -C "$root" rev-parse HEAD) dirty_tests=$(git -C "$root" status --porcelain -- "$test_dir/PerVertexIndirectScaleTests.mm" "$0" | wc -l | tr -d ' ')"
	[[ -f $(dirname "$library")/PROVENANCE.txt ]] && cat "$(dirname "$library")/PROVENANCE.txt"
	compile() { glslangValidator -V --target-env vulkan1.1 "${@:3}" "$test_dir/$1" -o "$shaders/$2" > /dev/null; spirv-val --target-env vulkan1.1 "$shaders/$2"; }
	compile pervertex-indirect.vert indirect.vert.spv
	compile pervertex-indirect.vert reference.vert.spv -DREFERENCE
	compile pervertex-indirect.frag pervertex-portable.frag.spv -DPORTABLE
	xcrun clang++ -arch arm64 -std=c++17 -O2 -Wall -Wextra -Werror -Wno-missing-field-initializers -I"$root/External/Vulkan-Headers/include" \
		"$test_dir/PerVertexIndirectScaleTests.mm" "$library" -Wl,-rpath,"$(dirname "$library")" -framework Metal -framework Foundation -o "$program"
	shasum -a 256 "$library" "$shaders"/*.spv "$program" "$test_dir/PerVertexIndirectScaleTests.mm" > "$output/INPUTS.sha256"
	echo 'max_draw_count,count,exit,verdict' > "$output/results.csv"
fi
for step in "${@:3}"; do
	max=${step%%:*} count=${step##*:}
	log=$output/runs/max$max-count$count.log
	if [[ -e $log ]]; then echo "STOP: $log already exists"; exit 1; fi
	rc=0
	(cd "$output/runs" && env -u DYLD_LIBRARY_PATH -u DYLD_INSERT_LIBRARIES MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 MVK_CONFIG_LOG_LEVEL=2 \
		gtimeout -k 2 120 "$program" "$shaders" "$max" "$count") > "$log" 2>&1 || rc=$?
	verdict=PASS
	[[ $rc == 0 ]] || verdict=FAIL
	grep -q 'Metal API Validation Enabled' "$log" || verdict=FAIL
	grep -q 'Metal GPU Validation Enabled' "$log" || verdict=FAIL
	if grep -qiE 'Shader Validation|GPU Address Sanitizer|validation error|Execution of the command buffer was aborted|execution failed|VK_ERROR' "$log"; then verdict=FAIL; fi
	grep -q '^PERVERTEX_SCALE PASS' "$log" || verdict=FAIL
	echo "$max,$count,$rc,$verdict" >> "$output/results.csv"
	printf 'max=%s count=%s exit=%s %s\n' "$max" "$count" "$rc" "$verdict"
	grep -E '^(record_ms|run=|pixel_mismatches)' "$log" | sed 's/^/    /' || true
	if [[ $verdict != PASS ]]; then echo "STOP: inspect $log before any further GPU work"; exit 1; fi
done
