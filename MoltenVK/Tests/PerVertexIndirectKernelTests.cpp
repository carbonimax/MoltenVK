// Copyright (c) 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
// Runs the production perVertexIndirect and perVertexRestart MSL kernels as host C++ (attributes and
// address spaces removed by the runner) and compares them with the CPU replay tables and the direct
// restart dispatch sequence: every topology, both provoking modes, admission bounds, plans and gathers.
#include "MVKPerVertexReplay.h"
#include <algorithm>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <initializer_list>
#include <tuple>
#include <vector>
using uint = uint32_t;
using ulong = unsigned long;
using atomic_uint = std::atomic<uint32_t>;
using std::max;
using std::min;
using std::memory_order_relaxed;
using std::atomic_fetch_or_explicit;
static_assert(sizeof(atomic_uint) == sizeof(uint) && sizeof(ulong) == 8, "host kernel model");
#include "PerVertexIndirectKernel.inc"

static unsigned checks = 0;
static void check(bool condition, const char* message) {
	++checks;
	if (!condition) { std::fprintf(stderr, "FAIL: %s\n", message); std::exit(1); }
}

enum : uint { kDrawCount, kStride, kIndexBytes, kIndexLo, kIndexHi, kCapacity, kViews, kTopology, kProvoking, kCorners, kHasCount, kDraw, kTableWidth, kGatherWidth, kCaptureWidth, kPhase, kRestart, kSteps };
constexpr uint kGuard = 0xDEADBEEF;

struct Kernel {
	std::vector<uint8_t> args = std::vector<uint8_t>(4096);
	std::vector<uint> count = {0}, plan = std::vector<uint>(256 + 64 * 40), gathered, pairs, triplets, corners;
	std::vector<uint8_t> source;
	uint p[18] = {};
	void run(uint phase, uint64_t threads) {
		p[kPhase] = phase;
		for (uint64_t i = 0; i < threads; ++i) {
			perVertexIndirect(args.data(), count.data(), plan.data(), source.data(), gathered.data(), pairs.data(), triplets.data(), corners.data(), p, uint(i));
		}
	}
	void setDraw(uint draw, std::initializer_list<uint> words) { std::copy(words.begin(), words.end(), reinterpret_cast<uint*>(args.data() + draw * p[kStride])); }
};

static Kernel kernel(uint topology, bool provokingLast, bool corners, uint views, uint indexBytes) {
	Kernel k;
	uint p[18] = {1, 32, indexBytes, 1000, 0, 1u << 20, views, topology, provokingLast, corners, 0, 0, 7, 5, 3, 0, 0, 0};
	std::copy(p, p + 18, k.p);
	k.source.resize(4096);
	k.gathered.assign(1024, kGuard);
	return k;
}

