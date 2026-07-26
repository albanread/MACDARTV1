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
    if (body != null) body();
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
            : (i == 3) ? gFindField : (i == 4) ? gEdText : null;
  if (focus != null) gWindow.makeFirstResponder(focus);
  if (i == 1) openBrowser();
  if (i == 4) editorRefreshClasses();
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
  buildMenu();
  gWindow = Cocoa.cls("NSWindow").alloc().initWithContentRect(
      [0.0, 0.0, 900.0, 640.0], styleMask: 15, backing: 2, defer: false);
  gWindow.setTitle("MACDART Workspace");
  gContent = gWindow.contentView();

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
  iconButton(bar, "Docs", "documentation", [168.0, 6.0, 36.0, 32.0], (s) => switchTab(2));
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

  // Transcript dock (shared across tabs): docked to the bottom at a fixed
  // height, widening with the window.
  gTranscript = scrolledTextView(gContent, [16.0, 12.0, 868.0, 140.0], false);
  anchorScroll(gTranscript, kWidthSizable);
  // Clear sits with the transcript it clears, reachable from every tab.
  button(gContent, "Clear", [824.0, 154.0, 60.0, 18.0], (s) {
    gLog.clear(); gTranscript.setString(""); repaint();
  }).setAutoresizingMask(kMinXMargin);

  // Below this the panes stop being usable, so don't let the window get there.
  gWindow.setContentMinSize([680.0, 480.0]);

  gTabView.selectTabViewItemAtIndex(0);
  log("workspace ready — Workspace / Browser / Docs");
  updateMetrics();

  gWindow.center();
  gWindow.makeKeyAndOrderFront(null);
  Cocoa.cls("NSApplication").sharedApplication().activateIgnoringOtherApps(true);
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

// A New/Remove pair across the bottom of a column. The Remove button gets the
// larger share, since "Remove Method" is the longest label here and a truncated
// button is worse than an uneven split.
void paneButtons(Cocoa pane, double w, String leftTitle, CocoaAction leftFn,
                 String rightTitle, CocoaAction rightFn) {
  var lw = (w * 0.42) - 6.0, rw = (w * 0.58) - 6.0;
  var l = button(pane, leftTitle, [4.0, 3.0, lw, 22.0], leftFn);
  var r = button(pane, rightTitle, [(w * 0.42) + 2.0, 3.0, rw, 22.0], rightFn);
  l.setAutoresizingMask(kWidthSizable);
  r.setAutoresizingMask(kWidthSizable + kMinXMargin);
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
  paneButtons(classPane, cw, "+ Class", (s) => newClass(),
                             "Remove Class", (s) => browserRemove());

  // Variables — the instance/class toggle governs this column and Methods, so it
  // rides the top of this pane rather than floating in the tab.
  var varPane = browserPane(hsplit, cw, ph);
  gVarTable = tableIn(varPane, [0.0, 0.0, cw, ph - kPaneBtnH]);
  var bi = button(varPane, "instance", [4.0, ph - 24.0, (cw / 2.0) - 6.0, 22.0], (s) => setSide('i'));
  var bc = button(varPane, "class", [(cw / 2.0) + 2.0, ph - 24.0, (cw / 2.0) - 6.0, 22.0], (s) => setSide('c'));
  bi.setAutoresizingMask(kWidthSizable + kMinYMargin);
  bc.setAutoresizingMask(kWidthSizable + kMinXMargin + kMinYMargin);

  // Methods — list over its own New/Remove.
  var methPane = browserPane(hsplit, cw, ph);
  gMethodTable = tableIn(methPane, [0.0, kPaneBtnH, cw, ph - kPaneBtnH]);
  paneButtons(methPane, cw, "+ Method", (s) => newMethod(),
                             "Remove Method", (s) => removeMethod());

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
  var mf = _mono(13.0);
  if (!mf.isNil) gBrowserSrc.setFont(mf);

  gTargets.add(onTable(gCatTable, () => gBrCats.length, (r) => gBrCats[r].toString(), sel(selectCategory)));
  gTargets.add(onTable(gClassTable, () => gBrClasses.length, (r) => gBrClasses[r].toString(), sel(selectClass)));
  gTargets.add(onTable(gVarTable, () => gVarRecs.length, (r) => gVarRecs[r][2].toString(), sel((r) => selectMemberRec(gVarRecs, r))));
  gTargets.add(onTable(gMethodTable, () => gMethodRecs.length, (r) => gMethodRecs[r][2].toString(), sel((r) => selectMemberRec(gMethodRecs, r))));
  gTargets.add(onTextChange(gBrowserSrc, (s) => highlightView(gBrowserSrc)));
}

