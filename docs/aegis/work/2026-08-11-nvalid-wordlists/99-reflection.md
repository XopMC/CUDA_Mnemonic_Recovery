# Reflection

The implementation preserved the 2048-word bit-decode fast path and added dynamic base-N decoding only when required. Review caught and repaired one scope drift: subset detection initially considered every embedded dictionary; it now reuses the canonical `bip39_lists` view, excluding CoolWallet and Electrum lists. Local Windows build and GPU validation are complete. Linux/all-SM compilation and GitHub release publication remain external CI steps.
