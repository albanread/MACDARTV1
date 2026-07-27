// Demo: Sprite Invaders — the whole game pane: shader sky, sprites, SFX, HUD
//
// Every layer of the engine at once, as a playable game. Layer 0: a twinkling
// starfield fragment shader compiled AT RUNTIME from the MSL string below.
// Layer 1: the indexed pane holds a ground strip. Layer 2: a 32-pixel player
// fighter (16x12 art at scale 2), shots, and a descending rank of invaders —
// all 16-colour sprites with their own palettes. Layer 3: seven-segment
// score. Keys ride the pull tick
// (← → or A/D move, space fires), sounds are synth presets (zap, explode,
// hurt), and the looping theme is ABC notation compiled IN THIS ISOLATE
// (demos/abc.dart), played through the Mac's GM synth. F goes fullscreen
// (Esc comes back). Lose all three lives and space restarts.
import 'dart:isolate';
import 'dart:math';

import 'gamepane.dart';

const String kSky =
    'fragment float4 fmain(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {\n'
    '    float2 uv = in.uv * float2(u.aspect, 1.0);\n'
    '    float3 col = float3(0.01, 0.01, 0.05);\n'
    '    for (int i = 0; i < 3; i++) {\n'
    '        float layer = float(i);\n'
    '        float scale = 18.0 + layer * 14.0;\n'
    '        float2 grid = uv * scale + layer * 11.0;\n'
    '        float2 cellId = floor(grid);\n'
    '        float2 cellUv = fract(grid) - 0.5;\n'
    '        float h = fract(sin(dot(cellId, float2(12.9898, 78.233)) + layer * 3.7) * 43758.5453);\n'
    '        float star = smoothstep(0.06, 0.0, length(cellUv)) * step(0.97, h);\n'
    '        float twinkle = 0.5 + 0.5 * sin(u.time * (2.0 + h * 4.0) + h * 12.0);\n'
    '        col += float3(star * twinkle);\n'
    '    }\n'
    '    return float4(col, 1.0);\n'
    '}\n';

// An original little theme: Am–G–F–E arpeggios on a square lead, eighths at
// a marching 140. Written for this demo; loops seamlessly.
const String kTheme = 'X:1\n'
    'T:march of the sprites\n'
    'M:4/4\n'
    'L:1/8\n'
    'Q:1/4=140\n'
    '%%MIDI program 80\n'
    'K:Am\n'
    '|: A,CEA cAEC | G,B,DG BGDB, | F,ACF AFCA, | E,^G,B,E ^G,B,E2 :|\n'
    'A,2 E,2 A,,4 |\n';

