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

#include <dlfcn.h>    // dlsym(RTLD_DEFAULT, …) — the FFI floor (ST_PORTING_PLAN §3a)
#include <pthread.h>  // pthread_sigmask — shield blocking FFI syscalls from SIGPROF
#include <signal.h>
#include <stdio.h>
#include <string.h>

#include <memory>
#include <mutex>   // the ST_eq (isolate, cid) -> `=` Function dispatch cache
#include <string>
#include <unordered_map>  // the ext-send (isolate, cid, sel) dispatch cache
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

// A miss — no such class, no such method, a bad argument — must raise a
// CATCHABLE Dart error. It used to be reported with Dart_NewApiError, and an
// ApiError returned from a native is an UNHANDLED error: it terminates the
// isolate, so the caller's try/catch never runs.
//
// That made two promises in the code untrue. cocoa.dart's stDivide probes for
// the world's Fraction class inside a try/catch and documents "a plain double
// otherwise" — a fallback it could never reach; an inexact `3 / 2` in a
// standalone .mst killed the process instead. And `42 become: 43` died on the
// lookup rather than reaching become:'s own refusal. Both found by
// st/test/type_conformance.mst, which now covers them.
//
// Dart_ThrowException does not return; every call site keeps its `return` for
// shape. Must be called OUTSIDE any TransitionNativeToVM scope — all sites are.
static void STThrow(const char* msg) {
  Dart_ThrowException(Dart_NewStringFromCString(msg));
}


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
    STThrow("stInvokeStatic: bad class/selector argument");
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
    STThrow(err.c_str());
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
    STThrow("stNew: bad class argument");
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
    STThrow(err.c_str());
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
    STThrow("stSend: bad selector argument");
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
    STThrow(err.c_str());
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

// ── ST_eq(a, b): the `=` slow path, direct and cached ──────────────────────
// _stEqualsSlow's terminal used to be stSend(a, '=', [b]) — a fresh args List
// per comparison, then STSendCommon's per-call MangleSelector + Symbols::New +
// an UNCACHED super-chain walk + an OLD-space args Array. On ST receivers
// (Fraction, user classes) that priced every value-equality at ~158ns, 11x
// MACVM's dispatch (the front-end review's probe). This entry takes (a, b)
// directly and caches (isolate, cid) -> the resolved `=` Function.
//
// Why raw pointers are safe: Functions/Classes live in OLD space and this VM's
// old space never moves (1.24 mark-sweep, no compactor). Why the cache must be
// FLUSHED: an st load or a hot reload can replace a class's methods — both
// call st::ClearSendCache() (Loader::Load, wsReload).
struct EqCacheEntry {
  dart::Isolate* iso;
  intptr_t cid;
  dart::RawFunction* fn;
};
static std::vector<EqCacheEntry> g_eq_cache;
static std::mutex g_eq_mutex;

// The ext-send dispatch cache: (isolate, cid, mangled-selector symbol) -> the
// resolved "<Type> ext" holder Function. ST_extSendTry otherwise re-resolves
// the holder by NAME on EVERY send to a native receiver — FindStClassByName is
// a library scan + a String::ToCString per candidate, and the profiler put
// that whole chain at ~a third of DeltaBlue's CPU (`between:and:` on a Smi,
// from OrderedCollection>>at:'s bounds check, fired ~30k times per run, each a
// fresh name scan). Same safety as the `=` cache: raw old-space pointers
// (1.24 old space never moves); the selector symbol is canonical (Symbols::New
// interns) so its RawString* is a stable identity key; flushed by
// ClearSendCache on every load/reload (both can replace a holder's methods).
struct ExtCacheKey {
  dart::Isolate* iso;
  intptr_t cid;
  dart::RawString* sel;
  bool operator==(const ExtCacheKey& o) const {
    return iso == o.iso && cid == o.cid && sel == o.sel;
  }
};
struct ExtCacheHash {
  size_t operator()(const ExtCacheKey& k) const {
    return (reinterpret_cast<size_t>(k.iso) >> 4) ^
           (static_cast<size_t>(k.cid) * 2654435761u) ^
           (reinterpret_cast<size_t>(k.sel) >> 3);
  }
};
static std::unordered_map<ExtCacheKey, dart::RawFunction*, ExtCacheHash>
    g_ext_cache;
// The class-side send cache: (isolate, class-value cid, selector) -> the
// resolved class-side static Function. STClassSendCommon otherwise re-resolves
// the "Foo class" metaclass shadow BY NAME (FindStClassByName) on every
// class-side send — the residual name-lookup cost after the ext-send cache
// (`Planner current`, `Strength required` in the deltablue cascade). Same key
// STRUCTURE as the ext cache but a DISTINCT map: this keys on the class value's
// OWN cid (type.type_class().id()), a different id-space meaning than a native
// receiver's cid, so the two must not share a map. Same mutex + same flush.
static std::unordered_map<ExtCacheKey, dart::RawFunction*, ExtCacheHash>
    g_cls_cache;
static std::mutex g_ext_mutex;

namespace st {
void ClearSendCache() {
  { std::lock_guard<std::mutex> lock(g_eq_mutex); g_eq_cache.clear(); }
  {
    std::lock_guard<std::mutex> lock(g_ext_mutex);
    g_ext_cache.clear();
    g_cls_cache.clear();
  }
}
}  // namespace st

// stSymbolFor(name) -> the canonical StSymbol. The Dart-side stSymbol delegates
// here so runtime symbols share the builder's compile-time intern table. The
// intern table + st::InternStSymbol live in st_loader.cc (always-linked, so the
// one strong `::st::` definition is used everywhere — see the note there).
void ST_symbolFor(Dart_NativeArguments args) {
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
    RawInstance* sym = ::st::InternStSymbol(thread, name.c_str());
    result = Api::NewHandle(thread, sym);
  }
  Dart_SetReturnValue(args, result);
}

