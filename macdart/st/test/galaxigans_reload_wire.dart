// galaxigans_reload_wire.dart — the hall-of-fame save must not kill the frame loop.
//
// THE BUG THIS LOCKS DOWN ("the high-score page never ends"): a qualifying score
// makes Galaxigans>>enterHiscores persist the hall through the image host. When
// that went through the Browser's acceptEditorClass:, the host HOT-RELOADED the
// whole world — every class loaded fresh, re-initialising class-side state. The
// casualty is GamePane's StepBlock, the class variable holding the per-frame
// closure that IS the frame loop. The driver keeps calling GamePane
// stepWithKeys: every tick (stInvokeStatic, resolved by name, so it finds the
// NEW class), but the new class's StepBlock is nil, so every tick is a no-op:
// the game froze on the frame that saved and the table never counted down. The
// game could not re-arm itself either — its own methods' globals are already
// bound to the pre-reload class, so it writes a variable nobody reads.
//
// galaxigans_smoke cannot see any of this: headless there is no image host, so
// saveHall answers ERR, nothing reloads, and its timeout check passes precisely
// because the hazard never fires. This test INSTALLS a host, so the save path
// runs for real.
//
// It asserts the two halves separately:
//   1. the FIX — the shipped saveHall (storeEditorClass: -> the host's storeClass
//      verb, which persists and makes ONE class live, no world reload) leaves the
//      loop running, and the table times out into attract;
//   2. the ROOT FIX — even a full accept-style world reload leaves the loop
//      running, because onStep:/onReset: hold their blocks in dart:cocoa rather
//      than in GamePane's class variables (world/80_gamepane_wiring.mst), where
//      no reload can nil them. Half 1 protects the save path; half 2 protects
//      every OTHER reload — accepting any class in the Browser while a game is
//      playing used to freeze it the same way.
//
// Usage: dart --with-st galaxigans_reload_wire.dart <galaxigans.mst>
//        <43_gamepane.mst> <80_gamepane_wiring.mst>
import 'dart:cocoa';
import 'dart:io';

int fails = 0;
void check(String name, bool ok, [String detail = '']) {
  if (ok) {
    print('  ok    ' + name);
  } else {
    fails++;
    print('  FAIL  ' + name + (detail.isEmpty ? '' : ' — ' + detail));
  }
}

/// The running game's state. stRun answers its LOAD REPORT, not the value of the
/// expression, so the game has to be read through a real value-returning send.
String summary() =>
    stSend(stInvokeStatic('Galaxigans', 'current', []), 'summary', []).toString();

/// Play a guaranteed-qualifying game over, then run frames until the hall of
/// fame has had its full time plus a margin. Answers the state it ended in:
/// #attract if the loop survived the save, #hiscore if it froze.
String playIntoTheHallAndOut() {
  stRun('Galaxigans launch. '
        'Galaxigans current setScore: 999999. '
        'Galaxigans current danceNow.');
  stRun('1 to: Galaxigans danceLength + 5 do: [ :i | GamePane stepWithKeys: 0 ].');
  var atHandoff = summary();
  stRun('1 to: Galaxigans hiscoreLength + 100 do: [ :i | GamePane stepWithKeys: 0 ].');
  return atHandoff.contains('hiscore') ? summary() : ('NO-HANDOFF ' + atHandoff);
}

main(List<String> args) {
  print('MACDART galaxigans reload-wire test (headless)');
  if (args.length < 3) {
    stderr.writeln('usage: galaxigans_reload_wire.dart <galaxigans.mst>'
        ' <43_gamepane.mst> <80_gamepane_wiring.mst>');
    exit(2);
  }
  var gpSrc = new File(args[1]).readAsStringSync();
  var wiringSrc = new File(args[2]).readAsStringSync();

  var lr = stRun(new File(args[0]).readAsStringSync());
  check('galaxigans loads into the world', !lr.toString().startsWith('ERR'), lr.toString());

  // --- 1. the shipped path: store, no world reload ---------------------------
  // The host the GUI provides, reduced to what the store verb does: parse-check
  // (skipped — the generated source is fixed), make THIS class live, persist.
  var stored = 0;
  stHostHook = (verb, a) {
    if (verb.toString() == 'storeClass') {
      stored++;
      var r = stLoad(a[0].toString());          // one class live; nothing else touched
      return r.toString().startsWith('ERR') ? ('ERR ' + r.toString()) : 'OK stored';
    }
    return 'ERR unhandled ' + verb.toString();
  };
  var end = playIntoTheHallAndOut();
  check('the qualifying score reached the host as a STORE (not an accept)', stored >= 1,
      'storeClass calls=' + stored.toString() +
      ' — saveHall must use storeEditorClass:');
  check('the hall of fame times out into attract', end.contains('attract'), end);
  check('the stored table is live and readable in this session',
      stInvokeStatic('GxHallOfFame', 'table', []).toString().contains('YOU'),
      stInvokeStatic('GxHallOfFame', 'table', []).toString());

  // --- 2. the hazard is DEAD at the root -------------------------------------
  // This half used to assert the opposite — that a world-reloading save freezes
  // the loop — with a note that if it ever stopped freezing, the loop no longer
  // depended on reloaded class-side state. That is now true by construction:
  // onStep:/onReset: keep their blocks in dart:cocoa rather than in GamePane's
  // class variables (world/80_gamepane_wiring.mst), and a reload cannot reach
  // Dart-side state. So half 1's store is no longer the only thing standing
  // between a save and a dead game: even a full accept-style world reload now
  // leaves the frame loop running.
  //
  // The reload must carry the WIRING OVERLAY as well as the corpus file, which
  // is what a real accept does — _stReloadAll rebuilds every decl as one fresh
  // load, so 80 lands with 43 and its methods win. Reloading 43 alone would put
  // the corpus's own class-variable versions back on top and freeze the loop for
  // a reason the GUI can never produce.
  stHostHook = (verb, a) {
    stLoadFresh(gpSrc + '\n\n' + wiringSrc);     // what a full accept does to the loop
    return 'OK test-reload';
  };
  var reloaded = playIntoTheHallAndOut();
  check('a full world reload no longer freezes the loop (blocks live Dart-side)',
      reloaded.contains('attract'), reloaded);

  print(fails == 0 ? 'RELOAD-WIRE OK' : ('RELOAD-WIRE ' + fails.toString() + ' FAILED'));
  exit(fails == 0 ? 0 : 1);
}
