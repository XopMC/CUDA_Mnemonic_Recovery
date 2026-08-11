// Author: Mikhail Khoroshavin aka "XopMC"

#include "cuda/Kernel.cuh"
#include "third_party/secp256k1/secp256k1.cuh"
#include "third_party/secp256k1/secp256k1_batch_impl.cuh"
#include "third_party/fastpbkdf2/fastpbkdf2.cuh"
#include "cuda/DerivationFunc.cuh"

// Device helper: validate mnemonic checksum for dynamic word count (3..48, multiple of 3).
static __device__ __forceinline__ bool recovery_checksum_valid_ids_dyn(const uint16_t* ids, int words_count) {
    if (words_count <= 0 || words_count > 48 || (words_count % 3) != 0) {
        return false;
    }

    const int total_bits = words_count * 11;
    const int ent_bits = (total_bits * 32) / 33;
    const int cs_bits = total_bits - ent_bits;
    if (cs_bits <= 0) {
        return false;
    }

    const int ent_bytes = (ent_bits + 7) >> 3;

    uint8_t bits[68];
    uint8_t entropy[68];
    uint8_t digest[32];

#pragma unroll
    for (int i = 0; i < 68; ++i) {
        bits[i] = 0u;
        entropy[i] = 0u;
    }

    int bitpos = 0;
    for (int i = 0; i < words_count; ++i) {
        const int v = static_cast<int>(ids[i] & 0x7FFu);
        for (int b = 10; b >= 0; --b) {
            const uint8_t bit = static_cast<uint8_t>((v >> b) & 1);
            bits[bitpos >> 3] |= static_cast<uint8_t>(bit << (7 - (bitpos & 7)));
            ++bitpos;
        }
    }

#pragma unroll
    for (int i = 0; i < 68; ++i) {
        if (i >= ent_bytes) break;
        entropy[i] = bits[i];
    }

    if ((ent_bits & 7) != 0 && ent_bytes > 0) {
        entropy[ent_bytes - 1] &= static_cast<uint8_t>(0xFFu << (8 - (ent_bits & 7)));
    }

    SHA256(entropy, static_cast<size_t>(ent_bytes), digest);

    for (int i = 0; i < cs_bits; ++i) {
        const int phrase_bit_pos = ent_bits + i;
        const uint8_t phrase_bit = static_cast<uint8_t>((bits[phrase_bit_pos >> 3] >> (7 - (phrase_bit_pos & 7))) & 1u);
        const uint8_t digest_bit = static_cast<uint8_t>((digest[i >> 3] >> (7 - (i & 7))) & 1u);
        if (phrase_bit != digest_bit) {
            return false;
        }
    }

    return true;
}

// Device helper: validate mnemonic checksum for fixed word count.
template<int WORDS_COUNT>
static __device__ __forceinline__ bool recovery_checksum_valid_ids_fixed(const uint16_t* ids) {
    static_assert(WORDS_COUNT > 0 && WORDS_COUNT <= 48, "Unsupported mnemonic size");
    static_assert((WORDS_COUNT % 3) == 0, "Mnemonic size must be divisible by 3");

    constexpr int total_bits = WORDS_COUNT * 11;
    constexpr int ent_bits = (total_bits * 32) / 33;
    constexpr int cs_bits = total_bits - ent_bits;
    constexpr int bits_bytes = (total_bits + 7) >> 3;
    constexpr int ent_bytes = (ent_bits + 7) >> 3;

    uint8_t bits[bits_bytes];
    uint8_t entropy[ent_bytes];

#pragma unroll
    for (int i = 0; i < bits_bytes; ++i) {
        bits[i] = 0u;
    }

#pragma unroll
    for (int i = 0; i < ent_bytes; ++i) {
        entropy[i] = 0u;
    }

    int bitpos = 0;
#pragma unroll
    for (int i = 0; i < WORDS_COUNT; ++i) {
        const int v = static_cast<int>(ids[i] & 0x7FFu);
#pragma unroll
        for (int b = 10; b >= 0; --b) {
            const uint8_t bit = static_cast<uint8_t>((v >> b) & 1);
            bits[bitpos >> 3] |= static_cast<uint8_t>(bit << (7 - (bitpos & 7)));
            ++bitpos;
        }
    }

#pragma unroll
    for (int i = 0; i < ent_bytes; ++i) {
        entropy[i] = bits[i];
    }

    if ((ent_bits & 7) != 0 && ent_bytes > 0) {
        entropy[ent_bytes - 1] &= static_cast<uint8_t>(0xFFu << (8 - (ent_bits & 7)));
    }

    uint8_t digest[32];
    SHA256(entropy, static_cast<size_t>(ent_bytes), digest);

#pragma unroll
    for (int i = 0; i < cs_bits; ++i) {
        const int phrase_bit_pos = ent_bits + i;
        const uint8_t phrase_bit = static_cast<uint8_t>((bits[phrase_bit_pos >> 3] >> (7 - (phrase_bit_pos & 7))) & 1u);
        const uint8_t digest_bit = static_cast<uint8_t>((digest[i >> 3] >> (7 - (i & 7))) & 1u);
        if (phrase_bit != digest_bit) {
            return false;
        }
    }
    return true;
}

