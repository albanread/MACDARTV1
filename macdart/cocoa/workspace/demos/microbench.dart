// The five microbenchmarks from MACVM's world/42_benchdash.mst
// (BenchmarkDashboard class-side methods) — same iteration counts, same
// problem sizes. Shared by demos/16_benchdash.dart (the GUI dashboard) and
// macdart/scripts/cog-bench.dart (the Cog/Pharo head-to-head), so the two
// can never silently drift apart under a future edit.
// (A library; no demo-title header.)
library microbench;

int benchArith() {
  var s = 0;
  for (var i = 1; i <= 1500000; i++) { s = s + (i * i) - (i * 3); }
  return s;
}
const int kBenchArithCheck = 1124997749998000000;

int _fib(int n) => n < 2 ? n : _fib(n - 1) + _fib(n - 2);
int benchFib() => _fib(32);
const int kBenchFibCheck = 2178309;

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
const int kBenchSieveCheck = 1899;

int benchDict() {
  var d = new Map<int, int>();
  for (var i = 1; i <= 8000; i++) d[i] = i * i;
  var sum = 0;
  for (var i = 1; i <= 8000; i++) sum += d[i];
  return sum;
}
const int kBenchDictCheck = 170698668000;

class _Assoc { final int key; final _Assoc value; _Assoc(this.key, this.value); }
int benchAlloc() {
  _Assoc last;
  for (var i = 1; i <= 200000; i++) last = new _Assoc(i, last);
  return last.key;
}
const int kBenchAllocCheck = 200000;
