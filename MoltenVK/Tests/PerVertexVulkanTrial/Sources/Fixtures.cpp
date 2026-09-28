// Copyright (c) 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
// The macOS Vulkan fixtures, compiled unchanged into the app: each in its own namespace, so that their file-local
// helpers and their main() do not collide. Every header they include comes first, so that their own includes inside
// the namespaces are empty.
// VK_KHR_portability_subset is a beta extension, as the macOS builds of the fixtures declare it.
#define VK_ENABLE_BETA_EXTENSIONS 1
#include <vulkan/vulkan.h>
#include <vulkan/vulkan_metal.h>
#include <dlfcn.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <tuple>
#include <vector>

namespace indirect_fixture {
#include "PerVertexIndirectGPUTests.cpp"
}
namespace mesh_fixture {
#include "mesh-draw.cpp"
}

extern "C" int pervertexIndirectMain(int argc, char** argv) { return indirect_fixture::main(argc, argv); }
extern "C" int pervertexMeshMain(int argc, char** argv) { return mesh_fixture::main(argc, argv); }
