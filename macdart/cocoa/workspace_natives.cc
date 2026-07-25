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

}  // namespace bin
}  // namespace dart
