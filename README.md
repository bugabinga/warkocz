<picture>
  <source media="(prefers-color-scheme: dark)" srcset=".github/assets/banner-dark.png">
  <source media="(prefers-color-scheme: light)" srcset=".github/assets/banner-light.png">
  <img alt="warkocz · Untangle intent. A native, merge-first Git client in Zig. Early development." src=".github/assets/banner-dark.png" width="1280" height="640">
</picture>

# warkocz

[![License: MIT](https://img.shields.io/badge/license-MIT-b59ae4?style=flat-square)](LICENSE) [![Zig: 0.17.0](https://img.shields.io/badge/Zig-0.17.0-d151d1?style=flat-square&logo=zig&logoColor=white)](mise.toml) [![Status: bootstrap](https://img.shields.io/badge/status-bootstrap-7ba1aa?style=flat-square)](#status)

**Read changes clearly. Resolve them deliberately. Keep their meaning.**

*warkocz* is Polish for *braid*.
The goal: a native graphical Git client built around the hardest part of version control, bringing divergent changes together without losing intent.

[Specification](SPEC.html) · [Contributing](CONTRIBUTING.md) · [Discussions](https://github.com/bugabinga/warkocz/discussions) · [Issues](https://github.com/bugabinga/warkocz/issues)

> [!IMPORTANT]
> **Bootstrap, not a usable Git client yet.**
> The executable prints status/help/version and rejects diff/merge execution before opening files.
> Tested in-memory byte editing, conservative text merge, resolution history, and safety primitives exist; they are not connected to a GUI.
> No GUI, repository mutations, structural merge, durable recovery, or LSP integration is implemented.
> The artwork above is branding, not an application screenshot.

## The direction

| Focus | Intended experience |
| :--- | :--- |
| **Merge first** | Editable two-way comparisons and real common-ancestor three-way merges, with a result-centered workspace. |
| **Structure without guesswork** | Moved/edited syntax, exact text views, inspectable automatic resolutions, and explicit fallbacks. |
| **Git, not a shortcut around Git** | Daily and advanced workflows; hooks, filters, signing, worktrees, and recovery remain part of the contract. |
| **Quiet interface, readable code** | Nugu dark/light, JetBrains Mono, Nerd Fonts icon fallback, minimal chrome, keyboard and mouse parity. |
| **Local and deliberate** | Offline core workflows, explicit workspace trust, no silent uploads or telemetry. |

Windows, Linux with Wayland/X11, and macOS are completion targets, **not currently validated product support**.
[SPEC.html](SPEC.html) defines the full contract, safety requirements, and unresolved feasibility gates.

## Status

- [x] Product and engineering specification.
- [x] Zig bootstrap with ReleaseSafe default.
- [x] mise tool registry and thin Zig build delegation.
- [x] Executable checks for status/help/version, unavailable operations, and argument exhaustion.
- [x] Bounded byte editing, conservative single-range merge, in-memory resolution/undo, snapshot leases, lexical paths, and invocation parsing.
- [x] Hosted core-check workflow definition; not product acceptance.
- [ ] Native rendering, typography, accessibility, and input feasibility.
- [ ] Editor, Git integration, structural engines, LSP, and recovery.
- [ ] Product acceptance, native GUI CI, benchmarks, and release packages.

[Implementation evidence and remaining gates](IMPLEMENTATION.md) distinguish internal primitives from usable product capabilities.
No performance target or product capability is claimed from scaffold tests.

## Development

Requires [mise](https://mise.jdx.dev/) and the Zig version pinned in [mise.toml](mise.toml).
Review the project configuration before trusting it or provisioning tools.
The scaffold has no third-party application dependencies.

| mise task | Delegates to | What it does today |
| :--- | :--- | :--- |
| `mise run build` | `zig build` | Builds the bootstrap into `zig-out/bin`. |
| `mise run run` | `zig build run` | Prints bootstrap status; no window or repository access. |
| `mise run test` | `zig build test` | Runs bounded core tests and executable invocation contracts. |
| `mise run fmt` | `zig build fmt` | Formats Zig source/build files. |
| `mise run check` | `zig build check` | Checks formatting, bounded core, and executable behavior. |

ReleaseSafe is spelled `safe` in Zig 0.17; Debug is available through `-Doptimize=debug`.
Unsafe optimization modes are rejected.
Benchmark and packaging tasks will appear when they do real work.
Tool-download integrity metadata and the complete native dependency graph remain acceptance gates.

<details>
<summary><strong>Repository map</strong></summary>

| Path | Responsibility |
| :--- | :--- |
| [SPEC.html](SPEC.html) | Binding completion contract. |
| [src/main.zig](src/main.zig) | Bootstrap entry point; help/version and explicit execution refusal. |
| [src/bytes.zig](src/bytes.zig), [src/session.zig](src/session.zig) | Exact byte edits and bounded in-memory resolution history. |
| [src/ui](src/ui) | Future UI/editor; scoped guidance only today. |
| [src/engine](src/engine) | Conservative text merge and snapshot lease protocol; no structural worker process yet. |
| [src/vcs](src/vcs) | Lexical path checks; no Git backend yet. |
| [tests/cli.zig](tests/cli.zig) | Executable checks owned by the Zig build graph. |
| [bench](bench) | Benchmark guidance; no timing harness yet. |
| [AGENTS.md](AGENTS.md) | Agent routing into scoped instructions and local skills. |

</details>

## Contributing

Concrete fixtures, reproducible failures, and evidence-backed design feedback are welcome.
Start with [CONTRIBUTING.md](CONTRIBUTING.md) and the relevant part of the specification.
Report vulnerabilities through [private security reporting](SECURITY.md), not public issues.

## License

Project-owned code and artwork: [MIT](LICENSE).
Dependency and font licenses remain separate.
