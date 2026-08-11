#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exe="${CMR_EXE:-$repo_root/out/build/linux-release/bin/CUDA_Mnemonic_Recovery}"
device="${CMR_DEVICE:-0}"
multi_device="${CMR_MULTI_DEVICE:-}"
skip_experimental="${CMR_SKIP_EXPERIMENTAL:-0}"

if [[ ! -x "$exe" ]]; then
  echo "Executable not found or not executable: $exe" >&2
  exit 1
fi

phrase_exact="adapt access alert human kiwi rough pottery level soon funny burst divorce"
phrase_one_missing="adapt access alert human kiwi rough pottery level soon funny burst *"
hash_compressed="1a4603d1ff9121515d02a6fee37c20829ca522b0"
hash_pass="1e398598f50849236bc8a077b184fbce0aa74f4e"
hash_solana_d1="553ff1f4f34d1c013fd885073a0b6b82f02bb3d0"
hash_solana_d2="89dfcdfe8986448bf0ca1f5bc1720de5ad66104c"
hash_d4="4fd01a8da7097495668c9ee9499084bc5680199a"

templates_file="examples/validation/templates-file.txt"
templates_stream_a="examples/validation/templates-stream-a.txt"
templates_stream_b="examples/validation/templates-stream-b.txt"
template_typo="examples/validation/template-typo.txt"
derivations_default="examples/derivations/default.txt"
derivations_secp="examples/validation/derivations-secp.txt"
derivations_solana="examples/validation/derivations-solana.txt"
wordlist_english="assets/wordlists/bip39-en.txt"

validation_out_dir="$repo_root/out/validation-run"
mkdir -p "$validation_out_dir"

run_case() {
  local name="$1"
  shift
  echo "[case] $name"
  local output
  if ! output="$("$exe" "$@" 2>&1)"; then
    echo "$output" >&2
    echo "Case '$name' failed." >&2
    exit 1
  fi
  printf '%s\n' "$output"
}

require_pattern() {
  local name="$1"
  local output="$2"
  local pattern="$3"
  if ! grep -Eq "$pattern" <<<"$output"; then
    echo "Case '$name' did not match pattern '$pattern'." >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
}

extract_found_count() {
  local output="$1"
  local value
  value="$(grep -Eo 'Found:[[:space:]]+[0-9]+' <<<"$output" | head -n1 | awk '{print $2}')"
  if [[ -z "$value" ]]; then
    echo "Could not extract Found count." >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
  printf '%s\n' "$value"
}

pushd "$repo_root" >/dev/null

help_output="$(run_case "help" -help)"
require_pattern "help" "$help_output" '-d_type 1\|2\|3\|4'
require_pattern "help" "$help_output" '-nvalid'
echo "[ok] help"

wordlist_en_128="$validation_out_dir/wordlist-en-128.txt"
wordlist_custom_3="$validation_out_dir/wordlist-custom-3.txt"
wordlist_mixed_3="$validation_out_dir/wordlist-mixed-3.txt"
wordlist_custom_2049="$validation_out_dir/wordlist-custom-2049.txt"
head -n 128 "$wordlist_english" > "$wordlist_en_128"
printf '%s\n' alpha custombeta customgamma > "$wordlist_custom_3"
printf '%s\n' abandon ability customword > "$wordlist_mixed_3"
awk 'BEGIN { for (i = 0; i <= 2048; ++i) printf "customword%04d\n", i }' > "$wordlist_custom_2049"

subset_output="$(run_case "standard subset checksum" \
  -device "$device" -recovery "$phrase_one_missing" \
  -wordlist "$wordlist_en_128" -d "$derivations_default" \
  -c c -hash "$hash_compressed" -pbkdf 1 -silent)"
require_pattern "standard subset checksum" "$subset_output" 'recognized as an unambiguous BIP39 subset'
require_pattern "standard subset checksum" "$subset_output" 'tested=128 checksum-valid=8'
echo "[ok] standard subset checksum"

custom_output="$(run_case "custom wordlist auto nvalid" \
  -device "$device" -recovery "alpha alpha alpha alpha alpha alpha alpha alpha alpha alpha alpha *" \
  -wordlist "$wordlist_custom_3" -d "$derivations_default" \
  -c c -hash "$hash_compressed" -pbkdf 1 -silent)"
require_pattern "custom wordlist auto nvalid" "$custom_output" 'enabling -nvalid automatically'
require_pattern "custom wordlist auto nvalid" "$custom_output" 'tested=3 checksum-valid=3'
echo "[ok] custom wordlist auto nvalid"

