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
Cocoa gCatTable, gClassTable, gVarTable, gMethodTable, gBrowserSrc;
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

Cocoa _mono(double sz) => Cocoa.cls("NSFont").userFixedPitchFontOfSize(sz);

Cocoa button(Cocoa parent, String title, List frame, CocoaAction fn) {
  var b = Cocoa.cls("NSButton").alloc().initWithFrame(frame);
  b.setTitle(title);
  b.setBezelStyle(1);
  parent.addSubview(b);
  gButtons[title] = b;
  gTargets.add(onAction(b, fn));
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
  item.setView(view);
  tabView.addTabViewItem(item);
  return view;
}

void switchTab(int i) {
  gTabView.selectTabViewItemAtIndex(i);
  if (i == 1) openBrowser();
  updateMetrics();
  gWindow.display();
}

void buildWindow() {
  buildMenu();
  gWindow = Cocoa.cls("NSWindow").alloc().initWithContentRect(
      [0.0, 0.0, 900.0, 640.0], styleMask: 15, backing: 2, defer: false);
  gWindow.setTitle("MACDART Workspace");
  gContent = gWindow.contentView();

  // Toolbar band: view-switchers on the left, a live metrics label on the right.
  button(gContent, "Workspace", [16.0, 604.0, 110.0, 28.0], (s) => switchTab(0));
  button(gContent, "Browser", [132.0, 604.0, 92.0, 28.0], (s) => switchTab(1));
  button(gContent, "Docs", [230.0, 604.0, 80.0, 28.0], (s) => switchTab(2));
  gMetrics = label(gContent, [520.0, 608.0, 364.0, 18.0]);
  gMetrics.setAlignment(2); // right

  // Tabless content host (the toolbar buttons are the tab bar).
  gTabView = Cocoa.cls("NSTabView").alloc().initWithFrame([16.0, 176.0, 868.0, 420.0]);
  gTabView.setTabViewType(6); // NSNoTabsNoBorder
  gContent.addSubview(gTabView);

  // Workspace tab: Do It / Print It / Clear + a highlighted editor.
  var ws = addTab(gTabView, "workspace", 868.0, 420.0);
  button(ws, "Do It", [8.0, 388.0, 84.0, 28.0], (s) => run(false));
  button(ws, "Print It", [98.0, 388.0, 90.0, 28.0], (s) => run(true));
  button(ws, "Accept", [194.0, 388.0, 92.0, 28.0], (s) => acceptEditor());
  button(ws, "Clear", [292.0, 388.0, 74.0, 28.0], (s) {
    gLog.clear(); gTranscript.setString(""); gWindow.display();
  });
  gEditor = scrolledTextView(ws, [8.0, 8.0, 852.0, 372.0], true);
  gTargets.add(onTextChange(gEditor, (s) => highlight()));

  // Browser tab: a Smalltalk-style class browser (World / User App).
  buildBrowserTab(addTab(gTabView, "browser", 868.0, 420.0));

  // Docs tab.
  var dc = addTab(gTabView, "docs", 868.0, 420.0);
  scrolledTextView(dc, [8.0, 8.0, 852.0, 404.0], false).setString(_docsText);

  // Transcript dock (shared across tabs).
  gTranscript = scrolledTextView(gContent, [16.0, 12.0, 868.0, 152.0], false);

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

void log(String line) {
  gLog.add(line);
  if (gLog.length > 200) gLog = gLog.sublist(gLog.length - 200);
  gTranscript.setString(gLog.join("\n"));
  gTranscript.scrollToEndOfDocument(null);
  gWindow.display();   // async/callback updates run outside AppKit's event flush
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
  var cell = col.dataCell();
  var f = _mono(12.0);
  if (!cell.isNil && !f.isNil) cell.setFont(f);
  table.addTableColumn(col);
  table.setHeaderView(null);
  table.setUsesAlternatingRowBackgroundColors(true);
  scroll.setDocumentView(table);
  parent.addSubview(scroll);
  return table;
}

void buildBrowserTab(Cocoa br) {
  // instance/class toggle (over the member panes).
  button(br, "instance", [372.0, 394.0, 84.0, 22.0], (s) => setSide('i'));
  button(br, "class", [460.0, 394.0, 66.0, 22.0], (s) => setSide('c'));

  // Four panes: Categories | Classes | Variables | Methods.
  gCatTable = tableIn(br, [8.0, 196.0, 158.0, 218.0]);
  gClassTable = tableIn(br, [174.0, 196.0, 190.0, 218.0]);
  gVarTable = tableIn(br, [372.0, 196.0, 224.0, 190.0]);
  gMethodTable = tableIn(br, [604.0, 196.0, 256.0, 190.0]);

  // Source pane modes + actions (over the source view).
  button(br, "Comment", [8.0, 168.0, 92.0, 22.0], (s) => setMode('comment'));
  button(br, "Definition", [104.0, 168.0, 98.0, 22.0], (s) => setMode('definition'));
  button(br, "Source", [206.0, 168.0, 78.0, 22.0], (s) => setMode('source'));
  button(br, "Accept", [604.0, 168.0, 84.0, 22.0], (s) => browserAccept());
  button(br, "Remove", [694.0, 168.0, 90.0, 22.0], (s) => browserRemove());

  gBrowserSrc = scrolledTextView(br, [8.0, 8.0, 852.0, 152.0], true);
  var mf = _mono(13.0);
  if (!mf.isNil) gBrowserSrc.setFont(mf);

  gTargets.add(onTable(gCatTable, () => gBrCats.length, (r) => gBrCats[r].toString(), (r) => selectCategory(r)));
  gTargets.add(onTable(gClassTable, () => gBrClasses.length, (r) => gBrClasses[r].toString(), (r) => selectClass(r)));
  gTargets.add(onTable(gVarTable, () => gVarRecs.length, (r) => gVarRecs[r][2].toString(), (r) => selectMemberRec(gVarRecs, r)));
  gTargets.add(onTable(gMethodTable, () => gMethodRecs.length, (r) => gMethodRecs[r][2].toString(), (r) => selectMemberRec(gMethodRecs, r)));
  gTargets.add(onTextChange(gBrowserSrc, (s) => highlightView(gBrowserSrc)));
}

void openBrowser() {
  ask('categories', '').then((r) {
    gBrCats = _dl(r);
    gCatTable.reloadData();
    gWindow.display();
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
    gWindow.display();
  });
}

void selectClass(int row) {
  if (row < 0 || row >= gBrClasses.length) return;
  gBrSelClass = gBrClasses[row].toString();
  gSelMemberSrc = null;
  var membersCmd = gBrUserApp ? 'classmembers' : 'worldclassmembers';
  var membersArg = gBrUserApp ? gBrSelClass : (gBrSelCat + '|' + gBrSelClass);
  ask(membersCmd, membersArg).then((r) { gClassMembers = _dl(r); filterMembers(); gWindow.display(); });
  if (gBrUserApp) {
    ask('classsrc', gBrSelClass).then((r) { gBrClassSrc = r.toString(); if (gBrMode == 'source') gBrMode = 'definition'; updateSourcePane(); });
    ask('classcomment', gBrSelClass).then((r) { gBrClassComment = r.toString(); });
  } else {
    gBrClassSrc = "// " + gBrSelClass + "  —  world class (read-only)";
    gBrClassComment = "";
    gBrMode = 'definition';
    updateSourcePane();
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

void setSide(String side) { gBrSide = side; filterMembers(); gWindow.display(); }

void selectMemberRec(List recs, int row) {
  if (row < 0 || row >= recs.length) return;
  var src = recs[row][3].toString();
  gSelMemberSrc = src.length > 0 ? src : recs[row][2].toString();
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
  gWindow.display();
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
  if (gBrMode == 'source' && gSelMemberSrc != null && gSelMemberSrc.length > 0 && gBrClassSrc != null) {
    var newClass = _replaceOnce(gBrClassSrc, gSelMemberSrc, text);   // edit one member
    ask('acceptMany', [newClass]).then((r) {
      log("✓ Accept — " + r);
      gBrClassSrc = newClass; gSelMemberSrc = text;
      _reloadBrowserClass();
    });
    return;
  }
  var decls = splitTopLevel(text);                                   // whole class
  if (decls.isEmpty) { log("(nothing to accept)"); return; }
  ask('acceptMany', decls).then((r) { log("✓ Accept — " + r); _reloadBrowserClass(); });
}

void _reloadBrowserClass() {
  updateMetrics();
  if (gBrSelClass == null || !gBrUserApp) return;
  ask('classmembers', gBrSelClass).then((r) { gClassMembers = _dl(r); filterMembers(); gWindow.display(); });
  ask('classsrc', gBrSelClass).then((r) { gBrClassSrc = r.toString(); gWindow.display(); });
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
  gTargets.add(onAction(it, fn));
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
    case 'snap': return await snapshot(arg.isEmpty ? "/tmp/dartui.png" : arg);
    case 'tab': switchTab(int.parse(arg)); return "ok";
    case 'brcat': selectCategory(int.parse(arg)); return "ok";
    case 'brclass': selectClass(int.parse(arg)); return "ok";
    case 'brvar': selectMemberRec(gVarRecs, int.parse(arg)); return "ok";
    case 'brmethod': selectMemberRec(gMethodRecs, int.parse(arg)); return "ok";
    case 'brside': setSide(arg); return "ok";
    case 'brmode': setMode(arg); return "ok";
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
  buildWindow();

  // The language isolate hot-reloads (rewrites) its own root file, so spawn it
  // from a MUTABLE COPY of the tracked language.dart template, never the source.
  var templatePath = Platform.script.resolve('language.dart').toFilePath();
  gScratch = Directory.systemTemp.path + '/macdart_ws_lang.dart';
  gDbPath = Directory.systemTemp.path + '/macdart_workspace.sqlite';  // the image
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
