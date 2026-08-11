// Author: Mikhail Khoroshavin aka "XopMC"

#pragma once

#include "cuda_runtime.h"
#include "device_launch_parameters.h"
#include <curand_kernel.h>
#include <cuda.h>

#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <atomic>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "third_party/hash/GPUHash.cuh"
#include "third_party/hash/sha3_ver3.cuh"
#include "third_party/secp256k1/secp256k1_common.cuh"

#ifdef _DEBUG
#define THREAD_STEPS 3
#ifdef __CUDA_ARCH__
#define free(ptr)   /* nothing */
#define cudaFree(ptr) cudaErrorNotSupported
#endif
#else
#define THREAD_STEPS 32
#endif

#ifdef __CUDA_ARCH__
#else
#define atomicAdd(x, n) ((uint64_t)x + (uint64_t)n)
#define __noinline__
#endif

#define PREFIX_MAX_LEN 25
#define KERNEL_LAUNCH_BOUNDS

// Endomorphism tag layout for secp256k1 result types.
static constexpr uint8_t ENDO_TAG_BASE = 0xA0u;
static constexpr uint8_t ENDO_GROUP_STRIDE = 8u;
static constexpr uint8_t ENDO_GROUP_COMPRESSED = 0u;
static constexpr uint8_t ENDO_GROUP_SEGWIT = 1u;
static constexpr uint8_t ENDO_GROUP_UNCOMPRESSED = 2u;
static constexpr uint8_t ENDO_GROUP_ETH = 3u;
static constexpr uint8_t ENDO_GROUP_TAPROOT = 4u;
static constexpr uint8_t ENDO_GROUP_XPOINT = 5u;

// Recovery derivation-engine tags stored alongside found results.
static constexpr uint8_t RESULT_DERIVATION_BIP32_SECP256K1 = 1u;
static constexpr uint8_t RESULT_DERIVATION_SLIP0010_ED25519 = 2u;
static constexpr uint8_t RESULT_DERIVATION_ED25519_BIP32_TEST = 3u;

extern __constant__ uint32_t _NUM_TARGET_HASHES[1];
extern __constant__ uint32_t HASH_TARGET_WORDS[5];
extern __constant__ uint32_t HASH_TARGET_MASKS[5];
extern __constant__ uint32_t HASH_TARGET_LEN[1];
extern __constant__ uint32_t HASH_TARGET_ENABLED[1];

extern __constant__ __align__(8) uint8_t* _BLOOM_FILTER[100];

extern __device__ __align__(8) uint32_t* fingerprints_d[25];
extern __device__ __align__(8) size_t size_d[25];
extern __device__ __align__(8) size_t arrayLength_d[25];
extern __device__ __align__(8) size_t segmentCount_d[25];
extern __device__ __align__(8) size_t segmentCountLength_d[25];
extern __device__ __align__(8) size_t segmentLength_d[25];
extern __device__ __align__(8) size_t segmentLengthMask_d[25];

extern __constant__ __align__(8) uint32_t* fingerprints_d_Un[25];
extern __device__ __align__(8) size_t size_d_Un[25];
extern __device__ __align__(8) size_t arrayLength_d_Un[25];
extern __device__ __align__(8) size_t segmentCount_d_Un[25];
extern __constant__ __align__(8) size_t segmentCountLength_d_Un[25];
extern __constant__ __align__(8) size_t segmentLength_d_Un[25];
extern __constant__ __align__(8) size_t segmentLengthMask_d_Un[25];

extern __device__ __align__(8) uint16_t* fingerprints_d_Uc[25];
extern __device__ __align__(8) size_t size_d_Uc[25];
extern __device__ __align__(8) size_t arrayLength_d_Uc[25];
extern __device__ __align__(8) size_t segmentCount_d_Uc[25];
extern __device__ __align__(8) size_t segmentCountLength_d_Uc[25];
extern __device__ __align__(8) size_t segmentLength_d_Uc[25];
extern __device__ __align__(8) size_t segmentLengthMask_d_Uc[25];

extern __device__ __align__(8) uint8_t* fingerprints_d_Hc[25];
extern __device__ __align__(8) size_t size_d_Hc[25];
extern __device__ __align__(8) size_t arrayLength_d_Hc[25];
extern __device__ __align__(8) size_t segmentCount_d_Hc[25];
extern __device__ __align__(8) size_t segmentCountLength_d_Hc[25];
extern __device__ __align__(8) size_t segmentLength_d_Hc[25];
extern __device__ __align__(8) size_t segmentLengthMask_d_Hc[25];

