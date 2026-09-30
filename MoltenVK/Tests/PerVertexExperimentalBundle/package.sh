#!/bin/bash
# Copyright (c) 2026 Jean-Philippe Meunier
# SPDX-License-Identifier: Apache-2.0
# Builds the experimental PerVertexKHR candidate and its offline bundle, on the build Mac, from the committed HEAD of this
# checkout (which must be clean, with the runtime of fb3970cc):
# 1. the library with PerVertexTES/build-library.sh: TES admission OFF, test adapter linked, Debug arm64, private API
#    OFF, macOS deployment target 11.0, configured from the checkout root so that its embedded revision is HEAD;
# 2. the identity probe, the dynamic topology and split programs, and the CTS shim, linked to @executable_path/../lib
#    and signed ad hoc; the SPIR-V they read;
# 3. deqp-vk (a Release arm64 build for macOS 11.0 with the CTS's own libpng) and its data, the exact case lists, their
#    unversioned inputs, the per-case expected files, the sources and licences;
# 4. PROVENANCE.txt, SHA256SUMS, and <revision>.tar.gz with its .sha256.
# The bundle then runs on any Apple Silicon Mac with macOS tools only (run.sh). The host test suites (A) need a compiler
# and run on the build Mac only, outside the bundle.
# Inputs (defaults): PERVERTEX_BUNDLE_CTS the deqp-vk build directory
# (../VK-GL-CTS-1.4.6.2/build-bundle-macos11/external/vulkancts/modules/vulkan), PERVERTEX_BUNDLE_CTS_SOURCE the CTS
# checkout, PERVERTEX_BUNDLE_LISTS (build/cts-lists), PERVERTEX_BUNDLE_E_REFERENCE (the results.csv of
# build/astra/final-r7-fb3970cc/cts-ordinary-validated).
# Usage: package.sh <output directory>
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
tests=$(cd "$here/.." && pwd)
root=$(cd "$tests/../.." && pwd)
out=$(mkdir -p "${1:?output directory}" && cd "$1" && pwd)
revision=pervertex-experimental-c3
bundle=$out/$revision
[[ ! -e $bundle ]] || { echo "STOP: $bundle already exists"; exit 1; }
cts_source=${PERVERTEX_BUNDLE_CTS_SOURCE:-$(cd "$root/../VK-GL-CTS-1.4.6.2" && pwd)}
cts=${PERVERTEX_BUNDLE_CTS:-$cts_source/build-bundle-macos11/external/vulkancts/modules/vulkan}
lists=${PERVERTEX_BUNDLE_LISTS:-$root/build/cts-lists}
reference=${PERVERTEX_BUNDLE_E_REFERENCE:-$root/build/astra/final-r7-fb3970cc/cts-ordinary-validated/results.csv}
runtime_base=fb3970cc063e63b10b68640be751e0dcbf267efc
runtime_paths=(MoltenVK/MoltenVK MoltenVKShaderConverter/MoltenVKShaderConverter ExternalRevisions CMakeLists.txt MoltenVK/CMakeLists.txt
	MoltenVK/Tests/PerVertexTES/EnableTestDevice.mm)

# 1. Source and library.
cd "$root"
[[ -z $(git status --porcelain --untracked-files=no) ]] || { echo 'STOP: the checkout has uncommitted changes'; exit 1; }
source_commit=$(git rev-parse HEAD)
short=$(git rev-parse --short HEAD)
git diff --quiet "$runtime_base" HEAD -- "${runtime_paths[@]}" || { echo "STOP: the runtime differs from $runtime_base"; exit 1; }
cross=$(cd External/SPIRV-Cross && pwd -P)
MACOSX_DEPLOYMENT_TARGET=11.0 bash MoltenVK/Tests/PerVertexTES/build-library.sh "$out/library" OFF ON > "$out/library.log"
built=$out/library/build/moltenvk/MoltenVK
grep -qx 'MVK_USE_METAL_PRIVATE_API:BOOL=OFF' "$out/library/build/CMakeCache.txt" || { echo 'STOP: MVK_USE_METAL_PRIVATE_API is not OFF'; exit 1; }
grep -q "mvkRevString = \"$short\"" "$built/mvkGitRevDerived.h" || { echo "STOP: the embedded revision is not $short"; exit 1; }
minos() { otool -l "$1" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}'; }
[[ $(minos "$built/libMoltenVK.1.4.3.dylib") == 11.0 ]] || { echo 'STOP: the library does not target macOS 11.0'; exit 1; }

