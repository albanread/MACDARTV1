// cog-bench.dart — MACDART's side of the Cog/Pharo head-to-head
// (docs/cog_bench.md). Reuses the workspace's OWN verified benchmark
// bodies — demos/richards.dart, demos/deltablue.dart (ported literally from
// MACVM's Smalltalk, self-checking against MACVM's own published results:
// 2324609297 and 224874) and demos/microbench.dart (the five MACVM
// 42_benchdash.mst micros) — so this script and the GUI Benchmark Dashboard
// can never silently diverge from each other, and both are checksum-
// identical to what MACVM itself asserts.
//
// Protocol matches scripts/cog-bench.st (the checked-in Pharo fileIn,
// generated once from MACVM's world/41a via its mst2st.py — see that file's
// header) and MACVM's own scripts/cog-bench.mst EXACTLY: 10 inner reps per
// timed batch, cold = the first batch (includes JIT compilation), warm =
// the MEDIAN of 6 further batches, microsecond clock
// (Stopwatch.elapsedMicroseconds — millisecond clocks truncate on these
// sub-5ms benches badly enough to invert verdicts; this is exactly the bug
// MACVM's own cog_bench.md documents fixing). Output line shape
// `name cold_us=N warm_us=M`, identical on both sides, so one reduce script
// treats Cog and MACDART identically.
import 'dart:io';

import '../cocoa/workspace/demos/richards.dart';
import '../cocoa/workspace/demos/deltablue.dart';
import '../cocoa/workspace/demos/microbench.dart';

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

int _median(List<int> xs) {
  var s = new List<int>.from(xs)..sort();
  return s[((s.length + 1) ~/ 2) - 1];   // 1-based (n+1)//2, 0-indexed
}

void _check(String name, got, want) {
  if (got != want) {
    print('$name WRONG RESULT $got want $want');
    exit(1);
  }
}

void _run(String name, Function block, want) {
  var sw = new Stopwatch()..start();
  var r;
  for (var i = 0; i < 10; i++) r = block();
  var cold = sw.elapsedMicroseconds;
  _check(name, r, want);
  var times = <int>[];
  for (var b = 0; b < 6; b++) {
    var w = new Stopwatch()..start();
    for (var i = 0; i < 10; i++) r = block();
    times.add(w.elapsedMicroseconds);
  }
  _check(name, r, want);
  print('$name cold_us=$cold warm_us=${_median(times)}');
}

main(List<String> args) {
  var all = <String, Function>{
    'arith':     () => _run('arith    ', benchArith, kBenchArithCheck),
    'fib':       () => _run('fib      ', benchFib, kBenchFibCheck),
    'sieve':     () => _run('sieve    ', benchSieve, kBenchSieveCheck),
    'dict':      () => _run('dict     ', benchDict, kBenchDictCheck),
    'alloc':     () => _run('alloc    ', benchAlloc, kBenchAllocCheck),
    'richards':  () => _run('richards ', benchRichards, 2324609297),
    'deltablue': () => _run('deltablue', benchDeltaBlue, 224874),
  };
  if (args.isNotEmpty) {
    var f = all[args[0]];
    if (f == null) { print('unknown bench ${args[0]}'); exit(2); }
    f();
    return;
  }
  for (var name in ['arith', 'fib', 'sieve', 'dict', 'alloc', 'richards', 'deltablue']) {
    all[name]();
  }
}
