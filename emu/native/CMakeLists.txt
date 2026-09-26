# libemucore: the melonDS core (DS) and SkyEmu's cores (GB / GBC / GBA)
# behind emucore.h, for fold3ds/emu.lua (LuaJIT FFI).
#
#   MELONDS_DIR  melonDS-android-lib's source (build.sh fetches it)
#   SKYEMU_DIR   SkyEmu's source
#
# Android (arm64): built by the :emucore Gradle module (emu/android).  The
# desktop build is for testing on a PC with LOVE.
cmake_minimum_required(VERSION 3.16)
project(emucore C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_C_STANDARD 11)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
if (NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release)
endif()

set(MELONDS_DIR "" CACHE PATH "melonDS-android-lib source")
set(SKYEMU_DIR "" CACHE PATH "SkyEmu source")
if (NOT EXISTS "${MELONDS_DIR}/src/NDS.h")
    message(FATAL_ERROR "MELONDS_DIR must point at melonDS-android-lib (got '${MELONDS_DIR}')")
endif()
if (NOT EXISTS "${SKYEMU_DIR}/src/libretro.c")
    message(FATAL_ERROR "SKYEMU_DIR must point at SkyEmu (got '${SKYEMU_DIR}')")
endif()

# the melonDS core only: no Qt frontend, no OpenGL renderer (the software
# renderer draws into memory the HOME menu shows), no debugger
set(BUILD_QT_SDL OFF CACHE BOOL "" FORCE)
set(ENABLE_OGLRENDERER OFF CACHE BOOL "" FORCE)
set(ENABLE_GDBSTUB OFF CACHE BOOL "" FORCE)
set(ENABLE_LTO_RELEASE OFF CACHE BOOL "" FORCE)
set(ENABLE_JIT ON CACHE BOOL "" FORCE)
add_subdirectory("${MELONDS_DIR}" melonds EXCLUDE_FROM_ALL)

# SkyEmu's libretro core, as a static part of this library
add_library(skyemu STATIC
    "${SKYEMU_DIR}/src/libretro.c"
    "${SKYEMU_DIR}/src/shared.c"
    "${SKYEMU_DIR}/src/localization.c")
target_include_directories(skyemu PUBLIC "${SKYEMU_DIR}/src")
target_compile_definitions(skyemu PRIVATE GIT_COMMIT_HASH="${SKYEMU_COMMIT}")
if (CMAKE_C_COMPILER_ID MATCHES "Clang|GNU")
    target_compile_options(skyemu PRIVATE -O3 -w)
endif()

add_library(emucore SHARED emucore.cpp ds_host.cpp vc_host.c core_host.c)
target_include_directories(emucore PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}" "${MELONDS_DIR}/src")
target_link_libraries(emucore PRIVATE core skyemu m ${CMAKE_DL_LIBS})
# only emucore.h's functions are exported; the cores and the C++ runtime
# stay inside
set_target_properties(emucore PROPERTIES C_VISIBILITY_PRESET hidden CXX_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN ON)
if (NOT APPLE)
    target_link_options(emucore PRIVATE "-Wl,--exclude-libs,ALL")
endif()
if (ANDROID)
    target_link_libraries(emucore PRIVATE log)
    # the 16 KB page size newer Android devices need
    target_link_options(emucore PRIVATE "-Wl,-z,max-page-size=16384")
endif()
