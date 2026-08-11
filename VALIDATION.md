<p align="center">
  <a href="#english"><strong>English</strong></a> |
  <a href="#russian"><strong>Русский</strong></a>
</p>

<a id="english"></a>

# VALIDATION

This document tracks the release-validation surface for `CUDA_Mnemonic_Recovery`.

## Automated CLI Validation

Windows:

```powershell
.\scripts\validate_release.ps1 -Device 2 -MultiDevice 0,2
```

Linux / WSL:

```bash
CMR_DEVICE=2 CMR_MULTI_DEVICE=0,2 ./scripts/validate_release.sh
```

Both scripts accept an explicit executable path if you want to validate a packaged binary instead of a build-tree binary.

## Fixed Validation Fixtures

- Base mnemonic: `adapt access alert human kiwi rough pottery level soon funny burst divorce`
- Base compressed exact hash: `1a4603d1ff9121515d02a6fee37c20829ca522b0`
- Passphrase exact hash (`TREZOR`): `1e398598f50849236bc8a077b184fbce0aa74f4e`
- Solana prefix target for `-d_type 1`: `553ff1f4f34d1c013fd885073a0b6b82f02bb3d0`
- Solana prefix target for default `slip0010-ed25519`: `89dfcdfe8986448bf0ca1f5bc1720de5ad66104c`
- Compressed exact hash for `-d_type 4`: `4fd01a8da7097495668c9ee9499084bc5680199a`

Validation fixtures live in [`examples/validation`](./examples/validation).

File-based recovery inputs are validated in streaming mode. The release path no longer preloads the entire templates file into RAM before processing begins.

## Validation Matrix

| Area | Coverage | Mode |
| --- | --- | --- |
| Public help | `-help` includes public flags and experimental note for `-d_type 4` | automated |
| Inline exact-hash recovery | one-missing-word recovery against the bundled BTC-style fixture | automated |
| File-based recovery | recovery from `examples/validation/templates-file.txt` | automated |
| Streaming mixed sources | inline phrase + file + file, with ordered processing and per-file skip/processed summaries | automated |
| Typo correction | `acces -> access` correction and successful hit | automated |
| `-save` behavior | output file is created and contains address-oriented `Found` lines | automated |
| Passphrase path | exact-hash recovery with `-pass TREZOR` | automated |
| `-d_type 1` | explicit BTC-style derivation for Solana target | automated |
| `-d_type 2` | default ed25519-oriented derivation for Solana target | automated |
| `-d_type 3` | mixed derivation mode with non-default derivation marker in output | automated |
| `-d_type 4` | experimental `ed25519-bip32` path | automated |
| Multi-GPU parity | same fixture reaches the same `Found` count on single-GPU and multi-GPU runs | automated when `MultiDevice` is provided |
| External `-wordlist FILE` | 128-word BIP39 subset, custom auto-`-nvalid`, explicit `-nvalid`, and legacy 2048-word metrics | automated |
| Bloom / XOR / `-xb` / `-xx` | filter-backed validation with external filter assets | manual |
| Phrase lengths `3..48` | broader acceptance sweep for all supported multiples of `3` | manual |

## Notes

- `-d_type 4` is intentionally treated as experimental/test-only coverage. It is validated separately and is not part of the main production-path claims.
- The automated scripts focus on deterministic CLI correctness. They do not replace broader field testing on large real recovery jobs.
- Partial/custom wordlist assertions use the actual option count; only the legacy full dictionary case keeps the fixed `2048/128` expectation.

---

<a id="russian"></a>

# VALIDATION

Этот документ фиксирует release-validation surface для `CUDA_Mnemonic_Recovery`.

## Automated CLI Validation

Windows:

```powershell
.\scripts\validate_release.ps1 -Device 2 -MultiDevice 0,2
```

Linux / WSL:

```bash
CMR_DEVICE=2 CMR_MULTI_DEVICE=0,2 ./scripts/validate_release.sh
```

Оба скрипта принимают и явный путь к бинарнику, если нужно валидировать готовую release-сборку, а не бинарник из build-tree.

## Фиксированные Validation Fixtures

- Базовая мнемоника: `adapt access alert human kiwi rough pottery level soon funny burst divorce`
- Базовый compressed exact hash: `1a4603d1ff9121515d02a6fee37c20829ca522b0`
- Exact hash с passphrase (`TREZOR`): `1e398598f50849236bc8a077b184fbce0aa74f4e`
- Solana prefix target для `-d_type 1`: `553ff1f4f34d1c013fd885073a0b6b82f02bb3d0`
- Solana prefix target для default `slip0010-ed25519`: `89dfcdfe8986448bf0ca1f5bc1720de5ad66104c`
- Compressed exact hash для `-d_type 4`: `4fd01a8da7097495668c9ee9499084bc5680199a`

Validation fixtures лежат в [`examples/validation`](./examples/validation).

Файловый recovery-path валидируется именно в streaming-режиме. Публичная release-логика больше не предзагружает весь templates-файл в ОЗУ до начала обработки.

## Матрица Проверок

| Зона | Покрытие | Режим |
| --- | --- | --- |
| Публичное help-меню | `-help` содержит публичные флаги и experimental note для `-d_type 4` | automated |
| Inline exact-hash recovery | recovery с одним пропущенным словом на bundled BTC-style fixture | automated |
| Recovery из файла | recovery через `examples/validation/templates-file.txt` | automated |
| Streaming mixed sources | inline phrase + file + file, с сохранением порядка обработки и per-file skip/processed summary | automated |
| Исправление опечатки | коррекция `acces -> access` и успешный hit | automated |
| Поведение `-save` | создаётся output-файл и в нём лежат address-oriented `Found` строки | automated |
| Passphrase path | exact-hash recovery с `-pass TREZOR` | automated |
| `-d_type 1` | явная BTC-style derivation для Solana target | automated |
| `-d_type 2` | default ed25519-ориентированная derivation для Solana target | automated |
| `-d_type 3` | mixed derivation mode с маркером non-default derivation в output | automated |
| `-d_type 4` | experimental `ed25519-bip32` path | automated |
| Multi-GPU parity | один и тот же fixture даёт одинаковый `Found` на single-GPU и multi-GPU | automated, если передан `MultiDevice` |
| Внешний `-wordlist FILE` | 128-word BIP39 subset, custom auto-`-nvalid`, явный `-nvalid` и прежние метрики 2048-word режима | automated |
| Bloom / XOR / `-xb` / `-xx` | filter-backed validation с внешними filter-assets | manual |
| Длины фраз `3..48` | более широкий acceptance-sweep по всем поддерживаемым кратным `3` | manual |

## Примечания

- `-d_type 4` специально остаётся в отдельном experimental/test-only контуре. Он валидируется отдельно и не входит в основные production-claims.
- Automated-скрипты сфокусированы на deterministic CLI correctness. Они не заменяют более широкие полевые проверки на длинных реальных recovery-задачах.
- Для partial/custom wordlist проверки используют фактическое число опций; фиксированное ожидание `2048/128` остаётся только для legacy full-dictionary кейса.
