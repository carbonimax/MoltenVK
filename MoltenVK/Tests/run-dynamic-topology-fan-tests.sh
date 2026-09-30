#!/bin/bash
# Copyright (c) 2026 Jean-Philippe Meunier
# SPDX-License-Identifier: Apache-2.0
# Triangle fans with a dynamic primitive topology on MoltenVK's ordinary path (DynamicTopologyFanTests.mm), under Metal
# API and GPU validation, one case at a time. The library is the output of a MoltenVK build that holds PROVENANCE.txt
# and build/moltenvk/MoltenVK/libMoltenVK.dylib, whose SHA-256 must match the provenance. Each case is class:form
# (triangles, triangles-fan-first or lines; direct, indexed, indirect or indexed-indirect) and must exit with the
# expected code (0 pass, 2 image or invocation mismatch); the list stops at the first unexpected result.
# Usage: run-dynamic-topology-fan-tests.sh <MoltenVK build output> <output directory> <expected exit> <class:form>...
set -euo pipefail
test_dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$test_dir/../.." && pwd)
build=$(cd "$1" && pwd)
library=$build/build/moltenvk/MoltenVK/libMoltenVK.dylib
output=$(mkdir -p "$2" && cd "$2" && pwd)
expected=$3
shaders=$output/shaders
program=$output/dynamic-topology-fan
mkdir -p "$shaders" "$output/runs"
exec > >(tee -a "$output/run.log") 2>&1
if [[ ! -x $program ]]; then
	test "$(shasum -a 256 "$library" | cut -d' ' -f1)" = "$(sed -n 's/^library_sha256=//p' "$build/PROVENANCE.txt")"
	cp "$build/PROVENANCE.txt" "$output/PROVENANCE.txt"
	{ sw_vers; uname -m; xcodebuild -version | tr '\n' ' '; echo; sysctl -n machdep.cpu.brand_string; } | tee "$output/ENVIRONMENT.txt"
	echo "test_tree=$(git -C "$root" rev-parse HEAD) dirty_tests=$(git -C "$root" status --porcelain -- "$test_dir/DynamicTopologyFanTests.mm" "$test_dir/pervertex-indirect.vert" "$test_dir/pervertex-dynamic-topology.frag" "$0" | wc -l | tr -d ' ')" | tee -a "$output/ENVIRONMENT.txt"
	cat "$output/PROVENANCE.txt"
	compile() { glslangValidator -V --target-env vulkan1.1 "$test_dir/$1" -o "$shaders/$2" > /dev/null; spirv-val --target-env vulkan1.1 "$shaders/$2"; }
	compile pervertex-indirect.vert indirect.vert.spv
	compile pervertex-dynamic-topology.frag ordinary.frag.spv
	xcrun clang++ -arch arm64 -std=c++17 -O2 -Wall -Wextra -Werror -Wno-missing-field-initializers -I"$root/External/Vulkan-Headers/include" \
		"$test_dir/DynamicTopologyFanTests.mm" "$library" -Wl,-rpath,"$(dirname "$library")" -framework Metal -framework Foundation -o "$program"
	shasum -a 256 "$(readlink -f "$library")" "$shaders"/*.spv "$program" "$test_dir/DynamicTopologyFanTests.mm" "$test_dir/pervertex-indirect.vert" "$test_dir/pervertex-dynamic-topology.frag" "$0" > "$output/INPUTS.sha256"
fi
for step in "${@:4}"; do
	IFS=: read -r klass form <<< "$step"
	log=$output/runs/$klass-$form.log
	if [[ -e $log ]]; then echo "STOP: $log already exists"; exit 1; fi
	# Process names only (truncated to 15 characters): the arguments of this runner name pervertex directories.
	busy=$(pgrep -l '^(deqp-vk|pervertex-|dynamic-topolog|sample-shading|xctrace)' || true)
	if [[ -n $busy ]]; then echo "STOP: another GPU workload is running:"; echo "$busy"; exit 1; fi
	rc=0
	(cd "$output/runs" && env -u DYLD_LIBRARY_PATH -u DYLD_INSERT_LIBRARIES MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 MVK_CONFIG_LOG_LEVEL=2 \
		gtimeout -k 2 60 "$program" "$shaders" "$klass" "$form") > "$log" 2>&1 || rc=$?
	verdict=PASS
	[[ $rc == "$expected" ]] || verdict=FAIL
	grep -q 'Metal API Validation Enabled' "$log" || verdict=FAIL
	grep -q 'Metal GPU Validation Enabled' "$log" || verdict=FAIL
	if grep -qiE 'Shader Validation|GPU Address Sanitizer|validation error|Execution of the command buffer was aborted|execution failed' "$log"; then verdict=FAIL; fi
	case $expected in
		0) grep -q "^DYNAMIC_TOPOLOGY_FAN PASS $klass $form\$" "$log" || verdict=FAIL ;;
		2) grep -q "^DYNAMIC_TOPOLOGY_FAN FAIL $klass $form\$" "$log" || verdict=FAIL ;;
	esac
	printf '%s:%s exit=%s %s\n' "$klass" "$form" "$rc" "$verdict"
	grep -E '^(DEVICE|static vs|DYNAMIC_TOPOLOGY_FAN)|mvk-error' "$log" | sed 's/^/    /' | cut -c1-220 || true
	if [[ $verdict != PASS ]]; then echo "STOP: inspect $log before any further GPU work"; exit 1; fi
done
