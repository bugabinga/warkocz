# Implementation evidence

`SPEC.html` remains binding completion contract.
Version `0.0.0` is an early native GUI slice, not a usable full Git client or release candidate.

## Implemented slice

| Source | Evidence | Explicit boundary |
| :--- | :--- | :--- |
| `src/ui/native.zig`, `src/ui/editor.zig` | SDL result-only lossless ASCII editing through exact `Session.apply_edits`, bounded cursor/selection, CRLF-atomic navigation/selection boundaries, drag and Shift-click range extension, selected-range painting, caret-following keyboard editing/navigation, bounded edge-drag autoscroll, backspace/delete, explicit Ctrl copy/cut/paste/select-all, bounded undo/redo, receipt invalidation, diagnostic byte display, whole-side choices, text-focus routing that never invokes plain resolution/save keys, and injected GUI open→select→edit→undo→redo→Save→async Complete exact-byte evidence. Welcome has visible Open two-way comparison, Open three-way merge, and Open repository controls plus Ctrl+P entries with names, aliases, help, bindings, and picker-pending disabled reason. Mouse, key, and palette route through the same launcher action dispatch. | Unsupported controls (including NUL, ESC, and DEL) and non-ASCII result bytes remain exact read-only byte review with whole-side choices; editable content is printable ASCII plus TAB, CR, and LF. No Unicode/grapheme editor, shaped text, IME, syntax, accessibility, Nugu theme, bundled fonts, or real diff presentation. Initial input loading/hashing/session construction runs in a bounded LoadJob; metadata is copied into stable process storage and shutdown joins the worker. OS picker interaction remains manual; injected tests cover SDL routing and copied callback results only. Picker-pending window close is visibly blocked until picker dismissal, retaining callback state safely. Clipboard failures retain the result and bounded copied bytes. SDL clipboard returned memory is unavoidable foreign allocation attributed to explicit Paste. |
| `src/save.zig` | One worker with caller-owned fixed path/content/preflight storage, immutable source-path/identity/result copy, bounded distinct save/verification jobs, worker-side regular-file load+SHA-256 source revalidation before no-clobber publication and output/source rereads for completion verification, observable job ID/kind/identity/result, join during shutdown. | Revalidation observes files only; no filesystem snapshot or TOCTOU guarantee, repository-state preflight, or Git integration. |
| `src/output.zig` | Windows-only local-NTFS new-file publication, exclusive write-through temporary handle, random temporary name, no-clobber rename, flush before and after rename, receipt SHA-256/length, handle-bound cleanup. Remote-volume detection queries `FS_DEVICE_INFORMATION.Characteristics`; filesystem attribute `0x10` is compression, not remote. Post-rename handle closes; pre-rename cleanup uses legacy `Disposition`, not invalid `DispositionEx` on-close flags. | No overwrite/replacement, directory durability proof, power-loss proof, Linux/macOS implementation, repository-state preflight, or Git integration. |
| `src/recovery.zig`, `src/recovery_directory.zig`, `src/ui/native.zig` | Windows DPAPI versioned complete recovery records; verified DACL-protected random `%LOCALAPPDATA%` session child; bounded two-slot automatic journal that copies draft snapshots, coalesces worker publication at 500 ms, retains only owned encrypted records, and exposes ready/pending/writing/durable/failed state without blocking editing. Manual Export remains a distinct new-file-only path; Restore decrypts chosen records, reloads source paths, validates immutable hashes, then opens exact recovered bytes unresolved and unreviewed. | Protected-directory setup runs in a worker. Welcome supports bounded protected-draft discovery, explicit restore, and confirmed Forget selected draft. Exact recovery restoration has native GPU coverage. Changed-source reconciliation beyond rejection, complete decision replay, retention race coverage, and measured crash-loss guarantees remain incomplete. `deinit` retains nonempty protected directories/files after failed or dirty close. Encrypted records are not final results and restoring them must not mark conflicts resolved, Save/Complete, mutate repositories, or grant trust. |
| `src/session.zig`, `src/engine/diff.zig`, `src/engine/multihunk.zig` | Immutable input identities, bounded caller-owned exact line diff, conservative multi-hunk clean composition/conflicts, GUI source change provenance, bounded history, generation changes, exact result bytes. GUI merge allocates fixed pools for ≤128 lines/side and 1,000,000 work units. Resource exhaustion or ambiguous alignment opens a lossless unresolved byte-review session from immutable loaded inputs; manual whole-side choices remain available. | Single-file, in-memory, no persistence or external-change reconciliation. Fallback makes no structural or automatic merge claim and never defaults clean. |
| `src/vcs/inspect.zig`, `src/vcs/record.zig`, `src/vcs/trust.zig`, `src/ui/repository.zig` | Explicit `repo --path --git` native metadata/history view. Installed Git inspection uses native argv from one fixed-pool worker. Whole-file installed-Git `add -- PATH`, `restore --staged -- PATH`, and `commit -m MESSAGE` argv construction exists with exact operation-scoped, revocable in-memory trust records and single-use stale-state tokens. UI exposes Stage selected file, Unstage selected file, Commit staged changes through S/U/C, mouse, and Ctrl+P; it retains selected status path slice directly from the NUL parser, provides review text, ASCII bounded commit-message editing, and executes only after explicit one-operation confirmation. Preflight fingerprints repository/common-directory, symbolic/resolved HEAD, index, selected bytes, executable/config, attributes/hooks and operation state; common-directory serialization and immediate revalidation guard the worker. Fetch/Push review receives an owned by-value summary from collected evidence and renders every role-specific sanitized endpoint before its confirmation text; raw URLs, paths, credentials, query, and fragments remain hidden, while full effective config stays fingerprint-bound. Summary-capacity failure is visible and never renders a partial list. Native GPU fixture routes configured nonorigin Fetch/normal Push through UI input against isolated owned local bare repositories. | No paired rename/copy recording, hunk/line staging, amend/fixup, branch switching, forced push/deletion, pull/integration, or full advanced Git workflow; UI confirmation requires a displayed matching preflight; changing action or commit text revokes the previous review. Local-bare fixture coverage is not real-network, credential, custom-transport, or broad remote acceptance. External-process/filesystem TOCTOU remains; configured hooks/filters/signing execute only under the reviewed grant, not generic containment. Git still parses local config, so inspection is not generic hostile-repository containment. |
| `src/engine/json_merge.zig`, `src/session.zig`, `src/ui/native.zig` | Explicit `.json` three-way requests use bounded root-object merge v1, with exact base-byte shell retention, independent existing-field value composition, retained engine identity, precharged scanner/render work, and key-comparison bounds. | Root fields only; no nested structural merge or Mergiraf equivalence claim. Malformed, duplicate-root-key, changed/reordered member sets, formatting ambiguity, capacity, and budget cases remain exact unresolved byte review. Nested values are atomic; competing nested edits conflict rather than compose. |
| `src/engine/zig_merge.zig`, `src/session.zig`, `src/ui/native.zig` | Explicit `.zig` three-way requests use `zig_declaration_merge v1`, composing independent edits to existing named top-level `fn`/`const`/`var` declarations while retaining exact surrounding bytes and immutable input hashes. Native allocation ceilings are provisional: 4096 declarations/side, 64 KiB names/side, 2 MiB parser scratch. UI claims whole-declaration scope only. Native GPU fixture exercises real `.zig` files through LoadJob, exact-byte composition, Save, and Complete; malformed-source fixture remains unresolved. | Unsupported/malformed syntax, duplicate names, declaration-set/order changes, ambiguous shell, and resource limits use exact unresolved byte review. No fine-grained source pane range model; not Mergiraf-comparable full structural merge. |
| `src/bytes.zig`, `src/engine/text_merge.zig` | Caller-buffer byte editing and legacy conservative single-range fallback for callers not providing multi-hunk storage. | Not full diff3, structural merge, binary/image UI, or fidelity metadata support. |

