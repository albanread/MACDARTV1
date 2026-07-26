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

Cocoa gWindow, gContent, gTabView, gEditor, gTranscript, gMetrics;
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

/// A draggable pane splitter (MACVM's browser shape). [vertical] true = panes
/// side by side with vertical dividers.
Cocoa splitView(List frame, bool vertical) {
  var sp = Cocoa.cls("NSSplitView").alloc().initWithFrame(frame);
  sp.setVertical(vertical);
  sp.setDividerStyle(3);   // NSSplitViewDividerStylePaneSplitter — visibly grabbable
  sp.setAutoresizingMask(kWidthSizable + kHeightSizable);
  return sp;
}

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
  if (i == 1) openBrowser();
  updateMetrics();
  repaint();
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
  iconButton(bar, "Find", "open", [88.0, 6.0, 36.0, 32.0], (s) => switchTab(3));
  iconButton(bar, "Docs", "documentation", [128.0, 6.0, 36.0, 32.0], (s) => switchTab(2));
  gMetrics = label(bar, [520.0, 13.0, 372.0, 18.0]);
  gMetrics.setAlignment(2); // right
  gMetrics.setAutoresizingMask(kMinXMargin);   // stays right-anchored

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
  button(ws, "Accept", [194.0, 388.0, 92.0, 28.0], (s) => acceptEditor());
  button(ws, "Clear", [292.0, 388.0, 74.0, 28.0], (s) {
    gLog.clear(); gTranscript.setString(""); repaint();
  });
  pinTop(<String>["Do It", "Print It", "Accept", "Clear"]);
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

  // Transcript dock (shared across tabs): docked to the bottom at a fixed
  // height, widening with the window.
  gTranscript = scrolledTextView(gContent, [16.0, 12.0, 868.0, 152.0], false);
  anchorScroll(gTranscript, kWidthSizable);

  // Below this the panes stop being usable, so don't let the window get there.
  gWindow.setContentMinSize([680.0, 480.0]);

  gTabView.selectTabViewItemAtIndex(0);
  log("workspace ready — Workspace / Browser / Docs");
  updateMetrics();

  gWindow.center();
  gWindow.makeKeyAndOrderFront(null);
  Cocoa.cls("NSApplication").sharedApplication().activateIgnoringOtherApps(true);
}

void updateMetrics() {
  if (gMetrics == null) return;
  var st = cocoaStats();   // [wraps, releases]
  gMetrics.setStringValue(
      "cocoa: " + st[0].toString() + " wrapped / " + st[1].toString() + " freed");
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
  table.setAutoresizingMask(kWidthSizable + kHeightSizable);
  table.setColumnAutoresizingStyle(1);   // NSTableViewUniformColumnAutoresizingStyle
  scroll.setDocumentView(table);
  scroll.setAutoresizingMask(kWidthSizable + kHeightSizable);
  parent.addSubview(scroll);
  return table;
}

void buildBrowserTab(Cocoa br) {
  // create buttons (left) + instance/class toggle (over the member panes).
  button(br, "+ Class", [8.0, 394.0, 78.0, 22.0], (s) => newClass());
  button(br, "+ Method", [90.0, 394.0, 90.0, 22.0], (s) => newMethod());
  button(br, "instance", [372.0, 394.0, 84.0, 22.0], (s) => setSide('i'));
  button(br, "class", [460.0, 394.0, 66.0, 22.0], (s) => setSide('c'));
  br.setAutoresizesSubviews(true);
  for (var t in <String>["+ Class", "+ Method", "instance", "class"]) {
    gButtons[t].setAutoresizingMask(kMinYMargin);   // ride the top edge
  }

  // The browser proper is two nested split views, so every separator is a
  // draggable splitter: the four panes side by side over the source area.
  var vsplit = splitView([8.0, 8.0, 852.0, 380.0], false);
  var hsplit = splitView([0.0, 0.0, 852.0, 220.0], true);

  // Four panes: Categories | Classes | Variables | Methods. Each scroll view is
  // a split pane, so the splitter resizes it directly.
  var cw = 213.0;
  gCatTable = tableIn(hsplit, [0.0, 0.0, cw, 220.0]);
  gClassTable = tableIn(hsplit, [0.0, 0.0, cw, 220.0]);
  gVarTable = tableIn(hsplit, [0.0, 0.0, cw, 220.0]);
  gMethodTable = tableIn(hsplit, [0.0, 0.0, cw, 220.0]);

  // Lower half: the mode/action row pinned above the source view, both inside
  // one container so the horizontal splitter moves them together.
  var lower = Cocoa.cls("NSView").alloc().initWithFrame([0.0, 0.0, 852.0, 150.0]);
  lower.setAutoresizesSubviews(true);
  button(lower, "Comment", [0.0, 126.0, 84.0, 22.0], (s) => setMode('comment'));
  button(lower, "Definition", [86.0, 126.0, 92.0, 22.0], (s) => setMode('definition'));
  button(lower, "Source", [182.0, 126.0, 72.0, 22.0], (s) => setMode('source'));
  gStatus = label(lower, [262.0, 128.0, 320.0, 18.0]);
  button(lower, "Accept", [586.0, 126.0, 68.0, 22.0], (s) => browserAccept());
  button(lower, "Cancel", [658.0, 126.0, 64.0, 22.0], (s) => browserCancel());
  button(lower, "Remove", [726.0, 126.0, 90.0, 22.0], (s) => browserRemove());
  pinTop(<String>["Comment", "Definition", "Source"]);          // ride the top edge
  pinTop(<String>["Accept", "Cancel", "Remove"], kMinXMargin);  // ...and the right edge
  gStatus.setAutoresizingMask(kMinYMargin + kWidthSizable);
  gBrowserSrc = scrolledTextView(lower, [0.0, 0.0, 852.0, 122.0], true);
  anchorScroll(gBrowserSrc, kWidthSizable + kHeightSizable);

  vsplit.addSubview(hsplit);
  vsplit.addSubview(lower);
  vsplit.adjustSubviews();
  hsplit.adjustSubviews();
  vsplit.setPosition(220.0, ofDividerAtIndex: 0);
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
  // Definition mode / a brand-new class: accept the whole source.
  var decls = splitTopLevel(text);
  if (decls.isEmpty) { log("(nothing to accept)"); return; }
  ask('acceptMany', decls).then((r) { log("✓ Accept — " + r); _reloadClassList(); });
}