// Delete the selected member from its class, then re-accept the class — so the
// removal is live and saved, exactly like any other edit.
void removeMethod() {
  if (!gBrUserApp) { log("world classes are read-only"); return; }
  if (gBrSelClass == null || gBrClassSrc == null) { log("select a class first"); return; }
  if (gSelMemberSrc == null || gSelMemberSrc.isEmpty) {
    log("select a member in the Variables or Methods pane to remove");
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
    gSelMemberSrc = text;
    ask('acceptMany', [newClass]).then((r) {
      log("✓ Accept — " + r);
      gBrClassSrc = newClass;
      _reloadBrowserClass();
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
  var m = new RegExp(r'^\s*(?:abstract\s+)?(?:class|enum)\s+(\w+)').firstMatch(d);
  return m != null ? m.group(1) : null;
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
  ask('acceptMany', decls).then((r) {
    if (r.startsWith('accepted')) {
      log("✓ Accept — " + r);
    } else {
      log("Accept failed — " + r);
    }
    updateMetrics();
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
  menuSep(code);
  menuItem(code, "Restart Language Isolate", "", (s) => respawnLanguage("restart from the menu"));

  var view = subMenu(mainMenu, "View");
  menuItem(view, "Workspace", "1", (s) => switchTab(0));
  menuItem(view, "Browser", "2", (s) => switchTab(1));
  menuItem(view, "Editor", "3", (s) => switchTab(4));
  menuItem(view, "Find", "4", (s) => switchTab(3));
  menuItem(view, "Docs", "5", (s) => switchTab(2));
  menuSep(view);
  menuItem(view, "Clear Transcript", "k", (s) {
    gLog.clear(); gTranscript.setString(""); repaint();
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

Future ask(String cmd, var arg) async {   // arg/result may be a String or a List
  if (gLang == null) return "ERR: language isolate restarting…";
  var rp = new ReceivePort();
  gLang.send([cmd, arg, rp.sendPort]);
  var result = await rp.first.timeout(_kDoitTimeout, onTimeout: () => _kTimeout);
  rp.close();
  if (identical(result, _kTimeout)) {
    await respawnLanguage("'" + cmd + "' timed out — killed runaway code");
    return "ERR: " + cmd + " timed out (isolate restarted)";
  }
  return result;
}

// Spawn the language isolate from the scratch file, with error/exit monitoring.
Future spawnLanguage() async {
  var gen = ++gLangGen;
  var fromLang = new ReceivePort();
  var errPort = new ReceivePort();
  var exitPort = new ReceivePort();
  gLangIsolate = await Isolate.spawnUri(
      Uri.parse('file://' + gScratch), <String>[gScratch, gDbPath], fromLang.sendPort,
      onError: errPort.sendPort, onExit: exitPort.sendPort, errorsAreFatal: false);
  gLang = await fromLang.first;
  fromLang.close();
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
  await spawnLanguage();   // boots from the image
  gRespawning = false;
  log("language isolate restarted (declarations reloaded from the image)");
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
      var br = gTabView.tabViewItemAtIndex(1).view();
      o.add("browser   " + br.frame().toString() + " subviews=" + br.subviews().count().toString());
      for (var t in <String>["+ Class", "instance", "Comment", "Accept", "Remove"]) {
        var b = gButtons[t];
        o.add(t.padRight(10) + b.frame().toString() +
              " hidden=" + b.isHidden().toString() +
              " super=" + b.superview().frame().toString());
      }
      o.add("srcScroll " + gBrowserSrc.enclosingScrollView().frame().toString());
      o.add("transcript" + gTranscript.enclosingScrollView().frame().toString());
      return o.join("\n");
    }
    case 'snap': return await snapshot(arg.isEmpty ? "/tmp/dartui.png" : arg);
    case 'tab': switchTab(int.parse(arg)); return "ok";
    case 'brcat': selectCategory(int.parse(arg)); return "ok";
    case 'brclass': selectClass(int.parse(arg)); return "ok";
    case 'brvar': selectMemberRec(gVarRecs, int.parse(arg)); return "ok";
    case 'brmethod': selectMemberRec(gMethodRecs, int.parse(arg)); return "ok";
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
    case 'doit': return await ask('doit', arg);
    case 'accept': return await ask('accept', arg);   // persisted in the image
    case 'remove': return await ask('remove', arg);
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
  ask('acceptMany', decls).then((r) {
    log("✓ Save to Image — " + r);
    if (!r.toString().startsWith("ERR")) {
      gEdClass = _classNameOf(decls[0]);
      edStatus((gEdClass != null ? gEdClass : "(saved)") + "  ·  live + saved in the image");
      editorRefreshClasses();
      _reloadClassList();
    }
  });
}

// Editor -> live isolate ONLY. Try a class in the running world without
// committing it: a respawn (or the next launch) re-reads the image and it is gone.
void editorAddToWorld() {
  var decls = splitTopLevel(edText());
  if (decls.isEmpty) { log("editor: nothing to add"); return; }
  ask('acceptLive', decls).then((r) {
    log("✓ Add to World — " + r);
    if (!r.toString().startsWith("ERR")) {
      edStatus("live in the running world — NOT saved to the image");
    }
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
  new Timer.run(() {
    var p = (kind == 'open')
        ? Cocoa.cls("NSOpenPanel").openPanel()
        : Cocoa.cls("NSSavePanel").savePanel();
    p.setAllowedFileTypes(["dart"]);
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
    ask('acceptMany', decls).then((r) {
      log("✓ File In (" + decls.length.toString() + " declaration(s)) — " + r);
      edStatus(path + "  ·  filed in: " + decls.length.toString() + " declaration(s) live + saved");
      editorRefreshClasses();
      _reloadClassList();
    });
  });
}

// --- Format -----------------------------------------------------------------
// Re-indent only: 2 spaces per brace depth, computed from CODE braces alone.
// lexDart already knows which spans are strings and comments, so their contents
// - including braces and quotes inside them - are never counted and never
// rewritten. A line whose start lies inside a multi-line string or comment is
// emitted verbatim.
String formatDart(String src) {
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
  var bin = _analyzeBinary();
  if (bin == null) {
    log("Analyze unavailable: no dart binary beside " + Platform.resolvedExecutable);
    return;
  }
  // Line numbers must map 1:1 onto the editor, so nothing above the buffer and
  // no trimming: the empty main goes at the END.
  var probe = _neutraliseMain(src) + "\n\nmain() {}\n";
  var path = Directory.systemTemp.path + "/macdart_analyze.dart";
  var out;
  try {
    new File(path).writeAsStringSync(probe);
    out = await Process.run(bin, <String>["--compile_all", path])
        .timeout(const Duration(seconds: 20), onTimeout: () => null);
  } catch (e) {
    log("Analyze failed to run: " + e.toString());
    return;
  } finally {
    try { new File(path).deleteSync(); } catch (e) {}
  }
  if (out == null) { edStatus("Analyze timed out"); log("Analyze timed out"); return; }
  if (out.exitCode == 0) {
    edStatus("Analyze: compiles cleanly");
    log("Analyze: compiles cleanly");
    return;
  }
  var msg = out.stderr.toString().trim();
  if (msg.isEmpty) msg = out.stdout.toString().trim();
  var first = _firstLine(msg);
  edStatus("Analyze FAILED: " + first);
  log("Analyze FAILED: " + msg);
  var line = _errorLine(msg);
  if (line > 0) _selectLine(line);
}

String _firstLine(String s) {
  var i = s.indexOf('\n');
  return i < 0 ? s : s.substring(0, i);
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

TABS (View menu, Cmd-1..5)
  Workspace  a scratch pane: Do It / Print It against the live language isolate.
  Browser    a Smalltalk-style class browser over the image and the world.
  Editor     one whole class as text, with Analyze and Format.
  Find       name search and senders over the image.
  Docs       this page.

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
  View   the five tabs, and Clear Transcript (Cmd-K).

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
  A loopback control socket (127.0.0.1:7644) drives the UI and captures snapshots.
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
  startMetrics();   // ~4 Hz VM counters in the toolbar

  var server = await ServerSocket.bind(InternetAddress.LOOPBACK_IP_V4, 7644);
  stderr.writeln("dartui workspace control on 127.0.0.1:7644");
  server.listen((Socket socket) {
    // A driver that hangs up before we answer (a timed-out `nc`, say) would
    // otherwise surface as an unhandled SocketException in the UI isolate.
    socket.done.catchError((e) {});
    socket.transform(UTF8.decoder).transform(new LineSplitter()).listen((line) async {
      var reply = await handle(line);
      try { socket.write(reply + "\n"); } catch (e) {}
    }, onError: (e) {}, cancelOnError: true);
  }, onError: (e) => log("control socket: " + e.toString()));
}
