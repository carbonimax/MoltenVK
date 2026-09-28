#!/bin/bash
# Copyright (c) 2026 Jean-Philippe Meunier
# SPDX-License-Identifier: Apache-2.0
# Short, sequential M4 oracles for PerVertexKHR indirect continuation and queue publication, under Metal API and GPU
# validation (the binary semaphore oracles run without it, as recorded). Each executable loads the library through
# @executable_path/lib, so the same binaries can be rerun against another library for before/after comparisons.
# Usage: run-pervertex-continuation-tests.sh <libMoltenVK.dylib> <output directory> <before|after> [repeats]
# "before" records the expected outcomes of the parent runtime (legal draws beyond the private capacity lose the
# device, dependent work reports success after that loss); "after" requires the continuation outcomes. An expected
# value may list alternatives ("1|2"): in the parent runtime the loss is published by a completion handler that races
# with the dependent work, so the dependent result is either the reported success (1) or the loss (2 when the legal draw
# is lost, 0 when the draw is unrepresentable and its loss is the expected outcome). The optional repeat count reruns
# these racing cases, so results.csv gives the frequency of each outcome. MVK_PERVERTEX_INDIRECT_RECORD_CAPACITY only
# exists in the parent runtime; the continuation ignores it, so the capacity-5 cases are ordinary legal draws after.
# Every case stops the run on an unexpected result, so no further GPU work follows a failure.
set -euo pipefail
test_dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$test_dir/../.." && pwd)
library=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
output=$(mkdir -p "$2" && cd "$2" && pwd)
mode=$3
repeats=${4:-0}
[[ $mode == before || $mode == after ]] || { echo "mode must be before or after"; exit 64; }
mkdir -p "$output/shaders" "$output/runs" "$output/bin/lib"
exec > >(tee "$output/oracles.log") 2>&1
echo "mode=$mode library=$library"
sw_vers
sysctl -n machdep.cpu.brand_string
ln -sf "$library" "$output/bin/lib/libMoltenVK.1.dylib"
compile() { glslangValidator -V --target-env vulkan1.1 "${@:3}" "$test_dir/$1" -o "$output/shaders/$2" > /dev/null; spirv-val --target-env vulkan1.1 "$output/shaders/$2"; }
compile pervertex-indirect.vert indirect.vert.spv
compile pervertex-indirect.vert reference.vert.spv -DREFERENCE
compile pervertex-indirect.frag pervertex.frag.spv
compile pervertex-indirect.frag pervertex-swap.frag.spv -DSWAP
compile pervertex-indirect-args.comp args.comp.spv
flags=(-arch arm64 -std=c++17 -O2 -Wall -Wextra -Werror -Wno-missing-field-initializers -I"$root/External/Vulkan-Headers/include")
xcrun clang++ "${flags[@]}" "$test_dir/PerVertexIndirectGPUTests.cpp" "$library" -Wl,-rpath,@executable_path/lib -o "$output/bin/pervertex-indirect-gpu"
xcrun clang++ "${flags[@]}" "$test_dir/PerVertexBinarySemaphoreOrderTests.mm" "$library" -Wl,-rpath,@executable_path/lib -framework Metal -framework Foundation -o "$output/bin/pervertex-binary-order"
shasum -a 256 "$library" "$output"/shaders/*.spv "$output"/bin/pervertex-* "$test_dir/PerVertexIndirectGPUTests.cpp" "$test_dir/PerVertexBinarySemaphoreOrderTests.mm" > "$output/INPUTS.sha256"
echo 'case,expected_exit,actual_exit,verdict' > "$output/results.csv"
validation=(MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1)
common=(MVK_CONFIG_LOG_LEVEL=2 PERVERTEX_TEST_SPLIT_PRODUCER=1 PERVERTEX_TEST_LATE_SIGNAL=1 PERVERTEX_TEST_DEPENDENT_SUBMISSION=1 PERVERTEX_TEST_WAIT_IDLE=1)
# run <name> <expected before> <expected after> <validated 0|1> <environment...> -- <driver|binary-order> <arguments...>
run() {
	local name=$1 before=$2 after=$3 validated=$4; shift 4
	local vars=()
	while [[ $1 != -- ]]; do vars+=("$1"); shift; done
	shift
	local program=$1; shift
	local expected=${!mode} log=$output/runs/$name.log rc=0
	[[ $validated == 1 ]] && vars+=("${validation[@]}")
	(cd "$output/runs" && gtimeout -k 2 40 env DYLD_PRINT_LIBRARIES=1 "${vars[@]}" "$output/bin/$program" "$@") > "$log" 2>&1 || rc=$?
	local verdict=PASS
	[[ "|$expected|" == *"|$rc|"* ]] || verdict=FAIL
	# dyld resolves the alias and reports the library file actually loaded.
	grep -qF "> $library" "$log" || verdict=FAIL
	[[ " ${vars[*]} " != *" PERVERTEX_TEST_SECONDARY=1 "* ]] || grep -q ' secondary=1 ' "$log" || verdict=FAIL
	[[ " ${vars[*]} " != *" PERVERTEX_TEST_DRAW_TWICE=1 "* ]] || grep -q ' draw_twice=1$' "$log" || verdict=FAIL
	if [[ $validated == 1 ]]; then
		grep -q 'Metal API Validation Enabled' "$log" || verdict=FAIL
		grep -q 'Metal GPU Validation Enabled' "$log" || verdict=FAIL
		if grep -qiE 'Shader Validation|GPU Address Sanitizer|validation error|Execution of the command buffer was aborted' "$log"; then verdict=FAIL; fi
	fi
	echo "$name,$expected,$rc,$verdict" >> "$output/results.csv"
	printf '%-44s expected=%s exit=%s %s\n' "$name" "$expected" "$rc" "$verdict"
	grep -E '^submission=.*indirect|^dependent |^queue idle|^C=|^D_|^B_|^rescued|^external|^ERROR' "$log" | sed 's/^/    /' || true
	if [[ $verdict != PASS ]]; then echo "STOP: inspect $log before any further GPU work"; exit 1; fi
}
sync=(MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=1 MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS=0)
async=(MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=0 MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS=0)
same=(PERVERTEX_TEST_DEPENDENT_SAME_QUEUE=1)
# 1. Legal six-record draw, same-queue C, synchronous submits: red before at private capacity 5, green after.
run single-capacity5-sync 2 0 1 "${sync[@]}" "${common[@]}" "${same[@]}" MVK_PERVERTEX_INDIRECT_RECORD_CAPACITY=5 -- pervertex-indirect-gpu "$output/shaders" draw u32 single compute single5
run single-capacity6-sync 0 0 1 "${sync[@]}" "${common[@]}" "${same[@]}" MVK_PERVERTEX_INDIRECT_RECORD_CAPACITY=6 -- pervertex-indirect-gpu "$output/shaders" draw u32 single compute single6
run single-default-async-cross 0 0 1 "${async[@]}" "${common[@]}" -- pervertex-indirect-gpu "$output/shaders" draw u32 single compute single-async
# 2. Cross-queue C waits on B's semaphore; C's fence is read first. Success, then a draw beyond the capacity (red
#    before: B lost, C success), then a legal draw with UINT32_MAX instances that no uint32 record ID can represent:
#    it must lose the device before or after, and C must never report success after that loss.
run dependent-first-restart-two 0 0 1 "${async[@]}" "${common[@]}" PERVERTEX_TEST_DEPENDENT_FIRST=1 -- pervertex-indirect-gpu "$output/shaders" indexed-count u32 restart-two compute restart-two
run dependent-first-restart-two-capacity5 "1|2" 0 1 "${async[@]}" "${common[@]}" PERVERTEX_TEST_DEPENDENT_FIRST=1 MVK_PERVERTEX_INDIRECT_RECORD_CAPACITY=5 -- pervertex-indirect-gpu "$output/shaders" indexed-count u32 restart-two compute restart-two5
run dependent-first-huge "0|1" 0 1 "${async[@]}" "${common[@]}" PERVERTEX_TEST_DEPENDENT_FIRST=1 -- pervertex-indirect-gpu "$output/shaders" indexed-count u32 huge compute huge-dependent
# 3. Ordinary same-queue C without wait signals a timeline observed on the host before B's fence.
run no-wait-timeline-success 0 0 1 "${async[@]}" "${common[@]}" "${same[@]}" PERVERTEX_TEST_DEPENDENT_NO_WAIT=1 -- pervertex-indirect-gpu "$output/shaders" indexed-count u32 restart-two compute no-wait
run no-wait-timeline-huge "0|1" 0 1 "${async[@]}" "${common[@]}" "${same[@]}" PERVERTEX_TEST_DEPENDENT_NO_WAIT=1 -- pervertex-indirect-gpu "$output/shaders" indexed-count u32 huge compute no-wait-huge
run no-wait-timeline-huge-sync "0|1" 0 1 "${sync[@]}" "${common[@]}" "${same[@]}" PERVERTEX_TEST_DEPENDENT_NO_WAIT=1 -- pervertex-indirect-gpu "$output/shaders" draw u32 huge compute no-wait-huge-sync
# 4. Deferred failure from the GPU index range check, same-queue C in synchronous mode.
run index-oob-sync 0 0 1 "${sync[@]}" "${common[@]}" "${same[@]}" -- pervertex-indirect-gpu "$output/shaders" indexed u32 index-oob compute index-oob
# 5. Binary semaphore oracles, unchanged scenarios (asynchronous submits, no Metal validation, as archived):
#    B/A/C/D is a preexisting pairing defect and must keep its outcome; imported reuse must stay green.
run binary-bacd 1 1 0 MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=0 -- pervertex-binary-order
run binary-imported-reuse 0 0 0 MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=0 -- pervertex-binary-order --imported-reuse
# 6. Secondary command buffers and Metal command buffer prefill. The draw recorded in a secondary pauses the primary's
#    encoder; a loss there stops the primary too. Deferred (1) and immediate (2) prefill encode these draws at submission.
secondary=(PERVERTEX_TEST_SECONDARY=1)
run secondary-single-capacity5-sync 2 0 1 "${sync[@]}" "${common[@]}" "${same[@]}" "${secondary[@]}" MVK_PERVERTEX_INDIRECT_RECORD_CAPACITY=5 -- pervertex-indirect-gpu "$output/shaders" draw u32 single compute secondary-single5
run secondary-restart-two-async 0 0 1 "${async[@]}" "${common[@]}" "${secondary[@]}" PERVERTEX_TEST_DEPENDENT_FIRST=1 -- pervertex-indirect-gpu "$output/shaders" indexed-count u16 restart-two compute secondary-restart-two
run secondary-index-oob-sync 0 0 1 "${sync[@]}" "${common[@]}" "${same[@]}" "${secondary[@]}" -- pervertex-indirect-gpu "$output/shaders" indexed u32 index-oob compute secondary-index-oob
for prefill in 1 2; do
	prefilled=(MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=1 MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS=$prefill)
	run prefill$prefill-single-capacity5-sync 2 0 1 "${prefilled[@]}" "${common[@]}" "${same[@]}" MVK_PERVERTEX_INDIRECT_RECORD_CAPACITY=5 -- pervertex-indirect-gpu "$output/shaders" draw u32 single compute prefill$prefill-single5
	run prefill$prefill-index-oob-sync 0 0 1 "${prefilled[@]}" "${common[@]}" "${same[@]}" -- pervertex-indirect-gpu "$output/shaders" indexed u32 index-oob compute prefill$prefill-index-oob
done
# 7. Two indirect draw commands in one command buffer: the second continues from the Metal command buffer the first
#    opened. When the first loses the device, the second is never encoded.
twice=(PERVERTEX_TEST_DRAW_TWICE=1)
run twice-single-capacity5-sync 2 0 1 "${sync[@]}" "${common[@]}" "${same[@]}" "${twice[@]}" MVK_PERVERTEX_INDIRECT_RECORD_CAPACITY=5 -- pervertex-indirect-gpu "$output/shaders" draw u32 single compute twice-single5
run twice-secondary-restart-two-async 0 0 1 "${async[@]}" "${common[@]}" "${secondary[@]}" "${twice[@]}" PERVERTEX_TEST_DEPENDENT_FIRST=1 -- pervertex-indirect-gpu "$output/shaders" indexed-count u16 restart-two compute twice-secondary-restart-two
run twice-index-oob-sync 0 0 1 "${sync[@]}" "${common[@]}" "${same[@]}" "${twice[@]}" -- pervertex-indirect-gpu "$output/shaders" indexed u32 index-oob compute twice-index-oob
# 8. The racing loss cases again: before they give the frequency of the parent defect, after they must never flip.
for ((i = 1; i <= repeats; ++i)); do
	run dependent-first-restart-two-capacity5-r$i "1|2" 0 1 "${async[@]}" "${common[@]}" PERVERTEX_TEST_DEPENDENT_FIRST=1 MVK_PERVERTEX_INDIRECT_RECORD_CAPACITY=5 -- pervertex-indirect-gpu "$output/shaders" indexed-count u32 restart-two compute restart-two5-r$i
	run dependent-first-huge-r$i "0|1" 0 1 "${async[@]}" "${common[@]}" PERVERTEX_TEST_DEPENDENT_FIRST=1 -- pervertex-indirect-gpu "$output/shaders" indexed-count u32 huge compute huge-dependent-r$i
	run no-wait-timeline-huge-r$i "0|1" 0 1 "${async[@]}" "${common[@]}" "${same[@]}" PERVERTEX_TEST_DEPENDENT_NO_WAIT=1 -- pervertex-indirect-gpu "$output/shaders" indexed-count u32 huge compute no-wait-huge-r$i
	run no-wait-timeline-huge-sync-r$i "0|1" 0 1 "${sync[@]}" "${common[@]}" "${same[@]}" PERVERTEX_TEST_DEPENDENT_NO_WAIT=1 -- pervertex-indirect-gpu "$output/shaders" draw u32 huge compute no-wait-huge-sync-r$i
done
shasum -a 256 "$output"/runs/* "$output/results.csv" > "$output/EVIDENCE.sha256"
echo "PERVERTEX_CONTINUATION $mode PASS: $(($(wc -l < "$output/results.csv") - 1)) cases"
