// Copyright 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
#include "SPIRVToMSLConverter.h"
#include <cereal/archives/binary.hpp>
#include <cereal/types/map.hpp>
#include <cereal/types/string.hpp>
#include <cereal/types/vector.hpp>
#include <cassert>
#include <cstdio>
#include <sstream>
#include "ArchiveDefinitions.h"

template<class T> static std::string encode(T& value) {
    std::ostringstream stream;
    cereal::BinaryOutputArchive archive(stream);
    archive(value);
    return stream.str();
}

template<class T> static void roundtrip(T& source, T& restored) {
    std::ostringstream stream;
    { cereal::BinaryOutputArchive archive(stream); archive(source, uint32_t(0xabcdef01)); }
    std::istringstream input(stream.str());
    cereal::BinaryInputArchive archive(input);
    uint32_t sentinel = 0;
    archive(restored, sentinel);
    assert(sentinel == 0xabcdef01 && input.peek() == EOF);
}

int main() {
    using Options = SPIRV_CROSS_NAMESPACE::CompilerMSL::Options;
    Options defaults;
    mvk::SPIRVToMSLConversionConfiguration config;
    assert(!defaults.tessellation_factors_float32 && !defaults.tese_as_compute);
    for (bool float32 : {false, true}) {
        for (bool compute : {false, true}) {
            Options source, restored;
            source.tessellation_factors_float32 = float32;
            source.tese_as_compute = compute;
            restored.tessellation_factors_float32 = !float32;
            restored.tese_as_compute = !compute;
            roundtrip(source, restored);
            assert(restored.tessellation_factors_float32 == float32);
            assert(restored.tese_as_compute == compute);
            assert(encode(source) == encode(restored));
            mvk::SPIRVToMSLConversionConfiguration original, loaded;
            original.options.mslOptions.tessellation_factors_float32 = float32;
            original.options.mslOptions.tese_as_compute = compute;
            original.options.entryPointName = "cache_roundtrip";
            original.options.numTessControlPoints = 3;
            loaded.options.mslOptions.tessellation_factors_float32 = !float32;
            loaded.options.mslOptions.tese_as_compute = !compute;
            roundtrip(original, loaded);
            assert(original.matches(loaded));
            auto alternate = loaded;
            alternate.options.mslOptions.tessellation_factors_float32 = !float32;
            assert(!original.matches(alternate) && encode(original) != encode(alternate));
            alternate = loaded;
            alternate.options.mslOptions.tese_as_compute = !compute;
            assert(!original.matches(alternate) && encode(original) != encode(alternate));
            printf("PASS roundtrip and cache identity float32=%d tese_as_compute=%d\n", float32, compute);
        }
    }
    assert(sizeof(defaults) == encode(defaults).size() + optionsPadding);
    assert(sizeof(config.options) == encode(config.options).size() + conversionPadding);
    assert(sizeof(config) == encode(config).size() + configurationPadding);
    printf("PASS default OFF; sizes/archive/padding: %zu/%zu/%zu %zu/%zu/%zu %zu/%zu/%zu\n", sizeof(defaults), encode(defaults).size(), optionsPadding, sizeof(config.options), encode(config.options).size(), conversionPadding, sizeof(config), encode(config).size(), configurationPadding);
}
