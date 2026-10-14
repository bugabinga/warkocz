# Zig implementation

- Follow TigerStyle: safety, performance, developer experience.
- Use explicit control flow, no recursion, bounded work/queues, descriptive snake_case names, explicit units and ownership.
- Keep functions ≤70 lines; require approval for exceptions.
- Assert meaningful pre/postconditions and invariants, including paired boundary checks; average ≥2 assertions per function without vacuous checks.
- Keep programmer-invariant checks active in ReleaseSafe; handle input, OS, cancellation, and resource failures as errors.
- Allocate Zig-owned backing storage once per process before service; borrow/recycle bounded pools afterward.
- Keep ordinary exhaustion recoverable; preserve existing work.
- Make library options, lifetime transitions, and error handling explicit; explain non-obvious decisions.
- Add abstractions only for demonstrated domain or safety needs.
- Verify changes with relevant tests, allocation/pool audits, and formatter checks; do not disable failing safeguards.
