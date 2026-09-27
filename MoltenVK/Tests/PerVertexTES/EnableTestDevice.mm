// Copyright (c) 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
// Linked only by the TES test driver, never by shipping CMake/Xcode targets.
#include "MVKDevice.h"
struct TestPhysicalDevice : MVKPhysicalDevice {
    static void enable(MVKPhysicalDevice* device) {
        // Use the same initialization convention as MVKPhysicalDevice::initExtensions.
        auto& extensions = const_cast<MVKExtensionList&>(device->* &TestPhysicalDevice::_supportedExtensions);
        // The merged test library may already expose this feature for indirect fixtures.
        extensions.vk_KHR_fragment_shader_barycentric.enabled = true;
    }
};
extern "C" void mvkEnableTESFixtureDevice(VkPhysicalDevice device) {
    TestPhysicalDevice::enable(MVKPhysicalDevice::getMVKPhysicalDevice(device));
}