void ST_eq(Dart_NativeArguments args) {
  Dart_Handle a_h = Dart_GetNativeArgument(args, 0);
  Dart_Handle b_h = Dart_GetNativeArgument(args, 1);
  Thread* thread = Thread::Current();
  Dart_Handle result_handle = Dart_Null();
  std::string err;
  {
    TransitionNativeToVM transition(thread);
    HANDLESCOPE(thread);
    Zone* zone = thread->zone();
    const Object& recv = Object::Handle(zone, Api::UnwrapHandle(a_h));
    const intptr_t cid = recv.GetClassId();
    Isolate* iso = thread->isolate();
    Function& fn = Function::Handle(zone);
    {
      std::lock_guard<std::mutex> lock(g_eq_mutex);
      for (size_t i = 0; i < g_eq_cache.size(); i++) {
        if (g_eq_cache[i].iso == iso && g_eq_cache[i].cid == cid) {
          fn ^= g_eq_cache[i].fn;
          break;
        }
      }
    }
    if (fn.IsNull()) {
      const String& sel = String::Handle(zone, Symbols::New(thread, "="));
      Class& c = Class::Handle(zone, recv.clazz());
      while (!c.IsNull()) {
        if (!c.is_finalized()) ClassFinalizer::FinalizeClass(c);
        fn ^= c.LookupDynamicFunction(sel);
        if (!fn.IsNull()) break;
        c ^= c.SuperClass();
      }
      if (!fn.IsNull()) {
        std::lock_guard<std::mutex> lock(g_eq_mutex);
        if (g_eq_cache.size() < 64) {  // a handful of classes define `=`
          EqCacheEntry e;
          e.iso = iso;
          e.cid = cid;
          e.fn = fn.raw();
          g_eq_cache.push_back(e);
        }
      }
    }
    if (fn.IsNull()) {
      const Class& cls = Class::Handle(zone, recv.clazz());
      err = "stSend: " + std::string(cls.ToCString()) + " has no method '='";
    } else {
      // kNew, deliberately: the args Array dies at the next scavenge, where
      // STSendCommon's kOld allocation churned old space per comparison.
      const Array& arr = Array::Handle(zone, Array::New(2));
      arr.SetAt(0, recv);
      arr.SetAt(1, Object::Handle(zone, Api::UnwrapHandle(b_h)));
      const Object& result =
          Object::Handle(zone, DartEntry::InvokeFunction(fn, arr));
      result_handle = Api::NewHandle(thread, result.raw());
    }
  }
  if (!err.empty()) {
    STThrow(err.c_str());
    return;
  }
  Dart_SetReturnValue(args, result_handle);
}

// stGetField(recv, name) -> the value of the dart:core GETTER `name` on recv.
// The universal send (stSendExt) uses this as the LAST resort for a unary ST
// selector on a NATIVE receiver whose name is a dart:core getter that no ST
// method overrode — `#(1 2 3) first`, `aList reversed`, `7 sign` — where the
// getter IS the intended Smalltalk value. Dart's own getter-call semantics
// (`o.name()` -> `(o.name).call()`) would otherwise crash on the result; a
// plain field read does not. A missing getter returns an error handle, which
// propagates as the honest doesNotUnderstand.
void ST_getField(Dart_NativeArguments args) {
  Dart_Handle recv = Dart_GetNativeArgument(args, 0);
  Dart_Handle name_h = Dart_GetNativeArgument(args, 1);
  const char* name_c = NULL;
  if (Dart_IsError(Dart_StringToCString(name_h, &name_c)) || name_c == NULL) {
    Dart_SetReturnValue(args, Dart_Null());
    return;
  }
  Dart_SetReturnValue(args,
                      Dart_GetField(recv, Dart_NewStringFromCString(name_c)));
}

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

static const char** ExtHolderCandidates(const Object& recv);  // defined below

// stRespondsTo(recv, selectorString) -> bool. `respondsTo:` for every receiver.
// stHasMethod alone only walks the receiver's own Dart class chain — right for
// an ST object, but a native (a Smi is a _Smi) keeps its methods in the "Integer
// ext" holders, so this ALSO walks the extension chain (the same one dispatch
// uses). The selector arrives already un-symboled to a String by the Dart side.
void ST_respondsTo(Dart_NativeArguments args) {
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
    // 1. the receiver's own class chain (an ST object; a native Dart method).
    Class& c = Class::Handle(zone, recv.clazz());
    while (!c.IsNull() && !found) {
      if (!c.is_finalized()) ClassFinalizer::FinalizeClass(c);
      fn ^= c.LookupDynamicFunction(sel);
      if (!fn.IsNull()) found = true;
      c ^= c.SuperClass();
    }
    // 2. the extension holders (where a native receiver's ST methods live).
    if (!found) {
      const char** candidates = ExtHolderCandidates(recv);
      for (const char** name = candidates; *name != NULL && !found; name++) {
        c = ::st::FindStClassByName(thread, *name);
        while (!c.IsNull() && !found) {
          if (!c.is_finalized()) ClassFinalizer::FinalizeClass(c);
          fn ^= c.LookupDynamicFunction(sel);
          if (!fn.IsNull()) found = true;
          c ^= c.SuperClass();
        }
      }
    }
  }
  Dart_SetReturnValue(args, Dart_NewBoolean(found));
}

