// Demo: Benchmark Dashboard — arith/fib/sieve/dict/alloc + Richards +
// DeltaBlue, cold vs warm
//
// The same graphical benchmark dashboard MACVM runs behind its own GUI
// Benchmarks button (world/42_benchdash.mst), ported to Dart for a direct
// side-by-side comparison. Seven recognizable micro/macro-benchmarks, each
// run 6 times: the first (COLD, amber bar) includes JIT tier-up and
// compilation; the other five give a WARM (green bar) median. One glance
// shows both absolute speed and the JIT warm-up story — the same honest
// framing MACVM's own dashboard argues for, because a single number can be
// misread in exactly the way a stale doc figure gets misread.
//
// Richards and DeltaBlue (demos/richards.dart, demos/deltablue.dart) are
// ported LITERALLY from MACVM's own Smalltalk source (not adapted from any
// other language's port), so they self-verify against the exact numbers
// MACVM's dashboard checks — 2324609297 and 224874 — making this genuinely
// the same workload, not merely a similarly-named one. arith/fib/sieve/
// dict/alloc use the identical iteration counts and problem sizes as
// MACVM's BenchmarkDashboard class-side methods.
import 'dart:async';
import 'dart:isolate';

import 'richards.dart';
import 'deltablue.dart';

// --- the five microbenchmarks (MACVM 42_benchdash.mst parameters) ----------

int benchArith() {
  var s = 0;
  for (var i = 1; i <= 1500000; i++) { s = s + (i * i) - (i * 3); }
  return s;
}

int _fib(int n) => n < 2 ? n : _fib(n - 1) + _fib(n - 2);
int benchFib() => _fib(32);

int _sieveOnce() {
  const int size = 8190;
  var flags = new List<bool>(size + 1);
  for (var x = 1; x <= size; x++) flags[x] = true;
  var count = 0;
  for (var i = 1; i <= size; i++) {
    if (flags[i]) {
      var prime = i + i + 1;
      var k = i + prime;
      while (k <= size) { flags[k] = false; k += prime; }
      count++;
    }
  }
  return count;
}
int benchSieve() {
  var count = 0;
  for (var t = 0; t < 4; t++) count = _sieveOnce();
  return count;
}

int benchDict() {
  var d = new Map<int, int>();
  for (var i = 1; i <= 8000; i++) d[i] = i * i;
  var sum = 0;
  for (var i = 1; i <= 8000; i++) sum += d[i];
  return sum;
}

class _Assoc { final int key; final _Assoc value; _Assoc(this.key, this.value); }
int benchAlloc() {
  _Assoc last;
  for (var i = 1; i <= 200000; i++) last = new _Assoc(i, last);
  return last.key;
}

// The two classic OO macro-benchmarks, driven through their own self-check —
// a wrong answer cannot masquerade as a fast time, in either VM.
int benchRichards() {
  var r = richardsRunOne();
  if (!richardsCheck(r)) throw new StateError('richards: wrong result ($r)');
  return r;
}
int benchDeltaBlue() {
  var r = deltaBlueRunOne();
  if (!deltaBlueCheck(r)) throw new StateError('deltablue: wrong result ($r)');
  return r;
}

const List<String> kNames = const <String>[
  'arith', 'fib', 'sieve', 'dict', 'alloc', 'richards', 'deltablue',
];

// --- timing: run reps times; answer [coldUs, warmMedianUs] -----------------
// The first run alone (cold, with compilation) then the median of the rest
// (warm) — identical methodology to MACVM's time:reps:/median:. MICROSECOND
// resolution, not MACVM's millisecondClock: on this VM several of these
// workloads finish warm in under a millisecond, and a chart full of rounded-
// to-zero bars would hide the exact thing this dashboard exists to show.
// The workload (problem sizes, iteration counts) is unchanged — only the
// measurement's precision improved.
List<int> _time(Function block, int reps) {
  var sw = new Stopwatch()..start();
  block();
  var cold = sw.elapsedMicroseconds;
  var warm = <int>[];
  for (var r = 1; r < reps; r++) {
    var w = new Stopwatch()..start();
    block();
    warm.add(w.elapsedMicroseconds);
  }
  return <int>[cold, _median(warm)];
}
int _median(List<int> xs) {
  if (xs.isEmpty) return 0;
  var sorted = new List<int>.from(xs)..sort();
  var n = sorted.length;
  return sorted[(n + 1) ~/ 2 - 1];
}
String _fmtMs(int us) => (us / 1000.0).toStringAsFixed(us < 10000 ? 2 : 1) + ' ms';

