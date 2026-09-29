#!/bin/bash
# Copyright (c) 2026 Jean-Philippe Meunier
# SPDX-License-Identifier: Apache-2.0
# Portable PerVertexKHR with a dynamic primitive topology, under Metal API and GPU validation, one case at a time.
# Each case is class:form (triangles or lines, direct or indexed); the list stops at the first unexpected result.
# Usage: run-pervertex-dynamic-topology-tests.sh <libMoltenVK> <output directory> <expected exit> <class:form>...
set -euo pipefail
test_dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$test_dir/../.." && pwd)
library=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
output=$(mkdir -p "$2" && cd "$2" && pwd)
expected=$3
shaders=$output/shaders
program=$output/pervertex-dynamic-topology
mkdir -p "$shaders" "$output/runs"
exec > >(tee -a "$output/run.log") 2>&1
if [[ ! -x $program ]]; then
	sw_vers
	echo "test_tree=$(git -C "$root" rev-parse HEAD) dirty_tests=$(git -C "$root" status --porcelain -- "$test_dir/PerVertexDynamicTopologyTests.mm" "$0" | wc -l | tr -d ' ')"
	[[ -f $(dirname "$library")/PROVENANCE.txt ]] && cat "$(dirname "$library")/PROVENANCE.txt"
	compile() { glslangValidator -V --target-env vulkan1.1 "${@:3}" "$test_dir/$1" -o "$shaders/$2" > /dev/null; spirv-val --target-env vulkan1.1 "$shaders/$2"; }
	compile pervertex-indirect.vert indirect.vert.spv
	compile pervertex-indirect.frag pervertex-portable.frag.spv -DPORTABLE
	xcrun clang++ -arch arm64 -std=c++17 -O2 -Wall -Wextra -Werror -Wno-missing-field-initializers -I"$root/External/Vulkan-Headers/include" \
		"$test_dir/PerVertexDynamicTopologyTests.mm" "$library" -Wl,-rpath,"$(dirname "$library")" -framework Metal -framework Foundation -o "$program"
	shasum -a 256 "$library" "$shaders"/*.spv "$program" "$test_dir/PerVertexDynamicTopologyTests.mm" > "$output/INPUTS.sha256"
fi
for step in "${@:4}"; do
	klass=${step%%:*} form=${step##*:}
	log=$output/runs/$klass-$form.log
	if [[ -e $log ]]; then echo "STOP: $log already exists"; exit 1; fi
	rc=0
	(cd "$output/runs" && env -u DYLD_LIBRARY_PATH -u DYLD_INSERT_LIBRARIES MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 MVK_CONFIG_LOG_LEVEL=2 \
		gtimeout -k 2 60 "$program" "$shaders" "$klass" "$form") > "$log" 2>&1 || rc=$?
	verdict=PASS
	[[ $rc == "$expected" ]] || verdict=FAIL
	grep -q 'Metal API Validation Enabled' "$log" || verdict=FAIL
	grep -q 'Metal GPU Validation Enabled' "$log" || verdict=FAIL
	if grep -qiE 'Shader Validation|GPU Address Sanitizer|validation error|Execution of the command buffer was aborted|execution failed' "$log"; then verdict=FAIL; fi
	[[ $expected != 0 ]] || grep -q '^PERVERTEX_DYNAMIC_TOPOLOGY PASS' "$log" || verdict=FAIL
	printf '%s:%s exit=%s %s\n' "$klass" "$form" "$rc" "$verdict"
	grep -E '^(dynamic topology|static vs|PERVERTEX_DYNAMIC|mode )|mvk-error' "$log" | sed 's/^/    /' | cut -c1-200 || true
	if [[ $verdict != PASS ]]; then echo "STOP: inspect $log before any further GPU work"; exit 1; fi
done