void _reloadBrowserClass() {
  updateMetrics();
  if (gBrSelClass == null || !gBrUserApp) return;
  ask('classmembers', gBrSelClass).then((r) { gClassMembers = _dl(r); filterMembers(); repaint(); });
  ask('classsrc', gBrSelClass).then((r) { gBrClassSrc = r.toString(); repaint(); });
}

void _reloadClassList() {
  updateMetrics();
  if (gBrSelCat == null) return;
  ask(gBrUserApp ? 'classes' : 'worldclasses', gBrUserApp ? '' : gBrSelCat).then((r) {
    gBrClasses = _dl(r); gClassTable.reloadData(); repaint();
  });
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
  gBrSelClass = null; gSelMemberSrc = null; gSelMemberSig = null;
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
  if (!gBrUserApp || gBrSelClass == null) { log("select a user class first"); return; }
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
  button(fd, "Find", [412.0, 386.0, 76.0, 28.0], (s) => runFind('find'));
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

void buildMenu() {
  var app = Cocoa.cls("NSApplication").sharedApplication();
  var mainMenu = Cocoa.cls("NSMenu").alloc().init();

  var appItem = Cocoa.cls("NSMenuItem").alloc().init();
  mainMenu.addItem(appItem);
  var appMenu = Cocoa.cls("NSMenu").alloc().init();
  appItem.setSubmenu(appMenu);
  menuItem(appMenu, "Quit MACDART", "q", (s) => app.terminate(null));

  var wsItem = Cocoa.cls("NSMenuItem").alloc().init();
  wsItem.setTitle("Workspace");
  mainMenu.addItem(wsItem);
  var wsMenu = Cocoa.cls("NSMenu").alloc().initWithTitle("Workspace");
  wsItem.setSubmenu(wsMenu);
  menuItem(wsMenu, "Do It", "d", (s) => run(false));
  menuItem(wsMenu, "Print It", "p", (s) => run(true));
  menuItem(wsMenu, "Accept", "s", (s) => acceptEditor());

  app.setMainMenu(mainMenu);
}

// Time-boxed request to the language isolate. If it doesn't reply in time the
// isolate is presumed hung (a runaway do-it), and the watchdog kills + respawns
// it so the workspace can never wedge.
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

const _docsText = '''MACDART Workspace — a native Dart V1 IDE

WORKSPACE
  Type Dart in the code pane, then:
    Do It    (⌘D) — run the selection (or whole buffer); value goes to the
                    transcript. Multi-statement code with a `return` works.
    Print It (⌘P) — evaluate and print the value.
  Syntax highlighting is live as you type.

  Declarations persist. To make a class or variable live across runs, evaluate
  it (it is remembered), then redefine it later — existing instances are MORPHED
  in place (fields kept by name, new fields initialised) via hot reload, so a
  live object survives a class-structure change.

BROWSER
  Reflects the language isolate's live classes (dart:mirrors). Refresh after you
  add or redefine classes.

ARCHITECTURE
  Two isolates: this UI isolate (pinned to the AppKit thread, builds the views)
  and a language isolate (runs your code, holds state), talking over SendPort.
  A loopback control socket (127.0.0.1:7644) drives the UI and captures snapshots.

  ⌘Q quits.''';

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

  var server = await ServerSocket.bind(InternetAddress.LOOPBACK_IP_V4, 7644);
  stderr.writeln("dartui workspace control on 127.0.0.1:7644");
  server.listen((Socket socket) {
    socket.transform(UTF8.decoder).transform(new LineSplitter()).listen((line) async {
      socket.write(await handle(line) + "\n");
    });
  });
}
