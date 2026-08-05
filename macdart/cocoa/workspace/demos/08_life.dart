// Demo: Game of Life — Conway on a torus, cells coloured by age
//
// Four rules on a wrap-around grid: a live cell with two or three live
// neighbours survives, a dead cell with exactly three is born, all else dies.
// That is the entire universe. Each cell also carries an age — bright when just
// born, deepening to green as it persists — so gliders streak and still-lifes
// glow steadily. The grid is a Pixmap, one cell per pixel, blitted up to fill
// the canvas. When the pattern stalls, a few fresh cells rain in to revive it.
//
// SPACE freezes/resumes the automaton (a plain gamestate tick, no GamePane
// needed — the pull protocol ships held keys with every frame regardless of
// which canvas a demo draws on). While frozen, arrows move a cursor (a small
// red outline over the current cell), ENTER toggles that cell alive/dead, and
// C clears the board — so a glider, a glider gun, anything, can be hand-built
// from scratch, then released back into the simulation.
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:math';

import 'pixmap.dart';

const int kSpace = 49, kReturn = 36, kLeftK = 123, kRightK = 124, kDownK = 125, kUpK = 126;
const int kKeyC = 8;             // macOS ANSI 'C'

main(List args, SendPort ui) {
  var w = int.parse(args[0]), h = int.parse(args[1]);
  var gw = w ~/ 5, gh = h ~/ 5;
  var rng = new Random(101);
  var cur = new Uint8List(gw * gh);
  var nxt = new Uint8List(gw * gh);
  var age = new Uint8List(gw * gh);
  var cellW = w / gw, cellH = h / gh;

  void seed(double density) {
    for (var i = 0; i < cur.length; i++) {
      cur[i] = rng.nextDouble() < density ? 1 : 0;
      age[i] = cur[i];
    }
  }
  void sprinkle(int blobs) {
    for (var k = 0; k < blobs; k++) {
      var x = rng.nextInt(gw), y = rng.nextInt(gh);
      for (var dy = -2; dy <= 2; dy++) {
        for (var dx = -2; dx <= 2; dx++) {
          if (rng.nextDouble() < 0.5) {
            cur[((y + dy + gh) % gh) * gw + (x + dx + gw) % gw] = 1;
          }
        }
      }
    }
  }
  seed(0.28);

  var gen = 0, stall = 0, lastPop = -1, pop = 0;
  var frozen = false;
  var cx = gw ~/ 2, cy = gh ~/ 2;      // the edit cursor, in grid cells
  var prevDown = new Set<int>();       // last tick's held keys, for edge-detect
  var moveCooldown = 0;                // throttles cursor movement while held
  var stepAccum = 0;                   // paces the sim to ~60ms/gen under a
  const int kStepEvery = 2;            // ~30ms tick (unchanged from the original)

  void step() {
    pop = 0;
    for (var y = 0; y < gh; y++) {
      var yUp = ((y - 1 + gh) % gh) * gw;
      var yMid = y * gw;
      var yDn = ((y + 1) % gh) * gw;
      for (var x = 0; x < gw; x++) {
        var xL = (x - 1 + gw) % gw, xR = (x + 1) % gw;
        var nb = cur[yUp + xL] + cur[yUp + x] + cur[yUp + xR] +
                 cur[yMid + xL]              + cur[yMid + xR] +
                 cur[yDn + xL] + cur[yDn + x] + cur[yDn + xR];
        var i = yMid + x;
        var alive = cur[i] != 0;
        var live = (alive && (nb == 2 || nb == 3)) || (!alive && nb == 3);
        nxt[i] = live ? 1 : 0;
        if (live) {
          pop++;
          var a = age[i];
          age[i] = alive ? (a < 250 ? a + 6 : 255) : 1;   // survivor ages; birth = 1
        } else {
          age[i] = 0;
        }
      }
    }
    var tmp = cur; cur = nxt; nxt = tmp;

    // keep it lively: a population that stops changing gets a few new blobs
    if (pop == lastPop) stall++; else stall = 0;
    lastPop = pop;
    if (stall > 24 || pop == 0) { sprinkle(6); stall = 0; }
    gen++;
  }

  void render(List<List> cmds) {
    var px = new Pixmap(gw, gh);
    for (var y = 0; y < gh; y++) {
      for (var x = 0; x < gw; x++) {
        var a = age[y * gw + x];
        if (a == 0)      { px.set8(x, y, 6, 8, 14); }        // dead: near-black
        else if (a == 1) { px.set8(x, y, 210, 240, 255); }   // just born: bright
        else {
          var t2 = 255 - a;                                  // young = large
          px.set8(x, y, 30, 90 + (165 * t2 ~/ 255), 70 + (60 * t2 ~/ 255));
        }
      }
    }
    cmds.add(px.blit(0, 0, w, h));
    if (frozen) {
      cmds.add(<dynamic>['rect', cx * cellW, cy * cellH, cellW, cellH,
                         1.0, 0.25, 0.2, false]);
    }
    cmds.add(<dynamic>['text', 10.0, 8.0,
        frozen
            ? 'PAUSED — arrows move, ENTER toggles a cell, C clears, SPACE resumes'
            : 'life  gen ' + gen.toString() + '   pop ' + pop.toString(),
        11.0,
        frozen ? 1.0 : 0.7, frozen ? 0.85 : 0.85, frozen ? 0.3 : 0.7]);
  }

  var ctl = new ReceivePort();
  ui.send(['port', ctl.sendPort]);
  ui.send(['status', gw.toString() + 'x' + gh.toString() +
      ' cells on a torus — SPACE to freeze, then edit with arrows + ENTER']);

  ctl.listen((tick) {
    var down = (tick is List && tick.isNotEmpty && tick[0] is List)
        ? new Set<int>.from((tick[0] as List).map((k) => k as int))
        : new Set<int>();
    bool pressed(int k) => down.contains(k) && !prevDown.contains(k);   // rising edge

    if (pressed(kSpace)) frozen = !frozen;

    if (frozen) {
      if (moveCooldown > 0) moveCooldown--;
      if (moveCooldown == 0) {
        var moved = false;
        if (down.contains(kLeftK))  { cx = (cx - 1 + gw) % gw; moved = true; }
        if (down.contains(kRightK)) { cx = (cx + 1) % gw; moved = true; }
        if (down.contains(kUpK))    { cy = (cy - 1 + gh) % gh; moved = true; }
        if (down.contains(kDownK))  { cy = (cy + 1) % gh; moved = true; }
        if (moved) moveCooldown = 3;      // a light key-repeat throttle
      }
      if (pressed(kReturn)) {
        var i = cy * gw + cx;
        if (cur[i] != 0) { cur[i] = 0; age[i] = 0; }
        else { cur[i] = 1; age[i] = 1; }
      }
      if (pressed(kKeyC)) {
        for (var i = 0; i < cur.length; i++) { cur[i] = 0; age[i] = 0; }
        gen = 0; pop = 0; lastPop = -1; stall = 0;
      }
    } else {
      stepAccum++;
      if (stepAccum >= kStepEvery) { stepAccum = 0; step(); }
    }

    prevDown = down;
    var cmds = <List>[];
    render(cmds);
    ui.send(['draw', cmds]);
  });
}