extern __device__ __align__(8) const char (*current_dict)[34];
extern __device__ curandState state;

extern __constant__ uint32_t _USE_BLOOM_FILTER[1];
extern __constant__ int _bloom_count[1];
extern __device__ int _xor_count[1];
extern __constant__ int _xor_un_count[1];
extern __device__ int _xor_uc_count[1];
extern __device__ int _xor_hc_count[1];
extern __device__ bool useBloom_d;
extern __device__ bool useXor_d;
extern __device__ bool useXorUn_d;
extern __device__ bool useXorUc_d;
extern __device__ bool useXorHc_d;

extern __constant__ __align__(4) uint8_t salt[12];
extern __constant__ __align__(4) uint8_t salt_swap[16];
extern __constant__ __align__(4) uint8_t ton_salt1[20];
extern __constant__ __align__(4) uint8_t ton_seed_swap[24];
extern __constant__ __align__(4) uint8_t ton_salt[16];
extern __constant__ __align__(4) uint8_t key001[16];
extern __constant__ __align__(4) uint8_t key[12];
extern __constant__ __align__(4) uint8_t ed_key[12];
extern __constant__ __align__(4) uint8_t ed_key_swap[16];
extern __constant__ __align__(4) uint8_t key_swap[16];

extern __constant__ __align__(64) uint8_t SECP_G65[65];

extern __device__ unsigned long long int d_resultsCount[1];

extern __device__ char (*d_foundStrings)[512];
extern __device__ unsigned char (*d_foundPrvKeys)[64];
extern __device__ uint32_t (*d_foundHash160)[20];
extern __device__ uint32_t (*d_len)[1];
extern __device__ uint8_t* d_type;
extern __device__ uint8_t* d_resultDerivationType;
extern __device__ int64_t* d_round;
extern __device__ uint32_t* d_foundDerivations;
extern __device__ char (*d_pass)[128];
extern __device__ uint16_t* d_pass_size;

extern __device__ bool secp256_d;
extern __device__ bool ed25519_d;
extern __device__ bool ed25519_bip32_d;
extern __device__ bool compressed_dev;
extern __device__ bool uncompressed_dev;
extern __device__ bool segwit_dev;
extern __device__ bool taproot_dev;
extern __device__ bool ethereum_dev;
extern __device__ bool xpoint_dev;
extern __device__ bool solana_dev;
extern __device__ bool ton_dev;
extern __device__ bool ton_all_dev;

extern __device__ uint64_t Seed;
extern __device__ uint64_t pbkdf2_iterations;
extern __device__ uint32_t MAX_FOUNDS_DEV;
extern __device__ bool FULL_d;
extern __device__ bool IS_PASS;

extern uint64_t false_positive;
extern bool STOP_THREAD;
extern uint64_t pbkdf_iter;
extern uint32_t MAX_FOUNDS;
extern bool FULL;

extern std::vector<std::thread> g_save_threads;
extern std::mutex g_save_threads_mutex;

typedef struct __align__(16) {
    uint8_t key[32];
    uint8_t chain_code[32];
} extended_private_key_t;

typedef struct __align__(16) {
    uint8_t key[64];
    uint8_t chain_code[32];
} extended_public_key_t;

typedef struct __align__(16) {
    uint64_t inner_H[8];
    uint64_t outer_H[8];
} hmac_sha512_precomp_t;

cudaError_t loadHashTarget(const uint32_t words[5], const uint32_t masks[5], uint32_t lenBytes, bool enabled);
cudaError_t cudaMemcpyToSymbol_BLOOM_FILTER(uint8_t* bloom_filter_ptr, int count);
cudaError_t cudaMemcpyToSymbol_XOR(uint32_t* deviceFilter, int count, size_t size_h, size_t arrayLength_h, size_t segmentCount_h, size_t segmentCountLength_h, size_t segmentLength_h, size_t segmentLengthMask_h);
cudaError_t cudaMemcpyToSymbol_XORUn(uint32_t* deviceFilter, int count, size_t size_h, size_t arrayLength_h, size_t segmentCount_h, size_t segmentCountLength_h, size_t segmentLength_h, size_t segmentLengthMask_h);
cudaError_t cudaMemcpyToSymbol_XORUc(uint16_t* deviceFilter, int count, size_t size_h, size_t arrayLength_h, size_t segmentCount_h, size_t segmentCountLength_h, size_t segmentLength_h, size_t segmentLengthMask_h);
cudaError_t cudaMemcpyToSymbol_XORHc(uint8_t* deviceFilter, int count, size_t size_h, size_t arrayLength_h, size_t segmentCount_h, size_t segmentCountLength_h, size_t segmentLength_h, size_t segmentLengthMask_h);
cudaError_t loadWindow(unsigned int windowSize, unsigned int windows);

