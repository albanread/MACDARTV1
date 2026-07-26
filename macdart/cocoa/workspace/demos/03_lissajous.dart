// Demo: Lissajous — a drifting parametric curve, hue-cycled along its length
import 'dart:async';
import 'dart:isolate';
import 'dart:math';

/// h in [0,6) -> [r,g,b]; s=v=1. Enough of HSV for a rainbow.
List<double> hue(double h) {
  h = h % 6.0;
  var x = 1.0 - (h % 2.0 - 1.0).abs();
  if (h < 1) return <double>[1.0, x, 0.0];
  if (h < 2) return <double>[x, 1.0, 0.0];
  if (h < 3) return <double>[0.0, 1.0, x];
  if (h < 4) return <double>[0.0, x, 1.0];
  if (h < 5) return <double>[x, 0.0, 1.0];
  return <double>[1.0, 0.0, x];
}

main(List args, SendPort ui) {
  var w = double.parse(args[0]), h = double.parse(args[1]);
  var cx = w / 2, cy = h / 2;
  var rx = w / 2 - 30.0, ry = h / 2 - 30.0;
  var t = 0.0;
  const int kSegs = 180;
  ui.send(['status', 'x = sin(3p + t), y = sin(4p) — the phase drifts']);
  new Timer.periodic(const Duration(milliseconds: 40), (tm) {
    t += 0.02;
    var cmds = <List>[];
    cmds.add(<dynamic>['clear', 0.06, 0.06, 0.09]);
    var px = cx + sin(t) * rx, py = cy + sin(0.0) * ry;
    for (var i = 1; i <= kSegs; i++) {
      var p = i / kSegs * 2 * PI;
      var x = cx + sin(3 * p + t) * rx;
      var y = cy + sin(4 * p) * ry;
      var c = hue(i / kSegs * 6.0 + t);
      cmds.add(<dynamic>['line', px, py, x, y, c[0], c[1], c[2], 2.0]);
      px = x; py = y;
    }
    cmds.add(<dynamic>['text', 10.0, 8.0, 'lissajous 3:4  t=' + t.toStringAsFixed(2),
                       11.0, 0.65, 0.68, 0.78]);
    ui.send(['draw', cmds]);
  });
}
