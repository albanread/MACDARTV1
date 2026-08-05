// spriteed_model.dart — the sprite editor's document, pure and headless.
//
// A document is what the game pane's sprite system renders: frames of 4-bit
// pixels (0..15, 0 = transparent) plus one 16-entry RGB palette shared by
// every frame — the engine's own shape (a def's palette is per-def, not
// per-frame; gp_engine.h). Everything here is plain data and string work so
// the whole model runs under a bare `dart` with no GUI and no --with-st
// (st/test/spriteed_model_test.dart); workspace.dart imports it for the
// window, the test imports it for the assertions, and the two can never
// drift apart.
//
// The persistence format is SOURCE, the house doctrine (the hall of fame,
// the apps): a sheet saves as an ordinary class in the image. Its methods
// answer the art rows and palette as literals, and installOn: replays them
// onto a live pane with the exact sends every shipped game already uses
// (defineSprite: / addFrame: / colorAt:r:g:b:) — so a saved sheet is one
// send away from playing, and the Browser can read (or tweak) the art as
// text.

/// Hex digit per pixel, lowercase like every shipped game's art.
const String _kHex = '0123456789abcdef';

/// DawnBringer's 16 — the default palette for a fresh document. Entry 0 is
/// the transparent index; its RGB is kept anyway (shown behind a checker in
/// the editor, exported like the rest so round-trips are exact).
List<List<int>> defaultPalette16() {
  return <List<int>>[
    <int>[20, 12, 28],    // 0 transparent (colour kept for round-trip)
    <int>[68, 36, 52],    // 1 deep purple-brown
    <int>[48, 52, 109],   // 2 navy
    <int>[78, 74, 78],    // 3 grey
    <int>[133, 76, 48],   // 4 brown
    <int>[52, 101, 36],   // 5 green
    <int>[208, 70, 72],   // 6 red
    <int>[117, 113, 97],  // 7 light grey
    <int>[89, 125, 206],  // 8 blue
    <int>[210, 125, 44],  // 9 orange
    <int>[133, 149, 161], // 10 steel
    <int>[109, 170, 44],  // 11 lime
    <int>[210, 170, 153], // 12 skin
    <int>[109, 194, 202], // 13 cyan
    <int>[218, 212, 94],  // 14 yellow
    <int>[222, 238, 214], // 15 near-white
  ];
}

class SpriteDoc {
  String name = 'Sprite';
  int w = 16, h = 16;
  List<List<int>> frames;           // each w*h ints 0..15, row-major top-down
  List<List<int>> pal;              // 16 x [r, g, b]

  SpriteDoc() {
    frames = <List<int>>[new List<int>.filled(w * h, 0)];
    pal = defaultPalette16();
  }

  // --- pixels ---------------------------------------------------------------

  int getPx(int f, int x, int y) {
    if (f < 0 || f >= frames.length) return 0;
    if (x < 0 || x >= w || y < 0 || y >= h) return 0;
    return frames[f][y * w + x];
  }

  /// Answers true when the write changed anything — the window uses that to
  /// skip repaints while a drag sits inside one cell.
  bool setPx(int f, int x, int y, int c) {
    if (f < 0 || f >= frames.length) return false;
    if (x < 0 || x >= w || y < 0 || y >= h) return false;
    if (c < 0) c = 0;
    if (c > 15) c = 15;
    if (frames[f][y * w + x] == c) return false;
    frames[f][y * w + x] = c;
    return true;
  }

  /// Classic 4-way flood from (x,y): every connected pixel of the seed's
  /// colour becomes c. A no-op when the seed already IS c (the fill would
  /// otherwise walk the region writing the value it reads).
  bool floodFill(int f, int x, int y, int c) {
    if (f < 0 || f >= frames.length) return false;
    if (x < 0 || x >= w || y < 0 || y >= h) return false;
    if (c < 0) c = 0;
    if (c > 15) c = 15;
    var px = frames[f];
    var from = px[y * w + x];
    if (from == c) return false;
    var stack = <int>[y * w + x];
    while (stack.isNotEmpty) {
      var i = stack.removeLast();
      if (px[i] != from) continue;
      px[i] = c;
      var ix = i % w, iy = i ~/ w;
      if (ix > 0) stack.add(i - 1);
      if (ix < w - 1) stack.add(i + 1);
      if (iy > 0) stack.add(i - w);
      if (iy < h - 1) stack.add(i + w);
    }
    return true;
  }

