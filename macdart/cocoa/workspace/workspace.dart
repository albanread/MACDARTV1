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

Cocoa gWindow, gContent, gTabView, gEditor, gTranscript, gBrowser, gMetrics;
SendPort gLang;
List<String> gLog = <String>[];
Map<String, Cocoa> gButtons = <String, Cocoa>{};
List<Cocoa> gTargets = <Cocoa>[];      // keep action targets/delegates alive

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
  if (i == 1) refreshBrowser();
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
  button(ws, "Do It", [8.0, 388.0, 90.0, 28.0], (s) => run(false));
  button(ws, "Print It", [104.0, 388.0, 96.0, 28.0], (s) => run(true));
  button(ws, "Clear", [206.0, 388.0, 80.0, 28.0], (s) {
    gLog.clear(); gTranscript.setString(""); gWindow.display();
  });
  gEditor = scrolledTextView(ws, [8.0, 8.0, 852.0, 372.0], true);
  gTargets.add(onTextChange(gEditor, (s) => highlight()));

  // Browser tab: reflect the language isolate's classes (dart:mirrors).
  var br = addTab(gTabView, "browser", 868.0, 420.0);
  button(br, "Refresh", [8.0, 388.0, 90.0, 28.0], (s) => refreshBrowser());
  label(br, [110.0, 392.0, 500.0, 18.0]).setStringValue("live classes in the language isolate");
  gBrowser = scrolledTextView(br, [8.0, 8.0, 852.0, 372.0], false);

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

void refreshBrowser() {
  ask('browse', '').then((r) {
    if (gBrowser != null) { gBrowser.setString(r); gWindow.display(); }
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

void highlight() {
  if (gEditor == null) return;
  applySpans(gEditor, lexDart(gEditor.string().UTF8String()));
}

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

  app.setMainMenu(mainMenu);
}

Future<String> ask(String cmd, String arg) async {
  var rp = new ReceivePort();
  gLang.send([cmd, arg, rp.sendPort]);
  var result = await rp.first;
  rp.close();
  return result;
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
    case 'accept': return await ask('accept', arg);
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
  var scratch = Directory.systemTemp.path + '/macdart_ws_lang.dart';
  new File(scratch).writeAsStringSync(new File(templatePath).readAsStringSync());

  var fromLang = new ReceivePort();
  await Isolate.spawnUri(
      Uri.parse('file://' + scratch), <String>[scratch], fromLang.sendPort);
  gLang = await fromLang.first;
  fromLang.close();
  log("language isolate ready");

  var server = await ServerSocket.bind(InternetAddress.LOOPBACK_IP_V4, 7644);
  stderr.writeln("dartui workspace control on 127.0.0.1:7644");
  server.listen((Socket socket) {
    socket.transform(UTF8.decoder).transform(new LineSplitter()).listen((line) async {
      socket.write(await handle(line) + "\n");
    });
  });
}
