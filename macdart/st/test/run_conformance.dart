// run_conformance.dart — the driver for type_conformance.mst.
//
// Loads the probes, calls each one, and checks the answer against what this VM
// is DECLARED to do. Two verdicts, deliberately distinguished:
//
//   ok        the probe matches real Smalltalk semantics.
//   ok(dart)  the probe matches a KNOWN, ACCEPTED deviation — Dart's semantics
//             showing through the mapping. Recorded so a change is visible.
//
// Anything else is a FAIL and exits non-zero. A "deviation" line that starts
// agreeing with Smalltalk is *also* a FAIL: the mapping changed, and this file
// is where that gets noticed.
import 'dart:cocoa';
import 'dart:io';

int passed = 0, failed = 0;

// expected == the observed value we accept. `why` non-null marks a deviation
// from standard Smalltalk and says what the Smalltalk answer would have been.
void check(String name, actual, expected, [String why]) {
  var okay = actual == expected;
  // Distinguish 1 from 1.0 and true from 'true': type is half the point here.
  if (okay && actual != null && expected != null) {
    okay = actual.runtimeType == expected.runtimeType;
  }
  if (okay) {
    passed++;
    var tag = why == null ? 'ok      ' : 'ok(dart)';
    var note = why == null ? '' : '   <- Smalltalk: ' + why;
    print('  $tag ${name.padRight(20)} ${_show(actual)}$note');
  } else {
    failed++;
    print('  FAIL     ${name.padRight(20)} got ${_show(actual)}'
          '  want ${_show(expected)}');
  }
}

String _show(v) {
  if (v == null) return 'nil';
  if (v is String) return "'" + v + "' (" + v.runtimeType.toString() + ")";
  return v.toString() + ' (' + v.runtimeType.toString() + ')';
}

void section(String s) { print('\n$s'); }

main(List<String> args) {
  var path = args.isEmpty
      ? new File(Platform.script.toFilePath()).parent.path + '/type_conformance.mst'
      : args[0];
  var r = stLoad(new File(path).readAsStringSync());
  if (r.startsWith('ERR:')) { print(r); exit(1); }
  var t = stNew('TypeConformance');
  send(String sel) => stSend(t, sel, []);

  print('MACDART — Smalltalk type conformance');
  print('what Smalltalk\'s types actually ARE on the Dart VM');

  section('integers  ->  Dart int');
  check('40 + 2', send('intAdd'), 42);
  check('6 * 7', send('intMul'), 42);
  check('42 == 42', send('intIdentity'), true);
  check('42 ~~ 43', send('intNotIdentity'), true);
  check('3 < 4 and: 4 >= 4', send('intCompare'), true);
  check('7 \\\\ 2', send('intMod'), 1);
  check('2^30 * 2^30', send('intBig'), 1152921504606846976);
  check('big == big', send('intBigIdentity'), true);

  // Exact division only. `3 / 2` reaches stDivide's Fraction probe, which is
  // fatal without the world loaded (see HAZARD in type_conformance.mst).
  section('division  ->  Smalltalk-exact, NOT Dart');
  check('4 / 2', send('intDivideExact'), 2,
        null);   // Dart\'s own 4/2 is the double 2.0 — this is the ST answer
  check('100 / 10', send('intDivideExact2'), 10);

  section('booleans  ->  Dart bool');
  check('true', send('boolTrue'), true);
  check('true == true', send('boolIdentity'), true);
  check('ifTrue:ifFalse:', send('boolPickFalse'), 'no');
  check('true and: [false]', send('boolAnd'), false);
  check('false or: [true]', send('boolOr'), true);

  section('nil  ->  Dart null');
  check('nil', send('nilValue'), null);
  check('nil == nil', send('nilIdentity'), true);
  check('nil ~~ false', send('nilNotFalse'), true);

  section('floats  ->  Dart double');
  check('1.5 + 1.5', send('floatAdd'), 3.0);
  check('1 + 1.5', send('floatMixed'), 2.5);
  // false, and CORRECT: a Float is a boxed object in Smalltalk too, so two
  // literals are two objects. Identity is not value equality here or there.
  check('1.5 == 1.5', send('floatIdentity'), false);

  section('symbols  ->  interned Symbol objects (StSymbol)');
  check('#foo == #foo', send('symbolIdentity'), true);
  check('#foo = #foo', send('symbolEquals'), true);

  section('strings  ->  Dart String');
  check("'foo' = 'foo'", send('stringEquals'), true);
  // false, and CORRECT: two string literals are two objects in Smalltalk too.
  check("'foo' == 'foo'", send('stringIdentity'), false);

  // The equality representation fix (Phase 1): Symbol is now its OWN class, so
  // Symbol>>= is identity — #foo only equals #foo, never a String of the same
  // spelling. (String>>= is asymmetric the Smalltalk way: 'foo' = #foo IS true,
  // since a Symbol's characters compare equal element-wise.)
  section('symbol vs string  ->  distinct classes now');
  check("#foo = 'foo'", send('symbolVsString'), false);
  check("#foo == 'foo'", send('symbolIsString'), false);

  // The equality representation fix (Phase 2): Character is a flyweight object,
  // not a one-char String — so `$a == $a` is identity-TRUE (the whole point),
  // and `$a = 'a'` is FALSE because a Character is not a String.
  section('characters  ->  flyweight Character objects (StChar)');
  check('\$a = \$a', send('charEquals'), true);
  check('\$a == \$a', send('charIdentity'), true);
  check("\$a = 'a'", send('charVsString'), false);

  section('blocks  ->  Dart closure');
  check('[:x | x+1] value: 41', send('blockValue'), 42);
  check('capture is by reference', send('blockCapture'), 21);

  section('literal collections  ->  Dart List');
  var arr = send('arrayLiteral');
  check('#(1 2 3) is a List', arr is List, true);
  check('#(1 2 3) size', (arr as List).length, 3);
  check('#[1 2 3] is a List', send('byteArrayLiteral') is List, true,
        'a ByteArray, a distinct class');

  section('what stClassOf answers');
  for (var probe in ['anInt', 'aFloat', 'aString', 'aSymbol', 'aChar',
                     'aBool', 'aBlock']) {
    var v = send(probe);
    var cls;
    try { cls = stClassOf(v); } catch (e) { cls = 'ERR ' + e.toString(); }
    print('  info     ${probe.padRight(20)} ${_show(v)}  class=$cls');
  }

  // Both of these used to take the process down (see HAZARD in the .mst); they
  // are checks now because the natives raise a catchable error.
  section('a miss must be catchable, not fatal');
  check('3 / 2 (no world)', send('intDivideInexact'), 1.5,
        'the exact Fraction 3/2 — which IS what it answers once the '
        'world image is loaded');

  var refused = false, detail = '';
  try {
    var out = stSend(send('anInt'), 'become:', [43]);
    detail = 'returned ' + _show(out);
    refused = out != null && out.toString().contains('cannot forward');
  } catch (e) {
    refused = true;                       // refused, and the run survived it
    detail = 'threw: ' + _firstLine(e.toString());
  }
  check('42 become: 43 refused', refused, true);
  print('           $detail');

  var caught = false;
  try {
    stNew('NoSuchClassAnywhere');
  } catch (e) {
    caught = true;
    detail = _firstLine(e.toString());
  }
  check('stNew of a missing class', caught, true);
  print('           $detail');

  print('\npassed $passed, failed $failed');
  exit(failed > 0 ? 1 : 0);
}

String _firstLine(String s) {
  var i = s.indexOf('\n');
  return i < 0 ? s : s.substring(0, i);
}
