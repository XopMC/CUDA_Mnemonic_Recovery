// Author: Mikhail Khoroshavin aka "XopMC"

#if defined(_WIN64) && !defined(__CYGWIN__) && !defined(__MINGW64__)
#ifndef _HAS_STD_BYTE
#define _HAS_STD_BYTE 0
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#endif

#include <iostream>
#include <algorithm>
#include <sstream>
#include <fstream>
#include <stdio.h>
#include <stdlib.h>
#include <chrono>
#include <set>
#include <thread>
#include <mutex>
#include <condition_variable>
#include <shared_mutex>
#include <queue>
#include "cuda/Kernel.cuh"
#include "app/recovery_app.h"
#include "app/recovery_cli.h"
#include "app/recovery_config.h"
#include "recovery/RecoveryWordlistsEmbedded.h"
#include "third_party/hash/sha256.h"
#include "support/xor_filter.cuh"
#include "support/CudaHashLookup.h"
#include <cuda_runtime.h>
#include <curand_kernel.h>
#include <random>
#include <iomanip>
#include <future>
#include <vector>
#include <unordered_map>
#include <unordered_set>
#include <memory>
#include <stdexcept>
#include <atomic>
#include <cctype>
#include <cstring>
#include <string>
#include <limits>
#include <cmath>
#include <functional>
#include "recovery/filter.h"
//#include <experimental/filesystem>
#if defined(_WIN64) && !defined(__CYGWIN__) && !defined(__MINGW64__)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef _HAS_STD_BYTE
#define _HAS_STD_BYTE 0
#endif
#include <windows.h>
#include <dbghelp.h>
#include <io.h>
#include <fcntl.h>
#pragma comment(lib, "Dbghelp.lib")
#else
#include <dirent.h>
#include <sys/stat.h>
#include <unistd.h>
#endif
//#include <tbb/concurrent_queue.h>
//#include <tbb/tbb.h>
#define BLOOM_SIZE (512*1024*1024)

using namespace std;

std::vector<std::thread> g_save_threads;
std::mutex g_save_threads_mutex;
bool g_save_output_with_gpu_prefix = false;
bool FULL = false;

enum class DerivationPolicy : uint8_t {
    Auto = 0,
    ForceBip32Secp256k1 = 1,
    ForceSlip0010Ed25519 = 2,
    Mixed = 3,
    ForceEd25519Bip32Test = 4
};

static bool Ethereum = false;
static bool Compressed = true;
static bool Uncompressed = true;
static bool Segwit = true;
static bool Taproot = false;
static bool Xpoint = false;
static bool Solana = false;
static bool Ton = false;
static bool Ton_all = false;

static DerivationPolicy g_derivation_policy = DerivationPolicy::Auto;
static bool secp256_host = false;
static bool ed25519_host = false;
static bool ed25519_bip32_host = false;
static bool secp_target_host = true;
static bool ed25519_target_host = false;

static bool has_secp_targets_selected() {
    return Ethereum || Compressed || Uncompressed || Segwit || Xpoint || Taproot;
}

static bool has_ed25519_targets_selected() {
    return Solana || Ton || Ton_all;
}

static bool configure_derivation_policy_runtime() {
    secp_target_host = has_secp_targets_selected();
    ed25519_target_host = has_ed25519_targets_selected();
    const bool any_target_selected = secp_target_host || ed25519_target_host;

    switch (g_derivation_policy) {
    case DerivationPolicy::Auto:
        secp256_host = secp_target_host;
        ed25519_host = ed25519_target_host;
        ed25519_bip32_host = false;
        return any_target_selected;
    case DerivationPolicy::ForceBip32Secp256k1:
        secp256_host = any_target_selected;
        ed25519_host = false;
        ed25519_bip32_host = false;
        return any_target_selected;
    case DerivationPolicy::ForceSlip0010Ed25519:
        secp256_host = false;
        ed25519_host = any_target_selected;
        ed25519_bip32_host = false;
        return any_target_selected;
    case DerivationPolicy::Mixed:
        secp256_host = any_target_selected;
        ed25519_host = any_target_selected;
        ed25519_bip32_host = false;
        return any_target_selected;
    case DerivationPolicy::ForceEd25519Bip32Test:
        secp256_host = false;
        ed25519_host = false;
        ed25519_bip32_host = any_target_selected;
        return any_target_selected;
    default:
        secp256_host = false;
        ed25519_host = false;
        ed25519_bip32_host = false;
        return false;
    }
}

uint64_t pbkdf_iter = 2048;
vector<uint32_t> Iterations = { 1 };

static int language = 0;
static int chunks = 1;
static int keys_per_chunk = 1024;  // Vanity baseline chunk size is 1024 keys.
static int THREAD_STEPS_PUB_H = keys_per_chunk * chunks;

uint32_t MAX_FOUNDS = 150000;
bool pass_set = false;

uint8_t start_pass_point[128] = { 0 };
uint8_t end_pass_point[128] = { 0xff };

std::string passwords;
vector<string> passwords_list;
vector<uint32_t> passwords_lenght;
vector<string> passwords_files;

enum class RecoveryQueueEntryType {
    Phrase,
    File
};

struct RecoveryQueueEntry {
    RecoveryQueueEntryType type = RecoveryQueueEntryType::Phrase;
    std::string value;
};

struct RecoveryWordlist {
    std::string id;
    std::string file_name;
    std::string path;
    std::string name;
    std::vector<std::string> words;
    std::vector<std::string> words_norm;
    std::unordered_map<std::string, int> id_by_norm;
    std::vector<uint16_t> word_options;
    size_t source_word_count = 0u;
    int device_lang = -1;
    bool external = false;
    bool standard_subset = false;
    bool auto_nvalid = false;
};

struct RecoveryTemplateInput {
    std::string source;
    size_t line_no = 0;
    std::string phrase;
};

struct RecoveryPreparedTask {
    std::string source;
    size_t line_no = 0;
    const RecoveryWordlist* wordlist = nullptr;
    std::vector<int> ids;
    std::vector<int> missing_positions;
    size_t word_options_count = 0u;
    bool wordlist_source_is_standard_subset = false;
    bool effective_nvalid = false;
    std::string normalized_phrase;
    size_t added_stars = 0;
    std::vector<std::pair<std::string, std::string>> replacements;
};

struct RecoverySourceStats {
    std::string label;
    bool is_file = false;
    uint64_t processed = 0ull;
    uint64_t skipped = 0ull;
    uint64_t tested = 0ull;
    uint64_t emitted = 0ull;
    uint64_t found = 0ull;
};

bool RECOVERY_MODE = false;
std::vector<RecoveryQueueEntry> recoveryQueue;
std::string recoveryForcedWordlist;
bool recoveryIncludeInvalid = false;

struct RecoveryMultiGpuPartition {
    bool enabled = false;
    size_t index = 0;
    size_t count = 1;
};
thread_local RecoveryMultiGpuPartition g_recovery_multi_gpu_partition;

struct RecoveryRunStats {
    uint64_t tested_total = 0ull;
    uint64_t emitted_total = 0ull;
};
thread_local RecoveryRunStats g_recovery_run_stats;

struct RecoveryGpuDirectContext {
    uint64_t batch_capacity = 0;
    bool* buffIsResult = nullptr;
    bool* buffDeviceResult = nullptr;
    char* devLines = nullptr;
    uint32_t* devIndexes = nullptr;
    uint32_t* devDerivationList = nullptr;
    uint32_t* devDerIndex = nullptr;
    uint32_t* devIter = nullptr;
    uint32_t iteration_size = 0;
    bool kernel_inflight = false;
    std::string combined;
    std::vector<uint32_t> indexes;
    char(*devRecoveryDict)[34] = nullptr;
    size_t devRecoveryDictWords = 0;
    const RecoveryWordlist* activeWordlist = nullptr;
};

thread_local char* passwords_dev = nullptr;
thread_local size_t passwords_dev_capacity = 0;
thread_local uint32_t passwords_lenght_dev = 0;
thread_local bool* shared_result_flag = nullptr;
thread_local bool* shared_result_buffer = nullptr;
thread_local size_t shared_result_buffer_capacity = 0;

//device founds arrays ptr
thread_local char* p_str = nullptr;
thread_local unsigned char* p_prv = nullptr;
thread_local uint32_t* p_h160 = nullptr;
thread_local uint8_t* p_typ = nullptr;
thread_local uint8_t* p_result_derivation_type = nullptr;
thread_local uint32_t* p_len1 = nullptr;
thread_local uint32_t* p_der = nullptr;
thread_local char* p_pas = nullptr;
thread_local uint16_t* p_pas_size = nullptr;
thread_local int64_t* p_round = nullptr;
thread_local uint64_t* p_seed = nullptr;
thread_local unsigned long long* p_results_count = nullptr;
thread_local size_t free_gpu_start = 0;
thread_local size_t total_gpu_start = 0;
thread_local size_t free_gpu_end = 0;
thread_local size_t total_gpu_end = 0;


#if defined(_WIN32) || defined(_WIN64)
thread_local const char* g_crash_stage = "startup";
thread_local int g_crash_device_hint = -1;

// CrashHandler: prints crash context and aborts execution on unhandled exceptions.
static LONG WINAPI CrashHandler(EXCEPTION_POINTERS* p) {
    std::fprintf(stderr, "\n[CRASH] code=0x%08X addr=%p stage=%s gpu_hint=%d\n",
        (unsigned)p->ExceptionRecord->ExceptionCode,
        p->ExceptionRecord->ExceptionAddress,
        g_crash_stage ? g_crash_stage : "(null)",
        g_crash_device_hint);
    HANDLE proc = GetCurrentProcess();
    SymInitialize(proc, nullptr, TRUE);
    unsigned char symbol_buffer[sizeof(SYMBOL_INFO) + MAX_SYM_NAME] = {};
    PSYMBOL_INFO symbol = reinterpret_cast<PSYMBOL_INFO>(symbol_buffer);
    symbol->SizeOfStruct = sizeof(SYMBOL_INFO);
    symbol->MaxNameLen = MAX_SYM_NAME;
    DWORD64 displacement = 0;
    const DWORD64 addr = reinterpret_cast<DWORD64>(p->ExceptionRecord->ExceptionAddress);
    if (SymFromAddr(proc, addr, &displacement, symbol)) {
        std::fprintf(stderr, "[CRASH] symbol=%s+0x%llx\n", symbol->Name, static_cast<unsigned long long>(displacement));
    }
    SymCleanup(proc);
    std::fflush(stderr);
    return EXCEPTION_EXECUTE_HANDLER;
}
#define SET_CRASH_STAGE(stage_name) do { g_crash_stage = (stage_name); } while(0)
#define SET_CRASH_GPU_HINT(device_id) do { g_crash_device_hint = (device_id); } while(0)
#else
#define SET_CRASH_STAGE(stage_name) do {} while(0)
#define SET_CRASH_GPU_HINT(device_id) do {} while(0)
#endif

unsigned char*
hex(unsigned char* buf, size_t buf_sz,
    unsigned char* hexed, size_t hexed_sz) {
    int i, j;
    --hexed_sz;
    for (i = j = 0; i < buf_sz && j < hexed_sz; ++i, j += 2) {
        snprintf((char*)hexed + j, 3, "%02x", buf[i]);
    }
    hexed[j] = 0; // null terminate
    return hexed;
}

// hex_nibble_value: converts nibble value.
static inline int hex_nibble_value(const char c) {
    if (c >= '0' && c <= '9') return (int)(c - '0');
    const char cl = (char)(c | 0x20);
    if (cl >= 'a' && cl <= 'f') return (int)(cl - 'a' + 10);
    return -1;
}

static inline bool parse_hash_target_argument(
    const char* arg,
    uint32_t out_words[5],
    uint32_t out_masks[5],
    uint32_t& out_len_bytes,
    std::string& out_hex,
    std::string& err) {

    if (arg == nullptr) {
        err = "value is missing";
        return false;
    }

    std::string s(arg);
    if (s.size() >= 2 && s[0] == '0' && ((s[1] | 0x20) == 'x')) {
        s.erase(0, 2);
    }

    if (s.empty()) {
        err = "value is empty";
        return false;
    }
    if ((s.size() & 1u) != 0u) {
        err = "hex length must be even";
        return false;
    }
    if (s.size() < 8u || s.size() > 40u) {
        err = "expects 4..20 bytes (8..40 hex chars)";
        return false;
    }
    for (const char ch : s) {
        if (!std::isxdigit(static_cast<unsigned char>(ch))) {
            err = "contains non-hex characters";
            return false;
        }
    }

    uint8_t bytes[20] = { 0 };
    const size_t len_bytes = s.size() / 2u;
    for (size_t i = 0; i < len_bytes; ++i) {
        const int hi = hex_nibble_value(s[i * 2]);
        const int lo = hex_nibble_value(s[i * 2 + 1]);
        if (hi < 0 || lo < 0) {
            err = "contains non-hex characters";
            return false;
        }
        bytes[i] = static_cast<uint8_t>((hi << 4) | lo);
    }

    memset(out_words, 0, sizeof(uint32_t) * 5);
    memcpy(out_words, bytes, len_bytes);

    for (size_t w = 0; w < 5; ++w) {
        const size_t word_start = w * 4u;
        if (word_start >= len_bytes) {
            out_masks[w] = 0u;
            continue;
        }
        const size_t remain = len_bytes - word_start;
        if (remain >= 4u) {
            out_masks[w] = 0xFFFFFFFFu;
        }
        else {
            out_masks[w] = (1u << (remain * 8u)) - 1u;
        }
    }

    out_len_bytes = static_cast<uint32_t>(len_bytes);
    out_hex = s;
    std::transform(out_hex.begin(), out_hex.end(), out_hex.begin(), [](unsigned char c) {
        return static_cast<char>(std::tolower(c));
        });
    return true;
}

// ensure_password_device_capacity: ensures password device capacity.
static inline cudaError_t ensure_password_device_capacity(size_t bytes) {
    if (bytes == 0) {
        bytes = 1;
    }
    if (passwords_dev == nullptr || passwords_dev_capacity < bytes) {
        char* new_buffer = nullptr;
        cudaError_t st = cudaMalloc((void**)&new_buffer, bytes);
        if (st != cudaSuccess) {
            return st;
        }
        if (passwords_dev != nullptr) {
            cudaFree(passwords_dev);
        }
        passwords_dev = new_buffer;
        passwords_dev_capacity = bytes;
    }
    return cudaSuccess;
}

// copy_password_to_device: copies password to device.
static inline cudaError_t copy_password_to_device(const void* src, size_t bytes) {
    cudaError_t st = ensure_password_device_capacity(bytes);
    if (st != cudaSuccess) {
        return st;
    }
    if (bytes == 0) {
        return cudaSuccess;
    }
    return cudaMemcpyAsync(passwords_dev, src, bytes, cudaMemcpyHostToDevice);
}

thread_local static std::unordered_map<void**, size_t> g_device_buffer_capacities;

// ensure_device_buffer_capacity: ensures device buffer capacity.
static inline cudaError_t ensure_device_buffer_capacity(void** device_ptr, size_t bytes) {
    if (bytes == 0) {
        bytes = 1;
    }

    size_t& capacity = g_device_buffer_capacities[device_ptr];
    if (*device_ptr == nullptr || capacity < bytes) {
        void* new_buffer = nullptr;
        cudaError_t st = cudaMalloc(&new_buffer, bytes);
        if (st != cudaSuccess) {
            return st;
        }
        if (*device_ptr != nullptr) {
            cudaFree(*device_ptr);
        }
        *device_ptr = new_buffer;
        capacity = bytes;
    }
    return cudaSuccess;
}

// copy_to_device_grow: copies to device grow.
static inline cudaError_t copy_to_device_grow(void** device_ptr, const void* src, size_t bytes) {
    cudaError_t st = ensure_device_buffer_capacity(device_ptr, bytes);
    if (st != cudaSuccess) {
        return st;
    }
    if (bytes == 0) {
        return cudaSuccess;
    }
    return cudaMemcpyAsync(*device_ptr, src, bytes, cudaMemcpyHostToDevice);
}

// trim_crlf_inplace: trims crlf inplace.
static inline void trim_crlf_inplace(std::string& line) {
    if (!line.empty() && line.back() == '\r') {
        line.pop_back();
    }
}

// truncate_inplace: truncates inplace.
static inline void truncate_inplace(std::string& line, const size_t max_len) {
    if (line.size() > max_len) {
        line.resize(max_len);
    }
}

static std::mutex g_cuda_context_api_mutex;

// read_trimmed_line: reads trimmed line.
static inline bool read_trimmed_line(std::istream& stream, std::string& line, const size_t max_len) {
    if (!std::getline(stream, line)) {
        return false;
    }
    trim_crlf_inplace(line);
    truncate_inplace(line, max_len);
    return true;
}

// tune_ifstream_buffer: tunes ifstream buffer.
static inline void tune_ifstream_buffer(std::ifstream& stream) {
    static std::mutex s_ifstream_buf_mutex;
    static std::unordered_map<std::streambuf*, std::vector<char>> s_ifstream_bufs;

    std::streambuf* const buf = stream.rdbuf();
    if (buf == nullptr) {
        return;
    }

    std::lock_guard<std::mutex> guard(s_ifstream_buf_mutex);
    auto it = s_ifstream_bufs.find(buf);
    if (it == s_ifstream_bufs.end()) {
        it = s_ifstream_bufs.emplace(buf, std::vector<char>(4u << 20)).first;
    }
    else if (it->second.empty()) {
        it->second.resize(4u << 20);
    }
    buf->pubsetbuf(it->second.data(), static_cast<std::streamsize>(it->second.size()));
}

// reserve_batch_buffers: reserves batch buffers.
static inline void reserve_batch_buffers(std::string& combined, std::vector<uint32_t>& indexes, const uint64_t output_threads, const size_t max_line_len) {
    const size_t reserve_lines = (size_t)std::min<uint64_t>(output_threads, 1u << 20);
    if (indexes.capacity() < reserve_lines) {
        indexes.reserve(reserve_lines);
    }
    const size_t reserve_bytes = std::min<size_t>(reserve_lines * max_line_len, 128u * 1024u * 1024u);
    if (combined.capacity() < reserve_bytes) {
        combined.reserve(reserve_bytes);
    }
}

static inline void reset_password_stream_cache();

// init_shared_result_buffers_for_current_gpu: initializes shared result buffers for current GPU.
static inline cudaError_t init_shared_result_buffers_for_current_gpu(const uint64_t capacity_entries) {
    const uint64_t safe_entries = (capacity_entries == 0) ? 1ull : capacity_entries;
    if (shared_result_flag != nullptr && shared_result_buffer != nullptr && shared_result_buffer_capacity >= safe_entries) {
        return cudaSuccess;
    }

    if (shared_result_flag != nullptr) {
        cudaFree(shared_result_flag);
        shared_result_flag = nullptr;
    }
    if (shared_result_buffer != nullptr) {
        cudaFree(shared_result_buffer);
        shared_result_buffer = nullptr;
        shared_result_buffer_capacity = 0;
    }

    cudaError_t st = cudaMalloc(reinterpret_cast<void**>(&shared_result_flag), sizeof(bool));
    if (st != cudaSuccess) {
        return st;
    }
    st = cudaMalloc(reinterpret_cast<void**>(&shared_result_buffer), static_cast<size_t>(safe_entries) * sizeof(bool));
    if (st != cudaSuccess) {
        cudaFree(shared_result_flag);
        shared_result_flag = nullptr;
        return st;
    }
    shared_result_buffer_capacity = static_cast<size_t>(safe_entries);
    return cudaSuccess;
}

// reset_thread_local_gpu_runtime_aliases_for_init: resets thread local GPU runtime aliases for init.
static inline void reset_thread_local_gpu_runtime_aliases_for_init() {
    passwords_dev = nullptr;
    passwords_dev_capacity = 0;
    passwords_lenght_dev = 0;

    shared_result_flag = nullptr;
    shared_result_buffer = nullptr;
    shared_result_buffer_capacity = 0;

    p_str = nullptr;
    p_prv = nullptr;
    p_h160 = nullptr;
    p_typ = nullptr;
    p_result_derivation_type = nullptr;
    p_len1 = nullptr;
    p_der = nullptr;
    p_pas = nullptr;
    p_pas_size = nullptr;
    p_round = nullptr;
    p_seed = nullptr;
    p_results_count = nullptr;

    g_device_buffer_capacities.clear();
    reset_password_stream_cache();
}

// acquire_shared_result_buffers: acquires shared result buffers.
static inline cudaError_t acquire_shared_result_buffers(const uint64_t output_entries, bool** out_is_result, bool** out_device_result) {
    if (out_is_result == nullptr || out_device_result == nullptr) {
        return cudaErrorInvalidValue;
    }
    if (shared_result_flag == nullptr || shared_result_buffer == nullptr) {
        return cudaErrorInvalidDevicePointer;
    }
    if (output_entries > shared_result_buffer_capacity) {
        return cudaErrorInvalidValue;
    }

    *out_is_result = shared_result_flag;
    *out_device_result = shared_result_buffer;

    cudaError_t st = cudaMemset(shared_result_flag, 0, sizeof(bool));
    if (st != cudaSuccess) {
        return st;
    }
    if (output_entries > 0) {
        st = cudaMemset(shared_result_buffer, 0, static_cast<size_t>(output_entries) * sizeof(bool));
        if (st != cudaSuccess) {
            return st;
        }
    }
    return cudaSuccess;
}

static std::mutex g_result_flag_host_access_mutex;

// read_result_flag_host: reads result flag host.
static inline bool read_result_flag_host(bool* flag_ptr) {
    if (flag_ptr == nullptr) {
        return false;
    }
    std::lock_guard<std::mutex> lock(g_result_flag_host_access_mutex);
    bool host_value = false;
    const cudaError_t st = cudaMemcpy(&host_value, flag_ptr, sizeof(bool), cudaMemcpyDeviceToHost);
    if (st != cudaSuccess) {
        return false;
    }
    return host_value;
}

// clear_result_flag_host: clears result flag host.
static inline void clear_result_flag_host(bool* flag_ptr) {
    if (flag_ptr == nullptr) {
        return;
    }
    std::lock_guard<std::mutex> lock(g_result_flag_host_access_mutex);
    cudaMemset(flag_ptr, 0, sizeof(bool));
}

class BufferedIfstream final {
public:
    explicit BufferedIfstream(const size_t buffer_bytes = (4u << 20))
// BufferedIfstream: constructs file reader with a reusable custom buffer.
        : buffer_(buffer_bytes) {
        stream_.rdbuf()->pubsetbuf(buffer_.data(), static_cast<std::streamsize>(buffer_.size()));
    }

// open: opens a file in binary mode and resets stream state before reuse.
    bool open(const std::string& path) {
        if (stream_.is_open()) {
            stream_.clear();
            stream_.close();
        }
        stream_.open(path.c_str(), std::ios::binary);
        return stream_.is_open();
    }

    std::ifstream& stream() { return stream_; }

private:
    std::ifstream stream_;
    std::vector<char> buffer_;
};

thread_local static std::unordered_map<std::string, std::unique_ptr<BufferedIfstream>> g_password_stream_cache;
thread_local static std::unordered_set<std::string> g_password_stream_open_failed;

// reset_password_stream_cache: resets password stream cache.
static inline void reset_password_stream_cache() {
    g_password_stream_cache.clear();
    g_password_stream_open_failed.clear();
}

// acquire_password_stream_for_rewind: acquires password stream for rewind.
static inline std::ifstream* acquire_password_stream_for_rewind(const std::string& path) {
    if (g_password_stream_open_failed.find(path) != g_password_stream_open_failed.end()) {
        return nullptr;
    }

    auto it = g_password_stream_cache.find(path);
    if (it == g_password_stream_cache.end()) {
        auto stream_holder = std::make_unique<BufferedIfstream>(1u << 20);
        if (!stream_holder->open(path)) {
            std::cout << "Error: Failed to open password file '" << path << "'\n";
            g_password_stream_open_failed.insert(path);
            return nullptr;
        }
        it = g_password_stream_cache.emplace(path, std::move(stream_holder)).first;
    }

    std::ifstream& stream = it->second->stream();
    stream.clear();
    stream.seekg(0, std::ios::beg);
    if (!stream.good()) {
        if (!it->second->open(path)) {
            std::cout << "Error: Failed to open password file '" << path << "'\n";
            g_password_stream_open_failed.insert(path);
            g_password_stream_cache.erase(it);
            return nullptr;
        }
    }

    return &stream;
}

// parse_int32_token: parses int 32 token.
static inline bool parse_int32_token(const std::string& src, size_t begin, size_t end, int32_t& out) {
    while (begin < end && std::isspace(static_cast<unsigned char>(src[begin]))) {
        ++begin;
    }
    while (end > begin && std::isspace(static_cast<unsigned char>(src[end - 1]))) {
        --end;
    }
    if (begin >= end) {
        return false;
    }
    const std::string token = src.substr(begin, end - begin);
    char* end_ptr = nullptr;
    const long parsed = std::strtol(token.c_str(), &end_ptr, 10);
    if (end_ptr == token.c_str() || *end_ptr != '\0') {
        return false;
    }
    if (parsed < std::numeric_limits<int32_t>::min() || parsed > std::numeric_limits<int32_t>::max()) {
        return false;
    }
    out = static_cast<int32_t>(parsed);
    return true;
}