// Kernel entry point: validate wildcard range and compact checksum-valid mnemonics for fixed mnemonic size.
template<int WORDS_COUNT>
__global__ void workerRecoveryChecksumFixed(
    const uint16_t* base_ids,
    const int* missing_positions,
    int missing_count,
    const uint16_t* word_options,
    uint32_t word_options_count,
    bool include_invalid,
    uint64_t range_start,
    uint64_t range_count,
    uint16_t* out_ids,
    uint32_t* out_count,
    uint32_t out_capacity) {

    const uint64_t tid = static_cast<uint64_t>(blockIdx.x) * static_cast<uint64_t>(blockDim.x) + static_cast<uint64_t>(threadIdx.x);
    const uint64_t stride = static_cast<uint64_t>(blockDim.x) * static_cast<uint64_t>(gridDim.x);

    uint16_t ids[WORDS_COUNT];
    int missing_pos_local[48];

#pragma unroll
    for (int i = 0; i < WORDS_COUNT; ++i) {
        ids[i] = base_ids[i];
    }
    for (int j = 0; j < missing_count; ++j) {
        missing_pos_local[j] = missing_positions[j];
    }

    for (uint64_t local = tid; local < range_count; local += stride) {
        uint64_t combo = range_start + local;

        for (int j = 0; j < missing_count; ++j) {
            const int pos = missing_pos_local[j];
            uint32_t option = 0u;
            if (word_options == nullptr && word_options_count == 2048u) {
                option = static_cast<uint32_t>(combo & 0x7FFull);
                combo >>= 11;
            }
            else {
                option = static_cast<uint32_t>(combo % static_cast<uint64_t>(word_options_count));
                combo /= static_cast<uint64_t>(word_options_count);
            }
            ids[pos] = (word_options == nullptr) ? static_cast<uint16_t>(option) : word_options[option];
        }

        if (!include_invalid && !recovery_checksum_valid_ids_fixed<WORDS_COUNT>(ids)) {
            continue;
        }

        const uint32_t slot = atomicAdd(out_count, 1u);
        if (slot < out_capacity) {
            uint16_t* dst = out_ids + (static_cast<size_t>(slot) * static_cast<size_t>(WORDS_COUNT));
#pragma unroll
            for (int i = 0; i < WORDS_COUNT; ++i) {
                dst[i] = ids[i];
            }
        }
    }
}

