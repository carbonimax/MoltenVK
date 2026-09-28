#!/bin/bash
# Copyright (c) 2026 Jean-Philippe Meunier
# SPDX-License-Identifier: Apache-2.0
# Attachment content across the capture and replay of a direct non-indexed portable PerVertexKHR draw
# (PerVertexAttachmentSplitTests.mm), under Metal API and shader validation, one run at a time under gtimeout.
# Expected outcomes by library:
# - reference: capture and replay in one render pass with a memory barrier (before a564af04): every variant renders;
# - before: a render pass boundary (a564af04) loses imported memoryless attachments (wrong image or Metal assertion);
# - after: memoryless attachments are refused before submission; ordinary MSAA still renders.
# Usage: run-pervertex-split-tests.sh <libMoltenVK test build> <output directory> <reference|before|after>
set -euo pipefail
test_dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$test_dir/../.." && pwd)
library=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
output=$(mkdir -p "$2" && cd "$2" && pwd)
side=${3:?reference, before or after}
mkdir -p "$output/bin/lib" "$output/runs" "$output/shaders"
exec > >(tee "$output/split.log") 2>&1
ln -sf "$library" "$output/bin/lib/libMoltenVK.1.dylib"
for stage in vert frag; do
	glslangValidator -V --target-env vulkan1.1 "$test_dir/pervertex-split.$stage" -o "$output/shaders/split.$stage.spv" > /dev/null
	spirv-val --target-env vulkan1.1 "$output/shaders/split.$stage.spv"
done
xcrun clang++ -arch arm64 -std=c++17 -O2 -Wall -Wextra -Werror -Wno-missing-field-initializers -I"$root/External/Vulkan-Headers/include" \
	"$test_dir/PerVertexAttachmentSplitTests.mm" "$library" -Wl,-rpath,@executable_path/lib -framework Metal -framework Foundation -o "$output/bin/pervertex-split"
shasum -a 256 "$library" "$output/bin/pervertex-split" "$output"/shaders/*.spv "$test_dir/PerVertexAttachmentSplitTests.mm" > "$output/INPUTS.sha256"
echo 'variant,expected,actual,verdict' > "$output/results.csv"
failures=0
for variant in memoryless-depth memoryless-stencil msaa msaa-memoryless; do
	case $side:$variant in
		reference:*|*:msaa) expected=0 ;;
		before:msaa-memoryless) expected='0|1|134|139' ;;	# observed to render on an M4, which Metal does not guarantee
		before:*) expected='1|134|139' ;;
		after:*) expected=4 ;;
	esac
	log=$output/runs/$variant.log rc=0
	env -u DYLD_LIBRARY_PATH -u DYLD_INSERT_LIBRARIES MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 MVK_CONFIG_LOG_LEVEL=2 \
		gtimeout -k 2 40 "$output/bin/pervertex-split" "$output/shaders" "$variant" > "$log" 2>&1 || rc=$?
	verdict=PASS
	[[ "|$expected|" == *"|$rc|"* ]] || verdict=FAIL
	grep -q 'Metal API Validation Enabled' "$log" || verdict=FAIL
	[[ $verdict == PASS ]] || failures=$((failures + 1))
	echo "$variant,$expected,$rc,$verdict" >> "$output/results.csv"
	printf '%-20s expected=%-8s exit=%-4s %s | %s\n' "$variant" "$expected" "$rc" "$verdict" "$(grep -E '^SPLIT_ATTACHMENT|failed assertion|^submit=' "$log" | tr '\n' ' ' | cut -c1-160)"
done
(cd "$output" && shasum -a 256 results.csv split.log runs/*.log > EVIDENCE.sha256)
echo "SPLIT ATTACHMENTS $side: $failures unexpected"
exit $(( failures ? 1 : 0 ))
