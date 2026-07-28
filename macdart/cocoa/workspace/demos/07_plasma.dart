// Demo: Plasma — the demoscene classic, sine fields into a cycling palette
//
// Four sine waves — two axis-aligned, one diagonal, one radial — summed per
// pixel give a value in [-4,4]; that indexes a 256-colour palette which itself
// scrolls, so the field writhes and the colours cycle at once. Sines come from
// a lookup table and the radial distance is precomputed once, so a frame costs
// a few array reads per pixel. Computed small, blitted up as one Pixmap image
// (see demos/pixmap.dart) — one message a frame, not one per pixel.
import 'dart:async';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'pixmap.dart';

main(List args, SendPort ui) {
  var w = int.parse(args[0]), h = int.parse(args[1]);
  const int kScale = 4;                       // compute at quarter res, blit up
  var pw = w ~/ kScale, ph = h ~/ kScale;

  // sine LUT, indexed by (phase * kPhase).toInt() & kMask — negatives wrap too
  const int kLut = 2048, kMask = 2047;
  var sinT = new Float64List(kLut);
  for (var i = 0; i < kLut; i++) sinT[i] = sin(i / kLut * 2 * PI);
  final double kPhase = kLut / (2 * PI);
  double si(double phase) => sinT[(phase * kPhase).toInt() & kMask];

  // palette: a smooth cyclic rainbow, RGB channels 120° apart
  var palR = new Uint8List(256), palG = new Uint8List(256), palB = new Uint8List(256);
  for (var i = 0; i < 256; i++) {
    var a = i / 256.0 * 2 * PI;
    palR[i] = ((sin(a)         * 0.5 + 0.5) * 255).toInt();
    palG[i] = ((sin(a + 2.094) * 0.5 + 0.5) * 255).toInt();
    palB[i] = ((sin(a + 4.188) * 0.5 + 0.5) * 255).toInt();
  }
  // radial distance from centre — never changes, so compute it once
  var rad = new Float64List(pw * ph);
  var rcx = pw / 2.0, rcy = ph / 2.0;
  for (var y = 0; y < ph; y++) {
    for (var x = 0; x < pw; x++) {
      var dx = x - rcx, dy = y - rcy;
      rad[y * pw + x] = sqrt(dx * dx + dy * dy);
    }
  }

  var frame = 0;
  ui.send(['status', 'four sine fields at ' + pw.toString() + 'x' + ph.toString() +
      ' → palette-cycled blit']);
  new Timer.periodic(const Duration(milliseconds: 40), (tm) {
    var t = frame * 0.06;
    var shift = (frame * 2) & 255;
    var px = new Pixmap(pw, ph);
    for (var y = 0; y < ph; y++) {
      var sy = si(y * 0.23 - t * 0.7);        // per-row term, hoisted
      var base = y * pw;
      for (var x = 0; x < pw; x++) {
        var v = si(x * 0.19 + t)
              + sy
              + si((x + y) * 0.15 + t * 0.5)
              + si(rad[base + x] * 0.30 - t);
        var idx = (((v + 4.0) * 32.0).toInt() + shift) & 255;
        px.set8(x, y, palR[idx], palG[idx], palB[idx]);
      }
    }
    ui.send(['draw', <List>[px.blit(0, 0, w, h)]]);
    frame++;
  });
}
