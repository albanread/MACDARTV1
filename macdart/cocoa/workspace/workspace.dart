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

// Browser (Smalltalk-style, 4-pane) state.
Cocoa gCatTable, gClassTable, gVarTable, gMethodTable, gBrowserSrc, gStatus;
String gSelMemberSig;              // signature of the selected member (status line)
List gBrCats = <dynamic>[];        // Categories: "User App" + world libraries
List gBrClasses = <dynamic>[];     // classes in the selected category
List gClassMembers = <dynamic>[];  // all member records of the selected class
List gVarRecs = <dynamic>[];       // variables for the current side (i/c)
List gMethodRecs = <dynamic>[];    // methods for the current side (i/c)
String gBrSide = 'i';              // instance | class
String gBrMode = 'source';         // comment | definition | source
String gBrSelCat, gBrSelClass, gBrClassSrc, gBrClassComment, gSelMemberSrc;
bool gBrUserApp = true;            // is the selected category editable (user app)?
int gTab = 0;                      // the visible tab, for context-sensitive menu items
String gSelPane;                   // 'v' or 'm': which member pane owns the selection
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
  var focus = (i == 0) ? gEditor : (i == 1) ? gBrowserSrc
            : (i == 3) ? gFindField : (i == 4) ? gEdText
            : (i == 5) ? gDbgSrc : null;
  if (focus != null) gWindow.makeFirstResponder(focus);
  if (i == 1) openBrowser();
  if (i == 4) editorRefreshClasses();
  if (i == 5 && gLangIsolateId != null) dbgLoadSource();
  if (i == 7) appRefreshList();
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

void buildWindow() {
  gWindow = Cocoa.cls("NSWindow").alloc().initWithContentRect(
      [0.0, 0.0, 900.0, 640.0], styleMask: 15, backing: 2, defer: false);
  gWindow.setTitle("MACDART Workspace");
  // Below this the panes stop being usable, so don't let the window get there.
  gWindow.setContentMinSize([680.0, 480.0]);
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
  var bar = Cocoa.cls("NSView").alloc().initWithFrame([0.0, 596.0, 900.0, 44.0]);
  bar.setAutoresizingMask(kWidthSizable + kMinYMargin);   // pinned to the top edge
  gContent.addSubview(bar);
  texturedBox(bar, [0.0, 0.0, 900.0, 44.0], kWidthSizable + kHeightSizable);
  iconButton(bar, "Workspace", "texteditor", [8.0, 6.0, 36.0, 32.0], (s) => switchTab(0));
  iconButton(bar, "Browser", "hierarchy", [48.0, 6.0, 36.0, 32.0], (s) => switchTab(1));
  iconButton(bar, "Editor", "blankSheet", [88.0, 6.0, 36.0, 32.0], (s) => switchTab(4));
  alias("tab:Find", iconButton(bar, "Find", "open", [128.0, 6.0, 36.0, 32.0], (s) => switchTab(3)));
  iconButton(bar, "Debug", "goForward", [168.0, 6.0, 36.0, 32.0], (s) => switchTab(5));
  iconButton(bar, "Demos", "canvas", [208.0, 6.0, 36.0, 32.0], (s) => switchTab(6));
  iconButton(bar, "App", "home", [248.0, 6.0, 36.0, 32.0], (s) => switchTab(7));
  iconButton(bar, "Docs", "documentation", [288.0, 6.0, 36.0, 32.0], (s) => switchTab(2));
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

  // Browser tab: a Smalltalk-style class browser (World / User App).
  buildBrowserTab(addTab(gTabView, "browser", 868.0, 420.0));

  // Docs tab.
  var dc = addTab(gTabView, "docs", 868.0, 420.0);
  var docs = scrolledTextView(dc, [8.0, 8.0, 852.0, 404.0], false);
  docs.setString(_docsText);
  anchorScroll(docs, kWidthSizable + kHeightSizable);

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

  // Transcript dock (shared across tabs): docked to the bottom at a fixed
  // height, widening with the window.
  gTranscript = scrolledTextView(gContent, [16.0, 12.0, 868.0, 140.0], false);
  anchorScroll(gTranscript, kWidthSizable);
  // Clear sits with the transcript it clears, reachable from every tab.
  button(gContent, "Clear", [824.0, 154.0, 60.0, 18.0], (s) {
    gLog.clear(); gTranscript.setString(""); repaint();
  }).setAutoresizingMask(kMinXMargin);

  gTabView.selectTabViewItemAtIndex(0);
  updateMetrics();
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
  new Timer.periodic(const Duration(milliseconds: 250), (t) => pollVmStats());
}

