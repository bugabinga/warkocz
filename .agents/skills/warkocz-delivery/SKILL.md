---
name: warkocz-delivery
description: Change warkocz CI, package releases, verify provenance, or prepare distribution and upgrades.
---

# Delivery workflow

- Read ../../../SPEC.html for platform, packaging, update, and acceptance requirements.
- Use the same mise registry and delegated Zig build steps locally and in CI.
- Separate PR, nightly, and release gates; do not substitute cross-compilation for native execution.
- Keep untrusted contributions away from secrets and personal-machine execution.
- Verify artifact hashes, provenance, notices, protected state, migration/rollback behavior, and unsigned-package labels.
- Publish only when explicitly requested; report missing acceptance evidence as blockers.
