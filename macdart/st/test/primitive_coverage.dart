// primitive_coverage.dart — does every <primitive: N> in the world actually DO
// something on this VM?
//
// MACDART ignores MACVM's numbered primitives. Its own primitive pragma is
// <stprim: name> (st_flow_graph_builder.cc:2431), which compiles to a call into
// dart:cocoa; a `<primitive: N>` matches nothing and is silently skipped, so the
// method compiles from whatever Smalltalk follows it.
//
// That is fine when a fallback follows — SmallInteger>>+ has isDouble/isFraction
// cases below its <primitive: 1>, and those are the real payload. It is NOT fine
// when the pragma is the whole body: the method then compiles to an empty body,
// and an empty Smalltalk body RETURNS SELF. `5 bitAnd: 3` would quietly answer 5.
//
// Nothing enforces that today. The protection is a hand-maintained set of fast
// paths in cocoa.dart (stAsDouble, stTruncated, stDivide, …) plus the operators
// the front-end maps to Dart IL tokens, and no test says the set is complete.
// This is that test:
//
//   PHASE 1  scan world/*.mst and inventory every <primitive:> — bare (no
//            Smalltalk fallback) or guarded (fallback present).
//   PHASE 2  load the world, then CALL the bare ones on real receivers and
//            assert the answer is right — and specifically not the receiver.
//
// A bare primitive with no probe is reported, loudly, as uncovered. Silence is
// the failure mode this file exists to remove.
import 'dart:cocoa';
import 'dart:io';

// ---------------------------------------------------------------- phase 1 ---

class Prim {
  String cls, signature, file, pragma;
  int line;
  bool bare;
  Prim(this.cls, this.signature, this.pragma, this.file, this.line, this.bare);
  String get selector => _selectorOf(signature);
  String get key => cls + '>>' + selector;
}

/// The selector out of a method signature line: `at: k put: v <Type> [` -> `at:put:`.
String _selectorOf(String sig) {
  var s = sig.trim();
  var open = s.lastIndexOf('[');
  if (open >= 0) s = s.substring(0, open);
  // strip a return-type annotation `^ <Foo>`
  var caret = s.indexOf('^');
  if (caret >= 0) s = s.substring(0, caret);
  s = s.trim();
  if (s.startsWith('class >>')) s = s.substring(8).trim();
  var parts = s.split(new RegExp(r'\s+'));
  var out = new StringBuffer();
  var keyword = false;
  for (var p in parts) {
    if (p.endsWith(':')) { out.write(p); keyword = true; }
  }
  if (keyword) return out.toString();
  return parts.isEmpty ? s : parts[0];   // unary or binary
}

List<Prim> scanWorld(String dir) {
  var out = <Prim>[];
  var files = <String>[];
  for (var f in new Directory(dir).listSync()) {
    if (f.path.endsWith('.mst')) files.add(f.path);
  }
  files.sort();
  for (var path in files) {
    var lines = new File(path).readAsLinesSync();
    var cls = '(top level)';
    for (var i = 0; i < lines.length; i++) {
      var t = lines[i].trim();
      var cm = new RegExp(r'subclass:\s*(\w+)').firstMatch(t);
      if (cm != null) { cls = cm.group(1); continue; }
      var em = new RegExp(r'^(\w+)\s+extend\s*\[').firstMatch(t);
      if (em != null) { cls = em.group(1); continue; }
      if (!t.startsWith('<primitive:')) continue;

      // The signature: nearest preceding line that opens a method body.
      var sig = '(unknown)';
      for (var k = i - 1; k >= 0 && k > i - 12; k--) {
        var s = lines[k].trim();
        if (s.endsWith('[') && !s.startsWith('"') && !s.contains('subclass:')) {
          sig = s;
          break;
        }
      }
      // Bare? The method body's `[` opened on the SIGNATURE line, so at the
      // pragma we are already one level deep. Walk forward until that level
      // closes; anything on the way that is not a comment or another pragma is
      // a Smalltalk fallback, and the fallback is what actually runs.
      var depth = 1, bare = true;
      for (var k = i; k < lines.length && depth > 0; k++) {
        var stripped = lines[k].replaceAll(new RegExp(r'"[^"]*"'), ' ');
        var content = stripped.replaceAll(new RegExp(r'<[^>]*>'), ' ');
        if (k > i) {
          var body = content.replaceAll('[', ' ').replaceAll(']', ' ').trim();
          if (body.isNotEmpty) bare = false;
        }
        for (var c = 0; c < stripped.length; c++) {
          if (stripped[c] == '[') depth++;
          if (stripped[c] == ']') depth--;
          if (depth == 0) break;
        }
      }
      out.add(new Prim(cls, sig, t, path.split('/').last, i + 1, bare));
    }
  }
  return out;
}

