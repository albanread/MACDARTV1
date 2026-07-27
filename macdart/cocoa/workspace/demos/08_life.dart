// Demo: Game of Life — Conway on a torus, cells coloured by age
//
// Four rules on a wrap-around grid: a live cell with two or three live
// neighbours survives, a dead cell with exactly three is born, all else dies.
// That is the entire universe. Each cell also carries an age — bright when just
// born, deepening to green as it persists — so gliders streak and still-lifes
// glow steadily. The grid is a Pixmap, one cell per pixel, blitted up to fill
// the canvas. When the pattern stalls, a few fresh cells rain in to revive it.
import 'dart:async';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'pixmap.dart';

main(List args, SendPort ui) {
  var w = int.parse(args[0]), h = int.parse(args[1]);
  var gw = w ~/ 5, gh = h ~/ 5;
  var rng = new Random(101);
  var cur = new Uint8List(gw * gh);
  var nxt = new Uint8List(gw * gh);
  var age = new Uint8List(gw * gh);

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

  var gen = 0, stall = 0, lastPop = -1;
  ui.send(['status', gw.toString() + 'x' + gh.toString() +
      ' cells on a torus — Life in an isolate']);
  new Timer.periodic(const Duration(milliseconds: 60), (t) {
    var pop = 0;
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
    ui.send(['draw', <List>[
      px.blit(0, 0, w, h),
      <dynamic>['text', 10.0, 8.0,
          'life  gen ' + gen.toString() + '   pop ' + pop.toString(),
          11.0, 0.7, 0.85, 0.7],
    ]]);
    gen++;
  });
}
