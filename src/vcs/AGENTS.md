# VCS integration

- Follow SPEC.html's mutation, trust, recovery, and Git-compatibility contracts.
- Preflight effective repository state and required safeguards before mutation.
- Use Git fallback when library equivalence is unproven; block when neither backend can honor required semantics.
- Serialize shared Git resources and recheck stale state before writes.
- Never test mutations against personal repositories or encrypted dotfiles.