template <typename T>
// parse_list_or_ranges: parses list or ranges.
static inline bool parse_list_or_ranges(const std::string& input, std::vector<T>& out, const bool clear_out = false) {
    if (clear_out) {
        out.clear();
    }
    size_t token_begin = 0;
    while (token_begin <= input.size()) {
        const size_t comma = input.find(',', token_begin);
        const size_t token_end = (comma == std::string::npos) ? input.size() : comma;
        if (token_end > token_begin) {
            size_t dash = std::string::npos;
            for (size_t i = token_begin; i < token_end; ++i) {
                if (input[i] == '-') {
                    dash = i;
                    break;
                }
            }
            if (dash != std::string::npos) {
                int32_t start = 0;
                int32_t end = 0;
                if (!parse_int32_token(input, token_begin, dash, start) || !parse_int32_token(input, dash + 1, token_end, end)) {
                    std::cerr << "Invalid range token: " << input.substr(token_begin, token_end - token_begin) << std::endl;
                }
                else if (start > end) {
                    std::cerr << "Invalid range: " << input.substr(token_begin, token_end - token_begin) << std::endl;
                }
                else {
                    for (int32_t v = start; v <= end; ++v) {
                        out.emplace_back(static_cast<T>(v));
                    }
                }
            }
            else {
                int32_t value = 0;
                if (!parse_int32_token(input, token_begin, token_end, value)) {
                    std::cerr << "Invalid value token: " << input.substr(token_begin, token_end - token_begin) << std::endl;
                }
                else {
                    out.emplace_back(static_cast<T>(value));
                }
            }
        }
        if (comma == std::string::npos) {
            break;
        }
        token_begin = comma + 1;
    }
    return true;
}

// try_get_file_size: tries to get file size.
static inline bool try_get_file_size(const std::string& path, uint64_t& out_bytes) {
    std::ifstream probe(path.c_str(), std::ios::binary | std::ios::ate);
    if (!probe.is_open()) {
        return false;
    }
    const std::streamoff pos = probe.tellg();
    if (pos < 0) {
        return false;
    }
    out_bytes = static_cast<uint64_t>(pos);
    return true;
}

// preload_password_files_once: preloads password files once.
static inline void preload_password_files_once() {
    static bool initialized = false;
    if (initialized || !pass_set) {
        return;
    }
    initialized = true;
    reset_password_stream_cache();

    if (passwords_files.empty()) {
        for (std::string& p : passwords_list) {
            trim_crlf_inplace(p);
            truncate_inplace(p, 128);
        }
        passwords_lenght.clear();
        passwords_lenght.reserve(passwords_list.size());
        for (const std::string& p : passwords_list) {
            passwords_lenght.emplace_back(static_cast<uint32_t>(p.size()));
        }
        return;
    }

    constexpr uint64_t kCachePerFileLimitBytes = 256ull * 1024ull * 1024ull;
    constexpr uint64_t kCacheTotalLimitBytes = 768ull * 1024ull * 1024ull;

    uint64_t cached_bytes = 0;
    size_t cached_lines = 0;
    size_t cached_files = 0;

    std::vector<std::string> inline_passwords = std::move(passwords_list);
    passwords_list.clear();
    passwords_list.reserve(inline_passwords.size() + (1u << 16));

    std::vector<std::string> remaining_files;
    remaining_files.reserve(passwords_files.size());

    for (const std::string& fname : passwords_files) {
        uint64_t fsize = 0;
        if (!try_get_file_size(fname, fsize) || fsize > kCachePerFileLimitBytes || (cached_bytes + fsize) > kCacheTotalLimitBytes) {
            remaining_files.emplace_back(fname);
            continue;
        }

        BufferedIfstream fin(1u << 20);
        if (!fin.open(fname)) {
            std::cout << "Error: Failed to open password file '" << fname << "'\n";
            continue;
        }

        std::string line;
        while (read_trimmed_line(fin.stream(), line, 128)) {
            passwords_list.emplace_back(line);
            ++cached_lines;
        }
        cached_bytes += fsize;
        ++cached_files;
    }

    for (std::string& p : inline_passwords) {
        trim_crlf_inplace(p);
        truncate_inplace(p, 128);
        passwords_list.emplace_back(std::move(p));
    }

    passwords_files.swap(remaining_files);
    reset_password_stream_cache();
    passwords_lenght.clear();
    passwords_lenght.reserve(passwords_list.size());
    for (const std::string& p : passwords_list) {
        passwords_lenght.emplace_back(static_cast<uint32_t>(p.size()));
    }

    if (cached_files > 0) {
        fprintf(stderr, "[!] Password cache enabled: %zu file(s), %llu bytes, %zu line(s)\n",
            cached_files,
            static_cast<unsigned long long>(cached_bytes),
            cached_lines);
    }
    if (!passwords_files.empty()) {
        fprintf(stderr, "[!] Password streaming fallback: %zu large file(s) left uncached\n", passwords_files.size());
    }
}

cudaError_t prepareCuda();
void SpeedThreadFunc();
static bool initialize_gpu_contexts(const unsigned int requested_threads, const unsigned int requested_blocks);
static void release_all_gpu_contexts();

cudaError_t setTargetXorFilter(std::vector<std::string>& targets);
cudaError_t setTargetXorUnFilter(std::vector<std::string>& targets);
cudaError_t setTargetXorUcFilter(std::vector<std::string>& targets);
cudaError_t setTargetXorHcFilter(std::vector<std::string>& targets);

cudaError_t processCudaRecovery();

bool mallocFounds(uint32_t N);

bool readArgs(int argc, char** argv);
bool parseDerivations(vector<string> file);
bool checkDevice();
void printSpeed(double speed, int byte_p = 0, uint32_t seed_p = 0, int skip = 0, double valid_speed = -1.0);

class AtomicCounter64 {
public:
    // Creates the counter with an explicit initial value.
    AtomicCounter64(const uint64_t initial = 0) : value_(initial) {}
    // Copies the current value from another counter.
    AtomicCounter64(const AtomicCounter64& other) : value_(other.value_.load(std::memory_order_relaxed)) {}
    // Assigns the value from another AtomicCounter64 instance.
    AtomicCounter64& operator=(const AtomicCounter64& other) {
        if (this != &other) {
            value_.store(other.value_.load(std::memory_order_relaxed), std::memory_order_relaxed);
        }
        return *this;
    }

    // Assigns a raw uint64_t value to the counter.
    AtomicCounter64& operator=(const uint64_t v) {
        value_.store(v, std::memory_order_relaxed);
        return *this;
    }
    // Adds delta to the counter and returns the same object.
    AtomicCounter64& operator+=(const uint64_t delta) {
        value_.fetch_add(delta, std::memory_order_release);
        return *this;
    }
    // Prefix increment: increments first, then returns this object.
    AtomicCounter64& operator++() {
        value_.fetch_add(1, std::memory_order_release);
        return *this;
    }
    // Postfix increment: returns old value, then increments the counter.
    uint64_t operator++(int) {
        return value_.fetch_add(1, std::memory_order_release);
    }
    // Implicit conversion to the current counter value.
    operator uint64_t() const {
        return value_.load(std::memory_order_acquire);
    }
    // Reads the current value with acquire ordering.
    uint64_t load() const {
        return value_.load(std::memory_order_acquire);
    }

private:
    std::atomic<uint64_t> value_;
};

thread_local int DEVICE_NR = 0;
thread_local unsigned int BLOCK_THREADS = 0;
thread_local unsigned int BLOCK_NUMBER = 0;
bool set_block = false;
bool set_thread = false;
thread_local uint64_t workSize = 0;
AtomicCounter64 counterTotal = 0;
std::atomic_uint64_t g_recovery_tested_total = 0;
std::atomic_uint64_t g_recovery_emitted_total = 0;
std::atomic_uint32_t Founds = 0;

static inline void recovery_publish_checksum_valid_delta(const uint64_t delta) {
    if (delta == 0ull) {
        return;
    }
    g_recovery_emitted_total.fetch_add(delta, std::memory_order_relaxed);
}

string fileResult = "result.txt";
FILE* OUT_FILE;
vector<int> DEVICE_LIST = { 0 };
vector<string> bloomFiles;
vector<string> bloomFilesCPU;
vector<string> xorFiles;
vector<string> xorFilesUn;
vector<string> xorFilesUc;
vector<string> xorFilesHc;
vector<string> xorFilesCPU;
bool useBloom = false;
bool useXor = false;
bool useXorUn = false;
bool useXorUc = false;
bool useXorHc = false;
bool useXorCPU = false;
bool useBloomCPU = false;
bool useHashTarget = false;
uint32_t hashTargetWordsHost[5] = { 0, 0, 0, 0, 0 };
uint32_t hashTargetMasksHost[5] = { 0, 0, 0, 0, 0 };
uint32_t hashTargetLenBytes = 0;
std::string hashTargetHex;
thread_local bool gpu_bloom_loaded = false;
thread_local bool gpu_xor_loaded = false;
thread_local bool gpu_xor_un_loaded = false;
thread_local bool gpu_xor_uc_loaded = false;
thread_local bool gpu_xor_hc_loaded = false;


bool isRun = true;

vector<string> mnemonicFiles;
vector<string> derivationFiles;
vector<uint32_t> derIndex;
uint32_t derIndex_size;
bool save = false;
uint32_t deep = 0;
uint64_t Rounds = 0;
vector<uint32_t> Derivations;
vector<string> Derivations_list;

static uint64_t recovery_target_checks_per_derivation() {
    uint64_t checks = 0ull;
    if (Compressed) {
        ++checks;
    }
    if (Uncompressed) {
        ++checks;
    }
    if (Segwit) {
        ++checks;
    }
    if (Taproot) {
        ++checks;
    }
    if (Ethereum) {
        ++checks;
    }
    if (Xpoint) {
        ++checks;
    }
    if (Solana) {
        ++checks;
    }
    if (Ton) {
        checks += 4ull;
    }
    if (Ton_all) {
        checks += 10ull;
    }
    return checks;
}

static uint64_t recovery_derivation_engine_multiplier() {
    switch (g_derivation_policy) {
    case DerivationPolicy::Mixed:
        return 2ull;
    case DerivationPolicy::Auto:
    case DerivationPolicy::ForceBip32Secp256k1:
    case DerivationPolicy::ForceSlip0010Ed25519:
    case DerivationPolicy::ForceEd25519Bip32Test:
    default:
        return 1ull;
    }
}

static uint64_t recovery_round_multiplier() {
    return (Rounds * 2ull) + 1ull;
}

static uint64_t recovery_hash_checks_per_candidate() {
    const uint64_t derivation_count = static_cast<uint64_t>(Derivations_list.size());
    const uint64_t target_checks = recovery_target_checks_per_derivation();
    if (derivation_count == 0ull || target_checks == 0ull) {
        return 0ull;
    }

    return derivation_count * target_checks * recovery_derivation_engine_multiplier() * recovery_round_multiplier();
}

#ifdef _DEBUG
unsigned int PARAM_ECMULT_WINDOW_SIZE = 4;
#else
unsigned int PARAM_ECMULT_WINDOW_SIZE = 16;
#endif

union hash160_20 {
    uint32_t bits5[5];
    uint8_t bits20[20];
};

set<string>addresses;
//set<string>pubkeys;
CudaHashLookup _targetLookup;
std::vector<hash160> _targets;


std::mutex myMutex;

thread_local secp256k1_ge_storage* _dev_precomp = nullptr;
thread_local size_t pitch = 0;


thread_local uint64_t step = 1;

struct GpuRuntimeContext {
    int device_id = 0;
    unsigned int block_threads = 0;
    unsigned int block_number = 0;
    uint64_t work_size = 0;

    char* p_str = nullptr;
    unsigned char* p_prv = nullptr;
    uint32_t* p_h160 = nullptr;
    uint8_t* p_typ = nullptr;
    uint8_t* p_result_derivation_type = nullptr;
    uint32_t* p_len1 = nullptr;
    uint32_t* p_der = nullptr;
    char* p_pas = nullptr;
    uint16_t* p_pas_size = nullptr;
    int64_t* p_round = nullptr;
    uint64_t* p_seed = nullptr;
    unsigned long long* p_results_count = nullptr;

    char* passwords_dev = nullptr;
    size_t passwords_dev_capacity = 0;
    uint32_t passwords_lenght_dev = 0;
    bool* shared_result_flag = nullptr;
    bool* shared_result_buffer = nullptr;
    size_t shared_result_buffer_capacity = 0;

    secp256k1_ge_storage* dev_precomp = nullptr;
    size_t pitch = 0;

    bool bloom_loaded = false;
    bool xor_loaded = false;
    bool xor_un_loaded = false;
    bool xor_uc_loaded = false;
    bool xor_hc_loaded = false;
};

static std::vector<GpuRuntimeContext> g_gpu_contexts;
thread_local static bool g_disable_multi_gpu_dispatch = false;

// is_multi_gpu_active: checks whether multi GPU active is valid.
static inline bool is_multi_gpu_active() {
    return g_gpu_contexts.size() > 1;
}

// capture_current_gpu_context: captures current GPU context.
static inline GpuRuntimeContext capture_current_gpu_context() {
    GpuRuntimeContext ctx;
    ctx.device_id = DEVICE_NR;
    ctx.block_threads = BLOCK_THREADS;
    ctx.block_number = BLOCK_NUMBER;
    ctx.work_size = workSize;
    ctx.p_str = p_str;
    ctx.p_prv = p_prv;
    ctx.p_h160 = p_h160;
    ctx.p_typ = p_typ;
    ctx.p_result_derivation_type = p_result_derivation_type;
    ctx.p_len1 = p_len1;
    ctx.p_der = p_der;
    ctx.p_pas = p_pas;
    ctx.p_pas_size = p_pas_size;
    ctx.p_round = p_round;
    ctx.p_seed = p_seed;
    ctx.p_results_count = p_results_count;
    ctx.passwords_dev = passwords_dev;
    ctx.passwords_dev_capacity = passwords_dev_capacity;
    ctx.passwords_lenght_dev = passwords_lenght_dev;
    ctx.shared_result_flag = shared_result_flag;
    ctx.shared_result_buffer = shared_result_buffer;
    ctx.shared_result_buffer_capacity = shared_result_buffer_capacity;
    ctx.dev_precomp = _dev_precomp;
    ctx.pitch = pitch;
    ctx.bloom_loaded = gpu_bloom_loaded;
    ctx.xor_loaded = gpu_xor_loaded;
    ctx.xor_un_loaded = gpu_xor_un_loaded;
    ctx.xor_uc_loaded = gpu_xor_uc_loaded;
    ctx.xor_hc_loaded = gpu_xor_hc_loaded;
    return ctx;
}

// apply_gpu_context: applies GPU context.
static inline void apply_gpu_context(const GpuRuntimeContext& ctx) {
    DEVICE_NR = ctx.device_id;
    BLOCK_THREADS = ctx.block_threads;
    BLOCK_NUMBER = ctx.block_number;
    workSize = ctx.work_size;
    p_str = ctx.p_str;
    p_prv = ctx.p_prv;
    p_h160 = ctx.p_h160;
    p_typ = ctx.p_typ;
    p_result_derivation_type = ctx.p_result_derivation_type;
    p_len1 = ctx.p_len1;
    p_der = ctx.p_der;
    p_pas = ctx.p_pas;
    p_pas_size = ctx.p_pas_size;
    p_round = ctx.p_round;
    p_seed = ctx.p_seed;
    p_results_count = ctx.p_results_count;
    passwords_dev = ctx.passwords_dev;
    passwords_dev_capacity = ctx.passwords_dev_capacity;
    passwords_lenght_dev = ctx.passwords_lenght_dev;
    shared_result_flag = ctx.shared_result_flag;
    shared_result_buffer = ctx.shared_result_buffer;
    shared_result_buffer_capacity = ctx.shared_result_buffer_capacity;
    _dev_precomp = ctx.dev_precomp;
    pitch = ctx.pitch;
    gpu_bloom_loaded = ctx.bloom_loaded;
    gpu_xor_loaded = ctx.xor_loaded;
    gpu_xor_un_loaded = ctx.xor_un_loaded;
    gpu_xor_uc_loaded = ctx.xor_uc_loaded;
    gpu_xor_hc_loaded = ctx.xor_hc_loaded;
}

// activate_gpu_context: activates GPU context.
static inline bool activate_gpu_context(const GpuRuntimeContext& ctx) {
    SET_CRASH_STAGE("activate_gpu_context.cudaSetDevice");
    SET_CRASH_GPU_HINT(ctx.device_id);
    cudaError_t st = cudaSetDevice(ctx.device_id);
    if (st != cudaSuccess) {
        fprintf(stderr, "[!] Failed to activate device %d: %s [!]\n", ctx.device_id, cudaGetErrorString(st));
        return false;
    }
    SET_CRASH_STAGE("activate_gpu_context.cudaFree0");
    st = cudaFree(0);
    if (st != cudaSuccess) {
        fprintf(stderr, "[!] Failed to initialize CUDA runtime on device %d thread: %s [!]\n", ctx.device_id, cudaGetErrorString(st));
        return false;
    }
    SET_CRASH_STAGE("activate_gpu_context.apply_gpu_context");
    apply_gpu_context(ctx);
    SET_CRASH_STAGE("activate_gpu_context.done");
    return true;
}

template <typename Fn>
// dispatch_recovery_mode_multi_gpu: dispatches recovery mode multi GPU.
static cudaError_t dispatch_recovery_mode_multi_gpu(const char* mode_name, Fn&& worker_fn) {
    if (!is_multi_gpu_active() || g_disable_multi_gpu_dispatch) {
        return worker_fn();
    }

    g_recovery_tested_total.store(0ull, std::memory_order_relaxed);
    g_recovery_emitted_total.store(0ull, std::memory_order_relaxed);

    const size_t gpu_count = g_gpu_contexts.size();
    std::vector<std::thread> workers;
    std::vector<cudaError_t> statuses(gpu_count, cudaSuccess);
    std::vector<uint64_t> tested_totals(gpu_count, 0ull);
    std::vector<uint64_t> emitted_totals(gpu_count, 0ull);
    workers.reserve(gpu_count);

    for (size_t gpu_idx = 0; gpu_idx < gpu_count; ++gpu_idx) {
        workers.emplace_back([&, gpu_idx]() {
            {
                std::lock_guard<std::mutex> lock(g_cuda_context_api_mutex);
                if (!activate_gpu_context(g_gpu_contexts[gpu_idx])) {
                    statuses[gpu_idx] = cudaErrorInvalidDevice;
                    return;
                }
            }

            const RecoveryMultiGpuPartition previous_partition = g_recovery_multi_gpu_partition;
            g_recovery_multi_gpu_partition.enabled = true;
            g_recovery_multi_gpu_partition.index = gpu_idx;
            g_recovery_multi_gpu_partition.count = gpu_count;

            g_disable_multi_gpu_dispatch = true;
            statuses[gpu_idx] = worker_fn();
            g_disable_multi_gpu_dispatch = false;
            tested_totals[gpu_idx] = g_recovery_run_stats.tested_total;
            emitted_totals[gpu_idx] = g_recovery_run_stats.emitted_total;

            g_recovery_multi_gpu_partition = previous_partition;
        });
    }

    for (auto& th : workers) {
        if (th.joinable()) {
            th.join();
        }
    }

    if (!g_gpu_contexts.empty()) {
        std::lock_guard<std::mutex> lock(g_cuda_context_api_mutex);
        activate_gpu_context(g_gpu_contexts.front());
    }

    cudaError_t first_error = cudaSuccess;
    for (size_t gpu_idx = 0; gpu_idx < gpu_count; ++gpu_idx) {
        if (statuses[gpu_idx] != cudaSuccess) {
            first_error = statuses[gpu_idx];
            fprintf(stderr, "[!] mode %s failed on GPU %d: %s [!]\n",
                mode_name,
                g_gpu_contexts[gpu_idx].device_id,
                cudaGetErrorString(statuses[gpu_idx]));
            break;
        }
    }

    if (first_error == cudaSuccess) {
        uint64_t tested_sum = 0ull;
        uint64_t emitted_sum = 0ull;
        for (size_t gpu_idx = 0; gpu_idx < gpu_count; ++gpu_idx) {
            tested_sum += tested_totals[gpu_idx];
            emitted_sum += emitted_totals[gpu_idx];
        }
        printf("[!] Recovery summary: tested=%llu checksum-valid=%llu [!]\n",
            static_cast<unsigned long long>(tested_sum),
            static_cast<unsigned long long>(emitted_sum));
        g_recovery_tested_total.store(tested_sum, std::memory_order_relaxed);
        g_recovery_emitted_total.store(emitted_sum, std::memory_order_relaxed);
        g_recovery_run_stats.tested_total = tested_sum;
        g_recovery_run_stats.emitted_total = emitted_sum;
        for (size_t gpu_idx = 0; gpu_idx < gpu_count; ++gpu_idx) {
            printf("[!] Recovery device %d: tested=%llu checksum-valid=%llu [!]\n",
                g_gpu_contexts[gpu_idx].device_id,
                static_cast<unsigned long long>(tested_totals[gpu_idx]),
                static_cast<unsigned long long>(emitted_totals[gpu_idx]));
        }
    }

    return first_error;
}

class BlockingPipeBuf final : public std::streambuf
{
public:
    explicit BlockingPipeBuf(size_t capacityBytes = (1u << 20))
        : cap_(std::max<size_t>(capacityBytes, 1)),
        q_(cap_)
    {
        setg(nullptr, nullptr, nullptr);
        setp(nullptr, nullptr);
    }

// close: marks the pipe as closed and wakes all waiting producers/consumers.
    void close()
    {
        {
            std::lock_guard<std::mutex> lk(m_);
            closed_ = true;
        }
        cv_not_empty_.notify_all();
        cv_not_full_.notify_all();
    }

// reset: clears queue state so the same pipe buffer can be reused.
    void reset()
    {
        std::lock_guard<std::mutex> lk(m_);
        read_pos_ = 0;
        write_pos_ = 0;
        size_ = 0;
        closed_ = false;
        setg(nullptr, nullptr, nullptr);
        setp(nullptr, nullptr);
        cv_not_empty_.notify_all();
        cv_not_full_.notify_all();
    }

protected:
    // overflow: pushes one character through the pipe write path.
    int_type overflow(int_type ch) override
    {
        if (traits_type::eq_int_type(ch, traits_type::eof()))
            return traits_type::not_eof(ch);

        const char c = traits_type::to_char_type(ch);
        return (xsputn(&c, 1) == 1) ? ch : traits_type::eof();
    }

    // xsputn: writes a block of data into the bounded ring buffer.
    std::streamsize xsputn(const char* s, std::streamsize n) override
    {
        if (n <= 0) return 0;

        std::streamsize written = 0;
        while (written < n)
        {
            std::unique_lock<std::mutex> lk(m_);
            cv_not_full_.wait(lk, [&] { return closed_ || size_ < cap_; });
            if (closed_) break;

            const size_t freeSpace = cap_ - size_;
            const std::streamsize canWrite =
                (std::streamsize)std::min<size_t>(freeSpace, (size_t)(n - written));

            const size_t canWriteU = static_cast<size_t>(canWrite);
            const size_t first = std::min(canWriteU, cap_ - write_pos_);
            memcpy(q_.data() + write_pos_, s + written, first);
            const size_t second = canWriteU - first;
            if (second) {
                memcpy(q_.data(), s + written + first, second);
            }
            write_pos_ = (write_pos_ + canWriteU) % cap_;
            size_ += canWriteU;
            written += canWrite;

            lk.unlock();
            cv_not_empty_.notify_one();
        }
        return written;
    }

    // sync: streambuf sync hook (nothing to flush for in-memory pipe).
    int sync() override
    {
        return 0;
    }

    // underflow: waits for data and exposes the next readable byte.
    int_type underflow() override
    {
        std::unique_lock<std::mutex> lk(m_);
        cv_not_empty_.wait(lk, [&] { return closed_ || size_ > 0; });

        if (size_ == 0 && closed_)
            return traits_type::eof();

        const size_t take = std::min<size_t>(READ_CHUNK_BYTES, size_);
        const size_t first = std::min(take, cap_ - read_pos_);
        memcpy(read_chunk_, q_.data() + read_pos_, first);
        const size_t second = take - first;
        if (second) {
            memcpy(read_chunk_ + first, q_.data(), second);
        }
        read_pos_ = (read_pos_ + take) % cap_;
        size_ -= take;
        setg(read_chunk_, read_chunk_, read_chunk_ + take);

        lk.unlock();
        cv_not_full_.notify_one();
        return traits_type::to_int_type(*gptr());
    }



private:
    static constexpr size_t READ_CHUNK_BYTES = 8192;

    size_t cap_;
    std::vector<char> q_;
    size_t read_pos_ = 0;
    size_t write_pos_ = 0;
    size_t size_ = 0;
    std::mutex m_;
    std::condition_variable cv_not_empty_;
    std::condition_variable cv_not_full_;
    bool closed_ = false;
    char read_chunk_[READ_CHUNK_BYTES];
};

BlockingPipeBuf g_pipe(1u << 24);
std::istream    g_pipe_in(&g_pipe);
std::ostream    g_pipe_out(&g_pipe);

// ReadWords: reads words.
static std::vector<std::string> ReadWords(std::istream& in, size_t maxWords = 9999999)
{
    std::vector<std::string> words;
    words.reserve(std::min<size_t>(maxWords, 1u << 16));

    std::string w;
    while (words.size() < maxWords && (in >> w))
        words.push_back(std::move(w));

    return words;
}

static inline void WriteCombo(const std::vector<std::string>& words,
    const std::vector<int>& idx,
    bool space)
{
    static thread_local std::string line;
    line.clear();

    size_t total = 1;
    if (!idx.empty()) {
        if (space && idx.size() > 1) {
            total += idx.size() - 1;
        }
        for (size_t i = 0; i < idx.size(); ++i) {
            total += words[(size_t)idx[i]].size();
        }
    }
    if (line.capacity() < total) {
        line.reserve(total);
    }

    for (size_t i = 0; i < idx.size(); ++i)
    {
        if (i && space) {
            line.push_back(' ');
        }
        line.append(words[(size_t)idx[i]]);
    }
    line.push_back('\n');
    g_pipe_out.write(line.data(), (std::streamsize)line.size());

    if (!g_pipe_out.good()) return;
}