// Plan and replay tables for every portable topology against mvkPopulatePerVertexReplay.
static void checkTables() {
	for (uint topology = 0; topology <= 5; ++topology) {
		for (bool provokingLast : {false, true}) {
			for (bool withCorners : {false, true}) {
				for (uint views : {1u, 2u}) {
					for (uint indexBytes : {0u, 4u}) {
						for (uint vertices = 0; vertices <= 25; ++vertices) {
							for (uint instances = 1; instances <= 3; ++instances) {
								Kernel k = kernel(topology, provokingLast, withCorners, views, indexBytes);
								uint physical = instances * views, firstInstance = 5;
								if (indexBytes) { k.setDraw(0, {vertices, instances, 7, uint(-3), firstInstance}); }
								else { k.setDraw(0, {vertices, instances, 9, firstInstance}); }
								auto topo = VkPrimitiveTopology(topology);
								uint primitives = mvkPerVertexPrimitiveCount(vertices, topo), raster = mvkPerVertexReplayVertexCount(topo);
								uint keys = primitives * physical, occurrences = keys * raster;
								k.pairs.assign(2 * occurrences + 8, kGuard);
								k.triplets.assign(3 * keys + 8, kGuard);
								k.corners.assign(occurrences + 8, kGuard);
								k.run(0, 1);
								k.run(1, 3);
								const uint* w = k.plan.data();
								check(!w[0], "admitted draw");
								uint first = indexBytes ? uint(-3) : 9;
								bool nonempty = vertices != 0;
								check(w[4] == vertices && w[5] == (nonempty ? physical : 0) && w[6] == first && w[7] == firstInstance, "capture draw arguments");
								check(w[8] == (vertices + 2) / 3 && w[9] == w[5] && w[10] == 1, "capture dispatch");
								check(w[12] == first && w[13] == firstInstance && w[14] == 0 && w[15] == vertices && w[16] == w[5] && w[17] == 1, "stage-in region");
								check(w[20] == primitives * raster && w[21] == (primitives ? w[5] : 0) && w[22] == 0 && w[23] == firstInstance, "replay draw arguments");
								check(w[64] == 0 && w[65] == 0 && w[66] == firstInstance && w[67] == primitives * raster && w[128] == vertices, "replay and capture constants");
								check(w[24] == (uint64_t(primitives) * w[5] + 6) / 7 && w[28] == (indexBytes ? (vertices + 4) / 5 : 0) && w[35] == (indexBytes ? 7 : 0), "table and gather dispatch");
								if (!nonempty) { continue; }
								// Every dispatched thread, including the partial final threadgroup.
								k.run(2, uint64_t(w[24]) * 7);
								std::vector<uint> pairs(2 * occurrences + 8, kGuard), triplets(3 * keys + 8, kGuard), cornerValues(occurrences + 8, kGuard);
								mvkPopulatePerVertexReplay(vertices, physical, topo, provokingLast, pairs.data(), triplets.data(), withCorners ? cornerValues.data() : nullptr);
								check(k.pairs == pairs && k.triplets == triplets, "GPU tables match mvkPopulatePerVertexReplay, no write past the tables");
								if (withCorners) { check(k.corners == cornerValues, "GPU corners match"); }
								else { check(std::all_of(k.corners.begin(), k.corners.end(), [](uint v) { return v == kGuard; }), "corners untouched when unused"); }
							}
						}
					}
				}
			}
		}
	}
}

// Every draw of the command is admitted before any executes; 64-bit products cannot wrap.
static void checkAdmission() {
	struct Case { uint vertices, instances, first, views, capacity; bool counted; uint count; uint expected; const char* name; };
	const Case cases[] = {
		{6, 2, 0, 1, 12, false, 0, 0, "exact capacity"},
		{6, 2, 0, 1, 11, false, 0, 1, "one record over capacity"},
		{6, 2, 0, 2, 24, false, 0, 0, "views multiply records"},
		{6, 2, 0, 2, 23, false, 0, 1, "views over capacity"},
		{UINT32_MAX, UINT32_MAX, 0, 32, UINT32_MAX, false, 0, 1, "largest product without wrapping"},
		{3, UINT32_MAX, 0, 1, 1u << 20, false, 0, 1, "UINT32_MAX instances"},
		{0, UINT32_MAX, 0, 1, 1, false, 0, 0, "zero vertices is empty"},
		{UINT32_MAX, 0, 0, 1, 1, false, 0, 0, "zero instances is empty"},
		{6, 2, 0, 1, 11, true, 0, 0, "GPU count zero executes nothing"},
	};
	for (const auto& c : cases) {
		for (uint indexBytes : {0u, 2u}) {
			Kernel k = kernel(3, false, false, c.views, indexBytes);
			k.p[kCapacity] = c.capacity;
			k.p[kDrawCount] = 2;
			k.p[kHasCount] = c.counted;
			k.count[0] = c.count;
			k.p[kIndexLo] = UINT32_MAX;
			k.p[kIndexHi] = 1;
			// The first draw needs one record per view, so each case is decided by the second draw.
			k.setDraw(0, {1, 1, 0, 0, 0});
			if (indexBytes) { k.setDraw(1, {c.vertices, c.instances, c.first, 0, 0}); }
			else { k.setDraw(1, {c.vertices, c.instances, c.first, 0}); }
			k.run(0, 7);
			check(k.plan[0] == c.expected, c.name);
		}
	}
	// Count clamps to maxDrawCount; draws beyond Count are neither admitted nor planned.
	Kernel k = kernel(3, false, false, 1, 0);
	k.p[kDrawCount] = 2;
	k.p[kHasCount] = 1;
	k.p[kCapacity] = 12;
	k.count[0] = 1;
	k.setDraw(0, {6, 2, 0, 0});
	k.setDraw(1, {6, 3, 0, 0});
	k.run(0, 7);
	check(k.plan[0] == 0, "draw beyond Count is not admitted");
	k.p[kDraw] = 1;
	k.run(1, 1);
	check(k.plan[4] == 0 && k.plan[5] == 0 && k.plan[20] == 0 && k.plan[21] == 0 && k.plan[24] == 0, "draw beyond Count is planned empty");
	k.count[0] = 7;
	k.run(0, 7);
	check(k.plan[0] == 1, "Count above maxDrawCount clamps, second draw admitted and over capacity");
	k.p[kDraw] = 0;
	k.run(1, 1);
	check(k.plan[4] == 0 && k.plan[5] == 0 && k.plan[21] == 0 && k.plan[24] == 0 && k.plan[28] == 0, "rejected command plans every draw empty");
	// Index range against a binding with more than 2^32 indices.
	for (auto [first, count, capacityLo, capacityHi, expected] : {std::tuple<uint, uint, uint, uint, uint>{2, 6, 8, 0, 0}, {3, 6, 8, 0, 2}, {UINT32_MAX, UINT32_MAX, 0, 2, 0}, {UINT32_MAX, UINT32_MAX, UINT32_MAX - 2, 1, 2}}) {
		Kernel r = kernel(3, false, false, 1, 4);
		r.p[kCapacity] = UINT32_MAX;
		r.p[kIndexLo] = capacityLo;
		r.p[kIndexHi] = capacityHi;
		r.setDraw(0, {count, 1, first, 0, 0});
		r.run(0, 1);
		check(r.plan[0] == expected, "index range admission");
	}
}

