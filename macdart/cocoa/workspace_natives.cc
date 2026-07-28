// MACDART workspace runtime natives — the two irreducible eval primitives for
// the live workspace (see WORKSPACE_PLAN.md §5). These run on the LANGUAGE
// isolate and reach embedder services the Dart API doesn't otherwise expose:
//   Workspace_eval   — Dart_EvaluateExpr: run one expression against live state.
//   Workspace_reload — (next) Isolate::ReloadSources: hot-reload a library.
// Registered via the dart:cocoa resolver for now (declared extern there); they
// will move to a dedicated dart:workspace library.
#include <stdio.h>
#include <string.h>

#include "include/dart_api.h"
#include "include/dart_tools_api.h"

// Implemented by the GUI host (macdart/cocoa/cocoa_host.mm), which is linked
// only into `dartui`. Every other binary (dart, gen_snapshot, dart_bootstrap)
// still pulls this object via the dart:cocoa native resolver table, so it needs
// SOME definition to link — these WEAK no-op fallbacks. In dartui the host's
// strong definitions override them; nowhere else is the UI-reload path ever
// reached, so the fallbacks are inert.
extern "C" __attribute__((weak)) void macdart_request_ui_reload(void) {}
extern "C" __attribute__((weak)) void macdart_ui_ready(void) {}
extern "C" __attribute__((weak)) const char* macdart_take_ui_reload_status(void) {
  return "";
}

namespace dart {
namespace bin {

// wsEval(String src) -> String. Evaluates `src` as an expression in the scope of
// the current root library (later: the workspace scratch library), returning the
// result's toString(). On a compile or runtime error, returns an "ERR: <msg>"
// STRING rather than throwing — the workspace decides what to do (e.g. a compile
// error means "treat as a declaration and hot-reload instead").
//
// Note: Dart_EvaluateExpr compiles `src` as `(…) => src`, i.e. a single
// expression. Wrap multi-statement do-its as an immediately-invoked closure
// `(){ … }()` on the Dart side.
void Workspace_eval(Dart_NativeArguments args) {
  Dart_Handle src = Dart_GetNativeArgument(args, 0);
  Dart_Handle lib = Dart_RootLibrary();

  Dart_Handle result = Dart_EvaluateExpr(lib, src);
  if (Dart_IsError(result)) {
    char buf[1024];
    snprintf(buf, sizeof(buf), "ERR: %s", Dart_GetError(result));
    Dart_SetReturnValue(args, Dart_NewStringFromCString(buf));
    return;
  }

  // Stringify the value. toString() itself may throw — report that too.
  Dart_Handle str = Dart_ToString(result);
  if (Dart_IsError(str)) {
    char buf[1024];
    snprintf(buf, sizeof(buf), "ERR: toString: %s", Dart_GetError(str));
    Dart_SetReturnValue(args, Dart_NewStringFromCString(buf));
    return;
  }
  const char* c = NULL;
  Dart_StringToCString(str, &c);
  Dart_SetReturnValue(args, Dart_NewStringFromCString(c != NULL ? c : "null"));
}

// wsReload() -> String. Hot-reloads the language isolate's sources: re-reads the
// root scratch file (which the workspace has just rewritten with the new/changed
// declaration), recompiles, and MORPHS live instances to the new class shape —
// existing objects keep same-named fields and gain new ones. Returns "" on
// success, or "ERR: <reason>" if the reload was cancelled (an unsafe structural
// change), at which point the workspace restarts the isolate. This is the piece
// MACVM lacks (no `become`): a structural class change stays live here.
void Workspace_reload(Dart_NativeArguments args) {
  Dart_Handle r = Dart_WorkspaceReloadSources(true /* force_reload */);
  if (Dart_IsError(r)) {
    char buf[1024];
    snprintf(buf, sizeof(buf), "ERR: %s", Dart_GetError(r));
    Dart_SetReturnValue(args, Dart_NewStringFromCString(buf));
    return;
  }
  Dart_SetReturnValue(args, Dart_NewStringFromCString(""));
}

// wsVmStats() -> List<int>. This isolate's live VM counters for the workspace
// toolbar — heap used/capacity, GC collection counts, and (only when the VM ran
// with --compiler_stats) functions compiled/optimized and generated code bytes.
// Layout and caveats: dart_tools_api.h. Nothing here is estimated: a counter the
// VM cannot answer comes back 0, so the toolbar can say so rather than showing a
// number that looks measured but isn't.
void Workspace_vmStats(Dart_NativeArguments args) {
  int64_t v[kDartWorkspaceVmStatCount];
  Dart_Handle err = Dart_WorkspaceVmStats(v, kDartWorkspaceVmStatCount);
  if (Dart_IsError(err)) {
    Dart_SetReturnValue(args, err);
    return;
  }
  Dart_Handle list = Dart_NewList(kDartWorkspaceVmStatCount);
  if (Dart_IsError(list)) {
    Dart_SetReturnValue(args, list);
    return;
  }
  for (intptr_t i = 0; i < kDartWorkspaceVmStatCount; i++) {
    Dart_ListSetAt(list, i, Dart_NewInteger(v[i]));
  }
  Dart_SetReturnValue(args, list);
}

// wsRequestUiReload(): ask the HOST to hot-reload the UI isolate.
// Deliberately indirect. The UI isolate cannot reload itself from its own stack
// — it would be replacing the code it is standing in, while AppKit holds its
// closures. This raises a flag and returns; cocoa_host.mm performs the reload at
// the top of the pump, once Dart is off the stack. Only meaningful in dartui.
void Workspace_requestUiReload(Dart_NativeArguments args) {
  macdart_request_ui_reload();
  Dart_SetReturnValue(args, Dart_NewStringFromCString(""));
}

// wsUiReady(): the window is up. Until this is called, the host treats any UI
// isolate error as fatal rather than leaving a process with no window.
void Workspace_uiReady(Dart_NativeArguments args) {
  macdart_ui_ready();
  Dart_SetReturnValue(args, Dart_NewStringFromCString(""));
}

// wsUiReloadStatus() -> "" | "ok" | "ERR: ...". Takes (and clears) the outcome
// of the last host-driven reload, so the UI can report it on its next tick
// without the host having to call back into Dart.
void Workspace_uiReloadStatus(Dart_NativeArguments args) {
  const char* s = macdart_take_ui_reload_status();
  Dart_SetReturnValue(args, Dart_NewStringFromCString(s != NULL ? s : ""));
}

}  // namespace bin
}  // namespace dart
