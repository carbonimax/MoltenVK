#!/bin/bash
# Copyright 2026 Jean-Philippe Meunier
# SPDX-License-Identifier: Apache-2.0
# Builds the bundle that qualifies the loss inventory (R8) on a Mac without unified memory, where MoltenVK encodes the
# Metal synchronizations of vkInvalidateMappedMemoryRanges and vkCopyImageToMemoryEXT. On a build Mac with Command Line
# Tools, CMake and Ninja, for x86_64, macOS 11.0:
# - three test libraries, each from an archive of an exact commit with the current build-library.sh: before (the first
#   R8, whose synchronizations acquire inside their bracket and have no admission check), after (the final R8), and a
#   negative control (after, with both admission checks removed by an exact replacement, kept as a patch);
# - the loss oracles from this checkout's committed PerVertexLossTests.mm, linked to @executable_path/lib, ad-hoc signed;
# - run.sh, timeout.pl, the README, the sources, PROVENANCE.txt, SHA256SUMS, the archive and its checksum.
# Usage: package.sh <output directory> [before commit [after commit [bundle name]]]
set -euo pipefail
harness=$(cd "$(dirname "$0")" && pwd)
tests=$(cd "$harness/.." && pwd)
root=$(cd "$tests/../.." && pwd)
output=$(mkdir -p "${1:?output directory}" && cd "$1" && pwd)
before=$(git -C "$root" rev-parse --verify "${2:-67dd59d4}^{commit}")
after=$(git -C "$root" rev-parse --verify "${3:-d4110762}^{commit}")
name=${4:-non-unified-harness-r1}
head=$(git -C "$root" rev-parse HEAD)
git -C "$root" diff --quiet HEAD -- MoltenVK/Tests || { echo 'Commit the tests first: the bundle is built from committed sources'; exit 1; }
cross=$(cd "$root/External/SPIRV-Cross" && pwd -P)
for commit in "$before" "$after"; do
	[[ $(git -C "$cross" rev-parse HEAD) == $(git -C "$root" show "$commit:ExternalRevisions/SPIRV-Cross_repo_revision") ]] \
		|| { echo "SPIRV-Cross is not at the pin of $commit"; exit 1; }
done
git -C "$cross" diff --quiet HEAD || { echo 'SPIRV-Cross has local changes'; exit 1; }
exec > >(tee "$output/package.log") 2>&1
echo "head=$head before=$before after=$after spirv_cross=$(git -C "$cross" rev-parse HEAD)"

