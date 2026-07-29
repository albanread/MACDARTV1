// MACVM Smalltalk (.mst) embedder native — Sprint 2 of ST_PLAN.md.
//
// One native, `ST_load(String src) -> String`, exposed to Dart as `stLoad`
// (declared in macdart/cocoa/cocoa.dart, wired through the dart:cocoa native
// resolver in cocoa_natives.mm). It runs the standalone reader (st::Lexer +
// st::Parser) and then st::Loader inside the CURRENT isolate, registering the
// parsed classes/methods/fields into the live VM object model. It returns a
// human-readable summary of what was registered, or an "ERR: ..." string on any
// lex/parse/finalize failure (it never throws). This is Sprint 2's verification
// surface: it inspects registration metadata only and never invokes an ST
// method (their bodies are not compiled until Sprint 3).

#include <stdio.h>
#include <string.h>

#include <memory>
#include <string>
#include <vector>

#include "include/dart_api.h"

#include "vm/class_finalizer.h"  // ClassFinalizer::FinalizeClass (on-demand)
#include "vm/dart_api_impl.h"  // DARTSCOPE / TransitionNativeToVM / HANDLESCOPE / Api
#include "vm/dart_entry.h"     // DartEntry::InvokeFunction (Sprint 3 invoke)
#include "vm/isolate.h"
#include "vm/object.h"
#include "vm/object_store.h"
#include "vm/symbols.h"
#include "vm/thread.h"

#include "st_lexer.h"
#include "st_loader.h"
#include "st_parser.h"

