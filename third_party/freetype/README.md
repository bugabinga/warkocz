# Vendored FreeType rasterization subset

Upstream: <https://freetype.org>, FreeType License (FTL) — see `LICENSE.TXT` and `docs/FTL.TXT` (the FTL requires distributing `docs/FTL.TXT` with the sources).

## Provenance

| Field | Value |
|---|---|
| Upstream version | `VER-2-14-1` |
| Source archive | `freetype-2.14.1.tar.xz` |
| Archive SHA-256 | `32427e8c471ac095853212a37aef816c60b42052d4d9e48230bab3bdf2936ccc` |

Every vendored file is byte-identical to the extracted archive. Nothing here is patched; if a patch ever becomes necessary, follow the `third_party/kb/README.md` gate pattern and record it here.

## Subset

- `include/` — complete public and internal headers.
- `src/base/`, `src/sfnt/`, `src/truetype/`, `src/smooth/` — the modules registered in `config/ftmodule.h` (TrueType driver, SFNT, grayscale rasterizer).
- `config/ftoption.h`, `config/ftmodule.h` — minimal configuration: no gzip, bzip2, PNG, Brotli, HarfBuzz, SVG, cache subystem, or platform stream support; embedded bitmaps and CMap formats 4/12 enabled; shared Type 1 limits defined because internal headers reference them.

## Build integration

`zig build ft-check` compiles the subset into a static library with the vendored configuration and runs a hosted smoke test (`FT_Init_FreeType` → version 2.14.1 → `FT_Done_FreeType`).
`zig build check` and `zig build test` include it.
`.gitattributes` marks this tree `-text` so checkouts keep upstream bytes.

## Updating upstream

1. Download the new release archive and record its SHA-256 here.
2. Replace `include/` and the four `src/` module directories from the extracted archive; keep `config/` unless the release requires option changes.
3. Run `mise run check` (compile gate plus smoke test) and update the version table.
4. Record behavioral changes worth knowing below.

## History

- `VER-2-14-1`: initial vendored subset, verified by the isolated typography spike (raster baseline, 38 allocation-failure positions, 8 byte-budget cases, cleanup integrity) before vendoring.
