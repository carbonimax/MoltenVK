// Copyright (c) 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
// The device loss oracles, compiled unchanged into the app (TRIAL_SUITE=abandon), in their own namespace like the
// fixtures of Fixtures.cpp. They use manual reference counting: project.yml compiles this file with -fno-objc-arc.
#import <Metal/Metal.h>
#include <objc/runtime.h>
#include <vulkan/vulkan.h>
#include <vulkan/vulkan_metal.h>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <pthread.h>
#include <string>
#include <thread>
#include <vector>

namespace loss_fixture {
#include "PerVertexLossTests.mm"
}

extern "C" int pervertexLossMain(int argc, char** argv) { return loss_fixture::main(argc, argv); }
