// Copyright (c) 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
#include "MVKPerVertexReplay.h"
#include <array>
#include <cassert>
#include <cstdio>
#include <vector>
using uint = uint32_t;
#include "PerVertexRestartKernel.inc"

static void check(const std::vector<int64_t>& input, uint bytes, VkPrimitiveTopology topology, bool last, uint instances, bool withCorners) {
    constexpr uint guard = 0xabcdef01;
    uint vertices = mvkPerVertexReplayVertexCount(topology);
    uint maxPrimitives = mvkPerVertexPrimitiveCount(uint(input.size()), topology);
    std::vector<uint8_t> source(bytes * (input.size() + 2), 0xcc);
    std::vector<uint> expectedCompact, expectedTriplets;
    std::vector<uint> segment;
    auto flush = [&] {
        uint primitiveCount = mvkPerVertexPrimitiveCount(uint(segment.size()), topology);
        std::vector<uint> pairs(2 * vertices * primitiveCount), triplets(3 * primitiveCount);
        mvkPopulatePerVertexReplay(uint(segment.size()), 1, topology, last, pairs.data(), triplets.data(), nullptr);
        uint base = uint(expectedCompact.size());
        for (uint record : triplets) { expectedTriplets.push_back(base + record); }
        expectedCompact.insert(expectedCompact.end(), segment.begin(), segment.end());
        segment.clear();
    };
    for (uint i = 0; i < input.size(); ++i) {
        uint index = input[i] < 0 ? ~0u : uint(input[i]);
        for (uint b = 0; b < bytes; ++b) { source[(i + 1) * bytes + b] = uint8_t(index >> (8 * b)); }
        if (input[i] < 0) { flush(); } else { segment.push_back(index); }
    }
    flush();
    uint primitives = uint(expectedTriplets.size()) / 3;
    std::vector<uint> compact(input.size() + 2, guard), pairs(2 * vertices * maxPrimitives * instances + 2, guard), triplets(3 * maxPrimitives * instances + 2, guard), corners(vertices * maxPrimitives * instances + 2, guard);
    std::array<uint, 70> args; args.fill(guard);
    uint p[] = {uint(input.size()), instances, bytes, uint(topology), uint(last), 17, uint(withCorners)};
    perVertexRestart(source.data() + bytes, compact.data() + 1, pairs.data() + 1, triplets.data() + 1, corners.data() + 1, args.data() + 1, p);
    assert(compact.front() == guard && compact.back() == guard && pairs.front() == guard && pairs.back() == guard && triplets.front() == guard && triplets.back() == guard && corners.front() == guard && corners.back() == guard && args.front() == guard && args.back() == guard);
    for (uint i = 0; i < expectedCompact.size(); ++i) { assert(compact[1 + i] == expectedCompact[i]); }
    assert(args[1] == expectedCompact.size() && args[2] == (expectedCompact.empty() ? 0 : instances) && args[3] == 1);
    assert(args[5] == primitives * vertices && args[6] == (primitives ? instances : 0) && args[7] == 0 && args[8] == 17);
    assert(args[65] == 0 && args[66] == 0 && args[67] == 17 && args[68] == primitives * vertices);
    for (uint instance = 0; instance < instances; ++instance) {
        for (uint primitive = 0; primitive < primitives; ++primitive) {
            uint key = instance * primitives + primitive;
            for (uint corner = 0; corner < 3; ++corner) {
                uint record = instance * uint(expectedCompact.size()) + expectedTriplets[3 * primitive + corner];
                assert(triplets[1 + 3 * key + corner] == record);
                if (corner >= vertices) { continue; }
                uint occurrence = key * vertices + corner;
                assert(pairs[1 + 2 * occurrence] == record && pairs[2 + 2 * occurrence] == key);
                assert(corners[1 + occurrence] == (withCorners ? corner : guard));
                // Dense records preserve repeated indices, signed base vertex, and base instance.
                assert(compact[1 + record % expectedCompact.size()] + uint(-3) == expectedCompact[record % expectedCompact.size()] + uint(-3));
                assert(record / expectedCompact.size() + 17 == instance + 17);
            }
        }
    }
    for (uint i = uint(expectedCompact.size()); i < input.size(); ++i) { assert(compact[1 + i] == guard); }
    for (uint i = primitives * instances * 3; i < maxPrimitives * instances * 3; ++i) { assert(triplets[1 + i] == guard); }
}

static void checkReexecution() {
    uint8_t source[] = {7, 8, 9};
    uint compact[3] = {}, pairs[6] = {}, triplets[3] = {}, corners[3] = {}, args[68] = {};
    uint p[] = {3, 1, 1, VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, 0, 19, 1};
    perVertexRestart(source, compact, pairs, triplets, corners, args, p);
    assert(args[0] == 3 && args[4] == 3 && args[5] == 1);
    // A later GPU execution can see different index data; all consumer counts must be overwritten.
    for (auto& index : source) { index = 255; }
    perVertexRestart(source, compact, pairs, triplets, corners, args, p);
    assert(args[0] == 0 && args[1] == 0 && args[4] == 0 && args[5] == 0 && args[67] == 0);
    source[1] = 42;
    perVertexRestart(source, compact, pairs, triplets, corners, args, p);
    assert(args[0] == 1 && args[1] == 1 && compact[0] == 42 && args[4] == 0 && args[5] == 0);
}

int main() {
    checkReexecution();
    assert(mvkCanAssemblePerVertexRestart(65536, 1, true));
    assert(mvkCanAssemblePerVertexRestart(16384, 4, true));
    assert(!mvkCanAssemblePerVertexRestart(65537, 1, true));
    assert(!mvkCanAssemblePerVertexRestart(16385, 4, true));
    assert(!mvkCanAssemblePerVertexRestart(UINT32_MAX, UINT32_MAX, true));
    assert(!mvkCanAssemblePerVertexRestart(3, 1, false));
    unsigned cases = 0;
    for (uint topology = 0; topology <= 5; ++topology) {
        for (uint bytes : {1u, 2u, 4u}) {
            for (bool last : {false, true}) {
                for (uint instances : {1u, 3u}) {
                    for (uint mask = 0; mask < 1024; ++mask) {
                        std::vector<int64_t> input;
                        for (uint i = 0; i < 10; ++i) { input.push_back(mask & (1u << i) ? -1 : int(i % 4 + 7)); }
                        check(input, bytes, VkPrimitiveTopology(topology), last, instances, mask & 1);
                        ++cases;
                    }
                    for (const auto& input : std::vector<std::vector<int64_t>>{{}, {7}, {-1}, {7, 8}, {-1, 7, 8, 9, 10, 11, -1, -1, 12, 13, 14, 15, 16, 17, -1}}) { check(input, bytes, VkPrimitiveTopology(topology), last, instances, true); ++cases; }
                    // Width-specific sentinels: 255/65535 remain ordinary larger-width indices.
                    check({int64_t(bytes == 1 ? 254 : bytes == 2 ? 65534 : UINT32_MAX - 1), 255 - (bytes == 1), 7, -1, 8, 9, 10}, bytes, VkPrimitiveTopology(topology), last, instances, true);
                }
            }
        }
    }
    check(std::vector<int64_t>(65536, 9), 4, VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP, true, 1, true);
    check(std::vector<int64_t>(16384, 9), 1, VK_PRIMITIVE_TOPOLOGY_LINE_STRIP, false, 4, true);
    std::printf("PASS: %u restart patterns, all portable topologies/widths/provoking modes, instances, guards and 64K boundary (production kernel, CPU only)\n", cases);
}
