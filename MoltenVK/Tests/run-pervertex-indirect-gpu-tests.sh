#!/bin/bash
# Copyright (c) 2026 Jean-Philippe Meunier
# SPDX-License-Identifier: Apache-2.0
# Short GPU matrix for portable PerVertexKHR indirect draws, with Metal API and GPU validation.
# Usage: run-pervertex-indirect-gpu-tests.sh <after libMoltenVK> <before libMoltenVK> <output directory>
# Every case stops the matrix on an unexpected result, so no further GPU work follows a failure.
set -euo pipefail
test_dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$test_dir/../.." && pwd)
after=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
before=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
output=$(mkdir -p "$3" && cd "$3" && pwd)
shaders=$output/shaders
mkdir -p "$shaders" "$output/runs"
exec > >(tee "$output/matrix.log") 2>&1
sw_vers
uname -m
glslangValidator --version | head -1
compile() { glslangValidator -V --target-env vulkan1.1 "${@:3}" "$test_dir/$1" -o "$shaders/$2" > /dev/null; spirv-val --target-env vulkan1.1 "$shaders/$2"; }
compile pervertex-indirect.vert indirect.vert.spv
compile pervertex-indirect.vert reference.vert.spv -DREFERENCE
compile pervertex-indirect.frag pervertex.frag.spv
compile pervertex-indirect.frag pervertex-swap.frag.spv -DSWAP
compile pervertex-indirect-args.comp args.comp.spv
for variant in after before; do
	library=${!variant}
	xcrun clang++ -arch arm64 -std=c++17 -O2 -Wall -Wextra -Werror -Wno-missing-field-initializers -I"$root/External/Vulkan-Headers/include" \
		"$test_dir/PerVertexIndirectGPUTests.cpp" "$library" -Wl,-rpath,"$(dirname "$library")" -o "$output/pervertex-indirect-gpu-$variant"
