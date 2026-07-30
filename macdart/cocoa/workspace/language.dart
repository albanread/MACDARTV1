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
import 'dart:convert';     // BASE64 — ST pixmap RGBA -> BMP for the demos pane
import 'dart:typed_data';  // Uint8List — the BMP buffer
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
  var classCat = <String, String>{};   // name -> first defining file's stem
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
          classCat[name] = _worldCategoryOf(stem);  // system category
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
  // Version stamp: the launcher compares this against the vendored world and
  // re-imports on mismatch (a presence check alone left images STALE).
  if (_db != null && _db.isOpen) {
    var bytes = 0;
    for (var p in files) bytes += new File(p).lengthSync();
    _db.exec('CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT)');
    _db.exec('INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)',
        ['stworld_sig', files.length.toString() + '-' + bytes.toString()]);
  }
  classText.forEach((name, buf) {
    _imageUpsert(name, _decls[name],
        classCat.containsKey(name) ? classCat[name] : 'world');
  });
  doitText.forEach((name, text) { _imageUpsert(name, text, 'boot'); });
  return 'imported ' + classNames.length.toString() + ' classes, ' +
      doitText.length.toString() + ' boot chunks from ' +
      files.length.toString() + ' files';
}


// --- Sprint 14: the browser host (STHostService's data, over the image) ----
// Wire formats per CocoaBrowser2's own parsers: US (char 31) separated
// fields, LF lines, space-separated token lists.
final String _us = new String.fromCharCode(31);

String _sigToSelector(String sig) {
  // 'from: a to: b' -> 'from:to:';  '+ x' -> '+';  'size' -> 'size'
  if (!sig.contains(':')) {
    var t = sig.trim().split(' ');
    return t[0];
  }
  var out = new StringBuffer();
  for (var tok in sig.split(' ')) {
    if (tok.endsWith(':')) out.write(tok);
  }
  return out.toString();
}

String _stSuperOf(String src) {
  var m = _stClassRe.firstMatch(src);
  return m == null ? 'Object' : m.group(1);
}

String _leadingComment(String src) {
  var t = src.trimLeft();
  if (!t.startsWith('"')) return '';
  var end = t.indexOf('"', 1);
  while (end > 0 && end + 1 < t.length && t[end + 1] == '"') {
    end = t.indexOf('"', end + 2);          // "" escapes
  }
  return end < 0 ? '' : t.substring(1, end);
}

_hostSelectors(String src, String side) {
  var out = <String>[];
  for (var m in _stMembers(src)) {
    if (m[0] != (side == 'class' ? 'c' : 'i')) continue;
    out.add(_sigToSelector(m[2].toString()));
  }
  return out;
}

// --- Sprint 15b: ST demos into the dartui demos pane ------------------------
// The ST graphics tier (world files 35/37/42) emits HTML5-canvas-style JSON
// batches; the pixmap tier (36) emits raw RGBA. This isolate RUNS the demo
// (it owns the ST engine) and hands the UI isolate a ready-to-render payload:
//   ['json', canvasJsonString]   — vector, the UI translates to draw-ops
//   ['blit', w, h, base64Bmp]    — a bitmap, one blit op
// Each entry is {class, class-side selector, kind}. All one-shot (a frame),
// so a demo never ties up the language isolate — the UI drives animation by
// re-asking. Anything registered here must exist in the image (world imported).
final List<Map> _kStDemos = <Map>[
  {'name': 'Waves', 'cls': 'WaveChart', 'sel': 'commandsForWidth:height:',
   'kind': 'json', 'inst': true,
   'blurb': 'damped sine field (37_waves.mst) — vector canvas'},
  {'name': 'Mandelbrot', 'cls': 'Mandelbrot', 'sel': 'pixelsForWidth:height:',
   'kind': 'rgba', 'inst': true,
   'blurb': 'the set rendered per-pixel into a Pixmap (35/36) — a blit'},
  {'name': 'Benchmarks', 'cls': 'BenchmarkDashboard',
   'sel': 'chartForWidth:height:', 'kind': 'json', 'inst': false,
   'blurb': 'live cold-vs-warm perf chart (42) — runs the suite, ~seconds'},
];

