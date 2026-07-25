# MACDART — darwin-arm64 JIT build of the Dart 1.24.3 VM.
#
# Owns the build entirely; no gyp/GN/gclient. Source lists come from the
# upstream .gypi manifests, filtered to arm64+macOS+non-test by
# port/gen_sources.py. Core-library Dart sources are embedded as C arrays by
# port/gen_library_src_paths.py (the "nosnapshot" configuration), so the VM
# compiles the core libs from source at startup — no prebuilt snapshot.
#
# Phase 0 goal: compile the engine (static lib `dart_engine`). The `dart`
# executable / embedder layer is added once the engine is clean.
cmake_minimum_required(VERSION 3.20)
project(macdart CXX C)

# 2017-era Dart targets C++11; clang's modern default (c++17/20) removes
# features this code uses (dynamic exception specs, etc.). Pin to C++14 as a
# safe middle ground and revisit per-error.
set(CMAKE_CXX_STANDARD 14)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_OSX_ARCHITECTURES)
  set(CMAKE_OSX_ARCHITECTURES arm64)
endif()
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Debug)  # -O0 -g: fastest iteration during bring-up
endif()

find_package(Python3 REQUIRED COMPONENTS Interpreter)

set(MACDART_ROOT ${CMAKE_CURRENT_SOURCE_DIR})
set(RT   ${MACDART_ROOT}/runtime)
set(SDKLIB ${MACDART_ROOT}/sdk/lib)
set(PORT ${MACDART_ROOT}/port)
set(DC   ${RT}/third_party/double-conversion/src)
set(COCOA ${MACDART_ROOT}/cocoa)   # MACDART-owned dart:cocoa bridge (tracked)
set(GEN  ${CMAKE_CURRENT_BINARY_DIR}/gen)
file(MAKE_DIRECTORY ${GEN})

# --- Preprocessor configuration -------------------------------------------
# TARGET_ARCH_ARM64 + HOST/TARGET_OS_MACOS: arch is passed explicitly; the OS
# auto-derives from __APPLE__. DART_PRECOMPILER matches the stock bootstrap
# target; DART_SHARED_LIB exports the embedding API.
#
# DART_NO_SNAPSHOT is NOT global: it is a per-target define. It changes the
# engine at COMPILE time (Object::Init / Dart::InitOnce bootstrap from source
# vs. from a snapshot), so we build the engine twice — once with it
# (gen_snapshot, dart_bootstrap) and once without (the snapshot `dart`).
add_compile_definitions(
  TARGET_ARCH_ARM64
  DART_PRECOMPILER
  DART_SHARED_LIB
  DART_IO_SECURE_SOCKET_DISABLED  # defer TLS/BoringSSL; use no-ssl io variants
)
# The VM requires exactly one of DEBUG / NDEBUG. Tie it to the CMake config:
# Debug builds get DEBUG (asserts + heap verification, invaluable for the
# port bring-up); optimized configs get NDEBUG.
add_compile_definitions(
  $<$<CONFIG:Debug>:DEBUG>
  $<$<NOT:$<CONFIG:Debug>>:NDEBUG>
)

include_directories(${RT} ${RT}/include ${DC} ${RT}/third_party ${COCOA})

# Warnings visible but non-fatal. Optimization is build-type driven so a
# separate Release build dir gives a fast dart (NDEBUG compiles out Dart's
# ASSERT/heap-verification; -O2 optimizes). Debug keeps -O0 -g for iteration.
add_compile_options(-Wall -Wno-unused-parameter -Wno-unused-function)
add_compile_options($<IF:$<CONFIG:Debug>,-g,-O2>)
add_compile_options($<$<CONFIG:Debug>:-O0>)
# The VM type-puns pervasively; -fno-strict-aliasing is required for correct
# optimized codegen (upstream passes it too). Without it, -O2 miscompiles the
# flow-graph compiler into a NULL deref.
add_compile_options(-fno-strict-aliasing)

# --- Helper: expand .gypi manifest(s) into a filtered source list ----------
function(dart_sources outvar kind)
  set(args "")
  foreach(g ${ARGN})
    list(APPEND args --gypi ${g})
  endforeach()
  execute_process(
    COMMAND ${Python3_EXECUTABLE} ${PORT}/gen_sources.py --kind ${kind} ${args}
    OUTPUT_VARIABLE _out RESULT_VARIABLE _rc)
  if(NOT _rc EQUAL 0)
    message(FATAL_ERROR "gen_sources.py failed (${_rc}) for: ${ARGN}")
  endif()
  string(STRIP "${_out}" _out)
  string(REPLACE "\n" ";" _out "${_out}")
  set(${outvar} ${_out} PARENT_SCOPE)