# 2. Programs, shim and SPIR-V.
mkdir -p "$bundle"/{bin,lib,cts,shaders/dynamic,shaders/split,lists,inputs,expected,source,licenses}
cp "$built/libMoltenVK.1.4.3.dylib" "$bundle/lib/"
ln -s libMoltenVK.1.4.3.dylib "$bundle/lib/libMoltenVK.1.dylib"
compile() { # target-env source output [defines...]
	glslangValidator -V --target-env "$1" "${@:4}" "$tests/$2" -o "$3" > /dev/null
	spirv-val --target-env "$1" "$3"
}
d=$bundle/shaders/dynamic
compile vulkan1.1 pervertex-indirect.vert "$d/indirect.vert.spv"
compile vulkan1.1 pervertex-indirect.vert "$d/indirect-w.vert.spv" -DVARIED_W
compile vulkan1.1 pervertex-indirect.frag "$d/pervertex-portable.frag.spv" -DPORTABLE
compile vulkan1.1 pervertex-dynamic-topology.frag "$d/ordinary.frag.spv"
compile vulkan1.1 pervertex-dynamic-topology.frag "$d/weights.frag.spv" -DWEIGHTS
compile vulkan1.1 pervertex-dynamic-topology.frag "$d/weights-noperspective.frag.spv" -DWEIGHTS -DNOPERSPECTIVE
compile vulkan1.1 pervertex-dynamic-topology.frag "$d/reference.frag.spv" -DREFERENCE
compile vulkan1.1 pervertex-dynamic-topology.frag "$d/reference-noperspective.frag.spv" -DREFERENCE -DNOPERSPECTIVE
compile vulkan1.1 pervertex-dynamic-reference.vert "$d/reference.vert.spv"
compile vulkan1.1 pervertex-dynamic-reference.vert "$d/reference-w.vert.spv" -DVARIED_W
compile vulkan1.1 pervertex-split.vert "$bundle/shaders/split/split.vert.spv"
compile vulkan1.1 pervertex-split.frag "$bundle/shaders/split/split.frag.spv"
headers=$root/External/Vulkan-Headers/include
program() { # output source [flags...]: as MacFamilyHarness/package.sh builds its fixtures
	xcrun clang++ -arch arm64 -std=c++17 -O2 -mmacosx-version-min=11.0 -Wall -Wextra -Werror -Wno-missing-field-initializers -DVK_ENABLE_BETA_EXTENSIONS \
		-I"$headers" "$2" "$bundle/lib/libMoltenVK.1.dylib" -Wl,-rpath,@executable_path/../lib "${@:3}" -o "$bundle/bin/$1"
	otool -L "$bundle/bin/$1" | grep -q '@rpath/libMoltenVK.1.dylib'
}
program probe "$tests/MacFamilyHarness/probe.mm" -DPROBE_BARYCENTRIC_ADAPTER_ONLY -fobjc-arc -framework Foundation -framework Metal
program dynamic-topology "$tests/PerVertexDynamicTopologyTests.mm" -framework Metal -framework Foundation
program split "$tests/PerVertexAttachmentSplitTests.mm" -framework Metal -framework Foundation
xcrun clang -dynamiclib -O2 -mmacosx-version-min=11.0 -Wall -Wextra -Werror -I"$headers" -install_name @rpath/libpervertex-cts-shim.dylib \
	"$tests/PerVertexCTS/AdapterShim.c" -o "$bundle/lib/libpervertex-cts-shim.dylib"