// Invoke a demo's producer selector — class-side (stInvokeStatic) or on a
// fresh instance (`new` then send), per the demo's `inst` flag.
_stDemoInvoke(Map demo, int w, int h) {
  if (demo['inst'] == true) {
    var obj = stInvokeStatic(demo['cls'], 'new', []);
    return stSend(obj, demo['sel'], [w, h]);
  }
  return stInvokeStatic(demo['cls'], demo['sel'], [w, h]);
}

List _stDemoList() {
  var out = <List>[];
  for (var d in _kStDemos) {
    out.add(<dynamic>[d['name'], d['blurb'], _decls.containsKey(d['cls'])]);
  }
  return out;
}

// `stdemo <name> <w> <h>` -> the payload for that demo at that size.
_stDemo(String arg) {
  var parts = arg.trim().split(' ');
  var name = parts.isNotEmpty ? parts[0] : '';
  var w = parts.length > 1 ? int.parse(parts[1], onError: (_) => 840) : 840;
  var h = parts.length > 2 ? int.parse(parts[2], onError: (_) => 360) : 360;
  Map demo = null;
  for (var d in _kStDemos) { if (d['name'] == name) demo = d; }
  if (demo == null) return 'ERR unknown demo ' + name;
  if (!_decls.containsKey(demo['cls'])) {
    return 'ERR ' + demo['cls'] + ' not in the image (import the world)';
  }
  try {
    if (demo['kind'] == 'json') {
      var js = _stDemoInvoke(demo, w, h);
      // The world's WriteStream (18) builds into a String via at:put:, but
      // Dart Strings are immutable, so `contents` comes back as a List of
      // 1-char pieces — join it into the real JSON text.
      var jstr = (js is List) ? js.join('') : js.toString();
      return <dynamic>['json', jstr];
    }
    var bytes = _stDemoInvoke(demo, w, h);
    return <dynamic>['blit', w, h, _rgbaToBmpBase64(bytes as List, w, h)];
  } catch (e) {
    return 'ERR ' + e.toString();
  }
}

/// RGBA (row-major, top-down) -> base64 of a 24-bit bottom-up BGR BMP — the one
/// format NSImage decodes natively (same encoder as demos/pixmap.dart, fed the
/// ST pixel buffer with its alpha dropped).
String _rgbaToBmpBase64(List px, int width, int height) {
  var rowSize = (3 * width + 3) & ~3;
  var imageSize = rowSize * height;
  var out = new Uint8List(54 + imageSize);
  var b = new ByteData.view(out.buffer);
  out[0] = 0x42; out[1] = 0x4D;
  b.setUint32(2, 54 + imageSize, Endianness.LITTLE_ENDIAN);
  b.setUint32(10, 54, Endianness.LITTLE_ENDIAN);
  b.setUint32(14, 40, Endianness.LITTLE_ENDIAN);
  b.setUint32(18, width, Endianness.LITTLE_ENDIAN);
  b.setUint32(22, height, Endianness.LITTLE_ENDIAN);
  b.setUint16(26, 1, Endianness.LITTLE_ENDIAN);
  b.setUint16(28, 24, Endianness.LITTLE_ENDIAN);
  b.setUint32(34, imageSize, Endianness.LITTLE_ENDIAN);
  b.setUint32(38, 2835, Endianness.LITTLE_ENDIAN);
  b.setUint32(42, 2835, Endianness.LITTLE_ENDIAN);
  var o = 54;
  var n = px.length;
  for (var y = height - 1; y >= 0; y--) {
    var i = y * width * 4;                 // RGBA source stride
    for (var x = 0; x < width; x++) {
      var r = (i < n) ? (px[i] as int) : 0;
      var g = (i + 1 < n) ? (px[i + 1] as int) : 0;
      var bl = (i + 2 < n) ? (px[i + 2] as int) : 0;
      out[o] = bl & 0xff; out[o + 1] = g & 0xff; out[o + 2] = r & 0xff;
      o += 3; i += 4;
    }
    o += rowSize - width * 3;
  }
  return BASE64.encode(out);
}