static void GenRep(const std::vector<std::string>& words,
    std::vector<int>& idx,
    int pos,
    bool space)
{
    if (!g_pipe_out.good()) return;

    const int k = (int)idx.size();
    if (pos == k) { WriteCombo(words, idx, space); return; }

    const int n = (int)words.size();
    for (int i = 0; i < n; ++i)
    {
        idx[pos] = i;
        GenRep(words, idx, pos + 1, space);
        if (!g_pipe_out.good()) return;
    }
}

static void GenNoRep(const std::vector<std::string>& words,
    std::vector<int>& idx,
    std::vector<unsigned char>& used,
    int pos,
    bool space)
{
    if (!g_pipe_out.good()) return;

    const int k = (int)idx.size();
    if (pos == k) { WriteCombo(words, idx, space); return; }

    const int n = (int)words.size();
    for (int i = 0; i < n; ++i)
    {
        if (used[(size_t)i]) continue;
        used[(size_t)i] = 1;
        idx[pos] = i;

        GenNoRep(words, idx, used, pos + 1, space);

        used[(size_t)i] = 0;
        if (!g_pipe_out.good()) return;
    }
}

void EmitCombinations(std::istream& in,
    const std::vector<int>& comb,
    bool space,
    bool rep)
{
    std::vector<std::string> words = ReadWords(in, 9999999);
    if (words.empty()) return;

    for (int k : comb)
    {
        if (k <= 0) continue;
        if (!rep && k > (int)words.size()) continue;

        std::vector<int> idx((size_t)k, 0);

        if (rep)
        {
            GenRep(words, idx, 0, space);
        }
        else
        {
            std::vector<unsigned char> used(words.size(), 0);
            GenNoRep(words, idx, used, 0, space);
        }

        if (!g_pipe_out.good()) return;
    }
}

// recovery_trim_spaces_copy: recovery mode helper that trims spaces copy.
static std::string recovery_trim_spaces_copy(const std::string& in) {
    size_t b = 0;
    size_t e = in.size();
    while (b < e && std::isspace(static_cast<unsigned char>(in[b])) != 0) {
        ++b;
    }
    while (e > b && std::isspace(static_cast<unsigned char>(in[e - 1])) != 0) {
        --e;
    }
    return in.substr(b, e - b);
}

// recovery_is_ascii: recovery mode helper that checks whether ascii is valid.
static bool recovery_is_ascii(const std::string& s) {
    for (const unsigned char c : s) {
        if (c >= 128u) return false;
    }
    return true;
}

// recovery_norm_token: recovery mode helper that normalizes token.
static std::string recovery_norm_token(const std::string& in) {
    if (!recovery_is_ascii(in)) {
        return in;
    }
    std::string out = in;
    for (char& c : out) {
        c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    }
    return out;
}

// recovery_split_tokens: recovery mode helper that splits tokens.
static std::vector<std::string> recovery_split_tokens(const std::string& phrase) {
    std::vector<std::string> out;
    std::istringstream iss(phrase);
    std::string token;
    while (iss >> token) {
        out.emplace_back(std::move(token));
    }
    return out;
}

// recovery_levenshtein: computes edit distance between two normalized tokens.
static size_t recovery_levenshtein(const std::string& a, const std::string& b) {
    const size_t n = a.size();
    const size_t m = b.size();
    if (n == 0) return m;
    if (m == 0) return n;

    std::vector<size_t> prev(m + 1);
    std::vector<size_t> curr(m + 1);
    for (size_t j = 0; j <= m; ++j) prev[j] = j;

    for (size_t i = 1; i <= n; ++i) {
        curr[0] = i;
        for (size_t j = 1; j <= m; ++j) {
            const size_t cost = (a[i - 1] == b[j - 1]) ? 0u : 1u;
            const size_t delv = prev[j] + 1u;
            const size_t insv = curr[j - 1] + 1u;
            const size_t sub = prev[j - 1] + cost;
            curr[j] = std::min(std::min(delv, insv), sub);
        }
        prev.swap(curr);
    }
    return prev[m];
}

// recovery_path_filename: extracts a filename from path string with slash normalization.
static std::string recovery_path_filename(const std::string& path) {
    const size_t p1 = path.find_last_of("/\\");
    if (p1 == std::string::npos) return path;
    return path.substr(p1 + 1);
}

// recovery_norm_file_id: recovery mode helper that normalizes file id.
static std::string recovery_norm_file_id(const std::string& raw) {
    std::string name = recovery_path_filename(raw);
    name = recovery_norm_token(name);
    const size_t dot = name.find_last_of('.');
    if (dot != std::string::npos) {
        name = name.substr(0, dot);
    }
    return name;
}

// recovery_detect_device_lang: recovery mode helper that detects device lang.
static int recovery_detect_device_lang(const std::string& id_norm, const std::string& file_norm) {
    const std::string key = id_norm + "|" + file_norm;

    auto has_token = [&](const char* token) -> bool {
        return (id_norm.find(token) != std::string::npos) ||
            (file_norm.find(token) != std::string::npos) ||
            (key.find(token) != std::string::npos);
        };

    if (has_token("bip39_en") || has_token("_en") || has_token("english")) return 0;
    if (has_token("bip39_es") || has_token("bip39_sp") || has_token("_es") || has_token("spanish")) return 1;
    if (has_token("bip39_ja") || has_token("_ja") || has_token("japanese")) return 2;
    if (has_token("bip39_it") || has_token("_it") || has_token("italian")) return 3;
    if (has_token("bip39_fr") || has_token("_fr") || has_token("french")) return 4;
    if (has_token("bip39_cs") || has_token("_cs") || has_token("czech")) return 5;
    if (has_token("bip39_pt") || has_token("_pt") || has_token("portuguese")) return 6;
    if (has_token("bip39_ko") || has_token("_ko") || has_token("korean")) return 7;
    if (has_token("bip39_zh_hans") || has_token("zh_hans") || has_token("chinese_simplified")) return 8;
    if (has_token("bip39_zh_hant") || has_token("zh_hant") || has_token("chinese_traditional")) return 9;
    return -1;
}

// recovery_add_embedded_wordlist: recovery mode helper that adds embedded wordlist.
static bool recovery_add_embedded_wordlist(const RecoveryEmbeddedWordlistView& view, RecoveryWordlist& out, std::string& err) {
    out = RecoveryWordlist{};
    out.id = view.id;
    out.file_name = view.file_name;
    out.path = view.file_name;
    out.name = view.file_name;
    out.external = false;
    out.device_lang = recovery_detect_device_lang(recovery_norm_token(out.id), recovery_norm_token(out.file_name));
    out.words.reserve(view.count);
    out.words_norm.reserve(view.count);
    out.id_by_norm.reserve(view.count * 2u);

    for (std::size_t i = 0; i < view.count; ++i) {
        const char* w = view.words[i];
        if (w == nullptr || *w == '\0') continue;

        const int idx = static_cast<int>(out.words.size());
        out.words.emplace_back(w);
        const std::string norm = recovery_norm_token(out.words.back());
        out.words_norm.emplace_back(norm);
        if (out.id_by_norm.find(norm) == out.id_by_norm.end()) {
            out.id_by_norm.emplace(norm, idx);
        }
    }

    if (out.words.empty()) {
        err = "embedded wordlist is empty: " + out.file_name;
        return false;
    }
    out.source_word_count = out.words.size();
    return true;
}

// recovery_add_file_wordlist: recovery mode helper that adds file wordlist.
static bool recovery_add_file_wordlist(const std::string& path, RecoveryWordlist& out, std::string& err) {
    out = RecoveryWordlist{};

    std::ifstream fin(path.c_str(), std::ios::binary);
    tune_ifstream_buffer(fin);
    if (!fin) {
        err = "failed to open external wordlist: " + path;
        return false;
    }

    out.path = path;
    out.file_name = recovery_path_filename(path);
    out.id = recovery_norm_file_id(path);
    out.name = out.file_name;
    out.external = true;
    out.device_lang = -1;
    out.words.reserve(2048u);
    out.words_norm.reserve(2048u);
    out.id_by_norm.reserve(4096u);

    std::string line;
    size_t line_no = 0;
    bool first_line = true;
    while (read_trimmed_line(fin, line, 4096u)) {
        ++line_no;
        line = recovery_trim_spaces_copy(line);
        if (line.empty()) {
            continue;
        }

        if (first_line && line.size() >= 3u &&
            static_cast<unsigned char>(line[0]) == 0xEFu &&
            static_cast<unsigned char>(line[1]) == 0xBBu &&
            static_cast<unsigned char>(line[2]) == 0xBFu) {
            line.erase(0u, 3u);
            line = recovery_trim_spaces_copy(line);
            if (line.empty()) {
                first_line = false;
                continue;
            }
        }
        first_line = false;

        if (!line.empty() && line[0] == '#') {
            continue;
        }

        bool has_space = false;
        for (const unsigned char c : line) {
            if (std::isspace(c) != 0) {
                has_space = true;
                break;
            }
        }
        if (has_space) {
            err = "invalid external wordlist line (contains spaces) at line " + std::to_string(line_no);
            return false;
        }

        if (line.size() > 33u) {
            err = "invalid external wordlist line (more than 33 bytes) at line " + std::to_string(line_no);
            return false;
        }

        if (out.words.size() >= static_cast<size_t>(std::numeric_limits<uint16_t>::max())) {
            err = "external wordlist must contain no more than 65535 words";
            return false;
        }

        const int idx = static_cast<int>(out.words.size());
        out.words.emplace_back(line);
        const std::string norm = recovery_norm_token(out.words.back());
        if (out.id_by_norm.find(norm) != out.id_by_norm.end()) {
            err = "duplicate word in external wordlist at line " + std::to_string(line_no);
            return false;
        }
        out.words_norm.emplace_back(norm);
        out.id_by_norm.emplace(norm, idx);
    }

    if (out.words.empty()) {
        err = "external wordlist is empty: " + path;
        return false;
    }

    out.source_word_count = out.words.size();
    return true;
}

// recovery_find_best_word_id: recovery mode helper that finds best word id.
static int recovery_find_best_word_id(const RecoveryWordlist& wl, const std::string& token_norm, size_t* out_dist) {
    auto it = wl.id_by_norm.find(token_norm);
    if (it != wl.id_by_norm.end()) {
        if (out_dist) *out_dist = 0;
        return it->second;
    }

    size_t best_dist = std::numeric_limits<size_t>::max();
    int best_id = -1;
    for (size_t i = 0; i < wl.words_norm.size(); ++i) {
        const std::string& cand = wl.words_norm[i];
        const size_t d = recovery_levenshtein(token_norm, cand);
        if (d < best_dist) {
            best_dist = d;
            best_id = static_cast<int>(i);
            if (best_dist == 1u) {
                break;
            }
        }
    }
    if (out_dist) *out_dist = best_dist;
    return best_id;
}

// recovery_pick_wordlist: recovery mode helper that selects wordlist.
static const RecoveryWordlist* recovery_pick_wordlist(const std::vector<RecoveryWordlist>& lists,
    const std::vector<std::string>& tokens) {
    if (lists.empty()) return nullptr;
    if (lists.size() == 1u) return &lists[0];

    int best_exact = -1;
    size_t best_penalty = std::numeric_limits<size_t>::max();
    size_t best_words = std::numeric_limits<size_t>::max();
    const RecoveryWordlist* best = &lists[0];

    for (const RecoveryWordlist& wl : lists) {
        int exact = 0;
        size_t penalty = 0;

        for (const std::string& token : tokens) {
            if (token == "*") continue;
            const std::string norm = recovery_norm_token(token);
            auto it = wl.id_by_norm.find(norm);
            if (it != wl.id_by_norm.end()) {
                ++exact;
                continue;
            }

            size_t dist = 0;
            (void)recovery_find_best_word_id(wl, norm, &dist);
            penalty += dist;
        }

        if (exact > best_exact ||
            (exact == best_exact && penalty < best_penalty) ||
            (exact == best_exact && penalty == best_penalty && wl.words.size() < best_words)) {
            best_exact = exact;
            best_penalty = penalty;
            best_words = wl.words.size();
            best = &wl;
        }
    }

    return best;
}

// recovery_format_scientific: recovery mode helper that formats scientific.
static std::string recovery_format_scientific(const long double v) {
    std::ostringstream oss;
    oss << std::scientific << std::setprecision(6) << static_cast<double>(v);
    return oss.str();
}

// recovery_join_tokens: recovery mode helper that joins tokens.
static std::string recovery_join_tokens(const std::vector<std::string>& tokens) {
    std::string out;
    size_t total = 0;
    for (const std::string& t : tokens) total += t.size();
    if (!tokens.empty()) total += tokens.size() - 1u;
    out.reserve(total);
    for (size_t i = 0; i < tokens.size(); ++i) {
        if (i) out.push_back(' ');
        out.append(tokens[i]);
    }
    return out;
}

// recovery_prepare_task: recovery mode helper that prepares task.
static bool recovery_prepare_task(
    const RecoveryTemplateInput& in,
    const std::vector<RecoveryWordlist>& lists,
    RecoveryPreparedTask& out,
    std::string& err) {

    std::vector<std::string> tokens = recovery_split_tokens(in.phrase);
    if (tokens.empty()) {
        err = "empty phrase";
        return false;
    }

    size_t added_stars = 0;
    while (tokens.size() < 3u || (tokens.size() % 3u) != 0u) {
        tokens.emplace_back("*");
        ++added_stars;
    }
    if (tokens.size() > 48u) {
        err = "word count is greater than 48 after normalization";
        return false;
    }

    const RecoveryWordlist* wl = recovery_pick_wordlist(lists, tokens);
    if (wl == nullptr) {
        err = "no wordlists available";
        return false;
    }

    out = RecoveryPreparedTask{};
    out.source = in.source;
    out.line_no = in.line_no;
    out.wordlist = wl;
    out.word_options_count = wl->word_options.empty() ? wl->words.size() : wl->word_options.size();
    out.wordlist_source_is_standard_subset = wl->standard_subset;
    out.effective_nvalid = recoveryIncludeInvalid || wl->auto_nvalid;
    out.added_stars = added_stars;
    out.ids.assign(tokens.size(), -1);

    for (size_t i = 0; i < tokens.size(); ++i) {
        if (tokens[i] == "*") {
            out.missing_positions.emplace_back(static_cast<int>(i));
            continue;
        }

        const std::string norm = recovery_norm_token(tokens[i]);
        size_t dist = 0;
        const int best_id = recovery_find_best_word_id(*wl, norm, &dist);
        if (best_id < 0 || static_cast<size_t>(best_id) >= wl->words.size()) {
            err = "failed to find replacement for token: " + tokens[i];
            return false;
        }

        out.ids[i] = best_id;
        if (dist != 0 || wl->words_norm[best_id] != norm) {
            out.replacements.emplace_back(tokens[i], wl->words[best_id]);
            tokens[i] = wl->words[best_id];
        }
    }

    out.normalized_phrase = recovery_join_tokens(tokens);
    return true;
}

// recovery_bip39_checksum_valid: recovery mode helper that checks whether BIP39 checksum is valid.
static bool recovery_bip39_checksum_valid(const std::vector<int>& ids) {
    const int n = static_cast<int>(ids.size());
    if (n <= 0 || (n % 3) != 0) return false;
    for (int i = 0; i < n; ++i) {
        if (ids[i] < 0 || ids[i] > 2047) return false;
    }

    const int total_bits = n * 11;
    const int ent_bits = (total_bits * 32) / 33;
    const int cs_bits = total_bits - ent_bits;
    if (cs_bits <= 0) return false;

    const int bits_bytes = (total_bits + 7) >> 3;
    std::vector<uint8_t> bits(static_cast<size_t>(bits_bytes), 0u);

    int bitpos = 0;
    for (int i = 0; i < n; ++i) {
        const int v = ids[i] & 0x7FF;
        for (int b = 10; b >= 0; --b) {
            const int bit = (v >> b) & 1;
            bits[static_cast<size_t>(bitpos >> 3)] |= static_cast<uint8_t>(bit << (7 - (bitpos & 7)));
            ++bitpos;
        }
    }

    const int ent_bytes = (ent_bits + 7) >> 3;
    std::vector<uint8_t> entropy(static_cast<size_t>(ent_bytes), 0u);
    for (int i = 0; i < ent_bytes; ++i) {
        entropy[static_cast<size_t>(i)] = bits[static_cast<size_t>(i)];
    }
    if ((ent_bits & 7) != 0 && !entropy.empty()) {
        entropy.back() &= static_cast<uint8_t>(0xFFu << (8 - (ent_bits & 7)));
    }

    uint8_t digest[32] = { 0 };
    sha256(entropy.data(), entropy.size(), digest);

    for (int i = 0; i < cs_bits; ++i) {
        const int phrase_bit_pos = ent_bits + i;
        const uint8_t phrase_bit = (bits[static_cast<size_t>(phrase_bit_pos >> 3)] >> (7 - (phrase_bit_pos & 7))) & 1u;
        const uint8_t digest_bit = (digest[static_cast<size_t>(i >> 3)] >> (7 - (i & 7))) & 1u;
        if (phrase_bit != digest_bit) {
            return false;
        }
    }

    return true;
}

// recovery_direct_release: recovery mode helper that releases the related data for direct.
static void recovery_direct_release(RecoveryGpuDirectContext& ctx) {
    if (ctx.devIndexes) {
        cudaFree(ctx.devIndexes);
        ctx.devIndexes = nullptr;
    }
    if (ctx.devLines) {
        cudaFree(ctx.devLines);
        ctx.devLines = nullptr;
    }
    if (ctx.devDerivationList) {
        cudaFree(ctx.devDerivationList);
        ctx.devDerivationList = nullptr;
    }
    if (ctx.devDerIndex) {
        cudaFree(ctx.devDerIndex);
        ctx.devDerIndex = nullptr;
    }
    if (ctx.devIter) {
        cudaFree(ctx.devIter);
        ctx.devIter = nullptr;
    }
    if (ctx.devRecoveryDict) {
        cudaFree(ctx.devRecoveryDict);
        ctx.devRecoveryDict = nullptr;
    }
    ctx.kernel_inflight = false;
    ctx.combined.clear();
    ctx.indexes.clear();
    ctx.devRecoveryDictWords = 0;
    ctx.activeWordlist = nullptr;
}

// recovery_direct_sync_previous: recovery mode helper that synchronizes previous for direct.
static cudaError_t recovery_direct_sync_previous(RecoveryGpuDirectContext& ctx) {
    if (!ctx.kernel_inflight) {
        return cudaSuccess;
    }
    cudaError_t st = cudaDeviceSynchronize();
    if (st != cudaSuccess) {
        return st;
    }
    const bool had_result = read_result_flag_host(ctx.buffIsResult);
    if (had_result) {
        clear_result_flag_host(ctx.buffIsResult);
        SaveResult(OUT_FILE, Founds, save, Derivations_list);
    }
    ctx.kernel_inflight = false;
    return cudaSuccess;
}

// recovery_direct_launch_current_batch: recovery mode helper that launches current batch for direct.
static cudaError_t recovery_direct_launch_current_batch(RecoveryGpuDirectContext& ctx, const uint32_t nr) {
    if (nr == 0u) {
        return cudaSuccess;
    }

    cudaError_t st = recovery_direct_sync_previous(ctx);
    if (st != cudaSuccess) {
        return st;
    }

    st = copy_to_device_grow(reinterpret_cast<void**>(&ctx.devLines), ctx.combined.data(), ctx.combined.size());
    if (st != cudaSuccess) {
        return st;
    }
    st = copy_to_device_grow(reinterpret_cast<void**>(&ctx.devIndexes), ctx.indexes.data(), ctx.indexes.size() * sizeof(uint32_t));
    if (st != cudaSuccess) {
        return st;
    }

    auto launch_kernel = [&](const uint32_t pass_len) -> cudaError_t {
        workerRecoveryCompat << <BLOCK_NUMBER, BLOCK_THREADS >> > (
            ctx.buffIsResult,
            ctx.buffDeviceResult,
            _dev_precomp,
            pitch,
            ctx.devLines,
            ctx.devIndexes,
            nr,
            ctx.devDerivationList,
            ctx.devDerIndex,
            derIndex_size,
            0,
            passwords_dev,
            pass_len,
            Rounds);

        cudaError_t launch_st = cudaGetLastError();
        if (launch_st == cudaSuccess) {
            counterTotal += static_cast<uint64_t>(nr) * static_cast<uint64_t>(Iterations.size());
            ctx.kernel_inflight = true;
        }
        return launch_st;
    };

    if (pass_set) {
        bool launched_any = false;

        for (size_t i = 0; i < passwords_files.size(); ++i) {
            const std::string& fname = passwords_files[i];
            std::ifstream* pass_stream = acquire_password_stream_for_rewind(fname);
            if (pass_stream == nullptr) {
                continue;
            }
            std::string password_line;
            while (read_trimmed_line(*pass_stream, password_line, 128)) {
                st = recovery_direct_sync_previous(ctx);
                if (st != cudaSuccess) {
                    return st;
                }
                st = copy_password_to_device(password_line.data(), password_line.size());
                if (st != cudaSuccess) {
                    return st;
                }
                st = launch_kernel(static_cast<uint32_t>(password_line.size()));
                if (st != cudaSuccess) {
                    return st;
                }
                launched_any = true;
            }
        }

        for (size_t i = 0; i < passwords_list.size(); ++i) {
            const std::string password_line = passwords_list[i];
            st = recovery_direct_sync_previous(ctx);
            if (st != cudaSuccess) {
                return st;
            }
            st = copy_password_to_device(password_line.data(), password_line.size());
            if (st != cudaSuccess) {
                return st;
            }
            st = launch_kernel(static_cast<uint32_t>(password_line.size()));
            if (st != cudaSuccess) {
                return st;
            }
            launched_any = true;
        }

        if (!launched_any) {
            st = launch_kernel(passwords_lenght_dev);
            if (st != cudaSuccess) {
                return st;
            }
        }
    }
    else {
        st = launch_kernel(passwords_lenght_dev);
        if (st != cudaSuccess) {
            return st;
        }
    }

    return cudaSuccess;
}

// recovery_direct_flush: recovery mode helper that flushes the related data for direct.
static bool recovery_direct_flush(RecoveryGpuDirectContext& ctx, std::string& err) {
    err.clear();
    if (ctx.indexes.empty()) {
        return true;
    }
    const uint32_t nr = static_cast<uint32_t>(ctx.indexes.size());
    const cudaError_t st = recovery_direct_launch_current_batch(ctx, nr);
    if (st != cudaSuccess) {
        err = std::string("recovery launch failed: ") + cudaGetErrorString(st);
        return false;
    }
    ctx.combined.clear();
    ctx.indexes.clear();
    return true;
}

// recovery_direct_append_candidate_u16: recovery mode helper that appends candidate u16 for direct.
static bool recovery_direct_append_candidate_u16(
    RecoveryGpuDirectContext& ctx,
    const RecoveryPreparedTask& task,
    const uint16_t* ids,
    const size_t ids_size,
    std::string& err) {
    err.clear();
    if (ids == nullptr || ids_size != task.ids.size()) {
        err = "invalid recovery candidate payload";
        return false;
    }
    if (ctx.indexes.size() >= ctx.batch_capacity) {
        if (!recovery_direct_flush(ctx, err)) {
            return false;
        }
    }
    for (size_t i = 0; i < ids_size; ++i) {
        if (i) {
            ctx.combined.push_back(' ');
        }
        const uint16_t id = ids[i];
        if (static_cast<size_t>(id) >= task.wordlist->words.size()) {
            err = "recovery candidate has invalid word id";
            return false;
        }
        ctx.combined.append(task.wordlist->words[static_cast<size_t>(id)]);
    }
    if (ctx.combined.size() > static_cast<size_t>(std::numeric_limits<uint32_t>::max())) {
        err = "recovery candidate batch exceeds indexable size";
        return false;
    }
    ctx.indexes.emplace_back(static_cast<uint32_t>(ctx.combined.size()));
    return true;
}

// recovery_direct_append_candidate_i32: recovery mode helper that appends candidate i32 for direct.
static bool recovery_direct_append_candidate_i32(
    RecoveryGpuDirectContext& ctx,
    const RecoveryPreparedTask& task,
    const std::vector<int>& ids,
    std::string& err) {
    std::vector<uint16_t> ids_u16(ids.size(), 0u);
    for (size_t i = 0; i < ids.size(); ++i) {
        const int id = ids[i];
        if (id < 0 || static_cast<size_t>(id) >= task.wordlist->words.size() || id > static_cast<int>(std::numeric_limits<uint16_t>::max())) {
            err = "recovery candidate has invalid CPU word id";
            return false;
        }
        ids_u16[i] = static_cast<uint16_t>(id);
    }
    return recovery_direct_append_candidate_u16(ctx, task, ids_u16.data(), ids_u16.size(), err);
}

// recovery_direct_append_batch_u16: recovery mode helper that appends batch u16 for direct.
static bool recovery_direct_append_batch_u16(
    RecoveryGpuDirectContext& ctx,
    const RecoveryPreparedTask& task,
    const uint16_t* ids,
    const size_t words_count,
    const uint32_t candidate_count,
    std::string& err) {
    err.clear();
    if (ids == nullptr || words_count != task.ids.size()) {
        err = "invalid recovery GPU batch payload";
        return false;
    }
    for (uint32_t i = 0; i < candidate_count; ++i) {
        const uint16_t* ptr = ids + static_cast<size_t>(i) * words_count;
        if (!recovery_direct_append_candidate_u16(ctx, task, ptr, words_count, err)) {
            return false;
        }
    }
    return true;
}

