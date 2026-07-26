// MACDART GUI host — runs the UI isolate on OS thread 0 so dart:cocoa AppKit
// calls are legal. Only linked into the `dartui` executable (DART_UI_HOST in
// bin/main.cc). See WORKSPACE_PLAN.md §1.
//
// The `dart` CLI services the main isolate on a thread-pool thread
// (NSThread.isMainThread==0), which AppKit rejects. This host is invoked from
// RunMainIsolate *on thread 0* with the isolate entered and main() already
// queued as the startup message.
//
// Instead of Dart_RunLoop() we own [NSApp run] and pump the isolate's message
// queue from a CFRunLoopSource, so main(), the control socket, timers,
// cross-isolate replies, and AppKit callbacks all run on thread 0. This is the
// documented Dart_SetMessageNotifyCallback pattern (dart_api.h): the notify
// callback (any thread) only *wakes* the run loop; Dart_HandleMessages() runs
// here on thread 0.
#import <Cocoa/Cocoa.h>

#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <string.h>

#include "include/dart_api.h"

static CFRunLoopRef g_main_loop;
static CFRunLoopSourceRef g_pump_source;
static bool g_in_pump;   // guards against re-entering the message loop
static bool g_pending;   // a wakeup arrived while pumping — don't lose it

// Runs on thread 0 (via the run-loop source). Drains the UI isolate's message
// queue: the queued main() on the first tick, then socket events, timers, and
// cross-isolate replies.
static void PumpPerform(void* info) {
  (void)info;
  if (g_in_pump) {
    // Re-entered (AppKit drawing can spin the loop). Handling messages here
    // would nest the message loop, but simply returning would DROP this wakeup:
    // the run loop clears a source's signalled flag before calling perform. So
    // remember it and re-signal once the outer pump unwinds.
    g_pending = true;
    return;
  }
  g_in_pump = true;
  do {
    g_pending = false;
    Dart_EnterScope();
    Dart_Handle r = Dart_HandleMessages();
    if (Dart_IsError(r)) {
      // A UI-isolate callback threw. Log and keep the app alive (leak-over-crash);
      // a genuinely fatal VM error would have aborted the process already.
      fprintf(stderr, "dartui: UI isolate error: %s\n", Dart_GetError(r));
    }
    Dart_ExitScope();
  } while (g_pending);
  g_in_pump = false;
}

// May be called from ANY thread (the IO event-handler thread, another isolate).
// Only signals/wakes the run loop; the actual message handling happens in
// PumpPerform on thread 0. CFRunLoopSourceSignal + CFRunLoopWakeUp are
// documented thread-safe.
static void NotifyUi(Dart_Isolate dest_isolate) {
  (void)dest_isolate;
  if (g_pump_source != NULL) {
    CFRunLoopSourceSignal(g_pump_source);
    CFRunLoopWakeUp(g_main_loop);
  }
}

extern "C" int macdart_run_ui_host(void) {
  @autoreleasepool {
    g_main_loop = CFRunLoopGetCurrent();  // thread 0

    CFRunLoopSourceContext ctx;
    memset(&ctx, 0, sizeof(ctx));
    ctx.perform = PumpPerform;
    g_pump_source = CFRunLoopSourceCreate(NULL, 0, &ctx);
    // COMMON modes, not just default: while AppKit tracks a mouse press (an
    // NSTableView row click runs a nested loop in NSEventTrackingRunLoopMode) a
    // default-mode-only source cannot fire, so isolate replies that land during
    // the click would sit unhandled until the press ended.
    CFRunLoopAddSource(g_main_loop, g_pump_source, kCFRunLoopCommonModes);

    // Route this isolate's message wakeups to our run loop instead of the VM's
    // pool threads. Applies to the current (UI) isolate only; spawned language
    // and compute isolates keep the VM's default off-main scheduling.
    Dart_SetMessageNotifyCallback(&NotifyUi);

    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

    // main() is already queued (bin/main.cc called _startMainIsolate). Kick the
    // first drain so it runs, then let AppKit own the loop.
    CFRunLoopSourceSignal(g_pump_source);
    CFRunLoopWakeUp(g_main_loop);

    [NSApp run];

    Dart_SetMessageNotifyCallback(NULL);
  }
  return 0;
}
