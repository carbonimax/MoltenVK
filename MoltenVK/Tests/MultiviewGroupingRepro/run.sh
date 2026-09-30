#!/bin/bash
# Copyright (c) 2026 Jean-Philippe Meunier
# SPDX-License-Identifier: Apache-2.0
# Host test of MoltenVK's multiview pass grouping: extracts the grouping functions from a MoltenVK checkout, compiles
# them with MultiviewGroupingTests.cpp under AddressSanitizer and UndefinedBehaviorSanitizer, and runs the full test,
# then three single masks. No GPU. Prints one line per run and exits with 1 if any run fails.
# Needs the Xcode command line tools and python3.
# Usage: run.sh <MoltenVK checkout> <output directory>
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
checkout=$(cd "$1" && pwd)
output=$(mkdir -p "$2" && cd "$2" && pwd)
# The test sits next to this script, or one directory up in the MoltenVK fork that holds it.
test=$here/MultiviewGroupingTests.cpp
[[ -f $test ]] || test=$here/../MultiviewGroupingTests.cpp
python3 - "$checkout" "$output" <<'PY'
from pathlib import Path
import sys
checkout, output = map(Path, sys.argv[1:])
device = (checkout / 'MoltenVK/MoltenVK/GPUObjects/MVKDevice.mm').read_text()
renderpass = (checkout / 'MoltenVK/MoltenVK/GPUObjects/MVKRenderPass.mm').read_text()
def function(source, signature):
    start = source.index(signature)
    end = source.index('\n}', start) + 2
    return source[start:end] + '\n'
functions = function(renderpass, 'uint32_t mvkGetNextViewMaskGroup(')
for name in ('getMultiviewMetalPassCount', 'getFirstViewIndexInMetalPass', 'getViewCountInMetalPass'):
    functions += function(device, 'uint32_t MVKDevice::' + name + '(')
functions += function(renderpass, 'uint32_t MVKRenderSubpass::getViewMaskGroupForMetalPass(')
(output / 'MultiviewGrouping.inc').write_text(functions)
PY
xcrun clang++ -std=c++17 -O1 -g -fsanitize=address,undefined -fno-sanitize-recover=all -I "$output" "$test" -o "$output/multiview-grouping-tests"
shasum -a 256 "$output/MultiviewGrouping.inc" "$output/multiview-grouping-tests" "$test" "$0" > "$output/INPUTS.sha256"
failed=0
for mask in all 0x5 0x80000000 0xffffffff; do
	rc=0
	# A sanitizer abort also makes the shell print an "Abort trap" notice; the sanitizer report is in the log.
	if [[ $mask == all ]]; then "$output/multiview-grouping-tests" > "$output/$mask.log" 2>&1 || rc=$?
	else "$output/multiview-grouping-tests" "$mask" > "$output/$mask.log" 2>&1 || rc=$?; fi
	[[ $rc == 0 ]] || failed=1
	detail=$(grep -m1 -E '^PASS|^mask=|runtime error' "$output/$mask.log" | sed 's/^.*runtime error: /runtime error: /' || true)
	printf '%-11s exit=%-3s %s\n' "$mask" "$rc" "${detail:-ok}"
done
exit $failed