// recovery_direct_init: recovery mode helper that initializes the related data for direct.
static bool recovery_direct_init(RecoveryGpuDirectContext& ctx, std::string& err) {
    err.clear();
    recovery_direct_release(ctx);

    if (Derivations.empty() || derIndex.empty() || Iterations.empty()) {
        err = "recovery requires loaded derivations and iterations";
        return false;
    }

    const uint64_t output_size = static_cast<uint64_t>(BLOCK_NUMBER) * static_cast<uint64_t>(BLOCK_THREADS);
    ctx.batch_capacity = (output_size == 0ull) ? 1ull : output_size;
    ctx.iteration_size = static_cast<uint32_t>(Iterations.size());
    reserve_batch_buffers(ctx.combined, ctx.indexes, ctx.batch_capacity, 512);

    cudaError_t st = acquire_shared_result_buffers(ctx.batch_capacity, &ctx.buffIsResult, &ctx.buffDeviceResult);
    if (st != cudaSuccess) {
        err = std::string("acquire_shared_result_buffers failed: ") + cudaGetErrorString(st);
        return false;
    }

    st = cudaMalloc(reinterpret_cast<void**>(&ctx.devDerIndex), derIndex.size() * sizeof(uint32_t));
    if (st != cudaSuccess) {
        err = "cudaMalloc recovery devDerIndex failed";
        recovery_direct_release(ctx);
        return false;
    }
    st = cudaMalloc(reinterpret_cast<void**>(&ctx.devDerivationList), Derivations.size() * sizeof(uint32_t));
    if (st != cudaSuccess) {
        err = "cudaMalloc recovery devDerivationList failed";
        recovery_direct_release(ctx);
        return false;
    }
    st = cudaMalloc(reinterpret_cast<void**>(&ctx.devIter), Iterations.size() * sizeof(uint32_t));
    if (st != cudaSuccess) {
        err = "cudaMalloc recovery devIter failed";
        recovery_direct_release(ctx);
        return false;
    }

    st = cudaMemcpy(ctx.devDerIndex, derIndex.data(), derIndex.size() * sizeof(uint32_t), cudaMemcpyHostToDevice);
    if (st != cudaSuccess) {
        err = "cudaMemcpy recovery devDerIndex failed";
        recovery_direct_release(ctx);
        return false;
    }
    st = cudaMemcpy(ctx.devDerivationList, Derivations.data(), Derivations.size() * sizeof(uint32_t), cudaMemcpyHostToDevice);
    if (st != cudaSuccess) {
        err = "cudaMemcpy recovery devDerivationList failed";
        recovery_direct_release(ctx);
        return false;
    }
    st = cudaMemcpy(ctx.devIter, Iterations.data(), Iterations.size() * sizeof(uint32_t), cudaMemcpyHostToDevice);
    if (st != cudaSuccess) {
        err = "cudaMemcpy recovery devIter failed";
        recovery_direct_release(ctx);
        return false;
    }

    return true;
}

// recovery_direct_select_wordlist: recovery mode helper that selects wordlist for direct.
static bool recovery_direct_select_wordlist(RecoveryGpuDirectContext& ctx, const RecoveryPreparedTask& task, std::string& err) {
    err.clear();
    if (task.wordlist == nullptr) {
        err = "recovery task has no wordlist";
        return false;
    }

    if (ctx.activeWordlist == task.wordlist) {
        return true;
    }

    cudaError_t st = cudaSuccess;
    if (!task.wordlist->external && task.wordlist->device_lang >= 0) {
        setDict << <1, 1 >> > (task.wordlist->device_lang);
        st = cudaGetLastError();
        if (st != cudaSuccess) {
            err = "setDict launch failed";
            return false;
        }
        st = cudaDeviceSynchronize();
        if (st != cudaSuccess) {
            err = std::string("setDict sync failed: ") + cudaGetErrorString(st);
            return false;
        }
        ctx.activeWordlist = task.wordlist;
        return true;
    }

    if (task.wordlist->words.empty()) {
        err = "external wordlist is empty";
        return false;
    }

    const size_t dict_words = task.wordlist->words.size();
    const size_t dict_bytes = dict_words * 34u;

    std::vector<char> host_dict(dict_bytes, 0);
    for (size_t i = 0; i < dict_words; ++i) {
        const std::string& w = task.wordlist->words[i];
        const size_t copy_len = (w.size() > 33u) ? 33u : w.size();
        memcpy(host_dict.data() + i * 34u, w.data(), copy_len);
    }

    if (ctx.devRecoveryDictWords != dict_words) {
        if (ctx.devRecoveryDict) {
            cudaFree(ctx.devRecoveryDict);
            ctx.devRecoveryDict = nullptr;
            ctx.devRecoveryDictWords = 0;
        }
        st = cudaMalloc(reinterpret_cast<void**>(&ctx.devRecoveryDict), dict_bytes);
        if (st != cudaSuccess) {
            err = "cudaMalloc recovery external dictionary failed";
            return false;
        }
        ctx.devRecoveryDictWords = dict_words;
    }

    st = cudaMemcpy(ctx.devRecoveryDict, host_dict.data(), dict_bytes, cudaMemcpyHostToDevice);
    if (st != cudaSuccess) {
        err = "cudaMemcpy recovery external dictionary failed";
        return false;
    }

    setDictPointer << <1, 1 >> > (ctx.devRecoveryDict);
    st = cudaGetLastError();
    if (st != cudaSuccess) {
        err = "setDictPointer launch failed";
        return false;
    }
    st = cudaDeviceSynchronize();
    if (st != cudaSuccess) {
        err = std::string("setDictPointer sync failed: ") + cudaGetErrorString(st);
        return false;
    }

    ctx.activeWordlist = task.wordlist;
    return true;
}

// recovery_direct_finalize: recovery mode helper that finalizes the related data for direct.
static bool recovery_direct_finalize(RecoveryGpuDirectContext& ctx, std::string& err) {
    err.clear();
    if (!recovery_direct_flush(ctx, err)) {
        return false;
    }
    const cudaError_t st = recovery_direct_sync_previous(ctx);
    if (st != cudaSuccess) {
        err = std::string("recovery final sync failed: ") + cudaGetErrorString(st);
        return false;
    }
    return true;
}

// recovery_pow_u64: recovery mode helper that computes a checked integer power.
static bool recovery_pow_u64(const uint32_t base, const int exponent, uint64_t& out) {
    out = 1ull;
    if (base == 0u || exponent < 0) {
        return false;
    }
    for (int i = 0; i < exponent; ++i) {
        if (out > (std::numeric_limits<uint64_t>::max() / static_cast<uint64_t>(base))) {
            return false;
        }
        out *= static_cast<uint64_t>(base);
    }
    return true;
}

// recovery_pick_low_missing_count: keeps the GPU linear range representable by uint64_t.
static int recovery_pick_low_missing_count(const int missing_count, const uint32_t word_options_count, uint64_t& low_space_candidates) {
    int low_missing_count = (missing_count > 5) ? 5 : missing_count;
    while (low_missing_count > 0 && !recovery_pow_u64(word_options_count, low_missing_count, low_space_candidates)) {
        --low_missing_count;
    }
    if (low_missing_count == 0) {
        low_space_candidates = 1ull;
    }
    return low_missing_count;
}

// recovery_word_option_id: maps a local wildcard option to the active dictionary ID.
static uint16_t recovery_word_option_id(const RecoveryPreparedTask& task, const size_t option) {
    if (task.wordlist->word_options.empty()) {
        return static_cast<uint16_t>(option);
    }
    return task.wordlist->word_options[option];
}

// recovery_u64_add_saturating: recovery mode helper that adds saturating for u64.
static inline void recovery_u64_add_saturating(uint64_t& acc, const uint64_t delta) {
    const uint64_t max_v = std::numeric_limits<uint64_t>::max();
    if (acc > max_v - delta) {
        acc = max_v;
        return;
    }
    acc += delta;
}

// recovery_partition_active: returns true when current worker uses GPU partitioning.
static inline bool recovery_partition_active() {
    return g_recovery_multi_gpu_partition.enabled && g_recovery_multi_gpu_partition.count > 1u;
}

// recovery_partition_is_log_owner: recovery mode helper that checks whether partition log owner is valid.
static inline bool recovery_partition_is_log_owner() {
    return !recovery_partition_active() || g_recovery_multi_gpu_partition.index == 0u;
}

static inline bool split_u64_range(const uint64_t range_start,
    const uint64_t range_end,
    const size_t part_index,
    const size_t part_count,
    uint64_t& out_start,
    uint64_t& out_end) {
    if (range_start > range_end || part_count == 0) {
        return false;
    }

    uint64_t base = 0ull;
    uint64_t rem = 0ull;
    if (range_start == 0ull && range_end == std::numeric_limits<uint64_t>::max()) {
        const uint64_t k = static_cast<uint64_t>(part_count);
        uint64_t q = std::numeric_limits<uint64_t>::max() / k;
        uint64_t r = std::numeric_limits<uint64_t>::max() % k;
        base = q;
        rem = r + 1ull;
        if (rem == k) {
            ++base;
            rem = 0ull;
        }
    }
    else {
        const uint64_t total = range_end - range_start + 1ull;
        base = total / part_count;
        rem = total % part_count;
    }

    const uint64_t my = base + (part_index < rem ? 1ull : 0ull);
    if (my == 0) {
        return false;
    }

    const uint64_t offset = static_cast<uint64_t>(part_index) * base + std::min<uint64_t>(part_index, rem);
    out_start = range_start + offset;
    out_end = out_start + my - 1ull;
    return true;
}

// recovery_partition_take_span: recovery mode helper that takes span for partition.
static inline bool recovery_partition_take_span(const uint64_t total, uint64_t& out_start, uint64_t& out_count) {
    out_start = 0ull;
    out_count = total;
    if (total == 0ull || !recovery_partition_active()) {
        return true;
    }
    uint64_t end = 0ull;
    const bool ok = split_u64_range(
        0ull,
        total - 1ull,
        g_recovery_multi_gpu_partition.index,
        g_recovery_multi_gpu_partition.count,
        out_start,
        end);
    if (!ok) {
        out_start = 0ull;
        out_count = 0ull;
        return true;
    }
    out_count = (end - out_start) + 1ull;
    return true;
}

// recovery_partition_skip_high_combo: recovery mode helper that skips high combo for partition.
static inline bool recovery_partition_skip_high_combo(const uint64_t high_combo_index) {
    if (!recovery_partition_active()) {
        return false;
    }
    const uint64_t part_count = static_cast<uint64_t>(g_recovery_multi_gpu_partition.count);
    const uint64_t part_index = static_cast<uint64_t>(g_recovery_multi_gpu_partition.index);
    return (high_combo_index % part_count) != part_index;
}

// recovery_can_use_fused_path: recovery mode helper that checks whether use fused path is valid.
static bool recovery_can_use_fused_path() {
    if (g_derivation_policy != DerivationPolicy::Auto) return false;
    if (pass_set) return false;
    if (!secp256_host || ed25519_host || ed25519_bip32_host) return false;
    if (Iterations.size() != 1u || Iterations[0] != 1u) return false;

    if (!Compressed && !Uncompressed && !Segwit && !Taproot && !Ethereum && !Xpoint) return false;
    return true;
}

static inline bool parse_derivation_components_fast(const std::string& path, uint32_t& parsed_count) {
    parsed_count = 0;
    size_t start = 0;
    while (start < path.size()) {
        const size_t slash = path.find('/', start);
        size_t end = (slash == std::string::npos) ? path.size() : slash;

        if (end > start) {
            bool hardened = false;
            if (path[end - 1] == '\'') {
                hardened = true;
                --end;
            }
            if (end <= start) {
                return false;
            }

            uint64_t value = 0ull;
            for (size_t i = start; i < end; ++i) {
                const char c = path[i];
                if (c < '0' || c > '9') {
                    return false;
                }
                value = (value * 10ull) + static_cast<uint64_t>(c - '0');
                if (value > UINT32_MAX) {
                    return false;
                }
            }

            uint32_t v32 = static_cast<uint32_t>(value);
            if (hardened) {
                v32 |= 0x80000000u;
            }
            Derivations.emplace_back(v32);
            ++parsed_count;
        }

        if (slash == std::string::npos) {
            break;
        }
        start = slash + 1;
    }
    return parsed_count > 0;
}

static bool parse_derivation_policy_argument(const char* value, DerivationPolicy& out_policy) {
    if (value == nullptr || *value == '\0' || value[1] != '\0') {
        return false;
    }

    switch (value[0]) {
    case '1':
        out_policy = DerivationPolicy::ForceBip32Secp256k1;
        return true;
    case '2':
        out_policy = DerivationPolicy::ForceSlip0010Ed25519;
        return true;
    case '3':
        out_policy = DerivationPolicy::Mixed;
        return true;
    case '4':
        out_policy = DerivationPolicy::ForceEd25519Bip32Test;
        return true;
    default:
        return false;
    }
}

static void sort_derivations_by_path();

// recovery_emit_task_candidates_cpu: recovery mode helper that emits task candidates CPU.
static bool recovery_emit_task_candidates_cpu(RecoveryGpuDirectContext& ctx, const RecoveryPreparedTask& task, uint64_t& tested, uint64_t& emitted, std::string& err) {
    err.clear();
    tested = 0;
    emitted = 0;
    uint64_t emitted_pending = 0ull;
    constexpr uint64_t kCpuChecksumPublishStride = 4096ull;

    std::vector<int> ids = task.ids;
    uint64_t linear_index = 0ull;

    if (task.missing_positions.empty()) {
        const bool take_candidate = !recovery_partition_active() || g_recovery_multi_gpu_partition.index == 0u;
        if (!take_candidate) {
            return true;
        }
        tested = 1;
        if (task.effective_nvalid || recovery_bip39_checksum_valid(ids)) {
            if (!recovery_direct_append_candidate_i32(ctx, task, ids, err)) {
                return false;
            }
            emitted = 1;
            recovery_publish_checksum_valid_delta(1ull);
        }
        return true;
    }

    std::function<bool(size_t)> dfs;
    dfs = [&](const size_t depth) -> bool {
        if (depth >= task.missing_positions.size()) {
            bool take_candidate = true;
            if (recovery_partition_active()) {
                const uint64_t part_count = static_cast<uint64_t>(g_recovery_multi_gpu_partition.count);
                const uint64_t part_index = static_cast<uint64_t>(g_recovery_multi_gpu_partition.index);
                take_candidate = ((linear_index % part_count) == part_index);
                ++linear_index;
            }
            if (!take_candidate) {
                return true;
            }

            ++tested;
            if (task.effective_nvalid || recovery_bip39_checksum_valid(ids)) {
                if (!recovery_direct_append_candidate_i32(ctx, task, ids, err)) {
                    return false;
                }
                ++emitted;
                ++emitted_pending;
                if (emitted_pending >= kCpuChecksumPublishStride) {
                    recovery_publish_checksum_valid_delta(emitted_pending);
                    emitted_pending = 0ull;
                }
            }
            return true;
        }

        const int pos = task.missing_positions[depth];
        for (size_t w = 0; w < task.word_options_count; ++w) {
            ids[static_cast<size_t>(pos)] = static_cast<int>(recovery_word_option_id(task, w));
            if (!dfs(depth + 1u)) {
                return false;
            }
        }
        return true;
    };

    const bool ok = dfs(0u);
    if (ok && emitted_pending != 0ull) {
        recovery_publish_checksum_valid_delta(emitted_pending);
    }
    if (recovery_partition_is_log_owner() && (tested & ((1ull << 20) - 1ull)) == 0ull) {
        printf("                                                                        \r");
        fflush(stdout);
    }
    if (!ok && err.empty()) {
        err = "recovery CPU candidate submit failed";
    }
    return ok;
}

// recovery_emit_task_candidates_gpu: recovery mode helper that emits task candidates GPU.
static bool recovery_emit_task_candidates_gpu(RecoveryGpuDirectContext& ctx, const RecoveryPreparedTask& task, uint64_t& tested, uint64_t& emitted, std::string& err) {
    tested = 0;
    emitted = 0;
    err.clear();

    const int words_count_local = static_cast<int>(task.ids.size());
    const int missing_count = static_cast<int>(task.missing_positions.size());

    if (words_count_local <= 0 || words_count_local > 48 || (words_count_local % 3) != 0) {
        err = "unsupported word count for GPU recovery";
        return false;
    }

    if (missing_count == 0) {
        std::vector<int> ids = task.ids;
        const bool take_candidate = !recovery_partition_active() || g_recovery_multi_gpu_partition.index == 0u;
        if (!take_candidate) {
            return true;
        }
        tested = 1;
        if (task.effective_nvalid || recovery_bip39_checksum_valid(ids)) {
            if (!recovery_direct_append_candidate_i32(ctx, task, ids, err)) {
                return false;
            }
            emitted = 1;
            recovery_publish_checksum_valid_delta(1ull);
        }
        return true;
    }

    const uint32_t word_options_count = static_cast<uint32_t>(task.word_options_count);
    uint64_t low_space_candidates = 0ull;
    const int low_missing_count = recovery_pick_low_missing_count(missing_count, word_options_count, low_space_candidates);
    const int high_missing_count = missing_count - low_missing_count;

    uint64_t partition_low_start = 0ull;
    uint64_t partition_low_count = low_space_candidates;
    if (high_missing_count == 0) {
        recovery_partition_take_span(low_space_candidates, partition_low_start, partition_low_count);
    }

    std::vector<uint16_t> base_ids(static_cast<size_t>(words_count_local), 0u);
    for (int i = 0; i < words_count_local; ++i) {
        const int id = task.ids[static_cast<size_t>(i)];
        base_ids[static_cast<size_t>(i)] = static_cast<uint16_t>(id < 0 ? 0 : id);
    }

    std::vector<int> high_missing_positions;
    std::vector<int> low_missing_positions;
    high_missing_positions.reserve(static_cast<size_t>(high_missing_count));
    low_missing_positions.reserve(static_cast<size_t>(low_missing_count));

    for (int i = 0; i < missing_count; ++i) {
        const int pos = task.missing_positions[static_cast<size_t>(i)];
        if (i < high_missing_count) {
            high_missing_positions.emplace_back(pos);
        }
        else {
            low_missing_positions.emplace_back(pos);
        }
    }

    const uint32_t out_capacity = 262144u;
    const size_t out_ids_count = static_cast<size_t>(out_capacity) * static_cast<size_t>(words_count_local);

    uint16_t* d_base_ids = nullptr;
    int* d_missing_positions = nullptr;
    uint16_t* d_word_options = nullptr;
    uint16_t* d_out_ids = nullptr;
    uint32_t* d_out_count = nullptr;
    std::vector<uint16_t> host_out_ids;
    struct RecoveryRange {
        uint64_t start = 0ull;
        uint64_t count = 0ull;
    };
    std::vector<RecoveryRange> pending;
    std::vector<uint16_t> active_base_ids = base_ids;
    std::vector<uint16_t> high_digits(static_cast<size_t>(high_missing_count), 0u);

    cudaError_t st = cudaSetDevice(DEVICE_NR);
    if (st != cudaSuccess) {
        err = "cudaSetDevice failed";
        return false;
    }

    const unsigned int launch_threads = (BLOCK_THREADS == 0u) ? 256u : BLOCK_THREADS;
    const unsigned int launch_blocks = (BLOCK_NUMBER == 0u) ? 1024u : BLOCK_NUMBER;
    // Keep checksum-valid batches comfortably below the compaction buffer limit.
    // The old 4M boundary sits exactly on the 1/16 checksum expectation and proved unstable
    // during long staged multi-GPU recovery runs.
    const uint64_t hard_batch = task.effective_nvalid ? static_cast<uint64_t>(out_capacity) : (static_cast<uint64_t>(out_capacity) << 3);
    pending.reserve(128u);

    auto run_low_space = [&](const uint64_t range_start, const uint64_t range_count) -> bool {
        st = cudaMemcpy(d_base_ids, active_base_ids.data(), active_base_ids.size() * sizeof(uint16_t), cudaMemcpyHostToDevice);
        if (st != cudaSuccess) {
            err = "cudaMemcpy d_base_ids failed";
            return false;
        }

        pending.clear();
        pending.push_back({ range_start, range_count });

        while (!pending.empty()) {
            RecoveryRange range = pending.back();
            pending.pop_back();
            if (range.count == 0ull) {
                continue;
            }

            if (range.count > hard_batch) {
                pending.push_back({ range.start + hard_batch, range.count - hard_batch });
                range.count = hard_batch;
            }

            const unsigned int checksum_blocks = static_cast<unsigned int>(
                std::min<uint64_t>(
                    static_cast<uint64_t>(launch_blocks),
                    std::max<uint64_t>(1ull, (range.count + static_cast<uint64_t>(launch_threads) - 1ull) / static_cast<uint64_t>(launch_threads))));

            st = cudaMemset(d_out_count, 0, sizeof(uint32_t));
            if (st != cudaSuccess) {
                err = "cudaMemset d_out_count failed";
                return false;
            }

            st = launchWorkerRecoveryChecksum(
                d_base_ids,
                words_count_local,
                d_missing_positions,
                low_missing_count,
                d_word_options,
                word_options_count,
                task.effective_nvalid,
                range.start,
                range.count,
                d_out_ids,
                d_out_count,
                out_capacity,
                checksum_blocks,
                launch_threads);
            if (st != cudaSuccess) {
                err = "failed to launch GPU checksum processing";
                return false;
            }

            st = cudaDeviceSynchronize();
            if (st != cudaSuccess) {
                err = "cudaDeviceSynchronize failed";
                return false;
            }

            uint32_t found_total = 0u;
            st = cudaMemcpy(&found_total, d_out_count, sizeof(uint32_t), cudaMemcpyDeviceToHost);
            if (st != cudaSuccess) {
                err = "cudaMemcpy d_out_count failed";
                return false;
            }

            if (found_total > out_capacity && range.count > 1ull) {
                const uint64_t left = range.count >> 1;
                const uint64_t right = range.count - left;
                pending.push_back({ range.start + left, right });
                pending.push_back({ range.start, left });
                continue;
            }

            recovery_u64_add_saturating(tested, range.count);

            const uint32_t copy_count = (found_total > out_capacity) ? out_capacity : found_total;
            if (copy_count > 0u) {
                const size_t copy_words = static_cast<size_t>(copy_count) * static_cast<size_t>(words_count_local);
                st = cudaMemcpy(host_out_ids.data(), d_out_ids, copy_words * sizeof(uint16_t), cudaMemcpyDeviceToHost);
                if (st != cudaSuccess) {
                    err = "cudaMemcpy d_out_ids failed";
                    return false;
                }

                if (!recovery_direct_append_batch_u16(
                    ctx,
                    task,
                    host_out_ids.data(),
                    static_cast<size_t>(words_count_local),
                    copy_count,
                    err)) {
                    return false;
                }
            }

            recovery_u64_add_saturating(emitted, static_cast<uint64_t>(found_total));
            recovery_publish_checksum_valid_delta(static_cast<uint64_t>(found_total));
      /*      if ((tested & ((1ull << 20) - 1ull)) == 0ull) {
                printf("[!] Recovery tested: %llu | checksum-valid: %llu\r",
                    static_cast<unsigned long long>(tested),
                    static_cast<unsigned long long>(emitted));
                fflush(stdout);
            }*/
        }

        return true;
    };

    st = cudaMalloc(reinterpret_cast<void**>(&d_base_ids), base_ids.size() * sizeof(uint16_t));
    if (st != cudaSuccess) { err = "cudaMalloc d_base_ids failed"; goto cleanup; }
    st = cudaMalloc(reinterpret_cast<void**>(&d_missing_positions), low_missing_positions.size() * sizeof(int));
    if (st != cudaSuccess) { err = "cudaMalloc d_missing_positions failed"; goto cleanup; }
    st = cudaMalloc(reinterpret_cast<void**>(&d_out_ids), out_ids_count * sizeof(uint16_t));
    if (st != cudaSuccess) { err = "cudaMalloc d_out_ids failed"; goto cleanup; }
    st = cudaMalloc(reinterpret_cast<void**>(&d_out_count), sizeof(uint32_t));
    if (st != cudaSuccess) { err = "cudaMalloc d_out_count failed"; goto cleanup; }

    if (!task.wordlist->word_options.empty()) {
        st = cudaMalloc(reinterpret_cast<void**>(&d_word_options), task.wordlist->word_options.size() * sizeof(uint16_t));
        if (st != cudaSuccess) { err = "cudaMalloc d_word_options failed"; goto cleanup; }
        st = cudaMemcpy(d_word_options, task.wordlist->word_options.data(), task.wordlist->word_options.size() * sizeof(uint16_t), cudaMemcpyHostToDevice);
        if (st != cudaSuccess) { err = "cudaMemcpy d_word_options failed"; goto cleanup; }
    }

    st = cudaMemcpy(d_missing_positions, low_missing_positions.data(), low_missing_positions.size() * sizeof(int), cudaMemcpyHostToDevice);
    if (st != cudaSuccess) { err = "cudaMemcpy d_missing_positions failed"; goto cleanup; }
    host_out_ids.resize(out_ids_count);

    if (high_missing_count == 0) {
        if (!run_low_space(partition_low_start, partition_low_count)) {
            goto cleanup;
        }
    }
    else {
        uint64_t high_combo_index = 0ull;
        for (;;) {
            for (int i = 0; i < high_missing_count; ++i) {
                const int pos = high_missing_positions[static_cast<size_t>(i)];
                active_base_ids[static_cast<size_t>(pos)] = recovery_word_option_id(task, high_digits[static_cast<size_t>(i)]);
            }

            if (!recovery_partition_skip_high_combo(high_combo_index)) {
                if (!run_low_space(0ull, low_space_candidates)) {
                    goto cleanup;
                }
            }
            ++high_combo_index;

            int carry_idx = 0;
            for (; carry_idx < high_missing_count; ++carry_idx) {
                const uint32_t next = static_cast<uint32_t>(high_digits[static_cast<size_t>(carry_idx)]) + 1u;
                if (next < word_options_count) {
                    high_digits[static_cast<size_t>(carry_idx)] = static_cast<uint16_t>(next);
                    break;
                }
                high_digits[static_cast<size_t>(carry_idx)] = 0u;
            }

            if (carry_idx == high_missing_count) {
                break;
            }
        }
    }

cleanup:
    if (d_base_ids) cudaFree(d_base_ids);
    if (d_missing_positions) cudaFree(d_missing_positions);
    if (d_word_options) cudaFree(d_word_options);
    if (d_out_ids) cudaFree(d_out_ids);
    if (d_out_count) cudaFree(d_out_count);

    if (!err.empty()) {
        return false;
    }

    if (recovery_partition_is_log_owner() && (tested & ((1ull << 20) - 1ull)) == 0ull) {
        printf("                                                                        \r");
        fflush(stdout);
    }
    return true;
}

