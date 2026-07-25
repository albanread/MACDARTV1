// The MACDART workspace LANGUAGE isolate (MACVM's "primary VM"). Its root
// library is this file; `accept` keeps a name->source table of the workspace's
// declarations, regenerates the USER region, and hot-reloads. Do-its evaluate
// against this same live root scope. See WORKSPACE_PLAN.md §1/§5.
import 'dart:cocoa';       // wsEval / wsReload
import 'dart:isolate';
import 'dart:io';
import 'dart:mirrors';      // live class browser

// ===BEGIN USER===
// ===END USER===

String _scratch;   // this isolate's own rewritable root file (from the spawn arg)
const _begin = '// ===BEGIN USER===';
const _end = '// ===END USER===';
var _decls = <String, String>{};   // name -> source (persists across reloads)

main(List args, SendPort uiPort) {
  _scratch = (args != null && args.length > 0)
      ? args[0]
      : Platform.script.toFilePath();
  var rp = new ReceivePort();
  uiPort.send(rp.sendPort);
  rp.listen((msg) {
    var cmd = msg[0];
    var arg = msg[1];
    SendPort reply = msg[2];
    var out;
    try {
      if (cmd == 'doit') {
        out = _doit(arg);
      } else if (cmd == 'accept') {
        out = _accept(arg);
      } else if (cmd == 'reset') {
        out = _reset(arg);   // arg is a List<String> of declarations (replay)
      } else if (cmd == 'browse') {
        out = _browse();
      } else if (cmd == 'ping') {
        out = 'lang-pong';
      } else {
        out = 'ERR: unknown ' + cmd.toString();
      }
    } catch (e) {
      out = 'ERR: ' + e.toString();
    }
    reply.send(out);
  });
}

// Evaluate a do-it: try it as a single expression; if that won't compile, wrap
// it as an immediately-invoked block so multi-statement code (with a `return`)
// runs too. Returns the value's toString or an "ERR: ..." message.
String _doit(String code) {
  var r = wsEval(code);
  if (r.startsWith('ERR:') && r.contains('error:')) {
    var r2 = wsEval('((){ ' + code + ' })()');
    if (!r2.startsWith('ERR:')) return r2;
  }
  return r;
}

String _accept(String decl) {
  var name = _declName(decl);
  _decls[name] = decl.trim();
  var err = _rebuildAndReload();
  return err.isEmpty ? ('accepted ' + name) : err;
}

// Replace the whole declaration set at once (used by the UI's watchdog to
// replay the accepted declarations into a freshly respawned isolate).
String _reset(List decls) {
  _decls.clear();
  for (var d in decls) {
    var s = d.toString();
    _decls[_declName(s)] = s.trim();
  }
  var err = _rebuildAndReload();
  return err.isEmpty ? ('reset (' + _decls.length.toString() + ' decls)') : err;
}

// Regenerate the USER region from _decls and hot-reload. Returns "" or "ERR:…".
String _rebuildAndReload() {
  var region = _decls.values.join('\n\n');
  var text = new File(_scratch).readAsStringSync();
  var s = text.indexOf(_begin) + _begin.length;
  var e = text.indexOf(_end);
  new File(_scratch).writeAsStringSync(
      text.substring(0, s) + '\n' + region + '\n' + text.substring(e));
  return wsReload();
}

String _declName(String d) {
  d = d.trim();
  var m = new RegExp(r'^(?:abstract\s+)?(?:class|enum|typedef)\s+(\w+)').firstMatch(d);
  if (m != null) return m.group(1);
  m = new RegExp(r'(\w+)\s*[=(]').firstMatch(d);
  if (m != null) return m.group(1);
  return 'anon' + _decls.length.toString();
}

// A live class browser over this isolate's root library (the user's accepted
// declarations), via dart:mirrors. Hides harness internals (underscore, main).
String _browse() {
  var sb = new StringBuffer();
  var root = currentMirrorSystem().isolate.rootLibrary;
  var classes = <String>[], vars = <String>[], funcs = <String>[];
  root.declarations.forEach((sym, decl) {
    var name = MirrorSystem.getName(sym);
    if (name.startsWith('_') || name == 'main') return;
    if (decl is ClassMirror) {
      ClassMirror cm = decl;
      var b = new StringBuffer();
      b.writeln('class ' + name + ' {');
      cm.declarations.forEach((s2, d2) {
        var n2 = MirrorSystem.getName(s2);
        if (d2 is VariableMirror) {
          VariableMirror vm = d2;
          b.writeln('    ' + _typeName(vm.type) + ' ' + n2 + ';');
        } else if (d2 is MethodMirror) {
          MethodMirror mm = d2;
          if (mm.isConstructor) b.writeln('    ' + n2 + '(...)');  // n2 already includes the class name
          else if (mm.isGetter) b.writeln('    get ' + n2);
          else if (mm.isSetter) {} // paired with the getter
          else b.writeln('    ' + n2 + '(...)');
        }
      });
      b.writeln('}');
      classes.add(b.toString());
    } else if (decl is MethodMirror && !decl.isGetter && !decl.isSetter) {
      funcs.add(name + '(...)');
    } else if (decl is VariableMirror) {
      VariableMirror vm = decl;
      vars.add(_typeName(vm.type) + ' ' + name);
    }
  });
  if (classes.isEmpty && vars.isEmpty && funcs.isEmpty) {
    return '(no declarations yet — Accept some code in the Workspace tab)';
  }
  for (var c in classes) sb.writeln(c);
  if (vars.isNotEmpty) {
    sb.writeln('— top-level variables —');
    for (var v in vars) sb.writeln('  ' + v);
    sb.writeln('');
  }
  if (funcs.isNotEmpty) {
    sb.writeln('— top-level functions —');
    for (var f in funcs) sb.writeln('  ' + f);
  }
  return sb.toString();
}

String _typeName(TypeMirror t) {
  try { return MirrorSystem.getName(t.simpleName); } catch (e) { return 'var'; }
}