Save requests are accepted only after explicit resolution.
A successful receipt is accepted only when byte count and SHA-256 match current result for current immutable input identity and generation.
Any session mutation invalidates UI durable-receipt and pending-completion state.
Complete schedules a distinct worker job which rereads input identities and output SHA-256/length against that receipt.
Complete exits successfully only when its current job returns matching output/source observations; output change/deletion or input change fails without rewriting output.
These observations are not a filesystem snapshot or TOCTOU proof.
Closing during a non-welcome session, including pending completion verification, returns `ResolutionIncomplete`.
`PublishedNotDurable` retains destination as recovery evidence and does not permit Complete.

Untrusted Git metadata inspection suppresses system/global config, signature verification, fsmonitor and implicit lazy fetch.
Initial inspection and refresh never run worktree status and render it as not scanned, never clean.
Review worktree status scan requires displayed matching preflight and explicit confirmation for exact `worktree_status` scope; configured clean/process filters may execute and grant expires after one scan attempt.
Parsed status rows use fixed caller-owned storage, remain tied to published metadata generation, disappear on refresh, and never trigger another scan automatically.
This observation/revalidation is not atomic configuration confinement: concurrent hostile config changes and filesystem/process TOCTOU remain unresolved trust boundaries.
Git fixture setup helpers explicitly disable personal/system configuration independently of production mutation environment policy.
Status authorization is consumed on every attempt, including buffer-validation failure; overlapping output/process storage is rejected before execution.
Remote review refuses confirmation when its bounded endpoint presentation cannot fit the viewport.
Git review also rejects Enter key-repeat and queued Enter events predating its first matching rendered frame.

## Root-context, push-source, and Cut review repairs

