// MACDART dart:cocoa — reverse callbacks (Phase 6) + the syntax-highlight span
// applier. AppKit target-action, text delegates, and NSTableView data sources
// call *into* Dart. We register one ObjC class at runtime whose method IMPs are
// C trampolines that invoke a single Dart dispatch closure on the UI isolate,
// keyed by an integer ticket (never a Dart handle ObjC-side). The data-source
// IMPs marshal Dart's RETURN value back to ObjC (row count / cell string).
//
// Runs on thread 0 (AppKit's thread), where the UI isolate is entered. Compiled
// MRC (-fno-objc-arc). See WORKSPACE_PLAN.md §4/§7.
#import <Cocoa/Cocoa.h>

#include <objc/message.h>
#include <objc/runtime.h>
#include <mutex>
#include <stdio.h>
#include <unordered_map>

#include "include/dart_api.h"

namespace dart {
namespace bin {

// Dart closure `dynamic _cocoaDispatch(int ticket, int kind, int arg)` — every
// callback funnels through it. kind: 0 action, 1 textDidChange, 2 tableRowCount,
// 3 tableValue(arg=row), 4 tableSelect(arg=row). Returns void for 0/1/4, an int
// for 2, a String for 3.
static Dart_PersistentHandle g_dispatch = NULL;
static std::unordered_map<void*, int64_t> g_ticket_of;  // instance ptr -> ticket
static std::mutex g_mu;
static Class g_action_class = nil;

// Invoke the Dart dispatcher; returns the raw result handle (NULL on failure).
// Caller must be inside a Dart scope and marshal the result per kind.
static Dart_Handle Dispatch(id self, int kind, int64_t arg) {
  int64_t ticket = 0;
  {
    std::lock_guard<std::mutex> lock(g_mu);
    std::unordered_map<void*, int64_t>::iterator it = g_ticket_of.find((void*)self);
    if (it == g_ticket_of.end()) return NULL;  // fail closed
    ticket = it->second;
  }
  if (g_dispatch == NULL) return NULL;
  Dart_Handle fn = Dart_HandleFromPersistent(g_dispatch);
  Dart_Handle args[3];
  args[0] = Dart_NewInteger(ticket);
  args[1] = Dart_NewInteger(kind);
  args[2] = Dart_NewInteger(arg);
  return Dart_InvokeClosure(fn, 3, args);
}

// -(void)macdartInvoke:(id)sender     — target-action (buttons, menu items).
static void ActionIMP(id self, SEL _cmd, id sender) {
  (void)_cmd;
  Dart_EnterScope();
  Dart_Handle r = Dispatch(self, 0, (int64_t)sender);
  if (r != NULL && Dart_IsError(r)) fprintf(stderr, "dart:cocoa callback: %s\n", Dart_GetError(r));
  Dart_ExitScope();
}

// -(void)textDidChange:(NSNotification*)note  — NSText/NSTextView delegate.
static void TextDidChangeIMP(id self, SEL _cmd, id note) {
  (void)_cmd;
  Dart_EnterScope();
  Dispatch(self, 1, (int64_t)note);
  Dart_ExitScope();
}

// -(NSInteger)numberOfRowsInTableView:(NSTableView*)tv   [q@:@]
static NSInteger NumRowsIMP(id self, SEL _cmd, id tv) {
  (void)_cmd; (void)tv;
  Dart_EnterScope();
  Dart_Handle r = Dispatch(self, 2, 0);
  int64_t n = 0;
  if (r != NULL && !Dart_IsError(r)) Dart_IntegerToInt64(r, &n);
  Dart_ExitScope();
  return (NSInteger)n;
}

// -(id)tableView:(NSTableView*)tv objectValueForTableColumn:(id)col row:(NSInteger)row  [@@:@@q]
static id ObjectValueIMP(id self, SEL _cmd, id tv, id col, NSInteger row) {
  (void)_cmd; (void)tv; (void)col;
  Dart_EnterScope();
  Dart_Handle r = Dispatch(self, 3, (int64_t)row);
  id s = @"";
  if (r != NULL && !Dart_IsError(r)) {
    const char* c = NULL;
    if (!Dart_IsError(Dart_StringToCString(r, &c)) && c != NULL) {
      s = [NSString stringWithUTF8String:c];
    }
  }
  Dart_ExitScope();
  return s;
}

// -(void)tableViewSelectionDidChange:(NSNotification*)note  — table delegate.
static void SelectionChangedIMP(id self, SEL _cmd, id note) {
  (void)_cmd;
  id tv = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("object"));
  NSInteger row = ((NSInteger (*)(id, SEL))objc_msgSend)(tv, sel_registerName("selectedRow"));
  Dart_EnterScope();
  Dispatch(self, 4, (int64_t)row);
  Dart_ExitScope();
}

static void EnsureActionClass() {
  if (g_action_class != nil) return;
  g_action_class = objc_allocateClassPair([NSObject class], "MacdartActionTarget", 0);
  class_addMethod(g_action_class, sel_registerName("macdartInvoke:"), (IMP)ActionIMP, "v@:@");
  class_addMethod(g_action_class, sel_registerName("textDidChange:"), (IMP)TextDidChangeIMP, "v@:@");
  class_addMethod(g_action_class, sel_registerName("numberOfRowsInTableView:"), (IMP)NumRowsIMP, "q@:@");
  class_addMethod(g_action_class, sel_registerName("tableView:objectValueForTableColumn:row:"), (IMP)ObjectValueIMP, "@@:@@q");
  class_addMethod(g_action_class, sel_registerName("tableViewSelectionDidChange:"), (IMP)SelectionChangedIMP, "v@:@");
  objc_registerClassPair(g_action_class);
}

// _registerCocoaDispatch(Function f) — store the Dart dispatcher (called once).
void Cocoa_registerCallbackDispatch(Dart_NativeArguments args) {
  Dart_Handle closure = Dart_GetNativeArgument(args, 0);
  if (g_dispatch != NULL) Dart_DeletePersistentHandle(g_dispatch);
  g_dispatch = Dart_NewPersistentHandle(closure);
}

// _makeActionTarget(int ticket) -> id handle. The target is deliberately never
// released (AppKit holds targets/delegates/data-sources weakly; UI targets live
// for the app).
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
  ((void (*)(id, SEL, id))objc_msgSend)(control, sel_registerName("setTarget:"), target);
  ((void (*)(id, SEL, SEL))objc_msgSend)(control, sel_registerName("setAction:"), sel_registerName("macdartInvoke:"));
}

