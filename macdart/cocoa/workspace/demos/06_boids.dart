// Demo: Boids — flocking from three local rules, order with no leader
//
// No boid can see the flock. Each looks only at neighbours inside a radius and
// obeys three urges — separation (don't crowd), alignment (match headings),
// cohesion (drift toward the local centre) — and the murmuration is just what
// those urges add up to across the O(n^2) crowd. Each boid is a little triangle
// pointing where it moves, hue following heading; the edges of the canvas wrap.
//
// Paced by PULL (see workspace.dart): one frame per UI invitation, no Timer —
// the flock can never send faster than the renderer can paint.
import 'dart:isolate';
import 'dart:math';

/// h in [0,6) -> [r,g,b], fully saturated. Enough of HSV for a rainbow.
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
  var rng = new Random(3);
  const int kN = 74;
  const double R = 46.0, sepR = 20.0, maxV = 3.4, minV = 1.7;

  var bx = new List<double>(kN), by = new List<double>(kN);
  var vx = new List<double>(kN), vy = new List<double>(kN);
  for (var i = 0; i < kN; i++) {
    bx[i] = rng.nextDouble() * w;
    by[i] = rng.nextDouble() * h;
    var a = rng.nextDouble() * 2 * PI;
    vx[i] = cos(a) * maxV; vy[i] = sin(a) * maxV;
  }

  var ctl = new ReceivePort();
  ui.send(['port', ctl.sendPort]);
  ui.send(['status', kN.toString() +
      ' boids, three rules, O(n^2) neighbours — one frame per UI invitation']);
  ctl.listen((tick) {
    var cmds = <List>[];
    cmds.add(<dynamic>['clear', 0.05, 0.06, 0.08]);
    for (var i = 0; i < kN; i++) {
      var spx = 0.0, spy = 0.0;              // separation push
      var alx = 0.0, aly = 0.0;              // neighbour velocity sum
      var cox = 0.0, coy = 0.0;              // neighbour position sum
      var n = 0;
      for (var j = 0; j < kN; j++) {
        if (j == i) continue;
        var dx = bx[i] - bx[j], dy = by[i] - by[j];
        var d2 = dx * dx + dy * dy;
        if (d2 > R * R || d2 == 0.0) continue;
        n++;
        alx += vx[j]; aly += vy[j];
        cox += bx[j]; coy += by[j];
        if (d2 < sepR * sepR) {
          var d = sqrt(d2);
          spx += dx / d; spy += dy / d;      // away, weighted by 1/distance
        }
      }
      if (n > 0) {
        alx /= n; aly /= n;
        cox = cox / n - bx[i]; coy = coy / n - by[i];
        vx[i] += spx * 0.85 + (alx - vx[i]) * 0.05 + cox * 0.006;
        vy[i] += spy * 0.85 + (aly - vy[i]) * 0.05 + coy * 0.006;
      }
      var sp = sqrt(vx[i] * vx[i] + vy[i] * vy[i]);
      if (sp > maxV)      { vx[i] = vx[i] / sp * maxV; vy[i] = vy[i] / sp * maxV; }
      else if (sp < minV && sp > 0.0) { vx[i] = vx[i] / sp * minV; vy[i] = vy[i] / sp * minV; }
      bx[i] += vx[i]; by[i] += vy[i];
      if (bx[i] < 0) bx[i] += w; else if (bx[i] >= w) bx[i] -= w;
      if (by[i] < 0) by[i] += h; else if (by[i] >= h) by[i] -= h;

      // draw a triangle: a nose along the heading and two swept-back corners
      var ang = atan2(vy[i], vx[i]);
      var c = hue((ang + PI) / PI * 3.0);
      var nx = bx[i] + cos(ang) * 8.0,       ny = by[i] + sin(ang) * 8.0;
      var lx = bx[i] + cos(ang + 2.6) * 6.0, ly = by[i] + sin(ang + 2.6) * 6.0;
      var rx = bx[i] + cos(ang - 2.6) * 6.0, ry = by[i] + sin(ang - 2.6) * 6.0;
      cmds.add(<dynamic>['line', nx, ny, lx, ly, c[0], c[1], c[2], 1.5]);
      cmds.add(<dynamic>['line', nx, ny, rx, ry, c[0], c[1], c[2], 1.5]);
      cmds.add(<dynamic>['line', lx, ly, rx, ry, c[0], c[1], c[2], 1.5]);
    }
    ui.send(['draw', cmds]);
  });
}
