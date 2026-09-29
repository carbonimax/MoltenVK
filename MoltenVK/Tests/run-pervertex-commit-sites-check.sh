#!/bin/bash
# Copyright (c) 2026 Jean-Philippe Meunier
# SPDX-License-Identifier: Apache-2.0
# Static check, no GPU (PerVertexExternalWait-DESIGN.md, O20). A device loss closes its inventory of work that may still
# write imported host memory once no encoding remains (R8), and counts that work through the completed handler that
# MVKDevice::commitMTLCommandBuffer() adds. So:
# - commitMTLCommandBuffer() must add, whenever the inventory is open, a completed handler that decrements the inventory
#   count, even when the command buffer has no other completed handler;
# - every function that calls it, member or free, in any source or header of the runtime, is classified:
#   "submission" (bracketed by MVKQueue::submit()), "bracket" (brackets itself: beginEncoding(), then the acquisition of
#   the Metal command buffer, then the commit, then endEncoding(), and any completion wait only after endEncoding(), so
#   that the publication, which waits for encodings, never waits for that completion), or "no-memory" (creates no blit,
#   compute or render encoder).
# An unclassified site, a missing classified site, a bracket out of order, or a "no-memory" site with an encoder fails.
# Usage: run-pervertex-commit-sites-check.sh [output directory]
set -euo pipefail
test_dir=$(cd "$(dirname "$0")" && pwd)
runtime=$(cd "$test_dir/../MoltenVK" && pwd)
python3 - "$runtime" "${1:-}" <<'PY'
import os, re, sys
runtime, output = sys.argv[1], sys.argv[2]
classes = {
	"MVKQueueCommandBufferSubmission::commitActiveMTLCommandBuffer": "submission",
	"MVKQueuePresentSurfaceSubmission::execute": "submission",
	"MVKDevice::invalidateMappedMemoryRanges": "bracket",
	"MVKImage::copyImageToMemory": "bracket",
	"MVKQueue::waitIdle": "no-memory",
	"MVKPresentableSwapchainImage::acquireAndSignalWhenAvailable": "no-memory",
	"MVKDevice::releaseSemaphoreWaitsAfterLoss": "no-memory",
}
# Where a bracketed site acquires its Metal command buffer: directly, or through the function it calls.
acquisitions = ("getMTLCommandBuffer(", "pullFromDevice(")
keywords = {"if", "for", "while", "switch", "return", "sizeof", "catch", "else", "do", "try"}

def blank(text):
	"""Comments, strings and characters replaced by spaces, keeping offsets and lines."""
	out, i, n = list(text), 0, len(text)
	while i < n:
		two = text[i:i + 2]
		if two == "//":
			while i < n and text[i] != "\n": out[i] = " "; i += 1
		elif two == "/*":
			j = text.find("*/", i + 2); j = n if j < 0 else j + 2
			for k in range(i, j):
				if text[k] != "\n": out[k] = " "
			i = j
		elif text[i] in "\"'":
			quote, j = text[i], i + 1
			while j < n and text[j] != quote:
				j += 2 if text[j] == "\\" else 1
			for k in range(i + 1, min(j, n)):
				if text[k] != "\n": out[k] = " "
			i = j + 1
		else:
			i += 1
	return "".join(out)

signature = re.compile(r'([A-Za-z_~][\w:~]*)\s*\((?:[^()]|\([^()]*\))*\)\s*(?:const\s*)?(?:override\s*)?(?:noexcept\s*)?(?:->\s*[\w:<>*& ]+)?\s*$')
container = re.compile(r'\b(namespace|class|struct|union)\b[^()]*$|extern\s*$')

def functions(code):
	"""(name, offset, body) of every function definition, member or free, including inline ones in classes."""
	found, stack, header_start = [], [], 0	# stack entries: "container" or ("function", name, start) or "block"
	for i, ch in enumerate(code):
		if ch == "{":
			if all(entry == "container" for entry in stack):
				header = code[header_start:i].strip()
				match = signature.search(header)
				if container.search(header) and not match:
					stack.append("container")
				elif match and match.group(1).split("::")[-1] not in keywords:
					stack.append(("function", match.group(1), i))
				else:
					stack.append("block")
			else:
				stack.append("block")
		elif ch == "}":
			entry = stack.pop() if stack else None
			if isinstance(entry, tuple): found.append((entry[1], entry[2], code[entry[2]:i + 1]))
			if all(e == "container" for e in stack): header_start = i + 1
		elif ch == ";" and all(entry == "container" for entry in stack):
			header_start = i + 1
	return found