// The one-draw GPU plan must retain producer-written arguments even when admission later fails.
static void checkSingleDrawSnapshot() {
	Kernel k = kernel(3, false, false, 2, 0);
	k.p[kCapacity] = 5;
	k.setDraw(0, {6, 2, 4, 7});
	k.run(0, 1);
	check(k.plan[0] == 1 && k.plan[55] == 1, "rejected single draw still has a plan snapshot");
	check(k.plan[48] == 6 && k.plan[49] == 2 && k.plan[50] == 4 && k.plan[51] == 7, "nonindexed GPU arguments snapshotted");
	check((uint64_t(k.plan[54]) << 32 | k.plan[53]) == 24, "physical records include views beyond old capacity");
	k.setDraw(0, {9, 1, 0, 0});
	check(k.plan[48] == 6 && k.plan[49] == 2, "later argument writes cannot change the snapshot");
	Kernel resumed = kernel(3, false, false, 1, 0);
	resumed.p[kCapacity] = 12;
	resumed.setDraw(0, {6, 2, 4, 7});
	resumed.run(0, 1);
	resumed.setDraw(0, {9, 1, 0, 0});
	resumed.run(1, 1);
	check(resumed.plan[4] == 6 && resumed.plan[5] == 2 && resumed.plan[6] == 4 && resumed.plan[7] == 7, "phase 1 consumes the plan snapshot");
	Kernel counted = kernel(3, false, false, 1, 0);
	counted.p[kHasCount] = 1;
	counted.setDraw(0, {6, 2, 4, 7});
	counted.run(0, 1);
	check(counted.plan[55] == 0 && counted.plan[53] == 0, "Count zero has no snapshot or records");
	counted.count[0] = 1;
	counted.run(1, 1);
	check(counted.plan[4] == 0 && counted.plan[5] == 0, "Count becoming one cannot enable a skipped draw");
	Kernel admittedCount = kernel(3, false, false, 1, 0);
	admittedCount.p[kHasCount] = 1;
	admittedCount.count[0] = 1;
	admittedCount.setDraw(0, {6, 2, 4, 7});
	admittedCount.run(0, 1);
	admittedCount.count[0] = 0;
	admittedCount.setDraw(0, {9, 1, 0, 0});
	admittedCount.run(1, 1);
	check(admittedCount.plan[4] == 6 && admittedCount.plan[5] == 2 && admittedCount.plan[6] == 4, "Count becoming zero cannot suppress an admitted draw");
	Kernel indexed = kernel(3, false, false, 1, 2);
	indexed.setDraw(0, {6, 2, 3, uint(-4), 7});
	indexed.run(0, 1);
	check(indexed.plan[48] == 6 && indexed.plan[50] == 3 && indexed.plan[51] == uint(-4) && indexed.plan[52] == 7, "indexed arguments include vertex offset and first instance");
	indexed.setDraw(0, {9, 1, 0, 0, 0});
	indexed.run(1, 1);
	check(indexed.plan[6] == uint(-4) && indexed.plan[7] == 7 && indexed.plan[35] == 3, "indexed phase 1 retains the snapped vertex offset and first index");
	Kernel overflow = kernel(3, false, false, 32, 0);
	overflow.setDraw(0, {UINT32_MAX, UINT32_MAX, 0, 0});
	overflow.run(0, 1);
	check(overflow.plan[53] == UINT32_MAX && overflow.plan[54] == UINT32_MAX, "record requirement saturates instead of wrapping");
	Kernel wide = kernel(3, false, false, 1, 0);
	wide.setDraw(0, {UINT32_MAX, 2, 0, 0});
	wide.run(0, 1);
	check(wide.plan[53] == UINT32_MAX - 1 && wide.plan[54] == 1, "record requirement keeps the nonoverflowing high word");
	Kernel carry = kernel(3, false, false, 2, 0);
	carry.setDraw(0, {UINT32_MAX, 2, 0, 0});
	carry.run(0, 1);
	check(carry.plan[53] == UINT32_MAX - 3 && carry.plan[54] == 3, "low-limb carry reaches the high word");
	Kernel empty = kernel(3, false, false, 1, 0);
	empty.setDraw(0, {0, 2, 4, 7});
	empty.run(0, 1);
	check(empty.plan[55] == 1 && empty.plan[53] == 0 && empty.plan[48] == 0, "empty draw preserves arguments with zero records");
}

