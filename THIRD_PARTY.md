# Third-party notices

## kb text shaping header (vendored, locally patched at build time)

- Package: `JimmyLefevre/kb` `kb_text_shape` `2.28g`
- Pinned upstream commit: `7d811ad80215eef6363d60057b0ea140215278a1`
- Source: <https://github.com/JimmyLefevre/kb>
- Vendored file: `third_party/kb/kb_text_shape.h`, byte-identical to the pinned commit, sha256 `51a93aad590375148f35cb32e24f44ee0afcb6eb4c993749ef31143f78979a5e`
- Local changes: applied in memory at build time from `third_party/kb/patches.zig`; the distributed source tree ships the unmodified upstream bytes plus the patch definitions
- License: zlib

```text
zlib License

(C) Copyright 2024-2025 Jimmy Lefevre

This software is provided 'as-is', without any express or implied
warranty.  In no event will the authors be held liable for any damages
arising from the use of this software.

Permission is granted to anyone to use this software for any purpose,
including commercial applications, and to alter it and redistribute it
freely, subject to the following restrictions:

1. The origin of this software must not be misrepresented; you must not
  claim that you wrote the original software. If you use this software
  in a product, an acknowledgment in the product documentation would be
  appreciated but is not required.
2. Altered source versions must be plainly marked as such, and must not be
  misrepresented as being the original software.
3. This notice may not be removed or altered from any source distribution.
```

## SDL Zig build wrapper

- Package: `allyourcodebase/SDL` `tag1.0.5+3.4.18`
- Pinned commit: `8cc97256dab25e17796b16c48e968eef5d90a5cc`
- Zig package integrity hash: `sdl-1.0.5+3.4.18-i4QD0eENqgB-RtDRu88zdUdtB6mSq5xdrs-nS9peVA3d`
- Source: <https://github.com/allyourcodebase/SDL>
- License: MIT

The wrapper source and MIT license are fetched through the pinned Zig package.

```text
MIT License

Copyright (c) contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## SDL

- Package: SDL `3.4.18`
- Pinned upstream source commit: `829a65d769d935c4852f8159e964312c0957260a`
- Source archive: <https://github.com/libsdl-org/SDL/archive/refs/tags/release-3.4.18.tar.gz>
- Zig package integrity hash: `N-V-__8AACpx-AKEJIUZ0-XrP9-96MpSaw17FJ7L6B7LmO42`
- License: zlib

SDL is linked statically by the current build graph.
The package copies the SDL license with the source archive.
`zig build` installs this file at `share/doc/warkocz/THIRD_PARTY.md`.

```text
Copyright (C) 1997-2026 Sam Lantinga <slouken@libsdl.org>

This software is provided 'as-is', without any express or implied
warranty. In no event will the authors be held liable for any damages
arising from the use of this software.

Permission is granted to anyone to use this software for any purpose,
including commercial applications, and to alter it and redistribute it
freely, subject to the following restrictions:

1. The origin of this software must not be misrepresented; you must not
   claim that you wrote the original software. If you use this software
   in a product, an acknowledgment in the product documentation would be
   appreciated but is not required.
2. Altered source versions must be plainly marked as such, and must not
   be misrepresented as being the original software.
3. This notice may not be removed or altered from any source distribution.
```
