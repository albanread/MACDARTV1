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

namespace dart {
class RawClass;
class RawInstance;
class Thread;
}  // namespace dart

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
  // url_override names the library (default: a fresh "st:mst/N"); the prelude
  // loads as "st:prelude".
  // has_toplevel (optional) is set true when bare top-level statements were
  // collected into a synthesized `STMain class >> main` (Sprint 11b); the
  // caller decides whether to invoke it (ST_load does, right after loading).
  static bool Load(std::unique_ptr<ProgramNode> program,
                   const std::string& source,
                   std::string* summary,
                   std::string* error,
                   const char* url_override = 0,
                   bool* has_toplevel = 0,
                   bool allow_reopen = true);
};

// Find a loaded ST class by name across EVERY st: library (newest first) —
// the shared resolver for cross-load references: a user file's
// `Error subclass: MyErr` finds the prelude's Error; the IL builder's
// class-name sends and class-as-value references use it too. Returns
// Class::null() if absent. Caller holds a VM transition + HANDLESCOPE.
dart::RawClass* FindStClassByName(dart::Thread* thread, const char* name);

// Sprint 12b: the --with-st boot. Resolve the vendored world directory
// (explicit path > $MACDART_ST_WORLD > relative to the executable), install
// the ST dispatch hooks, and stRun every *.mst in name order. Returns NULL on
// success (msg_buf gets a one-line summary) or an error string. Called from
// runtime/bin/main.cc after the main isolate's script has loaded.
const char* BootWorldForMain(const char* explicit_dir,
                             const char* exe_path,
                             char* msg_buf,
                             int msg_cap);

// The canonical VM-internal name of an ST selector: ':' -> '_' ("at:put:" ->
// "at_put_"). Keeps keyword selectors distinct from unary ones (signal vs
// signal:) while producing valid Dart method names; every registration and
// every lookup site (builder + natives) must agree on this one mangle.
std::string MangleSelector(const std::string& selector);

// Flush the (isolate, cid) -> Function dispatch cache in st_natives.cc
// (ST_eq). Called by every st load and every hot reload — both can replace a
// class's methods, and the cache holds raw old-space Function pointers.
void ClearSendCache();

// The canonical interned StSymbol for `name` in the current isolate (old-space,
// persistent-rooted). The flow-graph builder calls this to resolve a `#foo`
// literal AT COMPILE TIME and bake it as a Constant; the runtime stSymbol
// routes here too, so both yield the SAME object. Caller holds a VM transition
// + HANDLESCOPE. Returns Instance::null() only if StSymbol isn't loaded yet.
dart::RawInstance* InternStSymbol(dart::Thread* thread, const char* name);

}  // namespace st

#endif  // MACDART_ST_ST_LOADER_H_
