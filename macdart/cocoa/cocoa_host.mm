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
#include <stdlib.h>
#include <string.h>

#include "include/dart_api.h"
#include "include/dart_tools_api.h"

static CFRunLoopRef g_main_loop;
static CFRunLoopSourceRef g_pump_source;
static bool g_in_pump;   // guards against re-entering the message loop
static bool g_pending;   // a wakeup arrived while pumping — don't lose it

// A UI-isolate hot reload, driven from HERE rather than from Dart.
// The UI isolate cannot reload itself from its own stack: it would be rewriting
// the frames it is standing on, with AppKit holding its closures. It can be
// reloaded perfectly well by the HOST, though — the same flag-and-drain
// discipline a modal panel needs. Dart raises the flag and returns; the reload
// happens below, at the top of the pump, with no Dart frames live.
static bool g_ui_ready = false;   // has main() ever finished building the UI?
static bool g_ui_reload_requested = false;
static char g_ui_reload_status[1024] = {0};

// Dart calls this once the window is up. Until then, an isolate error means the
// UI never started, and there is nothing for [NSApp run] to show.
extern "C" void macdart_ui_ready(void) { g_ui_ready = true; }

extern "C" void macdart_request_ui_reload(void) {
  g_ui_reload_requested = true;
  if (g_pump_source != NULL) {
    CFRunLoopSourceSignal(g_pump_source);
    CFRunLoopWakeUp(g_main_loop);
  }
}

// Answers (and clears) the outcome of the last host-driven reload, so Dart can
// report it without the host having to call back into Dart.
extern "C" const char* macdart_take_ui_reload_status(void) {
  if (g_ui_reload_status[0] == '\0') return NULL;
  static char out[1024];
  snprintf(out, sizeof(out), "%s", g_ui_reload_status);
  g_ui_reload_status[0] = '\0';
  return out;
}

// Reload the UI isolate's own sources. Only ever called from PumpPerform, after
// Dart_HandleMessages has returned — i.e. the isolate is entered but quiescent.
// ReloadSources is atomic: if the new source does not compile, it is CANCELLED
// and the running code is untouched, so a syntax error here costs nothing.
static void PerformUiReload(void) {
  g_ui_reload_requested = false;
  Dart_EnterScope();
  Dart_Handle r = Dart_WorkspaceReloadSources(true /* force_reload */);
  if (Dart_IsError(r)) {
    snprintf(g_ui_reload_status, sizeof(g_ui_reload_status), "ERR: %s",
             Dart_GetError(r));
    fprintf(stderr, "dartui: UI reload cancelled: %s\n", Dart_GetError(r));
  } else {
    snprintf(g_ui_reload_status, sizeof(g_ui_reload_status), "ok");
    fprintf(stderr, "dartui: UI reloaded\n");
  }
  Dart_ExitScope();
}

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
      // Once the UI is up, a callback that throws is survivable: log it and keep
      // the window (leak-over-crash). BEFORE that, the script itself failed to
      // load or build a window — carrying on would leave a running process with
      // nothing on screen and no control socket, which looks like a hang. Say
      // how to recover and stop.
      fprintf(stderr, "dartui: UI isolate error: %s\n", Dart_GetError(r));
      if (!g_ui_ready) {
        fprintf(stderr,
                "dartui: the UI never started — recover the last good source "
                "with:\n    ./start-gui.sh --restore\n");
        exit(70);
      }
    }
    Dart_ExitScope();
    // Dart is off the stack here — the only safe moment to swap its code out.
    if (g_ui_reload_requested) PerformUiReload();
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

    // macOS injects Dictation and "Emoji & Symbols" into any menu titled "Edit".
    // These opt-outs are only honoured if they are set BEFORE NSApplication is
    // initialised, which happens here — before main() builds the menu bar.
    [[NSUserDefaults standardUserDefaults]
        registerDefaults:@{@"NSDisabledDictationMenuItem" : @YES,
                           @"NSDisabledCharacterPaletteMenuItem" : @YES}];

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