mixed_wordlist_output="$(run_case "mixed wordlist auto nvalid" \
  -device "$device" -recovery "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon *" \
  -wordlist "$wordlist_mixed_3" -d "$derivations_default" \
  -c c -hash "$hash_compressed" -pbkdf 1 -silent)"
require_pattern "mixed wordlist auto nvalid" "$mixed_wordlist_output" 'enabling -nvalid automatically'
require_pattern "mixed wordlist auto nvalid" "$mixed_wordlist_output" 'tested=3 checksum-valid=3'
echo "[ok] mixed wordlist auto nvalid"

explicit_nvalid_output="$(run_case "explicit nvalid" \
  -device "$device" -recovery "$phrase_one_missing" \
  -wordlist "$wordlist_english" -nvalid -d "$derivations_default" \
  -c c -hash "$hash_compressed" -pbkdf 1 -silent)"
require_pattern "explicit nvalid" "$explicit_nvalid_output" 'tested=2048 checksum-valid=2048'
echo "[ok] explicit nvalid"

custom_2049_output="$(run_case "custom wordlist above 2048" \
  -device "$device" -recovery "customword0000 customword0000 customword0000 customword0000 customword0000 customword0000 customword0000 customword0000 customword0000 customword0000 customword0000 *" \
  -wordlist "$wordlist_custom_2049" -d "$derivations_default" \
  -c c -hash "$hash_compressed" -pbkdf 1 -silent)"
require_pattern "custom wordlist above 2048" "$custom_2049_output" 'options=2049'
require_pattern "custom wordlist above 2048" "$custom_2049_output" 'tested=2049 checksum-valid=2049'
echo "[ok] custom wordlist above 2048"

inline_output="$(run_case "inline exact hash" \
  -device "$device" \
  -recovery "$phrase_one_missing" \
  -d "$derivations_default" \
  -c c \
  -hash "$hash_compressed" \
  -silent)"
require_pattern "inline exact hash" "$inline_output" 'Found:[[:space:]]+1'
echo "[ok] inline exact hash"

file_output="$(run_case "file exact hash" \
  -device "$device" \
  -recovery -i "$templates_file" \
  -d "$derivations_default" \
  -c c \
  -hash "$hash_compressed" \
  -silent)"
require_pattern "file exact hash" "$file_output" 'Found:[[:space:]]+1'
echo "[ok] file exact hash"

typo_output="$(run_case "typo correction" \
  -device "$device" \
  -recovery -i "$template_typo" \
  -d "$derivations_secp" \
  -c c \
  -hash "$hash_compressed")"
require_pattern "typo correction" "$typo_output" "Recovery replace: 'acces' -> 'access'"
require_pattern "typo correction" "$typo_output" 'Found:[[:space:]]+1'
echo "[ok] typo correction"

pass_output="$(run_case "passphrase exact hash" \
  -device "$device" \
  -recovery "$phrase_exact" \
  -d "$derivations_secp" \
  -c c \
  -pass TREZOR \
  -hash "$hash_pass" \
  -silent)"
require_pattern "passphrase exact hash" "$pass_output" 'Found:[[:space:]]+1'
echo "[ok] passphrase exact hash"

mixed_output="$(run_case "mixed streaming sources" \
  -device "$device" \
  -recovery "$phrase_one_missing" \
  -recovery -i "$templates_stream_a" \
  -recovery -i "$templates_stream_b" \
  -d "$derivations_default" \
  -c c \
  -hash "$hash_compressed" \
  -silent)"
