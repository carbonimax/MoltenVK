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
import os, sys
root, output = map(Path, sys.argv[1:])
commands = root / 'MoltenVK/MoltenVK/Commands'
source = Path(os.environ.get('MVK_MULTIVIEW_COMMAND_SOURCE', commands / 'MVKCommandBuffer.mm')).read_text()
def method(text, signature):
    start = text.index(signature)
    return text[start:text.index('\n}', start) + 2] + '\n'
parts = [method(source, signature) for signature in (
    'uint32_t MVKCommandBuffer::getViewCount(',
    'VkResult MVKCommandBuffer::recordPerVertexDraw(',
    'VkResult MVKCommandBuffer::recordExecuteCommands(',
    'MVKPerVertexScratch* MVKCommandEncoder::nextPerVertexScratch(',
    'void MVKCommandEncoder::setSubpass(',
    'void MVKCommandEncoder::beginNextMultiviewPass(',
    'void MVKCommandEncoder::encodeCommandsImpl(',
    'void MVKCommandEncoder::encodeSecondary(')]
if 'uint32_t MVKCommandBuffer::getViewMask(' in source:
    parts.insert(0, method(source, 'uint32_t MVKCommandBuffer::getViewMask('))
header = (commands / 'MVKCmdDraw.h').read_text()
parts.insert(0, method(header, 'static inline bool mvkCanEncodePerVertexDraw('))
device = (root / 'MoltenVK/MoltenVK/GPUObjects/MVKDevice.mm').read_text()
renderpass = (root / 'MoltenVK/MoltenVK/GPUObjects/MVKRenderPass.mm').read_text()
parts.insert(0, method(renderpass, 'uint32_t mvkGetNextViewMaskGroup(') + ''.join(method(device, 'uint32_t MVKDevice::' + name + '(') for name in ('getMultiviewMetalPassCount', 'getViewCountInMetalPass')))
(output / 'MultiviewScratchMethods.inc').write_text('\n'.join(parts))
PY
xcrun clang++ -std=c++17 -fblocks -Wall -Wextra -Werror -Wno-unused-parameter -fsanitize=address,undefined -fno-sanitize-recover=all \
    -I"$output" -I"$root/MoltenVK/MoltenVK/Commands" -I"$root/External/Vulkan-Headers/include" \
    "$test_dir/PerVertexMultiviewScratchTests.mm" -framework Foundation -framework Metal -o "$output/multiview-scratch-tests"
"$output/multiview-scratch-tests"