endfunction()

# --- Generated: version.cc -------------------------------------------------
add_custom_command(
  OUTPUT ${GEN}/version.cc
  COMMAND ${Python3_EXECUTABLE} ${PORT}/make_version.py
          --input ${RT}/vm/version_in.cc --output ${GEN}/version.cc
          --version-file ${MACDART_ROOT}/tools/VERSION --vm-dir ${RT}/vm
  DEPENDS ${PORT}/make_version.py ${RT}/vm/version_in.cc ${MACDART_ROOT}/tools/VERSION
  VERBATIM)

# --- Generated: core-library source arrays ---------------------------------
# Matrix: filebase | library token (var/uri) | has_patch.
# The token carries the leading underscore for _internal / _vmservice; the
# filebase and sdk/lib subdir do not. profiler is source-only (its patch array
# is defined as NULL directly in bootstrap.cc).
set(BOOTSTRAP_LIBS
  "core|core|1"
  "async|async|1"
  "collection|collection|1"
  "convert|convert|1"
  "developer|developer|1"
  "internal|_internal|1"
  "isolate|isolate|1"
  "math|math|1"
  "profiler|profiler|0"
  "typed_data|typed_data|1"
  "vmservice|_vmservice|1"
  "mirrors|mirrors|1"
)

set(GENERATED_LIB_CC "")
foreach(entry ${BOOTSTRAP_LIBS})
  string(REPLACE "|" ";" parts ${entry})
  list(GET parts 0 fb)      # filebase
  list(GET parts 1 tok)     # library token
  list(GET parts 2 haspatch)

  # dart:<lib> library source (sdk/lib side)
  dart_sources(SRC dart ${SDKLIB}/${fb}/${fb}_sources.gypi)
  add_custom_command(
    OUTPUT ${GEN}/${fb}_gen.cc
    COMMAND ${Python3_EXECUTABLE} ${PORT}/gen_library_src_paths.py
            --output ${GEN}/${fb}_gen.cc --input_cc ${RT}/lib/libgen_in.cc
            --include vm/bootstrap.h
            --var_name dart::Bootstrap::${tok}_source_paths_
            --library_name dart:${tok} ${SRC}
    DEPENDS ${PORT}/gen_library_src_paths.py ${RT}/lib/libgen_in.cc ${SRC}
    VERBATIM)
  list(APPEND GENERATED_LIB_CC ${GEN}/${fb}_gen.cc)

  # dart:<lib>-patch (runtime/lib side), where present
  if(haspatch)
    dart_sources(PSRC dart ${RT}/lib/${fb}_sources.gypi)
    add_custom_command(
      OUTPUT ${GEN}/${fb}_patch_gen.cc
      COMMAND ${Python3_EXECUTABLE} ${PORT}/gen_library_src_paths.py
              --output ${GEN}/${fb}_patch_gen.cc --input_cc ${RT}/lib/libgen_in.cc
              --include vm/bootstrap.h
              --var_name dart::Bootstrap::${tok}_patch_paths_
              --library_name dart:${tok} ${PSRC}
      DEPENDS ${PORT}/gen_library_src_paths.py ${RT}/lib/libgen_in.cc ${PSRC}
      VERBATIM)
    list(APPEND GENERATED_LIB_CC ${GEN}/${fb}_patch_gen.cc)
  endif()
endforeach()

# --- Source sets from manifests --------------------------------------------
# VM engine: vm_sources.gypi + service protocol + the platform abstraction
# layer (OS::, Utils::, ...). platform_sources is compiled exactly once, here.
dart_sources(VM_CC cc
  ${RT}/vm/vm_sources.gypi
  ${RT}/vm/service_sources.gypi
  ${RT}/platform/platform_sources.gypi)
# Allocator variant: no tcmalloc/jemalloc, so malloc_hooks_unsupported.cc is our
# real MallocHooks implementation. Drop the tcmalloc/jemalloc backends and the
# arch-specific stack-walker (used only by those backends).
list(FILTER VM_CC EXCLUDE REGEX "malloc_hooks_(tcmalloc|jemalloc|arm64)\\.cc$")

