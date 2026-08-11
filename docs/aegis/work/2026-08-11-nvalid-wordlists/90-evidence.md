# Evidence Bundle Draft

- `cmake --build --preset windows-release --config Release -- /m:1`: exit 0, Windows `sm_89` CUDA release binary linked.
- `scripts/validate_release.ps1 -Device 0`: exit 0 on RTX 4090, including all legacy release cases.
- Standard EN subset: `tested=128 checksum-valid=8` with checksum enabled.
- Custom and mixed lists: automatic `-nvalid`, `tested=3 checksum-valid=3`.
- Explicit `-nvalid`: `tested=2048 checksum-valid=2048`.
- Custom 2049-word list: `tested=2049 checksum-valid=2049` without 11-bit ID wrap.
- Loader boundaries: 65,535 accepted; 65,536, empty, duplicate, and 34-byte word rejected.
- Fixed invalid phrase: strict `1/0`, explicit `-nvalid` `1/1`.
- Six-wildcard mixed-radix split: mapped BIP39 subset and custom `-nvalid` both tested all `3^6=729` combinations.
- Legacy strict path: `tested=2048 checksum-valid=128`, found fixture unchanged.
- `git diff --check`: exit 0 before final closeout.

Uncovered scope: Linux and the complete GitHub SM matrix require CI runners; release publication requires push, PR merge, and tag authorization.

## Release workflow failure and fix (2026-08-12)

- Failed run: 31528663594.
- Observed error: /bin/sh: set: Illegal option -o pipefail.
- Root cause: the Linux Package step ran under the container default /bin/sh despite using Bash-only pipefail.
- Fix: set shell: bash, derive archive names from RELEASE_VERSION, and permit workflow_dispatch with release_tag.
- Recovery command: gh workflow run release-bundles.yml --ref main -f release_tag=v1.1.0.
