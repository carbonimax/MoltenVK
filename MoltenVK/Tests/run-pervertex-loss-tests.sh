#!/bin/bash
# Copyright (c) 2026 Jean-Philippe Meunier
# SPDX-License-Identifier: Apache-2.0
# Device loss oracles of PerVertexLossTests.mm, against a MoltenVK test build that exports mvkTestMarkDeviceLost.
# Each mode runs in synchronous and asynchronous queue submission, several times, one run at a time under gtimeout,
# with Metal API and shader validation. The executable loads the library through @executable_path/lib, so the same
# binary runs against another library for before/after comparisons.
# "before" expects each mode to show its defect (exit 1), "after" expects each to pass (exit 0).
# Usage: run-pervertex-loss-tests.sh <libMoltenVK test build> <output directory> <before|after> [repeats [modes...]]
set -euo pipefail
test_dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$test_dir/../.." && pwd)
library=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
output=$(mkdir -p "$2" && cd "$2" && pwd)
side=${3:?before or after}
repeats=${4:-3}
modes=("${@:5}")
(( ${#modes[@]} )) || modes=(counter-race binary-generation destroy-after-loss event-wait)
[[ $side == before || $side == after ]] || { echo 'side must be before or after'; exit 64; }
mkdir -p "$output/bin/lib" "$output/runs"
exec > >(tee "$output/loss.log") 2>&1
ln -sf "$library" "$output/bin/lib/libMoltenVK.1.dylib"
xcrun clang++ -arch arm64 -std=c++17 -O2 -Wall -Wextra -Werror -Wno-missing-field-initializers -I"$root/External/Vulkan-Headers/include" "$test_dir/PerVertexLossTests.mm" \
	"$library" -Wl,-rpath,@executable_path/lib -framework Metal -framework Foundation -o "$output/bin/pervertex-loss"
shasum -a 256 "$library" "$output/bin/pervertex-loss" "$test_dir/PerVertexLossTests.mm" > "$output/INPUTS.sha256"
echo 'case,mode,run,expected,actual,verdict' > "$output/results.csv"
failures=0
expected=$([[ $side == before ]] && echo 1 || echo 0)
for name in "${modes[@]}"; do
	for mode in sync async; do
		for run in $(seq 1 "$repeats"); do
			log=$output/runs/$name-$mode-$run.log rc=0
			env -u DYLD_LIBRARY_PATH -u DYLD_INSERT_LIBRARIES MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 MVK_CONFIG_LOG_LEVEL=2 \
				MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=$([[ $mode == sync ]] && echo 1 || echo 0) \
				gtimeout -k 2 40 "$output/bin/pervertex-loss" "$name" > "$log" 2>&1 || rc=$?
			verdict=PASS
			[[ $rc == "$expected" ]] || verdict=FAIL
			grep -q 'Metal API Validation Enabled' "$log" || verdict=FAIL
			[[ $verdict == PASS ]] || failures=$((failures + 1))
			echo "$name,$mode,$run,$expected,$rc,$verdict" >> "$output/results.csv"
			printf '%-20s %-5s %s exit=%s %s | %s\n' "$name" "$mode" "$run" "$rc" "$verdict" "$(grep -E '^(COUNTER_RACE|BINARY_GENERATION|DESTROY_AFTER_LOSS|EVENT_WAIT)' "$log" | head -1)"
		done
	done
done
(cd "$output" && shasum -a 256 results.csv loss.log runs/*.log > EVIDENCE.sha256)
echo "LOSS ORACLES $side: $failures unexpected"
exit $(( failures ? 1 : 0 ))