main(List args, SendPort ui) {
  var w = double.parse(args[0]), h = double.parse(args[1]);
  var benches = <Function>[
    benchArith, benchFib, benchSieve, benchDict, benchAlloc,
    benchRichards, benchDeltaBlue,
  ];
  var results = new List<List<int>>(kNames.length);   // null until computed
  var idx = 0;

  void render() {
    var cmds = <List>[];
    cmds.add(<dynamic>['clear', 0.07, 0.07, 0.09]);
    var titleH = 28.0;
    var bandH = (h - titleH) / kNames.length;
    var labelW = 96.0, valueW = 64.0;
    var barX0 = labelW;
    var barMaxW = w - labelW - valueW;
    var maxUs = 1;
    for (var r in results) {
      if (r == null) continue;
      if (r[0] > maxUs) maxUs = r[0];
      if (r[1] > maxUs) maxUs = r[1];
    }
    cmds.add(<dynamic>['text', 8.0, 6.0,
        'Benchmarks — cold (compile) vs warm ms', 13.0, 0.72, 0.75, 0.82]);
    for (var i = 0; i < kNames.length; i++) {
      var top = titleH + i * bandH;
      var barH = (bandH - 10) / 2;
      var coldY = top + 3;
      var warmY = coldY + barH + 2;
      var nameY = top + bandH / 2 + 4;
      cmds.add(<dynamic>['text', 6.0, nameY, kNames[i], 12.0, 0.68, 0.71, 0.78]);
      var r = results[i];
      if (r == null) {
        cmds.add(<dynamic>['text', barX0, nameY, 'running…', 11.0, 0.45, 0.47, 0.52]);
        continue;
      }
      var coldLen = (r[0] * barMaxW / maxUs).clamp(1.0, barMaxW);
      var warmLen = (r[1] * barMaxW / maxUs).clamp(1.0, barMaxW);
      // cold: amber, matching MACVM's rgb(240,150,70)
      cmds.add(<dynamic>['rect', barX0, coldY, coldLen, barH, 0.94, 0.59, 0.27, true]);
      cmds.add(<dynamic>['text', barX0 + coldLen + 5, coldY + barH - 1,
          _fmtMs(r[0]), 11.0, 0.68, 0.71, 0.78]);
      // warm: green, matching MACVM's rgb(80,200,120)
      cmds.add(<dynamic>['rect', barX0, warmY, warmLen, barH, 0.31, 0.78, 0.47, true]);
      cmds.add(<dynamic>['text', barX0 + warmLen + 5, warmY + barH - 1,
          _fmtMs(r[1]), 11.0, 0.68, 0.71, 0.78]);
    }
    ui.send(['draw', cmds]);
  }

  ui.send(['status',
      'running 7 benchmarks — arith/fib/sieve/dict/alloc + Richards + DeltaBlue']);
  render();

  void step() {
    if (idx >= kNames.length) {
      var summary = new StringBuffer('done — ');
      for (var i = 0; i < kNames.length; i++) {
        summary.write(kNames[i]);
        summary.write(' cold=');
        summary.write(_fmtMs(results[i][0]));
        summary.write(' warm=');
        summary.write(_fmtMs(results[i][1]));
        summary.write('  ');
      }
      ui.send(['done', summary.toString()]);
      return;
    }
    var name = kNames[idx];
    ui.send(['status', 'running ' + name + '  (' + (idx + 1).toString() +
        '/' + kNames.length.toString() + ')']);
    results[idx] = _time(benches[idx], 6);
    render();
    idx++;
    new Timer(const Duration(milliseconds: 30), step);
  }
  new Timer(const Duration(milliseconds: 30), step);
}
