// Copyright (c) 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
// The iOS Vulkan trial: the macOS fixtures (Fixtures.cpp) run in this process against the embedded MoltenVK test
// library, one case at a time, their output captured per case. Nothing is inferred from the device's name: the report
// records the Metal families, and each case's result comes from what the fixture checked on this GPU.
// MoltenVK reads its configuration once per process, so a run has one queue submission mode; launch the app again
// with MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=0 to cover the other one.
#import "TrialRunner.h"
#import <CommonCrypto/CommonDigest.h>
#import <Metal/Metal.h>
#import <UIKit/UIKit.h>
#include <fcntl.h>
#include <regex>
#include <string>
#include <sys/utsname.h>
#include <unistd.h>
#include <vector>

extern "C" int pervertexIndirectMain(int argc, char** argv);
extern "C" int pervertexMeshMain(int argc, char** argv);
extern "C" int pervertexBarrierMain(int argc, char** argv);

namespace {

enum Fixture { kIndirect, kMesh, kBarrier };  // PerVertexKHR indirect, mesh-draw, Metal-only barrier reproducer

struct TrialCase {
	const char* name;
	Fixture fixture;
	std::vector<std::string> args;      // after the shader directory (none for kBarrier); @PREFIX@ is the case's output prefix
	std::vector<std::string> env;       // NAME=VALUE, set for this case only
	int expectedExit;
	const char* pattern;                // must appear in the case log
};

// Continuation cases read BaryCoordKHR as well (PERVERTEX_TEST_PORTABLE), so that every GPU takes the portable capture
// and replay, whose continuation and losses they check; native vertex_value draws legal commands instead.
const std::vector<std::string> kContinuation = {"PERVERTEX_TEST_SPLIT_PRODUCER=1", "PERVERTEX_TEST_LATE_SIGNAL=1",
	"PERVERTEX_TEST_DEPENDENT_SUBMISSION=1", "PERVERTEX_TEST_WAIT_IDLE=1", "PERVERTEX_TEST_PORTABLE=1"};
// Plain PerVertexKHR, native on Apple10 with MSL 4.0: Vulkan allows repeated vertex shader invocations there.
const std::vector<std::string> kMaybeNative = {"PERVERTEX_TEST_ALLOW_REPEATED_INVOCATIONS=1"};

std::vector<std::string> with(std::vector<std::string> base, std::initializer_list<const char*> extra) {
	base.insert(base.end(), extra.begin(), extra.end());
	return base;
}

std::vector<TrialCase> cases() {
	return {
		// The public library closes VK_KHR_fragment_shader_barycentric and VK_EXT_mesh_shader on every platform.
		{"public-gate-closed", kMesh, {"no-adapter"}, {}, 0, "^MESH_DRAW PASS"},
		// Plain PerVertexKHR through Vulkan: on Apple10 with MSL 4.0 these triangle pipelines use native vertex_value,
		// elsewhere the portable capture and replay. Single draws are checked against an independent CPU oracle.
		{"pervertex-single-draw", kIndirect, {"draw", "u32", "single", "compute", "@PREFIX@"}, kMaybeNative, 0, "^PERVERTEX_INDIRECT PASS"},
		{"pervertex-single-indexed", kIndirect, {"indexed", "u32", "single", "compute", "@PREFIX@"}, kMaybeNative, 0, "^PERVERTEX_INDIRECT PASS"},
		{"pervertex-decisive-draw-count", kIndirect, {"draw-count", "u32", "decisive", "compute", "@PREFIX@"}, kMaybeNative, 0, "^PERVERTEX_INDIRECT PASS"},
		{"pervertex-restart-strip", kIndirect, {"indexed-count", "u16", "restart", "compute", "@PREFIX@"}, kMaybeNative, 0, "^PERVERTEX_INDIRECT PASS"},
		// Negative control: permuted corners must no longer match (exit 2 with differing pixels).
		{"pervertex-swap-negative", kIndirect, {"draw", "u32", "single", "compute", "@PREFIX@"}, with(kMaybeNative, {"PERVERTEX_TEST_SWAP_FRAGMENT=1"}), 2, "pixel_mismatches=[1-9]"},
		// The same with BaryCoordKHR also read: the portable capture and replay on every GPU, exact invocations.
		{"portable-single-draw", kIndirect, {"draw", "u32", "single", "compute", "@PREFIX@"}, {"PERVERTEX_TEST_PORTABLE=1"}, 0, "^PERVERTEX_INDIRECT PASS"},
		{"portable-restart-strip", kIndirect, {"indexed-count", "u16", "restart", "compute", "@PREFIX@"}, {"PERVERTEX_TEST_PORTABLE=1"}, 0, "^PERVERTEX_INDIRECT PASS"},
		{"portable-swap-negative", kIndirect, {"draw", "u32", "single", "compute", "@PREFIX@"}, {"PERVERTEX_TEST_PORTABLE=1", "PERVERTEX_TEST_SWAP_FRAGMENT=1"}, 2, "pixel_mismatches=[1-9]"},
		// Continuation: arguments produced on another queue after a late host signal, a dependent submission C and
		// vkQueueWaitIdle. Legal draws render; lost draws lose the device and C never reports success.
		{"continuation-legal-same-queue", kIndirect, {"draw", "u32", "single", "compute", "@PREFIX@"}, with(kContinuation, {"PERVERTEX_TEST_DEPENDENT_SAME_QUEUE=1"}), 0, "^PERVERTEX_INDIRECT PASS"},
		{"continuation-restart-cross-queue", kIndirect, {"indexed-count", "u16", "restart-two", "compute", "@PREFIX@"}, with(kContinuation, {"PERVERTEX_TEST_DEPENDENT_FIRST=1"}), 0, "^PERVERTEX_INDIRECT PASS"},
		{"continuation-huge-loss", kIndirect, {"indexed-count", "u32", "huge", "compute", "@PREFIX@"}, with(kContinuation, {"PERVERTEX_TEST_DEPENDENT_FIRST=1"}), 0, "^PERVERTEX_INDIRECT PASS"},
		{"continuation-index-oob-loss", kIndirect, {"indexed", "u32", "index-oob", "compute", "@PREFIX@"}, with(kContinuation, {"PERVERTEX_TEST_DEPENDENT_SAME_QUEUE=1"}), 0, "^PERVERTEX_INDIRECT PASS"},
		// PerVertex TES (test-only admission) with an indirect draw in one command buffer; level 4 must lose the device.
		{"tes-after-indirect", kIndirect, {"draw", "u32", "single", "compute", "@PREFIX@"}, with(kContinuation, {"PERVERTEX_TEST_DEPENDENT_SAME_QUEUE=1", "PERVERTEX_TEST_INCLUDE_TES=1"}), 0, "^PERVERTEX_INDIRECT PASS"},
		{"tes-level4-loss", kIndirect, {"draw", "u32", "single", "compute", "@PREFIX@"}, with(kContinuation, {"PERVERTEX_TEST_DEPENDENT_SAME_QUEUE=1", "PERVERTEX_TEST_INCLUDE_TES=1", "PERVERTEX_TEST_TES_FIRST=1", "PERVERTEX_TEST_TES_LEVEL4=1"}), 0, "^PERVERTEX_INDIRECT PASS"},
		// Mesh through the test adapter (Metal 3 GPUs).
		{"mesh-draw", kMesh, {"draw"}, {}, 0, "^MESH_DRAW PASS"},
		{"mesh-pervertex", kMesh, {"pervertex"}, {}, 0, "^MESH_DRAW PASS"},
		{"mesh-form-mixed", kMesh, {"form-mixed"}, {}, 0, "^MESH_DRAW PASS"},
		{"mesh-grid-limit", kMesh, {"reject-grid-limit"}, {}, 0, "^MESH_DRAW PASS"},
	};
}

// TRIAL_SUITE=metal-barrier: the Metal-only reproducer of the in-pass capture/replay barrier (PerVertexBarrierRepro).
// A barrier variant fails when the replay did not see the capture's records, which the Metal contract promises.
std::vector<TrialCase> barrierCases() {
	std::vector<TrialCase> list;
	for (const char* variant : {"barrier", "barrier-indirect", "split", "none", "barrier-raster", "barrier-shared", "barrier-resources", "barrier-v2v"}) {
		list.push_back({variant, kBarrier, {variant}, {}, 0, "^BARRIER_REPRO PASS"});
	}
	list.push_back({"cost", kBarrier, {"cost"}, {}, 0, "^BARRIER_COST PASS"});
	return list;
}

NSString* json(id object) {
	NSData* data = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
	return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

NSString* sha256(NSString* path) {
	NSData* data = [NSData dataWithContentsOfFile:path];
	if (!data) { return @"unreadable"; }
	unsigned char digest[CC_SHA256_DIGEST_LENGTH];
	CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
	NSMutableString* hex = [NSMutableString string];
	for (unsigned char byte : digest) { [hex appendFormat:@"%02x", byte]; }
	return hex;
}

// Appended and synced before and after each case: a case that kills the app leaves a START without an END.
void journal(NSString* path, NSString* line) {
	int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);
	if (fd < 0) { return; }
	NSData* data = [[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
	write(fd, data.bytes, data.length);
	fsync(fd);
	close(fd);
}

NSDictionary* deviceInfo() {
	struct utsname system;
	uname(&system);
	id<MTLDevice> device = MTLCreateSystemDefaultDevice();
	NSMutableDictionary* families = [NSMutableDictionary dictionary];
	for (int family = 1; family <= 11; ++family) { families[[NSString stringWithFormat:@"apple%d", family]] = @([device supportsFamily:(MTLGPUFamily)(1000 + family)]); }
	families[@"metal3"] = @([device supportsFamily:MTLGPUFamilyMetal3]);
	families[@"metal4"] = @([device supportsFamily:(MTLGPUFamily)5002]);
	NSMutableDictionary* environment = [NSMutableDictionary dictionary];
	[NSProcessInfo.processInfo.environment enumerateKeysAndObjectsUsingBlock:^(NSString* key, NSString* value, BOOL*) {
		if ([key hasPrefix:@"MTL_"] || [key hasPrefix:@"METAL_"] || [key hasPrefix:@"MVK_"] || [key hasPrefix:@"DYLD_"]) { environment[key] = value; }
	}];
	bool apple10 = [device supportsFamily:(MTLGPUFamily)1010];
	NSString* library = [NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:@"libMoltenVK.1.dylib"];
	return @{
		@"model_identifier": @(system.machine),
		@"system": [NSString stringWithFormat:@"%@ %@", UIDevice.currentDevice.systemName, UIDevice.currentDevice.systemVersion],
		@"os_build": NSProcessInfo.processInfo.operatingSystemVersionString,
		@"metal_device": device.name ?: @"none",
		@"gpu_families": families,
		@"barycentric_coordinates": @(device.supportsShaderBarycentricCoordinates),
		// Derived from the runtime rule in MVKPipeline.mm, not observed: native vertex_value needs Apple10, MSL 4.0 and
		// a triangle topology class; MSL 4.0 needs iOS 26.
		@"expected_pervertex_path": (apple10 && [NSProcessInfo.processInfo isOperatingSystemAtLeastVersion:{26, 0, 0}]) ? @"native vertex_value" : @"portable capture and replay",
		@"launch_environment": environment,
		@"moltenvk_library_sha256": sha256(library),
	};
}

}  // namespace

@implementation PVTrialRunner

+ (NSString*)runAllWithProgress:(void (^)(NSString*))progress {
	NSFileManager* files = NSFileManager.defaultManager;
	NSString* documents = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"PerVertexVulkanTrial"];
	NSDateFormatter* stamp = [NSDateFormatter new];
	stamp.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
	stamp.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
	stamp.dateFormat = @"yyyyMMdd'T'HHmmss'Z'";
	NSString* started = [stamp stringFromDate:NSDate.date];
	NSString* run = [documents stringByAppendingPathComponent:started];
	[files createDirectoryAtPath:run withIntermediateDirectories:YES attributes:nil error:nil];

	// A previous run that stopped inside a case left START without END in its journal.
	NSMutableArray* interrupted = [NSMutableArray array];
	for (NSString* previous in [files contentsOfDirectoryAtPath:documents error:nil]) {
		NSString* text = [NSString stringWithContentsOfFile:[[documents stringByAppendingPathComponent:previous] stringByAppendingPathComponent:@"journal.txt"] encoding:NSUTF8StringEncoding error:nil];
		NSString* open = nil;
		for (NSString* line in [text componentsSeparatedByString:@"\n"]) {
			if ([line hasPrefix:@"START "]) { open = [line substringFromIndex:6]; }
			if ([line hasPrefix:@"END "]) { open = nil; }
		}
		if (open) { [interrupted addObject:@{@"run": previous, @"case": open}]; }
	}

	NSString* journalPath = [run stringByAppendingPathComponent:@"journal.txt"];
	NSString* shaders = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"Shaders"];
	NSMutableArray* results = [NSMutableArray array];
	int pass = 0, fail = 0, skipped = 0;
	const char* suite = getenv("TRIAL_SUITE");
	bool barrier = suite && !strcmp(suite, "metal-barrier");
	for (const TrialCase& trial : barrier ? barrierCases() : cases()) {
		NSString* name = @(trial.name);
		NSString* log = [run stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"log"]];
		std::vector<std::string> args = {trial.fixture == kMesh ? "mesh-draw" : trial.fixture == kBarrier ? "pervertex-barrier-repro" : "pervertex-indirect-gpu"};
		if (trial.fixture != kBarrier) { args.push_back(std::string(shaders.UTF8String) + (trial.fixture == kMesh ? "/mesh" : "/indirect")); }
		for (const auto& arg : trial.args) { args.push_back(arg == "@PREFIX@" ? std::string([run stringByAppendingPathComponent:name].UTF8String) : arg); }
		std::vector<char*> argv;
		for (auto& arg : args) { argv.push_back(arg.data()); }
		argv.push_back(nullptr);
		for (const auto& assignment : trial.env) { putenv(strdup(assignment.c_str())); }

