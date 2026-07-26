// MACDART workspace — LANGUAGE isolate (MACVM's "primary VM"). The user app's
// source lives in a SQLite "image" (the source of truth); at boot we load it on
// top of the VM snapshot (the "world") and hot-reload it live. Accept UPSERTs the
// image + reloads (morphing instances); a watchdog respawn just re-reads the DB.
// Serves the browser's data (classes / members / source) from the image, and a
// read-only view of the world via dart:mirrors. Talks to the UI over SendPort.
import 'dart:cocoa';       // wsEval / wsReload / Db
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

main(List args, SendPort uiPort) {
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
      else if (cmd == 'vmstats') out = wsVmStats();
      else if (cmd == 'ping') out = 'lang-pong';
      else out = 'ERR: unknown ' + cmd.toString();
    } catch (e) {
      out = 'ERR: ' + e.toString();
    }
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

String _doit(String code) {
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

String _accept(String decl) {
  var name = _declName(decl);
  _decls[name] = decl.trim();
  _imageUpsert(name, decl.trim());
  var err = _rebuildAndReload();
  return err.isEmpty ? ('accepted ' + name) : err;
}

// GUI Accept: the editor's top-level declarations, redefining by name; UPSERT
// each into the image, then reload ONCE (live instances of a changed class morph).
String _acceptMany(List decls) {
  var names = <String>[];
  for (var d in decls) {
    var s = d.toString().trim();
    var name = _declName(s);
    _decls[name] = s;
    _imageUpsert(name, s);
    names.add(name);
  }
  var err = _rebuildAndReload();
  return err.isEmpty ? ('accepted ' + names.join(', ')) : err;
}

// Live-only accept: make declarations live in THIS isolate without touching the
// image. The editor's "Add to World" — try a class in the running world without
// committing it, so the next boot (or a watchdog respawn, which re-reads the
// image) comes back without it. Deliberately not persisted.
String _acceptLive(List decls) {
  var names = <String>[];
  for (var d in decls) {
    var s = d.toString().trim();
    var name = _declName(s);
    _decls[name] = s;
    names.add(name);
  }
  var err = _rebuildAndReload();
  return err.isEmpty ? ('live (not saved): ' + names.join(', ')) : err;
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
  var region = _decls.values.join('\n\n');
  var text = new File(_scratch).readAsStringSync();
  var s = text.indexOf(_begin) + _begin.length;
  var e = text.indexOf(_end);
  new File(_scratch).writeAsStringSync(
      text.substring(0, s) + '\n' + region + '\n' + text.substring(e));
  return wsReload();
}

// --- browser data (user app) ------------------------------------------------
List _classNames() {
  var out = <String>[];
  _decls.forEach((name, src) {
    var k = _kindOf(src);
    if (k == 'class' || k == 'enum') out.add(name);
  });
  out.sort();
  return out;
}

List _memberList(String className) {
  var src = _decls[className];
  if (src == null) return const <String>[];
  var out = <String>[];
  for (var m in _splitMembers(src)) {
    var sig = _memberSig(m);
    if (sig.length > 0) out.add(sig);
  }
  return out;
}

String _kindOf(String s) {
  s = s.trim();
  if (new RegExp(r'^(?:abstract\s+)?class\b').hasMatch(s)) return 'class';
  if (s.startsWith('enum ')) return 'enum';
  if (s.startsWith('typedef ')) return 'typedef';
  if (new RegExp(r'^[\w<>\[\],\s]+\s\w+\s*\(').hasMatch(s)) return 'function';
  return 'variable';
}

String _declName(String d) {
  d = d.trim();
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
