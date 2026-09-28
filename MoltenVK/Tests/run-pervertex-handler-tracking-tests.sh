#!/bin/bash
# Copyright (c) 2026 Jean-Philippe Meunier
# SPDX-License-Identifier: Apache-2.0
# Static check, no GPU: every handler that MoltenVK adds to a Metal command buffer, and every commit of one, goes
# through MVKDevice::addMTLCommandBufferHandler() and MVKDevice::commitMTLCommandBuffer(). A device loss is reported,
# and the device destroyed, only once those handlers have returned; a handler added or a command buffer committed
# directly would escape that count. MTLResidencySet commits are not command buffers.
# Usage: run-pervertex-handler-tracking-tests.sh [output directory]
set -euo pipefail
test_dir=$(cd "$(dirname "$0")" && pwd)
runtime=$(cd "$test_dir/../MoltenVK" && pwd)
helpers=GPUObjects/MVKDevice.mm
raw=$(cd "$runtime" && grep -rnE 'addCompletedHandler|addScheduledHandler|[[:space:]]commit\]' --include='*.mm' --include='*.h' --include='*.m' . \
	| grep -v '_residencySet commit\]' | grep -v "^\./$helpers:" || true)
helper_uses=$(cd "$runtime" && { grep -rn 'addMTLCommandBufferHandler\|commitMTLCommandBuffer' --include='*.mm' --include='*.h' . || true; } | wc -l | tr -d ' ')
in_helpers=$(cd "$runtime" && { grep -cE 'addCompletedHandler|addScheduledHandler|[[:space:]]commit\]' "$helpers" || true; })
if [[ -n ${1:-} ]]; then mkdir -p "$1"; { echo "$raw"; echo "helper_uses=$helper_uses in_helpers=$in_helpers"; } > "$1/handler-tracking.txt"; fi
if [[ -n $raw ]]; then
	echo "$raw"
	echo "FAIL: Metal command buffer handlers or commits outside MVKDevice's tracking helpers"
	exit 1
fi
# The helpers themselves register and commit exactly once each way.
[[ $in_helpers == 3 ]] || { echo "FAIL: expected 3 direct Metal calls in $helpers, found $in_helpers"; exit 1; }
echo "PASS: $helper_uses tracked handler and commit uses, no direct Metal command buffer handler or commit outside $helpers (CPU only)"
