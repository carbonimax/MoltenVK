#!/bin/bash
# Copyright 2026 Jean-Philippe Meunier
# SPDX-License-Identifier: Apache-2.0
# Builds the Mac family harness bundle and its archive, on a build Mac with Command Line Tools, CMake, Ninja,
# glslangValidator and spirv-val:
# - the test library from an exact MoltenVK commit (macOS 11.0 deployment target, TES test admission and the test
#   device adapters, as build-library.sh builds it for the TES and mesh tests), after checking that this checkout's
#   production sources equal that commit's;
# - the probe and the fixtures from this checkout's committed sources, linked to @executable_path/../lib and ad-hoc
#   signed, with the SPIR-V the smoke cases need;
# - the runner, its documentation, the sources, PROVENANCE.txt, SHA256SUMS, the archive and its checksum.
# Usage: package.sh <library base commit> <output directory> [bundle name]
set -euo pipefail
harness=$(cd "$(dirname "$0")" && pwd)
tests=$(cd "$harness/.." && pwd)
root=$(cd "$tests/../.." && pwd)
base=$(git -C "$root" rev-parse --verify "${1:?library base commit}^{commit}")
output=$(mkdir -p "${2:?output directory}" && cd "$2" && pwd)
name=${3:-mac-family-harness-r13}
head=$(git -C "$root" rev-parse HEAD)
git -C "$root" diff --quiet HEAD -- MoltenVK MoltenVKShaderConverter Common ExternalRevisions || { echo 'Commit the sources first: the bundle is built from committed sources'; exit 1; }
git -C "$root" diff --quiet "$base" HEAD -- MoltenVK/MoltenVK MoltenVKShaderConverter Common ExternalRevisions MoltenVK/Tests/PerVertexTES/EnableTestDevice.mm MoltenVK/Tests/PerVertexTES/build-library.sh \
	|| { echo "Library sources differ between $base and HEAD"; exit 1; }
cross=$(cd "$root/External/SPIRV-Cross" && pwd -P)
[[ $(git -C "$cross" rev-parse HEAD) == $(git -C "$root" show "$base:ExternalRevisions/SPIRV-Cross_repo_revision") ]] || { echo 'SPIRV-Cross is not at the pin of the base commit'; exit 1; }
git -C "$cross" diff --quiet HEAD || { echo 'SPIRV-Cross has local changes'; exit 1; }
exec > >(tee "$output/package.log") 2>&1
echo "base=$base head=$head spirv_cross=$(git -C "$cross" rev-parse HEAD)"

# 1. The library, from an archive of the base commit.
library_out=$output/library
tree=$library_out/src
rm -rf "$library_out" && mkdir -p "$tree/External"
git -C "$root" archive "$base" | tar -x -C "$tree"
for dependency in SPIRV-Cross SPIRV-Tools Volk Vulkan-Headers Vulkan-Tools cereal; do ln -s "$(cd "$root/External/$dependency" && pwd -P)" "$tree/External/$dependency"; done
MACOSX_DEPLOYMENT_TARGET=11.0 bash "$tree/MoltenVK/Tests/PerVertexTES/build-library.sh" "$library_out" ON ON > /dev/null
library=$library_out/build/moltenvk/MoltenVK/libMoltenVK.1.4.3.dylib
[[ $(otool -D "$library" | tail -1) == @rpath/libMoltenVK.1.dylib ]]
otool -l "$library" | grep -A4 LC_BUILD_VERSION | grep -q 'minos 11.0'

# 2. The bundle tree.
bundle=$output/$name
rm -rf "$bundle" "$output/$name.tar.gz" "$output/$name.tar.gz.sha256"
mkdir -p "$bundle/bin" "$bundle/lib" "$bundle/shaders/indirect" "$bundle/shaders/tes" "$bundle/shaders/mesh" "$bundle/source/fixtures" "$bundle/source/harness" \
	"$bundle/source/shaders/indirect" "$bundle/source/shaders/tes" "$bundle/source/shaders/mesh"
cp "$library" "$bundle/lib/"
ln -s libMoltenVK.1.4.3.dylib "$bundle/lib/libMoltenVK.1.dylib"

