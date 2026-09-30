#!/bin/bash
# Copyright (c) 2026 Jean-Philippe Meunier
# SPDX-License-Identifier: Apache-2.0
# Metal-only reproduction of the plain-mode sample-shading divergence, without MoltenVK. Every variant runs on the strip
# and on the list, without any Metal instrumentation (plain) and under Metal API and shader validation (validated).
# The table records each exit: 0 when the resolved image matches the per-sample model, 4 when it does not.
# Usage: run-sample-shading-strip.sh <output directory>
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
output=$(mkdir -p "$1" && cd "$1" && pwd)
program=$output/sample-shading-strip
exec > >(tee -a "$output/run.log") 2>&1
{ sw_vers; uname -m; system_profiler SPDisplaysDataType 2>/dev/null | grep -E 'Chipset Model|Metal' || true
  echo "test_tree=$(git -C "$root" rev-parse HEAD) dirty_tests=$(git -C "$root" status --porcelain -- "$here" | wc -l | tr -d ' ')"; } > "$output/ENVIRONMENT.txt"
cat "$output/ENVIRONMENT.txt"
xcrun clang++ -arch arm64 -std=c++17 -O2 -Wall -Wextra -Werror -fobjc-arc "$here/SampleShadingStrip.mm" -framework Metal -framework Foundation -o "$program"
shasum -a 256 "$program" "$here/SampleShadingStrip.mm" "$0" > "$output/INPUTS.sha256"
for mode in plain validated; do
	for variant in moltenvk no-sample-id sample-id-read buffer-write oracle; do
		for topology in strip list; do
			run=$output/runs/$mode-$variant-$topology
			mkdir -p "$run"
			rc=0
			if [[ $mode == validated ]]; then
				(cd "$run" && env -u DYLD_LIBRARY_PATH -u DYLD_INSERT_LIBRARIES MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 gtimeout 60 "$program" "$variant" "$topology" "$run") > "$run/run.log" 2>&1 || rc=$?
			else
				(cd "$run" && env -u DYLD_LIBRARY_PATH -u DYLD_INSERT_LIBRARIES -u MTL_DEBUG_LAYER -u MTL_SHADER_VALIDATION gtimeout 60 "$program" "$variant" "$topology" "$run") > "$run/run.log" 2>&1 || rc=$?
			fi
			instrumented=$(grep -c 'Validation Enabled' "$run/run.log" || true)
			printf '%-9s %-15s %-6s exit=%s validation_lines=%s | %s\n' "$mode" "$variant" "$topology" "$rc" "$instrumented" "$(grep -E '^resolved image vs per-sample' "$run/run.log" | cut -c1-90)"
			[[ $rc == 0 || $rc == 4 ]] || { echo "STOP: setup error, see $run/run.log"; exit 1; }
		done
	done
done
