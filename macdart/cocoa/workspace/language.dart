// MACDART workspace — LANGUAGE isolate (MACVM's "primary VM"). The user app's
// source lives in a SQLite "image" (the source of truth); at boot we load it on
// top of the VM snapshot (the "world") and hot-reload it live. Accept UPSERTs the
// image + reloads (morphing instances); a watchdog respawn just re-reads the DB.
// Serves the browser's data (classes / members / source) from the image, and a
// read-only view of the world via dart:mirrors. Talks to the UI over SendPort.
import 'dart:cocoa';       // wsEval / wsReload / Db
import 'dart:async';       // scheduleMicrotask — the app surface's auto-flush
import 'dart:isolate';
import 'dart:io';
import 'dart:mirrors';

// ===BEGIN USER===
// ===END USER===

const _begin = '// ===BEGIN USER===';
const _end = '// ===END USER===';
String _scratch;                    // this isolate's own rewritable root file
Db _db;                             // the SQLite image (user-app source)
var _decls = <String, String>{};    // name -> source (a mirror of the image)

// --- the running user app (APP_PANE_PLAN.md) --------------------------------
// One app at a time, on one surface. `_app` is a top-level of THIS library, so
// wsEval can construct into it (an expression compiles in this library's scope,
// so a private top-level is in scope) and everything afterwards is plain
// dynamic dispatch — no mirrors, whose class metadata goes stale after a reload.
SendPort _ui;                       // the UI isolate, for surface pushes
var _app;                           // the app instance, null when none runs
AppSurface _surface;                // where its widgets currently live
String _appClass;                   // the class it was built from
int _appGen = 0;                    // stale pushes from a stopped app are dropped

// --- bilingual: Smalltalk declarations in the same image (ST_PLAN Sprint 10).
// An image decl is Smalltalk when it LOOKS like one — `Super subclass: Name [`
// (optionally after "..." comments) — so Accept needs no language toggle. ST
// decls are excluded from the Dart scratch and loaded through stLoad as ONE
// combined layer (so they see each other), after every successful Dart reload.
final RegExp _stClassRe = new RegExp(
    r'^\s*(?:"(?:[^"]|"")*"\s*)*(\w+)\s+subclass:\s*(\w+)\s*\[');
// Sprint 12: an imported world class may START with a reopen/extension form
// (`Foo extend [`, `Foo class extend [`, `Foo >> sel [`) when its defining
// file precedes it only with extensions.
final RegExp _stExtendRe = new RegExp(
    r'^\s*(?:"(?:[^"]|"")*"\s*)*(\w+)(?:\s+class)?\s+(?:extend\s*\[|>>)');
// Sprint 12: an st-doit decl (a world file's init/driver lines) is marked by
// its first line: an ST comment `"st-doit <name>"` written by the importer.
final RegExp _stDoitRe = new RegExp(r'^\s*"st-doit\s+([^"]+)"');

bool _isStSource(String s) => _stClassRe.hasMatch(s);
bool _isStDoit(String s) => _stDoitRe.hasMatch(s);
// ANY Smalltalk decl (class, extension, or do-it chunk): excluded from the
// Dart scratch and from the Dart compile-lint.
bool _isStAny(String s) =>
    _stClassRe.hasMatch(s) || _stExtendRe.hasMatch(s) || _isStDoit(s);

String _stName(String s) {
  var m = _stClassRe.firstMatch(s);
  if (m != null) return m.group(2);
  var d = _stDoitRe.firstMatch(s);
  if (d != null) return d.group(1).trim();
  var e = _stExtendRe.firstMatch(s);
  return e == null ? null : e.group(1);
}

// The ST layer, reloaded: every class/extension decl as ONE combined FRESH
// load (same-name pieces merge within the load; the fresh layer fully
// shadows earlier ones, so an edit always wins) — then the st-doit decls
// (world init lines: `Character initTable`, ...) run in NAME order.
String _stReloadAll() {
  var st = <String>[];
  var boots = <String>[];
  _decls.forEach((n, s) {
    if (_isStDoit(s)) boots.add(n);
    else if (_isStAny(s)) st.add(s);
  });
  if (st.isEmpty && boots.isEmpty) return '';
  if (st.isNotEmpty) {
    var r = stLoadFresh(st.join('\n\n'));
    if (r.startsWith('ERR:')) return r;
  }
  boots.sort();
  for (var n in boots) {
    var r = stRun(_decls[n]);
    if (r.startsWith('ERR:')) return 'in ' + n + ': ' + r;
  }
  return '';
}

// --- Sprint 12: import MACVM .mst files into the image as editable decls ----
// One merged decl PER CLASS (all its definitions/reopens across files,
// separated by provenance comments), plus one `st-doit` decl per file that
// had top-level statements (init lines run at reload; name-ordered, so the
// numbered world stems keep their boot order). The slicing comes from the
// parse-only stOutline native; chunks start at an item's line and run to the
// next item's, so leading comments travel with what they describe.
String _stImport(String path) {
  var files = <String>[];
  if (FileSystemEntity.isDirectorySync(path)) {
    for (var f in new Directory(path).listSync()) {
      if (f.path.endsWith('.mst')) files.add(f.path);
    }
    files.sort();
  } else if (FileSystemEntity.isFileSync(path)) {
    files.add(path);
  } else {
    return 'ERR: stimport: no such file or directory: ' + path;
  }
  var classText = <String, StringBuffer>{};
  var classNames = <String>[];
  var doitText = <String, String>{};
  for (var p in files) {
    var stem = p.split('/').last.replaceAll('.mst', '');
    var src = new File(p).readAsStringSync();
    var items = stOutline(src);
    if (items is String) return 'ERR: stimport ' + stem + ': ' + items;
    var trip = <List>[];
    for (var it in items) {
      if (it != null) trip.add(it);
    }
    if (trip.isEmpty) continue;
    var lines = src.split('\n');
    var stmts = new StringBuffer();
    for (var i = 0; i < trip.length; i++) {
      var type = trip[i][0];
      var name = trip[i][1];
      int a = (i == 0) ? 1 : trip[i][2];
      int b = (i + 1 < trip.length) ? trip[i + 1][2] - 1 : lines.length;
      if (a < 1) a = 1;
      if (b > lines.length) b = lines.length;
      if (b < a) b = a;
      var chunk = lines.sublist(a - 1, b).join('\n').trimRight();
      if (chunk.isEmpty) continue;
      if (type == 'class' || type == 'extend' || type == 'extmethod') {
        var buf = classText[name];
        if (buf == null) {
          buf = new StringBuffer();
          classText[name] = buf;
          classNames.add(name);
        } else {
          buf.write('\n\n"— from ' + stem + ' —"\n');
        }
        buf.write(chunk);
      } else {
        // vardecl / stmt — the file's init & driver lines, kept in order.
        stmts.writeln(chunk);
      }
    }
    if (stmts.isNotEmpty) {
      var dn = 'boot:' + stem;
      doitText[dn] = '"st-doit ' + dn + '"\n' + stmts.toString().trimRight();
    }
  }
  if (classNames.isEmpty && doitText.isEmpty) {
    return 'ERR: stimport: nothing to import in ' + path;
  }
  classText.forEach((name, buf) {
    _decls[name] = buf.toString();
  });
  doitText.forEach((name, text) {
    _decls[name] = text;
  });
  var err = _rebuildAndReload();
  if (err.isNotEmpty) return err;
  classText.forEach((name, buf) { _imageUpsert(name, _decls[name]); });
  doitText.forEach((name, text) { _imageUpsert(name, text); });
  return 'imported ' + classNames.length.toString() + ' classes, ' +
      doitText.length.toString() + ' boot chunks from ' +
      files.length.toString() + ' files';
}