`src/vcs/record.zig` preserves the selected repository's trust identity while running worktree-relative preflight queries, status, and mutations from the verified worktree root.
Unstage evidence uses literal pathspecs.
The isolated subdirectory regression checks root/shadow paths, effective attributes, CRLF index bytes, status, Stage, Unstage, and unchanged worktree bytes.
Push freshness includes all local ref namespaces; moved tag and custom-namespace sources require fresh review before publication.
Explicit configured push sources additionally bind resolved OIDs, covering pseudorefs and reflog expressions outside the ordinary ref inventory; wildcard sources remain covered by the full inventory.
Refspec bytes are copied into existing caller-owned scratch before resolving sources, so command-output reuse cannot change the remaining expressions.
The local-bare regression covers tags, custom namespaces, `FETCH_HEAD`, and `main@{1}` changing while HEAD/index/config remain stable, stale rejection without remote publication, and successful renewed review.
Independent source review found no remaining blocker in these repaired routes; runtime verification remains separate.
`src/ui/native.zig` returns before clipboard access for collapsed Cut and deletes only the copied selected range.
The headless regression checks retained result/history/generation/receipt/editor state and unavailable bounded clipboard storage without accessing the OS clipboard.
Final-source ReleaseSafe `check test-gpu` passed 25/25 steps; Debug `test test-gpu` passed 23/23 steps.
Each executed 606 overlapping tests (188 core + 186 native + 232 GPU), plus executable contracts.
The explicit installed-Git ReleaseSafe suite passed 3/3 steps and 188/188 tests, including the four push-source scenarios and subdirectory regression.
Linux x86_64 and macOS ARM64 core compile-only checks passed; formatter and diff checks passed.
These repairs do not establish OS clipboard/input, native non-Windows execution, or full product acceptance.

## LSP lifecycle evidence

`Client.init` initializes every document slot's active flag, lengths, and version through `StoredDocument` defaults; inactive payload buffers remain unread until populated.
The regression starts with poisoned backing storage, fills all eight slots with owned URI/text snapshots, checks overflow preservation, then repeats initialization on the populated client.
Targeted ReleaseSafe and Debug checks each passed 3/3 test-root executions.
Final-source ReleaseSafe check/GPU passed 25/25 steps and Debug test/GPU passed 23/23; each ran 609 overlapping executions (189 core + 187 native + 233 GPU), plus executable contracts.
Native synthetic LSP lifecycle checks passed 4/4 steps in both modes, with fifteen fixture invocations per mode.
Linux x86_64 and macOS ARM64 core compile-only checks passed; this is not real-server or native non-Windows acceptance.

Server confirmation requires an identity-bound review latched only after successful presentation.
Exact executable/workspace paths, SHA-256 identities and the user-permission warning use bounded diagnostic-cell wrapping; incomplete/tiny viewports refuse authorization.
Visible Confirm/Cancel controls replace covered hit targets; review-mode keyboard/text input cannot edit the hidden result.
Confirmation requires a fresh non-repeated event newer than presentation, independently of displayed action readiness.
Opening the palette preserves an already displayed matching review but cannot establish a first review behind the palette.
Viewport, identity and incomplete-presentation changes invalidate readiness; worker-owned service state is not read while an LSP job is active.

Transport publications own bounded document URIs and carry worker-observed document versions.
Caller publication buffers must fit and remain disjoint before any copy or queue consumption.
The existing eight-document transport bound is unchanged; native synthetic coverage synchronizes two independent unsaved documents and checks attribution/stale rejection.
GUI remains single-result and rejects foreign same-version replies.
Command encoding/write failure and inbound/publication queue exhaustion now fail the transport visibly rather than silently losing work.
Failed transport suppresses capabilities/publications and clears displayed hover/navigation/diagnostics; result bytes remain authoritative and unchanged.
Detachment is required before reattachment, so failed workers cannot be replaced before reaping.

Revocation claims the captured process handle before joining a potentially stdin-blocked writer.
Writer and reader retain separate pipe ownership, preventing process cleanup from closing their handles concurrently.
A synthetic server completes initialization then stops reading stdin; queued maximum-size document payloads exercise revoke/reap after command writing begins.
That earlier revoke fixture alone did not establish pipe-capacity quotas, deadlines, process-tree teardown or latency bounds.
The supervision slice below adds narrower Windows-native evidence.

Explicit detach and normal close/Complete teardown reuse the existing LSP job slot off the UI thread.
Pending teardown retains storage and native picker callback state; closing permits resize/expose redraw but rejects document mutation.
Queuing failure preserves work and durable receipt while clearing successful-exit acknowledgement.
Closing during pending Complete invalidates that acknowledgement; already verified completion survives duplicate close during its teardown.
Held-teardown fixtures cover continued local state changes during explicit detach and retained immutable state during exit drain.
Exceptional cleanup and other controllers' shutdown joins remain synchronous.
Real-server, multi-language and multi-file GUI acceptance remain incomplete.

## Process supervision slice

