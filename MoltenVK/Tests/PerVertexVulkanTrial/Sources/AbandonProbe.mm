// Copyright (c) 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
// The Metal-only abandon probe of the Mac family harness, compiled unchanged into the app (TRIAL_SUITE=abandon).
#define ABANDON_PROBE_NO_MAIN 1
#include "MacFamilyHarness/abandon-probe.mm"

extern "C" int pervertexAbandonMain(int, char**) {
	@autoreleasepool { return runAbandonProbe(); }
}