// Sprint 15: build (or rebuild) the ST browser's container view sized for
// the workspace's Browser tab and answer its RAW VIEW HANDLE (an int) — the
// UI isolate parents it into the tab. ERR when the world is not imported.
String _stBrowserHandle(String arg) {
  if (!_decls.containsKey('Fraction')) {
    return 'ERR the Smalltalk world is not in this image - run stimport '
        '(or start-st-gui.sh)';
  }
  var parts = arg.trim().split(' ');
  var w = parts.length > 0 ? parts[0] : '868';
  var h = parts.length > 1 ? parts[1] : '420';
  var r = stRun('BrowserTabFrame := { 0.0. 0.0. ' + w + '. ' + h + ' }.');
  if (r.startsWith('ERR')) return r;
  try {
    stInvokeStatic('CocoaBrowser2', 'teardownIfAny', []);
  } catch (e) {}
  try {
    var container = stInvokeStatic('CocoaBrowser2', 'containerView', []);
    stInvokeStatic('CocoaBrowser2', 'doRefresh', []);
    var wrap = stSend(container, 'objcHandle', []);
    return (wrap as Cocoa).handle.toString();
  } catch (e) {
    return 'ERR ' + e.toString();
  }
}


/// Sprint 15: real SYSTEM CATEGORIES for the world — the file stems are
/// load-order artifacts; classes browse under Smalltalk-80-style groups.
/// Stored per decl in the DB category column (re-categorizable later).
String _worldCategoryOf(String stem) {
  var n = stem.split('_')[0];
  const kernel = const ['01', '02', '03', '04a', '05', '32', '54'];
  const numbers = const ['06', '07', '08', '23', '23a', '27', '51'];
  const text = const ['09', '12', '13', '41', '53', '57', '58a'];
  const collections = const ['10', '11', '14', '15', '16', '17', '21', '22',
                             '25', '26', '29', '39', '40', '52', '55', '56'];
  const streams = const ['18', '24', '31', '62a'];
  const system = const ['20', '33', '34', '47', '59', '61', '61a', '62', '74'];
  const net = const ['61c', '61d', '75'];
  const support = const ['04', '19', '28', '30', '58'];
  const graphics = const ['35', '36', '37', '38', '43', '44', '45', '46',
                          '48', '48a', '70'];
  const ui = const ['42', '49', '49a', '50', '60', '63', '64', '65', '66',
                    '67', '68', '69', '71', '72', '73'];
  if (kernel.contains(n)) return 'Kernel';
  if (numbers.contains(n)) return 'Numbers';
  if (text.contains(n)) return 'Text';
  if (collections.contains(n)) return 'Collections';
  if (streams.contains(n)) return 'Streams';
  if (system.contains(n)) return 'System';
  if (net.contains(n)) return 'Networking';
  if (support.contains(n)) return 'Support';
  if (graphics.contains(n)) return 'Graphics';
  if (ui.contains(n)) return 'Interface';
  return 'World-Other';
}

/// The displayed/matchable NAME of a mirror member sig: 'int get inDays' ->
/// 'inDays'; 'String toString()' -> 'toString'; operators as-is.
String _dartMemberName(String sig) {
  var s = sig.trim();
  var g = s.indexOf(' get ');
  if (g >= 0) return s.substring(g + 5).trim();
  var st = s.indexOf(' set ');
  if (st >= 0) return s.substring(st + 5).trim().split('(')[0].trim();
  var p = s.indexOf('(');
  if (p >= 0) {
    var head = s.substring(0, p).trim();
    var sp = head.lastIndexOf(' ');
    return sp >= 0 ? head.substring(sp + 1) : head;
  }
  var sp = s.lastIndexOf(' ');
  return sp >= 0 ? s.substring(sp + 1) : s;
}

const List<String> _kMirrorLibs = const [
  'dart:core', 'dart:cocoa', 'dart:collection', 'dart:async', 'dart:math',
  'dart:convert', 'dart:io', 'dart:isolate', 'dart:typed_data',
];

