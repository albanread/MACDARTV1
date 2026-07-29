// run_macdart.dart — the MACDART side of the ST benchmark (ST_PLAN Sprint 8).
//
// Loads stbench.mst (path = args[0]) into the VM via stLoad and times each
// STBench workload through stNew/stSend — real Smalltalk, JIT-compiled by
// this VM. Then runs the LINE-FOR-LINE native Dart mirror (DBench/DCell,
// same algorithms, instance methods so every call is the same InstanceCall+IC
// machinery) and prints both with the ST/Dart ratio: the ST-front-end tax.
// Same protocol as the MACVM driver: warmup, then best-of-5 wall ms.
import 'dart:cocoa';
import 'dart:io';

// --- the native Dart mirror of STBench/STCell (keep in sync!) ---------------
class DBench {
  fib(n) {
    if (n < 2) return n;
    return this.fib(n - 1) + this.fib(n - 2);
  }

  sumTo(n) {
    var s = 0, i = 1;
    while (i <= n) { s = s + i; i = i + 1; }
    return s;
  }

  blocks(n) {
    var s = 0, i = 0;
    var b = (x) => x + 1;
    while (i < n) { s = s + b(i); i = i + 1; }
    return s;
  }

  alloc(n) {
    var i = 0, c = null;
    while (i < n) { c = new DCell(); c.put(i); i = i + 1; }
    return c.val();
  }
}

class DCell {
  var v;
  put(x) { v = x; }
  val() { return v; }
}

// --- timing (mirrors the MACVM driver: best of 5) ---------------------------
int bestOf5(f) {
  var best = 1 << 30;
  for (var i = 0; i < 5; i++) {
    var sw = new Stopwatch()..start();
    f();
    sw.stop();
    if (sw.elapsedMilliseconds < best) best = sw.elapsedMilliseconds;
  }
  return best;
}

String pad(s, n) { s = s.toString(); while (s.length < n) s = ' ' + s; return s; }

main(List<String> args) {
  var src = new File(args[0]).readAsStringSync();
  var r = stLoad(src);
  if (r.startsWith('ERR:')) { print(r); exit(1); }

  var st = stNew('STBench');
  var d = new DBench();

  // warmup — same as the MACVM driver
  stSend(st, 'fib:', [20]);
  stSend(st, 'sumTo:', [100000]);
  stSend(st, 'blocks:', [10000]);
  stSend(st, 'alloc:', [10000]);
  d.fib(20); d.sumTo(100000); d.blocks(10000); d.alloc(10000);

  // sanity: identical answers before timing anything
  var checks = [
    ['fib', stSend(st, 'fib:', [20]), d.fib(20)],
    ['sum', stSend(st, 'sumTo:', [100000]), d.sumTo(100000)],
    ['blocks', stSend(st, 'blocks:', [10000]), d.blocks(10000)],
    ['alloc', stSend(st, 'alloc:', [10000]), d.alloc(10000)],
  ];
  for (var c in checks) {
    if (c[1] != c[2]) { print('MISMATCH ${c[0]}: st=${c[1]} dart=${c[2]}'); exit(1); }
  }

  var rows = [
    ['fib30      ', () => stSend(st, 'fib:', [30]),      () => d.fib(30)],
    ['sum50m     ', () => stSend(st, 'sumTo:', [50000000]), () => d.sumTo(50000000)],
    ['blocks2m   ', () => stSend(st, 'blocks:', [2000000]), () => d.blocks(2000000)],
    ['alloc2m    ', () => stSend(st, 'alloc:', [2000000]),  () => d.alloc(2000000)],
  ];
  print('bench        ST(ms)  Dart(ms)  ST/Dart');
  for (var row in rows) {
    var stMs = bestOf5(row[1]);
    var dMs = bestOf5(row[2]);
    var ratio = dMs > 0 ? (stMs / dMs).toStringAsFixed(2) : '-';
    print('${row[0]}${pad(stMs, 6)}  ${pad(dMs, 8)}  ${pad(ratio, 7)}');
  }
}
