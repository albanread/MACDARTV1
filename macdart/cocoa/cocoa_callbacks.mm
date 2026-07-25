// MACDART dart:cocoa — reverse callbacks (Phase 6). AppKit target-action and
// delegates must call *into* Dart. We register a small ObjC class at runtime
// whose method IMPs are C trampolines that invoke a Dart dispatch closure on the
// UI isolate. Per MACVM's model: never store a Dart handle ObjC-side — a global
// instance→ticket map holds an integer ticket; the Dart receiver lives in a
// GC-rooted Map keyed by that ticket. Fail closed on an unknown instance.
//
// Runs on thread 0 (AppKit's thread), where the UI isolate is entered — so the
// IMP can Dart_InvokeClosure directly. Compiled MRC (-fno-objc-arc). See
// WORKSPACE_PLAN.md §7.
#import <Foundation/Foundation.h>

#include <objc/message.h>
#include <objc/runtime.h>
#include <mutex>
#include <stdio.h>
#include <unordered_map>

#include "include/dart_api.h"

namespace dart {
namespace bin {

// Dart closure `void _cocoaDispatch(int ticket, int sender)` — the single entry
// every callback funnels through. Persistent handle owned by the UI isolate.
static Dart_PersistentHandle g_dispatch = NULL;
static std::unordered_map<void*, int64_t> g_ticket_of;  // instance ptr -> ticket
static std::mutex g_mu;
static Class g_action_class = nil;

// IMP for -(void)macdartInvoke:(id)sender  (@encode "v@:@"). On thread 0 with
// the UI isolate current: resolve self's ticket and invoke the Dart dispatcher.
static void ActionIMP(id self, SEL _cmd, id sender) {
  (void)_cmd;
  int64_t ticket = 0;
  {
    std::lock_guard<std::mutex> lock(g_mu);
    std::unordered_map<void*, int64_t>::iterator it = g_ticket_of.find((void*)self);
    if (it == g_ticket_of.end()) return;  // fail closed: unknown instance
    ticket = it->second;
  }
  if (g_dispatch == NULL) return;
  Dart_EnterScope();
  Dart_Handle fn = Dart_HandleFromPersistent(g_dispatch);
  Dart_Handle args[2];
  args[0] = Dart_NewInteger(ticket);
  args[1] = Dart_NewInteger((int64_t)sender);
  Dart_Handle r = Dart_InvokeClosure(fn, 2, args);
  if (Dart_IsError(r)) {
    fprintf(stderr, "dart:cocoa callback error: %s\n", Dart_GetError(r));
  }
  Dart_ExitScope();
}

static void EnsureActionClass() {
  if (g_action_class != nil) return;
  g_action_class =
      objc_allocateClassPair([NSObject class], "MacdartActionTarget", 0);
  class_addMethod(g_action_class, sel_registerName("macdartInvoke:"),
                  (IMP)ActionIMP, "v@:@");
  objc_registerClassPair(g_action_class);
}

// _registerCocoaDispatch(Function f) — store the Dart dispatcher (called once).
void Cocoa_registerCallbackDispatch(Dart_NativeArguments args) {
  Dart_Handle closure = Dart_GetNativeArgument(args, 0);
  if (g_dispatch != NULL) Dart_DeletePersistentHandle(g_dispatch);
  g_dispatch = Dart_NewPersistentHandle(closure);
}

// _makeActionTarget(int ticket) -> id handle. The returned target is deliberately
// never released (AppKit holds targets weakly; UI targets live for the app).
void Cocoa_makeActionTarget(Dart_NativeArguments args) {
  int64_t ticket = 0;
  Dart_IntegerToInt64(Dart_GetNativeArgument(args, 0), &ticket);
  EnsureActionClass();
  id obj = class_createInstance(g_action_class, 0);
  {
    std::lock_guard<std::mutex> lock(g_mu);
    g_ticket_of[(void*)obj] = ticket;
  }
  Dart_SetReturnValue(args, Dart_NewInteger((int64_t)obj));
}

// _wireAction(int control, int target): [control setTarget:target];
// [control setAction:@selector(macdartInvoke:)].
void Cocoa_wireAction(Dart_NativeArguments args) {
  int64_t c = 0, t = 0;
  Dart_IntegerToInt64(Dart_GetNativeArgument(args, 0), &c);
  Dart_IntegerToInt64(Dart_GetNativeArgument(args, 1), &t);
  id control = (id)c;
  id target = (id)t;
  ((void (*)(id, SEL, id))objc_msgSend)(control, sel_registerName("setTarget:"),
                                        target);
  ((void (*)(id, SEL, SEL))objc_msgSend)(
      control, sel_registerName("setAction:"),
      sel_registerName("macdartInvoke:"));
}

}  // namespace bin
}  // namespace dart
