// Demo: Pong — the canvas's first game: ← → (or A/D) steer, space serves
//
// The whole point of the gamestate protocol: this is just a pull demo whose
// tick it bothers to READ. Every invitation from the UI arrives carrying
// [downKeycodes, modifierFlags] — the keys held at that instant — so the game
// polls its input once per frame, with no event queue and no Timer. Ball off
// the bottom costs a life; the paddle's off-centre hits steer the ball; every
// hit is worth more and a little faster.
import 'dart:isolate';
import 'dart:math';

const int kLeft = 123, kRight = 124, kSpace = 49, kA = 0, kD = 2;

main(List args, SendPort ui) {
  var w = double.parse(args[0]), h = double.parse(args[1]);
  var padW = 110.0, padH = 10.0, r = 7.0;
  var padX = (w - padW) / 2;
  var bx = 0.0, by = 0.0, vx = 0.0, vy = 0.0;
  var score = 0, best = 0, balls = 3, frames = 0;
  var state = 'serve';                   // serve | play | over

  void launch() {
    state = 'play';
    vx = 3.0; vy = -5.2;
  }

  var ctl = new ReceivePort();
  ui.send(['port', ctl.sendPort]);
  ui.send(['status', 'Pong — ← → or A/D steer, space serves; keys ride the tick']);
  ctl.listen((gs) {
    frames++;
    // The tick payload is [downKeycodes, mods]; tolerate anything else (the
    // headless harness sends a bare int) by reading it as "no keys held".
    var down = (gs is List && gs.isNotEmpty && gs[0] is List) ? gs[0] : const [];
    bool held(int k) => down.contains(k);

    if (held(kLeft) || held(kA))  padX -= 7.0;
    if (held(kRight) || held(kD)) padX += 7.0;
    if (padX < 0.0) padX = 0.0;
    if (padX > w - padW) padX = w - padW;

    if (state == 'serve') {
      bx = padX + padW / 2; by = h - padH - 8.0 - r;
      if (held(kSpace)) launch();
    } else if (state == 'over') {
      if (held(kSpace)) {
        score = 0; balls = 3; state = 'serve';
      }
    } else {
      bx += vx; by += vy;
      if (bx < r)     { bx = r;     vx = -vx; }
      if (bx > w - r) { bx = w - r; vx = -vx; }
      if (by < r + 24.0) { by = r + 24.0; vy = -vy; }        // under the score line
      var padY = h - padH - 8.0;
      if (vy > 0 && by + r >= padY && by + r < padY + padH + 6.0 &&
          bx >= padX - r && bx <= padX + padW + r) {
        by = padY - r;
        vy = -vy * 1.03;                                     // a little faster
        vx = vx * 1.03 + (bx - (padX + padW / 2)) * 0.06;    // off-centre steers
        if (vx > 9.0) vx = 9.0; else if (vx < -9.0) vx = -9.0;
        score += 10;
        if (score > best) best = score;
      }
      if (by > h + r) {                                      // off the bottom
        balls--;
        state = balls > 0 ? 'serve' : 'over';
      }
    }

    var cmds = <List>[];
    cmds.add(<dynamic>['clear', 0.05, 0.05, 0.08]);
    cmds.add(<dynamic>['line', 0.0, 24.0, w, 24.0, 0.25, 0.28, 0.38, 1.0]);
    cmds.add(<dynamic>['text', 10.0, 4.0,
        'score ' + score.toString() + '   best ' + best.toString() +
        '   balls ' + balls.toString(), 12.0, 0.8, 0.84, 0.92]);
    cmds.add(<dynamic>['rect', padX, h - padH - 8.0, padW, padH,
                       0.55, 0.75, 1.0, true]);
    if (state != 'over') {
      cmds.add(<dynamic>['oval', bx - r, by - r, r * 2, r * 2,
                         1.0, 0.85, 0.3, true]);
    }
    if (state != 'play' && (frames ~/ 15) % 2 == 0) {        // gentle blink
      cmds.add(<dynamic>['text', w / 2 - 120.0, h / 2 - 10.0,
          state == 'over' ? 'game over — space to restart'
                          : 'space to serve  (← → or A/D)',
          15.0, 0.9, 0.9, 0.95]);
    }
    ui.send(['draw', cmds]);
  });
}
