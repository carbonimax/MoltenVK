#!/bin/bash
# Copyright (c) 2026 Jean-Philippe Meunier
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
test_dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$test_dir/../.." && pwd)
output=${1:-$(mktemp -d /private/tmp/mvk-restart.XXXXXX)}
mkdir -p "$output"
python3 - "$root" "$output" <<'PY'
from pathlib import Path
import re, sys
root, output = map(Path, sys.argv[1:])
source = (root / 'MoltenVK/MoltenVK/Commands/MVKCommandPipelineStateFactoryShaderSource.h').read_text()
start = source.index('kernel void perVertexRestart(')
end = source.index('\n}\n', start) + 3
kernel = source[start:end]
host = re.sub(r'\[\[[^]]+\]\]', '', kernel).replace('kernel ', '').replace('device ', '').replace('constant ', 'const ')
(output / 'PerVertexRestartKernel.inc').write_text(host)
(output / 'restart.metal').write_text('#include <metal_stdlib>\nusing namespace metal;\n' + kernel)
PY
xcrun metal -x metal -std=macos-metal2.4 -fsyntax-only -fno-modules "$output/restart.metal"
xcrun clang++ -arch arm64 -std=c++17 -fsanitize=address,undefined -Wall -Wextra -I"$output" -I"$root/External/Vulkan-Headers/include" -I"$root/MoltenVK/MoltenVK/Commands" "$test_dir/PerVertexRestartTests.cpp" -o "$output/restart-tests"
"$output/restart-tests"