// Gathered indices start at firstIndex, keep little-endian values, and widen only the restart marker.
static void checkGather() {
	for (uint bytes : {1u, 2u, 4u}) {
		for (bool restart : {false, true}) {
			Kernel k = kernel(4, false, false, 1, bytes);
			k.p[kRestart] = restart;
			k.p[kSteps] = 1;
			uint marker = bytes == 1 ? 0xFFu : bytes == 2 ? 0xFFFFu : 0xFFFFFFFFu;
			std::vector<uint> values = {0, 1, marker - 1, marker, 3, marker, 0x80};
			for (size_t i = 0; i < values.size(); ++i) {
				for (uint b = 0; b < bytes; ++b) { k.source[(5 + i) * bytes + b] = uint8_t(values[i] >> (8 * b)); }
			}
			k.setDraw(0, {uint(values.size()), 1, 5, 0, 0});
			k.run(0, 1);
			k.run(1, 1);
			k.run(3, uint64_t(k.plan[28]) * 5);
			for (size_t i = 0; i < values.size(); ++i) {
				uint want = restart && values[i] == marker ? 0xFFFFFFFFu : values[i];
				check(k.gathered[i] == want, "gathered index value");
			}
			check(k.gathered[values.size()] == kGuard, "gather stops at indexCount");
		}
	}
}