// stBlockNumArgs(block) -> the number of arguments an ST block takes
// ([:a :b | ...] numArgs = 2). An ST block compiles to a closure whose function
// carries 1 + N fixed parameters (the :closure context + the N block args, see
// st_flow_graph_builder BuildClosure), so the arity is num_fixed_parameters - 1.
void ST_blockNumArgs(Dart_NativeArguments args) {
  Dart_Handle recv_h = Dart_GetNativeArgument(args, 0);
  Thread* thread = Thread::Current();
  intptr_t n = 0;
  {
    TransitionNativeToVM transition(thread);
    HANDLESCOPE(thread);
    Zone* zone = thread->zone();
    const Object& recv = Object::Handle(zone, Api::UnwrapHandle(recv_h));
    if (recv.IsClosure()) {
      const Function& fn =
          Function::Handle(zone, Closure::Cast(recv).function());
      n = fn.num_fixed_parameters();
      if (n > 0) n -= 1;  // drop the implicit :closure context parameter
    }
  }
  Dart_SetReturnValue(args, Dart_NewInteger(n));
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
    STThrow("stClassSend: bad selector argument");
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
          if (cls_name == "String ext") {
            // A mutable String, via dart:cocoa's stStringNew(len).
            const Library& cocoa = Library::Handle(
                zone, Library::LookupLibrary(
                          thread, String::Handle(zone, String::New("dart:cocoa"))));
            const Function& mk = Function::Handle(
                zone, cocoa.LookupFunctionAllowPrivate(
                          String::Handle(zone, String::New("stStringNew"))));
            const Array& a = Array::Handle(zone, Array::New(1));
            a.SetAt(0, Smi::Handle(zone, Smi::New(len)));
            const Object& made =
                Object::Handle(zone, DartEntry::InvokeFunction(mk, a));
            result_handle = Api::NewHandle(thread, made.raw());
          } else {
            const Array& made = Array::Handle(zone, Array::New(len));
            result_handle = Api::NewHandle(thread, made.raw());
          }
          hit = true;
        }
      }
      // Only when the alloc intercept above did NOT already produce a result —
      // otherwise the `else if (!probe)` tail would clobber a good native
      // allocation with a bogus "no class-side method" error. That is exactly
      // why `self new: n` on a bridged holder (an INHERITED with:with: whose
      // self is "String ext") failed while the probe path (WriteStream's
      // `collection class new:`) worked.
      if (!hit) {
      const String& sel =
          String::Handle(zone, Symbols::New(thread, msel.c_str()));
      // Cache (isolate, class-value cid, selector) -> the class-side Function,
      // skipping the by-name "Foo class" shadow re-resolution. NEGATIVE entries
      // (a null Function) are cached too, and are the point: the hot residual
      // was `basicNew` on an INHERITED constraint factory — BinaryConstraint's
      // var:var:strength: sent to an EqualityConstraint/ScaleConstraint, so the
      // guarded-alloc slow path lands here with thisCls a subclass. basicNew has
      // no class-side method, so it MISSES the lookup and falls to Instance::New
      // below; a hit-only cache re-scanned FindStClassByName every call (~5000x
      // per constraint class per run). A negative entry skips straight to the
      // fallback. `cls` is type.type_class(); its cid identifies the class
      // value. Reached only when the alloc-intercept did NOT fire.
      const ExtCacheKey ckey = {thread->isolate(), cls.id(), sel.raw()};
      Function& fn = Function::Handle(zone);
      bool cached = false;
      {
        std::lock_guard<std::mutex> lock(g_ext_mutex);
        std::unordered_map<ExtCacheKey, dart::RawFunction*,
                           ExtCacheHash>::iterator it = g_cls_cache.find(ckey);
        if (it != g_cls_cache.end()) {
          fn ^= it->second;
          cached = true;
        }
      }
      if (!cached) {
        // The metaclass-shadow chain holds class-side methods.
        Class& c = Class::Handle(
            zone, ::st::FindStClassByName(thread, (cls_name + " class").c_str()));
        while (!c.IsNull()) {
          if (!c.is_finalized()) ClassFinalizer::FinalizeClass(c);
          fn ^= c.LookupStaticFunction(sel);
          if (!fn.IsNull()) break;
          c ^= c.SuperClass();
        }
        std::lock_guard<std::mutex> lock(g_ext_mutex);
        g_cls_cache[ckey] = fn.raw();  // the hit, OR null = a known miss
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
      }  // if (!hit) — the intercept already answered otherwise
    }
  }
  if (!err.empty()) {
    STThrow(err.c_str());
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

// stBasicNew(type) -> a fresh instance of the type's class. The FAST class-
// side `self new`/`self basicNew` path: it allocates straight from the runtime
// thisCls (full correctness — an inherited factory allocates the receiving
// subclass), skipping the general class-send's string-keyed library scan
// (FindStClassByName) + shadow-chain walk that dominated a 200k-alloc loop.
void ST_basicNewFromType(Dart_NativeArguments args) {
  Dart_Handle type_h = Dart_GetNativeArgument(args, 0);
  Thread* thread = Thread::Current();
  Dart_Handle result = Dart_Null();
  {
    TransitionNativeToVM transition(thread);
    HANDLESCOPE(thread);
    Zone* zone = thread->zone();
    const Object& t = Object::Handle(zone, Api::UnwrapHandle(type_h));
    if (t.IsType()) {
      const Class& cls = Class::Handle(zone, Type::Cast(t).type_class());
      if (!cls.is_finalized()) ClassFinalizer::FinalizeClass(cls);
      const Instance& inst =
          Instance::Handle(zone, Instance::New(cls, Heap::kNew));
      result = Api::NewHandle(thread, inst.raw());
    }
  }
  Dart_SetReturnValue(args, result);
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
// The extension-holder candidate chain for a native/AOT receiver, in hierarchy
// order — the same list ext-dispatch walks (SmallInteger ext -> ... -> Object
// ext). Probed individually because a standalone file may load only one holder;
// each found candidate's own super chain is walked too. Shared by ext-dispatch
// and respondsTo: so they can never disagree on what a native understands.
static const char** ExtHolderCandidates(const Object& recv) {
  static const char* kIntC[] = {"SmallInteger ext", "LargeInteger ext",
                                "Integer ext", "Number ext",
                                "Magnitude ext", "Object ext", NULL};
  static const char* kDblC[] = {"Double ext", "Float ext", "Number ext",
                                "Magnitude ext", "Object ext", NULL};
  static const char* kStrC[] = {"String ext", "Object ext", NULL};
  static const char* kTrueC[] = {"True ext", "Boolean ext", "Object ext", NULL};
  static const char* kFalseC[] = {"False ext", "Boolean ext", "Object ext",
                                  NULL};
  static const char* kNilC[] = {"UndefinedObject ext", "Object ext", NULL};
  static const char* kArrC[] = {"Array ext", "Object ext", NULL};
  static const char* kClosC[] = {"BlockClosure ext", "BlockContext ext",
                                 "Object ext", NULL};
  static const char* kTypeC[] = {"Behavior ext", "ClassDescription ext",
                                 "Class ext", "Object ext", NULL};
  static const char* kObjC[] = {"Object ext", NULL};
  if (recv.IsSmi() || recv.IsMint() || recv.IsBigint()) return kIntC;
  if (recv.IsDouble()) return kDblC;
  if (recv.IsString()) return kStrC;
  if (recv.IsBool()) return Bool::Cast(recv).value() ? kTrueC : kFalseC;
  if (recv.IsNull()) return kNilC;
  if (recv.IsArray() || recv.IsGrowableObjectArray()) return kArrC;
  if (recv.IsClosure()) return kClosC;
  if (recv.IsType()) return kTypeC;
  return kObjC;
}

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
    const String& sel = String::Handle(
        zone, Symbols::New(thread, ::st::MangleSelector(selector).c_str()));
    // Bool is the one type whose holder is NOT a function of cid alone: true
    // and false share kBoolCid but resolve to True ext vs False ext
    // (ExtHolderCandidates splits on the value). Never cache a bool receiver;
    // it always takes the full scan. No hot path sends to bools this way.
    const bool cacheable = !recv.IsBool();
    const ExtCacheKey key = {thread->isolate(), recv.GetClassId(), sel.raw()};
    Function& fn = Function::Handle(zone);
    if (cacheable) {
      std::lock_guard<std::mutex> lock(g_ext_mutex);
      std::unordered_map<ExtCacheKey, dart::RawFunction*,
                         ExtCacheHash>::iterator it = g_ext_cache.find(key);
      if (it != g_ext_cache.end()) fn ^= it->second;
    }
    if (fn.IsNull()) {
      const char** candidates = ExtHolderCandidates(recv);
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
      if (!fn.IsNull() && cacheable) {
        std::lock_guard<std::mutex> lock(g_ext_mutex);
        g_ext_cache[key] = fn.raw();
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
    static const char* kCharC[] = {"Character ext", NULL};
    static const char* kSymC[] = {"Symbol ext", NULL};
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
    } else {
      // A native Character/Symbol/mutable-String (dart:cocoa classes) reports
      // the world class it stands in for, so class-based dispatch works.
      const Class& rc = Class::Handle(zone, recv.clazz());
      const std::string rcn(String::Handle(zone, rc.Name()).ToCString());
      if (rcn == "StMutableString") candidates = kStrC;
      else if (rcn == "StChar") candidates = kCharC;    // -> Character ext
      else if (rcn == "StSymbol") candidates = kSymC;   // -> Symbol ext
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
    STThrow("stAsSymbol: bad argument");
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

// FFI stage C: a general arm64 AAPCS64 call trampoline. Loads x0..x7 from gpr[],
// d0..d7 from fpr[], copies nstk overflow words to the outgoing stack (16-byte
// aligned), calls fn, and hands back x0 (int return) plus d0 (via *out_d0, for
// an fp return). The marshaller below sorts each arg into gpr/fpr/stack per the
// procedure call standard, so this covers fp-register scalars (cblas_dgemm's
// alpha/beta) and >8-arg spill — everything the corpus's FFI needs.
extern "C" uint64_t ffi_call_aapcs(void* fn, const uint64_t* gpr,
                                   const double* fpr, const uint64_t* stk,
                                   int64_t nstk, double* out_d0);
__asm__(
    ".text\n"
    ".p2align 2\n"
    ".globl _ffi_call_aapcs\n"
    "_ffi_call_aapcs:\n"
    "  stp x29, x30, [sp, #-16]!\n"
    "  stp x19, x20, [sp, #-16]!\n"
    "  stp x21, x22, [sp, #-16]!\n"
    "  mov x29, sp\n"                  // frame pointer, after all saves
    "  mov x19, x0\n"                  // fn
    "  mov x20, x2\n"                  // fpr
    "  mov x21, x3\n"                  // stk
    "  mov x22, x5\n"                  // out_d0
    "  mov x9,  x1\n"                  // gpr (x1 is clobbered below)
    "  mov x10, x4\n"                  // nstk
    "  lsl x11, x10, #3\n"            // nstk*8
    "  add x11, x11, #15\n"
    "  bic x11, x11, #15\n"           // round up to 16
    "  sub sp, sp, x11\n"             // reserve outgoing stack
    "  mov x12, #0\n"
    "  cbz x10, Lffi_regs\n"
    "Lffi_copy:\n"
    "  ldr x13, [x21, x12, lsl #3]\n"
    "  str x13, [sp,  x12, lsl #3]\n"
    "  add x12, x12, #1\n"
    "  cmp x12, x10\n"
    "  b.lt Lffi_copy\n"
    "Lffi_regs:\n"
    "  ldp d0, d1, [x20, #0]\n"
    "  ldp d2, d3, [x20, #16]\n"
    "  ldp d4, d5, [x20, #32]\n"
    "  ldp d6, d7, [x20, #48]\n"
    "  ldp x0, x1, [x9, #0]\n"
    "  ldp x2, x3, [x9, #16]\n"
    "  ldp x4, x5, [x9, #32]\n"
    "  ldp x6, x7, [x9, #48]\n"
    "  blr x19\n"
    "  str d0, [x22]\n"               // fp return -> *out_d0
    "  mov sp, x29\n"                 // drop the outgoing-arg area
    "  ldp x21, x22, [sp], #16\n"
    "  ldp x19, x20, [sp], #16\n"
    "  ldp x29, x30, [sp], #16\n"
    "  ret\n");

// The FFI floor, stage A (ST_PORTING_PLAN.md §3a): call a C function BY NAME
// with word arguments. `stFfiCall(List args, String desc)` where desc is
// "name|ret|codes" (codes: one char per arg, 'g' = a machine word — a Dart
// int, which is also how an Alien address travels). Word-only for now: Posix +
// Time are entirely word-args; doubles (Accel) need the FPR trampoline
// (stage C). Fails SAFE via STThrow (catchable) on an unresolved symbol or an
// unsupported type — a bad binding must never segv the isolate. Runs in native
// state; the Dart embedding API used here is valid there.
void ST_ffiCall(Dart_NativeArguments args) {
  Dart_Handle list_h = Dart_GetNativeArgument(args, 0);
  Dart_Handle desc_h = Dart_GetNativeArgument(args, 1);
  const char* desc_c = NULL;
  if (Dart_IsError(Dart_StringToCString(desc_h, &desc_c)) || desc_c == NULL) {
    STThrow("FFI: bad descriptor");
    return;
  }
  const std::string desc(desc_c);
  const size_t p1 = desc.find('|');
  const size_t p2 = (p1 == std::string::npos) ? p1 : desc.find('|', p1 + 1);
  if (p1 == std::string::npos || p2 == std::string::npos) {
    STThrow("FFI: malformed descriptor");
    return;
  }
  const std::string name = desc.substr(0, p1);
  const char ret = desc[p1 + 1];
  const std::string codes = desc.substr(p2 + 1);

  void* fn = dlsym(RTLD_DEFAULT, name.c_str());
  if (fn == NULL) {
    STThrow(("FFI: unresolved symbol '" + name + "'").c_str());
    return;
  }

  // Sort each arg into its AAPCS64 slot: 'g' word -> next GPR then stack;
  // 'f'/'d' double -> next FPR then stack. Only the corpus's codes appear
  // (g word, f double, v void); an unknown code fails safe.
  intptr_t n = 0;
  Dart_ListLength(list_h, &n);
  uint64_t gpr[8] = {0, 0, 0, 0, 0, 0, 0, 0};
  double fpr[8] = {0, 0, 0, 0, 0, 0, 0, 0};
  uint64_t stk[16] = {0};
  int gi = 0, fi = 0, si = 0;
  for (intptr_t i = 0; i < n && i < static_cast<intptr_t>(codes.size()); i++) {
    const char code = codes[i];
    Dart_Handle e = Dart_ListGetAt(list_h, i);
    if (code == 'g') {
      int64_t v = 0;
      Dart_IntegerToInt64(e, &v);
      if (gi < 8) gpr[gi++] = static_cast<uint64_t>(v);
      else if (si < 16) stk[si++] = static_cast<uint64_t>(v);
    } else if (code == 'f' || code == 'd') {
      double v = 0.0;
      if (Dart_IsInteger(e)) {
        int64_t iv = 0;
        Dart_IntegerToInt64(e, &iv);
        v = static_cast<double>(iv);
      } else {
        Dart_DoubleValue(e, &v);
      }
      if (fi < 8) fpr[fi++] = v;
      else if (si < 16) memcpy(&stk[si++], &v, sizeof(double));
    } else {
      STThrow(("FFI: unknown arg code '" + std::string(1, code) + "'").c_str());
      return;
    }
  }

  // Block SIGPROF across the call: the VM profiler's sampling signal otherwise
  // interrupts a blocking syscall (connect/recv/send) into EINTR, which the
  // corpus's verbatim blocking sockets don't expect. Restored immediately after,
  // so the profiler loses at most one sample of a call that was blocked anyway.
  double out_d0 = 0.0;
  sigset_t ffi_block, ffi_old;
  sigemptyset(&ffi_block);
  sigaddset(&ffi_block, SIGPROF);
  pthread_sigmask(SIG_BLOCK, &ffi_block, &ffi_old);
  const uint64_t rx = ffi_call_aapcs(fn, gpr, fpr, stk, si, &out_d0);
  pthread_sigmask(SIG_SETMASK, &ffi_old, NULL);

  if (ret == 'v') {
    Dart_SetReturnValue(args, Dart_Null());
  } else if (ret == 'f' || ret == 'd') {
    Dart_SetReturnValue(args, Dart_NewDouble(out_d0));
  } else {
    Dart_SetReturnValue(args, Dart_NewInteger(static_cast<int64_t>(rx)));  // 'g'
  }
}

// FFI floor stage B (ST_PORTING_PLAN §3a): raw peek/poke behind the corpus's
// Alien. `a` is an ABSOLUTE address — an int, the way mmap/an FFI call answers
// one. Bounds are checked in Smalltalk (Alien knows its span) BEFORE reaching
// here; a null address is rejected as the commonest segv, anything else past
// the bounds check is the caller's footgun, by design. arm64 permits the
// unaligned f64 access a byte-offset doubleAt: can produce.
void ST_peekByte(Dart_NativeArguments args) {
  int64_t a = 0;
  Dart_IntegerToInt64(Dart_GetNativeArgument(args, 0), &a);
  if (a <= 0) { STThrow("Alien byteAt: bad address"); return; }
  Dart_SetReturnValue(args, Dart_NewInteger(*reinterpret_cast<uint8_t*>(a)));
}
void ST_pokeByte(Dart_NativeArguments args) {
  int64_t a = 0, v = 0;
  Dart_IntegerToInt64(Dart_GetNativeArgument(args, 0), &a);
  Dart_IntegerToInt64(Dart_GetNativeArgument(args, 1), &v);
  if (a <= 0) { STThrow("Alien byteAt:put: bad address"); return; }
  *reinterpret_cast<uint8_t*>(a) = static_cast<uint8_t>(v & 0xff);
  Dart_SetReturnValue(args, Dart_GetNativeArgument(args, 1));
}
void ST_peekF64(Dart_NativeArguments args) {
  int64_t a = 0;
  Dart_IntegerToInt64(Dart_GetNativeArgument(args, 0), &a);
  if (a <= 0) { STThrow("Alien doubleAt: bad address"); return; }
  Dart_SetReturnValue(args, Dart_NewDouble(*reinterpret_cast<double*>(a)));
}
void ST_pokeF64(Dart_NativeArguments args) {
  int64_t a = 0;
  Dart_IntegerToInt64(Dart_GetNativeArgument(args, 0), &a);
  if (a <= 0) { STThrow("Alien doubleAt:put: bad address"); return; }
  double v = 0.0;
  Dart_DoubleValue(Dart_GetNativeArgument(args, 1), &v);
  *reinterpret_cast<double*>(a) = v;
  Dart_SetReturnValue(args, Dart_GetNativeArgument(args, 1));
}
void ST_peekI64(Dart_NativeArguments args) {
  int64_t a = 0;
  Dart_IntegerToInt64(Dart_GetNativeArgument(args, 0), &a);
  if (a <= 0) { STThrow("Alien signedLongAt: bad address"); return; }
  Dart_SetReturnValue(args, Dart_NewInteger(*reinterpret_cast<int64_t*>(a)));
}
void ST_pokeI64(Dart_NativeArguments args) {
  int64_t a = 0, v = 0;
  Dart_IntegerToInt64(Dart_GetNativeArgument(args, 0), &a);
  Dart_IntegerToInt64(Dart_GetNativeArgument(args, 1), &v);
  if (a <= 0) { STThrow("Alien signedLongAt:put: bad address"); return; }
  *reinterpret_cast<int64_t*>(a) = v;
  Dart_SetReturnValue(args, Dart_GetNativeArgument(args, 1));
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
      // A native Character/Symbol carries a dart:cocoa Dart class outside the ST
      // hierarchy; walk from the "X ext" holder it stands in for so `$a isKindOf:
      // Character` (-> Magnitude) and `#s isKindOf: Symbol` (-> String) hold.
      Class& c = Class::Handle(zone);
      const std::string rcn(
          String::Handle(zone, Class::Handle(zone, obj.clazz()).Name())
              .ToCString());
      if (rcn == "StChar") c = ::st::FindStClassByName(thread, "Character ext");
      else if (rcn == "StSymbol") c = ::st::FindStClassByName(thread, "Symbol ext");
      if (c.IsNull()) c = isolate->class_table()->At(obj.GetClassId());
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
    STThrow(err.c_str());
    return;
  }
  Dart_SetReturnValue(args, b_h);
}

// stInstVarAt(obj, i): the world's Object>>instVarAt: — the i-th instance
// variable, 1-BASED, in declaration order with the super chain walked outermost
// first. There was no implementation at all: the world declares it as a bare
// <primitive: 25>, which MACDART ignores, so `c instVarAt: 1` answered the
// object itself. Found by st/test/primitive_coverage.
void ST_instVarAt(Dart_NativeArguments args) {
  Dart_Handle obj_h = Dart_GetNativeArgument(args, 0);
  int64_t idx = 0;
  if (Dart_IsError(Dart_IntegerToInt64(Dart_GetNativeArgument(args, 1), &idx))) {
    STThrow("instVarAt: index must be an Integer");
    return;
  }
  Thread* thread = Thread::Current();
  Dart_Handle result = Dart_Null();
  std::string err;
  {
    TransitionNativeToVM transition(thread);
    HANDLESCOPE(thread);
    Zone* zone = thread->zone();
    const Object& o = Object::Handle(zone, Api::UnwrapHandle(obj_h));
    if (!o.IsInstance()) {
      err = "instVarAt: receiver has no instance variables";
    } else {
      const Instance& inst = Instance::Cast(o);
      // Collect super-first so index 1 is the outermost declared field, which
      // is the order the world's own reflection assumes.
      std::vector<Class*> chain;
      Class& c = Class::Handle(zone, inst.clazz());
      while (!c.IsNull()) {
        chain.push_back(&Class::ZoneHandle(zone, c.raw()));
        c ^= c.SuperClass();
      }
      Array& fields = Array::Handle(zone);
      Field& f = Field::Handle(zone);
      int64_t seen = 0;
      bool found = false;
      for (intptr_t k = static_cast<intptr_t>(chain.size()) - 1; k >= 0 && !found; k--) {
        fields = chain[k]->fields();
        if (fields.IsNull()) continue;
        for (intptr_t i = 0; i < fields.Length(); i++) {
          f ^= fields.At(i);
          if (f.is_static()) continue;
          if (++seen == idx) {
            result = Api::NewHandle(thread, inst.GetField(f));
            found = true;
            break;
          }
        }
      }
      if (!found) err = "instVarAt: index out of range";
    }
  }
  if (!err.empty()) { STThrow(err.c_str()); return; }
  Dart_SetReturnValue(args, result);
}

// stInstVarAtPut(obj, i, v): the store twin of ST_instVarAt (the world's
// <primitive: 24>). Same super-first field walk; sets the i-th instance field
// and answers v. Reflective mutation the corpus had no working path for.
void ST_instVarAtPut(Dart_NativeArguments args) {
  Dart_Handle obj_h = Dart_GetNativeArgument(args, 0);
  Dart_Handle val_h = Dart_GetNativeArgument(args, 2);
  int64_t idx = 0;
  if (Dart_IsError(Dart_IntegerToInt64(Dart_GetNativeArgument(args, 1), &idx))) {
    STThrow("instVarAt:put: index must be an Integer");
    return;
  }
  Thread* thread = Thread::Current();
  std::string err;
  {
    TransitionNativeToVM transition(thread);
    HANDLESCOPE(thread);
    Zone* zone = thread->zone();
    const Object& o = Object::Handle(zone, Api::UnwrapHandle(obj_h));
    const Object& v = Object::Handle(zone, Api::UnwrapHandle(val_h));
    if (!o.IsInstance()) {
      err = "instVarAt:put: receiver has no instance variables";
    } else {
      const Instance& inst = Instance::Cast(o);
      std::vector<Class*> chain;
      Class& c = Class::Handle(zone, inst.clazz());
      while (!c.IsNull()) {
        chain.push_back(&Class::ZoneHandle(zone, c.raw()));
        c ^= c.SuperClass();
      }
      Array& fields = Array::Handle(zone);
      Field& f = Field::Handle(zone);
      int64_t seen = 0;
      bool found = false;
      for (intptr_t k = static_cast<intptr_t>(chain.size()) - 1; k >= 0 && !found; k--) {
        fields = chain[k]->fields();
        if (fields.IsNull()) continue;
        for (intptr_t i = 0; i < fields.Length(); i++) {
          f ^= fields.At(i);
          if (f.is_static()) continue;
          if (++seen == idx) {
            inst.SetField(f, v.IsNull() ? Object::null_instance() : Instance::Cast(v));
            found = true;
            break;
          }
        }
      }
      if (!found) err = "instVarAt:put: index out of range";
    }
  }
  if (!err.empty()) { STThrow(err.c_str()); return; }
  Dart_SetReturnValue(args, val_h);   // answers the stored value
}


// --- class reflection (ST_PORTING_PLAN M5: ClassMirror / browseSnapshot) -----
// MACVM read a class's name/super/selectors/ivars from the class OBJECT's own
// layout (instVarAt: KLASS_*_INDEX). MACDART classes are Dart Types, so these
// answer through the VM's real Class API instead. A MACDART overlay
// (76_reflection.mst) reopens Behavior>>name/superclass and ClassMirror's
// class-side primitives to <stprim:> onto these.

// The dart::Class behind a class-VALUE argument at index i (a Type), or null.
static RawClass* StClassArg(Thread* thread, Dart_NativeArguments args, int i) {
  Zone* zone = thread->zone();
  const Object& o =
      Object::Handle(zone, Api::UnwrapHandle(Dart_GetNativeArgument(args, i)));
  if (!o.IsType()) return Class::null();
  return Type::Cast(o).type_class();
}

// Selector spelling from a mangled VM function name ('_' -> ':'): ST selectors
// carry no literal underscores, so this inverts MangleSelector cleanly.
static std::string UnmangleSelector(const std::string& m) {
  std::string s = m;
  for (size_t i = 0; i < s.size(); i++)
    if (s[i] == '_') s[i] = ':';
  return s;
}

static bool IsMetaclassName(const char* n) {
  const size_t len = strlen(n);
  return len >= 6 && strcmp(n + len - 6, " class") == 0;
}

// `aClass name` — the class's name as a String.
void ST_classNameOf(Dart_NativeArguments args) {
  Thread* thread = Thread::Current();
  Dart_Handle result = Dart_Null();
  {
    TransitionNativeToVM transition(thread);
    HANDLESCOPE(thread);
    Zone* zone = thread->zone();
    const Class& cls = Class::Handle(zone, StClassArg(thread, args, 0));
    if (!cls.IsNull()) {
      // Strip the bridged-holder suffix so the browser shows "Object", not
      // "Object ext" (the holder IS the class — no ambiguity).
      std::string nm(String::Handle(zone, cls.Name()).ToCString());
      const size_t n = nm.size();
      if (n >= 4 && nm.compare(n - 4, 4, " ext") == 0) nm.erase(n - 4);
      result = Api::NewHandle(thread, String::New(nm.c_str(), Heap::kNew));
    }
  }
  Dart_SetReturnValue(args, result);
}

// `aClass superclass` — the superclass VALUE (a Type), or nil at the root.
void ST_superclassOf(Dart_NativeArguments args) {
  Thread* thread = Thread::Current();
  Dart_Handle result = Dart_Null();
  {
    TransitionNativeToVM transition(thread);
    HANDLESCOPE(thread);
    Zone* zone = thread->zone();
    const Class& cls = Class::Handle(zone, StClassArg(thread, args, 0));
    if (!cls.IsNull()) {
      const Class& sup = Class::Handle(zone, cls.SuperClass());
      // The ST hierarchy roots at Object; its Dart super is the bridge root
      // (named "?") or dart:core Object (ResolveSuper bridges `nil subclass:
      // Object` there). Report either as nil — ST's `Object superclass` is nil,
      // not a stray root class.
      if (!sup.IsNull()) {
        std::string nm(String::Handle(zone, sup.Name()).ToCString());
        const size_t n = nm.size();
        if (n >= 4 && nm.compare(n - 4, 4, " ext") == 0) nm.erase(n - 4);
        const Class& core = Class::Handle(
            zone, Type::Handle(zone, Type::ObjectType()).type_class());
        if (nm != "?" && sup.raw() != core.raw())
          result = Api::NewHandle(thread, Type::NewNonParameterizedType(sup));
      }
    }
  }
  Dart_SetReturnValue(args, result);
}

// allClasses — every ST class (instance side; the "Foo class" metaclasses are
// skipped) as a List of class Types, for ClassMirror's subclass sweep.
void ST_allClasses(Dart_NativeArguments args) {
  Thread* thread = Thread::Current();
  Dart_Handle result = Dart_Null();
  {
    TransitionNativeToVM transition(thread);
    HANDLESCOPE(thread);
    Zone* zone = thread->zone();
    Isolate* isolate = thread->isolate();
    const GrowableObjectArray& out =
        GrowableObjectArray::Handle(zone, GrowableObjectArray::New(Heap::kOld));
    const GrowableObjectArray& libs = GrowableObjectArray::Handle(
        zone, isolate->object_store()->libraries());
    Library& lib = Library::Handle(zone);
    String& url = String::Handle(zone);
    String& cname = String::Handle(zone);
    Class& cls = Class::Handle(zone);
    for (intptr_t i = 0; i < libs.Length(); i++) {
      lib ^= libs.At(i);
      url = lib.url();
      if (url.IsNull() || strncmp(url.ToCString(), "st:", 3) != 0) continue;
      DictionaryIterator it(lib);
      while (it.HasNext()) {
        const Object& entry = Object::Handle(zone, it.GetNext());
        if (!entry.IsClass()) continue;
        cls ^= entry.raw();
        cname = cls.Name();
        if (IsMetaclassName(cname.ToCString())) continue;
        out.Add(Type::Handle(zone, Type::NewNonParameterizedType(cls)));
      }
    }
    result = Api::NewHandle(thread, out.raw());
  }
  Dart_SetReturnValue(args, result);
}

// selectorsOf: aBehavior — the behavior's OWN instance selectors (un-mangled),
// as a List of Strings (the browser asStrings them; ClassMirror sorts them).
void ST_selectorsOf(Dart_NativeArguments args) {
  Thread* thread = Thread::Current();
  Dart_Handle result = Dart_Null();
  {
    TransitionNativeToVM transition(thread);
    HANDLESCOPE(thread);
    Zone* zone = thread->zone();
    const Class& cls = Class::Handle(zone, StClassArg(thread, args, 0));
    const GrowableObjectArray& out =
        GrowableObjectArray::Handle(zone, GrowableObjectArray::New(Heap::kOld));
    if (!cls.IsNull()) {
      const Array& fns = Array::Handle(zone, cls.functions());
      Function& f = Function::Handle(zone);
      String& nm = String::Handle(zone);
      if (!fns.IsNull()) {
        for (intptr_t i = 0; i < fns.Length(); i++) {
          f ^= fns.At(i);
          if (f.IsNull()) continue;
          nm = f.name();
          const std::string sel = UnmangleSelector(nm.ToCString());
          out.Add(String::Handle(zone, String::New(sel.c_str(), Heap::kNew)));
        }
      }
    }
    result = Api::NewHandle(thread, out.raw());
  }
  Dart_SetReturnValue(args, result);
}

// The own variable names of a class as a List of Strings; `want_static` picks
// class variables (static Fields) vs instance variables.
static void FieldNames(Dart_NativeArguments args, bool want_static) {
  Thread* thread = Thread::Current();
  Dart_Handle result = Dart_Null();
  {
    TransitionNativeToVM transition(thread);
    HANDLESCOPE(thread);
    Zone* zone = thread->zone();
    const Class& cls = Class::Handle(zone, StClassArg(thread, args, 0));
    const GrowableObjectArray& out =
        GrowableObjectArray::Handle(zone, GrowableObjectArray::New(Heap::kOld));
    if (!cls.IsNull()) {
      const Array& flds = Array::Handle(zone, cls.fields());
      Field& fld = Field::Handle(zone);
      String& nm = String::Handle(zone);
      if (!flds.IsNull()) {
        for (intptr_t i = 0; i < flds.Length(); i++) {
          fld ^= flds.At(i);
          if (fld.IsNull() || fld.is_static() != want_static) continue;
          nm = fld.name();
          out.Add(String::Handle(zone, String::New(nm.ToCString(), Heap::kNew)));
        }
      }
    }
    result = Api::NewHandle(thread, out.raw());
  }
  Dart_SetReturnValue(args, result);
}
void ST_instVarNamesOf(Dart_NativeArguments args) { FieldNames(args, false); }
void ST_classVarNamesOf(Dart_NativeArguments args) { FieldNames(args, true); }

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
    STThrow(err.c_str());
    return;
  }
  Dart_SetReturnValue(args, Dart_Null());
}

// stShallowCopy(obj): a fresh instance of the same class with every field
// copied — the working `shallowCopy` the world's <primitive: 247> body only
// pretended to be (it fell through to `^self`, so `x copy` ALIASED x: mutating
// an OrderedCollection copy also changed the original). The Dart helper handles
// the native/immutable receivers (String -> a mutable copy, List/Map -> a
// fresh container, Symbol/Character/Boolean/nil -> self); only a plain ST
// instance reaches here. A non-instance (should not happen) answers itself.
void ST_shallowCopy(Dart_NativeArguments args) {
  Dart_Handle obj_h = Dart_GetNativeArgument(args, 0);
  Thread* thread = Thread::Current();
  Dart_Handle result = obj_h;
  {
    TransitionNativeToVM transition(thread);
    HANDLESCOPE(thread);
    Zone* zone = thread->zone();
    const Object& obj = Object::Handle(zone, Api::UnwrapHandle(obj_h));
    if (obj.IsInstance() && !obj.IsNull()) {
      const Instance& copy =
          Instance::Handle(zone, ShallowCopy(thread, Instance::Cast(obj)));
      result = Api::NewHandle(thread, copy.raw());
    }
  }
  Dart_SetReturnValue(args, result);
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
