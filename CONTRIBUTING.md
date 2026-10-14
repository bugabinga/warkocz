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

## Reports

Include a minimal reproduction, expected/actual behavior, tool versions, and OS/display environment.
Remove secrets from logs before posting.
Use [private reporting](SECURITY.md) for vulnerabilities.
