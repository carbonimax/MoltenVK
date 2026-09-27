#!/bin/bash
# Copyright (c) 2026 Jean-Philippe Meunier
# SPDX-License-Identifier: Apache-2.0
# CPU-only: production grouping, real SPIR-V conversion, Metal syntax. No device or submission.
set -euo pipefail
test_dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$test_dir/../.." && pwd)
output=${1:?Output directory required; optionally followed by SPIRV-Cross source and library build}
mkdir -p "$output"
python3 - "$root" "$output" <<'PY'
from pathlib import Path
import os, sys
root, output = map(Path, sys.argv[1:])
device = Path(os.environ.get('MVK_MULTIVIEW_DEVICE_SOURCE', root / 'MoltenVK/MoltenVK/GPUObjects/MVKDevice.mm')).read_text()
renderpass = Path(os.environ.get('MVK_MULTIVIEW_RENDERPASS_SOURCE', root / 'MoltenVK/MoltenVK/GPUObjects/MVKRenderPass.mm')).read_text()
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
xcrun clang++ -std=c++17 -O1 -g -fsanitize=address,undefined -fno-sanitize-recover=all -I "$output" "$test_dir/MultiviewGroupingTests.cpp" -o "$output/multiview-grouping-tests"
"$output/multiview-grouping-tests"
if [[ $# -lt 3 ]]; then exit 0; fi
cross_source=$2
cross_build=$3
for stage in vert frag; do
    glslangValidator -V --target-env vulkan1.1 "$test_dir/pervertex-single-view.$stage" -o "$output/$stage.spv"
    spirv-val --target-env vulkan1.1 "$output/$stage.spv"
done
compiler_dir="$root/MoltenVKShaderConverter/MoltenVKShaderConverter"
xcrun clang++ -std=c++17 -O0 -g -DMVK_EXCLUDE_SPIRV_TOOLS=1 -DSPIRV_CROSS_NAMESPACE_OVERRIDE=MVK_spirv_cross \
    -I "$compiler_dir" -I "$root/Common" -I "$cross_source" -I "$root/External/Vulkan-Headers/include" \
    "$test_dir/PerVertexMultiviewTests.cpp" "$compiler_dir/SPIRVToMSLConverter.cpp" "$compiler_dir/SPIRVSupport.cpp" "$compiler_dir/FileSupport.mm" \
    "$cross_build/libspirv-cross-msl.a" "$cross_build/libspirv-cross-glsl.a" "$cross_build/libspirv-cross-reflect.a" "$cross_build/libspirv-cross-core.a" \
    -framework Foundation -o "$output/pervertex-multiview-tests"
"$output/pervertex-multiview-tests" "$output"
for shader in "$output"/*.metal; do
    case "$(basename "$shader")" in
        capture-1-1.metal|capture-1-2.metal)
            if xcrun metal -x metal -std=macos-metal2.4 -fno-modules -fsyntax-only "$shader" > "$shader.log" 2>&1; then
                echo "Unexpected layered indexed capture success: update the ABI boundary test" >&2
                exit 1
            fi
            # Pin the compiler failure, rather than treating an arbitrary tool failure as proof.
            grep -q "use of undeclared identifier 'gl_InstanceIndex'" "$shader.log"
            grep -q "use of undeclared identifier 'gl_BaseInstance'" "$shader.log"
            echo "REPRODUCED: $(basename "$shader") uses instance builtins before declaration"
            ;;
        *) xcrun metal -x metal -std=macos-metal2.4 -fno-modules -fsyntax-only "$shader" ;;
    esac
done
echo 'PASS: 16 Metal 2.4 syntax successes, 2 expected indexed-layered failures; public gate must remain closed'
