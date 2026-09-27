// Copyright (c) 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
// Reuse the existing Metal allocation fault-injection doubles.
#define main existingScratchMain
#include "../PerVertexScratchTests.mm"
#undef main
int main() {
    @autoreleasepool {
        auto* device = [ScratchTestDevice new];
        MVKPerVertexScratchRequest request{384, 48, 24, 24};
		// Invocations, VS output, TCS vertex and patch output, float32 levels (24/patch), topology plan.
		NSUInteger sizes[] = {208, 384, 384, 128, 48, 528};
		std::copy(std::begin(sizes), std::end(sizes), request.tessSizes);
		for (unsigned mode = 0; mode < 2; ++mode) {
			for (unsigned failure = 1; failure <= 11; ++failure) {
                device->calls = 0; device->failAt = failure; device->failureMode = mode;
                MVKPerVertexScratchReservations reservations;
                assert(!mvkReservePerVertexScratch((id<MTLDevice>)device, {request}, reservations));
                assert(reservations.empty() && liveBuffers == 0 && device->calls == failure);
            }
        }
		MVKPerVertexScratchReservations reservations;
        // Unmapped shared invocation records (6th allocation) and topology plan (11th) both roll back.
        for (unsigned failure : {6u, 11u}) {
            device->calls = 0; device->failAt = failure; device->failureMode = 2;
            assert(!mvkReservePerVertexScratch((id<MTLDevice>)device, {request}, reservations));
            assert(reservations.empty() && liveBuffers == 0);
        }
        device->calls = 0; device->failAt = 0;
        assert(mvkReservePerVertexScratch((id<MTLDevice>)device, {request}, reservations));
		for (unsigned i = 0; i < 6; ++i) assert(reservations[0]->buffers[7+i].length == sizes[i]);
		assert(reservations[0]->buffers[7].contents && !reservations[0]->buffers[8].contents && reservations[0]->buffers[12].contents);
		assert(reservations[0]->getTessEvalStatus() == 0);
		reservations.clear();
		assert(liveBuffers == 0);
		MVKPerVertexScratchRequest indirect{384, 48, 24, 24};
		indirect.indirectCapacity = 12;
		indirect.planSize = 1024;
		device->calls = 0;
		assert(mvkReservePerVertexScratch((id<MTLDevice>)device, {request, indirect}, reservations));
		assert(reservations[0]->getIndirectStatus() == 0 && reservations[0]->getTessEvalStatus() == 0);
		assert(reservations[1]->buffers[12].contents && reservations[1]->getIndirectStatus() == 0);
		*(uint32_t*)reservations[1]->buffers[12].contents = 2;
		assert(reservations[1]->getIndirectStatus() == 2 && reservations[1]->getTessEvalStatus() == 0);
		reservations.clear();
		assert(liveBuffers == 0);
        [device release];
    }
	puts("TES and indirect scratch: eleven transactional allocations, isolated statuses and ownership PASS");
}
