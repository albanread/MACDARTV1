// spriteed_model_test.dart — the sprite editor's document, asserted headless.
//
// Pure Dart (no GUI, no --with-st): the model file is imported straight from
// the workspace, so what the window manipulates and what this test asserts is
// the same code. The sheet-source test checks STRUCTURE (the exact sends
// installOn: makes); whether that source actually RUNS against the engine is
// gui_smoke's job, where a real image host and pane exist.
import '../../cocoa/workspace/spriteed_model.dart';

int fails = 0;
void check(String name, bool ok, [String detail = '']) {
  if (ok) {
    print('  ok    ' + name);
  } else {
    fails++;
    print('  FAIL  ' + name + (detail.isEmpty ? '' : ' - ' + detail));
  }
}

main() {
  print('MACDART sprite editor model test (headless)');

  // --- pixels + rows ---------------------------------------------------------
  var d = new SpriteDoc();
  check('fresh doc is 16x16, one frame, transparent',
      d.w == 16 && d.h == 16 && d.frames.length == 1 &&
      d.frames[0].every((p) => p == 0));
  check('setPx writes and reports change', d.setPx(0, 0, 0, 15) && d.getPx(0, 0, 0) == 15);
  check('setPx same value reports no change', !d.setPx(0, 0, 0, 15));
  check('setPx clamps colour', d.setPx(0, 1, 0, 99) && d.getPx(0, 1, 0) == 15);
  check('setPx out of bounds is refused', !d.setPx(0, 16, 0, 1) && !d.setPx(0, 0, -1, 1));

  d = new SpriteDoc();
  d.resize(4, 2);
  d.setPx(0, 0, 0, 15);
  d.setPx(0, 3, 1, 10);
  check('rowsOf emits lowercase hex rows', d.rowsOf(0) == 'f000/000a', d.rowsOf(0));

  var wh = <int>[0, 0];
  var px = SpriteDoc.parseRows('f0f/0F0/.1.', wh);
  check('parseRows: case + dot alias + size',
      px != null && wh[0] == 3 && wh[1] == 3 &&
      px.join(',') == '15,0,15,0,15,0,0,1,0',
      px == null ? 'null' : px.join(','));
  check('parseRows refuses ragged rows', SpriteDoc.parseRows('ff/f', wh) == null);
  check('parseRows refuses junk', SpriteDoc.parseRows('fg', wh) == null);
  check('parseRows refuses empty', SpriteDoc.parseRows('', wh) == null);

  // round-trip: emit -> parse -> identical pixels
  d = new SpriteDoc();
  d.resize(8, 8);
  for (var i = 0; i < 64; i++) { d.setPx(0, i % 8, i ~/ 8, i % 16); }
  var back = SpriteDoc.parseRows(d.rowsOf(0), wh);
  var same = wh[0] == 8 && wh[1] == 8;
  for (var i = 0; same && i < 64; i++) { same = back[i] == d.frames[0][i]; }
  check('rows round-trip exactly', same);

  // --- fill / shift / resize -------------------------------------------------
  d = new SpriteDoc();
  d.resize(4, 4);
  d.setPx(0, 2, 0, 5);  // wall splits top row from the rest? no — 4-way keeps
  var changed = d.floodFill(0, 0, 0, 7);
  check('flood fill fills the connected region',
      changed && d.getPx(0, 0, 3) == 7 && d.getPx(0, 3, 3) == 7);
  check('flood fill leaves other colours', d.getPx(0, 2, 0) == 5);
  check('flood fill same colour is a no-op', !d.floodFill(0, 2, 0, 5));

  d = new SpriteDoc();
  d.resize(3, 3);
  d.setPx(0, 0, 0, 9);
  d.shift(0, 1, 0);
  check('shift wraps horizontally', d.getPx(0, 1, 0) == 9 && d.getPx(0, 0, 0) == 0);
  d.shift(0, -2, 0);
  check('negative shift wraps too', d.getPx(0, 2, 0) == 9);
  d.shift(0, 0, -1);
  check('vertical shift wraps', d.getPx(0, 2, 2) == 9);

  d = new SpriteDoc();
  d.setPx(0, 2, 2, 12);
  d.resize(4, 4);
  check('shrink keeps the top-left window', d.getPx(0, 2, 2) == 12);
  d.resize(8, 8);
  check('grow pads transparent', d.getPx(0, 2, 2) == 12 && d.getPx(0, 7, 7) == 0);
  check('resize refuses silly bounds', !d.resize(0, 4) && !d.resize(4, 65));
  check('resize to same size reports no change', !d.resize(8, 8));

  // --- frames ----------------------------------------------------------------
  d = new SpriteDoc();
  d.resize(2, 2);
  d.setPx(0, 0, 0, 3);
  var ni = d.addFrame();
  check('addFrame appends blank', ni == 1 && d.frames.length == 2 && d.getPx(1, 0, 0) == 0);
  var di = d.dupFrame(0);
  check('dupFrame copies beside the original',
      di == 1 && d.frames.length == 3 && d.getPx(1, 0, 0) == 3);
  d.setPx(1, 1, 1, 9);
  check('the duplicate is independent', d.getPx(0, 1, 1) == 0);
  check('delFrame removes', d.delFrame(2) && d.frames.length == 2);
  d.delFrame(1);
  check('the last frame is undeletable', !d.delFrame(0) && d.frames.length == 1);

  // --- loadFrames ------------------------------------------------------------
  d = new SpriteDoc();
  check('loadFrames replaces art wholesale',
      d.loadFrames(<String>['f0/0f', '0f/f0']) &&
      d.w == 2 && d.h == 2 && d.frames.length == 2 && d.getPx(1, 0, 0) == 0);
  check('loadFrames refuses mismatched frames',
      !d.loadFrames(<String>['f0/0f', 'fff/000']));
  check('a refused load leaves the doc untouched',
      d.w == 2 && d.frames.length == 2);

  // --- palette + sheet source ------------------------------------------------
  d = new SpriteDoc();
  d.name = 'ShipTest';
  d.resize(2, 1);
  d.setPx(0, 0, 0, 1);
  d.addFrame();
  d.setPx(1, 1, 0, 2);
  d.setPal(1, 300, -5, 128);
  check('setPal clamps', d.pal[1][0] == 255 && d.pal[1][1] == 0 && d.pal[1][2] == 128);
  check('name validation',
      SpriteDoc.validName('Ship2') && !SpriteDoc.validName('ship') &&
      !SpriteDoc.validName('My Ship') && !SpriteDoc.validName(''));

  var src = d.sheetSource();
  check('sheet: marker comment first',
      src.startsWith('"SpriteSheet: ShipTest'));
  check('sheet: subclass line', src.contains('Object subclass: ShipTest ['));
  check('sheet: discovery marker', src.contains('isSpriteSheet [ ^true ]'));
  check('sheet: frames literal', src.contains("^#( '10' '02' )"));
  check('sheet: palette entry 1 as edited', src.contains('#(255 0 128)'));
  check('sheet: installOn: uses the game sends',
      src.contains('defineSprite: self frames first') &&
      src.contains('s addFrame:') &&
      src.contains('colorAt: i r:'));

  var snip = d.codeSnippet();
  check('snippet: define + frame + palette lines',
      snip.contains("defineSprite: '10'") &&
      snip.contains("addFrame: '02'") &&
      snip.contains('colorAt: 1 r: 255 g: 0 b: 128'));

  print(fails == 0 ? 'SPRITEED-MODEL OK' : ('SPRITEED-MODEL ' + fails.toString() + ' FAILED'));
}