main(List args, SendPort uiPort) {
  _ui = uiPort;
  // Smalltalk `Transcript show:`/`cr` lines land in the GUI Transcript.
  stTranscriptSink = (line) {
    _ui.send(<dynamic>['tr', line.toString()]);
  };
  _scratch = args[0];
  if (args.length > 1 && args[1] != null && (args[1] as String).length > 0) {
    _db = new Db.open(args[1]);
    if (_db.isOpen) {
      _db.exec('CREATE TABLE IF NOT EXISTS decls'
          '(name TEXT PRIMARY KEY, kind TEXT, category TEXT, source TEXT, comment TEXT)');
      _db.exec('ALTER TABLE decls ADD COLUMN comment TEXT');  // no-op if it exists
      _loadFromImage();
    }
  }
  var rp = new ReceivePort();
  uiPort.send(rp.sendPort);
  rp.listen((msg) {
    var cmd = msg[0];
    var arg = msg[1];
    SendPort reply = msg[2];
    var out;
    try {
      if (cmd == 'doit') out = _doit(arg);
      else if (cmd == 'accept') out = _accept(arg);
      else if (cmd == 'acceptMany') out = _acceptMany(arg);
      else if (cmd == 'acceptLive') out = _acceptLive(arg);
      else if (cmd == 'reset') out = _reset(arg);
      else if (cmd == 'remove') out = _remove(arg);
      else if (cmd == 'classes') out = _classNames();
      else if (cmd == 'members') out = _memberList(arg);
      else if (cmd == 'classsrc') out = _decls.containsKey(arg) ? _decls[arg] : '';
      else if (cmd == 'classmembers') out = _classMembers2(arg);
      else if (cmd == 'categories') out = _categories();
      else if (cmd == 'classcomment') out = _classComment(arg);
      else if (cmd == 'setcomment') out = _setComment(arg);
      else if (cmd == 'worldclasses') out = _worldClasses(arg.length > 0 ? arg : 'dart:core');
      else if (cmd == 'worldclassmembers') out = _worldClassMembers(arg);
      else if (cmd == 'worldclasssrc') out = _worldClassSrc(arg);
      else if (cmd == 'find') out = _find(arg);
      else if (cmd == 'senders') out = _senders(arg);
      else if (cmd == 'alldecls') out = _allDecls();
      else if (cmd == 'vmstats') out = wsVmStats();
      else if (cmd == 'apps') out = _appClasses();
      else if (cmd == 'apprun') out = _appRun(arg);
      else if (cmd == 'appstop') out = _appStop();
      else if (cmd == 'appbuild') out = _appBuild(arg);
      else if (cmd == 'appevent') out = _appEvent(arg);
      else if (cmd == 'stimport') out = _stImport(arg);
      else if (cmd == 'ping') out = 'lang-pong';
      else out = 'ERR: unknown ' + cmd.toString();
    } catch (e) {
      out = 'ERR: ' + e.toString();
    }
    // Whatever the command did to the surface goes out as one batch, before the
    // reply — so a click's visible effect never lags its acknowledgement.
    if (_surface != null) _surface.flush();
    reply.send(out);
  });
}

// --- do-it ------------------------------------------------------------------
// A do-it is ONE EXPRESSION compiled against this isolate's root library
// (Dart_EvaluateExpr), so it sees every accepted class and can mutate top-level
// state, but a `var` written inside it is a local of that evaluation and dies
// with it. Workspace variables close that gap the Smalltalk way: `var x = expr`
// (and an assignment to a name that does not exist yet) is promoted to a real
// top-level declaration first, so it persists like anything else you Accept.
final RegExp _wsVarDecl =
    new RegExp(r'^\s*(?:var|final)\s+(\w+)\s*=\s*([\s\S]+?);?\s*$');
// `=` but not `==` (an equality test is not an assignment).
final RegExp _wsAssign = new RegExp(r'^\s*(\w+)\s*=(?!=)\s*([\s\S]+?);?\s*$');

// A Smalltalk do-it: `st> expr` wraps the code as a class-side doIt method,
// loads it (a fresh tiny library each time; newest-first lookup finds it), and
// invokes it. A bare expression is wrapped `^ ( expr )`; code with statements
// (`.`) or an explicit `^` runs verbatim as the method body (write `^` for the
// value, Smalltalk style).
int _stDoitN = 0;
String _stDoit(String code) {
  var n = ++_stDoitN;
  var cls = 'STDoIt' + n.toString();
  var body;
  if (code.contains('^')) body = code;
  else if (code.startsWith('|') || code.contains('.')) body = code;
  else body = '^ ( ' + code + ' )';
  var src = 'Object subclass: ' + cls + ' [ ' + cls +
      ' class >> doIt [ ' + body + ' ] ]';
  var r = stLoad(src);
  if (r.startsWith('ERR:')) return r;
  try {
    var v = stInvokeStatic(cls, 'doIt', <dynamic>[]);
    return v == null ? 'nil' : stPrintOf(v).toString();  // ST printString
  } catch (e) {
    return 'ERR: ' + e.toString();
  }
}

