#!/bin/bash
# Copyright (c) 2026 Jean-Philippe Meunier
# SPDX-License-Identifier: Apache-2.0
# Installs the signed trial app on an unlocked iOS 17+ device, launches it without a debugger through devicectl, waits
# for its new report, and copies every run back. One launch covers one MoltenVK queue submission mode, with or
# without Metal API and shader validation. Run one launch at a time; the device runs the cases one by one.
# Usage: run-trial-device.sh <PerVertexVulkanTrial.app> <device UDID> <output directory> <sync|async> <validated|plain>
set -euo pipefail
app=$(cd "${1:?app}" && pwd)
device=${2:?device UDID}
output=$(mkdir -p "${3:?output directory}" && cd "$3" && pwd)
mode=${4:?sync or async}
validation=${5:?validated or plain}
[[ $mode == sync || $mode == async ]] || { echo 'mode must be sync or async'; exit 64; }
[[ $validation == validated || $validation == plain ]] || { echo 'validation must be validated or plain'; exit 64; }
bundle=jp.meunier.PerVertexVulkanTrial
exec > >(tee -a "$output/run-trial-device.log") 2>&1
echo "== $(date -u) device=$device mode=$mode validation=$validation"
shasum -a 256 "$app/PerVertexVulkanTrial" "$app/Frameworks/libMoltenVK.1.dylib"

# Runs already on the device, so that the new one is recognised by name.
fetch() { rm -rf "$1" && mkdir -p "$1" && xcrun devicectl device copy from --device "$device" --domain-type appDataContainer --domain-identifier "$bundle" --source Documents/PerVertexVulkanTrial --destination "$1" > /dev/null 2>&1 || true; }
xcrun devicectl device install app --device "$device" "$app"
# Run directories are named by their UTC start and hold journal.txt, wherever the copy nests them.
runs() { find "$1" -name journal.txt -exec dirname {} \; 2>/dev/null | while read -r dir; do basename "$dir"; done | LC_ALL=C sort; }
fetch "$output/.before"
before=$(runs "$output/.before")

environment="{\"MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS\":\"$([[ $mode == sync ]] && echo 1 || echo 0)\",\"MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS\":\"0\",\"MVK_CONFIG_LOG_LEVEL\":\"2\""
[[ $validation == plain ]] || environment="$environment,\"MTL_DEBUG_LAYER\":\"1\",\"MTL_SHADER_VALIDATION\":\"1\""
environment="$environment}"
xcrun devicectl device process launch --device "$device" --terminate-existing -e "$environment" "$bundle"

# Bounded wait: 15 minutes for a run directory that did not exist before and now holds report.json.
run= report=
for attempt in $(seq 1 60); do
	/usr/bin/perl -e 'select(undef, undef, undef, 15)'
	fetch "$output/.poll"
	for candidate in $(runs "$output/.poll"); do
		case " $(echo $before) " in *" $candidate "*) continue ;; esac
		found=$(find "$output/.poll" -path "*/$candidate/report.json" | head -1)
		[[ -z $found ]] || { run=$candidate; report=$found; }
	done
	[[ -z $run ]] || break
	echo "waiting ($attempt): no new report yet"
done
[[ -n $run ]] || { echo 'STOP: no new report after 15 minutes; the app may have stopped inside a case (see journal.txt of the newest run)'; cp -R "$output/.poll/." "$output/" 2>/dev/null || true; exit 1; }
cp -R "$(dirname "$report")" "$output/$run-$mode-$validation"
rm -rf "$output/.before" "$output/.poll"
python3 - "$output/$run-$mode-$validation/report.json" <<'PY'
import json, sys
report = json.load(open(sys.argv[1]))
device = report["device"]
print(f"{report['verdict']} {report['summary']} {device['model_identifier']} {device['system']} apple10={device['gpu_families']['apple10']} path={device['expected_pervertex_path']}")
for case in report["cases"]:
    print(f"  {case['verdict']:8} {case['case']:34} exit={case['exit']} validation={case['validation_announced']}")
PY
(cd "$output/$run-$mode-$validation" && shasum -a 256 * > SHA256SUMS)
echo "RUN: $output/$run-$mode-$validation"
