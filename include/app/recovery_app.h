// Author: Mikhail Khoroshavin aka "XopMC"

#pragma once

namespace cuda_mnemonic_recovery {

inline constexpr const char* kProjectName = "CUDA_Mnemonic_Recovery";
inline constexpr const char* kProjectVersion = "1.1.0";

}  // namespace cuda_mnemonic_recovery

int RunRecoveryApp(int argc, char** argv);