// Kernel entry point: validate wildcard range and compact checksum-valid mnemonics.
__global__ void workerRecoveryChecksum(
    const uint16_t* base_ids,
    int words_count,
    const int* missing_positions,
    int missing_count,
    const uint16_t* word_options,
    uint32_t word_options_count,
    bool include_invalid,
    uint64_t range_start,
    uint64_t range_count,
    uint16_t* out_ids,
    uint32_t* out_count,
    uint32_t out_capacity) {

    const uint64_t tid = static_cast<uint64_t>(blockIdx.x) * static_cast<uint64_t>(blockDim.x) + static_cast<uint64_t>(threadIdx.x);
    const uint64_t stride = static_cast<uint64_t>(blockDim.x) * static_cast<uint64_t>(gridDim.x);

    uint16_t ids[48];
    int missing_pos_local[48];

    for (int i = 0; i < words_count; ++i) {
        ids[i] = base_ids[i];
    }
    for (int j = 0; j < missing_count; ++j) {
        missing_pos_local[j] = missing_positions[j];
    }

    for (uint64_t local = tid; local < range_count; local += stride) {
        uint64_t combo = range_start + local;

        for (int j = 0; j < missing_count; ++j) {
            const int pos = missing_pos_local[j];
            uint32_t option = 0u;
            if (word_options == nullptr && word_options_count == 2048u) {
                option = static_cast<uint32_t>(combo & 0x7FFull);
                combo >>= 11;
            }
            else {
                option = static_cast<uint32_t>(combo % static_cast<uint64_t>(word_options_count));
                combo /= static_cast<uint64_t>(word_options_count);
            }
            ids[pos] = (word_options == nullptr) ? static_cast<uint16_t>(option) : word_options[option];
        }

        if (!include_invalid && !recovery_checksum_valid_ids_dyn(ids, words_count)) {
            continue;
        }

        const uint32_t slot = atomicAdd(out_count, 1u);
        if (slot < out_capacity) {
            uint16_t* dst = out_ids + (static_cast<size_t>(slot) * static_cast<size_t>(words_count));
            for (int i = 0; i < words_count; ++i) {
                dst[i] = ids[i];
            }
        }
    }
}

// Device helper: build mnemonic phrase from word IDs and dictionary.
static __device__ __forceinline__ uint32_t recovery_build_phrase_from_ids(
    const uint16_t* ids,
    int words_count,
    const char (*dict)[34],
    char* out,
    uint32_t out_capacity) {

    if (ids == nullptr || dict == nullptr || out == nullptr || out_capacity < 2u) {
        return 0u;
    }

    uint32_t off = 0u;
    const uint32_t limit = out_capacity - 1u;

    for (int i = 0; i < words_count; ++i) {
        const uint16_t id = ids[i];
        const char* word = dict[id];
        for (int j = 0; j < 33; ++j) {
            const char c = word[j];
            if (c == '\0') {
                break;
            }
            if (off >= limit) {
                out[0] = '\0';
                return 0u;
            }
            out[off++] = c;
        }

        if (i + 1 < words_count) {
            if (off >= limit) {
                out[0] = '\0';
                return 0u;
            }
            out[off++] = ' ';
        }
    }

    out[off] = '\0';
    return off;
}

// Device helper: store found candidate in global output buffers.
static __device__ __forceinline__ void recovery_store_found_basic(
    bool* isResult,
    bool* buffResult,
    uint32_t starter,
    uint32_t c_path,
    const char* phrase,
    uint32_t phrase_len,
    const uint8_t* prv_key32,
    const void* hash_data,
    size_t hash_data_len,
    uint8_t type,
    uint8_t derivation_type,
    int64_t current_round,
    const char* pass_start,
    int pass_size) {

    buffResult[starter] = true;
    isResult[0] = true;

    const unsigned long long idx = atomicAdd(&d_resultsCount[0], 1ull);
    if (idx >= MAX_FOUNDS_DEV) {
        return;
    }

    d_foundDerivations[idx] = c_path;
    memcpy(d_foundStrings[idx], phrase, phrase_len);
    d_len[idx][0] = phrase_len;
    memcpy(d_foundPrvKeys[idx], prv_key32, 32);
    if (hash_data != nullptr && hash_data_len > 0u) {
        memcpy(d_foundHash160[idx], hash_data, hash_data_len);
    }
    d_type[idx] = type;
    d_resultDerivationType[idx] = derivation_type;
    d_round[idx] = current_round;

    if (IS_PASS) {
        int copy_len = pass_size;
        if (copy_len < 0) {
            copy_len = 0;
        }
        if (copy_len > 128) {
            copy_len = 128;
        }
        d_pass_size[idx] = static_cast<uint16_t>(copy_len);
        if (copy_len > 0 && pass_start != nullptr) {
            memcpy(d_pass[idx], pass_start, static_cast<size_t>(copy_len));
        }
    }
}