  /// Shift the frame by (dx, dy) WITH WRAP — a game sprite's edges usually
  /// matter, and a wrapping shift loses nothing, so nudging art into place
  /// is always reversible.
  void shift(int f, int dx, int dy) {
    if (f < 0 || f >= frames.length) return;
    var src = frames[f];
    var dst = new List<int>.filled(w * h, 0);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        var nx = (x + dx) % w; if (nx < 0) nx += w;
        var ny = (y + dy) % h; if (ny < 0) ny += h;
        dst[ny * w + nx] = src[y * w + x];
      }
    }
    frames[f] = dst;
  }

  void clearFrame(int f) {
    if (f < 0 || f >= frames.length) return;
    frames[f] = new List<int>.filled(w * h, 0);
  }

  /// Resize every frame, anchored top-left: content inside the new bounds is
  /// kept, growth pads with transparent. Engine-honest bounds (1..64 — a def
  /// is a Metal texture, and nothing in the library is remotely that big).
  bool resize(int nw, int nh) {
    if (nw < 1 || nh < 1 || nw > 64 || nh > 64) return false;
    if (nw == w && nh == h) return false;
    for (var f = 0; f < frames.length; f++) {
      var src = frames[f];
      var dst = new List<int>.filled(nw * nh, 0);
      var cw = nw < w ? nw : w, ch = nh < h ? nh : h;
      for (var y = 0; y < ch; y++) {
        for (var x = 0; x < cw; x++) {
          dst[y * nw + x] = src[y * w + x];
        }
      }
      frames[f] = dst;
    }
    w = nw;
    h = nh;
    return true;
  }

  // --- frames ---------------------------------------------------------------

  int addFrame() {
    frames.add(new List<int>.filled(w * h, 0));
    return frames.length - 1;
  }

  int dupFrame(int f) {
    if (f < 0 || f >= frames.length) return -1;
    frames.insert(f + 1, new List<int>.from(frames[f]));
    return f + 1;
  }

  /// The last frame cannot be deleted — a def with zero frames is nothing the
  /// engine (or the editor) can show.
  bool delFrame(int f) {
    if (frames.length <= 1) return false;
    if (f < 0 || f >= frames.length) return false;
    frames.removeAt(f);
    return true;
  }

  // --- palette --------------------------------------------------------------

  bool setPal(int i, int r, int g, int b) {
    if (i < 0 || i > 15) return false;
    int cb(int v) { return v < 0 ? 0 : (v > 255 ? 255 : v); }
    pal[i] = <int>[cb(r), cb(g), cb(b)];
    return true;
  }

  // --- hex rows (the engine's wire format) ----------------------------------

  String rowsOf(int f) {
    var b = new StringBuffer();
    var px = frames[f];
    for (var y = 0; y < h; y++) {
      if (y > 0) b.write('/');
      for (var x = 0; x < w; x++) {
        b.write(_kHex[px[y * w + x]]);
      }
    }
    return b.toString();
  }

  /// Parse '/'-separated hex rows (the engine's own format; '.' is its
  /// transparent alias, upper-case hex tolerated). Every row must match the
  /// first row's width. Answers the pixels, or null with no doc change —
  /// parse first, commit after, so a bad string can never half-load.
  static List<int> parseRows(String rows, List<int> outWH) {
    if (rows == null || rows.isEmpty) return null;
    var lines = rows.split('/');
    var rw = lines[0].length;
    if (rw < 1 || rw > 64 || lines.length > 64) return null;
    var px = <int>[];
    for (var line in lines) {
      if (line.length != rw) return null;
      for (var i = 0; i < line.length; i++) {
        var ch = line[i].toLowerCase();
        if (ch == '.') { px.add(0); continue; }
        var v = _kHex.indexOf(ch);
        if (v < 0) return null;
        px.add(v);
      }
    }
    outWH[0] = rw;
    outWH[1] = lines.length;
    return px;
  }

  /// Replace the whole document's art from a list of row strings (all frames
  /// the same size, engine rule). Palette untouched. All-or-nothing.
  bool loadFrames(List<String> rowsList) {
    if (rowsList == null || rowsList.isEmpty) return false;
    var wh = <int>[0, 0];
    var parsed = <List<int>>[];
    for (var rows in rowsList) {
      var px = parseRows(rows, wh);
      if (px == null) return false;
      if (parsed.isNotEmpty && px.length != parsed[0].length) return false;
      if (parsed.isEmpty) { w = wh[0]; h = wh[1]; }
      else if (wh[0] != w || wh[1] != h) { return false; }
      parsed.add(px);
    }
    frames = parsed;
    return true;
  }

  // --- the saved form: a sheet class ----------------------------------------

  static final RegExp _kName = new RegExp(r'^[A-Z][A-Za-z0-9]*$');
  static bool validName(String s) { return s != null && _kName.hasMatch(s); }

  /// The whole sheet as class source. isSpriteSheet is the discovery marker
  /// (splist greps for it); installOn: replays the sheet onto a live pane
  /// with the same sends every shipped game uses, so
  /// `ship := Ship installOn: pane` is the entire consumption API. Entry 0
  /// is skipped there — the engine discards index 0 (transparent), so its
  /// colour is display-only.
  String sheetSource() {
    var b = new StringBuffer();
    b.write('"SpriteSheet: ');
    b.write(name);
    b.write(' - WRITTEN BY THE SPRITE EDITOR (Games menu). ');
    b.write(w.toString());
    b.write('x');
    b.write(h.toString());
    b.write(', ');
    b.write(frames.length.toString());
    b.write(frames.length == 1 ? ' frame' : ' frames');
    b.write('. Edit it here if you like - it is only source. In a game: ');
    b.write('| s | s := ');
    b.write(name);
    b.write(' installOn: pane. s moveTo: x y: y."\n');
    b.write('Object subclass: ');
    b.write(name);
    b.write(' [\n');
    b.write('    ');
    b.write(name);
    b.write(' class >> isSpriteSheet [ ^true ]\n');
    b.write('    ');
    b.write(name);
    b.write(' class >> frames [\n        ^#(');
    for (var f = 0; f < frames.length; f++) {
      b.write(" '");
      b.write(rowsOf(f));
      b.write("'");
    }
    b.write(' )\n    ]\n');
    b.write('    ');
    b.write(name);
    b.write(' class >> palette [\n        ^#(');
    for (var i = 0; i < 16; i++) {
      b.write(' #(');
      b.write(pal[i][0].toString());
      b.write(' ');
      b.write(pal[i][1].toString());
      b.write(' ');
      b.write(pal[i][2].toString());
      b.write(')');
    }
    b.write(' )\n    ]\n');
    b.write('    ');
    b.write(name);
    b.write(' class >> installOn: aPane [\n');
    b.write('        | s |\n');
    b.write('        s := aPane defineSprite: self frames first.\n');
    b.write('        2 to: self frames size do: [ :i |\n');
    b.write('            s addFrame: (self frames at: i) ].\n');
    b.write('        1 to: 15 do: [ :i | | c |\n');
    b.write('            c := self palette at: i + 1.\n');
    b.write('            s colorAt: i r: (c at: 1) g: (c at: 2) b: (c at: 3) ].\n');
    b.write('        ^s\n');
    b.write('    ]\n');
    b.write(']\n');
    return b.toString();
  }

  /// The clipboard export: verbatim game code for someone not using a sheet
  /// class — the raw defineSprite:/addFrame:/colorAt: calls.
  String codeSnippet() {
    var b = new StringBuffer();
    b.write('| s |\n');
    b.write("s := pane defineSprite: '");
    b.write(rowsOf(0));
    b.write("'.\n");
    for (var f = 1; f < frames.length; f++) {
      b.write("s addFrame: '");
      b.write(rowsOf(f));
      b.write("'.\n");
    }
    for (var i = 1; i < 16; i++) {
      b.write('s colorAt: ');
      b.write(i.toString());
      b.write(' r: ');
      b.write(pal[i][0].toString());
      b.write(' g: ');
      b.write(pal[i][1].toString());
      b.write(' b: ');
      b.write(pal[i][2].toString());
      b.write('.\n');
    }
    return b.toString();
  }
}
