cmake_minimum_required(VERSION 3.22)

project(CUDA_Mnemonic_Recovery VERSION 1.1.0 LANGUAGES C CXX CUDA)

if(CMAKE_SOURCE_DIR STREQUAL CMAKE_BINARY_DIR)
    message(FATAL_ERROR
        "In-source builds are not supported. Use an out-of-source build directory, "
        "for example via 'cmake --preset windows-release' or 'cmake --preset linux-release'."
    )
endif()

if(NOT DEFINED CMAKE_CUDA_ARCHITECTURES)
    set(CMAKE_CUDA_ARCHITECTURES 75 86 89 120)
endif()

option(CUDA_MNEMONIC_RECOVERY_ENABLE_DLTO "Enable CUDA device link-time optimization (-dlto)." OFF)
option(CUDA_MNEMONIC_RECOVERY_STATIC_LINUX_RUNTIME "Link libstdc++/libgcc statically on Linux." ON)

set(CMAKE_C_STANDARD 17)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CUDA_STANDARD 17)
set(CMAKE_CUDA_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

find_package(Threads REQUIRED)

set(CUDA_MNEMONIC_RECOVERY_SOURCES
    src/app/main.cpp
    src/app/recovery_cli.cpp
    src/app/recovery_config.cpp
    src/recovery/recovery_compat_device.cu
    src/recovery/recovery_filter_verify.cu
    src/recovery/recovery_pipeline.cu
    src/recovery/recovery_results.cu
    src/crypto/TonFunc.cu
    src/crypto/FilterFunc.cu
    src/crypto/HashFunc.cu
    src/crypto/MnemonicFunc.cu
    src/crypto/filter.cpp
    src/cuda/Kernel.cu
    src/cuda/WorkerRecoveryCompat.cu
    src/cuda/WorkerRecovery.cu
    third_party/fastpbkdf2/pbkdf2_func.cu
    third_party/hash/GPUHash.cu
    third_party/hash/sha256.cpp
    third_party/secp256k1/secp256k1.cu
    third_party/secp256k1/GPUConstants.cu
    third_party/ed25519/ed25519.cu
    third_party/ed25519/sha512_device.cu
)

add_executable(CUDA_Mnemonic_Recovery ${CUDA_MNEMONIC_RECOVERY_SOURCES})

set_source_files_properties(src/recovery/recovery_results.cu PROPERTIES LANGUAGE CXX)
set_source_files_properties(src/recovery/recovery_filter_verify.cu PROPERTIES LANGUAGE CXX)

target_include_directories(CUDA_Mnemonic_Recovery PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    ${CMAKE_CURRENT_SOURCE_DIR}/third_party/fastpbkdf2
    ${CMAKE_CURRENT_SOURCE_DIR}/third_party/hash
    ${CMAKE_CURRENT_SOURCE_DIR}/third_party/secp256k1
    ${CMAKE_CURRENT_SOURCE_DIR}/third_party/ed25519
    ${CMAKE_CUDA_TOOLKIT_INCLUDE_DIRECTORIES}
)

target_compile_definitions(CUDA_Mnemonic_Recovery PRIVATE
    $<$<CXX_COMPILER_ID:MSVC>:_CRT_SECURE_NO_WARNINGS>
    $<$<CXX_COMPILER_ID:MSVC>:NOMINMAX>
    $<$<BOOL:${WIN32}>:_HAS_STD_BYTE=0>
)

target_link_libraries(CUDA_Mnemonic_Recovery PRIVATE Threads::Threads)

if(MSVC)
    set_property(TARGET CUDA_Mnemonic_Recovery PROPERTY
        MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
    target_compile_options(CUDA_Mnemonic_Recovery PRIVATE
        $<$<COMPILE_LANGUAGE:CXX>:/utf-8>
        $<$<COMPILE_LANGUAGE:CUDA>:-Xcompiler=/utf-8>
        $<$<AND:$<COMPILE_LANGUAGE:CUDA>,$<CONFIG:Release>>:-Xcompiler=/MT>
        $<$<AND:$<COMPILE_LANGUAGE:CUDA>,$<CONFIG:Debug>>:-Xcompiler=/MTd>
    )
else()
    target_compile_options(CUDA_Mnemonic_Recovery PRIVATE
        $<$<COMPILE_LANGUAGE:CXX>:-O3>
        $<$<COMPILE_LANGUAGE:C>:-O3>
        $<$<COMPILE_LANGUAGE:CUDA>:--use_fast_math>
    )

    if(CUDA_MNEMONIC_RECOVERY_STATIC_LINUX_RUNTIME)
        target_link_options(CUDA_Mnemonic_Recovery PRIVATE
            -static-libstdc++
            -static-libgcc
        )
    endif()
endif()

set_target_properties(CUDA_Mnemonic_Recovery PROPERTIES
    CUDA_SEPARABLE_COMPILATION ON
    CUDA_RESOLVE_DEVICE_SYMBOLS ON
    CUDA_RUNTIME_LIBRARY Static
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin
)

if(CUDA_MNEMONIC_RECOVERY_ENABLE_DLTO)
    set_property(TARGET CUDA_Mnemonic_Recovery PROPERTY CUDA_ARCHITECTURES OFF)
    target_link_options(CUDA_Mnemonic_Recovery PRIVATE
        $<DEVICE_LINK:-dlto>
    )
    foreach(cuda_arch IN LISTS CMAKE_CUDA_ARCHITECTURES)
        target_compile_options(CUDA_Mnemonic_Recovery PRIVATE
            $<$<COMPILE_LANGUAGE:CUDA>:--generate-code=arch=compute_${cuda_arch},code=lto_${cuda_arch}>
        )
        target_link_options(CUDA_Mnemonic_Recovery PRIVATE
            $<DEVICE_LINK:--generate-code=arch=compute_${cuda_arch}$<COMMA>code=sm_${cuda_arch}>
        )
    endforeach()
endif()
