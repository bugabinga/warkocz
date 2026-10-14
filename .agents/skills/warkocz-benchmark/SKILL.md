---
name: warkocz-benchmark
description: Design, run, or interpret warkocz startup, interaction, allocation, memory, and regression benchmarks.
---

# Benchmark workflow

- Read ../../../SPEC.html for endpoints, workloads, budgets, and approval gates.
- Obtain approval before local benchmark execution or cache-reset operations; do not reboot.
- Pin artifact, toolchain, fixture seed/hash, machine, cache state, run order, sampling, and confidence procedure.
- Use Hyperfine for repetitions and raw export; endpoint timestamps determine GUI startup, excluding wrapper/cleanup overhead.
- Separate cold/warm classes; unsupported or unverified cache reset leaves cold compliance unverified.
- Trace input-to-presentation separately; attribute app, workers, LSP, shared memory, and GPU resources explicitly.
- Compare matched conditions; retain raw samples and report inconclusive results without passing them.