__global__ void setFULL();
__global__ void setPASS();
__global__ void setFoundSize(uint32_t max_founds);
__global__ void setDict(int lang);
__global__ void setDictPointer(const char (*dict)[34]);
__global__ void rand_state();
__global__ void setFilterType(bool bloomUse, bool xorFilter, bool xorFilterUn, bool xorFilterUc, bool xorFilterHc);
__global__ void SetCurve(bool secp256, bool ed25519, bool ed25519_bip32, bool compressed, bool uncompressed, bool segwit, bool taproot, bool ethereum, bool xpoint, bool solana, bool ton, bool ton_all);
__global__ void set_iter(uint64_t pbkdf_iter);
__global__ void ecmult_big_create(secp256k1_gej* gej_temp, secp256k1_fe* z_ratio, secp256k1_ge_storage* precPtr, size_t precPitch, unsigned int bits);

__host__ void setSilentMode();
__host__ void setPassMode();
void recovery_console_write_status_line(const std::string& line);
void recovery_console_clear_status_line();
void recovery_console_write_stdout_line(const std::string& line);

// Recovery compatibility evaluator used after checksum filtering.
__global__ void workerRecoveryCompat(bool* isResult, bool* buffResult, const secp256k1_ge_storage* __restrict__ precPtr, const size_t precPitch, char* __restrict__ lines, const uint32_t* __restrict__ indexes, const uint32_t indexes_size, const uint32_t* __restrict__ d_derivations, const uint32_t* __restrict__ derindex, const uint32_t der_indexes_size, const uint32_t der_start_index, const char* __restrict__ passwd, const uint32_t pass_size, uint64_t round);

__global__ void workerRecoveryChecksum(const uint16_t* base_ids, int words_count, const int* missing_positions, int missing_count, const uint16_t* word_options, uint32_t word_options_count, bool include_invalid, uint64_t range_start, uint64_t range_count, uint16_t* out_ids, uint32_t* out_count, uint32_t out_capacity);
__global__ void workerRecoverySeedBatch(const uint16_t* batch_ids, int words_count, uint32_t batch_count, const char* __restrict__ passwd, uint32_t pass_size, const uint32_t* __restrict__ iterations, uint32_t iterations_size, uint32_t* batch_master_words);
__global__ void workerRecoveryEvalMasterBatch(bool* isResult, bool* buffResult, const secp256k1_ge_storage* __restrict__ precPtr, size_t precPitch, const uint16_t* batch_ids, const uint32_t* batch_master_words, int words_count, uint32_t batch_count, const uint32_t* __restrict__ d_derivations, const uint32_t* __restrict__ derindex, uint32_t der_indexes_size, uint32_t der_start_index, const char* __restrict__ passwd, uint32_t pass_size, uint64_t round);

cudaError_t launchWorkerRecoveryChecksum(const uint16_t* d_base_ids, int words_count, const int* d_missing_positions, int missing_count, const uint16_t* d_word_options, uint32_t word_options_count, bool include_invalid, uint64_t range_start, uint64_t range_count, uint16_t* d_out_ids, uint32_t* d_out_count, uint32_t out_capacity, unsigned int block_count, unsigned int block_threads);
cudaError_t launchWorkerRecoverySeedBatch(const uint16_t* d_batch_ids, int words_count, uint32_t batch_count, const char* d_passwd, uint32_t pass_size, const uint32_t* d_iterations, uint32_t iterations_size, uint32_t* d_batch_master_words, unsigned int block_count, unsigned int block_threads);
cudaError_t launchWorkerRecoveryEvalMasterBatch(bool* d_is_result, bool* d_buff_result, const secp256k1_ge_storage* d_prec_ptr, size_t d_prec_pitch, const uint16_t* d_batch_ids, const uint32_t* d_batch_master_words, int words_count, uint32_t batch_count, const uint32_t* d_derivations, const uint32_t* d_derindex, uint32_t der_indexes_size, uint32_t der_start_index, const char* d_passwd, uint32_t pass_size, uint64_t round, unsigned int block_count, unsigned int block_threads);

__device__ bool bump_key_256(uint8_t* __restrict__ prv32, uint64_t n, bool plus);

__host__ void SaveResult(FILE* file, std::atomic_uint32_t& Founds, bool save, std::vector<std::string> Der_list);

