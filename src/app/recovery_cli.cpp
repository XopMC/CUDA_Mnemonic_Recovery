// Author: Mikhail Khoroshavin aka "XopMC"

#include "app/recovery_cli.h"

#include <cstring>
#include <iostream>

#include "app/recovery_app.h"

bool g_public_help_requested = false;

bool is_public_recovery_flag(const char* arg) {
    return std::strcmp(arg, "-recovery") == 0 ||
        std::strcmp(arg, "-i") == 0 ||
        std::strcmp(arg, "-wordlist") == 0 ||
        std::strcmp(arg, "-nvalid") == 0 ||
        std::strcmp(arg, "-d") == 0 ||
        std::strcmp(arg, "-d_type") == 0 ||
        std::strcmp(arg, "-c") == 0 ||
        std::strcmp(arg, "-hash") == 0 ||
        std::strcmp(arg, "-bf") == 0 ||
        std::strcmp(arg, "-xu") == 0 ||
        std::strcmp(arg, "-xc") == 0 ||
        std::strcmp(arg, "-xuc") == 0 ||
        std::strcmp(arg, "-xh") == 0 ||
        std::strcmp(arg, "-xx") == 0 ||
        std::strcmp(arg, "-xb") == 0 ||
        std::strcmp(arg, "-pbkdf") == 0 ||
        std::strcmp(arg, "-pass") == 0 ||
        std::strcmp(arg, "-device") == 0 ||
        std::strcmp(arg, "-b") == 0 ||
        std::strcmp(arg, "-t") == 0 ||
        std::strcmp(arg, "-fsize") == 0 ||
        std::strcmp(arg, "-o") == 0 ||
        std::strcmp(arg, "-save") == 0 ||
        std::strcmp(arg, "-silent") == 0 ||
        std::strcmp(arg, "-full") == 0 ||
        std::strcmp(arg, "-h") == 0 ||
        std::strcmp(arg, "-help") == 0;
}

bool is_supported_public_target_family(const char value) {
    switch (value) {
    case 'c':
    case 'u':
    case 's':
    case 'r':
    case 'x':
    case 'e':
    case 'S':
    case 't':
    case 'T':
        return true;
    default:
        return false;
    }
}


void printHelp() {
    std::cout
        << cuda_mnemonic_recovery::kProjectName << " " << cuda_mnemonic_recovery::kProjectVersion << "\n"
        << "Recovery-only CUDA tool for restoring missing BIP39 mnemonic words.\n\n"
        << "Usage:\n"
        << "  CUDA_Mnemonic_Recovery -recovery \"word1 word2 * ...\" -d derivations.txt [options]\n"
        << "  CUDA_Mnemonic_Recovery -recovery -i templates.txt -d derivations.txt [options]\n\n"
        << "Recovery sources:\n"
        << "  -recovery \"...\"     Add one recovery template inline. Repeatable.\n"
        << "  -recovery -i FILE    Load recovery templates from file, processed line by line. Repeatable.\n"
        << "  -wordlist FILE       Use 1..65535 words as wildcard candidates.\n"
        << "                       Non-2048 custom lists enable -nvalid automatically;\n"
        << "                       an unambiguous BIP39 subset keeps checksum filtering.\n"
        << "  -nvalid              Include checksum-invalid mnemonic combinations.\n"
        << "  -d FILE              Derivation file. Required.\n\n"
        << "Target selection:\n"
        << "  -c TYPES             Target families. Default: cus\n"
        << "                       c=compressed, u=uncompressed, s=segwit, r=taproot,\n"
        << "                       x=xpoint, e=ethereum, S=solana, t=ton, T=ton-all.\n"
        << "  -d_type 1|2|3|4      Derivation engine policy.\n"
        << "                       1=bip32-secp256k1, 2=slip0010-ed25519,\n"
        << "                       3=check both, 4=ed25519-bip32 (experimental).\n"
        << "                       If omitted, the tool uses the usual derivation style\n"
        << "                       for the selected target family.\n"
        << "                       Experimental mode must be requested explicitly and is\n"
        << "                       never included in mixed mode.\n"
        << "  -hash HEX            Exact hash prefix target.\n"
        << "  -bf FILE             Bloom filter target.\n"
        << "  -xu FILE             XOR filter (.xor_u), suitable for standalone exact runs.\n"
        << "  -xc FILE             Compact XOR prefilter (.xor_c); pair with -xx .xor_u.\n"
        << "  -xuc FILE            Compact XOR prefilter (.xor_uc); pair with -xx .xor_u.\n"
        << "  -xh FILE             Compact XOR prefilter (.xor_hc); pair with -xx .xor_u.\n"
        << "  -xx FILE             CPU verify using an uncompressed XOR filter (.xor_u).\n"
        << "  -xb FILE             CPU verify Bloom filter.\n\n"
        << "Runtime options:\n"
        << "  -pbkdf N             Override PBKDF2 iterations. Default: 2048.\n"
        << "  -pass VALUE|FILE     Single passphrase or passphrase file.\n"
        << "  -device LIST         GPU list, for example: -device 2,3 or -device 0-3\n"
        << "  -b N                 CUDA block count.\n"
        << "  -t N                 CUDA threads per block.\n"
        << "  -fsize N             Found-buffer capacity.\n"
        << "  -o FILE              Output file. Default: result.txt\n"
        << "  -save                Save address-oriented output instead of raw match hashes.\n"
        << "  -silent              Suppress console hit printing.\n\n"
        << "Notes:\n"
        << "  - This release supports only BIP39 recovery mode.\n"
        << "  - Flags outside the public recovery interface are rejected explicitly.\n";
}
