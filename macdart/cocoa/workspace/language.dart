// The MACDART workspace LANGUAGE isolate (MACVM's "primary VM"). Its root
// library is this file; `accept` keeps a name->source table of the workspace's
// declarations, regenerates the USER region, and hot-reloads. Do-its evaluate
// against this same live root scope. See WORKSPACE_PLAN.md §1/§5.
import 'dart:cocoa';       // wsEval / wsReload
import 'dart:isolate';
import 'dart:io';

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
  var region = _decls.values.join('\n\n');
  var text = new File(_scratch).readAsStringSync();
  var s = text.indexOf(_begin) + _begin.length;
  var e = text.indexOf(_end);
  var updated = text.substring(0, s) + '\n' + region + '\n' + text.substring(e);
  new File(_scratch).writeAsStringSync(updated);
  var err = wsReload();
  return err.isEmpty ? ('accepted ' + name) : err;
}

String _declName(String d) {
  d = d.trim();
  var m = new RegExp(r'^(?:abstract\s+)?(?:class|enum|typedef)\s+(\w+)').firstMatch(d);
  if (m != null) return m.group(1);
  m = new RegExp(r'(\w+)\s*[=(]').firstMatch(d);
  if (m != null) return m.group(1);
  return 'anon' + _decls.length.toString();
}
