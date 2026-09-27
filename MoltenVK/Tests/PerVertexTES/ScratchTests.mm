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
        NSUInteger sizes[] = {208, 384, 384, 128, 24};
        std::copy(std::begin(sizes), std::end(sizes), request.tessSizes);
        for (unsigned mode = 0; mode < 2; ++mode) {
            for (unsigned failure = 1; failure <= 10; ++failure) {
                device->calls = 0; device->failAt = failure; device->failureMode = mode;
                MVKPerVertexScratchReservations reservations;
                assert(!mvkReservePerVertexScratch((id<MTLDevice>)device, {request}, reservations));
                assert(reservations.empty() && liveBuffers == 0 && device->calls == failure);
            }
        }
        device->calls = 0; device->failAt = 6; device->failureMode = 2;
        MVKPerVertexScratchReservations reservations;
        assert(!mvkReservePerVertexScratch((id<MTLDevice>)device, {request}, reservations));
        assert(reservations.empty() && liveBuffers == 0);
        device->calls = 0; device->failAt = 0;
        assert(mvkReservePerVertexScratch((id<MTLDevice>)device, {request}, reservations));
        for (unsigned i = 0; i < 5; ++i) assert(reservations[0]->buffers[7+i].length == sizes[i]);
        assert(reservations[0]->buffers[7].contents && !reservations[0]->buffers[8].contents);
        reservations.clear();
        assert(liveBuffers == 0);
        [device release];
    }
    puts("TES scratch: all ten allocations transactional; nil/short/unmapped failures and ownership PASS");
}
