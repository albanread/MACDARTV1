// appui_wire.dart — the ST Apps-player surface, asserted headless (no GUI).
// Runs under --with-st (the world + 81_appui.mst are booted); points the
// stAppUiHook at a RECORDER, drives a mini ST app's build:/callbacks, and
// asserts the exact verb stream the AppSurface would receive — including the
// ST-block handler round-trip that 'appevent' relies on. This is the check
// that the AppUI face, the per-verb helpers, and block passthrough all agree
// before any NSView exists.
import 'dart:cocoa';
import 'dart:io';

int fails = 0;
void check(String name, bool ok, [String detail = '']) {
  if (ok) {
    print('  ok   ' + name);
  } else {
    fails++;
    print('  FAIL ' + name + (detail.isEmpty ? '' : ' - ' + detail));
  }
}

main(List<String> args) {
  print('MACDART appui wire test (headless)');
  var lines = <String>[];
  stTranscriptSink = (l) { lines.add(l.toString()); };
  String taken() { var t = lines.join('\n'); lines.clear(); return t; }

  // --- no hook: an honest, catchable Error (never a silent no-op) -----------
  stRun('''
| ui r |
ui := AppUI new.
r := [ ui title: 'x'. 'no-raise' ] on: Error do: [ :e | 'raised' ].
Transcript showCr: 'nohook=', r.
''');
  var r = taken();
  check('no hook raises a catchable Error', r.contains('nohook=raised'), r);

  // --- the recorder hook -----------------------------------------------------
  var calls = <List>[];
  stAppUiHook = (verb, List a) {
    calls.add(<dynamic>[verb, a]);
    if (verb == 'width') return 852.0;
    if (verb == 'height') return 352.0;
    return null;
  };

  // --- a mini ST app exercising the surface ----------------------------------
  stLoad('''
Object subclass: MiniApp [
    | ui count |
    build: aUi [
        ui := aUi.
        count := 0.
        ui title: 'Mini'.
        ui label: 'l1' text: 'hello' frame: { 8. 8. 100. 18 }.
        ui field: 'f1' text: '41' frame: { 8. 30. 100. 24 }
           onText: [ :s | ui set: 'l1' text: 'typed ', s ].
        ui button: 'b1' title: 'Go' frame: { 8. 60. 60. 26 }
           onClick: [ :x | count := count + 1.
                          ui set: 'l1' text: 'clicks ', count printString ].
        ui set: 'f1' enabled: true.
    ]
]
''');
  stSend(stNew('MiniApp'), 'build:', [stNew('AppUI')]);

  check('verb count', calls.length == 5,
      'got ' + calls.length.toString() + ': ' +
          calls.map((c) => c[0]).toList().toString());
  check('title', calls[0][0] == 'title' && calls[0][1][0] == 'Mini',
      calls[0].toString());
  check('label args', calls[1][0] == 'label' && calls[1][1][0] == 'l1' &&
      calls[1][1][1] == 'hello' && calls[1][1][2] is List &&
      (calls[1][1][2] as List).length == 4 && calls[1][1][3] == 'left',
      calls[1].toString());
  check('field args + block', calls[2][0] == 'field' &&
      calls[2][1][0] == 'f1' && calls[2][1][1] == '41' &&
      calls[2][1][3] is Function && calls[2][1][4] == null,
      calls[2].toString());
  check('button args + block', calls[3][0] == 'button' &&
      calls[3][1][0] == 'b1' && calls[3][1][3] is Function,
      calls[3].toString());
  check('set fans to (id, key, value)', calls[4][0] == 'set' &&
      listStr(calls[4][1]) == '[f1, enabled, true]', calls[4].toString());

  // --- the callback round-trip (what 'appevent' does) ------------------------
  var onText = calls[2][1][3];
  var onClick = calls[3][1][3];
  calls.clear();
  onText('7');                       // the pane fired a text event
  check('onText block ran and set the label',
      calls.length == 1 && calls[0][0] == 'set' &&
          listStr(calls[0][1]) == '[l1, text, typed 7]',
      calls.toString());
  calls.clear();
  onClick(null);
  onClick(null);                     // state lives in the ST instance
  check('onClick mutates ST state across events',
      calls.length == 2 && listStr(calls[1][1]) == '[l1, text, clicks 2]',
      calls.toString());

  // --- width/height + layout math -------------------------------------------
  calls.clear();
  stRun('''
| ui frames |
ui := AppUI new.
Transcript showCr: 'w=', ui width printString.
frames := ui columnX: 8 y: 8 w: 100 h: 24 count: 3 gap: 6.
Transcript showCr: 'f2=', (frames at: 2) printString.
''');
  var out = taken();
  check('width via the hook', out.contains('w=852.0'), out);
  check('column math (pure ST)', out.contains('f2=(8 38 100 24 )'), out);

  stAppUiHook = null;
  print(fails == 0 ? '== APPUI GREEN ==' : '== $fails FAILURE(S) ==');
  exit(fails == 0 ? 0 : 1);
}

String listStr(List l) => '[' + l.map((e) => e.toString()).join(', ') + ']';
