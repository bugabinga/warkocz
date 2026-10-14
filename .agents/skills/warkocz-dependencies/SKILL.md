---
name: warkocz-dependencies
description: Add, upgrade, replace, or approve warkocz toolchains, libraries, grammars, fonts, and shader tooling.
---

# Dependency workflow

- Read ../../../SPEC.html for approved candidates and unresolved gates.
- Distinguish investigation approval from final adoption.
- Verify upstream source, license, redistribution obligations, compiler compatibility, platform coverage, allocation behavior, and failure handling.
- Pin development tools through ../../../mise.toml; keep dependency/build ownership in Zig build files.
- Propose exact dependency changes before installation or adoption.
- Validate a single compatible toolchain graph with correctness, packaging, and relevant performance checks.
- Preserve provenance; never infer code-reuse permission from a project's name or upstream ancestry.