// Fixed scan-step blocks reproduce the direct restart dispatch: same compact indices, tables and arguments.
static void checkRestartBlocks() {
	const uint marker = 0xFFFFFFFFu;
	std::vector<std::vector<uint>> patterns = {{}, {1}, {marker}, {1, 2, 3, 4}, {1, 2, marker, 3, 4, 5, marker, marker, 6, 7, 8, 9}, {marker, 1, 2, 3, marker}};
	for (uint n = 0; n < 40; ++n) {
		std::vector<uint> pattern;
		for (uint i = 0; i < n; ++i) { pattern.push_back((i * 7 + n) % 5 == 0 ? marker : i); }
		patterns.push_back(pattern);
	}
	for (uint topology = 0; topology <= 5; ++topology) {
		for (bool provokingLast : {false, true}) {
			for (uint capacityScale : {1u, 3u, 64u}) {
				for (const auto& pattern : patterns) {
					uint count = uint(pattern.size()), instances = 2, capacity = std::max(count * instances * capacityScale, 1u);
					uint steps = mvkPerVertexIndirectRestartScanSteps(capacity);
					check(steps >= mvkPerVertexIndirectRestartScanSteps(count), "fixed steps cover every admissible count");
					// Direct reference with CPU parameters and the production dispatch sequence.
					auto topo = VkPrimitiveTopology(topology);
					uint raster = mvkPerVertexReplayVertexCount(topo);
					uint keys = mvkPerVertexPrimitiveCount(count, topo) * instances;
					auto run = [&](bool indirect, std::vector<uint>& compact, std::vector<uint>& pairs, std::vector<uint>& triplets, std::vector<uint>& args) {
						compact.assign(std::max<uint64_t>(mvkPerVertexRestartIndexScratchSize(count), 1), 0);
						pairs.assign(2 * raster * keys + 8, kGuard);
						triplets.assign(3 * keys + 8, kGuard);
						args.assign(68, kGuard);
						std::vector<uint> corners(raster * keys + 8, kGuard);
						const uint8_t* source = reinterpret_cast<const uint8_t*>(pattern.data());
						if (!indirect) {
							uint p[10] = {count, instances, 4, topology, provokingLast, 9, 1, 0, 0, 0};
							mvkDispatchPerVertexRestart(count, instances, topo, [&](uint phase, uint step, uint scanSource, uint64_t threads) {
								p[7] = phase; p[8] = step; p[9] = scanSource;
								for (uint64_t i = 0; i < threads; ++i) { perVertexRestart(source, compact.data(), pairs.data(), triplets.data(), corners.data(), args.data(), p, uint(i)); }
							});
							return;
						}
						Kernel k = kernel(topology, provokingLast, true, 1, 4);
						k.p[kRestart] = 1;
						k.p[kSteps] = steps;
						k.p[kCapacity] = capacity;
						k.setDraw(0, {count, instances, 0, 0, 9});
						k.run(0, 1);
						k.run(1, 1);
						for (uint block = 0; block < steps + 3; ++block) {
							const uint* p = k.plan.data() + 256 + 64 * block;
							uint64_t threads = uint64_t(k.plan[block == steps + 2 ? 40 : 36]) * 7;
							for (uint64_t i = 0; i < threads; ++i) { perVertexRestart(source, compact.data(), pairs.data(), triplets.data(), corners.data(), args.data(), p, uint(i)); }
						}
					};
					std::vector<uint> directCompact, directPairs, directTriplets, directArgs, compact, pairs, triplets, args;
					run(false, directCompact, directPairs, directTriplets, directArgs);
					run(true, compact, pairs, triplets, args);
					uint captured = directArgs[0];
					check(std::equal(compact.begin(), compact.begin() + captured, directCompact.begin()), "restart compact indices");
					check(pairs == directPairs && triplets == directTriplets, "restart replay tables");
					for (uint word : {0u, 1u, 2u, 4u, 5u, 6u, 7u, 64u, 65u, 66u, 67u}) { check(args[word] == directArgs[word], "restart indirect arguments"); }
				}
			}
		}
	}
}

int main() {
	checkTables();
	checkAdmission();
	checkSingleDrawSnapshot();
	checkGather();
	checkRestartBlocks();
	std::printf("PASS: %u checks; production perVertexIndirect tables for all six topologies, both provoking modes, corners, views and indexed/non-indexed plans; admission bounds, Count clamp, one-draw snapshots and 64-bit products; gathers for three index widths; fixed-step restart blocks equal to direct restart dispatch\n", checks);
}