# 3. SPIR-V for the smoke cases.
compile() { # target-env source-dir source output [defines...]
	glslangValidator -V --target-env "$1" "${@:5}" "$2/$3" -o "$4" > /dev/null
	spirv-val --target-env "$1" "$4"
}
indirect=$bundle/shaders/indirect tes=$bundle/shaders/tes mesh=$bundle/shaders/mesh
compile vulkan1.1 "$tests" pervertex-indirect.vert "$indirect/indirect.vert.spv"
compile vulkan1.1 "$tests" pervertex-indirect.vert "$indirect/reference.vert.spv" -DREFERENCE
compile vulkan1.1 "$tests" pervertex-indirect.frag "$indirect/pervertex.frag.spv"
compile vulkan1.1 "$tests" pervertex-indirect.frag "$indirect/pervertex-swap.frag.spv" -DSWAP
compile vulkan1.1 "$tests" pervertex-indirect-args.comp "$indirect/args.comp.spv"
T=$tests/PerVertexTES
# The indirect driver's TES draw, recorded with the indirect draw in one command buffer; level 4 must lose the device.
compile vulkan1.1 "$T" triangle.vert "$indirect/tes-triangle.vert.spv"
compile vulkan1.1 "$T" triangle.tesc "$indirect/tes-triangle.tesc.spv"
compile vulkan1.1 "$T" triangle.tesc "$indirect/tes-level4.tesc.spv" -DLEVEL=4.0
compile vulkan1.1 "$T" ordered.tese "$indirect/tes-ordered.tese.spv"
compile vulkan1.1 "$T" ordered.frag "$indirect/tes-ordered.frag.spv"
compile vulkan1.1 "$T" wrong-patch.frag "$indirect/tes-wrong-patch.frag.spv"
for shader in triangle.vert triangle.tesc ordered.tese ordered.frag ordered-swapped.frag wrong-patch.frag control.frag noop.comp; do compile vulkan1.1 "$T" "$shader" "$tes/$shader.spv"; done
compile vulkan1.1 "$T" topology.vert "$tes/topology.vert.spv"
compile vulkan1.1 "$T" topology.vert "$tes/drawid.vert.spv" -DDRAWID
compile vulkan1.1 "$T" topology.vert "$tes/resources.vert.spv" -DRESOURCES
compile vulkan1.1 "$T" topology.tesc "$tes/push.tesc.spv" -DPUSH
compile vulkan1.1 "$T" topology.tesc "$tes/topology.tesc.spv"
compile vulkan1.1 "$T" topology.tesc "$tes/descriptor.tesc.spv" -DDESCRIPTOR
compile vulkan1.1 "$T" topology.tese "$tes/ccw.tese.spv"
compile vulkan1.1 "$T" topology.tese "$tes/cw.tese.spv" -DCW
compile vulkan1.1 "$T" topology.tese "$tes/capture-ccw.tese.spv" -DCAPTURE
compile vulkan1.1 "$T" topology.tese "$tes/capture-cw.tese.spv" -DCAPTURE -DCW
compile vulkan1.1 "$T" topology.tese "$tes/quads.tese.spv" -DQUADS
compile vulkan1.1 "$T" topology.tese "$tes/fractional.tese.spv" -DFRACTIONAL
compile vulkan1.1 "$T" topology.tese "$tes/points.tese.spv" -DPOINTS
compile vulkan1.1 "$T" ordinary.frag "$tes/ordinary.frag.spv"
compile vulkan1.1 "$T" ordinary.frag "$tes/ordinary-resources.frag.spv" -DRESOURCES
compile vulkan1.1 "$T" interp.frag "$tes/interp.frag.spv"
compile vulkan1.1 "$T" interp.frag "$tes/interp-resources.frag.spv" -DRESOURCES
compile vulkan1.1 "$T" flat-ordered.frag "$tes/flat-ordered.frag.spv"
compile vulkan1.1 "$T" flat-ordered.frag "$tes/flat-swapped.frag.spv" -DSWAP
compile vulkan1.1 "$T" consistency.frag "$tes/consistency.frag.spv"
compile vulkan1.1 "$T" coords.frag "$tes/coords.frag.spv"
compile vulkan1.1 "$T" primitive-id.frag "$tes/primitive-id.frag.spv"
compile vulkan1.1 "$T" primitive-id.frag "$tes/primitive-id-ordinary.frag.spv" -DORDINARY
M=$tests/PerVertexMesh
compile vulkan1.3 "$M" mesh.mesh "$mesh/mesh.mesh.spv"
compile vulkan1.3 "$M" interp.frag "$mesh/interp.frag.spv"
compile vulkan1.3 "$M" pervertex.frag "$mesh/pervertex.frag.spv"
compile vulkan1.3 "$M" forms.mesh "$mesh/forms.mesh.spv"
compile vulkan1.3 "$M" forms.frag "$mesh/form-mixed.frag.spv" -DMIXED

