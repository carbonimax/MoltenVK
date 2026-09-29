#!/bin/bash
# Copyright (c) 2026 Jean-Philippe Meunier
# SPDX-License-Identifier: Apache-2.0
# Static check, no GPU (PerVertexExternalWait-DESIGN.md, O20): every call of MVKDevice::commitMTLCommandBuffer() is
# classified, because a device loss closes its inventory of work that may still write imported host memory once no
# encoding remains (R8). A site either runs inside an encoding bracket (beginEncoding() ... endEncoding(), directly or
# through MVKQueue::submit()), or encodes no memory access at all: no blit, compute or render encoder in the function
# that commits. An unclassified site, a "no memory access" site that gains an encoder, or a site that must be bracketed
# and is not, fails the check.
# Usage: run-pervertex-commit-sites-check.sh [output directory]
set -euo pipefail
test_dir=$(cd "$(dirname "$0")" && pwd)
runtime=$(cd "$test_dir/../MoltenVK" && pwd)
python3 - "$runtime" "${1:-}" <<'PY'
import os, re, sys
runtime, output = sys.argv[1], sys.argv[2]
# function -> classification. "submission": bracketed by MVKQueue::submit(); "bracket": must call beginEncoding() and
# endEncoding() itself; "no-memory": must not create a blit, compute or render encoder.
classes = {
	"MVKQueueCommandBufferSubmission::commitActiveMTLCommandBuffer": "submission",
	"MVKQueuePresentSurfaceSubmission::execute": "submission",
	"MVKDevice::invalidateMappedMemoryRanges": "bracket",
	"MVKImage::copyImageToMemory": "bracket",
	"MVKQueue::waitIdle": "no-memory",
	"MVKPresentableSwapchainImage::acquireAndSignalWhenAvailable": "no-memory",
	"MVKDevice::releaseSemaphoreWaitsAfterLoss": "no-memory",
}
definition = re.compile(r'^[A-Za-z_][\w:<>*&, ]*?\b([A-Za-z_]\w*::~?[A-Za-z_]\w*)\s*\(', re.M)
sites, problems = [], []
for folder, _, files in os.walk(runtime):
	for name in files:
		if not name.endswith(('.mm', '.m', '.cpp')): continue
		path = os.path.join(folder, name)
		text = open(path, encoding='utf-8', errors='replace').read()
		# Function bodies: from each definition to its matching closing brace.
		for match in definition.finditer(text):
			open_brace = text.find('{', match.end())
			semicolon = text.find(';', match.end())
			if open_brace < 0 or (0 <= semicolon < open_brace): continue
			depth, end = 0, open_brace
			for end in range(open_brace, len(text)):
				depth += {'{': 1, '}': -1}.get(text[end], 0)
				if depth == 0: break
			body = text[open_brace:end]
			function = match.group(1)
			if function == 'MVKDevice::commitMTLCommandBuffer' or 'commitMTLCommandBuffer(' not in body: continue
			line = text.count('\n', 0, match.start()) + 1
			kind = classes.get(function)
			sites.append(f'{os.path.relpath(path, runtime)}:{line} {function} {kind or "UNCLASSIFIED"}')
			if kind is None:
				problems.append(f'{function}: unclassified commit site')
			elif kind == 'bracket' and not ('beginEncoding()' in body and 'endEncoding()' in body):
				problems.append(f'{function}: commits outside an encoding bracket, and may write imported host memory')
			elif kind == 'no-memory' and re.search(r'(blit|compute|render)CommandEncoder|getMTL(Blit|Compute|Render)Encoder', body, re.I):
				problems.append(f'{function}: classified as encoding no memory access, but creates an encoder')
missing = set(classes) - {site.split()[1] for site in sites}
problems += [f'{function}: classified but no longer commits (update the list)' for function in sorted(missing)]
report = '\n'.join(sites + [f'PROBLEM {p}' for p in problems])
if output:
	os.makedirs(output, exist_ok=True)
	open(os.path.join(output, 'commit-sites.txt'), 'w').write(report + '\n')
print(report)
if problems:
	print(f'FAIL: {len(problems)} commit site problem(s) (CPU only)')
	sys.exit(1)
print(f'PASS: {len(sites)} commit sites, each bracketed or encoding no memory access (CPU only)')
PY