// Device helper: build phrase lazily from word IDs and store match.
static __device__ __forceinline__ void recovery_store_found_from_ids(
    bool* isResult,
    bool* buffResult,
    uint32_t starter,
    uint32_t c_path,
    const uint16_t* ids,
    int words_count,
    const char (*dict)[34],
    const uint8_t* prv_key32,
    const void* hash_data,
    size_t hash_data_len,
    uint8_t type,
    uint8_t derivation_type,
    int64_t current_round,
    const char* pass_start,
    int pass_size) {

    if (ids == nullptr || dict == nullptr) {
        return;
    }

    char phrase[512];
    const uint32_t phrase_len = recovery_build_phrase_from_ids(ids, words_count, dict, phrase, static_cast<uint32_t>(sizeof(phrase)));
    if (phrase_len == 0u) {
        return;
    }

    recovery_store_found_basic(
        isResult,
        buffResult,
        starter,
        c_path,
        phrase,
        phrase_len,
        prv_key32,
        hash_data,
        hash_data_len,
        type,
        derivation_type,
        current_round,
        pass_start,
        pass_size);
}

static constexpr uint32_t RECOVERY_MASTER_WORDS = 16u;

// Device helper: derive BIP32 master key material from mnemonic phrase.
static __device__ __forceinline__ bool recovery_build_master_words_from_phrase(
    const char* phrase,
    uint32_t phrase_len,
    const char* __restrict__ passwd,
    uint32_t pass_size,
    const uint32_t* __restrict__ iterations,
    uint32_t iterations_size,
    uint32_t* out_master_words) {

    if (phrase == nullptr || out_master_words == nullptr || phrase_len == 0u || iterations == nullptr || iterations_size == 0u) {
        return false;
    }

    bool has_work = false;
    for (uint32_t num = 0; num < iterations_size; ++num) {
        if (iterations[num] != 0u) {
            has_work = true;
            break;
        }
    }
    if (!has_work) {
        return false;
    }

    const uint8_t* pbkdfSaltMain = salt;
    uint32_t pbkdfSaltMainLen = 8u;
    uint8_t pbkdfSaltMainBuf[128 + 8];
    if (pass_size > 0u && passwd != nullptr) {
        memcpy(pbkdfSaltMainBuf, pbkdfSaltMain, 8);
        memcpy(pbkdfSaltMainBuf + 8, passwd, pass_size);
        pbkdfSaltMain = pbkdfSaltMainBuf;
        pbkdfSaltMainLen = static_cast<uint32_t>(8u + pass_size);
    }

    uint32_t ipad[256 / 4];
    uint32_t opad[256 / 4];
    uint32_t seed[64 / 4];

    fastpbkdf2_hmac_sha512(reinterpret_cast<const uint8_t*>(phrase), static_cast<size_t>(phrase_len),
        pbkdfSaltMain, pbkdfSaltMainLen, pbkdf2_iterations, reinterpret_cast<uint8_t*>(seed), 64);

#pragma unroll
    for (int x = 0; x < 8; x++) {
        *(uint64_t*)((uint64_t*)seed + x) = SWAP512(*(uint64_t*)((uint64_t*)seed + x));
    }

#pragma unroll 4
    for (int x = 0; x < 16 / 4; x++) {
        ipad[x] = 0x36363636 ^ *(uint32_t*)((uint32_t*)&key_swap + x);
    }
#pragma unroll 4
    for (int x = 0; x < 16 / 4; x++) {
        opad[x] = 0x5C5C5C5C ^ *(uint32_t*)((uint32_t*)&key_swap + x);
    }
    for (int x = 16 / 4; x < 128 / 4; x++) {
        ipad[x] = 0x36363636;
        opad[x] = 0x5C5C5C5C;
    }
#pragma unroll 16
    for (int x = 0; x < 64 / 4; x++) {
        ipad[x + 128 / 4] = seed[x];
    }
    sha512_swap((uint64_t*)ipad, 192, (uint64_t*)&opad[128 / 4]);
    sha512_swap((uint64_t*)opad, 192, (uint64_t*)&ipad[128 / 4]);
#pragma unroll 16
    for (int x = 0; x < 128 / 8; x++) {
        *(uint64_t*)((uint64_t*)&ipad[128 / 4] + x) = SWAP512(*(uint64_t*)((uint64_t*)&ipad[128 / 4] + x));
    }

    memcpy(out_master_words, &ipad[128 / 4], RECOVERY_MASTER_WORDS * sizeof(uint32_t));
    return true;
}

