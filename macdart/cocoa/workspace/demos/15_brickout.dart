// Demo: Brickout — paddle-steered physics, a wall you feel coming down
//
// The full game pane in service of one classic. The BRICK WALL is indexed-pane
// terrain (like the invaders' bunkers): drawn once per level, one fill per
// brick, erased brick-by-brick on impact so the shader sky shows through the
// holes. The BALL and PADDLE are sprites (smooth sub-pixel motion). Physics is
// the part that makes Breakout playable: where the ball meets the paddle sets
// its angle (edges send it steep), it speeds up as the wall thins, and the
// first ceiling touch narrows the paddle — the classic pressure curve. Sounds
// pitch-shift with the brick row, a screen shake rides the overscan scroll
// margin, and an original theme loops underneath. ← → (A/D) move, space
// serves, F fullscreen (Esc back). Left alone it serves itself — attract mode.
import 'dart:isolate';
import 'dart:math';

import 'gamepane.dart';

// An original bouncy loop in C — square lead, eighths at a driving 150.
const String kTheme = 'X:1\n'
    'T:wall to wall\n'
    'M:4/4\n'
    'L:1/8\n'
    'Q:1/4=150\n'
    '%%MIDI program 80\n'
    'K:C\n'
    '|: CEGE cGEG | A,CEA cAEC | F,ACF AFCA, | G,B,DG B,DG,2 :|\n'
    'C2 G,2 C,4 |\n';

const String kSky =
    'fragment float4 fmain(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {\n'
    '    float2 uv = in.uv;\n'
    '    float3 top = float3(0.02, 0.01, 0.08);\n'
    '    float3 bot = float3(0.05, 0.02, 0.13);\n'
    '    float3 col = mix(top, bot, uv.y);\n'
    '    float2 g = uv * float2(60.0, 34.0);\n'
    '    float2 id = floor(g);\n'
    '    float h = fract(sin(dot(id, float2(12.9898, 78.233))) * 43758.5453);\n'
    '    float star = smoothstep(0.05, 0.0, length(fract(g) - 0.5)) * step(0.985, h);\n'
    '    col += float3(star * (0.4 + 0.4 * sin(u.time * 3.0 + h * 20.0)));\n'
    '    return float4(col, 1.0);\n'
    '}\n';

// The field: 424x240 viewport in a 432x248 world (an 8px margin the screen
// shake borrows). 13 columns x 8 rows of 30x10 bricks under a top wall.
const int kCols = 13, kRows = 8;
const int kBrickW = 30, kBrickH = 10;
const int kFieldX = 17, kFieldY = 36;          // top-left of the wall
const double kWallL = 8.0, kWallR = 416.0, kWallT = 22.0;  // bounce planes
const double kPaddleY = 224.0, kDeathY = 248.0;

