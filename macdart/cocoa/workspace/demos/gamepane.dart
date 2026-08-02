// GamePane — the game-side face of the Metal game pane (GAMEPANE_PLAN.md).
// (No demo-title header: this is a library games import, like pixmap.dart.)
//
// A game is a pull demo that never touches dart:cocoa: it describes a
// RETAINED scene — sprites, palettes, scroll, sounds — and this library
// serializes that description as one ['draw', cmds] list per UI invitation.
// The tick's payload is the gamestate ([downKeycodes, modifierFlags]), read
// with key(). Handles are minted here, validated engine-side.
//
//   main(List args, SendPort ui) {
//     var gp = new GamePane(ui, 424, 240);
//     var ship = gp.sprite('..a../.aaa./aaaaa').place(212, 220);
//     var zap = gp.sound('zap');
//     gp.onFrame((g) {
//       if (g.key(Keys.left)) ship.x -= 3;
//       if (g.key(Keys.space)) zap.play();
//       ship.update();
//     });
//   }
library gamepane;

import 'dart:isolate';

import 'abc.dart';

/// macOS virtual keycodes the tick payload carries.
class Keys {
  static const int left = 123, right = 124, down = 125, up = 126;
  static const int space = 49, esc = 53;
  static const int a = 0, s = 1, d = 2, w = 13, f = 3;
}

class GamePane {
  final SendPort _ui;
  final int width, height, worldW, worldH;
  List _cmds = <List>[];
  List _down = const [];
  var _onFrame;
  int _nextDef = 0, _nextInst = 0, _nextSound = 0;
  int frame = 0;

  GamePane(SendPort ui, int w, int h, [int ww, int wh])
      : _ui = ui,
        width = w, height = h,
        worldW = ww == null ? w : ww,
        worldH = wh == null ? h : wh {
    var ctl = new ReceivePort();
    _ui.send(['port', ctl.sendPort]);
    _ui.send(['draw', <List>[
      <dynamic>['gpopen', width, height, worldW, worldH]]]);
    ctl.listen(_tick);
  }

  void _tick(gs) {
    _down = (gs is List && gs.isNotEmpty && gs[0] is List)
        ? gs[0] : const [];
    frame++;
    _cmds = <List>[];
    if (_onFrame != null) _onFrame(this);
    _ui.send(['draw', _cmds]);
  }

  /// The per-frame callback; runs once per UI invitation, then the
  /// accumulated commands ship as one atomic frame.
  void onFrame(f(GamePane g)) { _onFrame = f; }

  /// Is [keycode] held right now (this frame's gamestate)?
  bool key(int keycode) => _down.contains(keycode);

  void status(String s) { _ui.send(['status', s]); }
  void done(String s) { _ui.send(['done', s]); }

  // --- palette (0 transparent; 1-15 per-scanline; 16-255 global) ------------
  void pal(int i, int r, int g, int b) =>
      _cmds.add(<dynamic>['gppal', i, r, g, b]);
  void linePal(int line, int i, int r, int g, int b) =>
      _cmds.add(<dynamic>['gplinepal', line, i, r, g, b]);

  // --- the indexed world buffer ---------------------------------------------
  void cls(int i) => _cmds.add(<dynamic>['gpcls', i]);
  void pset(int x, int y, int i) => _cmds.add(<dynamic>['gppset', x, y, i]);
  void line(int x0, int y0, int x1, int y1, int i) =>
      _cmds.add(<dynamic>['gpline', x0, y0, x1, y1, i]);
  void fill(int x, int y, int w, int h, int i) =>
      _cmds.add(<dynamic>['gpfill', x, y, w, h, i]);
  void circle(int cx, int cy, int r, int i) =>
      _cmds.add(<dynamic>['gpcircle', cx, cy, r, i]);
  void disc(int cx, int cy, int r, int i) =>
      _cmds.add(<dynamic>['gpdisc', cx, cy, r, i]);
  void scrollTo(int x, int y) => _cmds.add(<dynamic>['gpscroll', x, y]);
  void active(int slot) => _cmds.add(<dynamic>['gpactive', slot]);
  void swap() => _cmds.add(<dynamic>['gpswap']);
  void loadBuffer(int slot, String base64) =>
      _cmds.add(<dynamic>['gpload', slot, base64]);
  /// mode: 0 copy, 1 transparent, 2 and, 3 or, 4 xor, 5 clear([value]).
  void blit(int mode, int src, int dst, int sx, int sy, int dx, int dy,
            int w, int h, [int value = 0]) =>
      _cmds.add(<dynamic>['gpblit', mode, src, dst, sx, sy, dx, dy, w, h, value]);

