# Repository artwork

`banner-dark.svg` and `banner-light.svg` are editable 1280 × 640 sources.
Matching PNGs serve the README and social sharing; `banner-dark.png` is the repository social-preview upload asset.
Artwork is branding, not an application screenshot.

Colors are Nugu semantic palette values generated from `bugabinga/dotfiles`' Nugu source, not independently chosen app-theme colors.
Backdrop/text use `content.backdrop`/`content.normal`; the braid uses `content.accent`, `content.important_local`, and `content.focus`.
Both modes retain the same roles.

Text uses JetBrains Mono, rasterized from locally installed regular/bold fonts with resvg.
Font binaries are not bundled here; JetBrains Mono's font license remains with its upstream distribution.
SVG/PNG artwork is covered by the repository MIT license.

GitHub's custom repository social preview is a separate setting from README images.
Uploading this PNG there requires the repository settings web interface; committing it alone does not configure that setting.