# 1. The libraries.
build() { # variant commit [mutate]
	local out=$output/library-$1 tree=$output/library-$1/src
	rm -rf "$out" && mkdir -p "$tree/External"
	git -C "$root" archive "$2" | tar -x -C "$tree"
	for dependency in SPIRV-Cross SPIRV-Tools Volk Vulkan-Headers Vulkan-Tools cereal; do ln -s "$(cd "$root/External/$dependency" && pwd -P)" "$tree/External/$dependency"; done
	cp "$tests/PerVertexTES/build-library.sh" "$tree/MoltenVK/Tests/PerVertexTES/build-library.sh"
	if [[ ${3:-} == mutate ]]; then
		(cd "$tree" && mkdir -p ../orig && cp MoltenVK/MoltenVK/GPUObjects/MVKDevice.mm MoltenVK/MoltenVK/GPUObjects/MVKImage.mm ../orig/ && python3 - <<'PY'
import sys
edits = {
	"MoltenVK/MoltenVK/GPUObjects/MVKDevice.mm":
		"\t\tif (isLosing()) {\n\t\t\tabandonMTLCommandBuffer(mvkBlitEnc.mtlCmdBuffer);\n\t\t\tmvkBlitEnc.mtlCmdBuffer = nil;\n\t\t}\n",
	"MoltenVK/MoltenVK/GPUObjects/MVKImage.mm":
		"\t\t\tif (getDevice()->isLosing()) {\n\t\t\t\tgetDevice()->abandonMTLCommandBuffer(mtlCmdBuff);\n\t\t\t\tmtlCmdBuff = nil;\n\t\t\t}\n",
}
for path, guard in edits.items():
	text = open(path).read()
	if text.count(guard) != 1: sys.exit(f"{path}: admission check not found once")
	open(path, "w").write(text.replace(guard, ""))
PY
		)
		(cd "$out" && { diff -u orig/MVKDevice.mm src/MoltenVK/MoltenVK/GPUObjects/MVKDevice.mm; diff -u orig/MVKImage.mm src/MoltenVK/MoltenVK/GPUObjects/MVKImage.mm; }) > "$out/no-admission.patch" || true
	fi
	MVK_TEST_ARCH=x86_64 MACOSX_DEPLOYMENT_TARGET=11.0 bash "$tree/MoltenVK/Tests/PerVertexTES/build-library.sh" "$out" ON ON > /dev/null
	local library=$out/build/moltenvk/MoltenVK/libMoltenVK.1.4.3.dylib
	[[ $(lipo -archs "$library") == x86_64 ]]
	[[ $(otool -D "$library" | tail -1) == @rpath/libMoltenVK.1.dylib ]]
	otool -l "$library" | grep -A4 LC_BUILD_VERSION | grep -q 'minos 11.0'
}
build before "$before"
build after "$after"
build no-admission "$after" mutate
[[ -s $output/library-no-admission/no-admission.patch ]]

# 2. The bundle tree.
bundle=$output/$name
rm -rf "$bundle" "$output/$name.tar.gz" "$output/$name.tar.gz.sha256"
mkdir -p "$bundle/source"
for variant in before after no-admission; do
	mkdir -p "$bundle/$variant/lib"
	cp "$output/library-$variant/build/moltenvk/MoltenVK/libMoltenVK.1.4.3.dylib" "$bundle/$variant/lib/"
	ln -s libMoltenVK.1.4.3.dylib "$bundle/$variant/lib/libMoltenVK.1.dylib"
done
xcrun clang++ -arch x86_64 -mmacosx-version-min=11.0 -std=c++17 -O2 -Wall -Wextra -Werror -Wno-missing-field-initializers \
	-I"$root/External/Vulkan-Headers/include" "$tests/PerVertexLossTests.mm" "$bundle/after/lib/libMoltenVK.1.4.3.dylib" \
	-Wl,-rpath,@executable_path/lib -framework Metal -framework QuartzCore -framework Foundation -o "$bundle/after/pervertex-loss"
codesign -s - -f "$bundle/after/pervertex-loss"
cp "$bundle/after/pervertex-loss" "$bundle/before/"
cp "$bundle/after/pervertex-loss" "$bundle/no-admission/"
cp "$harness/run.sh" "$harness/README.md" "$tests/MacFamilyHarness/timeout.pl" "$bundle/"
cp "$tests/PerVertexLossTests.mm" "$harness/package.sh" "$output/library-no-admission/no-admission.patch" "$bundle/source/"
{
	echo "harness_head=$head"
	echo "before=$before"
	echo "after=$after"
	echo "no_admission=$after with source/no-admission.patch"
	for variant in before after no-admission; do echo "[$variant]"; cat "$output/library-$variant/PROVENANCE.txt"; done
	echo "test_source_sha256=$(shasum -a 256 "$tests/PerVertexLossTests.mm" | cut -d' ' -f1)"
} > "$bundle/PROVENANCE.txt"
(cd "$bundle" && find . -type f ! -name SHA256SUMS | sort | xargs shasum -a 256 > SHA256SUMS)
tar -C "$output" -czf "$output/$name.tar.gz" "$name"
(cd "$output" && shasum -a 256 "$name.tar.gz" > "$name.tar.gz.sha256")
echo "BUNDLE $output/$name.tar.gz $(cut -d' ' -f1 "$output/$name.tar.gz.sha256")"
