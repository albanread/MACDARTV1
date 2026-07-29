// MACVM Smalltalk (.mst) loader — Sprint 2 of ST_PLAN.md.
//
// Turns a parsed ST program (st::ProgramNode, from st::Parser) into REGISTERED
// entities in the live Dart VM object model: one Library (importing dart:core),
// one Class per ST class, a Function per method, and a Field per instance
// variable. Method BODIES are NOT compiled here (that is Sprint 3) — each
// Function is only stamped with a dormant `set_kernel_function` marker pointing
// at its st::MethodNode. Nothing must ever CALL a marked function until the
// Sprint 3 compiler hook exists.
//
// This is a VM-internal translation unit: it #includes the engine headers and
// mirrors the structure of runtime/vm/kernel_reader.cc (ReadLibrary / ReadClass
// / ReadProcedure). Unlike the standalone reader (st_ast/st_lexer/st_parser),
// it links against the VM and must be built inside the `dart_cocoa` static lib.

#ifndef MACDART_ST_ST_LOADER_H_
#define MACDART_ST_ST_LOADER_H_

#include <memory>
#include <string>

#include "st_ast.h"

namespace st {

// Registers a parsed ST program into the CURRENT isolate's object model.
//
// Preconditions: the calling thread must already be transitioned into VM
// execution state with an active HANDLESCOPE (the st_natives entry sets this
// up). The loader allocates VM objects, so it must run at a safepoint-safe VM
// state, not native state.
//
// Ownership: the loader RETAINS `program` for the life of the isolate (it is
// leaked into a static list) because the `kernel_function` markers stamped onto
// the Functions are raw pointers into the AST — the tree must outlive them.
//
// Returns true on success and writes a human-readable, one-line-per-class
// summary into *summary (e.g. "Point: 6 methods, 2 fields"). Returns false on
// failure and writes a short reason into *error (no exception is thrown).
class Loader {
 public:
  static bool Load(std::unique_ptr<ProgramNode> program,
                   const std::string& source,
                   std::string* summary,
                   std::string* error);
};

}  // namespace st

#endif  // MACDART_ST_ST_LOADER_H_
