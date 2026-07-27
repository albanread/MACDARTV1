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
static std::unordered_map<void*, double> g_split_min;  // split view -> min pane size

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
//
// The handler is handed the CONTROL that changed, not the notification. It used
// to get the notification, which looks the same from Dart until you send it
// -stringValue: an unknown selector aborts the process, so a field whose
// handler read its own text was a latent crash. [note object] is the sender, so
// this now matches the action callback's contract.
static void TextDidChangeIMP(id self, SEL _cmd, id note) {
  (void)_cmd;
  id sender = note;
  if (note != nil && [note respondsToSelector:@selector(object)]) sender = [note object];
  Dart_EnterScope();
  Dispatch(self, 1, (int64_t)sender);
  Dart_ExitScope();
}

// -(void)controlTextDidChange:(NSNotification*)note — the NSControl half of the
// same idea. An NSTextField is NOT an NSTextView: it never sends
// textDidChange: to its delegate, so a search box wired with onTextChange sat
// there doing nothing while every keystroke went unheard.
static void ControlTextDidChangeIMP(id self, SEL _cmd, id note) {
  TextDidChangeIMP(self, _cmd, note);
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

// NSSplitView delegate: keep every pane at least g_split_min points.
// Deliberately implemented in ObjC rather than dispatched into Dart — AppKit
// calls these continuously while a divider is dragged, and a Dart_InvokeClosure
// per frame would make dragging lurch.
static double SplitMinFor(id sv) {
  std::lock_guard<std::mutex> lock(g_mu);
  std::unordered_map<void*, double>::iterator it = g_split_min.find((void*)sv);
  return (it == g_split_min.end()) ? 0.0 : it->second;
}

// The lowest position divider `idx` may take: every pane before it at minimum.
static CGFloat ConstrainMinIMP(id self, SEL _cmd, id sv, CGFloat proposed,
                               NSInteger idx) {
  (void)self; (void)_cmd;
  double m = SplitMinFor(sv);
  if (m <= 0.0) return proposed;
  CGFloat t = [(NSSplitView*)sv dividerThickness];
  CGFloat want = (CGFloat)((idx + 1) * m) + (CGFloat)(idx * t);
  return proposed > want ? proposed : want;
}

// The highest position divider `idx` may take: every pane after it at minimum.
static CGFloat ConstrainMaxIMP(id self, SEL _cmd, id sv, CGFloat proposed,
                               NSInteger idx) {
  (void)self; (void)_cmd;
  double m = SplitMinFor(sv);
  if (m <= 0.0) return proposed;
  NSSplitView* s = (NSSplitView*)sv;
  NSInteger n = (NSInteger)[[s subviews] count];
  CGFloat t = [s dividerThickness];
  CGFloat len = [s isVertical] ? [s bounds].size.width : [s bounds].size.height;
  CGFloat tail = (CGFloat)(n - 1 - idx);
  CGFloat want = len - tail * (CGFloat)m - tail * t;
  return proposed < want ? proposed : want;
}

static void EnsureActionClass() {
  if (g_action_class != nil) return;
  g_action_class = objc_allocateClassPair([NSObject class], "MacdartActionTarget", 0);
  class_addMethod(g_action_class, sel_registerName("macdartInvoke:"), (IMP)ActionIMP, "v@:@");
  class_addMethod(g_action_class, sel_registerName("textDidChange:"), (IMP)TextDidChangeIMP, "v@:@");
  class_addMethod(g_action_class, sel_registerName("controlTextDidChange:"),
                  (IMP)ControlTextDidChangeIMP, "v@:@");
  class_addMethod(g_action_class, sel_registerName("numberOfRowsInTableView:"), (IMP)NumRowsIMP, "q@:@");
  class_addMethod(g_action_class, sel_registerName("tableView:objectValueForTableColumn:row:"), (IMP)ObjectValueIMP, "@@:@@q");
  class_addMethod(g_action_class, sel_registerName("tableViewSelectionDidChange:"), (IMP)SelectionChangedIMP, "v@:@");
  class_addMethod(g_action_class,
                  sel_registerName("splitView:constrainMinCoordinate:ofSubviewAt:"),
                  (IMP)ConstrainMinIMP, "d40@0:8@16d24q32");
  class_addMethod(g_action_class,
                  sel_registerName("splitView:constrainMaxCoordinate:ofSubviewAt:"),
                  (IMP)ConstrainMaxIMP, "d40@0:8@16d24q32");
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

// _setSelectorAction(int control, String selectorName, int target)
// Point a control (here: an NSMenuItem) at a STANDARD ObjC selector by name,
// with an arbitrary target — target 0 meaning nil, which is what makes AppKit
// dispatch the action down the RESPONDER CHAIN. That is the only way Cut/Copy/
// Paste/Undo reach whichever NSTextView currently has focus. It has to live here
// because a SEL cannot be manufactured from Dart: cocoa_abi.cc maps the ':'
// encoding onto a pointer and the bridge would hand across an NSString.
void Cocoa_setSelectorAction(Dart_NativeArguments args) {
  int64_t c = 0, t = 0;
  Dart_IntegerToInt64(Dart_GetNativeArgument(args, 0), &c);
  Dart_IntegerToInt64(Dart_GetNativeArgument(args, 2), &t);
  const char* name = NULL;
  Dart_Handle sname = Dart_GetNativeArgument(args, 1);
  if (Dart_IsError(Dart_StringToCString(sname, &name)) || name == NULL) return;
  ((void (*)(id, SEL, id))objc_msgSend)((id)c, sel_registerName("setTarget:"),
                                        (id)t);
  ((void (*)(id, SEL, SEL))objc_msgSend)((id)c, sel_registerName("setAction:"),
                                         sel_registerName(name));
}

// _setSplitMinSize(int splitView, double minSize): stop the user dragging any
// pane of `splitView` below `minSize` points. Installs a delegate that answers
// AppKit's constrain callbacks natively.
void Cocoa_setSplitMinSize(Dart_NativeArguments args) {
  int64_t h = 0;
  double m = 0.0;
  Dart_IntegerToInt64(Dart_GetNativeArgument(args, 0), &h);
  Dart_DoubleValue(Dart_GetNativeArgument(args, 1), &m);
  id sv = (id)h;
  if (sv == nil) return;
  EnsureActionClass();
  {
    std::lock_guard<std::mutex> lock(g_mu);
    g_split_min[(void*)sv] = m;
  }
  // A delegate with no ticket: only the split-view callbacks above will fire on
  // it, and Dispatch() fails closed for everything else.
  id del = class_createInstance(g_action_class, 0);
  ((void (*)(id, SEL, id))objc_msgSend)(sv, sel_registerName("setDelegate:"), del);
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

// --- gamestate key poller ----------------------------------------------------
// Interactive demos need to know which keys are DOWN at frame time — a poller,
// not an event stream: games read state once per frame (the UI ships it with
// each pull tick), and no event queue can back up. One NSEvent local monitor
// records key transitions into a bitset with NO Dart round-trip per event; the
// UI isolate polls Cocoa_keyState when it invites a frame. While `capture` is
// on (a demo running on the Demos tab), non-Command key events are swallowed so
// the game's keys neither beep nor type into the workspace; Cmd shortcuts
// (quit, tabs) stay live. Everything here runs on thread 0: the monitor fires
// on the main thread and the natives are called by the UI isolate.
static bool g_keys_down[128];      // virtual keycode -> currently held
static uint64_t g_key_mods = 0;    // NSEvent modifierFlags as last seen
static bool g_key_capture = false;
static id g_key_monitor = nil;

void Cocoa_keyWatch(Dart_NativeArguments args) {
  if (g_key_monitor != nil) return;
  g_key_monitor = [[NSEvent
      addLocalMonitorForEventsMatchingMask:(NSEventMaskKeyDown |
                                            NSEventMaskKeyUp |
                                            NSEventMaskFlagsChanged)
      handler:^NSEvent*(NSEvent* e) {
        NSEventType ty = [e type];
        if (ty == NSEventTypeFlagsChanged) {
          g_key_mods = (uint64_t)[e modifierFlags];
          return e;                          // modifiers always pass through
        }
        unsigned short kc = [e keyCode];
        if (kc < 128) g_keys_down[kc] = (ty == NSEventTypeKeyDown);
        if (g_key_capture &&
            !([e modifierFlags] & NSEventModifierFlagCommand)) {
          return nil;                        // consumed by the game
        }
        return e;
      }] retain];
}

void Cocoa_keyCapture(Dart_NativeArguments args) {
  int64_t on = 0;
  Dart_IntegerToInt64(Dart_GetNativeArgument(args, 0), &on);
  g_key_capture = (on != 0);
  // Capture edges clear the board: a key held across the toggle would
  // otherwise stay stuck down if its keyUp lands elsewhere.
  memset(g_keys_down, 0, sizeof(g_keys_down));
}

void Cocoa_keyState(Dart_NativeArguments args) {
  int n = 0;
  for (int i = 0; i < 128; i++) if (g_keys_down[i]) n++;
  Dart_Handle down = Dart_NewList(n);
  int j = 0;
  for (int i = 0; i < 128; i++) {
    if (g_keys_down[i]) Dart_ListSetAt(down, j++, Dart_NewInteger(i));
  }
  Dart_Handle out = Dart_NewList(2);
  Dart_ListSetAt(out, 0, down);
  Dart_ListSetAt(out, 1, Dart_NewInteger((int64_t)g_key_mods));
  Dart_SetReturnValue(args, out);
}

}  // namespace bin
}  // namespace dart
