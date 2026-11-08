# libtdnapi.so —— ArkTS ↔ TDLib（tdjson）NAPI 桥
#
# 同一份 CMake 工程两个入口驱动：
#   1. hvigor 整包构建：entry/build-profile.json5 → buildOption.externalNativeOptions.path
#   2. 本机实编验证：scripts/build-napi-bridge.sh（NDK toolchain 直编，产物 /tmp 不入库）
#
# 桥职责刻意最小化：tdjson 新式四函数 API 的薄封装 + threadsafe function 接收线程，
# 纯 JSON 字符串透传，不做任何协议解析（解析在 ArkTS 侧 JSON.parse）。
cmake_minimum_required(VERSION 3.16.0)
project(tdnapi)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# __FILE__ 路径重映射：NAPI_MODULE 注册结构体内嵌 __FILE__，不重映射会把构建机的
# 绝对源码路径编进产物（AGENTS.md 二进制脱敏扫描规则，hvigor/脚本构建同时生效）
add_compile_options("-ffile-prefix-map=${CMAKE_CURRENT_SOURCE_DIR}=td")

# 预编译 TDLib（SONAME=libtdjson.so，新式四函数 API）。
# 仓库根 libs/arm64-v8a/：entry/src/main/cpp 上四级即仓库根。
set(TDJSON_LIB "${CMAKE_CURRENT_SOURCE_DIR}/../../../../libs/arm64-v8a/libtdjson.so")
if(NOT EXISTS "${TDJSON_LIB}")
  message(FATAL_ERROR "libtdjson.so 不存在: ${TDJSON_LIB} (先跑 scripts/build_tdlib.sh 产出)")
endif()

# 禁用构建树 RPATH：CMake 默认会把 IMPORTED 库目录（构建机绝对路径）写进 DT_RUNPATH，
# 既泄漏本机路径、对 HAP 内加载也毫无意义（.so 统一打包进应用 libs 目录，系统加载器按名解析）
set(CMAKE_SKIP_BUILD_RPATH TRUE)

add_library(tdjson SHARED IMPORTED)
set_target_properties(tdjson PROPERTIES IMPORTED_LOCATION "${TDJSON_LIB}")

add_library(tdnapi SHARED tdnapi_bridge.cpp)
# libace_napi.z.so：NAPI 运行时（NDK sysroot 内），NAPI_MODULE 构造注册依赖；
# libtdjson.so：DT_NEEDED 由链接闭包生成，hvigor 打包时随之进 HAP
target_link_libraries(tdnapi PRIVATE tdjson libace_napi.z.so)
