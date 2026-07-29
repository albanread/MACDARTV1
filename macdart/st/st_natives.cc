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
    // Sprint 9: the prelude (Exception/Error/STSystem) loads first, once per
    // isolate, so user code can subclass and reference it.
    ok = EnsurePrelude(thread, &load_err);
    if (ok) {
      ok = ::st::Loader::Load(std::move(program), source, &summary, &load_err);
    }
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

// Find a loaded ST class by name — newest st:mst/ library first. Returns
// Class::null() if absent. Caller holds a VM transition + HANDLESCOPE.
static RawClass* FindStClass(Thread* thread, const std::string& name) {
  Zone* zone = thread->zone();
  Isolate* isolate = thread->isolate();
  const GrowableObjectArray& libs = GrowableObjectArray::Handle(
      zone, isolate->object_store()->libraries());
  const String& cname =
      String::Handle(zone, Symbols::New(thread, name.c_str()));
  Library& lib = Library::Handle(zone);
  String& url = String::Handle(zone);
  Class& cls = Class::Handle(zone);
  for (intptr_t i = libs.Length() - 1; i >= 0; i--) {
    lib ^= libs.At(i);
    url = lib.url();
    if (url.IsNull()) continue;
    if (strncmp(url.ToCString(), "st:mst/", 7) != 0) continue;
    cls = lib.LookupLocalClass(cname);
    if (!cls.IsNull()) return cls.raw();
  }
  return Class::null();
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
void ST_send(Dart_NativeArguments args) {
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
  {
    TransitionNativeToVM transition(thread);
    HANDLESCOPE(thread);
    Zone* zone = thread->zone();
    const Object& recv = Object::Handle(zone, Api::UnwrapHandle(recv_h));
    const Class& cls = Class::Handle(zone, recv.clazz());
    if (!cls.is_finalized()) ClassFinalizer::FinalizeClass(cls);
    const String& sel =
        String::Handle(zone, Symbols::New(thread, selector.c_str()));
    const Function& fn =
        Function::Handle(zone, cls.LookupDynamicFunction(sel));
    if (fn.IsNull()) {
      err = "stSend: " + std::string(cls.ToCString()) + " has no method '" +
            selector + "'";
    } else {
      const Array& arr = Array::Handle(zone, Array::New(n + 1, Heap::kOld));
      arr.SetAt(0, recv);  // receiver = argument 0
      for (intptr_t i = 0; i < n; i++) {
        arr.SetAt(i + 1, Object::Handle(zone, Api::UnwrapHandle(elems[i])));
      }
      const Object& result =
          Object::Handle(zone, DartEntry::InvokeFunction(fn, arr));
      result_handle = Api::NewHandle(thread, result.raw());
    }
  }
  if (!err.empty()) {
    Dart_SetReturnValue(args, Dart_NewApiError(err.c_str()));
    return;
  }
  Dart_SetReturnValue(args, result_handle);
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
