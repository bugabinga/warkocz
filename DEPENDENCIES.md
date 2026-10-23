# Text and typography dependency proposal

Status: investigation only, no adoption, installation, font bundling, or `SPEC.html` change authorized.
Owner-authorized exception: the kb header is vendored unpatched under `third_party/kb/` and patch definitions are applied at build time (`third_party/kb/README.md`), and the FreeType subset is vendored pristine under `third_party/freetype/` with a compile gate; this is build-system wiring for the investigation, not adopted product capability and no product code consumes either yet.

Repository evidence: `SPEC.html` selects kb for shaping/segmentation, FreeType for rasterization, default JetBrains Mono with bundled Nerd Fonts icon fallback, and explicitly records kb's unsupported explicit bidi controls and unproven bounded-allocation safety.

Current toolchain floor: Zig 0.17.0 in `build.zig.zon` and `mise.toml`; current SDL is already integrated and is out of scope.

## Candidate stack

| Role | Proposed exact baseline | License and distribution | Compatibility and evidence status |
|---|---|---|---|
| Shaping and segmentation | `JimmyLefevre/kb`, commit `7d811ad80215eef6363d60057b0ea140215278a1` (header describes kb text-shape 2.28g) | zlib; retain upstream copyright/license and mark any changed source; upstream says single-header C/C++ | C header, not a Zig package/API; vendored pristine under `third_party/kb/` with build-time patches for allocation failure propagation and GB11 grapheme state. Verified against Zig 0.17.0 on Windows x64 in the isolated spike; Linux/macOS compile of the patched header not yet verified. |
| Glyph rasterization | FreeType `VER-2-14-1`, source archive `freetype-2.14.1.tar.xz`, SHA-256 `32427e8c471ac095853212a37aef816c60b42052d4d9e48230bab3bdf2936ccc` | FreeType License (FTL) chosen over GPLv2; `LICENSE.TXT` and required `docs/FTL.TXT` vendored; FTL attribution recorded in `THIRD_PARTY.md` | Owner-authorized exception like kb: pristine subset vendored under `third_party/freetype/` (`include/`, `src/base/`, `src/sfnt/`, `src/truetype/`, `src/smooth/`, minimal `config/`) and compiled into a static library by `zig build ft-check`. Verified against Zig 0.17.0 on Windows x64 in the isolated spike (raster baseline, 38 fault positions, 8 budgets); no product code consumes it yet and Linux/macOS rendering acceptance remains open. |
| Default code font | JetBrains Mono `v2.304`, upstream commit `cd5227bd1f61dff3bbd6c814ceaf7ffd95e947d9` | SIL OFL 1.1; bundle OFL and copyright, keep font under OFL; no standalone sale, respect Reserved Font Name terms for modified versions | Font asset, not a compiler dependency. Select the required static/variable font files and glyph coverage after inspection; no font file or size has been verified. |
| Icon fallback | Nerd Fonts JetBrains Mono patched font, `ryanoasis/nerd-fonts` `v3.5.1`, commit `b894ea7803af6aade63d60a4381e006098ec9c4d`; prefer `JetBrainsMono` Mono variant, icons only at fallback range | Nerd Fonts licensing is mixed by source; its v3.5.1 audit lists JetBrains Mono as OFL-1.1-no-RFN, while upstream Nerd Fonts license/audit details source glyph licenses. Package all applicable font and glyph notices with exact selected asset; do not assume one blanket Nerd Fonts license. | Separate font face for icons only, not ordinary code. Confirm asset identity, coverage, license files, fallback behavior, and redistribution permissions against the actual release asset before bundling. No font artifact downloaded or validated. |

References: [kb repo](https://github.com/JimmyLefevre/kb), [kb observed commit](https://github.com/JimmyLefevre/kb/commit/cc63806775f615908ec9562653af4726d8b895d5), [kb license](https://github.com/JimmyLefevre/kb/blob/cc63806775f615908ec9562653af4726d8b895d5/LICENSE), [FreeType announcement and source checksums](https://lists.nongnu.org/archive/html/freetype-announce/2025-09/msg00001.html), [FreeType license at candidate tag](https://github.com/freetype/freetype/blob/VER-2-14-1/LICENSE.TXT), [JetBrains Mono release](https://github.com/JetBrains/JetBrainsMono/releases/tag/v2.304), [JetBrains Mono OFL](https://github.com/JetBrains/JetBrainsMono/blob/v2.304/OFL.txt), [Nerd Fonts release](https://github.com/ryanoasis/nerd-fonts/releases/tag/v3.5.1), [Nerd Fonts license](https://github.com/ryanoasis/nerd-fonts/blob/v3.5.1/LICENSE), [Nerd Fonts license audit](https://github.com/ryanoasis/nerd-fonts/blob/v3.5.1/license-audit.md).

## Blocking findings and gates

- kb README scopes shaping to one infinitely long line and explicitly excludes paragraph layout, rasterization, system font discovery, and selection; application owns line layout, wrapping, cursor/selection mapping, and font loading.
- kb source documents custom allocator hooks, fixed-memory context placement, and caller-provided buffers, but these APIs alone do not prove a hard cap across every code path, safe exhaustion behavior, or safe integration with Zig allocators. Audit every allocation site and callback contract; exercise forced exhaustion/failure before adoption.
- kb's unsupported explicit bidi controls remain an acceptance gap per the binding SPEC. Decide whether to implement/control-sanitize separately, defer with an explicit product acceptance decision, or choose another shaping route; do not claim bidi compliance from basic RTL shaping examples.
- FreeType's FTL has a documentation attribution condition. Choosing GPLv2 instead is unsuitable absent a broader licensing decision; this proposal selects FTL.
- Nerd Fonts is an aggregator, not a single license grant. Candidate asset selection must trace the exact JetBrains Mono font, icon glyph sources, license/audit metadata, and redistributed notices; do not bundle an unreviewed all-font archive.
- No Zig 0.17.0 build, platform build, runtime integration, memory-cap test, font rendering/coverage test, or license audit of final binary/assets was run. Exact stable/current status should be refreshed before pinning; kb is a moving `main` commit rather than a tagged release.

## Decisions requested before adoption

1. Approve or reject exact pins for kb, FreeType, JetBrains Mono, and a specific Nerd Fonts JetBrains Mono Mono font artifact; pins above are investigation baselines, not accepted dependencies.
2. Approve FTL distribution and required FreeType attribution, plus the complete final font/icon notice set after artifact inspection.
3. Decide explicit bidi-control support/acceptance path and allocator-exhaustion gate; allocator customization is not itself approval to adopt kb.
4. Approve target-platform C integration and build ownership approach for kb and FreeType after an isolated Zig 0.17.0 compatibility spike.
5. Separately decide numeric memory/font-cache budgets and obtain owner visual approval for type hierarchy, font face, icon fallback, and coverage; this proposal does not decide those open SPEC requirements.

## Safe work before adoption

- Zig-owned text-layout and editor interfaces, test fixtures for grapheme/codepoint/byte provenance, and pure-Zig fallback/default-font selection contracts can be prepared without importing or vendoring these dependencies.
- Define candidate acceptance tests for shaping clusters, mixed scripts/direction, bidi-control edge cases, font coverage/fallback, FreeType raster output, allocator exhaustion, and package notice completeness.
- Do not implement speculative C bindings, fetch assets, pin dependencies in build files, or treat scaffolding as usable text capability before approval.