# Core-library native methods (the .cc in runtime/lib/*_sources.gypi).
file(GLOB LIB_GYPI ${RT}/lib/*_sources.gypi)
dart_sources(LIB_CC cc ${LIB_GYPI})

# Embedding API implementation + generated version string.
set(API_CC
  ${RT}/vm/dart_api_impl.cc
  ${RT}/vm/debugger_api_impl.cc
  ${RT}/vm/mirrors_api_impl.cc
  ${RT}/vm/native_api_impl.cc
  ${GEN}/version.cc)

# Vendored double-conversion.
file(GLOB DC_CC ${DC}/*.cc)

# --- Targets ---------------------------------------------------------------
add_library(double_conversion STATIC ${DC_CC})

# The engine is built twice, differing only in DART_NO_SNAPSHOT (a compile-time
# switch in Object::Init / Dart::InitOnce). bootstrap.cc is the nosnapshot
# bootstrap (compile core libs from source); the snapshot engine uses it too but
# takes the load-from-snapshot path at runtime.
set(ENGINE_CC ${VM_CC} ${LIB_CC} ${GENERATED_LIB_CC} ${API_CC} ${RT}/vm/bootstrap.cc)
function(add_engine name)
  add_library(${name} STATIC ${ENGINE_CC})
  target_link_libraries(${name} PUBLIC double_conversion)
  target_compile_definitions(${name} PRIVATE ${ARGN})
endfunction()
add_engine(dart_engine_nosnap DART_NO_SNAPSHOT)  # gen_snapshot, dart_bootstrap
add_engine(dart_engine_snap)                     # the snapshot `dart`

# ===========================================================================
# Embedder / bin layer  ->  the `dart` executable
# ===========================================================================

# --- Generated: dart:_builtin, dart:io library + patch source arrays -------
# These use the same generator as the core libs, but the bin template
# (builtin_in.cc) and the Builtin:: variable namespace.
function(dart_gen_builtin outfile var libname)
  # ARGN = the .dart source files
  add_custom_command(
    OUTPUT ${GEN}/${outfile}
    COMMAND ${Python3_EXECUTABLE} ${PORT}/gen_library_src_paths.py
            --output ${GEN}/${outfile} --input_cc ${RT}/bin/builtin_in.cc
            --include bin/builtin.h
            --var_name ${var} --library_name ${libname} ${ARGN}
    DEPENDS ${PORT}/gen_library_src_paths.py ${RT}/bin/builtin_in.cc ${ARGN}
    VERBATIM)
endfunction()

dart_sources(BUILTIN_DART dart ${RT}/bin/builtin_sources.gypi)
dart_gen_builtin(builtin_gen.cc dart::bin::Builtin::_builtin_source_paths_ dart:_builtin ${BUILTIN_DART})

dart_sources(IO_DART dart ${SDKLIB}/io/io_sources.gypi)
dart_gen_builtin(io_gen.cc dart::bin::Builtin::io_source_paths_ dart:io ${IO_DART})

# --- dart:cocoa bridge (MACDART) -------------------------------------------
# The dart:cocoa library source (cocoa_source_paths_) + its native resolver,
# packaged as one static lib linked into every executable (the shared bin files
# builtin.cc / builtin_natives.cc now reference these symbols). Objective-C++
# natives are compiled MRC (-fno-objc-arc) — the VM owns the ObjC refcount.
dart_gen_builtin(cocoa_gen.cc dart::bin::Builtin::cocoa_source_paths_ dart:cocoa ${COCOA}/cocoa.dart)
add_library(dart_cocoa STATIC
  ${COCOA}/cocoa_natives.mm    # resolver + natives (incl. the general _send)
  ${COCOA}/cocoa_callbacks.mm  # reverse callbacks (target-action, class pairs)
  ${COCOA}/objc_shim.m         # fixed-shape AAPCS64 dispatch shim
  ${COCOA}/cocoa_abi.cc        # @encode -> ABI-token classifier
  ${COCOA}/workspace_natives.cc # live-workspace eval primitives (Dart_EvaluateExpr)
  ${COCOA}/sqlite_natives.cc   # SQLite image store (libsqlite3)
  ${GEN}/cocoa_gen.cc)         # dart:cocoa library source array
set_source_files_properties(${COCOA}/cocoa_natives.mm ${COCOA}/cocoa_callbacks.mm ${COCOA}/objc_shim.m
  PROPERTIES COMPILE_FLAGS "-fno-objc-arc -fobjc-exceptions")
target_link_libraries(dart_cocoa PUBLIC "-framework Foundation" "-framework AppKit" sqlite3)

dart_sources(IO_PATCH_DART dart ${RT}/bin/io_sources.gypi)
dart_gen_builtin(io_patch_gen.cc dart::bin::Builtin::io_patch_paths_ dart:io ${IO_PATCH_DART})

# --- Generated: vmservice resources (service isolate; symbols must link) ----
dart_sources(VMSERVICE_DART dart ${RT}/bin/vmservice/vmservice_sources.gypi)
add_custom_command(
  OUTPUT ${GEN}/resources_gen.cc
  COMMAND ${Python3_EXECUTABLE} ${PORT}/create_resources.py
          --output ${GEN}/resources_gen.cc --outer_namespace dart
          --inner_namespace bin --table_name service_bin --root_prefix ${RT}/bin/
          ${VMSERVICE_DART}
  DEPENDS ${PORT}/create_resources.py ${VMSERVICE_DART}
  VERBATIM)

# --- libdart_builtin: the C++ file/dir/process/platform layer --------------
dart_sources(BUILTIN_CC cc ${RT}/bin/builtin_impl_sources.gypi)
# Use the real file/directory implementations, not the io-disabled stubs.
list(FILTER BUILTIN_CC EXCLUDE REGEX "(directory|file)_unsupported\\.cc$")
add_library(dart_builtin STATIC ${BUILTIN_CC} ${RT}/bin/log_macos.cc)

# --- libdart_io: dart:io native layer, curated for io-on / ssl-off / macOS --
# The io manifest picks SSL/zlib variants via gyp conditionals our resolver
# can't evaluate, so the file set is explicit. filter.cc is the real (zlib)
# implementation; secure-socket + certificates use the unsupported stubs.
set(IO_CC
  ${RT}/bin/eventhandler.cc            ${RT}/bin/eventhandler_macos.cc
  ${RT}/bin/file_system_watcher.cc     ${RT}/bin/file_system_watcher_macos.cc
  ${RT}/bin/filter.cc
  ${RT}/bin/io_service_no_ssl.cc
  ${RT}/bin/platform.cc                ${RT}/bin/platform_macos.cc
  ${RT}/bin/process.cc                 ${RT}/bin/process_macos.cc
  ${RT}/bin/secure_socket_unsupported.cc
  ${RT}/bin/root_certificates_unsupported.cc
  ${RT}/bin/socket.cc                  ${RT}/bin/socket_base.cc
  ${RT}/bin/socket_base_macos.cc       ${RT}/bin/socket_macos.cc
  ${RT}/bin/stdio.cc                   ${RT}/bin/stdio_macos.cc
  ${RT}/bin/sync_socket.cc             ${RT}/bin/sync_socket_macos.cc
  ${RT}/bin/io_natives.cc)
add_library(dart_io STATIC ${IO_CC})

set(MACOS_FRAMEWORKS
  "-framework CoreFoundation" "-framework CoreServices" "-framework Security")

# --- dart_bootstrap: nosnapshot JIT (compiles core libs from source) --------
# The proven, snapshot-free binary. Also the build tool that gen_snapshot's role
# generalises; kept as a fallback and for bring-up debugging.
add_executable(dart_bootstrap
  ${RT}/bin/builtin.cc ${RT}/bin/builtin_natives.cc ${RT}/bin/error_exit.cc
  ${RT}/bin/main.cc ${RT}/bin/loader.cc ${RT}/bin/snapshot_utils.cc
  ${RT}/bin/snapshot_empty.cc ${RT}/bin/observatory_assets_empty.cc
  ${RT}/bin/vmservice_impl.cc ${PORT}/macdart_browser_stubs.cc
  ${GEN}/builtin_gen.cc ${GEN}/io_gen.cc ${GEN}/io_patch_gen.cc ${GEN}/resources_gen.cc)
target_compile_definitions(dart_bootstrap PRIVATE DART_NO_SNAPSHOT)
target_link_libraries(dart_bootstrap PRIVATE dart_io dart_builtin dart_cocoa dart_engine_nosnap z ${MACOS_FRAMEWORKS})
target_link_options(dart_bootstrap PRIVATE -rdynamic)

# --- gen_snapshot: emits the core VM + isolate snapshots --------------------
# Uses gen_snapshot.cc (not main.cc) and builtin_gen_snapshot.cc (a minimal
# native resolver). builtin_common.cc comes from dart_builtin; don't repeat it.
add_executable(gen_snapshot
  ${RT}/bin/gen_snapshot.cc ${RT}/bin/builtin_gen_snapshot.cc ${RT}/bin/builtin.cc
  ${RT}/bin/loader.cc ${RT}/bin/vmservice_impl.cc ${RT}/bin/address_sanitizer.cc
  ${PORT}/macdart_browser_stubs.cc
  ${GEN}/builtin_gen.cc ${GEN}/io_gen.cc ${GEN}/io_patch_gen.cc ${GEN}/resources_gen.cc)
target_compile_definitions(gen_snapshot PRIVATE DART_NO_SNAPSHOT PLATFORM_DISABLE_SOCKET)
target_link_libraries(gen_snapshot PRIVATE dart_io dart_builtin dart_cocoa dart_engine_nosnap z ${MACOS_FRAMEWORKS})

# --- Snapshot pipeline: gen_snapshot -> .bin -> snapshot_gen.cc -------------
add_custom_command(
  OUTPUT ${GEN}/vm_isolate_snapshot.bin ${GEN}/isolate_snapshot.bin
  COMMAND $<TARGET_FILE:gen_snapshot> --ignore_unrecognized_flags --snapshot_kind=core
          --vm_snapshot_data=${GEN}/vm_isolate_snapshot.bin
          --isolate_snapshot_data=${GEN}/isolate_snapshot.bin
  DEPENDS gen_snapshot
  COMMENT "Generating core snapshot (vm_isolate_snapshot.bin, isolate_snapshot.bin)"
  VERBATIM)
add_custom_command(
  OUTPUT ${GEN}/snapshot_gen.cc
  COMMAND ${Python3_EXECUTABLE} ${PORT}/create_snapshot_file.py
          --vm_input_bin ${GEN}/vm_isolate_snapshot.bin
          --input_bin ${GEN}/isolate_snapshot.bin
          --input_cc ${RT}/bin/snapshot_in.cc --output ${GEN}/snapshot_gen.cc
  DEPENDS ${PORT}/create_snapshot_file.py ${RT}/bin/snapshot_in.cc
          ${GEN}/vm_isolate_snapshot.bin ${GEN}/isolate_snapshot.bin
  VERBATIM)

# --- dart: snapshot-loading JIT (fast startup) ------------------------------
# Loads core libs from the snapshot: builtin_nolib.cc (no source-array table),
# snapshot_gen.cc (the embedded snapshot), no DART_NO_SNAPSHOT.
add_executable(dart
  ${RT}/bin/builtin_nolib.cc ${RT}/bin/builtin_natives.cc ${RT}/bin/error_exit.cc
  ${RT}/bin/main.cc ${RT}/bin/loader.cc ${RT}/bin/snapshot_utils.cc
  ${RT}/bin/observatory_assets_empty.cc ${RT}/bin/vmservice_impl.cc
  ${GEN}/snapshot_gen.cc ${GEN}/resources_gen.cc)
target_link_libraries(dart PRIVATE dart_io dart_builtin dart_cocoa dart_engine_snap z ${MACOS_FRAMEWORKS})
target_link_options(dart PRIVATE -rdynamic)

# --- dartui: the Cocoa GUI host (dart + a thread-0 UI host) ------------------
# Identical to `dart` plus cocoa_host.mm, built with DART_UI_HOST so main.cc runs
# the UI isolate's main() on OS thread 0 (AppKit's only legal thread). The Dart
# workspace UI itself is written in Dart via dart:cocoa. See WORKSPACE_PLAN.md.
add_executable(dartui
  ${RT}/bin/builtin_nolib.cc ${RT}/bin/builtin_natives.cc ${RT}/bin/error_exit.cc
  ${RT}/bin/main.cc ${RT}/bin/loader.cc ${RT}/bin/snapshot_utils.cc
  ${RT}/bin/observatory_assets_empty.cc ${RT}/bin/vmservice_impl.cc
  ${GEN}/snapshot_gen.cc ${GEN}/resources_gen.cc
  ${COCOA}/cocoa_host.mm)
target_compile_definitions(dartui PRIVATE DART_UI_HOST)
set_source_files_properties(${COCOA}/cocoa_host.mm
  PROPERTIES COMPILE_FLAGS "-fno-objc-arc -fobjc-exceptions")
target_link_libraries(dartui PRIVATE dart_io dart_builtin dart_cocoa dart_engine_snap z ${MACOS_FRAMEWORKS})
target_link_options(dartui PRIVATE -rdynamic)

# Report the compile set size at configure time.
list(LENGTH VM_CC _n_vm)
list(LENGTH LIB_CC _n_lib)
list(LENGTH GENERATED_LIB_CC _n_gen)
list(LENGTH BUILTIN_CC _n_bi)
message(STATUS "MACDART: ${_n_vm} VM+platform, ${_n_lib} lib-native, ${_n_gen} generated core-lib, ${_n_bi} builtin-impl sources")