// recovery_emit_task_candidates_fused_gpu: recovery mode helper that emits task candidates fused GPU.
static bool recovery_emit_task_candidates_fused_gpu(RecoveryGpuDirectContext& ctx, const RecoveryPreparedTask& task, uint64_t& tested, uint64_t& emitted, std::string& err) {
    tested = 0;
    emitted = 0;
    err.clear();

    const int words_count_local = static_cast<int>(task.ids.size());
    const int missing_count = static_cast<int>(task.missing_positions.size());

    if (words_count_local <= 0 || words_count_local > 48 || (words_count_local % 3) != 0) {
        err = "unsupported word count for GPU-accelerated recovery";
        return false;
    }

    const uint32_t word_options_count = static_cast<uint32_t>(task.word_options_count);
    uint64_t low_space_candidates = 0ull;
    const int low_missing_count = recovery_pick_low_missing_count(missing_count, word_options_count, low_space_candidates);
    const int high_missing_count = missing_count - low_missing_count;

    uint64_t partition_low_start = 0ull;
    uint64_t partition_low_count = low_space_candidates;
    if (high_missing_count == 0) {
        recovery_partition_take_span(low_space_candidates, partition_low_start, partition_low_count);
    }

    std::vector<uint16_t> base_ids(static_cast<size_t>(words_count_local), 0u);
    for (int i = 0; i < words_count_local; ++i) {
        const int id = task.ids[static_cast<size_t>(i)];
        if (id > static_cast<int>(std::numeric_limits<uint16_t>::max())) {
            err = "invalid recovery base word id (>65535)";
            return false;
        }
        base_ids[static_cast<size_t>(i)] = static_cast<uint16_t>(id < 0 ? 0 : id);
    }

    std::vector<int> high_missing_positions;
    std::vector<int> low_missing_positions;
    high_missing_positions.reserve(static_cast<size_t>(high_missing_count));
    low_missing_positions.reserve(static_cast<size_t>(low_missing_count));

    for (int i = 0; i < missing_count; ++i) {
        const int pos = task.missing_positions[static_cast<size_t>(i)];
        if (i < high_missing_count) {
            high_missing_positions.emplace_back(pos);
        }
        else {
            low_missing_positions.emplace_back(pos);
        }
    }

    const uint32_t out_capacity = 262144u;
    const size_t out_ids_count = static_cast<size_t>(out_capacity) * static_cast<size_t>(words_count_local);
    const size_t master_words_count = static_cast<size_t>(out_capacity) * 16u;

    uint16_t* d_base_ids = nullptr;
    int* d_missing_positions = nullptr;
    uint16_t* d_word_options = nullptr;
    uint16_t* d_out_ids = nullptr;
    uint32_t* d_out_count = nullptr;
    uint32_t* d_master_words = nullptr;

    struct RecoveryRange {
        uint64_t start = 0ull;
        uint64_t count = 0ull;
    };
    std::vector<RecoveryRange> pending;
    std::vector<uint16_t> active_base_ids = base_ids;
    std::vector<uint16_t> high_digits(static_cast<size_t>(high_missing_count), 0u);

    cudaError_t st = cudaSetDevice(DEVICE_NR);
    if (st != cudaSuccess) {
        err = "cudaSetDevice failed";
        return false;
    }

    const unsigned int launch_threads = (BLOCK_THREADS == 0u) ? 256u : BLOCK_THREADS;
    const unsigned int launch_blocks = (BLOCK_NUMBER == 0u) ? 1024u : BLOCK_NUMBER;
    // Keep checksum-valid batches comfortably below the compaction buffer limit.
    // The old 4M boundary sits exactly on the 1/16 checksum expectation and proved unstable
    // during long staged multi-GPU recovery runs.
    const uint64_t hard_batch = task.effective_nvalid ? static_cast<uint64_t>(out_capacity) : (static_cast<uint64_t>(out_capacity) << 3);
    pending.reserve(128u);

    auto run_low_space = [&](const uint64_t range_start, const uint64_t range_count) -> bool {
        st = cudaMemcpy(d_base_ids, active_base_ids.data(), active_base_ids.size() * sizeof(uint16_t), cudaMemcpyHostToDevice);
        if (st != cudaSuccess) {
            err = "failed to upload recovery base indices";
            return false;
        }

        pending.clear();
        pending.push_back({ range_start, range_count });

        while (!pending.empty()) {
            RecoveryRange range = pending.back();
            pending.pop_back();
            if (range.count == 0ull) {
                continue;
            }

            if (range.count > hard_batch) {
                pending.push_back({ range.start + hard_batch, range.count - hard_batch });
                range.count = hard_batch;
            }

            const unsigned int checksum_blocks = static_cast<unsigned int>(
                std::min<uint64_t>(
                    static_cast<uint64_t>(launch_blocks),
                    std::max<uint64_t>(1ull, (range.count + static_cast<uint64_t>(launch_threads) - 1ull) / static_cast<uint64_t>(launch_threads))));

            st = cudaMemset(d_out_count, 0, sizeof(uint32_t));
            if (st != cudaSuccess) {
                err = "failed to reset the recovery candidate counter";
                return false;
            }

            st = launchWorkerRecoveryChecksum(
                d_base_ids,
                words_count_local,
                d_missing_positions,
                low_missing_count,
                d_word_options,
                word_options_count,
                task.effective_nvalid,
                range.start,
                range.count,
                d_out_ids,
                d_out_count,
                out_capacity,
                checksum_blocks,
                launch_threads);
            if (st != cudaSuccess) {
                err = "GPU checksum processing failed";
                return false;
            }

            uint32_t found_total = 0u;
            st = cudaMemcpy(&found_total, d_out_count, sizeof(uint32_t), cudaMemcpyDeviceToHost);
            if (st != cudaSuccess) {
                err = "failed to read the recovery candidate count";
                return false;
            }

            if (found_total > out_capacity && range.count > 1ull) {
                const uint64_t left = range.count >> 1;
                const uint64_t right = range.count - left;
                pending.push_back({ range.start + left, right });
                pending.push_back({ range.start, left });
                continue;
            }

            const uint32_t eval_count = (found_total > out_capacity) ? out_capacity : found_total;
            if (eval_count > 0u) {
                const unsigned int eval_blocks = static_cast<unsigned int>(
                    std::min<uint64_t>(
                        static_cast<uint64_t>(launch_blocks),
                        std::max<uint64_t>(1ull, (static_cast<uint64_t>(eval_count) + static_cast<uint64_t>(launch_threads) - 1ull) / static_cast<uint64_t>(launch_threads))));

                st = launchWorkerRecoverySeedBatch(
                    d_out_ids,
                    words_count_local,
                    eval_count,
                    passwords_dev,
                    passwords_lenght_dev,
                    ctx.devIter,
                    ctx.iteration_size,
                    d_master_words,
                    eval_blocks,
                    launch_threads);
                if (st != cudaSuccess) {
                    err = "GPU seed processing failed";
                    return false;
                }

                st = launchWorkerRecoveryEvalMasterBatch(
                    ctx.buffIsResult,
                    ctx.buffDeviceResult,
                    _dev_precomp,
                    pitch,
                    d_out_ids,
                    d_master_words,
                    words_count_local,
                    eval_count,
                    ctx.devDerivationList,
                    ctx.devDerIndex,
                    derIndex_size,
                    0u,
                    passwords_dev,
                    passwords_lenght_dev,
                    Rounds,
                    eval_blocks,
                    launch_threads);
                if (st != cudaSuccess) {
                    err = "GPU target validation failed";
                    return false;
                }

                st = cudaDeviceSynchronize();
                if (st != cudaSuccess) {
                    err = "device synchronization failed during recovery validation";
                    return false;
                }
            }

            const bool had_result = read_result_flag_host(ctx.buffIsResult);
            if (had_result) {
                clear_result_flag_host(ctx.buffIsResult);
                SaveResult(OUT_FILE, Founds, save, Derivations_list);
            }

            recovery_u64_add_saturating(tested, range.count);
            recovery_u64_add_saturating(emitted, static_cast<uint64_t>(found_total));
            recovery_publish_checksum_valid_delta(static_cast<uint64_t>(found_total));
            counterTotal += (range.count * static_cast<uint64_t>(Iterations.size()));

   /*         if ((tested & ((1ull << 20) - 1ull)) == 0ull) {
                printf("[!] Recovery tested: %llu | checksum-valid: %llu\r",
                    static_cast<unsigned long long>(tested),
                    static_cast<unsigned long long>(emitted));
                fflush(stdout);
            }*/
        }

        return true;
    };

    st = cudaMalloc(reinterpret_cast<void**>(&d_base_ids), base_ids.size() * sizeof(uint16_t));
    if (st != cudaSuccess) { err = "failed to allocate recovery workspace"; goto cleanup_fused; }
    if (low_missing_count > 0) {
        st = cudaMalloc(reinterpret_cast<void**>(&d_missing_positions), low_missing_positions.size() * sizeof(int));
        if (st != cudaSuccess) { err = "failed to allocate recovery workspace"; goto cleanup_fused; }
        st = cudaMemcpy(d_missing_positions, low_missing_positions.data(), low_missing_positions.size() * sizeof(int), cudaMemcpyHostToDevice);
        if (st != cudaSuccess) { err = "failed to upload recovery workspace data"; goto cleanup_fused; }
    }
    st = cudaMalloc(reinterpret_cast<void**>(&d_out_ids), out_ids_count * sizeof(uint16_t));
    if (st != cudaSuccess) { err = "failed to allocate recovery workspace"; goto cleanup_fused; }
    st = cudaMalloc(reinterpret_cast<void**>(&d_out_count), sizeof(uint32_t));
    if (st != cudaSuccess) { err = "failed to allocate recovery workspace"; goto cleanup_fused; }
    st = cudaMalloc(reinterpret_cast<void**>(&d_master_words), master_words_count * sizeof(uint32_t));
    if (st != cudaSuccess) { err = "failed to allocate recovery workspace"; goto cleanup_fused; }

    if (!task.wordlist->word_options.empty()) {
        st = cudaMalloc(reinterpret_cast<void**>(&d_word_options), task.wordlist->word_options.size() * sizeof(uint16_t));
        if (st != cudaSuccess) { err = "failed to allocate recovery word options"; goto cleanup_fused; }
        st = cudaMemcpy(d_word_options, task.wordlist->word_options.data(), task.wordlist->word_options.size() * sizeof(uint16_t), cudaMemcpyHostToDevice);
        if (st != cudaSuccess) { err = "failed to upload recovery word options"; goto cleanup_fused; }
    }

    if (high_missing_count == 0) {
        if (!run_low_space(partition_low_start, partition_low_count)) {
            goto cleanup_fused;
        }
    }
    else {
        uint64_t high_combo_index = 0ull;
        for (;;) {
            for (int i = 0; i < high_missing_count; ++i) {
                const int pos = high_missing_positions[static_cast<size_t>(i)];
                active_base_ids[static_cast<size_t>(pos)] = recovery_word_option_id(task, high_digits[static_cast<size_t>(i)]);
            }

            if (!recovery_partition_skip_high_combo(high_combo_index)) {
                if (!run_low_space(0ull, low_space_candidates)) {
                    goto cleanup_fused;
                }
            }
            ++high_combo_index;

            int carry_idx = 0;
            for (; carry_idx < high_missing_count; ++carry_idx) {
                const uint32_t next = static_cast<uint32_t>(high_digits[static_cast<size_t>(carry_idx)]) + 1u;
                if (next < word_options_count) {
                    high_digits[static_cast<size_t>(carry_idx)] = static_cast<uint16_t>(next);
                    break;
                }
                high_digits[static_cast<size_t>(carry_idx)] = 0u;
            }
            if (carry_idx == high_missing_count) {
                break;
            }
        }
    }

cleanup_fused:
    if (d_base_ids) cudaFree(d_base_ids);
    if (d_missing_positions) cudaFree(d_missing_positions);
    if (d_word_options) cudaFree(d_word_options);
    if (d_out_ids) cudaFree(d_out_ids);
    if (d_out_count) cudaFree(d_out_count);
    if (d_master_words) cudaFree(d_master_words);

    if (!err.empty()) {
        return false;
    }

    if (recovery_partition_is_log_owner() && (tested & ((1ull << 20) - 1ull)) == 0ull) {
        printf("                                                                        \r");
        fflush(stdout);
    }
    return true;
}

// recovery_emit_task_candidates: recovery mode helper that emits task candidates.
static bool recovery_emit_task_candidates(RecoveryGpuDirectContext& ctx, const RecoveryPreparedTask& task, bool use_fused_path, uint64_t& tested, uint64_t& emitted, std::string& err) {
    if (use_fused_path) {
        return recovery_emit_task_candidates_fused_gpu(ctx, task, tested, emitted, err);
    }

    std::string gpu_err;
    if (recovery_emit_task_candidates_gpu(ctx, task, tested, emitted, gpu_err)) {
        err.clear();
        return true;
    }

    if (!gpu_err.empty()) {
        fprintf(stderr, "[!] GPU-assisted checksum processing is unavailable for this task: %s [!]\n", gpu_err.c_str());
    }

    if (task.missing_positions.size() > 5u) {
        err = gpu_err.empty() ? "recovery GPU path failed for wildcard count > 5" : gpu_err;
        return false;
    }

    err.clear();
    if (!recovery_emit_task_candidates_cpu(ctx, task, tested, emitted, err)) {
        if (err.empty()) {
            err = gpu_err.empty() ? "recovery CPU fallback failed" : gpu_err;
        }
        return false;
    }
    return true;
}

// recovery_load_wordlists: recovery mode helper that loads wordlists.
static bool recovery_load_wordlists(std::vector<RecoveryWordlist>& out, std::string& err) {
    out.clear();

    std::vector<RecoveryWordlist> all_lists;
    all_lists.reserve(kRecoveryEmbeddedWordlistsCount);

    for (std::size_t i = 0; i < kRecoveryEmbeddedWordlistsCount; ++i) {
        RecoveryWordlist wl;
        std::string load_err;
        if (!recovery_add_embedded_wordlist(kRecoveryEmbeddedWordlists[i], wl, load_err)) {
            continue;
        }
        all_lists.emplace_back(std::move(wl));
    }

    if (all_lists.empty()) {
        err = "no embedded wordlists available";
        return false;
    }

    std::vector<RecoveryWordlist> bip39_lists;
    for (const RecoveryWordlist& wl : all_lists) {
        const std::string id_norm = recovery_norm_token(wl.id);
        const std::string file_norm = recovery_norm_token(wl.file_name);
        if (id_norm.find("bip39-") != std::string::npos || file_norm.find("bip39-") != std::string::npos) {
            bip39_lists.emplace_back(wl);
        }
    }

    if (!recoveryForcedWordlist.empty()) {
        RecoveryWordlist external_wl;
        if (!recovery_add_file_wordlist(recoveryForcedWordlist, external_wl, err)) {
            return false;
        }

        if (external_wl.words.size() != 2048u) {
            const RecoveryWordlist* matched_wordlist = nullptr;
            std::vector<uint16_t> matched_options;
            size_t matching_wordlists = 0u;

            for (const RecoveryWordlist& candidate : bip39_lists) {
                std::vector<uint16_t> candidate_options;
                candidate_options.reserve(external_wl.words_norm.size());
                bool matches = true;
                for (const std::string& word_norm : external_wl.words_norm) {
                    const auto it = candidate.id_by_norm.find(word_norm);
                    if (it == candidate.id_by_norm.end() || it->second < 0 || it->second > 2047) {
                        matches = false;
                        break;
                    }
                    candidate_options.emplace_back(static_cast<uint16_t>(it->second));
                }
                if (matches) {
                    ++matching_wordlists;
                    matched_wordlist = &candidate;
                    matched_options.swap(candidate_options);
                }
            }

            if (matching_wordlists == 1u && matched_wordlist != nullptr) {
                RecoveryWordlist subset = *matched_wordlist;
                subset.path = external_wl.path;
                subset.file_name = external_wl.file_name;
                subset.name = external_wl.file_name + " (subset of " + matched_wordlist->name + ")";
                subset.word_options.swap(matched_options);
                subset.source_word_count = external_wl.words.size();
                subset.standard_subset = true;
                subset.auto_nvalid = false;
                out.emplace_back(std::move(subset));
                return true;
            }

            external_wl.auto_nvalid = true;
        }

        out.emplace_back(std::move(external_wl));
        return true;
    }

    if (!bip39_lists.empty()) {
        out.swap(bip39_lists);
    }
    else {
        out.swap(all_lists);
    }

    return !out.empty();
}

static std::string recovery_format_input_ref(const RecoveryTemplateInput& in) {
    if (in.line_no > 0u) {
        return in.source + ":" + std::to_string(in.line_no);
    }
    return in.source;
}

static void recovery_log_prepared_task(const RecoveryPreparedTask& task, const bool recovery_log_master) {
    if (!recovery_log_master) {
        return;
    }

    if (task.added_stars > 0) {
        printf("[!] Recovery normalized word count by appending %llu wildcard(s). [!]\n",
            static_cast<unsigned long long>(task.added_stars));
    }
    for (const auto& repl : task.replacements) {
        printf("[!] Recovery replace: '%s' -> '%s' [!]\n", repl.first.c_str(), repl.second.c_str());
    }

    const size_t n_words = task.ids.size();
    const size_t missing = task.missing_positions.size();
    const long double combos = std::pow(static_cast<long double>(task.word_options_count), static_cast<long double>(missing));
    const long double expected_valid = task.effective_nvalid ? combos : (combos / std::pow(2.0L, static_cast<long double>(n_words / 3u)));

    if (task.wordlist->auto_nvalid) {
        printf("[!] External wordlist is not an unambiguous BIP39 subset; enabling -nvalid automatically. [!]\n");
    }
    else if (task.wordlist_source_is_standard_subset) {
        printf("[!] External wordlist recognized as an unambiguous BIP39 subset; checksum filtering remains enabled. [!]\n");
    }

    printf("[!] Recovery task: words=%llu missing=%llu options=%llu dict=%s checksum=%s [!]\n",
        static_cast<unsigned long long>(n_words),
        static_cast<unsigned long long>(missing),
        static_cast<unsigned long long>(task.word_options_count),
        task.wordlist->name.c_str(),
        task.effective_nvalid ? "disabled" : "enabled");
    printf("[!] Phrase: %s\n", task.normalized_phrase.c_str());
    printf("[!] Candidates to test: ~%s | expected checksum-valid: ~%s\n",
        recovery_format_scientific(combos).c_str(),
        recovery_format_scientific(expected_valid).c_str());
}

static bool recovery_process_prepared_task(
    RecoveryGpuDirectContext& recovery_ctx,
    const RecoveryPreparedTask& task,
    const bool use_fused_path,
    uint64_t& tested,
    uint64_t& emitted,
    std::string& err) {

    tested = 0ull;
    emitted = 0ull;
    err.clear();

    if (!recovery_direct_select_wordlist(recovery_ctx, task, err)) {
        return false;
    }
    if (!recovery_emit_task_candidates(recovery_ctx, task, use_fused_path, tested, emitted, err)) {
        if (err.empty()) {
            err = "recovery task generation failed";
        }
        return false;
    }
    if (!recovery_direct_finalize(recovery_ctx, err)) {
        if (err.empty()) {
            err = "recovery finalization failed";
        }
        return false;
    }
    return true;
}

template <typename Runner>
static bool recovery_process_streaming_input(
    const RecoveryTemplateInput& input,
    const std::vector<RecoveryWordlist>& wordlists,
    const bool recovery_log_master,
    Runner&& runner,
    RecoverySourceStats& source_stats,
    uint64_t& tested_total,
    uint64_t& emitted_total,
    uint64_t& processed_total,
    uint64_t& skipped_total,
    std::string& err) {

    RecoveryPreparedTask task;
    std::string prep_err;
    if (!recovery_prepare_task(input, wordlists, task, prep_err)) {
        fprintf(stderr, "[!] Recovery skip: %s -> %s [!]\n",
            recovery_format_input_ref(input).c_str(),
            prep_err.c_str());
        ++source_stats.skipped;
        ++skipped_total;
        return true;
    }

    recovery_log_prepared_task(task, recovery_log_master);

    const uint32_t found_before = Founds.load(std::memory_order_relaxed);
    uint64_t tested = 0ull;
    uint64_t emitted = 0ull;
    std::string task_err;
    if (!runner(task, tested, emitted, task_err)) {
        err = task_err.empty() ? "recovery task execution failed" : task_err;
        return false;
    }
    const uint32_t found_after = Founds.load(std::memory_order_relaxed);

    ++source_stats.processed;
    source_stats.tested += tested;
    source_stats.emitted += emitted;
    source_stats.found += static_cast<uint64_t>(found_after - found_before);

    ++processed_total;
    tested_total += tested;
    emitted_total += emitted;
    g_recovery_tested_total.fetch_add(tested, std::memory_order_relaxed);

    if (recovery_log_master) {
        printf("[!] Recovery task done: %s | tested=%llu checksum-valid=%llu [!]\n",
            recovery_format_input_ref(input).c_str(),
            static_cast<unsigned long long>(tested),
            static_cast<unsigned long long>(emitted));
    }

    return true;
}

struct RecoveryStreamingMultiGpuSession {
    std::mutex mutex;
    std::condition_variable cv_task;
    std::condition_variable cv_done;
    std::condition_variable cv_startup;
    std::vector<std::thread> workers;
    std::vector<cudaError_t> startup_statuses;
    std::vector<std::string> startup_errors;
    std::vector<cudaError_t> statuses;
    std::vector<std::string> errors;
    std::vector<uint64_t> tested;
    std::vector<uint64_t> emitted;
    const RecoveryPreparedTask* current_task = nullptr;
    bool current_use_fused_path = false;
    bool stop = false;
    uint64_t task_serial = 0ull;
    size_t startup_count = 0u;
    size_t completed = 0u;
};

static bool recovery_streaming_multi_gpu_session_start(
    RecoveryStreamingMultiGpuSession& session,
    std::string& err) {

    const size_t gpu_count = g_gpu_contexts.size();
    if (gpu_count == 0u) {
        err = "no active GPU contexts available";
        return false;
    }

    session.startup_statuses.assign(gpu_count, cudaSuccess);
    session.startup_errors.assign(gpu_count, std::string{});
    session.statuses.assign(gpu_count, cudaSuccess);
    session.errors.assign(gpu_count, std::string{});
    session.tested.assign(gpu_count, 0ull);
    session.emitted.assign(gpu_count, 0ull);
    session.workers.reserve(gpu_count);

    for (size_t gpu_idx = 0; gpu_idx < gpu_count; ++gpu_idx) {
        session.workers.emplace_back([&, gpu_idx, gpu_count]() {
            RecoveryGpuDirectContext recovery_ctx;
            std::string startup_err;
            cudaError_t startup_st = cudaSuccess;

            {
                std::lock_guard<std::mutex> lock(g_cuda_context_api_mutex);
                if (!activate_gpu_context(g_gpu_contexts[gpu_idx])) {
                    startup_st = cudaErrorInvalidDevice;
                    startup_err = "failed to activate GPU context";
                }
                else if (!recovery_direct_init(recovery_ctx, startup_err)) {
                    startup_st = cudaErrorUnknown;
                }
            }

            {
                std::lock_guard<std::mutex> lock(session.mutex);
                session.startup_statuses[gpu_idx] = startup_st;
                session.startup_errors[gpu_idx] = startup_err;
                ++session.startup_count;
            }
            session.cv_startup.notify_one();

            if (startup_st != cudaSuccess) {
                return;
            }

            uint64_t seen_serial = 0ull;
            const RecoveryMultiGpuPartition previous_partition = g_recovery_multi_gpu_partition;
            for (;;) {
                const RecoveryPreparedTask* task = nullptr;
                bool use_fused_path = false;

                {
                    std::unique_lock<std::mutex> lock(session.mutex);
                    session.cv_task.wait(lock, [&]() {
                        return session.stop || session.task_serial != seen_serial;
                    });
                    if (session.stop) {
                        break;
                    }
                    task = session.current_task;
                    use_fused_path = session.current_use_fused_path;
                    seen_serial = session.task_serial;
                }

                g_recovery_multi_gpu_partition.enabled = true;
                g_recovery_multi_gpu_partition.index = gpu_idx;
                g_recovery_multi_gpu_partition.count = gpu_count;

                uint64_t tested = 0ull;
                uint64_t emitted = 0ull;
                std::string task_err;
                cudaError_t task_st = cudaSuccess;
                if (task == nullptr || !recovery_process_prepared_task(recovery_ctx, *task, use_fused_path, tested, emitted, task_err)) {
                    task_st = cudaErrorUnknown;
                    if (task_err.empty()) {
                        task_err = "recovery task execution failed";
                    }
                }

                {
                    std::lock_guard<std::mutex> lock(session.mutex);
                    session.statuses[gpu_idx] = task_st;
                    session.errors[gpu_idx] = task_err;
                    session.tested[gpu_idx] = tested;
                    session.emitted[gpu_idx] = emitted;
                    ++session.completed;
                }
                session.cv_done.notify_one();
            }

            g_recovery_multi_gpu_partition = previous_partition;
            recovery_direct_release(recovery_ctx);
        });
    }

    {
        std::unique_lock<std::mutex> lock(session.mutex);
        session.cv_startup.wait(lock, [&]() {
            return session.startup_count == gpu_count;
        });
    }

    for (size_t gpu_idx = 0; gpu_idx < gpu_count; ++gpu_idx) {
        if (session.startup_statuses[gpu_idx] != cudaSuccess) {
            err = session.startup_errors[gpu_idx].empty()
                ? ("failed to initialize GPU " + std::to_string(g_gpu_contexts[gpu_idx].device_id))
                : ("GPU " + std::to_string(g_gpu_contexts[gpu_idx].device_id) + ": " + session.startup_errors[gpu_idx]);
            return false;
        }
    }

    return true;
}

