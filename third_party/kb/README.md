# Vendored kb text shaping header

Upstream: <https://github.com/JimmyLefevre/kb>, zlib license (see `LICENSE`).

## Layout

- `kb_text_shape.h` — pristine upstream bytes at the pinned commit. Never edit this file; the sha256 build gate rejects drift.
- `patches.zig` — ordered exact-context patches applied at build time, plus the engine, provenance pins, and the golden patched-header hash.
- `LICENSE` — upstream zlib license, retained verbatim.

## Current pin

| Field | Value |
|---|---|
| Upstream version | `kb_text_shape 2.28g` |
| Upstream commit | `7d811ad80215eef6363d60057b0ea140215278a1` |
| Upstream header sha256 | `51a93aad590375148f35cb32e24f44ee0afcb6eb4c993749ef31143f78979a5e` |
| Patched header sha256 | see `patched_sha256` in `patches.zig` |

## How the build uses this

`zig build check` and `zig build test` run `warkocz-kb-verify`, which applies the patch table in memory and fails with a targeted message when any patch context is missing or ambiguous, when the patched output hash drifts, or (via tests) when the vendored pin drifts. Because the vendored header is embedded at compile time (`vendored_header` in `patches.zig`), any change to it recompiles and re-runs the gate.
`zig build kb-check` additionally compile-checks the patched header with `zig cc`.
`mise run kb-patch-status` prints which patches still match the vendored header; use it first when touching upstream.

## Updating upstream

1. Download the new upstream `kb_text_shape.h` and `LICENSE`; record the commit and sha256 in `patches.zig` (`upstream_commit`, `upstream_sha256`) and this file.
2. Run `mise run kb-patch-status`. For every patch reporting `MISSING`, check whether upstream fixed it: if yes, delete the patch (the goal is zero patches); if no, port its intent to the new code.
3. Update remaining patch contexts, set `patched_sha256` to the new golden hash from the failing `zig build test` output, and run `mise run check`.
4. Record upstream changes worth knowing in this file's history section below.

Deleting a patch the moment upstream fixes it is the intended workflow; patches are a temporary bridge, not a fork.

## Patch history

- `7d811ad8` (2.28g): seventeen patches introduced after the isolated compatibility investigation found allocation-refusal crashes (including built-in fixed-memory paths), missing font-push OOM classification, and an GB11 grapheme-state bug splitting family ZWJ emoji into two clusters. Full rationale and evidence: temporary investigation report `C:/Users/okr/AppData/Local/Temp/warkocz-text-accessibility/kb-update/PATCHES.md` (session artifact), summarized in `PATCHES.md` notes inside `patches.zig` ids P0-P16.
- Strict UTF-8 validation is deliberately NOT patched: the kb decoder accepts overlong, surrogate, and out-of-range sequences; validation stays an application responsibility over authoritative bytes.
- Suspected upstream conformance gaps not patched for lack of official test data: `ZWJ × ZWJ` handling and Hangul/Indic `× ZWJ` transitions.
