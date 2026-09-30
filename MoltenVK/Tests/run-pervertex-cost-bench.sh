#!/bin/bash
# Copyright (c) 2026 Jean-Philippe Meunier
# SPDX-License-Identifier: Apache-2.0
# Cost of the portable PerVertexKHR path against an ordinary draw (PerVertexCostBench.mm), direct and indexed, on a
# 64 x 64 and a 256 x 256 grid of quads.
#   1. Correctness: each form once under Metal API and GPU validation, with a few samples; it must pass.
#   2. Calibration: each form without the anchor fill, so that timestamp A lands after the first Metal encoder.
#   3. Timing: three series without Metal validation, alternating the first arm and the order of the forms.
# Before each step the runner refuses to start if another GPU test is running, and it records the thermal state and
# the busiest processes. Timing runs set MoltenVK's performance tracking, synchronous submits and no prefill.
# Usage: run-pervertex-cost-bench.sh <libMoltenVK> <output directory> <samples per series>
set -euo pipefail
test_dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$test_dir/../.." && pwd)
library=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
output=$(mkdir -p "$2" && cd "$2" && pwd)
samples=$3
shaders=$output/shaders
program=$output/pervertex-cost-bench
mkdir -p "$shaders" "$output/runs"
exec > >(tee -a "$output/run.log") 2>&1
{
	sw_vers; uname -m; xcodebuild -version | tr '\n' ' '; echo
	sysctl -n machdep.cpu.brand_string
	echo "test_tree=$(git -C "$root" rev-parse HEAD) dirty_tests=$(git -C "$root" status --porcelain -- "$test_dir/PerVertexCostBench.mm" "$test_dir/pervertex-cost.vert" "$test_dir/pervertex-cost.frag" "$0" | wc -l | tr -d ' ')"
	[[ -f $(dirname "$library")/PROVENANCE.txt ]] && cat "$(dirname "$library")/PROVENANCE.txt"
	echo "samples_per_series=$samples"
} > "$output/ENVIRONMENT.txt"
cat "$output/ENVIRONMENT.txt"
compile() { glslangValidator -V --target-env vulkan1.1 "${@:3}" "$test_dir/$1" -o "$shaders/$2" > /dev/null; spirv-val --target-env vulkan1.1 "$shaders/$2"; }
compile pervertex-cost.vert cost.vert.spv
compile pervertex-cost.vert cost-indexed.vert.spv -DINDEXED
compile pervertex-cost.vert cost-256.vert.spv -DGRID=256u
compile pervertex-cost.vert cost-indexed-256.vert.spv -DINDEXED -DGRID=256u
compile pervertex-cost.frag cost-ordinary.frag.spv
compile pervertex-cost.frag cost-pervertex.frag.spv -DPERVERTEX
xcrun clang++ -arch arm64 -std=c++17 -O2 -Wall -Wextra -Werror -Wno-missing-field-initializers -I"$root/External/Vulkan-Headers/include" -I"$root/MoltenVK/MoltenVK/API" \
	"$test_dir/PerVertexCostBench.mm" "$library" -Wl,-rpath,"$(dirname "$library")" -framework Metal -framework Foundation -o "$program"
shasum -a 256 "$library" "$shaders"/*.spv "$program" "$test_dir/PerVertexCostBench.mm" "$test_dir/pervertex-cost.vert" "$test_dir/pervertex-cost.frag" "$0" > "$output/INPUTS.sha256"

quiet() {
	local busy
	busy=$(pgrep -fl 'deqp-vk|pervertex-(indirect|dynamic|msaa|tes|mesh|continuation|loss)|sample-shading-strip|xctrace' | grep -v "$$" || true)
	if [[ -n $busy ]]; then echo "STOP: another GPU workload is running:"; echo "$busy"; exit 1; fi
}
state() {
	{ date -u; pmset -g therm 2>/dev/null; ps -Ao pid,pcpu,pmem,comm -r | awk 'NR <= 8'; } > "$1"
}
step() { # name expected-exit validated(0|1) form grid samples order [--no-anchor]
	local name=$1 expected=$2 validated=$3 run=$output/runs/$1
	if [[ -e $run ]]; then echo "STOP: $run already exists"; exit 1; fi
	mkdir -p "$run"
	quiet
	state "$run/state-before.txt"
	local rc=0 env=(MVK_CONFIG_LOG_LEVEL=1 MVK_CONFIG_PERFORMANCE_TRACKING=1 MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=1 MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS=0)
	if [[ $validated == 1 ]]; then env+=(MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1); fi
	(cd "$run" && env -u DYLD_LIBRARY_PATH -u DYLD_INSERT_LIBRARIES -u MTL_DEBUG_LAYER -u MTL_SHADER_VALIDATION "${env[@]}" \
		gtimeout -k 2 300 "$program" "$shaders" "${@:4}") > "$run/run.log" 2>&1 || rc=$?
	state "$run/state-after.txt"
	local verdict=PASS
	[[ $rc == "$expected" ]] || verdict=FAIL
	grep -q '^PERVERTEX_COST PASS' "$run/run.log" || verdict=FAIL
	if [[ $validated == 1 ]]; then
		grep -q 'Metal API Validation Enabled' "$run/run.log" || verdict=FAIL
		grep -q 'Metal GPU Validation Enabled' "$run/run.log" || verdict=FAIL
	elif grep -q 'Validation Enabled' "$run/run.log"; then verdict=FAIL; fi
	if grep -qiE 'Shader Validation|GPU Address Sanitizer|validation error|Execution of the command buffer was aborted|execution failed' "$run/run.log"; then verdict=FAIL; fi
	printf '%-28s exit=%s %s\n' "$name" "$rc" "$verdict"
	grep -E '^(images|BENCH)' "$run/run.log" | grep -E 'images|paired_difference|memory' | sed 's/^/    /' | cut -c1-160 || true
	if [[ $verdict != PASS ]]; then echo "STOP: inspect $run/run.log"; exit 1; fi
}
for grid in 64 256; do
	step validated-direct-$grid 0 1 direct $grid 2 ordinary-first
	step validated-indexed-$grid 0 1 indexed $grid 2 ordinary-first
	step calibration-direct-$grid 0 0 direct $grid "$samples" ordinary-first --no-anchor
	step calibration-indexed-$grid 0 0 indexed $grid "$samples" ordinary-first --no-anchor
done
for grid in 64 256; do
	step series1-direct-$grid 0 0 direct $grid "$samples" ordinary-first
	step series1-indexed-$grid 0 0 indexed $grid "$samples" ordinary-first
	step series2-indexed-$grid 0 0 indexed $grid "$samples" pervertex-first
	step series2-direct-$grid 0 0 direct $grid "$samples" pervertex-first
	step series3-direct-$grid 0 0 direct $grid "$samples" ordinary-first
	step series3-indexed-$grid 0 0 indexed $grid "$samples" ordinary-first
done
echo "COST_BENCH DONE"