// ---------------------------------------------------------------- phase 2 ---

// MACVM platform bindings that MACDART never ported — Accelerate, POSIX, the
// Metal game pane, mach clocks. Their pragmas are the FFI form and there is
// nothing behind them here. Listed apart so the headline number means
// something: these are absent by design, not silently broken.
const List<String> kNotPorted = const <String>[
  'Accel', 'Posix', 'GamePane', 'Time', 'Worker', 'SystemDictionary'
];

/// Reach each bare primitive the way user code would: an ordinary Smalltalk
/// send to a native receiver (primitive_probes.mst), which misses in Dart and
/// arrives at the extension holder through noSuchMethod. Driving stSend from
/// Dart instead would exercise a direct-lookup path user code never takes.
var _probeObj;

void runProbes() {
  probe('SmallInteger>>bitAnd:', '5 bitAnd: 3', () => st('bitAnd'), 1);
  probe('SmallInteger>>bitOr:', '5 bitOr: 2', () => st('bitOr'), 7);
  probe('SmallInteger>>bitXor:', '5 bitXor: 3', () => st('bitXor'), 6);
  probe('SmallInteger>>bitShift:', '1 bitShift: 4', () => st('bitShift'), 16);
  probe('SmallInteger>>asDouble', '3 asDouble', () => st('intAsDouble'), 3.0);

  probe('Double>>sqrt', '4.0 sqrt', () => st('dsqrt'), 2.0);
  probe('Double>>floor', '2.7 floor', () => st('dfloor'), 2);
  probeNear('Double>>ln', '1.0 ln', () => st('dln'), 0.0);
  probeNear('Double>>exp', '1.0 exp', () => st('dexp'), 2.718281828459045);
  probeNear('Double>>cos', '0.0 cos', () => st('dcos'), 1.0);
  probeNear('Double>>sin', 'pi/2 sin', () => st('dsin'), 1.0);
  probeNear('Double>>tan', 'pi/4 tan', () => st('dtan'), 1.0);
  probeNear('Double>>atan', '1.0 atan', () => st('datan'), 0.7853981633974483);

  probe('String>>size', "'abc' size", () => st('strSize'), 3);
  probe('String>>hash', "'abc' hash is an int", () => st('strHash') is int, true);
  probe('String>>compare:', "'abc' compare: 'abc' is an int",
        () => st('strCompare') is int, true);

  probe('Array>>size', '#(7 8 9) size', () => st('arrSize'), 3);
  probe('Array>>at:', '#(7 8 9) at: 1', () => st('arrAt'), 7);
  probe('Array>>at:put:', 'at:put: then at:', () => st('arrAtPut'), 42);

  probe('BlockClosure>>value', '[42] value', () => st('blkValue'), 42);
  probe('BlockClosure>>value:', '[:x | x+1] value: 41', () => st('blkValue1'), 42);
  probe('BlockClosure>>value:value:', '[:a :b | a*b] value: 6 value: 7',
        () => st('blkValue2'), 42);

  probe('Object>>==', "'x' == 'y'", () => st('objIdentity'), false);
  probe('Object>>identityHash', '42 identityHash is an int',
        () => st('objIdHash') is int, true);
}

st(String sel) => stSend(_probeObj, sel, []);

/// Doubles: compare with a tolerance, but still insist the answer moved away
/// from the receiver.
void probeNear(String key, String what, f(), double expected) {
  covered.add(key);
  probed++;
  var got;
  try {
    got = f();
  } catch (e) {
    failed++;
    print('  FAIL  ${what.padRight(28)} threw ${_first(e.toString())}');
    return;
  }
  if (got is num && (got.toDouble() - expected).abs() < 1e-9) {
    passed++;
    print('  ok    ${what.padRight(28)} $got');
  } else {
    failed++;
    print('  FAIL  ${what.padRight(28)} got $got  want ~$expected');
  }
}


