#!/bin/bash
set -euo pipefail
test_dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$test_dir/../.." && pwd)
output=${1:-$(mktemp -d /private/tmp/mvk-indirect.XXXXXX)}
mkdir -p "$output"
# Compile the actual recording methods with CPU doubles, without a Metal device.
# A negative control removes one guard in the generated copy only.
python3 - "$root" "$output" <<'PY'
from pathlib import Path
import os, re, sys
root, output = map(Path, sys.argv[1:])
commands = root / 'MoltenVK/MoltenVK/Commands'
header = (commands / 'MVKCmdDraw.h').read_text()
source = (commands / 'MVKCmdDraw.mm').read_text()
classes = []
for name in ('MVKCmdDrawIndirect', 'MVKCmdDrawIndexedIndirect'):
    body = re.search(r'class ' + name + r' : public MVKCommand \{(.*?)\n\};', header, re.S).group(1)
    declarations = re.findall(r'VkResult setContent\(.*?\);', body, re.S)
    fields = re.findall(r'^\s*(?:id<MTLBuffer>|VkDeviceSize|uint32_t) _\w+;', body, re.M)
    assert len(declarations) == (3 if 'Indexed' in name else 2) and len(fields) == 6
    classes.append('class ' + name + ' { public:\n' + '\n'.join(declarations + fields) + '\n};')
methods = re.findall(r'VkResult MVKCmdDraw(?:Indexed)?Indirect::setContent\(.*?\n\}', source, re.S)
assert len(methods) == 5, 'Update extraction if production signatures change'
mutation = os.environ.get('MVK_INDIRECT_REMOVE_GUARD')
if mutation:
    assert mutation in ('MVKCmdDrawIndirect', 'MVKCmdDrawIndexedIndirect')
    matches = 0
    for i, method in enumerate(methods):
        if method.startswith('VkResult ' + mutation + '::'):
            methods[i], removed = re.subn(r'\tif \(drawCount && cmdBuff->recordedGraphicsPipelineUsesPerVertexInput\(\)\) \{[^\n]*\}\n', '', method)
            matches += removed
    assert matches == 1
(output / 'IndirectRecording.inc').write_text('\n'.join(classes + methods))
PY
xcrun clang++ -std=c++17 -Wall -Wextra -Werror -fsanitize=address,undefined -I"$output" -I"$root/External/Vulkan-Headers/include" "$test_dir/PerVertexIndirectTests.mm" -framework Foundation -framework Metal -o "$output/indirect-tests"
"$output/indirect-tests"