# 4. The probe and the fixtures, linked to the bundled library through @executable_path/../lib.
fixture() { # output source [extra flags...]
	xcrun clang++ -arch arm64 -std=c++17 -O2 -mmacosx-version-min=11.0 -Wall -Wextra -Werror -Wno-missing-field-initializers -DVK_ENABLE_BETA_EXTENSIONS \
		-I"$root/External/Vulkan-Headers/include" "$2" "$bundle/lib/libMoltenVK.1.dylib" -Wl,-rpath,@executable_path/../lib "${@:3}" -o "$bundle/bin/$1"
	codesign --force --sign - "$bundle/bin/$1"
	otool -L "$bundle/bin/$1" | grep -q '@rpath/libMoltenVK.1.dylib'
}
fixture probe "$harness/probe.mm" -fobjc-arc -framework Foundation -framework Metal
fixture pervertex-indirect-gpu "$tests/PerVertexIndirectGPUTests.cpp"
fixture topology "$T/topology.cpp" -Wl,-U,_mvkEnableTESFixtureDevice
fixture mesh-draw "$M/mesh-draw.cpp" -Wl,-U,_mvkEnableMeshTestDevice -Wl,-U,_mvkEnableTESFixtureDevice
# The Metal mesh limits probe uses neither Vulkan nor MoltenVK.
xcrun clang++ -arch arm64 -std=c++17 -fobjc-arc -O1 -mmacosx-version-min=13.0 -Wall -Wextra -Werror "$tests/PerVertexMeshLimits.mm" -framework Metal -framework Foundation -o "$bundle/bin/mesh-limits"
codesign --force --sign - "$bundle/bin/mesh-limits"

# 5. Runner, documentation and sources.
cp "$harness/run.sh" "$harness/timeout.pl" "$harness/README.md" "$bundle/"
chmod +x "$bundle/run.sh" "$bundle/timeout.pl"
cp "$harness/probe.mm" "$harness/run.sh" "$harness/timeout.pl" "$harness/package.sh" "$bundle/source/harness/"
cp "$tests/PerVertexIndirectGPUTests.cpp" "$T/topology.cpp" "$M/mesh-draw.cpp" "$T/EnableTestDevice.mm" "$tests/PerVertexMeshLimits.mm" "$bundle/source/fixtures/"
cp "$tests"/pervertex-indirect.vert "$tests"/pervertex-indirect.frag "$tests"/pervertex-indirect-args.comp "$bundle/source/shaders/indirect/"
cp "$T"/*.vert "$T"/*.tesc "$T"/*.tese "$T"/*.frag "$T"/*.comp "$bundle/source/shaders/tes/"
cp "$M"/*.mesh "$M"/*.frag "$bundle/source/shaders/mesh/"

# 6. Provenance and checksums.
{
	echo "bundle=$name"
	echo "library_base_commit=$base"
	echo "harness_commit=$head"
	echo "spirv_cross_commit=$(git -C "$cross" rev-parse HEAD)"
	echo "library=libMoltenVK.1.4.3.dylib Debug arm64, macOS deployment target 11.0, MVK_TEST_TES_PERVERTEX_ADMISSION=1, test device adapters linked (EnableTestDevice.mm)"
	echo "library_sha256=$(shasum -a 256 "$library" | cut -d' ' -f1)"
	echo "public_gates=VK_EXT_mesh_shader and VK_KHR_fragment_shader_barycentric closed without the adapters; the fixtures call the adapters"
	echo "build_host=$(sw_vers -productVersion) $(sw_vers -buildVersion), $(xcodebuild -version | tr '\n' ' ')"
	echo "glslang=$(glslangValidator --version | head -1)"
} > "$bundle/PROVENANCE.txt"
(cd "$bundle" && find bin lib shaders source -type f | LC_ALL=C sort | while IFS= read -r path; do shasum -a 256 "$path"; done > SHA256SUMS && shasum -a 256 README.md run.sh timeout.pl PROVENANCE.txt >> SHA256SUMS)

# 7. Archive.
tar -czf "$output/$name.tar.gz" -C "$output" "$name"
(cd "$output" && shasum -a 256 "$name.tar.gz" > "$name.tar.gz.sha256")
cat "$bundle/PROVENANCE.txt" "$output/$name.tar.gz.sha256"