String _doit(String code) {
  var t = code.trimLeft();
  if (t.startsWith('st>')) return _stDoit(t.substring(3).trim());
  var m = _wsVarDecl.firstMatch(code);
  if (m != null) {
    var err = _declareWsVar(m.group(1));
    if (err.isNotEmpty) return err;
    var r = wsEval(m.group(1) + ' = ' + m.group(2));
    if (!r.startsWith('ERR:')) _rememberWsValue(m.group(1), m.group(2));
    return r;
  }
  var r = wsEval(code);
  if (r.startsWith('ERR:') && r.contains('error:')) {
    var r2 = wsEval('((){ ' + code + ' })()');
    if (!r2.startsWith('ERR:')) return r2;
  }
  if (!r.startsWith('ERR:')) {
    // Reassigning an existing workspace variable keeps the image in step.
    var a = _wsAssign.firstMatch(code);
    if (a != null) _rememberWsValue(a.group(1), a.group(2));
    return r;
  }
  // `x = expr` where x has never been declared: make it a workspace variable
  // and run it again, rather than reporting a missing getter.
  if (r.startsWith('ERR:')) {
    var a = _wsAssign.firstMatch(code);
    if (a != null && _missingTopLevel(r, a.group(1))) {
      var err = _declareWsVar(a.group(1));
      if (err.isEmpty) {
        var r2 = wsEval(code);
        if (!r2.startsWith('ERR:')) _rememberWsValue(a.group(1), a.group(2));
        return r2;
      }
    }
  }
  return r;
}

// The VM names the missing member as 'u' for a getter but 'u=' for a setter.
bool _missingTopLevel(String err, String name) =>
    err.contains('No top-level') &&
    (err.contains("'" + name + "'") || err.contains("'" + name + "='"));

// Mint `var <name>;` as a top-level declaration and make it live + saved.
String _declareWsVar(String name) {
  if (_decls.containsKey(name)) return '';
  var src = 'var ' + name + ';';
  _decls[name] = src;
  _imageUpsert(name, src);
  return _rebuildAndReload();
}

// A value we can honestly write back into the image as an initialiser, so the
// variable comes back with it next launch. Only self-contained literals: an
// arbitrary expression could have side effects, or fail, when re-run at boot.
final RegExp _wsLiteral = new RegExp(
    '^\\s*(?:-?\\d+(?:\\.\\d+)?|true|false|null|' +
    "'[^'\\\\\\n]*'|\"[^\"\\\\\\n]*\")\\s*\$");

// Keep the image's initialiser in step with the variable's current value, so a
// scalar workspace variable survives a restart holding what you last put in it.
// No reload: the live value is already set. A variable holding an OBJECT keeps
// its declaration but comes back null — object graphs are not in the image.
void _rememberWsValue(String name, String expr) {
  if (!_decls.containsKey(name)) return;
  var cur = _decls[name];
  if (cur != null && !cur.startsWith('var ' + name)) return;   // not ours
  var src = _wsLiteral.hasMatch(expr)
      ? ('var ' + name + ' = ' + expr.trim() + ';')
      : ('var ' + name + ';');
  if (src == cur) return;
  _decls[name] = src;
  _imageUpsert(name, src);
}

// --- the image (user-app source) --------------------------------------------
void _loadFromImage() {
  _decls.clear();
  var rows = _db.query('SELECT name, source FROM decls ORDER BY name', const []);
  if (rows != null) {
    for (var r in rows) _decls[r[0]] = r[1];
  }
  _rebuildAndReload();   // make the loaded declarations live
}

void _imageUpsert(String name, String source) {
  if (_db != null && _db.isOpen) {
    _db.exec('INSERT OR REPLACE INTO decls(name,kind,category,source) VALUES(?,?,?,?)',
        [name, _kindOf(source), 'user', source]);
  }
}

String _accept(String decl) => _acceptMany(<String>[decl]);

// GUI Accept: the editor's top-level declarations, redefining by name; UPSERT
// each into the image, then reload ONCE (live instances of a changed class morph).
String _acceptMany(List decls) {
  // ST decls: cheap parse-check FIRST, so a syntax error reports its line/col
  // before anything is written or reloaded.
  for (var d in decls) {
    var s = d.toString().trim();
    if (_isStAny(s)) {
      var c = stCheck(s);
      if (c.isNotEmpty) return c;
    }
  }
  var names = <String>[];
  var prev = <String, String>{};        // name -> what was there (null = new)
  for (var d in decls) {
    var s = d.toString().trim();
    var name = _declName(s);
    prev[name] = _decls.containsKey(name) ? _decls[name] : null;
    _decls[name] = s;
    names.add(name);
  }
  var err = _rebuildAndReload();
  if (err.isNotEmpty) {
    // The image is the source of truth for the NEXT boot, so it must never keep
    // source the VM has just refused: writing it before the reload meant a
    // cancelled reload left a class that would fail to load on the next start.
    // Put back what was there and reload that, so live and saved agree again.
    prev.forEach((name, old) {
      if (old == null) _decls.remove(name); else _decls[name] = old;
    });
    _rebuildAndReload();
    return err;
  }
  for (var name in names) _imageUpsert(name, _decls[name]);
  return 'accepted ' + names.join(', ');
}

// Live-only accept: make declarations live in THIS isolate without touching the
// image. The editor's "Add to World" — try a class in the running world without
// committing it, so the next boot (or a watchdog respawn, which re-reads the
// image) comes back without it. Deliberately not persisted.
String _acceptLive(List decls) {
  var names = <String>[];
  var prev = <String, String>{};
  for (var d in decls) {
    var s = d.toString().trim();
    var name = _declName(s);
    prev[name] = _decls.containsKey(name) ? _decls[name] : null;
    _decls[name] = s;
    names.add(name);
  }
  var err = _rebuildAndReload();
  if (err.isNotEmpty) {            // roll back, same reasoning as _acceptMany
    prev.forEach((name, old) {
      if (old == null) _decls.remove(name); else _decls[name] = old;
    });
    _rebuildAndReload();
    return err;
  }
  return 'live (not saved): ' + names.join(', ');
}

