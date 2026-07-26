// Demo: Mandelbrot zoom — four persistent workers, warm JIT, live frame times
//
// "One or more new isolates", and a lesson about this VM: the first frame is
// slow because four freshly spawned workers run cold, unoptimized code (the
// same loop measures 179ms cold and 4ms optimized). So the workers PERSIST:
// each frame they re-render their band of a steadily deepening view, and once
// the optimizer has seen the loop the frame time collapses — printed top-left,
// watch it happen. Pixels travel as Pixmap blits (demos/pixmap.dart), one
// message per band per frame.
import 'dart:async';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'pixmap.dart';

const int kScale = 2;          // compute at half resolution; blits scale up
const int kFrames = 110;       // finite: zoom this deep, report, exit clean
const double kZoomPerFrame = 0.94;
const double kCx = -0.74364388703715;   // seahorse valley
const double kCy = 0.13182590420533;

/// Worker: sits on a job port rendering bands until jobs stop coming (a 4s
/// idle timer is its exit — the demo may be killed and cannot say goodbye).
/// job: [reply, y0, y1, pw, ph, cx, cy, halfW, maxIter]
void band(List boot) {
  SendPort out = boot[0];
  var jobs = new ReceivePort();
  out.send(<dynamic>['port', jobs.sendPort]);
  Timer idle;
  jobs.listen((job) {
    if (idle != null) idle.cancel();
    idle = new Timer(const Duration(seconds: 4), () { jobs.close(); });
    SendPort reply = job[0];
    int y0 = job[1], y1 = job[2], pw = job[3], ph = job[4];
    double cx = job[5], cy = job[6], halfW = job[7];
    int maxIter = job[8];
    var lutR = new Uint8List(maxIter + 1);
    var lutG = new Uint8List(maxIter + 1);
    var lutB = new Uint8List(maxIter + 1);
    for (var n = 0; n < maxIter; n++) {
      var t = n / maxIter;
      lutR[n] = (min(1.0, 9.0 * (1 - t) * t * t * t) * 255.0).toInt();
      lutG[n] = (min(1.0, 15.0 * (1 - t) * (1 - t) * t * t) * 255.0).toInt();
      lutB[n] = (min(1.0, 8.5 * (1 - t) * (1 - t) * (1 - t) * t) * 255.0).toInt();
    }
    lutR[maxIter] = 0; lutG[maxIter] = 0; lutB[maxIter] = 5;
    var halfH = halfW * ph / pw;
    var px = new Pixmap(pw, y1 - y0);
    for (var dy = 0; dy < y1 - y0; dy++) {
      double ci = cy - halfH + 2.0 * halfH * (y0 + dy) / ph;
      double ci2 = ci * ci;
      for (var x = 0; x < pw; x++) {
        double cr = cx - halfW + 2.0 * halfW * x / pw;
        int n;
        double xq = cr - 0.25;
        double q = xq * xq + ci2;
        if (q * (q + xq) < 0.25 * ci2 ||
            (cr + 1.0) * (cr + 1.0) + ci2 < 0.0625) {
          n = maxIter;                       // interior, classified for free
        } else {
          double zr = 0.0, zi = 0.0;
          n = 0;
          while (n < maxIter) {
            double zr2 = zr * zr - zi * zi + cr;
            zi = 2.0 * zr * zi + ci;
            zr = zr2;
            if (zr * zr + zi * zi > 4.0) break;
            n++;
          }
        }
        px.set8(x, dy, lutR[n], lutG[n], lutB[n]);
      }
    }
    reply.send(<dynamic>[y0, px.blit(0, y0 * kScale, pw * kScale, (y1 - y0) * kScale)]);
  });
}

main(List args, SendPort ui) {
  var w = int.parse(args[0]), h = int.parse(args[1]);
  var pw = w ~/ kScale, ph = h ~/ kScale;
  var bandH = (ph / 4).ceil();
  var boot = new ReceivePort();
  var workers = <SendPort>[];
  var results = new ReceivePort();
  var sw = new Stopwatch()..start();
  var frame = 0, arrived = 0;
  var frameMs = 0, firstMs = 0;
  var halfW = 1.55;
  var cmds = <List>[];
  var frameClock = new Stopwatch()..start();

  void kick() {
    arrived = 0;
    cmds = <List>[];
    frameClock.reset();
    var maxIter = 96 + (frame * 3 ~/ 2);           // deeper needs more
    for (var k = 0; k < 4; k++) {
      workers[k].send(<dynamic>[results.sendPort, k * bandH,
          min((k + 1) * bandH, ph), pw, ph, kCx, kCy, halfW, maxIter]);
    }
  }

  ui.send(['status', 'spawning four workers (the only cold part)…']);
  for (var k = 0; k < 4; k++) {
    Isolate.spawn(band, <dynamic>[boot.sendPort]);
  }
  boot.listen((m) {
    workers.add(m[1]);
    if (workers.length == 4) { boot.close(); kick(); }
  });

  results.listen((m) {
    cmds.add(m[1]);
    arrived++;
    if (arrived < 4) return;
    frameMs = frameClock.elapsedMilliseconds;
    if (frame == 0) firstMs = frameMs;
    cmds.add(<dynamic>['text', 10.0, 8.0,
        'frame ' + frame.toString() + '  compute ' + frameMs.toString() +
        'ms  (first was ' + firstMs.toString() + 'ms — cold JIT)',
        11.0, 0.85, 0.88, 0.95]);
    ui.send(['draw', cmds]);
    frame++;
    halfW *= kZoomPerFrame;
    if (frame < kFrames) {
      // Pace to ~30ms/frame: the screen cannot show more, and a zoom that
      // finishes in a blink is not an animation. Compute (frameMs) stays
      // honest — the gap is deliberate idle.
      var wait = 30 - frameClock.elapsedMilliseconds;
      if (wait < 1) wait = 1;
      new Timer(new Duration(milliseconds: wait), kick);
      return;
    }
    ui.send(['done', 'pixmaps from 4 worker isolates: ' + kFrames.toString() +
        ' zoom frames in ' + sw.elapsedMilliseconds.toString() +
        'ms — compute ' + firstMs.toString() + 'ms cold, ' +
        frameMs.toString() + 'ms warm, paced ~30ms for the screen']);
    results.close();   // workers' idle timers retire them; this isolate exits
  });
}