codesign -f -s - "$bundle"/bin/* "$bundle/lib/libpervertex-cts-shim.dylib" 2> /dev/null

# 3. CTS, lists, inputs, expected files, sources and licences.
otool -L "$cts/deqp-vk" | grep -q /opt/homebrew && { echo 'STOP: deqp-vk links a Homebrew library'; exit 1; }
[[ $(minos "$cts/deqp-vk") == 11.0 ]] || { echo 'STOP: deqp-vk does not target macOS 11.0'; exit 1; }
cp "$cts/deqp-vk" "$bundle/cts/"
cp -R "$cts/vulkan" "$bundle/cts/vulkan"
(cd "$lists" && shasum -a 256 -c SHA256SUMS > /dev/null) || { echo 'STOP: build/cts-lists does not match its SHA256SUMS'; exit 1; }
cp "$lists/experimental-vsfs-barycentric.txt" "$lists/ordinary-fan-topology.txt" "$bundle/lists/"
cp "$lists/barycentric-runnable.txt" "$lists/barycentric.txt" "$lists/SOURCE.txt" "$bundle/inputs/"
cp "$lists/SHA256SUMS" "$bundle/inputs/cts-lists-SHA256SUMS.txt"
cp "$reference" "$bundle/inputs/E-reference-final-r7-results.csv"
for f in direct indexed; do
	for g in pervertex ordinary weights weights-w weights-w-noperspective; do echo "triangles:$f:$g,PASS"; done
	for g in pervertex ordinary; do echo "lines:$f:$g,PASS"; done
done > "$bundle/expected/B.txt"
printf 'memoryless-depth,REFUSED\nmemoryless-stencil,REFUSED\n' > "$bundle/expected/C.txt"
sed 's/$/,Pass/' "$bundle/lists/experimental-vsfs-barycentric.txt" > "$bundle/expected/D.csv"
cut -d, -f1,2 "$reference" > "$bundle/expected/E.csv"
sed 's/$/,NotSupported/' "$bundle/lists/experimental-vsfs-barycentric.txt" > "$bundle/expected/F.csv"
diff <(cut -d, -f1 "$bundle/expected/E.csv" | sort) <(sort "$bundle/lists/ordinary-fan-topology.txt") > /dev/null || { echo 'STOP: the E reference does not cover exactly the E list'; exit 1; }
cp "$here/run.sh" "$here/cts.pl" "$here/compare.pl" "$tests/MacFamilyHarness/timeout.pl" "$here/README.md" "$bundle/"
cp "$here/package.sh" "$tests/MacFamilyHarness/probe.mm" "$tests/PerVertexDynamicTopologyTests.mm" "$tests/PerVertexAttachmentSplitTests.mm" \
	"$tests/PerVertexCTS/AdapterShim.c" "$tests/PerVertexCTS/select-experimental-scope.py" "$tests/PerVertexTES/EnableTestDevice.mm" \
	"$tests/PerVertexTES/build-library.sh" "$tests/pervertex-indirect.vert" "$tests/pervertex-indirect.frag" "$tests/pervertex-dynamic-topology.frag" \
	"$tests/pervertex-dynamic-reference.vert" "$tests/pervertex-split.vert" "$tests/pervertex-split.frag" "$bundle/source/"
cp "$root/LICENSE" "$bundle/licenses/MoltenVK-LICENSE.txt"
cp "$cts_source/LICENSE" "$bundle/licenses/VK-GL-CTS-LICENSE.txt"
cp "$cts_source/external/libpng/src/LICENSE" "$bundle/licenses/libpng-LICENSE.txt"

# 4. Provenance, checksums and archive.
tool() { "$@" 2>&1 | head -1; }
{
	echo "bundle_revision=$revision"
	echo "source_commit=$source_commit"
	echo "runtime_base=$runtime_base"
	echo "mvk_rev_string=$short"
	echo "spirv_cross_head=$(git -C "$cross" rev-parse HEAD)"
	for dependency in SPIRV-Tools Volk Vulkan-Headers Vulkan-Tools cereal; do echo "pin_$dependency=$(cat "ExternalRevisions/${dependency}_repo_revision")"; done
	echo "library_config=admission=OFF test_device=ON build_type=Debug arch=arm64 private_api=OFF macos_deployment_target=11.0"
	echo "library_sha256=$(shasum -a 256 "$bundle/lib/libMoltenVK.1.4.3.dylib" | cut -d' ' -f1)"
	echo "activation=the application calls mvkEnableTESFixtureDevice(VkPhysicalDevice); it opens VK_KHR_fragment_shader_barycentric only"
	echo "cts=vulkan-cts-1.4.6.2 $(git -C "$cts_source" rev-parse HEAD) Release arm64 macos_deployment_target=11.0 libpng=external (static)"
	echo "deqp_vk_sha256=$(shasum -a 256 "$bundle/cts/deqp-vk" | cut -d' ' -f1)"
	echo "cts_shim=AdapterShim.c as in the reference runs: it opens the barycentric and the mesh adapters; no case of D, E or F is a mesh case"
	echo "references=D and E: build/astra/final-r7-fb3970cc (admission ON), attendus, not proofs of this configuration; F: predicted; B: final-r7 and dyntopo-weights runs; C: final-r7"
	echo "build_host=$(sw_vers -productVersion) ($(sw_vers -buildVersion)) $(sysctl -n machdep.cpu.brand_string)"
	echo "tools=$(xcodebuild -version | tr '\n' ' ')/ $(tool cmake --version) / ninja $(ninja --version) / glslang $(tool glslangValidator --version) / $(tool spirv-val --version)"
} > "$bundle/PROVENANCE.txt"
chmod +x "$bundle/run.sh"
(cd "$bundle" && find . -type f ! -name SHA256SUMS | LC_ALL=C sort | while IFS= read -r path; do shasum -a 256 "$path"; done > SHA256SUMS)
tar -czf "$out/$revision.tar.gz" -C "$out" "$revision"
(cd "$out" && shasum -a 256 "$revision.tar.gz" > "$revision.tar.gz.sha256")
echo "bundle=$out/$revision.tar.gz sha256=$(cut -d' ' -f1 "$out/$revision.tar.gz.sha256") SHA256SUMS=$(shasum -a 256 "$bundle/SHA256SUMS" | cut -d' ' -f1)"
cat "$bundle/PROVENANCE.txt"
