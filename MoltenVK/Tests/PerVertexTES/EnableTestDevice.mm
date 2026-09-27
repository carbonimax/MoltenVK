// Copyright (c) 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
// Linked only by the TES and mesh test drivers, never by shipping CMake/Xcode targets.
#include "MVKDevice.h"
struct TestPhysicalDevice : MVKPhysicalDevice {
    static void enable(MVKPhysicalDevice* device) {
        // Use the same initialization convention as MVKPhysicalDevice::initExtensions.
        auto& extensions = const_cast<MVKExtensionList&>(device->* &TestPhysicalDevice::_supportedExtensions);
        // The merged test library may already expose this feature for indirect fixtures.
        extensions.vk_KHR_fragment_shader_barycentric.enabled = true;
    }
    // Mesh shaders need a Metal 3 GPU.
    static void enableMesh(MVKPhysicalDevice* device) {
        auto& extensions = const_cast<MVKExtensionList&>(device->* &TestPhysicalDevice::_supportedExtensions);
        extensions.vk_EXT_mesh_shader.enabled = [device->getMTLDevice() supportsFamily:MTLGPUFamilyMetal3];
    }
};
extern "C" void mvkEnableTESFixtureDevice(VkPhysicalDevice device) {
    TestPhysicalDevice::enable(MVKPhysicalDevice::getMVKPhysicalDevice(device));
}
extern "C" void mvkEnableMeshTestDevice(VkPhysicalDevice device) {
    TestPhysicalDevice::enableMesh(MVKPhysicalDevice::getMVKPhysicalDevice(device));
}