main(List args, SendPort ui) {
  var gp = new GamePane(ui, 424, 240);
  var rng = new Random(7);
  var first = true;
  SpriteRef ship;
  var shots = <SpriteRef>[];
  var foes = <SpriteRef>[];
  var foeAlive = <bool>[];
  Sound zap, boom, hurt2;
  var score = 0, lives = 3, wave = 0, cool = 0;
  var dir = 1.0, drop = 0.0;

  void spawnWave(GamePane g, Sprite foeDef) {
    wave++;
    for (var i = 0; i < foes.length; i++) foeAlive[i] = false;
    var n = 0;
    for (var row = 0; row < 3; row++) {
      for (var col = 0; col < 8; col++) {
        var x = 60.0 + col * 44.0, y = 40.0 + row * 26.0;
        if (n < foes.length) {
          foes[n].moveTo(x, y);
          foes[n].alpha = 1.0;
          foeAlive[n] = true;
        } else {
          var f = foeDef.place(x, y);
          f.scale = 2.0;                     // 6x6 art -> 12x12, proportionate
          f.animate(4 + wave);
          foes.add(f);
          foeAlive.add(true);
        }
        n++;
      }
    }
    dir = 1.0; drop = 0.0;
  }

  Sprite foeDef;
  gp.onFrame((g) {
    if (first) {
      first = false;
      g.shader(kSky);
      g.pal(16, 30, 90, 40);                 // ground
      g.pal(17, 90, 200, 110);
      g.fill(0, 228, 424, 12, 16);
      for (var x = 0; x < 424; x += 8) g.pset(x, 228, 17);
      // The ship: 16x12 art at scale 2 = a 32-pixel fighter, so the whole
      // shape reads — a red twin cannon up top, a bright cockpit, blue hull
      // with darker wing edges, and two engine flames trailing below. (a hull
      // edge, b hull, c cockpit, d cannon, e flame — its own 16-colour CLUT.)
      var shipDef = g.sprite(
          '.......dd......./'
          '.......dd......./'
          '......bccb....../'
          '......bccb....../'
          '.....bbccbb...../'
          '....bbccccbb..../'
          '...bbbccccbbb.../'
          '..abbbbccbbbba../'
          '.aabbbbbbbbbbaa./'
          'aa.abbbbbbbba.aa/'
          'a...bb.dd.bb...a/'
          '....ee....ee....');
      shipDef.rgb(0xa, 20, 70, 160);        // wing edge, dark blue
      shipDef.rgb(0xb, 70, 140, 235);       // hull, blue
      shipDef.rgb(0xc, 190, 245, 255);      // cockpit, bright cyan
      shipDef.rgb(0xd, 235, 80, 70);        // twin cannon, red
      shipDef.rgb(0xe, 255, 190, 60);       // engine flame, orange
      ship = shipDef.place(212, 210);
      ship.scale = 2.0;                     // 16x12 art -> 32x24 on screen
      var shotDef = g.sprite('e/e/f');
      shotDef.rgb(0xe, 255, 255, 160);
      shotDef.rgb(0xf, 255, 120, 40);
      for (var i = 0; i < 6; i++) {
        var s = shotDef.place(-20, -20);
        s.scale = 2.0;
        s.hide();
        shots.add(s);
      }
      foeDef = g.sprite('.d..d./.dddd./ddcddc/dddddd/.d..d./d....d');
      foeDef.addFrame('.d..d./.dddd./dcddcd/dddddd/d.dd.d/.d..d.');
      foeDef.rgb(0xc, 255, 80, 80);
      foeDef.rgb(0xd, 180, 255, 120);
      zap = g.sound('zap');
      boom = g.sound('explode');
      hurt2 = g.sound('hurt');
      g.tune(kTheme).loop();               // the theme, compiled here, looping
      spawnWave(g, foeDef);
      g.status('← → (A/D) move, space fires, F fullscreen (Esc back)');
    }

    if (g.key(Keys.f)) g.fullscreen(true); // engine no-ops when already on

    if (lives <= 0) {                        // game over: space restarts
      g.textClear();
      g.text(150, 100, score.toString(), 255, 80, 80);
      g.text(150, 120, '-------', 255, 255, 255);
      if (g.key(Keys.space)) { score = 0; lives = 3; wave = 0; spawnWave(g, foeDef); }
      return;
    }

    // ship
    if (g.key(Keys.left) || g.key(Keys.a)) ship.x -= 4;
    if (g.key(Keys.right) || g.key(Keys.d)) ship.x += 4;
    if (ship.x < 16) ship.x = 16;
    if (ship.x > 408) ship.x = 408;
    ship.update();

    // fire (cooldown so holding space streams, not floods)
    if (cool > 0) cool--;
    if (g.key(Keys.space) && cool == 0) {
      for (var i = 0; i < shots.length; i++) {
        if (shots[i].y < -10 || shots[i].y > 250) {
          shots[i].moveTo(ship.x, ship.y - 16);   // from the cannon tip
          zap.play();
          cool = 8;
          break;
        }
      }
    }

    // shots fly
    for (var s in shots) {
      if (s.y >= -10 && s.y <= 250) {
        s.y -= 7;
        if (s.y < -10) s.hide(); else s.update();
      }
    }

    // invaders march
    var minX = 1000.0, maxX = -1000.0, liveCount = 0;
    for (var i = 0; i < foes.length; i++) {
      if (!foeAlive[i]) continue;
      liveCount++;
      if (foes[i].x < minX) minX = foes[i].x + 0.0;
      if (foes[i].x > maxX) maxX = foes[i].x + 0.0;
    }
    if (liveCount == 0) { boom.play(); spawnWave(g, foeDef); return; }
    var speed = 0.6 + wave * 0.2 + (24 - liveCount) * 0.05;
    if ((dir > 0 && maxX > 404) || (dir < 0 && minX < 20)) {
      dir = -dir; drop = 8.0;
    }
    for (var i = 0; i < foes.length; i++) {
      if (!foeAlive[i]) continue;
      foes[i].x += speed * dir;
      foes[i].y += drop;
      foes[i].update();
      if (foes[i].y > 198) {                 // reached the ship line
        lives--;
        hurt2.play();
        spawnWave(g, foeDef);
        break;
      }
    }
    drop = 0.0;

    // hits
    for (var s in shots) {
      if (s.y < -10 || s.y > 250) continue;
      for (var i = 0; i < foes.length; i++) {
        if (!foeAlive[i]) continue;
        if (s.hits(foes[i], 2, 4, 7, 7)) {   // shot half-box vs foe half-box (12px)
          foeAlive[i] = false;
          foes[i].hide();
          s.y = -20; s.hide();
          score += 10;
          boom.play();
          break;
        }
      }
    }

    g.textClear();
    g.text(8, 6, score.toString(), 255, 255, 255);
    g.text(380, 6, lives.toString(), 255, 120, 120);
  });
}
