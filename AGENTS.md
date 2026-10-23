# warkocz

- Treat SPEC.html as binding product and architecture contract; read relevant sections before changing behavior.
- Use mise for development tools and tasks; keep task bodies delegated to zig build.
- Before editing any Zig code, read src/AGENTS.md.
- Before working in a subtree, read its AGENTS.md; do not assume automatic nested loading.
- Load matching local skills from .agents/skills for dependencies, benchmarking, or delivery.
- Before adding non-Zig dependencies, check https://github.com/allyourcodebase for an existing Zig build wrapper and prefer it; study those wrappers' build.zig patterns for C-dependency integration.
- Keep requirements in SPEC.html, coding rules in scoped AGENTS.md, conditional procedures in skills.
- Report executed checks and remaining gaps; scaffolding is not implemented product capability.
- Before branching, committing, rebasing, merging, or pushing, read the commit and history policy in CONTRIBUTING.md.
