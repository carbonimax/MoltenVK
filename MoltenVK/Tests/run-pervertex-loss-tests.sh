#!/bin/bash
# Copyright (c) 2026 Jean-Philippe Meunier
# SPDX-License-Identifier: Apache-2.0
# Device loss oracles of PerVertexLossTests.mm, against a MoltenVK test build that exports mvkTestMarkDeviceLost.
# Each mode runs in synchronous and asynchronous queue submission, several times, one run at a time under gtimeout,
# with Metal API and shader validation. The executable loads the library through @executable_path/lib, so the same
# binary runs against another library for before/after comparisons.
# "before" expects each mode to show its defect (exit 1), "after" expects each to pass (exit 0). The teardown modes may
# also crash before (134, 139): a handler then touches the destroyed device. So may the prefill-abandon and metal-error
# modes: a handler then touches a destroyed pool or queue submission. teardown-nil is a control, green on both sides.
# teardown-multi, prefill-abandon-* and metal-error-multi run with deferred prefill. The "before"
# library differs by mode: see the report. external-queue-wait reproduces an open blocker: no library passes it. Its
# verdict is BLOCKER, never PASS, when it shows the outcome documented for the side (before: C runs after the loss is
# reported; after: the loss is not reported within 2 s), and the summary names it. So do external-queue-wait-idle and
# -query, the same blocker through vkQueueWaitIdle and vkGetQueryPoolResults, and shared-queue-block (a healthy second
# device blocked on the Metal queue it shares with a lost one; MVK_CONFIG_MAX_ACTIVE_METAL_COMMAND_BUFFERS_PER_QUEUE=4),
# on both sides. timeline-listener-aba reproduces a defect without a device loss (before: 7758838b).
# Usage: run-pervertex-loss-tests.sh <libMoltenVK test build> <output directory> <before|after> [repeats [modes...]]
set -euo pipefail
test_dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$test_dir/../.." && pwd)
library=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
output=$(mkdir -p "$2" && cd "$2" && pwd)
side=${3:?before or after}
repeats=${4:-3}
modes=("${@:5}")
(( ${#modes[@]} )) || modes=(counter-race binary-generation destroy-after-loss event-wait teardown teardown-multi teardown-nil teardown-nil-transient
	prefill-abandon-reset prefill-abandon-free prefill-abandon-pool prefill-abandon-reset-lost prefill-abandon-free-lost prefill-abandon-pool-lost
	metal-error metal-error-multi metal-error-batches metal-error-batches2 metal-error-calls
	external-queue-wait external-queue-wait-idle external-queue-wait-query shared-queue-block timeline-listener-aba)
[[ $side == before || $side == after ]] || { echo 'side must be before or after'; exit 64; }
# The runner runs again as a child whose output tee records, so that the log is complete when this parent hashes it.
if [[ -z ${PERVERTEX_RUNNER_CHILD:-} ]]; then
	rc=0
	PERVERTEX_RUNNER_CHILD=1 bash "$0" "$@" 2>&1 | tee "$output/loss.log" || rc=$?
	(cd "$output" && shasum -a 256 results.csv loss.log runs/*.log > EVIDENCE.sha256)
	exit "$rc"
fi
mkdir -p "$output/bin/lib" "$output/runs"
ln -sf "$library" "$output/bin/lib/libMoltenVK.1.dylib"
# The sources are copied into the output and hashed there: the evidence stays checkable after they change.
mkdir -p "$output/source" && cp "$test_dir/PerVertexLossTests.mm" "$output/source/"
xcrun clang++ -arch arm64 -std=c++17 -O2 -Wall -Wextra -Werror -Wno-missing-field-initializers -I"$root/External/Vulkan-Headers/include" "$test_dir/PerVertexLossTests.mm" \
	"$library" -Wl,-rpath,@executable_path/lib -framework Metal -framework Foundation -o "$output/bin/pervertex-loss"
shasum -a 256 "$library" "$output/bin/pervertex-loss" "$output/source/PerVertexLossTests.mm" > "$output/INPUTS.sha256"
echo 'case,mode,run,expected,actual,verdict' > "$output/results.csv"
failures=0
blockers=()
for name in "${modes[@]}"; do
	case $side:$name in
		before:teardown | before:teardown-multi | before:prefill-abandon-* | before:metal-error*) expected='1|134|139' ;;
		before:teardown-nil | after:*) expected=0 ;;
		before:*) expected=1 ;;
	esac
	prefill=0 places=64
	[[ $name == teardown-multi || $name == prefill-abandon-* || $name == metal-error-multi ]] && prefill=1
	[[ $name == shared-queue-block ]] && places=4
	for mode in sync async; do
		for run in $(seq 1 "$repeats"); do
			log=$output/runs/$name-$mode-$run.log rc=0
			env -u DYLD_LIBRARY_PATH -u DYLD_INSERT_LIBRARIES MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 MVK_CONFIG_LOG_LEVEL=2 \
				MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=$([[ $mode == sync ]] && echo 1 || echo 0) MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS=$prefill \
				MVK_CONFIG_MAX_ACTIVE_METAL_COMMAND_BUFFERS_PER_QUEUE=$places \
				gtimeout -k 2 40 "$output/bin/pervertex-loss" "$name" > "$log" 2>&1 || rc=$?
			verdict=PASS
			[[ "|$expected|" == *"|$rc|"* ]] || verdict=FAIL
			if [[ $name == external-queue-wait* ]]; then
				blocker=$([[ $side == before ]] && echo RAN_AFTER_REPORT || echo LOSS_NOT_REPORTED)
				verdict=FAIL
				[[ $rc == 1 ]] && grep -q "^EXTERNAL_QUEUE_WAIT $blocker" "$log" && verdict=BLOCKER
			elif [[ $name == shared-queue-block ]]; then
				verdict=FAIL
				[[ $rc == 1 ]] && grep -q '^SHARED_QUEUE BLOCKED' "$log" && verdict=BLOCKER
			fi
			grep -q 'Metal API Validation Enabled' "$log" || verdict=FAIL
			[[ $verdict == BLOCKER ]] && blockers+=("$name-$mode-$run")
			[[ $verdict == PASS || $verdict == BLOCKER ]] || failures=$((failures + 1))
			echo "$name,$mode,$run,$expected,$rc,$verdict" >> "$output/results.csv"
			printf '%-20s %-5s %s exit=%s %s | %s\n' "$name" "$mode" "$run" "$rc" "$verdict" "$(grep -E '^(spurious_waits|COUNTER_RACE|BINARY_GENERATION|DESTROY_AFTER_LOSS|EVENT_WAIT|TEARDOWN|EXTERNAL_QUEUE_WAIT|SHARED_QUEUE|TIMELINE_LISTENER|PREFILL_ABANDON|METAL_ERROR)|^submit=|^C_before_loss|^shared_mtl_queue|^cleanup=|^wait=' "$log" | tr '\n' ' ' | cut -c1-200)"
		done
	done
done
if (( ${#blockers[@]} )); then echo "BLOCKER reproduced, not passed: ${blockers[*]}"; fi
echo "LOSS ORACLES $side: $failures unexpected, ${#blockers[@]} blocker run(s)"
exit $(( failures ? 1 : 0 ))