`src/vcs/git_process.zig` routes the four production installed-Git launch paths through Windows suspended launch, assignment to a kill-on-close Job Object before resume, concurrent stdout/stderr collection, and one absolute execution deadline including post-EOF process-exit observation.
Caller fixed workspace remains the allocation ceiling; either stream-limit or allocator exhaustion fails visibly, with no partial successful result.
Timeout/error terminates the owned job before pending reads are cancelled/awaited and their buffers released.
Safe cancellation and reaping may exceed the execution deadline; no hard OS-cleanup latency guarantee is claimed.
Trust, exact argv/environment, preflight locks, and mutation `ChildTimeout` unknown-outcome handling remain unchanged.
Termination is not rollback and does not prove that Git or a remote made no changes.
Non-Windows Git retains the previous stdlib process runner and lacks this deadline/tree-containment guarantee.

`src/lsp/transport.zig` now tracks request-reply deadlines, gives initialized idle reads finite wakeups without treating idle as failure, reports shutdown timeout after cleanup, and rejects commands once transport failed or began closing.
The existing 30-second lifecycle budget is provisional, not an owner-approved measured resource cap.
Shutdown waits drain inbound messages on the sole protocol-owning writer; the previous wait-only loop could never consume its acknowledgement.
Windows pipe reads/writes drain cancelled OVERLAPPED completion before releasing buffers; POSIX writes now use a timed operation, but native POSIX execution and descendant teardown remain unverified.
Failed outbound delivery may already have reached the server; the failed connection cannot resume normal service and must be detached before reinitialization.
Local result bytes remain authoritative.

Windows synthetic process fixtures cover exact 128 KiB output on each stream, both stream limits, closed streams with a living root, an exited root with a descendant retaining inherited streams, and a collective 1800 ms execution deadline across draining and exit wait.
Parent-held named mutex abandonment proves that the controlled fixture owner thread actually started and terminated, rather than accepting a timeout before descendant startup.
The collective-deadline fixture delays stream closure by 1200 ms and requires return before 2600 ms; this is a fixture assertion, not a product latency benchmark.
No personal repositories or real remotes are used.

Ultra dynamic tooling now works in this runtime.
After explicit approval for its actual cache location, `warkocz-contract-query` passed a real consumer canary and was reused by implementation/review workers.
It supplies bounded section discovery and derived readable text with source line ranges; `SPEC.html` remains authoritative, including source bytes.
Earlier builder-startup failures do not describe the current runtime.

### Supervision verification

- Final-source `mise run check -- -j1 --summary all`: 21/21 steps, 350/350 overlapping executions (174 core + 176 native), plus CLI contracts.
- Final-source `zig build test -Doptimize=debug -j1 --summary all`: 19/19 steps, the same 350/350 overlapping executions passed.
- Final-source `zig build test-gpu -j1 --summary all`: 9/9 steps, 213/213 overlapping tests passed with installed-Git fixtures disabled; injected SDL routing/rendering, not OS-input or owner visual acceptance.
- `mise exec -- zig build test-git-process-native -j1 --summary all`: 4/4 steps; seven Windows process cases passed in ReleaseSafe.
- The same process target with `-Doptimize=debug`: 4/4 steps; seven cases passed.
- Final-source LSP native target: 4/4 steps and fifteen fixture invocations passed in both ReleaseSafe and Debug.
- Installed-Git compatibility target with explicit `WARKOCZ_TEST_GIT_EXE=C:\Program Files\Git\cmd\git.exe`: 3/3 steps, 174/174 overlapping executions passed against isolated temporary repositories.
- Linux x86_64 and macOS ARM64 core `zig test -O safe -fno-emit-bin` compile-only checks passed; not native execution or full application cross-build acceptance.
- Formatting and `git diff --check` passed.
- OS-input/owner visual, real-server, remote-network, cleanup worst-case, and native non-Windows acceptance remain untested for this slice.

## Pre-merge safety review

Read-only domain reviews covered the complete integration diff before publication.
Repairs reject configured push deletion refspecs and enabled remote mirroring, bind LSP root URI into consent identity, wipe discovery plaintext immediately after metadata extraction, and open recovery deletion targets relative to the verified parent handle.
A Windows opt-in directory-substitution fixture verifies deletion remains anchored to the original directory while replacement-path contents survive.
Hardcoded Windows fixture roots remain an explicit single-host portability limitation, not default hosted-CI coverage.

The owner approved build/CI investigation of the exact Linux transitive graph pinned by SDL wrapper commit `8cc97256dab25e17796b16c48e968eef5d90a5cc` before publication.
This permits verification retrieval/builds, not final dependency adoption or release redistribution approval.
Typography pins remain investigation-only and unapproved for adoption.