static void recovery_streaming_multi_gpu_session_stop(RecoveryStreamingMultiGpuSession& session) {
    {
        std::lock_guard<std::mutex> lock(session.mutex);
        session.stop = true;
    }
    session.cv_task.notify_all();
    for (std::thread& worker : session.workers) {
        if (worker.joinable()) {
            worker.join();
        }
    }

    if (!g_gpu_contexts.empty()) {
        std::lock_guard<std::mutex> lock(g_cuda_context_api_mutex);
        activate_gpu_context(g_gpu_contexts.front());
    }
}

static bool recovery_streaming_multi_gpu_run_task(
    RecoveryStreamingMultiGpuSession& session,
    const RecoveryPreparedTask& task,
    const bool use_fused_path,
    uint64_t& tested,
    uint64_t& emitted,
    std::string& err) {

    tested = 0ull;
    emitted = 0ull;
    err.clear();

    {
        std::lock_guard<std::mutex> lock(session.mutex);
        std::fill(session.statuses.begin(), session.statuses.end(), cudaSuccess);
        std::fill(session.errors.begin(), session.errors.end(), std::string{});
        std::fill(session.tested.begin(), session.tested.end(), 0ull);
        std::fill(session.emitted.begin(), session.emitted.end(), 0ull);
        session.current_task = &task;
        session.current_use_fused_path = use_fused_path;
        session.completed = 0u;
        ++session.task_serial;
    }
    session.cv_task.notify_all();

    {
        std::unique_lock<std::mutex> lock(session.mutex);
        session.cv_done.wait(lock, [&]() {
            return session.completed == session.workers.size();
        });
    }

    for (size_t gpu_idx = 0; gpu_idx < session.workers.size(); ++gpu_idx) {
        if (session.statuses[gpu_idx] != cudaSuccess) {
            err = session.errors[gpu_idx].empty()
                ? ("GPU " + std::to_string(g_gpu_contexts[gpu_idx].device_id) + ": recovery task failed")
                : ("GPU " + std::to_string(g_gpu_contexts[gpu_idx].device_id) + ": " + session.errors[gpu_idx]);
            return false;
        }
        tested += session.tested[gpu_idx];
        emitted += session.emitted[gpu_idx];
    }

    return true;
}

// processCudaRecovery: runs the CUDA workflow for recovery.
cudaError_t processCudaRecovery() {
    g_recovery_run_stats = RecoveryRunStats{};
    g_recovery_tested_total.store(0ull, std::memory_order_relaxed);
    g_recovery_emitted_total.store(0ull, std::memory_order_relaxed);

    const bool use_multi_gpu_session = is_multi_gpu_active() && !g_disable_multi_gpu_dispatch;
    const bool recovery_log_master = true;

    std::vector<RecoveryWordlist> wordlists;
    std::string err;
    if (!recovery_load_wordlists(wordlists, err)) {
        fprintf(stderr, "[!] Recovery error: %s [!]\n", err.c_str());
        return cudaErrorInvalidValue;
    }
    const bool use_fused_path = recovery_can_use_fused_path();

    RecoveryGpuDirectContext recovery_ctx;
    RecoveryStreamingMultiGpuSession multi_session;
    cudaError_t st = cudaSuccess;
    uint64_t tested_total = 0ull;
    uint64_t emitted_total = 0ull;
    uint64_t processed_total = 0ull;
    uint64_t skipped_total = 0ull;

    auto stop_multi_session = [&]() {
        if (!multi_session.workers.empty()) {
            recovery_streaming_multi_gpu_session_stop(multi_session);
        }
    };

    if (use_multi_gpu_session) {
        if (!recovery_streaming_multi_gpu_session_start(multi_session, err)) {
            stop_multi_session();
            fprintf(stderr, "[!] Recovery error: %s [!]\n", err.c_str());
            return cudaErrorUnknown;
        }
    }
    else {
        if (!recovery_direct_init(recovery_ctx, err)) {
            fprintf(stderr, "[!] Recovery error: %s [!]\n", err.c_str());
            return cudaErrorUnknown;
        }
    }

    auto run_task = [&](const RecoveryPreparedTask& task, uint64_t& tested, uint64_t& emitted, std::string& task_err) -> bool {
        if (use_multi_gpu_session) {
            return recovery_streaming_multi_gpu_run_task(multi_session, task, use_fused_path, tested, emitted, task_err);
        }
        return recovery_process_prepared_task(recovery_ctx, task, use_fused_path, tested, emitted, task_err);
    };

    for (const RecoveryQueueEntry& entry : recoveryQueue) {
        RecoverySourceStats source_stats;
        source_stats.label = (entry.type == RecoveryQueueEntryType::File) ? entry.value : "<cmd>";
        source_stats.is_file = (entry.type == RecoveryQueueEntryType::File);

        if (source_stats.is_file) {
            printf("[!] Recovery source: %s [!]\n", source_stats.label.c_str());
        }

        if (entry.type == RecoveryQueueEntryType::Phrase) {
            const std::string phrase = recovery_trim_spaces_copy(entry.value);
            if (!phrase.empty()) {
                RecoveryTemplateInput input;
                input.source = "<cmd>";
                input.line_no = 0u;
                input.phrase = phrase;
                if (!recovery_process_streaming_input(input, wordlists, recovery_log_master, run_task, source_stats,
                    tested_total, emitted_total, processed_total, skipped_total, err)) {
                    fprintf(stderr, "[!] Recovery generator error: %s [!]\n", err.c_str());
                    st = cudaErrorUnknown;
                    break;
                }
            }
            continue;
        }

        std::ifstream fin(entry.value.c_str(), std::ios::binary);
        tune_ifstream_buffer(fin);
        if (!fin) {
            fprintf(stderr, "[!] Recovery error: failed to open recovery file: %s [!]\n", entry.value.c_str());
            st = cudaErrorInvalidValue;
            break;
        }

        std::string line;
        size_t line_no = 0u;
        while (read_trimmed_line(fin, line, 4096u)) {
            ++line_no;
            line = recovery_trim_spaces_copy(line);
            if (line.empty()) {
                continue;
            }

            RecoveryTemplateInput input;
            input.source = entry.value;
            input.line_no = line_no;
            input.phrase = std::move(line);
            if (!recovery_process_streaming_input(input, wordlists, recovery_log_master, run_task, source_stats,
                tested_total, emitted_total, processed_total, skipped_total, err)) {
                fprintf(stderr, "[!] Recovery generator error: %s [!]\n", err.c_str());
                st = cudaErrorUnknown;
                break;
            }
        }

        if (source_stats.is_file) {
            printf("[!] Recovery source done: %s | processed=%llu skipped=%llu tested=%llu checksum-valid=%llu found=%llu [!]\n",
                source_stats.label.c_str(),
                static_cast<unsigned long long>(source_stats.processed),
                static_cast<unsigned long long>(source_stats.skipped),
                static_cast<unsigned long long>(source_stats.tested),
                static_cast<unsigned long long>(source_stats.emitted),
                static_cast<unsigned long long>(source_stats.found));
        }

        if (st != cudaSuccess) {
            break;
        }
    }

    if (!use_multi_gpu_session) {
        recovery_direct_release(recovery_ctx);
    }
    stop_multi_session();

    if (st == cudaSuccess && processed_total == 0ull) {
        fprintf(stderr, "[!] Recovery error: no valid tasks to process [!]\n");
        st = cudaErrorInvalidValue;
    }

    if (st == cudaSuccess) {
        printf("[!] Recovery summary: processed=%llu skipped=%llu tested=%llu checksum-valid=%llu [!]\n",
            static_cast<unsigned long long>(processed_total),
            static_cast<unsigned long long>(skipped_total),
            static_cast<unsigned long long>(tested_total),
            static_cast<unsigned long long>(emitted_total));

        if (use_multi_gpu_session) {
            for (size_t gpu_idx = 0; gpu_idx < g_gpu_contexts.size(); ++gpu_idx) {
                printf("[!] Recovery device %d participated in the streaming session [!]\n",
                    g_gpu_contexts[gpu_idx].device_id);
            }
        }
    }

    g_recovery_run_stats.tested_total = tested_total;
    g_recovery_run_stats.emitted_total = emitted_total;

    return st;
}








#define rotl32_h(n,d) (((n) << (d)) | ((n) >> (32 - (d))))
// SWAP256_host: swaps 256 host.
inline uint32_t SWAP256_host(uint32_t val) {
    return (rotl32_h(((val) & (uint32_t)0x00FF00FF), (uint32_t)24U) | rotl32_h(((val) & (uint32_t)0xFF00FF00), (uint32_t)8U));
}

int RunRecoveryApp(int argc, char** argv)
{
#if defined(_WIN64) && !defined(__CYGWIN__) && !defined(__MINGW64__)
    SetConsoleOutputCP(CP_UTF8);
    _setmode(_fileno(stdin), _O_BINARY);
    SetUnhandledExceptionFilter(CrashHandler);
#endif
    setlocale(LC_ALL, "en_US.UTF-8");
    std::ios_base::sync_with_stdio(false);
    std::cin.tie(nullptr);

    printf("[!] %s %s by Mikhail Khoroshavin aka \"XopMC\"\n",
        cuda_mnemonic_recovery::kProjectName,
        cuda_mnemonic_recovery::kProjectVersion);
    printf("[!] Standalone BIP39 mnemonic recovery tool [!]\n");

    if (argc == 1) {
        printHelp();
        return 0;
    }

    if (!readArgs(argc, argv)) {
        if (g_public_help_requested) {
            printHelp();
            return 0;
        }
        return 1;
    }

    if (g_public_help_requested) {
        printHelp();
        return 0;
    }

    if (!RECOVERY_MODE) {
        fprintf(stderr, "[!] Error: this release supports only -recovery mode [!]\n");
        return 1;
    }

    if (recoveryQueue.empty()) {
        fprintf(stderr, "[!] Error: provide at least one recovery source via -recovery \"...\" or -recovery -i FILE [!]\n");
        return 1;
    }

    if (derivationFiles.empty()) {
        fprintf(stderr, "[!] Error: -d FILE is required [!]\n");
        return 1;
    }

    if (!load_public_recovery_derivations()) {
        fprintf(stderr, "[!] Error: loading derivations failed [!]\n");
        return 1;
    }

    if (pass_set) {
        preload_password_files_once();
    }

    if (!configure_derivation_policy_runtime()) {
        fprintf(stderr, "[!] Error: no target families selected for -c [!]\n");
        return 1;
    }
    PARAM_ECMULT_WINDOW_SIZE = 16;

    unsigned int requested_threads = set_thread ? BLOCK_THREADS : 0u;
    unsigned int requested_blocks = set_block ? BLOCK_NUMBER : 0u;

    if (!initialize_gpu_contexts(requested_threads, requested_blocks)) {
        fprintf(stderr, "[!] Error: failed to initialize selected GPU devices [!]\n");
        return 1;
    }

    std::cout << "[!] Active CUDA devices:";
    for (const auto& ctx : g_gpu_contexts) {
        std::cout << " " << ctx.device_id;
    }
    std::cout << "\n";

    if (!pass_set) {
        passwords.clear();
        passwords_list.clear();
        passwords_lenght.clear();
        passwords_list.push_back("");
        passwords_lenght.emplace_back(0u);
    }

    OUT_FILE = fopen(fileResult.c_str(), "a");
    if (OUT_FILE == nullptr) {
        fprintf(stderr, "[!] Error: failed to open output file '%s' [!]\n", fileResult.c_str());
        release_all_gpu_contexts();
        return 1;
    }

    std::time_t s_time = std::chrono::system_clock::to_time_t(std::chrono::system_clock::now());
    std::cout << "[!] Program started at: " << std::ctime(&s_time);

    std::thread speedThread;
    auto stopSpeedThread = [&]() {
        STOP_THREAD = true;
        if (speedThread.joinable()) {
            speedThread.join();
        }
    };

    STOP_THREAD = false;
    counterTotal = 0;
    g_recovery_tested_total.store(0ull, std::memory_order_relaxed);
    g_recovery_emitted_total.store(0ull, std::memory_order_relaxed);
    Founds.store(0u, std::memory_order_relaxed);
    speedThread = std::thread(SpeedThreadFunc);

    printf("[!] Starting mnemonic recovery mode [!]\n");
    const cudaError_t cudaStatus = processCudaRecovery();

    stopSpeedThread();
    recovery_console_clear_status_line();

    {
        std::lock_guard<std::mutex> lock(g_save_threads_mutex);
        if (!g_save_threads.empty()) {
            recovery_console_write_status_line("[!] Waiting for save workers to finish...");
        }
        for (auto& t : g_save_threads) {
            if (t.joinable()) {
                t.join();
            }
        }
        g_save_threads.clear();
    }
    recovery_console_clear_status_line();

    s_time = std::chrono::system_clock::to_time_t(std::chrono::system_clock::now());
    std::cout << "\n[!] Recovery tested " << g_recovery_tested_total.load(std::memory_order_relaxed)
              << " candidates. Checksum-valid: " << g_recovery_emitted_total.load(std::memory_order_relaxed)
              << ". Found: " << Founds.load(std::memory_order_relaxed) << ". Program finished at " << std::ctime(&s_time);

    if (OUT_FILE != nullptr) {
        fclose(OUT_FILE);
        OUT_FILE = nullptr;
    }
    release_all_gpu_contexts();

    return cudaStatus == cudaSuccess ? 0 : 1;
}

bool readArgs(int argc, char** argv) {
    g_public_help_requested = false;
    g_derivation_policy = DerivationPolicy::Auto;

    for (int a = 1; a < argc; ++a) {
        const char* arg = argv[a];

        if (!is_public_recovery_flag(arg)) {
            fprintf(stderr, "[!] Error: %s is not available in CUDA_Mnemonic_Recovery [!]\n", arg);
            return false;
        }

        if (strcmp(arg, "-h") == 0 || strcmp(arg, "-help") == 0) {
            g_public_help_requested = true;
            continue;
        }

        if (strcmp(arg, "-device") == 0) {
            if (++a >= argc) {
                fprintf(stderr, "[!] Error: -device requires value (example: 0 or 0,1,3 or 0-3) [!]\n");
                return false;
            }
            DEVICE_LIST.clear();
            parse_list_or_ranges<int>(argv[a], DEVICE_LIST, true);
            if (DEVICE_LIST.empty()) {
                fprintf(stderr, "[!] Error: invalid -device list '%s' [!]\n", argv[a]);
                return false;
            }
            DEVICE_NR = DEVICE_LIST.front();
            continue;
        }

        if (strcmp(arg, "-recovery") == 0) {
            RECOVERY_MODE = true;
            if (++a >= argc) {
                fprintf(stderr, "[!] Error: -recovery requires a phrase or '-i FILE' [!]\n");
                return false;
            }
            if (strcmp(argv[a], "-i") == 0) {
                if (++a >= argc) {
                    fprintf(stderr, "[!] Error: -recovery -i requires a file path [!]\n");
                    return false;
                }
                recoveryQueue.push_back({ RecoveryQueueEntryType::File, argv[a] });
                continue;
            }
            recoveryQueue.push_back({ RecoveryQueueEntryType::Phrase, argv[a] });
            continue;
        }

        if (strcmp(arg, "-i") == 0) {
            fprintf(stderr, "[!] Error: use '-recovery -i FILE' to add template files [!]\n");
            return false;
        }

        if (strcmp(arg, "-wordlist") == 0) {
            if (++a >= argc) {
                fprintf(stderr, "[!] Error: -wordlist requires a file path [!]\n");
                return false;
            }
            recoveryForcedWordlist = argv[a];
            continue;
        }

        if (strcmp(arg, "-nvalid") == 0) {
            recoveryIncludeInvalid = true;
            continue;
        }

        if (strcmp(arg, "-d") == 0) {
            if (++a >= argc) {
                fprintf(stderr, "[!] Error: -d requires a file path [!]\n");
                return false;
            }
            derivationFiles.push_back(argv[a]);
            continue;
        }

        if (strcmp(arg, "-d_type") == 0) {
            if (++a >= argc) {
                fprintf(stderr, "[!] Error: -d_type requires a value: 1, 2, 3 or 4 [!]\n");
                return false;
            }

            DerivationPolicy parsed_policy = DerivationPolicy::Auto;
            if (!parse_derivation_policy_argument(argv[a], parsed_policy)) {
                fprintf(stderr, "[!] Error: -d_type accepts only 1, 2, 3 or 4 [!]\n");
                return false;
            }

            g_derivation_policy = parsed_policy;
            continue;
        }

        if (strcmp(arg, "-c") == 0) {
            if (++a >= argc) {
                fprintf(stderr, "[!] Error: -c requires a value [!]\n");
                return false;
            }
            Ethereum = false;
            Compressed = false;
            Uncompressed = false;
            Segwit = false;
            Taproot = false;
            Xpoint = false;
            Solana = false;
            Ton = false;
            Ton_all = false;

            const char* value = argv[a];
            for (size_t i = 0; i < strlen(value); ++i) {
                if (!is_supported_public_target_family(value[i])) {
                    std::cerr << "[!] Target family '" << value[i]
                              << "' is not available in this release for '-c'. Allowed: c,u,s,r,x,e,S,t,T [!]" << std::endl;
                    return false;
                }
                switch (value[i]) {
                case 'c': Compressed = true; break;
                case 'u': Uncompressed = true; break;
                case 's': Segwit = true; break;
                case 'r': Taproot = true; break;
                case 'x': Xpoint = true; break;
                case 'e': Ethereum = true; break;
                case 'S': Solana = true; break;
                case 't': Ton = true; break;
                case 'T': Ton_all = true; break;
                default: break;
                }
            }
            continue;
        }

        if (strcmp(arg, "-hash") == 0) {
            if (++a >= argc) {
                std::cerr << "[!] Error: -hash requires HEX value (8..40 chars). [!]" << std::endl;
                return false;
            }
            uint32_t words[5] = { 0, 0, 0, 0, 0 };
            uint32_t masks[5] = { 0, 0, 0, 0, 0 };
            uint32_t len_bytes = 0;
            std::string normalized;
            std::string err;
            if (!parse_hash_target_argument(argv[a], words, masks, len_bytes, normalized, err)) {
                std::cerr << "[!] Error: invalid -hash value: " << err << " [!]" << std::endl;
                return false;
            }
            memcpy(hashTargetWordsHost, words, sizeof(hashTargetWordsHost));
            memcpy(hashTargetMasksHost, masks, sizeof(hashTargetMasksHost));
            hashTargetLenBytes = len_bytes;
            hashTargetHex = normalized;
            useHashTarget = true;
            continue;
        }

        if (strcmp(arg, "-bf") == 0) {
            if (++a >= argc) { std::cerr << "[!] Error: -bf requires a path [!]" << std::endl; return false; }
            add_filter_path(argv[a], bloomFiles, useBloom, exts_xb, false);
            continue;
        }
        if (strcmp(arg, "-xu") == 0) {
            if (++a >= argc) { std::cerr << "[!] Error: -xu requires a path [!]" << std::endl; return false; }
            add_filter_path(argv[a], xorFilesUn, useXorUn, exts_xu, false);
            continue;
        }
        if (strcmp(arg, "-xc") == 0) {
            if (++a >= argc) { std::cerr << "[!] Error: -xc requires a path [!]" << std::endl; return false; }
            add_filter_path(argv[a], xorFiles, useXor, exts_xc, false);
            continue;
        }
        if (strcmp(arg, "-xuc") == 0) {
            if (++a >= argc) { std::cerr << "[!] Error: -xuc requires a path [!]" << std::endl; return false; }
            add_filter_path(argv[a], xorFilesUc, useXorUc, exts_xuc, false);
            continue;
        }
        if (strcmp(arg, "-xh") == 0) {
            if (++a >= argc) { std::cerr << "[!] Error: -xh requires a path [!]" << std::endl; return false; }
            add_filter_path(argv[a], xorFilesHc, useXorHc, exts_xh, false);
            continue;
        }
        if (strcmp(arg, "-xx") == 0) {
            if (++a >= argc) { std::cerr << "[!] Error: -xx requires a path [!]" << std::endl; return false; }
            add_filter_path(argv[a], xorFilesCPU, useXorCPU, exts_xu, false);
            continue;
        }
        if (strcmp(arg, "-xb") == 0) {
            if (++a >= argc) { std::cerr << "[!] Error: -xb requires a path [!]" << std::endl; return false; }
            add_filter_path(argv[a], bloomFilesCPU, useBloomCPU, exts_xb, false);
            continue;
        }

        if (strcmp(arg, "-pbkdf") == 0) {
            if (++a >= argc) {
                fprintf(stderr, "[!] Error: -pbkdf requires an integer value [!]\n");
                return false;
            }
            pbkdf_iter = strtoull(argv[a], nullptr, 10);
            if (pbkdf_iter == 0ull) {
                fprintf(stderr, "[!] Error: -pbkdf must be greater than zero [!]\n");
                return false;
            }
            continue;
        }

        if (strcmp(arg, "-pass") == 0) {
            if (++a >= argc) {
                fprintf(stderr, "[!] Error: missing value for -pass [!]\n");
                return false;
            }
            std::ifstream ifs(argv[a]);
            tune_ifstream_buffer(ifs);
            if (ifs.is_open()) {
                passwords_files.push_back(argv[a]);
                ifs.close();
            }
            else {
                passwords += argv[a];
                passwords_lenght.emplace_back(static_cast<uint32_t>(passwords.size()));
                passwords_list.push_back(argv[a]);
            }
            pass_set = true;
            setPassMode();
            continue;
        }

        if (strcmp(arg, "-b") == 0) {
            if (++a >= argc) {
                fprintf(stderr, "[!] Error: -b requires an integer value [!]\n");
                return false;
            }
            BLOCK_NUMBER = static_cast<unsigned int>(strtoul(argv[a], nullptr, 10));
            set_block = true;
            continue;
        }

        if (strcmp(arg, "-t") == 0) {
            if (++a >= argc) {
                fprintf(stderr, "[!] Error: -t requires an integer value [!]\n");
                return false;
            }
            BLOCK_THREADS = static_cast<unsigned int>(strtoul(argv[a], nullptr, 10));
            set_thread = true;
            continue;
        }

        if (strcmp(arg, "-fsize") == 0) {
            if (++a >= argc) {
                fprintf(stderr, "[!] Error: -fsize requires an integer value [!]\n");
                return false;
            }
            MAX_FOUNDS = static_cast<uint32_t>(strtoul(argv[a], nullptr, 10));
            if (MAX_FOUNDS == 0u) {
                fprintf(stderr, "[!] Error: -fsize must be greater than zero [!]\n");
                return false;
            }
            continue;
        }

        if (strcmp(arg, "-o") == 0) {
            if (++a >= argc) {
                fprintf(stderr, "[!] Error: -o requires a file path [!]\n");
                return false;
            }
            fileResult = argv[a];
            continue;
        }

        if (strcmp(arg, "-save") == 0) {
            save = true;
            continue;
        }

        if (strcmp(arg, "-silent") == 0) {
            setSilentMode();
            continue;
        }

        if (strcmp(arg, "-full") == 0) {
            FULL = true;
            continue;
        }
    }

    return true;
}
static bool append_derivation_entry(std::string buffer) {
    if (buffer.empty()) {
        return true;
    }

    if ((buffer == "m") || (buffer == "m/")) {
        derIndex.emplace_back(0);
        derIndex_size++;
        Derivations_list.push_back("m/");
        return true;
    }

    if (buffer.size() >= 2 && buffer[0] == 'm' && buffer[1] == '/') {
        buffer.erase(0, 2);
    }
    if (buffer.empty()) {
        derIndex.emplace_back(0);
        derIndex_size++;
        Derivations_list.push_back("m/");
        return true;
    }

    uint64_t last_value = 0;
    bool last_hardened = false;
    bool can_increment_last = false;
    std::string prefix;
    {
        const size_t pos = buffer.find_last_of('/');
        const size_t start = (pos == std::string::npos) ? 0 : pos + 1;
        std::string last = buffer.substr(start);
        if (!last.empty() && last.back() == '\'') {
            last_hardened = true;
            last.pop_back();
        }
        if (!last.empty()) {
            can_increment_last = true;
            for (char c : last) {
                if (c < '0' || c > '9') {
                    can_increment_last = false;
                    break;
                }
                last_value = (last_value * 10ull) + static_cast<uint64_t>(c - '0');
                if (last_value > UINT32_MAX) {
                    can_increment_last = false;
                    break;
                }
            }
        }
        prefix = (pos == std::string::npos) ? "" : buffer.substr(0, pos + 1);
    }

    for (uint32_t step = 0; step <= deep; ++step) {
        std::string buf2 = buffer;
        if (step && can_increment_last) {
            const uint64_t next = last_value + static_cast<uint64_t>(step);
            if (next > UINT32_MAX) {
                break;
            }
            buf2 = prefix + std::to_string(next) + (last_hardened ? "'" : "");
        }

        uint32_t parsed_count = 0;
        if (!parse_derivation_components_fast(buf2, parsed_count)) {
            return false;
        }

        derIndex.emplace_back(parsed_count);
        derIndex_size++;
        Derivations_list.push_back("m/" + buf2);
    }

    return true;
}

