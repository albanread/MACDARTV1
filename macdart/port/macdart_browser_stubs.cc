// MACDART scaffolding — not from upstream.
//
// bin/builtin.cc lists the browser-only libraries (dart:html, dart:js, ...)
// in its builtin_libraries_ table under `#if defined(DART_NO_SNAPSHOT)`, which
// we define. Those libraries are dartium-only and out of scope for a
// command-line arm64 JIT, so we do not extract or generate their sources.
//
// To satisfy the table's references we define each `Builtin::<lib>_source_paths_`
// as an empty (NULL-terminated) array. Requesting one of these libraries at
// runtime then fails cleanly; the command-line VM and the test suites never do.
//
// If browser libraries are ever brought in, delete this file and generate the
// real *_gen.cc via gen_library_src_paths.py instead.

#include "bin/builtin.h"

namespace dart {
namespace bin {

#define MACDART_EMPTY_LIB(name) \
  const char* Builtin::name[] = {NULL, NULL, NULL}

MACDART_EMPTY_LIB(html_source_paths_);
MACDART_EMPTY_LIB(html_common_source_paths_);
MACDART_EMPTY_LIB(js_source_paths_);
MACDART_EMPTY_LIB(js_util_source_paths_);
MACDART_EMPTY_LIB(_blink_source_paths_);
MACDART_EMPTY_LIB(indexed_db_source_paths_);
MACDART_EMPTY_LIB(cached_patches_source_paths_);
MACDART_EMPTY_LIB(web_gl_source_paths_);
MACDART_EMPTY_LIB(metadata_source_paths_);
MACDART_EMPTY_LIB(web_sql_source_paths_);
MACDART_EMPTY_LIB(svg_source_paths_);
MACDART_EMPTY_LIB(web_audio_source_paths_);

#undef MACDART_EMPTY_LIB

}  // namespace bin
}  // namespace dart
