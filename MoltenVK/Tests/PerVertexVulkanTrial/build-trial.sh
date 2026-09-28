#!/bin/bash
# Copyright (c) 2026 Jean-Philippe Meunier
# SPDX-License-Identifier: Apache-2.0
# Builds the PerVertex Vulkan trial app for iOS devices from the committed sources of this checkout:
# 1. the MoltenVK test library for iOS (Debug arm64, iOS 16.0, test-only TES admission and the test device adapters);
# 2. the SPIR-V of the fixtures the app runs;
# 3. the Xcode project (XcodeGen) and the app, with any further xcodebuild arguments given here, for example
#    DEVELOPMENT_TEAM=<team> -allowProvisioningUpdates, or CODE_SIGNING_ALLOWED=NO for an unsigned build.
# TRIAL_PLATFORM=simulator builds for the arm64 iOS simulator instead: it checks the app's plumbing (library loading,
# cases, report), never GPU results, since the simulator's Metal is not a device's.
# Usage: build-trial.sh <output directory> [xcodebuild arguments...]
set -euo pipefail
trial=$(cd "$(dirname "$0")" && pwd)
tests=$(cd "$trial/.." && pwd)
root=$(cd "$tests/../.." && pwd)
output=$(mkdir -p "${1:?output directory}" && cd "$1" && pwd)
shift
git -C "$root" diff --quiet HEAD -- MoltenVK MoltenVKShaderConverter Common ExternalRevisions || { echo 'Commit the sources first: the app is built from committed sources'; exit 1; }
exec > >(tee "$output/build-trial.log") 2>&1
echo "moltenvk_head=$(git -C "$root" rev-parse HEAD)"

simulator=$([[ ${TRIAL_PLATFORM:-device} == simulator ]] && echo 1 || echo 0)
MVK_TEST_PLATFORM=$( (( simulator )) && echo ios-simulator || echo ios ) bash "$tests/PerVertexTES/build-library.sh" "$output/library" ON ON
# Embedded under the name the app loads (the library's install name is @rpath/libMoltenVK.1.dylib).
mkdir -p "$output/Frameworks"
cp "$output/library/build/moltenvk/MoltenVK/libMoltenVK.1.4.3.dylib" "$output/Frameworks/libMoltenVK.1.dylib"

shaders=$output/Shaders
rm -rf "$shaders" && mkdir -p "$shaders/indirect" "$shaders/mesh"
compile() { # target-env source output [defines...]
	glslangValidator -V --target-env "$1" "${@:4}" "$2" -o "$3" > /dev/null
	spirv-val --target-env "$1" "$3"
}
compile vulkan1.1 "$tests/pervertex-indirect.vert" "$shaders/indirect/indirect.vert.spv"
compile vulkan1.1 "$tests/pervertex-indirect.vert" "$shaders/indirect/reference.vert.spv" -DREFERENCE
compile vulkan1.1 "$tests/pervertex-indirect.frag" "$shaders/indirect/pervertex.frag.spv"
compile vulkan1.1 "$tests/pervertex-indirect.frag" "$shaders/indirect/pervertex-swap.frag.spv" -DSWAP
compile vulkan1.1 "$tests/pervertex-indirect-args.comp" "$shaders/indirect/args.comp.spv"
T=$tests/PerVertexTES
compile vulkan1.1 "$T/triangle.vert" "$shaders/indirect/tes-triangle.vert.spv"
compile vulkan1.1 "$T/triangle.tesc" "$shaders/indirect/tes-triangle.tesc.spv"
compile vulkan1.1 "$T/triangle.tesc" "$shaders/indirect/tes-level4.tesc.spv" -DLEVEL=4.0
compile vulkan1.1 "$T/ordered.tese" "$shaders/indirect/tes-ordered.tese.spv"
compile vulkan1.1 "$T/ordered.frag" "$shaders/indirect/tes-ordered.frag.spv"
compile vulkan1.1 "$T/wrong-patch.frag" "$shaders/indirect/tes-wrong-patch.frag.spv"
M=$tests/PerVertexMesh
compile vulkan1.3 "$M/mesh.mesh" "$shaders/mesh/mesh.mesh.spv"
compile vulkan1.3 "$M/interp.frag" "$shaders/mesh/interp.frag.spv"
compile vulkan1.3 "$M/pervertex.frag" "$shaders/mesh/pervertex.frag.spv"
compile vulkan1.3 "$M/forms.mesh" "$shaders/mesh/forms.mesh.spv"
compile vulkan1.3 "$M/forms.frag" "$shaders/mesh/form-mixed.frag.spv" -DMIXED

# XcodeGen resolves paths against the spec, so the spec and the sources are copied next to the generated project.
rm -rf "$output/app" && mkdir -p "$output/app"
cp -R "$trial/project.yml" "$trial/Sources" "$output/app/"
TRIAL_BUILD=$output TRIAL_TESTS=$tests xcodegen generate --spec "$output/app/project.yml" --project "$output/app"
destination=$( (( simulator )) && echo 'generic/platform=iOS Simulator' || echo 'generic/platform=iOS' )
xcodebuild -project "$output/app/PerVertexVulkanTrial.xcodeproj" -scheme PerVertexVulkanTrial -configuration Release -destination "$destination" \
	-derivedDataPath "$output/DerivedData" ARCHS=arm64 ONLY_ACTIVE_ARCH=NO ${@+"$@"} build
app=$output/DerivedData/Build/Products/Release-$( (( simulator )) && echo iphonesimulator || echo iphoneos )/PerVertexVulkanTrial.app
{
	cat "$output/library/PROVENANCE.txt"
	echo "app_executable_sha256=$(shasum -a 256 "$app/PerVertexVulkanTrial" | cut -d' ' -f1)"
	echo "embedded_library_sha256=$(shasum -a 256 "$app/Frameworks/libMoltenVK.1.dylib" | cut -d' ' -f1)"
	otool -L "$app/PerVertexVulkanTrial" | grep -q '@rpath/libMoltenVK.1.dylib' && echo "app_loads=@rpath/libMoltenVK.1.dylib"
	(cd "$shaders" && find . -name '*.spv' | LC_ALL=C sort | xargs shasum -a 256 | sed 's/^/shader /')
} > "$output/PROVENANCE.txt"
cat "$output/PROVENANCE.txt" | head -8
echo "PERVERTEX_VULKAN_TRIAL BUILT: $app"
