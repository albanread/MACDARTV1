// Demo: Julia (direct GPU memory) — CPU→GPU is a write, not a protocol
//
// The escape hatch from retained mode (GAMEPANE_PLAN.md §6b). The pane opens in
// DIRECT mode; each frame this isolate asks for the back buffer — a Uint8List
// that IS Metal's shared GPU memory (Dart_NewExternalTypedData over
// [MTLBuffer contents], zero copy) — and writes the Julia set straight into it,
// one palette index per pixel. No draw commands, no base64, no upload: 60k
// pixels a frame land in GPU memory by a plain list store, and the pull tick
// just says "present". The set morphs because its constant c rides a circle.
//
// This is the one demo that imports dart:cocoa — knowingly, and safely: the
// only native it calls is gpBackbuffer, which hands back a pointer and touches
// no AppKit, so it is legal off thread 0 (unlike the rest of the bridge).
import 'dart:cocoa';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

const int W = 384, H = 160;          // the direct framebuffer (2.4:1, like the pane)

main(List args, SendPort ui) {
  var ctl = new ReceivePort();
  ui.send(['port', ctl.sendPort]);
  ui.send(['draw', <List>[<dynamic>['gpopen', W, H, W, H, 1]]]);   // 1 = direct
  ui.send(['status', W.toString() + 'x' + H.toString() +
      ' Julia written straight into GPU memory — no copy, no protocol']);

  var setup = false;
  var stride = W;
  var frame = 0;
  const int kMaxIter = 48;

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
      // A vivid cyclic palette; index 0 is the interior (near-black).
      cmds.add(<dynamic>['gpdpal', 0, 4, 2, 10]);
      for (var i = 1; i < 256; i++) {
        var a = i / 255.0 * 2 * PI * 2.0;         // two rainbow cycles
        var r = (sin(a) * 0.5 + 0.5) * 255.0;
        var g = (sin(a + 2.094) * 0.5 + 0.5) * 255.0;
        var b = (sin(a + 4.188) * 0.5 + 0.5) * 255.0;
        cmds.add(<dynamic>['gpdpal', i, r.toInt(), g.toInt(), b.toInt()]);
      }
    }

    // c rides a circle of radius 0.7885 — the classic morphing Julia orbit.
    var t = frame * 0.012;
    var cr = 0.7885 * cos(t), ci = 0.7885 * sin(t);
    var scale = 3.0 / H;             // ~[-1.5,1.5] vertically
    var halfW = W / 2, halfH = H / 2;

    for (var py = 0; py < H; py++) {
      var zi0 = (py - halfH) * scale;
      var row = py * stride;
      for (var px = 0; px < W; px++) {
        var zr = (px - halfW) * scale;
        var zi = zi0;
        var n = 0;
        while (n < kMaxIter) {
          var zr2 = zr * zr, zi2 = zi * zi;
          if (zr2 + zi2 > 4.0) break;
          zi = 2.0 * zr * zi + ci;
          zr = zr2 - zi2 + cr;
          n++;
        }
        // interior -> 0 (black); escape -> a moving band of the palette
        fb[row + px] = n >= kMaxIter ? 0 : (1 + (n * 254 ~/ kMaxIter));
      }
    }

    cmds.add(<dynamic>['gptext', 8, 6, frame.toString(), 230, 230, 255]);
    ui.send(['draw', cmds]);         // apply palette/HUD, then present the buffer
    frame++;
  });
}
