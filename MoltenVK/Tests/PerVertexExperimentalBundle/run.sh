#!/bin/bash
# Copyright 2026 Jean-Philippe Meunier
# SPDX-License-Identifier: Apache-2.0
# Runner of the experimental PerVertexKHR candidate bundle (macOS system Bash 3.2, Perl and command line tools only).
#   --verify-only  integrity, signatures, library identity and the identity probe (a Metal device and a Vulkan instance,
#                  no GPU work submitted).
#   --qualify      the same, then the closed test list, in order: B dynamic topology oracle, C capture/replay split,
#                  D CTS minimal scope, F CTS minimal scope on the candidate library without activation, and last E, CTS
#                  ordinary topologies, whose expected statuses depend most on the Mac. Each step compares every case,
#                  by name and status, with expected/; the first divergence or failure stops every later step (NOT-RUN).
# Each invocation writes reports/<UTC>-<PID>/ and reports/<UTC>-<PID>.tar.gz, to send back even on failure.
# Exit: 0 every step identical to its expected file, 1 failure or divergence, 64 usage, 75 another run is active.
set -euo pipefail
root=$(cd "$(dirname "$0")" && pwd -P)
cd "$root"
mode=${1:-}
case "$mode" in
	--verify-only|--qualify) [[ $# == 1 ]] || { echo 'Usage: ./run.sh --verify-only | --qualify'; exit 64; } ;;
	*) echo 'Usage: ./run.sh --verify-only | --qualify'; exit 64 ;;
esac
mkdir "$root/.run-lock" 2>/dev/null || { echo 'STOP: another run is active, or a stale .run-lock remains after a hard kill; check that no bin/ or cts/ process runs before removing it'; exit 75; }
report="$root/reports/$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -p "$report"
summary=$report/summary.txt
say() { echo "$*" | tee -a "$summary"; }
completed=0
finish() {
	local rc=$?
	trap - EXIT
	# Any stop before an intended exit, including a Bash error, must never read as success.
	[[ $rc != 0 || $completed == 1 ]] || { say 'RUNNER ABORTED before completing this mode'; rc=1; }
	say "runner_exit=$rc"
	(cd "$report" && /usr/bin/find . -type f ! -name SHA256SUMS | LC_ALL=C /usr/bin/sort | while IFS= read -r path; do /usr/bin/shasum -a 256 "$path"; done) > "$report/SHA256SUMS"
	/usr/bin/tar -czf "$report.tar.gz" -C "$root/reports" "$(basename "$report")" || rc=1
	rmdir "$root/.run-lock"
	echo "Report: $report.tar.gz"
	exit "$rc"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

prov() { /usr/bin/sed -n "s/^$1=//p" PROVENANCE.txt | head -1; }
say "mode=$mode"
say "started_utc=$(date -u)"
say "bundle_revision=$(prov bundle_revision) source_commit=$(prov source_commit)"
{ /usr/bin/uname -a; /usr/bin/sw_vers; /usr/sbin/sysctl -n machdep.cpu.brand_string hw.model hw.memsize 2>/dev/null || true; /usr/bin/uptime; } > "$report/host.txt"
cp PROVENANCE.txt "$report/bundle-PROVENANCE.txt"
[[ $(/usr/bin/uname -m) == arm64 ]] || { say 'INELIGIBLE: run from a native arm64 Terminal (not Rosetta)'; exit 1; }

# 1. Integrity and identity of the bundle.
library=$root/lib/libMoltenVK.1.4.3.dylib
library_sha256=$(prov library_sha256)
source_commit=$(prov source_commit)
/usr/bin/shasum -a 256 -c SHA256SUMS > "$report/integrity.log" 2>&1 || { say 'VERIFY FAIL: SHA256SUMS does not match; see integrity.log'; exit 1; }
[[ $(/usr/bin/readlink lib/libMoltenVK.1.dylib) == libMoltenVK.1.4.3.dylib ]] || { say 'VERIFY FAIL: lib/libMoltenVK.1.dylib alias'; exit 1; }
[[ $(/usr/bin/shasum -a 256 "$library" | cut -d' ' -f1) == "$library_sha256" ]] || { say 'VERIFY FAIL: library identity'; exit 1; }
for binary in lib/*.dylib bin/* cts/deqp-vk; do
	[[ -L $binary ]] && continue
	/usr/bin/codesign --verify --strict "$binary" >> "$report/integrity.log" 2>&1 || { say "VERIFY FAIL: signature of $binary"; exit 1; }
	/usr/bin/file "$binary" >> "$report/integrity.log"
done
say "VERIFY PASS: integrity, signatures and library $library_sha256"

# child SECONDS [NAME=VALUE...] PROGRAM [ARGS...]: bounded, in an environment made only of the given words. env comes
# after the system Perl, which macOS protects: dyld drops DYLD_* variables when it starts a protected program.
child() {
	local seconds=$1
	shift
	/usr/bin/perl "$root/timeout.pl" "$seconds" /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" "$@"
}
validation_env='MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1'
# loaded LOG: dyld's list must name the bundled library, and no other MoltenVK; prints the images it found. Recent dyld
# versions put the image UUID, as <UUID>, before the path.
loaded() {
	local images
	images=$(/usr/bin/sed -n 's/^dyld\[[0-9]*\]: \(<[^>]*> \)\{0,1\}\(.*libMoltenVK.*\)$/\2/p' "$1" | LC_ALL=C /usr/bin/sort -u)
	echo "${images:-none}" | /usr/bin/paste -sd' ' -
	[[ $images == "$library" ]]
}
checked_log() { # LOG: Metal validation announced, no validation or execution error, only the bundled library loaded
	/usr/bin/grep -q 'Metal API Validation Enabled' "$1" && /usr/bin/grep -q 'Metal GPU Validation Enabled' "$1" || { echo 'Metal validation not announced'; return 1; }
	! /usr/bin/grep -qiE 'Shader Validation|GPU Address Sanitizer|validation error|Execution of the command buffer was aborted|execution failed' "$1" || { echo 'Metal validation or execution error'; return 1; }
	local images
	images=$(loaded "$1") || { echo "libMoltenVK images: $images"; return 1; }
}

# 2. G, identity probe: revision embedded in the loaded library, library actually loaded, and the public guard at the
# API: VK_KHR_fragment_shader_barycentric absent before mvkEnableTESFixtureDevice, present after it.
probe_rc=0
child 30 DYLD_PRINT_LIBRARIES=1 $validation_env MVK_CONFIG_LOG_LEVEL=2 "$root/bin/probe" > "$report/capabilities.txt" 2> "$report/probe.log" || probe_rc=$?
cap() { /usr/bin/sed -n "s/^$1=//p" "$report/capabilities.txt" | head -1; }
images=$(loaded "$report/probe.log") || { say "IDENTITY FAIL: loaded libMoltenVK images: $images"; exit 1; }
loaded_sha256=$(/usr/bin/shasum -a 256 "$images" | cut -d' ' -f1)
problems=
[[ $probe_rc == 0 && $(cap probe.complete) == 1 ]] || problems="$problems probe_exit=$probe_rc"
/usr/bin/grep -q 'Metal API Validation Enabled' "$report/probe.log" && /usr/bin/grep -q 'Metal GPU Validation Enabled' "$report/probe.log" || problems="$problems metal_validation_not_announced"
[[ $loaded_sha256 == "$library_sha256" ]] || problems="$problems loaded_sha256=$loaded_sha256"
[[ $(cap vk.mvk_revision) == "${source_commit:0:8}" ]] || problems="$problems mvk_revision=$(cap vk.mvk_revision)"
[[ $(cap vk.public.feature.fragmentShaderBarycentric) == 0 ]] || problems="$problems public_fragmentShaderBarycentric=$(cap vk.public.feature.fragmentShaderBarycentric)"
[[ $(cap vk.feature.fragmentShaderBarycentric) == 1 ]] || problems="$problems activated_fragmentShaderBarycentric=$(cap vk.feature.fragmentShaderBarycentric)"
[[ -z $problems ]] || { say "IDENTITY FAIL:$problems (capabilities.txt, probe.log)"; exit 1; }
say "IDENTITY PASS: source_commit=$source_commit mvk_revision=$(cap vk.mvk_revision) loaded=$images loaded_sha256=$loaded_sha256"
say "  metal=\"$(cap mtl.name)\" vulkan=\"$(cap vk.device_name)\" os=\"$(cap os.version)\" apple7=$(cap mtl.family.apple7) apple9=$(cap mtl.family.apple9) apple10=$(cap mtl.family.apple10)"
say "  guard: fragmentShaderBarycentric without activation=$(cap vk.public.feature.fragmentShaderBarycentric), after mvkEnableTESFixtureDevice=$(cap vk.feature.fragmentShaderBarycentric)"
say 'PLAN: B dynamic topology (14), C split (2), D CTS minimal scope (1201), F CTS without activation (1201), E CTS ordinary (562)'
[[ "$mode" == --qualify ]] || { say 'VERIFY-ONLY COMPLETE: no GPU work submitted'; completed=1; exit 0; }

# 3. The closed test list, in order. A failure or a divergence stops every later step.
stopped=0 failed=0
finish_step() { # NAME EXPECTED RESULTS
	local line rc=0
	line=$(/usr/bin/perl "$root/compare.pl" "$2" "$3" "$report/compare-$1.txt") || rc=$?
	if [[ $rc == 0 ]]; then say "STEP $1 PASS: $line"; else say "STEP $1 FAIL: $line (compare-$1.txt)"; /usr/bin/head -5 "$report/compare-$1.txt" | /usr/bin/sed 's/^/    /' | tee -a "$summary"; stopped=1; failed=1; fi
}
program_step() { # NAME PROGRAM SHADERS EXPECTED EXIT PATTERN STATUS: one program run per expected case, 60 s each; @CASE@ in
	# the pattern stands for the case words
	local name=$1 program=$2 shaders=$3 expected=$4 want_exit=$5 template=$6 want_status=$7 entry case rc log detail status pattern
	local results=$report/results-$name.csv
	: > "$results"
	while IFS=, read -r case entry; do
		log=$report/$name-${case//:/-}.log rc=0
		# shellcheck disable=SC2086 # the environment is a list of NAME=VALUE words; the case is words separated by ":"
		child 60 DYLD_PRINT_LIBRARIES=1 $validation_env MVK_CONFIG_LOG_LEVEL=2 "$root/bin/$program" "$root/shaders/$shaders" ${case//:/ } > "$log" 2>&1 || rc=$?
		status=$want_status pattern=${template//@CASE@/${case//:/ }}
		if [[ $rc == 124 ]]; then status='FAIL:timeout after 60 s'
		elif ! detail=$(checked_log "$log"); then status="FAIL:$detail"
		elif [[ $rc != "$want_exit" ]] || ! /usr/bin/grep -qE "^$pattern" "$log"; then status="FAIL:exit=$rc"
		fi
		echo "$case,$status" >> "$results"
		say "  $name $case ${status%%:*} exit=$rc $(/usr/bin/grep -m1 -E '^(static vs dynamic|SPLIT_ATTACHMENT|submit=)' "$log" | cut -c1-150)"
	done < "$expected"
	finish_step "$name" "$expected" "$results"
}
cts_step() { # NAME VULKAN-LIBRARY LIST EXPECTED [NAME=VALUE...]: deqp-vk in chunks of 200, 1800 s per chunk
	local name=$1 vulkan=$2 list=$3 expected=$4 rc=0
	shift 4
	# shellcheck disable=SC2086 # the environment is a list of NAME=VALUE words
	/usr/bin/perl "$root/cts.pl" "$root/cts" "$vulkan" "$library" "$root/lists/$list" "$report/cts-$name" 200 1800 -- \
		DYLD_PRINT_LIBRARIES=1 $validation_env MVK_CONFIG_LOG_LEVEL=1 MVK_CONFIG_RESUME_LOST_DEVICE=1 MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=1 \
		MVK_CONFIG_VK_SEMAPHORE_SUPPORT_STYLE=2 "$@" > "$report/cts-$name.log" 2>&1 || rc=$?
	if [[ $rc != 0 ]]; then say "STEP $name FAIL: cts.pl exit=$rc: $(tail -1 "$report/cts-$name.log")"; stopped=1; failed=1; return; fi
	finish_step "$name" "$root/expected/$expected" "$report/cts-$name/results.csv"
}
step() { # NAME DESCRIPTION FUNCTION ARGS...
	local name=$1 description=$2
	shift 2
	if [[ $stopped == 1 ]]; then say "STEP $name NOT-RUN: stopped by an earlier failure ($description)"; return; fi
	say "STEP $name START $(date -u +%H:%M:%S): $description"
	/usr/bin/uptime >> "$report/load.txt"
	"$@"
}
step B 'dynamic topology oracle' program_step B dynamic-topology dynamic "$root/expected/B.txt" 0 'PERVERTEX_DYNAMIC_TOPOLOGY PASS @CASE@$' PASS
step C 'capture/replay split, memoryless attachments' program_step C split split "$root/expected/C.txt" 4 'SPLIT_ATTACHMENT REFUSED' REFUSED
step D 'CTS minimal scope, candidate activated through the CTS shim' cts_step D "$root/lib/libpervertex-cts-shim.dylib" experimental-vsfs-barycentric.txt D.csv PERVERTEX_CTS_MOLTENVK="$library"
step F 'CTS minimal scope, candidate library without activation' cts_step F "$library" experimental-vsfs-barycentric.txt F.csv
# E last: its expected statuses were measured on M4; a Mac with other capabilities may differ without a candidate defect.
step E 'CTS ordinary topologies and fans, through the CTS shim' cts_step E "$root/lib/libpervertex-cts-shim.dylib" ordinary-fan-topology.txt E.csv PERVERTEX_CTS_MOLTENVK="$library"
/usr/bin/shasum -a 256 -c SHA256SUMS > "$report/integrity-after.log" 2>&1 || { say 'VERIFY FAIL after the qualification: SHA256SUMS'; exit 1; }
completed=1
if [[ $failed != 0 ]]; then say 'QUALIFICATION FAIL'; exit 1; fi
say 'QUALIFICATION PASS: every step identical to its expected file, case by case'
