// Demo: Font sheet — every glyph the HUD font owns, at three scales
//
// The text overlay's own proof. The printable ASCII range (0x20..0x7E) laid out
// sixteen to a row, then the same atlas blocked up ×2 and ×3, then a string
// with a newline in it. A hollow box here is a glyph the atlas does not have —
// the box IS the failure report, so this sheet reads as pass/fail at a glance
// (the font lives in gp_engine.mm, kFont5x7).
import 'dart:isolate';

import 'gamepane.dart';

main(List args, SendPort ui) {
  var gp = new GamePane(ui, 424, 240);
  var first = true;

  gp.onFrame((g) {
    if (first) {
      first = false;
      g.cls(16);
      g.pal(16, 12, 12, 24);            // a dark ground for pale glyphs
      g.status('5x7 atlas — 0x20..0x7E, plus scale 2 and 3');
    }
    g.textClear();
    var y = 10;
    for (var base = 0x20; base <= 0x70; base += 16) {
      var row = new StringBuffer();
      for (var c = base; c < base + 16 && c <= 0x7E; c++) {
        row.write(new String.fromCharCode(c));
        row.write(' ');
      }
      g.text(12, y, row.toString(), 220, 230, 255);
      y += 11;
    }
    g.text(12, 96, 'Score 1234  lives 3', 255, 210, 120, 2);
    g.text(12, 120, 'GAME OVER', 255, 120, 120, 3);
    g.text(12, 156, 'A line break\nstarts back here.', 150, 255, 170, 2);
    // Bytes outside the atlas draw as a hollow box, on purpose.
    g.text(12, 200, 'unmapped: é©', 180, 180, 200, 2);
  });
}
