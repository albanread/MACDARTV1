// Demo: Strange attractor — de Jong, drawn by density in an accumulation buffer
//
// Two coupled equations, x' = sin(a·y) − cos(b·x), y' = sin(c·x) − cos(d·y),
// iterated tens of thousands of times a frame. No single point matters; the
// ORBIT does — where it lingers, hits pile up in a per-pixel counter, and
// pushing that density through a sqrt curve turns a cloud of dots into smoky
// filaments. The four parameters drift on slow sines, so the whole form
// breathes from one attractor into the next. Sine is a table; the buffer
// blits up whole as one Pixmap (demos/pixmap.dart).
import 'dart:async';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'pixmap.dart';

main(List args, SendPort ui) {
  var w = int.parse(args[0]), h = int.parse(args[1]);
  const int kScale = 2;
  var pw = w ~/ kScale, ph = h ~/ kScale;
  const int kIter = 320000;

  // de Jong space is mostly dull; these six quadruples are known to bloom into
  // rich clouds. We ease from one to the next (smoothstep), dwelling on each
  // full attractor, so the animation is a tour of good ones — never a wander
  // into a sparse periodic orbit.
  var keys = <List<double>>[
    <double>[ 1.400, -2.300,  2.400, -2.100],
    <double>[ 2.010, -2.530,  1.610, -0.330],
    <double>[-2.700, -0.090, -0.860, -2.200],
    <double>[-0.827, -1.637,  1.659, -0.943],
    <double>[-2.240,  0.430, -0.650, -2.430],
    <double>[ 1.641,  1.902,  0.316,  1.525],
  ];
  const int kHold = 90;                       // frames to morph between two keys

  // Real sin/cos here, NOT a lookup table: this map is chaotic, so quantising
  // the trig to a few thousand steps collapses the orbit onto a discrete
  // lattice — pretty dots, but not the true continuous attractor. The honest
  // trig is the whole demo's compute, and the JIT swallows 320k of them a frame.
  var counts = new Int32List(pw * ph);
  var scale = ph * 0.23;
  var ox = pw / 2.0, oy = ph / 2.0;
  var frame = 0;

  ui.send(['status', kIter.toString() + ' iterations/frame into a ' +
      pw.toString() + 'x' + ph.toString() + ' density buffer']);
  new Timer.periodic(const Duration(milliseconds: 40), (tm) {
    var t = frame * 0.02;
    var seg = frame ~/ kHold;
    var f = (frame % kHold) / kHold;
    var s = f * f * (3.0 - 2.0 * f);          // smoothstep: ease at each key
    var k0 = keys[seg % keys.length];
    var k1 = keys[(seg + 1) % keys.length];
    var a = k0[0] + (k1[0] - k0[0]) * s;
    var b = k0[1] + (k1[1] - k0[1]) * s;
    var c = k0[2] + (k1[2] - k0[2]) * s;
    var d = k0[3] + (k1[3] - k0[3]) * s;

    for (var i = 0; i < counts.length; i++) counts[i] = 0;
    var x = 0.1, y = 0.1, maxc = 1;
    for (var it = 0; it < kIter; it++) {
      var nx = sin(a * y) - cos(b * x);
      var ny = sin(c * x) - cos(d * y);
      x = nx; y = ny;
      if (it < 20) continue;                 // let the transient settle first
      var px = (ox + x * scale).toInt();
      var py = (oy + y * scale).toInt();
      if (px < 0 || py < 0 || px >= pw || py >= ph) continue;
      var idx = py * pw + px;
      var v = counts[idx] + 1;
      counts[idx] = v;
      if (v > maxc) maxc = v;
    }

    // hue drifts too; density -> brightness through log (lifts faint filaments
    // that a single dense crossing point would otherwise crush to black)
    var hueA = t * 0.3;
    var hr = 0.35 + 0.65 * (sin(hueA)         * 0.5 + 0.5);
    var hg = 0.35 + 0.65 * (sin(hueA + 2.094) * 0.5 + 0.5);
    var hb = 0.35 + 0.65 * (sin(hueA + 4.188) * 0.5 + 0.5);
    var inv = 1.0 / log(maxc + 1.0);
    var out = new Pixmap(pw, ph);
    for (var i = 0; i < counts.length; i++) {
      var cc = counts[i];
      if (cc == 0) continue;                 // background stays the Pixmap's black
      var bnt = log(cc + 1.0) * inv * 1.15;   // 0..1, log-scaled, mid-tones lifted
      if (bnt > 1.0) bnt = 1.0;
      var yy = i ~/ pw, xx = i - yy * pw;
      out.set8(xx, yy, (bnt * hr * 255).toInt(),
                       (bnt * hg * 255).toInt(),
                       (bnt * hb * 255).toInt());
    }
    ui.send(['draw', <List>[
      out.blit(0, 0, w, h),
      <dynamic>['text', 10.0, 8.0,
          'de Jong  a=' + a.toStringAsFixed(2) + '  b=' + b.toStringAsFixed(2) +
          '  c=' + c.toStringAsFixed(2) + '  d=' + d.toStringAsFixed(2),
          11.0, 0.7, 0.72, 0.8],
    ]]);
    frame++;
  });
}