// Replace the whole declaration set at once (kept for scripted use / replay).
String _reset(List decls) {
  _decls.clear();
  for (var d in decls) {
    var s = d.toString().trim();
    var name = _declName(s);
    _decls[name] = s;
    _imageUpsert(name, s);
  }
  var err = _rebuildAndReload();
  return err.isEmpty ? ('reset (' + _decls.length.toString() + ' decls)') : err;
}

String _remove(String name) {
  _decls.remove(name);
  if (_db != null && _db.isOpen) _db.exec('DELETE FROM decls WHERE name=?', [name]);
  var err = _rebuildAndReload();
  return err.isEmpty ? ('removed ' + name) : err;
}

// Regenerate the USER region of the scratch file from _decls and hot-reload.
String _rebuildAndReload() {
  // Only DART decls go into the scratch (an .mst class is not Dart source);
  // the ST layer reloads separately after a successful Dart reload.
  var dart = <String>[];
  _decls.forEach((n, s) {
    if (!_isStAny(s)) dart.add(s);
  });
  var region = dart.join('\n\n');
  var text = new File(_scratch).readAsStringSync();
  var s = text.indexOf(_begin) + _begin.length;
  var e = text.indexOf(_end);
  new File(_scratch).writeAsStringSync(
      text.substring(0, s) + '\n' + region + '\n' + text.substring(e));
  var err = wsReload();
  if (err.isNotEmpty) return err;
  return _stReloadAll();
}

// Every declaration as [name, source]. The UI compiles a proposed edit against
// these before accepting it: a class checked ALONE would be rejected the moment
// it referenced another class in the image.
List _allDecls() {
  var out = <List>[];
  _decls.forEach((name, src) { out.add([name, src]); });
  return out;
}

// --- browser data (user app) ------------------------------------------------
List _classNames() {
  var out = <String>[];
  _decls.forEach((name, src) {
    var k = _kindOf(src);
    if (k == 'class' || k == 'enum' || k == 'st-class') out.add(name);
  });
  out.sort();
  return out;
}

List _memberList(String className) {
  var src = _decls[className];
  if (src == null) return const <String>[];
  if (_isStAny(src)) {
    var out = <String>[];
    for (var m in _stMembers(src)) out.add(m[2]);
    return out;
  }
  var out = <String>[];
  for (var m in _splitMembers(src)) {
    var sig = _memberSig(m);
    if (sig.length > 0) out.add(sig);
  }
  return out;
}

// Sprint 12: split a (possibly merged) ST class decl into members —
// [side 'c'|'i', 'method', signature, source] per method. Line-based: a
// method starts at a line ENDING in '[' at shallow indentation (world style)
// and runs to the line before the next such header. Class-side headers carry
// `class >>`. Ivar lines (`| a b |`) and headers are skipped.
List<List> _stMembers(String src) {
  var lines = src.split('\n');
  var headers = <int>[];
  for (var i = 0; i < lines.length; i++) {
    var t = lines[i].trimRight();
    if (!t.endsWith('[')) continue;
    var lt = t.trimLeft();
    var indent = t.length - lt.length;
    if (indent > 4) continue;                      // nested block, not a method
    if (lt.startsWith('"')) continue;
    if (lt.contains('subclass:')) continue;
    if (new RegExp(r'^\w+(\s+class)?\s+extend\s*\[$').hasMatch(lt)) continue;
    headers.add(i);
  }
  var out = <List>[];
  for (var h = 0; h < headers.length; h++) {
    var a = headers[h];
    var b = (h + 1 < headers.length) ? headers[h + 1] : lines.length;
    // trim the trailing class-closing ']' line off the last member's chunk
    var body = lines.sublist(a, b).join('\n');
    var head = lines[a].trim();
    var sig = head.substring(0, head.length - 1).trim();
    sig = sig.replaceAll(new RegExp(r'\^\s*<[^>]*>\s*$'), '');
    sig = sig.replaceAll(new RegExp(r'<[^>]*>'), '');
    sig = sig.replaceAll(new RegExp(r'\s+'), ' ').trim();
    var side = sig.contains('class >>') ? 'c' : 'i';
    sig = sig.replaceAll(new RegExp(r'^\w+\s+class\s*>>\s*'), '');
    if (sig.isEmpty) continue;
    out.add([side, 'method', sig, body]);
  }
  return out;
}

String _kindOf(String s) {
  if (_isStDoit(s)) return 'st-doit';     // Smalltalk boot/do-it chunk
  if (_isStAny(s)) return 'st-class';     // Smalltalk, before Dart heuristics
  // Past the doc comment first — same trap as _declName. A documented class
  // was classified as a 'variable', which quietly removed it from the Editor's
  // class picker and the Browser's class list: the apps/ examples ship with a
  // header comment, so every one of them was invisible.
  s = _afterLeadingComments(s).trim();
  if (new RegExp(r'^(?:abstract\s+)?class\b').hasMatch(s)) return 'class';
  if (s.startsWith('enum ')) return 'enum';
  if (s.startsWith('typedef ')) return 'typedef';
  if (new RegExp(r'^[\w<>\[\],\s]+\s\w+\s*\(').hasMatch(s)) return 'function';
  return 'variable';
}

