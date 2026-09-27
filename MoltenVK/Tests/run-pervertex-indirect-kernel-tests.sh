#!/bin/bash
# Copyright (c) 2026 Jean-Philippe Meunier
# SPDX-License-Identifier: Apache-2.0
# Host model of the production perVertexIndirect/perVertexRestart MSL kernels (ASan/UBSan).
# MVK_INDIRECT_KERNEL_MUTATION=provoking swaps the odd-strip corner exchange in the generated copy only.
set -euo pipefail
test_dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$test_dir/../.." && pwd)
output=${1:-$(mktemp -d /private/tmp/mvk-indirect-kernel.XXXXXX)}
mkdir -p "$output"
python3 - "$root" "$output" <<'PY'
from pathlib import Path
import os, re, sys
root, output = map(Path, sys.argv[1:])
source = (root / 'MoltenVK/MoltenVK/Commands/MVKCommandPipelineStateFactoryShaderSource.h').read_text()
start = source.index('uint perVertexRestartPrimitiveCount(')
end = source.index('\n}\n', source.index('kernel void perVertexIndirect(', start)) + 3
kernel = source[start:end]
if os.environ.get('MVK_INDIRECT_KERNEL_MUTATION') == 'provoking':
    kernel, count = re.subn(r'uint x = p\[8\] \? 0 : 1', 'uint x = p[8] ? 1 : 0', kernel)
    assert count == 1
host = re.sub(r'\[\[[^]]+\]\]', '', kernel).replace('kernel ', '').replace('device ', '').replace('constant ', 'const ')
(output / 'PerVertexIndirectKernel.inc').write_text(host)
PY
xcrun clang++ -arch arm64 -std=c++17 -O1 -g -fsanitize=address,undefined -Wall -Wextra -Wno-unused-parameter -I"$output" -I"$root/External/Vulkan-Headers/include" -I"$root/MoltenVK/MoltenVK/Commands" "$test_dir/PerVertexIndirectKernelTests.cpp" -o "$output/indirect-kernel-tests"
"$output/indirect-kernel-tests"