String _hostCall(String verb, List args) {
  if (verb == 'packageTree') {
    // The world grouped by source-file stem (MACVM: a class's category IS
    // its package); user-accepted ST and the Dart classes under 'image'.
    var world = <String, List<String>>{};
    var userSt = <String>[]; var da = <String>[];
    _decls.forEach((n, s) {
      var k = _kindOf(s);
      if (k == 'st-class') {
        var cat = _declCat.containsKey(n) ? _declCat[n] : 'user';
        if (cat == 'user') { userSt.add(n); }
        else {
          world.putIfAbsent(cat, () => <String>[]);
          world[cat].add(n);
        }
      } else if (k == 'class' || k == 'enum') {
        da.add(n);
      }
    });
    var out = new StringBuffer();
    var stems = world.keys.toList()..sort();
    for (var stem in stems) {
      var cs = world[stem]..sort();
      out.write('world' + _us + stem + _us + cs.join(' ') + '\n');
    }
    userSt.sort(); da.sort();
    if (userSt.isNotEmpty) {
      out.write('image' + _us + 'smalltalk' + _us + userSt.join(' ') + '\n');
    }
    out.write('image' + _us + 'dart' + _us + da.join(' ') + '\n');
    // The LIVE snapshot core, via mirrors — READ-ONLY (the user's tier 1).
    // Name collisions with image/world decls are skipped (the flat records
    // dictionary is keyed by bare class name; the editable side wins).
    var taken = new Set<String>();
    _decls.forEach((n, s) { taken.add(n); });
    for (var uri in _kMirrorLibs) {
      var cs = <String>[];
      for (var n in _worldClasses(uri)) {
        if (!taken.contains(n.toString())) cs.add(n.toString());
      }
      cs.sort();
      out.write('core' + _us + uri + _us + cs.join(' ') + '\n');
    }
    return out.toString();
  }
  if (verb == 'browseRecords') {
    var out = new StringBuffer();
    // Mirror-backed records first, so image decls of the same name OVERWRITE
    // them in the parsed dictionary (last line wins; editable side rules).
    var taken = new Set<String>();
    _decls.forEach((n, s) { taken.add(n); });
    for (var uri in _kMirrorLibs) {
      for (var cn in _worldClasses(uri)) {
        if (taken.contains(cn.toString())) continue;
        var inst = <String>[]; var stat = <String>[];
        for (var m in _worldClassMembers(uri + '|' + cn.toString())) {
          (m[0] == 'c' ? stat : inst).add(_dartMemberName(m[2].toString()));
        }
        out.write(cn.toString() + _us + 'Object' + _us + _us + _us +
            inst.join(' ') + _us + stat.join(' ') + '\n');
      }
    }
    _decls.forEach((n, s) {
      var k = _kindOf(s);
      if (k == 'st-class') {
        out.write(n + _us + _stSuperOf(s) + _us + _us + _us +
            _hostSelectors(s, 'instance').join(' ') + _us +
            _hostSelectors(s, 'class').join(' ') + '\n');
      } else if (k == 'class' || k == 'enum') {
        var sels = <String>[];
        for (var m in _splitMembers(s)) {
          var sig = _memberSig(m);
          if (sig.length > 0) sels.add(sig);
        }
        out.write(n + _us + 'Object' + _us + _us + _us +
            sels.join(' ') + _us + '\n');
      }
    });
    return out.toString();
  }
  // WRITE verbs (before the class-existence guard: newClass/acceptClass
  // carry source text, and the others do their own lookups).
  if (verb == 'saveMethod') return _hostSaveMethod(args[0].toString(), args[1].toString(), args[2].toString());
  if (verb == 'removeMethod') return _hostRemoveMethod(args[0].toString(), args[1].toString(), args[2].toString());
  if (verb == 'newClass') return _hostAcceptWhole(args[0].toString(), 'created');
  if (verb == 'acceptClass') return _hostAcceptWhole(args[0].toString(), 'accepted');
  if (verb == 'setComment') return _hostSetComment(args[0].toString(), args[1].toString());
  if (verb == 'removeClass') {
    var r = _remove(args[0].toString());
    return r.startsWith('removed') ? 'OK ' + r : 'ERR ' + r;
  }
  var cls = args.isNotEmpty ? args[0].toString() : '';
  var src = _decls.containsKey(cls) ? _decls[cls] : null;
  if (src == null) {
    // A LIVE snapshot-core class (mirrors): read-only synthesized views.
    for (var uri in _kMirrorLibs) {
      if (_worldClasses(uri).contains(cls)) {
        if (verb == 'comment') return '"' + cls + ' - ' + uri + ' (read-only)"';
        if (verb == 'classSource') return _worldClassSrc(uri + '|' + cls);
        if (verb == 'methodSource') {
          var want = args[2].toString();
          for (var m in _worldClassMembers(uri + '|' + cls)) {
            var sig = m[2].toString();
            if (sig == want || _dartMemberName(sig) == want) {
              var body = m[3].toString().trim();
              return (body.isEmpty ? sig + ';' : body) + '\n\n// ' + uri +
                  ' - snapshot core, read-only (mirrors carry signatures, '
                  'not bodies)';
            }
          }
          return 'ERR no such member ' + cls + '.' + want;
        }
      }
    }
    return 'ERR no such class ' + cls;
  }
  if (verb == 'comment') {
    var c = _leadingComment(src);
    return c.isEmpty ? '"' + cls + '"' : c;
  }
  if (verb == 'classSource') return src;
  if (verb == 'methodSource') {
    var side = args[1].toString();
    var sel = args[2].toString();
    if (_isStAny(src)) {
      for (var m in _stMembers(src)) {
        if (m[0] != (side == 'class' ? 'c' : 'i')) continue;
        if (_sigToSelector(m[2].toString()) == sel) return m[3].toString();
      }
    } else {
      for (var m in _splitMembers(src)) {
        if (_memberSig(m) == sel) return m;
      }
    }
    return 'ERR no source for ' + cls + '>>' + sel;
  }
  return 'ERR unknown host verb ' + verb;
}