done
shasum -a 256 "$after" "$before" "$shaders"/*.spv "$output"/pervertex-indirect-gpu-* > "$output/INPUTS.sha256"
echo 'case,expected_exit,actual_exit,verdict' > "$output/results.csv"
cases=0
run() {
	local name=$1 variant=$2 expected=$3 capacity=$4 swap=$5; shift 5
	local log=$output/runs/$name.log rc=0
	(cd "$output/runs" && env -u DYLD_LIBRARY_PATH -u DYLD_INSERT_LIBRARIES MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 \
		MVK_CONFIG_LOG_LEVEL=2 MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS="${PREFILL:-0}" MVK_PERVERTEX_INDIRECT_RECORD_CAPACITY="$capacity" \
		PERVERTEX_TEST_SWAP_FRAGMENT="$swap" PERVERTEX_TEST_TOPOLOGY="${TOPOLOGY:-triangle-list}" gtimeout -k 2 30 "$output/pervertex-indirect-gpu-$variant" "$shaders" "$@" "$name") > "$log" 2>&1 || rc=$?
	local verdict=PASS
	[[ $rc == "$expected" ]] || verdict=FAIL
	grep -q 'Metal API Validation Enabled' "$log" || verdict=FAIL
	grep -q 'Metal GPU Validation Enabled' "$log" || verdict=FAIL
	# A GPU fault also loses the device: only the admission message may explain an expected loss.
	if grep -qiE 'Shader Validation|GPU Address Sanitizer|validation error|Execution of the command buffer was aborted|execution failed' "$log"; then verdict=FAIL; fi
	case $* in
		*index-oob*) grep -q 'reads indices beyond the bound index buffer' "$log" || verdict=FAIL ;;
		*overflow*|*huge*) grep -q 'exceeds the reserved capture capacity' "$log" || verdict=FAIL ;;
		*) if grep -q 'indirect command was not executed' "$log"; then verdict=FAIL; fi ;;
	esac
	case $expected in
		0) grep -q '^PERVERTEX_INDIRECT PASS' "$log" || verdict=FAIL ;;
		2) grep -q '^PERVERTEX_INDIRECT FAIL' "$log" && grep -qE 'pixel_mismatches=[1-9]' "$log" || verdict=FAIL ;;
		1) grep -q 'End command buffer: -8' "$log" || verdict=FAIL ;;
	esac
	echo "$name,$expected,$rc,$verdict" >> "$output/results.csv"
	cases=$((cases + 1))
	printf '%-58s exit=%s %s\n' "$name" "$rc" "$verdict"
	grep -E '^submission=.*indirect' "$log" | sed 's/^/    /' || true
	if [[ $verdict != PASS ]]; then echo "STOP: inspect $log before any further GPU work"; exit 1; fi
}
big=1048576
# 1. Decisive: maxDrawCount 2, arguments/Count/indices written on the GPU, Count 1, two instances,
#    nonzero firstIndex/vertexOffset/firstVertex/firstInstance; every producer and index width.
for producer in update copy compute; do
	for form in draw draw-count; do run "decisive-$form-$producer" after 0 $big 0 $form u32 decisive $producer; done
	for form in indexed indexed-count; do for index in u8 u16 u32; do run "decisive-$form-$index-$producer" after 0 $big 0 $form $index decisive $producer; done; done
done
# 2. GPU count zero (Count forms) or zero instances (other forms), both draws overlapping with
#    DrawID 0/1 and blending (Count 7 is clamped to maxDrawCount 2), and repeated submissions of one
#    command buffer whose GPU-produced arguments change between executions.
for form in draw draw-count indexed indexed-count; do
	run "zero-$form" after 0 $big 0 $form u32 zero compute
	run "two-$form" after 0 $big 0 $form u16 two copy
	run "repeat-$form" after 0 $big 0 $form u32 repeat copy
done
# 3. Capacity: exactly 12 records per draw fits; 11 refuses the whole command, including when only
#    the second draw exceeds it; UINT32_MAX instances and out-of-range indices are refused without hang.
for form in draw draw-count indexed indexed-count; do
	run "capacity12-decisive-$form" after 0 12 0 $form u32 decisive compute
	run "capacity12-two-$form" after 0 12 0 $form u32 two compute
	run "capacity11-overflow-$form" after 0 11 0 $form u32 overflow compute
	run "capacity11-overflow-second-$form" after 0 11 0 $form u32 overflow-second compute
	run "huge-$form" after 0 $big 0 $form u32 huge compute
done
run "index-oob-indexed" after 0 $big 0 indexed u32 index-oob compute
run "index-oob-indexed-count" after 0 $big 0 indexed-count u32 index-oob compute
# 4. Primitive restart on a triangle strip: static restart for every index width, two draws, dynamic
#    restart on and off, and the restart capacity bound (8 indices x 2 instances = 16 records).
for form in indexed indexed-count; do
	for index in u8 u16 u32; do run "restart-$form-$index" after 0 $big 0 $form $index restart copy; done
	run "restart-two-$form" after 0 $big 0 $form u16 restart-two compute
	run "restart-dynamic-on-$form" after 0 $big 0 $form u16 restart-dynamic-on copy
	run "restart-dynamic-off-$form" after 0 $big 0 $form u8 restart-dynamic-off compute
	run "capacity16-restart-$form" after 0 16 0 $form u32 restart compute
	run "capacity15-restart-overflow-$form" after 0 15 0 $form u32 restart-overflow compute
done
# 5. Every other portable topology through the GPU-built replay tables (first-vertex provoking:
#    last-vertex needs the Metal private API; the host kernel test covers both modes), and two heavy
#    overlapping draws where draw 1 rewrites the scratch that draw 0's replay reads.
for topology in point-list line-list line-strip triangle-strip triangle-fan; do
	for form in draw draw-count indexed indexed-count; do TOPOLOGY=$topology run "topology-$topology-$form" after 0 $big 0 $form u16 decisive compute; done
	TOPOLOGY=$topology run "topology-$topology-two-indexed-count" after 0 $big 0 indexed-count u32 two copy
done
for form in draw draw-count indexed indexed-count; do run "stress-$form" after 0 $big 0 $form u32 stress compute; done
# 6. Deferred and immediate Metal command buffer prefill.
for prefill in 1 2; do
	for form in draw draw-count indexed indexed-count; do PREFILL=$prefill run "prefill$prefill-decisive-$form" after 0 $big 0 $form u32 decisive compute; done
	PREFILL=$prefill run "prefill$prefill-restart-indexed-count" after 0 $big 0 indexed-count u16 restart compute
done
# 7. Negative controls: permuted corners must mismatch; the previous library must refuse at recording.
for form in draw draw-count indexed indexed-count; do
	run "swap-negative-$form" after 2 $big 1 $form u32 decisive compute
	run "before-$form" before 1 $big 0 $form u32 decisive compute
done
shasum -a 256 "$output"/runs/* "$output/results.csv" > "$output/EVIDENCE.sha256"
echo "PERVERTEX_INDIRECT_MATRIX PASS: $cases cases"