		journal(journalPath, [@"START " stringByAppendingString:name]);
		fflush(stdout);
		fflush(stderr);
		int saved[2] = {dup(STDOUT_FILENO), dup(STDERR_FILENO)};
		int output = open(log.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0644);
		dup2(output, STDOUT_FILENO);
		dup2(output, STDERR_FILENO);
		NSDate* begin = NSDate.date;
		int (*entry)(int, char**) = trial.fixture == kMesh ? pervertexMeshMain : trial.fixture == kBarrier ? pervertexBarrierMain : pervertexIndirectMain;
		int rc = entry(int(argv.size() - 1), argv.data());
		double seconds = -begin.timeIntervalSinceNow;
		fflush(stdout);
		fflush(stderr);
		dup2(saved[0], STDOUT_FILENO);
		dup2(saved[1], STDERR_FILENO);
		close(saved[0]);
		close(saved[1]);
		close(output);
		journal(journalPath, [@"END " stringByAppendingString:name]);
		for (const auto& assignment : trial.env) { unsetenv(assignment.substr(0, assignment.find('=')).c_str()); }

		std::string text = [NSString stringWithContentsOfFile:log encoding:NSUTF8StringEncoding error:nil].UTF8String ?: "";
		auto has = [&](const char* expression) { return std::regex_search(text, std::regex(expression, std::regex::multiline)); };
		NSString* verdict = @"FAIL";
		// A capability this GPU lacks (the adapter opens barycentrics only with Metal barycentric coordinates, and mesh
		// only on Metal 3) skips the case; the reason stays in its lines.
		if (has("Required features are unavailable|^MESH_DRAW SKIP|No device with barycentric|is not exposed through the test adapter")) { verdict = @"SKIPPED"; ++skipped; }
		else if (has("Shader Validation|GPU Address Sanitizer|validation error|Execution of the command buffer was aborted")) { verdict = @"FAIL"; ++fail; }
		else if (rc == trial.expectedExit && has(trial.pattern)) { verdict = @"PASS"; ++pass; }
		else { ++fail; }
		// The lines that carry the fixture's own checks.
		NSMutableArray* lines = [NSMutableArray array];
		for (NSString* line in [@(text.c_str()) componentsSeparatedByString:@"\n"]) {
			if ([line hasPrefix:@"PERVERTEX_INDIRECT"] || [line hasPrefix:@"MESH_DRAW"] || [line hasPrefix:@"BARRIER_"] || [line hasPrefix:@"submission="] || [line hasPrefix:@"dependent wait"] ||
				[line hasPrefix:@"queue idle"] || [line hasPrefix:@"  sample"] || [line hasPrefix:@"[mvk-error]"] || [line hasPrefix:@"DEVICE="] || [line hasPrefix:@"VK_EXT"] ||
				[line hasPrefix:@"ERROR"]) { [lines addObject:line]; }
		}
		[results addObject:@{@"case": name, @"verdict": verdict, @"exit": @(rc), @"expected_exit": @(trial.expectedExit), @"seconds": @(seconds),
							 @"validation_announced": @(has("Metal API Validation Enabled")), @"log": log.lastPathComponent, @"lines": lines}];
		progress([NSString stringWithFormat:@"%@ %@ (exit %d)", verdict, name, rc]);
	}

	// Metal announces its validation once per process, in the first case that creates a device.
	bool validation = false;
	for (NSDictionary* result in results) { validation |= [result[@"validation_announced"] boolValue]; }
	NSDictionary* report = @{
		@"format": @"PerVertexVulkanTrial 2",
		@"suite": barrier ? @"metal-barrier" : @"vulkan",
		@"metal_validation_announced": @(validation),
		@"started_utc": started,
		@"device": deviceInfo(),
		@"interrupted_previous_runs": interrupted,
		@"cases": results,
		@"summary": @{@"pass": @(pass), @"fail": @(fail), @"skipped": @(skipped)},
		@"verdict": fail ? @"FAIL" : skipped ? @"INCOMPLETE" : @"PASS",
	};
	NSString* reportPath = [run stringByAppendingPathComponent:@"report.json"];
	[json(report) writeToFile:reportPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
	progress([NSString stringWithFormat:@"%@: pass=%d fail=%d skipped=%d", report[@"verdict"], pass, fail, skipped]);
	return reportPath;
}

@end