// --- the browser's WRITE flows (Sprint 14b) — every path funnels through
// _acceptMany, the same checked accept the workspace buttons use (parse
// check, store, reload, persist; refused source never reaches the image).
String _acceptOne(String declText) {
  var r = _acceptMany(<String>[declText]);
  return r.startsWith('accepted') ? '' : r;
}

String _hostAcceptWhole(String text, String what) {
  var name = _declName(text.trim());
  var err = _acceptOne(text.trim());
  if (err.isNotEmpty) return 'ERR ' + err;
  return 'OK ' + what + ' ' + name.toString();
}

String _hostSaveMethod(String cls, String side, String text) {
  var src = _decls.containsKey(cls) ? _decls[cls] : null;
  if (src == null) {
    for (var uri in _kMirrorLibs) {
      if (_worldClasses(uri).contains(cls)) {
        return 'ERR ' + uri + ' is snapshot core - read-only';
      }
    }
    return 'ERR no class ' + cls;
  }
  if (!_isStAny(src)) {
    // Sprint 15: a DART class — splice by member signature, through the
    // same checked accept (the browser edits BOTH languages).
    var t2 = text.trim();
    if (t2.isEmpty) return 'ERR empty method source';
    var sig = _memberSig(t2);
    if (sig.isEmpty) return 'ERR cannot read a Dart member signature from the text';
    var out = null;
    for (var m in _splitMembers(src)) {
      if (_memberSig(m) == sig) {
        out = src.replaceFirst(m.trim(), t2);
        break;
      }
    }
    if (out == null) {
      var close = src.lastIndexOf('}');
      if (close < 0) return 'ERR cannot find the class closing brace';
      out = src.substring(0, close) + '  ' + t2 + '\n' + src.substring(close);
    }
    var err = _acceptOne(out);
    return err.isEmpty ? 'OK ' + sig : 'ERR ' + err;
  }
  var t = text.trim();
  if (t.isEmpty) return 'ERR empty method source';
  var probe = t.split('\n')[0].trim();
  if (!probe.endsWith('[')) {
    return 'ERR a method starts \'selector ... [\' (got: ' + probe + ')';
  }
  var sig = probe.substring(0, probe.length - 1).trim();
  var isCs = new RegExp(r'^\w+\s+class\s*>>').hasMatch(sig);
  if (side == 'class' && !isCs) {
    t = cls + ' class >> ' + t;
    sig = cls + ' class >> ' + sig;
  } else if (side != 'class' && isCs) {
    return 'ERR class-side source while the instance side is selected';
  }
  var bare = sig
      .replaceAll(new RegExp(r'^\w+\s+class\s*>>\s*'), '')
      .replaceAll(new RegExp(r'\^\s*<[^>]*>\s*$'), '')
      .replaceAll(new RegExp(r'<[^>]*>'), '')
      .replaceAll(new RegExp(r'\s+'), ' ')
      .trim();
  var sel = _sigToSelector(bare);
  var body = t.split('\n').map((s) => '    ' + s).join('\n');

  var lines = src.split('\n');
  var wantSide = (side == 'class') ? 'c' : 'i';
  var hit = null;
  for (var m in _stMemberIndex(lines)) {
    if (m['side'] == wantSide && m['sel'] == sel) hit = m;
  }
  var out;
  if (hit != null) {
    out = lines.sublist(0, hit['start']).join('\n') + '\n' + body + '\n' +
        lines.sublist(hit['end'] + 1).join('\n');
  } else {
    // insert before the decl's final closing bracket line
    var close = -1;
    for (var i = lines.length - 1; i >= 0; i--) {
      if (lines[i].trim() == ']') { close = i; break; }
    }
    if (close < 0) return 'ERR cannot find the class closing bracket';
    out = lines.sublist(0, close).join('\n') + '\n' + body + '\n' +
        lines.sublist(close).join('\n');
  }
  var err = _acceptOne(out);
  return err.isEmpty ? 'OK ' + sel : 'ERR ' + err;
}

