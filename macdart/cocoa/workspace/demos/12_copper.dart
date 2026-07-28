// Demo: Copper bars — per-scanline palettes on the Metal game pane
//
// The oldest trick in the raster book, impossible on a plain framebuffer at
// this cost: the screen is filled ONCE with palette index 1, and from then on
// no pixel is ever touched — each frame just rewrites what colour index 1
// MEANS on each of the 240 scanlines (the per-line palette region, raster-
// locked exactly like a copper list). Three sine-riding bars + a glow, at
// 240 palette pokes a frame. Sprites float over on the sprite layer, and the
// frame counter is the seven-segment HUD.
import 'dart:isolate';
import 'dart:math';

import 'gamepane.dart';

main(List args, SendPort ui) {
  var gp = new GamePane(ui, 424, 240);
  var first = true;
  SpriteRef ball;

  gp.onFrame((g) {
    if (first) {
      first = false;
      g.cls(1);                       // every pixel = per-line index 1, forever
      var orb = g.sprite('..ccc../.cbbbc./cbaaabc/cbaaabc/cbaaabc/.cbbbc./..ccc..');
      orb.rgb(0xa, 255, 255, 255);
      orb.rgb(0xb, 255, 200, 60);
      orb.rgb(0xc, 200, 80, 20);
      ball = orb.place(212, 120);
      g.status('240 scanline palettes/frame — no pixel is ever redrawn');
    }
    var t = g.frame * 0.045;
    // Base sky: a dim vertical wash; then three bars glow over it.
    for (var line = 0; line < 240; line++) {
      var r = 8, gg = 8, b = 20 + line ~/ 12;
      for (var bar = 0; bar < 3; bar++) {
        var centre = 120.0 + sin(t * (1.0 + bar * 0.23) + bar * 2.1) * 90.0;
        var d = (line - centre).abs();
        if (d < 26.0) {
          var k = 1.0 - d / 26.0;         // 0..1 toward the bar's core
          var glow = (k * k * 255.0).toInt();
          if (bar == 0) { r += glow; }
          else if (bar == 1) { gg += glow; }
          else { r += glow; gg += (glow * 2) ~/ 3; }
        }
      }
      g.linePal(line, 1, r > 255 ? 255 : r, gg > 255 ? 255 : gg,
                b > 255 ? 255 : b);
    }
    ball.moveTo(212 + sin(t * 0.7) * 170, 120 + cos(t * 1.1) * 70);
    ball.rot = g.frame * 2.0;
    ball.update();
    g.textClear();
    g.text(8, 8, g.frame.toString(), 255, 255, 255);
  });
}
