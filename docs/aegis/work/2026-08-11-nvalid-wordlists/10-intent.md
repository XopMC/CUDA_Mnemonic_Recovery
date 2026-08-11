# Task Intent Draft

- Requested outcome: add `-nvalid`, variable-size wordlists, canonical BIP39 subset mapping, and per-SM v1.1.0 release assets.
- Scope: public CLI, recovery candidate enumeration, CUDA checksum compaction, validation, documentation, and release workflows.
- Non-goals: derivation algorithms, target filters, result format, and changes to v1.0.0.
- Baseline: clean `main` at `1703a363d5a866b816612d6f8f77c02437cb9741`, equal to `origin/main`.
- Compatibility boundary: preserve strict 2048-word behavior, log keys, multi-GPU partitioning, and uint16 candidate IDs.
- Test posture: TDD off; post-change build and deterministic validation required.

## Execution Readiness View

- Intent lock: every wildcard option is tested; checksum filtering is skipped only for explicit or automatic nvalid mode.
- Scope fence: recovery and distribution owners only.
- Baseline lock: no pre-existing task delta.
- Review gates: compile, CLI help, validation scripts, release matrix and artifact inspection.
- Stop conditions: complete, blocked by build/runtime evidence, needs verification, or scope exceeded.
