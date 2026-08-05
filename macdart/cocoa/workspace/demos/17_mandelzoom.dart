// Demo: Mandelbrot zoom (direct GPU memory)
//
// The Mandelbrot twin of 14_julia: the same escape hatch from retained mode
// (GAMEPANE_PLAN.md §6b). The pane opens in DIRECT mode; each frame this
// isolate asks for the back buffer — a Uint8List that IS Metal's shared GPU
// memory (Dart_NewExternalTypedData over [MTLBuffer contents], zero copy) —
// and writes the escape-time set straight into it, one palette index per
// pixel. No draw commands, no base64, no upload, and (unlike the pixmap-blit
// 04_mandelbrot, which splits each frame across 4 worker isolates) no
// isolate-to-isolate handoff either: the whole frame lands in GPU memory by a
// plain list store from the one isolate that owns the buffer.
//
// Where 14_julia holds its view fixed and morphs c around a circle, this one
// dives: the view's half-width shrinks by a constant factor every frame
// toward the seahorse valley — the same target 04_mandelbrot's workers use —
// growing maxIter as it goes so the deepening boundary stays resolved, then
// resets once the view gets too narrow for Double precision to stay clean
// (~1e-13 wide, per 04_mandelbrot's own comment) and dives again: an
// unending zoom, the same shape as MACVM's Smalltalk 45_mandelzoom.mst,
// rebuilt here on the direct-buffer path instead of a palette blit.
import 'dart:cocoa';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

const int W = 384, H = 160;           // the direct framebuffer (2.4:1, like the pane)
const double kCx = -0.743643887037151;  // seahorse valley (04_mandelbrot's kCx/kCy)
const double kCy = 0.131825904205330;
const double kStartScale = 1.6;       // half-width of the view, in complex units
const double kZoomPerFrame = 0.965;
const double kResetFloor = 3e-13;     // Double stays clean down to ~1e-13 (see header)
const int kIterFloor = 100, kIterCeil = 500;

main(List args, SendPort ui) {
  var ctl = new ReceivePort();
  ui.send(['port', ctl.sendPort]);
  ui.send(['draw', <List>[<dynamic>['gpopen', W, H, W, H, 1]]]);   // 1 = direct
  ui.send(['status', W.toString() + 'x' + H.toString() +
      ' Mandelbrot zoom written straight into GPU memory — no copy, no protocol']);

  var setup = false;
  var stride = W;
  var frame = 0;
  var dive = 0;                       // frames into the CURRENT dive (resets with it)
  var scale = kStartScale;

  ctl.listen((tick) {
    var fb = gpBackbuffer();          // Uint8List aliasing GPU memory, or null
    var cmds = <List>[];
    // ALWAYS answer the tick with a frame, else the pull loop stalls; skip the
    // compute until the pane is actually open and handing back a real buffer.
    if (fb is! Uint8List) {
      if (frame < 3) ui.send(['status', 'waiting for direct buffer (fb=' +
          (fb == null ? 'null' : fb.runtimeType.toString()) + ')']);
      ui.send(['draw', cmds]);
      frame++;
      return;
    }

    if (!setup) {
      setup = true;
      var st = gpStat();              // […, direct, stride]
      if (st is List && st.length > 6) stride = st[6];
      // Interior = a deep near-black blue (index 0); 1..255 = a cyclic
      // rainbow band, same palette shape 14_julia builds.
      cmds.add(<dynamic>['gpdpal', 0, 4, 2, 10]);
      for (var i = 1; i < 256; i++) {
        var a = i / 255.0 * 2 * PI * 2.0;         // two rainbow cycles
        var r = (sin(a) * 0.5 + 0.5) * 255.0;
        var g = (sin(a + 2.094) * 0.5 + 0.5) * 255.0;
        var b = (sin(a + 4.188) * 0.5 + 0.5) * 255.0;
        cmds.add(<dynamic>['gpdpal', i, r.toInt(), g.toInt(), b.toInt()]);
      }
    }

    // Deeper dives need more iterations to resolve the boundary, capped so a
    // single-isolate frame stays bounded (04_mandelbrot's 4 workers can afford
    // to grow faster; this one leans on the cardioid/bulb shortcut below).
    var maxIter = min(kIterCeil, kIterFloor + dive * 3 ~/ 2);
    var halfW = scale, halfH = scale * H / W;

    for (var py = 0; py < H; py++) {
      var ci = kCy - halfH + 2.0 * halfH * py / H;
      var ci2 = ci * ci;
      var row = py * stride;
      for (var px = 0; px < W; px++) {
        var cr = kCx - halfW + 2.0 * halfW * px / W;
        int n;
        // Cardioid + period-2 bulb test: classify the two big interior
        // regions for free, without iterating — the same shortcut
        // 04_mandelbrot's workers use, and the reason a deep interior-heavy
        // frame does not dominate the frame time.
        var xq = cr - 0.25;
        var q = xq * xq + ci2;
        if (q * (q + xq) < 0.25 * ci2 || (cr + 1.0) * (cr + 1.0) + ci2 < 0.0625) {
          n = maxIter;
        } else {
          var zr = 0.0, zi = 0.0;
          n = 0;
          while (n < maxIter) {
            var zr2 = zr * zr, zi2 = zi * zi;
            if (zr2 + zi2 > 4.0) break;
            zi = 2.0 * zr * zi + ci;
            zr = zr2 - zi2 + cr;
            n++;
          }
        }
        // interior -> 0 (black); escape -> a cycling band of the palette
        fb[row + px] = n >= maxIter ? 0 : (1 + ((n * 7) % 254));
      }
    }

    // Clear first: the overlay is retained between frames, so an un-cleared
    // counter prints over its own previous value until the digits are blocks.
    cmds.add(<dynamic>['gptextclear']);
    cmds.add(<dynamic>['gptext', 8, 6,
        'dive ' + dive.toString() + '  iter ' + maxIter.toString(), 230, 230, 255]);
    ui.send(['draw', cmds]);          // apply palette/HUD, then present the buffer
    frame++;
    dive++;
    scale *= kZoomPerFrame;
    if (scale < kResetFloor) { scale = kStartScale; dive = 0; }
  });
}
