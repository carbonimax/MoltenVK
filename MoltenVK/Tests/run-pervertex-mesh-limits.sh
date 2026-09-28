#!/bin/bash
# Copyright (c) 2026 Jean-Philippe Meunier
# SPDX-License-Identifier: Apache-2.0
# Metal mesh limits behind VkPhysicalDeviceMeshShaderPropertiesEXT, measured by rendering on this GPU, once under Metal
# API and shader validation and once without. No Vulkan and no MoltenVK library are involved. The verdicts are data:
# the script fails only if the probe cannot run. Short and sequential; run it alone on the GPU.
# Usage: run-pervertex-mesh-limits.sh <output directory>
set -euo pipefail
test_dir=$(cd "$(dirname "$0")" && pwd)
output=$(mkdir -p "${1:?output directory}" && cd "$1" && pwd)
exec > >(tee "$output/run.log") 2>&1
sw_vers
sysctl -n machdep.cpu.brand_string hw.model
xcodebuild -version
xcrun clang++ -arch arm64 -std=c++17 -fobjc-arc -O1 -Wall -Wextra -Werror "$test_dir/PerVertexMeshLimits.mm" -framework Metal -framework Foundation -o "$output/mesh-limits"
for mode in validated plain; do
	if [[ $mode == validated ]]; then vars=(MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1); else vars=(MTL_DEBUG_LAYER=0 MTL_SHADER_VALIDATION=0); fi
	(cd "$output" && gtimeout -k 2 300 env "${vars[@]}" ./mesh-limits) > "$output/mesh-limits-$mode.log" 2>&1
	grep -q '^MESH_LIMITS DONE' "$output/mesh-limits-$mode.log" || { echo "probe did not finish ($mode)"; exit 1; }
	echo "== $mode"
	grep -E '^DEVICE|^MESH_LIMIT ' "$output/mesh-limits-$mode.log" | cut -c1-220
done
shasum -a 256 "$test_dir/PerVertexMeshLimits.mm" "$output/mesh-limits" "$output"/mesh-limits-*.log > "$output/EVIDENCE.sha256"
echo "PERVERTEX_MESH_LIMITS DONE"
