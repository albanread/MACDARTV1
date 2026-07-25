// MACDART dart:cocoa — reverse callbacks (Phase 6) + the syntax-highlight span
// applier. AppKit target-action and delegates must call *into* Dart. We register
// a small ObjC class at runtime whose method IMPs are C trampolines that invoke a
// Dart dispatch closure on the UI isolate. Per MACVM's model: never store a Dart
// handle ObjC-side — a global instance→ticket map holds an integer ticket; the
// Dart receiver lives in a GC-rooted Map keyed by that ticket. Fail closed on an
// unknown instance.
//
// Runs on thread 0 (AppKit's thread), where the UI isolate is entered — so the
// IMP can Dart_InvokeClosure directly. Compiled MRC (-fno-objc-arc). See
// WORKSPACE_PLAN.md §4/§7.
#import <Cocoa/Cocoa.h>

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

// Common trampoline: resolve self's ticket and invoke the Dart dispatcher with
// (ticket, sender). On thread 0 with the UI isolate current.
static void DispatchTicket(id self, id sender) {
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

// -(void)macdartInvoke:(id)sender     — target-action (buttons, menu items).
static void ActionIMP(id self, SEL _cmd, id sender) {
  (void)_cmd;
  DispatchTicket(self, sender);
}

// -(void)textDidChange:(NSNotification*)note  — NSText/NSTextView delegate.
static void TextDidChangeIMP(id self, SEL _cmd, id note) {
  (void)_cmd;
  DispatchTicket(self, note);
}

static void EnsureActionClass() {
  if (g_action_class != nil) return;
  g_action_class =
      objc_allocateClassPair([NSObject class], "MacdartActionTarget", 0);
  class_addMethod(g_action_class, sel_registerName("macdartInvoke:"),
                  (IMP)ActionIMP, "v@:@");
  class_addMethod(g_action_class, sel_registerName("textDidChange:"),
                  (IMP)TextDidChangeIMP, "v@:@");
  objc_registerClassPair(g_action_class);
}

// _registerCocoaDispatch(Function f) — store the Dart dispatcher (called once).
void Cocoa_registerCallbackDispatch(Dart_NativeArguments args) {
  Dart_Handle closure = Dart_GetNativeArgument(args, 0);
  if (g_dispatch != NULL) Dart_DeletePersistentHandle(g_dispatch);
  g_dispatch = Dart_NewPersistentHandle(closure);
}

// _makeActionTarget(int ticket) -> id handle. The returned target is deliberately
// never released (AppKit holds targets/delegates weakly; UI targets live for the
// app).
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

// --- Syntax highlighting: batched attribute application ----------------------
// Colour per token kind (appearance-adaptive system colours; light & dark).
static NSColor* ColorForKind(int64_t kind) {
  switch (kind) {
    case 1: return [NSColor systemPurpleColor];  // keyword
    case 2: return [NSColor systemRedColor];      // string
    case 3: return [NSColor systemGreenColor];    // comment
    case 4: return [NSColor systemBlueColor];     // number
    case 5: return [NSColor systemTealColor];     // type (Capitalized ident)
    default: return [NSColor textColor];          // identifier / other
  }
}

// _applySpans(int textStorage, List<int> runs): runs is a flat
// [start,len,kind, start,len,kind, ...]. Resets the whole range to the base
// colour, then colours each run — attribute-only (the caret never moves), inside
// one begin/end batch. This is the ONE native worth keeping for the highlighter
// (avoids N bridge round-trips per keystroke).
void Cocoa_applySpans(Dart_NativeArguments args) {
  int64_t tsh = 0;
  Dart_IntegerToInt64(Dart_GetNativeArgument(args, 0), &tsh);
  NSTextStorage* ts = (NSTextStorage*)(id)tsh;
  Dart_Handle runs = Dart_GetNativeArgument(args, 1);
  intptr_t n = 0;
  Dart_ListLength(runs, &n);

  NSUInteger len = [ts length];
  [ts beginEditing];
  [ts addAttribute:NSForegroundColorAttributeName
             value:ColorForKind(0)
             range:NSMakeRange(0, len)];
  for (intptr_t i = 0; i + 2 < n; i += 3) {
    int64_t start = 0, rlen = 0, kind = 0;
    Dart_IntegerToInt64(Dart_ListGetAt(runs, i), &start);
    Dart_IntegerToInt64(Dart_ListGetAt(runs, i + 1), &rlen);
    Dart_IntegerToInt64(Dart_ListGetAt(runs, i + 2), &kind);
    if (start < 0 || rlen <= 0 ||
        (NSUInteger)(start + rlen) > len) {
      continue;  // stale offsets (text changed under us) — skip, never crash
    }
    [ts addAttribute:NSForegroundColorAttributeName
               value:ColorForKind(kind)
               range:NSMakeRange((NSUInteger)start, (NSUInteger)rlen)];
  }
  [ts endEditing];
}

}  // namespace bin
}  // namespace dart
