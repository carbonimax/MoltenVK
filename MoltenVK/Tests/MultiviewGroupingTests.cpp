// Copyright (c) 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
#include <cassert>
#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <strings.h>
#include <vector>

// Compile the actual device/grouping methods without creating a Metal device.
struct PhysicalDevice {
    bool layered;
    bool canUseInstancingForMultiview() const { return layered; }
};
struct MVKDevice {
    PhysicalDevice* _physicalDevice;
    uint32_t getMultiviewMetalPassCount(uint32_t) const;
    uint32_t getFirstViewIndexInMetalPass(uint32_t, uint32_t) const;
    uint32_t getViewCountInMetalPass(uint32_t, uint32_t) const;
};
struct MVKRenderPass {
    PhysicalDevice* physical;
    PhysicalDevice* getPhysicalDevice() { return physical; }
};
struct MVKRenderSubpass {
    struct { uint32_t viewMask; } _pipelineRenderingCreateInfo;
    MVKRenderPass* _renderPass;
    MVKDevice* device;
    uint32_t getMultiviewMetalPassCount() const { return device->getMultiviewMetalPassCount(_pipelineRenderingCreateInfo.viewMask); }
    uint32_t getFirstViewIndexInMetalPass(uint32_t pass) const { return device->getFirstViewIndexInMetalPass(_pipelineRenderingCreateInfo.viewMask, pass); }
    uint32_t getViewMaskGroupForMetalPass(uint32_t pass);
};
uint32_t mvkGetNextViewMaskGroup(uint32_t, uint32_t*, uint32_t*, uint32_t* = nullptr);
#include "MultiviewGrouping.inc"

static uint64_t checkMask(uint32_t mask) {
    uint64_t checks = 0;
    for (bool layered : {false, true}) {
        PhysicalDevice physical{layered};
        MVKDevice device{&physical};
        MVKRenderPass renderPass{&physical};
        MVKRenderSubpass subpass{{mask}, &renderPass, &device};
        std::vector<std::pair<uint32_t, uint32_t>> expected;
        for (uint32_t view = 0; view < 32; ++view) {
            if (!(mask & (uint32_t(1) << view))) { continue; }
            if (layered && !expected.empty() && expected.back().first + expected.back().second == view) { expected.back().second++; }
            else { expected.emplace_back(view, 1); }
        }
        if (device.getMultiviewMetalPassCount(mask) != expected.size()) { throw std::runtime_error("Incorrect pass count"); }
        for (uint32_t pass = 0; pass < expected.size(); ++pass) {
            auto first = device.getFirstViewIndexInMetalPass(mask, pass);
            auto count = device.getViewCountInMetalPass(mask, pass);
            if (first != expected[pass].first || count != expected[pass].second) {
                std::cerr << "mask=" << mask << " layered=" << layered << " pass=" << pass << " actual={" << first << ',' << count << "} expected={" << expected[pass].first << ',' << expected[pass].second << "}\n";
                throw std::runtime_error("Incorrect multiview ViewRange/attachment slice");
            }
            uint32_t expectedMask = uint32_t(((uint64_t(1) << count) - 1) << first);
            assert(subpass.getViewMaskGroupForMetalPass(pass) == expectedMask);
            checks++;
        }
        if (!mask) { assert(device.getFirstViewIndexInMetalPass(0, 0) == 0 && device.getViewCountInMetalPass(0, 0) == 0); }
    }
    // Group masks also drive attachment clears/load/store actions.
    uint32_t remaining = mask, visited = 0;
    while (remaining) {
        uint32_t first, count, group;
        remaining = mvkGetNextViewMaskGroup(remaining, &first, &count, &group);
        assert(first < 32 && count && count <= 32 - first);
        uint32_t expected = uint32_t(((uint64_t(1) << count) - 1) << first);
        assert(group == expected && !(visited & group) && !(remaining & group));
        visited |= group;
    }
    assert(visited == mask);
    return checks;
}

int main(int argc, char** argv) {
    try {
        if (argc == 2) { checkMask(uint32_t(std::stoull(argv[1], nullptr, 0))); return 0; }
        uint64_t checks = 0;
        for (uint32_t mask = 0; mask < 65536; ++mask) { checks += checkMask(mask); }
        for (uint32_t mask : {0x80000000u, 0xc0000000u, 0xffffffffu, 0x80000001u, 0x80000005u, 0xaaaaaaaau, 0x55555555u}) { checks += checkMask(mask); }
        uint32_t random = 0x12345678u;
        for (uint32_t i = 0; i < 4096; ++i) {
            random ^= random << 13; random ^= random >> 17; random ^= random << 5;
            checks += checkMask(random);
        }
        std::cout << "PASS: " << checks << " production ViewRanges, layered and multipass, exhaustive 16-bit and sparse/high-bit 32-bit masks\n";
    } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
