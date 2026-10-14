# Structural workers

- Follow SPEC.html's worker, snapshot, and provenance contracts.
- Reject stale generations; recycle shared slots only after lease release or confirmed worker death.
- Preserve user decisions across timeout, cancellation, malformed input, and exhaustion.
- Compare pinned reference implementations against reviewed expected results; agreement is not correctness proof.
- Track algorithm/source provenance; do not copy or translate GPL implementation code into MIT-owned engines.
