#!/bin/bash
# Copyright (c) 2026 Jean-Philippe Meunier
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
test_dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$test_dir/../.." && pwd)
output=${1:-$(mktemp -d /private/tmp/mvk-attachments.XXXXXX)}
mkdir -p "$output"
# Compile production recording, inheritance, begin-pass, and admission methods with CPU doubles.
python3 - "$root" "$output" <<'PY'
from pathlib import Path
import os, re, sys
root, output = map(Path, sys.argv[1:])
commands = root / 'MoltenVK/MoltenVK/Commands'
source = (commands / 'MVKCommandBuffer.mm').read_text()
rendering = (commands / 'MVKCmdRendering.mm').read_text()
def method(text, signature):
    start = text.index(signature)
    return text[start:text.index('\n}', start) + 2]
parts = [method(source, signature) for signature in (
    'void MVKCommandBuffer::recordRenderPass(', 'void MVKCommandBuffer::recordRendering(',
    'VkResult MVKCommandBuffer::validateIndexedPerVertexAttachments(', 'VkResult MVKCommandBuffer::recordPerVertexDraw(',
    'VkResult MVKCommandBuffer::recordExecuteCommands(', 'const char* MVKCommandEncoder::getIndexedPerVertexAttachmentError(',
    'void MVKCommandEncoder::beginRenderpass(', 'void MVKCommandEncoder::encodeSecondary(')]
parts += [method(rendering, 'VkResult MVKCmdBeginRenderPassBase::setContent('),
          'template <size_t N_CV, size_t N_A>\n' + method(rendering, 'VkResult MVKCmdBeginRenderPass<N_CV, N_A>::setContent('),
          method(rendering, 'VkResult MVKCmdEndRenderPass::setContent(MVKCommandBuffer* cmdBuff)'),
          method(rendering, 'VkResult MVKCmdEndRendering::setContent(MVKCommandBuffer* cmdBuff)')]
# Exercise the real inheritance initialization without unrelated begin() allocation/state setup.
start = source.index('\tif (_doesContinueRenderPass) {')
end = source.index('\n\n\tif (pInheritAttLocInfo)', start)
parts += ['void MVKCommandBuffer::inherit() {\n' + source[start:end] + '\n}']
renderpass = (root / 'MoltenVK/MoltenVK/GPUObjects/MVKRenderPass.mm').read_text()
parts += [method(renderpass, signature) for signature in (
    'void MVKRenderingAttachmentIterator::iterate(', 'void MVKRenderingAttachmentIterator::handleAttachment(',
    'MVKRenderingAttachmentIterator::MVKRenderingAttachmentIterator(')]
# Keep Vulkan pNext view selection in the test, so imageless views traverse the production flow.
vulkan = (root / 'MoltenVK/MoltenVK/Vulkan/vulkan.mm').read_text()
start = vulkan.index('\tVkRenderPassAttachmentBeginInfo* pAttachmentBegin = nullptr;')
end = vulkan.index('\n\tMVKAddCmdFrom5Thresholds', start)
parts += ['static MVKArrayRef<MVKImageView*> beginViews(const VkRenderPassBeginInfo* pRenderPassBegin) {\n' + vulkan[start:end] + '\nreturn attachments;\n}']
header = (commands / 'MVKCmdDraw.h').read_text()
parts.insert(0, method(header, 'static inline bool mvkCanEncodePerVertexDraw('))
# Regression controls mutate only the generated test copy. Each must fail the suite.
mutation = os.environ.get('MVK_ATTACHMENTS_NEGATIVE_CONTROL')
joined = '\n\n'.join(parts)
if mutation == 'framebuffer':
    joined = joined.replace('for (auto* attachment : _attachments)', 'for (auto* attachment : _pEncodingContext->getFramebuffer()->getAttachments())')
elif mutation == 'empty':
    joined = joined.replace('_recordedRenderingError = nullptr;', '_recordedRenderingError = attachmentsKnown && !attachments.size() ? "empty rejected" : nullptr;', 1)
elif mutation == 'inheritance':
    joined = joined.replace('if (cmdBuff->_needsInheritedPerVertexAttachments)', 'if (false)')
else:
    assert mutation is None, mutation
(output / 'AttachmentMethods.inc').write_text(joined)
# Ensure the tested encoder guard remains wired into the real draw before compute splitting.
draw = (commands / 'MVKCmdDraw.mm').read_text()
start = draw.index('static void encodePerVertexInput(')
assert draw.index('cmdEncoder->getIndexedPerVertexAttachmentError()', start) < draw.index('cmdEncoder->getMTLComputeEncoder(', start)
PY
includes=(-I"$output" -I"$root/Common" -I"$root/MoltenVK/include" -I"$root/External/Vulkan-Headers/include")
for directory in API Commands GPUObjects Layers OS Utility Vulkan; do
    includes+=(-I"$root/MoltenVK/MoltenVK/$directory")
done
xcrun clang++ -std=c++17 -arch arm64 -Wall -Wextra -Werror -Wno-unused-parameter -Wno-deprecated-declarations -fsanitize=address,undefined "${includes[@]}" "$test_dir/PerVertexAttachmentTests.mm" -framework Foundation -framework Metal -o "$output/attachment-tests"
"$output/attachment-tests"