- Pre-merge ReleaseSafe check/GPU/recovery graph: 27/27 steps, 397 executed overlapping tests plus cached checks; includes handle-relative retention regression.
- Focused installed-Git destructive-push preflight fixture: 3/3 passed after moving mirror validation before endpoint lookup, so malformed mirror config fails at its owning check.
- A preceding full installed-Git run passed 178/179; only that new malformed-mirror expected-error case failed before the ordering repair.
- Final local Debug check/test graph: 21/21 steps, 357/357 overlapping executions passed.
- Full pre-merge installed-Git suite passed 179/179 overlapping executions after the ordering repair.
- First expanded hosted run `39791066122` passed Windows; Linux/macOS exposed Windows-only environment construction and nonportable test paths/failure injection.
- CI repair preserves explicit unsupported non-Windows mutation environments, uses OS-native path fixtures, and injects write failure at the transport boundary without touching process stdin.
- Repair verification: local ReleaseSafe check passed 358/358 overlapping executions; Linux x86_64/macOS ARM64 core compile-only checks passed.
- Second expanded hosted run `39795047791` passed Windows; Linux/macOS each passed 356/358 overlapping executions, with only the shared POSIX URI encoder regression failing in both test roots.
- Corrected the encoder's extra slash without changing expected URIs; host-independent cases cover POSIX root, POSIX/Windows absolute paths, Unicode/reserved bytes, exact capacity, and undersized buffers.
- New regression failed before the fix; all six protocol tests then passed in ReleaseSafe and Debug.
- Repair-commit native LSP fixtures passed 4/4 steps with fifteen invocations; installed-Git verification passed 180/180 overlapping executions.
- URI repair hosted run `39800021937` passed Windows, Linux, and macOS before the subsequent review-crash repairs below.

### Review-crash repairs

Five automated review reports were verified against `e777cbe` before merge.
Resolution now retains conflict/degradation provenance without false accessor assertions, with history-record consistency checked independently.
Resolved degradation status retains the fallback reason without falsely labeling the result unresolved.
Editor replacement rebuilds line offsets before caret scrolling and clamps the result view; LSP positions use UTF-16 units rather than tab-expanded display columns.
Recovery rebuilds result line offsets before handoff to rendering.
The encrypted GPU restore fixture covers the original CRLF draft, an empty draft, and changed multiline boundaries through restore, render, explicit resolution, Save, and Complete.

- Untouched-conflict and malformed-JSON resolution regressions failed against the old accessors and passed after repair; malformed-Zig/resource-limited history cases and the original JSON-budget regression remain covered.
- ReleaseSafe check/GPU graph passed 25/25 steps and 592 overlapping executions (183 core + 184 native + 225 GPU), plus executable contracts.
- Debug test/GPU graph passed 23/23 steps with the same 592 overlapping executions and executable contracts.
- Owner visual/OS-input acceptance remains unrun; injected rendering and status assertions are not visual approval.
- Hosted run `39804547814` passed Windows, Linux, and macOS at `55ab9f8`.

### Reviewed branch targets and control-byte safety

Branch collection owns the captured commit OID rather than borrowing command scratch.
Creation binds that exact OID into preflight, then uses the freshly revalidated captured OID without another symbolic-ref lookup.
Create, rename, and delete review displays use OIDs from the same collected evidence; rename/delete retain their target presentation.
Moved tags and remote-tracking refs reject confirmation before creating a branch; fresh review permits the newly observed commit.
Editable source and inserted text share the printable-ASCII/TAB/CR/LF policy, while empty results remain editable and empty insertions are rejected.
Unsupported controls retain exact read-only byte review and whole-side choices.
Native line indexing also recognizes lone CR alongside CRLF/LF, keeping allowed newline bytes consistent with editor hit-testing and LSP positions; the encrypted restore fixture includes a bare-CR draft.

- Focused installed-Git moved-ref regression passed 3/3 test-root executions against isolated approved temporary fixtures.
- Captured argv and owned SHA-1/SHA-256 validation regressions each passed 3/3 test-root executions; editor unit tests passed 4/4.
- Full installed-Git target passed 3/3 steps and 186/186 overlapping executions with the explicit installed executable.
- Final ReleaseSafe check/GPU graph passed 25/25 steps; Debug test/GPU graph passed 23/23 steps; each reran 414 overlapping native/GPU executions (185 + 229), with core checks cached.
- Linux x86_64/macOS ARM64 core compile-only checks passed; owner visual/OS-input acceptance remains unrun.
- Fresh hosted verification remains required before merge.

## Earlier verification

