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
