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

#include "vm/become.h"           // Become::ElementsForwardIdentity (Sprint 9)
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
#include "st_prelude.h"

namespace dart {
namespace bin {

// Parse+load the ST PRELUDE (st_prelude.h) into this isolate's `st:prelude`
// library, once — keyed on the library's presence, so it is per-isolate
// correct. Caller holds the VM transition + HANDLESCOPE. Returns false (with
// *err set) only on a prelude bug.
static bool EnsurePrelude(Thread* thread, std::string* err) {
  Zone* zone = thread->zone();
  const Library& present = Library::Handle(
      zone, Library::LookupLibrary(
                thread, String::Handle(zone, String::New("st:prelude"))));
  if (!present.IsNull()) return true;

  std::string src(::st::kPreludeSource);
  ::st::Lexer lexer(src);
  std::vector<::st::Token> tokens;
  ::st::LexError lex_err;
  if (!lexer.Tokenize(&tokens, &lex_err)) {
    *err = "ERR: prelude lex: " + lex_err.message;
    return false;
  }
  ::st::Parser parser(std::move(tokens));
  ::st::ParseError perr;
  std::unique_ptr<::st::ProgramNode> program = parser.ParseProgram(&perr);
  if (program == nullptr || !perr.ok) {
    *err = "ERR: prelude parse: " + perr.message;
    return false;
  }
  std::string summary;
  return ::st::Loader::Load(std::move(program), src, &summary, err,
                            "st:prelude");
}

// The load(+run) core shared by the ST_load/ST_run/ST_loadFresh natives and
// the --with-st world boot (st::BootWorldForMain): lex/parse/register, then
// optionally invoke the synthesized STMain>>main. Returns the load summary or
// an "ERR: ..." string. Caller is in NATIVE state (the transitions are here).
static std::string STRunSourceString(const std::string& source,
                                     bool run_toplevel,
                                     bool allow_reopen) {
  ::st::Lexer lexer(source);
  std::vector<::st::Token> tokens;
  ::st::LexError lex_err;
  if (!lexer.Tokenize(&tokens, &lex_err)) {
    char buf[600];
    snprintf(buf, sizeof(buf), "ERR: lex %d:%d: %s", lex_err.line,
             lex_err.col, lex_err.message.c_str());
    return std::string(buf);
  }
  ::st::Parser parser(std::move(tokens));
  ::st::ParseError perr;
  std::unique_ptr<::st::ProgramNode> program = parser.ParseProgram(&perr);
  if (program == nullptr || !perr.ok) {
    char buf[600];
    snprintf(buf, sizeof(buf), "ERR: parse %d:%d: %s", perr.line, perr.col,
             perr.message.c_str());
    return std::string(buf);
  }

  std::string summary;
  std::string load_err;
  bool ok = false;
  bool has_toplevel = false;
  {
    Thread* thread = Thread::Current();
    TransitionNativeToVM transition(thread);
    HANDLESCOPE(thread);
    ok = EnsurePrelude(thread, &load_err);
    if (ok) {
      ok = ::st::Loader::Load(std::move(program), source, &summary, &load_err,
                              /*url_override=*/0, &has_toplevel, allow_reopen);
    }
  }
  if (!ok) return load_err;

  if (run_toplevel && has_toplevel) {
    Thread* thread = Thread::Current();
    std::string run_err;
    {
      TransitionNativeToVM transition(thread);
      HANDLESCOPE(thread);
      Zone* zone = thread->zone();
      Class& cls =
          Class::Handle(zone, ::st::FindStClassByName(thread, "STMain"));
      Class& meta = Class::Handle(
          zone, ::st::FindStClassByName(thread, "STMain class"));
      const String& sel =
          String::Handle(zone, Symbols::New(thread, "main"));
      Function& fn = Function::Handle(zone);
      Class& c = Class::Handle(zone, meta.IsNull() ? cls.raw() : meta.raw());
      while (!c.IsNull()) {
        if (!c.is_finalized()) ClassFinalizer::FinalizeClass(c);
        fn ^= c.LookupStaticFunction(sel);
        if (!fn.IsNull()) break;
        c ^= c.SuperClass();
      }
      if (fn.IsNull() || cls.IsNull()) {
        run_err = "ERR: toplevel: STMain>>main not registered";
      } else {
        if (!cls.is_finalized()) ClassFinalizer::FinalizeClass(cls);
        const Type& type =
            Type::Handle(zone, Type::NewNonParameterizedType(cls));
        const Array& argv = Array::Handle(zone, Array::New(1, Heap::kOld));
        argv.SetAt(0, type);
        const Object& result =
            Object::Handle(zone, DartEntry::InvokeFunction(fn, argv));
        if (result.IsError()) {
          run_err = "ERR: toplevel: ";
          run_err += Error::Cast(result).ToErrorCString();
        }
      }
    }
    if (!run_err.empty()) return run_err;
  }
  return summary;
}

// Shared by ST_load (register only — the workspace image reload must never
// fire do-its) and ST_run (register + execute top-level statements, the
// MACVM file semantics).
static void STLoadCommon(Dart_NativeArguments args, bool run_toplevel,
                         bool allow_reopen = true) {
  Dart_Handle src_h = Dart_GetNativeArgument(args, 0);
  const char* src_c = NULL;
  Dart_Handle err = Dart_StringToCString(src_h, &src_c);
  if (Dart_IsError(err) || src_c == NULL) {
    Dart_SetReturnValue(args,
                        Dart_NewStringFromCString("ERR: bad source argument"));
    return;
  }
  const std::string result =
      STRunSourceString(std::string(src_c), run_toplevel, allow_reopen);
  Dart_SetReturnValue(args, Dart_NewStringFromCString(result.c_str()));
}

void ST_load(Dart_NativeArguments args) { STLoadCommon(args, false); }
void ST_run(Dart_NativeArguments args) { STLoadCommon(args, true); }
// The workspace image reload: a FRESH layer — no cross-load reopen, so a
// re-Accepted class fully shadows its previous version (clean edit
// semantics, no stale inline caches on replaced methods). The combined decl
// text still merges same-name definitions within the one load.
void ST_loadFresh(Dart_NativeArguments args) {
  STLoadCommon(args, false, /*allow_reopen=*/false);
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
    // Sprint 11, metaclass split: class-side methods live on the `Foo class`
    // shadow (cross-load resolve — covers the prelude too). Prefer it; fall
    // back to the flat class for pre-metaclass layouts.
    Class& meta = Class::Handle(
        zone, ::st::FindStClassByName(thread, (cls_name + " class").c_str()));
    if (cls.IsNull() && meta.IsNull()) {
      cls ^= ::st::FindStClassByName(thread, cls_name.c_str());
    }
    if (cls.IsNull() && meta.IsNull()) {
      err = "stInvokeStatic: no loaded ST class '" + cls_name + "'";
    } else {
      // Member-finalize on demand while WALKING THE SUPER CHAIN for the
      // method (inherited class-side methods dispatch) — via
      // ClassFinalizer::FinalizeClass, NOT EnsureIsFinalized, which routes to
      // Parser::ParseClass and crashes on an ST class (no TokenStream). Once
      // finalized, lazy compile never re-parses it. Only visited classes are
      // finalized, so a method-less base elsewhere is never touched.
      const String& sel =
          String::Handle(zone, Symbols::New(thread, ::st::MangleSelector(selector).c_str()));
      Function& fn = Function::Handle(zone);
      Class& c = Class::Handle(zone, meta.IsNull() ? cls.raw() : meta.raw());
      while (!c.IsNull()) {
        if (!c.is_finalized()) ClassFinalizer::FinalizeClass(c);
        fn ^= c.LookupStaticFunction(sel);
        if (!fn.IsNull()) break;
        c ^= c.SuperClass();
      }
      if (fn.IsNull()) {
        err = "stInvokeStatic: class '" + cls_name +
              "' has no static method '" + selector + "'";
      } else {
        // Implicit arg 0 = the receiving class as a Type value (Sprint 11 —
        // class-side `self`). `cls` is the instance class found by name.
        if (!cls.is_finalized()) ClassFinalizer::FinalizeClass(cls);
        const Type& type = Type::Handle(
            zone, Type::NewNonParameterizedType(cls));
        const Array& arr = Array::Handle(zone, Array::New(n + 1, Heap::kOld));
        arr.SetAt(0, type);
        for (intptr_t i = 0; i < n; i++) {
          arr.SetAt(i + 1, Object::Handle(zone, Api::UnwrapHandle(elems[i])));
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

// Find a loaded ST class by name — delegates to the shared cross-load
// resolver (st_loader.cc): every st: library, newest first, INCLUDING the
// prelude (stNew('Error') from the stError helper must see st:prelude).
// Returns Class::null() if absent. Caller holds a VM transition + HANDLESCOPE.
static RawClass* FindStClass(Thread* thread, const std::string& name) {
  return ::st::FindStClassByName(thread, name.c_str());
}

// stNew(String className) -> instance.  Sprint 5: allocate an instance of a
// loaded ST class (member-finalized on demand so its instance size/layout
// exist). The returned Dart object is an instance of the ST class.
void ST_new(Dart_NativeArguments args) {
  Dart_Handle cls_h = Dart_GetNativeArgument(args, 0);
  const char* cls_c = NULL;
  if (Dart_IsError(Dart_StringToCString(cls_h, &cls_c)) || cls_c == NULL) {
    Dart_SetReturnValue(args, Dart_NewApiError("stNew: bad class argument"));
    return;
  }
  const std::string cls_name(cls_c);
  Thread* thread = Thread::Current();
  Dart_Handle result_handle = Dart_Null();
  std::string err;
  {
    TransitionNativeToVM transition(thread);
    HANDLESCOPE(thread);
    Zone* zone = thread->zone();
    Class& cls = Class::Handle(zone, FindStClass(thread, cls_name));
    if (cls.IsNull()) {
      err = "stNew: no loaded ST class '" + cls_name + "'";
    } else {
      if (!cls.is_finalized()) ClassFinalizer::FinalizeClass(cls);
      const Instance& obj =
          Instance::Handle(zone, Instance::New(cls, Heap::kNew));
      result_handle = Api::NewHandle(thread, obj.raw());
    }
  }
  if (!err.empty()) {
    Dart_SetReturnValue(args, Dart_NewApiError(err.c_str()));
    return;
  }
  Dart_SetReturnValue(args, result_handle);
}

// stSend(receiver, String selector, List args) -> result.  Sprint 5: send an
// instance method to an ST object (receiver = argument 0). The first call
// lazily compiles the body via the compiler.cc hook -> st::BuildGraph.
static void STSendCommon(Dart_NativeArguments args, bool probe) {
  Dart_Handle recv_h = Dart_GetNativeArgument(args, 0);
  Dart_Handle sel_h = Dart_GetNativeArgument(args, 1);
  Dart_Handle list_h = Dart_GetNativeArgument(args, 2);
  const char* sel_c = NULL;
  if (Dart_IsError(Dart_StringToCString(sel_h, &sel_c)) || sel_c == NULL) {
    Dart_SetReturnValue(args, Dart_NewApiError("stSend: bad selector argument"));
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
  const std::string selector(sel_c);
  Thread* thread = Thread::Current();
  Dart_Handle result_handle = Dart_Null();
  std::string err;
  bool hit = false;
  {
    TransitionNativeToVM transition(thread);
    HANDLESCOPE(thread);
    Zone* zone = thread->zone();
    const Object& recv = Object::Handle(zone, Api::UnwrapHandle(recv_h));
    const Class& cls = Class::Handle(zone, recv.clazz());
    const String& sel =
        String::Handle(zone, Symbols::New(thread, ::st::MangleSelector(selector).c_str()));
    // Walk the super chain (inherited methods dispatch — Error inherits
    // messageText: from Exception), finalizing each visited class on demand.
    Function& fn = Function::Handle(zone);
    Class& c = Class::Handle(zone, cls.raw());
    while (!c.IsNull()) {
      if (!c.is_finalized()) ClassFinalizer::FinalizeClass(c);
      fn ^= c.LookupDynamicFunction(sel);
      if (!fn.IsNull()) break;
      c ^= c.SuperClass();
    }
    if (fn.IsNull()) {
      if (!probe) {
        err = "stSend: " + std::string(cls.ToCString()) +
              " has no method '" + selector + "'";
      }
    } else {
      const Array& arr = Array::Handle(zone, Array::New(n + 1, Heap::kOld));
      arr.SetAt(0, recv);  // receiver = argument 0
      for (intptr_t i = 0; i < n; i++) {
        arr.SetAt(i + 1, Object::Handle(zone, Api::UnwrapHandle(elems[i])));
      }
      const Object& result =
          Object::Handle(zone, DartEntry::InvokeFunction(fn, arr));
      result_handle = Api::NewHandle(thread, result.raw());
      hit = true;
    }
  }
  if (!err.empty()) {
    Dart_SetReturnValue(args, Dart_NewApiError(err.c_str()));
    return;
  }
  if (probe) {
    if (!hit) {
      Dart_SetReturnValue(args, Dart_Null());
      return;
    }
    if (Dart_IsError(result_handle)) {
      Dart_SetReturnValue(args, result_handle);  // an ST signal propagates
      return;
    }
    Dart_Handle box = Dart_NewList(1);
    Dart_ListSetAt(box, 0, result_handle);
    Dart_SetReturnValue(args, box);
    return;
  }
  Dart_SetReturnValue(args, result_handle);
}

// stSend: dispatch an instance method by selector — the throwing form.
void ST_send(Dart_NativeArguments args) { STSendCommon(args, false); }
// stSendTry: probe form — [result] on a hit, null on a miss, NEVER an
// ApiError for a missing method (an ApiError is not catchable by Dart
// try/catch, which crashed the Release GUI inside stPrintOf's fallback).
void ST_sendTry(Dart_NativeArguments args) { STSendCommon(args, true); }

// stClassNamed(name) -> the class VALUE (canonical Type) or null. Sprint 14:
// `Worker classNamed:` binds here — the engine's own lookup instead of a
// ClassMirror sweep.
void ST_classNamed(Dart_NativeArguments args) {
  Dart_Handle name_h = Dart_GetNativeArgument(args, 0);
  const char* name_c = NULL;
  if (Dart_IsError(Dart_StringToCString(name_h, &name_c)) || name_c == NULL) {
    Dart_SetReturnValue(args, Dart_Null());
    return;
  }
  const std::string name(name_c);
  Thread* thread = Thread::Current();
  Dart_Handle result = Dart_Null();
  {
    TransitionNativeToVM transition(thread);
    HANDLESCOPE(thread);
    Zone* zone = thread->zone();
    const Class& cls =
        Class::Handle(zone, ::st::FindStClassByName(thread, name.c_str()));
    if (!cls.IsNull()) {
      if (!cls.is_finalized()) ClassFinalizer::FinalizeClass(cls);
      const Type& type =
          Type::Handle(zone, Type::NewNonParameterizedType(cls));
      result = Api::NewHandle(thread, type.raw());
    }
  }
  Dart_SetReturnValue(args, result);
}

// stHasMethod(recv, selector) -> bool.  Sprint 13: a lookup-only probe (no
// invoke, no prelude requirement) — does the receiver's class chain define
// the (mangled) selector? The NSM hook uses it to decide whether a missed
// send should be reified as a Smalltalk doesNotUnderstand:.
void ST_hasMethod(Dart_NativeArguments args) {
  Dart_Handle recv_h = Dart_GetNativeArgument(args, 0);
  Dart_Handle sel_h = Dart_GetNativeArgument(args, 1);
  const char* sel_c = NULL;
  if (Dart_IsError(Dart_StringToCString(sel_h, &sel_c)) || sel_c == NULL) {
    Dart_SetReturnValue(args, Dart_NewBoolean(false));
    return;
  }
  const std::string selector(sel_c);
  Thread* thread = Thread::Current();
  bool found = false;
  {
    TransitionNativeToVM transition(thread);
    HANDLESCOPE(thread);
    Zone* zone = thread->zone();
    const Object& recv = Object::Handle(zone, Api::UnwrapHandle(recv_h));
    const String& sel = String::Handle(
        zone, Symbols::New(thread, ::st::MangleSelector(selector).c_str()));
    Function& fn = Function::Handle(zone);
    Class& c = Class::Handle(zone, recv.clazz());
    while (!c.IsNull()) {
      if (!c.is_finalized()) ClassFinalizer::FinalizeClass(c);
      fn ^= c.LookupDynamicFunction(sel);
      if (!fn.IsNull()) { found = true; break; }
      c ^= c.SuperClass();
    }
  }
  Dart_SetReturnValue(args, Dart_NewBoolean(found));
}

// stClassSend(type, selector, args) -> result.  Sprint 11: the class-side
// `self <sel>` dispatch — receiver is a CLASS VALUE (Type), target resolved at
// runtime by walking its metaclass-shadow chain, so an inherited class-side
// constructor sees self = the class the message was sent to. Falls back to
// allocation for new/basicNew and create-and-signal for signal/signal:
// (mirroring TranslateClassSend's compile-time fallbacks).
static void STClassSendCommon(Dart_NativeArguments args, bool probe) {
  Dart_Handle type_h = Dart_GetNativeArgument(args, 0);
  Dart_Handle sel_h = Dart_GetNativeArgument(args, 1);
  Dart_Handle list_h = Dart_GetNativeArgument(args, 2);
  const char* sel_c = NULL;
  if (Dart_IsError(Dart_StringToCString(sel_h, &sel_c)) || sel_c == NULL) {
    Dart_SetReturnValue(args,
                        Dart_NewApiError("stClassSend: bad selector argument"));
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
  const std::string selector(sel_c);
  Thread* thread = Thread::Current();
  Dart_Handle result_handle = Dart_Null();
  bool hit = false;
  std::string err;
  {
    TransitionNativeToVM transition(thread);
    HANDLESCOPE(thread);
    Zone* zone = thread->zone();
    const Object& type_obj = Object::Handle(zone, Api::UnwrapHandle(type_h));
    if (!type_obj.IsType()) {
      if (!probe) err = "stClassSend: receiver is not a class value";
    } else {
      const Type& type = Type::Cast(type_obj);
      const Class& cls = Class::Handle(zone, type.type_class());
      const String& cname = String::Handle(zone, cls.Name());
      const std::string cls_name(cname.ToCString());
      // The selector may arrive RAW (builder stClassSendN sites) or already
      // MANGLED (the NSM hooks pass the missed method name) — normalize once
      // and compare canonical forms below.
      const std::string msel = ::st::MangleSelector(selector);
      // Sprint 11c: allocation on an ARRAY-LIKE extension holder's class
      // value (`aCollection class new: 20` in the world's WriteStream) makes
      // the NATIVE thing — the holder's own <primitive:>-stub new: must
      // never run (its ignored-pragma body would answer the Type itself).
      if (cls_name == "Array ext" || cls_name == "ByteArray ext" ||
          cls_name == "String ext") {
        intptr_t len = -1;
        if ((msel == "new_" || msel == "basicNew_") && n == 1) {
          const Object& arg =
              Object::Handle(zone, Api::UnwrapHandle(elems[0]));
          if (arg.IsSmi()) len = Smi::Cast(arg).Value();
        } else if ((msel == "new" || msel == "basicNew") && n == 0) {
          len = 0;
        }
        if (len >= 0) {
          const Array& made = Array::Handle(zone, Array::New(len));
          result_handle = Api::NewHandle(thread, made.raw());
          hit = true;
        }
      }
      const String& sel =
          String::Handle(zone, Symbols::New(thread, msel.c_str()));
      // The metaclass-shadow chain holds class-side methods.
      Function& fn = Function::Handle(zone);
      Class& c = Class::Handle(zone);
      if (!hit) {
        c = ::st::FindStClassByName(thread, (cls_name + " class").c_str());
      }
      while (!c.IsNull()) {
        if (!c.is_finalized()) ClassFinalizer::FinalizeClass(c);
        fn ^= c.LookupStaticFunction(sel);
        if (!fn.IsNull()) break;
        c ^= c.SuperClass();
      }
      if (!fn.IsNull()) {
        const Array& arr =
            Array::Handle(zone, Array::New(n + 1, Heap::kOld));
        arr.SetAt(0, type);  // thisCls propagates unchanged
        for (intptr_t i = 0; i < n; i++) {
          arr.SetAt(i + 1, Object::Handle(zone, Api::UnwrapHandle(elems[i])));
        }
        const Object& result =
            Object::Handle(zone, DartEntry::InvokeFunction(fn, arr));
        result_handle = Api::NewHandle(thread, result.raw());
        hit = true;
      } else if ((msel == "new" || msel == "basicNew") && n == 0) {
        if (!cls.is_finalized()) ClassFinalizer::FinalizeClass(cls);
        const Instance& inst = Instance::Handle(zone, Instance::New(cls));
        result_handle = Api::NewHandle(thread, inst.raw());
        hit = true;
      } else if ((msel == "signal" && n == 0) ||
                 (msel == "signal_" && n == 1)) {
        if (!cls.is_finalized()) ClassFinalizer::FinalizeClass(cls);
        const Instance& inst = Instance::Handle(zone, Instance::New(cls));
        // Instance-side signal/signal: up the chain (prelude Exception).
        Function& sfn = Function::Handle(zone);
        Class& sc = Class::Handle(zone, cls.raw());
        while (!sc.IsNull()) {
          if (!sc.is_finalized()) ClassFinalizer::FinalizeClass(sc);
          sfn ^= sc.LookupDynamicFunction(sel);
          if (!sfn.IsNull()) break;
          sc ^= sc.SuperClass();
        }
        if (sfn.IsNull()) {
          err = "stClassSend: '" + cls_name + "' cannot signal";
        } else {
          const Array& arr =
              Array::Handle(zone, Array::New(n + 1, Heap::kOld));
          arr.SetAt(0, inst);
          for (intptr_t i = 0; i < n; i++) {
            arr.SetAt(i + 1,
                      Object::Handle(zone, Api::UnwrapHandle(elems[i])));
          }
          const Object& result =
              Object::Handle(zone, DartEntry::InvokeFunction(sfn, arr));
          result_handle = Api::NewHandle(thread, result.raw());
          hit = true;
        }
      } else if (!probe) {
        err = "stClassSend: class '" + cls_name +
              "' has no class-side method '" + selector + "'";
      }
    }
  }
  if (!err.empty()) {
    Dart_SetReturnValue(args, Dart_NewApiError(err.c_str()));
    return;
  }
  if (probe) {
    if (!hit) {
      Dart_SetReturnValue(args, Dart_Null());  // genuine miss
      return;
    }
    // An error result (an ST signal from inside the found method) must
    // PROPAGATE, not read as a miss.
    if (Dart_IsError(result_handle)) {
      Dart_SetReturnValue(args, result_handle);
      return;
    }
    Dart_Handle box = Dart_NewList(1);
    Dart_ListSetAt(box, 0, result_handle);
    Dart_SetReturnValue(args, box);
    return;
  }
  Dart_SetReturnValue(args, result_handle);
}

void ST_classSend(Dart_NativeArguments args) { STClassSendCommon(args, false); }
void ST_classSendTry(Dart_NativeArguments args) {
  STClassSendCommon(args, true);
}

// stExtSendTry(receiver, selector, args) -> [result] | null.  Sprint 11c:
// core-class EXTENSION dispatch — Object.noSuchMethod's ST hook. Maps the
// receiver's runtime kind to its extension-holder chain ("SmallInteger ext"
// -> "Integer ext" -> "Number ext" -> ... wired by the loader from the world
// files' own declared supers), finds the method, invokes it with the
// receiver as arg 0. Null on a genuine miss.
void ST_extSendTry(Dart_NativeArguments args) {
  Dart_Handle recv_h = Dart_GetNativeArgument(args, 0);
  Dart_Handle sel_h = Dart_GetNativeArgument(args, 1);
  Dart_Handle list_h = Dart_GetNativeArgument(args, 2);
  const char* sel_c = NULL;
  if (Dart_IsError(Dart_StringToCString(sel_h, &sel_c)) || sel_c == NULL) {
    Dart_SetReturnValue(args, Dart_Null());
    return;
  }
  intptr_t n = 0;
  if (Dart_IsError(Dart_ListLength(list_h, &n))) {
    Dart_SetReturnValue(args, Dart_Null());
    return;
  }
  std::vector<Dart_Handle> elems(n);
  for (intptr_t i = 0; i < n; i++) {
    elems[i] = Dart_ListGetAt(list_h, i);
  }
  const std::string selector(sel_c);
  Thread* thread = Thread::Current();
  Dart_Handle result_handle = Dart_Null();
  bool hit = false;
  {
    TransitionNativeToVM transition(thread);
    HANDLESCOPE(thread);
    Zone* zone = thread->zone();
    const Object& recv = Object::Handle(zone, Api::UnwrapHandle(recv_h));
    // Candidate holders in hierarchy order — probed individually, because a
    // standalone file may load only ONE of them (fib.mst loads just
    // "Integer ext"); each found candidate's own super chain is also walked
    // (in a full world boot the chain covers the rest by itself).
    static const char* kIntC[] = {"SmallInteger ext", "LargeInteger ext",
                                  "Integer ext", "Number ext",
                                  "Magnitude ext", "Object ext", NULL};
    static const char* kDblC[] = {"Double ext", "Float ext", "Number ext",
                                  "Magnitude ext", "Object ext", NULL};
    static const char* kStrC[] = {"String ext", "Object ext", NULL};
    static const char* kTrueC[] = {"True ext", "Boolean ext", "Object ext",
                                   NULL};
    static const char* kFalseC[] = {"False ext", "Boolean ext", "Object ext",
                                    NULL};
    static const char* kNilC[] = {"UndefinedObject ext", "Object ext", NULL};
    static const char* kArrC[] = {"Array ext", "Object ext", NULL};
    static const char* kClosC[] = {"BlockClosure ext", "BlockContext ext",
                                   "Object ext", NULL};
    static const char* kTypeC[] = {"Behavior ext", "ClassDescription ext",
                                   "Class ext", "Object ext", NULL};
    static const char* kObjC[] = {"Object ext", NULL};
    const char** candidates = kObjC;
    if (recv.IsSmi() || recv.IsMint() || recv.IsBigint()) {
      candidates = kIntC;
    } else if (recv.IsDouble()) {
      candidates = kDblC;
    } else if (recv.IsString()) {
      candidates = kStrC;
    } else if (recv.IsBool()) {
      candidates = Bool::Cast(recv).value() ? kTrueC : kFalseC;
    } else if (recv.IsNull()) {
      candidates = kNilC;
    } else if (recv.IsArray() || recv.IsGrowableObjectArray()) {
      candidates = kArrC;
    } else if (recv.IsClosure()) {
      candidates = kClosC;
    } else if (recv.IsType()) {
      candidates = kTypeC;
    }
    const String& sel = String::Handle(
        zone, Symbols::New(thread, ::st::MangleSelector(selector).c_str()));
    Function& fn = Function::Handle(zone);
    Class& c = Class::Handle(zone);
    for (const char** name = candidates; *name != NULL && fn.IsNull();
         name++) {
      c = ::st::FindStClassByName(thread, *name);
      while (!c.IsNull()) {
        if (!c.is_finalized()) ClassFinalizer::FinalizeClass(c);
        fn ^= c.LookupDynamicFunction(sel);
        if (!fn.IsNull()) break;
        c ^= c.SuperClass();
      }
    }
    if (!fn.IsNull()) {
      const Array& arr = Array::Handle(zone, Array::New(n + 1, Heap::kOld));
      arr.SetAt(0, recv);
      for (intptr_t i = 0; i < n; i++) {
        arr.SetAt(i + 1, Object::Handle(zone, Api::UnwrapHandle(elems[i])));
      }
      const Object& result =
          Object::Handle(zone, DartEntry::InvokeFunction(fn, arr));
      result_handle = Api::NewHandle(thread, result.raw());
      hit = true;
    }
  }
  if (!hit) {
    Dart_SetReturnValue(args, Dart_Null());
    return;
  }
  if (Dart_IsError(result_handle)) {
    Dart_SetReturnValue(args, result_handle);  // ST signal propagates
    return;
  }
  Dart_Handle box = Dart_NewList(1);
  Dart_ListSetAt(box, 0, result_handle);
  Dart_SetReturnValue(args, box);
}

// stClassOf(x) -> the receiver's CLASS VALUE (a canonical Type). ST instances
// answer their own class's Type (so `x class == Point` holds against class
// literals, and `self class multiplier` reaches class-side methods through
// the Type-NSM machinery); Dart natives answer their extension HOLDER's Type
// when the world image is loaded, else their runtime class's Type.
void ST_classOf(Dart_NativeArguments args) {
  Dart_Handle recv_h = Dart_GetNativeArgument(args, 0);
  Thread* thread = Thread::Current();
  Dart_Handle result = Dart_Null();
  {
    TransitionNativeToVM transition(thread);
    HANDLESCOPE(thread);
    Zone* zone = thread->zone();
    const Object& recv = Object::Handle(zone, Api::UnwrapHandle(recv_h));
    static const char* kIntC[] = {"SmallInteger ext", "Integer ext", NULL};
    static const char* kDblC[] = {"Double ext", "Float ext", NULL};
    static const char* kStrC[] = {"String ext", NULL};
    static const char* kTrueC[] = {"True ext", "Boolean ext", NULL};
    static const char* kFalseC[] = {"False ext", "Boolean ext", NULL};
    static const char* kNilC[] = {"UndefinedObject ext", NULL};
    static const char* kArrC[] = {"Array ext", NULL};
    static const char* kClosC[] = {"BlockClosure ext", NULL};
    const char** candidates = NULL;
    if (recv.IsSmi() || recv.IsMint() || recv.IsBigint()) {
      candidates = kIntC;
    } else if (recv.IsDouble()) {
      candidates = kDblC;
    } else if (recv.IsString()) {
      candidates = kStrC;
    } else if (recv.IsBool()) {
      candidates = Bool::Cast(recv).value() ? kTrueC : kFalseC;
    } else if (recv.IsNull()) {
      candidates = kNilC;
    } else if (recv.IsArray() || recv.IsGrowableObjectArray()) {
      candidates = kArrC;
    } else if (recv.IsClosure()) {
      candidates = kClosC;
    }
    Class& cls = Class::Handle(zone);
    if (candidates != NULL) {
      for (const char** name = candidates; *name != NULL && cls.IsNull();
           name++) {
        cls = ::st::FindStClassByName(thread, *name);
      }
    }
    if (cls.IsNull()) cls = recv.clazz();  // ST instance / no holder loaded
    const Type& type =
        Type::Handle(zone, Type::NewNonParameterizedType(cls));
    result = Api::NewHandle(thread, type.raw());
  }
  Dart_SetReturnValue(args, result);
}

// stAsSymbol(String) -> the canonical VM-symbol String: `'foo' asSymbol` is
// IDENTICAL to the `#foo` literal (both come from Symbols::New).
void ST_asSymbol(Dart_NativeArguments args) {
  Dart_Handle s_h = Dart_GetNativeArgument(args, 0);
  const char* s_c = NULL;
  if (Dart_IsError(Dart_StringToCString(s_h, &s_c)) || s_c == NULL) {
    Dart_SetReturnValue(args, Dart_NewApiError("stAsSymbol: bad argument"));
    return;
  }
  const std::string text(s_c);
  Thread* thread = Thread::Current();
  Dart_Handle result = Dart_Null();
  {
    TransitionNativeToVM transition(thread);
    HANDLESCOPE(thread);
    Zone* zone = thread->zone();
    const String& sym =
        String::Handle(zone, Symbols::New(thread, text.c_str()));
    result = Api::NewHandle(thread, sym.raw());
  }
  Dart_SetReturnValue(args, result);
}

// Smalltalk gcScavenge — force a new-space collection.
void ST_gcScavenge(Dart_NativeArguments args) {
  Thread* thread = Thread::Current();
  {
    TransitionNativeToVM transition(thread);
    thread->isolate()->heap()->CollectGarbage(Heap::kNew);
  }
  Dart_SetReturnValue(args, Dart_Null());
}

// Smalltalk gcFull — force an old-space (full) collection.
void ST_gcFull(Dart_NativeArguments args) {
  Thread* thread = Thread::Current();
  {
    TransitionNativeToVM transition(thread);
    thread->isolate()->heap()->CollectGarbage(Heap::kOld);
  }
  Dart_SetReturnValue(args, Dart_Null());
}

// Smalltalk gcStats — the MACVM SPEC 8-element order: (scavengeCount
// fullGcCount edenUsed oldUsed oldCommitted bytesPromoted markedBytesLast
// contextAllocs). Sizes are real (bytes); counters V1's Heap doesn't expose
// publicly answer 0.
void ST_gcStats(Dart_NativeArguments args) {
  int64_t eden_used = 0, old_used = 0, old_committed = 0;
  Thread* thread = Thread::Current();
  {
    TransitionNativeToVM transition(thread);
    Heap* heap = thread->isolate()->heap();
    eden_used = heap->UsedInWords(Heap::kNew) * kWordSize;
    old_used = heap->UsedInWords(Heap::kOld) * kWordSize;
    old_committed = heap->CapacityInWords(Heap::kOld) * kWordSize;
  }
  Dart_Handle list = Dart_NewList(8);
  Dart_ListSetAt(list, 0, Dart_NewInteger(0));             // scavengeCount
  Dart_ListSetAt(list, 1, Dart_NewInteger(0));             // fullGcCount
  Dart_ListSetAt(list, 2, Dart_NewInteger(eden_used));     // edenUsed
  Dart_ListSetAt(list, 3, Dart_NewInteger(old_used));      // oldUsed
  Dart_ListSetAt(list, 4, Dart_NewInteger(old_committed)); // oldCommitted
  Dart_ListSetAt(list, 5, Dart_NewInteger(0));             // bytesPromoted
  Dart_ListSetAt(list, 6, Dart_NewInteger(0));             // markedBytesLast
  Dart_ListSetAt(list, 7, Dart_NewInteger(0));             // contextAllocs
  Dart_SetReturnValue(args, list);
}

// stOutline(src) -> List of [type, name, startLine] triples (or an
// "ERR: ..." String). Sprint 12: the import slicer — parse-only, no VM
// registration. Types: 'class' (Super subclass: Name), 'extend'
// (Name extend / Name class extend), 'extmethod' (Name >> sel), 'vardecl'
// (top-level | a b |), 'stmt' (a bare do-it statement). The caller slices
// the source by consecutive startLines (each item's chunk runs to the next
// item's start), so leading comments travel with the item they precede.
void ST_outline(Dart_NativeArguments args) {
  Dart_Handle src_h = Dart_GetNativeArgument(args, 0);
  const char* src_c = NULL;
  if (Dart_IsError(Dart_StringToCString(src_h, &src_c)) || src_c == NULL) {
    Dart_SetReturnValue(args,
                        Dart_NewStringFromCString("ERR: bad source argument"));
    return;
  }
  std::string source(src_c);
  ::st::Lexer lexer(source);
  std::vector<::st::Token> tokens;
  ::st::LexError lex_err;
  if (!lexer.Tokenize(&tokens, &lex_err)) {
    char buf[600];
    snprintf(buf, sizeof(buf), "ERR: lex %d:%d: %s", lex_err.line,
             lex_err.col, lex_err.message.c_str());
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
  Dart_Handle out = Dart_NewList(
      static_cast<intptr_t>(program->items.size()));
  intptr_t idx = 0;
  for (auto& item : program->items) {
    ::st::Node* n = item.get();
    if (n == nullptr) continue;
    const char* type = "stmt";
    std::string name;
    if (auto* cd = dynamic_cast<::st::ClassDefNode*>(n)) {
      type = "class";
      name = cd->name;
    } else if (auto* ex = dynamic_cast<::st::ExtendNode*>(n)) {
      type = "extend";
      name = ex->class_name;
    } else if (auto* em = dynamic_cast<::st::ExtMethodNode*>(n)) {
      type = "extmethod";
      name = em->class_name;
    } else if (dynamic_cast<::st::VarDeclNode*>(n) != nullptr) {
      type = "vardecl";
    }
    Dart_Handle triple = Dart_NewList(3);
    Dart_ListSetAt(triple, 0, Dart_NewStringFromCString(type));
    Dart_ListSetAt(triple, 1, Dart_NewStringFromCString(name.c_str()));
    Dart_ListSetAt(triple, 2, Dart_NewInteger(n->pos.line));
    Dart_ListSetAt(out, idx++, triple);
  }
  Dart_SetReturnValue(args, out);
}

// stCheck(src) -> ''.  Parse-only validation (Sprint 10: the editor's cheap
// pre-Accept check): lex+parse, no VM state touched. Returns '' when the
// source parses, else "ERR: line:col: message".
void ST_check(Dart_NativeArguments args) {
  Dart_Handle src_h = Dart_GetNativeArgument(args, 0);
  const char* src_c = NULL;
  if (Dart_IsError(Dart_StringToCString(src_h, &src_c)) || src_c == NULL) {
    Dart_SetReturnValue(args,
                        Dart_NewStringFromCString("ERR: bad source argument"));
    return;
  }
  std::string source(src_c);
  ::st::Lexer lexer(source);
  std::vector<::st::Token> tokens;
  ::st::LexError lex_err;
  if (!lexer.Tokenize(&tokens, &lex_err)) {
    char buf[600];
    snprintf(buf, sizeof(buf), "ERR: %d:%d: %s", lex_err.line, lex_err.col,
             lex_err.message.c_str());
    Dart_SetReturnValue(args, Dart_NewStringFromCString(buf));
    return;
  }
  ::st::Parser parser(std::move(tokens));
  ::st::ParseError perr;
  std::unique_ptr<::st::ProgramNode> program = parser.ParseProgram(&perr);
  if (program == nullptr || !perr.ok) {
    char buf[600];
    snprintf(buf, sizeof(buf), "ERR: %d:%d: %s", perr.line, perr.col,
             perr.message.c_str());
    Dart_SetReturnValue(args, Dart_NewStringFromCString(buf));
    return;
  }
  Dart_SetReturnValue(args, Dart_NewStringFromCString(""));
}

// stIsKindOf(obj, type) -> bool.  Is obj's class the Type's class or one of
// its subclasses? (Sprint 9: the on:do: handler match.)
void ST_isKindOf(Dart_NativeArguments args) {
  Dart_Handle obj_h = Dart_GetNativeArgument(args, 0);
  Dart_Handle type_h = Dart_GetNativeArgument(args, 1);
  bool result = false;
  Thread* thread = Thread::Current();
  {
    TransitionNativeToVM transition(thread);
    HANDLESCOPE(thread);
    Zone* zone = thread->zone();
    Isolate* isolate = thread->isolate();
    const Object& obj = Object::Handle(zone, Api::UnwrapHandle(obj_h));
    const Object& t = Object::Handle(zone, Api::UnwrapHandle(type_h));
    if (t.IsType()) {
      const Class& target = Class::Handle(zone, Type::Cast(t).type_class());
      Class& c = Class::Handle(
          zone, isolate->class_table()->At(obj.GetClassId()));
      while (!c.IsNull()) {
        if (c.raw() == target.raw()) {
          result = true;
          break;
        }
        c ^= c.SuperClass();
      }
    }
  }
  Dart_SetReturnValue(args, Dart_NewBoolean(result));
}

// Guard for the become natives: only plain, non-null, non-canonical heap
// instances may forward (a canonical object — a Smi, a symbol, an interned
// string — lives in identity tables that forwarding would corrupt).
static const char* BecomeGuard(const Object& a, const Object& b) {
  if (!a.raw()->IsHeapObject() || !b.raw()->IsHeapObject()) {
    return "become: immediates (SmallIntegers) cannot forward";
  }
  if (a.IsNull() || b.IsNull()) return "become: nil cannot forward";
  if (!a.IsInstance() || !b.IsInstance()) {
    return "become: only plain instances can forward";
  }
  if (a.IsCanonical() || b.IsCanonical()) {
    return "become: canonical objects cannot forward";
  }
  return NULL;
}

// stBecomeForward(a, b): every reference to a — heap, stack, handles —
// becomes a reference to b (the VM's reload primitive, Become::
// ElementsForwardIdentity). One-way. Returns b. Sprint 9: the feature MACVM
// had to drop; here it is the same machinery live class-reshape uses.
void ST_becomeForward(Dart_NativeArguments args) {
  Dart_Handle a_h = Dart_GetNativeArgument(args, 0);
  Dart_Handle b_h = Dart_GetNativeArgument(args, 1);
  Thread* thread = Thread::Current();
  std::string err;
  {
    TransitionNativeToVM transition(thread);
    HANDLESCOPE(thread);
    Zone* zone = thread->zone();
    const Object& a = Object::Handle(zone, Api::UnwrapHandle(a_h));
    const Object& b = Object::Handle(zone, Api::UnwrapHandle(b_h));
    const char* guard = BecomeGuard(a, b);
    if (guard != NULL) {
      err = guard;
    } else {
      const Array& before = Array::Handle(zone, Array::New(1, Heap::kOld));
      const Array& after = Array::Handle(zone, Array::New(1, Heap::kOld));
      before.SetAt(0, a);
      after.SetAt(0, b);
      Become::ElementsForwardIdentity(before, after);
    }
  }
  if (!err.empty()) {
    Dart_SetReturnValue(args, Dart_NewApiError(err.c_str()));
    return;
  }
  Dart_SetReturnValue(args, b_h);
}

// Shallow-copy an ST instance: a fresh Instance of the same (finalized)
// class with every instance Field copied (the class chain walked). Public-API
// equivalent of the protected Object::Clone, sufficient for ST objects.
static RawInstance* ShallowCopy(Thread* thread, const Instance& src) {
  Zone* zone = thread->zone();
  const Class& cls = Class::Handle(zone, src.clazz());
  const Instance& copy = Instance::Handle(zone, Instance::New(cls, Heap::kOld));
  Class& c = Class::Handle(zone, cls.raw());
  Array& fields = Array::Handle(zone);
  Field& f = Field::Handle(zone);
  Object& val = Object::Handle(zone);
  while (!c.IsNull()) {
    fields = c.fields();
    if (!fields.IsNull()) {
      for (intptr_t i = 0; i < fields.Length(); i++) {
        f ^= fields.At(i);
        if (f.is_static()) continue;
        val = src.GetField(f);
        copy.SetField(f, val);
      }
    }
    c ^= c.SuperClass();
  }
  return copy.raw();
}

// stBecome(a, b): two-way identity swap, via shallow clones — refs to a see
// (a copy of) b and refs to b see (a copy of) a. Identity hashes are those of
// the fresh copies (documented caveat). Returns null.
void ST_become(Dart_NativeArguments args) {
  Dart_Handle a_h = Dart_GetNativeArgument(args, 0);
  Dart_Handle b_h = Dart_GetNativeArgument(args, 1);
  Thread* thread = Thread::Current();
  std::string err;
  {
    TransitionNativeToVM transition(thread);
    HANDLESCOPE(thread);
    Zone* zone = thread->zone();
    const Object& a = Object::Handle(zone, Api::UnwrapHandle(a_h));
    const Object& b = Object::Handle(zone, Api::UnwrapHandle(b_h));
    const char* guard = BecomeGuard(a, b);
    if (guard != NULL) {
      err = guard;
    } else {
      const Object& a_copy = Object::Handle(
          zone, ShallowCopy(thread, Instance::Cast(a)));
      const Object& b_copy = Object::Handle(
          zone, ShallowCopy(thread, Instance::Cast(b)));
      const Array& before = Array::Handle(zone, Array::New(2, Heap::kOld));
      const Array& after = Array::Handle(zone, Array::New(2, Heap::kOld));
      before.SetAt(0, a);
      after.SetAt(0, b_copy);
      before.SetAt(1, b);
      after.SetAt(1, a_copy);
      Become::ElementsForwardIdentity(before, after);
    }
  }
  if (!err.empty()) {
    Dart_SetReturnValue(args, Dart_NewApiError(err.c_str()));
    return;
  }
  Dart_SetReturnValue(args, Dart_Null());
}

}  // namespace bin
}  // namespace dart

// --- the --with-st world boot (Sprint 12b) ---------------------------------
// Called from runtime/bin/main.cc (the one-line hook in the patch) after the
// main isolate's script has loaded: resolve the vendored world directory,
// install the ST dispatch hooks, and stRun every *.mst in name order. All the
// logic lives HERE (tracked); the VM tree carries only the call.

#include <dirent.h>
#include <sys/stat.h>

#include <algorithm>

namespace st {

static bool DirHasWorld(const std::string& dir) {
  struct stat st_buf;
  return stat((dir + "/01_object.mst").c_str(), &st_buf) == 0;
}

// Resolution order: explicit --with-st=<path> > $MACDART_ST_WORLD > the
// vendored copy relative to the executable (build dirs live under macdart/,
// so <exedir>/../st/world is macdart/st/world; <exedir>/st/world covers an
// installed layout).
static std::string ResolveWorldDir(const char* explicit_dir,
                                   const char* exe_path) {
  if (explicit_dir != NULL && explicit_dir[0] != '\0') {
    return std::string(explicit_dir);
  }
  const char* env = getenv("MACDART_ST_WORLD");
  if (env != NULL && env[0] != '\0') return std::string(env);
  std::string exe(exe_path == NULL ? "" : exe_path);
  const size_t slash = exe.rfind('/');
  const std::string bindir = (slash == std::string::npos)
                                 ? std::string(".")
                                 : exe.substr(0, slash);
  const char* rels[] = {"/../st/world", "/st/world", "/../../macdart/st/world"};
  for (size_t i = 0; i < sizeof(rels) / sizeof(rels[0]); i++) {
    const std::string cand = bindir + rels[i];
    if (DirHasWorld(cand)) return cand;
  }
  return std::string();
}

const char* BootWorldForMain(const char* explicit_dir,
                             const char* exe_path,
                             char* msg_buf,
                             int msg_cap) {
  static std::string s_error;  // stable storage for the returned message
  const std::string dir = ResolveWorldDir(explicit_dir, exe_path);
  if (dir.empty() || !DirHasWorld(dir)) {
    s_error = "cannot find the Smalltalk world (looked relative to the "
              "executable; set --with-st=<dir> or $MACDART_ST_WORLD)";
    if (!dir.empty()) s_error = "no world at " + dir;
    return s_error.c_str();
  }

  // The dispatch hooks (class values / core-class extensions) install from
  // dart:cocoa — the Dart-side wrappers normally do this on first use, but
  // the boot path enters through C++.
  {
    Dart_Handle cocoa =
        Dart_LookupLibrary(Dart_NewStringFromCString("dart:cocoa"));
    if (!Dart_IsError(cocoa)) {
      Dart_Handle r = Dart_Invoke(
          cocoa, Dart_NewStringFromCString("stEnsureHooks"), 0, NULL);
      if (Dart_IsError(r)) {
        s_error = std::string("hook install failed: ") + Dart_GetError(r);
        return s_error.c_str();
      }
    }
  }

  std::vector<std::string> files;
  DIR* d = opendir(dir.c_str());
  if (d == NULL) {
    s_error = "cannot open " + dir;
    return s_error.c_str();
  }
  struct dirent* ent;
  while ((ent = readdir(d)) != NULL) {
    const std::string name(ent->d_name);
    if (name.size() > 4 && name.compare(name.size() - 4, 4, ".mst") == 0) {
      files.push_back(name);
    }
  }
  closedir(d);
  std::sort(files.begin(), files.end());

  int loaded = 0;
  for (size_t i = 0; i < files.size(); i++) {
    const std::string path = dir + "/" + files[i];
    FILE* f = fopen(path.c_str(), "rb");
    if (f == NULL) {
      s_error = "cannot read " + path;
      return s_error.c_str();
    }
    std::string src;
    char buf[65536];
    size_t n;
    while ((n = fread(buf, 1, sizeof(buf), f)) > 0) src.append(buf, n);
    fclose(f);
    const std::string r = dart::bin::STRunSourceString(
        src, /*run_toplevel=*/true, /*allow_reopen=*/true);
    if (r.compare(0, 4, "ERR:") == 0) {
      s_error = files[i] + ": " + r;
      return s_error.c_str();
    }
    loaded++;
  }
  snprintf(msg_buf, msg_cap, "st: world loaded (%d files) from %s", loaded,
           dir.c_str());
  return NULL;
}

}  // namespace st