__device__ uint32_t SWAP256(uint32_t val);
__device__ uint64_t SWAP512(uint64_t val);
__device__ void md_pad_128(uint64_t* msg, const long msgLen_bytes);
__device__ void sha256_process2(const uint32_t* W, uint32_t* digest);
__device__ void sha512_d(uint64_t* input, const uint32_t length, uint64_t* hash);
__device__ void md_pad_128_swap(uint64_t* msg, const long msgLen_bytes);
__device__ void sha512_swap(uint64_t* input, const uint32_t length, uint64_t* hash);
__device__ void hmac_sha512_const(const uint32_t* key, const uint32_t* message, uint32_t* output);
__device__ void hmac_sha512_const_precompute(const uint32_t* key, hmac_sha512_precomp_t* ctx);
__device__ void hmac_sha512_const_precomp(const hmac_sha512_precomp_t* ctx, const uint32_t* message, uint32_t* output);
__device__ void sha256_d(const uint32_t* pass, int pass_len, uint32_t* hash);
__device__ void sha256_swap_64(const uint32_t* pass, uint32_t* hash);

__device__ bool pubkey_to_hash_ton(const uint8_t* public_key, const char* type, uint8_t* out, size_t out_len = 32);
__device__ void ton_to_masterkey(char* __restrict__ mnem, uint64_t len, const char* passwd, uint32_t pass_size, extended_private_key_t* out_master);

__device__ uint64_t rng_splitmix64(uint64_t* seed);
__device__ bool checkHashEth(const unsigned char d_hash[32]);
__device__ bool bloom_chk_hash160(const unsigned char* bloom, const uint32_t* h);
__device__ uint64_t fnv1a_64(const uint8_t* buffer, size_t length);
__device__ bool checkHash(const uint32_t hash[5]);

__device__ void hardened_private_child_from_private(const extended_private_key_t* parent, extended_private_key_t* child, uint32_t hardened_child_number);
__device__ void normal_private_child_from_private(const secp256k1_ge_storage* __restrict__ precPtr, const size_t precPitch, const extended_private_key_t* parent, extended_private_key_t* child, uint32_t normal_child_number);
__device__ void normal_private_child_from_private_cached_pub(const extended_private_key_t* parent, extended_private_key_t* child, uint32_t normal_child_number, const uint8_t* cached_serialized_pub);
__device__ void normal_private_child_from_private_save_pub(const secp256k1_ge_storage* __restrict__ precPtr, const size_t precPitch, const extended_private_key_t* parent, extended_private_key_t* child, uint32_t normal_child_number, uint8_t* out_serialized_pub);
__device__ void normal_private_child_from_private_cached_pub_precomp(const extended_private_key_t* parent, extended_private_key_t* child, uint32_t normal_child_number, const uint8_t* cached_serialized_pub, const hmac_sha512_precomp_t* hctx);
__device__ void hardened_private_child_from_private_precomp(const extended_private_key_t* parent, extended_private_key_t* child, uint32_t hardened_child_number, const hmac_sha512_precomp_t* hctx);
__device__ void hardened_private_child_from_private_ed25519(const extended_private_key_t* parent, extended_private_key_t* child, uint32_t hardened_child_number);
__device__ void hardened_private_child_from_private_ed25519_precomp(const extended_private_key_t* parent, extended_private_key_t* child, uint32_t hardened_child_number, const hmac_sha512_precomp_t* hctx);
__device__ void ed25519_bip32_ckd_priv_hardened(const extended_private_key_t* parent, extended_private_key_t* child, uint32_t i_hardened);
__device__ void ed25519_bip32_ckd_priv_normal(const extended_private_key_t* parent, extended_private_key_t* child, uint32_t i_normal);

__device__ void GenerateMnemonic(const char* __restrict__ entropy, size_t entropy_size, char* __restrict__ mnemonic_phrase, const char (*words)[34], size_t& mnemo_len);
__device__ bool mnemonic_to_entropy(const char* phrase, int slen, uint8_t* out_entropy, uint32_t* out_len);
__device__ void random32(uint32_t* output, int size);
__device__ size_t TweakTaproot_batch(uint8_t* __restrict__ out, const uint8_t* __restrict__ pub_uncomp, const int count, const secp256k1_ge_storage* __restrict__ precPtr, const size_t precPitch);
__device__ void TweakTaproot(uint8_t* __restrict__ out, const uint8_t* __restrict__ pub_uncomp, const secp256k1_ge_storage* __restrict__ precPtr, const size_t precPitch);
