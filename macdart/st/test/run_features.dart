// run_features.dart — the self-validating ST feature-test driver (ST_PORTING
// tier 3). Loads the SUnit-style framework, then each features/test_*.mst
// (which subclasses STestCase), invokes its class-side run (answers the fail
// count), and sums. No external oracle — each test asserts known-correct values.
import 'dart:cocoa';
import 'dart:io';

main(List<String> args) {
  var dir = new File(Platform.script.toFilePath()).parent.path + '/features';
  stLoad(new File(dir + '/framework.mst').readAsStringSync());
  var files = new Directory(dir)
      .listSync()
      .map((e) => e.path)
      .where((p) => p.endsWith('.mst') && !p.endsWith('framework.mst'))
      .toList()
    ..sort();
  print('MACDART feature tests — self-validating (no oracle)\n');
  var totalFail = 0, suites = 0;
  for (var f in files) {
    var src = new File(f).readAsStringSync();
    var m = new RegExp(r'STestCase\s+subclass:\s*(\w+)').firstMatch(src);
    if (m == null) continue;
    stLoad(src);
    suites++;
    try {
      var fails = stInvokeStatic(m.group(1), 'run', []);
      totalFail += (fails is int) ? fails : 1;
    } catch (e) {
      // A Dart-level crash (NoSuchMethod/ApiError) escapes ST's on:do:; record
      // the suite as failed and keep going so one bug can't hide the rest.
      totalFail += 1;
      print('    CRASH ' + m.group(1) + ': ' + e.toString().split('\n').first);
    }
  }
  print('\n== $suites suite(s), ' +
      (totalFail == 0 ? 'ALL GREEN' : '$totalFail FAILURE(S)') + ' ==');
  exit(totalFail == 0 ? 0 : 1);
}
