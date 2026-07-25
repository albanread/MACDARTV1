// MACDART workspace UI isolate (thread 0). MACVM-style layout: an editable code
// pane, Do It / Print It, and a transcript docked below. Do It / Print It send
// the selection (or all) to the language isolate and print the value below.
import 'dart:cocoa';
import 'dart:io';
import 'dart:isolate';
import 'dart:convert';
import 'dart:async';

Cocoa gWindow, gContent, gEditor, gTranscript;
SendPort gLang;
List<String> gLog = <String>[];
Map<String, Cocoa> gButtons = <String, Cocoa>{};
List<Cocoa> gTargets = <Cocoa>[];

Cocoa _mono(double sz) => Cocoa.cls("NSFont").userFixedPitchFontOfSize(sz);

Cocoa button(String title, double x, double w, CocoaAction fn) {
  var b = Cocoa.cls("NSButton").alloc().initWithFrame([x, 540.0, w, 28.0]);
  b.setTitle(title);
  b.setBezelStyle(1);
  gContent.addSubview(b);
  gButtons[title] = b;
  gTargets.add(onAction(b, fn));
  return b;
}

// An NSTextView inside a bezeled, vertically-scrolling NSScrollView.
Cocoa scrolledTextView(List frame, bool editable) {
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
  gContent.addSubview(scroll);
  return tv;
}

void buildWindow() {
  buildMenu();

  gWindow = Cocoa.cls("NSWindow").alloc().initWithContentRect(
      [0.0, 0.0, 820.0, 584.0], styleMask: 15, backing: 2, defer: false);
  gWindow.setTitle("MACDART Workspace");
  gContent = gWindow.contentView();

  button("Do It", 16.0, 90.0, (s) => run(false));
  button("Print It", 112.0, 96.0, (s) => run(true));
  button("Clear", 214.0, 80.0, (s) {
    gLog.clear();
    gTranscript.setString("");
  });

  // Code editor (fills the middle) and the transcript dock (bottom).
  gEditor = scrolledTextView([16.0, 188.0, 788.0, 344.0], true);
  gTranscript = scrolledTextView([16.0, 12.0, 788.0, 164.0], false);

  log("workspace ready — type Dart above, then Do It / Print It");

  gWindow.center();
  gWindow.makeKeyAndOrderFront(null);
  Cocoa.cls("NSApplication").sharedApplication().activateIgnoringOtherApps(true);
}

void log(String line) {
  gLog.add(line);
  if (gLog.length > 200) gLog = gLog.sublist(gLog.length - 200);
  gTranscript.setString(gLog.join("\n"));
  gTranscript.scrollToEndOfDocument(null);
  // Async replies (and socket commands) update the UI from the run-loop-source
  // pump, not an AppKit event, so force the window to repaint to screen.
  gWindow.display();
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
  // Immediate feedback (synchronous, so a physical click shows instantly),
  // then the value when the language isolate replies.
  var oneLine = code.replaceAll('\n', ' ');
  log((printIt ? "Print It ▶ " : "Do It ▶ ") +
      (oneLine.length > 64 ? oneLine.substring(0, 64) + "…" : oneLine));
  ask('doit', code).then((r) => log("   ⟹   " + r));
}

// --- Menu bar ---------------------------------------------------------------
Cocoa menuItem(Cocoa menu, String title, String key, CocoaAction fn) {
  var it = Cocoa.cls("NSMenuItem").alloc().init();
  it.setTitle(title);
  if (key.length > 0) it.setKeyEquivalent(key);   // Command modifier is default
  menu.addItem(it);
  gTargets.add(onAction(it, fn));                  // same target-action as buttons
  return it;
}

void buildMenu() {
  var app = Cocoa.cls("NSApplication").sharedApplication();
  var mainMenu = Cocoa.cls("NSMenu").alloc().init();

  // Application menu (the first menu; macOS titles it with the app name).
  var appItem = Cocoa.cls("NSMenuItem").alloc().init();
  mainMenu.addItem(appItem);
  var appMenu = Cocoa.cls("NSMenu").alloc().init();
  appItem.setSubmenu(appMenu);
  menuItem(appMenu, "Quit MACDART", "q", (s) => app.terminate(null));

  // Workspace menu: Do It / Print It (also ⌘D / ⌘P).
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
  var nl = line.indexOf('\n');            // keep only the first line as the command
  line = nl < 0 ? line : line.substring(0, nl);
  line = line.trimRight();
  if (line.isEmpty) return "";
  var sp = line.indexOf(' ');
  var cmd = sp < 0 ? line : line.substring(0, sp);
  var arg = sp < 0 ? "" : line.substring(sp + 1);
  switch (cmd) {
    case 'ping': return "pong";
    case 'snap': return await snapshot(arg.isEmpty ? "/tmp/dartui.png" : arg);
    case 'settext':                        // "type" into the editor; \n -> newline
      gEditor.setString(arg.replaceAll('\\n', '\n'));
      return "ok";
    case 'select':                         // "select loc len" for selection tests
      var p = arg.split(' ');
      // (skipped: needs NSRange arg; Do It/Print It use whole buffer by default)
      return "ok";
    case 'click':
      var b = gButtons[arg];
      if (b == null) return "ERR: no button " + arg;
      b.performClick(null);
      return "clicked " + arg;
    case 'doit':
      return await ask('doit', arg);
    case 'accept':
      return await ask('accept', arg);
    case 'quit':
      Cocoa.cls("NSApplication").sharedApplication().terminate(null); return "ok";
    default: return "ERR: unknown " + cmd;
  }
}

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