String _hostRemoveMethod(String cls, String side, String sel) {
  var src = _decls.containsKey(cls) ? _decls[cls] : null;
  if (src == null) return 'ERR no class ' + cls;
  var lines = src.split('\n');
  var wantSide = (side == 'class') ? 'c' : 'i';
  var hit = null;
  for (var m in _stMemberIndex(lines)) {
    if (m['side'] == wantSide && m['sel'] == sel) hit = m;
  }
  if (hit == null) return 'ERR no such method ' + cls + '>>' + sel;
  var out = lines.sublist(0, hit['start']).join('\n') + '\n' +
      lines.sublist(hit['end'] + 1).join('\n');
  var err = _acceptOne(out);
  return err.isEmpty ? 'OK removed ' + sel : 'ERR ' + err;
}

String _hostSetComment(String cls, String comment) {
  var src = _decls.containsKey(cls) ? _decls[cls] : null;
  if (src == null) return 'ERR no class ' + cls;
  var quoted = '"' + comment.replaceAll('"', '""') + '"';
  var t = src.trimLeft();
  var out;
  if (t.startsWith('"')) {
    var end = t.indexOf('"', 1);
    while (end > 0 && end + 1 < t.length && t[end + 1] == '"') {
      end = t.indexOf('"', end + 2);
    }
    out = (end < 0) ? (quoted + '\n' + t) : (quoted + t.substring(end + 1));
  } else {
    out = quoted + '\n' + t;
  }
  var err = _acceptOne(out);
  return err.isEmpty ? 'OK comment saved' : 'ERR ' + err;
}

main(List args, SendPort uiPort) {
  _ui = uiPort;
  // Smalltalk `Transcript show:`/`cr` lines land in the GUI Transcript.
  stTranscriptSink = (line) {
    _ui.send(<dynamic>['tr', line.toString()]);
  };
  // Sprint 13b: the ACTION HOST — AppKit-side trampolines post
  // [ticket, selector] here (Dart_PostCObject, any thread, fails closed on a
  // dead port); the world's MacvmDelegate registry dispatches to the ST
  // receiver. Handler errors land in the Transcript, never unwind the loop.
  var stActions = new ReceivePort();
  stActions.listen((msg) {
    try {
      if (msg is List && msg.length >= 2) {
        stActionDispatch(msg[0], msg[1].toString(),
            msg.length > 2 ? msg[2] : null);
      }
    } catch (e) {
      _ui.send(<dynamic>['tr', 'action handler error: ' + e.toString()]);
    }
  });
  stActionPort = stActions.sendPort;
  stHostHook = (verb, argv) => _hostCall(verb.toString(), argv);

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
      else if (cmd == 'classes') out = _classNames(arg.toString());
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
      else if (cmd == 'stbrowser') out = _stBrowserHandle(arg.toString());
      else if (cmd == 'stdemo') out = _stDemo(arg.toString());
      else if (cmd == 'stdemos') out = _stDemoList();
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
  _declCat.clear();
  var rows = _db.query(
      'SELECT name, source, category FROM decls ORDER BY name', const []);
  if (rows != null) {
    for (var r in rows) {
      _decls[r[0]] = r[1];
      _declCat[r[0]] = (r.length > 2 && r[2] != null) ? r[2].toString() : 'user';
    }
  }
  _rebuildAndReload();   // make the loaded declarations live
}

final Map<String, String> _declCat = <String, String>{};  // name -> package