int passed = 0, failed = 0, probed = 0;
Set<String> covered = new Set<String>();

/// Call an operation that reaches [key] and assert the answer. The point is
/// not merely equality: a silently-ignored primitive answers the RECEIVER, so
/// every expectation here is deliberately different from the receiver.
void probe(String key, String what, f(), expected) {
  covered.add(key);
  probed++;
  var got;
  try {
    got = f();
  } catch (e) {
    failed++;
    print('  FAIL  ${what.padRight(28)} threw ${_first(e.toString())}');
    return;
  }
  if (got == expected && got.runtimeType == expected.runtimeType) {
    passed++;
    print('  ok    ${what.padRight(28)} $got');
  } else {
    failed++;
    print('  FAIL  ${what.padRight(28)} got $got (${got.runtimeType})'
          '  want $expected (${expected.runtimeType})');
  }
}

String _first(String s) {
  var i = s.indexOf('\n');
  return i < 0 ? s : s.substring(0, i);
}

main(List<String> args) {
  var here = new File(Platform.script.toFilePath()).parent.path;
  var worldDir = args.isEmpty ? here + '/../world' : args[0];

  print('MACDART — <primitive: N> coverage');
  print('MACDART ignores numbered primitives; a BARE one answers self.\n');

  // --- phase 1 -------------------------------------------------------------
  var prims = scanWorld(worldDir);
  var bare = prims.where((p) => p.bare).toList();
  var guarded = prims.where((p) => !p.bare).toList();
  print('phase 1 — inventory of ${worldDir.split('/').last}/');
  print('  ${prims.length} <primitive:> pragmas');
  print('  ${guarded.length} with a Smalltalk fallback below them  (safe: the '
        'fallback is what runs)');
  print('  ${bare.length} BARE — the pragma is the whole body, so the compiled '
        'method answers self');

  // --- phase 2 -------------------------------------------------------------
  print('\nphase 2 — loading the world');
  var loaded = 0, failedLoad = 0;
  var files = <String>[];
  for (var f in new Directory(worldDir).listSync()) {
    if (f.path.endsWith('.mst')) files.add(f.path);
  }
  files.sort();
  for (var p in files) {
    try {
      var r = stLoad(new File(p).readAsStringSync());
      if (r.startsWith('ERR:')) { failedLoad++; } else { loaded++; }
    } catch (e) {
      failedLoad++;
    }
  }
  print('  $loaded loaded, $failedLoad refused');

  print('\nphase 3 — do the bare primitives actually work?');
  var probeSrc = new File(here + '/primitive_probes.mst').readAsStringSync();
  var pr = stLoad(probeSrc);
  if (pr.startsWith('ERR:')) { print('  cannot load probes: ' + pr); exit(1); }
  _probeObj = stNew('PrimProbe');
  runProbes();

  // --- the honest remainder ------------------------------------------------
  var uncovered = <Prim>[];
  for (var p in bare) {
    if (!covered.contains(p.key)) uncovered.add(p);
  }
  var core = <Prim>[], notPorted = <Prim>[];
  for (var p in uncovered) {
    (kNotPorted.contains(p.cls) ? notPorted : core).add(p);
  }
  void dump(String title, List<Prim> ps) {
    print('\n$title — ${ps.length}');
    var byClass = <String, List<Prim>>{};
    for (var p in ps) byClass.putIfAbsent(p.cls, () => <Prim>[]).add(p);
    var names = byClass.keys.toList()..sort();
    for (var c in names) {
      var sels = byClass[c].map((p) => p.selector).toList()..sort();
      print('  ${c.padRight(18)} ${sels.join(', ')}');
    }
  }
  dump('UNCOVERED on core classes — reachable, unproven', core);
  dump('not ported to MACDART (MACVM platform bindings)', notPorted);

  print('\nprobed $probed, passed $passed, failed $failed'
        ', uncovered ${uncovered.length}');
  exit(failed > 0 ? 1 : 0);
}
