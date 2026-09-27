# Cereal cache repair — complete

Goal met: default-OFF startup assertion removed, both TES options serialized, incompatible private cache formats rejected before option parsing. Scope is MVKPipeline.mm cache/serialization/validator plus Tests/CerealCache only. Existing WIP and TES guards preserved; no commits/push/PR.

Final source: SPIRV-Cross P2 db9ab6dc2c6123a6e71fcb2c2ecad696cd431208353c355db95b32d269b5bd4e, forcibly recompiled and relinked. Historical fa1c control aborted before GPU. Coordinator CLI 4fd9... is not the linked artifact. See README and validated.sha256 for exact provenance.

Verified: failing-before/passing-after Cereal roundtrip for false/true of both options; distinct cache identity; corrected sizes/padding; clean Debug build; actual startup validator; populated Vulkan cache reload; no-op Metal dispatch/fence with API/GPU validation; legacy/future/truncated schema rejection. Final tests exit 0.

Limits: arm64 macOS; ON options CPU only; Vulkan/Metal false; no TES render. Existing public gate harness link failed due absent weak adapter; source/build gate checks pass and no adapter enabled. All criteria within scope satisfied; no remaining work for this task. Evidence and reproduction in README.md.