// parseDerivations: parses derivations.
bool parseDerivations(vector<string> file) {
    for (size_t i = 0; i < file.size(); ++i) {
        std::ifstream stream(file[i].c_str(), std::ios::binary);
        tune_ifstream_buffer(stream);
        if (!stream) {
            std::cerr << "[!] Failed to open derivations file: " << file[i] << " [!]" << std::endl;
            continue;
        }

        std::string buffer;
        while (read_trimmed_line(stream, buffer, 512)) {
            try {
                if (!append_derivation_entry(buffer)) {
                    throw std::runtime_error("invalid derivation");
                }
            }
            catch (const std::exception&) {
                std::cerr << "[!] Wrong derivation: " << buffer << " skipped [!]" << std::endl;
                continue;
            }
        }
    }

    if (Derivations_list.empty()) return false;
    /* Sort derivation paths lexicographically. Consecutive paths with common prefixes
     * maximize cache hits in get_child_key_secp256k1 (deriv_cache). */
    sort_derivations_by_path();
    return true;
}

/* Reorder Derivations, derIndex, Derivations_list so paths are sorted lexicographically.
 * Improves derivation cache hit rate when many paths share prefixes (e.g. m/44'/0'/0'/0/0..N). */
static void sort_derivations_by_path() {
    const size_t n = derIndex.size();
    if (n <= 1u) return;

    std::vector<size_t> offsets(n + 1, 0);
    for (size_t i = 0; i < n; i++)
        offsets[i + 1] = offsets[i] + derIndex[i];

    std::vector<size_t> perm(n);
    for (size_t i = 0; i < n; i++) perm[i] = i;

    auto path_less = [&](size_t a, size_t b) {
        const uint32_t* pa = Derivations.data() + offsets[a];
        const uint32_t* pb = Derivations.data() + offsets[b];
        const size_t la = derIndex[a], lb = derIndex[b];
        const size_t l = (la < lb) ? la : lb;
        for (size_t i = 0; i < l; i++) {
            if (pa[i] != pb[i]) return pa[i] < pb[i];
        }
        return la < lb;
    };
    std::sort(perm.begin(), perm.end(), path_less);

    std::vector<uint32_t> newDerivations;
    std::vector<uint32_t> newDerIndex;
    std::vector<std::string> newDerivations_list;
    newDerivations.reserve(Derivations.size());
    newDerIndex.reserve(n);
    newDerivations_list.reserve(n);

    for (size_t i = 0; i < n; i++) {
        const size_t idx = perm[i];
        const size_t off = offsets[idx], len = derIndex[idx];
        newDerIndex.push_back(static_cast<uint32_t>(len));
        newDerivations_list.push_back(Derivations_list[idx]);
        for (size_t j = 0; j < len; j++)
            newDerivations.push_back(Derivations[off + j]);
    }
    Derivations = std::move(newDerivations);
    derIndex = std::move(newDerIndex);
    Derivations_list = std::move(newDerivations_list);
}

// readHex: reads hex.
void readHex(char* buf, const char* txt) {
    char b[3] = "00";
    for (unsigned int i = 0; i < strlen(txt); i += 2) {
        b[0] = *(txt + i);
        b[1] = *(txt + i + 1);
        *(buf + (i >> 1)) = static_cast<char>(strtoul(b, NULL, 16));
    }
}

// checkDevice: checks whether device is valid.
bool checkDevice() {
    cudaError_t cudaStatus = cudaSetDevice(DEVICE_NR);
    if (cudaStatus != cudaSuccess) {
        fprintf(stderr, "[!] Device %d initialization failed: %s [!]\n", DEVICE_NR, cudaGetErrorString(cudaStatus));
        return false;
    }
    cudaDeviceProp props{};
    cudaStatus = cudaGetDeviceProperties(&props, DEVICE_NR);
    if (cudaStatus != cudaSuccess) {
        fprintf(stderr, "[!] Failed to query device %d properties: %s [!]\n", DEVICE_NR, cudaGetErrorString(cudaStatus));
        return false;
    }

    fprintf(stderr, "[!] Using device: %d (%s)\n", DEVICE_NR, props.name);

    if (BLOCK_THREADS == 0u) {
        BLOCK_THREADS = std::min<unsigned int>(256u, static_cast<unsigned int>(props.maxThreadsPerBlock));
    }

    const size_t deriv_count = Derivations_list.empty() ? 1u : Derivations_list.size();
    unsigned int blocks_per_sm = (deriv_count > 2u) ? 2u : 1u;

    if (BLOCK_NUMBER == 0u) {

        if (useBloom || useXor || useXorUn || useXorUc || useXorHc || useHashTarget) {
            blocks_per_sm = std::max<unsigned int>(blocks_per_sm, 2u);
        }
        if (pass_set) {
            blocks_per_sm = std::max<unsigned int>(blocks_per_sm, 2u);
        }

        const unsigned int max_output_threads = 16u * 1024u * 1024u;
        const unsigned int max_blocks = std::max<unsigned int>(1u, max_output_threads / std::max<unsigned int>(1u, BLOCK_THREADS));
        unsigned int max_blocks_per_sm = std::max<unsigned int>(1u, max_blocks / std::max<int>(1, props.multiProcessorCount));
        blocks_per_sm = std::min(blocks_per_sm, max_blocks_per_sm);

        BLOCK_NUMBER = std::max<unsigned int>(1u, static_cast<unsigned int>(props.multiProcessorCount) * blocks_per_sm);
    }

    workSize = static_cast<uint64_t>(BLOCK_NUMBER) * static_cast<uint64_t>(BLOCK_THREADS) * static_cast<uint64_t>(THREAD_STEPS);
    fprintf(stderr, "[!] Auto-tuned recovery launch: %u blocks/SM (derivations: %zu)\n", blocks_per_sm, deriv_count);
    fprintf(stderr, "[!] %s (%2d SMs | Blocks: %u | Threads: %u)\n", props.name, props.multiProcessorCount, BLOCK_NUMBER, BLOCK_THREADS);
    return true;
}

// mallocFounds: allocates founds.
bool mallocFounds(uint32_t N) {
    cudaError_t cudaStatus;
    size_t free0, total0, free1, total1;
    cudaMemGetInfo(&free0, &total0);
    cudaStatus = cudaMalloc(&p_str, static_cast<size_t>(N) * 512u);
    if (cudaStatus != cudaSuccess) {
        fprintf(stderr, "[!] CUDA malloc for mnemonic strings failed [!]\n");
        return false;
    }
    cudaStatus = cudaMalloc(&p_len1, static_cast<size_t>(N) * sizeof(uint32_t));
    if (cudaStatus != cudaSuccess) {
        fprintf(stderr, "[!] CUDA malloc for mnemonic lengths failed [!]\n");
        return false;
    }
    cudaStatus = cudaMalloc(&p_der, static_cast<size_t>(N) * sizeof(uint32_t));
    if (cudaStatus != cudaSuccess) {
        fprintf(stderr, "[!] CUDA malloc for derivation indices failed [!]\n");
        return false;
    }
    if (pass_set) {
        cudaStatus = cudaMalloc(&p_pas, static_cast<size_t>(N) * 128u);
        if (cudaStatus != cudaSuccess) {
            fprintf(stderr, "[!] CUDA malloc for passphrase buffer failed [!]\n");
            return false;
        }
        cudaStatus = cudaMalloc(&p_pas_size, static_cast<size_t>(N) * sizeof(uint16_t));
        if (cudaStatus != cudaSuccess) {
            fprintf(stderr, "[!] CUDA malloc for passphrase sizes failed [!]\n");
            return false;
        }
    }

    cudaStatus = cudaMalloc(&p_prv, static_cast<size_t>(N) * 64u);
    if (cudaStatus != cudaSuccess) {
        fprintf(stderr, "[!] CUDA malloc for private keys failed [!]\n");
        return false;
    }
    cudaStatus = cudaMalloc(&p_h160, static_cast<size_t>(N) * 20u * sizeof(uint32_t));
    if (cudaStatus != cudaSuccess) {
        fprintf(stderr, "[!] CUDA malloc for target matches failed [!]\n");
        return false;
    }
    cudaStatus = cudaMalloc(&p_typ, static_cast<size_t>(N) * sizeof(uint8_t));
    if (cudaStatus != cudaSuccess) {
        fprintf(stderr, "[!] CUDA malloc for type tags failed [!]\n");
        return false;
    }
    cudaStatus = cudaMalloc(&p_result_derivation_type, static_cast<size_t>(N) * sizeof(uint8_t));
    if (cudaStatus != cudaSuccess) {
        fprintf(stderr, "[!] CUDA malloc for derivation type tags failed [!]\n");
        return false;
    }
    cudaStatus = cudaMalloc(&p_round, static_cast<size_t>(N) * sizeof(int64_t));
    if (cudaStatus != cudaSuccess) {
        fprintf(stderr, "[!] CUDA malloc for round tags failed [!]\n");
        return false;
    }

    char (*p_str2)[512] = reinterpret_cast<char (*)[512]>(p_str);
    unsigned char (*p_prv2)[64] = reinterpret_cast<unsigned char (*)[64]>(p_prv);
    char (*p_pas2)[128] = reinterpret_cast<char (*)[128]>(p_pas);
    uint32_t (*p_h160_2)[20] = reinterpret_cast<uint32_t (*)[20]>(p_h160);
    uint32_t (*p_len2)[1] = reinterpret_cast<uint32_t (*)[1]>(p_len1);

    cudaStatus = cudaMemcpyToSymbol(d_foundStrings, &p_str2, sizeof(p_str2));
    if (cudaStatus != cudaSuccess) {
        fprintf(stderr, "[!] CUDA symbol upload for mnemonic strings failed [!]\n");
        return false;
    }
    cudaStatus = cudaMemcpyToSymbol(d_len, &p_len2, sizeof(p_len2));
    if (cudaStatus != cudaSuccess) {
        fprintf(stderr, "[!] CUDA symbol upload for mnemonic lengths failed [!]\n");
        return false;
    }
    cudaStatus = cudaMemcpyToSymbol(d_foundDerivations, &p_der, sizeof(p_der));
    if (cudaStatus != cudaSuccess) {
        fprintf(stderr, "[!] CUDA symbol upload for derivation indices failed [!]\n");
        return false;
    }
    if (pass_set) {
        cudaStatus = cudaMemcpyToSymbol(d_pass, &p_pas2, sizeof(p_pas2));
        if (cudaStatus != cudaSuccess) {
            fprintf(stderr, "[!] CUDA symbol upload for passphrase buffer failed [!]\n");
            return false;
        }
        cudaStatus = cudaMemcpyToSymbol(d_pass_size, &p_pas_size, sizeof(p_pas_size));
        if (cudaStatus != cudaSuccess) {
            fprintf(stderr, "[!] CUDA symbol upload for passphrase sizes failed [!]\n");
            return false;
        }
    }

    cudaStatus = cudaMemcpyToSymbol(d_foundPrvKeys, &p_prv2, sizeof(p_prv2));
    if (cudaStatus != cudaSuccess) {
        fprintf(stderr, "[!] CUDA symbol upload for private keys failed [!]\n");
        return false;
    }
    cudaStatus = cudaMemcpyToSymbol(d_foundHash160, &p_h160_2, sizeof(p_h160_2));
    if (cudaStatus != cudaSuccess) {
        fprintf(stderr, "[!] CUDA symbol upload for target matches failed [!]\n");
        return false;
    }
    cudaStatus = cudaMemcpyToSymbol(d_type, &p_typ, sizeof(p_typ));
    if (cudaStatus != cudaSuccess) {
        fprintf(stderr, "[!] CUDA symbol upload for type tags failed [!]\n");
        return false;
    }
    cudaStatus = cudaMemcpyToSymbol(d_resultDerivationType, &p_result_derivation_type, sizeof(p_result_derivation_type));
    if (cudaStatus != cudaSuccess) {
        fprintf(stderr, "[!] CUDA symbol upload for derivation type tags failed [!]\n");
        return false;
    }
    cudaStatus = cudaMemcpyToSymbol(d_round, &p_round, sizeof(p_round));
    if (cudaStatus != cudaSuccess) {
        fprintf(stderr, "[!] CUDA symbol upload for rounds failed [!]\n");
        return false;
    }

    cudaStatus = cudaMemset(p_str, 0, static_cast<size_t>(N) * 512u);
    if (cudaStatus != cudaSuccess) {
        fprintf(stderr, "[!] CUDA memset for mnemonic strings failed [!]\n");
        return false;
    }
    cudaStatus = cudaMemset(p_len1, 0, static_cast<size_t>(N) * sizeof(uint32_t));
    if (cudaStatus != cudaSuccess) {
        fprintf(stderr, "[!] CUDA memset for mnemonic lengths failed [!]\n");
        return false;
    }
    cudaStatus = cudaMemset(p_der, 0, static_cast<size_t>(N) * sizeof(uint32_t));
    if (cudaStatus != cudaSuccess) {
        fprintf(stderr, "[!] CUDA memset for derivation indices failed [!]\n");
        return false;
    }
    if (pass_set) {
        cudaStatus = cudaMemset(p_pas, 0, static_cast<size_t>(N) * 128u);
        if (cudaStatus != cudaSuccess) {
            fprintf(stderr, "[!] CUDA memset for passphrase buffer failed [!]\n");
            return false;
        }
        cudaStatus = cudaMemset(p_pas_size, 0, static_cast<size_t>(N) * sizeof(uint16_t));
        if (cudaStatus != cudaSuccess) {
            fprintf(stderr, "[!] CUDA memset for passphrase sizes failed [!]\n");
            return false;
        }
    }
    cudaStatus = cudaMemset(p_prv, 0, static_cast<size_t>(N) * 64u);
    if (cudaStatus != cudaSuccess) {
        fprintf(stderr, "[!] CUDA memset for private keys failed [!]\n");
        return false;
    }
    cudaStatus = cudaMemset(p_h160, 0, static_cast<size_t>(N) * 20u * sizeof(uint32_t));
    if (cudaStatus != cudaSuccess) {
        fprintf(stderr, "[!] CUDA memset for target matches failed [!]\n");
        return false;
    }
    cudaStatus = cudaMemset(p_typ, 0, static_cast<size_t>(N) * sizeof(uint8_t));
    if (cudaStatus != cudaSuccess) {
        fprintf(stderr, "[!] CUDA memset for type tags failed [!]\n");
        return false;
    }
    cudaStatus = cudaMemset(p_result_derivation_type, 0, static_cast<size_t>(N) * sizeof(uint8_t));
    if (cudaStatus != cudaSuccess) {
        fprintf(stderr, "[!] CUDA memset for derivation type tags failed [!]\n");
        return false;
    }
    cudaStatus = cudaMemset(p_round, 0, static_cast<size_t>(N) * sizeof(int64_t));
    if (cudaStatus != cudaSuccess) {
        fprintf(stderr, "[!] CUDA memset for rounds failed [!]\n");
        return false;
    }

    cudaDeviceSynchronize();
    cudaMemGetInfo(&free1, &total1);   // Snapshot after allocations.
    printf("[!] GPU %d founds memory allocated: %.2f MiB [!]\n", DEVICE_NR, (free0 - free1) / 1024.0 / 1024.0);
    return true;
}

// prepareCuda: prepares cuda.
cudaError_t prepareCuda() {
    unsigned int windows;
    unsigned int bits;
    size_t window_size;
    cudaError_t cudaStatus;
    gpu_bloom_loaded = false;
    gpu_xor_loaded = false;
    gpu_xor_un_loaded = false;
    gpu_xor_uc_loaded = false;
    gpu_xor_hc_loaded = false;
    static std::mutex s_cpu_filter_load_mutex;
    static bool s_cpu_filters_loaded = false;


#ifdef ECMULT_BIG_TABLE
    bits = PARAM_ECMULT_WINDOW_SIZE;
    //printf("prec big gen %d bit, please wait\n", bits);
    windows = (256 / bits) + 1;
    window_size = (size_t{ 1 } << (bits - 1));
    printf("[!] GPU %d: preparing cuda device... Please wait... \n", DEVICE_NR);
    if (secp256_host || secp_target_host) {
        cudaStatus = cudaMallocPitch(&_dev_precomp, &pitch, sizeof(secp256k1_ge_storage) * window_size, windows);
        if (cudaStatus != cudaSuccess) {
            fprintf(stderr, "[!] Cuda prepare failed: kernel launch failed: %s [!]\n", cudaGetErrorString(cudaStatus));
            goto Error;
        }
        secp256k1_gej* _dev_gej_temp;// = new secp256k1_gej[WINDOW_SIZE];
        cudaStatus = cudaMalloc((void**)&_dev_gej_temp, window_size * sizeof(secp256k1_gej));
        secp256k1_fe* _dev_z_ratio;// = new secp256k1_fe[WINDOW_SIZE];
        cudaStatus = cudaMalloc((void**)&_dev_z_ratio, window_size * sizeof(secp256k1_fe));

        cudaStatus = loadWindow(bits, windows);
        if (cudaStatus != cudaSuccess) {
            fprintf(stderr, "[!] Cuda prepare failed: loadWindow(bits) %d! [!]\n", cudaStatus);
            goto Error;
        }

        ecmult_big_create << <1, 1 >> > (_dev_gej_temp, _dev_z_ratio, _dev_precomp, pitch, bits);
        cudaStatus = cudaGetLastError();
        if (cudaStatus != cudaSuccess) {
            fprintf(stderr, "[!] Cuda prepare failed: kernel launch failed: %s [!]\n", cudaGetErrorString(cudaStatus));
            goto Error;
        }
        cudaStatus = cudaDeviceSynchronize();
        if (cudaStatus != cudaSuccess) {
            fprintf(stderr, "[!] Cuda prepare failed: cudaDeviceSynchronize returned error code %d after launching kernel 'computeTable'! [!]\n", cudaStatus);
            goto Error;
        }
        printf("[!] GPU %d: preparing finished \n", DEVICE_NR);
    Error:
        cudaFree(_dev_gej_temp);
        cudaFree(_dev_z_ratio);

    }
#else
    bits = ECMULT_GEN_PREC_BITS;
    if (bits != 8 && bits != 4 && bits != 2) {
        int g = ECMULT_GEN_PREC_G;
        int n = ECMULT_GEN_PREC_N;
        secp256k1_ge_storage* _dev_prec_table = new secp256k1_ge_storage[g * n];
        secp256k1_ge* _dev_prec = new secp256k1_ge[g * n];
        secp256k1_gej* _dev_precj = new secp256k1_gej[g * n];

        cudaStatus = cudaMalloc((void**)&_dev_precj, g * n * sizeof(secp256k1_gej));
        cudaStatus = cudaMalloc((void**)&_dev_prec, g * n * sizeof(secp256k1_ge));
        cudaStatus = cudaMalloc((void**)&_dev_prec_table, g * n * sizeof(secp256k1_ge_storage));

        computeTable << <1, 1 >> > (_dev_prec_table, _dev_prec, _dev_precj);
        cudaStatus = cudaGetLastError();
        if (cudaStatus != cudaSuccess) {
            fprintf(stderr, "[!] Cuda prepare failed: kernel launch failed: %s [!]\n", cudaGetErrorString(cudaStatus));
            goto Error;
        }
        cudaStatus = cudaDeviceSynchronize();
        if (cudaStatus != cudaSuccess) {
            fprintf(stderr, "[!] Cuda prepare failed: cudaDeviceSynchronize returned error code %d after launching kernel 'computeTable'! [!]\n", cudaStatus);
            goto Error;
        }
    Error:
        cudaFree(_dev_precj);
        cudaFree(_dev_prec);
        cudaFree(_dev_prec_table);

    }
#endif
    if (FULL)
    {
        setFULL << <1, 1 >> > ();
        printf("[!] using -full --- saving all recovery hits without target filters [!]\n");
    }
    else
    {
        if (useBloom) {
            printf("[!] loading [%lld] bloom filter(s):\n", bloomFiles.size());
            cudaStatus = _targetLookup.setTargets(bloomFiles);
            if (cudaStatus != cudaSuccess) {
                fprintf(stderr, "\n[!] Bloom filter(s) loading failed on GPU %d, skipping bloom on this GPU: %s [!]\n", DEVICE_NR, cudaGetErrorString(cudaStatus));
            }
            else {
                gpu_bloom_loaded = true;
            }
        }
        if (useXor)
        {
            printf("[!] loading [%lld] compressed xor filter(s):\n", xorFiles.size());
            cudaStatus = setTargetXorFilter(xorFiles);
            if (cudaStatus != cudaSuccess) {
                fprintf(stderr, "\n[!] Compressed xor filters loading failed on GPU %d, skipping on this GPU: %s [!]\n", DEVICE_NR, cudaGetErrorString(cudaStatus));
            }
            else {
                gpu_xor_loaded = true;
            }
        }
        if (useXorUn)
        {
            printf("[!] loading [%lld] uncompressed xor filter(s):\n", xorFilesUn.size());
            cudaStatus = setTargetXorUnFilter(xorFilesUn);
            if (cudaStatus != cudaSuccess) {
                fprintf(stderr, "\n[!] Uncompressed xor filters loading failed on GPU %d, skipping on this GPU: %s [!]\n", DEVICE_NR, cudaGetErrorString(cudaStatus));
            }
            else {
                gpu_xor_un_loaded = true;
            }
        }
        if (useXorUc)
        {
            printf("[!] loading [%lld] ultra compressed xor filter(s):\n", xorFilesUc.size());
            cudaStatus = setTargetXorUcFilter(xorFilesUc);
            if (cudaStatus != cudaSuccess) {
                fprintf(stderr, "\n[!] Ultra compressed xor filters loading failed on GPU %d, skipping on this GPU: %s [!]\n", DEVICE_NR, cudaGetErrorString(cudaStatus));
            }
            else {
                gpu_xor_uc_loaded = true;
            }
        }
        if (useXorHc)
        {
            printf("[!] loading [%lld] hyper compressed xor filter(s):\n", xorFilesHc.size());
            cudaStatus = setTargetXorHcFilter(xorFilesHc);
            if (cudaStatus != cudaSuccess) {
                fprintf(stderr, "\n[!] Hyper compressed xor filters loading failed on GPU %d, skipping on this GPU: %s [!]\n", DEVICE_NR, cudaGetErrorString(cudaStatus));
            }
            else {
                gpu_xor_hc_loaded = true;
            }
        }

        if (useBloomCPU || useXorCPU)
        {
            bool need_cpu_load = false;
            {
                std::lock_guard<std::mutex> lock(s_cpu_filter_load_mutex);
                if (!s_cpu_filters_loaded) {
                    s_cpu_filters_loaded = true;
                    need_cpu_load = true;
                }
            }

            if (need_cpu_load) {
                if (useBloomCPU)
                {
                    printf("[!] loading [%lld] bloom filter(s) in CPU RAM:\n", bloomFilesCPU.size());
                    if (!loadBloomFiltersIntoSharedMemory(bloomFilesCPU))
                    {
                        fprintf(stderr, "\n[!] Bloom filter(s) CPU loading failed [!]\n");
                        {
                            std::lock_guard<std::mutex> lock(s_cpu_filter_load_mutex);
                            s_cpu_filters_loaded = false;
                        }
                        goto Error;
                    }

                }
                if (useXorCPU)
                {
                    printf("[!] loading [%lld] uncompressed xor filter(s) in CPU RAM:\n", xorFilesCPU.size());
                    if (!loadXorFilters(xorFilesCPU))
                    {
                        fprintf(stderr, "\n[!] XOR's CPU loading failed [!]\n");
                        {
                            std::lock_guard<std::mutex> lock(s_cpu_filter_load_mutex);
                            s_cpu_filters_loaded = false;
                        }
                        goto Error;
                    }

                }
            }
        }
    }
    cudaStatus = loadHashTarget(hashTargetWordsHost, hashTargetMasksHost, hashTargetLenBytes, useHashTarget);
    if (cudaSuccess != cudaStatus) {
        fprintf(stderr, "\n[!] Cuda prepare failed: 'loadHashTarget' %s [!]\n", cudaGetErrorString(cudaStatus));
        goto Error;
    }
    if (useHashTarget) {
        printf("[!] GPU %d: loaded hash prefix matcher (%u byte(s), hex=%s)\n",
            DEVICE_NR, hashTargetLenBytes, hashTargetHex.c_str());
    }
    printf("[!] GPU %d: all preparation finished.\n", DEVICE_NR);
    cudaMemGetInfo(&free_gpu_end, &total_gpu_end);
    printf("[!] GPU %d total memory used: %.2f MiB [!]\n", DEVICE_NR, (free_gpu_start - free_gpu_end) / 1024.0 / 1024.0);
    printf("-----------------------------------------------------------------\n");
    printf("[!] Loaded bloom filters on GPU %d: %lld\n", DEVICE_NR, gpu_bloom_loaded ? (long long)bloomFiles.size() : 0ll);
    printf("[!] Loaded uncompressed xor filters on GPU %d: %lld\n", DEVICE_NR, gpu_xor_un_loaded ? (long long)xorFilesUn.size() : 0ll);
    printf("[!] Loaded compressed xor filters on GPU %d: %lld\n", DEVICE_NR, gpu_xor_loaded ? (long long)xorFiles.size() : 0ll);
    printf("[!] Loaded ultra compressed xor filters on GPU %d: %lld\n", DEVICE_NR, gpu_xor_uc_loaded ? (long long)xorFilesUc.size() : 0ll);
    printf("[!] Loaded hyper compressed xor filters on GPU %d: %lld\n", DEVICE_NR, gpu_xor_hc_loaded ? (long long)xorFilesHc.size() : 0ll);
    printf("[!] Loaded hash prefix matcher on GPU %d: %s\n", DEVICE_NR, useHashTarget ? "yes" : "no");
    return cudaStatus;
}

