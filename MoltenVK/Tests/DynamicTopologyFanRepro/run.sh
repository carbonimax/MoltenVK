#!/bin/bash
# Copyright (c) 2026 Jean-Philippe Meunier
# SPDX-License-Identifier: Apache-2.0
# Builds the reproducer against a libMoltenVK and runs its twelve cases (three classes, four draw forms) under Metal API
# and GPU validation. Prints one line per case and exits with 1 if any case does not pass.
# Needs the Xcode command line tools, glslangValidator and spirv-val.
# Usage: run.sh <libMoltenVK.dylib> <Vulkan-Headers include directory> <output directory>
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
library=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
headers=$(cd "$2" && pwd)
output=$(mkdir -p "$3" && cd "$3" && pwd)
program=$output/dynamic-topology-fan
mkdir -p "$output/logs"
for stage in vert frag; do
	glslangValidator -V --target-env vulkan1.1 "$here/dynamic-topology-fan.$stage" -o "$output/$stage.spv" > /dev/null
	spirv-val --target-env vulkan1.1 "$output/$stage.spv"
done
xcrun clang++ -arch arm64 -std=c++17 -O2 -Wall -Wextra -Werror -Wno-missing-field-initializers -I"$headers" \
	"$here/DynamicTopologyFan.mm" "$library" -Wl,-rpath,"$(dirname "$library")" -framework Metal -framework Foundation -o "$program"
shasum -a 256 "$(readlink -f "$library")" "$output"/*.spv "$program" "$here"/* > "$output/INPUTS.sha256"
failed=0
for klass in triangles triangles-fan-first lines; do
	for form in direct indexed indirect indexed-indirect; do
		log=$output/logs/$klass-$form.log
		rc=0
		env -u DYLD_LIBRARY_PATH -u DYLD_INSERT_LIBRARIES MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 MVK_CONFIG_LOG_LEVEL=2 \
			"$program" "$output" "$klass" "$form" > "$log" 2>&1 || rc=$?
		# PASS and FAIL are the oracle's verdicts; ERROR is any other exit, INVALID a run without clean Metal validation.
		result=ERROR
		if [[ $rc == 0 ]] && grep -q "^DYNAMIC_TOPOLOGY_FAN PASS $klass $form\$" "$log"; then result=PASS; fi
		if [[ $rc == 2 ]] && grep -q "^DYNAMIC_TOPOLOGY_FAN FAIL $klass $form\$" "$log"; then result=FAIL; fi
		if ! grep -q 'Metal API Validation Enabled' "$log" || ! grep -q 'Metal GPU Validation Enabled' "$log" ||
			grep -qiE 'Shader Validation|GPU Address Sanitizer|validation error|Execution of the command buffer was aborted|execution failed' "$log"; then result=INVALID; fi
		[[ $result == PASS ]] || failed=1
		printf '%-20s %-17s %-7s %s\n' "$klass" "$form" "$result" "$(sed -n 's/^static vs dynamic: //p' "$log")"
	done
done
exit $failed
