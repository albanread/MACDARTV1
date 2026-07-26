// Demo: Bouncing balls — physics in this isolate, pixels via the UI isolate
//
// The shape every demo shares: this file is a standalone program, spawned into
// its OWN isolate by the workspace's Demos menu. It computes, and sends draw
// commands over [ui]; the UI isolate — the only one allowed near AppKit —
// renders them. This isolate never imports dart:cocoa.
import 'dart:async';
import 'dart:isolate';
import 'dart:math';

main(List args, SendPort ui) {
  var w = double.parse(args[0]), h = double.parse(args[1]);
  var rng = new Random(7);
  // Each ball: x, y, vx, vy, radius, r, g, b   (y grows downward)
  var balls = <List<double>>[];
  for (var i = 0; i < 14; i++) {
    balls.add(<double>[
      rng.nextDouble() * (w - 80.0) + 40.0,
      rng.nextDouble() * (h / 2),
      rng.nextDouble() * 7.0 - 3.5,
      rng.nextDouble() * 3.0,
      rng.nextDouble() * 15.0 + 8.0,
      rng.nextDouble() * 0.7 + 0.3,
      rng.nextDouble() * 0.7 + 0.3,
      rng.nextDouble() * 0.7 + 0.3,
    ]);
  }
  var frames = 0;
  ui.send(['status', '14 balls under gravity, 30fps — Stop kills this isolate']);
  new Timer.periodic(const Duration(milliseconds: 33), (t) {
    frames++;
    var cmds = <List>[];
    cmds.add(<dynamic>['clear', 0.09, 0.09, 0.13]);
    for (var b in balls) {
      b[3] += 0.35;                                  // gravity
      b[0] += b[2];
      b[1] += b[3];
      var r = b[4];
      if (b[0] < r)     { b[0] = r;     b[2] = -b[2]; }
      if (b[0] > w - r) { b[0] = w - r; b[2] = -b[2]; }
      if (b[1] > h - r) { b[1] = h - r; b[3] = -b[3] * 0.97; b[2] *= 0.995; }
      if (b[1] < r)     { b[1] = r;     b[3] = -b[3]; }
      cmds.add(<dynamic>['oval', b[0] - r, b[1] - r, r * 2, r * 2,
                         b[5], b[6], b[7], true]);
    }
    cmds.add(<dynamic>['text', 10.0, 8.0, 'bounce — frame ' + frames.toString(),
                       11.0, 0.65, 0.68, 0.78]);
    ui.send(['draw', cmds]);
  });
}