void pollVmStats() {
  pollUiReload();   // the host leaves its reload result for us to report
  if (gDbgPaused) return;   // a poll now would just queue against the stopped isolate
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
  gTranscript.setString(gLog.join("\n"));
  gTranscript.scrollToEndOfDocument(null);
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

void buildBrowserTab(Cocoa br) {
  br.setAutoresizesSubviews(true);

  // Two nested split views, so every separator is a draggable splitter: the four
  // columns side by side over the source area.
  var vsplit = splitView([8.0, 8.0, 852.0, 404.0], false);
  var hsplit = splitView([0.0, 0.0, 852.0, 250.0], true);
  var cw = 213.0, ph = 250.0;

  // Categories — just a list.
  var catPane = browserPane(hsplit, cw, ph);
  gCatTable = tableIn(catPane, [0.0, 0.0, cw, ph]);

  // Classes — list over its own New/Remove.
  var classPane = browserPane(hsplit, cw, ph);
  gClassTable = tableIn(classPane, [0.0, kPaneBtnH, cw, ph - kPaneBtnH]);
  paneButtons(classPane, cw, "+ Class", 66.0, (s) => newClass(),
                             "− Class", 66.0, (s) => browserRemove(),
                             "New class", "Remove the selected class");

  // Variables — the instance/class toggle governs this column and Methods, so it
  // rides the top of this pane rather than floating in the tab.
  var varPane = browserPane(hsplit, cw, ph);
  gVarTable = tableIn(varPane, [0.0, kPaneBtnH, cw, ph - (2.0 * kPaneBtnH)]);
  var bi = button(varPane, "instance", [4.0, ph - 24.0, 72.0, 22.0], (s) => setSide('i'));
  var bc = button(varPane, "class", [78.0, ph - 24.0, 56.0, 22.0], (s) => setSide('c'));
  bi.setAutoresizingMask(kMinYMargin);   // a fixed-size pair, kept together at
  bc.setAutoresizingMask(kMinYMargin);   // the top-left of the column
  _paneBtnFont(bi); _paneBtnFont(bc);
  paneButtons(varPane, cw, "+ Variable", 82.0, (s) => newVariable(),
                           "− Variable", 82.0, (s) => removeMember('v'),
                           "New instance or class variable",
                           "Remove the selected variable");

  // Methods — list over its own New/Remove.
  var methPane = browserPane(hsplit, cw, ph);
  gMethodTable = tableIn(methPane, [0.0, kPaneBtnH, cw, ph - kPaneBtnH]);
  paneButtons(methPane, cw, "+ Method", 74.0, (s) => newMethod(),
                             "− Method", 74.0, (s) => removeMember('m'),
                             "New method", "Remove the selected member");

  // Lower half: the mode/action row pinned above the source view, both inside one
  // container so the horizontal splitter moves them together.
  var lower = Cocoa.cls("NSView").alloc().initWithFrame([0.0, 0.0, 852.0, 144.0]);
  lower.setAutoresizesSubviews(true);
  button(lower, "Comment", [0.0, 120.0, 84.0, 22.0], (s) => setMode('comment'));
  button(lower, "Definition", [86.0, 120.0, 92.0, 22.0], (s) => setMode('definition'));
  button(lower, "Source", [182.0, 120.0, 72.0, 22.0], (s) => setMode('source'));
  gStatus = label(lower, [262.0, 122.0, 380.0, 18.0]);
  alias("br:Accept", button(lower, "Accept", [650.0, 120.0, 68.0, 22.0], (s) => browserAccept()));
  button(lower, "Cancel", [722.0, 120.0, 64.0, 22.0], (s) => browserCancel());
  pinTop(<String>["Comment", "Definition", "Source"]);   // ride the top edge
  pinTop(<String>["Accept", "Cancel"], kMinXMargin);     // ...and the right edge
  gStatus.setAutoresizingMask(kMinYMargin + kWidthSizable);
  gBrowserSrc = scrolledTextView(lower, [0.0, 0.0, 852.0, 116.0], true);
  anchorScroll(gBrowserSrc, kWidthSizable + kHeightSizable);

  vsplit.addSubview(hsplit);
  vsplit.addSubview(lower);
  vsplit.adjustSubviews();
  hsplit.adjustSubviews();
  vsplit.setPosition(ph, ofDividerAtIndex: 0);
  hsplit.setPosition(cw, ofDividerAtIndex: 0);
  hsplit.setPosition(cw * 2, ofDividerAtIndex: 1);
  hsplit.setPosition(cw * 3, ofDividerAtIndex: 2);
  br.addSubview(vsplit);
  // A column narrower than this would let its own +/- buttons overlap, and the
  // source pane needs room to be worth editing in.
  setSplitMinSize(hsplit, 150.0);
  setSplitMinSize(vsplit, 90.0);
  var mf = _mono(13.0);
  if (!mf.isNil) gBrowserSrc.setFont(mf);

  gTargets.add(onTable(gCatTable, () => gBrCats.length, (r) => gBrCats[r].toString(), sel(selectCategory)));
  gTargets.add(onTable(gClassTable, () => gBrClasses.length, (r) => gBrClasses[r].toString(), sel(selectClass)));
  gTargets.add(onTable(gVarTable, () => gVarRecs.length, (r) => gVarRecs[r][2].toString(),
      sel((r) { gSelPane = 'v'; selectMemberRec(gVarRecs, r); })));
  gTargets.add(onTable(gMethodTable, () => gMethodRecs.length, (r) => gMethodRecs[r][2].toString(),
      sel((r) { gSelPane = 'm'; selectMemberRec(gMethodRecs, r); })));
  gTargets.add(onTextChange(gBrowserSrc, (s) => highlightView(gBrowserSrc)));
}

// Delete the selected member from its class, then re-accept the class — so the
// removal is live and saved, exactly like any other edit. [pane] is 'v' or 'm':
// each column removes only from ITS OWN list, so clicking − Method can never
// delete the variable you had selected in the pane next door.
void removeMember(String pane) {
  if (!gBrUserApp) { log("world classes are read-only"); return; }
  if (gBrSelClass == null || gBrClassSrc == null) { log("select a class first"); return; }
  if (gSelPane != pane) {
    log(pane == 'v' ? "select a variable first" : "select a method first");
    return;
  }
  if (gSelMemberSrc == null || gSelMemberSrc.isEmpty) {
    log("select a member to remove");
    return;
  }
  var gone = gSelMemberSig;
  var updated = _replaceOnce(gBrClassSrc, gSelMemberSrc, "");
  ask('acceptMany', [updated]).then((r) {
    if (r.toString().startsWith("ERR")) { log("Remove Method — " + r); return; }
    log("Removed " + gBrSelClass + " >> " + (gone != null ? gone : "member"));
    gBrClassSrc = updated;
    gSelMemberSrc = null; gSelMemberSig = null;
    gBrMode = 'definition';
    _reloadBrowserClass();
    updateSourcePane();
  });
}

void openBrowser() {
  ask('categories', '').then((r) {
    gBrCats = _dl(r);
    gCatTable.reloadData();
    repaint();
  });
}

void selectCategory(int row) {
  if (row < 0 || row >= gBrCats.length) return;
  gBrSelCat = gBrCats[row].toString();
  gBrUserApp = (gBrSelCat == 'User App');
  gBrSelClass = null;
  gClassMembers = <dynamic>[]; gVarRecs = <dynamic>[]; gMethodRecs = <dynamic>[];
  gBrowserSrc.setString("");
  ask(gBrUserApp ? 'classes' : 'worldclasses', gBrUserApp ? '' : gBrSelCat).then((r) {
    gBrClasses = _dl(r);
    gClassTable.reloadData(); gVarTable.reloadData(); gMethodTable.reloadData();
    repaint();
  });
}

void selectClass(int row) {
  if (row < 0 || row >= gBrClasses.length) return;
  gBrSelClass = gBrClasses[row].toString();
  gSelMemberSrc = null; gSelMemberSig = null;
  var membersCmd = gBrUserApp ? 'classmembers' : 'worldclassmembers';
  var membersArg = gBrUserApp ? gBrSelClass : (gBrSelCat + '|' + gBrSelClass);
  ask(membersCmd, membersArg).then((r) { gClassMembers = _dl(r); filterMembers(); repaint(); });
  if (gBrUserApp) {
    ask('classsrc', gBrSelClass).then((r) { gBrClassSrc = r.toString(); if (gBrMode == 'source') gBrMode = 'definition'; updateSourcePane(); });
    ask('classcomment', gBrSelClass).then((r) { gBrClassComment = r.toString(); });
  } else {
    // A world class has no source on disk; synthesize the WHOLE class from
    // mirrors so Definition shows fields + typed signatures (read-only).
    gBrClassSrc = "// " + gBrSelClass + "  —  loading definition…";
    gBrClassComment = "";
    gBrMode = 'definition';
    updateSourcePane();
    ask('worldclasssrc', gBrSelCat + '|' + gBrSelClass).then((r) {
      var s = r.toString();
      gBrClassSrc = s.length > 0 ? s : ("// " + gBrSelClass + "  —  world class (read-only)");
      if (gBrMode == 'definition') updateSourcePane();
    });
  }
}

void filterMembers() {
  gVarRecs = <dynamic>[]; gMethodRecs = <dynamic>[];
  for (var rec in gClassMembers) {
    if (rec[0] != gBrSide) continue;
    if (rec[1] == 'var') gVarRecs.add(rec); else gMethodRecs.add(rec);
  }
  gVarTable.reloadData(); gMethodTable.reloadData();
}

void setSide(String side) { gBrSide = side; filterMembers(); repaint(); }

void selectMemberRec(List recs, int row) {
  if (row < 0 || row >= recs.length) return;
  var src = recs[row][3].toString();
  gSelMemberSig = recs[row][2].toString();
  gSelMemberSrc = src.length > 0 ? src : gSelMemberSig;
  gBrMode = 'source';
  updateSourcePane();
}

void setMode(String mode) { gBrMode = mode; updateSourcePane(); }

void updateSourcePane() {
  var text;
  if (gBrMode == 'comment') text = gBrClassComment != null ? gBrClassComment : "";
  else if (gBrMode == 'definition') text = gBrClassSrc != null ? gBrClassSrc : "";
  else text = (gSelMemberSrc != null && gSelMemberSrc.length > 0) ? gSelMemberSrc : (gBrClassSrc != null ? gBrClassSrc : "");
  gBrowserSrc.setString(text);
  clearUndo();
  highlightView(gBrowserSrc);
  updateStatus();
  repaint();
}

// The "edit Class>>member" status line. Accept both hot-reloads live AND writes
// the SQLite image, so it persists for the next run — hence "live + saved".
void updateStatus() {
  if (gStatus == null) return;
  var t = "";
  var tag = gBrUserApp ? "   ·   Accept: live + saved" : "   (read-only)";
  if (gBrSelClass == null) {
    t = (gBrMode == 'definition') ? "new class" + tag : "";
  } else if (gBrMode == 'comment') {
    t = "comment: " + gBrSelClass + tag;
  } else if (gBrMode == 'definition') {
    t = "definition: " + gBrSelClass + tag;
  } else if (gSelMemberSig != null && gSelMemberSig.length > 0) {
    t = gBrSelClass + " >> " + gSelMemberSig + tag;
  } else {
    t = "new method in " + gBrSelClass + tag;
  }
  gStatus.setStringValue(t);
}

// Cancel: discard edits in the source pane, restoring the committed version of
// whatever is selected (member / class / comment).
void browserCancel() {
  updateSourcePane();
  log("cancelled — reverted");
}

String _replaceOnce(String s, String find, String repl) {
  var i = s.indexOf(find);
  return i < 0 ? s : (s.substring(0, i) + repl + s.substring(i + find.length));
}

void browserAccept() {
  if (!gBrUserApp) { log("world classes are read-only"); return; }
  var text = gBrowserSrc.string().UTF8String();
  if (gBrMode == 'comment') {
    if (gBrSelClass == null) return;
    var name = gBrSelClass;
    ask('setcomment', [name, text]).then((r) { gBrClassComment = text; log("✓ comment saved — " + name); });
    return;
  }
  // Source mode + a selected class: edit an existing member (replace) or add a
  // new one (insert before the class's closing brace).
  if (gBrMode == 'source' && gBrSelClass != null && gBrClassSrc != null) {
    var newClass = (gSelMemberSrc != null && gSelMemberSrc.length > 0)
        ? _replaceOnce(gBrClassSrc, gSelMemberSrc, text)
        : _insertMember(gBrClassSrc, text);
    guardedAccept(<String>[newClass], "Accept", () {
      gSelMemberSrc = text;
      ask('acceptMany', [newClass]).then((r) {
        log("✓ Accept — " + r);
        gBrClassSrc = newClass;
        _reloadBrowserClass();
      });
    });
    return;
  }
  // Definition mode / a brand-new class: accept the whole source. Select what we
  // just accepted, so "+ Method" (and the member panes) work straight away —
  // otherwise a freshly created class is left with nothing selected and the next
  // click on + Method just says "select a user class first".
  var decls = splitTopLevel(text);
  if (decls.isEmpty) { log("(nothing to accept)"); return; }
  var name = _classNameOf(decls[0]);
  guardedAccept(decls, "Accept", () {
  ask('acceptMany', decls).then((r) {
    log("✓ Accept — " + r);
    if (r.toString().startsWith("ERR")) return;   // reload cancelled: keep the edits
    if (name != null) {
      gBrSelCat = 'User App'; gBrUserApp = true;
      gBrSelClass = name;
      gBrClassSrc = text;
      gSelMemberSrc = null; gSelMemberSig = null;
    }
    _reloadClassList();
    updateStatus();
  });
  });
}

void _reloadBrowserClass() {
  updateMetrics();
  if (gBrSelClass == null || !gBrUserApp) return;
  ask('classmembers', gBrSelClass).then((r) { gClassMembers = _dl(r); filterMembers(); repaint(); });
  ask('classsrc', gBrSelClass).then((r) { gBrClassSrc = r.toString(); repaint(); });
}

void _reloadClassList() {
  updateMetrics();
  if (gBrSelCat == null) { gBrSelCat = 'User App'; gBrUserApp = true; }
  ask(gBrUserApp ? 'classes' : 'worldclasses', gBrUserApp ? '' : gBrSelCat).then((r) {
    gBrClasses = _dl(r);
    gClassTable.reloadData();
    _showClassSelection();
    repaint();
  });
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

// Mirror gBrSelClass into the Classes pane, so the highlighted row always agrees
// with what Accept / + Method act on. Reloading a table otherwise leaves the OLD
// row index highlighted, which is how a click could look like it selected one
// class while the browser was acting on another.
void _showClassSelection() {
  if (gBrSelClass == null) { gClassTable.deselectAll(null); return; }
  for (var i = 0; i < gBrClasses.length; i++) {
    if (gBrClasses[i].toString() != gBrSelClass) continue;
    gClassTable.selectRowIndexes(
        Cocoa.cls("NSIndexSet").indexSetWithIndex(i), byExtendingSelection: false);
    gClassTable.scrollRowToVisible(i);
    return;
  }
  gClassTable.deselectAll(null);   // it isn't in this list any more
}

// Insert a new member just before the class's closing brace.
String _insertMember(String classSrc, String member) {
  var i = classSrc.lastIndexOf('}');
  if (i < 0) return classSrc + "\n" + member.trim();
  return classSrc.substring(0, i) + "  " + member.trim() + "\n" + classSrc.substring(i);
}

// + New Class: drop a class template into the Definition pane; edit + Accept creates it.
void newClass() {
  gBrUserApp = true;
  gBrSelCat = 'User App';   // a new class is always the user app's, whatever was browsed
  gBrSelClass = null; gSelMemberSrc = null; gSelMemberSig = null;
  gClassTable.deselectAll(null);
  gClassMembers = <dynamic>[]; gVarRecs = <dynamic>[]; gMethodRecs = <dynamic>[];
  gVarTable.reloadData(); gMethodTable.reloadData();
  gBrMode = 'definition';
  gBrClassSrc = "class NewClass {\n  \n}";
  gBrowserSrc.setString(gBrClassSrc);
  highlightView(gBrowserSrc);
  updateStatus();
  repaint();
  log("+ New Class — rename it, add members, then Accept");
}

// + New Method: drop a method template into the Source pane; edit + Accept adds it.
// Drop a variable template into the source pane; Accept inserts it into the
// class. Which side it lands on follows the instance/class toggle.
void newVariable() {
  if (!gBrUserApp) {
    log("'" + gBrSelCat + "' is a world library (read-only)");
    return;
  }
  if (gBrSelClass == null) { log("select a class in the Classes pane first"); return; }
  gSelMemberSrc = null; gSelMemberSig = null;
  gBrMode = 'source';
  gBrowserSrc.setString(gBrSide == 'c' ? "static int newVar = 0;" : "int newVar = 0;");
  highlightView(gBrowserSrc);
  updateStatus();
  repaint();
  log("+ New " + (gBrSide == 'c' ? "class" : "instance") + " variable in " +
      gBrSelClass + " — edit and Accept");
}

void newMethod() {
  if (!gBrUserApp) {
    log("'" + gBrSelCat + "' is a world library (read-only) — pick User App to add methods");
    return;
  }
  if (gBrSelClass == null) {
    log("select a class in the Classes pane first (a new class needs Accept before you can add methods)");
    return;
  }
  gSelMemberSrc = null; gSelMemberSig = null;   // new member — nothing to replace
  gBrMode = 'source';
  var tmpl = (gBrSide == 'c') ? "static newMethod() {\n  \n}" : "newMethod() {\n  \n}";
  gBrowserSrc.setString(tmpl);
  highlightView(gBrowserSrc);
  updateStatus();
  repaint();
  log("+ New Method in " + gBrSelClass + " — edit and Accept");
}

void browserRemove() {
  if (!gBrUserApp || gBrSelClass == null) { log("nothing to remove"); return; }
  var name = gBrSelClass;
  ask('remove', name).then((r) {
    log("Browser — " + r);
    gBrSelClass = null; gSelMemberSrc = null; gBrowserSrc.setString("");
    selectCategory(0);
  });
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
  return member.length > 0 ? (cls + "  >>  " + member) : cls;
}

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

// Click a result → open the Browser on that class.
void findNavigate(int row) {
  if (row < 0 || row >= gFindResults.length) return;
  var cls = gFindResults[row][0].toString();
  gTabView.selectTabViewItemAtIndex(1);   // Browser (no reset)
  gBrSelCat = 'User App'; gBrUserApp = true;
  ask('classes', '').then((r) {
    gBrClasses = _dl(r); gClassTable.reloadData();
    for (var i = 0; i < gBrClasses.length; i++) {
      if (gBrClasses[i].toString() == cls) { selectClass(i); break; }
    }
    updateMetrics(); repaint();
  });
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

void highlightView(Cocoa tv) {
  if (tv == null) return;
  applySpans(tv, lexDart(tv.string().UTF8String()));
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
  var decls = splitTopLevel(gEditor.string().UTF8String());
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
  if (gTab == 1) { browserAccept(); return; }
  acceptEditor();
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

  // Demos: standalone programs from demos/ beside the UI source, each spawned
  // into its own isolate, drawing on the Demos tab's canvas through this
  // isolate. The menu IS the folder — drop a file in, Rescan, run it.
  var demos = subMenu(mainMenu, "Demos");
  var found = scanDemos();
  if (found.isEmpty) {
    menuItem(demos, "(no demos found in demos/)", "", (s) {});
  }
  for (var d in found) {
    var title = d[0], path = d[1];
    menuItem(demos, title, "", (s) => runDemoAt(title, path));
  }
  menuSep(demos);
  menuItem(demos, "Stop Demo", ".", (s) => stopDemo("stopped"));
  menuItem(demos, "Rescan Demos Folder", "", (s) {
    buildMenu();   // setMainMenu: replaces the bar, so this rescans cleanly
    log("demos rescanned — " + scanDemos().length.toString() + " found");
  });

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
  menuItem(view, "Clear Transcript", "k", (s) {
    gLog.clear(); gTranscript.setString(""); repaint();
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

Future ask(String cmd, var arg) async {   // arg/result may be a String or a List
  if (gLang == null) return "ERR: language isolate restarting…";
  // A message sent now would QUEUE against the stopped isolate, invisibly, and
  // all fire the moment you press Continue — and with the watchdog rightly
  // suspended while paused, nothing would ever time it out. Refuse loudly.
  if (gDbgPaused) {
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
  });
  var errPort = new ReceivePort();
  var exitPort = new ReceivePort();
  gLangIsolate = await Isolate.spawnUri(
      Uri.parse('file://' + gScratch), <String>[gScratch, gDbPath], gFromLang.sendPort,
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
  guiEvent('languageRestarted', <String, String>{'why': why});
  if (gLangIsolateId != null) {          // the debugger was attached: re-target
    if (await vmsResolveTarget()) {
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
    case 'dbgattach': await dbgAttach(); return gLangIsolateId == null ? "ERR: not attached" : gLangIsolateId;
    case 'dbgbreak': {
      if (gLangIsolateId == null) return "ERR: attach first";
      var ln = int.parse(arg.trim(), onError: (_) => 0);
      var r = await vmsCall('addBreakpoint', <String, dynamic>{
          'isolateId': gLangIsolateId, 'scriptId': gLangScriptId, 'line': ln});
      if (r == null) return "ERR: no breakpoint at line " + ln.toString();
      var anchor = _anchorFor(_scratchLines(), ln);
      if (anchor == null) return "ERR: line " + ln.toString() + " is outside any declaration";
      gDbgBreaks.add(new DbgBreak(anchor[0], anchor[1], ln, r['id']));
      dbgLoadSource();
      return "breakpoint in " + anchor[0] + " +" + anchor[1].toString() +
             " (line " + ln.toString() + ") resolved=" + r['resolved'].toString();
    }
    case 'dbgvars': {
      var o = <String>[];
      for (var v in gDbgVars) o.add(v[0].toString() + "=" + v[1].toString());
      return o.isEmpty ? "(none)" : o.join(", ");
    }
    case 'dbgframe': { dbgSelectFrame(int.parse(arg.trim(), onError: (_) => 0)); return "ok"; }
    case 'dbgeval': { await dbgEval(arg); return gDbgStatusLbl.stringValue().UTF8String(); }
    case 'dbgsource': return gDbgSrc == null ? "" : gDbgSrc.string().UTF8String();
    case 'dbgstate': return gDbgPaused
        ? ("paused, " + gDbgFrames.length.toString() + " frames, top=" +
           (gDbgFrames.isEmpty ? "?" : gDbgFrames[0][0].toString()))
        : "running";
    case 'dbgstep': await dbgResume(arg.trim().isEmpty ? null : arg.trim()); return "ok";
    case 'dbgclear': await dbgClearBreaks(); return "ok";
    case 'dbghold': debugHold(); return "held (watchdog paused), depth " + gDebugHold.toString();
    case 'dbgrelease': debugRelease(); return "released, depth " + gDebugHold.toString();
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
    case 'frames': {
      var o = <String>[];
      o.add("content   " + gContent.bounds().toString());
      o.add("tabview   " + gTabView.frame().toString());
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
          await runDemoAt(d[0], d[1]);
          return gDemoTitle == null ? "ERR: demo failed to start" : "started " + d[0];
        }
      }
      return "ERR: no demo matching " + arg;
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
    case 'appstop': await appStop(); return "ok";
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
      return "ok";
    }
    case 'appget': {
      var s = appValueOf(arg.trim());
      return s == null ? "ERR: no widget " + arg.trim() : s;
    }
    case 'demostop': stopDemo("stopped"); return "ok";
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
    case 'gpstat': return gpStat().toString();
    case 'gpfull': gpFullscreen(arg.trim() == '1'); return "ok";
    case 'tab': switchTab(int.parse(arg)); return "ok";
    case 'brcat': selectCategory(int.parse(arg)); return "ok";
    case 'brclass': selectClass(int.parse(arg)); return "ok";
    // Mirror the real click path, which tags the owning pane (see gSelPane) —
    // a verb that skipped that would make the harness lie about what a user does.
    case 'brvar': gSelPane = 'v'; selectMemberRec(gVarRecs, int.parse(arg)); return "ok";
    case 'brmethod': gSelPane = 'm'; selectMemberRec(gMethodRecs, int.parse(arg)); return "ok";
    case 'brside': setSide(arg); return "ok";
    case 'brmode': setMode(arg); return "ok";
    case 'brnewclass': newClass(); return "ok";
    case 'brnewmethod': newMethod(); return "ok";
    case 'brsettext': gBrowserSrc.setString(arg.replaceAll('\\n', '\n')); highlightView(gBrowserSrc); return "ok";
    case 'braccept': browserAccept(); return "ok";
    case 'brcancel': browserCancel(); return "ok";
    case 'findset': gFindField.setStringValue(arg); return "ok";
    case 'findrun': runFind(arg.length > 0 ? arg : 'find'); return "ok";
    case 'findsel': findNavigate(int.parse(arg)); return "ok";
    case 'edsettext': edSetText(arg.replaceAll('\\n', '\n')); return "ok";
    case 'edtext': return edText();
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
  var decls = splitTopLevel(edText());
  if (decls.isEmpty) { log("editor: nothing to save"); return; }
  guardedAccept(decls, "Save to Image", () {
  ask('acceptMany', decls).then((r) {
    log("✓ Save to Image — " + r);
    if (!r.toString().startsWith("ERR")) {
      gEdClass = _classNameOf(decls[0]);
      edStatus((gEdClass != null ? gEdClass : "(saved)") + "  ·  live + saved in the image");
      editorRefreshClasses();
      _reloadClassList();
    }
  });
  });
}

// Editor -> live isolate ONLY. Try a class in the running world without
// committing it: a respawn (or the next launch) re-reads the image and it is gone.
void editorAddToWorld() {
  var decls = splitTopLevel(edText());
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
    var decls = splitTopLevel(src);
    if (decls.isEmpty) { log("editor: " + path + " has no top-level declarations"); return; }
    gEdFile = path; gEdClass = null;
    edSetText(src);
    guardedAccept(decls, "File In", () {
    ask('acceptMany', decls).then((r) {
      log("✓ File In (" + decls.length.toString() + " declaration(s)) — " + r);
      edStatus(path + "  ·  filed in: " + decls.length.toString() + " declaration(s) live + saved");
      editorRefreshClasses();
      _reloadClassList();
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
      var c = gVmsPending.remove(d['id'] is int ? d['id'] : int.parse(d['id'].toString()));
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
  for (var iso in vm['isolates']) {
    if (!iso['name'].toString().contains('macdart_ws_lang')) continue;
    gLangIsolateId = iso['id'];
    var info = await vmsCall('getIsolate', <String, dynamic>{'isolateId': gLangIsolateId});
    if (info == null || info['rootLib'] == null) return false;
    var lib = await vmsCall('getObject', <String, dynamic>{
      'isolateId': gLangIsolateId, 'objectId': info['rootLib']['id']});
    if (lib == null || lib['scripts'] == null || lib['scripts'].isEmpty) return false;
    gLangScriptId = lib['scripts'][0]['id'];
    return true;
  }
  dbgStatus("debugger: no language isolate found");
  return false;
}

// A breakpoint remembered by WHERE IT IS IN YOUR CODE, not by a line number in
// the generated file. The language isolate's scratch file is rewritten from the
// image on every accept and at every boot, so a raw line number goes stale the
// moment you edit anything — mid-test a breakpoint in fact() silently moved from
// line 53 to 47 and simply stopped being hit. Anchoring to
// (declaration, offset within it) survives that: after each reload the anchor is
// mapped to the new line and re-armed.
class DbgBreak {
  String decl;      // the declaration it lives in
  int offset;       // lines from that declaration's first line
  int line;         // where it currently sits in the scratch file
  String vmId;      // the vm-service's id, so it can be removed
  DbgBreak(this.decl, this.offset, this.line, this.vmId);
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
List gDbgFrames = <dynamic>[];        // [functionName, frameJson]
List gDbgVars = <dynamic>[];          // [name, renderedValue] for the chosen frame
int gDbgFrame = 0;                    // which frame locals and eval apply to
// (breakpoints are anchored to a declaration — see DbgBreak below)
bool gDbgPaused = false;
String gDbgScratch;                   // the scratch path, for the source pane

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
  button(db, "Attach", [8.0, 392.0, 72.0, 24.0], (s) => dbgAttach());
  button(db, "Pause", [84.0, 392.0, 62.0, 24.0], (s) => dbgPause());
  button(db, "Continue", [150.0, 392.0, 80.0, 24.0], (s) => dbgResume(null));
  button(db, "Step Over", [234.0, 392.0, 84.0, 24.0], (s) => dbgResume('Over'));
  button(db, "Step In", [322.0, 392.0, 72.0, 24.0], (s) => dbgResume('Into'));
  button(db, "Step Out", [398.0, 392.0, 78.0, 24.0], (s) => dbgResume('Out'));
  button(db, "Break Here", [480.0, 392.0, 92.0, 24.0], (s) => dbgToggleBreak());
  button(db, "Clear Breaks", [576.0, 392.0, 100.0, 24.0], (s) => dbgClearBreaks());
  pinTop(<String>["Attach", "Pause", "Continue", "Step Over", "Step In",
                  "Step Out", "Break Here", "Clear Breaks"]);

  gDbgStatusLbl = label(db, [8.0, 372.0, 852.0, 16.0]);
  gDbgStatusLbl.setAutoresizingMask(kMinYMargin + kWidthSizable);

  gDbgEvalField = Cocoa.cls("NSTextField").alloc().initWithFrame([8.0, 344.0, 700.0, 24.0]);
  gDbgEvalField.setStringValue("");
  var ef = _mono(12.0); if (!ef.isNil) gDbgEvalField.setFont(ef);
  db.addSubview(gDbgEvalField);
  gDbgEvalField.setAutoresizingMask(kMinYMargin + kWidthSizable);
  button(db, "Evaluate", [714.0, 343.0, 84.0, 26.0], (s) => dbgEval());
  pinTop(<String>["Evaluate"], kMinXMargin);

  // source on the left, stack on the right
  var split = splitView([8.0, 8.0, 852.0, 330.0], true);
  var srcPane = browserPane(split, 560.0, 330.0);
  gDbgSrc = scrolledTextView(srcPane, [0.0, 0.0, 560.0, 330.0], false);
  var mf = _mono(12.0);
  if (!mf.isNil) gDbgSrc.setFont(mf);
  anchorScroll(gDbgSrc, kWidthSizable + kHeightSizable);

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

Future dbgAttach() async {
  if (!await vmsConnect()) return;
  if (!await vmsResolveTarget()) return;
  await vmsCall('streamListen', <String, dynamic>{'streamId': 'Debug'});
  gDbgScratch = gScratch;
  dbgLoadSource();
  dbgStatus("attached to the language isolate — click a line, then Break Here");
  log("debugger attached (" + gLangIsolateId + ")");
}

// The source the VM sees: the scratch file, with the VM's own line numbers.
void dbgLoadSource() {
  if (gDbgScratch == null) return;
  String src;
  try { src = new File(gDbgScratch).readAsStringSync(); }
  catch (e) { dbgStatus("cannot read " + gDbgScratch); return; }
  var lines = src.split('\n');
  var out = new StringBuffer();
  for (var i = 0; i < lines.length; i++) {
    var n = (i + 1).toString();
    while (n.length < 4) n = " " + n;
    out.write(_dbgHasBreakAt(i + 1) ? "*" : " ");
    out.write(n);
    out.write("  ");
    out.write(lines[i]);
    out.write("\n");
  }
  gDbgSrc.setString(out.toString());
  repaint();
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

Future dbgToggleBreak() async {
  if (gLangIsolateId == null) { dbgStatus("attach first"); return; }
  var line = dbgCaretLine();
  var r = await vmsCall('addBreakpoint', <String, dynamic>{
    'isolateId': gLangIsolateId, 'scriptId': gLangScriptId, 'line': line});
  if (r == null) {
    dbgStatus("line " + line.toString() + ": no breakpoint there "
              "(a one-line class has no body line to stop on — Format it)");
    return;
  }
  var anchor = _anchorFor(_scratchLines(), line);
  if (anchor == null) {
    dbgStatus("line " + line.toString() + " is outside any declaration");
    return;
  }
  gDbgBreaks.add(new DbgBreak(anchor[0], anchor[1], line, r['id']));
  dbgLoadSource();
  dbgStatus("breakpoint in " + anchor[0] + " +" + anchor[1].toString() +
            " (line " + line.toString() + ")" +
            (r['resolved'] == true ? " resolved" : " pending"));
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
    if (!gDbgPaused) { gDbgPaused = true; debugHold(); }
    _tripPauseGates();
    dbgOnPaused(kind);
  } else if (kind == 'Resume') {
    if (gDbgPaused) { gDbgPaused = false; debugRelease(); }
    dbgStatus("running");
  }
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

Future dbgOnPaused(String kind) async {
  var stk = await vmsCall('getStack', <String, dynamic>{'isolateId': gLangIsolateId});
  gDbgFrames = <dynamic>[];
  if (stk != null && stk['frames'] != null) {
    for (var f in stk['frames']) {
      var name = (f['function'] != null) ? f['function']['name'].toString() : '?';
      gDbgFrames.add(<dynamic>[name, f]);
    }
  }
  gDbgStack.reloadData();
  gDbgFrame = 0;
  dbgShowVars(0);
  switchTab(5);
  dbgStatus(kind + " — " + gDbgFrames.length.toString() +
            " frames; the window stays live because this is a different isolate");
  log("debugger: " + kind);
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
Future dbgEval([String expr]) async {
  if (gLangIsolateId == null) { dbgStatus("attach first"); return; }
  if (!gDbgPaused) { dbgStatus("evaluate needs the isolate stopped"); return; }
  var src = expr != null ? expr : gDbgEvalField.stringValue().UTF8String();
  if (src.trim().isEmpty) return;
  var r = await vmsCall('evaluateInFrame', <String, dynamic>{
    'isolateId': gLangIsolateId, 'frameIndex': gDbgFrame, 'expression': src});
  if (r == null) { dbgStatus("evaluate failed"); return; }
  // A failed evaluate carries the VM's whole stack trace; the first line is the
  // part that says what went wrong.
  var shown = (r['kind'] == 'Error' || r['message'] != null)
      ? ("error: " + _firstLine((r['message'] != null ? r['message'] : r).toString()))
      : dbgValue(r);
  dbgStatus(src + "  =>  " + shown);
  log("debug eval: " + src + " => " + shown);
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
  var o = cmds[0];
  int gi(int i, int dflt) =>
      (o.length > i && o[i] is num) ? (o[i] as num).toInt() : dflt;
  var w = gi(1, 424), h = gi(2, 240);
  gGpView = gpOpen(w, h, gi(3, w), gi(4, h));
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
  pinTop(<String>["Stop", "Full"]);
  gDemoStatusLbl = label(dm, [140.0, 396.0, 720.0, 16.0]);
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
void renderDemo(List cmds) {
  if (gDemoImage == null) return;
  autoreleasePool(() {
    gDemoImage.lockFocus();
    for (var c in cmds) {
      if (c is! List || c.isEmpty) continue;
      var op = c[0];
      if (op == 'clear') {
        _demoColor(c[1], c[2], c[3]).setFill();
        Cocoa.cls("NSBezierPath").fillRect([0.0, 0.0, kDemoW, kDemoH]);
      } else if (op == 'rect' || op == 'oval') {
        var rect = [_d(c[1]), kDemoH - _d(c[2]) - _d(c[4]), _d(c[3]), _d(c[4])];
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
            [_d(c[1]), kDemoH - _d(c[2])],
            toPoint: [_d(c[3]), kDemoH - _d(c[4])]);
      } else if (op == 'text') {
        var sz = _d(c[4]);
        var attrs = Cocoa.cls("NSMutableDictionary").dictionary();
        var f = _mono(sz);
        if (!f.isNil) attrs.setObject(f, forKey: "NSFont");
        attrs.setObject(_demoColor(c[5], c[6], c[7]), forKey: "NSColor");
        Cocoa.cls("NSString").stringWithString(c[3].toString())
            .drawAtPoint([_d(c[1]), kDemoH - _d(c[2]) - sz * 1.25],
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
        img.drawInRect([_d(c[1]), kDemoH - _d(c[2]) - dh, dw, dh]);
      }
    }
    gDemoImage.unlockFocus();
  });
  // Off the Demos tab, keep rendering (the demo is live) but skip the window
  // redisplay — no point repainting pixels nobody can see at 30fps.
  if (gTab == 6 && gDemoView != null) {
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
/// `// Demo:` header, so the menu reads like a playbill, not a directory.
List<List<String>> scanDemos() {
  var out = <List<String>>[];
  try {
    var files = <String>[];
    for (var f in new Directory(demosDir()).listSync()) {
      if (f.path.endsWith('.dart')) files.add(f.path);
    }
    files.sort();
    for (var path in files) {
      var title;
      try {
        for (var line in new File(path).readAsLinesSync().take(5)) {
          // The marker must OPEN the line: a file that merely mentions it in
          // prose (pixmap.dart's header does) is not declaring itself a demo.
          if (line.startsWith('// Demo:')) { title = line.substring(8).trim(); break; }
        }
      } catch (e) {}
      // No header, no listing: files like pixmap.dart are LIBRARIES the demos
      // import, not programs to spawn.
      if (title == null) continue;
      out.add(<String>[title, path]);
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
  switchTab(6);
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
  pinTop(<String>["Run", "Stop App"]);
  gAppTitleLbl = label(ap, [392.0, 394.0, 200.0, 16.0]);
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

/// Top-left [x,y,w,h] in the surface -> an AppKit frame in the container.
List _appFrame(var f) {
  if (f is! List || f.length < 4) return [0.0, 0.0, 80.0, 20.0];
  var x = (f[0] as num).toDouble(), y = (f[1] as num).toDouble();
  var w = (f[2] as num).toDouble(), h = (f[3] as num).toDouble();
  return [x, appPaneHeight() - y - h, w, h];
}

// macOS keeps the legacy NSTextAlignment order: left 0, right 1, center 2.
int _appAlign(var a) {
  var s = (a == null) ? 'left' : a.toString();
  if (s == 'right') return 1;
  if (s == 'center') return 2;
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
    else if (op == 'remove') appRemove(c[1].toString());
    else if (op == 'title') {
      if (gAppTitleLbl != null) gAppTitleLbl.setStringValue(c[1].toString());
    } else if (op == 'focus') {
      var v = gAppViews[c[1].toString()];
      if (v != null) gWindow.makeFirstResponder(v);
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
}

void appAdd(String kind, String id, Map p) {
  appRemove(id);                       // rebuilding over an id replaces it
  var frame = _appFrame(p['frame']);
  var v;
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
  } else {                             // 'label', and anything unknown
    kind = 'label';
    v = Cocoa.cls("NSTextField").alloc().initWithFrame(frame);
    v.setStringValue(p['text'] == null ? '' : p['text'].toString());
    v.setAlignment(_appAlign(p['align']));
    v.setBezeled(false); v.setEditable(false); v.setDrawsBackground(false);
  }
  gAppPane.addSubview(v);
  gAppViews[id] = v;
  gAppKinds[id] = kind;
  gAppOrder.add(id);
}

void appSet(String id, Map p) {
  var v = gAppViews[id];
  if (v == null) return;
  if (p['text'] != null) v.setStringValue(p['text'].toString());
  if (p['title'] != null) v.setTitle(p['title'].toString());
  if (p['enabled'] != null) v.setEnabled(p['enabled'] == true);
}

void appRemove(String id) {
  var v = gAppViews.remove(id);
  if (v != null) v.removeFromSuperview();
  gAppKinds.remove(id);
  gAppOrder.remove(id);
}

/// A widget's current value, as the user would read it.
String appValueOf(String id) {
  var v = gAppViews[id];
  if (v == null) return null;
  var kind = gAppKinds[id];
  if (kind == 'button') return v.title().UTF8String();
  return v.stringValue().UTF8String();
}

/// Deliver an event to the app. Deliberately an ordinary ask(): that inherits
/// the watchdog (a runaway handler is killed, not left hanging), the debugger's
/// pause guard, and generation checking.
void appFire(String id, String kind, String value) {
  if (gAppName == null) return;
  ask('appevent', <dynamic>[id, kind, value]).then((r) {
    var s = r.toString();
    if (s.startsWith('ERR')) appStatus(s);
  });
}

Future appRun(String name) async {
  switchTab(7);
  appStatus("starting " + name + "…");
  var r = await ask('apprun', <dynamic>[name, kAppW, appPaneHeight()]);
  var s = r.toString();
  if (s.startsWith('ERR')) {
    gAppName = null;
    appStatus(s);
    log("✗ app — " + s);
    return;
  }
  gAppName = name;
  appStatus("running " + name);
  log("app: " + name);
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
      if (f.path.endsWith('.dart')) files.add(f.path);
    }
    files.sort();
    for (var path in files) {
      var title;
      try {
        for (var line in new File(path).readAsLinesSync().take(5)) {
          if (line.startsWith('// App:')) { title = line.substring(7).trim(); break; }
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
  var src;
  try { src = new File(path).readAsStringSync(); }
  catch (e) { log("✗ app — cannot read " + path); return; }
  var decls = splitTopLevel(src);
  if (decls.isEmpty) { log("✗ app — " + path + " has no declarations"); return; }
  var name;
  for (var d in decls) {
    var n = _classNameOf(d.toString());
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
  gCatTable = null; gClassTable = null; gVarTable = null; gMethodTable = null;
  gBrowserSrc = null; gStatus = null; gEdText = null; gEdPicker = null;
  gEdStatus = null; gFindField = null; gFindTable = null; gEditor = null;
  gTranscript = null; gTabView = null;
  // The demo VIEW dies with the tree; the demo IMAGE and its isolate live on —
  // buildDemosTab reattaches them, so a running demo just keeps drawing.
  gDemoView = null; gDemoStatusLbl = null;
  // Same for the app: its instance is in the language isolate and untouched by
  // this. The widgets die here and are replayed from the retained spec below.
  gAppPane = null; gAppPicker = null; gAppStatusLbl = null; gAppTitleLbl = null;
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
  if (bin == null) return new CheckResult(true, "", 0);   // no checker: don't block work

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
      ctx.write("\n");
      ctx.write(d[1].toString());
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
Future<CheckResult> checkDecls(List decls) async {
  var names = <String>[];
  for (var d in decls) {
    var n = _classNameOf(d.toString());
    if (n != null) names.add(n);
  }
  return await compileCheck(decls.join("\n\n"), replacing: names);
}

Future guardedAccept(List decls, String what, void commit()) async {
  if (gDbgPaused) {
    log("✗ " + what + " refused — the language isolate is stopped in the debugger; Continue first");
    return;
  }
  var r = await checkDecls(decls);
  if (!r.ok) {
    log("✗ " + what + " refused — " + r.message);
    if (r.line > 0) _selectLine(r.line);
    return;
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
String _analyzeBinary() {
  var dir = new File(Platform.resolvedExecutable).parent.path;
  for (var c in <String>[dir + "/../build-release/dart", dir + "/dart"]) {
    if (new File(c).existsSync()) return c;
  }
  return null;
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
  for (var d in splitTopLevel(src)) {
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
  Docs       this page.
  Debugger   breakpoints, stepping and evaluation in the language isolate.
  Demos      a canvas that demo programs draw on. Each demo in demos/ runs in
             its OWN isolate (some spawn workers of their own) and sends draw
             commands here - only this UI isolate ever touches AppKit. Shapes
             go as ['rect'|'oval'|'line'|'text', ...] lists; whole images go as
             a Pixmap (demos/pixmap.dart), which crosses as ONE blit command.
             Only files with a "// Demo:" header line are listed in the menu.

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
  View   the tabs, and Clear Transcript (Cmd-K).

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

ARCHITECTURE
  Two isolates: this UI isolate (pinned to the AppKit thread, builds the views)
  and a language isolate (runs your code, holds state), talking over SendPort.
  ONE control plane: the VM's service WebSocket (ws://127.0.0.1:8181/ws)
  carries Observatory introspection, GUI control (the ext.dartui.send
  extension — macdart/tcl/dartui.tcl), and pushed events.
''';

main() async {
  gAssets = Platform.script.resolve('assets/').toFilePath();   // icons + texture
  initEvents();     // AppKit callbacks re-enter through this port — see [defer]
  buildWindow();

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
  startMetrics();   // ~4 Hz VM counters in the toolbar
  snapshotLastGood();

  // ONE listener: the vm-service. Control rides it as the ext.dartui.send
  // extension (macdart/tcl/dartui.tcl), introspection is the Observatory
  // protocol, events are its streams. The old line socket (7644) and the framed
  // channel (7645) are gone — three listeners was the opposite of unified.
  registerServiceExtensions();
  // The window and the control plane are up. Until this point the host treats a
  // UI isolate error as fatal, so a workspace that failed to load exits instead
  // of sitting there as a process with no window.
  wsUiReady();
}