- Tag 128: frozen-source ReleaseSafe serial graph passed 34/34 steps and 985/985 overlapping test executions before endpoint-review additions.
- Tags 129/130: Linux x86_64 and macOS ARM64 compile-only checks passed at that earlier source state; not native acceptance.
- Tag 131: 996/997 executions passed; new remote GUI fixture failed without diagnostic output.
- Focused endpoint-redaction/capacity tests passed 4/4, including IPv6 authority validation, custom helpers, empty endpoint rejection and no partial summary publication.
- Tag 132: remote GUI and injected repository events passed; status-scan fixture timed out without a diagnosed cause.
- Tag 133: focused Debug native checks passed 4/4, including status authorization, stale/repeated confirmation rejection, and configured local Fetch/normal Push with pre-contact callback markers.
- Diagnostics now distinguish refused confirmation from a timed-out executing worker; timeouts and safeguards remain unchanged.
- Tag 134: Mise invocation produced no collected verification result; no passing check is claimed.
- Tag 135: serial check/GPU/Git/LSP/output/recovery passed 34/34 steps with 678 executed tests plus cached checks, before transport multi-document changes.
- Tag 136: 32/34 steps and 840/841 executions; installed-Git inspection fixture failed without diagnostic output.
- Tag 137: eight focused Debug inspection attempts passed 3/3 each; one further Debug and five ReleaseSafe attempts also passed after failure-phase diagnostics were added.
- Tag 138: serial graph passed 34/34 steps and 684/684 executions before exit-drain review repairs.
- Exit-drain review found and repaired stale completion acknowledgement on queue failure, suppressed resize redraw, and pending-Complete close semantics despite the preceding passing suite.
- Repair verification initially exposed fixture regressions; final child run passed 23/23 steps with 198 GPU tests plus cached checks.
- Tag 139: 34/34 steps and 845/845 executions during the final close-publication test assertion update; not frozen-source evidence for that assertion.
- Tag 140: frozen-source serial graph passed 34/34 steps and 684/684 executions, before the subsequent transport failure-boundary audit fixes.
- Independent audit found silently ignored outbound failures and inbound exhaustion; repairs additionally cover publication exhaustion and injected write failure.
- Focused current transport tests passed 8/8, including wrapper tests; full current-source verification remains pending.
- That child's earlier runs also reported configured-remote and rejecting-pre-commit Git fixture failures without diagnostic output; a rerun is not a root-cause fix.
- Earlier intermittent local-bare push/inspection failures remain unproven in cause.
- Tags 141 and 142 each passed 34/34 steps and 1037/1037 overlapping executions; tag 142 includes the bounded inbound-drain guard, but predates subsequent trust-overlay repairs.
- `-j1` did not establish test-process isolation: two test processes were observed under one build parent.
- Tag 143 standalone Debug core failed 1/167: required-clean-filter fixture returned `ChildTimeout` from `execute_revalidated`.
- Tag 144 Linux/macOS compile-only checks passed at that earlier source state; not native acceptance.
- Test-only phase diagnostics subsequently reproduced `phase=execute command=add error=Timeout elapsed_ms=49470`; this identifies the failing subprocess boundary, not the root cause.
- Tag 145 focused retry and all eight tag 146 focused retries passed 3/3 each; these do not fix the preceding failure.
- Pinned `std.process.run` applies relative timeout separately to stream-fill waits, then waits for child exit without that timeout; current Git timeout values do not prove end-to-end deadlines or process-tree teardown.
- Latest trust-overlay repairs additionally cover bounded static text, visible modal controls, hidden-input suppression, palette readiness and worker-state read guards.
- Tag 147 formatting check passed for `src/ui/native.zig` and `src/vcs/record.zig`.
- Tag 148 final-source `build test test-gpu -j1 --summary all` passed 23/23 steps and 542/542 overlapping executions: 167 core, 169 native and 206 GPU tests, with explicit installed-Git opt-in.
- The earlier child GPU invocation exceeded its 180-second tool timeout; tag 148 completed with a five-minute GPU run, resolving that missing result without changing product timeouts.

Counts overlap suites and are not unique cases or full-SPEC acceptance.
No real remote-network or credential tests were run.

## Historical verification

These counts predate the resumed AFK implementation and are not final acceptance for current changes.

Host: `NB-00718`, Windows x64, kernel `10.0.26200`.
Toolchain: Zig `0.17.0` via existing `mise.toml` pin.

| Check | Result |
| :--- | :--- |
| `mise run check` | Passed. |
| `mise run test-output-native` | Passed, including real local-NTFS external-input preflight. |
| `mise run test-git-native` with `WARKOCZ_TEST_GIT_EXE` | Passed, 87 tests including real temporary Git status/history and unborn-history fixtures. |
| `mise run test-gpu -- -Doptimize=Debug` | Passed, 97 tests including injected SDL mouse move/down/up routing, actual DPI-normalized result-byte selection, GUI open→select→edit→undo→redo→Save→async Complete, external output replacement/deletion rejection, stale Save, no-clobber destination, and close-during-pending-Complete coverage. |
| `mise run test-gpu -- -Doptimize=safe` | Passed, same GPU integration suite with ReleaseSafe checks. |
| `mise exec -- zig test src/output.zig -target x86_64-linux-gnu -fno-emit-bin` | Passed compile-only portable rejection path. |
| `mise exec -- zig test src/output.zig -target aarch64-macos -fno-emit-bin` | Passed compile-only portable rejection path. |
| `git diff --check` | Passed. |

