// MACDART workspace UI isolate (thread 0). MACVM-style tabbed shell: a toolbar of
// view-switchers over a tabless NSTabView (Workspace / Browser / Docs), with a
// transcript docked below. The Workspace tab is an editable, syntax-highlighted
// code pane with Do It / Print It against the live language isolate; the Browser
// tab reflects the language isolate's classes via dart:mirrors. A loopback
// control socket lets an external driver set text, click, switch tabs, snapshot.
import 'dart:cocoa';
import 'dart:io';
import 'dart:isolate';
import 'dart:convert';
import 'dart:async';
import 'dart:developer';

import 'dart:math' as math;

import 'spriteed_model.dart';   // the sprite editor's document (pure, tested)
import 'sounded_model.dart';    // the sound editor's document (pure, tested)

Cocoa gWindow, gContent, gTabView, gEditor, gTranscript;
SendPort gLang;
List<String> gLog = <String>[];
Map<String, Cocoa> gButtons = <String, Cocoa>{};
List<Cocoa> gTargets = <Cocoa>[];      // keep action targets/delegates alive

// Language-isolate watchdog state.
Isolate gLangIsolate;
String gScratch;                       // the language isolate's scratch root file
String gDbPath;                        // the SQLite image (source of truth)
bool gRespawning = false;
int gLangGen = 0;                      // generation, to ignore stale exit events
final Object _kTimeout = new Object();
const Duration _kDoitTimeout = const Duration(seconds: 6);

int gTab = 0;                      // the visible tab, for context-sensitive menu items
List _dl(dynamic r) => r is List ? r : <dynamic>[];   // reply -> list

// Find state.
Cocoa gFindField, gFindTable;
List gFindResults = <dynamic>[];   // [class, memberSig]

// --- AppKit event -> isolate message ----------------------------------------
// An AppKit callback reaches Dart through Dart_InvokeClosure, straight out of an
// ObjC IMP — it does NOT arrive as an isolate message. That matters because this
// VM drains the microtask queue in exactly ONE place: _RawReceivePortImpl.
// _handleMessage (runtime/lib/isolate_patch.dart) calls _runPendingImmediateCallback()
// after dispatching a message, and nowhere else. And an `async` function body is
// started as `new Future.microtask(...)` (runtime/vm/parser.cc, Symbols::FutureMicrotask).
//
// So a handler that awaits — every browser navigation does, via ask() — would have
// its body parked as a microtask that nothing ever drains: the request is never
// even SENT, so no reply arrives, so no message is ever dispatched, so the queue
// is never drained. The click does nothing, permanently. (Driving the same
// function over the control socket works precisely because socket data IS a
// message, so _handleMessage drains the microtask right after.)
//
// Fix: bounce the event through our own port. The handler then runs from inside
// _handleMessage, where microtasks drain normally and async work completes. The
// send also wakes the run-loop pump, so it runs promptly.
ReceivePort _evPort;
SendPort _evSend;
int _evNext = 0;
final Map<int, Function> _evPending = <int, Function>{};

void initEvents() {
  _evPort = new ReceivePort();
  _evSend = _evPort.sendPort;
  _evPort.listen((id) {
    var body = _evPending.remove(id);
    if (body == null) return;
    // Every UI action arrives here, so an uncaught throw would be an unhandled
    // exception in the isolate's MESSAGE HANDLER — fatal to the root isolate,
    // which takes the window and your unsaved work with it. A bug in one button
    // must cost that button, not the app. (Found by the Debug menu's test error,
    // which killed the process before this.)
    try {
      body();
    } catch (e, st) {
      log("✗ UI action failed — " + e.toString());
      stderr.writeln("dartui: UI action failed: " + e.toString() + "\n" +
                     st.toString());
    }
  });
}

/// Run [body] from the isolate's message loop rather than inline in the AppKit
/// callback, so that any `async`/`await` work inside it actually runs.
void defer(void body()) {
  var id = _evNext++;
  _evPending[id] = body;
  _evSend.send(id);
}

/// A table-selection handler that runs deferred (see [defer]).
SelectFn sel(void body(int row)) => (r) => defer(() => body(r));

// --- chrome: MACVM's toolbar texture + icon set -----------------------------
// The icons (assets/icons-mono/*.svg) and the tiled grain (assets/toolbar-texture.png)
// are the SAME files MACVM's Cocoa UI uses, so the two systems look like siblings.
String gAssets;   // .../cocoa/workspace/assets/

// NSView autoresizing masks.
const int kMinXMargin = 1, kWidthSizable = 2, kMinYMargin = 8, kHeightSizable = 16;

/// The tiled grain as a backing box: a borderless NSBox filled with the texture
/// as a pattern colour, added FIRST so everything placed after it draws on top.
/// Fails soft — if the texture is missing, no box (never a blank hole).
Cocoa texturedBox(Cocoa parent, List frame, int mask) {
  var img = Cocoa.cls("NSImage").alloc().initWithContentsOfFile(gAssets + "toolbar-texture.png");
  if (img.isNil) return null;
  var box = Cocoa.cls("NSBox").alloc().initWithFrame(frame);
  box.setBoxType(4);      // NSBoxCustom
  box.setBorderType(0);   // NSNoBorder
  box.setFillColor(Cocoa.cls("NSColor").colorWithPatternImage(img));
  box.setAutoresizingMask(mask);
  parent.addSubview(box);
  return box;
}

/// An icon-only toolbar button. The SVG is set as a TEMPLATE image, so AppKit
/// tints it to the current appearance (light/dark) instead of us theming it.
/// Falls back to the text title if the icon fails to load — never an invisible
/// control. Keyed in [gButtons] under [title], so `click <title>` keeps working.
Cocoa iconButton(Cocoa parent, String title, String icon, List frame, CocoaAction fn) {
  var b = Cocoa.cls("NSButton").alloc().initWithFrame(frame);
  b.setTitle(title);
  b.setBordered(false);
  b.setToolTip(title);    // an icon-only bar still has to be discoverable
  var img = Cocoa.cls("NSImage").alloc().initWithContentsOfFile(
      gAssets + "icons-mono/" + icon + ".svg");
  if (!img.isNil) {
    img.setTemplate(true);
    b.setImage(img);
    b.setImagePosition(1);   // NSImageOnly
  }
  parent.addSubview(b);
  gButtons[title] = b;
  gTargets.add(onAction(b, (s) => defer(() => fn(s))));   // see [defer]
  return b;
}

// Right-anchored MEM / JIT / CODE / GC cells at the end of the toolbar: a muted
// caption over a value, MEM wider because it carries "used/capacity" plus a 2px
// usage bar (MACVM's buildMetricsClusterIn: / buildMemBarAt:width:in:). The bar
// is two plain-colour NSBoxes — a light track with a fill on top — which keeps
// us off CGColorRef marshalling entirely.
void buildMetricsCluster(Cocoa bar, double barW) {
  const double kCell = 64.0, kMem = 104.0, kGap = 6.0;
  var total = kMem + 3 * kCell + 3 * kGap;
  var x = barW - 8.0 - total;
  var caption = Cocoa.cls("NSFont").systemFontOfSize(9.0);
  var value = Cocoa.cls("NSFont").systemFontOfSize(12.0);
  var muted = Cocoa.cls("NSColor").secondaryLabelColor();
  for (var name in _kCells) {
    var w = (name == "MEM") ? kMem : kCell;
    var cap = label(bar, [x, 26.0, w, 12.0]);
    cap.setStringValue(name);
    if (!caption.isNil) cap.setFont(caption);
    if (!muted.isNil) cap.setTextColor(muted);
    cap.setAutoresizingMask(kMinXMargin);
    var val = label(bar, [x, 8.0, w, 16.0]);
    val.setStringValue("—");            // no reading yet — not a fake zero
    if (!value.isNil) val.setFont(value);
    val.setAutoresizingMask(kMinXMargin);
    gMetricVals[name] = val;
    if (name == "MEM") buildMemBar(bar, x, w - 8.0);
    x += w + kGap;
  }
}

// A 2px used/capacity bar under the MEM value: a light track with a fill drawn
// over it, both borderless NSBoxes with a plain fill colour.
void buildMemBar(Cocoa bar, double x, double w) {
  gMemBarWidth = w;
  var track = Cocoa.cls("NSBox").alloc().initWithFrame([x, 6.0, w, 2.0]);
  track.setBoxType(4); track.setBorderType(0);
  var grey = Cocoa.cls("NSColor").tertiaryLabelColor();
  if (!grey.isNil) track.setFillColor(grey);
  track.setAutoresizingMask(kMinXMargin);
  bar.addSubview(track);
  gMemBarFill = Cocoa.cls("NSBox").alloc().initWithFrame([x, 6.0, 1.0, 2.0]);
  gMemBarFill.setBoxType(4); gMemBarFill.setBorderType(0);
  var ink = Cocoa.cls("NSColor").secondaryLabelColor();
  if (!ink.isNil) gMemBarFill.setFillColor(ink);
  gMemBarFill.setAutoresizingMask(kMinXMargin);
  bar.addSubview(gMemBarFill);
}

/// A draggable pane splitter (MACVM's browser shape). [vertical] true = panes
/// side by side with vertical dividers.
Cocoa splitView(List frame, bool vertical) {
  var sp = Cocoa.cls("NSSplitView").alloc().initWithFrame(frame);
  sp.setVertical(vertical);
  sp.setDividerStyle(3);   // NSSplitViewDividerStylePaneSplitter — visibly grabbable
  sp.setAutoresizingMask(kWidthSizable + kHeightSizable);
  return sp;
}

// The control socket addresses buttons by title, but two titles are used on more
// than one tab: "Find" is both a toolbar tab-switcher and the Find tab's search
// button, and "Accept" is both the Workspace editor's and the browser's. The
// plain title keeps its historic (last-registered) meaning; these aliases let a
// driver name the one it actually means.
Cocoa alias(String name, Cocoa b) { gButtons[name] = b; return b; }

Cocoa _mono(double sz) => Cocoa.cls("NSFont").userFixedPitchFontOfSize(sz);

Cocoa button(Cocoa parent, String title, List frame, CocoaAction fn) {
  var b = Cocoa.cls("NSButton").alloc().initWithFrame(frame);
  b.setTitle(title);
  b.setBezelStyle(1);
  parent.addSubview(b);
  gButtons[title] = b;
  gTargets.add(onAction(b, (s) => defer(() => fn(s))));   // see [defer]
  return b;
}

// An NSTextView inside a bezeled, vertically-scrolling NSScrollView.
Cocoa scrolledTextView(Cocoa parent, List frame, bool editable) {
  var scroll = Cocoa.cls("NSScrollView").alloc().initWithFrame(frame);
  scroll.setHasVerticalScroller(true);
  scroll.setBorderType(2); // NSBezelBorder
  var tv = Cocoa.cls("NSTextView").alloc()
      .initWithFrame([0.0, 0.0, frame[2], frame[3]]);
  tv.setEditable(editable);
  tv.setAllowsUndo(editable);   // so Edit > Undo/Redo work in this view
  tv.setRichText(false);
  tv.setAutomaticQuoteSubstitutionEnabled(false);
  tv.setAutomaticDashSubstitutionEnabled(false);
  tv.setAutomaticSpellingCorrectionEnabled(false);
  var f = _mono(13.0);
  if (!f.isNil) tv.setFont(f);
  scroll.setDocumentView(tv);
  parent.addSubview(scroll);
  return tv;
}

Cocoa label(Cocoa parent, List frame) {
  var t = Cocoa.cls("NSTextField").alloc().initWithFrame(frame);
  t.setBezeled(false); t.setEditable(false); t.setDrawsBackground(false);
  parent.addSubview(t);
  return t;
}

// Add a tabless tab; returns its content container view (sized to the host).
Cocoa addTab(Cocoa tabView, String ident, double w, double h) {
  var item = Cocoa.cls("NSTabViewItem").alloc().initWithIdentifier(ident);
  var view = Cocoa.cls("NSView").alloc().initWithFrame([0.0, 0.0, w, h]);
  view.setAutoresizingMask(kWidthSizable + kHeightSizable);
  view.setAutoresizesSubviews(true);
  item.setView(view);
  tabView.addTabViewItem(item);
  return view;
}

/// Anchor a scrolled text view's SCROLL view (the text view is its document, so
/// the mask belongs on the scroll view, not the text view).
void anchorScroll(Cocoa textView, int mask) {
  textView.enclosingScrollView().setAutoresizingMask(mask);
}

/// Pin controls to the top edge of their container, so a taller container grows
/// downward under them instead of leaving them stranded.
void pinTop(List<String> titles, [int extra = 0]) {
  for (var t in titles) {
    if (gButtons[t] != null) gButtons[t].setAutoresizingMask(kMinYMargin + extra);
  }
}

void switchTab(int i) {
  gTabView.selectTabViewItemAtIndex(i);
  gTab = i;
  // The undo manager belongs to the WINDOW and is shared by every text view in
  // it, and undo: is implemented by NSWindow — so without this, typing in the
  // Workspace, switching tabs and pressing Cmd-Z would silently undo that edit
  // off-screen, in a buffer the user is no longer looking at.
  clearUndo();
  // NSTabView hands the first responder to the first view in the new tab's
  // key-view loop, which for the Browser is the Categories table — Cut/Copy/
  // Paste would be greyed out until the user clicked the source pane. Put focus
  // on the tab's text view instead.
  // The Browser tab (i==1) is the EMBEDDED ST browser (CocoaBrowser2): focus and
  // refresh belong to the embedded view — re-embed if it is missing (world
  // imported after boot, or a lost isolate), else ask it to refresh from the image.
  var focus = (i == 0) ? gEditor
            : (i == 3) ? gFindField : (i == 4) ? gEdText
            : (i == 5) ? gDbgSrc : (i == 8) ? gProfSrc : null;
  if (focus != null) gWindow.makeFirstResponder(focus);
  if (i == 1) {
    if (gStBrowserView == null) stBrowserEmbed();
    else ask('doit', 'st> CocoaBrowser2 doRefresh. nil').then((_) {});
  }
  if (i == 4) editorRefreshClasses();
  if (i == 5) dbgRefreshIsolates();    // fresh isolate list on entering the tab
  if (i == 5 && gLangIsolateId != null) dbgLoadSource();
  if (i == 8) profRefreshIsolates();   // fresh isolate list for the profiler
  if (i == 7) appRefreshList();
  if (i == 2) helpStart();   // index on first use, not at startup
  // The keyboard belongs to a game only while the user is watching it: leaving
  // the Demos tab returns every key to the workspace, coming back re-arms.
  keyCapture(i == 6 && gDemoTitle != null);
  updateMetrics();
  repaint();
}

/// Drop the window's undo stack. Needed whenever we replace a text view's
/// contents programmatically: setString: registers no undo action but does NOT
/// clear the stack, so a later Undo would splice the PREVIOUS buffer's edits
/// into freshly loaded content.
void clearUndo() {
  var um = gWindow.undoManager();
  if (!um.isNil) um.removeAllActions();
}

bool gStandalone = false;             // running one image class as a windowed app

/// `dartui --app <Class>` (or `MACDART_APP=<Class>`): the class to run standalone.
/// Name from a script arg or the env var; null = the normal IDE.
String _standaloneAppName(List<String> args) {
  if (args != null) {
    for (var i = 0; i < args.length; i++) {
      if (args[i] == '--app' && i + 1 < args.length) return args[i + 1];
      if (args[i].startsWith('--app=')) return args[i].substring(6);
    }
  }
  var e = Platform.environment['MACDART_APP'];
  return (e != null && e.trim().isNotEmpty) ? e.trim() : null;
}

/// A minimal window: the app surface fills the whole content, plus a Quit menu.
/// The app runs in the language isolate exactly as on the App tab — the same
/// class, the same image, the same hot reload — just without the IDE chrome.
bool gStandaloneFullscreen = false;   // a --game launched with --fullscreen

// The app menu (Quit) both standalone windows share.
void _standaloneMenu(String title) {
  Cocoa.cls("NSProcessInfo").processInfo().setProcessName(title);
  var mainMenu = Cocoa.cls("NSMenu").alloc().init();
  var appItem = Cocoa.cls("NSMenuItem").alloc().init();
  mainMenu.addItem(appItem);
  var appMenu = Cocoa.cls("NSMenu").alloc().init();
  appItem.setSubmenu(appMenu);
  stdItem(appMenu, "Quit " + title, "q", "terminate:");
  Cocoa.cls("NSApplication").sharedApplication().setMainMenu(mainMenu);
}

void buildStandaloneWindow(String title) {
  gStandalone = true;
  _standaloneMenu(title);
  gWindow = Cocoa.cls("NSWindow").alloc().initWithContentRect(
      [0.0, 0.0, 900.0, 600.0], styleMask: 15, backing: 2, defer: false);
  gWindow.setTitle(title);
  gWindow.setContentMinSize([320.0, 240.0]);
  quitOnClose(gWindow);
  gContent = gWindow.contentView();
  gAppPane = Cocoa.cls("NSView").alloc().initWithFrame([0.0, 0.0, 900.0, 600.0]);
  gAppPane.setAutoresizingMask(kWidthSizable + kHeightSizable);
  gAppPane.setAutoresizesSubviews(false);
  gContent.addSubview(gAppPane);
  gWindow.center();
  gWindow.makeKeyAndOrderFront(null);
  Cocoa.cls("NSApplication").sharedApplication().activateIgnoringOtherApps(true);
}

/// `dartui … --game <Name>` / `--demo <Name>` (or `MACDART_GAME=<Name>`): the
/// game/demo to run standalone.
String _standaloneGameName(List<String> args) {
  if (args != null) {
    for (var i = 0; i < args.length; i++) {
      if ((args[i] == '--game' || args[i] == '--demo') && i + 1 < args.length) return args[i + 1];
      if (args[i].startsWith('--game=')) return args[i].substring(7);
      if (args[i].startsWith('--demo=')) return args[i].substring(7);
    }
  }
  var e = Platform.environment['MACDART_GAME'];
  return (e != null && e.trim().isNotEmpty) ? e.trim() : null;
}

/// [title, path] of the demo/game whose title or filename contains `name`.
List<String> _resolveDemo(String name) {
  var want = name.toLowerCase();
  for (var d in scanDemos()) {
    if (d[0].toLowerCase().contains(want) ||
        d[1].split('/').last.toLowerCase().contains(want)) return d;
  }
  return null;
}

/// A bare window hosting the demo/game surface: the game pane opens OVER a
/// full-window gDemoView exactly as it does on the Demos tab (gpEnter uses
/// gDemoView's frame + superview), so games and canvas demos both just work.
void buildStandaloneGameWindow(String title) {
  gStandalone = true;
  _standaloneMenu(title);
  gWindow = Cocoa.cls("NSWindow").alloc().initWithContentRect(
      [0.0, 0.0, 848.0, 480.0], styleMask: 15, backing: 2, defer: false);  // 2x a 424x240 game
  gWindow.setTitle(title);
  gWindow.setContentMinSize([424.0, 240.0]);
  quitOnClose(gWindow);
  gContent = gWindow.contentView();
  gDemoImage = Cocoa.cls("NSImage").alloc().initWithSize([kDemoW, kDemoH]);
  gDemoView = Cocoa.cls("NSImageView").alloc().initWithFrame([0.0, 0.0, 848.0, 480.0]);
  gDemoView.setImageScaling(3);        // proportional up/down — pixel-doubles the game
  gDemoView.setImage(gDemoImage);
  gDemoView.setAutoresizingMask(kWidthSizable + kHeightSizable);
  gContent.addSubview(gDemoView);
  gWindow.center();
  gWindow.makeKeyAndOrderFront(null);
  Cocoa.cls("NSApplication").sharedApplication().activateIgnoringOtherApps(true);
}

void buildWindow() {
  gWindow = Cocoa.cls("NSWindow").alloc().initWithContentRect(
      [0.0, 0.0, 900.0, 640.0], styleMask: 15, backing: 2, defer: false);
  gWindow.setTitle("MACDART Workspace");
  // Below this the panes stop being usable, so don't let the window get there.
  gWindow.setContentMinSize([680.0, 480.0]);
  quitOnClose(gWindow);   // the red close button quits, same as Cmd-Q
  gContent = gWindow.contentView();
  buildChrome();
  gWindow.center();
  gWindow.makeKeyAndOrderFront(null);
  Cocoa.cls("NSApplication").sharedApplication().activateIgnoringOtherApps(true);
}

/// Everything inside the window: the menu bar and the whole view tree. Separated
/// from [buildWindow] so it can be run AGAIN over a torn-down content view — a
/// source reload changes behaviour, but only re-running this moves a button.
void buildChrome() {
  buildMenu();

  // Toolbar band: a textured strip carrying icon view-switchers on the left and
  // a live metrics readout on the right (MACVM's CocoaUI toolbar, same assets).
  var bar = Cocoa.cls("NSView").alloc().initWithFrame([0.0, 596.0, 900.0, kToolbarH]);
  bar.setAutoresizingMask(kWidthSizable + kMinYMargin);   // pinned to the top edge
  bar.setAutoresizesSubviews(true);
  gToolbar = bar;                    // [layoutChrome] re-seats it on a rebuild
  gContent.addSubview(bar);
  texturedBox(bar, [0.0, 0.0, 900.0, kToolbarH], kWidthSizable + kHeightSizable);
  iconButton(bar, "Workspace", "texteditor", [8.0, 6.0, 36.0, 32.0], (s) => switchTab(0));
  iconButton(bar, "Browser", "hierarchy", [48.0, 6.0, 36.0, 32.0], (s) => switchTab(1));
  iconButton(bar, "Editor", "blankSheet", [88.0, 6.0, 36.0, 32.0], (s) => switchTab(4));
  alias("tab:Find", iconButton(bar, "Find", "open", [128.0, 6.0, 36.0, 32.0], (s) => switchTab(3)));
  iconButton(bar, "Debug", "goForward", [168.0, 6.0, 36.0, 32.0], (s) => switchTab(5));
  iconButton(bar, "Demos", "canvas", [208.0, 6.0, 36.0, 32.0], (s) => switchTab(6));
  iconButton(bar, "App", "home", [248.0, 6.0, 36.0, 32.0], (s) => switchTab(7));
  iconButton(bar, "Docs", "documentation", [288.0, 6.0, 36.0, 32.0], (s) => switchTab(2));
  iconButton(bar, "Profile", "gauge", [328.0, 6.0, 36.0, 32.0], (s) => switchTab(8));
  buildMetricsCluster(bar, 900.0);

  // Tabless content host (the toolbar buttons are the tab bar). It absorbs all
  // the slack when the window resizes: pinned between the transcript below and
  // the toolbar above, so its top edge always meets the toolbar's bottom.
  gTabView = Cocoa.cls("NSTabView").alloc().initWithFrame([16.0, 176.0, 868.0, 420.0]);
  gTabView.setTabViewType(6); // NSNoTabsNoBorder
  gTabView.setAutoresizingMask(kWidthSizable + kHeightSizable);
  gContent.addSubview(gTabView);

  // Workspace tab: Do It / Print It / Clear + a highlighted editor.
  var ws = addTab(gTabView, "workspace", 868.0, 420.0);
  button(ws, "Do It", [8.0, 388.0, 84.0, 28.0], (s) => run(false));
  button(ws, "Print It", [98.0, 388.0, 90.0, 28.0], (s) => run(true));
  alias("ws:Accept", button(ws, "Accept", [194.0, 388.0, 92.0, 28.0], (s) => acceptEditor()));
  pinTop(<String>["Do It", "Print It", "Accept"]);
  gEditor = scrolledTextView(ws, [8.0, 8.0, 852.0, 372.0], true);
  anchorScroll(gEditor, kWidthSizable + kHeightSizable);
  gTargets.add(onTextChange(gEditor, (s) => highlight()));

  // Browser tab (Sprint 15): MACVM's OWN CocoaBrowser2, embedded — it
  // browses BOTH languages from the image (and edits them). The view is BUILT
  // by the language isolate (where the ST engine and the image live) and
  // PARENTED by this one: the raw view handle crosses as an int.
  buildStBrowserTab(addTab(gTabView, "browser", 868.0, 420.0));

  // Docs tab: the workspace guide, and searchable Dart V1 help beside it.
  buildDocsTab(addTab(gTabView, "docs", 868.0, 420.0));

  // Find tab.
  buildFindTab(addTab(gTabView, "find", 868.0, 420.0));

  // Editor tab: a whole class as text, against the image or a .dart file.
  buildEditorTab(addTab(gTabView, "editor", 868.0, 420.0));

  // Debugger tab: breakpoints and stepping in the LANGUAGE isolate.
  buildDebugTab(addTab(gTabView, "debug", 868.0, 420.0));

  // Demos tab: a canvas that demo isolates draw on, through this isolate.
  buildDemosTab(addTab(gTabView, "demos", 868.0, 420.0));

  // App tab: the surface a user's own Cocoa app runs on.
  buildAppTab(addTab(gTabView, "app", 868.0, 420.0));

  // Profiler tab: sample the VM's built-in CPU profiler for any running isolate.
  buildProfileTab(addTab(gTabView, "profile", 868.0, 420.0));

  // Transcript dock (shared across tabs): docked to the bottom at a fixed
  // height, widening with the window — and collapsible, see [layoutChrome].
  gTranscript = scrolledTextView(gContent, [16.0, kDockMargin, 868.0, kDockH], false);
  anchorScroll(gTranscript, kWidthSizable);

  // The dock's strip: the collapse toggle on the left, the newest line beside
  // it (shown only when the pane is shut), and Clear on the right with the
  // transcript it clears — all reachable from every tab.
  gDockBar = Cocoa.cls("NSView").alloc().initWithFrame(
      [16.0, _dockBarY(), 868.0, kDockBarH]);
  gDockBar.setAutoresizingMask(kWidthSizable);
  gDockBar.setAutoresizesSubviews(true);
  gContent.addSubview(gDockBar);
  var dockFont = Cocoa.cls("NSFont").systemFontOfSize(10.0);
  // Registered under the plain title so `click Transcript` keeps working: the
  // displayed title carries the ▾/▸ state and is rewritten on every toggle.
  gDockToggle = button(gDockBar, "Transcript", [0.0, 0.0, 104.0, kDockBarH],
                       (s) => setDock(!gDockCollapsed));
  if (!dockFont.isNil) gDockToggle.setFont(dockFont);
  gDockLastLbl = label(gDockBar, [112.0, 1.0, 868.0 - 112.0 - 68.0, 14.0]);
  if (!dockFont.isNil) gDockLastLbl.setFont(dockFont);
  gDockLastLbl.setAutoresizingMask(kWidthSizable);
  gDockLastLbl.setHidden(true);
  button(gDockBar, "Clear", [808.0, 0.0, 60.0, kDockBarH], (s) {
    gLog.clear(); gTranscript.setString(""); dockShowLast(); repaint();
  }).setAutoresizingMask(kMinXMargin);

  gTabView.selectTabViewItemAtIndex(0);
  layoutChrome();   // the dock's height is the tab host's — settle both together
  updateMetrics();
}

// --- the transcript dock ----------------------------------------------------
// Everything below the toolbar is either the dock or the tab host, so what one
// gives up the other takes: collapsing the transcript to its strip hands those
// 142pt to whichever tab is in front.
//
// The collapsed flag is a global on purpose. rebuildUi() throws the whole view
// tree away and runs buildChrome() again, and a rebuild that popped the dock
// back open would undo the user's choice every time the layout reloads.
bool gDockCollapsed = false;
Cocoa gToolbar;          // the textured band (laid out here, not just at build)
Cocoa gDockBar;          // the strip carrying the toggle, the last line, Clear
Cocoa gDockToggle;       // "▾ Transcript" / "▸ Transcript"
Cocoa gDockLastLbl;      // the newest line, shown only while collapsed
Cocoa gDockMenuItem;     // View ▸ Hide/Show Transcript

const double kToolbarH = 44.0;    // the textured band across the top
const double kDockH = 140.0;      // the transcript pane, when open
const double kDockBarH = 18.0;    // the strip above it
const double kDockMargin = 12.0;  // gap to the window's bottom edge

/// The strip's y: at the window's bottom edge when collapsed, above the
/// transcript pane when open.
double _dockBarY() =>
    gDockCollapsed ? kDockMargin : kDockMargin + kDockH + 2.0;

/// Lay the window's fixed furniture out for the current state and window size:
/// the toolbar band, the dock, and the tab host between them. Run on build and
/// on every toggle; in between, autoresizing masks hold the arrangement — the
/// margins set here are exactly what AppKit then preserves.
///
/// buildChrome() builds at the 900x640 frames it was written for, so this is
/// also what makes a REBUILD land correctly on a window that has since been
/// resized (Debug ▸ Rebuild UI Layout, and every UI reload) — before this, a
/// rebuild at another size left the toolbar and the tab host at their build-time
/// geometry, stranded across the middle of the window.
void layoutChrome() {
  if (gTabView == null || gDockBar == null || gTranscript == null) return;
  var b = gContent.bounds();
  var w = b[2], h = b[3];
  if (gToolbar != null) gToolbar.setFrame([0.0, h - kToolbarH, w, kToolbarH]);
  var scroll = gTranscript.enclosingScrollView();
  scroll.setHidden(gDockCollapsed);
  scroll.setFrame([16.0, kDockMargin, w - 32.0, kDockH]);
  var barY = _dockBarY();
  gDockBar.setFrame([16.0, barY, w - 32.0, kDockBarH]);
  var tabY = barY + kDockBarH + 4.0;
  gTabView.setFrame([16.0, tabY, w - 32.0, h - kToolbarH - tabY]);
  gDockToggle.setTitle(gDockCollapsed ? "▸ Transcript" : "▾ Transcript");
  gDockLastLbl.setHidden(!gDockCollapsed);   // open, the pane itself shows it
  dockShowLast();
  if (gDockMenuItem != null) {
    gDockMenuItem.setTitle(gDockCollapsed ? "Show Transcript" : "Hide Transcript");
  }
}

/// Collapse the transcript to its strip, or open it again.
void setDock(bool collapsed) {
  if (gDockBar == null) return;      // a standalone app window has no transcript
  gDockCollapsed = collapsed;
  // A hidden view must not keep the keyboard: hand focus back to the tab in
  // front if the transcript had it.
  if (collapsed) gWindow.makeFirstResponder(gTabView);
  layoutChrome();
  repaint();
}

/// The newest transcript line, in the collapsed strip. Collapsing must not make
/// output invisible — and an error is the line you most need to see when the
/// pane it would have landed in is shut, so those come through in red. The
/// FIRST line of the entry: a failed do-it logs its stack under the message,
/// and the message is the part worth a single line.
void dockShowLast() {
  if (gDockLastLbl == null || !gDockCollapsed) return;
  var line = gLog.isEmpty ? "" : gLog.last;
  var nl = line.indexOf('\n');
  if (nl >= 0) line = line.substring(0, nl);
  gDockLastLbl.setStringValue(line.trim());
  // The two shapes an error takes here: "✗ …" from the UI itself, and a do-it
  // whose result came back "⟹   ERR: …" from the language isolate.
  var bad = line.trimLeft().startsWith("✗") || line.contains("ERR:");
  var c = bad ? Cocoa.cls("NSColor").systemRedColor()
              : Cocoa.cls("NSColor").secondaryLabelColor();
  if (!c.isNil) gDockLastLbl.setTextColor(c);
}

// --- VM metrics cluster (MACVM's toolbar readout) ---------------------------
// The numbers come from the LANGUAGE isolate (where user code runs), sampled
// over the port — see Dart_WorkspaceVmStats. Everything shown is read straight
// off the VM; nothing is estimated, and a counter the VM cannot answer shows
// "—" rather than a plausible-looking zero. (MACVM's ALLOC B/s cell has no
// equivalent here: this VM keeps no cumulative allocation counter, so a rate
// could only be guessed.)
Map<String, Cocoa> gMetricVals = <String, Cocoa>{};
Cocoa gMemBarFill;
double gMemBarWidth = 0.0;
bool gPolling = false;                     // one sample in flight at a time
const List<String> _kCells = const <String>["MEM", "JIT", "CODE", "GC"];

/// `1536` -> `1.5K`. Base 1024, one decimal past the first suffix — MACVM's
/// format_bytes, so the two toolbars read the same.
String formatBytes(int n) {
  if (n < 1024) return n.toString() + "B";
  const List<String> units = const <String>["K", "M", "G", "T"];
  var v = n.toDouble();
  var u = -1;
  while (v >= 1024.0 && u < units.length - 1) { v /= 1024.0; u++; }
  return v.toStringAsFixed(1) + units[u];
}

void updateMetrics() {
  if (gMetricVals.isEmpty) return;
  pollVmStats();
}

// ~4 Hz, like MACVM. Skips while a sample is outstanding, and while the
// language isolate is restarting.
void startMetrics() {
  new Timer.periodic(const Duration(milliseconds: 250), (t) {
    appWatchResize();   // a running app re-lays-itself-out when the pane changes
    pollVmStats();
  });
}

void pollVmStats() {
  pollUiReload();   // the host leaves its reload result for us to report
  if (gDbgPaused && gDbgIsLang) return;   // stats poll targets the language isolate
  if (gPolling || gLang == null || gMetricVals.isEmpty) return;
  gPolling = true;
  askQuiet('vmstats', '', const Duration(seconds: 2)).then((r) {
    gPolling = false;
    if (r is! List || r.length < 9) return;   // busy or restarting: leave the last reading
    renderMetrics(r);
  }).catchError((e) { gPolling = false; });
}

void renderMetrics(List v) {
  var used = v[0] + v[2];              // new + old heap in use
  var cap = v[1] + v[3];
  _setCell("MEM", formatBytes(used) + "/" + formatBytes(cap));
  // Compiler counters are only live when the VM ran with --compiler_stats.
  var compiled = v[6], optimized = v[7], codeBytes = v[8];
  _setCell("JIT", compiled == 0 && optimized == 0
      ? "—" : compiled.toString() + "c·" + optimized.toString() + "o");
  _setCell("CODE", codeBytes == 0 ? "—" : formatBytes(codeBytes));
  _setCell("GC", v[4].toString() + "·" + v[5].toString());   // scavenge · mark-sweep
  if (gMemBarFill != null && cap > 0) {
    var f = gMemBarWidth * (used / cap);
    if (f < 1.0) f = 1.0;
    if (f > gMemBarWidth) f = gMemBarWidth;
    var fr = gMemBarFill.frame();
    gMemBarFill.setFrame([fr[0], fr[1], f, fr[3]]);
  }
  repaint();
}

void _setCell(String name, String value) {
  var tf = gMetricVals[name];
  if (tf != null) tf.setStringValue(value);
}

// Force pending UI changes onto the screen. Updates driven from the run-loop
// pump — async `.then` continuations, cross-isolate replies, socket commands —
// happen OUTSIDE an AppKit event, so they never get AppKit's end-of-event
// display flush and the window would otherwise stay stale until the next OS
// event. (Offscreen snapshots force-render, so they always look correct and
// mask this — verify real interaction, not snapshots.)
void repaint() {
  gWindow.display();
}

void log(String line) {
  gLog.add(line);
  if (gLog.length > 200) gLog = gLog.sublist(gLog.length - 200);
  if (gTranscript != null) {                 // no transcript in a standalone app window
    gTranscript.setString(gLog.join("\n"));
    gTranscript.scrollToEndOfDocument(null);
    dockShowLast();                          // collapsed: the strip is the view
  }
  repaint();   // async/callback updates run outside AppKit's event flush
}

// --- Smalltalk-style class browser ------------------------------------------
// An NSTableView (single text column, no header) inside a scroll view.
Cocoa tableIn(Cocoa parent, List frame) {
  var scroll = Cocoa.cls("NSScrollView").alloc().initWithFrame(frame);
  scroll.setHasVerticalScroller(true);
  scroll.setBorderType(2);
  var table = Cocoa.cls("NSTableView").alloc().initWithFrame([0.0, 0.0, frame[2], frame[3]]);
  var col = Cocoa.cls("NSTableColumn").alloc().initWithIdentifier("c");
  col.setWidth(frame[2] - 4.0);
  col.setEditable(false);        // a browser pane: clicks SELECT the row, never edit the cell
  var cell = col.dataCell();
  var f = _mono(12.0);
  if (!cell.isNil && !f.isNil) cell.setFont(f);
  table.addTableColumn(col);
  table.setHeaderView(null);
  table.setUsesAlternatingRowBackgroundColors(true);
  // Follow the enclosing pane when a splitter resizes it.
  table.setAutoresizingMask(kWidthSizable);   // height is the table's own business
  table.setColumnAutoresizingStyle(1);        // NSTableViewUniformColumnAutoresizingStyle
  scroll.setDocumentView(table);
  scroll.setAutoresizingMask(kWidthSizable + kHeightSizable);
  parent.addSubview(scroll);
  return table;
}

// A browser column. Each split pane is its OWN NSView holding the table plus any
// buttons that belong to that column, which is how MACVM does it
// (world/72_cocoabrowser2.mst buildClassListPane:): the scroll view is inset by
// the button row's height and the buttons sit at the pane's bottom edge. Because
// they are children of the pane, the splitter carries them — put them in the tab
// instead, at fixed coordinates, and they drift out of alignment as soon as a
// divider moves.
const double kPaneBtnH = 26.0;

Cocoa browserPane(Cocoa split, double w, double h) {
  var v = Cocoa.cls("NSView").alloc().initWithFrame([0.0, 0.0, w, h]);
  v.setAutoresizesSubviews(true);
  v.setAutoresizingMask(kWidthSizable + kHeightSizable);
  split.addSubview(v);
  return v;
}

// Shrink a pane button's label so a New/Remove pair fits a narrow column.
void _paneBtnFont(Cocoa b) {
  var f = Cocoa.cls("NSFont").systemFontOfSize(11.0);
  if (!f.isNil) b.setFont(f);
}

// A New/Remove pair across the bottom of a column, at FIXED widths anchored to
// opposite edges. Springs-and-struts cannot split a width between two siblings:
// give both kWidthSizable with fixed margins and the left one absorbs the whole
// delta and grows straight over its neighbour. Anchoring instead means a wider
// column opens a gap in the middle, which is harmless, and they can never overlap.
void paneButtons(Cocoa pane, double w, String leftTitle, double lw, CocoaAction leftFn,
                 String rightTitle, double rw, CocoaAction rightFn,
                 [String leftTip = "", String rightTip = ""]) {
  var l = button(pane, leftTitle, [4.0, 3.0, lw, 22.0], leftFn);
  var r = button(pane, rightTitle, [w - 4.0 - rw, 3.0, rw, 22.0], rightFn);
  l.setAutoresizingMask(0);             // rides the left edge
  r.setAutoresizingMask(kMinXMargin);   // rides the right edge
  l.setToolTip(leftTip);
  r.setToolTip(rightTip);
  _paneBtnFont(l); _paneBtnFont(r);
}

Cocoa gStBrowserHost;      // the tab view the ST browser embeds into
Cocoa gStBrowserView;      // the embedded container (language-isolate built)

void buildStBrowserTab(Cocoa host) {
  gStBrowserHost = host;
  stBrowserEmbed();
}

/// Ask the language isolate to build the ST browser for the tab's frame and
/// parent the returned view. Retries while the language isolate boots; also
/// called on languageRestarted (the old view's action ports die with its
/// isolate, so the browser is rebuilt fresh).
void stBrowserEmbed() {
  if (gStBrowserHost == null) return;
  var host = gStBrowserHost;
  () async {
    for (var attempt = 0; attempt < 30; attempt++) {
      var f = host.frame();
      var wpx = (f is List && f.length == 4) ? f[2] : 868.0;
      var hpx = (f is List && f.length == 4) ? f[3] : 420.0;
      var r = await askQuiet(
          'stbrowser', wpx.toString() + ' ' + hpx.toString(),
          const Duration(seconds: 8));
      if (r == null) {
        await new Future.delayed(const Duration(seconds: 1));
        continue;
      }
      var s = r.toString();
      if (s.startsWith('ERR')) {
        log('Smalltalk browser: ' + s.substring(3).trim());
        return;   // no world in the image — the tab stays empty until stimport
      }
      var handle = int.parse(s, onError: (_) => 0);
      if (handle == 0) return;
      if (gStBrowserView != null) {
        gStBrowserView.removeFromSuperview();
        gStBrowserView = null;
      }
      gStBrowserView = Cocoa.adoptHandle(handle);
      host.addSubview(gStBrowserView);
      return;
    }
    log('Smalltalk browser: the language isolate never became ready');
  }();
}

/// The name a declaration defines, or null if it isn't a class/enum.
String _classNameOf(String d) {
  var m = new RegExp(r'^\s*(?:abstract\s+)?(?:class|enum)\s+(\w+)')
      .firstMatch(afterLeadingComments(d));
  return m != null ? m.group(1) : null;
}

/// A declaration's text minus any comments in front of it. splitTopLevel keeps
/// a leading doc comment attached to the declaration it documents (rightly —
/// the comment belongs with the class), so every name matcher has to step over
/// it. Without this a documented class is not recognised as a class at all, and
/// the image stores it under whatever the fallback matcher finds in the prose.
String afterLeadingComments(String s) {
  var i = 0;
  while (i < s.length) {
    var c = s.codeUnitAt(i);
    if (c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D) { i++; continue; }
    if (c == 0x2F && i + 1 < s.length) {
      var d = s.codeUnitAt(i + 1);
      if (d == 0x2F) {                                  // // to end of line
        while (i < s.length && s.codeUnitAt(i) != 0x0A) i++;
        continue;
      }
      if (d == 0x2A) {                                  // /* … */
        i += 2;
        while (i + 1 < s.length &&
               !(s.codeUnitAt(i) == 0x2A && s.codeUnitAt(i + 1) == 0x2F)) i++;
        i = (i + 1 < s.length) ? i + 2 : s.length;
        continue;
      }
    }
    break;
  }
  return s.substring(i);
}

// --- Find (search / senders over the image) ---------------------------------
void buildFindTab(Cocoa fd) {
  gFindField = Cocoa.cls("NSTextField").alloc().initWithFrame([8.0, 388.0, 396.0, 24.0]);
  gFindField.setStringValue("");
  var mf = _mono(13.0); if (!mf.isNil) gFindField.setFont(mf);
  fd.addSubview(gFindField);
  gFindField.setAutoresizingMask(kMinYMargin + kWidthSizable);
  alias("find:Search", button(fd, "Find", [412.0, 386.0, 76.0, 28.0], (s) => runFind('find')));
  button(fd, "Senders", [494.0, 386.0, 92.0, 28.0], (s) => runFind('senders'));
  pinTop(<String>["Find", "Senders"], kMinXMargin);
  var hint = label(fd, [598.0, 390.0, 262.0, 18.0]);
  hint.setStringValue("name search / senders — click a result to open it");
  hint.setAutoresizingMask(kMinYMargin + kMinXMargin);
  gFindTable = tableIn(fd, [8.0, 8.0, 852.0, 368.0]);
  gTargets.add(onTable(gFindTable, () => gFindResults.length, (r) => _findRowLabel(r), sel(findNavigate)));
}

String _findRowLabel(int r) {
  if (r < 0 || r >= gFindResults.length) return "";
  var rec = gFindResults[r];
  var cls = rec[0].toString();
  var member = (rec is List && rec.length > 1) ? rec[1].toString() : "";
  var side = (rec is List && rec.length > 2) ? rec[2].toString() : "";
  var sep = (side == 'class') ? "  class >>  " : "  >>  ";
  return member.length > 0 ? (cls + sep + member) : cls;
}

String _sqEsc(String s) => s.replaceAll("'", "''");   // ST single-quote escape

void runFind(String cmd) {
  var term = gFindField.stringValue().UTF8String().trim();   // NSTextField -> stringValue
  if (term.length == 0) { gFindResults = <dynamic>[]; gFindTable.reloadData(); repaint(); return; }
  ask(cmd, term).then((r) {
    gFindResults = _dl(r);
    gFindTable.reloadData();
    repaint();
    log((cmd == 'senders' ? "Senders of '" : "Find '") + term + "' — " + gFindResults.length.toString() + " result(s)");
  });
}

// Click a result → open the Browser and REVEAL that class + method. The live
// Browser tab is MACVM's CocoaBrowser2 (Sprint 15a); the old gClassTable browser
// is dead code, which is why the previous version — driving gClassTable — landed
// "in a random place". Drive the real browser: it finds the class's package,
// selects the package/class/side/method, and highlights the rows.
void findNavigate(int row) {
  if (row < 0 || row >= gFindResults.length) return;
  var rec = gFindResults[row];
  var cls = rec[0].toString();
  var sel = (rec is List && rec.length > 1) ? rec[1].toString() : "";
  var side = (rec is List && rec.length > 2) ? rec[2].toString() : "instance";
  gTabView.selectTabViewItemAtIndex(1);   // the Browser (CocoaBrowser2)
  // `ask`s serialize into the language isolate, so this reveal runs after the
  // tab-switch's own doRefresh and wins the selection.
  ask('doit', "st> CocoaBrowser2 revealClass: '" + _sqEsc(cls) +
      "' selector: '" + _sqEsc(sel) + "' side: '" + side + "'. nil")
      .then((r) { log("Find → " + cls + (sel.isEmpty ? "" : " >> " + sel)); });
}

// --- Syntax highlighting ----------------------------------------------------
final Set<String> _dartKeywords = new Set<String>.from(<String>[
  'abstract','as','assert','async','await','break','case','catch','class','const',
  'continue','default','deferred','do','dynamic','else','enum','export','extends',
  'external','factory','false','final','finally','for','get','if','implements',
  'import','in','is','library','new','null','operator','part','rethrow','return',
  'set','static','super','switch','sync','this','throw','true','try','typedef',
  'var','void','while','with','yield','bool','int','double','num',
]);

bool _isDigit(int c) => c >= 0x30 && c <= 0x39;
bool _isHex(int c) => _isDigit(c) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66);
bool _isUpper(int c) => c >= 0x41 && c <= 0x5A;
bool _isAlpha(int c) => _isUpper(c) || (c >= 0x61 && c <= 0x7A);
bool _isIdentStart(int c) => _isAlpha(c) || c == 0x5F || c == 0x24;
bool _isIdentPart(int c) => _isIdentStart(c) || _isDigit(c);

List<int> lexDart(String s) {
  var out = <int>[];
  var n = s.length, i = 0;
  while (i < n) {
    var c = s.codeUnitAt(i);
    if (c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D) { i++; continue; }
    if (c == 0x2F && i + 1 < n) {                       // '/'
      var d = s.codeUnitAt(i + 1);
      if (d == 0x2F) {                                  // // line comment
        var st = i; while (i < n && s.codeUnitAt(i) != 0x0A) i++;
        out..add(st)..add(i - st)..add(3); continue;
      }
      if (d == 0x2A) {                                  // /* block comment */
        var st = i; i += 2;
        while (i + 1 < n && !(s.codeUnitAt(i) == 0x2A && s.codeUnitAt(i + 1) == 0x2F)) i++;
        i = (i + 1 < n) ? i + 2 : n;
        out..add(st)..add(i - st)..add(3); continue;
      }
    }
    if (c == 0x27 || c == 0x22) {                       // ' or " string
      var st = i, q = c;
      var triple = i + 2 < n && s.codeUnitAt(i + 1) == q && s.codeUnitAt(i + 2) == q;
      if (triple) {
        i += 3;
        while (i + 2 < n && !(s.codeUnitAt(i) == q && s.codeUnitAt(i + 1) == q && s.codeUnitAt(i + 2) == q)) {
          if (s.codeUnitAt(i) == 0x5C) i++;
          i++;
        }
        i = (i + 2 < n) ? i + 3 : n;
      } else {
        i++;
        while (i < n && s.codeUnitAt(i) != q && s.codeUnitAt(i) != 0x0A) {
          if (s.codeUnitAt(i) == 0x5C) i++;
          i++;
        }
        if (i < n && s.codeUnitAt(i) == q) i++;
      }
      out..add(st)..add(i - st)..add(2); continue;
    }
    if (_isDigit(c)) {                                  // number
      var st = i;
      if (c == 0x30 && i + 1 < n && (s.codeUnitAt(i + 1) == 0x78 || s.codeUnitAt(i + 1) == 0x58)) {
        i += 2; while (i < n && _isHex(s.codeUnitAt(i))) i++;
      } else {
        while (i < n) {
          var d = s.codeUnitAt(i);
          if (_isDigit(d) || d == 0x2E || d == 0x65 || d == 0x45 || d == 0x5F) i++; else break;
        }
      }
      out..add(st)..add(i - st)..add(4); continue;
    }
    if (_isIdentStart(c)) {                             // identifier / keyword / type
      var st = i; i++;
      while (i < n && _isIdentPart(s.codeUnitAt(i))) i++;
      var word = s.substring(st, i);
      var kind = _dartKeywords.contains(word) ? 1 : (_isUpper(c) ? 5 : 0);
      out..add(st)..add(i - st)..add(kind); continue;
    }
    i++;                                                // punctuation / other
  }
  return out;
}


// --- Smalltalk ---------------------------------------------------------------
// The Dart lexer cannot read this dialect, and the way it fails is loud: a `"`
// opens a Dart string that ENDS AT THE NEWLINE, so the first line of a
// Smalltalk comment came out as a string and every line after it was lexed as
// CODE — a multi-line comment rendered as a rainbow of keywords, numbers and
// types. Which is most of this corpus, since its classes document themselves in
// long "..." blocks.
//
// So: lex Smalltalk as Smalltalk. Comments are "..." (doubled "" escapes,
// spanning lines), strings are '...' (doubled ''), plus $c characters, #symbols
// and #(literal arrays), radix and scaled numbers, and <pragmas>.
final Set<String> _stKeywords = new Set<String>.from(<String>[
  'self', 'super', 'true', 'false', 'nil', 'thisContext',
]);

List<int> lexSmalltalk(String s) {
  var out = <int>[];
  var n = s.length, i = 0;
  while (i < n) {
    var c = s.codeUnitAt(i);
    if (c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D) { i++; continue; }
    if (c == 0x22) {                                    // "comment", "" escapes
      var st = i; i++;
      while (i < n) {
        if (s.codeUnitAt(i) == 0x22) {
          if (i + 1 < n && s.codeUnitAt(i + 1) == 0x22) { i += 2; continue; }
          i++; break;
        }
        i++;
      }
      out..add(st)..add(i - st)..add(3); continue;
    }
    if (c == 0x27) {                                    // 'string', '' escapes
      var st = i; i++;
      while (i < n) {
        if (s.codeUnitAt(i) == 0x27) {
          if (i + 1 < n && s.codeUnitAt(i + 1) == 0x27) { i += 2; continue; }
          i++; break;
        }
        i++;
      }
      out..add(st)..add(i - st)..add(2); continue;
    }
    if (c == 0x24) {                                    // $c character literal
      var st = i;
      i += (i + 1 < n) ? 2 : 1;
      out..add(st)..add(i - st)..add(2); continue;
    }
    if (c == 0x23) {                                    // #symbol / #(array
      var st = i; i++;
      if (i < n && s.codeUnitAt(i) == 0x27) {           // #'quoted symbol'
        i++;
        while (i < n && s.codeUnitAt(i) != 0x27) i++;
        if (i < n) i++;
      } else {
        while (i < n) {
          var d = s.codeUnitAt(i);
          if (_isIdentPart(d) || d == 0x3A) i++; else break;   // keyword runs
        }
      }
      out..add(st)..add(i - st)..add(5); continue;      // a literal, like a type
    }
    if (c == 0x3C && _stPragmaAt(s, i)) {               // <primitive: 42>
      var st = i;
      while (i < n && s.codeUnitAt(i) != 0x3E) i++;
      if (i < n) i++;
      out..add(st)..add(i - st)..add(1); continue;
    }
    if (_isDigit(c)) {                                  // 42, 3.14, 16r1F, 2e8
      var st = i;
      while (i < n) {
        var d = s.codeUnitAt(i);
        if (_isDigit(d) || d == 0x2E || d == 0x72 || d == 0x65 || d == 0x73 ||
            _isHex(d)) {
          // a '.' only continues the number when a digit follows (else it is
          // the statement terminator)
          if (d == 0x2E && !(i + 1 < n && _isDigit(s.codeUnitAt(i + 1)))) break;
          i++;
        } else break;
      }
      out..add(st)..add(i - st)..add(4); continue;
    }
    if (_isIdentStart(c)) {                             // identifier / keyword
      var st = i; i++;
      while (i < n && _isIdentPart(s.codeUnitAt(i))) i++;
      if (i < n && s.codeUnitAt(i) == 0x3A) i++;        // a keyword part, at:put:
      var word = s.substring(st, i);
      var kind = _stKeywords.contains(word) ? 1 : (_isUpper(c) ? 5 : 0);
      out..add(st)..add(i - st)..add(kind); continue;
    }
    i++;                                                // punctuation / binary
  }
  return out;
}

/// `<` opens a pragma when what follows is a keyword (`<primitive: 42>`,
/// `<stprim: foo>`) — otherwise it is the binary selector `<`.
bool _stPragmaAt(String s, int i) {
  var j = i + 1;
  while (j < s.length && s.codeUnitAt(j) == 0x20) j++;
  var st = j;
  while (j < s.length && _isIdentPart(s.codeUnitAt(j))) j++;
  return j > st && j < s.length && s.codeUnitAt(j) == 0x3A;
}

/// Is this buffer Smalltalk? The shapes that only occur there: a class
/// definition, a method reopen, or a `st>` do-it. Deliberately cheap and
/// deliberately conservative — Dart source must never be lexed as Smalltalk.
bool looksSmalltalk(String s) {
  if (s == null || s.isEmpty) return false;
  if (new RegExp(r'^\s*st>', multiLine: true).hasMatch(s)) return true;
  if (new RegExp(r'\bsubclass:\s*\w+\s*\[').hasMatch(s)) return true;
  if (new RegExp(r'(?:^|\n)\s*\w+(?:\s+class)?\s*>>\s*\w').hasMatch(s)) return true;
  if (new RegExp(r'(?:^|\n)\s*\w+\s+extend\s*\[').hasMatch(s)) return true;
  return false;
}

const List<String> _kSpanKindNames = const <String>[
  'plain', 'keyword', 'string', 'comment', 'number', 'type'
];

void highlightView(Cocoa tv) {
  if (tv == null) return;
  var src = tv.string().UTF8String();
  applySpans(tv, looksSmalltalk(src) ? lexSmalltalk(src) : lexDart(src));
}

void highlight() => highlightView(gEditor);

// The selected text, or the whole buffer if there's no selection. Dart strings
// and NSString ranges are both UTF-16, so the offsets line up directly.
String currentCode() {
  var full = gEditor.string().UTF8String();
  var r = gEditor.selectedRange();          // [location, length]
  var loc = r[0], len = r[1];
  if (len > 0 && loc + len <= full.length) return full.substring(loc, loc + len);
  return full.trim();
}

void run(bool printIt) {
  var code = currentCode();
  if (code.trim().isEmpty) { log("(nothing to run)"); return; }
  var oneLine = code.replaceAll('\n', ' ');
  log((printIt ? "Print It ▶ " : "Do It ▶ ") +
      (oneLine.length > 64 ? oneLine.substring(0, 64) + "…" : oneLine));
  ask('doit', code).then((r) { log("   ⟹   " + r); updateMetrics(); });
}

// Accept: commit the editor's top-level declarations to the language isolate.
// They go LIVE via hot reload (existing instances morph) and are written to the
// SQLite image, so they persist and survive a watchdog respawn — unlike Do It,
// which evaluates transiently.
void acceptEditor() {
  var decls = editorDecls(gEditor.string().UTF8String());
  if (decls.isEmpty) { log("(nothing to accept)"); return; }
  guardedAccept(decls, "Accept", () {
    ask('acceptMany', decls).then((r) {
      if (r.startsWith('accepted')) {
        log("✓ Accept — " + r);
      } else {
        log("Accept failed — " + r);
      }
      updateMetrics();
    });
  });
}

// Split source into top-level declarations (class / enum / typedef / var /
// function), respecting strings and comments. A unit ends at a top-level '}'
// (depth returns to 0) or a top-level ';'.
/// Split an editor buffer into top-level declarations, in the RIGHT language.
/// Smalltalk source (an ST class/extend decl, after any leading "..."
/// comments) must NOT go through the Dart splitter — its `"..."` comments read
/// as unterminated Dart string literals (the "Save to Image refused" the user
/// hit). ST buffers split on `[`/`]` class-bracket depth (respecting
/// "comments", 'strings', and $c literals); a single loaded class returns as
/// one decl.
List<String> editorDecls(String s) {
  return _wsIsSt(s) ? _splitStTopLevel(s) : splitTopLevel(s);
}

List<String> _splitStTopLevel(String s) {
  var out = <String>[];
  var n = s.length, i = 0, start = 0, depth = 0;
  var seen = false;                 // a `[` has opened the current decl
  while (i < n) {
    var c = s.codeUnitAt(i);
    if (c == 0x22) {                // "comment"
      i++;
      while (i < n) {
        if (s.codeUnitAt(i) == 0x22) {
          if (i + 1 < n && s.codeUnitAt(i + 1) == 0x22) { i += 2; continue; }
          i++; break;
        }
        i++;
      }
      continue;
    }
    if (c == 0x27) {                // 'string'
      i++;
      while (i < n) {
        if (s.codeUnitAt(i) == 0x27) {
          if (i + 1 < n && s.codeUnitAt(i + 1) == 0x27) { i += 2; continue; }
          i++; break;
        }
        i++;
      }
      continue;
    }
    if (c == 0x24 && i + 1 < n) { i += 2; continue; }   // $c literal
    if (c == 0x5B) { depth++; seen = true; i++; continue; }   // [
    if (c == 0x5D) {                                          // ]
      i++;
      if (depth > 0) depth--;
      if (depth == 0 && seen) {
        var d = s.substring(start, i).trim();
        if (d.length > 0) out.add(d);
        start = i; seen = false;
      }
      continue;
    }
    i++;
  }
  var tail = s.substring(start).trim();
  if (tail.length > 0) out.add(tail);
  return out;
}

List<String> splitTopLevel(String s) {
  var out = <String>[];
  var n = s.length, i = 0, start = 0, depth = 0;
  while (i < n) {
    var c = s.codeUnitAt(i);
    if (c == 0x2F && i + 1 < n) {                       // comments
      var d = s.codeUnitAt(i + 1);
      if (d == 0x2F) { while (i < n && s.codeUnitAt(i) != 0x0A) i++; continue; }
      if (d == 0x2A) {
        i += 2;
        while (i + 1 < n && !(s.codeUnitAt(i) == 0x2A && s.codeUnitAt(i + 1) == 0x2F)) i++;
        i = (i + 1 < n) ? i + 2 : n; continue;
      }
    }
    if (c == 0x27 || c == 0x22) {                       // strings
      var q = c;
      var triple = i + 2 < n && s.codeUnitAt(i + 1) == q && s.codeUnitAt(i + 2) == q;
      if (triple) {
        i += 3;
        while (i + 2 < n && !(s.codeUnitAt(i) == q && s.codeUnitAt(i + 1) == q && s.codeUnitAt(i + 2) == q)) {
          if (s.codeUnitAt(i) == 0x5C) i++; i++;
        }
        i = (i + 2 < n) ? i + 3 : n;
      } else {
        i++;
        while (i < n && s.codeUnitAt(i) != q && s.codeUnitAt(i) != 0x0A) {
          if (s.codeUnitAt(i) == 0x5C) i++; i++;
        }
        if (i < n && s.codeUnitAt(i) == q) i++;
      }
      continue;
    }
    if (c == 0x7B) { depth++; i++; continue; }           // {
    if (c == 0x7D) {                                     // }
      i++;
      if (depth > 0) depth--;
      if (depth == 0) { var d = s.substring(start, i).trim(); if (d.length > 0) out.add(d); start = i; }
      continue;
    }
    if (c == 0x3B && depth == 0) {                       // ; at top level
      i++; var d = s.substring(start, i).trim(); if (d.length > 0) out.add(d); start = i; continue;
    }
    i++;
  }
  var tail = s.substring(start).trim();
  if (tail.length > 0) out.add(tail);
  return out;
}

// --- Menu bar ---------------------------------------------------------------
Cocoa menuItem(Cocoa menu, String title, String key, CocoaAction fn) {
  var it = Cocoa.cls("NSMenuItem").alloc().init();
  it.setTitle(title);
  if (key.length > 0) it.setKeyEquivalent(key);   // Command modifier is default
  menu.addItem(it);
  gTargets.add(onAction(it, (s) => defer(() => fn(s))));   // see [defer]
  return it;
}

// --- main menu --------------------------------------------------------------
// Modifier masks for setKeyEquivalentModifierMask: (Command is implied by
// setKeyEquivalent:, so it is only spelled out when combining).
const int kCmd = 1 << 20, kShift = 1 << 17, kCtrl = 1 << 18, kOpt = 1 << 19;

Cocoa menuSep(Cocoa menu) {
  var it = Cocoa.cls("NSMenuItem").separatorItem();
  menu.addItem(it);
  return it;
}

Cocoa subMenu(Cocoa mainMenu, String title) {
  var item = Cocoa.cls("NSMenuItem").alloc().init();
  item.setTitle(title);
  mainMenu.addItem(item);
  var m = Cocoa.cls("NSMenu").alloc().initWithTitle(title);
  item.setSubmenu(m);
  return m;
}

/// A menu item bound to one of Cocoa's OWN editing selectors, with a nil target
/// so AppKit walks the responder chain to whatever currently has focus. This is
/// what makes Cut/Copy/Paste/Undo work in the focused text view — routing them
/// through our own action target instead would send them nowhere useful.
Cocoa stdItem(Cocoa menu, String title, String key, String selector, [int mask = 0]) {
  var it = Cocoa.cls("NSMenuItem").alloc().init();
  it.setTitle(title);
  if (key.length > 0) it.setKeyEquivalent(key);
  if (mask != 0) it.setKeyEquivalentModifierMask(mask);
  menu.addItem(it);
  setSelectorAction(it, selector);   // target nil -> responder chain
  return it;
}

// ⌘S means "commit what is in front of me", which differs per tab.
void menuSave() {
  if (gTab == 4) { editorSaveImage(); return; }
  // Tab 1 is the embedded Smalltalk browser (CocoaBrowser2); it commits through
  // its own Accept button, so ⌘S here falls through to the workspace editor.
  acceptEditor();
}

// Undo the most recent persisted image edit, via the append-only version history
// in the SQLite image (Debug ▸ Roll Back Last Change). askDeferrable so a reload
// that stops at a breakpoint can't deadlock; then refresh the browser view.
Future rollbackLast() async {
  var r = await askDeferrable('rollback', '');
  log("Roll Back — " + r.toString());
  if (!r.toString().startsWith("ERR")) {
    ask('doit', 'st> CocoaBrowser2 doRefresh. nil').then((_) {});
  }
}

void buildMenu() {
  // With no .app bundle there is no CFBundleName, so macOS titles the
  // application menu from the process name — "dartui" without this.
  Cocoa.cls("NSProcessInfo").processInfo().setProcessName("MACDART");
  var app = Cocoa.cls("NSApplication").sharedApplication();
  var mainMenu = Cocoa.cls("NSMenu").alloc().init();

  // The first menu is the application menu; macOS titles it from the process.
  var appItem = Cocoa.cls("NSMenuItem").alloc().init();
  mainMenu.addItem(appItem);
  var appMenu = Cocoa.cls("NSMenu").alloc().init();
  appItem.setSubmenu(appMenu);
  stdItem(appMenu, "Quit MACDART", "q", "terminate:");

  var file = subMenu(mainMenu, "File");
  menuItem(file, "New Class", "n", (s) { switchTab(4); editorNew(); });
  menuItem(file, "Open…", "o", (s) { switchTab(4); editorOpen(); });
  menuItem(file, "Save File…", "S", (s) { switchTab(4); editorSaveFile(); })
      .setKeyEquivalentModifierMask(kCmd + kShift);
  menuItem(file, "File In…", "i", (s) { switchTab(4); editorFileIn(); });
  menuSep(file);
  menuItem(file, "Save", "s", (s) => menuSave());

  // Cocoa's own editing commands, dispatched through the responder chain.
  var edit = subMenu(mainMenu, "Edit");
  stdItem(edit, "Undo", "z", "undo:");
  stdItem(edit, "Redo", "Z", "redo:", kCmd + kShift);
  menuSep(edit);
  stdItem(edit, "Cut", "x", "cut:");
  stdItem(edit, "Copy", "c", "copy:");
  stdItem(edit, "Paste", "v", "paste:");
  stdItem(edit, "Delete", "", "delete:");
  menuSep(edit);
  stdItem(edit, "Select All", "a", "selectAll:");

  var code = subMenu(mainMenu, "Code");
  menuItem(code, "Do It", "d", (s) => run(false));
  menuItem(code, "Print It", "p", (s) => run(true));
  menuSep(code);
  menuItem(code, "Format", "f", (s) { switchTab(4); editorFormat(); })
      .setKeyEquivalentModifierMask(kCmd + kOpt);
  menuItem(code, "Analyze", "b", (s) { switchTab(4); editorAnalyze(); });

  // Demos: standalone programs from demos/ beside the UI source. A .dart demo
  // spawns into its own isolate, drawing on the Demos tab's canvas through
  // this isolate; a .mst demo installs into the running image instead and
  // plays live through the ST-game pull-tick loop (runStFileDemo) — same
  // dual-language colocation apps/ already has via scanApps. The menu IS the
  // folder — drop a file in, Rescan, run it.
  // The PLAYABLE games are filed under their own Games menu (below); Demos
  // keeps the visual/benchmark pieces (Copper is an effect, so it stays).
  var demos = subMenu(mainMenu, "Demos");
  var found = scanDemos();
  var dartGames = <List>[];
  var shows = <List>[];
  for (var d in found) {
    var base = d[1].toString().split('/').last;
    if (base.contains('brickout') || base.contains('invaders') ||
        base.contains('pong') || (d.length > 2 && d[2] == 'game')) {
      dartGames.add(d);
    } else {
      shows.add(d);
    }
  }
  if (shows.isEmpty) {
    menuItem(demos, "(no demos found in demos/)", "", (s) {});
  }
  for (var d in shows) {
    var title = d[0], path = d[1];
    menuItem(demos, title, "", (s) => runScannedDemo(title, path));
  }
  // Sprint 15b: the Smalltalk graphics tier, rendered into the SAME pane — its
  // HTML5-canvas / pixmap output is translated to the pane's draw-ops. The
  // list comes from the language isolate (present iff the world is imported).
  menuSep(demos);
  stAddDemoMenu(demos);
  menuSep(demos);
  menuItem(demos, "Stop Demo", ".", (s) => stopDemo("stopped"));
  menuItem(demos, "Rescan Demos Folder", "", (s) {
    buildMenu();   // setMainMenu: replaces the bar, so this rescans cleanly
    log("demos rescanned — " + scanDemos().length.toString() + " found");
  });

  // Games: the playable ones. Dart games run in their own isolates exactly as
  // demos do; the Smalltalk games are the world's 44_breakout/48a_worms driven
  // one tick at a time by the language isolate over the same pane wire
  // (GAMEPANE_PLAN.md §8 — arrows steer, space/Z = A, X = B).
  var games = subMenu(mainMenu, "Games");
  for (var d in dartGames) {
    var title = d[0], path = d[1];
    menuItem(games, title, "", (s) => runScannedDemo(title, path));
  }
  if (dartGames.isNotEmpty) menuSep(games);
  menuItem(games, "Smalltalk Breakout", "", (s) => runStGame("Breakout"));
  menuItem(games, "Smalltalk Worms", "", (s) => runStGame("Worms"));
  menuItem(games, "Smalltalk MandelZoom", "", (s) => runStGame("MandelZoom"));
  menuItem(games, "Smalltalk MandelVM", "", (s) => runStGame("MandelVM"));
  menuItem(games, "Smalltalk FFT", "", (s) => runStGame("FFT"));
  menuSep(games);
  menuItem(games, "Sprite Editor", "", (s) => spriteEdShow(''));
  menuItem(games, "Sound Editor", "", (s) => soundEdShow(''));
  menuSep(games);
  menuItem(games, "Stop Game", "", (s) => stopDemo("stopped"));

  // Apps: your own Cocoa apps, running on the App pane. The examples in apps/
  // are filed into the image (through the usual compile gate) and then run —
  // after that they are ordinary image classes you edit in the Browser.
  var apps = subMenu(mainMenu, "Apps");
  var examples = scanApps();
  for (var a in examples) {
    var title = a[0], path = a[1];
    menuItem(apps, "Install " + title, "", (s) => installApp(title, path));
  }
  if (examples.isNotEmpty) menuSep(apps);
  menuItem(apps, "Run Selected", "", (s) {
    if (gAppPicker == null || gAppPicker.numberOfItems() == 0) {
      log("no app classes in the image (an app is a class with a build(ui) method)");
      return;
    }
    appRun(gAppPicker.titleOfSelectedItem().UTF8String());
  });
  menuItem(apps, "Stop App", "", (s) => appStop());

  var view = subMenu(mainMenu, "View");
  menuItem(view, "Workspace", "1", (s) => switchTab(0));
  menuItem(view, "Browser", "2", (s) => switchTab(1));
  menuItem(view, "Editor", "3", (s) => switchTab(4));
  menuItem(view, "Find", "4", (s) => switchTab(3));
  menuItem(view, "Docs", "5", (s) => switchTab(2));
  menuItem(view, "Debugger", "6", (s) => switchTab(5));
  menuItem(view, "Demos", "7", (s) => switchTab(6));
  menuItem(view, "App", "8", (s) => switchTab(7));
  menuSep(view);
  // Title and state are set by [layoutChrome], which runs after this — the menu is
  // built before the dock exists.
  gDockMenuItem = menuItem(view, "Hide Transcript", "t",
                           (s) => setDock(!gDockCollapsed));
  menuItem(view, "Clear Transcript", "k", (s) {
    gLog.clear(); gTranscript.setString(""); dockShowLast(); repaint();
  });

  // The workspace's own sources, editable from inside itself.
  var own = subMenu(mainMenu, "Source");
  menuItem(own, "Edit workspace.dart", "", (s) => editProjectFile('workspace'));
  menuItem(own, "Edit language.dart", "", (s) => editProjectFile('language'));
  menuItem(own, "Edit cocoa.dart", "", (s) => editProjectFile('cocoa'));

  // Debug: the UI's own lifecycle. Reload swaps the code; Rebuild re-runs
  // buildChrome so layout changes land; Revert is the way back from an edit that
  // compiled but misbehaves.
  var dbg = subMenu(mainMenu, "Debug");
  menuItem(dbg, "Reload UI from Source", "r", (s) => reloadUi())
      .setKeyEquivalentModifierMask(kCmd + kCtrl);
  menuItem(dbg, "Rebuild UI Layout", "l", (s) => rebuildUi())
      .setKeyEquivalentModifierMask(kCmd + kCtrl);
  menuItem(dbg, "Revert UI to Last Good", "", (s) => revertUi());
  menuItem(dbg, "Roll Back Last Change", "", (s) => rollbackLast());
  menuSep(dbg);
  menuItem(dbg, "Restart Language Isolate", "", (s) => respawnLanguage("restart from the Debug menu"));
  menuSep(dbg);
  menuItem(dbg, "Attach Debugger", "", (s) { switchTab(5); dbgAttach(); });
  menuSep(dbg);
  // Proves the recovery path actually recovers. Post-startup a thrown callback
  // is survivable: the host logs it and keeps the window.
  menuItem(dbg, "Raise a Test Error", "", (s) {
    log("raising a deliberate error — the window should survive it");
    throw "deliberate test error from the Debug menu";
  });

  app.setMainMenu(mainMenu);
}

// Time-boxed request to the language isolate. If it doesn't reply in time the
// isolate is presumed hung (a runaway do-it), and the watchdog kills + respawns
// it so the workspace can never wedge.
// A request the WATCHDOG MUST IGNORE. The metrics poll runs continuously, so if
// it went through ask() a long-running do-it would make it time out and the
// watchdog would kill the user's language isolate mid-computation — the poll
// would be shooting the thing it is measuring. This just gives up quietly
// instead, and never logs: the isolate is busy, which is not an error.
Future askQuiet(String cmd, var arg, Duration limit) async {
  if (gLang == null) return null;
  var rp = new ReceivePort();
  gLang.send([cmd, arg, rp.sendPort]);
  var result = await rp.first.timeout(limit, onTimeout: () => _kTimeout);
  rp.close();
  return identical(result, _kTimeout) ? null : result;
}

// While the debugger holds the language isolate stopped, the watchdog must not
// count that as a runaway. Without this it kills the very isolate you are
// debugging: sitting on a breakpoint for six seconds produced
// "'doit' timed out — killed runaway code — restarting language isolate".
// A plain timeout cannot tell "paused at a breakpoint" from "while(true)"; the
// debugger can, so it raises this and the clock stops.
int gDebugHold = 0;

void debugHold() { gDebugHold++; }
void debugRelease() { if (gDebugHold > 0) gDebugHold--; }
bool get debugHolding => gDebugHold > 0;

/// Store declarations formatted, so the image never holds a one-liner. A class
/// on a single line has no body line for a breakpoint to resolve on — that is
/// what made Counter undebuggable. Falls back to the original text if formatting
/// would change anything but layout, so this can never damage a declaration.
List formatDecls(List decls) {
  var out = <dynamic>[];
  for (var d in decls) {
    var src = d.toString();
    var f;
    try { f = formatDart(src); } catch (e) { out.add(src); continue; }
    out.add(_tokenSignature(f) == _tokenSignature(src) ? f : src);
  }
  return out;
}

// Outstanding work a driver can wait on: requests in flight (gAskPending) and
// long UI-initiated jobs that are not yet requests (gBusy — a compile check
// runs a whole `dart --compile_all` before the accept it gates). See `settle`.
int gAskPending = 0;
int gBusy = 0;

/// Return when the workspace has finished what it is doing. Scripts used fixed
/// sleeps before, which is guesswork that silently rots: when the compile gate
/// came back the accepts got slower and every `after 4000` in the suite became
/// a coin toss.
Future workSettle([int maxMs = 30000]) async {
  // The click that started the work is a queued message that has not run yet.
  await new Future.delayed(const Duration(milliseconds: 5));
  var waited = 0;
  while ((gAskPending > 0 || gBusy > 0 || gAppPending > 0) && waited < maxMs) {
    await new Future.delayed(const Duration(milliseconds: 20));
    waited += 20;
  }
  return waited < maxMs;
}

Future ask(String cmd, var arg) async {   // arg/result may be a String or a List
  if (gLang == null) return "ERR: language isolate restarting…";
  // A message sent now would QUEUE against the stopped isolate, invisibly, and
  // all fire the moment you press Continue — and with the watchdog rightly
  // suspended while paused, nothing would ever time it out. Refuse loudly.
  if (gDbgPaused && gDbgIsLang) {   // a paused DEMO must not block this channel
    return "ERR: the language isolate is stopped in the debugger — press "
           "Continue first ('" + cmd + "' was not sent; Evaluate works while paused)";
  }
  // Every accept path funnels through here, including the socket verbs, so this
  // is the one place formatting has to happen.
  if (cmd == 'acceptMany' || cmd == 'acceptLive') {
    if (arg is List) arg = formatDecls(arg);
  } else if (cmd == 'accept') {
    arg = formatDecls(<dynamic>[arg])[0];
  }
  var gen = gLangGen;   // which isolate this was sent to
  gAskPending++;
  try {
    return await _ask(cmd, arg, gen);
  } finally {
    gAskPending--;
  }
}

Future _ask(String cmd, var arg, int gen) async {
  var rp = new ReceivePort();
  gLang.send([cmd, arg, rp.sendPort]);

  // The deadline is checked on a tick rather than by Future.timeout, so time
  // spent stopped in the debugger can be given back instead of counted.
  var done = new Completer();
  var sub = rp.listen((msg) { if (!done.isCompleted) done.complete(msg); });
  var since = new Stopwatch()..start();
  var tick;
  tick = new Timer.periodic(const Duration(milliseconds: 250), (t) {
    if (done.isCompleted) { t.cancel(); return; }
    // The isolate this was sent to is gone (restarted under us — say, Restart
    // while it sat at a breakpoint). No reply is ever coming, and timing out
    // 6 seconds later would respawn the REPLACEMENT for a crime it didn't
    // commit. Fail the request now, respawn nothing.
    if (gLangGen != gen) {
      t.cancel();
      done.complete("ERR: " + cmd + " was lost — the language isolate was restarted");
      return;
    }
    if (debugHolding) { since.reset(); return; }   // stopped: not runaway
    if (since.elapsed >= _kDoitTimeout && !done.isCompleted) {
      t.cancel();
      done.complete(_kTimeout);
    }
  });

  var result = await done.future;
  tick.cancel();
  sub.cancel();
  rp.close();
  // An accept rewrites the scratch file, so every anchored breakpoint has to be
  // mapped to its new line and re-armed.
  if (!identical(result, _kTimeout) && gLangGen == gen &&
      (cmd == 'acceptMany' || cmd == 'acceptLive' || cmd == 'accept' ||
       cmd == 'remove') &&
      gLangIsolateId != null) {
    await dbgReResolve();
  }
  // An Accept morphed the running app's instance; re-running build() puts the
  // new layout on screen with the app's state intact.
  if (!identical(result, _kTimeout) && gLangGen == gen && gAppName != null &&
      (cmd == 'acceptMany' || cmd == 'acceptLive' || cmd == 'accept')) {
    await appRebuild();
  }
  if (identical(result, _kTimeout)) {
    await respawnLanguage("'" + cmd + "' timed out — killed runaway code");
    return "ERR: " + cmd + " timed out (isolate restarted)";
  }
  return result;
}

// --- answering the socket while user code is stopped -------------------------
// A socket verb that runs user code can stop at a breakpoint, and then its
// reply cannot exist until Continue. Holding the RPC open for that parks the
// client against its read deadline — on the ONE connection, that is the suite's
// old hang in new clothes. So: if the language isolate pauses while such a verb
// is still in flight, answer NOW with what is true ("stopped in the debugger"),
// and hand the real result to the transcript when it finally lands.
List<Completer> _pauseGates = <Completer>[];

void _tripPauseGates() {
  var gates = _pauseGates;
  _pauseGates = <Completer>[];
  for (var c in gates) { if (!c.isCompleted) c.complete(); }
}

final Object _kParked = new Object();

Future<String> askDeferrable(String cmd, var arg) async {
  var gate = new Completer();
  _pauseGates.add(gate);
  var work = ask(cmd, arg);
  var r = await Future.any(<Future>[
    work,
    gate.future.then((_) => _kParked),
  ]);
  _pauseGates.remove(gate);   // won or lost, this race is decided
  if (!identical(r, _kParked)) return r.toString();
  work.then((real) => log("(after the pause) " + cmd + " => " + real.toString()));
  return "stopped in the debugger — '" + cmd + "' is parked at a breakpoint; "
         "its result will print on Continue";
}

// Spawn the language isolate from the scratch file, with error/exit monitoring.
//
// The port STAYS OPEN after the handshake. It used to be `await fromLang.first`
// then close, which left the language isolate unable to speak first — and a
// user app that repaints on a Timer has no request to answer, so it needs to.
// The first SendPort to arrive is the handshake; everything after is a push.
ReceivePort gFromLang;

Future spawnLanguage() async {
  var gen = ++gLangGen;
  if (gFromLang != null) gFromLang.close();     // never leak the old generation
  gFromLang = new ReceivePort();
  var handshake = new Completer();
  gFromLang.listen((msg) {
    if (msg is SendPort) {
      if (!handshake.isCompleted) handshake.complete(msg);
      return;
    }
    if (msg is List && msg.length > 3 && msg[0] == 'appui') onAppPush(msg);
    // An ST game (GAMEPANE_PLAN.md §8): the language isolate acts as a pull
    // demo, pushing the same ['port',ctl]/['draw',cmds]/['done',s] envelope a
    // demo isolate sends — feed those into the demo machinery unchanged.
    if (gStGameActive && msg is List && msg.isNotEmpty &&
        (msg[0] == 'draw' || msg[0] == 'port' || msg[0] == 'status' ||
         msg[0] == 'done')) {
      _onDemoMsg(msg);
      return;
    }
    // Smalltalk `Transcript show: ...; cr` lines from the language isolate.
    if (msg is List && msg.length == 2 && msg[0] == 'tr') log(msg[1].toString());
  });
  var errPort = new ReceivePort();
  var exitPort = new ReceivePort();
  // The language isolate boots from a temp scratch file, so it cannot resolve
  // the source tree itself — hand it the on-disk Dart library sources (the same
  // the VM was built from) so the Browser can show the REAL source of the
  // read-only libraries (dart:core, dart:cocoa, …), not just mirror signatures.
  var sdkLib = Platform.script.resolve('../../sdk/lib').toFilePath();
  var cocoaSrc = Platform.script.resolve('../cocoa.dart').toFilePath();
  // The language isolate runs from a MUTABLE COPY in /tmp (it rewrites its own
  // root file on reload), so it cannot find anything by its own script path.
  // The vendored Smalltalk world is one of those things, and it needs it to
  // notice when the image's copy has gone stale — so hand it over from here.
  var worldDir = Platform.script.resolve('../../st/world/').toFilePath();
  gLangIsolate = await Isolate.spawnUri(
      Uri.parse('file://' + gScratch),
      <String>[gScratch, gDbPath, sdkLib, cocoaSrc, worldDir], gFromLang.sendPort,
      onError: errPort.sendPort, onExit: exitPort.sendPort, errorsAreFatal: false);
  gLang = await handshake.future;
  errPort.listen((e) {
    var m = (e is List && e.length > 0) ? e[0].toString() : e.toString();
    log("⚠ language error: " + m);
  });
  exitPort.listen((_) {
    exitPort.close();
    if (gen == gLangGen && !gRespawning) {
      respawnLanguage("language isolate exited unexpectedly");
    }
  });
}

// Kill the (possibly hung) language isolate and start a fresh one. The new
// isolate boots from the SQLite image (the source of truth), so accepted
// declarations come back automatically — MACVM's supervisor pattern. Live object
// state is an honest clean loss.
Future respawnLanguage(String why) async {
  if (gRespawning) return;
  gRespawning = true;
  log("⚠ " + why + " — restarting language isolate…");
  gLang = null;
  // A PAUSED isolate does not honour kill: Isolate.kill's OOB message queues
  // behind the debugger pause and is dropped with it, so a "restarted" isolate
  // that was sitting at a breakpoint lived on as a ZOMBIE. getVM then listed
  // two ws_lang isolates, vmsResolveTarget attached to the corpse (first
  // match), and every breakpoint after that was armed in an isolate nothing
  // would ever run again — the regress suite's paused/locals/eval trio, dead
  // deterministic. Resume every language isolate through the vm-service before
  // killing, so the kill lands in a running message loop. (No service = no
  // debugger = nothing can be paused, so skipping is sound, not lucky.)
  if (await vmsConnect()) {
    var vm = await vmsCall('getVM');
    if (vm != null) {
      for (var iso in vm['isolates']) {
        if (!iso['name'].toString().contains('macdart_ws_lang')) continue;
        await vmsCall('resume', <String, dynamic>{'isolateId': iso['id']});
      }
    }
  }
  try { if (gLangIsolate != null) gLangIsolate.kill(priority: Isolate.IMMEDIATE); } catch (e) {}
  // If the old isolate died sitting at a breakpoint, no Resume event is ever
  // coming for it. Left alone, gDbgPaused stays true and every ask() is refused
  // with "press Continue first" — a ghost pause over a corpse, which reads as
  // the whole app hanging. The pause died with its isolate; say so.
  dbgForgetPause("the stopped isolate was restarted — nothing is paused now");
  appOnRespawn();   // the user app's instance died with it too
  await spawnLanguage();   // boots from the image
  gRespawning = false;
  log("language isolate restarted (declarations reloaded from the image)");
  // Suspenders to the resume-first belt: if an old isolate is somehow still
  // listed, say so loudly — a silent zombie cost an afternoon of phantom
  // debugger failures before this existed.
  if (await vmsConnect()) {
    var vm = await vmsCall('getVM');
    if (vm != null) {
      var n = 0;
      for (var iso in vm['isolates']) {
        if (iso['name'].toString().contains('macdart_ws_lang')) n++;
      }
      if (n > 1) {
        log("⚠ " + (n - 1).toString() + " old language isolate(s) did not die "
            "— the debugger may attach to a corpse; restart the workspace");
      }
    }
  }
  guiEvent('languageRestarted', <String, String>{'why': why});
  stBrowserEmbed();   // the embedded ST browser died with its isolate
  if (gLangIsolateId != null && gDbgIsLang) {   // the debugger was ON the language
    if (await vmsResolveTarget()) {              // isolate: follow it to the new one.
      gDbgScratch = gScratch;                    // (a demo session is left alone)
      await vmsCall('streamListen', <String, dynamic>{'streamId': 'Debug'});
      await dbgReResolve();
    }
  }
  updateMetrics();
}

Future<String> snapshot(String path) async {
  var bounds = gContent.bounds();
  var rep = gContent.bitmapImageRepForCachingDisplayInRect(bounds);
  gContent.cacheDisplayInRect(bounds, toBitmapImageRep: rep);
  var dict = Cocoa.cls("NSDictionary").dictionary();
  var png = rep.representationUsingType(4, properties: dict);
  var ok = png.writeToFile(path, atomically: true);
  return (ok != 0 && ok != false) ? "ok " + path : "ERR write";
}

Future<String> handle(String line) async {
  var nl = line.indexOf('\n');
  line = (nl < 0 ? line : line.substring(0, nl)).trimRight();
  if (line.isEmpty) return "";
  var sp = line.indexOf(' ');
  var cmd = sp < 0 ? line : line.substring(0, sp);
  var arg = sp < 0 ? "" : line.substring(sp + 1);
  switch (cmd) {
    case 'ping': return "pong";
    case 'trtail': {
      // The Transcript's last N characters (default 400) — lets a headless
      // test verify what reached the pane (e.g. Smalltalk Transcript lines).
      var n = int.parse(arg.trim(), onError: (_) => 400);
      var s = gTranscript == null ? "" : gTranscript.string().UTF8String();
      return s.length <= n ? s : s.substring(s.length - n);
    }
    case 'prof': {
      // "prof [ms] [id|name|index]" — sample the target isolate's CPU profile
      // and return the hottest functions by SELF time. Read-only: the VM's
      // sampling profiler is always running; this windows and reads it, never
      // pausing anything. Default target is a running demo/game, else language.
      var toks = arg.trim().isEmpty ? <String>[] : arg.trim().split(new RegExp(r'\s+'));
      var ms = 1000;
      var want = '';
      if (toks.isNotEmpty) {
        var m = int.parse(toks[0], onError: (_) => -1);
        if (m > 0) { ms = m; toks = toks.sublist(1); }
        want = toks.join(' ');
      }
      var list = await profListIsolates();
      if (list.isEmpty) return "ERR: no isolates (vm-service down? start-gui.sh enables it)";
      var target = profPickDefault(list, want);
      if (target == null) return "ERR: no isolate matching '" + want + "'";
      if (!await profSample(target[0].toString(), ms)) return "ERR: no profile (is --profiler on?)";
      profShowRows();
      var lbl = _dbgIsoLabel(target[1].toString(), target[0].toString());
      return "profiled " + lbl + " over ~" + ms.toString() + "ms\n" + profReport(15);
    }
    case 'proftree': {
      // Like prof, but renders the inclusive CALL TREE (the path to hot code)
      // instead of the flat self-time list. Paths below 2% are pruned.
      var toks = arg.trim().isEmpty ? <String>[] : arg.trim().split(new RegExp(r'\s+'));
      var ms = 1000;
      var want = '';
      if (toks.isNotEmpty) {
        var m = int.parse(toks[0], onError: (_) => -1);
        if (m > 0) { ms = m; toks = toks.sublist(1); }
        want = toks.join(' ');
      }
      var list = await profListIsolates();
      if (list.isEmpty) return "ERR: no isolates (vm-service down?)";
      var target = profPickDefault(list, want);
      if (target == null) return "ERR: no isolate matching '" + want + "'";
      if (!await profSample(target[0].toString(), ms)) return "ERR: no profile (is --profiler on?)";
      var tree = profTreeReport(2.0);
      if (gProfSrc != null) gProfSrc.setString(tree);
      if (gProfStatusLbl != null) {
        gProfStatusLbl.setStringValue(gProfSamples == 0
            ? "0 samples — the isolate was idle"
            : (gProfSamples.toString() + " samples — inclusive call tree (paths >= 2%)"));
      }
      repaint();
      return "call tree of " + _dbgIsoLabel(target[1].toString(), target[0].toString()) +
             " over ~" + ms.toString() + "ms\n" + tree;
    }
    case 'profisolates': {                 // every isolate (UI included — read-only)
      var list = await profListIsolates();
      var o = <String>[];
      for (var i = 0; i < list.length; i++) {
        var e = list[i];
        o.add(i.toString() + "  " + e[1].toString() + "  " + e[0].toString() +
              (e[2] == true ? "  [ui]" : e[3] == true ? "  [lang]" : ""));
      }
      return o.isEmpty ? "(none)" : o.join('\n');
    }
    case 'profclear': {
      var list = await profListIsolates();
      if (list.isEmpty) return "ERR: no isolates";
      var t = profPickDefault(list, arg.trim());
      if (t == null) return "ERR: no isolate matching '" + arg.trim() + "'";
      await vmsCall('_clearCpuProfile', <String, dynamic>{'isolateId': t[0].toString()});
      gProfRows = <dynamic>[]; gProfSamples = 0; profShowRows();
      return "cleared " + _dbgIsoLabel(t[1].toString(), t[0].toString());
    }
    case 'dbgisolates': {                  // the attachable isolates (UI excluded)
      await dbgRefreshIsolates();
      var o = <String>[];
      for (var e in gDbgIsoList) {
        o.add(e[1].toString() + "  " + e[0].toString() + (e[2] == true ? "  [lang]" : ""));
      }
      return o.isEmpty ? "(none)" : o.join('\n');
    }
    case 'dbgattach': {
      // Optional arg selects the isolate by index or name substring (for
      // scripted attach); with none, the picker's current selection is used.
      await dbgRefreshIsolates();
      var want = arg.trim();
      if (want.isNotEmpty && gDbgIsoPicker != null) {
        for (var i = 0; i < gDbgIsoList.length; i++) {
          // Full isolate id first (stable across list churn), then a name
          // fragment; a bare index works but can race a changing list.
          if (gDbgIsoList[i][0].toString() == want || i.toString() == want ||
              gDbgIsoList[i][1].toString().contains(want)) {
            gDbgIsoPicker.selectItemAtIndex(i); break;
          }
        }
      }
      await dbgAttach();
      return gLangIsolateId == null ? "ERR: not attached"
          : (gLangIsolateId + (gDbgIsLang ? " [lang]" : " [raw]"));
    }
    case 'dbgbreak': {
      // "dbgbreak L" or "dbgbreak L if EXPR" — one shared path with the UI.
      var a = arg.trim();
      var cond = '';
      var sp = a.indexOf(' ');
      if (sp > 0) {
        var rest = a.substring(sp + 1).trim();
        a = a.substring(0, sp);
        if (rest.startsWith('if ')) cond = rest.substring(3).trim();
        else if (rest.isNotEmpty) return "ERR: dbgbreak L [if EXPR]";
      }
      var ln = int.parse(a, onError: (_) => 0);
      if (ln <= 0) return "ERR: dbgbreak L [if EXPR]";
      return await dbgAddBreak(ln, cond);
    }
    case 'dbgvars': {
      // One per line: values render with commas (_GrowableList(14), maps…),
      // so a comma join is ambiguous for the scripts that parse this.
      var o = <String>[];
      for (var v in gDbgVars) o.add(v[0].toString() + "=" + v[1].toString());
      return o.isEmpty ? "(none)" : o.join('\n');
    }
    case 'dbgframe': { dbgSelectFrame(int.parse(arg.trim(), onError: (_) => 0)); return "ok"; }
    case 'dbgeval': return await dbgEval(arg);   // the VALUE, not the status label
    case 'dbgquiet': {                 // 1: pauses stop yanking the GUI to tab 5
      gDbgQuiet = arg.trim() == '1';
      return gDbgQuiet ? "quiet (pauses leave the current tab)" : "surfacing";
    }
    case 'dbgsource': return gDbgSrc == null ? "" : gDbgSrc.string().UTF8String();
    case 'dbgstscript': {
      // Point the debugger at the ST script that DEFINES a class (so the
      // gutter click-sets real .mst breakpoints). arg = class name.
      var cls = arg.trim();
      if (cls.isEmpty) return "ERR: dbgstscript <ClassName>";
      var sid = await _dbgFindStScript(cls);
      if (sid == null) return "ERR: no ST script defines " + cls;
      return await dbgLoadStScript(sid, cls);
    }
    case 'dbggutter': {                    // the gutter's current dots, for tests
      var lines = <int>[];
      for (var b in gDbgBreaks) lines.add(b.line);
      return "breaks=" + lines.join(',') + " paused=" + gDbgPauseLine.toString();
    }
    // "paused at <fn>:<line>, K frames" — the line is what lets a stepping
    // agent VERIFY the step moved (top-frame names rarely change mid-function).
    case 'dbgstate': {
      if (!gDbgPaused) return "running";
      var at = gDbgFrames.isEmpty ? "?" : gDbgFrames[0][0].toString();
      if (gDbgFrameLines.isNotEmpty && gDbgFrameLines[0] > 0) {
        at += ":" + gDbgFrameLines[0].toString();
      }
      return "paused at " + at + ", " + gDbgFrames.length.toString() + " frames";
    }
    case 'dbgpause': {                     // the frame-loop-friendly way in:
      if (gLangIsolateId == null) return "ERR: attach first";
      await dbgPause();                    // stop wherever it is — no re-break trap
      return "pause requested — poll dbgstate";
    }
    case 'dbgstack': {                     // "N  fn:line" per frame, for dbgframe N
      if (!gDbgPaused) return "(not paused)";
      var o = <String>[];
      for (var i = 0; i < gDbgFrames.length; i++) {
        var ln = (i < gDbgFrameLines.length && gDbgFrameLines[i] > 0)
            ? ":" + gDbgFrameLines[i].toString() : "";
        o.add(i.toString() + "  " + gDbgFrames[i][0].toString() + ln);
      }
      return o.isEmpty ? "(no frames)" : o.join('\n');
    }
    case 'dbgbreaks': {                    // what is armed, one per line
      var o = <String>[];
      for (var b in gDbgBreaks) {
        var s = "L" + b.line.toString() +
            (b.decl.isEmpty ? "" : "  (" + b.decl + " +" + b.offset.toString() + ")");
        if (b.condition.isNotEmpty) {
          s += "  if " + b.condition +
               "  hits " + b.hits.toString() + " skips " + b.skips.toString();
        }
        o.add(s);
      }
      return o.isEmpty ? "(none)" : o.join('\n');
    }
    case 'dbgunbreak': {                   // remove ONE breakpoint, by its line
      var ln = int.parse(arg.trim(), onError: (_) => 0);
      var kept = <DbgBreak>[];
      var removed = 0;
      for (var b in gDbgBreaks) {
        if (b.line == ln) {
          removed++;
          if (b.vmId != null) {
            await vmsCall('removeBreakpoint', <String, dynamic>{
                'isolateId': gLangIsolateId, 'breakpointId': b.vmId});
          }
        } else {
          kept.add(b);
        }
      }
      gDbgBreaks = kept;
      dbgLoadSource();
      return removed == 0 ? "ERR: no breakpoint at line " + ln.toString()
                          : "removed " + removed.toString() + " at line " + ln.toString();
    }
    case 'dbgstep': await dbgResume(arg.trim().isEmpty ? null : arg.trim()); return "ok";
    case 'dbgclear': await dbgClearBreaks(); return "ok";
    case 'dbghold': debugHold(); return "held (watchdog paused), depth " + gDebugHold.toString();
    case 'dbgrelease': debugRelease(); return "released, depth " + gDebugHold.toString();
    case 'settle': {  // wait for in-flight work instead of guessing with sleep
      var ok = await workSettle();
      return ok ? "idle" : "ERR: still busy after 30s";
    }
    case 'sleep': {   // a pacing aid for scripts; does not block the isolate
      var ms = int.parse(arg.trim(), onError: (_) => 0);
      if (ms > 0) await new Future.delayed(new Duration(milliseconds: ms));
      return "";
    }
    case 'resize': {   // "resize W H" — drive the window size to test the layout
      var wh = arg.split(' ');
      var f = gWindow.frame();
      var w = double.parse(wh[0]), h = double.parse(wh[1]);
      gWindow.setFrame([f[0], f[1] + f[3] - h, w, h], display: true);
      repaint();
      var b = gContent.bounds();
      return "content " + b[2].toString() + "x" + b[3].toString();
    }
    case 'dock': {   // "dock" reports; "dock hide|show|toggle" moves it
      var a = arg.trim().toLowerCase();
      if (a == 'hide' || a == 'collapse') setDock(true);
      else if (a == 'show' || a == 'open') setDock(false);
      else if (a == 'toggle') setDock(!gDockCollapsed);
      else if (a.isNotEmpty) return "ERR: dock [show|hide|toggle]";
      return gDockCollapsed ? "collapsed" : "open";
    }
    case 'frames': {
      var o = <String>[];
      o.add("content   " + gContent.bounds().toString());
      o.add("toolbar   " + (gToolbar == null ? "(absent)" : gToolbar.frame().toString()));
      o.add("tabview   " + gTabView.frame().toString());
      o.add("dock      " + (gDockCollapsed ? "collapsed" : "open") +
            "  bar " + gDockBar.frame().toString() +
            "  pane " + gTranscript.enclosingScrollView().frame().toString());
      for (var t in <String>["+ Class", "− Class", "+ Method", "− Method",
                             "instance", "class", "Comment", "Accept", "Clear"]) {
        var b = gButtons[t];
        if (b == null) { o.add(t.padRight(14) + "(absent)"); continue; }
        var f = b.frame(), sf = b.superview().frame();
        o.add(t.padRight(14) + "x=" + f[0].toStringAsFixed(0) +
              " w=" + f[2].toStringAsFixed(0) +
              " right=" + (f[0] + f[2]).toStringAsFixed(0) +
              "  pane w=" + sf[2].toStringAsFixed(0));
      }
      return o.join("\n");
    }
    case 'demos': {
      var o = <String>[];
      for (var d in scanDemos()) o.add(d[0]);
      return o.isEmpty ? "(none)" : o.join('\n');
    }
    case 'demorun': {
      var want = arg.trim().toLowerCase();
      if (want.isEmpty) return "ERR: demorun <title or filename fragment>";
      for (var d in scanDemos()) {
        if (d[0].toLowerCase().contains(want) ||
            d[1].split('/').last.toLowerCase().contains(want)) {
          await runScannedDemo(d[0], d[1]);
          return gDemoTitle == null ? "ERR: demo failed to start" : "started " + d[0];
        }
      }
      return "ERR: no demo matching " + arg;
    }
    case 'helpsearch': {
      await helpStart();
      if (!await helpSettle()) return "ERR: the help index is not up";
      helpSearch(arg);
      await new Future.delayed(const Duration(milliseconds: 250));
      var o = <String>[];
      for (var r in gHelpRows) {
        o.add(r[1].toString().padRight(10) + r[2].toString().padRight(17) + " " +
              r[3].toString());
      }
      return o.isEmpty ? "(nothing matches " + arg + ")" : o.join('\n');
    }
    case 'helpsel': {
      helpSelect(int.parse(arg.trim(), onError: (_) => 0));
      await new Future.delayed(const Duration(milliseconds: 250));
      return gHelpDetail.isEmpty ? "(nothing selected)" : _firstLine(gHelpDetail);
    }
    case 'helptext': return gHelpDetail;
    case 'helpcount': {
      await helpStart();
      await helpSettle();
      return gHelpCount.toString();
    }
    case 'apps': {
      var r = await ask('apps', '');
      var names = _dl(r);
      return names.isEmpty ? "(none)" : names.join('\n');
    }
    case 'apprun': {
      var name = arg.trim();
      if (name.isEmpty) return "ERR: apprun <ClassName>";
      await appRun(name);
      return gAppName == null
          ? gAppStatusLbl.stringValue().UTF8String()
          : "running " + gAppName;
    }
    case 'appinstall': {                   // install a SCANNED app by title
      var want = arg.trim().toLowerCase();
      if (want.isEmpty) return "ERR: appinstall <title>";
      for (var a in scanApps()) {
        if (a[0].toLowerCase() == want) {
          await installApp(a[0], a[1]);
          return gAppName == null ? "ERR: install failed (see log)"
                                  : "running " + gAppName;
        }
      }
      return "ERR: no app titled " + arg.trim() + " in apps/";
    }
    case 'appstop': await appStop(); return "ok";
    case 'appedit': {
      await appEdit();
      return gEdClass == null ? "ERR: nothing to edit" : "editing " + gEdClass;
    }
    case 'appremove': {
      // Optional arg selects the class; with none, the picker's selection goes.
      var want = arg.trim();
      if (want.isNotEmpty && gAppPicker != null) gAppPicker.selectItemWithTitle(want);
      await appUninstall();
      return gAppStatusLbl.stringValue().UTF8String();
    }
    case 'appstatus': return gAppName == null ? "idle" : "running " + gAppName;
    case 'apptree': {
      if (gAppName == null) return "(no app running)";
      var o = <String>[];
      for (var id in gAppOrder) {
        var v = gAppViews[id];
        if (v == null) continue;
        var f = v.frame();
        o.add(id.padRight(10) + gAppKinds[id].padRight(8) +
              '"' + appValueOf(id) + '"  ' +
              "x=" + (f[0] as num).toStringAsFixed(0) +
              " y=" + (f[1] as num).toStringAsFixed(0) +
              " w=" + (f[2] as num).toStringAsFixed(0) +
              " h=" + (f[3] as num).toStringAsFixed(0));
      }
      return o.isEmpty ? "(no widgets)" : o.join('\n');
    }
    case 'appclick': {
      var v = gAppViews[arg.trim()];
      if (v == null) return "ERR: no widget " + arg.trim();
      v.performClick(null);              // the real click path, as `click` does
      await appSettle();                 // ...and answer once the app has acted
      return "clicked " + arg.trim();
    }
    case 'appset': {
      var sp2 = arg.indexOf(' ');
      if (sp2 < 0) return "ERR: appset <id> <text>";
      var id = arg.substring(0, sp2), text = arg.substring(sp2 + 1);
      var v = gAppViews[id];
      if (v == null) return "ERR: no widget " + id;
      v.setStringValue(text);
      appFire(id, 'text', text);         // as typing into it would
      await appSettle();
      return "ok";
    }
    case 'appget': {
      var s = appValueOf(arg.trim());
      return s == null ? "ERR: no widget " + arg.trim() : s;
    }
    case 'appcanvasclick': {             // "appcanvasclick <id> <x> <y>" — drive a canvas click
      var parts = arg.trim().split(new RegExp(r'\s+'));
      if (parts.length < 3) return "ERR: appcanvasclick <id> <x> <y>";
      if (gAppKinds[parts[0]] != 'canvas') return "ERR: no canvas " + parts[0];
      appFire(parts[0], 'click', parts[1] + ',' + parts[2]);
      await appSettle();
      return "ok";
    }
    case 'apptab': {                     // "apptab <tabsId> <index>" — show a tab
      var parts = arg.trim().split(new RegExp(r'\s+'));
      if (parts.length < 2) return "ERR: apptab <tabsId> <index>";
      var tv = gAppViews[parts[0]];
      if (tv == null || gAppKinds[parts[0]] != 'tabs') return "ERR: no tabs widget " + parts[0];
      tv.selectTabViewItemAtIndex(int.parse(parts[1], onError: (_) => 0));
      repaint();
      return "ok";
    }
    // `demostop` is THE stop verb — it ends a Dart demo, an ST demo and an ST
    // game alike, since all three are the same pull demo to this isolate.
    // `stgamestop` is accepted because `stgame` starts one and the language
    // isolate has answered that name all along; only the UI route was missing,
    // so the obvious guess used to come back "ERR: unknown stgamestop".
    case 'demostop': case 'stgamestop': stopDemo("stopped"); return "ok";
    case 'demoedit': {
      await demoEdit();
      return (gEdClass == null && gEdFile == null)
          ? "ERR: nothing to edit" : "editing " + (gEdClass != null ? gEdClass : gEdFile);
    }
    // received vs painted: if painted stalls while received climbs, the pacer
    // is dropping every frame — the screen is NOT showing what the demo sends.
    case 'demostatus': return gDemoTitle == null
        ? "idle"
        : (gDemoIso == null ? "finished " : "running ") + gDemoTitle +
          " — " + gDemoFrames.toString() + " frames, " +
          gDemoPaints.toString() + " painted";
    case 'snap': return await snapshot(arg.isEmpty ? "/tmp/dartui.png" : arg);
    // The game pane's honest pixels: the offscreen texture, not the window
    // (cacheDisplayInRect cannot see a CAMetalLayer).
    case 'gpsnap': {
      var e = gpSnap(arg.isEmpty ? "/tmp/gp.png" : arg);
      return e.isEmpty ? "ok " + (arg.isEmpty ? "/tmp/gp.png" : arg) : "ERR: " + e;
    }
    case 'colint': {                       // COCOA_STATIC_CHECK_PLAN.md §2
      var f = cocoaLint(arg);
      return f.isEmpty ? "clean" : f.join('\n');
    }
    case 'gpstat': return gpStat().toString();
    // The frame stepper (language isolate — that is where the frame loop is).
    // A game is a loop of discrete frames, so pausing between them IS the
    // debugger: park it, take frames by hand, and read or poke the running game
    // with an ordinary `doit` in between. `gpsnap` after a step shows you the
    // exact frame you just took.
    //   gppause | gpstep [n] | gprun | gpwhere | gpkeys <mask|->
    case 'gppause': case 'gprun': case 'gpwhere': {
      var r = await ask(cmd, '');
      return r == null ? 'ERR: ' + cmd + ' timed out' : r.toString();
    }
    case 'gpstep': case 'gpkeys': {
      var r = await ask(cmd, arg.trim());
      return r == null ? 'ERR: ' + cmd + ' timed out' : r.toString();
    }
    case 'gpfull': gpFullscreen(arg.trim() == '1'); return "ok";
    case 'tab': {
      if (arg.trim().isEmpty) return gTab.toString();   // read the current tab
      switchTab(int.parse(arg));
      return "ok";
    }
    case 'findset': gFindField.setStringValue(arg); return "ok";
    case 'findrun': runFind(arg.length > 0 ? arg : 'find'); return "ok";
    case 'findsel': findNavigate(int.parse(arg)); return "ok";
    case 'edsettext': edSetText(arg.replaceAll('\\n', '\n')); return "ok";
    case 'edtext': return edText();
    // How the Editor's buffer is being LEXED — the language chosen and the run
    // lengths per kind. Colour is the one thing a screenshot proves and a test
    // cannot, so the test asserts the spans instead: "the whole comment is one
    // run of kind 3" is exactly the property that broke when a Smalltalk
    // comment was lexed as a Dart string.
    case 'edlex': {
      var src = edText();
      var st = looksSmalltalk(src);
      var spans = st ? lexSmalltalk(src) : lexDart(src);
      var chars = <int, int>{};
      for (var i = 0; i + 2 < spans.length; i += 3) {
        var k = spans[i + 2];
        chars[k] = (chars.containsKey(k) ? chars[k] : 0) + spans[i + 1];
      }
      var o = <String>[st ? 'smalltalk' : 'dart',
                       (spans.length ~/ 3).toString() + ' spans'];
      for (var k in <int>[0, 1, 2, 3, 4, 5]) {
        if (chars.containsKey(k)) {
          o.add(_kSpanKindNames[k] + '=' + chars[k].toString());
        }
      }
      return o.join(' ');
    }
    case 'edstatus': return gEdStatus.stringValue().UTF8String();
    case 'edpick': gEdPicker.selectItemWithTitle(arg); return "ok";
    case 'edclasses': { var o = <String>[]; for (var i = 0; i < gEdPicker.numberOfItems(); i++) o.add(gEdPicker.itemTitleAtIndex(i).UTF8String()); return o.join(','); }
    case 'log': return gLog.join('\n');   // the transcript, for headless testing
    case 'edit': editProjectFile(arg.trim()); return "ok";
    case 'uireload': await reloadUi(); return "ok";
    case 'uirebuild': rebuildUi(); return "ok";
    case 'menuclick': {   // "menuclick Debug/Rebuild UI Layout" — drive a menu item
      var i = arg.indexOf('/');
      if (i < 0) return "ERR: use menuclick <Menu>/<Item>";
      var mm = Cocoa.cls("NSApplication").sharedApplication().mainMenu();
      var top = mm.itemWithTitle(arg.substring(0, i));
      if (top.isNil) return "ERR: no menu " + arg.substring(0, i);
      var sub = top.submenu();
      var want = arg.substring(i + 1);
      for (var k = 0; k < sub.numberOfItems(); k++) {
        if (sub.itemAtIndex(k).title().UTF8String() != want) continue;
        sub.performActionForItemAtIndex(k);
        return "clicked " + arg;
      }
      return "ERR: no item " + want;
    }
    case 'menus': {   // the menu bar's top-level titles, to catch duplication
      var mm = Cocoa.cls("NSApplication").sharedApplication().mainMenu();
      var out = <String>[];
      for (var i = 0; i < mm.numberOfItems(); i++) {
        out.add(mm.itemAtIndex(i).title().UTF8String());
      }
      return out.length.toString() + ": " + out.join(" | ");
    }
    case 'uirevert': await revertUi(); return "ok";
    case 'uilastgood': return gLastGood == null ? "(none yet)" : gLastGood;
    case 'edload': editorLoad(); return "ok";
    case 'ednew': editorNew(); return "ok";
    case 'edsave': editorSaveImage(); return "ok";
    case 'edlive': editorAddToWorld(); return "ok";
    case 'edformat': editorFormat(); return "ok";
    case 'edanalyze': await editorAnalyze(); return "ok";
    case 'settext':
      gEditor.setString(arg.replaceAll('\\n', '\n'));
      highlight();
      return "ok";
    case 'click':
      var b = gButtons[arg];
      if (b == null) return "ERR: no button " + arg;
      b.performClick(null);
      return "clicked " + arg;
    case 'doit': return await askDeferrable('doit', arg);
    case 'accept': {
      // Scripted accepts go through the same gate as the buttons. This verb
      // used to be the one unguarded door into the image, which is how source
      // the reloader refuses got in during testing.
      if (gDbgPaused) return await ask('accept', arg);   // refused with the reason
      var r = await checkDecls(<dynamic>[arg]);
      if (!r.ok) {
        return "ERR: refused — " + r.message +
               (r.line > 0 ? "  (line " + r.line.toString() + ")" : "");
      }
      return await askDeferrable('accept', arg);   // persisted in the image
    }
    case 'classsrc': return await askDeferrable('classsrc', arg);
    case 'remove': return await askDeferrable('remove', arg);
    case 'versions': {   // "versions [N]" — the image's append-only edit history
      var r = await ask('versions', arg.trim().isEmpty ? '20' : arg.trim());
      var l = _dl(r);
      return l.isEmpty ? "(no versions)" : l.join('\n');
    }
    case 'rollback': return await askDeferrable('rollback', arg);   // "rollback [<id>]"
    case 'lang': {
      // Generic language-isolate passthrough for scripted tests:
      // `lang <cmd> [arg]` → ask(cmd, arg). Read-only browsing verbs mostly
      // (classes, classmembers, members, categories, ...).
      var s2 = arg.indexOf(' ');
      var sub = s2 < 0 ? arg : arg.substring(0, s2);
      var rest = s2 < 0 ? '' : arg.substring(s2 + 1);
      var r = await ask(sub, rest);
      return r == null ? 'nil' : r.toString();
    }
    case 'acceptb64': {
      // Scripted MULTILINE accept: the control line is one line by contract,
      // so a whole-decl edit travels base64-encoded. Same gate as 'accept'.
      var text;
      try { text = UTF8.decode(BASE64.decode(arg.trim())); }
      catch (e) { return 'ERR: acceptb64: bad payload'; }
      if (gDbgPaused) return await ask('accept', text);
      var r = await checkDecls(<dynamic>[text]);
      if (!r.ok) {
        return "ERR: refused — " + r.message +
               (r.line > 0 ? "  (line " + r.line.toString() + ")" : "");
      }
      return await askDeferrable('accept', text);
    }
    case 'stimport': {
      // Sprint 12: import MACVM .mst file(s)/directory into the image as
      // editable ST decls (one merged decl per class + boot chunks). Slow for
      // a whole world (parses + reloads everything), so it bypasses the doit
      // watchdog with its own generous quiet timeout.
      var r = await askQuiet('stimport', arg.trim(),
          const Duration(seconds: 180));
      return r == null ? 'ERR: stimport timed out' : r.toString();
    }
    case 'stdemo': runStDemo(arg.trim().isEmpty ? 'Waves' : arg.trim()); return "ok";
    case 'stgame': runStGame(arg.trim().isEmpty ? 'Breakout' : arg.trim()); return "ok";
    // The sprite editor's scripted face — same handlers the mouse drives.
    case 'sprited': case 'spritedclose': case 'spedstat': case 'spedrows':
    case 'spedpaint': case 'spedcolor': case 'spedrgb': case 'spedtool':
    case 'spedframe': case 'spedname': case 'spedsave': case 'spedload':
    case 'spedlist': case 'speddump': case 'spednew':
      return await spriteEdVerb(cmd, arg.trim());
    // The sound editor's scripted face — same handlers the sliders drive.
    case 'sounded': case 'soundedclose': case 'sndnew': case 'sndstat':
    case 'sndparams': case 'sndset': case 'sndosc': case 'sndpreset':
    case 'sndplay': case 'sndsave': case 'sndload': case 'sndlist':
      return await soundEdVerb(cmd, arg.trim());
    case 'kill': await respawnLanguage("manual kill"); return "ok";
    case 'quit':
      Cocoa.cls("NSApplication").sharedApplication().terminate(null); return "ok";
    default: return "ERR: unknown " + cmd;
  }
}


// --- Editor tab -------------------------------------------------------------
// A whole class as text (MACVM's editor). The class picker + Load/Save work on
// the SQLite IMAGE; Open…/Save File… work on plain .dart FILES; File In brings a
// file's declarations into the image. Format re-indents, Analyze compiles for
// real. What each button touches is spelled out in the status line, because
// "saved" and "live" are different things here.
Cocoa gEdText, gEdPicker, gEdStatus;
String gEdFile;            // the .dart file the buffer came from, if any
String gEdClass;           // the image class the buffer came from, if any

void buildEditorTab(Cocoa ed) {
  gEdPicker = Cocoa.cls("NSPopUpButton").alloc()
      .initWithFrame([8.0, 390.0, 300.0, 26.0], pullsDown: false);
  ed.addSubview(gEdPicker);
  gEdPicker.setAutoresizingMask(kMinYMargin);
  // Deliberately NO action on the picker. Populating an NSPopUpButton changes
  // its selection and fires its action, and that action runs later (see [defer]),
  // so any "am I refreshing?" flag is already clear by the time it arrives — the
  // refresh would Load over an unsaved buffer. The picker selects; Load loads.

  button(ed, "Load", [316.0, 390.0, 68.0, 26.0], (s) => editorLoad());
  button(ed, "Save to Image", [390.0, 390.0, 118.0, 26.0], (s) => editorSaveImage());
  button(ed, "Add to World", [514.0, 390.0, 112.0, 26.0], (s) => editorAddToWorld());

  button(ed, "New", [8.0, 360.0, 60.0, 24.0], (s) => editorNew());
  button(ed, "Open…", [72.0, 360.0, 76.0, 24.0], (s) => editorOpen());
  button(ed, "Save File…", [152.0, 360.0, 96.0, 24.0], (s) => editorSaveFile());
  button(ed, "File In", [252.0, 360.0, 74.0, 24.0], (s) => editorFileIn());
  button(ed, "Format", [330.0, 360.0, 74.0, 24.0], (s) => editorFormat());
  button(ed, "Analyze", [408.0, 360.0, 80.0, 24.0], (s) => editorAnalyze());
  pinTop(<String>["Load", "Save to Image", "Add to World", "New", "Open…",
                  "Save File…", "File In", "Format", "Analyze"]);

  gEdStatus = label(ed, [8.0, 340.0, 852.0, 16.0]);
  gEdStatus.setAutoresizingMask(kMinYMargin + kWidthSizable);
  gEdText = scrolledTextView(ed, [8.0, 8.0, 852.0, 326.0], true);
  var mf = _mono(13.0);
  if (!mf.isNil) gEdText.setFont(mf);
  anchorScroll(gEdText, kWidthSizable + kHeightSizable);
  gTargets.add(onTextChange(gEdText, (s) => highlightView(gEdText)));
  edStatus("empty — pick a class and Load, or Open… a .dart file");
}

void edStatus(String s) {
  if (gEdStatus != null) gEdStatus.setStringValue(s);
}

String edText() => gEdText.string().UTF8String();

void edSetText(String s) {
  gEdText.setString(s);
  clearUndo();
  highlightView(gEdText);
  repaint();
}

// Repopulate the class picker from the image.
void editorRefreshClasses() {
  ask('classes', '').then((r) {
    var names = _dl(r);
    var keep = gEdClass;
    gEdPicker.removeAllItems();
    for (var n in names) gEdPicker.addItemWithTitle(n.toString());
    if (keep != null) gEdPicker.selectItemWithTitle(keep);
    repaint();
  });
}

void editorLoad() {
  if (gEdPicker.numberOfItems() == 0) { log("editor: no classes in the image yet"); return; }
  var name = gEdPicker.titleOfSelectedItem().UTF8String();
  ask('classsrc', name).then((r) {
    gEdClass = name; gEdFile = null;
    edSetText(r.toString());
    edStatus(name + "  ·  from the image  ·  Save to Image = live + saved");
  });
}

// Editor -> image AND live (this is Accept: the image is the source of truth).
void editorSaveImage() {
  var decls = editorDecls(edText());
  if (decls.isEmpty) { log("editor: nothing to save"); return; }
  guardedAccept(decls, "Save to Image", () {
  ask('acceptMany', decls).then((r) {
    log("✓ Save to Image — " + r);
    if (!r.toString().startsWith("ERR")) {
      gEdClass = _classNameOf(decls[0]);
      edStatus((gEdClass != null ? gEdClass : "(saved)") + "  ·  live + saved in the image");
      editorRefreshClasses();
    }
  });
  });
}

// Editor -> live isolate ONLY. Try a class in the running world without
// committing it: a respawn (or the next launch) re-reads the image and it is gone.
void editorAddToWorld() {
  var decls = editorDecls(edText());
  if (decls.isEmpty) { log("editor: nothing to add"); return; }
  guardedAccept(decls, "Add to World", () {
  ask('acceptLive', decls).then((r) {
    log("✓ Add to World — " + r);
    if (!r.toString().startsWith("ERR")) {
      edStatus("live in the running world — NOT saved to the image");
    }
  });
  });
}

void editorNew() {
  gEdClass = null; gEdFile = null;
  edSetText("class NewClass {\n  \n}\n");
  edStatus("new class — rename it, then Save to Image");
}

// --- files ------------------------------------------------------------------
// A modal panel spins its own AppKit event pump. Our button actions already run
// from the isolate message loop (see [defer]), i.e. with Dart on the stack, so
// the panel is deferred one more hop via Timer.run: the stack unwinds first and
// the pump is idle when the panel takes over. (MACVM hit the same hazard —
// cocoa_gui/src/panels.rs runs its panels from a drain pass, never in a callback.)
void _panel(String kind, void done(String path)) {
  // Timer.run is a STATIC method, not a named constructor: `new Timer.run(…)`
  // threw NoSuchMethodError on every click, defer's catch ate it, and the
  // panel simply never appeared. The deferral itself is still wanted — the
  // modal session should start from a fresh message, not nested inside the
  // AppKit action callout.
  Timer.run(() {
    var p = (kind == 'open')
        ? Cocoa.cls("NSOpenPanel").openPanel()
        : Cocoa.cls("NSSavePanel").savePanel();
    // A Dart List is a STRUCT to this bridge (NSRect and friends); for an id
    // argument it marshals to nil, which silently removes the filter. Build a
    // real NSArray through the bridge instead.
    p.setAllowedFileTypes(Cocoa.cls("NSArray").arrayWithObject("dart"));
    if (kind == 'open') {
      p.setCanChooseFiles(true);
      p.setAllowsMultipleSelection(false);
    } else {
      p.setNameFieldStringValue((gEdClass != null ? gEdClass : "Untitled") + ".dart");
    }
    var rc = p.runModal();
    if (rc != 1) return;                        // NSModalResponseOK
    var url = p.URL();
    if (url.isNil) return;
    done(url.path().UTF8String());
  });
}

void editorOpen() {
  _panel('open', (path) {
    try {
      var src = new File(path).readAsStringSync();
      gEdFile = path; gEdClass = null;
      edSetText(src);
      edStatus(path + "  ·  a file on disk — File In to bring it into the image");
    } catch (e) { log("editor: open failed — " + e.toString()); }
  });
}

void editorSaveFile() {
  _panel('save', (path) {
    try {
      new File(path).writeAsStringSync(edText());
      gEdFile = path;
      edStatus(path + "  ·  written to disk (the image is unchanged)");
      log("✓ saved " + path);
    } catch (e) { log("editor: save failed — " + e.toString()); }
  });
}

// A .dart file's declarations -> the image (+ live). The file-in of MACVM.
void editorFileIn() {
  _panel('open', (path) {
    var src;
    try { src = new File(path).readAsStringSync(); }
    catch (e) { log("editor: file in failed — " + e.toString()); return; }
    var decls = editorDecls(src);
    if (decls.isEmpty) { log("editor: " + path + " has no top-level declarations"); return; }
    gEdFile = path; gEdClass = null;
    edSetText(src);
    guardedAccept(decls, "File In", () {
    ask('acceptMany', decls).then((r) {
      log("✓ File In (" + decls.length.toString() + " declaration(s)) — " + r);
      edStatus(path + "  ·  filed in: " + decls.length.toString() + " declaration(s) live + saved");
      editorRefreshClasses();
    });
    });
  });
}

// --- Format -----------------------------------------------------------------
// Re-indent only: 2 spaces per brace depth, computed from CODE braces alone.
// lexDart already knows which spans are strings and comments, so their contents
// - including braces and quotes inside them - are never counted and never
// rewritten. A line whose start lies inside a multi-line string or comment is
// emitted verbatim.
String formatDart(String src) => _reindent(_breakStatements(src));

// Put each brace and statement on its own line. Re-indenting alone cannot help a
// class stored as a ONE-LINER: there is no body line for a breakpoint to resolve
// on, which is why `Counter` could not be debugged. Literal-aware — a brace or
// semicolon inside a string or comment is left alone — and a semicolon inside
// parentheses (a for-header) does not end a line.
String _breakStatements(String src) {
  var spans = lexDart(src);
  var lit = new List<bool>.filled(src.length + 1, false);
  for (var i = 0; i + 2 < spans.length; i += 3) {
    var k = spans[i + 2];
    if (k != 2 && k != 3) continue;
    for (var p = spans[i]; p < spans[i] + spans[i + 1] && p < lit.length; p++) {
      lit[p] = true;
    }
  }
  var out = new StringBuffer();
  var paren = 0;
  var atLineStart = true;      // also suppresses runs of blank lines
  var i = 0, n = src.length;
  while (i < n) {
    var c = src.codeUnitAt(i);
    if (lit[i]) { out.write(src[i]); atLineStart = (c == 0x0A); i++; continue; }
    if (c == 0x0A) { if (!atLineStart) { out.write('\n'); atLineStart = true; } i++; continue; }
    if (c == 0x20 || c == 0x09) { if (!atLineStart) out.write(' '); i++; continue; }
    if (c == 0x28) paren++;
    if (c == 0x29 && paren > 0) paren--;
    if (c == 0x7B) { out.write('{\n'); atLineStart = true; i++; continue; }
    if (c == 0x7D) {
      if (!atLineStart) out.write('\n');
      out.write('}\n');
      atLineStart = true; i++; continue;
    }
    if (c == 0x3B && paren == 0) { out.write(';\n'); atLineStart = true; i++; continue; }
    out.write(src[i]);
    atLineStart = false;
    i++;
  }
  return out.toString();
}

String _reindent(String src) {
  var spans = lexDart(src);
  // pos -> is it inside a string(2) or comment(3) span?
  var lit = new List<bool>.filled(src.length + 1, false);
  for (var i = 0; i + 2 < spans.length; i += 3) {
    var kind = spans[i + 2];
    if (kind != 2 && kind != 3) continue;
    var s = spans[i], n = spans[i + 1];
    for (var p = s; p < s + n && p < lit.length; p++) lit[p] = true;
  }
  // A line is left verbatim only if it CONTINUES a literal that opened on an
  // earlier line (a triple-quoted string, a block comment). A line that merely
  // begins with // still gets indented like the code around it.
  var cont = new List<bool>.filled(src.length + 1, false);
  for (var i = 0; i + 2 < spans.length; i += 3) {
    var kind = spans[i + 2];
    if (kind != 2 && kind != 3) continue;
    var s = spans[i], n = spans[i + 1];
    var nl = src.indexOf('\n', s);
    if (nl < 0 || nl >= s + n) continue;      // single-line literal
    for (var p = nl + 1; p < s + n && p < cont.length; p++) cont[p] = true;
  }
  var out = new StringBuffer();
  var depth = 0, i = 0, n = src.length;
  while (i <= n) {
    var eol = src.indexOf('\n', i);
    if (eol < 0) eol = n;
    var line = src.substring(i, eol);
    var trimmed = line.trim();
    if (i < n && cont[i]) {
      out.write(line);                       // continues a literal: verbatim
    } else if (trimmed.isEmpty) {
      // collapses to a bare empty line
    } else {
      var lead = trimmed.codeUnitAt(0);      // a leading closer dedents its line
      var d = depth;
      if (lead == 0x7D || lead == 0x29 || lead == 0x5D) d = depth - 1;
      if (d < 0) d = 0;
      for (var k = 0; k < d; k++) out.write("  ");
      out.write(trimmed);
    }
    for (var p = i; p < eol; p++) {          // net depth from CODE braces only
      if (lit[p]) continue;
      var c = src.codeUnitAt(p);
      if (c == 0x7B) depth++;
      else if (c == 0x7D) depth--;
    }
    if (depth < 0) depth = 0;
    if (eol >= n) break;
    out.write("\n");
    i = eol + 1;
  }
  var text = out.toString();
  if (!text.endsWith("\n")) text += "\n";
  return text;
}

// The token stream ignoring whitespace - the formatter's safety gate. If this
// differs before and after, the reformat changed something other than layout, so
// we refuse to apply it rather than silently mangling the user's class.
String _tokenSignature(String src) {
  var spans = lexDart(src);
  var b = new StringBuffer();
  for (var i = 0; i + 2 < spans.length; i += 3) {
    b.write(spans[i + 2].toString());
    b.write(':');
    b.write(src.substring(spans[i], spans[i] + spans[i + 1]).trim());
    b.write('|');
  }
  return b.toString();
}

void editorFormat() {
  var src = edText();
  if (src.trim().isEmpty) return;
  var f = formatDart(src);
  if (_tokenSignature(src) != _tokenSignature(f)) {
    log("Format REFUSED: that would have changed more than layout (left untouched)");
    return;
  }
  if (f == src) { log("Format - already tidy"); return; }
  edSetText(f);
  log("Format - re-indented");
}

// --- vm-service client (the debugger's transport) ---------------------------
// The UI isolate talks JSON-RPC to the VM's own service over a WebSocket. It can
// debug the LANGUAGE isolate precisely because that is a different isolate: user
// code stops, this one keeps drawing. An isolate cannot debug itself.
//
// Socket accounting, since we have been burned by drift here: the process owns
// exactly ONE listener, the vm-service (ws://127.0.0.1:8181/ws). This client is
// a loopback CONNECTION to that same listener, not a second server — this VM
// has no in-process API for speaking the service protocol, so the service's own
// front door is the supported way in, even from inside. External drivers
// (macdart/tcl/dartui.tcl) are further connections to the same door.
//
// dart:io gives us the WebSocket, so no native code is involved. Requires the
// vm-service to be on (start-gui.sh passes --enable-vm-service by default).
WebSocket gVms;                        // the service connection, null when off
int gVmsSeq = 0;
Map<int, Completer> gVmsPending = <int, Completer>{};
String gLangIsolateId;                 // the isolate we debug
String gLangScriptId;                  // its root script (the scratch file)
bool gVmsConnecting = false;

Future<bool> vmsConnect([String url = 'ws://127.0.0.1:8181/ws']) async {
  if (gVms != null) return true;
  if (gVmsConnecting) return false;
  gVmsConnecting = true;
  try {
    gVms = await WebSocket.connect(url);
  } catch (e) {
    gVmsConnecting = false;
    log("debugger: no vm-service at " + url +
        " — start-gui.sh enables it unless --no-observe was passed  (" +
        e.toString() + ")");
    return false;
  }
  gVmsConnecting = false;
  gVms.listen((data) {
    var d;
    try { d = JSON.decode(data.toString()); } catch (e) { return; }
    if (d['id'] != null) {
      // A JSON-RPC reply's id is the integer we sent. Some vm-service messages
      // are service OBJECTS with their own non-numeric `id` (e.g. an event or
      // error {type,id,kind,message}) — not replies to us; skip them.
      var idv = d['id'];
      var key = (idv is int) ? idv : int.parse(idv.toString(), onError: (_) => -1);
      if (key == -1) return;
      var c = gVmsPending.remove(key);
      if (c != null && !c.isCompleted) c.complete(d);
    } else if (d['method'] == 'streamNotify') {
      onVmsEvent(d['params']);
    }
  }, onDone: () { gVms = null; _failPendingVms("vm-service disconnected"); },
     onError: (e) { gVms = null; _failPendingVms("vm-service error: " + e.toString()); });
  return true;
}

// A dead connection answers everything in flight NOW: each pending vmsCall
// otherwise sits out its own 10-second timeout, serially, and a caller chaining
// a few of them (dbgReResolve does) turns one disconnect into a half-minute of
// nothing happening.
void _failPendingVms(String why) {
  var pending = gVmsPending;
  gVmsPending = <int, Completer>{};
  for (var c in pending.values) {
    if (!c.isCompleted) c.complete(<String, dynamic>{'error': {'message': why}});
  }
  dbgStatus(why);
}

Future vmsCall(String method, [Map params]) async {
  if (gVms == null) return null;
  var id = ++gVmsSeq;
  var c = new Completer();
  gVmsPending[id] = c;
  gVms.add(JSON.encode(<String, dynamic>{
    'jsonrpc': '2.0', 'id': id, 'method': method,
    'params': params != null ? params : <String, dynamic>{}
  }));
  var reply = await c.future.timeout(const Duration(seconds: 10),
      onTimeout: () {
        gVmsPending.remove(id);   // a reply this late is nobody's answer
        return <String, dynamic>{'error': {'message': 'timed out'}};
      });
  if (reply['error'] != null) {
    dbgStatus("vm-service: " + method + ": " + reply['error']['message'].toString());
    return null;
  }
  return reply['result'];
}

/// Find the language isolate and its script — the thing we set breakpoints in.
Future<bool> vmsResolveTarget() async {
  var vm = await vmsCall('getVM');
  if (vm == null) return false;
  // The LAST ws_lang in the list: getVM lists in creation order, and any
  // earlier one is a leftover from a respawn — attaching there arms
  // breakpoints in an isolate nothing will ever run again.
  var target;
  for (var iso in vm['isolates']) {
    if (iso['name'].toString().contains('macdart_ws_lang')) target = iso;
  }
  {
    var iso = target;
    if (iso == null) {
      dbgStatus("debugger: no language isolate found");
      return false;
    }
    gLangIsolateId = iso['id'];
    var info = await vmsCall('getIsolate', <String, dynamic>{'isolateId': gLangIsolateId});
    if (info == null || info['rootLib'] == null) return false;
    var lib = await vmsCall('getObject', <String, dynamic>{
      'isolateId': gLangIsolateId, 'objectId': info['rootLib']['id']});
    if (lib == null || lib['scripts'] == null || lib['scripts'].isEmpty) return false;
    gLangScriptId = lib['scripts'][0]['id'];
    return true;
  }
}

String _dbgIsoLabel(String name, String id) {
  var n = name;
  var d = n.indexOf('.dart');
  if (d > 0) n = n.substring(0, d);                       // "06_boids" ← "…dart$main"
  var slash = id.lastIndexOf('/');
  return n + "  #" + (slash >= 0 ? id.substring(slash + 1) : id);   // id keeps it unique
}

/// Populate the isolate picker with every attachable isolate — ALL of them
/// except the UI isolate, which is the one that registered `ext.dartui.send`.
/// Pausing that isolate would freeze the debugger and the whole window, so it is
/// never offered. The language isolate is flagged (its breakpoints stay anchored
/// across reloads) and pre-selected, so the default Attach behaves as before.
Future dbgRefreshIsolates() async {
  if (gDbgIsoPicker == null) return;
  if (!await vmsConnect()) return;
  var vm = await vmsCall('getVM');
  if (vm == null) return;
  var list = <dynamic>[];
  for (var iso in vm['isolates']) {
    var info = await vmsCall('getIsolate', <String, dynamic>{'isolateId': iso['id']});
    if (info == null) continue;
    var exts = info['extensionRPCs'];
    if (exts != null && exts.contains('ext.dartui.send')) continue;   // the UI isolate — never
    var name = iso['name'].toString();
    list.add(<dynamic>[iso['id'], name, name.contains('macdart_ws_lang')]);
  }
  gDbgIsoList = list;
  gDbgIsoPicker.removeAllItems();
  var sel = 0;
  for (var i = 0; i < list.length; i++) {
    gDbgIsoPicker.addItemWithTitle(_dbgIsoLabel(list[i][1].toString(), list[i][0].toString()));
    if (list[i][2] == true && sel == 0) sel = i;          // default to the language isolate
  }
  if (list.isNotEmpty) gDbgIsoPicker.selectItemAtIndex(sel);
  repaint();
}

// ---- Profiler ----------------------------------------------------------------

String _profPct(int ticks, int total) {
  if (total <= 0) return "  0.0%";
  var s = (ticks * 100.0 / total).toStringAsFixed(1) + "%";
  while (s.length < 6) s = " " + s;
  return s;
}

/// A profile function name, with anonymous closures QUALIFIED by their
/// enclosing function/class — the ref already carries the owner chain, so a
/// bare "<anonymous closure>" (useless: which one?) becomes e.g.
/// "JuliaDemo.render.<closure>". Regular functions and [Stub] rows pass through.
String _profFnName(dynamic fn) {
  if (fn is! Map) return '?';
  var name = fn['name'] != null ? fn['name'].toString() : '?';
  if (!name.contains('closure')) return name;
  var chain = <String>[];                         // owner chain: innermost first
  var o = fn['owner'];
  for (var guard = 0; o is Map && o['name'] != null && guard < 6; guard++) {
    var on = o['name'].toString();
    if (on.isNotEmpty) chain.add(on);             // skip synthetic empty-named owners
    o = o['owner'];
  }
  if (chain.isEmpty) return name;
  var q = new StringBuffer();                      // reverse to Class.method order
  for (var i = chain.length - 1; i >= 0; i--) { q.write(chain[i]); q.write('.'); }
  q.write('<closure>');
  return q.toString();
}

/// The formatted hot-function report from the last sample: self% (time IN the
/// function) and total% (time in it or anything it called), by self-desc.
String profReport(int topN) {
  if (gProfSamples == 0) {
    return "0 samples — the isolate was idle for the whole window.\n"
        "The profiler only sees ON-CPU time, so a frame-paced demo that sleeps\n"
        "between frames shows little. Profile a CPU-bound workload.";
  }
  var o = <String>[];
  o.add(gProfSamples.toString() + " samples     self%   total%   function");
  var n = (topN <= 0 || gProfRows.length < topN) ? gProfRows.length : topN;
  for (var i = 0; i < n; i++) {
    o.add("  " + _profPct(gProfRows[i][0], gProfSamples) + "  " +
          _profPct(gProfRows[i][1], gProfSamples) + "   " + gProfRows[i][2].toString());
  }
  return o.join('\n');
}

/// Every isolate with role flags. Profiling is read-only, so — unlike the
/// debugger — the UI isolate is offered too (profiling it never freezes it).
Future<List> profListIsolates() async {
  if (!await vmsConnect()) return <dynamic>[];
  var vm = await vmsCall('getVM');
  if (vm == null) return <dynamic>[];
  var list = <dynamic>[];
  for (var iso in vm['isolates']) {
    var info = await vmsCall('getIsolate', <String, dynamic>{'isolateId': iso['id']});
    if (info == null) continue;
    var exts = info['extensionRPCs'];
    var isUI = exts != null && exts.contains('ext.dartui.send');
    var name = iso['name'].toString();
    list.add(<dynamic>[iso['id'], name, isUI, name.contains('macdart_ws_lang')]);
  }
  return list;
}

/// The most interesting default target: a running demo/game (non-UI, non-lang),
/// then the language isolate, then any non-UI. An explicit id / name-fragment /
/// index overrides (and a non-matching explicit request is an error, not a
/// silent fallback).
dynamic profPickDefault(List list, String want) {
  want = want.trim();
  if (want.isNotEmpty) {
    for (var i = 0; i < list.length; i++) {
      if (list[i][0].toString() == want || i.toString() == want ||
          list[i][1].toString().contains(want)) return list[i];
    }
    return null;
  }
  for (var e in list) { if (e[2] != true && e[3] != true) return e; }   // demo/game
  for (var e in list) { if (e[3] == true) return e; }                    // language
  for (var e in list) { if (e[2] != true) return e; }                    // any non-UI
  return list.isEmpty ? null : list[0];
}

/// Clear the profiler, let the target run for `ms`, fetch its CPU profile, and
/// fill gProfRows (functions by SELF ticks). The VM samples continuously; this
/// just windows and aggregates. Read-only — nothing is paused. tags:None keeps
/// the attribution to real functions (no VM/user tag pseudo-nodes).
Future<bool> profSample(String isolateId, int ms) async {
  await vmsCall('_clearCpuProfile', <String, dynamic>{'isolateId': isolateId});
  await new Future.delayed(new Duration(milliseconds: ms));
  var p = await vmsCall('_getCpuProfile', <String, dynamic>{
    'isolateId': isolateId, 'tags': 'None'});
  if (p == null) { gProfRows = <dynamic>[]; gProfSamples = 0; return false; }
  gProfSamples = (p['sampleCount'] is int)
      ? p['sampleCount'] : int.parse(p['sampleCount'].toString());
  var funcs = p['functions'];
  // Resolve every function-table name once, in ORIGINAL order — the call trie
  // indexes into this, so it must not be the filtered/sorted flat list.
  var names = <dynamic>[];
  if (funcs != null) for (var f in funcs) names.add(_profFnName(f['function']));
  gProfFuncNames = names;
  gProfTrie = p['inclusiveFunctionTrie'];      // top-down: root (entry) → callees
  var rows = <dynamic>[];
  if (funcs != null) {
    for (var idx = 0; idx < funcs.length; idx++) {
      var f = funcs[idx];
      // exclusive/inclusiveTicks are JSON STRINGS (AddPropertyF formats them).
      var excl = int.parse(f['exclusiveTicks'].toString());
      var incl = int.parse(f['inclusiveTicks'].toString());
      if (excl == 0 && incl == 0) continue;
      rows.add(<dynamic>[excl, incl, names[idx]]);
    }
  }
  rows.sort((a, b) => b[0].compareTo(a[0]));
  gProfRows = rows;
  return true;
}

int _asInt(dynamic v) => v is int ? v : int.parse(v.toString());

/// The inclusive call tree, top-down, indented, pruned to paths >= minPct so a
/// deep stack stays readable. Shows the PATH to hot code — what the flat view
/// can't: e.g. _handleMessage → the frame closure → the pixel loop. Consumes
/// the whole preorder subtree from the flat array regardless of pruning so the
/// cursor stays aligned; only emits shown nodes.
void _profTreeWalk(List trie, List pos, int depth, bool emit,
                   double minPct, List<String> out) {
  // Node layout (profiler_service.cc ProfileFunctionTrieNode::PrintToJSONArray):
  //   idx, count, inclAllocs, exclAllocs, codeCount, (codeIdx,codeTicks)*N,
  //   childCount, <children preorder>
  var i = pos[0];
  var tableIndex = _asInt(trie[i]);
  var count = _asInt(trie[i + 1]);
  var codeCount = _asInt(trie[i + 4]);
  var childCountPos = i + 5 + 2 * codeCount;
  var childCount = _asInt(trie[childCountPos]);
  pos[0] = childCountPos + 1;
  var show = emit && (depth == 0 || count * 100.0 / gProfSamples >= minPct) &&
             out.length < 120;                 // hard cap: never flood the pane
  if (show) {
    var sb = new StringBuffer(_profPct(count, gProfSamples));
    sb.write(' ');
    for (var k = 0; k < depth; k++) sb.write('  ');
    sb.write((tableIndex >= 0 && tableIndex < gProfFuncNames.length)
        ? gProfFuncNames[tableIndex].toString() : '?');
    out.add(sb.toString());
  }
  for (var c = 0; c < childCount; c++) {
    _profTreeWalk(trie, pos, depth + 1, show, minPct, out);   // pruned parent → pruned subtree
  }
}

String profTreeReport(double minPct) {
  if (gProfSamples == 0 || gProfTrie == null || gProfTrie is! List || gProfTrie.isEmpty) {
    return profReport(0);   // fall back to the idle/flat message
  }
  var out = <String>[];
  out.add(gProfSamples.toString() + " samples — inclusive call tree (paths >= " +
          minPct.toStringAsFixed(0) + "%)   total%  path");
  _profTreeWalk(gProfTrie, <int>[0], 0, true, minPct, out);
  return out.join('\n');
}

Future profRefreshIsolates() async {
  if (gProfIsoPicker == null) return;
  gProfIsoList = await profListIsolates();
  gProfIsoPicker.removeAllItems();
  var sel = 0;
  for (var i = 0; i < gProfIsoList.length; i++) {
    var e = gProfIsoList[i];
    gProfIsoPicker.addItemWithTitle(_dbgIsoLabel(e[1].toString(), e[0].toString()) +
        (e[2] == true ? "  [ui]" : e[3] == true ? "  [lang]" : ""));
    if (e[2] != true && e[3] != true && sel == 0) sel = i;   // default to a demo/game
  }
  if (gProfIsoList.isNotEmpty) gProfIsoPicker.selectItemAtIndex(sel);
  repaint();
}

void profShowRows() {
  if (gProfSrc != null) gProfSrc.setString(profReport(60));
  if (gProfStatusLbl != null) {
    gProfStatusLbl.setStringValue(gProfSamples == 0
        ? "0 samples — the isolate was idle (profile a CPU-bound workload)"
        : (gProfSamples.toString() + " samples — hottest functions by self time"));
  }
  repaint();
}

Future profSampleButton() async {
  if (gProfStatusLbl == null) return;
  if (!await vmsConnect()) { gProfStatusLbl.setStringValue("no vm-service (start-gui.sh enables it)"); return; }
  if (gProfIsoList.isEmpty) await profRefreshIsolates();
  if (gProfIsoList.isEmpty) { gProfStatusLbl.setStringValue("no isolates to profile"); return; }
  var idx = gProfIsoPicker.indexOfSelectedItem();
  if (idx < 0 || idx >= gProfIsoList.length) idx = 0;
  var t = gProfIsoList[idx];
  var ms = int.parse(gProfMsField.stringValue().UTF8String().trim(), onError: (_) => 1000);
  gProfStatusLbl.setStringValue("sampling " + _dbgIsoLabel(t[1].toString(), t[0].toString()) +
      " for " + ms.toString() + "ms…");
  repaint();
  await profSample(t[0].toString(), ms);
  profShowRows();
}

// Same sample, rendered as the inclusive call tree instead of the flat list.
Future profTreeButton() async {
  if (gProfStatusLbl == null) return;
  if (!await vmsConnect()) { gProfStatusLbl.setStringValue("no vm-service"); return; }
  if (gProfIsoList.isEmpty) await profRefreshIsolates();
  if (gProfIsoList.isEmpty) { gProfStatusLbl.setStringValue("no isolates to profile"); return; }
  var idx = gProfIsoPicker.indexOfSelectedItem();
  if (idx < 0 || idx >= gProfIsoList.length) idx = 0;
  var t = gProfIsoList[idx];
  var ms = int.parse(gProfMsField.stringValue().UTF8String().trim(), onError: (_) => 1000);
  gProfStatusLbl.setStringValue("sampling " + _dbgIsoLabel(t[1].toString(), t[0].toString()) +
      " for " + ms.toString() + "ms (call tree)…");
  repaint();
  await profSample(t[0].toString(), ms);
  if (gProfSrc != null) gProfSrc.setString(profTreeReport(2.0));
  gProfStatusLbl.setStringValue(gProfSamples == 0
      ? "0 samples — the isolate was idle (profile a CPU-bound workload)"
      : (gProfSamples.toString() + " samples — inclusive call tree (paths >= 2%)"));
  repaint();
}

Future profClearButton() async {
  if (gProfIsoList.isEmpty) await profRefreshIsolates();
  if (gProfIsoList.isEmpty) return;
  var idx = gProfIsoPicker.indexOfSelectedItem();
  if (idx < 0 || idx >= gProfIsoList.length) idx = 0;
  await vmsCall('_clearCpuProfile', <String, dynamic>{'isolateId': gProfIsoList[idx][0].toString()});
  gProfRows = <dynamic>[]; gProfSamples = 0; profShowRows();
}

/// Resolve a CHOSEN isolate: its root script (for breakpoints) and its source
/// file (for the source pane, read from the script's file:// URI — every
/// MACDART isolate is spawned from a file). Sets `gDbgIsLang` so breakpoints are
/// anchored to declarations only for the reloadable language isolate; elsewhere
/// the file is stable, so a raw line is enough.
Future<bool> vmsResolveTargetId(String isolateId, String name) async {
  gLangIsolateId = isolateId;
  gDbgIsLang = name.contains('macdart_ws_lang');
  var info = await vmsCall('getIsolate', <String, dynamic>{'isolateId': isolateId});
  if (info == null || info['rootLib'] == null) return false;
  var lib = await vmsCall('getObject', <String, dynamic>{
    'isolateId': isolateId, 'objectId': info['rootLib']['id']});
  if (lib == null || lib['scripts'] == null || lib['scripts'].isEmpty) return false;
  gLangScriptId = lib['scripts'][0]['id'];
  var sc = await vmsCall('getObject', <String, dynamic>{
    'isolateId': isolateId, 'objectId': gLangScriptId});
  if (sc != null && sc['uri'] != null) {
    try { gDbgScratch = Uri.parse(sc['uri'].toString()).toFilePath(); }
    catch (e) { gDbgScratch = gScratch; }                 // fall back to the language scratch
  }
  return true;
}

// A breakpoint remembered by WHERE IT IS IN YOUR CODE, not by a line number in
// the generated file. The language isolate's scratch file is rewritten from the
// image on every accept and at every boot, so a raw line number goes stale the
// moment you edit anything — mid-test a breakpoint in fact() silently moved from
// line 53 to 47 and simply stopped being hit. Anchoring to
// (declaration, offset within it) survives that: after each reload the anchor is
// mapped to the new line and re-armed.
class DbgBreak {
  String decl;      // the declaration it lives in ('' = raw-line breakpoint)
  int offset;       // lines from that declaration's first line
  int line;         // where it currently sits in the scratch file
  String vmId;      // the vm-service's id, so it can be removed
  // Conditional breakpoints are CLIENT-SIDE (this VM's addBreakpoint has no
  // condition): on hit the expression is evaluated in the top frame; false
  // resumes silently. hits/skips make the behaviour observable.
  String condition;
  int hits = 0, skips = 0;
  DbgBreak(this.decl, this.offset, this.line, this.vmId,
           [this.condition = '']);
}

List<DbgBreak> gDbgBreaks = <DbgBreak>[];

// The scratch's declarations start at column 0, so a top-level declaration is a
// line that begins with a non-space and is not a comment or an import.
final RegExp _declStart =
    new RegExp(r'^(?:abstract\s+)?(?:class|enum|typedef)\s+(\w+)|^(?:var|final)\s+(\w+)');

String _declNameOfLine(String line) {
  var m = _declStart.firstMatch(line);
  if (m == null) return null;
  return m.group(1) != null ? m.group(1) : m.group(2);
}

List<String> _scratchLines() {
  if (gDbgScratch == null) return <String>[];
  try { return new File(gDbgScratch).readAsStringSync().split('\n'); }
  catch (e) { return <String>[]; }
}

/// The declaration containing 1-based [line], and how far into it we are.
/// Returns null when the line is outside any declaration (the header, say).
List _anchorFor(List<String> lines, int line) {
  for (var i = line - 1; i >= 0 && i < lines.length; i--) {
    var name = _declNameOfLine(lines[i]);
    if (name != null) return <dynamic>[name, line - (i + 1)];
  }
  return null;
}

int _lineForAnchor(List<String> lines, String decl, int offset) {
  for (var i = 0; i < lines.length; i++) {
    if (_declNameOfLine(lines[i]) == decl) return i + 1 + offset;
  }
  return 0;   // the declaration is gone
}

/// Re-arm every breakpoint against the current scratch file. Called after an
/// accept (which rewrites it) and after a respawn (which also renumbers, and
/// gives the isolate a new id).
Future dbgReResolve() async {
  if (!gDbgIsLang) return;              // only the language isolate is reloaded/renumbered
  if (gLangIsolateId == null || gDbgBreaks.isEmpty) return;
  // A reload recompiles the library, and the SCRIPT gets a new id — re-arming
  // against the one captured at attach time fails with nothing but a null, which
  // read as "could not re-arm". Re-resolve the target first.
  if (!await vmsResolveTarget()) return;
  var lines = _scratchLines();
  var kept = <DbgBreak>[];
  for (var b in gDbgBreaks) {
    var line = _lineForAnchor(lines, b.decl, b.offset);
    if (line <= 0) {
      log("debugger: dropped a breakpoint — " + b.decl + " is gone");
      continue;
    }
    if (b.vmId != null) {
      await vmsCall('removeBreakpoint', <String, dynamic>{
        'isolateId': gLangIsolateId, 'breakpointId': b.vmId});
    }
    var r = await vmsCall('addBreakpoint', <String, dynamic>{
      'isolateId': gLangIsolateId, 'scriptId': gLangScriptId, 'line': line});
    if (r == null) {
      log("debugger: could not re-arm " + b.decl + "+" + b.offset.toString());
      continue;
    }
    b.line = line;
    b.vmId = r['id'];
    kept.add(b);
  }
  gDbgBreaks = kept;
  dbgLoadSource();
  if (kept.isNotEmpty) {
    dbgStatus(kept.length.toString() + " breakpoint(s) re-armed after the reload");
  }
}

// --- Debugger tab -----------------------------------------------------------
// Breakpoints, pause/step, and the stack, against the LANGUAGE isolate. The
// window stays live while user code is stopped because the debugger runs in a
// different isolate from the code it is debugging.
//
// Breakpoints address the language isolate's root script — the scratch file the
// image is written into — so that is what the source pane shows. Line numbers
// here are the numbers the VM uses, which is why they are displayed.
Cocoa gDbgSrc, gDbgStack, gDbgLocals, gDbgStatusLbl, gDbgEvalField;
Cocoa gDbgGutter;                     // the graphical breakpoint gutter (Sprint 16)
int gDbgPauseLine = 0;                // paused source line, for the gutter caret
// ST source mode: when set, the debug pane shows an ST script's source (fetched
// over vm-service, not a file) and the gutter sets breakpoints in it.
String gDbgStScriptId;                // the ST script under debug (null = Dart scratch)
String gDbgStSource;                  // its source text
List gDbgFrames = <dynamic>[];        // [functionName, frameJson]
List<int> gDbgFrameLines = <int>[];   // per-frame source line (0 = unknown)
Map gDbgTokenTables = <String, dynamic>{};   // scriptId -> tokenPosTable, per attach
List gDbgVars = <dynamic>[];          // [name, renderedValue] for the chosen frame
int gDbgFrame = 0;                    // which frame locals and eval apply to
// (breakpoints are anchored to a declaration — see DbgBreak below)
bool gDbgPaused = false;
String gDbgScratch;                   // the source file of the attached isolate
Cocoa gDbgIsoPicker;                  // the isolate lookup, to the left of Attach
List gDbgIsoList = <dynamic>[];       // [ [id, name, isLang], … ] matching picker rows
bool gDbgIsLang = true;               // is the target the reloadable language isolate?

// --- Profiler: surfaces the VM's built-in sampling CPU profiler (--profiler)
// over the same vm-service the debugger uses. Unlike the debugger it is
// READ-ONLY — sampling never pauses an isolate — so any isolate can be
// profiled (even the UI one) with no freeze risk.
Cocoa gProfIsoPicker;                 // isolate to profile
List gProfIsoList = <dynamic>[];      // [ [id, name, isUI, isLang], … ]
Cocoa gProfSrc;                       // the hot-function report (a mono text view)
Cocoa gProfStatusLbl;
Cocoa gProfMsField;                   // sample window, ms
List gProfRows = <dynamic>[];         // [ selfTicks, totalTicks, name ], self-desc
int gProfSamples = 0;                 // sampleCount of the last profile
List gProfFuncNames = <dynamic>[];    // resolved name per functions[] table index (for the trie)
dynamic gProfTrie;                    // inclusiveFunctionTrie: flat [idx,count,childCount,…] preorder
bool gDbgQuiet = false;               // 1: a pause does not yank the GUI to tab 5

// A vm-service value comes back as an @Instance: primitives carry
// valueAsString, everything else is identified by its class. Show the value when
// there is one and the class when there is not, rather than a handle nobody can
// read.
String dbgValue(var v) {
  if (v == null) return "null";
  if (v is! Map) return v.toString();
  if (v['valueAsString'] != null) {
    var s = v['valueAsString'].toString();
    if (v['kind'] == 'String') s = "'" + s + "'";
    if (v['valueAsStringIsTruncated'] == true) s = s + "…";
    return s;
  }
  if (v['kind'] == 'Null') return "null";
  if (v['class'] != null && v['class']['name'] != null) {
    var cls = v['class']['name'].toString();
    if (v['length'] != null) return cls + "(" + v['length'].toString() + ")";
    return "a " + cls;
  }
  if (v['kind'] != null) return v['kind'].toString();
  return v.toString();
}

void dbgStatus(String s) {
  if (gDbgStatusLbl != null) gDbgStatusLbl.setStringValue(s);
  repaint();
}

void buildDebugTab(Cocoa db) {
  db.setAutoresizesSubviews(true);
  // The isolate to debug, chosen BEFORE Attach. It lists every isolate except
  // the UI one — pausing that would freeze the debugger (and the window) itself.
  // Populated on entering this tab (switchTab) and on the first Attach.
  gDbgIsoPicker = Cocoa.cls("NSPopUpButton").alloc()
      .initWithFrame([8.0, 392.0, 148.0, 24.0], pullsDown: false);
  db.addSubview(gDbgIsoPicker);
  gDbgIsoPicker.setAutoresizingMask(kMinYMargin);
  button(db, "Attach", [162.0, 392.0, 72.0, 24.0], (s) => dbgAttach());
  button(db, "Pause", [238.0, 392.0, 62.0, 24.0], (s) => dbgPause());
  button(db, "Continue", [304.0, 392.0, 80.0, 24.0], (s) => dbgResume(null));
  button(db, "Step Over", [388.0, 392.0, 84.0, 24.0], (s) => dbgResume('Over'));
  button(db, "Step In", [476.0, 392.0, 72.0, 24.0], (s) => dbgResume('Into'));
  button(db, "Step Out", [552.0, 392.0, 78.0, 24.0], (s) => dbgResume('Out'));
  button(db, "Break Here", [634.0, 392.0, 92.0, 24.0], (s) => dbgToggleBreak());
  button(db, "Clear Breaks", [730.0, 392.0, 100.0, 24.0], (s) => dbgClearBreaks());
  pinTop(<String>["Attach", "Pause", "Continue", "Step Over", "Step In",
                  "Step Out", "Break Here", "Clear Breaks"]);

  gDbgStatusLbl = label(db, [8.0, 372.0, 852.0, 16.0]);
  gDbgStatusLbl.setAutoresizingMask(kMinYMargin + kWidthSizable);

  gDbgEvalField = Cocoa.cls("NSTextField").alloc().initWithFrame([8.0, 344.0, 640.0, 24.0]);
  gDbgEvalField.setStringValue("");
  var ef = _mono(12.0); if (!ef.isNil) gDbgEvalField.setFont(ef);
  db.addSubview(gDbgEvalField);
  gDbgEvalField.setAutoresizingMask(kMinYMargin + kWidthSizable);
  button(db, "Evaluate", [654.0, 343.0, 84.0, 26.0], (s) => dbgEval());
  // Break If: the field is the condition, the caret is the line — evaluated in
  // the top frame on each hit; false skips silently (see dbgAddBreak).
  button(db, "Break If", [742.0, 343.0, 92.0, 26.0], (s) => dbgBreakIf());
  pinTop(<String>["Evaluate", "Break If"], kMinXMargin);

  // source on the left, stack on the right
  var split = splitView([8.0, 8.0, 852.0, 330.0], true);
  var srcPane = browserPane(split, 560.0, 330.0);
  gDbgSrc = scrolledTextView(srcPane, [0.0, 0.0, 560.0, 330.0], false);
  var mf = _mono(12.0);
  if (!mf.isNil) gDbgSrc.setFont(mf);
  anchorScroll(gDbgSrc, kWidthSizable + kHeightSizable);
  // Sprint 16: the graphical breakpoint gutter — click a line to toggle a
  // breakpoint (Dart scratch or, in ST mode, an .mst script). Replaces the
  // old text "*" marker with a real IDE ruler (red dot + paused-line caret).
  var dbgScroll = gDbgSrc.enclosingScrollView();
  if (!dbgScroll.isNil) {
    gDbgGutter = attachGutter(dbgScroll, (line) { dbgGutterToggle(line); });
  }

  // stack over locals, so selecting a frame changes what you are looking at
  var right = browserPane(split, 284.0, 358.0);
  var rsplit = splitView([0.0, 0.0, 284.0, 358.0], false);
  var stackPane = browserPane(rsplit, 284.0, 170.0);
  gDbgStack = tableIn(stackPane, [0.0, 0.0, 284.0, 170.0]);
  gTargets.add(onTable(gDbgStack, () => gDbgFrames.length,
      (r) => gDbgFrames[r][0].toString(), sel(dbgSelectFrame)));
  var localsPane = browserPane(rsplit, 284.0, 188.0);
  gDbgLocals = tableIn(localsPane, [0.0, 0.0, 284.0, 188.0]);
  gTargets.add(onTable(gDbgLocals, () => gDbgVars.length,
      (r) => gDbgVars[r][0].toString() + " = " + gDbgVars[r][1].toString(),
      (r) {}));
  rsplit.adjustSubviews();
  rsplit.setPosition(170.0, ofDividerAtIndex: 0);
  setSplitMinSize(rsplit, 60.0);
  right.addSubview(rsplit);

  split.adjustSubviews();
  split.setPosition(560.0, ofDividerAtIndex: 0);
  setSplitMinSize(split, 160.0);
  db.addSubview(split);
  dbgStatus("not attached — press Attach (needs the vm-service: start-gui.sh enables it)");
}

// The Profiler tab: pick an isolate, Sample, read where its time goes. The
// picker offers ALL isolates (profiling is read-only — no freeze risk); the
// report is a mono text view of the hottest functions by self time.
void buildProfileTab(Cocoa pf) {
  pf.setAutoresizesSubviews(true);
  gProfIsoPicker = Cocoa.cls("NSPopUpButton").alloc()
      .initWithFrame([8.0, 392.0, 240.0, 24.0], pullsDown: false);
  pf.addSubview(gProfIsoPicker);
  gProfIsoPicker.setAutoresizingMask(kMinYMargin);
  var mslbl = label(pf, [256.0, 395.0, 22.0, 16.0]);
  mslbl.setStringValue("ms");
  mslbl.setAutoresizingMask(kMinYMargin);
  gProfMsField = Cocoa.cls("NSTextField").alloc().initWithFrame([278.0, 392.0, 60.0, 24.0]);
  gProfMsField.setStringValue("1000");
  pf.addSubview(gProfMsField);
  gProfMsField.setAutoresizingMask(kMinYMargin);
  button(pf, "Sample", [346.0, 392.0, 78.0, 24.0], (s) => profSampleButton());
  button(pf, "Tree", [428.0, 392.0, 60.0, 24.0], (s) => profTreeButton());
  button(pf, "Clear", [492.0, 392.0, 60.0, 24.0], (s) => profClearButton());
  pinTop(<String>["Sample", "Tree", "Clear"]);

  gProfStatusLbl = label(pf, [8.0, 372.0, 852.0, 16.0]);
  gProfStatusLbl.setAutoresizingMask(kMinYMargin + kWidthSizable);
  gProfStatusLbl.setStringValue(
      "pick an isolate and Sample — profiling is read-only (never pauses anything)");

  gProfSrc = scrolledTextView(pf, [8.0, 8.0, 852.0, 356.0], false);
  var mf = _mono(12.0); if (!mf.isNil) gProfSrc.setFont(mf);
  anchorScroll(gProfSrc, kWidthSizable + kHeightSizable);
  gProfSrc.setString(
      "No profile yet.\n\n"
      "This reads the VM's built-in sampling CPU profiler (--profiler) over the\n"
      "vm-service — where a running isolate's time actually goes, without\n"
      "pausing it. Run a CPU-bound demo or game, pick its isolate, and Sample.\n"
      "(A frame-paced demo that sleeps between frames shows few samples: the\n"
      "profiler only sees ON-CPU time.)");
}

Future dbgAttach() async {
  if (!await vmsConnect()) return;
  if (gDbgIsoList.isEmpty) await dbgRefreshIsolates();    // first Attach with no tab visit
  if (gDbgIsoList.isEmpty) { dbgStatus("no attachable isolate (only the UI is running)"); return; }
  var idx = gDbgIsoPicker.indexOfSelectedItem();
  if (idx < 0 || idx >= gDbgIsoList.length) idx = 0;
  var chosen = gDbgIsoList[idx];
  if (!await vmsResolveTargetId(chosen[0].toString(), chosen[1].toString())) return;
  await vmsCall('streamListen', <String, dynamic>{'streamId': 'Debug'});
  gDbgBreaks = <DbgBreak>[];                              // breakpoints belonged to the old target
  gDbgTokenTables = <String, dynamic>{};                  // and so did its scripts
  gDbgPauseLine = 0;                                      // no stale caret from the old target
  gDbgStScriptId = null; gDbgStSource = null;             // reset ST source mode
  dbgRepaintGutter();
  dbgLoadSource();
  dbgStatus("attached to " + _dbgIsoLabel(chosen[1].toString(), chosen[0].toString()) +
      (gDbgIsLang ? "  (language isolate)" : "  — raw-line breakpoints") +
      " — click a line, then Break Here");
  // Arm `self halt` in the language isolate: only now, with a debugger attached
  // to catch and resume it, is it safe to pause (debugger() BLOCKS forever with
  // no client). Unarmed, halt is the no-op the world promises.
  if (gDbgIsLang) ask('sthaltarm', 'on');
  log("debugger attached (" + gLangIsolateId + ")");
}

// The source the VM sees: the scratch file, with the VM's own line numbers.
void dbgLoadSource() {
  String src;
  if (gDbgStScriptId != null) {
    // ST source mode: the pane shows an .mst script (fetched over vm-service,
    // not a file). The graphical gutter carries the breakpoint markers.
    src = gDbgStSource != null ? gDbgStSource : "";
  } else {
    if (gDbgScratch == null) return;
    try { src = new File(gDbgScratch).readAsStringSync(); }
    catch (e) { dbgStatus("cannot read " + gDbgScratch); return; }
  }
  var lines = src.split('\n');
  var out = new StringBuffer();
  for (var i = 0; i < lines.length; i++) {
    var n = (i + 1).toString();
    while (n.length < 4) n = " " + n;
    // The graphical gutter (Sprint 16) draws breakpoint dots; the text keeps
    // just the line number for reference.
    out.write(" ");
    out.write(n);
    out.write("  ");
    out.write(lines[i]);
    out.write("\n");
  }
  gDbgSrc.setString(out.toString());
  dbgRepaintGutter();
  repaint();
}

/// The AUTHORITATIVE script of the live class [cls] — its Class object's
/// location.script (via getClassList), which is the same script the paused
/// frame reports. (A source-text search across libraries could pick a stale
/// combined-image layer whose line numbers are shifted from the live one, so
/// the gutter dots and the paused caret would disagree.)
Future<String> _dbgFindStScript(String cls) async {
  if (gLangIsolateId == null) return null;
  var cl = await vmsCall('getClassList', <String, dynamic>{'isolateId': gLangIsolateId});
  if (cl == null || cl['classes'] == null) return null;
  for (var c in cl['classes']) {
    if (c['name'] != null && c['name'].toString() == cls) {
      var obj = await vmsCall('getObject', <String, dynamic>{
        'isolateId': gLangIsolateId, 'objectId': c['id']});
      var loc = (obj != null) ? obj['location'] : null;
      var scr = (loc != null) ? loc['script'] : null;
      if (scr != null && scr['id'] != null) return scr['id'].toString();
    }
  }
  return null;
}

/// Point the debugger's source pane at an ST script (an st:mst/N id) — fetch
/// its source over the vm-service and switch breakpoints to it, so gutter
/// clicks set REAL Smalltalk breakpoints. Pass the class name to scroll to it.
Future<String> dbgLoadStScript(String scriptId, [String scrollToDecl]) async {
  if (gLangIsolateId == null) return "ERR: attach the language isolate first";
  var sc = await vmsCall('getObject', <String, dynamic>{
    'isolateId': gLangIsolateId, 'objectId': scriptId});
  if (sc == null || sc['source'] == null) return "ERR: script has no source";
  gDbgStScriptId = scriptId;
  gDbgStSource = sc['source'].toString();
  gLangScriptId = scriptId;      // breakpoints now land in the ST script
  gDbgIsLang = false;            // raw-line breakpoints (ST source is stable here)
  dbgLoadSource();
  var msg = "debugging ST script " + (sc['uri'] == null ? scriptId : sc['uri'].toString());
  if (scrollToDecl != null) {
    var idx = gDbgStSource.indexOf('subclass: ' + scrollToDecl);
    if (idx < 0) idx = gDbgStSource.indexOf(scrollToDecl);
    if (idx >= 0) {
      var line = 1;
      for (var i = 0; i < idx; i++) if (gDbgStSource.codeUnitAt(i) == 0x0A) line++;
      dbgScrollToLine(line);
      msg = msg + " — " + scrollToDecl + " at line " + line.toString();
    }
  }
  dbgStatus(msg);
  return msg;
}

/// Scroll the debug source so [line] is visible (1-based).
void dbgScrollToLine(int line) {
  if (gDbgSrc == null) return;
  var text = gDbgSrc.string().UTF8String();
  var pos = 0, cur = 1;
  while (cur < line && pos < text.length) {
    if (text.codeUnitAt(pos) == 0x0A) cur++;
    pos++;
  }
  gDbgSrc.scrollRangeToVisible([pos, 0]);
}

/// The 1-based line the caret sits on in the source pane.
int dbgCaretLine() {
  var r = gDbgSrc.selectedRange();
  var pos = (r is List && r.length > 0) ? r[0] : 0;
  var text = gDbgSrc.string().UTF8String();
  var line = 1;
  for (var i = 0; i < pos && i < text.length; i++) {
    if (text.codeUnitAt(i) == 0x0A) line++;
  }
  return line;
}

/// Arm a breakpoint at [line], optionally guarded by [condition] (evaluated
/// client-side in the top frame on each hit — see _dbgMaybeConditionalPause).
/// Returns the status message it also shows; "ERR: …" on failure.
Future<String> dbgAddBreak(int line, String condition) async {
  if (gLangIsolateId == null) { dbgStatus("attach first"); return "ERR: attach first"; }
  var r = await vmsCall('addBreakpoint', <String, dynamic>{
    'isolateId': gLangIsolateId, 'scriptId': gLangScriptId, 'line': line});
  if (r == null) {
    var m = "line " + line.toString() + ": no breakpoint there "
            "(a one-line class has no body line to stop on — Format it)";
    dbgStatus(m);
    return "ERR: " + m;
  }
  var suffix = (condition.isEmpty ? "" : "  if " + condition) +
               (r['resolved'] == true ? " — resolved" : " — pending");
  var m;
  if (gDbgIsLang) {
    // The language isolate's file is rewritten on every accept, so a raw line
    // goes stale — anchor to (declaration, offset) and re-map after each reload.
    var anchor = _anchorFor(_scratchLines(), line);
    if (anchor == null) {
      m = "line " + line.toString() + " is outside any declaration";
      dbgStatus(m);
      return "ERR: " + m;
    }
    gDbgBreaks.add(new DbgBreak(anchor[0], anchor[1], line, r['id'], condition));
    m = "breakpoint in " + anchor[0] + " +" + anchor[1].toString() +
        " (line " + line.toString() + ")" + suffix;
  } else {
    // Any other isolate is spawned from a stable file — a raw line is enough.
    gDbgBreaks.add(new DbgBreak('', 0, line, r['id'], condition));
    m = "breakpoint at line " + line.toString() + suffix;
  }
  dbgLoadSource();
  dbgStatus(m);
  return m;
}

Future dbgToggleBreak() async {
  await dbgAddBreak(dbgCaretLine(), '');
}

/// A gutter click: toggle a breakpoint at [line] — remove it if one is already
/// there, else arm one. Fire-and-forget (the gutter callback is synchronous).
void dbgGutterToggle(int line) {
  if (_dbgHasBreakAt(line)) {
    dbgRemoveBreakAt(line);
  } else {
    dbgAddBreak(line, '');
  }
}

/// Remove the breakpoint at [line] (both in the VM and our anchored list).
Future dbgRemoveBreakAt(int line) async {
  var kept = <DbgBreak>[];
  var removed = 0;
  for (var b in gDbgBreaks) {
    if (b.line == line) {
      if (gLangIsolateId != null && b.vmId != null) {
        await vmsCall('removeBreakpoint', <String, dynamic>{
          'isolateId': gLangIsolateId, 'breakpointId': b.vmId});
      }
      removed++;
    } else {
      kept.add(b);
    }
  }
  gDbgBreaks = kept;
  if (removed > 0) { dbgStatus("removed breakpoint at line " + line.toString()); }
  dbgLoadSource();
}

/// Repaint the gutter from the current breakpoints + paused line.
void dbgRepaintGutter() {
  if (gDbgGutter == null) return;
  var lines = <int>[];
  for (var b in gDbgBreaks) lines.add(b.line);
  gutterSetLines(gDbgGutter, lines, gDbgPaused ? gDbgPauseLine : 0);
}

/// The Break If button: the condition is whatever is typed in the eval field,
/// the line is the caret's — the two things already on screen.
Future dbgBreakIf() async {
  var cond = gDbgEvalField.stringValue().UTF8String().trim();
  if (cond.isEmpty) {
    dbgStatus("Break If: type the condition in the field first (it is "
              "evaluated in the top frame on each hit; false skips silently)");
    return;
  }
  await dbgAddBreak(dbgCaretLine(), cond);
}

bool _dbgHasBreakAt(int line) {
  for (var b in gDbgBreaks) if (b.line == line) return true;
  return false;
}

Future dbgClearBreaks() async {
  if (gLangIsolateId == null) return;
  var info = await vmsCall('getIsolate', <String, dynamic>{'isolateId': gLangIsolateId});
  if (info != null && info['breakpoints'] != null) {
    for (var bp in info['breakpoints']) {
      await vmsCall('removeBreakpoint', <String, dynamic>{
        'isolateId': gLangIsolateId, 'breakpointId': bp['id']});
    }
  }
  gDbgBreaks = <DbgBreak>[];
  dbgLoadSource();
  dbgStatus("breakpoints cleared");
}

Future dbgPause() async {
  if (gLangIsolateId == null) { dbgStatus("attach first"); return; }
  await vmsCall('pause', <String, dynamic>{'isolateId': gLangIsolateId});
}

Future dbgResume(String step) async {
  if (gLangIsolateId == null) return;
  var p = <String, dynamic>{'isolateId': gLangIsolateId};
  if (step != null) p['step'] = step;
  await vmsCall('resume', p);
  // The hold is dropped here, not on the Resume event: the watchdog clock must
  // stay stopped until user code is genuinely running again.
  if (gDbgPaused) { gDbgPaused = false; debugRelease(); }
  gDbgFrames = <dynamic>[];
  gDbgPauseLine = 0;              // clear the gutter caret
  dbgRepaintGutter();
  gDbgStack.reloadData();
  dbgStatus(step == null ? "running" : "stepping " + step);
}

// Debug-stream events. A pause is where the watchdog has to be told to stop
// counting — see debugHold().
void onVmsEvent(Map params) {
  var e = params['event'];
  if (e == null) return;
  // The Debug stream carries EVERY isolate's events. Another client — an
  // Observatory in a browser, say — pausing some other isolate must not flip
  // this debugger's state: gDbgPaused going true here freezes the whole
  // workspace ("press Continue first") over an isolate we are not even showing.
  var iso = e['isolate'] is Map ? e['isolate']['id'] : null;
  if (gLangIsolateId == null || iso != gLangIsolateId) return;
  var kind = e['kind'].toString();
  if (kind.startsWith('Pause')) {
    // The watchdog hold and the ask-gates belong to the LANGUAGE isolate; a
    // paused demo pauses only itself — the workspace channel stays live.
    if (!gDbgPaused) { gDbgPaused = true; if (gDbgIsLang) debugHold(); }
    _dbgMaybeConditionalPause(kind, e);
  } else if (kind == 'Resume') {
    if (gDbgPaused) { gDbgPaused = false; if (gDbgIsLang) debugRelease(); }
    dbgStatus("running");
  }
}

/// The breakpoint (ours) this pause event names, or null.
DbgBreak _dbgBreakForEvent(Map e) {
  var ids = <String>[];
  if (e['pauseBreakpoints'] is List) {
    for (var pb in e['pauseBreakpoints']) {
      if (pb is Map && pb['id'] != null) ids.add(pb['id'].toString());
    }
  }
  if (e['breakpoint'] is Map && e['breakpoint']['id'] != null) {
    ids.add(e['breakpoint']['id'].toString());
  }
  for (var b in gDbgBreaks) {
    if (b.vmId != null && ids.contains(b.vmId)) return b;
  }
  return null;
}

/// Conditional breakpoints, client-side: on PauseBreakpoint, evaluate the
/// breakpoint's condition in the TOP frame. Exactly 'false' resumes silently
/// (counted as a skip — the ask-gates are never tripped, so nothing else in
/// the workspace notices). 'true' pauses normally. Anything else — an eval
/// error, a non-bool — PAUSES with the reason: resuming would leave a broken
/// condition as a silently dead breakpoint.
Future _dbgMaybeConditionalPause(String kind, Map e) async {
  var b = (kind == 'PauseBreakpoint') ? _dbgBreakForEvent(e) : null;
  if (b != null && b.condition.isNotEmpty) {
    var v = await vmsCall('evaluateInFrame', <String, dynamic>{
      'isolateId': gLangIsolateId, 'frameIndex': 0, 'expression': b.condition});
    var truth = (v != null && v['valueAsString'] != null)
        ? v['valueAsString'].toString() : null;
    if (truth == 'false') {
      b.skips++;
      gDbgPaused = false;
      if (gDbgIsLang) debugRelease();
      await vmsCall('resume', <String, dynamic>{'isolateId': gLangIsolateId});
      return;
    }
    if (truth != 'true') {
      dbgStatus("condition '" + b.condition +
                "' did not answer true/false — pausing so you can see why");
    }
    b.hits++;
  } else if (b != null) {
    b.hits++;
  }
  if (gDbgIsLang) _tripPauseGates();
  // A breakpoint pause knows its exact line (the dot you clicked); the ST
  // frame's tokenPos->line can drift a few lines, so prefer the breakpoint's.
  dbgOnPaused(kind, (b != null) ? b.line : 0);
}

/// Forget a pause whose isolate no longer exists (it was killed or restarted).
/// This is state cleanup, NOT a resume: there is nothing left to resume.
void dbgForgetPause(String why) {
  if (gDbgPaused) { gDbgPaused = false; debugRelease(); }
  gDbgFrames = <dynamic>[];
  gDbgVars = <dynamic>[];
  if (gDbgStack != null) gDbgStack.reloadData();
  if (gDbgLocals != null) gDbgLocals.reloadData();
  dbgStatus(why);
}

// A tokenPosTable row is [lineNumber, tokenPos, col, tokenPos, col, …]; a
// frame's location carries an exact tokenPos, so an exact match finds its line.
int _dbgLineForToken(List table, int tokenPos) {
  for (var row in table) {
    if (row is! List || row.length < 2) continue;
    for (var i = 1; i + 1 < row.length; i += 2) {
      if (row[i] == tokenPos) return row[0];
    }
  }
  return 0;
}

/// The source line of one stack frame — via its script's tokenPosTable,
/// fetched once per script per attach (stepping pauses constantly; the table
/// never changes). 0 when unknown; a failed fetch caches empty so it is
/// asked exactly once.
Future<int> _dbgFrameLine(Map frame) async {
  var loc = frame['location'];
  if (loc == null || loc['script'] == null || loc['tokenPos'] == null) return 0;
  var sid = loc['script']['id'].toString();
  var table = gDbgTokenTables[sid];
  if (table == null) {
    var sc = await vmsCall('getObject', <String, dynamic>{
        'isolateId': gLangIsolateId, 'objectId': sid});
    table = (sc != null && sc['tokenPosTable'] != null)
        ? sc['tokenPosTable'] : <dynamic>[];
    gDbgTokenTables[sid] = table;
  }
  if (table is! List || table.isEmpty) return 0;
  var t = loc['tokenPos'];
  return _dbgLineForToken(table, t is int ? t : 0);
}

Future dbgOnPaused(String kind, [int hitLine = 0]) async {
  var stk = await vmsCall('getStack', <String, dynamic>{'isolateId': gLangIsolateId});
  gDbgFrames = <dynamic>[];
  if (stk != null && stk['frames'] != null) {
    for (var f in stk['frames']) {
      var name = (f['function'] != null) ? f['function']['name'].toString() : '?';
      gDbgFrames.add(<dynamic>[name, f]);
    }
  }
  gDbgFrameLines = <int>[];
  for (var f in gDbgFrames) {
    gDbgFrameLines.add(await _dbgFrameLine(f[1]));
  }
  // Sprint 16: if the top frame is in an .mst script, show that ST source in
  // the pane (so you SEE where you paused), then mark the paused line in the
  // gutter and scroll to it.
  var top = gDbgFrames.isEmpty ? null : gDbgFrames[0][1];
  var scr = (top != null && top['location'] != null) ? top['location']['script'] : null;
  if (scr != null && scr['uri'] != null &&
      scr['uri'].toString().startsWith('st:') && scr['id'] != null) {
    // Show the .mst source where we paused (its line comes from _dbgFrameLine's
    // tokenPosTable lookup — the service's tokenPos is table-keyed, not a raw
    // byte offset, so trust that value rather than recomputing).
    await dbgLoadStScript(scr['id'].toString());
  }
  gDbgPauseLine = (hitLine > 0)
      ? hitLine
      : (gDbgFrameLines.isNotEmpty ? gDbgFrameLines[0] : 0);
  dbgRepaintGutter();
  if (gDbgPauseLine > 0) dbgScrollToLine(gDbgPauseLine);
  gDbgStack.reloadData();
  gDbgFrame = 0;
  dbgShowVars(0);
  // Surface the debugger for a human, but not when an agent asked for quiet
  // (dbgquiet 1) — scripted stepping would otherwise yank the screen per step.
  // Already on tab 5: skip the redundant switch (it re-refreshes the picker).
  if (!gDbgQuiet && gTab != 5) switchTab(5);
  var at = gDbgFrames.isEmpty ? "?" : gDbgFrames[0][0].toString();
  if (gDbgFrameLines.isNotEmpty && gDbgFrameLines[0] > 0) {
    at += ":" + gDbgFrameLines[0].toString();
  }
  dbgStatus(kind + " at " + at + " — " + gDbgFrames.length.toString() +
            " frames; the window stays live because this is a different isolate");
  log("debugger: " + kind + " at " + at);
  repaint();
}

void dbgSelectFrame(int row) {
  if (row < 0 || row >= gDbgFrames.length) return;
  gDbgFrame = row;
  dbgShowVars(row);
  dbgStatus("frame " + row.toString() + ": " + gDbgFrames[row][0].toString() +
            " — locals and Evaluate now apply to this frame");
}

// A frame carries its own bound variables; no extra round trip needed.
void dbgShowVars(int row) {
  gDbgVars = <dynamic>[];
  if (row >= 0 && row < gDbgFrames.length) {
    var f = gDbgFrames[row][1];
    if (f is Map && f['vars'] != null) {
      for (var v in f['vars']) {
        gDbgVars.add(<dynamic>[v['name'].toString(), dbgValue(v['value'])]);
      }
    }
  }
  if (gDbgLocals != null) gDbgLocals.reloadData();
  repaint();
}

/// Run an expression IN the selected frame, so it sees that frame's locals.
/// Evaluate in the selected frame. RETURNS the rendered value (or "ERR: …" /
/// "error: …") — the control-plane verb hands it straight to the caller, so
/// an agent gets the value itself, not a race against the shared status label.
Future<String> dbgEval([String expr]) async {
  if (gLangIsolateId == null) { dbgStatus("attach first"); return "ERR: attach first"; }
  if (!gDbgPaused) {
    dbgStatus("evaluate needs the isolate stopped");
    return "ERR: evaluate needs the isolate stopped";
  }
  var src = expr != null ? expr : gDbgEvalField.stringValue().UTF8String();
  if (src.trim().isEmpty) return "";
  var r = await vmsCall('evaluateInFrame', <String, dynamic>{
    'isolateId': gLangIsolateId, 'frameIndex': gDbgFrame, 'expression': src});
  if (r == null) { dbgStatus("evaluate failed"); return "ERR: evaluate failed"; }
  // A failed evaluate carries the VM's whole stack trace; the first line is the
  // part that says what went wrong.
  var shown = (r['kind'] == 'Error' || r['message'] != null)
      ? ("error: " + _firstLine((r['message'] != null ? r['message'] : r).toString()))
      : dbgValue(r);
  dbgStatus(src + "  =>  " + shown);
  log("debug eval: " + src + " => " + shown);
  return shown;
}

// --- Demos tab ---------------------------------------------------------------
// Graphical demos, and a worked example of this app's own law: only the UI
// isolate may touch AppKit, because only it lives on thread 0. So a demo is a
// STANDALONE Dart program in demos/ next to this file, spawned into its own
// isolate (Isolate.spawnUri) — and free to spawn more of its own workers. Demo
// code never imports dart:cocoa: it computes, and sends draw commands over its
// SendPort; this isolate replays them into an NSImage with NSBezierPath and
// shows it in an NSImageView. Thread-correct by construction, and a runaway
// demo costs its isolate (Stop kills it), never the window.
//
// Demo -> UI messages (everything plain lists, so they cross the port cheaply):
//   ['draw', cmds]     replay a draw list onto the canvas (see below)
//   ['status', text]   one line under the canvas
//   ['done', text]     the demo is finished (logged; the isolate may then exit)
//   ['port', ctl]      opt into PULL pacing: the UI sends a tick on [ctl] to
//                      invite each frame; the demo answers one tick with one
//                      ['draw', …] and needs no Timer of its own. Preferred for
//                      anything heavy — the demo then can never outrun the
//                      renderer, and a slow machine degrades to fewer fps with
//                      no frame ever computed just to be dropped. (Demos that
//                      just push at their own rate still work; the pacer below
//                      drops what the machine can't show.)
//                      Each tick's payload is the GAMESTATE at that instant:
//                      [downKeycodes, modifierFlags] from dart:cocoa keyState()
//                      (left 123, right 124, down 125, up 126, space 49, A 0,
//                      D 2). While a demo runs on this tab, plain keys are
//                      captured for it — Cmd shortcuts stay with the app. So an
//                      interactive game is just a pull demo that reads its tick.
// Draw commands, coordinates TOP-LEFT (the renderer flips into AppKit's
// bottom-left; demos should never have to know):
//   ['clear', r,g,b]
//   ['rect', x,y,w,h, r,g,b, fill]        fill true/false
//   ['oval', x,y,w,h, r,g,b, fill]
//   ['line', x1,y1,x2,y2, r,g,b, width]
//   ['text', x,y, string, size, r,g,b]
// The demo learns the canvas size from its args: main(args, ui) gets
// [width, height] as strings.
Cocoa gDemoView, gDemoStatusLbl, gDemoImage;
Isolate gDemoIso;
ReceivePort gDemoPort, gDemoErrPort, gDemoExitPort;
String gDemoTitle;                     // the running demo, null when idle
// What Edit should open — mutually exclusive, mirroring gEdFile/gEdClass:
// a Dart demo (runDemoAt) is a file on disk (gDemoEditPath). A Smalltalk
// game (runStGame) or one-shot chart demo (runStDemo) sets gDemoEditStName
// instead — its _kStGames/_kStDemos DISPLAY name, which is not always its
// class (Waves is class WaveChart, FFT is class FftScope) — resolved to a
// real class lazily, on demand, by demoEdit via 'stnamecls', rather than
// trusting a cache populated once at menu-build time (stAddDemoMenu's own
// fetch of the demo list can lose that race against the language isolate
// spawning and never resolve, silently, for the rest of the session —
// confirmed live). Both null when idle (cleared alongside gDemoTitle in
// stopDemo).
String gDemoEditPath, gDemoEditStName;
int gDemoFrames = 0;
bool gDemoFinished = false;            // saw 'done' (so exit is not news)
const double kDemoW = 848.0, kDemoH = 352.0;

// A demo whose Timer enqueues draw lists faster than the renderer can paint
// them would let HandleAllMessages drain an ever-growing queue, pegging the
// main thread and starving AppKit — the frozen window a sampler caught. So the
// paint is PACED to what the machine sustains: render inline (as the message
// pump always has — repaint() is a synchronous gWindow.display(), so it only
// reaches the screen from this context, NOT from a Timer), then refuse to paint
// again until at least that paint's own COST has elapsed. Frames arriving inside
// that gap are dropped cheaply, so the queue can't grow. A demo heavier than the
// paint rate degrades to fewer fps; it never hangs.
var gDrawClock = new Stopwatch()..start();
int gDrawNextDueMs = 0;                 // earliest clock time the next paint may run
int gDemoPaints = 0;                    // frames actually painted (vs received)
const int kMinDrawGapMs = 15;           // idle floor between paints
SendPort gDemoCtl;                      // pull-mode demo's tick port (null = push)
const int kPullPeriodMs = 30;           // invite pull frames at ~33fps when cheap

// The game pane (GAMEPANE_PLAN.md): a demo whose first frame opens with
// ['gpopen', …] gets the Metal engine instead of the NSImage canvas. Its
// whole frame list goes to the native in ONE call (gpApply) — applied
// atomically, presented at the end, so MACVM's mid-frame flicker class
// cannot exist here. The NSView is engine-owned and reused across games.
bool gGpMode = false;
Cocoa gGpView;

void gpEnter(List cmds) {
  // The engine's NSView is a singleton: opening it here re-parents it away
  // from wherever it was — including the sprite editor's preview box. Tell
  // the editor it lost the pane, so its rebuilds stop until it re-acquires.
  spriteEdPaneTaken();
  soundEdPaneTaken();
  var o = cmds[0];
  int gi(int i, int dflt) =>
      (o.length > i && o[i] is num) ? (o[i] as num).toInt() : dflt;
  var w = gi(1, 424), h = gi(2, 240);
  gGpView = gpOpen(w, h, gi(3, w), gi(4, h), gi(5, 0));   // gi(5)=mode: 1 direct
  if (gDemoView != null) {
    gGpView.setFrame(gDemoView.frame());
    gGpView.setAutoresizingMask(kWidthSizable + kHeightSizable);
    gDemoView.superview().addSubview(gGpView);
    gDemoView.setHidden(true);
  }
  gGpMode = true;
  var rest = cmds.sublist(1);
  if (rest.isNotEmpty) {
    var e = gpApply(rest);
    if (e != null) log("⚠ gp: " + e.toString());
  }
  // A standalone game launched with --fullscreen goes fullscreen as soon as its
  // pane exists (once, then clear the flag so re-opens stay windowed).
  if (gStandaloneFullscreen) { gStandaloneFullscreen = false; gpFullscreen(true); }
}

void gpLeave() {
  if (!gGpMode) return;
  gpClose();
  if (gGpView != null) {
    try { gGpView.removeFromSuperview(); } catch (e) {}
  }
  gGpView = null;                       // the native keeps the NSView for reuse
  if (gDemoView != null) gDemoView.setHidden(false);
  gGpMode = false;
}

void buildDemosTab(Cocoa dm) {
  button(dm, "Stop", [8.0, 392.0, 64.0, 24.0], (s) => stopDemo("stopped"));
  // Fullscreen for the game pane only (Esc brings it back); the classic
  // NSImage canvas has no fullscreen story and the button says so by doing
  // nothing when no game is up.
  button(dm, "Full", [76.0, 392.0, 56.0, 24.0], (s) {
    if (gGpMode) gpFullscreen(true);
  });
  // Same contract as the App pane's Edit: stop what's running, open its
  // source on the Editor tab — a Dart demo's file, or a Smalltalk game's or
  // chart demo's class (demoEdit resolves whichever of gDemoEditPath/
  // gDemoEditStName is set).
  button(dm, "Edit", [138.0, 392.0, 60.0, 24.0], (s) => demoEdit());
  pinTop(<String>["Stop", "Full", "Edit"]);
  gDemoStatusLbl = label(dm, [204.0, 396.0, 656.0, 16.0]);
  gDemoStatusLbl.setAutoresizingMask(kMinYMargin + kWidthSizable);
  // The image survives a chrome rebuild on purpose: a demo that is mid-flight
  // keeps drawing into it while the views around it are torn down and rebuilt.
  if (gDemoImage == null) {
    gDemoImage = Cocoa.cls("NSImage").alloc().initWithSize([kDemoW, kDemoH]);
    renderDemo(<dynamic>[
      <dynamic>['clear', 0.07, 0.07, 0.09],
      <dynamic>['text', 14.0, 14.0,
        'Demos menu: pick one. It runs in its own isolate and draws here.',
        13.0, 0.62, 0.66, 0.76],
    ]);
  }
  gDemoView = Cocoa.cls("NSImageView").alloc().initWithFrame([8.0, 8.0, 852.0, 378.0]);
  gDemoView.setImageScaling(3);        // NSImageScaleProportionallyUpOrDown
  gDemoView.setImage(gDemoImage);
  gDemoView.setAutoresizingMask(kWidthSizable + kHeightSizable);
  dm.addSubview(gDemoView);
  // A chrome rebuild mid-game: the engine-owned Metal view survives the
  // teardown (it is not ours to destroy); re-seat it over the fresh canvas.
  if (gGpMode && gGpView != null) {
    gGpView.setFrame(gDemoView.frame());
    gGpView.setAutoresizingMask(kWidthSizable + kHeightSizable);
    dm.addSubview(gGpView);
    gDemoView.setHidden(true);
  }
  demoStatus(gDemoTitle == null
      ? "idle — pick something from the Demos menu"
      : "running " + gDemoTitle);
}

void demoStatus(String s) {
  if (gDemoStatusLbl != null) gDemoStatusLbl.setStringValue(s);
  repaint();
}

double _d(v) => (v as num).toDouble();

Cocoa _demoColor(r, g, b) => Cocoa.cls("NSColor")
    .colorWithCalibratedRed(_d(r), green: _d(g), blue: _d(b), alpha: 1.0);

/// Replay one draw list into the canvas image — the only place demo output
/// touches AppKit, and it runs on thread 0 by construction. Wrapped in an
/// autorelease pool: at 30fps the colours and paths would otherwise pile up
/// until the next drain.
/// Replay a draw list into ANY image — the Demos canvas or an app `canvas`
/// widget. `_w`/`_h` are the image size, for the top-left -> AppKit y-flip.
/// The op vocabulary (clear/rect/oval/line/text/blit) is shared by both.
void renderInto(Cocoa _img, double _w, double _h, List cmds) {
  if (_img == null) return;
  autoreleasePool(() {
    _img.lockFocus();
    for (var c in cmds) {
      if (c is! List || c.isEmpty) continue;
      var op = c[0];
      if (op == 'clear') {
        _demoColor(c[1], c[2], c[3]).setFill();
        Cocoa.cls("NSBezierPath").fillRect([0.0, 0.0, _w, _h]);
      } else if (op == 'rect' || op == 'oval') {
        var rect = [_d(c[1]), _h - _d(c[2]) - _d(c[4]), _d(c[3]), _d(c[4])];
        var col = _demoColor(c[5], c[6], c[7]);
        var fill = c.length > 8 && c[8] == true;
        if (op == 'rect') {
          if (fill) { col.setFill(); Cocoa.cls("NSBezierPath").fillRect(rect); }
          else { col.setStroke(); Cocoa.cls("NSBezierPath").strokeRect(rect); }
        } else {
          var path = Cocoa.cls("NSBezierPath").bezierPathWithOvalInRect(rect);
          if (fill) { col.setFill(); path.fill(); }
          else { col.setStroke(); path.stroke(); }
        }
      } else if (op == 'line') {
        _demoColor(c[5], c[6], c[7]).setStroke();
        Cocoa.cls("NSBezierPath").setDefaultLineWidth(c.length > 8 ? _d(c[8]) : 1.0);
        Cocoa.cls("NSBezierPath").strokeLineFromPoint(
            [_d(c[1]), _h - _d(c[2])],
            toPoint: [_d(c[3]), _h - _d(c[4])]);
      } else if (op == 'text') {
        var sz = _d(c[4]);
        var attrs = Cocoa.cls("NSMutableDictionary").dictionary();
        var f = _mono(sz);
        if (!f.isNil) attrs.setObject(f, forKey: "NSFont");
        attrs.setObject(_demoColor(c[5], c[6], c[7]), forKey: "NSColor");
        Cocoa.cls("NSString").stringWithString(c[3].toString())
            .drawAtPoint([_d(c[1]), _h - _d(c[2]) - sz * 1.25],
                withAttributes: attrs);
      } else if (op == 'blit') {
        // ['blit', x, y, dw, dh, base64-bmp] — a demos/pixmap.dart Pixmap.
        // The whole image crosses as one string; NSImage does the decode and
        // drawInRect: does the scaling.
        var data = Cocoa.cls("NSData").alloc()
            .initWithBase64EncodedString(c[5].toString(), options: 1);
        if (data.isNil) { log("blit: base64 decode failed (" + c[5].toString().length.toString() + " chars)"); continue; }
        var img = Cocoa.cls("NSImage").alloc().initWithData(data);
        if (img.isNil) { log("blit: NSImage rejected the BMP (" + data.length().toString() + " bytes)"); continue; }
        var dw = _d(c[3]), dh = _d(c[4]);
        // The single-argument drawInRect:, deliberately. The full
        // drawInRect:fromRect:operation:fraction: takes TWO NSRects — eight
        // doubles, exactly filling v0–v7 — so `fraction` must spill to the
        // stack, which the bridge's marshaler does not do: fraction arrived as
        // garbage and the image composited invisibly. One rect fits in
        // registers; whole image, source-over, fraction 1 is what we want.
        img.drawInRect([_d(c[1]), _h - _d(c[2]) - dh, dw, dh]);
      }
    }
    _img.unlockFocus();
  });
}

/// The Demos-tab canvas: render into gDemoImage, then show it on the Demos tab.
// --- Sprint 15b: ST demos into the demos pane -------------------------------
// The ST graphics tier emits HTML5-canvas JSON (["clearRect",..],["fillStyle",
// "#rgb"],["fillRect",..],["fillText",..],["beginPath"],["moveTo",..],["lineTo",
// ..],["stroke"], font/lineWidth/textAlign). This is the ONE translator from
// that vocabulary into the demos pane's native draw-ops (clear/rect/line/text)
// — so every existing ST canvas demo renders unchanged, no ST rewrite.
// Canvas y is baseline-down and top-left origin, which is exactly what
// renderInto already flips; colours parse from #rgb / #rrggbb / rgb()/rgba().

List<double> _cssColor(String c, List<double> fallback) {
  var s = c.trim().toLowerCase();
  if (s.startsWith('#')) {
    s = s.substring(1);
    if (s.length == 3) {
      s = s[0] + s[0] + s[1] + s[1] + s[2] + s[2];
    }
    if (s.length >= 6) {
      var r = int.parse(s.substring(0, 2), radix: 16, onError: (_) => -1);
      var g = int.parse(s.substring(2, 4), radix: 16, onError: (_) => -1);
      var b = int.parse(s.substring(4, 6), radix: 16, onError: (_) => -1);
      if (r >= 0 && g >= 0 && b >= 0) {
        return <double>[r / 255.0, g / 255.0, b / 255.0];
      }
    }
    return fallback;
  }
  if (s.startsWith('rgb')) {
    var lp = s.indexOf('('), rp = s.indexOf(')');
    if (lp >= 0 && rp > lp) {
      var nums = s.substring(lp + 1, rp).split(',');
      if (nums.length >= 3) {
        var r = double.parse(nums[0].trim(), (_) => -1.0);
        var g = double.parse(nums[1].trim(), (_) => -1.0);
        var b = double.parse(nums[2].trim(), (_) => -1.0);
        if (r >= 0 && g >= 0 && b >= 0) {
          return <double>[r / 255.0, g / 255.0, b / 255.0];
        }
      }
    }
    return fallback;
  }
  const named = const {
    'black': const [0.0, 0.0, 0.0], 'white': const [1.0, 1.0, 1.0],
    'red': const [1.0, 0.0, 0.0], 'green': const [0.0, 0.5, 0.0],
    'blue': const [0.0, 0.0, 1.0], 'gray': const [0.5, 0.5, 0.5],
    'grey': const [0.5, 0.5, 0.5],
  };
  return named.containsKey(s) ? new List<double>.from(named[s]) : fallback;
}

double _fontPx(String font) {
  // "12px monospace" / "bold 14px ..." -> 12 / 14; default 13.
  var m = new RegExp(r'(\d+(?:\.\d+)?)px').firstMatch(font);
  return m != null ? double.parse(m.group(1), (_) => 13.0) : 13.0;
}

/// Translate an HTML5-canvas JSON batch into demos-pane draw-ops.
List stCanvasToOps(String jsonBatch) {
  var cmds;
  try { cmds = JSON.decode(jsonBatch); }
  catch (e) { return <dynamic>[<dynamic>['clear', 0.07, 0.07, 0.09],
      <dynamic>['text', 8.0, 8.0, 'ST demo: bad canvas JSON', 13.0, 0.9, 0.4, 0.4]]; }
  if (cmds is! List) return <dynamic>[];
  var ops = <dynamic>[<dynamic>['clear', 0.07, 0.07, 0.09]];
  var fill = <double>[0.85, 0.85, 0.9];
  var stroke = <double>[0.5, 0.5, 0.5];
  var lw = 1.0;
  var size = 13.0;
  var path = <List<double>>[];        // accumulated moveTo/lineTo points
  for (var c in cmds) {
    if (c is! List || c.isEmpty) continue;
    var op = c[0].toString();
    if (op == 'clearRect') {
      // a full-canvas clear is already emitted; a partial one -> a filled rect
      // in the background colour (rare in these demos).
    } else if (op == 'fillStyle') {
      fill = _cssColor(c[1].toString(), fill);
    } else if (op == 'strokeStyle') {
      stroke = _cssColor(c[1].toString(), stroke);
    } else if (op == 'lineWidth') {
      lw = (c[1] as num).toDouble();
    } else if (op == 'font') {
      size = _fontPx(c[1].toString());
    } else if (op == 'fillRect') {
      ops.add(<dynamic>['rect', (c[1] as num).toDouble(), (c[2] as num).toDouble(),
          (c[3] as num).toDouble(), (c[4] as num).toDouble(),
          fill[0], fill[1], fill[2], true]);
    } else if (op == 'strokeRect') {
      ops.add(<dynamic>['rect', (c[1] as num).toDouble(), (c[2] as num).toDouble(),
          (c[3] as num).toDouble(), (c[4] as num).toDouble(),
          stroke[0], stroke[1], stroke[2], false]);
    } else if (op == 'fillText') {
      // canvas y is the text baseline; the pane's text y is the top -> lift.
      ops.add(<dynamic>['text', (c[2] as num).toDouble(),
          (c[3] as num).toDouble() - size, c[1].toString(), size,
          fill[0], fill[1], fill[2]]);
    } else if (op == 'beginPath') {
      path = <List<double>>[];
    } else if (op == 'moveTo' || op == 'lineTo') {
      path.add(<double>[(c[1] as num).toDouble(), (c[2] as num).toDouble()]);
    } else if (op == 'stroke') {
      for (var k = 1; k < path.length; k++) {
        ops.add(<dynamic>['line', path[k - 1][0], path[k - 1][1],
            path[k][0], path[k][1], stroke[0], stroke[1], stroke[2], lw]);
      }
    }
  }
  return ops;
}

// Append the Smalltalk demos to the Demos menu (the list is served by the
// language isolate — empty/greyed until the world is imported). Async, so the
// menu builds immediately and fills a beat later.
void stAddDemoMenu(Cocoa demos) {
  var header = menuItem(demos, "Smalltalk", "", (s) {});
  header.setEnabled(false);
  askQuiet('stdemos', '', const Duration(seconds: 6)).then((r) {
    if (r is! List) return;
    for (var d in r) {
      if (d is! List || d.length < 3) continue;
      var name = d[0].toString();
      var have = d[2] == true;
      var it = menuItem(demos, "  " + name, "", (s) => runStDemo(name));
      if (!have) it.setEnabled(false);
    }
  });
}

// Run a registered ST demo: ask the language isolate for its payload, render
// into the demos pane, switch to it. One-shot (a frame); the language isolate
// is never held (askQuiet bypasses the do-it watchdog — the perf chart runs
// the whole suite and legitimately takes seconds).
void runStDemo(String name) {
  switchTab(6);                                  // the Demos tab
  gDemoTitle = "Smalltalk " + name;
  // The real class (Waves -> WaveChart) is resolved lazily, on demand, by
  // demoEdit — see gDemoEditStName's own comment for why not eagerly here.
  gDemoEditStName = name;
  gDemoEditPath = null;
  demoStatus('Smalltalk: ' + name + ' …');
  askQuiet('stdemo', name + ' ' + kDemoW.toInt().toString() + ' ' +
      kDemoH.toInt().toString(), const Duration(seconds: 90)).then((r) {
    if (r == null) { demoStatus('ST demo: timed out'); return; }
    if (r is String) {                           // an ERR string
      demoStatus('ST demo: ' + r);
      log('x ST demo ' + name + ' - ' + r);
      return;
    }
    if (r is! List || r.isEmpty) { demoStatus('ST demo: no payload'); return; }
    var kind = r[0].toString();
    if (kind == 'json') {
      renderDemo(stCanvasToOps(r[1].toString()));
    } else if (kind == 'blit') {
      renderDemo(<dynamic>[<dynamic>['clear', 0.07, 0.07, 0.09],
          <dynamic>['blit', 0.0, 0.0, kDemoW, kDemoH, r[3].toString()]]);
    }
    demoStatus('Smalltalk: ' + name);
  });
}

void renderDemo(List cmds) {
  if (gDemoImage == null) return;
  renderInto(gDemoImage, kDemoW, kDemoH, cmds);
  // Off the Demos tab, keep rendering (the demo is live) but skip the window
  // redisplay — no point repainting pixels nobody can see at 30fps.
  if ((gTab == 6 || gStandalone) && gDemoView != null) {
    gDemoView.setImage(gDemoImage);    // never trust the view's cached rep
    gDemoView.setNeedsDisplay(true);
    repaint();
    // NOTE: display() reaches the screen at demo rates ONLY when frames leave
    // the run loop idle time between them — an unpaced burst renders every
    // frame but the screen shows just the last. Demos must pace themselves
    // (~30ms); see 04_mandelbrot. (A CATransaction flush here looked like the
    // fix and ABORTED the app — unprobed AppKit from a hot path, the exact
    // trap the probe law exists for.)
  }
}

String demosDir() => Platform.script.resolve('demos/').toFilePath();

/// `[title, path]` per demo file, sorted by filename. The title is the file's
/// `// Demo:` header (or the ST comment twin `"Demo:`), so the menu reads
/// like a playbill, not a directory. `.dart` and `.mst` demos live side by
/// side here exactly as they already do in apps/ (scanApps) — a `.mst` demo
/// is installed into the running image and played live instead of spawned
/// into its own isolate (see runStFileDemo), but it is found the same way.
List<List<String>> scanDemos() {
  var out = <List<String>>[];
  try {
    var files = <String>[];
    for (var f in new Directory(demosDir()).listSync()) {
      if (f.path.endsWith('.dart') || f.path.endsWith('.mst')) files.add(f.path);
    }
    files.sort();
    for (var path in files) {
      var title, kind = 'demo';
      try {
        for (var line in new File(path).readAsLinesSync().take(5)) {
          // The marker must OPEN the line: a file that merely mentions it in
          // prose (pixmap.dart's header does) is not declaring itself a demo.
          // `Game:` is the same marker for something PLAYABLE — it lands in the
          // Games menu instead, so a game dropped in demos/ needs no entry in
          // any table to be listed where a player looks for it.
          if (line.startsWith('// Demo:')) { title = line.substring(8).trim(); break; }
          if (line.startsWith('// Game:')) {
            title = line.substring(8).trim(); kind = 'game'; break;
          }
          if (line.startsWith('"Demo:') || line.startsWith('"Game:')) {
            if (line.startsWith('"Game:')) kind = 'game';
            var t = line.substring(6).trim();
            var q = t.indexOf('"');
            title = (q >= 0 ? t.substring(0, q) : t).trim();
            break;
          }
        }
      } catch (e) {}
      // No header, no listing: files like pixmap.dart are LIBRARIES the demos
      // import, not programs to spawn.
      if (title == null) continue;
      out.add(<String>[title, path, kind]);
    }
  } catch (e) {}   // no demos folder: the menu will say so
  return out;
}

Future runDemoAt(String title, String path) async {
  stopDemo(null);
  gDemoFrames = 0;
  gDemoPaints = 0;
  gDemoFinished = false;
  gDemoTitle = title;
  gDemoEditPath = path; gDemoEditStName = null;   // what the Edit button opens
  if (!gStandalone) switchTab(6);
  demoStatus("starting " + title + "…");
  gDemoPort = new ReceivePort();
  gDemoErrPort = new ReceivePort();
  gDemoExitPort = new ReceivePort();
  gDemoPort.listen(onDemoMsg);
  gDemoErrPort.listen((e) {
    var m = (e is List && e.length > 0) ? e[0].toString() : e.toString();
    log("⚠ demo error: " + _firstLine(m));
    demoStatus(title + " — error: " + _firstLine(m));
  });
  gDemoExitPort.listen((_) {
    gDemoIso = null;
    if (!gDemoFinished) demoStatus(title + " — demo isolate exited");
  });
  try {
    gDemoIso = await Isolate.spawnUri(Uri.parse('file://' + path),
        <String>[kDemoW.toInt().toString(), kDemoH.toInt().toString()],
        gDemoPort.sendPort,
        onError: gDemoErrPort.sendPort, onExit: gDemoExitPort.sendPort,
        errorsAreFatal: false);
  } catch (e) {
    log("✗ demo failed to load — " + _firstLine(e.toString()));
    demoStatus("failed to load " + title + " — " + _firstLine(e.toString()));
    stopDemo(null);
    return;
  }
  log("demo: " + title + "  (" + path.split('/').last + ")");
}

void stopDemo(String why) {
  if (gStGameActive) {
    // An ST game has no demo isolate to kill — tell the language isolate to
    // end its tick loop and run the game's onReset: instead.
    gStGameActive = false;
    askQuiet('stgamestop', '', const Duration(seconds: 5));
  }
  if (gDemoIso != null) {
    try { gDemoIso.kill(priority: Isolate.IMMEDIATE); } catch (e) {}
  }
  gDemoIso = null;
  if (gDemoPort != null) gDemoPort.close();
  if (gDemoErrPort != null) gDemoErrPort.close();
  if (gDemoExitPort != null) gDemoExitPort.close();
  gDemoPort = null; gDemoErrPort = null; gDemoExitPort = null;
  gDemoCtl = null;                      // orphan any scheduled pull tick
  gDrawNextDueMs = 0;                   // let the next demo paint immediately
  keyCapture(false);                    // the keyboard back to the workspace
  gpLeave();                            // Metal pane down, NSImage canvas back
  if (gDemoTitle != null && why != null) {
    demoStatus(gDemoTitle + " — " + why);
    log("demo " + why + " — " + gDemoTitle);
  }
  gDemoTitle = null;
  gDemoEditPath = null; gDemoEditStName = null;
}

/// Open whatever is running (or last shown) on the Demos tab in the Editor,
/// stopping it first — the same "Edit ends it" contract the App pane's Edit
/// button has. A Dart demo (runDemoAt) is a file on disk (gDemoEditPath); a
/// Smalltalk game (runStGame) or one-shot chart demo (runStDemo) only has
/// its display name (gDemoEditStName — Waves is class WaveChart, FFT is
/// class FftScope), resolved to a real class here via 'stnamecls', on
/// demand, rather than a cache populated once at menu-build time (which
/// can lose the race against the language isolate spawning and never
/// resolve for the rest of the session — confirmed live).
Future demoEdit() async {
  var path = gDemoEditPath, stName = gDemoEditStName, cls;
  if (path == null && stName == null) {
    demoStatus("nothing to edit — pick something from the Demos or Games menu");
    return;
  }
  if (stName != null) {
    var r = (await ask('stnamecls', stName)).toString();
    if (r.startsWith('ERR')) {
      demoStatus("could not resolve " + stName + "'s class");
      return;
    }
    cls = r;
  }
  if (cls != null) {
    var src = (await ask('classsrc', cls)).toString();
    if (src.isEmpty || src.startsWith('ERR')) {
      demoStatus("could not read " + cls + " from the image");
      return;
    }
    stopDemo(null);
    gEdClass = cls; gEdFile = null;
    switchTab(4);
    edSetText(src);
    edStatus(cls + "  ·  stopped for editing  ·  Save to Image compiles + "
             "saves; pick it again from the Games menu to try it");
    log("editing " + cls + " (stopped)");
    return;
  }
  var src;
  try { src = new File(path).readAsStringSync(); }
  catch (e) { demoStatus("could not read " + path); return; }
  var title = gDemoTitle;
  stopDemo(null);
  gEdFile = path; gEdClass = null;
  switchTab(4);
  edSetText(src);
  edStatus(path + "  ·  stopped for editing  ·  Save writes to disk; "
           "Rescan Demos Folder then pick it again to try it");
  log("editing " + (title != null ? title : path) + " (stopped)");
}

// --- Smalltalk games (GAMEPANE_PLAN.md §8: the language-isolate driver) ------
// The language isolate launches the game, then acts as a pull demo: its
// ['port'/'draw'/'done'] pushes arrive on gFromLang and are fed into
// _onDemoMsg above while this flag is up (see spawnLanguage's listener).
bool gStGameActive = false;

void runStGame(String name) {
  stopDemo(null);                       // replaces any demo OR prior ST game
  gStGameActive = true;
  gDemoTitle = "Smalltalk " + name;     // keyCapture keys off this on tab 6
  // name is a _kStGames display name, not always its class (FFT -> FftScope)
  // — resolved lazily by demoEdit via 'stnamecls', same as one-shot demos.
  gDemoEditStName = name;
  gDemoEditPath = null;
  switchTab(6);
  keyCapture(true);
  demoStatus('Smalltalk ' + name + ' …');
  askQuiet('stgame', name, const Duration(seconds: 30)).then((r) {
    if (r == 'ok') {
      demoStatus('Smalltalk ' + name + ' — arrows to play, Stop Demo to end');
      log("st game: " + name);
      return;
    }
    gStGameActive = false;
    var err = r == null ? 'timed out' : r.toString();
    demoStatus('ST game: ' + err);
    log("x st game " + name + " - " + err);
  });
}

/// Run a [title, path] pair as scanDemos() returns it, regardless of which
/// call site found it (the Demos menu, the Games menu's dartGames slice, the
/// `demorun` console command, or a standalone `--game` launch): a `.dart`
/// demo spawns into its own isolate (runDemoAt); a `.mst` demo installs into
/// the running image and plays live instead (runStFileDemo). Routing every
/// site through here means `.mst` support is not something each one has to
/// remember to add.
Future runScannedDemo(String title, String path) {
  return path.endsWith('.mst') ? runStFileDemo(title, path) : runDemoAt(title, path);
}

/// A standalone `.mst` file found by scanDemos (Demos menu), the same file
/// shape apps/ already colocates with .dart via scanApps. There is no isolate
/// to spawn — the classes FILE IN to the same running isolate (editorDecls +
/// acceptLive: live now, never written to the image) and then play live through
/// the ST-game pull-tick loop (runStGame), so a demo dropped in demos/ needs
/// no matching entry in language.dart's _kStGames table: _stGame() falls back
/// there to an ad-hoc {cls: name, sel: 'launch'} for any class it finds
/// live but not in its hardcoded list.
Future runStFileDemo(String title, String path) async {
  var src;
  try { src = new File(path).readAsStringSync(); }
  catch (e) { log("✗ demo — cannot read " + path); return; }
  var decls = editorDecls(src);
  if (decls.isEmpty) { log("✗ demo — " + path + " has no declarations"); return; }
  // WHICH class is the game? The one with a class-side `launch` — a file may
  // hold five (Galaxigans ships the game, an alien, a shot, a spark and a
  // species), and taking the first one found would start the alien.
  var name, first;
  var stClassRe = new RegExp(r'subclass:\s*(\w+)\s*\[');
  for (var d in decls) {
    var s = d.toString();
    var n = _classNameOf(s);
    if (n == null) {
      var m = stClassRe.firstMatch(s);
      if (m != null) n = m.group(1);
    }
    if (n == null) continue;
    if (first == null) first = n;
    if (name == null &&
        new RegExp(r'\bclass\s*>>\s*launch\b').hasMatch(s)) name = n;
  }
  if (name == null) name = first;
  if (name == null) { log("✗ demo — no class in " + path); return; }
  var r = await checkDecls(decls);
  if (!r.ok) { log("✗ demo refused — " + r.message); return; }
  // FILE IN, do not install: acceptLive makes the classes live in the running
  // isolate without writing them to the image. A game belongs to its FILE — the
  // Demos/Games menu IS the folder, Save writes back to disk (gDemoEditPath
  // below), and every launch re-reads the file, so what runs is always what is
  // on disk. Committing them with acceptMany instead left a stale copy in the
  // image that silently won on the next launch: edit the file, run it, and the
  // OLD code played — hours of "but I fixed that" (galaxigans' hall of fame).
  // Apps are different and still install: an app is meant to live in the image
  // and be edited there (see _installApp). Data a game persists is different
  // again — the hall of fame is a class the GAME writes, and it goes through the
  // host's store verb, so scores survive while code never does.
  var reply = await ask('acceptLive', decls);
  log("✓ filed in " + title + " — " + reply.toString() + " (file, not image)");
  await runStGame(name);
  // runStGame points Edit at the launched CLASS; for a filed-in game the file
  // is the truth (it holds every class, and Save writes back to disk), so it
  // wins.
  gDemoEditPath = path; gDemoEditStName = null;
}

void onDemoMsg(msg) {
  // A demo sending garbage must cost the frame, never the window: this runs in
  // the isolate's MESSAGE HANDLER, where an uncaught throw is fatal.
  try { _onDemoMsg(msg); }
  catch (e) { log("⚠ demo message dropped — " + _firstLine(e.toString())); }
}

void _onDemoMsg(msg) {
  if (msg is! List || msg.isEmpty) return;
  var kind = msg[0];
  if (kind == 'draw') {
    gDemoFrames++;
    var cmds = msg[1];
    // gpopen is SETUP, not a frame: it must neither consume the paint budget
    // nor schedule a tick — the game's first real frame follows immediately
    // behind it (answering the 'port' tick), and the pacer dropping THAT
    // frame silently eats the game's one-time scene definitions.
    if (!gGpMode && cmds is List && cmds.isNotEmpty && cmds[0] is List &&
        (cmds[0] as List).isNotEmpty && cmds[0][0] == 'gpopen') {
      gpEnter(cmds);                                   // Metal pane takes over
      return;
    }
    var t = gDrawClock.elapsedMilliseconds;
    if (t >= gDrawNextDueMs) {
      if (gGpMode) {
        var e = gpApply(cmds);                         // one native call/frame
        if (e != null) log("⚠ gp: " + e.toString());
      } else {
        renderDemo(cmds);                              // inline: display() works
      }
      gDemoPaints++;
      var end = gDrawClock.elapsedMilliseconds;
      var cost = end - t;
      // Due time counts from the END of this paint, and the gap is at least
      // the paint's own cost: display() only reaches the glass when the run
      // loop goes IDLE, so every paint must buy an equal breath of idle after
      // it. (start+cost was tried and is wrong: a queued frame is already due
      // the moment the paint ends — back-to-back paints, no idle, frozen glass.)
      var gap = cost > kMinDrawGapMs ? cost : kMinDrawGapMs;
      gDrawNextDueMs = end + gap;
      if (gDemoCtl != null) {
        // Pull mode: invite the next frame so it lands at ~kPullPeriodMs pace
        // when paints are cheap, and no sooner than the idle debt when they
        // are not. The port is captured: a tick must never reach a demo that
        // replaced the one it was scheduled for.
        var wait = kPullPeriodMs - cost;
        if (wait < gap) wait = gap;
        var p = gDemoCtl;
        new Timer(new Duration(milliseconds: wait), () {
          // The tick carries the GAMESTATE: [downKeycodes, modifierFlags] at
          // this instant. Non-games ignore the payload; games read their input
          // exactly once per frame with no event queue to drain.
          if (!identical(gDemoCtl, p)) return;
          var ks = keyState();
          // Esc while the game pane is fullscreen: the workspace comes back.
          // (The keypress still reaches the game in this same tick.)
          if (gGpMode && ks[0] is List && (ks[0] as List).contains(53)) {
            gpFullscreen(false);
          }
          p.send(ks);
        });
      }
    }
    // else: behind — drop this frame cheaply so the message queue can't grow
    // (an honest pull demo is never early, so never dropped)
    if (gDemoFrames % 30 == 1 && gDemoTitle != null) {
      demoStatus(gDemoTitle + " — frame " + gDemoFrames.toString());
    }
  } else if (kind == 'port') {
    gDemoCtl = msg[1];
    gDemoCtl.send(keyState());           // the first invitation starts the loop
  } else if (kind == 'status') {
    demoStatus((gDemoTitle != null ? gDemoTitle + " — " : "") + msg[1].toString());
  } else if (kind == 'done') {
    gDemoFinished = true;
    demoStatus((gDemoTitle != null ? gDemoTitle + " — " : "") + msg[1].toString());
    log("demo done — " + msg[1].toString());
  }
}

// --- Help: searchable Dart V1 reference --------------------------------------
// The Docs tab is the workspace guide PLUS a search over the Dart V1 language
// itself: every documented declaration in the SDK libraries this VM was built
// from, the language specification, and dart:cocoa. Nothing is transcribed —
// see help/indexer.dart — so the help cannot describe a language other than the
// one you are running.
//
// The index lives in its own isolate: parsing ~9MB of source on thread 0 would
// stall the window, and this isolate is the one that must never stall. Spawned
// on first use, so startup pays nothing.
Cocoa gHelpField, gHelpTable, gHelpText, gHelpStatusLbl;
SendPort gHelpPort;                    // the indexer, once it is up
ReceivePort gHelpFrom;
List gHelpRows = <dynamic>[];          // [id, kind, where, name, summary]
int gHelpCount = 0;
bool gHelpStarting = false;
String gHelpQuery = '';
String gHelpDetail = '';

void buildDocsTab(Cocoa dc) {
  dc.setAutoresizesSubviews(true);
  // 44pt clipped it to "Searc". A label is not sized to its text by default,
  // and every control in a resizable tab needs its mask set or it drifts away
  // from the row it belongs to when the window grows.
  var lbl = label(dc, [8.0, 394.0, 56.0, 18.0]);
  lbl.setStringValue("Search");
  lbl.setAutoresizingMask(kMinYMargin);
  gHelpField = Cocoa.cls("NSTextField").alloc().initWithFrame([68.0, 390.0, 308.0, 24.0]);
  var hf = _mono(12.0); if (!hf.isNil) gHelpField.setFont(hf);
  dc.addSubview(gHelpField);
  gHelpField.setAutoresizingMask(kMinYMargin);
  gTargets.add(onTextChange(gHelpField, (s) =>
      defer(() => helpSearch(s.stringValue().UTF8String()))));
  button(dc, "Guide", [384.0, 389.0, 68.0, 26.0], (s) => helpShowGuide());
  pinTop(<String>["Guide"]);
  gHelpStatusLbl = label(dc, [460.0, 394.0, 400.0, 18.0]);
  gHelpStatusLbl.setAutoresizingMask(kMinYMargin + kWidthSizable);

  // results on the left, the entry itself on the right
  var split = splitView([8.0, 8.0, 852.0, 374.0], true);
  var listPane = browserPane(split, 300.0, 374.0);
  gHelpTable = tableIn(listPane, [0.0, 0.0, 300.0, 374.0]);
  gTargets.add(onTable(gHelpTable, () => gHelpRows.length,
      (r) => gHelpRows[r][3].toString(), sel(helpSelect)));
  var textPane = browserPane(split, 544.0, 374.0);
  gHelpText = scrolledTextView(textPane, [0.0, 0.0, 544.0, 374.0], false);
  var mf = _mono(12.0);
  if (!mf.isNil) gHelpText.setFont(mf);
  anchorScroll(gHelpText, kWidthSizable + kHeightSizable);
  split.adjustSubviews();
  split.setPosition(300.0, ofDividerAtIndex: 0);
  setSplitMinSize(split, 140.0);
  dc.addSubview(split);

  gHelpText.setString(gHelpDetail.isEmpty ? _docsText : gHelpDetail);
  helpStatus(gHelpCount > 0
      ? (gHelpCount.toString() + " entries — search the language, the libraries and dart:cocoa")
      : "type to search the Dart V1 language and libraries");
}

void helpStatus(String s) {
  if (gHelpStatusLbl != null) gHelpStatusLbl.setStringValue(s);
  repaint();
}

void helpShowGuide() {
  gHelpDetail = _docsText;
  if (gHelpText != null) gHelpText.setString(_docsText);
  repaint();
}

/// Bring the indexer up. Spawned once, on first use.
Future helpStart() async {
  if (gHelpPort != null || gHelpStarting) return;
  gHelpStarting = true;
  gHelpFrom = new ReceivePort();
  gHelpFrom.listen(onHelpMsg);
  var here = Platform.script;
  var sdkLib = here.resolve('../../../sdk/sdk/lib').toFilePath();
  var spec = here.resolve('../../../sdk/docs/language/dartLangSpec.tex').toFilePath();
  var cocoa = here.resolve('../cocoa.dart').toFilePath();
  helpStatus("indexing the SDK and the language spec…");
  try {
    await Isolate.spawnUri(here.resolve('help/indexer.dart'),
        <String>[sdkLib, spec, cocoa], gHelpFrom.sendPort);
  } catch (e) {
    gHelpStarting = false;
    helpStatus("help: could not start the indexer — " + _firstLine(e.toString()));
  }
}

void onHelpMsg(msg) {
  try {
    if (msg is! List || msg.isEmpty) return;
    var kind = msg[0];
    if (kind == 'port') {
      gHelpPort = msg[1];
      gHelpStarting = false;
      if (gHelpQuery.isNotEmpty) gHelpPort.send(<dynamic>['q', gHelpQuery]);
    } else if (kind == 'ready') {
      gHelpCount = msg[1];
      helpStatus(gHelpCount.toString() +
          " entries — the SDK this VM was built from, the language spec, dart:cocoa");
    } else if (kind == 'status') {
      helpStatus(msg[1].toString());
    } else if (kind == 'results') {
      if (msg[1].toString() != gHelpQuery) return;   // a stale query's answer
      gHelpRows = msg[2];
      gHelpTable.reloadData();
      helpStatus(gHelpRows.isEmpty
          ? ("nothing matches '" + gHelpQuery + "'")
          : (gHelpRows.length.toString() + " for '" + gHelpQuery + "'"));
      if (gHelpRows.isNotEmpty) helpSelect(0);
    } else if (kind == 'detail') {
      gHelpDetail = msg[2].toString();
      gHelpText.setString(gHelpDetail);
      gHelpText.scrollRangeToVisible([0, 0]);
      repaint();
    }
  } catch (e) {
    log("⚠ help message dropped — " + _firstLine(e.toString()));
  }
}

void helpSearch(String q) {
  gHelpQuery = q.trim();
  if (gHelpPort == null) { helpStart(); return; }
  if (gHelpQuery.isEmpty) {
    gHelpRows = <dynamic>[];
    gHelpTable.reloadData();
    helpShowGuide();
    helpStatus(gHelpCount.toString() + " entries — type to search");
    return;
  }
  gHelpPort.send(<dynamic>['q', gHelpQuery]);
}

void helpSelect(int row) {
  if (row < 0 || row >= gHelpRows.length) return;
  // selectRowIndexes:, not the deprecated selectRow: — an unknown selector
  // aborts the process, so only the form already proven here is used.
  if (gHelpTable != null) {
    gHelpTable.selectRowIndexes(
        Cocoa.cls("NSIndexSet").indexSetWithIndex(row), byExtendingSelection: false);
    gHelpTable.scrollRowToVisible(row);
  }
  if (gHelpPort == null) return;
  gHelpPort.send(<dynamic>['get', gHelpRows[row][0]]);
}

/// Wait for the index and a query to settle — `settle` cannot see this work
/// because it happens in another isolate.
Future helpSettle([int maxMs = 60000]) async {
  var waited = 0;
  while (gHelpPort == null && waited < maxMs) {
    await new Future.delayed(const Duration(milliseconds: 50));
    waited += 50;
  }
  while (gHelpCount == 0 && waited < maxMs) {
    await new Future.delayed(const Duration(milliseconds: 50));
    waited += 50;
  }
  await new Future.delayed(const Duration(milliseconds: 120));
  return gHelpCount > 0;
}

// --- App surface (APP_PANE_PLAN.md) ------------------------------------------
// Where a user's own Cocoa app runs. The app itself lives in the LANGUAGE
// isolate — that is where the image, morphing hot reload, the debugger and the
// watchdog are — and it never touches AppKit, because only this isolate may.
// It sends widget commands; this materialises real NSViews from them and sends
// events back. One app at a time, on one surface (M2 adds the window).
//
// Commands, all top-left coordinates (flipped here, so apps never meet AppKit's
// origin):  ['clear'] ['add', kind, id, props] ['set', id, props]
//           ['remove', id] ['title', text] ['focus', id]
Cocoa gAppPane, gAppPicker, gAppStatusLbl, gAppTitleLbl;
Map<String, Cocoa> gAppViews = <String, Cocoa>{};
Map<String, String> gAppKinds = <String, String>{};
List<String> gAppOrder = <String>[];
Map<String, List> gAppListItems = <String, List>{};          // rows of each list widget
Map<String, List<Cocoa>> gAppTabPages = <String, List<Cocoa>>{};  // content view per tab
Map<String, Cocoa> gAppScrollDoc = <String, Cocoa>{};   // a scroll container's document view
Map<String, double> gAppScrollH = <String, double>{};   // its content height, for the coord flip
Map<String, Cocoa> gAppCanvasImg = <String, Cocoa>{};   // a canvas widget's backing NSImage
Map<String, List> gAppCanvasWH = <String, List>{};      // its [w,h], for renderInto's y-flip
Cocoa gAppContainer;                  // where adds land now (a tab page/scroll doc), or null = the pane
double gAppContainerH = 0.0;          // its height for the coord flip (a non-shown tab page reads 0)
List gAppSpec = <dynamic>[];      // commands since the last clear, for a rebuild
String gAppName;                  // the running app's class, null when idle
const double kAppW = 852.0;

void buildAppTab(Cocoa ap) {
  ap.setAutoresizesSubviews(true);
  gAppPicker = Cocoa.cls("NSPopUpButton").alloc()
      .initWithFrame([8.0, 390.0, 220.0, 26.0], pullsDown: false);
  ap.addSubview(gAppPicker);
  gAppPicker.setAutoresizingMask(kMinYMargin);
  button(ap, "Run", [234.0, 390.0, 60.0, 26.0], (s) {
    if (gAppPicker.numberOfItems() == 0) { appStatus("no app classes in the image"); return; }
    appRun(gAppPicker.titleOfSelectedItem().UTF8String());
  });
  button(ap, "Stop App", [298.0, 390.0, 84.0, 26.0], (s) => appStop());
  // The point of the pane: change the app that is running in it. Edit stops
  // the running instance and opens its source on the Editor tab, like any
  // other class — Save to Image commits it back; Run starts it fresh.
  button(ap, "Edit", [386.0, 390.0, 60.0, 26.0], (s) => appEdit());
  // The inverse of installing: delete the picked class from the image.
  button(ap, "Remove", [450.0, 390.0, 76.0, 26.0], (s) => appUninstall());
  pinTop(<String>["Run", "Stop App", "Edit", "Remove"]);
  gAppTitleLbl = label(ap, [534.0, 394.0, 200.0, 16.0]);
  gAppTitleLbl.setAutoresizingMask(kMinYMargin);
  gAppStatusLbl = label(ap, [8.0, 366.0, 852.0, 16.0]);
  gAppStatusLbl.setAutoresizingMask(kMinYMargin + kWidthSizable);

  // The app's own canvas: widgets are subviews of THIS, so clearing an app
  // cannot touch the workspace's chrome.
  gAppPane = Cocoa.cls("NSView").alloc().initWithFrame([8.0, 8.0, kAppW, 352.0]);
  gAppPane.setAutoresizingMask(kWidthSizable + kHeightSizable);
  gAppPane.setAutoresizesSubviews(false);
  ap.addSubview(gAppPane);

  appRefreshList();
  appStatus(gAppName == null
      ? "idle — pick a class with a build(ui) method and press Run"
      : "running " + gAppName);
}

void appStatus(String s) {
  if (gAppStatusLbl != null) gAppStatusLbl.setStringValue(s);
  repaint();
}

double appPaneHeight() {
  if (gAppPane == null) return 352.0;
  var b = gAppPane.bounds();
  return (b[3] as num).toDouble();
}

double _appViewH(Cocoa v) {
  if (v == null) return 352.0;
  var b = v.bounds();
  return (b is List && b.length >= 4) ? (b[3] as num).toDouble() : 352.0;
}

/// Top-left [x,y,w,h] in a container of height `ch` -> an AppKit (bottom-left)
/// frame. Widgets on the pane flip by the pane's height; widgets inside a tab
/// flip by that page's height, so tab-relative coordinates work the same way.
List _appFrameIn(var f, double ch) {
  if (f is! List || f.length < 4) return [0.0, 0.0, 80.0, 20.0];
  var x = (f[0] as num).toDouble(), y = (f[1] as num).toDouble();
  var w = (f[2] as num).toDouble(), h = (f[3] as num).toDouble();
  return [x, ch - y - h, w, h];
}

// NSTextAlignment took the UIKit values years ago: left 0, CENTER 1, RIGHT 2.
// The legacy AppKit order (right 1, center 2) is the one everyone remembers and
// it is wrong here — it silently centred the calculator's display.
int _appAlign(var a) {
  var s = (a == null) ? 'left' : a.toString();
  if (s == 'center') return 1;
  if (s == 'right') return 2;
  return 0;
}

void appRefreshList() {
  if (gAppPicker == null) return;
  ask('apps', '').then((r) {
    if (gAppPicker == null) return;
    var names = _dl(r);
    gAppPicker.removeAllItems();
    for (var n in names) gAppPicker.addItemWithTitle(n.toString());
    if (gAppName != null) gAppPicker.selectItemWithTitle(gAppName);
    repaint();
  });
}

/// Apply one batch of commands. The batch is retained so the surface can be
/// rebuilt from it — a UI layout rebuild tears the view tree down under a
/// running app, and it has to come back exactly as it was.
void onAppPush(List msg) {
  try { appApply(msg[3], true); }
  catch (e) { log("⚠ app command dropped — " + _firstLine(e.toString())); }
}

void appApply(List cmds, bool retain) {
  if (gAppPane == null) return;
  for (var c in cmds) {
    if (c is! List || c.isEmpty) continue;
    var op = c[0];
    if (op == 'clear') {
      appClearViews();
      if (retain) gAppSpec = <dynamic>[];
      continue;
    }
    if (retain) gAppSpec.add(c);
    if (op == 'add') appAdd(c[1].toString(), c[2].toString(), c[3]);
    else if (op == 'set') appSet(c[1].toString(), c[2]);
    else if (op == 'draw') appDraw(c[1].toString(), c[2]);
    else if (op == 'remove') appRemove(c[1].toString());
    else if (op == 'title') {
      if (gAppTitleLbl != null) gAppTitleLbl.setStringValue(c[1].toString());
    } else if (op == 'focus') {
      var v = gAppViews[c[1].toString()];
      if (v != null) gWindow.makeFirstResponder(v);
    } else if (op == 'container') {
      // Route subsequent adds into a tab page (or back to the pane on null).
      if (c.length < 2 || c[1] == null) {
        gAppContainer = null;
      } else {
        var cid = c[1].toString();
        var pages = gAppTabPages[cid];
        if (pages != null) {
          var idx = (c.length > 2 && c[2] is int) ? c[2] : 0;
          if (idx >= 0 && idx < pages.length) {
            gAppContainer = pages[idx];
            // A page not currently shown has 0 bounds; the tab view's
            // contentRect is the stable page size to flip coordinates by.
            var tv = gAppViews[cid];
            var cr = (tv != null) ? tv.contentRect() : null;
            gAppContainerH = (cr is List && cr.length >= 4)
                ? (cr[3] as num).toDouble() : _appViewH(gAppContainer);
          } else {
            gAppContainer = null;
          }
        } else if (gAppScrollDoc[cid] != null) {
          gAppContainer = gAppScrollDoc[cid];       // route into the scroll's document view
          gAppContainerH = gAppScrollH[cid];        // flip by the content height, not the viewport
        } else {
          gAppContainer = null;
        }
      }
    }
  }
  repaint();
}

void appClearViews() {
  if (gAppPane != null) {
    while (gAppPane.subviews().count() > 0) {
      gAppPane.subviews().objectAtIndex(0).removeFromSuperview();
    }
  }
  gAppViews.clear();
  gAppKinds.clear();
  gAppOrder = <String>[];
  gAppListItems.clear();
  gAppTabPages.clear();
  gAppScrollDoc.clear();
  gAppScrollH.clear();
  gAppCanvasImg.clear();
  gAppCanvasWH.clear();
  gAppContainer = null;
  gAppContainerH = 0.0;
}

void appAdd(String kind, String id, Map p) {
  appRemove(id);                       // rebuilding over an id replaces it
  var container = gAppContainer != null ? gAppContainer : gAppPane;
  var frame = _appFrameIn(p['frame'],
      gAppContainer != null ? gAppContainerH : appPaneHeight());
  var v;
  var deferAdd = false;                // a list adds its own scroll view via tableIn
  if (kind == 'button') {
    v = Cocoa.cls("NSButton").alloc().initWithFrame(frame);
    v.setTitle(p['title'] == null ? '' : p['title'].toString());
    v.setBezelStyle(1);
    if (p['enabled'] == false) v.setEnabled(false);
    gTargets.add(onAction(v, (s) => defer(() => appFire(id, 'click', ''))));
  } else if (kind == 'field') {
    v = Cocoa.cls("NSTextField").alloc().initWithFrame(frame);
    v.setStringValue(p['text'] == null ? '' : p['text'].toString());
    v.setAlignment(_appAlign(p['align']));
    if (p['readOnly'] == true) { v.setEditable(false); v.setSelectable(true); }
    gTargets.add(onTextChange(v, (s) => defer(() =>
        appFire(id, 'text', s.stringValue().UTF8String()))));
    gTargets.add(onAction(v, (s) => defer(() =>
        appFire(id, 'enter', s.stringValue().UTF8String()))));
  } else if (kind == 'checkbox') {
    v = Cocoa.cls("NSButton").alloc().initWithFrame(frame);
    v.setButtonType(3);                          // NSButtonTypeSwitch
    v.setTitle(p['title'] == null ? '' : p['title'].toString());
    v.setState(p['value'] == true ? 1 : 0);
    if (p['enabled'] == false) v.setEnabled(false);
    gTargets.add(onAction(v, (s) => defer(() =>
        appFire(id, 'toggle', v.state() == 1 ? 'true' : 'false'))));
  } else if (kind == 'slider') {
    v = Cocoa.cls("NSSlider").alloc().initWithFrame(frame);
    v.setMinValue(_appD(p['min'], 0.0));
    v.setMaxValue(_appD(p['max'], 1.0));
    v.setDoubleValue(_appD(p['value'], 0.0));
    if (p['enabled'] == false) v.setEnabled(false);
    gTargets.add(onAction(v, (s) => defer(() =>
        appFire(id, 'slide', v.doubleValue().toString()))));
  } else if (kind == 'popup') {
    v = Cocoa.cls("NSPopUpButton").alloc().initWithFrame(frame, pullsDown: false);
    var items = p['items'];
    if (items is List) for (var it in items) v.addItemWithTitle(it.toString());
    if (p['selected'] != null) v.selectItemWithTitle(p['selected'].toString());
    if (p['enabled'] == false) v.setEnabled(false);
    gTargets.add(onAction(v, (s) => defer(() =>
        appFire(id, 'select', v.titleOfSelectedItem().UTF8String()))));
  } else if (kind == 'secure') {
    v = Cocoa.cls("NSSecureTextField").alloc().initWithFrame(frame);
    v.setStringValue(p['text'] == null ? '' : p['text'].toString());
    gTargets.add(onTextChange(v, (s) => defer(() =>
        appFire(id, 'text', s.stringValue().UTF8String()))));
    gTargets.add(onAction(v, (s) => defer(() =>
        appFire(id, 'enter', s.stringValue().UTF8String()))));
  } else if (kind == 'progress') {
    v = Cocoa.cls("NSProgressIndicator").alloc().initWithFrame(frame);
    v.setStyle(0);                               // NSProgressIndicatorStyleBar
    v.setIndeterminate(false);
    v.setMinValue(_appD(p['min'], 0.0));
    v.setMaxValue(_appD(p['max'], 1.0));
    v.setDoubleValue(_appD(p['value'], 0.0));
  } else if (kind == 'box') {
    v = Cocoa.cls("NSBox").alloc().initWithFrame(frame);
    var t = p['title'] == null ? '' : p['title'].toString();
    if (t.isEmpty) v.setTitlePosition(0);        // NSNoTitle
    else v.setTitle(t);
  } else if (kind == 'list') {
    var items = <dynamic>[];
    if (p['items'] is List) for (var it in p['items']) items.add(it.toString());
    gAppListItems[id] = items;
    v = tableIn(container, frame);               // adds its own scroll view here
    deferAdd = true;
    // tableIn makes the scroll fill its parent; an app widget has a FIXED frame
    // (a resizing tab page would otherwise grow the list past its bounds, and
    // NSViews don't clip — the rows would spill over everything).
    var lsc = v.enclosingScrollView();
    if (lsc != null && !lsc.isNil) lsc.setAutoresizingMask(0);
    gTargets.add(onTable(v,
        () => gAppListItems[id] == null ? 0 : gAppListItems[id].length,
        (r) => (gAppListItems[id] != null && r >= 0 && r < gAppListItems[id].length)
            ? gAppListItems[id][r].toString() : '',
        sel((r) {
          var rows = gAppListItems[id];
          if (rows != null && r >= 0 && r < rows.length) appFire(id, 'select', rows[r].toString());
        })));
  } else if (kind == 'canvas') {
    // A drawing surface: an NSImageView backed by its own NSImage. ui.draw(id,
    // ops) replays the SAME clear/rect/oval/line/text/blit vocabulary the demos
    // use (renderInto) into that image — charts, diagrams, custom widgets.
    var cw = frame[2], ch = frame[3];
    var img = Cocoa.cls("NSImage").alloc().initWithSize([cw, ch]);
    v = Cocoa.cls("NSImageView").alloc().initWithFrame(frame);
    v.setImageScaling(3);                        // ProportionallyUpOrDown
    v.setImage(img);
    gAppCanvasImg[id] = img;
    gAppCanvasWH[id] = <dynamic>[cw, ch];
    if (p['bg'] is List && p['bg'].length >= 3) {   // optional initial fill
      renderInto(img, cw, ch, <dynamic>[<dynamic>['clear', p['bg'][0], p['bg'][1], p['bg'][2]]]);
    }
    // Clicks: a gesture recogniser fires the same proxy action a button does
    // (Cocoa_wireAction is generic). The point comes back bottom-left in view
    // coords; flip to top-left canvas coords to match the draw ops.
    var gr = Cocoa.cls("NSClickGestureRecognizer").alloc().init();
    v.addGestureRecognizer(gr);
    var cvView = v, cvH = ch;
    gTargets.add(onAction(gr, (s) {
      // Read the point NOW — the action fires synchronously with the gesture, so
      // its location is valid here; a deferred read gets a stale/default point.
      // Defer only the delivery (the [defer] rule is about re-entering, which
      // appFire does; a plain locationInView query does not).
      var pt = gr.locationInView(cvView);
      var x = 0.0, y = 0.0;
      if (pt is List && pt.length >= 2) {
        x = (pt[0] as num).toDouble();
        y = (pt[1] as num).toDouble();
      }
      var fy = cvH - y;
      defer(() => appFire(id, 'click', x.toStringAsFixed(1) + ',' + fy.toStringAsFixed(1)));
    }));
  } else if (kind == 'scroll') {
    // A viewport whose document view can be LARGER than the frame, so an app
    // taller/wider than the pane scrolls. Widgets route into the document view.
    var cw = _appD(p['cw'], frame[2]);
    var ch = _appD(p['ch'], frame[3]);
    if (cw < frame[2]) cw = frame[2];
    if (ch < frame[3]) ch = frame[3];
    v = Cocoa.cls("NSScrollView").alloc().initWithFrame(frame);
    v.setHasVerticalScroller(ch > frame[3]);
    v.setHasHorizontalScroller(cw > frame[2]);
    v.setBorderType(2);                          // NSBezelBorder
    v.setDrawsBackground(false);
    var doc = Cocoa.cls("NSView").alloc().initWithFrame([0.0, 0.0, cw, ch]);
    v.setDocumentView(doc);
    gAppScrollDoc[id] = doc;
    gAppScrollH[id] = ch;
    // NSScrollView shows the document ORIGIN (bottom-left) first; a top-anchored
    // form should start at its first field, so scroll the clip to the top.
    var clip = v.contentView();
    if (clip != null && !clip.isNil) {
      clip.scrollToPoint([0.0, ch - frame[3]]);
      v.reflectScrolledClipView(clip);
    }
  } else if (kind == 'tabs') {
    v = Cocoa.cls("NSTabView").alloc().initWithFrame(frame);
    var pages = <Cocoa>[];
    if (p['items'] is List) {
      var idx = 0;
      for (var it in p['items']) {
        var item = Cocoa.cls("NSTabViewItem").alloc().initWithIdentifier(id + '/' + idx.toString());
        item.setLabel(it.toString());
        v.addTabViewItem(item);
        pages.add(item.view());                  // each tab's content view
        idx++;
      }
    }
    gAppTabPages[id] = pages;
  } else {                             // 'label', and anything unknown
    kind = 'label';
    v = Cocoa.cls("NSTextField").alloc().initWithFrame(frame);
    v.setStringValue(p['text'] == null ? '' : p['text'].toString());
    v.setAlignment(_appAlign(p['align']));
    v.setBezeled(false); v.setEditable(false); v.setDrawsBackground(false);
  }
  if (!deferAdd) container.addSubview(v);
  gAppViews[id] = v;
  gAppKinds[id] = kind;
  gAppOrder.add(id);
}

double _appD(var x, double dflt) => (x is num) ? x.toDouble() : dflt;

/// Replay a draw list onto a canvas widget's backing image, then refresh it.
/// Draw lists ACCUMULATE (there is no implicit clear) — start with a 'clear'
/// op to wipe, exactly as the demos do.
void appDraw(String id, List cmds) {
  var img = gAppCanvasImg[id];
  if (img == null) return;
  var wh = gAppCanvasWH[id];
  renderInto(img, _appD(wh[0], 100.0), _appD(wh[1], 100.0), cmds);
  var view = gAppViews[id];
  if (view != null) { view.setImage(img); view.setNeedsDisplay(true); }
  repaint();
}

void appSet(String id, Map p) {
  var v = gAppViews[id];
  if (v == null) return;
  var kind = gAppKinds[id];
  if (kind == 'list') {                          // a table, not a text widget
    if (p['items'] is List) {
      var items = <dynamic>[];
      for (var it in p['items']) items.add(it.toString());
      gAppListItems[id] = items;
      v.reloadData();
    }
    if (p['enabled'] != null) v.setEnabled(p['enabled'] == true);
    return;
  }
  if (kind == 'tabs' || kind == 'box' || kind == 'scroll') return;  // containers have no scalar value
  if (p['text'] != null) v.setStringValue(p['text'].toString());
  if (p['title'] != null) v.setTitle(p['title'].toString());
  if (p['enabled'] != null) v.setEnabled(p['enabled'] == true);
  if (p['value'] != null && (kind == 'slider' || kind == 'progress')) {
    v.setDoubleValue((p['value'] as num).toDouble());
  }
  if (p['checked'] != null && kind == 'checkbox') v.setState(p['checked'] == true ? 1 : 0);
  if (kind == 'popup') {
    if (p['items'] is List) {
      v.removeAllItems();
      for (var it in p['items']) v.addItemWithTitle(it.toString());
    }
    if (p['selected'] != null) v.selectItemWithTitle(p['selected'].toString());
  }
}

void appRemove(String id) {
  var kind = gAppKinds[id];
  var v = gAppViews.remove(id);
  if (v != null) {
    if (kind == 'list') {                        // remove the enclosing scroll, not the table
      var sc = v.enclosingScrollView();
      (sc != null && !sc.isNil ? sc : v).removeFromSuperview();
    } else {
      v.removeFromSuperview();
    }
  }
  gAppKinds.remove(id);
  gAppOrder.remove(id);
  gAppListItems.remove(id);
  gAppTabPages.remove(id);
  gAppScrollDoc.remove(id);
  gAppScrollH.remove(id);
  gAppCanvasImg.remove(id);
  gAppCanvasWH.remove(id);
}

/// A widget's current value, as the user would read it.
String appValueOf(String id) {
  var v = gAppViews[id];
  if (v == null) return null;
  var kind = gAppKinds[id];
  if (kind == 'button') return v.title().UTF8String();
  if (kind == 'checkbox') return v.state() == 1 ? 'true' : 'false';
  if (kind == 'slider' || kind == 'progress') return v.doubleValue().toString();
  if (kind == 'popup') return v.titleOfSelectedItem().UTF8String();
  if (kind == 'list') {
    var r = v.selectedRow();
    var ri = (r is int) ? r : int.parse(r.toString(), onError: (_) => -1);
    var items = gAppListItems[id];
    return (ri >= 0 && items != null && ri < items.length) ? items[ri].toString() : '';
  }
  if (kind == 'box' || kind == 'tabs' || kind == 'scroll' || kind == 'canvas') return '';
  return v.stringValue().UTF8String();
}

/// Deliver an event to the app. Deliberately an ordinary ask(): that inherits
/// the watchdog (a runaway handler is killed, not left hanging), the debugger's
/// pause guard, and generation checking.
int gAppPending = 0;              // events in flight, so a driver can wait

void appFire(String id, String kind, String value) {
  if (gAppName == null) return;
  gAppPending++;
  ask('appevent', <dynamic>[id, kind, value]).then((r) {
    gAppPending--;
    var s = r.toString();
    if (s.startsWith('ERR')) appStatus(s);
  });
}

/// Wait until every event raised so far has been handled and its widget updates
/// applied. A click is three hops — deferred callback, request to the language
/// isolate, pushed update back — so a verb that returned on the first hop would
/// make a script read the state BEFORE the click it just made. Every driven
/// click funnels through here, which is why the suite needs no sleeps.
Future appSettle() async {
  // The click's own handler is a queued message that has not run yet; one turn
  // of the event loop lets it through and registers the event.
  await new Future.delayed(const Duration(milliseconds: 1));
  var spins = 0;
  while (gAppPending > 0 && spins < 300) {
    await new Future.delayed(const Duration(milliseconds: 10));
    spins++;
  }
}

// An app lays itself out in TOP-LEFT coordinates against the surface size it
// was given, so its widgets keep the AppKit frames they were built with and
// slide away from the top edge when the pane grows. Autoresizing masks cannot
// fix that — only the app knows what its layout means — so the surface watches
// its own bounds and re-runs build() once the drag settles.
double gAppLastW = 0.0, gAppLastH = 0.0;
int gAppResizedAt = 0;

void appWatchResize() {
  if (gAppName == null || gAppPane == null) return;
  var b = gAppPane.bounds();
  var w = (b[2] as num).toDouble(), h = (b[3] as num).toDouble();
  var now = new DateTime.now().millisecondsSinceEpoch;
  if (w != gAppLastW || h != gAppLastH) {
    gAppLastW = w; gAppLastH = h;
    gAppResizedAt = now;      // still moving; wait for it to stop
    return;
  }
  if (gAppResizedAt != 0 && now - gAppResizedAt > 300) {
    gAppResizedAt = 0;
    appRebuild();
  }
}

Future appRun(String name) async {
  if (!gStandalone) switchTab(7);
  appStatus("starting " + name + "…");
  var b = gAppPane.bounds();               // the surface's real size (full window standalone)
  var w = (b is List && b.length >= 3) ? (b[2] as num).toDouble() : kAppW;
  var r = await ask('apprun', <dynamic>[name, w, appPaneHeight()]);
  var s = r.toString();
  if (s.startsWith('ERR')) {
    gAppName = null;
    appStatus(s);
    log("✗ app — " + s);
    return;
  }
  gAppName = name;
  var b0 = gAppPane.bounds();
  gAppLastW = (b0[2] as num).toDouble();
  gAppLastH = (b0[3] as num).toDouble();
  gAppResizedAt = 0;
  appStatus("running " + name);
  log("app: " + name);
}

/// Open the app's own source in the Editor, stopping it first if it is the
/// one running — otherwise whatever is selected in the picker, so it also
/// works as "show me what I am about to run" for an app that isn't up yet.
/// The inverse of installing an app: delete the picker's class from the image
/// (the language isolate's 'remove' drops it from the decls AND the SQLite DB,
/// then hot-reloads — so it is gone live, not just on disk). A running app is
/// stopped first so the pane is not left showing a class that no longer
/// exists. Recoverable: shipped examples reinstall from the Apps menu, and an
/// open Editor buffer can Save to Image to bring a user class back.
Future appUninstall() async {
  if (gAppPicker == null || gAppPicker.numberOfItems() == 0) {
    appStatus("nothing to remove — the image has no app classes");
    return;
  }
  var name = gAppPicker.titleOfSelectedItem().UTF8String();
  if (name == gAppName) await appStop();
  var r = (await ask('remove', name)).toString();
  if (r.startsWith('removed')) {
    appStatus("removed " + name + " from the image (Apps menu reinstalls the examples)");
    log("✓ app removed — " + name);
  } else {
    appStatus("remove failed — " + r);
    log("✗ app remove — " + r);
  }
  appRefreshList();
  editorRefreshClasses();
}

Future appEdit() async {
  var name = gAppName;
  if (name == null && gAppPicker != null && gAppPicker.numberOfItems() > 0) {
    name = gAppPicker.titleOfSelectedItem().UTF8String();
  }
  if (name == null) {
    appStatus("nothing to edit — pick an app first");
    return;
  }
  var src = (await ask('classsrc', name)).toString();
  if (src.isEmpty || src.startsWith('ERR')) {
    appStatus("could not read " + name + " from the image");
    return;
  }
  // Edit ends the running instance rather than hot-reloading it in place —
  // simpler to reason about (no live state to keep consistent with a source
  // that's mid-edit), and it frees the App pane immediately instead of
  // leaving a stale build behind it. Only stop if THIS is the running app
  // (name may instead be the picker's selection when nothing is running).
  if (gAppName == name) await appStop();
  // Set the class BEFORE switching: the Editor repopulates its picker on the
  // way in and restores the selection from gEdClass.
  gEdClass = name;
  gEdFile = null;
  switchTab(4);
  edSetText(src);
  edStatus(name + "  ·  stopped for editing  ·  Save to Image compiles + "
           "saves; press Run on the App pane to try it again");
  log("editing " + name + " (stopped)");
}

Future appStop() async {
  if (gAppName == null) { appStatus("no app running"); return; }
  var was = gAppName;
  gAppName = null;
  await ask('appstop', '');
  appClearViews();
  gAppSpec = <dynamic>[];
  if (gAppTitleLbl != null) gAppTitleLbl.setStringValue("");
  appStatus("stopped " + was);
}

/// After an Accept that changed the running app's class: the instance was
/// MORPHED by the reload, so re-running build() changes the layout while the
/// app's state survives. This is the whole reason the App pane exists.
Future appRebuild() async {
  if (gAppName == null) return;
  var r = await ask('appbuild', <dynamic>[gAppName, kAppW, appPaneHeight()]);
  var s = r.toString();
  if (s.startsWith('ERR')) appStatus(s);
}

/// The language isolate was restarted: its app instance died with it.
void appOnRespawn() {
  if (gAppName == null) return;
  var was = gAppName;
  gAppName = null;
  appClearViews();
  gAppSpec = <dynamic>[];
  appStatus(was + " stopped — the language isolate restarted; press Run again");
}

/// Put the surface back after a UI layout rebuild tore the view tree down.
void appRematerialise() {
  if (gAppName == null || gAppSpec.isEmpty) return;
  var spec = gAppSpec;
  gAppSpec = <dynamic>[];
  appApply(spec, true);
}

// The Apps menu is the apps/ folder, exactly like the Demos menu: a file with
// an "// App:" header is an app you can install into the image and run.
String appsDir() => Platform.script.resolve('apps/').toFilePath();

List<List<String>> scanApps() {
  var out = <List<String>>[];
  try {
    var files = <String>[];
    for (var f in new Directory(appsDir()).listSync()) {
      // .dart apps and .mst (Smalltalk) apps live side by side; both carry an
      // App: header so a support library is never mistaken for an app.
      if (f.path.endsWith('.dart') || f.path.endsWith('.mst')) files.add(f.path);
    }
    files.sort();
    for (var path in files) {
      var title;
      try {
        for (var line in new File(path).readAsLinesSync().take(5)) {
          if (line.startsWith('// App:')) { title = line.substring(7).trim(); break; }
          if (line.startsWith('"App:')) {   // the ST comment twin
            var t = line.substring(5).trim();
            var q = t.indexOf('"');
            title = (q >= 0 ? t.substring(0, q) : t).trim();
            break;
          }
        }
      } catch (e) {}
      if (title == null) continue;    // a library the apps import, not an app
      out.add(<String>[title, path]);
    }
  } catch (e) {}
  return out;
}

/// File an example app into the image (through the same compile gate as every
/// other route in), then run it.
Future installApp(String title, String path) async {
  gBusy++;                      // so `settle` covers the whole install + run
  try {
    await _installApp(title, path);
  } finally {
    gBusy--;
  }
}

Future _installApp(String title, String path) async {
  var src;
  try { src = new File(path).readAsStringSync(); }
  catch (e) { log("✗ app — cannot read " + path); return; }
  var decls = editorDecls(src);
  if (decls.isEmpty) { log("✗ app — " + path + " has no declarations"); return; }
  var name;
  var stClassRe = new RegExp(r'subclass:\s*(\w+)\s*\[');   // the ST class form
  for (var d in decls) {
    var s = d.toString();
    var n = _classNameOf(s);
    if (n == null) {
      var m = stClassRe.firstMatch(s);
      if (m != null) n = m.group(1);
    }
    if (n != null && name == null) name = n;
  }
  if (name == null) { log("✗ app — no class in " + path); return; }
  var r = await checkDecls(decls);
  if (!r.ok) { log("✗ app refused — " + r.message); return; }
  var reply = await ask('acceptMany', decls);
  log("✓ installed " + title + " — " + reply.toString());
  appRefreshList();
  await appRun(name);
}

// --- the vm-service front door (one control plane) ---------------------------
// The Observatory's vm-service is already linked into dartui, and this VM has
// service extensions — a custom JSON-RPC method served over the SAME WebSocket
// the Observatory uses. So the GUI channel does not need its own socket, its own
// wire format, or a bridge: it becomes `ext.dartui.send`, and one client speaks
// JSON-RPC 2.0 for introspection (getVM, _getCpuProfile, …) AND for driving the
// UI, over one connection.
//
// Deliberately ONE generic method rather than one per command: the verb set here
// is large and still growing, and every verb already funnels through handle().
// Registering each would mean remembering to register the next one.
//
// Thread-correct for free: an extension is invoked by delivering a message to
// the registering isolate, so the handler runs on the same main-thread
// CFRunLoop pump that already services the socket channels — no new path
// touches AppKit from the wrong thread.
void registerServiceExtensions() {
  registerExtension('ext.dartui.send',
      (String method, Map<String, String> params) async {
    var line = params['line'];
    if (line == null) {
      return new ServiceExtensionResponse.error(
          ServiceExtensionResponse.kInvalidParams,
          "ext.dartui.send needs a 'line' parameter");
    }
    try {
      // nowait: fire the command and answer immediately. A do-it that stops at
      // a breakpoint cannot reply until Continue, and a client awaiting it on
      // the one connection would deadlock — the exact hang the old suite had.
      if (params['nowait'] == 'true') {
        handle(line).catchError((e) => log("bg command failed — " + e.toString()));
        return new ServiceExtensionResponse.result(
            JSON.encode(<String, String>{'reply': 'started'}));
      }
      var reply = await handle(line);
      return new ServiceExtensionResponse.result(
          JSON.encode(<String, String>{'reply': reply.toString()}));
    } catch (e) {
      // A bug in one verb costs that call an ERR, never the app its window.
      return new ServiceExtensionResponse.result(
          JSON.encode(<String, String>{'reply': 'ERR: ' + e.toString()}));
    }
  });
}

/// Push a GUI event onto the Extension stream of that same socket, so a client
/// watching the Observatory sees UI activity without polling.
void guiEvent(String what, Map<String, String> data) {
  try {
    var m = <String, String>{'event': what};
    data.forEach((k, v) { m[k] = v; });
    postEvent('dartui', m);
  } catch (e) {}   // no vm-service running: the GUI must not care
}

// --- rebuilding the view tree -----------------------------------------------
// A source reload swaps CODE; it does not move a view that buildChrome() already
// positioned. Re-running buildChrome() over a torn-down content view does, so a
// layout change goes live like everything else.
//
// MACVM documents the trap here (world/64_cocoaui.mst installMenu): the menu bar
// is a NATIVE object that SURVIVES the rebuild, so re-running the menu code
// against it appends a second full set of submenus — duplicates, the stale half
// greyed out because their targets are dead. We are immune by construction:
// buildMenu() builds a FRESH NSMenu and setMainMenu: REPLACES the bar rather
// than adding to it. Verified after a rebuild, because "immune by construction"
// is exactly the kind of claim that quietly stops being true.
List<int> _rebuildTimes = <int>[];   // ms timestamps, for the storm backstop
const int _kStormN = 5;              // this many rebuilds...
const int _kStormMs = 8000;          // ...within this long is a storm

// N rebuilds in T seconds means something faults the instant the UI is back.
// Looping forever would just hide it (MACVM's Layer-3 backstop, same reasoning).
bool _rebuildAllowed() {
  var now = new DateTime.now().millisecondsSinceEpoch;
  var recent = <int>[];
  for (var t in _rebuildTimes) if (now - t < _kStormMs) recent.add(t);
  recent.add(now);
  _rebuildTimes = recent;
  if (recent.length > _kStormN) {
    log("✗ rebuild storm — " + recent.length.toString() + " rebuilds in " +
        (_kStormMs ~/ 1000).toString() + "s. Stopping rather than looping.");
    log("  recover with:  ./start-gui.sh --restore");
    return false;
  }
  return true;
}

/// Tear the window's contents down and build them again from the current code.
/// The NSWindow itself is kept, so position and size survive; so does the
/// transcript, the tab you were on, and an unsaved Editor buffer.
void rebuildUi() {
  if (gWindow == null || !_rebuildAllowed()) return;
  var tab = gTab;
  var edBuf = gEdText != null ? edText() : null;
  var edStat = (gEdStatus != null) ? gEdStatus.stringValue().UTF8String() : null;

  // Drop every Dart-side handle into the old tree BEFORE it goes away, so
  // nothing later reaches through a stale wrapper.
  gButtons.clear();
  gTargets.clear();
  gMetricVals.clear();
  gMemBarFill = null;
  gEdText = null; gEdPicker = null;
  gEdStatus = null; gFindField = null; gFindTable = null; gEditor = null;
  gTranscript = null; gTabView = null;
  // The dock's collapsed state is NOT cleared: it is the user's choice and
  // buildChrome rebuilds into it (see [layoutChrome]).
  gToolbar = null;
  gDockBar = null; gDockToggle = null; gDockLastLbl = null; gDockMenuItem = null;
  // The demo VIEW dies with the tree; the demo IMAGE and its isolate live on —
  // buildDemosTab reattaches them, so a running demo just keeps drawing.
  gDemoView = null; gDemoStatusLbl = null;
  // Same for the app: its instance is in the language isolate and untouched by
  // this. The widgets die here and are replayed from the retained spec below.
  gAppPane = null; gAppPicker = null; gAppStatusLbl = null; gAppTitleLbl = null;
  gHelpField = null; gHelpTable = null; gHelpText = null; gHelpStatusLbl = null;
  gAppViews.clear(); gAppKinds.clear(); gAppOrder = <String>[];
  // The ObjC action targets outlive this: AppKit holds them unretained and we
  // never owned a reference. Their tickets are gone, so a stale one now fails
  // closed (dart:cocoa's dispatch returns on an unknown ticket) rather than
  // firing into a dead handler. A few small objects per rebuild is the price.
  disposeCallbacks();

  var subs = gContent.subviews();
  while (gContent.subviews().count() > 0) {
    gContent.subviews().objectAtIndex(0).removeFromSuperview();
  }

  buildChrome();

  gTranscript.setString(gLog.join("\n"));
  gTranscript.scrollToEndOfDocument(null);
  if (edBuf != null && edBuf.length > 0) edSetText(edBuf);
  if (edStat != null && edStat.length > 0) edStatus(edStat);
  appRematerialise();   // a running app's widgets, rebuilt from its spec
  switchTab(tab);
  log("UI layout rebuilt");
  repaint();
}

// --- reloading the UI itself ------------------------------------------------
// The UI isolate cannot reload itself from its own stack — it would be replacing
// the code it is standing in, with AppKit holding its closures. The HOST can,
// though: wsRequestUiReload() raises a flag and returns, and cocoa_host.mm does
// the reload at the top of its pump with no Dart frames live. ReloadSources is
// atomic, so a source that does not compile is cancelled and the running UI is
// untouched.
//
// What a reload DOES change is behaviour: method bodies, new methods, morphed
// classes. It does NOT rebuild the window — views already constructed by
// buildWindow() keep the frames they were given, so a layout change still needs
// a restart. Say so rather than let it look broken.
String gLastGood;                  // a copy of the UI source that booted us

/// After the app has run for a moment, keep a copy of the UI source that got it
/// here. This file is the only thing that can rescue a bad edit, so it is
/// written only once per launch, and only by a build that actually booted.
void snapshotLastGood() {
  new Timer(const Duration(seconds: 6), () {
    try {
      var src = new File(Platform.script.toFilePath()).readAsStringSync();
      var dir = new Directory(_macdartDir());
      if (!dir.existsSync()) dir.createSync(recursive: true);
      gLastGood = _macdartDir() + "/workspace.last-good.dart";
      new File(gLastGood).writeAsStringSync(src);
    } catch (e) {
      log("could not save a recovery copy of the UI — " + e.toString());
    }
  });
}

String _macdartDir() => Platform.environment['HOME'] + "/.macdart";

/// Hot-reload the UI from workspace.dart on disk. Syntax-checked first: a
/// cancelled reload is harmless but uninformative, and this way the error points
/// at a line.
Future reloadUi() async {
  var path = Platform.script.toFilePath();
  String src;
  try { src = new File(path).readAsStringSync(); }
  catch (e) { log("UI reload: cannot read " + path + " — " + e.toString()); return; }

  var r = await compileCheck(src, standalone: true);
  if (!r.ok) {
    log("✗ UI reload refused — " + r.message);
    return;
  }
  log("reloading the UI from " + path + " …");
  wsRequestUiReload();          // the host takes it from here
}

/// Put the last-good UI source back, then reload it. The way out of an edit that
/// compiled but left the UI misbehaving.
Future revertUi() async {
  if (gLastGood == null || !new File(gLastGood).existsSync()) {
    log("no recovery copy yet (one is saved a few seconds after a clean start)");
    return;
  }
  var path = Platform.script.toFilePath();
  try {
    new File(path).writeAsStringSync(new File(gLastGood).readAsStringSync());
  } catch (e) {
    log("revert failed — " + e.toString());
    return;
  }
  log("restored " + gLastGood + " over " + path);
  await reloadUi();
}

// Polled from the metrics tick: the host leaves its result here rather than
// calling back into Dart from outside the message loop.
void pollUiReload() {
  var s = wsUiReloadStatus();
  if (s.isEmpty) return;
  if (s == "ok") {
    log("✓ UI reloaded");
    guiEvent('uiReloaded', <String, String>{});
    rebuildUi();      // re-run buildChrome so layout changes take effect too
  } else {
    log("✗ UI reload cancelled (the running UI is untouched) — " + s);
  }
}

// --- editing the workspace's own source -------------------------------------
// The UI is written in Dart, so it may as well be editable from inside itself.
// These open the project's own files in the Editor. What a save DOES differs per
// file, and the status line says so rather than leaving you to find out:
//   workspace.dart  the UI you are looking at — a runtime script, so a restart
//                   picks it up (it cannot hot-reload itself: this isolate IS
//                   the window, and a bad reload leaves nothing to fix it with)
//   language.dart   the TEMPLATE the language isolate is spawned from; the live
//                   isolate runs a copy, so a restart picks it up
//   cocoa.dart      the dart:cocoa bridge, baked into the VM snapshot — needs a
//                   rebuild (./start-gui.sh --rebuild)
const Map<String, List<String>> _kProjectFiles = const <String, List<String>>{
  'workspace': const <String>['workspace.dart',
      'the UI itself — restart to pick it up'],
  'language': const <String>['language.dart',
      'the language-isolate template — restart to pick it up'],
  'cocoa': const <String>['../cocoa.dart',
      'the dart:cocoa bridge — needs ./start-gui.sh --rebuild'],
};

String projectFilePath(String which) {
  var e = _kProjectFiles[which];
  if (e == null) return null;
  return Platform.script.resolve(e[0]).toFilePath();
}

/// Open one of the workspace's own source files in the Editor.
void editProjectFile(String which) {
  var e = _kProjectFiles[which];
  if (e == null) {
    log("edit: unknown file '" + which + "' (workspace | language | cocoa)");
    return;
  }
  var path = projectFilePath(which);
  var f = new File(path);
  if (!f.existsSync()) { log("edit: no such file — " + path); return; }
  String src;
  try { src = f.readAsStringSync(); }
  catch (err) { log("edit: cannot read " + path + " — " + err.toString()); return; }
  switchTab(4);
  gEdFile = path;      // Save File… writes back here; Analyze compiles standalone
  gEdClass = null;
  edSetText(src);
  edStatus(e[0] + "  ·  " + e[1]);
  log("editing " + path);
}

// --- compile check ----------------------------------------------------------
// One real compile, shared by every path that commits code. Nothing is accepted
// on the strength of a brace count: the buffer is written to a temp file and put
// through `dart --compile_all`, which compiles method BODIES too (spawnUri does
// not — Dart 1 compiles them lazily, so a broken body would sail through).
//
// A declaration is never checked alone. Compiled by itself, `class A { B b; }`
// fails with "cannot resolve class 'B'" the moment B is another class in your
// image, so the probe is assembled as: the language isolate's imports, every
// OTHER declaration in the image, then the code under test. Reported lines are
// mapped back to the buffer the user is looking at.
const String _kProbeImports =
    "import 'dart:cocoa';\nimport 'dart:async';\nimport 'dart:isolate';\n"
    "import 'dart:io';\nimport 'dart:mirrors';\n";

class CheckResult {
  final bool ok;
  final String message;   // "" when ok
  final int line;         // 1-based line in the SOURCE UNDER TEST, 0 if unknown
  CheckResult(this.ok, this.message, this.line);
}

int _countLines(String s) {
  var n = 0;
  for (var i = 0; i < s.length; i++) if (s.codeUnitAt(i) == 0x0A) n++;
  return n;
}

/// Compile [src]. When [standalone] the text is compiled as its own program
/// (it carries its own imports — a project file); otherwise it is compiled
/// against the image, with declarations named in [replacing] left out so a
/// redefinition does not collide with the version already there.
Future<CheckResult> compileCheck(String src,
    {bool standalone: false, List<String> replacing: null}) async {
  var bin = _analyzeBinary();
  if (bin == null) {         // no checker: don't block work, but never silently
    _warnNoChecker();
    return new CheckResult(true, "", 0);
  }

  var probe, offset = 0;
  if (standalone) {
    // ALWAYS supply the entry point: _neutraliseMain has just renamed any main
    // the file had, so without this the VM reports "no main" on a perfectly good
    // file — and running the user's main is exactly what we are avoiding.
    probe = _neutraliseMain(src) + "\n\nmain() {}\n";
  } else {
    var ctx = new StringBuffer();
    ctx.write(_kProbeImports);
    var others = _dl(await askQuiet('alldecls', '', const Duration(seconds: 3)));
    var skip = replacing != null ? replacing : <String>[];
    for (var d in others) {
      if (skip.contains(d[0].toString())) continue;
      var s = d[1].toString();
      if (_wsIsSt(s)) continue;  // Smalltalk decl: not Dart context
      ctx.write("\n");
      ctx.write(s);
      ctx.write("\n");
    }
    ctx.write("\n");
    var head = ctx.toString();
    offset = _countLines(head);
    probe = head + _neutraliseMain(src) + "\n\nmain() {}\n";
  }

  var path = Directory.systemTemp.path + "/macdart_check.dart";
  var out;
  try {
    new File(path).writeAsStringSync(probe);
    out = await Process.run(bin, <String>["--compile_all", path])
        .timeout(const Duration(seconds: 20), onTimeout: () => null);
  } catch (e) {
    return new CheckResult(true, "", 0);   // could not run it: don't block work
  } finally {
    try { new File(path).deleteSync(); } catch (e) {}
  }
  if (out == null) return new CheckResult(true, "", 0);
  if (out.exitCode == 0) return new CheckResult(true, "", 0);

  var msg = out.stderr.toString().trim();
  if (msg.isEmpty) msg = out.stdout.toString().trim();
  // Native linking happens AFTER parsing, so reaching it means the source is
  // syntactically sound — it just declares natives that only exist inside
  // dartui (dart:cocoa does). Report the limit, not a phantom error.
  if (msg.contains('native function') && msg.contains('cannot be found')) {
    return new CheckResult(true,
        "parses cleanly (its native functions only resolve inside dartui)", 0);
  }
  var line = _errorLine(msg) - offset;      // back into the user's own buffer
  if (line < 1) line = 0;
  return new CheckResult(false, _cleanError(_firstLine(msg), offset), line);
}

// The VM reports against the temp probe: an absolute path and a line number that
// counts the image context we prepended. Neither means anything to someone
// looking at their own buffer, so report the line THEY can see.
String _cleanError(String msg, int offset) {
  var m = msg;
  var q = m.indexOf("': ");
  if (m.startsWith("'file://") && q > 0) m = m.substring(q + 3);
  if (offset > 0) {
    var lm = new RegExp(r'line (\d+)').firstMatch(m);
    if (lm != null) {
      var n = int.parse(lm.group(1)) - offset;
      if (n > 0) m = m.replaceFirst('line ' + lm.group(1), 'line ' + n.toString());
    }
  }
  return m;
}

/// Check [decls] and, if they compile, run [commit]. Otherwise say why and
/// leave the buffer untouched — a cancelled hot reload is a far worse outcome
/// than a refused Accept.
/// Compile [decls] against the image without committing anything. The single
/// gate every route into the image goes through — buttons and scripts alike.
// A Smalltalk declaration — the DART compile check must not see it; the
// language isolate parse-checks it with stCheck instead. Covers class defs
// (`Super subclass: Name [`), Sprint-12 extension chunks (`Foo extend [`,
// `Foo class >> sel [`), and st-doit boot chunks (`"st-doit name"` header).
final RegExp _wsStClassRe = new RegExp(
    r'^\s*(?:"(?:[^"]|"")*"\s*)*\w+\s+subclass:\s*\w+\s*\[');
final RegExp _wsStExtendRe = new RegExp(
    r'^\s*(?:"(?:[^"]|"")*"\s*)*\w+(?:\s+class)?\s+(?:extend\s*\[|>>)');
final RegExp _wsStDoitRe = new RegExp(r'^\s*"st-doit\s+[^"]+"');
bool _wsIsSt(String s) =>
    _wsStClassRe.hasMatch(s) ||
    _wsStExtendRe.hasMatch(s) ||
    _wsStDoitRe.hasMatch(s);

Future<CheckResult> checkDecls(List decls) async {
  var dartDecls = <dynamic>[];
  for (var d in decls) {
    if (!_wsIsSt(d.toString())) dartDecls.add(d);
  }
  if (dartDecls.isEmpty) return new CheckResult(true, "", 0);  // all Smalltalk
  var names = <String>[];
  for (var d in dartDecls) {
    var n = _classNameOf(d.toString());
    if (n != null) names.add(n);
  }
  return await compileCheck(dartDecls.join("\n\n"), replacing: names);
}

// --- Accept-time Cocoa lint (COCOA_STATIC_CHECK_PLAN.md §2) ------------------
// Best-effort static check of dynamic Cocoa sends against the one database we
// own — the loaded runtime (the cocoa* query natives). It recognises the two
// shapes that carry a known class: `Cocoa.cls("X").sel(...)` and a local
// `var c = Cocoa.cls("X")` then `c.sel(...)`. It rebuilds the ObjC selector the
// way noSuchMethod does, then flags an unknown class, an unknown selector (with
// a "did you mean"), or a call that trips the 8-FP-register marshaling limit.
// Anything it cannot resolve it leaves alone; the louder runtime exceptions are
// the net for the rest. Findings are WARNINGS — they never block Accept.

class _CTok {                          // 0 ident, 1 string-content, 2 punct
  final int kind; final String text; final int pos;
  _CTok(this.kind, this.text, this.pos);
}

List<_CTok> _cocoaTokens(String s) {
  var out = <_CTok>[]; var n = s.length, i = 0;
  while (i < n) {
    var c = s.codeUnitAt(i);
    if (c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D) { i++; continue; }
    if (c == 0x2F && i + 1 < n) {                       // comments
      var d = s.codeUnitAt(i + 1);
      if (d == 0x2F) { while (i < n && s.codeUnitAt(i) != 0x0A) i++; continue; }
      if (d == 0x2A) { i += 2;
        while (i + 1 < n && !(s.codeUnitAt(i) == 0x2A && s.codeUnitAt(i + 1) == 0x2F)) i++;
        i = (i + 1 < n) ? i + 2 : n; continue; }
    }
    if (c == 0x27 || c == 0x22) {                       // string -> its content
      var q = c, st = i; i++; var buf = new StringBuffer();
      var triple = st + 2 < n && s.codeUnitAt(st + 1) == q && s.codeUnitAt(st + 2) == q;
      if (triple) { i = st + 3;
        while (i + 2 < n && !(s.codeUnitAt(i) == q && s.codeUnitAt(i + 1) == q && s.codeUnitAt(i + 2) == q)) { buf.writeCharCode(s.codeUnitAt(i)); i++; }
        i = (i + 2 < n) ? i + 3 : n;
      } else {
        while (i < n && s.codeUnitAt(i) != q && s.codeUnitAt(i) != 0x0A) {
          if (s.codeUnitAt(i) == 0x5C && i + 1 < n) i++;
          buf.writeCharCode(s.codeUnitAt(i)); i++;
        }
        if (i < n && s.codeUnitAt(i) == q) i++;
      }
      out.add(new _CTok(1, buf.toString(), st)); continue;
    }
    if (_isIdentStart(c)) { var st = i; i++;
      while (i < n && _isIdentPart(s.codeUnitAt(i))) i++;
      out.add(new _CTok(0, s.substring(st, i), st)); continue;
    }
    out.add(new _CTok(2, new String.fromCharCode(c), i)); i++;   // one punct char
  }
  return out;
}

bool _tokIdent(List<_CTok> t, int i, String name) =>
    i >= 0 && i < t.length && t[i].kind == 0 && t[i].text == name;
bool _tokPunct(List<_CTok> t, int i, String ch) =>
    i >= 0 && i < t.length && t[i].kind == 2 && t[i].text == ch;

int _lineAt(String src, int pos) {
  var line = 1;
  for (var i = 0; i < pos && i < src.length; i++) if (src.codeUnitAt(i) == 0x0A) line++;
  return line;
}

// Cocoa's OWN Dart members — not ObjC selectors, so never lint them.
const List<String> _cocoaOwnMembers =
    const <String>['send', 'toString', 'noSuchMethod', 'hashCode', 'runtimeType', 'cls'];

// Rebuild the selector from a parenthesised call: name + ':' + one 'label:' per
// named argument (noSuchMethod's own rule); a call with no args is the bare name.
String _reconSelector(List<_CTok> toks, String method, int open) {
  // Any content between the parens means at least one arg (numbers tokenise as
  // punct, so "did we see an identifier" is NOT a reliable has-args test).
  var first = open + 1;
  if (first >= toks.length || _tokPunct(toks, first, ')')) return method;   // 0-arg
  var i = first, depth = 1; var labels = <String>[]; var argStart = true;
  while (i < toks.length && depth > 0) {
    var t = toks[i];
    if (t.kind == 2) {
      if (t.text == '(' || t.text == '[' || t.text == '{') { depth++; argStart = false; }
      else if (t.text == ')' || t.text == ']' || t.text == '}') { depth--; if (depth == 0) break; argStart = false; }
      else if (t.text == ',' && depth == 1) { argStart = true; }
      else argStart = false;
    } else {
      if (depth == 1 && argStart && t.kind == 0 && _tokPunct(toks, i + 1, ':')) labels.add(t.text);
      argStart = false;
    }
    i++;
  }
  var sel = new StringBuffer()..write(method)..write(':');
  for (var l in labels) sel..write(l)..write(':');
  return sel.toString();
}

void _lintSend(List<String> out, String src, String cls, List<_CTok> toks, int mi) {
  var method = toks[mi].text;
  if (_cocoaOwnMembers.contains(method)) return;
  if (!_tokPunct(toks, mi + 1, '(')) return;            // only parenthesised calls
  var sel = _reconSelector(toks, method, mi + 1);
  var info = cocoaSelectorInfo(cls, sel);
  var line = _lineAt(src, toks[mi].pos);
  if (info == null) {
    var msg = 'L' + line.toString() + ': ' + cls + ' has no selector "' + sel + '"';
    var near = cocoaNearestSelectors(cls, sel);
    if (near is List && near.isNotEmpty) msg += ' — did you mean ' + near.take(3).join(', ');
    out.add(msg);
  } else {
    var enc = info.length > 2 ? info[2].toString() : '';
    var colon = enc.indexOf(':');                       // the _cmd marker; args follow
    if (colon >= 0) {
      var fp = 0;
      for (var k = colon + 1; k < enc.length; k++) {
        var ch = enc.codeUnitAt(k);
        if (ch == 0x64 || ch == 0x66) fp++;             // 'd' double / 'f' float
      }
      if (fp > 8) out.add('L' + line.toString() + ': ' + cls + '.' + sel +
          ' passes ' + fp.toString() + ' float args — the bridge marshals only 8 in registers; the rest arrive as garbage');
    }
  }
}

/// Lint [src] for suspect Cocoa sends; returns human-readable findings.
List<String> cocoaLint(String src) {
  var out = <String>[];
  var toks = _cocoaTokens(src);
  // pass 1: local vars bound directly to a class — `... name = Cocoa.cls("X")`
  var varClass = <String, String>{};
  for (var i = 1; i + 5 < toks.length; i++) {
    if (_tokPunct(toks, i, '=') && _tokIdent(toks, i + 1, 'Cocoa') &&
        _tokPunct(toks, i + 2, '.') && _tokIdent(toks, i + 3, 'cls') &&
        _tokPunct(toks, i + 4, '(') && toks[i + 5].kind == 1 &&
        toks[i - 1].kind == 0) {
      varClass[toks[i - 1].text] = toks[i + 5].text;
    }
  }
  // pass 2: check the two send shapes
  for (var i = 0; i < toks.length; i++) {
    if (_tokIdent(toks, i, 'Cocoa') && _tokPunct(toks, i + 1, '.') &&
        _tokIdent(toks, i + 2, 'cls') && _tokPunct(toks, i + 3, '(') &&
        i + 5 < toks.length && toks[i + 4].kind == 1 && _tokPunct(toks, i + 5, ')')) {
      var cls = toks[i + 4].text;
      if (!cocoaClassExists(cls)) {
        out.add('L' + _lineAt(src, toks[i].pos).toString() + ': no such class "' + cls + '"');
        continue;
      }
      if (_tokPunct(toks, i + 6, '.') && i + 7 < toks.length && toks[i + 7].kind == 0) {
        _lintSend(out, src, cls, toks, i + 7);
      }
    } else if (toks[i].kind == 0 && varClass.containsKey(toks[i].text) &&
               _tokPunct(toks, i + 1, '.') && i + 2 < toks.length && toks[i + 2].kind == 0) {
      _lintSend(out, src, varClass[toks[i].text], toks, i + 2);
    }
  }
  return out;
}

Future guardedAccept(List decls, String what, void commit()) async {
  if (gDbgPaused && gDbgIsLang) {   // a paused demo isolate does not block Accept
    log("✗ " + what + " refused — the language isolate is stopped in the debugger; Continue first");
    return;
  }
  gBusy++;                    // the compile check is not a request; count it
  var r;
  try {
    r = await checkDecls(decls);
  } finally {
    gBusy--;
  }
  if (!r.ok) {
    log("✗ " + what + " refused — " + r.message);
    if (r.line > 0) _selectLine(r.line);
    return;
  }
  // Compiles — now lint the Cocoa sends. Warnings only: they inform, never
  // block (best-effort static analysis of a dynamic bridge; the runtime net
  // catches whatever this misses). See COCOA_STATIC_CHECK_PLAN.md §2.
  var warned = 0;
  for (var d in decls) {
    for (var f in cocoaLint(d.toString())) {
      if (warned++ < 12) log("⚠ cocoa — " + f);
    }
  }
  commit();
}

// --- Analyze ----------------------------------------------------------------
// A REAL compile of every method body, by the real front end.
//
// Two things this has to get right, both learned the hard way:
//  1. Isolate.spawnUri is NOT enough. Dart 1 compiles method bodies lazily, so
//     spawning `class Foo { f() { var x = ; } }` succeeds and Analyze would
//     report it clean — a false all-clear on exactly the error it exists to
//     catch. `dart --compile_all` compiles everything up front and reports it.
//  2. --compile_all still RUNS main, and so did the old spawnUri version: a
//     buffer whose main() called exit() would have taken the workspace down with
//     it, and any main() with side effects ran every time Analyze was pressed.
//     So a top-level main is renamed out of the way first and we supply an empty
//     one. Pressing Analyze must never execute the user's program.
// Look in BOTH build directories, not just this one's sibling. Running from
// build-release/ used to collapse the two candidates onto the same missing path
// (build-release/../build-release/dart), so no checker was found, compileCheck
// quietly returned "ok", and the Accept gate disabled itself in silence — which
// is exactly how source that does not compile got into the image.
String _analyzeBinary() {
  var dir = new File(Platform.resolvedExecutable).parent.path;
  for (var c in <String>[dir + "/dart",
                         dir + "/../build-release/dart",
                         dir + "/../build/dart"]) {
    if (new File(c).existsSync()) return c;
  }
  return null;
}

// A safety gate that turns itself off has to say so, every time it matters:
// silence here reads as "checked and fine".
bool _warnedNoChecker = false;
void _warnNoChecker() {
  if (_warnedNoChecker) return;
  _warnedNoChecker = true;
  log("⚠ no dart binary beside dartui — Accept is NOT compile-checked, so "
      "source that does not compile can reach the image "
      "(build one: ninja -C macdart/build dart)");
}

// Rename a TOP-LEVEL `main` so the trial cannot execute it. Literal-aware (via
// lexDart) so `main(` inside a string or comment is left alone, and depth-aware
// so a method called main() inside a class is not touched.
String _neutraliseMain(String src) {
  var spans = lexDart(src);
  var lit = new List<bool>.filled(src.length + 1, false);
  for (var i = 0; i + 2 < spans.length; i += 3) {
    var k = spans[i + 2];
    if (k != 2 && k != 3) continue;
    for (var p = spans[i]; p < spans[i] + spans[i + 1] && p < lit.length; p++) lit[p] = true;
  }
  var depth = 0, i = 0, n = src.length;
  while (i < n) {
    if (lit[i]) { i++; continue; }
    var c = src.codeUnitAt(i);
    if (c == 0x7B) { depth++; i++; continue; }
    if (c == 0x7D) { depth--; i++; continue; }
    if (depth == 0 && _isIdentStart(c)) {
      var s = i;
      while (i < n && _isIdentPart(src.codeUnitAt(i))) i++;
      if (src.substring(s, i) == "main") {
        var j = i;
        while (j < n && src.codeUnitAt(j) <= 0x20) j++;
        if (j < n && src.codeUnitAt(j) == 0x28) {          // main (
          return src.substring(0, s) + "__wsMain" + src.substring(i);
        }
      }
      continue;
    }
    i++;
  }
  return src;
}

Future editorAnalyze() async {
  var src = edText();
  if (src.trim().isEmpty) return;
  if (_analyzeBinary() == null) {
    log("Analyze unavailable: no dart binary beside " + Platform.resolvedExecutable);
    return;
  }
  // A project file carries its own imports and is compiled as a program; an
  // image class is compiled against the rest of the image.
  var r = gEdFile != null
      ? await compileCheck(src, standalone: true)
      : await compileCheck(src, replacing: _bufferNames(src));
  if (r.ok) {
    var note = r.message.isEmpty ? "compiles cleanly" : r.message;
    edStatus("Analyze: " + note);
    log("Analyze: " + note);
    return;
  }
  edStatus("Analyze FAILED: " + r.message);
  log("Analyze FAILED: " + r.message);
  if (r.line > 0) _selectLine(r.line);
}

// The declarations a buffer defines, so a check does not collide them with the
// copies already in the image.
List<String> _bufferNames(String src) {
  var out = <String>[];
  for (var d in editorDecls(src)) {
    var n = _classNameOf(d);
    if (n != null) out.add(n);
  }
  return out;
}

// The first line of a compile error is the whole story; the first line of a
// RUNTIME error is just "Unhandled exception:", so carry the line after it too.
String _firstLine(String s) {
  var lines = s.split('\n');
  if (lines.isEmpty) return s;
  var first = lines[0].trim();
  if (first.endsWith('exception:') && lines.length > 1) {
    return first + ' ' + lines[1].trim();
  }
  return first;
}

// "...: line 12 pos 7: unexpected token" -> 12
int _errorLine(String msg) {
  var m = new RegExp(r'line (\d+) pos \d+').firstMatch(msg);
  if (m == null) m = new RegExp(r'\.dart:(\d+):').firstMatch(msg);
  return m != null ? int.parse(m.group(1)) : 0;
}

// Put the caret on the offending line, so the error is where the user is looking.
void _selectLine(int line) {
  var src = edText();
  var start = 0;
  for (var i = 1; i < line; i++) {
    var nl = src.indexOf('\n', start);
    if (nl < 0) return;
    start = nl + 1;
  }
  var end = src.indexOf('\n', start);
  if (end < 0) end = src.length;
  gEdText.setSelectedRange([start, end - start]);
  gEdText.scrollRangeToVisible([start, end - start]);
  repaint();
}

const _docsText = '''MACDART Workspace - a native Dart V1 IDE

TABS (View menu, Cmd-1..7)
  Workspace  a scratch pane: Do It / Print It against the live language isolate.
  Browser    a Smalltalk-style class browser over the image and the world.
  Editor     one whole class as text, with Analyze and Format.
  Find       name search and senders over the image.
  Docs       this page, and SEARCHABLE DART V1 HELP beside it. Type in the
             search box: every documented declaration in the SDK libraries this
             VM was built from, every section of the Dart 1.24 language
             specification, and dart:cocoa. Nothing is transcribed - the index
             is parsed from those files (help/indexer.dart, in its own isolate),
             so it cannot describe a language other than the one you are
             running, and every entry cites its own file:line. Search a name
             (Future, String.substring, spawnUri) or a keyword the libraries
             cannot explain (await, async*, mixin, cascade). Guide comes back
             here.
  Debugger   breakpoints, stepping and evaluation in the language isolate.
  Demos      a canvas that demo programs draw on. Each demo in demos/ runs in
             its OWN isolate (some spawn workers of their own) and sends draw
             commands here - only this UI isolate ever touches AppKit. Shapes
             go as ['rect'|'oval'|'line'|'text', ...] lists; whole images go as
             a Pixmap (demos/pixmap.dart), which crosses as ONE blit command.
             Only files with a "// Demo:" header line are listed in the menu.
  App        your own Cocoa app, running on real controls. An app is an ordinary
             image class with a build(ui) method; it runs in the LANGUAGE
             isolate and never imports dart:cocoa - it describes widgets and
             this isolate materialises them. Edit build() and press Accept and
             the layout changes while the app KEEPS ITS STATE, because the
             reload morphs the live instance. Examples are in apps/ (Apps menu);
             see APP_PANE_PLAN.md.

THE IMAGE AND THE WORLD
  The world is the VM snapshot (dart:core and friends) - read-only. Your app is
  source held in a SQLite image at ~/.macdart/workspace.sqlite and loaded on top
  of it at boot. The image is the source of truth: a watchdog respawn re-reads it.

  Accept / Save to Image writes the image AND hot-reloads, so a change is live
  AND survives a restart. Existing instances are MORPHED in place (fields kept by
  name, new fields initialised), so a live object survives a class-structure
  change. Add to World reloads WITHOUT writing the image: live now, gone next boot.

MENUS
  File   New Class, Open..., Save File..., File In..., Save (Cmd-S commits
         whatever is in front of you: the editor to the image, the browser's
         pane, or the workspace).
  Edit   Undo/Redo/Cut/Copy/Paste/Select All - the standard Cocoa editing
         commands, routed to whichever text view has focus.
  Code   Do It (Cmd-D), Print It (Cmd-P), Format (Opt-Cmd-F), Analyze (Cmd-B),
         Restart Language Isolate.
  Demos  one item per file in demos/ - picking one spawns it as an isolate and
         switches to the Demos tab. Stop Demo is Cmd-. and kills the isolate.
         Drop a new .dart in the folder and Rescan.
  Apps   install an example from apps/ into the image and run it. In the App
         pane, Edit stops the running app and opens its own source in the
         Editor; Save to Image commits it, then Run starts it again.
         Remove is install's inverse: it deletes the picked class from the
         image (DB + live, via hot reload), stopping it first if running —
         examples reinstall from this menu, and an open Editor buffer can
         Save to Image to bring a class back.
  View   the tabs, Hide/Show Transcript (Cmd-T) and Clear Transcript (Cmd-K).

EDITOR
  Analyze compiles the buffer for real (dart --compile_all in a separate
  process), so errors inside method bodies are caught, and your own main() is
  renamed out of the way first so pressing Analyze never runs your program.
  Format re-indents only; it refuses to apply if that would change anything but
  layout, so it cannot mangle a class.

TOOLBAR
  Live VM counters for the language isolate: MEM used/capacity with a usage bar,
  JIT functions compiled/optimised, CODE generated bytes, GC scavenges/marksweeps.
  A cell shows - when the VM cannot answer it.

TRANSCRIPT
  The pane docked below every tab. COLLAPSE it with the "Transcript" button on
  its strip (or Cmd-T) and the tab in front takes the freed height; collapsed,
  the strip still shows the newest line, errors in red, so nothing goes
  unreported. Clear empties it (Cmd-K). The choice survives a UI rebuild.
  Control verb: `dock [show|hide|toggle]` -> "open" | "collapsed".

DEBUGGER — CONTROL VERBS (the formats below are a CONTRACT; agents parse them)
  dbgisolates             one per line: "<name>  <isolates/ID>[  [lang]]".
                          The UI isolate is NEVER listed (pausing it would
                          freeze this interface).
  dbgattach [id|name|N]   attach to the picker's selection, or select first by
                          full isolate id (churn-safe), name fragment, or index.
                          -> "<isolates/ID> [lang]" | "<isolates/ID> [raw]"
  dbgstate                "running" | "paused at <fn>:<line>, <K> frames".
                          The :line is omitted when unknown; an idle-loop pause
                          is honestly "paused at ?, 0 frames".
  dbgpause                request a pause wherever it is (the frame-loop-safe
                          way in; no re-break trap) -> poll dbgstate.
  dbgbreak L [if EXPR] / dbgunbreak L / dbgbreaks / dbgclear
                          arm (optionally conditional), disarm one, list, clear.
                          List format, one per line or "(none)":
                          "L<line>[  (<decl> +<off>)][  if <expr>  hits H skips S]"
                          Language-isolate breakpoints are declaration-anchored
                          and survive Accepts; other isolates use raw lines.
                          CONDITIONS are client-side (this VM has no server
                          ones): each hit evaluates EXPR in the TOP frame —
                          exactly false resumes silently (a skip); true pauses
                          (a hit); an error or non-bool PAUSES with the reason,
                          never silently dead. Each hit costs a service round
                          trip, so a condition on a hot per-frame line slows
                          that isolate while armed. In the GUI: type the
                          condition in the eval field, caret the line, Break If.
  dbgstack                "<N>  <fn>[:<line>]" one per frame; feed N to dbgframe.
  dbgframe N / dbgvars    select a frame; locals as "name=value" ONE PER LINE
                          (values may contain commas).
  dbgeval EXPR            evaluate in the selected frame; returns the VALUE
                          (or "error: ..." / "ERR: ...").
  dbgstep [Over|In(to)|Out]   empty = Continue.
  dbgquiet 0|1            1: a pause no longer switches the GUI to this tab —
                          set it when stepping programmatically so the human's
                          screen is not yanked per step. Default 0.
  tab [N]                 with no argument returns the current tab index.
  LAW: a per-frame breakpoint in a Timer loop re-breaks every Continue, and
  Dart 1 periodic timers ACCRUE missed ticks while paused (a long pause bursts
  them all on resume). Debug frame loops with dbgpause or rare-path breaks,
  and dbgclear before the final Continue.

PROFILER — CONTROL VERBS (surfaces the VM's sampling CPU profiler; read-only)
  profisolates            every isolate, one per line: "<N>  <name>  <id>
                          [  [ui]|[lang]]". ALL are listed — profiling never
                          pauses anything, so even the UI isolate is fair game.
  prof [ms] [id|name|N]   clear the target's profile, let it run `ms` (default
                          1000), then report the hottest functions by SELF
                          time. Default target is a running demo/game, else the
                          language isolate. Output: a header line
                          "<K> samples ... self% total% function" then rows
                          "<self%>  <total%>  <function>" by self-desc. Self% is
                          time IN the function; total% includes what it called.
  proftree [ms] [id|name] same sample, rendered as the inclusive CALL TREE
                          (top-down: entry → callees), indented, paths < 2%
                          pruned. Shows the PATH to hot code the flat view
                          can't — e.g. _handleMessage → the frame closure →
                          the pixel loop. GUI: the Tree button.
  profclear [id|name]     drop the target's samples.
  LAW: the profiler only sees ON-CPU time. A frame-paced demo that sleeps
  between frames shows FEW samples ("0 samples — idle" is normal); profile a
  CPU-bound workload. Sampling is read-only, so nothing is ever paused — this
  is the safe counterpart to the debugger. In the GUI it is the Profile tab
  (pick isolate, Sample). [Stub] rows are VM runtime stubs (inline-cache,
  allocation) the sampled code spent time in.

ARCHITECTURE
  Two isolates: this UI isolate (pinned to the AppKit thread, builds the views)
  and a language isolate (runs your code, holds state), talking over SendPort.
  ONE control plane: the VM's service WebSocket (ws://127.0.0.1:8181/ws)
  carries Observatory introspection, GUI control (the ext.dartui.send
  extension — macdart/tcl/dartui.tcl), and pushed events.
''';

main(List<String> args) async {
  gAssets = Platform.script.resolve('assets/').toFilePath();   // icons + texture
  initEvents();     // AppKit callbacks re-enter through this port — see [defer]
  var standaloneApp = _standaloneAppName(args);
  var standaloneGame = _standaloneGameName(args);
  if (standaloneApp != null) {
    buildStandaloneWindow(standaloneApp);
  } else if (standaloneGame != null) {
    buildStandaloneGameWindow(standaloneGame);
    gStandaloneFullscreen = args != null &&
        (args.contains('--fullscreen') || args.contains('--full'));
  } else {
    buildWindow();
  }

  // The language isolate hot-reloads (rewrites) its own root file, so spawn it
  // from a MUTABLE COPY of the tracked language.dart template, never the source.
  var templatePath = Platform.script.resolve('language.dart').toFilePath();
  gScratch = Directory.systemTemp.path + '/macdart_ws_lang.dart';
  // The image lives in ~/.macdart so it persists across sessions.
  var home = Platform.environment['HOME'];
  var appDir = new Directory(home + '/.macdart');
  if (!appDir.existsSync()) appDir.createSync(recursive: true);
  gDbPath = home + '/.macdart/workspace.sqlite';
  new File(gScratch).writeAsStringSync(new File(templatePath).readAsStringSync());
  await spawnLanguage();
  log("language isolate ready — image: " + gDbPath);
  keyWatch();       // record held keys app-wide; games poll it via pull ticks
  if (!gStandalone) {
    startMetrics();   // ~4 Hz VM counters in the toolbar (no toolbar standalone)
    snapshotLastGood();
  }

  // ONE listener: the vm-service. Control rides it as the ext.dartui.send
  // extension (macdart/tcl/dartui.tcl), introspection is the Observatory
  // protocol, events are its streams. The old line socket (7644) and the framed
  // channel (7645) are gone — three listeners was the opposite of unified.
  registerServiceExtensions();
  // The window and the control plane are up. Until this point the host treats a
  // UI isolate error as fatal, so a workspace that failed to load exits instead
  // of sitting there as a process with no window.
  wsUiReady();

  // Standalone: run the requested class now that the language isolate is ready.
  if (standaloneApp != null) {
    await appRun(standaloneApp);
    if (gAppName == null) {
      gWindow.setTitle(standaloneApp + " — not found in the image");
    }
  } else if (standaloneGame != null) {
    var d = _resolveDemo(standaloneGame);
    if (d != null) await runScannedDemo(d[0], d[1]);  // opens the game pane on its first frame
    else gWindow.setTitle(standaloneGame + " — no such game/demo");
  }
}

// === The Sprite Editor (SPRITE_EDITOR_PLAN.md) ===============================
// A paint program for the game library, in its own window: the 16-colour
// sprites the pane renders — pixels, per-sprite palette, frames — edited with
// the mouse and saved as SOURCE in the image (a sheet class with installOn:,
// the hall-of-fame doctrine: your art is source). The document model lives in
// spriteed_model.dart, pure and headless-tested; this section is only views,
// mouse, and the pane preview.
//
// The preview IS the real engine: gpOpen returns the engine's NSView and this
// window parents it like the demos tab does. Defs and frames are append-only
// engine-side, so an edit never mutates engine state — the preview rebuilds
// from scratch each time (reopen + ONE gpApply batch; apply is atomic and ends
// in a present, so the glass never shows a partial rebuild). The engine is a
// singleton: launching a game re-parents the view away (gpEnter's hook tells
// us), and the Preview button takes it back.

Cocoa gSpWindow;
Cocoa gSpGridView, gSpGridImg;
Cocoa gSpPalView, gSpPalImg;
Cocoa gSpNameField, gSpWField, gSpHField;
Cocoa gSpFrameLbl, gSpStatusLbl, gSpRgbLbl;
Cocoa gSpRSlider, gSpGSlider, gSpBSlider;
Cocoa gSpFpsSlider, gSpPlayChk;
Cocoa gSpLoadPopup;
Cocoa gSpPreviewBox;
Map<String, Cocoa> gSpToolBtns = <String, Cocoa>{};

SpriteDoc gSpDoc;
int gSpFrame = 0;                 // the frame under edit
int gSpColor = 15;                // the active palette index
String gSpTool = 'pencil';        // pencil | fill | pick
bool gSpOwnsPane = false;         // the engine view is in OUR preview box
Timer gSpPreviewTimer;            // coalesces preview rebuilds

const double kSpGridPx = 432.0;   // the editing canvas, square
const double kSpPalW = 256.0, kSpPalH = 64.0;   // 8x2 swatches of 32px

// --- window ------------------------------------------------------------------

void spriteEdShow(String loadName) {
  if (gSpDoc == null) gSpDoc = new SpriteDoc();
  if (gSpWindow == null) spBuildWindow();
  gSpWindow.makeKeyAndOrderFront(null);
  // A scripted `sprited` arrives with some other app frontmost; the menu
  // path is already active, so this is a no-op there.
  Cocoa.cls("NSApplication").sharedApplication().activateIgnoringOtherApps(true);
  // Take the pane for the preview unless a game is actually playing on it —
  // stealing a running game on a menu click would be rude; the Preview button
  // is the deliberate version.
  if (!gSpOwnsPane && !gGpMode) spAcquirePane();
  if (loadName != null && loadName.isNotEmpty) spLoadSheet(loadName);
  spRepaintAll();
}

void spriteEdPaneTaken() {
  if (!gSpOwnsPane) return;
  gSpOwnsPane = false;
  spStatus("a game took the pane — Preview takes it back");
}

void spStatus(String s) {
  if (gSpStatusLbl != null) gSpStatusLbl.setStringValue(s);
}

void spBuildWindow() {
  // titled | closable | miniaturizable — deliberately NOT resizable: the grid
  // and pane are fixed-pitch surfaces, and a fixed layout keeps every frame
  // computation honest. The red button HIDES the window (there is no close
  // notification in the bridge, and releasedWhenClosed=false keeps the window
  // object alive), so state survives and the menu item brings it straight back.
  gSpWindow = Cocoa.cls("NSWindow").alloc().initWithContentRect(
      [0.0, 0.0, 980.0, 560.0], styleMask: 7, backing: 2, defer: false);
  gSpWindow.setTitle("Sprite Editor");
  gSpWindow.setReleasedWhenClosed(false);
  var c = gSpWindow.contentView();

  // --- left: the editing grid + tools ---
  gSpGridImg = Cocoa.cls("NSImage").alloc().initWithSize([kSpGridPx, kSpGridPx]);
  gSpGridView = Cocoa.cls("NSImageView").alloc()
      .initWithFrame([12.0, 116.0, kSpGridPx, kSpGridPx]);
  gSpGridView.setImageScaling(3);
  gSpGridView.setImage(gSpGridImg);
  c.addSubview(gSpGridView);
  // Click paints a dot (or fills / picks); pan paints a stroke. Both come
  // through the generic action proxy the app canvas already proves; the point
  // is read synchronously (a deferred read gets a stale/default point) and
  // only the DELIVERY is deferred.
  var clickG = Cocoa.cls("NSClickGestureRecognizer").alloc().init();
  gSpGridView.addGestureRecognizer(clickG);
  gTargets.add(onAction(clickG, (s) {
    var pt = clickG.locationInView(gSpGridView);
    if (pt is List && pt.length >= 2) {
      var x = (pt[0] as num).toDouble(), y = kSpGridPx - (pt[1] as num).toDouble();
      defer(() => spPointer(x, y, false));
    }
  }));
  var panG = Cocoa.cls("NSPanGestureRecognizer").alloc().init();
  gSpGridView.addGestureRecognizer(panG);
  gTargets.add(onAction(panG, (s) {
    var pt = panG.locationInView(gSpGridView);
    if (pt is List && pt.length >= 2) {
      var x = (pt[0] as num).toDouble(), y = kSpGridPx - (pt[1] as num).toDouble();
      defer(() => spPointer(x, y, true));
    }
  }));

  var ty = 84.0;
  spToolBtn(c, 'pencil', "Pencil", [12.0, ty, 64.0, 24.0]);
  spToolBtn(c, 'fill',   "Fill",   [80.0, ty, 56.0, 24.0]);
  spToolBtn(c, 'pick',   "Pick",   [140.0, ty, 56.0, 24.0]);
  button(c, "◀", [212.0, ty, 32.0, 24.0], (s) { spShift(-1, 0); });
  button(c, "▶", [246.0, ty, 32.0, 24.0], (s) { spShift(1, 0); });
  button(c, "▲", [280.0, ty, 32.0, 24.0], (s) { spShift(0, -1); });
  button(c, "▼", [314.0, ty, 32.0, 24.0], (s) { spShift(0, 1); });
  button(c, "Clear", [356.0, ty, 56.0, 24.0], (s) {
    gSpDoc.clearFrame(gSpFrame);
    spEdited();
  });

  gSpStatusLbl = label(c, [12.0, 8.0, 956.0, 18.0]);
  spStatus("pencil, colour 15 — click or drag to paint");

  // --- right column ---
  var rx = 456.0;
  var nameLbl = label(c, [rx, 528.0, 44.0, 18.0]);
  nameLbl.setStringValue("Name");
  gSpNameField = Cocoa.cls("NSTextField").alloc()
      .initWithFrame([rx + 46.0, 524.0, 150.0, 24.0]);
  gSpNameField.setStringValue(gSpDoc == null ? "Sprite" : gSpDoc.name);
  c.addSubview(gSpNameField);
  var wLbl = label(c, [rx + 206.0, 528.0, 18.0, 18.0]);
  wLbl.setStringValue("W");
  gSpWField = Cocoa.cls("NSTextField").alloc()
      .initWithFrame([rx + 226.0, 524.0, 44.0, 24.0]);
  c.addSubview(gSpWField);
  var hLbl = label(c, [rx + 276.0, 528.0, 18.0, 18.0]);
  hLbl.setStringValue("H");
  gSpHField = Cocoa.cls("NSTextField").alloc()
      .initWithFrame([rx + 296.0, 524.0, 44.0, 24.0]);
  c.addSubview(gSpHField);
  button(c, "Resize", [rx + 348.0, 524.0, 64.0, 24.0], (s) { spResizeFromFields(); });

  // Palette: one canvas, 16 swatches — a click selects; the sliders edit the
  // selection. Cheaper and prettier than sixteen NSButtons.
  gSpPalImg = Cocoa.cls("NSImage").alloc().initWithSize([kSpPalW, kSpPalH]);
  gSpPalView = Cocoa.cls("NSImageView").alloc()
      .initWithFrame([rx, 448.0, kSpPalW, kSpPalH]);
  gSpPalView.setImageScaling(3);
  gSpPalView.setImage(gSpPalImg);
  c.addSubview(gSpPalView);
  var palClick = Cocoa.cls("NSClickGestureRecognizer").alloc().init();
  gSpPalView.addGestureRecognizer(palClick);
  gTargets.add(onAction(palClick, (s) {
    var pt = palClick.locationInView(gSpPalView);
    if (pt is List && pt.length >= 2) {
      var x = (pt[0] as num).toDouble(), y = kSpPalH - (pt[1] as num).toDouble();
      var col = (x / 32.0).floor(), row = (y / 32.0).floor();
      if (col >= 0 && col < 8 && row >= 0 && row < 2) {
        defer(() { spSelectColor(row * 8 + col); });
      }
    }
  }));

  gSpRSlider = spSlider(c, [rx + 268.0, 492.0, 150.0, 20.0]);
  gSpGSlider = spSlider(c, [rx + 268.0, 470.0, 150.0, 20.0]);
  gSpBSlider = spSlider(c, [rx + 268.0, 448.0, 150.0, 20.0]);
  gSpRgbLbl = label(c, [rx + 424.0, 466.0, 88.0, 18.0]);

  gSpFrameLbl = label(c, [rx, 404.0, 92.0, 18.0]);
  button(c, "<",   [rx + 94.0, 400.0, 30.0, 24.0], (s) { spGotoFrame(gSpFrame - 1); });
  button(c, ">",   [rx + 126.0, 400.0, 30.0, 24.0], (s) { spGotoFrame(gSpFrame + 1); });
  button(c, "Add", [rx + 164.0, 400.0, 46.0, 24.0], (s) {
    gSpFrame = gSpDoc.addFrame();
    spEdited();
  });
  button(c, "Dup", [rx + 212.0, 400.0, 46.0, 24.0], (s) {
    var ni = gSpDoc.dupFrame(gSpFrame);
    if (ni >= 0) { gSpFrame = ni; spEdited(); }
  });
  button(c, "Del", [rx + 260.0, 400.0, 46.0, 24.0], (s) {
    if (gSpDoc.delFrame(gSpFrame)) {
      if (gSpFrame >= gSpDoc.frames.length) gSpFrame = gSpDoc.frames.length - 1;
      spEdited();
    } else {
      spStatus("the last frame stays — a sprite with no frames is nothing");
    }
  });

  gSpPlayChk = Cocoa.cls("NSButton").alloc()
      .initWithFrame([rx, 368.0, 60.0, 22.0]);
  gSpPlayChk.setButtonType(3);
  gSpPlayChk.setTitle("Play");
  gSpPlayChk.setState(1);
  c.addSubview(gSpPlayChk);
  gTargets.add(onAction(gSpPlayChk, (s) { defer(spPreviewMark); }));
  gSpFpsSlider = spSlider(c, [rx + 66.0, 368.0, 150.0, 20.0]);
  gSpFpsSlider.setMinValue(1.0);
  gSpFpsSlider.setMaxValue(30.0);
  gSpFpsSlider.setDoubleValue(8.0);

  // The preview box: 512x256 view, 256x128 logical pane — exactly 2x, so the
  // engine's nearest-filter upscale lands on whole pixels.
  gSpPreviewBox = Cocoa.cls("NSView").alloc()
      .initWithFrame([rx, 96.0, 512.0, 256.0]);
  c.addSubview(gSpPreviewBox);

  button(c, "Preview", [rx, 56.0, 70.0, 24.0], (s) { spAcquirePane(); spPreviewMark(); });
  button(c, "Save", [rx + 78.0, 56.0, 60.0, 24.0], (s) { spSave(); });
  gSpLoadPopup = Cocoa.cls("NSPopUpButton").alloc()
      .initWithFrame([rx + 146.0, 56.0, 170.0, 24.0], pullsDown: true);
  gSpLoadPopup.addItemWithTitle("Load…");
  c.addSubview(gSpLoadPopup);
  gTargets.add(onAction(gSpLoadPopup, (s) {
    var t = gSpLoadPopup.titleOfSelectedItem().UTF8String();
    if (t != null && t != "Load…" && !t.startsWith("(")) {
      defer(() { spLoadSheet(t); });
    }
  }));
  button(c, "Copy Code", [rx + 324.0, 56.0, 88.0, 24.0], (s) { spCopyCode(); });
  button(c, "New", [rx + 420.0, 56.0, 52.0, 24.0], (s) { spNew(); });

  gSpWindow.center();
}

void spToolBtn(Cocoa parent, String tool, String title, List frame) {
  var b = button(parent, title, frame, (s) {
    gSpTool = tool;
    spSyncTools();
    spStatus(tool + ", colour " + gSpColor.toString());
  });
  b.setButtonType(2);              // toggle — shows the active tool pressed
  gSpToolBtns[tool] = b;
  if (tool == gSpTool) b.setState(1);
}

void spSyncTools() {
  gSpToolBtns.forEach((t, b) { b.setState(t == gSpTool ? 1 : 0); });
}

Cocoa spSlider(Cocoa parent, List frame) {
  var v = Cocoa.cls("NSSlider").alloc().initWithFrame(frame);
  v.setMinValue(0.0);
  v.setMaxValue(255.0);
  parent.addSubview(v);
  gTargets.add(onAction(v, (s) { defer(spRgbFromSliders); }));
  return v;
}

// --- painting ----------------------------------------------------------------

double spCell() {
  var m = gSpDoc.w > gSpDoc.h ? gSpDoc.w : gSpDoc.h;
  var cell = (kSpGridPx / m).floorToDouble();
  if (cell < 4.0) cell = 4.0;
  if (cell > 27.0) cell = 27.0;
  return cell;
}

/// One pointer event on the grid, click or drag. Drags paint with the pencil
/// regardless of tool — a dragged fill or pick would fire dozens of times.
void spPointer(double px, double py, bool dragging) {
  if (gSpDoc == null) return;
  var cell = spCell();
  var x = (px / cell).floor(), y = (py / cell).floor();
  if (x < 0 || x >= gSpDoc.w || y < 0 || y >= gSpDoc.h) return;
  if (dragging || gSpTool == 'pencil') {
    if (gSpDoc.setPx(gSpFrame, x, y, gSpColor)) spEdited();
  } else if (gSpTool == 'fill') {
    if (gSpDoc.floodFill(gSpFrame, x, y, gSpColor)) spEdited();
  } else if (gSpTool == 'pick') {
    spSelectColor(gSpDoc.getPx(gSpFrame, x, y));
  }
}

void spShift(int dx, int dy) {
  gSpDoc.shift(gSpFrame, dx, dy);
  spEdited();
}

void spSelectColor(int i) {
  if (i < 0 || i > 15) return;
  gSpColor = i;
  var p = gSpDoc.pal[i];
  gSpRSlider.setDoubleValue(p[0].toDouble());
  gSpGSlider.setDoubleValue(p[1].toDouble());
  gSpBSlider.setDoubleValue(p[2].toDouble());
  spRepaintPal();
  spSyncFields();
  spStatus(gSpTool + ", colour " + i.toString() +
      (i == 0 ? " (transparent — the engine discards it)" : ""));
}

void spRgbFromSliders() {
  gSpDoc.setPal(gSpColor, gSpRSlider.doubleValue().round(),
      gSpGSlider.doubleValue().round(), gSpBSlider.doubleValue().round());
  spEdited();
}

void spResizeFromFields() {
  var nw = int.parse(gSpWField.stringValue().UTF8String().trim(),
      onError: (_) => 0);
  var nh = int.parse(gSpHField.stringValue().UTF8String().trim(),
      onError: (_) => 0);
  if (gSpDoc.resize(nw, nh)) {
    spEdited();
  } else {
    spStatus("size is 1..64 x 1..64 (" + gSpDoc.w.toString() + "x" +
        gSpDoc.h.toString() + " unchanged)");
    spSyncFields();
  }
}

void spGotoFrame(int f) {
  if (f < 0 || f >= gSpDoc.frames.length) return;
  gSpFrame = f;
  spRepaintGrid();
  spSyncFields();
  spPreviewMark();   // a paused preview shows the frame under edit
}

/// Every mutation funnels here: repaint what shows the document, mark the
/// preview. Called at pointer rate during a drag, so it stays cheap — one
/// renderInto of the grid, no allocation beyond the op lists.
void spEdited() {
  spRepaintGrid();
  spRepaintPal();
  spSyncFields();
  spPreviewMark();
}

void spRepaintAll() {
  spRepaintGrid();
  spRepaintPal();
  spSyncFields();
  spSyncTools();
  spSelectColor(gSpColor);
}

void spSyncFields() {
  if (gSpFrameLbl != null) {
    gSpFrameLbl.setStringValue("Frame " + (gSpFrame + 1).toString() + "/" +
        gSpDoc.frames.length.toString());
  }
  if (gSpWField != null) gSpWField.setStringValue(gSpDoc.w.toString());
  if (gSpHField != null) gSpHField.setStringValue(gSpDoc.h.toString());
  if (gSpRgbLbl != null) {
    var p = gSpDoc.pal[gSpColor];
    gSpRgbLbl.setStringValue(p[0].toString() + "," + p[1].toString() + "," +
        p[2].toString());
  }
}

// The draw-op colour contract is 0.0..1.0 (renderInto hands components
// straight to colorWithCalibratedRed:, which clamps) — the model's palette is
// 0..255, so every op converts HERE. Passing bytes draws white-on-white: the
// first build of this window was a perfectly rendered blank.
double _spC(num v) => v / 255.0;

void spRepaintGrid() {
  if (gSpGridImg == null) return;
  var cell = spCell();
  var ops = <List>[<dynamic>['clear', _spC(46), _spC(46), _spC(52)]];
  var px = gSpDoc.frames[gSpFrame];
  for (var y = 0; y < gSpDoc.h; y++) {
    for (var x = 0; x < gSpDoc.w; x++) {
      var cx = x * cell, cy = y * cell;
      var v = px[y * gSpDoc.w + x];
      if (v == 0) {
        // Transparent: the checker every paint program means by "nothing".
        var half = cell / 2;
        ops.add(<dynamic>['rect', cx, cy, cell, cell, _spC(58), _spC(58), _spC(64), true]);
        ops.add(<dynamic>['rect', cx, cy, half, half, _spC(74), _spC(74), _spC(80), true]);
        ops.add(<dynamic>['rect', cx + half, cy + half, half, half, _spC(74), _spC(74), _spC(80), true]);
      } else {
        var p = gSpDoc.pal[v];
        ops.add(<dynamic>['rect', cx, cy, cell, cell, _spC(p[0]), _spC(p[1]), _spC(p[2]), true]);
      }
      // The 1px seam that makes it a grid (skipped when cells get tiny).
      if (cell >= 6.0) {
        ops.add(<dynamic>['rect', cx, cy, cell, cell, _spC(30), _spC(30), _spC(34), false]);
      }
    }
  }
  renderInto(gSpGridImg, kSpGridPx, kSpGridPx, ops);
  // Re-SET the image: NSImageView caches the drawn representation, and a
  // lockFocus draw alone never reaches the glass (the app canvas learned the
  // same lesson — see appApply).
  gSpGridView.setImage(gSpGridImg);
  gSpGridView.setNeedsDisplay(true);
}

void spRepaintPal() {
  if (gSpPalImg == null) return;
  var ops = <List>[<dynamic>['clear', _spC(46), _spC(46), _spC(52)]];
  for (var i = 0; i < 16; i++) {
    var cx = (i % 8) * 32.0, cy = (i ~/ 8) * 32.0;
    var p = gSpDoc.pal[i];
    ops.add(<dynamic>['rect', cx + 2, cy + 2, 28.0, 28.0, _spC(p[0]), _spC(p[1]), _spC(p[2]), true]);
    if (i == 0) {
      // Entry 0 carries a colour but the engine discards it — say so visually.
      ops.add(<dynamic>['line', cx + 4, cy + 26, cx + 26, cy + 4, 1.0, 1.0, 1.0, 2.0]);
    }
    if (i == gSpColor) {
      ops.add(<dynamic>['rect', cx + 1, cy + 1, 30.0, 30.0, 1.0, 1.0, 1.0, false]);
      ops.add(<dynamic>['rect', cx, cy, 32.0, 32.0, 0.0, 0.0, 0.0, false]);
    }
  }
  renderInto(gSpPalImg, kSpPalW, kSpPalH, ops);
  gSpPalView.setImage(gSpPalImg);
  gSpPalView.setNeedsDisplay(true);
}

// --- the pane preview --------------------------------------------------------

void spAcquirePane() {
  // A game on the demos tab holds the pane through the demo machinery — end
  // that session properly (gpLeave restores the demos canvas) rather than
  // yanking the view out from under it.
  if (gGpMode) stopDemo("the sprite editor took the pane");
  var v = gpOpen(256, 128, 256, 128, 0);
  if (v == null) { spStatus("the engine would not open"); return; }
  v.setFrame([0.0, 0.0, 512.0, 256.0]);
  gSpPreviewBox.addSubview(v);
  gSpOwnsPane = true;
}

/// Coalesce rebuilds: a drag edits at pointer rate, the pane needs ~10Hz.
void spPreviewMark() {
  if (gSpPreviewTimer != null) return;
  gSpPreviewTimer = new Timer(const Duration(milliseconds: 100), () {
    gSpPreviewTimer = null;
    spRebuildPreview();
  });
}

/// The whole preview scene, from scratch, in one atomic apply: reopen resets
/// the engine (defs are append-only — rebuilding IS the edit path), then one
/// batch carries background, def, frames, palette, placements and the
/// present. Sprite instances at every power-of-two scale that fits, so the
/// art is judged at game distance and up close in the same glance.
void spRebuildPreview() {
  if (!gSpOwnsPane || gSpDoc == null) return;
  var v = gpOpen(256, 128, 256, 128, 0);   // open() closes first: full reset
  if (v == null) return;
  var cmds = <List>[];
  // Screen palette 1..15 is the fixed per-scanline set — programmable
  // entries start at 16 (the engine refuses lower; it told us so).
  cmds.add(<dynamic>['gppal', 16, 26, 24, 38]);
  cmds.add(<dynamic>['gpcls', 16]);
  cmds.add(<dynamic>['gpsprite', 0, gSpDoc.rowsOf(0)]);
  for (var f = 1; f < gSpDoc.frames.length; f++) {
    cmds.add(<dynamic>['gpframe', 0, gSpDoc.rowsOf(f)]);
  }
  for (var i = 1; i < 16; i++) {
    var p = gSpDoc.pal[i];
    cmds.add(<dynamic>['gpspritepal', 0, i, p[0], p[1], p[2]]);
  }
  var playing = gSpPlayChk != null && gSpPlayChk.state() == 1 &&
      gSpDoc.frames.length > 1;
  var fps = gSpFpsSlider == null ? 8.0 : gSpFpsSlider.doubleValue();
  var x = 10.0;
  var inst = 0;
  for (var scale in <double>[1.0, 2.0, 4.0]) {
    var sw = gSpDoc.w * scale, sh = gSpDoc.h * scale;
    if (x + sw > 250.0 || sh > 120.0) continue;
    var y = (128.0 - sh) / 2;
    cmds.add(<dynamic>['gpspawn', inst, 0, x, y]);
    cmds.add(<dynamic>['gpplace', inst, x, y,
        playing ? 0 : gSpFrame, scale, 0.0, 1.0]);
    if (playing) cmds.add(<dynamic>['gpanim', inst, fps]);
    inst++;
    x += sw + 14.0;
  }
  var e = gpApply(cmds);
  if (e != null) spStatus("preview: " + e.toString());
}

// --- save / load / export ----------------------------------------------------

Future spSave() async {
  var name = gSpNameField.stringValue().UTF8String().trim();
  if (!SpriteDoc.validName(name)) {
    spStatus("name must be a class name: capital letter, then letters/digits");
    return;
  }
  gSpDoc.name = name;
  // The STORE path, deliberately (live-reload contracts): parse-check, image
  // write, one class made live — no world reload, nothing running disturbed.
  var r = await ask('spstore', gSpDoc.sheetSource());
  spStatus(r == null ? "save timed out" : r.toString());
  spRefreshLoadList();
}

Future spRefreshLoadList() async {
  if (gSpLoadPopup == null) return;
  var r = await ask('splist', '');
  gSpLoadPopup.removeAllItems();
  gSpLoadPopup.addItemWithTitle("Load…");
  if (r is List && r.isNotEmpty) {
    for (var n in r) { gSpLoadPopup.addItemWithTitle(n.toString()); }
  } else {
    gSpLoadPopup.addItemWithTitle("(no sheets in the image)");
  }
}

Future spLoadSheet(String name) async {
  var r = await ask('spload', name);
  if (r is! List || r.length < 3) {
    spStatus("load " + name + ": " + r.toString());
    return;
  }
  var rows = <String>[];
  for (var s in (r[1] as List)) { rows.add(s.toString()); }
  if (!gSpDoc.loadFrames(rows)) {
    spStatus("load " + name + ": bad art rows in the image class");
    return;
  }
  gSpDoc.name = r[0].toString();
  var pl = r[2] as List;
  for (var i = 0; i < 16 && i < pl.length; i++) {
    var p = pl[i] as List;
    gSpDoc.setPal(i, (p[0] as num).toInt(), (p[1] as num).toInt(),
        (p[2] as num).toInt());
  }
  gSpFrame = 0;
  if (gSpNameField != null) gSpNameField.setStringValue(gSpDoc.name);
  spRepaintAll();
  spPreviewMark();
  spStatus("loaded " + gSpDoc.name + " — " +
      gSpDoc.frames.length.toString() + " frame(s), " +
      gSpDoc.w.toString() + "x" + gSpDoc.h.toString());
}

void spNew() {
  gSpDoc = new SpriteDoc();
  gSpFrame = 0;
  gSpColor = 15;
  gSpTool = 'pencil';
  if (gSpNameField != null) gSpNameField.setStringValue(gSpDoc.name);
  spRepaintAll();
  spPreviewMark();
  spStatus("new 16x16 document");
}

void spCopyCode() {
  var code = gSpDoc.codeSnippet();
  try {
    var pb = Cocoa.cls("NSPasteboard").generalPasteboard();
    pb.clearContents();
    pb.setString(code, forType: "public.utf8-plain-text");
    spStatus("defineSprite: code copied — paste it into a game's setup");
  } catch (e) {
    log(code);
    spStatus("clipboard refused; the code went to the log instead");
  }
}

// --- the scripted face (gui_smoke + the control plane) -----------------------

Future<String> spriteEdVerb(String cmd, String arg) async {
  if (cmd == 'sprited') { spriteEdShow(arg.trim()); await spRefreshLoadList(); return "ok"; }
  if (gSpWindow == null) return "ERR: sprite editor not open (run sprited)";
  switch (cmd) {
    case 'spritedclose':
      gSpWindow.orderOut(null);
      return "ok";
    case 'spedstat':
      return (gSpOwnsPane ? "pane" : "nopane") + " " + gSpDoc.name + " " +
          gSpDoc.w.toString() + "x" + gSpDoc.h.toString() +
          " frame " + (gSpFrame + 1).toString() + "/" +
          gSpDoc.frames.length.toString() +
          " colour " + gSpColor.toString() + " tool " + gSpTool;
    case 'spedrows':
      return gSpDoc.rowsOf(gSpFrame);
    case 'spednew':
      spNew();
      return "ok";
    case 'speddump': {                        // debug: the two canvases to disk
      try {
        gSpGridImg.TIFFRepresentation().writeToFile("/tmp/sp_grid.tiff",
            atomically: true);
        gSpPalImg.TIFFRepresentation().writeToFile("/tmp/sp_pal.tiff",
            atomically: true);
        return "ok /tmp/sp_grid.tiff /tmp/sp_pal.tiff";
      } catch (e) { return "ERR: " + e.toString(); }
    }
    case 'spedpaint': {                       // spedpaint <x> <y> — the tool, by hand
      var p = arg.split(' ').where((s) => s.isNotEmpty).toList();
      if (p.length < 2) return "ERR: spedpaint <x> <y>";
      var cell = spCell();
      spPointer((int.parse(p[0]) + 0.5) * cell, (int.parse(p[1]) + 0.5) * cell, false);
      return gSpDoc.rowsOf(gSpFrame);
    }
    case 'spedcolor': {
      spSelectColor(int.parse(arg.trim(), onError: (_) => -1));
      return "colour " + gSpColor.toString();
    }
    case 'spedrgb': {
      var p = arg.split(' ').where((s) => s.isNotEmpty).toList();
      if (p.length < 3) return "ERR: spedrgb <r> <g> <b>";
      gSpDoc.setPal(gSpColor, int.parse(p[0]), int.parse(p[1]), int.parse(p[2]));
      spEdited();
      return "ok";
    }
    case 'spedtool':
      if (arg != 'pencil' && arg != 'fill' && arg != 'pick') return "ERR: pencil|fill|pick";
      gSpTool = arg;
      spSyncTools();
      return "ok";
    case 'spedframe': {
      var a = arg.trim();
      if (a == 'add') { gSpFrame = gSpDoc.addFrame(); spEdited(); }
      else if (a == 'dup') { var ni = gSpDoc.dupFrame(gSpFrame); if (ni >= 0) { gSpFrame = ni; spEdited(); } }
      else if (a == 'del') {
        if (!gSpDoc.delFrame(gSpFrame)) return "ERR: the last frame stays";
        if (gSpFrame >= gSpDoc.frames.length) gSpFrame = gSpDoc.frames.length - 1;
        spEdited();
      }
      else if (a == 'next') { spGotoFrame(gSpFrame + 1); }
      else if (a == 'prev') { spGotoFrame(gSpFrame - 1); }
      else { return "ERR: add|dup|del|next|prev"; }
      return "frame " + (gSpFrame + 1).toString() + "/" + gSpDoc.frames.length.toString();
    }
    case 'spedname':
      if (arg.trim().isNotEmpty) {
        gSpNameField.setStringValue(arg.trim());
      }
      return gSpNameField.stringValue().UTF8String();
    case 'spedsave': {
      if (arg.trim().isNotEmpty) gSpNameField.setStringValue(arg.trim());
      await spSave();
      return gSpStatusLbl.stringValue().UTF8String();
    }
    case 'spedload': {
      await spLoadSheet(arg.trim());
      return gSpStatusLbl.stringValue().UTF8String();
    }
    case 'spedlist': {
      var r = await ask('splist', '');
      if (r is List) return r.map((x) => x.toString()).join('\n');
      return r.toString();
    }
  }
  return "ERR: unknown " + cmd;
}

// === The Sound Editor (SOUND_EDITOR_PLAN.md) =================================
// The sprite editor's sibling: the synth's FULL Effect recipe — the parameter
// space the eleven presets are hand-tuned points in — edited with sliders,
// auditioned through the real synth (gpeffect + gpplay on slot 0), and saved
// as source in the image. The Metal pane draws the ENVELOPE and sweep (model
// math — there is no sample readback); the AUDIO is the native truth via
// Play. Same ownership etiquette as the sprite editor: the engine is a
// singleton, the editor holds the pane, a launching game borrows it away.

Cocoa gSndWindow;
Cocoa gSndNameField, gSndSeedField, gSndStatusLbl;
Cocoa gSndPresetPopup, gSndLoadPopup;
Cocoa gSndPreviewBox;
List gSndSliderDefs;                 // [label, min, max, get(), set(v)] rows
List<Cocoa> gSndSliders = <Cocoa>[];
List<Cocoa> gSndSliderVals = <Cocoa>[];
List<Cocoa> gSndOscPopups = <Cocoa>[];
List<Cocoa> gSndOscFreq = <Cocoa>[];
List<Cocoa> gSndOscAmp = <Cocoa>[];
List<Cocoa> gSndOscPw = <Cocoa>[];

SoundDoc gSndDoc;
bool gSndOwnsPane = false;
Timer gSndPreviewTimer;
math.Random gSndRng = new math.Random();

void soundEdShow(String loadName) {
  if (gSndDoc == null) gSndDoc = new SoundDoc();
  if (gSndWindow == null) sndBuildWindow();
  gSndWindow.makeKeyAndOrderFront(null);
  Cocoa.cls("NSApplication").sharedApplication().activateIgnoringOtherApps(true);
  if (!gSndOwnsPane && !gGpMode) sndAcquirePane();
  if (loadName != null && loadName.isNotEmpty) sndLoadSheet(loadName);
  sndSyncAll();
}

void soundEdPaneTaken() {
  if (!gSndOwnsPane) return;
  gSndOwnsPane = false;
  sndStatus("a game took the pane — Play takes it back");
}

void sndStatus(String s) {
  if (gSndStatusLbl != null) gSndStatusLbl.setStringValue(s);
}

void sndBuildWindow() {
  gSndWindow = Cocoa.cls("NSWindow").alloc().initWithContentRect(
      [0.0, 0.0, 980.0, 560.0], styleMask: 7, backing: 2, defer: false);
  gSndWindow.setTitle("Sound Editor");
  gSndWindow.setReleasedWhenClosed(false);
  var c = gSndWindow.contentView();

  // --- left: the pane (envelope view) + the oscillator rack ---
  gSndPreviewBox = Cocoa.cls("NSView").alloc()
      .initWithFrame([12.0, 288.0, 512.0, 256.0]);
  c.addSubview(gSndPreviewBox);

  for (var i = 0; i < 4; i++) {
    var y = 252.0 - i * 32.0;
    var lbl = label(c, [12.0, y + 3.0, 40.0, 18.0]);
    lbl.setStringValue("Osc " + (i + 1).toString());
    var pop = Cocoa.cls("NSPopUpButton").alloc()
        .initWithFrame([54.0, y, 96.0, 24.0], pullsDown: false);
    for (var w in kSndWaves) { pop.addItemWithTitle(w); }
    c.addSubview(pop);
    gSndOscPopups.add(pop);
    var oi = i, opop = pop;
    gTargets.add(onAction(pop, (s) { defer(() {
      if (oi < gSndDoc.oscs.length) {
        gSndDoc.oscs[oi].wave = opop.indexOfSelectedItem();
        sndEdited();
      }
    }); }));
    var fq = Cocoa.cls("NSTextField").alloc()
        .initWithFrame([156.0, y, 66.0, 24.0]);
    c.addSubview(fq);
    gSndOscFreq.add(fq);
    var ofq = fq;
    gTargets.add(onAction(fq, (s) { defer(() {
      if (oi < gSndDoc.oscs.length) {
        gSndDoc.oscs[oi].freq = double.parse(
            ofq.stringValue().UTF8String().trim(), (_) => 440.0);
        sndEdited();
      }
    }); }));
    var amp = Cocoa.cls("NSSlider").alloc()
        .initWithFrame([228.0, y, 200.0, 22.0]);
    amp.setMinValue(0.0);
    amp.setMaxValue(1.0);
    c.addSubview(amp);
    gSndOscAmp.add(amp);
    var oamp = amp;
    gTargets.add(onAction(amp, (s) { defer(() {
      if (oi < gSndDoc.oscs.length) {
        gSndDoc.oscs[oi].amp = oamp.doubleValue();
        sndEdited();
      }
    }); }));
    var pw = Cocoa.cls("NSTextField").alloc()
        .initWithFrame([434.0, y, 50.0, 24.0]);
    c.addSubview(pw);
    gSndOscPw.add(pw);
    var opw = pw;
    gTargets.add(onAction(pw, (s) { defer(() {
      if (oi < gSndDoc.oscs.length) {
        gSndDoc.oscs[oi].pw = double.parse(
            opw.stringValue().UTF8String().trim(), (_) => 0.5);
        sndEdited();
      }
    }); }));
  }
  button(c, "Add Osc", [12.0, 92.0, 76.0, 24.0], (s) {
    if (gSndDoc.oscs.length < 4) {
      gSndDoc.oscs.add(new SndOsc(0, 440.0, 0.5));
      sndEdited();
    }
  });
  button(c, "Del Osc", [94.0, 92.0, 76.0, 24.0], (s) {
    if (gSndDoc.oscs.isNotEmpty) {
      gSndDoc.oscs.removeLast();
      sndEdited();
    }
  });
  var oscNote = label(c, [180.0, 95.0, 340.0, 18.0]);
  oscNote.setStringValue("no oscillators = the sweep + noise ARE the voice");

  gSndStatusLbl = label(c, [12.0, 8.0, 956.0, 18.0]);
  sndStatus("the eleven presets are starting points — pick one and pull sliders");

  // --- right column: name, presets, the slider stack, files ---
  var rx = 540.0;
  var nameLbl = label(c, [rx, 528.0, 44.0, 18.0]);
  nameLbl.setStringValue("Name");
  gSndNameField = Cocoa.cls("NSTextField").alloc()
      .initWithFrame([rx + 48.0, 524.0, 150.0, 24.0]);
  gSndNameField.setStringValue("Sound");
  c.addSubview(gSndNameField);
  var seedLbl = label(c, [rx + 210.0, 528.0, 38.0, 18.0]);
  seedLbl.setStringValue("Seed");
  gSndSeedField = Cocoa.cls("NSTextField").alloc()
      .initWithFrame([rx + 250.0, 524.0, 90.0, 24.0]);
  c.addSubview(gSndSeedField);
  gTargets.add(onAction(gSndSeedField, (s) { defer(() {
    gSndDoc.seed = int.parse(gSndSeedField.stringValue().UTF8String().trim(),
        onError: (_) => gSndDoc.seed);
    sndEdited();
  }); }));

  gSndPresetPopup = Cocoa.cls("NSPopUpButton").alloc()
      .initWithFrame([rx, 488.0, 130.0, 24.0], pullsDown: true);
  gSndPresetPopup.addItemWithTitle("Preset…");
  for (var nm in SoundDoc.kPresets) { gSndPresetPopup.addItemWithTitle(nm); }
  c.addSubview(gSndPresetPopup);
  gTargets.add(onAction(gSndPresetPopup, (s) { defer(() {
    var t = gSndPresetPopup.titleOfSelectedItem().UTF8String();
    if (t != null && t != "Preset…") {
      var keep = gSndDoc.name;
      gSndDoc = SoundDoc.preset(t);
      gSndDoc.name = keep;
      sndSyncAll();
      sndStatus("preset " + t + " — now make it yours");
    }
  }); }));
  button(c, "Play", [rx + 138.0, 488.0, 64.0, 24.0], (s) { sndPlay(); });
  button(c, "Random", [rx + 208.0, 488.0, 70.0, 24.0], (s) {
    gSndDoc.randomize(gSndRng);
    sndSyncAll();
    sndPlay();
  });
  button(c, "Mutate", [rx + 284.0, 488.0, 66.0, 24.0], (s) {
    gSndDoc.mutate(gSndRng);
    sndSyncAll();
    sndPlay();
  });

  // The slider stack, data-driven: label, min, max, read, write.
  gSndSliderDefs = <List>[
    <dynamic>["duration", 0.01, 4.0, () => gSndDoc.duration, (v) { gSndDoc.duration = v; }],
    <dynamic>["attack", 0.0, 1.0, () => gSndDoc.a, (v) { gSndDoc.a = v; }],
    <dynamic>["decay", 0.0, 1.0, () => gSndDoc.d, (v) { gSndDoc.d = v; }],
    <dynamic>["sustain", 0.0, 1.0, () => gSndDoc.s, (v) { gSndDoc.s = v; }],
    <dynamic>["release", 0.0, 1.0, () => gSndDoc.r, (v) { gSndDoc.r = v; }],
    <dynamic>["sweep from", 0.0, 3000.0, () => gSndDoc.sweepStart, (v) { gSndDoc.sweepStart = v; }],
    <dynamic>["sweep to", 0.0, 3000.0, () => gSndDoc.sweepEnd, (v) { gSndDoc.sweepEnd = v; }],
    <dynamic>["noise", 0.0, 1.0, () => gSndDoc.noiseMix, (v) { gSndDoc.noiseMix = v; }],
    <dynamic>["distortion", 0.0, 1.0, () => gSndDoc.distortion, (v) { gSndDoc.distortion = v; }],
    <dynamic>["echo taps", 0.0, 8.0, () => gSndDoc.echoCount.toDouble(), (v) { gSndDoc.echoCount = v.round(); }],
    <dynamic>["echo delay", 0.0, 0.5, () => gSndDoc.echoDelay, (v) { gSndDoc.echoDelay = v; }],
    <dynamic>["echo decay", 0.0, 0.95, () => gSndDoc.echoDecay, (v) { gSndDoc.echoDecay = v; }],
  ];
  for (var i = 0; i < gSndSliderDefs.length; i++) {
    var def = gSndSliderDefs[i];
    var y = 452.0 - i * 27.0;
    var lbl = label(c, [rx, y + 2.0, 84.0, 18.0]);
    lbl.setStringValue(def[0]);
    var sl = Cocoa.cls("NSSlider").alloc()
        .initWithFrame([rx + 88.0, y, 240.0, 22.0]);
    sl.setMinValue(def[1]);
    sl.setMaxValue(def[2]);
    c.addSubview(sl);
    gSndSliders.add(sl);
    var vl = label(c, [rx + 334.0, y + 2.0, 86.0, 18.0]);
    gSndSliderVals.add(vl);
    var dslider = sl, ddef = def;
    gTargets.add(onAction(sl, (s) { defer(() {
      ddef[4](dslider.doubleValue());
      sndEdited();
    }); }));
  }

  button(c, "New", [rx, 56.0, 52.0, 24.0], (s) {
    gSndDoc = new SoundDoc();
    gSndNameField.setStringValue(gSndDoc.name);
    sndSyncAll();
    sndStatus("new sound");
  });
  button(c, "Save", [rx + 58.0, 56.0, 58.0, 24.0], (s) { sndSave(); });
  gSndLoadPopup = Cocoa.cls("NSPopUpButton").alloc()
      .initWithFrame([rx + 122.0, 56.0, 160.0, 24.0], pullsDown: true);
  gSndLoadPopup.addItemWithTitle("Load…");
  c.addSubview(gSndLoadPopup);
  gTargets.add(onAction(gSndLoadPopup, (s) {
    var t = gSndLoadPopup.titleOfSelectedItem().UTF8String();
    if (t != null && t != "Load…" && !t.startsWith("(")) {
      defer(() { sndLoadSheet(t); });
    }
  }));
  button(c, "Copy Code", [rx + 288.0, 56.0, 88.0, 24.0], (s) {
    try {
      var pb = Cocoa.cls("NSPasteboard").generalPasteboard();
      pb.clearContents();
      pb.setString(gSndDoc.codeSnippet(), forType: "public.utf8-plain-text");
      sndStatus("effect code copied — paste it into a game's setup");
    } catch (e) {
      log(gSndDoc.codeSnippet());
      sndStatus("clipboard refused; the code went to the log instead");
    }
  });

  gSndWindow.center();
}

// --- state <-> controls ------------------------------------------------------

String _sndF(double v) => (v * 1000).round() / 1000.0 == v.roundToDouble()
    ? v.toStringAsFixed(0) : v.toStringAsFixed(3);

void sndSyncAll() {
  gSndDoc.clamp();
  for (var i = 0; i < gSndSliderDefs.length; i++) {
    gSndSliders[i].setDoubleValue(gSndSliderDefs[i][3]());
    gSndSliderVals[i].setStringValue(_sndF(gSndSliderDefs[i][3]()));
  }
  for (var i = 0; i < 4; i++) {
    var have = i < gSndDoc.oscs.length;
    gSndOscPopups[i].setEnabled(have);
    gSndOscFreq[i].setEnabled(have);
    gSndOscAmp[i].setEnabled(have);
    gSndOscPw[i].setEnabled(have);
    if (have) {
      var o = gSndDoc.oscs[i];
      gSndOscPopups[i].selectItemAtIndex(o.wave);
      gSndOscFreq[i].setStringValue(o.freq.toStringAsFixed(1));
      gSndOscAmp[i].setDoubleValue(o.amp);
      gSndOscPw[i].setStringValue(o.pw.toStringAsFixed(2));
    } else {
      gSndOscFreq[i].setStringValue("");
      gSndOscPw[i].setStringValue("");
    }
  }
  if (gSndSeedField != null) gSndSeedField.setStringValue(gSndDoc.seed.toString());
  sndPreviewMark();
}

void sndEdited() {
  sndSyncAll();
}

// --- the pane: envelope + sweep, drawn by the engine -------------------------

void sndAcquirePane() {
  if (gGpMode) stopDemo("the sound editor took the pane");
  var v = gpOpen(256, 128, 256, 128, 0);
  if (v == null) { sndStatus("the engine would not open"); return; }
  v.setFrame([0.0, 0.0, 512.0, 256.0]);
  gSndPreviewBox.addSubview(v);
  gSndOwnsPane = true;
}

void sndPreviewMark() {
  if (gSndPreviewTimer != null) return;
  gSndPreviewTimer = new Timer(const Duration(milliseconds: 100), () {
    gSndPreviewTimer = null;
    sndRebuildPreview();
  });
}

/// The whole view, one atomic apply: the ADSR as a polyline over the full
/// duration (attack up, decay to sustain, hold, release to zero — the
/// engine's FIXED-DURATION rule, so what you see is exactly the length you
/// hear), the sweep as a falling/rising line, osc stubs as labelled ticks.
void sndRebuildPreview() {
  if (!gSndOwnsPane || gSndDoc == null) return;
  gSndDoc.clamp();
  var v = gpOpen(256, 128, 256, 128, 0);
  if (v == null) return;
  var cmds = <List>[];
  cmds.add(<dynamic>['gppal', 16, 24, 22, 34]);
  cmds.add(<dynamic>['gppal', 17, 109, 194, 202]);  // envelope: DB16 cyan
  cmds.add(<dynamic>['gppal', 18, 210, 125, 44]);   // sweep: DB16 orange
  cmds.add(<dynamic>['gppal', 19, 78, 74, 78]);     // grid grey
  cmds.add(<dynamic>['gpcls', 16]);
  // baseline + envelope box
  cmds.add(<dynamic>['gpline', 8, 100, 248, 100, 19]);
  var dur = gSndDoc.duration;
  var aX = 8 + (232 * (gSndDoc.a / dur)).clamp(0, 232);
  var dX = aX + (232 * (gSndDoc.d / dur)).clamp(0, 232);
  var rX = 240 - (232 * (gSndDoc.r / dur)).clamp(0, 232);
  if (dX > 240) dX = 240;
  if (rX < dX) rX = dX;
  var sY = 100 - (80 * gSndDoc.s).round();
  cmds.add(<dynamic>['gpline', 8, 100, aX.round(), 20, 17]);
  cmds.add(<dynamic>['gpline', aX.round(), 20, dX.round(), sY, 17]);
  cmds.add(<dynamic>['gpline', dX.round(), sY, rX.round(), sY, 17]);
  cmds.add(<dynamic>['gpline', rX.round(), sY, 240, 100, 17]);
  // the sweep, scaled into the same box against 3kHz
  if (gSndDoc.sweepStart != gSndDoc.sweepEnd) {
    var y0 = 100 - (80 * (gSndDoc.sweepStart / 3000.0)).clamp(0, 80).round();
    var y1 = 100 - (80 * (gSndDoc.sweepEnd / 3000.0)).clamp(0, 80).round();
    cmds.add(<dynamic>['gpline', 8, y0, 240, y1, 18]);
  }
  cmds.add(<dynamic>['gptextclear']);
  cmds.add(<dynamic>['gptext', 8, 106, 'ADSR ' + gSndDoc.duration.toStringAsFixed(2) + 'S', 109, 194, 202, 1]);
  var oscLbl = '';
  for (var o in gSndDoc.oscs) {
    oscLbl = oscLbl + kSndWaves[o.wave].substring(0, 2).toUpperCase() + ' ';
  }
  if (oscLbl.isNotEmpty) {
    cmds.add(<dynamic>['gptext', 8, 116, oscLbl + (gSndDoc.noiseMix > 0 ? '+NOISE' : ''), 133, 149, 161, 1]);
  } else {
    cmds.add(<dynamic>['gptext', 8, 116, gSndDoc.noiseMix > 0 ? 'NOISE VOICE' : 'SWEEP VOICE', 133, 149, 161, 1]);
  }
  var e = gpApply(cmds);
  if (e != null) sndStatus("preview: " + e.toString());
}

/// Audition on slot 0: define (render) + play, one atomic apply. Slot 0 is a
/// game's low-rack slot, safe because the editor holds the pane — no game is
/// live while it does.
void sndPlay() {
  if (!gSndOwnsPane) sndAcquirePane();
  if (!gSndOwnsPane) return;
  var op = <dynamic>['gpeffect', 0];
  for (var p in gSndDoc.paramsList()) { op.add(p); }
  var e = gpApply(<List>[op, <dynamic>['gpplay', 0]]);
  sndStatus(e == null
      ? "played — " + gSndDoc.duration.toStringAsFixed(2) + "s on slot 0"
      : "play: " + e.toString());
}

// --- save / load -------------------------------------------------------------

Future sndSave() async {
  var name = gSndNameField.stringValue().UTF8String().trim();
  if (!SoundDoc.validName(name)) {
    sndStatus("name must be a class name: capital letter, then letters/digits");
    return;
  }
  gSndDoc.name = name;
  var r = await ask('sndstore', gSndDoc.sheetSource());
  sndStatus(r == null ? "save timed out" : r.toString());
  sndRefreshLoadList();
}

Future sndRefreshLoadList() async {
  if (gSndLoadPopup == null) return;
  var r = await ask('sndlist', '');
  gSndLoadPopup.removeAllItems();
  gSndLoadPopup.addItemWithTitle("Load…");
  if (r is List && r.isNotEmpty) {
    for (var n in r) { gSndLoadPopup.addItemWithTitle(n.toString()); }
  } else {
    gSndLoadPopup.addItemWithTitle("(no sounds in the image)");
  }
}

Future sndLoadSheet(String name) async {
  var r = await ask('sndload', name);
  if (r is! List || r.length < 2) {
    sndStatus("load " + name + ": " + r.toString());
    return;
  }
  var params = <dynamic>[];
  for (var x in (r[1] as List)) { params.add(x); }
  if (!gSndDoc.fromParams(params)) {
    sndStatus("load " + name + ": bad params in the image class");
    return;
  }
  gSndDoc.name = r[0].toString();
  if (gSndNameField != null) gSndNameField.setStringValue(gSndDoc.name);
  sndSyncAll();
  sndStatus("loaded " + gSndDoc.name + " — Play to hear it");
}

// --- the scripted face -------------------------------------------------------

Future<String> soundEdVerb(String cmd, String arg) async {
  if (cmd == 'sounded') {
    soundEdShow(arg.trim());
    await sndRefreshLoadList();
    return "ok";
  }
  if (gSndWindow == null) return "ERR: sound editor not open (run sounded)";
  switch (cmd) {
    case 'soundedclose':
      gSndWindow.orderOut(null);
      return "ok";
    case 'sndnew':
      gSndDoc = new SoundDoc();
      gSndNameField.setStringValue(gSndDoc.name);
      sndSyncAll();
      return "ok";
    case 'sndstat':
      return (gSndOwnsPane ? "pane " : "nopane ") + gSndDoc.name + " " +
          gSndDoc.duration.toStringAsFixed(2) + "s osc " +
          gSndDoc.oscs.length.toString() + " seed " + gSndDoc.seed.toString();
    case 'sndparams':
      return gSndDoc.paramsList().join(' ');
    case 'sndset': {                       // sndset <field> <value>
      var p = arg.split(' ').where((x) => x.isNotEmpty).toList();
      if (p.length < 2) return "ERR: sndset <field> <value>";
      var v = double.parse(p[1], (_) => 0.0);
      var f = p[0];
      if (f == 'duration') gSndDoc.duration = v;
      else if (f == 'attack') gSndDoc.a = v;
      else if (f == 'decay') gSndDoc.d = v;
      else if (f == 'sustain') gSndDoc.s = v;
      else if (f == 'release') gSndDoc.r = v;
      else if (f == 'sweepstart') gSndDoc.sweepStart = v;
      else if (f == 'sweepend') gSndDoc.sweepEnd = v;
      else if (f == 'noise') gSndDoc.noiseMix = v;
      else if (f == 'distortion') gSndDoc.distortion = v;
      else if (f == 'echocount') gSndDoc.echoCount = v.round();
      else if (f == 'echodelay') gSndDoc.echoDelay = v;
      else if (f == 'echodecay') gSndDoc.echoDecay = v;
      else if (f == 'seed') gSndDoc.seed = v.round();
      else return "ERR: unknown field " + f;
      sndSyncAll();
      return "ok " + f;
    }
    case 'sndosc': {                       // sndosc <i> <wave|freq|amp|phase|pw> <v>
      var p = arg.split(' ').where((x) => x.isNotEmpty).toList();
      if (p.length < 3) return "ERR: sndosc <i> <prop> <v>";
      var i = int.parse(p[0], onError: (_) => -1);
      while (gSndDoc.oscs.length <= i && gSndDoc.oscs.length < 4) {
        gSndDoc.oscs.add(new SndOsc(0, 440.0, 0.5));
      }
      if (i < 0 || i >= gSndDoc.oscs.length) return "ERR: osc 0..3";
      var o = gSndDoc.oscs[i];
      var v = double.parse(p[2], (_) => 0.0);
      if (p[1] == 'wave') o.wave = v.round();
      else if (p[1] == 'freq') o.freq = v;
      else if (p[1] == 'amp') o.amp = v;
      else if (p[1] == 'phase') o.phase = v;
      else if (p[1] == 'pw') o.pw = v;
      else return "ERR: wave|freq|amp|phase|pw";
      sndSyncAll();
      return "ok osc " + i.toString();
    }
    case 'sndpreset': {
      var keep = gSndDoc.name;
      gSndDoc = SoundDoc.preset(arg.trim());
      gSndDoc.name = keep;
      sndSyncAll();
      return "ok " + arg.trim();
    }
    case 'sndplay':
      sndPlay();
      return gSndStatusLbl.stringValue().UTF8String();
    case 'sndsave': {
      if (arg.trim().isNotEmpty) gSndNameField.setStringValue(arg.trim());
      await sndSave();
      return gSndStatusLbl.stringValue().UTF8String();
    }
    case 'sndload': {
      await sndLoadSheet(arg.trim());
      return gSndStatusLbl.stringValue().UTF8String();
    }
    case 'sndlist': {
      var r = await ask('sndlist', '');
      if (r is List) return r.map((x) => x.toString()).join('\n');
      return r.toString();
    }
  }
  return "ERR: unknown " + cmd;
}