// Device helper: evaluate one mnemonic candidate in fused secp256-only recovery path.
// Device helper: evaluate checksum-valid mnemonic using precomputed master key material.
static __device__ __forceinline__ void recovery_eval_candidate_master_secp_basic(
    bool* isResult,
    bool* buffResult,
    uint32_t starter,
    const secp256k1_ge_storage* __restrict__ precPtr,
    size_t precPitch,
    const uint16_t* ids,
    int words_count,
    const char (*dict)[34],
    const uint32_t* __restrict__ master_words,
    const uint32_t* __restrict__ d_derivations,
    const uint32_t* __restrict__ derindex,
    uint32_t der_indexes_size,
    uint32_t der_start_index,
    const char* __restrict__ passwd,
    uint32_t pass_size,
    uint64_t round) {

    if (master_words == nullptr || ids == nullptr || dict == nullptr) {
        return;
    }

    unsigned char pubKeys[65];
    unsigned char prvKeys[32];
    uint32_t hash160[8];
    uint32_t master_local[RECOVERY_MASTER_WORDS];

#pragma unroll
    for (int i = 0; i < static_cast<int>(RECOVERY_MASTER_WORDS); ++i) {
        master_local[i] = master_words[i];
    }

    extended_private_key_t* master_private = reinterpret_cast<extended_private_key_t*>(master_local);
    char* passStart = (char*)passwd;
    int passSize = static_cast<int>(pass_size);

    const bool compressed = compressed_dev;
    const bool uncompressed = uncompressed_dev;
    const bool segwit = segwit_dev;
    const bool taproot = taproot_dev;
    const bool ethereum = ethereum_dev;
    const bool xpoint = xpoint_dev;

    uint32_t processedElements_se = 0u;
    deriv_cache_secp256k1_t secp_deriv_cache = {};
    deriv_cache_secp256k1_t* secp_deriv_cache_ptr = (der_indexes_size > (der_start_index + 1u)) ? &secp_deriv_cache : nullptr;
    uint32_t c_path = 0u;

    for (uint32_t start_point = der_start_index; start_point < der_indexes_size; start_point++) {
        const uint32_t currentStringLength = derindex[start_point];

        pubKeys[0] = 0x4;
        int keylenskip = 0;
        get_child_key_secp256k1(precPtr, precPitch, master_private, d_derivations, currentStringLength, processedElements_se, prvKeys, secp_deriv_cache_ptr);

        int64_t current_round = 0;

        if (round > 0u) {
            bump_key_256(prvKeys, round, false);
        }

        for (uint64_t s = 0; s <= 2ull * round; s++) {
            current_round = static_cast<int64_t>(s) - static_cast<int64_t>(round);
            if (s == 0ull) {
                secp256k1_ec_pubkey_create((secp256k1_pubkey*)&pubKeys[1], (const uint8_t*)prvKeys, precPtr, precPitch);
            }

            if (uncompressed) {
                _GetHash160(pubKeys, keylenskip, (uint8_t*)hash160);
                if (checkHash(hash160)) {
                    recovery_store_found_from_ids(isResult, buffResult, starter, c_path, ids, words_count, dict, prvKeys, hash160, 32u, 0x01u, RESULT_DERIVATION_BIP32_SECP256K1, current_round, passStart, passSize);
                }
            }

            if (compressed) {
                _GetHash160Comp(pubKeys, keylenskip, (uint8_t*)hash160);
                if (checkHash(hash160)) {
                    recovery_store_found_from_ids(isResult, buffResult, starter, c_path, ids, words_count, dict, prvKeys, hash160, 32u, 0x02u, RESULT_DERIVATION_BIP32_SECP256K1, current_round, passStart, passSize);
                }
            }

            if (segwit) {
                if (!compressed) {
                    _GetHash160Comp(pubKeys, keylenskip, (uint8_t*)hash160);
                }
                _GetHash160P2SHCompFromHash(hash160, hash160);
                if (checkHash(hash160)) {
                    recovery_store_found_from_ids(isResult, buffResult, starter, c_path, ids, words_count, dict, prvKeys, hash160, 32u, 0x03u, RESULT_DERIVATION_BIP32_SECP256K1, current_round, passStart, passSize);
                }
            }

            if (ethereum) {
                unsigned char keccak_hash[32];
                uint32_t eth_hash160[8] = { 0 };
                keccak((char*)&pubKeys[1], 64, keccak_hash, 32);
                for (int h = 12, i = 0; i < 5; i++) {
                    eth_hash160[i] = (keccak_hash[h++]) |
                        ((keccak_hash[h++] << 8) & 0x0000ff00) |
                        ((keccak_hash[h++] << 16) & 0x00ff0000) |
                        ((keccak_hash[h++] << 24) & 0xff000000);
                }
                if (checkHash(eth_hash160)) {
                    recovery_store_found_from_ids(isResult, buffResult, starter, c_path, ids, words_count, dict, prvKeys, eth_hash160, 32u, 0x06u, RESULT_DERIVATION_BIP32_SECP256K1, current_round, passStart, passSize);
                }
            }

            if (taproot) {
                uint8_t tap_hash[32] = { 0 };
                TweakTaproot(tap_hash, pubKeys, precPtr, precPitch);
                _GetRMD160((uint32_t*)tap_hash, hash160);
                if (checkHash(hash160)) {
                    recovery_store_found_from_ids(isResult, buffResult, starter, c_path, ids, words_count, dict, prvKeys, tap_hash, 32u, 0x04u, RESULT_DERIVATION_BIP32_SECP256K1, current_round, passStart, passSize);
                }
            }

            if (xpoint) {
                uint32_t xpoint_hash[8];
                memcpy(xpoint_hash, pubKeys + 1, 32);
                if (checkHash(xpoint_hash)) {
                    recovery_store_found_from_ids(isResult, buffResult, starter, c_path, ids, words_count, dict, prvKeys, xpoint_hash, 32u, 0x05u, RESULT_DERIVATION_BIP32_SECP256K1, current_round, passStart, passSize);
                }
            }

            if (s < 2ull * round) {
                const bool wrapped = bump_key_256(prvKeys, 1u, true);
                if (wrapped) {
                    s += 2ull;
                    memcpy(pubKeys, SECP_G65, 65);
                }
                pub_add_basepoint_batch_from_prec(&pubKeys[0], 1, +1, precPtr);
            }
        }

        c_path++;
    }
}