namespace dart {
namespace bin {

void ST_load(Dart_NativeArguments args) {
  // --- 1) read the source argument (public API; native execution state) -----
  Dart_Handle src_h = Dart_GetNativeArgument(args, 0);
  const char* src_c = NULL;
  Dart_Handle err = Dart_StringToCString(src_h, &src_c);
  if (Dart_IsError(err) || src_c == NULL) {
    Dart_SetReturnValue(args,
                        Dart_NewStringFromCString("ERR: bad source argument"));
    return;
  }
  std::string source(src_c);

  // --- 2) lex + parse (pure C++17 reader, no VM state needed) ---------------
  ::st::Lexer lexer(source);
  std::vector<::st::Token> tokens;
  ::st::LexError lex_err;
  if (!lexer.Tokenize(&tokens, &lex_err)) {
    char buf[600];
    snprintf(buf, sizeof(buf), "ERR: lex %d:%d: %s", lex_err.line, lex_err.col,
             lex_err.message.c_str());
    Dart_SetReturnValue(args, Dart_NewStringFromCString(buf));
    return;
  }
  ::st::Parser parser(std::move(tokens));
  ::st::ParseError perr;
  std::unique_ptr<::st::ProgramNode> program = parser.ParseProgram(&perr);
  if (program == nullptr || !perr.ok) {
    char buf[600];
    snprintf(buf, sizeof(buf), "ERR: parse %d:%d: %s", perr.line, perr.col,
             perr.message.c_str());
    Dart_SetReturnValue(args, Dart_NewStringFromCString(buf));
    return;
  }

  // --- 3) register into the live object model (transition to VM state) ------
  std::string summary;
  std::string load_err;
  bool ok = false;
  {
    Thread* thread = Thread::Current();
    TransitionNativeToVM transition(thread);
    HANDLESCOPE(thread);
    ok = ::st::Loader::Load(std::move(program), source, &summary, &load_err);
  }

  if (!ok) {
    Dart_SetReturnValue(args, Dart_NewStringFromCString(load_err.c_str()));
    return;
  }
  Dart_SetReturnValue(args, Dart_NewStringFromCString(summary.c_str()));
}

// stInvokeStatic(String className, String selector, List args) -> result
//
// Sprint 3 of ST_PLAN.md — THE invocation surface: look up a loaded ST class by
// name, find its CLASS-SIDE (static) method by selector, and call it via
// DartEntry::InvokeFunction. That first call triggers lazy compilation, which
// runs the compiler.cc hook -> st::BuildGraph -> the ARM64 back-end -> the
// method body, returning the computed value (an int for the milestone). No
// instance is allocated (static methods only, so no layout finalization).
void ST_invokeStatic(Dart_NativeArguments args) {
  // --- 1) read className + selector + args (public API, native state) --------
  Dart_Handle cls_h = Dart_GetNativeArgument(args, 0);
  Dart_Handle sel_h = Dart_GetNativeArgument(args, 1);
  Dart_Handle list_h = Dart_GetNativeArgument(args, 2);
  const char* cls_c = NULL;
  const char* sel_c = NULL;
  if (Dart_IsError(Dart_StringToCString(cls_h, &cls_c)) ||
      Dart_IsError(Dart_StringToCString(sel_h, &sel_c))) {
    Dart_SetReturnValue(
        args, Dart_NewApiError("stInvokeStatic: bad class/selector argument"));
    return;
  }
  intptr_t n = 0;
  Dart_Handle len_err = Dart_ListLength(list_h, &n);
  if (Dart_IsError(len_err)) {
    Dart_SetReturnValue(args, len_err);
    return;
  }
  std::vector<Dart_Handle> elems(n);
  for (intptr_t i = 0; i < n; i++) {
    elems[i] = Dart_ListGetAt(list_h, i);
    if (Dart_IsError(elems[i])) {
      Dart_SetReturnValue(args, elems[i]);
      return;
    }
  }
  const std::string cls_name(cls_c);
  const std::string selector(sel_c);

  // --- 2) look up + invoke (transition to VM state) -------------------------
  Thread* thread = Thread::Current();
  Dart_Handle result_handle = Dart_Null();
  std::string err;
  {
    TransitionNativeToVM transition(thread);
    HANDLESCOPE(thread);
    Zone* zone = thread->zone();
    Isolate* isolate = thread->isolate();

    // Find the class in a loaded `st:mst/N` library (newest first). The ST
    // loader creates one library per stLoad and registers classes into it.
    const GrowableObjectArray& libs = GrowableObjectArray::Handle(
        zone, isolate->object_store()->libraries());
    const String& cname =
        String::Handle(zone, Symbols::New(thread, cls_name.c_str()));
    Class& cls = Class::Handle(zone);
    Library& lib = Library::Handle(zone);
    String& url = String::Handle(zone);
    for (intptr_t i = libs.Length() - 1; i >= 0 && cls.IsNull(); i--) {
      lib ^= libs.At(i);
      url = lib.url();
      if (url.IsNull()) continue;
      if (strncmp(url.ToCString(), "st:mst/", 7) != 0) continue;
      cls = lib.LookupLocalClass(cname);
    }
    if (cls.IsNull()) {
      err = "stInvokeStatic: no loaded ST class '" + cls_name + "'";
    } else {
      // Member-finalize the target class on demand. Registration is lazy
      // (st_loader.cc), so finalize it here — via ClassFinalizer::FinalizeClass,
      // NOT EnsureIsFinalized, which routes to Parser::ParseClass and crashes on
      // an ST class (no TokenStream). Once finalized, lazy compile never
      // re-parses it. Only the invoked class (+ its super chain) is finalized,
      // so a method-less base elsewhere in the corpus is never touched.
      if (!cls.is_finalized()) {
        ClassFinalizer::FinalizeClass(cls);
      }
      const String& sel =
          String::Handle(zone, Symbols::New(thread, selector.c_str()));
      const Function& fn =
          Function::Handle(zone, cls.LookupStaticFunction(sel));
      if (fn.IsNull()) {
        err = "stInvokeStatic: class '" + cls_name +
              "' has no static method '" + selector + "'";
      } else {
        const Array& arr = Array::Handle(zone, Array::New(n, Heap::kOld));
        for (intptr_t i = 0; i < n; i++) {
          arr.SetAt(i, Object::Handle(zone, Api::UnwrapHandle(elems[i])));
        }
        // Triggers lazy compile -> compiler.cc hook -> st::BuildGraph -> run.
        // An Error result (compile failure / unhandled exception) is returned
        // as-is so it propagates to Dart.
        const Object& result =
            Object::Handle(zone, DartEntry::InvokeFunction(fn, arr));
        result_handle = Api::NewHandle(thread, result.raw());
      }
    }
  }

  if (!err.empty()) {
    Dart_SetReturnValue(args, Dart_NewApiError(err.c_str()));
    return;
  }
  Dart_SetReturnValue(args, result_handle);
}

}  // namespace bin
}  // namespace dart