main(List args, SendPort ui) {
  var gp = new GamePane(ui, 424, 240, 432, 248);
  var rng = new Random();
  var first = true;
  SpriteRef ball, paddle;
  Sound serveSnd, wallSnd, hurtSnd, clearSnd;
  var rowSnd = <Sound>[];

  var bricks = new List<int>(kCols * kRows);   // 0 empty, else its row+1
  var remaining = 0;
  var score = 0, lives = 3, level = 1;
  var mode = 'serve';                          // serve | play | over
  var bx = 212.0, by = 218.0, vx = 0.0, vy = 0.0;
  var speed = 3.2;
  var paddleScale = 2.0;                       // narrows after a ceiling touch
  var shrunk = false;
  var shakeT = 0, serveT = 0, blink = 0;

  // Row colours (palette 16+row) and per-row score, Atari-style top-down.
  const rowR = const <int>[235, 235, 240, 240, 80, 80, 240, 240];
  const rowG = const <int>[70, 70, 150, 150, 210, 210, 230, 230];
  const rowB = const <int>[70, 70, 40, 40, 90, 90, 90, 90];
  const rowPts = const <int>[7, 7, 5, 5, 3, 3, 1, 1];

  void drawBrick(GamePane g, int c, int r, bool present) {
    g.fill(kFieldX + c * kBrickW, kFieldY + r * kBrickH,
           kBrickW - 2, kBrickH - 2, present ? 16 + r : 0);
  }

  void buildWall(GamePane g) {
    remaining = kCols * kRows;
    for (var r = 0; r < kRows; r++) {
      for (var c = 0; c < kCols; c++) {
        bricks[r * kCols + c] = r + 1;
        drawBrick(g, c, r, true);
      }
    }
  }

  void serve() {
    mode = 'serve';
    serveT = 0;
    bx = paddle.x; by = kPaddleY - 8.0;
    vx = 0.0; vy = 0.0;
  }

  void launch() {
    mode = 'play';
    var a = (rng.nextDouble() - 0.5) * 0.9;    // up, a little off-vertical
    vx = speed * sin(a);
    vy = -speed * cos(a);
    serveSnd.play();
  }

  // The brick under a point, or -1. (x,y) in world coordinates.
  int cellAt(double x, double y) {
    var c = ((x - kFieldX) / kBrickW).floor();
    var r = ((y - kFieldY) / kBrickH).floor();
    if (c < 0 || c >= kCols || r < 0 || r >= kRows) return -1;
    return bricks[r * kCols + c] != 0 ? r * kCols + c : -1;
  }

  void smashBrick(GamePane g, int idx) {
    var r = idx ~/ kCols, c = idx % kCols;
    bricks[idx] = 0;
    remaining--;
    drawBrick(g, c, r, false);
    score += rowPts[r] * level;
    rowSnd[r].play();
    // The wall fights back: thinning it speeds the ball (two steps per level).
    if (remaining == kCols * kRows - 16 || remaining == kCols * kRows ~/ 2) {
      speed += 0.4;
    }
  }

  gp.onFrame((g) {
    if (first) {
      first = false;
      g.shader(kSky);
      for (var r = 0; r < kRows; r++) g.pal(16 + r, rowR[r], rowG[r], rowB[r]);
      g.pal(30, 150, 155, 175);                // walls
      g.pal(31, 90, 95, 115);                  // wall shading
      // side + top walls, drawn once in world space
      g.fill(0, 16, 8, 232, 30);   g.pset(7, 16, 31);
      g.fill(416, 16, 8, 232, 30);
      g.fill(0, 16, 424, 6, 30);
      var ballDef = g.sprite('.bcc./bbccc/bbbcc/bbbbc/.bbb.');
      ballDef.rgb(0xb, 235, 235, 245);
      ballDef.rgb(0xc, 255, 255, 255);
      ball = ballDef.place(212, 218);
      ball.scale = 2.0;                        // 5x5 art -> a 10px ball
      var padDef = g.sprite(
          '.cccccccccccccccccccccc./'
          'cbbbbbbbbbbbbbbbbbbbbbbc/'
          'cbbbbbbbbbbbbbbbbbbbbbbc/'
          '.aaaaaaaaaaaaaaaaaaaaaa.');
      padDef.rgb(0xa, 30, 80, 170);            // keel, dark blue
      padDef.rgb(0xb, 80, 150, 240);           // body
      padDef.rgb(0xc, 190, 225, 255);          // shine
      paddle = padDef.place(212, kPaddleY);
      paddle.scale = 2.0;                      // 24x4 -> 48x8
      serveSnd = g.sound('jump');
      wallSnd = g.sound('click');
      hurtSnd = g.sound('hurt');
      clearSnd = g.sound('powerup');
      for (var r = 0; r < kRows; r++) {        // row voice: higher rows ring higher
        rowSnd.add(g.sound('blip', 1.9 - r * 0.15, 0.06));
      }
      g.tune(kTheme).loop();
      buildWall(g);
      serve();
      g.status('← → (A/D) move, space serves, F fullscreen — clear the wall');
    }

    if (g.key(Keys.f)) g.fullscreen(true);
    blink++;

    // screen shake: borrow the world's 8px margin for a few frames
    if (shakeT > 0) {
      shakeT--;
      g.scrollTo(rng.nextInt(4), rng.nextInt(4));
      if (shakeT == 0) g.scrollTo(0, 0);
    }

    if (mode == 'over') {
      g.textClear();
      g.text(166, 96, score.toString(), 255, 120, 120);
      g.text(166, 118, '------', 255, 255, 255);
      if (g.key(Keys.space)) {
        score = 0; lives = 3; level = 1; speed = 3.2;
        paddleScale = 2.0; shrunk = false;
        paddle.scale = paddleScale; paddle.update();
        buildWall(g);
        serve();
      }
      return;
    }

    // paddle (always steerable — even during serve, to aim)
    var pv = 0.0;
    if (g.key(Keys.left) || g.key(Keys.a)) pv = -6.0;
    if (g.key(Keys.right) || g.key(Keys.d)) pv = 6.0;
    paddle.x += pv;
    var half = 24.0 * paddleScale / 2.0;
    if (paddle.x < kWallL + half) paddle.x = kWallL + half;
    if (paddle.x > kWallR - half) paddle.x = kWallR - half;
    paddle.update();

    if (mode == 'serve') {
      serveT++;
      bx = paddle.x; by = kPaddleY - 8.0;
      ball.moveTo(bx, by);
      ball.alpha = (blink ~/ 8) % 2 == 0 ? 1.0 : 0.45;   // "waiting" blink
      ball.update();
      if (g.key(Keys.space) || serveT > 75) launch();    // attract: self-serve
      g.textClear();
      g.text(8, 2, score.toString(), 255, 255, 255);
      g.text(396, 2, lives.toString(), 255, 120, 120);
      g.text(204, 2, level.toString(), 140, 220, 255);
      return;
    }

    // --- play: sub-step the flight so a fast ball cannot tunnel a brick ----
    ball.alpha = 1.0;
    var steps = (sqrt(vx * vx + vy * vy) / 3.0).ceil();
    if (steps < 1) steps = 1;
    for (var s = 0; s < steps && mode == 'play'; s++) {
      var nx = bx + vx / steps, ny = by + vy / steps;
      const double r = 5.0;

      // walls
      if (nx < kWallL + r) { nx = kWallL + r; vx = vx.abs(); wallSnd.play(); }
      if (nx > kWallR - r) { nx = kWallR - r; vx = -vx.abs(); wallSnd.play(); }
      if (ny < kWallT + r) {
        ny = kWallT + r; vy = vy.abs(); wallSnd.play();
        if (!shrunk) {                         // the classic ceiling tax
          shrunk = true;
          paddleScale = 1.4;
          paddle.scale = paddleScale;
          paddle.update();
        }
      }

      // bricks: probe ahead on each axis separately, bounce on the axis hit
      var hit = cellAt(bx, ny + (vy > 0 ? r : -r));
      if (hit >= 0) { smashBrick(g, hit); vy = -vy; ny = by; }
      else {
        hit = cellAt(nx + (vx > 0 ? r : -r), by);
        if (hit >= 0) { smashBrick(g, hit); vx = -vx; nx = bx; }
      }

      // paddle: position on the face sets the angle — the whole game
      if (vy > 0 && ny > kPaddleY - 6.0 && ny < kPaddleY + 6.0 &&
          (nx - paddle.x).abs() < half + r) {
        var off = ((nx - paddle.x) / half);
        if (off < -1.0) off = -1.0;
        if (off > 1.0) off = 1.0;
        var sp = sqrt(vx * vx + vy * vy);
        var ang = off * 1.05;                  // up to ~60 degrees off vertical
        vx = sp * sin(ang);
        vy = -sp * cos(ang);
        ny = kPaddleY - 6.0;
        rowSnd[7].play();
      }

      bx = nx; by = ny;

      // the floor is the only way out
      if (by > kDeathY) {
        lives--;
        hurtSnd.play();
        shakeT = 10;
        if (lives <= 0) { mode = 'over'; } else {
          paddleScale = 2.0; shrunk = false;   // a fresh life, a full paddle
          paddle.scale = paddleScale; paddle.update();
          serve();
        }
      }
    }

    if (mode == 'play') {
      // keep the flight lively: never fully horizontal
      var sp = sqrt(vx * vx + vy * vy);
      if (sp > 0 && vy.abs() < sp * 0.25) {
        vy = (vy < 0 ? -1 : 1) * sp * 0.25;
        var ax = sp * sp - vy * vy;
        vx = (vx < 0 ? -1 : 1) * sqrt(ax > 0.0 ? ax : 0.0);
      }
      // match current speed setting (ramps as the wall thins / levels rise)
      if (sp > 0 && (sp - speed).abs() > 0.01) {
        vx = vx / sp * speed; vy = vy / sp * speed;
      }
      ball.moveTo(bx, by);

      if (remaining == 0) {                    // the wall is down
        level++;
        speed = 3.2 + level * 0.5;
        clearSnd.play();
        shakeT = 8;
        buildWall(g);
        serve();
      }
    }

    g.textClear();
    g.text(8, 2, score.toString(), 255, 255, 255);
    g.text(396, 2, lives.toString(), 255, 120, 120);
    g.text(204, 2, level.toString(), 140, 220, 255);
  });
}
