#!/bin/bash
# Copyright 2026 Jean-Philippe Meunier
# SPDX-License-Identifier: Apache-2.0
# Qualifies the loss inventory (R8) on a Mac without unified memory. Runs the host-sync oracles of PerVertexLossTests.mm
# on three test libraries, each 3 times with synchronous and asynchronous submissions, under Metal API and shader
# validation, and the free-imported oracles on the final library. Only macOS tools: Bash, Perl, shasum.
# Expected, per library:
#   host-sync-progress-*:  before FAIL (an encoding holds the loss report back), no-admission PASS, after PASS
#   host-sync-admission-*: before FAIL (commits once the loss began), no-admission FAIL (the same), after PASS
#   free-imported-*:       after PASS
# The verdict is QUALIFIED only when every run matches, and none skips: a SKIP means this Mac has unified memory, or
# lacks VK_EXT_host_image_copy for the -copy modes, and proves nothing.
# Usage: run.sh [output directory]   (default: results-<host>-<time> next to this script)
set -uo pipefail
bundle=$(cd "$(dirname "$0")" && pwd)
output=${1:-$bundle/results-$(hostname -s)-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$output/runs"
(cd "$bundle" && shasum -a 256 -c SHA256SUMS > "$output/checksums.txt" 2>&1) || { echo "Bundle checksums differ: see $output/checksums.txt"; exit 2; }
{
	echo "date=$(date -u +%Y-%m-%dT%H:%M:%SZ) host=$(hostname -s) machine=$(uname -m) model=$(sysctl -n hw.model)"
	echo "macos=$(sw_vers -productVersion) build=$(sw_vers -buildVersion)"
	system_profiler SPDisplaysDataType 2>/dev/null | grep -E 'Chipset Model|Type|Bus|VRAM|Vendor|Metal' | sed 's/^ *//'
} > "$output/ENVIRONMENT.txt"
cat "$output/ENVIRONMENT.txt"
[[ $(uname -m) == x86_64 || -n ${NON_UNIFIED_SMOKE:-} ]] || { echo 'Run this on an Intel Mac, in a native x86_64 Terminal'; exit 2; }
echo 'library,case,mode,run,expected,actual,verdict' > "$output/results.csv"
mismatches=0 skips=0 runs=0
run() { # library case expected
	local library=$1 name=$2 expected=$3 places=64
	[[ $name == host-sync-progress-* ]] && places=4
	for mode in sync async; do
		for index in 1 2 3; do
			local log=$output/runs/$library-$name-$mode-$index.log rc=0
			env -u DYLD_LIBRARY_PATH -u DYLD_INSERT_LIBRARIES MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 MVK_CONFIG_LOG_LEVEL=2 \
				MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=$([[ $mode == sync ]] && echo 1 || echo 0) MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS=0 \
				MVK_CONFIG_MAX_ACTIVE_METAL_COMMAND_BUFFERS_PER_QUEUE=$places \
				perl "$bundle/timeout.pl" 60 "$bundle/$library/pervertex-loss" "$name" > "$log" 2>&1 || rc=$?
			local verdict
			if [[ $rc == 3 ]] && grep -q '^HOST_SYNC SKIP' "$log"; then verdict=SKIP; skips=$((skips + 1))
			elif [[ ($expected == PASS && $rc == 0) || ($expected == FAIL && $rc == 1) ]]; then verdict=MATCH
			else verdict=MISMATCH; mismatches=$((mismatches + 1)); fi
			grep -q 'Metal API Validation Enabled' "$log" || { [[ $verdict == MISMATCH ]] || mismatches=$((mismatches + 1)); verdict=MISMATCH; }
			runs=$((runs + 1))
			echo "$library,$name,$mode,$index,$expected,$rc,$verdict" >> "$output/results.csv"
			printf '%-13s %-31s %-5s %s expected=%s exit=%s %s | %s\n' "$library" "$name" "$mode" "$index" "$expected" "$rc" "$verdict" \
				"$(grep -E '^(HOST_SYNC|FREE_IMPORTED|acquiring_before|acquisition_delayed|late_import|loss_at)' "$log" | tr '\n' ' ' | cut -c1-220)"
		done
	done
}
for name in host-sync-progress-invalidate host-sync-progress-copy; do
	run before "$name" FAIL; run no-admission "$name" PASS; run after "$name" PASS
done
for name in host-sync-admission-invalidate host-sync-admission-copy; do
	run before "$name" FAIL; run no-admission "$name" FAIL; run after "$name" PASS
done
for name in free-imported-waits free-imported-waits-late-commit free-imported-waits-slow-handler free-imported-late-allocation \
		free-imported-failed-allocation; do
	run after "$name" PASS
done
verdict=QUALIFIED
(( skips )) && verdict='NOT QUALIFIED: skipped runs, this Mac cannot run the path'
(( mismatches )) && verdict='NOT QUALIFIED: runs differ from the expected results'
echo "NON_UNIFIED $verdict ($runs runs, $mismatches mismatch(es), $skips skip(s))" | tee "$output/VERDICT.txt"
(cd "$output" && find . -type f ! -name EVIDENCE.sha256 | sort | xargs shasum -a 256 > EVIDENCE.sha256)
echo "Send back the whole directory: $output"
[[ $verdict == QUALIFIED ]]