  // --- HUD text (a 5x7 pixel font, the whole printable ASCII range) ---------
  void textClear() => _cmds.add(<dynamic>['gptextclear']);
  /// [x],[y] is the top-left of the first glyph. Six pixels of advance per
  /// character, eight per line; `\n` starts a new line at the same left edge.
  /// [scale] blocks each font pixel — 1 for a HUD, 3+ for a title screen.
  void text(int x, int y, String s, int r, int g, int b, [int scale = 1]) =>
      _cmds.add(<dynamic>['gptext', x, y, s, r, g, b, scale]);

  // --- the shader background (layer 0) --------------------------------------
  /// [fmainBody] is an MSL fragment function:
  ///   fragment float4 fmain(VOut in [[stage_in]],
  ///                         constant Uniforms& u [[buffer(0)]]) { ... }
  /// with Uniforms{float time; float aspect; float p[8];}. A compile error
  /// is logged by the workspace; the pane just keeps its black background.
  void shader(String fmainBody) => _cmds.add(<dynamic>['gpshader', fmainBody]);
  void shaderParam(int i, num v) => _cmds.add(<dynamic>['gpparam', i, v]);

  // --- retained objects ------------------------------------------------------
  Sprite sprite(String rows) {
    var d = _nextDef++;
    _cmds.add(<dynamic>['gpsprite', d, rows]);
    return new Sprite._(this, d);
  }

  Sound sound(String preset, [num a1 = 0, num a2 = 0]) {
    var slot = _nextSound++;
    _cmds.add(<dynamic>['gpsound', slot, preset, a1, a2]);
    return new Sound._(this, slot);
  }

  /// Compile [abc] (ABC notation — see abc.dart for the subset) HERE in the
  /// game isolate and ship the flat event list; the native side wraps it in
  /// a Standard MIDI File and plays it through the Mac's built-in GM synth.
  Tune tune(String abc) {
    var slot = _nextTune++;
    var t = parseAbc(abc);
    _cmds.add(<dynamic>['gptune', slot, t.bpm, t.events]);
    return new Tune._(this, slot);
  }
  int _nextTune = 0;

  /// The pane takes the whole screen (Esc — or the workspace — brings it
  /// back; the logical resolution is unchanged, just upscaled crisp).
  void fullscreen(bool on) => _cmds.add(<dynamic>['gpfull', on ? 1 : 0]);
}

/// A sprite DEFINITION: hex-row art ('0'-'f', '.' = transparent, rows split
/// by '/'), a 16-colour palette of its own, optional extra animation frames.
class Sprite {
  final GamePane gp;
  final int def;
  Sprite._(this.gp, this.def);

  void addFrame(String rows) =>
      gp._cmds.add(<dynamic>['gpframe', def, rows]);
  void rgb(int i, int r, int g, int b) =>
      gp._cmds.add(<dynamic>['gpspritepal', def, i, r, g, b]);

  SpriteRef place(num x, num y) {
    var id = gp._nextInst++;
    gp._cmds.add(<dynamic>['gpspawn', id, def, x, y]);
    return new SpriteRef._(gp, id, x, y);
  }
}

/// A PLACED sprite. Mutate the fields, then update() ships the transform.
/// (x, y) is the world-space CENTRE — it scrolls with the camera.
class SpriteRef {
  final GamePane gp;
  final int id;
  num x, y;
  num scale = 1.0, rot = 0.0, alpha = 1.0;
  int frame = 0;
  SpriteRef._(this.gp, this.id, this.x, this.y);

  void update() => gp._cmds.add(
      <dynamic>['gpplace', id, x, y, frame, scale, rot, alpha]);
  void moveTo(num nx, num ny) { x = nx; y = ny; update(); }
  void hide() => gp._cmds.add(<dynamic>['gphide', id]);
  void animate(num fps) => gp._cmds.add(<dynamic>['gpanim', id, fps]);

  /// AABB overlap against another placed sprite, using the game's own
  /// bookkeeping of half-extents (the wire is one-way; games know their art).
  bool hits(SpriteRef o, num myHalfW, num myHalfH, num oHalfW, num oHalfH) {
    return x - myHalfW < o.x + oHalfW && x + myHalfW > o.x - oHalfW &&
           y - myHalfH < o.y + oHalfH && y + myHalfH > o.y - oHalfH;
  }
}

class Sound {
  final GamePane gp;
  final int slot;
  Sound._(this.gp, this.slot);
  void play() => gp._cmds.add(<dynamic>['gpplay', slot]);
}

/// A compiled tune (see GamePane.tune). Looping restarts engine-side the
/// frame after it ends; stop() silences it.
class Tune {
  final GamePane gp;
  final int slot;
  Tune._(this.gp, this.slot);
  void play() => gp._cmds.add(<dynamic>['gpmusic', slot, 1]);
  void loop() => gp._cmds.add(<dynamic>['gpmusic', slot, 2]);
  void stop() => gp._cmds.add(<dynamic>['gpmusic', slot, 0]);
}