void _imageUpsert(String name, String source, [String category]) {
  var cat = category != null
      ? category
      : (_declCat.containsKey(name) ? _declCat[name] : 'user');
  _declCat[name] = cat;
  if (_db != null && _db.isOpen) {
    _db.exec('INSERT OR REPLACE INTO decls(name,kind,category,source) VALUES(?,?,?,?)',
        [name, _kindOf(source), cat, source]);
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
List _classNames([String filter = '']) {
  var out = <String>[];
  _decls.forEach((name, src) {
    var k = _kindOf(src);
    var isDart = (k == 'class' || k == 'enum');
    var isSt = (k == 'st-class');
    if (filter == 'dart' && !isDart) return;
    if (filter == 'st' && !isSt) return;
    if (filter == '' && !(isDart || isSt)) return;
    out.add(name);
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

// Sprint 12/14: split a (possibly merged) ST class decl into members —
// [side 'c'|'i', 'method', signature, source] per method. A member's source
// runs from its header line to the line where ITS OWN bracket closes
// (depth-tracked through 'strings', "comments", and $c literals) — slicing
// to the next header leaked trailing comments, the class's closing bracket,
// even the next merged chunk into the pane ("follow-on text").
int _stMemberEndLine(List<String> lines, int start) {
  var depth = 0;
  var inStr = false, inCmt = false;
  for (var li = start; li < lines.length; li++) {
    var s = lines[li];
    for (var i = 0; i < s.length; i++) {
      var ch = s[i];
      if (inStr) {
        if (ch == "'") {
          if (i + 1 < s.length && s[i + 1] == "'") { i++; } else { inStr = false; }
        }
        continue;
      }
      if (inCmt) {
        if (ch == '"') inCmt = false;
        continue;
      }
      if (ch == "'") { inStr = true; continue; }
      if (ch == '"') { inCmt = true; continue; }
      if (ch == r'$') { i++; continue; }        // $[ char literal
      if (ch == '[') depth++;
      if (ch == ']') {
        depth--;
        if (depth == 0) return li;
      }
    }
  }
  return lines.length - 1;
}

/// Every method in the decl: {side 'c'|'i', sel, sig, start, end} (line idx,
/// inclusive). The shared index under _stMembers, methodSource, and the
/// browser's Accept splices.
List<Map> _stMemberIndex(List<String> lines) {
  var out = <Map>[];
  var i = 0;
  while (i < lines.length) {
    var t = lines[i].trimRight();
    var lt = t.trimLeft();
    var indent = t.length - lt.length;
    var isHeader = t.endsWith('[') &&
        indent <= 4 &&
        !lt.startsWith('"') &&
        !lt.contains('subclass:') &&
        !new RegExp(r'^\w+(\s+class)?\s+extend\s*\[$').hasMatch(lt);
    if (!isHeader) { i++; continue; }
    var end = _stMemberEndLine(lines, i);
    var head = lines[i].trim();
    var sig = head.substring(0, head.length - 1).trim();
    sig = sig.replaceAll(new RegExp(r'\^\s*<[^>]*>\s*$'), '');
    sig = sig.replaceAll(new RegExp(r'<[^>]*>'), '');
    sig = sig.replaceAll(new RegExp(r'\s+'), ' ').trim();
    var side = sig.contains('class >>') ? 'c' : 'i';
    var bare = sig.replaceAll(new RegExp(r'^\w+\s+class\s*>>\s*'), '');
    if (bare.isNotEmpty) {
      out.add({'side': side, 'sel': _sigToSelector(bare), 'sig': bare,
               'start': i, 'end': end});
    }
    i = end + 1;
  }
  return out;
}

List<List> _stMembers(String src) {
  var lines = src.split('\n');
  var out = <List>[];
  for (var m in _stMemberIndex(lines)) {
    out.add([m['side'], 'method', m['sig'],
             lines.sublist(m['start'], m['end'] + 1).join('\n')]);
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

List _worldLibs() {
  var out = <String>[];
  currentMirrorSystem().libraries.forEach((uri, lib) {
    var u = uri.toString();
    // Smalltalk libraries are NOT mirror-safe: their classes have no
    // TokenStream, and ClassMirror.members routes through EnsureIsFinalized
    // -> the Dart parser, which CRASHES the process. ST classes browse
    // through the User App path (image decls) instead.
    if (u.startsWith('st:')) return;
    out.add(u);
  });
  out.sort();
  return out;
}

List _worldClasses(String libUri) {
  var out = <String>[];
  if (libUri.startsWith('st:')) return out;   // mirror-unsafe (no TokenStream)
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

List _worldClassMembers(String qualified) {   // "libUri|ClassName"
  if (qualified.startsWith('st:')) return const <List>[];  // mirror-unsafe
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
  if (qualified.startsWith('st:')) return '';              // mirror-unsafe
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