// --- Syntax highlighting: batched attribute application ----------------------
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

// _applySpans(int textStorage, List<int> runs): flat [start,len,kind, ...].
void Cocoa_applySpans(Dart_NativeArguments args) {
  int64_t tsh = 0;
  Dart_IntegerToInt64(Dart_GetNativeArgument(args, 0), &tsh);
  NSTextStorage* ts = (NSTextStorage*)(id)tsh;
  Dart_Handle runs = Dart_GetNativeArgument(args, 1);
  intptr_t n = 0;
  Dart_ListLength(runs, &n);

  NSUInteger len = [ts length];
  [ts beginEditing];
  [ts addAttribute:NSForegroundColorAttributeName value:ColorForKind(0) range:NSMakeRange(0, len)];
  for (intptr_t i = 0; i + 2 < n; i += 3) {
    int64_t start = 0, rlen = 0, kind = 0;
    Dart_IntegerToInt64(Dart_ListGetAt(runs, i), &start);
    Dart_IntegerToInt64(Dart_ListGetAt(runs, i + 1), &rlen);
    Dart_IntegerToInt64(Dart_ListGetAt(runs, i + 2), &kind);
    if (start < 0 || rlen <= 0 || (NSUInteger)(start + rlen) > len) continue;
    [ts addAttribute:NSForegroundColorAttributeName value:ColorForKind(kind)
               range:NSMakeRange((NSUInteger)start, (NSUInteger)rlen)];
  }
  [ts endEditing];
}

}  // namespace bin
}  // namespace dart