// release_gpu_context: releases GPU context.
static void release_gpu_context(GpuRuntimeContext& ctx) {
    if (cudaSetDevice(ctx.device_id) != cudaSuccess) {
        return;
    }
    if (ctx.p_str) cudaFree(ctx.p_str);
    if (ctx.p_prv) cudaFree(ctx.p_prv);
    if (ctx.p_h160) cudaFree(ctx.p_h160);
    if (ctx.p_typ) cudaFree(ctx.p_typ);
    if (ctx.p_result_derivation_type) cudaFree(ctx.p_result_derivation_type);
    if (ctx.p_len1) cudaFree(ctx.p_len1);
    if (ctx.p_der) cudaFree(ctx.p_der);
    if (ctx.p_pas) cudaFree(ctx.p_pas);
    if (ctx.p_pas_size) cudaFree(ctx.p_pas_size);
    if (ctx.p_round) cudaFree(ctx.p_round);
    if (ctx.p_seed) cudaFree(ctx.p_seed);
    if (ctx.passwords_dev) cudaFree(ctx.passwords_dev);
    if (ctx.shared_result_flag) cudaFree(ctx.shared_result_flag);
    if (ctx.shared_result_buffer) cudaFree(ctx.shared_result_buffer);
    if (ctx.dev_precomp) cudaFree(ctx.dev_precomp);

    ctx.p_str = nullptr;
    ctx.p_prv = nullptr;
    ctx.p_h160 = nullptr;
    ctx.p_typ = nullptr;
    ctx.p_result_derivation_type = nullptr;
    ctx.p_len1 = nullptr;
    ctx.p_der = nullptr;
    ctx.p_pas = nullptr;
    ctx.p_pas_size = nullptr;
    ctx.p_round = nullptr;
    ctx.p_seed = nullptr;
    ctx.p_results_count = nullptr;
    ctx.passwords_dev = nullptr;
    ctx.passwords_dev_capacity = 0;
    ctx.passwords_lenght_dev = 0;
    ctx.shared_result_flag = nullptr;
    ctx.shared_result_buffer = nullptr;
    ctx.shared_result_buffer_capacity = 0;
    ctx.dev_precomp = nullptr;
    ctx.pitch = 0;
    ctx.bloom_loaded = false;
    ctx.xor_loaded = false;
    ctx.xor_un_loaded = false;
    ctx.xor_uc_loaded = false;
    ctx.xor_hc_loaded = false;
}

// release_all_gpu_contexts: releases all GPU contexts.
static void release_all_gpu_contexts() {
    for (auto& ctx : g_gpu_contexts) {
        release_gpu_context(ctx);
    }
    g_gpu_contexts.clear();
    g_save_output_with_gpu_prefix = false;
}

// build_valid_device_list: builds valid device list.
static bool build_valid_device_list(std::vector<int>& out_devices) {
    out_devices.clear();
    int device_count = 0;
    cudaError_t st = cudaGetDeviceCount(&device_count);
    if (st != cudaSuccess || device_count <= 0) {
        fprintf(stderr, "[!] CUDA device enumeration failed: %s [!]\n", cudaGetErrorString(st));
        return false;
    }

    if (DEVICE_LIST.empty()) {
        DEVICE_LIST.push_back(DEVICE_NR);
    }

    std::unordered_set<int> seen;
    for (const int dev : DEVICE_LIST) {
        if (dev < 0 || dev >= device_count) {
            fprintf(stderr, "[!] Warning: device %d is out of range [0..%d], skipped [!]\n", dev, device_count - 1);
            continue;
        }
        if (seen.insert(dev).second) {
            out_devices.push_back(dev);
        }
    }
    return !out_devices.empty();
}

// initialize_gpu_contexts: initializes GPU contexts.
static bool initialize_gpu_contexts(const unsigned int requested_threads, const unsigned int requested_blocks) {
    g_save_output_with_gpu_prefix = false;
    std::vector<int> valid_devices;
    if (!build_valid_device_list(valid_devices)) {
        fprintf(stderr, "[!] No valid CUDA devices selected [!]\n");
        return false;
    }

    g_gpu_contexts.clear();
    for (const int dev : valid_devices) {
        reset_thread_local_gpu_runtime_aliases_for_init();
        _dev_precomp = nullptr;
        pitch = 0;
        gpu_bloom_loaded = false;
        gpu_xor_loaded = false;
        gpu_xor_un_loaded = false;
        gpu_xor_uc_loaded = false;
        gpu_xor_hc_loaded = false;

        DEVICE_NR = dev;
        BLOCK_THREADS = requested_threads;
        BLOCK_NUMBER = requested_blocks;

        fprintf(stderr, "[!] Initializing GPU %d...\n", dev);
        if (!checkDevice()) {
            fprintf(stderr, "[!] Device %d init skipped [!]\n", dev);
            continue;
        }

        cudaMemGetInfo(&free_gpu_start, &total_gpu_start);
        setFoundSize << <1, 1 >> > (MAX_FOUNDS);
        cudaError_t st = cudaDeviceSynchronize();
        if (st != cudaSuccess) {
            fprintf(stderr, "[!] setFoundSize failed on GPU %d: %s [!]\n", dev, cudaGetErrorString(st));
            continue;
        }

        if (!mallocFounds(MAX_FOUNDS)) {
            fprintf(stderr, "[!] mallocFounds failed on GPU %d [!]\n", dev);
            continue;
        }

        st = prepareCuda();
        if (st != cudaSuccess) {
            fprintf(stderr, "[!] prepareCuda failed on GPU %d: %s [!]\n", dev, cudaGetErrorString(st));
            GpuRuntimeContext tmp = capture_current_gpu_context();
            release_gpu_context(tmp);
            continue;
        }

        uint64_t shared_result_capacity = static_cast<uint64_t>(BLOCK_NUMBER) * static_cast<uint64_t>(BLOCK_THREADS);
        uint64_t max_output_multiplier = 1ull;
        if (static_cast<uint64_t>(THREAD_STEPS) > max_output_multiplier) {
            max_output_multiplier = static_cast<uint64_t>(THREAD_STEPS);
        }
        if (static_cast<uint64_t>(THREAD_STEPS_PUB_H) > max_output_multiplier) {
            max_output_multiplier = static_cast<uint64_t>(THREAD_STEPS_PUB_H);
        }
        if (max_output_multiplier > 1ull) {
            if (shared_result_capacity > (std::numeric_limits<uint64_t>::max() / max_output_multiplier)) {
                shared_result_capacity = std::numeric_limits<uint64_t>::max();
            }
            else {
                shared_result_capacity *= max_output_multiplier;
            }
        }
        st = init_shared_result_buffers_for_current_gpu(shared_result_capacity);
        if (st != cudaSuccess) {
            fprintf(stderr, "[!] shared result buffers init failed on GPU %d: %s [!]\n", dev, cudaGetErrorString(st));
            GpuRuntimeContext tmp = capture_current_gpu_context();
            release_gpu_context(tmp);
            continue;
        }

        if (!pass_set) {
            st = copy_password_to_device("", 0);
            if (st != cudaSuccess) {
                fprintf(stderr, "[!] default password upload failed on GPU %d: %s [!]\n", dev, cudaGetErrorString(st));
                GpuRuntimeContext tmp = capture_current_gpu_context();
                release_gpu_context(tmp);
                continue;
            }
            passwords_lenght_dev = 0;
        }
        else {
            setPASS << <1, 1 >> > ();
        }

        rand_state << <1, 1 >> > ();
        SetCurve << <1, 1 >> > (secp256_host, ed25519_host, ed25519_bip32_host, Compressed, Uncompressed, Segwit, Taproot, Ethereum, Xpoint, Solana, Ton, Ton_all);
        setFilterType << <1, 1 >> > (gpu_bloom_loaded, gpu_xor_loaded, gpu_xor_un_loaded, gpu_xor_uc_loaded, gpu_xor_hc_loaded);
        setDict << <1, 1 >> > (language);
        set_iter << <1, 1 >> > (pbkdf_iter);

        st = cudaDeviceSynchronize();
        if (st != cudaSuccess) {
            fprintf(stderr, "[!] Runtime constant setup failed on GPU %d: %s [!]\n", dev, cudaGetErrorString(st));
            GpuRuntimeContext tmp = capture_current_gpu_context();
            release_gpu_context(tmp);
            continue;
        }

        void* results_counter_ptr = nullptr;
        st = cudaGetSymbolAddress(&results_counter_ptr, d_resultsCount);
        if (st != cudaSuccess || results_counter_ptr == nullptr) {
            fprintf(stderr, "[!] Result counter symbol bind failed on GPU %d: %s [!]\n", dev, cudaGetErrorString(st));
            GpuRuntimeContext tmp = capture_current_gpu_context();
            release_gpu_context(tmp);
            continue;
        }
        p_results_count = reinterpret_cast<unsigned long long*>(results_counter_ptr);

        g_gpu_contexts.emplace_back(capture_current_gpu_context());
    }

    if (g_gpu_contexts.empty()) {
        return false;
    }
    g_save_output_with_gpu_prefix = (g_gpu_contexts.size() > 1);
    activate_gpu_context(g_gpu_contexts.front());
    return true;
}

// SpeedThreadFunc: periodically reports recovery throughput.
void SpeedThreadFunc()
{
    using clock_type = std::chrono::steady_clock;
    uint64_t last_seen = counterTotal.load();
    auto last_tick = clock_type::now();

    while (!STOP_THREAD) {
        std::this_thread::sleep_for(std::chrono::milliseconds(1000));

        const auto now = clock_type::now();
        const uint64_t current = counterTotal.load();
        const std::chrono::duration<double> dt = now - last_tick;
        const double elapsed = dt.count();
        if (elapsed <= 0.0) {
            continue;
        }

        const double speed = static_cast<double>(current - last_seen) / elapsed;
        printSpeed(speed);

        last_seen = current;
        last_tick = now;
    }
}

// printSpeed: prints the current recovery throughput.
void printSpeed(double speed, int, uint32_t, int, double)
{
    const unsigned long long tested = static_cast<unsigned long long>(counterTotal.load());
    const unsigned long long valid = static_cast<unsigned long long>(g_recovery_emitted_total.load(std::memory_order_relaxed));
    const double hash_speed = speed * static_cast<double>(recovery_hash_checks_per_candidate());
    std::ostringstream line;
    line << "[!] Recovery speed: " << std::fixed << std::setprecision(2)
         << (speed / 1000000.0) << " M candidates/s"
         << " | " << (hash_speed / 1000000.0) << " M hashes/s"
         << " | tested=" << tested
         << " | checksum-valid=" << valid
         << " | found=" << Founds.load(std::memory_order_relaxed);
    recovery_console_write_status_line(line.str());
}
cudaError_t CudaHashLookup::loadBloomFromFiles(const std::vector<string>& targets)
{
    if (targets.size() > 100) {
        std::cerr << "Too many bloom filters: " << targets.size() << " (max 100)" << std::endl;
        return cudaErrorInvalidValue;
    }
    _bloomCount = 0;
    for (size_t i = 0; i < targets.size(); ++i) {
        fprintf(stderr, "[!] Initializing BF [size=%lu] [file=%s]\n",
            (unsigned long)BLOOM_SIZE, targets[i].c_str());

        try {
            _bloomHostData[i] = new uint8_t[BLOOM_SIZE];
        }
        catch (std::bad_alloc&) {
            return cudaErrorMemoryAllocation;
        }
        _bloomHostSize[i] = BLOOM_SIZE;

        memset(_bloomHostData[i], 0, BLOOM_SIZE);
        FILE* file = fopen(targets[i].c_str(), "rb");
        if (file == nullptr) {
            delete[] _bloomHostData[i];
            _bloomHostData[i] = nullptr;
            _bloomHostSize[i] = 0;
            std::cerr << "Failed to open bloom file: " << targets[i] << std::endl;
            return cudaErrorInvalidValue;
        }
        size_t bytesRead = fread(_bloomHostData[i], 1, BLOOM_SIZE, file);
        fclose(file);
        if (bytesRead != BLOOM_SIZE) {
            std::cerr << "Warning: bloom file '" << targets[i]
                << "' read " << bytesRead << " of " << BLOOM_SIZE << " bytes" << std::endl;
        }
        _bloomCount++;
    }
    return cudaSuccess;
}

// Uploads CPU-cached bloom data to the currently active GPU.
cudaError_t CudaHashLookup::uploadBloomToGPU()
{
    for (int i = 0; i < _bloomCount; ++i) {
        uint8_t* devPtr = nullptr;
        cudaError_t err = cudaMalloc(&devPtr, _bloomHostSize[i]);
        if (err) return err;

        err = cudaMemcpy(devPtr, _bloomHostData[i], _bloomHostSize[i], cudaMemcpyHostToDevice);
        if (err) { cudaFree(devPtr); return err; }

        err = cudaMemcpyToSymbol_BLOOM_FILTER(devPtr, i);
        if (err) { cudaFree(devPtr); return err; }
        // devPtr is now referenced by this GPU's _BLOOM_FILTER constant; freed at GPU context teardown
    }
    return cudaSuccess;
}

// Cache structures for XOR filter data (CPU-side, loaded once and reused per GPU).
struct XorFilterCache32 {
    std::vector<uint32_t> fp;
    size_t size, arrayLength, segmentCount, segmentCountLength, segmentLength, segmentLengthMask;
};
struct XorFilterCache16 {
    std::vector<uint16_t> fp;
    size_t size, arrayLength, segmentCount, segmentCountLength, segmentLength, segmentLengthMask;
};
struct XorFilterCache8 {
    std::vector<uint8_t> fp;
    size_t size, arrayLength, segmentCount, segmentCountLength, segmentLength, segmentLengthMask;
};

// setTargetXorFilter: loads compressed XOR filter files once, uploads to each GPU.
cudaError_t setTargetXorFilter(std::vector<std::string>& targets) {
    static std::mutex s_mutex;
    static std::vector<XorFilterCache32> s_cache;
    static bool s_loaded = false;

    {
        std::lock_guard<std::mutex> lock(s_mutex);
        if (!s_loaded) {
            s_cache.clear();
            for (size_t i = 0; i < targets.size(); ++i) {
                xorbinaryfusefilter_lowmem4wise::XorBinaryFuseFilter<uint64_t, uint32_t> hostFilter;
                if (!hostFilter.LoadFromFile(targets[i])) {
                    std::cerr << "Failed to load XOR filter from file: " << targets[i] << std::endl;
                    s_cache.clear();
                    return cudaErrorUnknown;
                }
                fprintf(stderr, "[!] Initializing Compressed XOR Filter [size=%zu] [file=%s]\n", hostFilter.SizeInBytes(), targets[i].c_str());
                XorFilterCache32 entry;
                entry.fp.assign(hostFilter.fingerprints, hostFilter.fingerprints + hostFilter.arrayLength);
                entry.size = hostFilter.size;
                entry.arrayLength = hostFilter.arrayLength;
                entry.segmentCount = hostFilter.segmentCount;
                entry.segmentCountLength = hostFilter.segmentCountLength;
                entry.segmentLength = hostFilter.segmentLength;
                entry.segmentLengthMask = hostFilter.segmentLengthMask;
                s_cache.push_back(std::move(entry));
            }
            s_loaded = true;
        }
    }

    cudaError_t err;
    for (size_t i = 0; i < s_cache.size(); ++i) {
        uint32_t* devPtr = nullptr;
        err = cudaMalloc(&devPtr, sizeof(uint32_t) * s_cache[i].arrayLength);
        if (err) return err;
        err = cudaMemcpy(devPtr, s_cache[i].fp.data(), sizeof(uint32_t) * s_cache[i].arrayLength, cudaMemcpyHostToDevice);
        if (err) { cudaFree(devPtr); return err; }
        err = cudaMemcpyToSymbol_XOR(devPtr, static_cast<int>(i), s_cache[i].size, s_cache[i].arrayLength, s_cache[i].segmentCount, s_cache[i].segmentCountLength, s_cache[i].segmentLength, s_cache[i].segmentLengthMask);
        if (err) { cudaFree(devPtr); return err; }
    }
    return cudaSuccess;
}

// setTargetXorUnFilter: loads uncompressed XOR filter files once, uploads to each GPU.
cudaError_t setTargetXorUnFilter(std::vector<std::string>& targets) {
    static std::mutex s_mutex;
    static std::vector<XorFilterCache32> s_cache;
    static bool s_loaded = false;

    {
        std::lock_guard<std::mutex> lock(s_mutex);
        if (!s_loaded) {
            s_cache.clear();
            for (size_t i = 0; i < targets.size(); ++i) {
                xorbinaryfusefilter_lowmem4wise::XorBinaryFuseFilter<uint64_t, uint32_t> hostFilter;
                if (!hostFilter.LoadFromFile(targets[i])) {
                    std::cerr << "Failed to load XOR filter from file: " << targets[i] << std::endl;
                    s_cache.clear();
                    return cudaErrorUnknown;
                }
                fprintf(stderr, "[!] Initializing Uncompressed XOR Filter [size=%zu] [file=%s]\n", hostFilter.SizeInBytes(), targets[i].c_str());
                XorFilterCache32 entry;
                entry.fp.assign(hostFilter.fingerprints, hostFilter.fingerprints + hostFilter.arrayLength);
                entry.size = hostFilter.size;
                entry.arrayLength = hostFilter.arrayLength;
                entry.segmentCount = hostFilter.segmentCount;
                entry.segmentCountLength = hostFilter.segmentCountLength;
                entry.segmentLength = hostFilter.segmentLength;
                entry.segmentLengthMask = hostFilter.segmentLengthMask;
                s_cache.push_back(std::move(entry));
            }
            s_loaded = true;
        }
    }

    cudaError_t err;
    for (size_t i = 0; i < s_cache.size(); ++i) {
        uint32_t* devPtr = nullptr;
        err = cudaMalloc(&devPtr, sizeof(uint32_t) * s_cache[i].arrayLength);
        if (err) return err;
        err = cudaMemcpy(devPtr, s_cache[i].fp.data(), sizeof(uint32_t) * s_cache[i].arrayLength, cudaMemcpyHostToDevice);
        if (err) { cudaFree(devPtr); return err; }
        err = cudaMemcpyToSymbol_XORUn(devPtr, static_cast<int>(i), s_cache[i].size, s_cache[i].arrayLength, s_cache[i].segmentCount, s_cache[i].segmentCountLength, s_cache[i].segmentLength, s_cache[i].segmentLengthMask);
        if (err) { cudaFree(devPtr); return err; }
    }
    return cudaSuccess;
}

// setTargetXorUcFilter: loads ultra-compressed XOR filter files once, uploads to each GPU.
cudaError_t setTargetXorUcFilter(std::vector<std::string>& targets) {
    static std::mutex s_mutex;
    static std::vector<XorFilterCache16> s_cache;
    static bool s_loaded = false;

    {
        std::lock_guard<std::mutex> lock(s_mutex);
        if (!s_loaded) {
            s_cache.clear();
            for (size_t i = 0; i < targets.size(); ++i) {
                xorbinaryfusefilter_lowmem4wise::XorBinaryFuseFilter<uint64_t, uint16_t> hostFilter;
                if (!hostFilter.LoadFromFile(targets[i])) {
                    std::cerr << "Failed to load XOR filter from file: " << targets[i] << std::endl;
                    s_cache.clear();
                    return cudaErrorUnknown;
                }
                fprintf(stderr, "[!] Initializing Ultra compressed XOR Filter [size=%zu] [file=%s]\n", hostFilter.SizeInBytes(), targets[i].c_str());
                XorFilterCache16 entry;
                entry.fp.assign(hostFilter.fingerprints, hostFilter.fingerprints + hostFilter.arrayLength);
                entry.size = hostFilter.size;
                entry.arrayLength = hostFilter.arrayLength;
                entry.segmentCount = hostFilter.segmentCount;
                entry.segmentCountLength = hostFilter.segmentCountLength;
                entry.segmentLength = hostFilter.segmentLength;
                entry.segmentLengthMask = hostFilter.segmentLengthMask;
                s_cache.push_back(std::move(entry));
            }
            s_loaded = true;
        }
    }

    cudaError_t err;
    for (size_t i = 0; i < s_cache.size(); ++i) {
        uint16_t* devPtr = nullptr;
        err = cudaMalloc(&devPtr, sizeof(uint16_t) * s_cache[i].arrayLength);
        if (err) return err;
        err = cudaMemcpy(devPtr, s_cache[i].fp.data(), sizeof(uint16_t) * s_cache[i].arrayLength, cudaMemcpyHostToDevice);
        if (err) { cudaFree(devPtr); return err; }
        err = cudaMemcpyToSymbol_XORUc(devPtr, static_cast<int>(i), s_cache[i].size, s_cache[i].arrayLength, s_cache[i].segmentCount, s_cache[i].segmentCountLength, s_cache[i].segmentLength, s_cache[i].segmentLengthMask);
        if (err) { cudaFree(devPtr); return err; }
    }
    return cudaSuccess;
}

// setTargetXorHcFilter: loads hyper-compressed XOR filter files once, uploads to each GPU.
cudaError_t setTargetXorHcFilter(std::vector<std::string>& targets) {
    static std::mutex s_mutex;
    static std::vector<XorFilterCache8> s_cache;
    static bool s_loaded = false;

    {
        std::lock_guard<std::mutex> lock(s_mutex);
        if (!s_loaded) {
            s_cache.clear();
            for (size_t i = 0; i < targets.size(); ++i) {
                xorbinaryfusefilter_lowmem4wise::XorBinaryFuseFilter<uint64_t, uint8_t> hostFilter;
                if (!hostFilter.LoadFromFile(targets[i])) {
                    std::cerr << "Failed to load XOR filter from file: " << targets[i] << std::endl;
                    s_cache.clear();
                    return cudaErrorUnknown;
                }
                fprintf(stderr, "[!] Initializing Hyper compressed XOR Filter [size=%zu] [file=%s]\n", hostFilter.SizeInBytes(), targets[i].c_str());
                XorFilterCache8 entry;
                entry.fp.assign(hostFilter.fingerprints, hostFilter.fingerprints + hostFilter.arrayLength);
                entry.size = hostFilter.size;
                entry.arrayLength = hostFilter.arrayLength;
                entry.segmentCount = hostFilter.segmentCount;
                entry.segmentCountLength = hostFilter.segmentCountLength;
                entry.segmentLength = hostFilter.segmentLength;
                entry.segmentLengthMask = hostFilter.segmentLengthMask;
                s_cache.push_back(std::move(entry));
            }
            s_loaded = true;
        }
    }

    cudaError_t err;
    for (size_t i = 0; i < s_cache.size(); ++i) {
        uint8_t* devPtr = nullptr;
        err = cudaMalloc(&devPtr, sizeof(uint8_t) * s_cache[i].arrayLength);
        if (err) return err;
        err = cudaMemcpy(devPtr, s_cache[i].fp.data(), sizeof(uint8_t) * s_cache[i].arrayLength, cudaMemcpyHostToDevice);
        if (err) { cudaFree(devPtr); return err; }
        err = cudaMemcpyToSymbol_XORHc(devPtr, static_cast<int>(i), s_cache[i].size, s_cache[i].arrayLength, s_cache[i].segmentCount, s_cache[i].segmentCountLength, s_cache[i].segmentLength, s_cache[i].segmentLengthMask);
        if (err) { cudaFree(devPtr); return err; }
    }
    return cudaSuccess;
}

// CudaHashLookup::setTargets: loads bloom data once from files, then uploads to current GPU.
cudaError_t CudaHashLookup::setTargets(const vector<string>& targets)
{
    std::lock_guard<std::mutex> lock(_mutex);
    if (!_bloomFilesLoaded) {
        cudaError_t err = loadBloomFromFiles(targets);
        if (err != cudaSuccess) return err;
        _bloomFilesLoaded = true;
    }
    return uploadBloomToGPU();
}

// CudaHashLookup::cleanup: releases CPU-side bloom filter buffers.
void CudaHashLookup::cleanup()
{
    for (int i = 0; i < 100; ++i) {
        delete[] _bloomHostData[i];
        _bloomHostData[i] = nullptr;
        _bloomHostSize[i] = 0;
    }
    _bloomCount = 0;
    _bloomFilesLoaded = false;
}
