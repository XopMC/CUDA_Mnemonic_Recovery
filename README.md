<p align="center">
  <a href="#english"><strong>English</strong></a> |
  <a href="#russian"><strong>Русский</strong></a>
</p>

<a id="english"></a>
<p align="center">
  <img src="./docs/media/hero.svg" alt="CUDA_Mnemonic_Recovery hero" width="820">
</p>

<p align="center">
  <img alt="Platform" src="https://img.shields.io/badge/platform-Windows%20%7C%20Linux-0f172a?style=for-the-badge">
  <img alt="CUDA" src="https://img.shields.io/badge/CUDA-ready-0ea5e9?style=for-the-badge">
  <img alt="Focus" src="https://img.shields.io/badge/focus-BIP39%20Recovery-22c55e?style=for-the-badge">
  <img alt="Targets" src="https://img.shields.io/badge/targets-BTC%20%7C%20ETH%20%7C%20SOL%20%7C%20TON-f59e0b?style=for-the-badge">
</p>

# CUDA_Mnemonic_Recovery

Author: Mikhail Khoroshavin aka "XopMC"

`CUDA_Mnemonic_Recovery` is a focused CUDA tool for one very specific job: recover incomplete BIP39 mnemonic phrases quickly, validate them against real targets, and keep the workflow clear enough to trust in a real recovery session.

It is built for practical recovery work: real wildcard templates, real derivation lists, real filters, real multi-GPU runs, and output that stays easy to read when a long session is finally producing hits.

## Why This Tool Exists

- You have a real mnemonic backup with missing words marked as `*`.
- You want to validate candidates against exact hashes, Bloom filters, or XOR filters instead of scrolling through noise.
- You want one tool that can check Bitcoin, Ethereum, Solana, and TON-oriented targets from the same recovery flow.
- You want multi-GPU support in a focused, easy-to-follow recovery workflow.

## Visual Tour

### Command Help

<p>
  <img src="./docs/media/help-terminal.svg" alt="Command help screenshot" width="880">
</p>

### Single-GPU Recovery

<p>
  <img src="./docs/media/single-recovery.svg" alt="Single GPU recovery example" width="880">
</p>

### Multi-GPU Recovery

<p>
  <img src="./docs/media/multigpu-recovery.svg" alt="Multi GPU recovery example" width="880">
</p>

### Recovery Flow

<p>
  <img src="./docs/media/recovery-flow-diagram.svg" alt="Recovery flow diagram" width="880">
</p>

### Multi-GPU Work Split

<p>
  <img src="./docs/media/multigpu-diagram.svg" alt="Multi GPU work split diagram" width="880">
</p>

## Highlights

