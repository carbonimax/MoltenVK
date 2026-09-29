#!/bin/bash
# Copyright 2026 Jean-Philippe Meunier
# SPDX-License-Identifier: Apache-2.0
# Mac family harness runner (macOS system Bash 3.2 and Perl only).
#   --verify-only  integrity, signatures, library identity, capability probe and the smoke plan; no GPU work is submitted
#                  (the probe only creates a Metal device and a Vulkan instance).
#   --smoke        the same, then the bounded smoke cases the probed capabilities admit, one process at a time.
# Every eligibility decision comes from the probe, never from the name of the Mac. Each case ends as PASS, FAIL,
# REFUSED (the implementation refused a form it was expected to render), SKIPPED (a required capability is absent,
# with the missing keys) or NOT-RUN (a previous failure stopped the GPU cases). Each invocation writes
# reports/<UTC>-<PID>/ and reports/<UTC>-<PID>.tar.gz, to send back even on failure.
set -euo pipefail
root=$(cd "$(dirname "$0")" && pwd -P)
cd "$root"
mode=${1:-}
case "$mode" in
	--verify-only|--smoke) [[ $# == 1 ]] || { echo 'Usage: ./run.sh --verify-only | --smoke'; exit 64; } ;;
	*) echo 'Usage: ./run.sh --verify-only | --smoke'; exit 64 ;;
esac
mkdir "$root/.run-lock" 2>/dev/null || { echo 'STOP: another run is active, or a stale .run-lock remains after a hard kill; check that no bin/ process runs before removing it'; exit 75; }
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

say "mode=$mode"
say "started_utc=$(date -u)"
{ /usr/bin/uname -a; /usr/bin/sw_vers; /usr/sbin/sysctl -n machdep.cpu.brand_string hw.model hw.memsize 2>/dev/null || true; /usr/bin/uptime; } > "$report/host.txt"
cp PROVENANCE.txt "$report/bundle-PROVENANCE.txt"
[[ $(/usr/bin/uname -m) == arm64 ]] || { say 'INELIGIBLE: run from a native arm64 Terminal (not Rosetta)'; exit 1; }

# 1. Integrity and identity of the bundle.
/usr/bin/shasum -a 256 -c SHA256SUMS > "$report/integrity.log" 2>&1 || { say 'VERIFY FAIL: SHA256SUMS does not match; see integrity.log'; exit 1; }
[[ $(/usr/bin/readlink lib/libMoltenVK.1.dylib) == libMoltenVK.1.4.3.dylib ]] || { say 'VERIFY FAIL: lib/libMoltenVK.1.dylib alias'; exit 1; }
expected_library=$(/usr/bin/sed -n 's/^library_sha256=//p' PROVENANCE.txt)
[[ $(/usr/bin/shasum -a 256 lib/libMoltenVK.1.4.3.dylib | cut -d' ' -f1) == "$expected_library" ]] || { say 'VERIFY FAIL: library identity'; exit 1; }
for binary in lib/libMoltenVK.1.4.3.dylib bin/*; do
	/usr/bin/codesign --verify --strict "$binary" >> "$report/integrity.log" 2>&1 || { say "VERIFY FAIL: signature of $binary"; exit 1; }
	/usr/bin/file "$binary" >> "$report/integrity.log"
done
say "VERIFY PASS: integrity, signatures and library $expected_library"

# 2. Capabilities: Metal and Vulkan as the bundled library exposes them, before and after the test adapters.
# child SECONDS [NAME=VALUE...] PROGRAM [ARGS...]: bounded, in a clean environment. env comes after the system Perl,
# which macOS protects: dyld drops DYLD_* variables when it starts a protected program.
child() {
	local seconds=$1
	shift
	/usr/bin/perl "$root/timeout.pl" "$seconds" /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" \
		MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 MVK_CONFIG_LOG_LEVEL=2 "$@"
}
probe_rc=0
child 30 "$root/bin/probe" > "$report/capabilities.txt" 2> "$report/probe.log" || probe_rc=$?
cap() { /usr/bin/sed -n "s/^$1=//p" "$report/capabilities.txt" | head -1; }
[[ $probe_rc == 0 && $(cap probe.complete) == 1 ]] || { say "PROBE FAIL: exit=$probe_rc (capabilities.txt, probe.log)"; exit 1; }
validation=0
/usr/bin/grep -q 'Metal API Validation Enabled' "$report/probe.log" && /usr/bin/grep -q 'Metal GPU Validation Enabled' "$report/probe.log" && validation=1
echo "metal.validation=$validation" >> "$report/capabilities.txt"
say "PROBE PASS: metal=\"$(cap mtl.name)\" vulkan=\"$(cap vk.device_name)\" os=\"$(cap os.version)\" metal3=$(cap mtl.family.metal3) apple7=$(cap mtl.family.apple7) apple9=$(cap mtl.family.apple9) apple10=$(cap mtl.family.apple10) metal_validation=$validation"
say "  public (without adapters): fragmentShaderBarycentric=$(cap vk.public.feature.fragmentShaderBarycentric) meshShader=$(cap vk.public.feature.meshShader)"
say "  with test adapters: fragmentShaderBarycentric=$(cap vk.feature.fragmentShaderBarycentric) meshShader=$(cap vk.feature.meshShader) tessellationShader=$(cap vk.feature.tessellationShader) drawIndirectCount=$(cap vk.ext.VK_KHR_draw_indirect_count)"

# 3. Smoke cases: name|kind|fixture|arguments|environment|expected exit|success pattern|required capabilities|prerequisite case
# kind: gate (no GPU submission), render (GPU work), refusal (MoltenVK must refuse before any GPU draw), measure (Metal
# only, without MoltenVK: the probe must finish; its per-limit verdicts are data for the report), metal (Metal only,
# without MoltenVK, with a verdict).
indirect_caps='vk.feature.fragmentShaderBarycentric vk.ext.VK_KHR_draw_indirect_count vk.feature.shaderDrawParameters vk.feature.drawIndirectFirstInstance vk.feature.multiDrawIndirect vk.feature.vertexPipelineStoresAndAtomics'
tes_caps='vk.feature.tessellationShader vk.feature.shaderDrawParameters vk.feature.vertexPipelineStoresAndAtomics vk.feature.fragmentStoresAndAtomics vk.feature.multiDrawIndirect'
mesh_caps='vk.feature.meshShader vk.feature.fragmentShaderBarycentric vk.feature.shaderDrawParameters vk.feature.bufferDeviceAddress'
indirect_env='PERVERTEX_TEST_TOPOLOGY=triangle-list'
# Continuation: arguments produced by a split producer released by a late host signal, a dependent submission C and
# vkQueueWaitIdle. A legal draw must render; a lost draw must lose the device with C never reporting success.
continuation_caps="$indirect_caps vk.feature.timelineSemaphore"
continuation_env='PERVERTEX_TEST_SPLIT_PRODUCER=1 PERVERTEX_TEST_LATE_SIGNAL=1 PERVERTEX_TEST_DEPENDENT_SUBMISSION=1 PERVERTEX_TEST_WAIT_IDLE=1 MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS=0'
sync_same='MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=1 PERVERTEX_TEST_DEPENDENT_SAME_QUEUE=1'
# Prefill abandon: a deferred prefilled command buffer, reset, freed or destroyed with its pool before any submission,
# with or without a device loss, returns its pooled buffer exactly once and executes nothing.
abandon_env='MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS=1'
cases=(
	"mesh-gate|gate|mesh-draw|@SHADERS@/mesh no-adapter||0|^MESH_DRAW PASS|vk.instance|"
	"metal-abandon|metal|abandon-probe|||0|^ABANDON_PROBE PASS|mtl.present|"
	"prefill-abandon-reset|render|pervertex-loss|prefill-abandon-reset|$abandon_env MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=1|0|^PREFILL_ABANDON PASS|vk.feature.timelineSemaphore|metal-abandon"
	"prefill-abandon-free|render|pervertex-loss|prefill-abandon-free|$abandon_env MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=0|0|^PREFILL_ABANDON PASS|vk.feature.timelineSemaphore|metal-abandon"
	"prefill-abandon-pool|render|pervertex-loss|prefill-abandon-pool|$abandon_env MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=1|0|^PREFILL_ABANDON PASS|vk.feature.timelineSemaphore|metal-abandon"
	"prefill-abandon-reset-lost|render|pervertex-loss|prefill-abandon-reset-lost|$abandon_env MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=0|0|^PREFILL_ABANDON PASS|vk.feature.timelineSemaphore|metal-abandon"
	"pervertex-direct-indirect|render|pervertex-indirect-gpu|@SHADERS@/indirect draw u32 decisive compute @PREFIX@|$indirect_env PERVERTEX_TEST_SWAP_FRAGMENT=0|0|^PERVERTEX_INDIRECT PASS|$indirect_caps|"
	"pervertex-indexed-indirect|render|pervertex-indirect-gpu|@SHADERS@/indirect indexed u32 decisive compute @PREFIX@|$indirect_env PERVERTEX_TEST_SWAP_FRAGMENT=0|0|^PERVERTEX_INDIRECT PASS|$indirect_caps|"
	"pervertex-swap-negative|render|pervertex-indirect-gpu|@SHADERS@/indirect draw u32 decisive compute @PREFIX@|$indirect_env PERVERTEX_TEST_SWAP_FRAGMENT=1|2|pixel_mismatches=[1-9]|$indirect_caps|pervertex-direct-indirect"
	"continuation-legal-sync|render|pervertex-indirect-gpu|@SHADERS@/indirect draw u32 single compute @PREFIX@|$continuation_env $sync_same|0|^PERVERTEX_INDIRECT PASS|$continuation_caps|pervertex-direct-indirect"
	"continuation-restart-async|render|pervertex-indirect-gpu|@SHADERS@/indirect indexed-count u16 restart-two compute @PREFIX@|$continuation_env MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=0 PERVERTEX_TEST_DEPENDENT_FIRST=1|0|^PERVERTEX_INDIRECT PASS|$continuation_caps|pervertex-indexed-indirect"
	"continuation-huge-loss|render|pervertex-indirect-gpu|@SHADERS@/indirect indexed-count u32 huge compute @PREFIX@|$continuation_env MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=0 PERVERTEX_TEST_DEPENDENT_FIRST=1|0|^PERVERTEX_INDIRECT PASS|$continuation_caps|continuation-legal-sync"
	"continuation-index-oob-loss|render|pervertex-indirect-gpu|@SHADERS@/indirect indexed u32 index-oob compute @PREFIX@|$continuation_env $sync_same|0|^PERVERTEX_INDIRECT PASS|$continuation_caps|continuation-legal-sync"
	"tes-ordinary-direct|render|topology|@SHADERS@/tes ordinary-levels-direct ccw @PREFIX@||0|^TES_TOPOLOGY PASS|$tes_caps|"
	"tes-ordinary-indexed|render|topology|@SHADERS@/tes ordinary-levels-indexed ccw @PREFIX@||0|^TES_TOPOLOGY PASS|$tes_caps|"
	"tes-pervertex-f1|render|topology|@SHADERS@/tes f1 ccw @PREFIX@||0|^TES_TOPOLOGY PASS|$tes_caps vk.feature.fragmentShaderBarycentric|"
	"tes-scratch-limit-prefill|refusal|topology|@SHADERS@/tes ordinary-levels-scratch-limit ccw @PREFIX@|MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS=1|0|nothing submitted|$tes_caps|"
	"tes-scratch-limit-async|refusal|topology|@SHADERS@/tes ordinary-levels-scratch-limit ccw @PREFIX@|MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS=0 MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=0|0|nothing submitted|$tes_caps|tes-scratch-limit-prefill"
	"tes-level4-loss|render|pervertex-indirect-gpu|@SHADERS@/indirect draw u32 single compute @PREFIX@|$continuation_env $sync_same PERVERTEX_TEST_INCLUDE_TES=1 PERVERTEX_TEST_TES_FIRST=1 PERVERTEX_TEST_TES_LEVEL4=1|0|^PERVERTEX_INDIRECT PASS|$continuation_caps $tes_caps|tes-pervertex-f1"
	"mesh-draw|render|mesh-draw|@SHADERS@/mesh draw||0|^MESH_DRAW PASS|$mesh_caps|"
	"mesh-pervertex|render|mesh-draw|@SHADERS@/mesh pervertex||0|^MESH_DRAW PASS|$mesh_caps|"
	"mesh-form-mixed|render|mesh-draw|@SHADERS@/mesh form-mixed||0|^MESH_DRAW PASS|$mesh_caps|"
	"mesh-grid-limit|refusal|mesh-draw|@SHADERS@/mesh reject-grid-limit||0|^MESH_DRAW PASS|$mesh_caps|"
	"mesh-limits|measure|mesh-limits|||0|^MESH_LIMITS DONE|mtl.family.metal3|"
)
field() { echo "$1" | cut -d'|' -f"$2"; }
# Harness verification only: HARNESS_ASSUME_MISSING lists capability keys to treat as absent, so that the skip paths can
# be exercised on a Mac that has them. The summary marks every such run as a simulation.
assume_missing=${HARNESS_ASSUME_MISSING:-}
[[ -z $assume_missing ]] || say "SIMULATION: HARNESS_ASSUME_MISSING=$assume_missing; results of this run do not describe this Mac"
missing_caps() {
	local key value missing=
	for key in $1; do
		value=$(cap "$key")
		case " $assume_missing " in *" $key "*) value=0;; esac
		[[ -n $value && $value != 0 ]] || missing="$missing $key"
	done
	[[ $validation == 1 ]] || missing="$missing metal.validation"
	echo "${missing# }"
}
say "SMOKE PLAN (from the probed capabilities):"
for entry in "${cases[@]}"; do
	missing=$(missing_caps "$(field "$entry" 8)")
	if [[ -n $missing ]]; then say "  PLAN $(field "$entry" 1) SKIP missing: $missing"; else say "  PLAN $(field "$entry" 1) RUN ($(field "$entry" 2))"; fi
done
[[ "$mode" == --smoke ]] || { say 'VERIFY-ONLY COMPLETE: no GPU work submitted'; completed=1; exit 0; }

# 4. Smoke run, sequential. A FAIL stops every later GPU case; a refusal or a skip does not.
statuses=
status_of() { echo "$statuses" | /usr/bin/sed -n "s/^$1=//p" | head -1; }
stopped=0 pass=0 fail=0 refused=0 skipped=0 not_run=0
for entry in "${cases[@]}"; do
	name=$(field "$entry" 1) kind=$(field "$entry" 2) fixture=$(field "$entry" 3) args=$(field "$entry" 4) case_env=$(field "$entry" 5)
	expected=$(field "$entry" 6) pattern=$(field "$entry" 7) prerequisite=$(field "$entry" 9)
	missing=$(missing_caps "$(field "$entry" 8)") status= detail=
	if [[ $stopped == 1 ]]; then status=NOT-RUN detail='stopped by an earlier FAIL'
	elif [[ -n $missing ]]; then status=SKIPPED detail="missing: $missing"
	elif [[ -n $prerequisite && $(status_of "$prerequisite") != PASS ]]; then status=SKIPPED detail="prerequisite $prerequisite did not pass"
	else
		log=$report/$name.log rc=0
		# Placeholders are replaced per word, so that paths with spaces stay single arguments.
		read -r -a words <<< "$args"
		argv=()
		# Bash 3.2 treats an empty array as unbound under set -u.
		for word in ${words[@]+"${words[@]}"}; do
			word=${word//@SHADERS@/$root/shaders}
			argv+=("${word//@PREFIX@/$report/$name}")
		done
		/usr/bin/uptime >> "$report/load.txt"
		# shellcheck disable=SC2086 # the case environment is a list of NAME=VALUE words
		# The Metal mesh limits probe compiles and draws some forty pipelines: it gets 240 s, every other case 40 s.
		seconds=40
		[[ $kind != measure ]] || seconds=240
		child $seconds DYLD_PRINT_LIBRARIES=1 $case_env "$root/bin/$fixture" ${argv[@]+"${argv[@]}"} > "$log" 2>&1 || rc=$?
		# dyld prints the real path of every image it loads: exactly the bundled library, and no other MoltenVK.
		loaded=$(/usr/bin/grep -cF " $root/lib/libMoltenVK.1.4.3.dylib" "$log" || true)
		others=$(/usr/bin/grep -E '^dyld\[[0-9]+\]: ' "$log" | /usr/bin/grep 'libMoltenVK' | /usr/bin/grep -vcF " $root/lib/libMoltenVK.1.4.3.dylib" || true)
		# The Metal probes load no MoltenVK at all.
		[[ $kind != measure && $kind != metal ]] || { [[ $others == 0 && $loaded == 0 ]] && loaded=1; }
		if [[ $rc == 124 ]]; then status=FAIL detail="timeout after $seconds s"
		elif [[ $loaded == 0 || $others != 0 ]]; then status=FAIL detail='the bundled libMoltenVK was not the one loaded'
		elif ! /usr/bin/grep -q 'Metal API Validation Enabled' "$log" || ! /usr/bin/grep -q 'Metal GPU Validation Enabled' "$log"; then status=FAIL detail='Metal API/GPU validation did not announce activation'
		elif /usr/bin/grep -qiE 'Shader Validation|GPU Address Sanitizer|validation error|Execution of the command buffer was aborted|execution failed' "$log"; then status=FAIL detail="Metal validation or execution error (exit=$rc)"
		elif /usr/bin/grep -qE '^(TES_TOPOLOGY|MESH_DRAW) SKIP' "$log"; then status=SKIPPED detail="$(/usr/bin/grep -E '^(TES_TOPOLOGY|MESH_DRAW) SKIP' "$log" | head -1)"
		elif [[ $rc == "$expected" ]] && /usr/bin/grep -qE -- "$pattern" "$log"; then status=PASS detail="exit=$rc"
		elif [[ $kind != refusal ]] && /usr/bin/grep -qE 'VK_ERROR_FEATURE_NOT_PRESENT|: -8$|=-8( |,|$)' "$log"; then status=REFUSED detail="exit=$rc: $(/usr/bin/grep -m1 -E 'mvk-error|ERROR' "$log" | cut -c1-200)"
		else status=FAIL detail="exit=$rc expected=$expected"
		fi
		[[ $status != FAIL ]] || stopped=1
	fi
	statuses="$statuses
$name=$status"
	case $status in PASS) pass=$((pass + 1));; FAIL) fail=$((fail + 1));; REFUSED) refused=$((refused + 1));; SKIPPED) skipped=$((skipped + 1));; NOT-RUN) not_run=$((not_run + 1));; esac
	say "CASE $name $status ($kind) $detail"
	[[ ! -f ${log:-/nonexistent} || $status == SKIPPED || $status == NOT-RUN ]] || /usr/bin/grep -E '^(MESH_DRAW|TES_TOPOLOGY|PERVERTEX_INDIRECT|ABANDON_PROBE|PREFILL_ABANDON|submission=|dependent wait|queue idle)|^  ' "$log" 2>/dev/null | head -6 | /usr/bin/sed 's/^/    /' | tee -a "$summary" || true
	[[ $name != mesh-limits || ! -f ${log:-/nonexistent} ]] || /usr/bin/grep -E '^(DEVICE|MESH_LIMIT [a-z])' "$log" | cut -c1-200 | /usr/bin/sed 's/^/    /' | tee -a "$summary" || true
	log=
done
/usr/bin/shasum -a 256 -c SHA256SUMS > "$report/integrity-after.log" 2>&1 || { say 'VERIFY FAIL after the smoke: SHA256SUMS'; exit 1; }
say "SMOKE TOTAL: pass=$pass fail=$fail refused=$refused skipped=$skipped not_run=$not_run"
completed=1
if [[ $fail != 0 ]]; then say 'SMOKE FAIL'; exit 1; fi
if [[ $refused != 0 || $skipped != 0 ]]; then say 'SMOKE INCOMPLETE: no failure, but some cases were refused or skipped (see above)'; exit 3; fi
say 'SMOKE PASS'
