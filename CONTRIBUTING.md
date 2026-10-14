# Contributing

warkocz is at the bootstrap stage.
The [specification](SPEC.html) defines the intended product, not current capabilities.

## Before changing code

- Read the relevant contract section and [agent/development guidance](AGENTS.md).
- Discuss architectural or dependency changes in an issue or discussion before broad implementation.
- Keep changes focused; distinguish implemented behavior from investigation candidates.
- Use the development tasks documented in [README.md](README.md#development).

## Pull requests

Explain the problem, the change, and the evidence.
Run the relevant checks and report what passed, failed, or remains untested.
Use synthetic repositories for mutation tests; never include credentials, private source, decrypted files, or personal repository contents.
Screenshots can demonstrate appearance, not mutation correctness or performance.

## Commit and history policy

### Commits

- Keep each commit focused on one logical change; include its tests and necessary documentation.
- Separate unrelated cleanup, formatting, and dependency updates.
- Use imperative subjects of at most 72 characters, without a trailing period.
- Explain non-obvious rationale and compatibility consequences in the body; reference relevant issues.
- Inspect the staged diff and run relevant checks before committing.
- Never stage unrelated user changes, secrets, generated build outputs, or machine-local configuration.
- Commit, push, publish, or merge only when explicitly requested; permission for one action does not imply the others.

### Linear history

- Work on short-lived topic branches from current main.
- Integrate through squash-merged pull requests; no direct pushes or merge commits on main.
- Keep the resulting squash commit coherent and validated; use its title and body to describe the complete change.
- Rebase topic branches onto current main instead of merging main into them; rerun affected checks after rebasing.
- Never rewrite published main or published release tags; undo mistakes with new revert or corrective commits.
- Rewrite a published topic branch only with explicit approval and collaborator coordination.
- When an approved rewrite requires pushing, use force-with-lease pinned to the reviewed remote commit; never use plain force.
- Do not bypass required checks or branch protections.

## Reports

Include a minimal reproduction, expected/actual behavior, tool versions, and OS/display environment.
Remove secrets from logs before posting.
Use [private reporting](SECURITY.md) for vulnerabilities.
