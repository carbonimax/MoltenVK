// Copyright (c) 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
// Runs every variant of BarrierRepro.mm once at launch, off the main thread, and shows each result line on screen and
// on stdout. The last line summarizes: with a working barrier, every barrier variant sees 5 of 5 runs, like "split".
#import <Metal/Metal.h>
#import <UIKit/UIKit.h>
#include <fcntl.h>
#include <unistd.h>

extern "C" int pervertexBarrierMain(int argc, char** argv);

static NSString* runVariant(const char* variant) {
	NSString* path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"variant.txt"];
	fflush(stdout);
	int saved = dup(STDOUT_FILENO), output = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0644);
	dup2(output, STDOUT_FILENO);
	char* argv[] = {(char*)"BarrierRepro", (char*)variant, NULL};
	int rc = pervertexBarrierMain(2, argv);
	fflush(stdout);
	dup2(saved, STDOUT_FILENO);
	close(saved);
	close(output);
	NSString* text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] ?: @"";
	for (NSString* line in [text componentsSeparatedByString:@"\n"]) {
		if ([line hasPrefix:@"BARRIER_REPRO"] || [line hasPrefix:@"ERROR"]) { return line; }
	}
	return [NSString stringWithFormat:@"ERROR variant=%s exit=%d without a result line", variant, rc];
}

@interface ReproViewController : UIViewController
@end

@implementation ReproViewController {
	UITextView* _text;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	_text = [[UITextView alloc] initWithFrame:self.view.bounds];
	_text.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	_text.editable = NO;
	_text.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
	[self.view addSubview:_text];
	[self show:[NSString stringWithFormat:@"BarrierRepro on %@ %@ %@, MTL_SHADER_VALIDATION=%@", UIDevice.currentDevice.model,
		UIDevice.currentDevice.systemName, NSProcessInfo.processInfo.operatingSystemVersionString,
		NSProcessInfo.processInfo.environment[@"MTL_SHADER_VALIDATION"] ?: @"unset"]];
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		const char* variants[] = {"barrier", "barrier-indirect", "barrier-resources", "barrier-v2v", "barrier-raster", "barrier-shared", "split", "none"};
		int barrierPassed = 0;
		for (const char* variant : variants) {
			NSString* line = runVariant(variant);
			if (!strncmp(variant, "barrier", 7) && [line hasPrefix:@"BARRIER_REPRO PASS"]) { ++barrierPassed; }
			[self show:line];
		}
		[self show:[NSString stringWithFormat:@"SUMMARY barrier variants that ordered the capture before the replay: %d of 6 (expected 6)", barrierPassed]];
	});
}

- (void)show:(NSString*)line {
	printf("%s\n", line.UTF8String);
	fflush(stdout);
	dispatch_async(dispatch_get_main_queue(), ^{ self->_text.text = [self->_text.text stringByAppendingFormat:@"%@\n\n", line]; });
}

@end

// iOS 27 requires the scene life cycle (Info.plist UIApplicationSceneManifest names this delegate).
@interface SceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (strong, nonatomic) UIWindow* window;
@end

@implementation SceneDelegate

- (void)scene:(UIScene*)scene willConnectToSession:(UISceneSession*)session options:(UISceneConnectionOptions*)options {
	self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene*)scene];
	self.window.rootViewController = [ReproViewController new];
	[self.window makeKeyAndVisible];
}

@end

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation AppDelegate
@end

int main(int argc, char* argv[]) {
	@autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(AppDelegate.class)); }
}