// Kernel entry point: derive master key material for checksum-valid recovery candidates.
__global__ void workerRecoverySeedBatch(
    const uint16_t* batch_ids,
    int words_count,
    uint32_t batch_count,
    const char* __restrict__ passwd,
    uint32_t pass_size,
    const uint32_t* __restrict__ iterations,
    uint32_t iterations_size,
    uint32_t* batch_master_words) {

    const uint64_t tid64 = static_cast<uint64_t>(blockIdx.x) * static_cast<uint64_t>(blockDim.x) + static_cast<uint64_t>(threadIdx.x);
    const uint64_t stride = static_cast<uint64_t>(blockDim.x) * static_cast<uint64_t>(gridDim.x);
    const char (*dict)[34] = current_dict;

    if (dict == nullptr || batch_ids == nullptr || batch_master_words == nullptr || batch_count == 0u || iterations == nullptr || iterations_size == 0u) {
        return;
    }

    const size_t words_stride = static_cast<size_t>(words_count);
    char phrase[512];

    for (uint64_t idx = tid64; idx < static_cast<uint64_t>(batch_count); idx += stride) {
        const uint16_t* ids = batch_ids + (static_cast<size_t>(idx) * words_stride);
        uint32_t* out_master = batch_master_words + (static_cast<size_t>(idx) * static_cast<size_t>(RECOVERY_MASTER_WORDS));

        const uint32_t phrase_len = recovery_build_phrase_from_ids(ids, words_count, dict, phrase, static_cast<uint32_t>(sizeof(phrase)));
        const bool ok = (phrase_len != 0u) && recovery_build_master_words_from_phrase(
            phrase, phrase_len, passwd, pass_size, iterations, iterations_size, out_master);

        if (!ok) {
#pragma unroll
            for (int i = 0; i < static_cast<int>(RECOVERY_MASTER_WORDS); ++i) {
                out_master[i] = 0u;
            }
        }
    }
}

