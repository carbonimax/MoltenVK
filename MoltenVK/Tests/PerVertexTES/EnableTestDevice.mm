// Copyright (c) 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
// Linked only by the TES and mesh test drivers, never by shipping CMake/Xcode targets.
#include "MVKDevice.h"
struct TestPhysicalDevice : MVKPhysicalDevice {
    static void enable(MVKPhysicalDevice* device) {
        // Use the same initialization convention as MVKPhysicalDevice::initExtensions.
        auto& extensions = const_cast<MVKExtensionList&>(device->* &TestPhysicalDevice::_supportedExtensions);
        // The public library closes this extension; the adapter opens it only where Metal has barycentric coordinates.
        extensions.vk_KHR_fragment_shader_barycentric.enabled = device->getMetalFeatures()->shaderBarycentricCoordinates;
    }
    // Reproduces a GPU whose Metal buffers are smaller, before the device is created.
    static void limitMetalBufferSize(MVKPhysicalDevice* device, uint64_t size) {
        auto& features = const_cast<MVKPhysicalDeviceMetalFeatures&>(device->* &TestPhysicalDevice::_metalFeatures);
        features.maxMTLBufferSize = std::min<uint64_t>(features.maxMTLBufferSize, size);
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
extern "C" void mvkTestLimitMetalBufferSize(VkPhysicalDevice device, uint64_t size) {
    TestPhysicalDevice::limitMetalBufferSize(MVKPhysicalDevice::getMVKPhysicalDevice(device), size);
}
// Loses the device as an encoder does, so that device loss tests choose the moment of the loss.
extern "C" void mvkTestMarkDeviceLost(VkDevice device) {
    MVKDevice::getMVKDevice(device)->markLost();
}