- Recover missing BIP39 words with `*` wildcards.
- Work with mnemonic lengths from `3` to `48` words, as long as the phrase length is a multiple of `3`.
- Use embedded BIP39 wordlists or force an external `-wordlist FILE`.
- Auto-pick the matching BIP39 language wordlist and correct common word-entry typos when the intended word is clear.
- Feed templates inline or from files.
- Process file-based recovery inputs in true streaming mode, one line at a time, without preloading the whole template file into RAM.
- Check candidates against exact `-hash`, Bloom filters, XOR filters, and optional CPU-side verification.
- Build XOR filters with [XorFilter](https://github.com/XopMC/XorFilter) and plug them straight into the recovery flow.
- Select Bitcoin-like, Ethereum, Solana, and TON target families with one CLI.
- Override derivation routing with `-d_type` when wallet behavior does not match the usual coin-native path.
- Run one GPU or several GPUs with the same recovery workflow.
- Keep save/output compact, readable, and practical for long recovery sessions.

## Supported Target Families

`-c` selects which target families are derived and checked.

| Letter | Family | Typical output |
| --- | --- | --- |
| `c` | Compressed | Bitcoin compressed address / hash160 |
| `u` | Uncompressed | Legacy uncompressed address / hash160 |
| `s` | SegWit | P2SH-wrapped SegWit style output |
| `r` | Taproot | Bech32m taproot output |
| `x` | XPoint | X-only/public point style match |
| `e` | Ethereum | Ethereum address / hash |
| `S` | Solana | Solana public address / raw target |
| `t` | TON | Core TON wallet sweep |
| `T` | TON-all | Extended TON wallet sweep |

Any `-c` letters outside this set are rejected in the public release.

## Build

### Windows with CMake

```powershell
cmake --preset windows-release
cmake --build --preset windows-release --config Release
```

### Windows with Visual Studio

```powershell
msbuild CUDA_Mnemonic_Recovery.sln /p:Configuration=Release /p:Platform=x64
```

### Linux / WSL

```bash
make configure
make build
```

### Force a local `sm_89` build

```powershell
cmake --preset windows-release -D CMAKE_CUDA_ARCHITECTURES=89
cmake --build --preset windows-release --config Release
```

## Prebuilt GitHub Bundles

GitHub Actions is set up to produce two distribution archives:

- `CUDA_Mnemonic_Recovery-windows-builds.zip`
- `CUDA_Mnemonic_Recovery-linux-builds.tar.gz`

The Linux archive contains these build profiles:

| Profile | Intended cards | Notes |
| --- | --- | --- |
| `sm_61-dlto` | GTX 10xx / Pascal | Dedicated legacy-friendly Linux build |
| `sm_75-dlto` | RTX 20xx / Turing | Best fit for RTX 20xx on Linux |
| `sm_86-dlto` | RTX 30xx / Ampere | Dedicated Ampere Linux build |
| `sm_89-dlto` | RTX 40xx / Ada | Dedicated Ada Linux build |
| `sm_120-dlto` | RTX 50xx / Blackwell | Dedicated Blackwell Linux build |
| `universal-sm_86-sm_120` | RTX 30xx / 40xx / 50xx | One Linux binary for modern cards from `sm_86` through `sm_120` |

The Windows archive contains these build profiles:

| Profile | Intended cards | Notes |
| --- | --- | --- |
| `sm_61` | GTX 10xx / Pascal | Dedicated legacy-friendly Windows build |
| `sm_75` | RTX 20xx / Turing | Best fit for RTX 20xx on Windows |
| `sm_86` | RTX 30xx / Ampere | Dedicated Ampere Windows build |
| `sm_89` | RTX 40xx / Ada | Dedicated Ada Windows build |
| `sm_120` | RTX 50xx / Blackwell | Dedicated Blackwell Windows build |
| `universal-sm_86-sm_120` | RTX 30xx / 40xx / 50xx | One Windows binary for modern cards from `sm_86` through `sm_120` |

Release assets are built with CUDA `12.8` and published as separate archives for every OS/SM profile, plus `SHA256SUMS.txt`. Pick a dedicated build when you want the best match for one GPU generation, or choose `universal-sm_86-sm_120` when you want one binary for RTX `30xx` through `50xx`. RTX `20xx` remains on the dedicated `sm_75` build.

The packaged binaries are intended to be easy to move between machines. A compatible NVIDIA driver is still required on the target machine.

## Publication Notes

- Reproducible benchmark methodology and measured results: [`BENCHMARKS.md`](./BENCHMARKS.md)
- Validation coverage and release smoke matrix: [`VALIDATION.md`](./VALIDATION.md)
- Release checklist for clean-room packaging: [`RELEASE_CHECKLIST.md`](./RELEASE_CHECKLIST.md)
- Citation metadata for public and technical references: [`CITATION.cff`](./CITATION.cff)
- High-level release history: [`CHANGELOG.md`](./CHANGELOG.md)

## Quick Start

The first commands below all use the same bundled exact-hash fixture, so you can reproduce the run as-is on this repository.

### Recover one missing word from the command line

```bash
CUDA_Mnemonic_Recovery -device 2 -recovery "adapt access alert human kiwi rough pottery level soon funny burst *" -d examples/derivations/default.txt -c c -hash 1a4603d1ff9121515d02a6fee37c20829ca522b0
```

### Recover from a file with template lines

```bash
CUDA_Mnemonic_Recovery -device 2 -recovery -i examples/templates.txt -d examples/derivations/default.txt -c c -hash 1a4603d1ff9121515d02a6fee37c20829ca522b0
```

### Validate against a real exact hash

```bash
CUDA_Mnemonic_Recovery -device 2 -recovery "* * alert human kiwi rough pottery level * funny burst divorce" -d examples/derivations/default.txt -c c -hash 1a4603d1ff9121515d02a6fee37c20829ca522b0
```

### Recover with an XOR filter

```bash
CUDA_Mnemonic_Recovery -recovery -i examples/templates.txt -d examples/derivations/default.txt -xc wallet.xor_c -xx wallet.xor_u -c cus
```

### Recover with passphrases from a file

```bash
CUDA_Mnemonic_Recovery -recovery -i examples/templates.txt -d examples/derivations/default.txt -pass examples/passphrases.txt -c e
```

### Check Solana through BTC-style derivation rules

```bash
CUDA_Mnemonic_Recovery -recovery -i examples/templates.txt -d examples/derivations/default.txt -c S -d_type 1
```

## File Input Formats

### Recovery templates file

Each line is one mnemonic template. Missing words are written as `*`.

Example: [`examples/templates.txt`](./examples/templates.txt)

```text
adapt access alert human kiwi rough pottery level soon funny burst *
adapt access alert human kiwi rough pottery level soon funny * *
```

Rules:

- one template per line
- use spaces between words
- use `*` for every unknown word
- keep the line as a normal mnemonic phrase, only with missing positions replaced
- valid phrase lengths are `3..48` words and must stay divisible by `3`
- the tool auto-detects the matching BIP39 language wordlist
- the parser can correct common typos when the intended BIP39 word is obvious
- file inputs are processed in streaming mode: one line is prepared, checked, and finished before the next line is read
- large template files are not preloaded into RAM before recovery starts

### Derivations file

Each line is one derivation path.

Example: [`examples/derivations/default.txt`](./examples/derivations/default.txt)

```text
m/44'/0'/0'/0/0
m/49'/0'/0'/0/0
m/84'/0'/0'/0/0
m/86'/0'/0'/0/0
m/44'/60'/0'/0/0
m/44'/501'/0'/0'
m/44'/607'/0'/0/0
```

### Passphrase file

Each line is one passphrase candidate.

Example: [`examples/passphrases.txt`](./examples/passphrases.txt)

```text
TREZOR
wallet-passphrase-example
```

## Command Line Reference

### Recovery sources

| Option | Meaning | Notes |
| --- | --- | --- |
| `-recovery "..."` | Add one template inline | Repeatable |
| `-recovery -i FILE` | Load templates from file | Repeatable; processed line by line in streaming mode |
| `-wordlist FILE` | Restrict wildcard candidates to words from a file | Accepts 1..65,535 unique words |
| `-nvalid` | Include checksum-invalid combinations | Explicitly disables BIP39 checksum filtering |
| `-d FILE` | Load derivation paths from file | Required |

An external list with exactly 2048 words keeps the traditional ordered BIP39 checksum behavior. For any other size, the tool checks whether every word belongs to exactly one embedded BIP39 dictionary. An unambiguous standard subset keeps checksum filtering and maps each file entry to its canonical BIP39 ID; custom, mixed-language, or ambiguous lists enable `-nvalid` automatically. Explicit `-nvalid` always takes priority. Empty lists, duplicates, words longer than 33 bytes, and lists above 65,535 words are rejected.

### Targets and derivation routing

| Option | Meaning |
| --- | --- |
| `-c TYPES` | Target family selection. Default: `cus` |
| `-d_type <1/2/3/4>` | Force derivation engine: `1=bip32-secp256k1`, `2=slip0010-ed25519`, `3=check both`, `4=ed25519-bip32 (experimental)` |

If `-d_type` is omitted, the tool uses the usual derivation style for the selected target family:

- Bitcoin-like and Ethereum targets use the usual BIP32/secp256k1 path
- Solana and TON use their usual ed25519-oriented derivation style
- `-c` still controls the target family that is generated and checked, even when `-d_type` overrides the derivation engine
- `-d_type 4` is available only when requested explicitly and is never included in mixed mode
- Live status shows both `candidates/s` and `hashes/s`; hash throughput grows with derivation count, selected targets, and derivation policy

### Experimental `-d_type 4`

`-d_type 4` keeps the `ed25519-bip32` path available for evaluation work.

- It is opt-in only.
- It is not part of `-d_type 3`.
- It is not part of the main production-path claims in this README.
- Validation coverage for this mode is tracked separately in [`VALIDATION.md`](./VALIDATION.md).

### Filters and direct targets

| Option | Meaning |
| --- | --- |
| `-hash HEX` | Match an exact target hash or raw target prefix in hex |
| `-bf FILE` | Load a Bloom filter. Repeatable |
| `-xu FILE` | Load `.xor_u`, the uncompressed XOR filter format. Repeatable |
| `-xc FILE` | Load `.xor_c`, a compact GPU-side XOR prefilter. Repeatable |
| `-xuc FILE` | Load `.xor_uc`, an even smaller GPU-side XOR prefilter. Repeatable |
| `-xh FILE` | Load `.xor_hc`, the smallest GPU-side XOR prefilter. Repeatable |
| `-xx FILE` | CPU verify using an uncompressed `.xor_u` filter |
| `-xb FILE` | CPU verify with Bloom filter |

`-hash` is a hex input. For classic hash160-based families you usually provide the full 20-byte value. For raw 32-byte targets, the tool consumes a hex prefix, so you typically pass the leading bytes of the raw value.

Target-oriented `-hash` guidance:

- `-c c`, `-c u`, `-c s`, `-c r` expect Bitcoin-style `hash160` in hex.
- `-c x` expects the leading bytes of the raw x-only public key in hex, without `02`, `03`, or `04`.
- `-c e` expects the Ethereum address in hex, without `0x`.
- `-c S` expects the leading bytes of the raw ed25519 public key in hex, which means the Solana address must be decoded from base58 first.
- `-c t` and `-c T` expect the leading bytes of the raw TON account hash in hex, without the `<workchain:>` prefix.

Practical BTC-style exact hash example:

```bash
CUDA_Mnemonic_Recovery -device 2 -recovery "adapt access alert human kiwi rough pottery level soon funny burst *" -d examples/derivations/default.txt -c c -hash 1a4603d1ff9121515d02a6fee37c20829ca522b0
```

### Bloom filters

`CUDA_Mnemonic_Recovery` accepts Bloom filters compatible with the formats used by [brainflayer](https://github.com/ryancdotorg/brainflayer) and [Mnemonic_CPP](https://github.com/XopMC/Mnemonic_CPP).

You can add several Bloom filters by repeating `-bf`:

```bash
CUDA_Mnemonic_Recovery -recovery -i examples/templates.txt -d examples/derivations/default.txt -bf wallet_a.blf -bf wallet_b.blf -c c
```

## XOR Filters and XorFilter

If you want XOR filters for this project, generate them with [XorFilter](https://github.com/XopMC/XorFilter).

Recommended workflow:

- `.xor_u` is the only XOR format recommended for a full standalone run without extra CPU confirmation.
- `.xor_c`, `.xor_uc`, and `.xor_hc` are compact GPU prefilters. They are excellent for reducing memory and accelerating broad scans, but they should not be treated as the final truth in a full recovery session.
- For `.xor_c`, `.xor_uc`, and `.xor_hc`, add `-xx wallet.xor_u` so the survivors are rechecked on the CPU against an uncompressed `.xor_u` filter.
- You can load several XOR filters of the same family by repeating the corresponding flag.

Practical example:

```bash
CUDA_Mnemonic_Recovery -recovery -i examples/templates.txt -d examples/derivations/default.txt -xc wallet.xor_c -xx wallet.xor_u -c cus
```

Multi-filter example:

```bash
CUDA_Mnemonic_Recovery -recovery -i examples/templates.txt -d examples/derivations/default.txt -xc wallet_a.xor_c -xc wallet_b.xor_c -xx wallet_master.xor_u -c cus
```

That pattern gives you a compact GPU filter on the front end and a precise CPU re-check on the back end.

### Runtime and output

| Option | Meaning |
| --- | --- |
| `-pbkdf N` | Override PBKDF2 iteration count. Default: `2048` |
| `-pass VALUE\|FILE` | Use one passphrase string or a passphrase file |
| `-device LIST` | Use one or more GPUs, for example `2`, `2,3`, `0-3` |
| `-b N` | Force CUDA blocks |
| `-t N` | Force CUDA threads per block |
| `-fsize N` | Found-buffer capacity |
| `-o FILE` | Output file. Default: `result.txt` |
| `-save` | Save address-oriented output instead of raw match hash |
| `-silent` | Suppress console hit printing |
| `-h`, `-help` | Show public help |

## Understanding `-save`

The tool keeps compact colon-separated `Found` lines.

Without `-save`, the last field is the raw matched hash/target bytes:

```text
[!] Found: <mnemonic>:<derivation>:<private_key_hex>:COMPRESSED:<matched_hash>
```

With `-save`, the last field becomes the address-oriented output instead:

```text
[!] Found: <mnemonic>:<derivation>:<private_key_hex>:COMPRESSED:<address>
```

What stays the same:

- the private key is still written
- the derivation path is still written
- the coin/type label is still written

What changes:

- raw hash output becomes address-oriented output
- compressed Bitcoin emits an additional `P2WPKH` line

Examples:

```text
[!] Found: ...:COMPRESSED:1LqBGSKuX5yYUonjxT5qGfpUsXKYYWeabA
[!] Found: ...:P2WPKH:bc1qmxrw6qdh5g3ztfcwm0et5l8mvws4eva24kmp8m
[!] Found: ...:ETH:0x9858effd232b4033e47d90003d41ec34ecaeda94
[!] Found: ...:SOLANA:EHqmfkN89RJ7Y33CXM6uCzhVeuywHoJXZZLszBHHZy7o
```

In mixed derivation runs, non-default derivation engines are annotated next to the derivation path, not in the coin label:

```text
[!] Found: ...:(bip32-secp256k1) m/44'/501'/0'/0':<private_key>:SOLANA:<value>
```

## Multi-GPU

Multi-GPU mode is enabled through `-device LIST`.

Examples:

```bash
CUDA_Mnemonic_Recovery -device 2,3 -recovery -i examples/templates.txt -d examples/derivations/default.txt -c c
CUDA_Mnemonic_Recovery -device 0-3 -recovery -i examples/templates.txt -d examples/derivations/default.txt -c cusrxeStT
```

What the tool does in multi-GPU mode:

- initializes one active worker context per selected GPU
- splits the recovery workload across devices
- keeps per-device accounting
- aggregates final tested / checksum-valid totals
- keeps async save workers alive until the end of the run

### Benchmark summary

Full methodology, fixture details, run conditions, and stress-case notes live in [`BENCHMARKS.md`](./BENCHMARKS.md).

Short local summary from the current benchmark set:

| GPUs | Devices | Workload | Time to first hit |
| --- | --- | --- | --- |
| `1` | `2` | `1 template`, `3 missing words`, exact hash | `550.07 s` |
| `2` | `0,2` | same | `211.58 s` |
| `4` | `0,1,2,3` | same | `41.59 s` |

Stress-case summary:

- `1 GPU`, device `2`, `4 missing words`, `10 minute` limit: no hit within `600.37 s`
- `4 GPU`, devices `0,1,2,3`, same stress fixture: first hit in `15.75 s`

For the exact commands, fixture files, hardware notes, repeated-run policy, and measurement boundaries, see [`BENCHMARKS.md`](./BENCHMARKS.md).

## Troubleshooting

### The tool says `-d FILE is required`

That is expected. Public documentation assumes explicit derivation files for recovery runs.

### I want to recover from a file instead of typing the phrase

Use:

```bash
CUDA_Mnemonic_Recovery -recovery -i examples/templates.txt -d examples/derivations/default.txt
```

### My wallet uses unusual derivation logic

Try `-d_type`:

- `-d_type 1` for forced BIP32/secp256k1
- `-d_type 2` for forced SLIP-0010 ed25519
- `-d_type 3` to try both
- `-d_type 4` for experimental `ed25519-bip32` checks only

### `-save` does not show the raw hash anymore

That is by design. `-save` switches the last field to address-oriented output.

### Can I use several GPUs?

Yes. Use `-device LIST`, for example:

```bash
-device 2,3
-device 0-3
```

## Repository Layout

- `src/app/` entry point, CLI, config
- `src/recovery/` recovery flow and host-side orchestration
- `src/crypto/` mnemonic, TON, filters, hashes
- `src/cuda/` CUDA recovery workers and device control
- `include/` project headers
- `support/` shared host utilities
- `third_party/` bundled crypto and PBKDF2 code
- `assets/wordlists/` source BIP39 wordlists
- `examples/` ready-to-run sample inputs
- `scripts/` local validation helpers
- `docs/media/` README visuals and social preview assets

## Responsible Use

This project is intended only for legitimate recovery of wallets, backups, and seed phrases that belong to you or that you are explicitly authorized to recover.

The author strongly discourages any malicious use of this software. Any unlawful or abusive use is entirely the responsibility of the user. See [`RESPONSIBLE_USE.md`](./RESPONSIBLE_USE.md) for the short lawful-use policy and [`SECURITY.md`](./SECURITY.md) for private vulnerability reporting guidance.

## Support The Project

If you want to support further development, donation addresses and contact details are collected in [`SUPPORT.md`](./SUPPORT.md).

## Custom Development

I build custom software on request. If you want changes, extensions, or project-specific adaptations for `CUDA_Mnemonic_Recovery`, you can discuss them with me on Telegram:

- https://t.me/xopmc

This public release is also an example of the kind of performance-oriented software and recovery tooling I can design and implement.

---

<a id="russian"></a>

## Русский

Автор: Mikhail Khoroshavin aka "XopMC"

`CUDA_Mnemonic_Recovery` — это узкоспециализированный CUDA-инструмент для одной конкретной задачи: восстановления неполных BIP39 mnemonic-фраз с реальной проверкой кандидатов по нужным целям.

Он рассчитан на практическую работу: реальные wildcard-шаблоны, реальные derivation-path’ы, реальные фильтры, реальные MultiGPU-запуски и вывод, который остаётся удобным даже в длинной сессии восстановления.

## Для Чего Этот Проект

- У вас есть реальная BIP39-фраза, где часть слов потеряна и заменена на `*`.
- Вы хотите проверять кандидатов не вручную, а по реальному `-hash`, Bloom/XOR-фильтрам или CPU verify.
- Вам нужен один recovery flow для Bitcoin, Ethereum, Solana и TON.
- Вам нужна MultiGPU-поддержка в понятном и сфокусированном recovery workflow.

## Визуальный Обзор

### Меню Помощи

<p>
  <img src="./docs/media/help-terminal.svg" alt="Скриншот help" width="920">
</p>

### Обычный Recovery Запуск

<p>
  <img src="./docs/media/single-recovery.svg" alt="Скриншот single GPU recovery" width="920">
</p>

### Multi-GPU Recovery

<p>
  <img src="./docs/media/multigpu-recovery.svg" alt="Скриншот multi GPU recovery" width="920">
</p>

### Схема Recovery Flow

<p>
  <img src="./docs/media/recovery-flow-diagram.svg" alt="Схема recovery flow" width="920">
</p>

### Схема Multi-GPU Разделения Нагрузки

<p>
  <img src="./docs/media/multigpu-diagram.svg" alt="Схема multi GPU split" width="920">
</p>

## Что Умеет Проект

- Восстанавливать BIP39-фразы с пропущенными словами `*`.
- Работать с фразами длиной от `3` до `48` слов, если общее число слов кратно `3`.
- Использовать встроенные словари BIP39 или внешний `-wordlist FILE`.
- Автоматически подбирать подходящий языковой BIP39-словарь и исправлять типичные опечатки в словах, когда нужное слово определяется однозначно.
- Принимать шаблоны как из командной строки, так и из файлов.
- Обрабатывать recovery-файлы в настоящем streaming-режиме: по одной строке, без предварительной загрузки всего файла в ОЗУ.
- Проверять кандидатов по `-hash`, Bloom-фильтрам, XOR-фильтрам и optional CPU verify.
- Создавать XOR-фильтры с помощью [XorFilter](https://github.com/XopMC/XorFilter) и сразу использовать их в recovery flow.
- Работать с target-семействами Bitcoin-like, Ethereum, Solana и TON.
- Переопределять тип derivation через `-d_type`, если кошелёк использует не стандартную схему.
- Работать на одной GPU или сразу на нескольких.
- Получать компактный и практичный `Found` вывод, удобный для длинных recovery-сессий.

## Поддерживаемые Target Families

`-c` задаёт, какие именно целевые семейства нужно строить и проверять.

| Буква | Семейство | Что обычно получается |
| --- | --- | --- |
| `c` | Compressed | Bitcoin compressed address / hash160 |
| `u` | Uncompressed | Legacy uncompressed address / hash160 |
| `s` | SegWit | P2SH-wrapped SegWit style output |
| `r` | Taproot | Bech32m taproot output |
| `x` | XPoint | X-only/public point style match |
| `e` | Ethereum | Ethereum address / hash |
| `S` | Solana | Solana public address / raw target |
| `t` | TON | Базовый sweep по TON |
| `T` | TON-all | Расширенный sweep по TON |

Любые другие буквы в `-c` в публичной версии отвергаются.

## Сборка

### Windows через CMake

```powershell
cmake --preset windows-release
cmake --build --preset windows-release --config Release
```

### Windows через Visual Studio

```powershell
msbuild CUDA_Mnemonic_Recovery.sln /p:Configuration=Release /p:Platform=x64
```

### Linux / WSL

```bash
make configure
make build
```

### Локальная сборка только под `sm_89`

```powershell
cmake --preset windows-release -D CMAKE_CUDA_ARCHITECTURES=89
cmake --build --preset windows-release --config Release
```

## Готовые GitHub-Сборки

GitHub Actions подготавливает два дистрибутивных архива:

- `CUDA_Mnemonic_Recovery-windows-builds.zip`
- `CUDA_Mnemonic_Recovery-linux-builds.tar.gz`

В Linux-архиве лежат такие профили:

| Профиль | Для каких карт | Примечание |
| --- | --- | --- |
| `sm_61-dlto` | GTX 10xx / Pascal | Отдельная Linux-сборка для Pascal |
| `sm_75-dlto` | RTX 20xx / Turing | Лучший выбор для RTX 20xx под Linux |
| `sm_86-dlto` | RTX 30xx / Ampere | Отдельная Linux-сборка под Ampere |
| `sm_89-dlto` | RTX 40xx / Ada | Отдельная Linux-сборка под Ada |
| `sm_120-dlto` | RTX 50xx / Blackwell | Отдельная Linux-сборка под Blackwell |
| `universal-sm_86-sm_120` | RTX 30xx / 40xx / 50xx | Один Linux-бинарник для `sm_86`...`sm_120` |

В Windows-архиве лежат такие профили:

| Профиль | Для каких карт | Примечание |
| --- | --- | --- |
| `sm_61` | GTX 10xx / Pascal | Отдельная Windows-сборка для Pascal |
| `sm_75` | RTX 20xx / Turing | Лучший выбор для RTX 20xx под Windows |
| `sm_86` | RTX 30xx / Ampere | Отдельная Windows-сборка под Ampere |
| `sm_89` | RTX 40xx / Ada | Отдельная Windows-сборка под Ada |
| `sm_120` | RTX 50xx / Blackwell | Отдельная Windows-сборка под Blackwell |
| `universal-sm_86-sm_120` | RTX 30xx / 40xx / 50xx | Один Windows-бинарник для `sm_86`...`sm_120` |

Release-сборки делаются на CUDA `12.8` и публикуются отдельными архивами для каждого OS/SM-профиля вместе с `SHA256SUMS.txt`. Если нужен максимально подходящий вариант под одно поколение GPU, берите dedicated-профиль. Если нужен один бинарник для современных карт, выбирайте `universal-sm_86-sm_120` для RTX `30xx`...`50xx`. Для RTX `20xx` остаётся отдельный профиль `sm_75`.

Пакеты подготовлены так, чтобы их было удобно переносить между машинами. Совместимый NVIDIA driver на целевой машине всё равно обязателен.

## Publication Notes

- Воспроизводимая benchmark-методика и measured results: [`BENCHMARKS.md`](./BENCHMARKS.md)
- Validation coverage и release smoke matrix: [`VALIDATION.md`](./VALIDATION.md)
- Release checklist для clean-room packaging: [`RELEASE_CHECKLIST.md`](./RELEASE_CHECKLIST.md)
- Citation metadata для публичных и технических ссылок: [`CITATION.cff`](./CITATION.cff)
- Краткая release history: [`CHANGELOG.md`](./CHANGELOG.md)

## Быстрый Старт

Первые команды ниже используют один и тот же exact-hash fixture из репозитория, так что их можно воспроизвести как есть.

### Восстановление одного пропущенного слова из командной строки

```bash
CUDA_Mnemonic_Recovery -device 2 -recovery "adapt access alert human kiwi rough pottery level soon funny burst *" -d examples/derivations/default.txt -c c -hash 1a4603d1ff9121515d02a6fee37c20829ca522b0
```

### Восстановление из файла с шаблонами

```bash
CUDA_Mnemonic_Recovery -device 2 -recovery -i examples/templates.txt -d examples/derivations/default.txt -c c -hash 1a4603d1ff9121515d02a6fee37c20829ca522b0
```

### Проверка по реальному точному hash target

```bash
CUDA_Mnemonic_Recovery -device 2 -recovery "* * alert human kiwi rough pottery level * funny burst divorce" -d examples/derivations/default.txt -c c -hash 1a4603d1ff9121515d02a6fee37c20829ca522b0
```

### Проверка через XOR filter

```bash
CUDA_Mnemonic_Recovery -recovery -i examples/templates.txt -d examples/derivations/default.txt -xc wallet.xor_c -xx wallet.xor_u -c cus
```

### Recovery с passphrase из файла

```bash
CUDA_Mnemonic_Recovery -recovery -i examples/templates.txt -d examples/derivations/default.txt -pass examples/passphrases.txt -c e
```

### Проверка Solana через BTC-style derivation

```bash
CUDA_Mnemonic_Recovery -recovery -i examples/templates.txt -d examples/derivations/default.txt -c S -d_type 1
```

## Форматы Входных Файлов

### Файл шаблонов восстановления

Каждая строка — это один mnemonic-шаблон. Пропущенные слова помечаются как `*`.

Пример: [`examples/templates.txt`](./examples/templates.txt)

```text
adapt access alert human kiwi rough pottery level soon funny burst *
adapt access alert human kiwi rough pottery level soon funny * *
```

Правила:

- одна фраза на строку
- слова разделяются пробелами
- каждый неизвестный слот — это отдельный `*`
- строка должна выглядеть как обычная mnemonic-фраза, только с заменой неизвестных слов на `*`
- допустимая длина фразы — от `3` до `48` слов, при этом число слов должно быть кратно `3`
- инструмент автоматически подбирает подходящий языковой BIP39-словарь
- парсер умеет исправлять типичные опечатки, если нужное слово определяется однозначно
- file input обрабатывается в streaming-режиме: сначала завершается текущая строка, и только потом читается следующая
- большие файлы с шаблонами не предзагружаются целиком в ОЗУ до старта recovery

### Файл derivation-path’ов

Каждая строка — это один derivation path.

Пример: [`examples/derivations/default.txt`](./examples/derivations/default.txt)

```text
m/44'/0'/0'/0/0
m/49'/0'/0'/0/0
m/84'/0'/0'/0/0
m/86'/0'/0'/0/0
m/44'/60'/0'/0/0
m/44'/501'/0'/0'
m/44'/607'/0'/0/0
```

### Файл passphrase

Каждая строка — это одна passphrase.

Пример: [`examples/passphrases.txt`](./examples/passphrases.txt)

```text
TREZOR
wallet-passphrase-example
```

## Справка По Аргументам

### Источники recovery-входа

| Аргумент | Что делает | Примечание |
| --- | --- | --- |
| `-recovery "..."` | Добавляет один шаблон прямо из CLI | Можно повторять |
| `-recovery -i FILE` | Загружает шаблоны из файла | Можно повторять; строки обрабатываются последовательно в streaming-режиме |
| `-wordlist FILE` | Ограничивает wildcard-кандидаты словами из файла | От 1 до 65 535 уникальных слов |
| `-nvalid` | Учитывает комбинации с невалидным checksum | Явно отключает BIP39 checksum-фильтрацию |
| `-d FILE` | Загружает derivation-path’ы | Обязательный аргумент |

Внешний список ровно из 2048 слов сохраняет прежнюю ordered-BIP39 семантику checksum. Для другого размера программа проверяет, входят ли все слова ровно в один встроенный BIP39-словарь. Однозначное стандартное подмножество сохраняет checksum-фильтрацию и использует канонические BIP39 ID; кастомный, смешанный или неоднозначный список автоматически включает `-nvalid`. Явный `-nvalid` всегда имеет приоритет. Пустые списки, дубликаты, слова длиннее 33 байт и списки более 65 535 слов отклоняются.

### Цели и тип derivation

| Аргумент | Что делает |
| --- | --- |
| `-c TYPES` | Выбор target families. По умолчанию `cus` |
| `-d_type <1/2/3/4>` | Переопределяет derivation engine: `1=bip32-secp256k1`, `2=slip0010-ed25519`, `3=оба варианта`, `4=ed25519-bip32 (experimental)` |

Если `-d_type` не указан, инструмент использует обычный тип derivation для выбранной target family:

- Bitcoin-подобные и Ethereum-цели идут через обычный BIP32/secp256k1
- Solana и TON используют свой привычный ed25519-ориентированный тип derivation
- `-c` при этом всё равно задаёт именно target family, которую нужно строить и проверять
- `-d_type 4` включается только явно и не входит в mixed-режим
- В live status показываются и `candidates/s`, и `hashes/s`; hash throughput растёт вместе с числом derivations, выбранных целей и derivation policy

### Experimental `-d_type 4`

`-d_type 4` оставляет `ed25519-bip32` доступным как режим для отдельной оценки и проверки.

- Он включается только явно.
- Он не входит в `-d_type 3`.
- Он не входит в основные production-claims этого README.
- Отдельное покрытие для этого режима зафиксировано в [`VALIDATION.md`](./VALIDATION.md).

### Filters и direct targets

| Аргумент | Что делает |
| --- | --- |
| `-hash HEX` | Проверка по точному hash или raw target prefix в hex |
| `-bf FILE` | Загружает Bloom filter. Аргумент можно повторять |
| `-xu FILE` | Загружает `.xor_u`, несжатый формат XOR filter. Аргумент можно повторять |
| `-xc FILE` | Загружает `.xor_c`, компактный GPU-side XOR prefilter. Аргумент можно повторять |
| `-xuc FILE` | Загружает `.xor_uc`, ещё более компактный GPU-side XOR prefilter. Аргумент можно повторять |
| `-xh FILE` | Загружает `.xor_hc`, самый компактный GPU-side XOR prefilter. Аргумент можно повторять |
| `-xx FILE` | CPU verify через несжатый `.xor_u` filter |
| `-xb FILE` | CPU verify через Bloom filter |

`-hash` принимает hex-строку. Для classic hash160-семейств обычно используется весь 20-byte hash. Для raw 32-byte targets инструмент работает как prefix matcher, поэтому обычно передаются начальные байты raw значения.

Практическая подсказка по `-hash` для `-c`:

- `-c c`, `-c u`, `-c s`, `-c r` ждут Bitcoin-style `hash160` в hex.
- `-c x` ждёт начальные байты raw x-only публичного ключа в hex, без `02`, `03` и `04`.
- `-c e` ждёт Ethereum address в hex без `0x`.
- `-c S` ждёт начальные байты raw ed25519 public key в hex, то есть Solana-адрес нужно сначала декодировать из base58.
- `-c t` и `-c T` ждут начальные байты raw TON account hash в hex, без `<workchain:>`.

Практический BTC-style пример с точным hash:

```bash
CUDA_Mnemonic_Recovery -device 2 -recovery "adapt access alert human kiwi rough pottery level soon funny burst *" -d examples/derivations/default.txt -c c -hash 1a4603d1ff9121515d02a6fee37c20829ca522b0
```

### Bloom filters

`CUDA_Mnemonic_Recovery` принимает Bloom-фильтры, совместимые с форматами, которые используют [brainflayer](https://github.com/ryancdotorg/brainflayer) и [Mnemonic_CPP](https://github.com/XopMC/Mnemonic_CPP).

Можно подключать несколько Bloom-фильтров, просто повторяя `-bf`:

```bash
CUDA_Mnemonic_Recovery -recovery -i examples/templates.txt -d examples/derivations/default.txt -bf wallet_a.blf -bf wallet_b.blf -c c
```

## XOR Фильтры И XorFilter

Если вам нужны XOR-фильтры для этого проекта, создавать их лучше через [XorFilter](https://github.com/XopMC/XorFilter).

Рекомендуемая схема:

- `.xor_u` — единственный XOR-формат, который подходит как финальный standalone-вариант без дополнительной CPU-проверки.
- `.xor_c`, `.xor_uc` и `.xor_hc` — это компактные GPU-side prefilter’ы. Они отлично подходят для экономии памяти и ускорения широкого сканирования, но их нельзя считать финальной истиной в полноценной recovery-сессии.
- Для `.xor_c`, `.xor_uc` и `.xor_hc` добавляйте `-xx wallet.xor_u`, чтобы прошедшие кандидаты перепроверялись на CPU по несжатому `.xor_u`.
- Несколько XOR-фильтров одного семейства можно подключать повторением соответствующего флага.

Практический пример:

```bash
CUDA_Mnemonic_Recovery -recovery -i examples/templates.txt -d examples/derivations/default.txt -xc wallet.xor_c -xx wallet.xor_u -c cus
```

Пример с несколькими XOR-фильтрами:

```bash
CUDA_Mnemonic_Recovery -recovery -i examples/templates.txt -d examples/derivations/default.txt -xc wallet_a.xor_c -xc wallet_b.xor_c -xx wallet_master.xor_u -c cus
```

Такой шаблон даёт компактный GPU-фильтр на входе и точную CPU-перепроверку на выходе.

### Runtime и вывод

| Аргумент | Что делает |
| --- | --- |
| `-pbkdf N` | Переопределяет число PBKDF2 итераций. По умолчанию `2048` |
| `-pass VALUE\|FILE` | Одна passphrase строкой или файл passphrase |
| `-device LIST` | Выбор одной или нескольких GPU, например `2`, `2,3`, `0-3` |
| `-b N` | Принудительное число CUDA blocks |
| `-t N` | Принудительное число threads per block |
| `-fsize N` | Размер found-buffer |
| `-o FILE` | Файл результатов. По умолчанию `result.txt` |
| `-save` | Переключает последний столбец с raw hash на адресный вывод |
| `-silent` | Не печатать hits в консоль |
| `-h`, `-help` | Показать публичное help-меню |

## Как Работает `-save`

Инструмент сохраняет компактные `Found` строки в плоском формате через `:`.

Без `-save` последний сегмент строки — это raw matched hash/target bytes:

```text
[!] Found: <mnemonic>:<derivation>:<private_key_hex>:COMPRESSED:<matched_hash>
```

С `-save` последний сегмент становится адресно-ориентированным:

```text
[!] Found: <mnemonic>:<derivation>:<private_key_hex>:COMPRESSED:<address>
```

Что остаётся всегда:

- приватный ключ
- путь деривации
- label типа/монеты

Что меняется:

- raw hash заменяется на адресный вывод
- для compressed Bitcoin добавляется дополнительная строка `P2WPKH`

Примеры:

```text
[!] Found: ...:COMPRESSED:1LqBGSKuX5yYUonjxT5qGfpUsXKYYWeabA
[!] Found: ...:P2WPKH:bc1qmxrw6qdh5g3ztfcwm0et5l8mvws4eva24kmp8m
[!] Found: ...:ETH:0x9858effd232b4033e47d90003d41ec34ecaeda94
[!] Found: ...:SOLANA:EHqmfkN89RJ7Y33CXM6uCzhVeuywHoJXZZLszBHHZy7o
```

В mixed-режиме non-default derivation engine помечается рядом с derivation path, а не внутри названия монеты:

```text
[!] Found: ...:(bip32-secp256k1) m/44'/501'/0'/0':<private_key>:SOLANA:<value>
```

## Multi-GPU

Multi-GPU включается через `-device LIST`.

Примеры:

```bash
CUDA_Mnemonic_Recovery -device 2,3 -recovery -i examples/templates.txt -d examples/derivations/default.txt -c c
CUDA_Mnemonic_Recovery -device 0-3 -recovery -i examples/templates.txt -d examples/derivations/default.txt -c cusrxeStT
```

Что делает инструмент в multi-GPU режиме:

- создаёт отдельный рабочий контекст на каждую выбранную GPU
- делит workload между устройствами
- ведёт per-device статистику
- агрегирует итоговые tested / checksum-valid totals
- сохраняет async save workers до конца выполнения

### Краткий benchmark summary

Полная benchmark-методика, описание fixture’ов, условия запуска и stress-case notes вынесены в [`BENCHMARKS.md`](./BENCHMARKS.md).

Короткая локальная сводка из текущего benchmark-набора:

| GPU | Устройства | Нагрузка | Время до первого hit |
| --- | --- | --- | --- |
| `1` | `2` | `1 шаблон`, `3 пропущенных слова`, exact hash | `550.07 s` |
| `2` | `0,2` | то же самое | `211.58 s` |
| `4` | `0,1,2,3` | то же самое | `41.59 s` |

Stress-case summary:

- `1 GPU`, устройство `2`, `4 пропущенных слова`, лимит `10 минут`: hit не найден за `600.37 s`
- `4 GPU`, устройства `0,1,2,3`, тот же stress-fixture: первый hit через `15.75 s`

За точными командами, fixture-файлами, оговорками по hardware и границами измерений см. [`BENCHMARKS.md`](./BENCHMARKS.md).

## Troubleshooting

### Инструмент пишет `-d FILE is required`

Это ожидаемо. В публичной документации recovery-запуски всегда предполагают явный файл с derivation-path’ами.

### Я хочу восстанавливать из файла, а не печатать phrase вручную

Используйте:

```bash
CUDA_Mnemonic_Recovery -recovery -i examples/templates.txt -d examples/derivations/default.txt
```

### У моего кошелька необычная derivation-логика

Пробуйте `-d_type`:

- `-d_type 1` — принудительный BIP32/secp256k1
- `-d_type 2` — принудительный SLIP-0010 ed25519
- `-d_type 3` — оба варианта
- `-d_type 4` — экспериментальный `ed25519-bip32` test-режим

### С `-save` перестал показываться raw hash

Это нормально. `-save` специально переключает последний сегмент на адресный вывод.

### Можно ли использовать несколько GPU?

Да. Например:

```bash
-device 2,3
-device 0-3
```

## Структура Репозитория

- `src/app/` — entry point, CLI, config
- `src/recovery/` — recovery flow и orchestration на стороне хоста
- `src/crypto/` — mnemonic, TON, filters, hashes
- `src/cuda/` — CUDA recovery workers и device control
- `include/` — заголовки проекта
- `support/` — общие host utilities
- `third_party/` — bundled crypto и PBKDF2 код
- `assets/wordlists/` — исходные BIP39 wordlists
- `examples/` — готовые примерные входы
- `scripts/` — локальные validation-скрипты
- `docs/media/` — визуалы README и social preview assets

## Responsible Use

Проект предназначен только для легитимного восстановления кошельков, backup-фраз и seed-фраз, которые принадлежат вам или на восстановление которых у вас есть явное разрешение владельца.

Я настоятельно не рекомендую использовать это ПО в злонамеренных целях. Полная ответственность за любое незаконное или злоупотребляющее использование лежит исключительно на пользователе. См. [`RESPONSIBLE_USE.md`](./RESPONSIBLE_USE.md) и [`SECURITY.md`](./SECURITY.md).

## Поддержка Проекта

Если вы хотите поддержать дальнейшую разработку, адреса для донатов и контактные данные собраны в [`SUPPORT.md`](./SUPPORT.md).

## Разработка На Заказ

Я занимаюсь разработкой ПО на заказ. Если вам нужны доработки, адаптация или развитие `CUDA_Mnemonic_Recovery` под конкретную задачу, это можно обсудить со мной в Telegram:

- https://t.me/xopmc

Это ПО вынесено в публичный доступ в том числе как пример задач и систем, с которыми я умею работать.
