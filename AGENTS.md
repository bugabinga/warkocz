# warkocz

- Treat SPEC.html as binding product and architecture contract; read relevant sections before changing behavior.
- Use mise for development tools and tasks; keep task bodies delegated to zig build.
- Before editing any Zig code, read src/AGENTS.md.
- Before working in a subtree, read its AGENTS.md; do not assume automatic nested loading.
- Load matching local skills from .agents/skills for dependencies, benchmarking, or delivery.
- Keep requirements in SPEC.html, coding rules in scoped AGENTS.md, conditional procedures in skills.
- Report executed checks and remaining gaps; scaffolding is not implemented product capability.
