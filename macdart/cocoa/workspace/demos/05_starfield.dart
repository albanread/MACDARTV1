// Demo: Starfield — a 3D warp, perspective projection in one isolate
//
// Every star is three numbers (x, y, z); the whole demo is one divide. Each
// frame z shrinks — the star drifts toward the eye — and it is drawn at
// (x/z, y/z) scaled to the canvas: near stars fling outward fast, far ones
// barely move, and that spread IS the depth. Streaks come free by projecting
// last frame's z too and joining the two points. When a star passes the eye
// (z below zNear) it respawns far off with a fresh x, y.
//
// Paced by PULL: the demo hands the UI a tick port and answers each invitation
// with exactly one frame — no Timer here, the renderer's cadence is the clock,
// so 300 stars can never outrun the machine that draws them.
import 'dart:isolate';
import 'dart:math';

main(List args, SendPort ui) {
  var w = double.parse(args[0]), h = double.parse(args[1]);
  var cx = w / 2, cy = h / 2;
  var rng = new Random(12);
  const double zNear = 0.06, zFar = 1.0, scale = 300.0;
  const int kStars = 300;

  // Each star: x, y, z, speed   (x,y in [-1,1]; z the depth toward the eye)
  var stars = <List<double>>[];
  void spawn(List<double> s) {
    s[0] = rng.nextDouble() * 2.0 - 1.0;
    s[1] = rng.nextDouble() * 2.0 - 1.0;
    s[2] = zNear + rng.nextDouble() * (zFar - zNear);
    s[3] = 0.004 + rng.nextDouble() * 0.011;
  }
  for (var i = 0; i < kStars; i++) {
    var s = <double>[0.0, 0.0, 0.0, 0.0];
    spawn(s);
    stars.add(s);
  }

  var frames = 0;
  var ctl = new ReceivePort();
  ui.send(['port', ctl.sendPort]);
  ui.send(['status', kStars.toString() +
      ' stars, one divide each — one frame per UI invitation']);
  ctl.listen((tick) {
    frames++;
    var cmds = <List>[];
    cmds.add(<dynamic>['clear', 0.02, 0.02, 0.05]);
    for (var s in stars) {
      var pz = s[2];
      s[2] -= s[3];
      if (s[2] <= zNear) { spawn(s); continue; }
      var k = scale / s[2];
      var pk = scale / pz;
      var sx = cx + s[0] * k,  sy = cy + s[1] * k;
      var px = cx + s[0] * pk, py = cy + s[1] * pk;
      var b = (zFar - s[2]) / (zFar - zNear);           // 0 far … 1 near
      var bright = 0.25 + b * 0.75;
      cmds.add(<dynamic>['line', px, py, sx, sy,
                         0.70 + 0.30 * bright, 0.78 + 0.22 * bright, 1.0,
                         0.6 + b * 2.0]);
    }
    cmds.add(<dynamic>['text', 10.0, 8.0,
        'starfield — ' + kStars.toString() + ' stars, frame ' + frames.toString(),
        11.0, 0.55, 0.6, 0.75]);
    ui.send(['draw', cmds]);
  });
}