Native output fixture is restricted to `C:/Users/okr/AppData/Local/Temp/warkocz-native-e2e`.
The LSP native runner now uses the same `warkocz-native-e2e` temporary-root name.
`mise run test-git-native` requires an explicit absolute `WARKOCZ_TEST_GIT_EXE`; it does not discover or invoke `git` from `PATH`.
On Windows opt-in native output and GPU GUI tasks fail on unsupported/remote filesystems; they do not swallow that condition.
Portable default tests do not run native filesystem publication.

Native save preflight uses only unique files below `C:/Users/okr/AppData/Local/Temp/warkocz-native-e2e`.
It proves unchanged three-way publication, same-length changed input rejection, deleted-input rejection, two-way mode has no fictitious base path, input preservation, and absent destination after preflight failure.
Preflight failures return error identities only; source content is never logged.
GPU GUI E2E injects SDL mouse move/down/up events after clearing startup-only queue residue, maps fixture coordinates through current render/window scale, selects exact ASCII result bytes, then verifies undo/redo, Save receipt, and Complete against exact bytes in a unique local-NTFS file.
Welcome launcher tests cover action metadata, Ctrl+P matching, stable copied dialog-path limits, and picker-pending disabled state; they do not automate or equate to real OS picker interaction.
External replacement/deletion, stale Save, existing-destination rejection, and close-during-pending-Complete scenarios each run in an independently initialized fixture, never conditionally disabled.
It does not claim OS clipboard integration, Unicode/grapheme editing, IME, or full editor parity.

## SPEC coverage

| Contract | Status |
| :--- | :--- |
| Scope/platforms | Native Windows development slice only. Required Windows/Linux/macOS product support unverified. |
| Git workflows | Installed-Git metadata/history, explicit reviewed one-use worktree-status scan, selected-file history/literal search/HEAD blame, authorized whole-file Stage/Unstage/Commit, branch create/rename/safe-delete, configured Fetch/normal Push with bounded sanitized endpoint review. Hunk/line staging, amend/fixup, switching, remote management, stash/tag, merge/rebase/cherry-pick/revert, worktrees/submodules, real-network and credential acceptance remain incomplete. |
| Diff/merge | Bounded exact multi-hunk line merge and source highlighting/navigation in GUI merge sessions; whole-side controls remain. Structural diff/merge and large-input pool policy unimplemented. |
| File fidelity | Supplied byte preservation in bounded paths and Windows new-file primitive only. Metadata/conflict cases unimplemented. |
| Language intelligence | Bounded JSON root-field and Zig named-declaration structural composition; explicit installed-server LSP transport and result-only unsaved synchronization, diagnostics/hover, symbols/definition/references requests. Fake-server native/GPU coverage does not establish real multi-language acceptance. Bounded structured target lists navigate current-result UTF-16 ranges by keyboard/mouse, reject stale versions and disable external targets; multi-file workspace presentation remains incomplete. |
| Interface | Provisional diagnostic SDL UI only. |
| Recovery/cancellation | Windows protected-directory automatic DPAPI journal with bounded worker/coalescing and visible failure state, plus manual export/restore with worker original-hash revalidation. Prior-session discovery, deliberate Forget, asynchronous protected-directory setup and native restore fixtures are implemented. Changed-source reconciliation UI, complete decision-history replay, full retention/crash matrix and measured crash-loss SLA remain incomplete. |
| Trust/privacy | In-memory exact repository/config/operation grants plus revocation primitives exist. UI grants one exact operation after preflight and explicit hook/filter/signing review. Persisted grants and complete hostile-repository isolation remain unimplemented; observation-based validation is not filesystem confinement. |
| Invocation | Explicit local file paths plus explicit `repo --path --git` read-only view. No Git registration or wait-contract validation. |
| Architecture/performance | SDL adopted for slice. No approved application caps, allocation audit, benchmark evidence, or required worker/process architecture. |
| Delivery/acceptance | Core build graph and notices only. No packages, provenance, native platform matrix, or acceptance corpus. |

## Dependency and approval state

Current adopted dependency graph is SDL Zig wrapper `8cc97256dab25e17796b16c48e968eef5d90a5cc`, package hash recorded in `build.zig.zon`.
`THIRD_PARTY.md` records wrapper MIT and SDL zlib notices.
This establishes a pinned current GUI dependency, not full cross-platform packaging/compliance evidence.

| Stack | SPEC direction | Missing before adoption |
| :--- | :--- | :--- |
| Typography/editor | `kb` + FreeType; Zig-owned layout/editing | Exact revisions/hashes, license/notices, redistribution/font coverage, Zig/API/platform compatibility, bounded allocation/failure evidence, proposed integration approval. |
| Structural | Tree-sitter runtime + pinned grammars | Exact runtime/grammar revisions and licenses, generated-artifact provenance, language matrix/fallback fixtures, worker bounds/failure behavior, approval. |
| Git | libgit2 first + installed Git fallback | Exact revision/license, compatibility and mutation-preflight evidence for hooks, filters, signing, credentials, worktrees, fallback policy, approval. |
| Accessibility | AccessKit C backend | Exact revision/license, platform backend/link/package plan, semantic model and bounded incremental-update evidence, approval. |
| Fonts/icons/themes | JetBrains Mono + Nerd Fonts fallback + Nugu mappings | Redistributable font files/licenses/notices, exact version/hash, coverage/fallback and rendering validation, Nugu source/provenance/mapping approval. |
| Shader tooling | Build-time backend-specific artifacts | Selected compiler/version/hash/license, source and artifact provenance, Windows/Linux/macOS backend evidence, no runtime compiler plan, approval. |

