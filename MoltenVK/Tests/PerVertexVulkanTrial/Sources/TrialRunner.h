// Copyright (c) 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/** Runs the Vulkan trial cases in this process, one at a time, and writes Documents/PerVertexVulkanTrial/<UTC>/. */
@interface PVTrialRunner : NSObject
/** Runs every case, reports each finished case line through progress, and returns the path of report.json. */
+ (NSString*)runAllWithProgress:(void (^)(NSString* line))progress;
@end

NS_ASSUME_NONNULL_END