// Kernel entry point: evaluate checksum-valid candidates from precomputed master key material.
__global__ void workerRecoveryEvalMasterBatch(
    bool* isResult,
    bool* buffResult,
    const secp256k1_ge_storage* __restrict__ precPtr,
    size_t precPitch,
    const uint16_t* batch_ids,
    const uint32_t* batch_master_words,
    int words_count,
    uint32_t batch_count,
    const uint32_t* __restrict__ d_derivations,
    const uint32_t* __restrict__ derindex,
    uint32_t der_indexes_size,
    uint32_t der_start_index,
    const char* __restrict__ passwd,
    uint32_t pass_size,
    uint64_t round) {

    const uint64_t tid64 = static_cast<uint64_t>(blockIdx.x) * static_cast<uint64_t>(blockDim.x) + static_cast<uint64_t>(threadIdx.x);
    const uint64_t stride = static_cast<uint64_t>(blockDim.x) * static_cast<uint64_t>(gridDim.x);
    const uint32_t starter = static_cast<uint32_t>(tid64);
    const char (*dict)[34] = current_dict;

    if (dict == nullptr || batch_ids == nullptr || batch_master_words == nullptr || batch_count == 0u) {
        return;
    }

    const size_t words_stride = static_cast<size_t>(words_count);
    for (uint64_t idx = tid64; idx < static_cast<uint64_t>(batch_count); idx += stride) {
        const uint16_t* ids = batch_ids + (static_cast<size_t>(idx) * words_stride);
        const uint32_t* master_words = batch_master_words + (static_cast<size_t>(idx) * static_cast<size_t>(RECOVERY_MASTER_WORDS));

        bool empty_master = true;
#pragma unroll
        for (int i = 0; i < static_cast<int>(RECOVERY_MASTER_WORDS); ++i) {
            if (master_words[i] != 0u) {
                empty_master = false;
            }
        }
        if (empty_master) {
            continue;
        }

        recovery_eval_candidate_master_secp_basic(
            isResult,
            buffResult,
            starter,
            precPtr,
            precPitch,
            ids,
            words_count,
            dict,
            master_words,
            d_derivations,
            derindex,
            der_indexes_size,
            der_start_index,
            passwd,
            pass_size,
            round);
    }
}

// Host helper: launch recovery checksum kernel.
cudaError_t launchWorkerRecoveryChecksum(
    const uint16_t* d_base_ids,
    int words_count,
    const int* d_missing_positions,
    int missing_count,
    const uint16_t* d_word_options,
    uint32_t word_options_count,
    bool include_invalid,
    uint64_t range_start,
    uint64_t range_count,
    uint16_t* d_out_ids,
    uint32_t* d_out_count,
    uint32_t out_capacity,
    unsigned int block_count,
    unsigned int block_threads) {

    if (range_count == 0ull) {
        return cudaSuccess;
    }
    if (d_base_ids == nullptr || d_out_ids == nullptr || d_out_count == nullptr) {
        return cudaErrorInvalidValue;
    }
    if (words_count <= 0 || words_count > 48 || (words_count % 3) != 0) {
        return cudaErrorInvalidValue;
    }
    if (missing_count < 0 || missing_count > words_count) {
        return cudaErrorInvalidValue;
    }
    if (missing_count > 0 && d_missing_positions == nullptr) {
        return cudaErrorInvalidValue;
    }
    if (word_options_count == 0u || word_options_count > 65535u) {
        return cudaErrorInvalidValue;
    }
    if (out_capacity == 0u) {
        return cudaErrorInvalidValue;
    }

    if (block_threads == 0u) {
        block_threads = 256u;
    }
    if (block_count == 0u) {
        block_count = 1u;
    }

    switch (words_count) {
    case 12:
        workerRecoveryChecksumFixed<12> << <block_count, block_threads >> > (
            d_base_ids,
            d_missing_positions,
            missing_count,
            d_word_options,
            word_options_count,
            include_invalid,
            range_start,
            range_count,
            d_out_ids,
            d_out_count,
            out_capacity);
        break;
    case 24:
        workerRecoveryChecksumFixed<24> << <block_count, block_threads >> > (
            d_base_ids,
            d_missing_positions,
            missing_count,
            d_word_options,
            word_options_count,
            include_invalid,
            range_start,
            range_count,
            d_out_ids,
            d_out_count,
            out_capacity);
        break;
    default:
        workerRecoveryChecksum << <block_count, block_threads >> > (
            d_base_ids,
            words_count,
            d_missing_positions,
            missing_count,
            d_word_options,
            word_options_count,
            include_invalid,
            range_start,
            range_count,
            d_out_ids,
            d_out_count,
            out_capacity);
        break;
    }

    return cudaGetLastError();
}