require_pattern "mixed streaming sources" "$mixed_output" 'Recovery source done: examples/validation/templates-stream-a\.txt \| processed=1 skipped=0 tested=2048 checksum-valid=128 found=1'
require_pattern "mixed streaming sources" "$mixed_output" 'Recovery source done: examples/validation/templates-stream-b\.txt \| processed=1 skipped=1 tested=2048 checksum-valid=128 found=1'
require_pattern "mixed streaming sources" "$mixed_output" 'Recovery summary: processed=3 skipped=1 tested=6144 checksum-valid=384'
require_pattern "mixed streaming sources" "$mixed_output" 'Found:[[:space:]]+3'
mixed_cmd_index="$(awk 'index($0,"Recovery task done: <cmd> | tested=2048 checksum-valid=128"){print NR; exit}' <<<"$mixed_output")"
mixed_a_index="$(awk 'index($0,"Recovery source done: examples/validation/templates-stream-a.txt | processed=1 skipped=0 tested=2048 checksum-valid=128 found=1"){print NR; exit}' <<<"$mixed_output")"
mixed_b_index="$(awk 'index($0,"Recovery source done: examples/validation/templates-stream-b.txt | processed=1 skipped=1 tested=2048 checksum-valid=128 found=1"){print NR; exit}' <<<"$mixed_output")"
if [[ -z "$mixed_cmd_index" || -z "$mixed_a_index" || -z "$mixed_b_index" || "$mixed_cmd_index" -ge "$mixed_a_index" || "$mixed_a_index" -ge "$mixed_b_index" ]]; then
  echo "Mixed-source streaming order did not stay aligned with the recovery queue." >&2
  printf '%s\n' "$mixed_output" >&2
  exit 1
fi
echo "[ok] mixed streaming sources"

save_file="$validation_out_dir/save-output.txt"
rm -f "$save_file"
save_output="$(run_case "save output" \
  -device "$device" \
  -recovery "$phrase_one_missing" \
  -d "$derivations_default" \
  -c c \
  -hash "$hash_compressed" \
  -save \
  -o "$save_file" \
  -silent)"
require_pattern "save output" "$save_output" 'Found:[[:space:]]+1'
if [[ ! -f "$save_file" ]]; then
  echo "Save output file was not created: $save_file" >&2
  exit 1
fi
save_content="$(cat "$save_file")"
require_pattern "save output file" "$save_content" '\[!\][[:space:]]+Found:'
if grep -Fq "$hash_compressed" <<<"$save_content"; then
  echo "Save output still contains the raw exact hash." >&2
  printf '%s\n' "$save_content" >&2
  exit 1
fi
echo "[ok] save output"

d1_output="$(run_case "d_type 1 solana" \
  -device "$device" \
  -recovery "$phrase_exact" \
  -d "$derivations_solana" \
  -c S \
  -d_type 1 \
  -hash "$hash_solana_d1" \
  -silent)"
require_pattern "d_type 1 solana" "$d1_output" 'Found:[[:space:]]+1'
echo "[ok] d_type 1 solana"

d2_output="$(run_case "d_type 2 solana" \
  -device "$device" \
  -recovery "$phrase_exact" \
  -d "$derivations_solana" \
  -c S \
  -hash "$hash_solana_d2" \
  -silent)"
require_pattern "d_type 2 solana" "$d2_output" 'Found:[[:space:]]+1'
echo "[ok] d_type 2 solana"

d3_output="$(run_case "d_type 3 mixed marker" \
  -device "$device" \
  -recovery "$phrase_exact" \
  -d "$derivations_solana" \
  -c S \
  -d_type 3 \
  -hash "$hash_solana_d1")"
require_pattern "d_type 3 mixed marker" "$d3_output" '\(bip32-secp256k1\)'
require_pattern "d_type 3 mixed marker" "$d3_output" 'Found:[[:space:]]+1'
echo "[ok] d_type 3 mixed marker"

if [[ "$skip_experimental" != "1" ]]; then
  d4_output="$(run_case "d_type 4 experimental" \
    -device "$device" \
    -recovery "$phrase_exact" \
    -d "$derivations_secp" \
    -c c \
    -d_type 4 \
    -hash "$hash_d4")"
  require_pattern "d_type 4 experimental" "$d4_output" '\(ed25519-bip32-test\)'
  require_pattern "d_type 4 experimental" "$d4_output" 'Found:[[:space:]]+1'
  echo "[ok] d_type 4 experimental"
fi

if [[ -n "$multi_device" ]]; then
  multi_output="$(run_case "multi-GPU parity" \
    -device "$multi_device" \
    -recovery -i "$templates_file" \
    -d "$derivations_default" \
    -c c \
    -hash "$hash_compressed" \
    -silent)"
  require_pattern "multi-GPU parity" "$multi_output" 'Found:[[:space:]]+1'
  single_found="$(extract_found_count "$file_output")"
  multi_found="$(extract_found_count "$multi_output")"
  if [[ "$single_found" != "$multi_found" ]]; then
    echo "Single-GPU and multi-GPU Found counts differ: $single_found vs $multi_found" >&2
    exit 1
  fi
  echo "[ok] multi-GPU parity"
fi

echo
echo "Validation suite completed successfully."

popd >/dev/null