Candidates named by SPEC are directions, not adopted approvals.
No new external dependency was adopted.
Native Git mutation, configuration and local transport tests use owned synthetic fixtures only.
No system tool/config changes, cache reset, working-repository commits/pushes/merges/rebases or real remote-network tests were performed.

## Feasible next priorities

1. Complete native non-Windows supervision and cleanup/failure evidence; extend multi-file GUI and real-server acceptance without confusing transport fixtures with product coverage.
2. Add save cancellation/fault-state evidence; investigate identity-bound replacement, alias-safe traversal and directory durability before enabling overwrite.
3. Expand recovery reconciliation, provenance replay and crash-matrix evidence without treating scheduling intervals as loss guarantees.
4. Extend structural movement/reordering within existing supported languages; retain exact unresolved fallback.
5. Establish approved resource/reference protocols and native platform evidence.
6. Obtain exact dependency/font/Nugu mapping approvals before integration; complete packaging/provenance only with honest capability boundaries.


## kb build-time patch wiring (investigation scaffold)

Vendored pristine upstream `kb_text_shape` 2.28g (`7d811ad80215eef6363d60057b0ea140215278a1`) under `third_party/kb/`; the header is embedded at compile time and `tests/kb_verify.zig` applies seventeen exact-context patches from `third_party/kb/patches.zig` into the build cache, failing with a targeted reevaluation message when a patch context disappears, becomes ambiguous, or the golden patched hash drifts.
`zig build check`/`test` gate on it; `zig build kb-check` compile-checks the patched header with `zig cc`; `zig build kb-patch-status` reports per-patch match state for future upstream updates.
Patches cover allocation failure propagation (context creation, arena blocks, config caches, scratchpads, font push) and the GB11 ExtendedPictographic-ZWJ transition; strict UTF-8 validation stays an application boundary.
Evidence: hosted tests (pin, golden hash, markers, missing/ambiguous/hash-drift diagnostics), live tamper/restore drill, Windows x64 fault sweeps in the isolated spike under `C:/Users/okr/AppData/Local/Temp/warkocz-text-accessibility/kb-update/`.
Scaffold only: no product code consumes the patched header yet and this is not dependency adoption.


## FreeType vendored subset wiring (investigation scaffold)

Vendored pristine FreeType `VER-2-14-1` subset (archive SHA-256 `32427e8c…`) under `third_party/freetype/` with the minimal TrueType/SFNT/grayscale configuration from the isolated spike.
`zig build ft-check` compiles the eight translation units into a static library and `tests/freetype_smoke.zig` gates check/test on `FT_Init_FreeType` → version 2.14.1 → `FT_Done_FreeType`.
FTL notices, including the required `docs/FTL.TXT`, are vendored and summarized in `THIRD_PARTY.md`; the tree is `-text` in `.gitattributes` to keep upstream bytes pristine.
Scaffold only: no product code links the library yet and this is not dependency adoption.


## FreeType glyph pipeline (investigation scaffold)

`src/ui/text.zig` rasterizes glyphs from one in-memory face at a fixed pixel size through a bounded caller-owned pool (256 slots, 32x32 cap, monotonic fill; space-like empty bitmaps cache with zero pixels).
`src/ui/native.zig` composes a single-row RGBA atlas and `gpu_text_pipeline_test` (opt-in, gated behind absolute `WARKOCZ_TEST_FONT` and the GPU suite) proves FreeType -> atlas -> GPU texture -> readback determinism and background distinctness.
The FreeType headers are exposed to Zig through a translateC module (`src/ui/freetype_shim.h`), and the app plus native tests link the vendored static library.
The product UI still renders through `SDL_RenderDebugText`; no product text path consumes the pipeline yet, fonts are not bundled, and this is not Unicode-editing or visual acceptance.


## FreeType product text rendering (behind WARKOCZ_FONT)

`debug_text` now routes through `draw_freetype_text`: when absolute `WARKOCZ_FONT` is set, product text draws through the bounded glyph rasterizer with per-glyph SDL textures (renderer-bound cache, drop-on-renderer-change, textures freed by SDL with the renderer) while layout keeps the fixed 8x12 grid; without the variable the SDL debug-font path is unchanged.
GPU suites pass both ways on Windows x64: fallback preserves the pre-existing rendered hashes, and with the font every event/readback fixture stays deterministic through FreeType.
Still open: font bundling decision, per-face advance layout, DPI/zoom integration, Unicode text through this path, and the ASCII diagnostic guardrail itself.