// Host helper: launch recovery seed builder for checksum-valid candidate IDs.
cudaError_t launchWorkerRecoverySeedBatch(
    const uint16_t* d_batch_ids,
    int words_count,
    uint32_t batch_count,
    const char* d_passwd,
    uint32_t pass_size,
    const uint32_t* d_iterations,
    uint32_t iterations_size,
    uint32_t* d_batch_master_words,
    unsigned int block_count,
    unsigned int block_threads) {

    if (batch_count == 0u) {
        return cudaSuccess;
    }
    if (d_batch_ids == nullptr || d_passwd == nullptr || d_iterations == nullptr || d_batch_master_words == nullptr) {
        return cudaErrorInvalidValue;
    }
    if (words_count <= 0 || words_count > 48 || (words_count % 3) != 0) {
        return cudaErrorInvalidValue;
    }
    if (iterations_size == 0u) {
        return cudaErrorInvalidValue;
    }
    if (block_threads == 0u) {
        block_threads = 256u;
    }
    if (block_count == 0u) {
        block_count = 1u;
    }

    workerRecoverySeedBatch << <block_count, block_threads >> > (
        d_batch_ids,
        words_count,
        batch_count,
        d_passwd,
        pass_size,
        d_iterations,
        iterations_size,
        d_batch_master_words);

    return cudaGetLastError();
}

// Host helper: launch recovery evaluator from precomputed master key material.
cudaError_t launchWorkerRecoveryEvalMasterBatch(
    bool* d_is_result,
    bool* d_buff_result,
    const secp256k1_ge_storage* d_prec_ptr,
    size_t d_prec_pitch,
    const uint16_t* d_batch_ids,
    const uint32_t* d_batch_master_words,
    int words_count,
    uint32_t batch_count,
    const uint32_t* d_derivations,
    const uint32_t* d_derindex,
    uint32_t der_indexes_size,
    uint32_t der_start_index,
    const char* d_passwd,
    uint32_t pass_size,
    uint64_t round,
    unsigned int block_count,
    unsigned int block_threads) {

    if (batch_count == 0u) {
        return cudaSuccess;
    }
    if (d_is_result == nullptr || d_buff_result == nullptr || d_prec_ptr == nullptr || d_batch_ids == nullptr ||
        d_batch_master_words == nullptr || d_derivations == nullptr || d_derindex == nullptr || d_passwd == nullptr) {
        return cudaErrorInvalidValue;
    }
    if (words_count <= 0 || words_count > 48 || (words_count % 3) != 0) {
        return cudaErrorInvalidValue;
    }
    if (block_threads == 0u) {
        block_threads = 256u;
    }
    if (block_count == 0u) {
        block_count = 1u;
    }

    workerRecoveryEvalMasterBatch << <block_count, block_threads >> > (
        d_is_result,
        d_buff_result,
        d_prec_ptr,
        d_prec_pitch,
        d_batch_ids,
        d_batch_master_words,
        words_count,
        batch_count,
        d_derivations,
        d_derindex,
        der_indexes_size,
        der_start_index,
        d_passwd,
        pass_size,
        round);

    return cudaGetLastError();
}
