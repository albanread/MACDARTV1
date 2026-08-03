// run_mst.dart — load+run a .mst file's top-level do-its on the ST VM.
//
// The minimal driver the battery (run_all.sh) uses for the boot and app tiers:
// with the world already booted by --with-st, stRun executes a file's own
// driver lines (a bench's `Bench run: …`, a boot probe). Exits nonzero on an
// ST error so a wrong answer fails the gate. Usage: dart --with-st run_mst.dart f.mst
import 'dart:cocoa';
import 'dart:io';

// Several files run in order, so a test can FILE IN what it is about to drive
// — a game that lives in demos/ is not part of the booted world, and loading it
// is the first line of its own test rather than a special case in the harness.
main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: run_mst.dart file.mst [more.mst …]');
    exit(2);
  }
  for (var path in args) {
    var r = stRun(new File(path).readAsStringSync());
    if (r != null && r.toString().startsWith('ERR')) {
      stderr.writeln(path + ': ' + r.toString());
      exit(1);
    }
  }
}
