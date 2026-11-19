cmake_minimum_required(VERSION 3.21)
set(CMAKE_OSX_DEPLOYMENT_TARGET "14.0" CACHE STRING "" FORCE)
project(talk_engine C CXX)

# Built by `zig build` (see build.zig). Produces one static archive,
# libtalk_engine_all.a, that bundles the shim with llama.cpp, libmtmd and ggml
# (Metal shaders embedded), so Zig links a single C ABI library.

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OSX_ARCHITECTURES arm64 CACHE STRING "" FORCE)

set(BUILD_SHARED_LIBS        OFF CACHE BOOL "" FORCE)
set(GGML_METAL               ON  CACHE BOOL "" FORCE)
set(GGML_METAL_EMBED_LIBRARY OFF CACHE BOOL "" FORCE) # precompiled default.metallib, shipped beside the binary / in Resources
set(LLAMA_BUILD_COMMON       ON  CACHE BOOL "" FORCE)
set(LLAMA_BUILD_MTMD         ON  CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TOOLS        OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TESTS        OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES     OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER       OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_APP          OFF CACHE BOOL "" FORCE)
set(LLAMA_OPENSSL            OFF CACHE BOOL "" FORCE)
set(LLAMA_SUBPROCESS         OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_IS_DEV       OFF CACHE BOOL "" FORCE)

add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../vendor/llama.cpp llama.cpp EXCLUDE_FROM_ALL)

set(MD4C_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../vendor/md4c/src)

# talk_engine.cpp: TTS shim (C++). talk_audio.c: AudioQueue output (C).
# md4c: markdown parser, plain C, used by the Zig text pipeline.
add_library(talk_engine STATIC
    talk_engine.cpp talk_engine.h
    talk_audio.c talk_audio.h
    ${MD4C_DIR}/md4c.c
)
target_link_libraries(talk_engine PRIVATE mtmd llama-common llama)
target_include_directories(talk_engine PUBLIC ${CMAKE_CURRENT_SOURCE_DIR} ${MD4C_DIR})

# Merge every static library the shim depends on into one archive.
set(TE_ALL ${CMAKE_CURRENT_BINARY_DIR}/libtalk_engine_all.a)
add_custom_command(
    OUTPUT  ${TE_ALL}
    COMMAND /usr/bin/libtool -static -no_warning_for_no_symbols -o ${TE_ALL}
            $<TARGET_FILE:talk_engine>
            $<TARGET_FILE:mtmd>
            $<TARGET_FILE:llama-common>
            $<TARGET_FILE:llama-common-base>
            $<TARGET_FILE:llama>
            $<TARGET_FILE:ggml>
            $<TARGET_FILE:ggml-base>
            $<TARGET_FILE:ggml-cpu>
            $<TARGET_FILE:ggml-metal>
            $<TARGET_FILE:ggml-blas>            $<TARGET_FILE:vendor-hash>
    DEPENDS talk_engine mtmd llama-common llama-common-base llama ggml ggml-base ggml-cpu ggml-metal ggml-blas vendor-hash
    COMMENT "Bundling libtalk_engine_all.a"
)
add_custom_target(talk_engine_all ALL DEPENDS ${TE_ALL})
# precompiled shaders: .build/engine/bin/default.metallib (+ ggml-tensor.metallib when the SDK supports it)
add_dependencies(talk_engine_all ggml-metal-lib)
