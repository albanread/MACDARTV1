// Demo: Wireframe globe — a spinning sphere, latitude and longitude in 3D
//
// A unit sphere sampled on a lat/long grid, rotated by a running spin and a
// fixed tilt, then perspective-projected: near points spread, far ones bunch,
// and the mesh reads as a turning planet. There is no hidden-surface removal —
// instead every vertex is dimmed by its depth, so the far side just fades into
// the background. Rings and meridians are plain lines; the maths is two
// rotations and one divide per vertex, all in this isolate.
//
// Paced by PULL (see workspace.dart): one frame per UI invitation, no Timer —
// at ~340 lines a frame this is the heaviest vector demo, and pull means it
// can never outrun the renderer.
import 'dart:isolate';
import 'dart:math';

main(List args, SendPort ui) {
  var w = double.parse(args[0]), h = double.parse(args[1]);
  var cx = w / 2, cy = h / 2;
  const int LAT = 10, LON = 18;
  const double D = 3.2, FOV = 470.0, tilt = 0.42;
  var n = (LAT + 1) * LON;

  // base unit-sphere vertices, never mutated
  var bx = new List<double>(n), by = new List<double>(n), bz = new List<double>(n);
  for (var i = 0; i <= LAT; i++) {
    var phi = -PI / 2 + PI * i / LAT;
    var cp = cos(phi), sp = sin(phi);
    for (var j = 0; j < LON; j++) {
      var th = 2 * PI * j / LON;
      var k = i * LON + j;
      bx[k] = cp * cos(th); by[k] = sp; bz[k] = cp * sin(th);
    }
  }
  var sx = new List<double>(n), sy = new List<double>(n), br = new List<double>(n);
  var ct = cos(tilt), st = sin(tilt);
  var a = 0.0;

  var ctl = new ReceivePort();
  ui.send(['port', ctl.sendPort]);
  ui.send(['status', 'unit sphere, ' + LAT.toString() + 'x' + LON.toString() +
      ' grid, depth-cued — one frame per UI invitation']);
  ctl.listen((tick) {
    a += 0.02;
    var ca = cos(a), sa = sin(a);
    for (var k = 0; k < n; k++) {
      var x = bx[k], y = by[k], z = bz[k];
      var x1 = x * ca + z * sa;              // spin about the vertical axis
      var z1 = -x * sa + z * ca;
      var y2 = y * ct - z1 * st;             // then a fixed tilt toward us
      var z2 = y * st + z1 * ct;
      var f = FOV / (D + z2);
      sx[k] = cx + x1 * f;
      sy[k] = cy - y2 * f;                   // screen y grows downward
      var b = (1.3 - z2) / 2.6;              // near ~1, far ~0
      br[k] = b < 0.0 ? 0.0 : (b > 1.0 ? 1.0 : b);
    }
    var cmds = <List>[];
    cmds.add(<dynamic>['clear', 0.03, 0.04, 0.07]);
    for (var i = 0; i < LAT; i++) {          // meridians
      for (var j = 0; j < LON; j++) {
        var k = i * LON + j, k2 = (i + 1) * LON + j;
        var b = 0.22 + 0.78 * (br[k] + br[k2]) * 0.5;
        cmds.add(<dynamic>['line', sx[k], sy[k], sx[k2], sy[k2],
                           b * 0.35, b * 0.85, b, 0.6 + b]);
      }
    }
    for (var i = 1; i < LAT; i++) {          // latitude rings (poles degenerate)
      for (var j = 0; j < LON; j++) {
        var k = i * LON + j, k2 = i * LON + (j + 1) % LON;
        var b = 0.22 + 0.78 * (br[k] + br[k2]) * 0.5;
        cmds.add(<dynamic>['line', sx[k], sy[k], sx[k2], sy[k2],
                           b * 0.35, b * 0.85, b, 0.6 + b]);
      }
    }
    cmds.add(<dynamic>['text', 10.0, 8.0, 'wireframe globe', 11.0, 0.5, 0.7, 0.85]);
    ui.send(['draw', cmds]);
  });
}