/// A declaration's text minus any comments in front of it — a documented class
/// otherwise matches none of the patterns below and gets named from its own
/// prose by the fallback.
String _afterLeadingComments(String s) {
  var i = 0;
  while (i < s.length) {
    var c = s.codeUnitAt(i);
    if (c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D) { i++; continue; }
    if (c == 0x2F && i + 1 < s.length) {
      var d = s.codeUnitAt(i + 1);
      if (d == 0x2F) {
        while (i < s.length && s.codeUnitAt(i) != 0x0A) i++;
        continue;
      }
      if (d == 0x2A) {
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

String _declName(String d) {
  var st = _stName(d);                    // Smalltalk: `Super subclass: NAME [`
  if (st != null) return st;
  d = _afterLeadingComments(d).trim();
  var m = new RegExp(r'^(?:abstract\s+)?(?:class|enum|typedef)\s+(\w+)').firstMatch(d);
  if (m != null) return m.group(1);
  m = new RegExp(r'(\w+)\s*[=(]').firstMatch(d);
  if (m != null) return m.group(1);
  return 'anon' + _decls.length.toString();
}

// Split a class body into member declarations (fields / methods / constructors),
// respecting strings/comments; a member ends at a depth-0 '}' or ';'.
List<String> _splitMembers(String classSrc) {
  var b = classSrc.indexOf('{');
  var e = classSrc.lastIndexOf('}');
  if (b < 0 || e <= b) return const <String>[];
  var s = classSrc.substring(b + 1, e);
  var out = <String>[];
  var n = s.length, i = 0, start = 0, depth = 0;
  while (i < n) {
    var c = s.codeUnitAt(i);
    if (c == 0x2F && i + 1 < n) {                       // comments
      var d = s.codeUnitAt(i + 1);
      if (d == 0x2F) { while (i < n && s.codeUnitAt(i) != 0x0A) i++; continue; }
      if (d == 0x2A) { i += 2; while (i + 1 < n && !(s.codeUnitAt(i) == 0x2A && s.codeUnitAt(i + 1) == 0x2F)) i++; i = (i + 1 < n) ? i + 2 : n; continue; }
    }
    if (c == 0x27 || c == 0x22) {                       // strings
      var q = c; i++;
      while (i < n && s.codeUnitAt(i) != q && s.codeUnitAt(i) != 0x0A) { if (s.codeUnitAt(i) == 0x5C) i++; i++; }
      if (i < n && s.codeUnitAt(i) == q) i++;
      continue;
    }
    if (c == 0x7B) { depth++; i++; continue; }
    if (c == 0x7D) { i++; if (depth > 0) depth--; if (depth == 0) { var m = s.substring(start, i).trim(); if (m.length > 0) out.add(m); start = i; } continue; }
    if (c == 0x3B && depth == 0) { i++; var m = s.substring(start, i).trim(); if (m.length > 0) out.add(m); start = i; continue; }
    i++;
  }
  var tail = s.substring(start).trim();
  if (tail.length > 0) out.add(tail);
  return out;
}

// A member's one-line signature (up to '{', '=>', or ';').
String _memberSig(String m) {
  m = m.trim();
  var end = m.length;
  for (var i = 0; i < m.length; i++) {
    var c = m.codeUnitAt(i);
    if (c == 0x7B || c == 0x3B) { end = i; break; }
    if (c == 0x3D && i + 1 < m.length && m.codeUnitAt(i + 1) == 0x3E) { end = i; break; }
  }
  return m.substring(0, end).trim();
}

// --- the world (read-only, via dart:mirrors) --------------------------------
// Browser categories: the editable user app, then the world's libraries.
List _categories() {
  var out = <String>['User App'];
  out.addAll(_worldLibs());
  return out;
}

List _worldLibs() {
  var out = <String>[];
  currentMirrorSystem().libraries.forEach((uri, lib) { out.add(uri.toString()); });
  out.sort();
  return out;
}

List _worldClasses(String libUri) {
  var out = <String>[];
  currentMirrorSystem().libraries.forEach((uri, lib) {
    if (uri.toString() == libUri) {
      lib.declarations.forEach((sym, decl) {
        if (decl is ClassMirror) out.add(MirrorSystem.getName(sym));
      });
    }
  });
  out.sort();
  return out;
}

// A member record: [side('i'|'c'), kind('var'|'method'), signature, source].
// User-app members, parsed from the class source.
List _classMembers2(String className) {
  var src = _decls[className];
  if (src == null) return const <List>[];
  if (_isStAny(src)) return _stMembers(src);
  var out = <List>[];
  for (var m in _splitMembers(src)) {
    var t = m.trim();
    if (t.length == 0) continue;
    out.add([new RegExp(r'^static\b').hasMatch(t) ? 'c' : 'i',
             _isMethod(t) ? 'method' : 'var', _memberSig(t), m]);
  }
  return out;
}

// A member is a method if a '(' precedes any '{' / ';' / plain '=' (field init).
bool _isMethod(String m) {
  for (var i = 0; i < m.length; i++) {
    var c = m.codeUnitAt(i);
    if (c == 0x28) return true;                 // '('
    if (c == 0x7B || c == 0x3B) return false;   // '{' or ';'
    if (c == 0x3D) {                            // '='
      var nxt = (i + 1 < m.length) ? m.codeUnitAt(i + 1) : 0;
      if (nxt != 0x3D && nxt != 0x3E) return false;
    }
  }
  return false;
}

// World class members via mirrors, same record format (source = signature, r/o).
List _worldClassMembers(String qualified) {   // "libUri|ClassName"
  var parts = qualified.split('|');
  if (parts.length != 2) return const <List>[];
  var out = <List>[];
  currentMirrorSystem().libraries.forEach((uri, lib) {
    if (uri.toString() == parts[0]) {
      lib.declarations.forEach((sym, decl) {
        if (decl is ClassMirror && MirrorSystem.getName(sym) == parts[1]) {
          ClassMirror cm = decl;
          cm.declarations.forEach((s2, d2) {
            var n2 = MirrorSystem.getName(s2);
            if (d2 is VariableMirror) {
              VariableMirror vm = d2;
              out.add([vm.isStatic ? 'c' : 'i', 'var', _typeName(vm.type) + ' ' + n2, '']);
            } else if (d2 is MethodMirror) {
              MethodMirror mm = d2;
              if (mm.isSetter) return;
              out.add([mm.isStatic ? 'c' : 'i', 'method', _methodSig(n2, mm), '']);
            }
          });
        }
      });
    }
  });
  return out;
}

// A synthesized, read-only "whole class" for a world class, reconstructed from
// mirrors (superclass + interfaces, fields, getters, constructors, methods) —
// so the Definition pane can show the ENTIRE class at once even though no source
// exists on disk, the way an IDE shows a stubbed SDK declaration.
String _worldClassSrc(String qualified) {   // "libUri|ClassName"
  var parts = qualified.split('|');
  if (parts.length != 2) return '';
  var result = '';
  currentMirrorSystem().libraries.forEach((uri, lib) {
    if (uri.toString() != parts[0]) return;
    lib.declarations.forEach((sym, decl) {
      if (decl is! ClassMirror || MirrorSystem.getName(sym) != parts[1]) return;
      ClassMirror cm = decl;
      var head = new StringBuffer();
      if (cm.isAbstract) head.write('abstract ');
      head.write('class ' + parts[1]);
      try {
        var sc = cm.superclass;
        if (sc != null) {
          var scn = MirrorSystem.getName(sc.simpleName);
          if (scn.length > 0 && scn != 'Object') head.write(' extends ' + scn);
        }
      } catch (e) {}
      var fields = <String>[], accessors = <String>[], ctors = <String>[], methods = <String>[];
      cm.declarations.forEach((s2, d2) {
        var n2 = MirrorSystem.getName(s2);
        if (d2 is VariableMirror) {
          VariableMirror vm = d2;
          fields.add('  ' + (vm.isStatic ? 'static ' : '') + (vm.isFinal ? 'final ' : '') + _typeName(vm.type) + ' ' + n2 + ';');
        } else if (d2 is MethodMirror) {
          MethodMirror mm = d2;
          if (mm.isSetter) return;
          var line = '  ' + (mm.isStatic ? 'static ' : '') + _methodSig(n2, mm) + ';';
          if (mm.isConstructor) ctors.add(line);
          else if (mm.isGetter) accessors.add(line);
          else methods.add(line);
        }
      });
      var buf = new StringBuffer();
      buf.write('// ' + parts[0] + ' — read-only (synthesized from mirrors)\n');
      buf.write(head.toString() + ' {\n');
      var groups = <List<String>>[fields, accessors, ctors, methods];
      var wrote = false;
      for (var g in groups) {
        if (g.isEmpty) continue;
        if (wrote) buf.write('\n');
        for (var l in g) buf.write(l + '\n');
        wrote = true;
      }
      buf.write('}\n');
      result = buf.toString();
    });
  });
  return result;
}

String _typeName(TypeMirror t) {
  try { return MirrorSystem.getName(t.simpleName); } catch (e) { return 'var'; }
}

// A readable Dart signature for a mirror method — so the Members pane reads like
// real source: `double get value`, `int bump()`, `void add(Metric m)`,
// `Gauge(String name)` — instead of a bare, cryptic `get value`.
String _methodSig(String name, MethodMirror mm) {
  if (mm.isConstructor) return name + '(' + _paramSig(mm) + ')';
  var ret = _typeName(mm.returnType);
  if (mm.isGetter) return ret + ' get ' + name;
  if (mm.isOperator) return ret + ' operator ' + name + '(' + _paramSig(mm) + ')';
  return ret + ' ' + name + '(' + _paramSig(mm) + ')';
}

// Comma-joined `Type name` parameters (types only if a name is unavailable).
String _paramSig(MethodMirror mm) {
  try {
    var ps = <String>[];
    for (var p in mm.parameters) {
      var t = _typeName(p.type);
      var nm = MirrorSystem.getName(p.simpleName);
      ps.add(nm.length > 0 ? (t + ' ' + nm) : t);
    }
    return ps.join(', ');
  } catch (e) { return ''; }
}

// The class comment, stored in the image alongside its source.
String _classComment(String name) {
  if (_db == null || !_db.isOpen) return '';
  var r = _db.query('SELECT comment FROM decls WHERE name=?', [name]);
  if (r != null && r.length > 0 && r[0].length > 0 && r[0][0] != null) return r[0][0];
  return '';
}

String _setComment(List a) {
  if (_db != null && _db.isOpen) {
    _db.exec('UPDATE decls SET comment=? WHERE name=?', [a[1].toString(), a[0].toString()]);
  }
  return 'ok';
}

// --- Find (over the image) --------------------------------------------------
// Name search: classes and members whose name contains `term`. Records
// [class, memberSig] ('' = the class itself).
List _find(String term) {
  var t = term.toLowerCase();
  var out = <List>[];
  _decls.forEach((name, src) {
    if (name.toLowerCase().contains(t)) out.add([name, '']);
    for (var m in _splitMembers(src)) {
      var sig = _memberSig(m);
      if (sig.toLowerCase().contains(t)) out.add([name, sig]);
    }
  });
  return out;
}

// Senders: classes whose source references `term` as an identifier.
List _senders(String term) {
  var re = new RegExp(r'\b' + _reEscape(term) + r'\b');
  var out = <List>[];
  _decls.forEach((name, src) {
    if (re.hasMatch(src)) out.add([name, '']);
  });
  return out;
}

String _reEscape(String s) {
  return s.replaceAllMapped(new RegExp(r'[.*+?^${}()|[\]\\]'), (m) => '\\' + m.group(0));
}

// --- the app surface (APP_PANE_PLAN.md §3-§4) --------------------------------
// What a user app is handed as `ui`. It never touches dart:cocoa: it appends
// draw-nothing COMMANDS to a batch, and the UI isolate — the only one allowed
// near AppKit — materialises real NSViews from them. Handlers stay here as
// closures keyed by widget id; the UI isolate only ever sends (id, kind, value)
// back, and holds no handle belonging to the app.
//
// Coordinates are TOP-LEFT (the UI isolate flips them): nobody should have to
// learn AppKit's origin to put one button under another. Frames are absolute;
// laying out a keypad is an ordinary Dart loop, which is the point — layout is
// the app's code, not a framework's.
class AppSurface {
  final String name;                 // 'pane' — the host it currently lives on
  final int gen;
  final SendPort _out;
  double width, height;              // the surface's size, for the app's layout

  List _batch = <dynamic>[];
  Map<String, Function> _handlers = <String, Function>{};
  bool _flushPending = false;

  AppSurface(this.name, this.gen, this._out, this.width, this.height);

  void _cmd(List c) {
    _batch.add(c);
    // An app that updates from a Timer has no command to ride out on, so a
    // mutation schedules its own flush. Microtasks drain after every message
    // AND every timer callback, so this covers both without an explicit call.
    if (!_flushPending) {
      _flushPending = true;
      scheduleMicrotask(flush);
    }
  }

  void _on(String id, String kind, Function fn) {
    if (fn != null) _handlers[id + '/' + kind] = fn;
  }

  Function handlerFor(String id, String kind) {
    var h = _handlers[id + '/' + kind];
    return h;
  }

  /// Send everything queued as one message. Idempotent.
  void flush() {
    _flushPending = false;
    if (_batch.isEmpty) return;
    var b = _batch;
    _batch = <dynamic>[];
    _out.send(<dynamic>['appui', name, gen, b]);
  }

  // -- the widget vocabulary: title, label, field, button, checkbox, slider,
  //    popup, secure, progress, box ------------------------------------------

  /// The surface's title — the window title once popped out.
  void title(String text) { _cmd(<dynamic>['title', text]); }

  /// Remove every widget. `build()` starts from here.
  void clear() {
    _handlers.clear();
    _cmd(<dynamic>['clear']);
  }

  void label(String id, {String text: '', List frame, String align: 'left'}) {
    _cmd(<dynamic>['add', 'label', id,
        <String, dynamic>{'text': text, 'frame': frame, 'align': align}]);
  }

  void field(String id, {String text: '', List frame, String align: 'left',
                         bool readOnly: false, Function onText, Function onEnter}) {
    _on(id, 'text', onText);
    _on(id, 'enter', onEnter);
    _cmd(<dynamic>['add', 'field', id,
        <String, dynamic>{'text': text, 'frame': frame, 'align': align,
                          'readOnly': readOnly}]);
  }

  void button(String id, {String title: '', List frame, bool enabled: true,
                          Function onClick}) {
    _on(id, 'click', onClick);
    _cmd(<dynamic>['add', 'button', id,
        <String, dynamic>{'title': title, 'frame': frame, 'enabled': enabled}]);
  }

  // -- more controls: the handler is wrapped so the app gets a TYPED value
  //    (bool for a checkbox, double for a slider), not the raw wire string. ---

  /// A labelled on/off switch. onToggle receives a bool.
  void checkbox(String id, {String label: '', List frame, bool value: false,
                            bool enabled: true, Function onToggle}) {
    if (onToggle != null) _on(id, 'toggle', (s) => onToggle(s.toString() == 'true'));
    _cmd(<dynamic>['add', 'checkbox', id, <String, dynamic>{
        'title': label, 'frame': frame, 'value': value, 'enabled': enabled}]);
  }

  /// A horizontal slider over [min,max]. onSlide receives a double.
  void slider(String id, {List frame, double min: 0.0, double max: 1.0,
                          double value: 0.0, bool enabled: true, Function onSlide}) {
    if (onSlide != null) _on(id, 'slide', (s) => onSlide(double.parse(s.toString(), (_) => value)));
    _cmd(<dynamic>['add', 'slider', id, <String, dynamic>{
        'frame': frame, 'min': min, 'max': max, 'value': value, 'enabled': enabled}]);
  }

  /// A drop-down of choices. onSelect receives the chosen title (a String).
  void popup(String id, {List items, List frame, String selected,
                         bool enabled: true, Function onSelect}) {
    if (onSelect != null) _on(id, 'select', (s) => onSelect(s == null ? '' : s.toString()));
    _cmd(<dynamic>['add', 'popup', id, <String, dynamic>{
        'items': items, 'frame': frame, 'selected': selected, 'enabled': enabled}]);
  }

  /// A password field — like `field`, but the characters are hidden.
  void secure(String id, {String text: '', List frame, Function onText, Function onEnter}) {
    _on(id, 'text', onText);
    _on(id, 'enter', onEnter);
    _cmd(<dynamic>['add', 'secure', id,
        <String, dynamic>{'text': text, 'frame': frame}]);
  }

  /// A determinate progress bar over [min,max]. Display only; drive it with set.
  void progress(String id, {List frame, double min: 0.0, double max: 1.0,
                            double value: 0.0}) {
    _cmd(<dynamic>['add', 'progress', id, <String, dynamic>{
        'frame': frame, 'min': min, 'max': max, 'value': value}]);
  }

  /// A titled group frame — visual grouping behind other widgets.
  void box(String id, {String title: '', List frame}) {
    _cmd(<dynamic>['add', 'box', id, <String, dynamic>{'title': title, 'frame': frame}]);
  }

  /// A scrolling single-column list. onSelect receives the chosen row's text;
  /// update the rows live with set(id, items: [...]).
  void list(String id, {List items, List frame, Function onSelect}) {
    if (onSelect != null) _on(id, 'select', (s) => onSelect(s == null ? '' : s.toString()));
    _cmd(<dynamic>['add', 'list', id, <String, dynamic>{'items': items, 'frame': frame}]);
  }

  /// A tabbed container. After it, route widgets into a tab with `tab(id, n)`;
  /// their frames are relative to that tab's page. `pane()` routes back to the
  /// surface. The native tab view shows/hides pages for you.
  void tabs(String id, {List items, List frame}) {
    _cmd(<dynamic>['add', 'tabs', id, <String, dynamic>{'items': items, 'frame': frame}]);
  }

  /// Route subsequent widgets into tab `index` of the tabs widget `tabsId`.
  void tab(String tabsId, int index) { _cmd(<dynamic>['container', tabsId, index]); }

  /// A scrolling viewport whose CONTENT can be larger than its frame — so an app
  /// with more controls than fit the pane scrolls. Route widgets into it with
  /// into(id); their frames are relative to the width×height content area.
  void scroll(String id, {List frame, double width: 0.0, double height: 0.0}) {
    _cmd(<dynamic>['add', 'scroll', id,
        <String, dynamic>{'frame': frame, 'cw': width, 'ch': height}]);
  }

  /// Route subsequent widgets into container `id` (a scroll, or a tab's page 0).
  void into(String id) { _cmd(<dynamic>['container', id, 0]); }

  /// Route subsequent widgets back onto the surface itself.
  void pane() { _cmd(<dynamic>['container', null, 0]); }

  /// A drawing surface. Paint it with draw(id, ops) — the same op vocabulary the
  /// demos use. `bg` (an [r,g,b] 0..1) is an optional initial fill. onClick(x,y)
  /// fires on a click, in top-left canvas coordinates.
  void canvas(String id, {List frame, List bg, Function onClick}) {
    if (onClick != null) _on(id, 'click', (s) {
      var parts = s.toString().split(',');
      var x = parts.length > 0 ? double.parse(parts[0], (_) => 0.0) : 0.0;
      var y = parts.length > 1 ? double.parse(parts[1], (_) => 0.0) : 0.0;
      onClick(x, y);
    });
    _cmd(<dynamic>['add', 'canvas', id, <String, dynamic>{'frame': frame, 'bg': bg}]);
  }

  /// Replay a draw list onto a canvas. Ops (coords in top-left points):
  ///   ['clear', r,g,b]                        wipe to a colour (0..1)
  ///   ['rect'|'oval', x,y,w,h, r,g,b, fill?]  fill? true = filled, else stroked
  ///   ['line', x1,y1,x2,y2, r,g,b, width?]
  ///   ['text', x,y, string, size, r,g,b]
  ///   ['blit', x,y, w,h, base64Bmp]           a demos/pixmap.dart Pixmap
  /// Draw lists ACCUMULATE; begin with a 'clear' to wipe.
  void draw(String id, List ops) { _cmd(<dynamic>['draw', id, ops]); }

  // -- layout helpers: pure frame math, no widget. Feed the frames to widgets. -

  /// `count` frames stacked DOWN from (x,y), each w×h, `gap` apart.
  List column(double x, double y, double w, double h, int count, {double gap: 6.0}) {
    var out = <dynamic>[];
    for (var i = 0; i < count; i++) out.add(<double>[x, y + i * (h + gap), w, h]);
    return out;
  }

  /// `count` frames placed ACROSS from (x,y), each w×h, `gap` apart.
  List row(double x, double y, double w, double h, int count, {double gap: 6.0}) {
    var out = <dynamic>[];
    for (var i = 0; i < count; i++) out.add(<double>[x + i * (w + gap), y, w, h]);
    return out;
  }

  /// A cols×rows grid of w×h frames from (x,y), row-major.
  List grid(double x, double y, double w, double h, int cols, int rows,
            {double gapX: 6.0, double gapY: 6.0}) {
    var out = <dynamic>[];
    for (var r = 0; r < rows; r++)
      for (var c = 0; c < cols; c++)
        out.add(<double>[x + c * (w + gapX), y + r * (h + gapY), w, h]);
    return out;
  }

  /// Change a live widget without rebuilding — the fast path a keystroke takes.
  /// value: slider/progress position; checked: a checkbox; selected/items: a popup.
  void set(String id, {String text, String title, bool enabled, num value,
                       bool checked, List items, String selected}) {
    var p = <String, dynamic>{};
    if (text != null) p['text'] = text;
    if (title != null) p['title'] = title;
    if (enabled != null) p['enabled'] = enabled;
    if (value != null) p['value'] = value;
    if (checked != null) p['checked'] = checked;
    if (items != null) p['items'] = items;
    if (selected != null) p['selected'] = selected;
    _cmd(<dynamic>['set', id, p]);
  }

  void remove(String id) { _cmd(<dynamic>['remove', id]); }
  void focus(String id) { _cmd(<dynamic>['focus', id]); }
}

/// Image classes that look like apps: anything declaring a `build` method.
List _appClasses() {
  var out = <String>[];
  // Anchored to a line, so a class whose COMMENT mentions build(ui) — this
  // project's own example does — is not mistaken for an app.
  var re = new RegExp(r'^\s*\w*\s*build\s*\(', multiLine: true);
  _decls.forEach((name, src) { if (re.hasMatch(src)) out.add(name); });
  out.sort();
  return out;
}

// A name, not an expression: this is the one string that reaches wsEval, so it
// is checked to be an identifier before it gets there.
final RegExp _identRe = new RegExp(r'^[A-Za-z_]\w*$');

/// arg: [className, width, height]
String _appRun(List arg) {
  var name = arg[0].toString();
  if (!_identRe.hasMatch(name)) return 'ERR: not a class name: ' + name;
  if (!_decls.containsKey(name)) return 'ERR: no class ' + name + ' in the image';
  _appStop();
  var r = wsEval('_app = new ' + name + '()');
  if (r.startsWith('ERR:')) return 'ERR: could not create ' + name + ' — ' + r;
  _appClass = name;
  _appGen++;
  _surface = new AppSurface('pane', _appGen, _ui,
      (arg[1] as num).toDouble(), (arg[2] as num).toDouble());
  var b = _appBuild(arg);
  return b.startsWith('ERR:') ? b : 'running ' + name;
}

/// (Re)run the app's build() against the current surface — after a start, and
/// after an Accept that changed its class. The INSTANCE is untouched, so a hot
/// reload that morphs it leaves its state intact and only the layout changes.
String _appBuild(List arg) {
  if (_app == null || _surface == null) return 'ERR: no app running';
  if (arg is List && arg.length > 2) {
    _surface.width = (arg[1] as num).toDouble();
    _surface.height = (arg[2] as num).toDouble();
  }
  _surface.clear();
  try {
    _app.build(_surface);
  } catch (e) {
    return 'ERR: ' + _appClass + '.build() threw — ' + e.toString();
  }
  return 'built ' + _appClass;
}

String _appStop() {
  // An app that owns a Timer has to be told, or it keeps ticking against a
  // surface nobody can see. `stop()` is optional — most apps have no teardown —
  // so a missing one is not an error.
  if (_app != null) {
    try { _app.stop(); } catch (e) { }
  }
  if (_surface != null) { _surface.clear(); _surface.flush(); }
  _app = null;
  _surface = null;
  _appClass = null;
  return 'ok';
}

/// arg: [id, kind, value] — delivered as an ordinary request, so the watchdog
/// covers a runaway handler and the debugger's pause guard covers a click made
/// while user code is stopped.
String _appEvent(List arg) {
  if (_surface == null) return 'ERR: no app running';
  var id = arg[0].toString(), kind = arg[1].toString();
  var fn = _surface.handlerFor(id, kind);
  if (fn == null) return 'ignored';
  fn(arg.length > 2 ? arg[2] : null);
  return 'ok';
}