sites, problems, bodies = [], [], {}
for folder, _, files in os.walk(runtime):
	for name in sorted(files):
		if not name.endswith((".mm", ".m", ".cpp", ".h", ".hpp")): continue
		path = os.path.join(folder, name)
		text = open(path, encoding="utf-8", errors="replace").read()
		code = blank(text)
		for function, offset, body in functions(code):
			bodies.setdefault(function, body)
			if function == "MVKDevice::commitMTLCommandBuffer" or "commitMTLCommandBuffer(" not in body: continue
			line = code.count("\n", 0, offset) + 1
			kind = classes.get(function)
			sites.append(f"{os.path.relpath(path, runtime)}:{line} {function} {kind or 'UNCLASSIFIED'}")
			if kind is None:
				problems.append(f"{function}: unclassified commit site")
			elif kind == "bracket":
				begin, commit, end = body.find("beginEncoding()"), body.find("commitMTLCommandBuffer("), body.rfind("endEncoding()")
				acquire = min([p for p in (body.find(a) for a in acquisitions) if p >= 0], default=-1)
				waits = [m.start() for m in re.finditer(r"waitUntilCompleted|waitForMTLCommandBuffer", body)]
				if min(begin, acquire, commit, end) < 0 or not (begin < acquire < commit < end):
					problems.append(f"{function}: not bracketed as beginEncoding(), acquisition, commit, endEncoding(); it may write imported host memory outside the inventory")
				elif any(w < end for w in waits):
					problems.append(f"{function}: waits for completion inside its bracket, which the loss publication would then wait for")
			elif kind == "no-memory" and re.search(r"(blit|compute|render)CommandEncoder|getMTL(Blit|Compute|Render)Encoder", body, re.I):
				problems.append(f"{function}: classified as encoding no memory access, but creates an encoder")

# The inventory is counted by commitMTLCommandBuffer()'s completed handler: it must exist whenever the inventory is open.
commit_body = bodies.get("MVKDevice::commitMTLCommandBuffer", "")
completed_at = commit_body.find("addCompletedHandler")

def matching(text, start, opening, closing):
	depth = 0
	for i in range(start, len(text)):
		depth += (text[i] == opening) - (text[i] == closing)
		if depth == 0: return i
	return len(text)

# The conditions of every if-block that encloses the addCompletedHandler call.
guards = []
for m in re.finditer(r"\bif\s*\(", commit_body[:max(completed_at, 0)]):
	close = matching(commit_body, m.end() - 1, "(", ")")
	brace = commit_body.find("{", close)
	if 0 <= brace < completed_at and matching(commit_body, brace, "{", "}") > completed_at:
		guards.append(commit_body[m.start():close + 1])
handler_text = commit_body[completed_at:] if completed_at >= 0 else ""
if completed_at < 0 or "_handlersBeforeInventory--" not in handler_text:
	problems.append("MVKDevice::commitMTLCommandBuffer: no completed handler that decrements _handlersBeforeInventory")
elif any("isCounted" not in g for g in guards):
	problems.append(f"MVKDevice::commitMTLCommandBuffer: its counted completed handler depends on {guards}, not only on the inventory being open")
missing = set(classes) - {site.split()[1] for site in sites}
problems += [f"{function}: classified but no longer commits (update the list)" for function in sorted(missing)]

report = "\n".join(sites + [f"PROBLEM {p}" for p in problems])
if output:
	os.makedirs(output, exist_ok=True)
	open(os.path.join(output, "commit-sites.txt"), "w").write(report + "\n")
print(report)
if problems:
	print(f"FAIL: {len(problems)} commit site problem(s) (CPU only)")
	sys.exit(1)
print(f"PASS: {len(sites)} commit sites, each bracketed or encoding no memory access, all counted by the inventory (CPU only)")
PY
