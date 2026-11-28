cmake_minimum_required(VERSION 3.22.1)
project(vyse_native)

option(DOVI_ENABLE_LIBDOVI "Link real libdovi" ON)
set(DOVI_LIBDOVI_PREBUILT_ROOT "" CACHE PATH "Path to prebuilt libdovi")
set(MPV_FFMPEG_ROOT "" CACHE PATH "Path to libmpv's FFmpeg headers and shared libraries")

add_library(dovi_bridge SHARED dovi_bridge.cpp)

if(DOVI_ENABLE_LIBDOVI)
    add_library(dovi_static STATIC IMPORTED)
    set_target_properties(dovi_static PROPERTIES
        IMPORTED_LOCATION "${DOVI_LIBDOVI_PREBUILT_ROOT}/${ANDROID_ABI}/lib/libdovi.a")
    target_compile_definitions(dovi_bridge PRIVATE DOVI_REAL_LINKED=1)
    target_include_directories(dovi_bridge PRIVATE ${CMAKE_SOURCE_DIR}/include)
    target_link_libraries(dovi_bridge dovi_static log)
else()
    target_compile_definitions(dovi_bridge PRIVATE DOVI_REAL_LINKED=0)
    target_link_libraries(dovi_bridge log)
endif()

foreach(ffmpeg_library avcodec avutil swresample swscale)
    add_library(${ffmpeg_library} SHARED IMPORTED)
    set_target_properties(${ffmpeg_library} PROPERTIES
        IMPORTED_LOCATION "${MPV_FFMPEG_ROOT}/native/${ANDROID_ABI}/lib${ffmpeg_library}.so")
endforeach()

add_library(ffmpegJNI SHARED
    media3_ffmpeg_decoder/ffmpeg_jni.cc)
target_compile_features(ffmpegJNI PRIVATE cxx_std_17)
target_include_directories(ffmpegJNI PRIVATE
    "${MPV_FFMPEG_ROOT}/include"
    "${CMAKE_CURRENT_SOURCE_DIR}/media3_ffmpeg_decoder")
target_link_libraries(ffmpegJNI
    avcodec
    avutil
    swresample
    android
    log)

# FFmpeg's video decoding for Media3: nextlib's (github.com/anilbeesetti/nextlib, GPL-3.0,
# nextlib_ffvideo/LICENSE), loaded as "media3ext" by its FfmpegLibrary.
add_library(media3ext SHARED
    nextlib_ffvideo/ffmain.cpp
    nextlib_ffvideo/ffcommon.cpp
    nextlib_ffvideo/ffvideo.cpp)
target_compile_features(media3ext PRIVATE cxx_std_17)
target_include_directories(media3ext PRIVATE
    "${MPV_FFMPEG_ROOT}/include"
    "${CMAKE_CURRENT_SOURCE_DIR}/nextlib_ffvideo")
target_link_options(media3ext PRIVATE "-Wl,-z,max-page-size=16384")
target_link_libraries(media3ext
    avcodec
    avutil
    swresample
    swscale
    android
    log)
