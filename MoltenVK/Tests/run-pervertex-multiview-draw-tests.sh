#!/bin/bash
# Copyright (c) 2026 Jean-Philippe Meunier
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
test_dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$test_dir/../.." && pwd)
output=${1:?Output directory required}
mkdir -p "$output"
python3 - "$root" "$output" <<'PY'
from pathlib import Path
import os, re, sys
root, output = map(Path, sys.argv[1:])
commands = root / 'MoltenVK/MoltenVK/Commands'
source = Path(os.environ.get('MVK_MULTIVIEW_DRAW_SOURCE', commands / 'MVKCmdDraw.mm')).read_text()
header = (commands / 'MVKCmdDraw.h').read_text()
kernel_source = (commands / 'MVKCommandPipelineStateFactoryShaderSource.h').read_text()
start = kernel_source.index('uint perVertexRestartPrimitiveCount(')
end = kernel_source.index('\n}\n', kernel_source.index('kernel void perVertexRestart(', start)) + 3
kernel = re.sub(r'\[\[[^]]+\]\]', '', kernel_source[start:end]).replace('kernel ', '').replace('device ', '').replace('constant ', 'const ')
(output / 'MultiviewRestartKernel.inc').write_text(kernel)
def method(text, signature):
    start = text.index(signature)
    return text[start:text.index('\n}', start) + 2]
state = Path(os.environ.get('MVK_MULTIVIEW_STATE_SOURCE', commands / 'MVKCommandEncoderState.mm')).read_text()
start = state.index('id<MTLComputePipelineState> mtlPipeline = nil;', state.index('void MVKMetalComputeCommandEncoderState::prepareRenderDispatch'))
selection = state[start:state.index('\n\tif (_vkPipeline != pipeline)', start)]
finalize = 'void MVKCommandEncoder::finalizeDrawState(Stage graphicsStage) { if (graphicsStage != kMVKGraphicsStageVertex) return; auto stage = kMVKShaderStageVertex; auto& mvkEncoder = *this; auto& vk = graphics; auto* pipeline = graphics._pipeline;\n' + selection + '\nmetal.bindPipeline(getMTLComputeEncoder(kMVKCommandUseTessellationVertexTessCtl), mtlPipeline);\n}\n'
(output / 'MultiviewDrawMethods.inc').write_text(method(state, 'void MVKCommandEncoderState::offsetZeroDivisorVertexBuffers(') + '\n' + finalize + method(header, 'static inline bool mvkCanEncodePerVertexDraw(') + '\n' + method(source, 'static void encodePerVertexInput('))
PY
xcrun clang++ -std=c++17 -fblocks -Wall -Wextra -Werror -Wno-unused-parameter -fsanitize=address,undefined -fno-sanitize-recover=all \
    -I"$output" -I"$root/MoltenVK/MoltenVK/Commands" -I"$root/External/Vulkan-Headers/include" \
    "$test_dir/PerVertexMultiviewDrawTests.mm" -framework Foundation -framework Metal -o "$output/multiview-draw-tests"
"$output/multiview-draw-tests"
