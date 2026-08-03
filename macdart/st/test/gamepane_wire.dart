// gamepane_wire.dart — the ST game wire, asserted headless (no GUI, no pane).
// Runs under --with-st (the world + 80_gamepane_wiring.mst are booted); drives
// the ST GamePane/Sound/Tune API and asserts the dart:cocoa command buffer
// fills with the EXACT gp* wire ops a Dart game would ship. This is the check
// that the overlay, the helpers, the sound-preset map, the ABC compiler and
// the run/stepWithKeys: loop all agree — before any pixel exists.
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

bool listEq(a, b) {
  if (a is! List || b is! List || a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] is List || b[i] is List) {
      if (!listEq(a[i], b[i])) return false;
    } else if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}

main(List<String> args) {
  print('MACDART gamepane wire test (headless)');
  stGpReset();

  // --- draw ops ---------------------------------------------------------------
  stRun('''
| g |
g := GamePane new.
g cls: 3.
g point: 10 y: 20 color: 5.
g line: 0 y: 0 to: 100 y: 50 color: 7.
g fill: 4 y: 8 width: 30 height: 12 color: 9.
g disc: 50 y: 60 radius: 15 color: 2.
g paletteAt: 16 r: 255 g: 128 b: 0.
g clearR: 10 g: 20 b: 30.
g present.
''');
  var ops = stGpTake();
  check('draw op count', ops.length == 8, 'got ' + ops.length.toString());
  check('gpcls', listEq(ops[0], ['gpcls', 3]), ops[0].toString());
  check('gppset', listEq(ops[1], ['gppset', 10, 20, 5]), ops[1].toString());
  check('gpline', listEq(ops[2], ['gpline', 0, 0, 100, 50, 7]), ops[2].toString());
  check('gpfill', listEq(ops[3], ['gpfill', 4, 8, 30, 12, 9]), ops[3].toString());
  check('gpdisc', listEq(ops[4], ['gpdisc', 50, 60, 15, 2]), ops[4].toString());
  check('gppal', listEq(ops[5], ['gppal', 16, 255, 128, 0]), ops[5].toString());
  check('clearRGB -> gppal 1 + gpcls 1',
      listEq(ops[6], ['gppal', 1, 10, 20, 30]) && listEq(ops[7], ['gpcls', 1]),
      ops[6].toString() + ' / ' + ops[7].toString());
  check('drain empties the buffer', stGpTake().isEmpty);

  // --- sprites ----------------------------------------------------------------
  stRun('''
| g s |
g := GamePane new.
s := g defineSprite: 'f0f/0f0/f0f'.
s colorAt: 15 r: 255 g: 0 b: 0.
s moveTo: 42 y: 24.
''');
  ops = stGpTake();
  check('sprite op count', ops.length == 4, 'got ' + ops.length.toString());
  var id = ops.length > 0 && ops[0].length > 1 ? ops[0][1] : -1;
  check('gpsprite', ops[0][0] == 'gpsprite' && ops[0][2] == 'f0f/0f0/f0f',
      ops[0].toString());
  check('gpspawn parks offscreen',
      listEq(ops[1], ['gpspawn', id, id, -100, -100]), ops[1].toString());
  check('gpspritepal', listEq(ops[2], ['gpspritepal', id, 15, 255, 0, 0]),
      ops[2].toString());
  check('gpplace', listEq(ops[3], ['gpplace', id, 42, 24, 0, 1.0, 0.0, 1.0]),
      ops[3].toString());

  // --- sounds (preset map + define-once) --------------------------------------
  stRun('Sound click play. Sound click play. Sound coin play.');
  ops = stGpTake();
  // Slots are the TOP of the engine's rack: 64 - presets + index, so the last
  // preset is always slot 63 and the block grows downward as presets are added.
  check('sound op count', ops.length == 5, 'got ' + ops.length.toString());
  check('click defines once then plays',
      listEq(ops[0], ['gpsound', 60, 'click', 0, 0]) &&
          listEq(ops[1], ['gpplay', 60]) && listEq(ops[2], ['gpplay', 60]),
      ops.toString());
  check('coin preset name',
      listEq(ops[3], ['gpsound', 53, 'coin', 0, 0]) &&
          listEq(ops[4], ['gpplay', 53]),
      ops.toString());

  // --- the saucer warble (preset 10, past MACVM's ten) ------------------------
  // The wah is the arcade UFO: two sines 5 Hz apart, beating. Slot 64 would be
  // off the end of the engine's rack, so the point of this check is that the
  // eleventh preset still lands inside it and carries the right name.
  stRun('Sound saucer play. Sound saucer play.');
  ops = stGpTake();
  check('wah defines once then plays',
      ops.length == 3 && listEq(ops[0], ['gpsound', 63, 'wah', 0, 0]) &&
          listEq(ops[1], ['gpplay', 63]) && listEq(ops[2], ['gpplay', 63]),
      ops.toString());

  // --- music (ABC -> gptune once + gpmusic; cached on replay) -----------------
  stRun("(Tune fromAbc: 'X:1\nQ:1/4=120\nK:C\nCDE') playOnce.");
  ops = stGpTake();
  check('tune op count', ops.length == 2, 'got ' + ops.length.toString());
  check('gptune shape',
      ops[0][0] == 'gptune' && ops[0][2] == 120 && ops[0][3] is List &&
          (ops[0][3] as List).length == 24, // 3 notes x on+off x 4 ints
      ops[0].toString());
  check('gpmusic play-once', listEq(ops[1], ['gpmusic', ops[0][1], 1]),
      ops[1].toString());
  stRun("(Tune fromAbc: 'X:1\nQ:1/4=120\nK:C\nCDE') playOnce.");
  ops = stGpTake();
  check('same ABC replays from the cache (gpmusic only)',
      ops.length == 1 && ops[0][0] == 'gpmusic', ops.toString());

  // --- run / stepWithKeys: (the frame loop contract) --------------------------
  check('not running before run', !stGpIsRunning());
  stRun('''
| g |
g := GamePane new.
g onStep: [ (g keyHeld: GamePane keyLeft)
    ifTrue: [ g cls: 1 ] ifFalse: [ g cls: 2 ] ].
g run.
''');
  check('run sets the flag', stGpIsRunning());
  check('run answered the pane', stGpPane() != null);
  stGpTake(); // discard setup remnants
  stInvokeStatic('GamePane', 'stepWithKeys:', [1]); // bit 0 = keyLeft held
  ops = stGpTake();
  check('step with keyLeft draws cls 1', listEq(ops[0], ['gpcls', 1]),
      ops.toString());
  stInvokeStatic('GamePane', 'stepWithKeys:', [0]);
  ops = stGpTake();
  check('step without keys draws cls 2', listEq(ops[0], ['gpcls', 2]),
      ops.toString());
  stRun('GamePane new stop.');
  check('stop clears the flag', !stGpIsRunning());
  stInvokeStatic('GamePane', 'reset', []);
  stGpReset();
  check('reset leaves a clean wire', stGpTake().isEmpty && !stGpIsRunning());

  // --- the real games boot their setup through the wire -----------------------
  stRun('Breakout launch.');
  var breakout = stGpTake();
  check('Breakout launch runs and buffers setup ops', breakout.length > 5,
      'got ' + breakout.length.toString());
  check('Breakout run reached the wire', stGpIsRunning());
  stInvokeStatic('GamePane', 'stepWithKeys:', [0]);
  var frame = stGpTake();
  check('Breakout first frame draws', frame.length > 5,
      'got ' + frame.length.toString());
  stInvokeStatic('GamePane', 'reset', []);
  stGpReset();

  stRun('Worms launch.');
  var worms = stGpTake();
  check('Worms launch runs and buffers setup ops', worms.length > 5,
      'got ' + worms.length.toString());
  check('Worms run reached the wire', stGpIsRunning());
  stInvokeStatic('GamePane', 'stepWithKeys:', [0]);
  frame = stGpTake();
  check('Worms first frame draws', frame.length > 0,
      'got ' + frame.length.toString());
  stInvokeStatic('GamePane', 'reset', []);
  stGpReset();

  print(fails == 0 ? '== WIRE GREEN ==' : '== $fails FAILURE(S) ==');
  exit(fails == 0 ? 0 : 1);
}
