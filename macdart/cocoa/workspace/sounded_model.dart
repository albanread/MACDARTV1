// sounded_model.dart — the sound editor's document, pure and headless.
//
// A document is one synth Effect (gp_synth.h): duration, ADSR, sweep, noise
// mix, distortion, echo, seed, and up to four oscillators. The FLAT PARAMS
// LIST is the contract shared by the native gpeffect op, the ST face
// (Sound effect:slot:), and saved sheets — SOUND_EDITOR_PLAN.md pins the
// order; paramsList()/fromParams() here are its one Dart spelling:
//   [duration, a, d, s, r, sweepStart, sweepEnd, noiseMix, distortion,
//    echoCount, echoDelay, echoDecay, seed, oscCount,
//    (wave, freq, amp, phase, pulseWidth) * oscCount]
// The ADSR is FIXED-DURATION: the envelope shapes the asked-for length,
// nothing renders past it (gp_synth_test.cc asserts the same rule).
import 'dart:math' as math;

const List<String> kSndWaves = const <String>[
  'sine', 'square', 'saw', 'triangle', 'noise', 'pulse'
];

class SndOsc {
  int wave = 0;              // index into kSndWaves
  double freq = 440.0;       // Hz
  double amp = 0.5;          // linear
  double phase = 0.0;        // radians
  double pw = 0.5;           // pulse width, Pulse only
  SndOsc(this.wave, this.freq, this.amp);
}

class SoundDoc {
  String name = 'Sound';
  double duration = 0.3;     // seconds, 0.01..4 (echo tail fits kMaxSamples)
  double a = 0.01, d = 0.1, s = 0.7, r = 0.2;   // attack/decay s, sustain LEVEL, release s
  double sweepStart = 0.0, sweepEnd = 0.0;      // Hz; skipped when equal
  double noiseMix = 0.0;     // 0..1
  double distortion = 0.0;   // tanh drive; skipped when <= 0
  int echoCount = 0;         // 0..8 taps
  double echoDelay = 0.0, echoDecay = 0.0;
  int seed = 12345;          // the LCG seed — same seed, same sound
  List<SndOsc> oscs = <SndOsc>[new SndOsc(0, 440.0, 0.5)];

  static double _c(num v, double lo, double hi) {
    var x = v.toDouble();
    return x < lo ? lo : (x > hi ? hi : x);
  }

  void clamp() {
    duration = _c(duration, 0.01, 4.0);
    a = _c(a, 0.0, 2.0); d = _c(d, 0.0, 2.0);
    s = _c(s, 0.0, 1.0); r = _c(r, 0.0, 2.0);
    sweepStart = _c(sweepStart, 0.0, 8000.0);
    sweepEnd = _c(sweepEnd, 0.0, 8000.0);
    noiseMix = _c(noiseMix, 0.0, 1.0);
    distortion = _c(distortion, 0.0, 1.0);
    if (echoCount < 0) echoCount = 0;
    if (echoCount > 8) echoCount = 8;
    echoDelay = _c(echoDelay, 0.0, 0.5);
    echoDecay = _c(echoDecay, 0.0, 0.95);
    if (oscs.length > 4) oscs = oscs.sublist(0, 4);
    for (var o in oscs) {
      if (o.wave < 0 || o.wave > 5) o.wave = 0;
      o.freq = _c(o.freq, 1.0, 8000.0);
      o.amp = _c(o.amp, 0.0, 1.0);
      o.phase = _c(o.phase, 0.0, 6.283185307179586);
      o.pw = _c(o.pw, 0.05, 0.95);
    }
  }

  List paramsList() {
    clamp();
    var p = <dynamic>[duration, a, d, s, r, sweepStart, sweepEnd,
        noiseMix, distortion, echoCount, echoDelay, echoDecay, seed,
        oscs.length];
    for (var o in oscs) {
      p.add(o.wave); p.add(o.freq); p.add(o.amp); p.add(o.phase); p.add(o.pw);
    }
    return p;
  }

  /// All-or-nothing load of the contract list (a saved sheet's `params`).
  bool fromParams(List p) {
    if (p == null || p.length < 14) return false;
    double n(i) => (p[i] as num).toDouble();
    var oc = (p[13] as num).toInt();
    if (oc < 0 || oc > 4 || p.length < 14 + oc * 5) return false;
    duration = n(0); a = n(1); d = n(2); s = n(3); r = n(4);
    sweepStart = n(5); sweepEnd = n(6); noiseMix = n(7); distortion = n(8);
    echoCount = (p[9] as num).toInt();
    echoDelay = n(10); echoDecay = n(11);
    seed = (p[12] as num).toInt();
    var no = <SndOsc>[];
    for (var i = 0; i < oc; i++) {
      var b = 14 + i * 5;
      var o = new SndOsc((p[b] as num).toInt(), n(b + 1), n(b + 2));
      o.phase = n(b + 3); o.pw = n(b + 4);
      no.add(o);
    }
    oscs = no;
    clamp();
    return true;
  }

  // --- the eleven presets, transcribed from gp_synth.cc as STARTING POINTS
  // (some presets randomize per render; the seed here makes ours exact).
  static SoundDoc preset(String which) {
    var doc = new SoundDoc();
    doc.oscs = <SndOsc>[];
    void env(double a_, double d_, double s_, double r_) {
      doc.a = a_; doc.d = d_; doc.s = s_; doc.r = r_;
    }
    switch (which) {
      case 'coin':
        doc.duration = 0.3;
        doc.oscs.add(new SndOsc(0, 987.77, 0.5));
        doc.oscs.add(new SndOsc(0, 1318.51, 0.3));
        env(0.01, 0.1, 0.3, 0.15);
        break;
      case 'jump':
        doc.duration = 0.2;
        doc.sweepStart = 300.0; doc.sweepEnd = 600.0;
        env(0.01, 0.05, 0.5, 0.1);
        break;
      case 'zap':
        doc.duration = 0.2;
        doc.sweepStart = 1000.0; doc.sweepEnd = 100.0;
        doc.noiseMix = 0.2;
        env(0.01, 0.05, 0.3, 0.08);
        break;
      case 'shoot':
        doc.duration = 0.15;
        doc.sweepStart = 800.0; doc.sweepEnd = 200.0;
        doc.noiseMix = 0.3;
        env(0.01, 0.05, 0.4, 0.08);
        break;
      case 'explode':
        doc.duration = 0.5;
        doc.oscs.add(new SndOsc(0, 58.0, 0.95));
        doc.oscs.add(new SndOsc(3, 86.0, 0.28));
        doc.noiseMix = 0.06;
        doc.sweepStart = 135.0; doc.sweepEnd = 32.0;
        doc.distortion = 0.08;
        env(0.0015, 0.14, 0.0, 0.10);
        break;
      case 'powerup':
        doc.duration = 0.4;
        doc.oscs.add(new SndOsc(1, 400.0, 0.4));
        doc.sweepStart = 200.0; doc.sweepEnd = 800.0;
        env(0.1, 0.1, 0.8, 0.2);
        break;
      case 'hurt':
        doc.duration = 0.25;
        doc.sweepStart = 600.0; doc.sweepEnd = 200.0;
        doc.noiseMix = 0.4;
        env(0.01, 0.1, 0.2, 0.15);
        break;
      case 'click':
        doc.duration = 0.05;
        doc.oscs.add(new SndOsc(4, 440.0, 0.3));
        env(0.001, 0.01, 0.0, 0.03);
        break;
      case 'bang':
        doc.duration = 0.3;
        doc.noiseMix = 0.8;
        env(0.01, 0.05, 0.0, 0.1);
        break;
      case 'wah':
        doc.duration = 0.9;
        doc.oscs.add(new SndOsc(0, 280.0, 0.45));
        doc.oscs.add(new SndOsc(0, 285.0, 0.45));
        env(0.01, 0.1, 0.92, 0.2);
        break;
      default:   // 'beep' and anything unknown: the plain tone
        doc.duration = 0.15;
        doc.oscs.add(new SndOsc(0, 440.0, 0.5));
        env(0.01, 0.05, 0.7, 0.1);
        break;
    }
    doc.clamp();
    return doc;
  }

  static const List<String> kPresets = const <String>['beep', 'coin', 'jump',
      'zap', 'shoot', 'explode', 'powerup', 'hurt', 'click', 'bang', 'wah'];

  /// The sfxr joy: a whole new sound in bounded, musical ranges.
  void randomize(math.Random rng) {
    duration = 0.08 + rng.nextDouble() * 0.6;
    a = rng.nextDouble() * 0.05;
    d = 0.02 + rng.nextDouble() * 0.2;
    s = rng.nextDouble();
    r = 0.02 + rng.nextDouble() * 0.3;
    var swept = rng.nextInt(3);          // 0 none, 1 up, 2 down
    if (swept == 0) { sweepStart = 0.0; sweepEnd = 0.0; }
    else {
      var lo = 80.0 + rng.nextDouble() * 400.0;
      var hi = lo * (1.5 + rng.nextDouble() * 3.0);
      sweepStart = swept == 1 ? lo : hi;
      sweepEnd = swept == 1 ? hi : lo;
    }
    noiseMix = rng.nextInt(3) == 0 ? rng.nextDouble() * 0.5 : 0.0;
    distortion = rng.nextInt(4) == 0 ? rng.nextDouble() * 0.3 : 0.0;
    echoCount = rng.nextInt(4) == 0 ? 1 + rng.nextInt(3) : 0;
    echoDelay = 0.04 + rng.nextDouble() * 0.15;
    echoDecay = 0.3 + rng.nextDouble() * 0.4;
    seed = rng.nextInt(0x7fffffff);
    oscs = <SndOsc>[];
    var n = 1 + rng.nextInt(2);
    for (var i = 0; i < n; i++) {
      var o = new SndOsc(rng.nextInt(4), 110.0 * (1 + rng.nextInt(8)),
          0.3 + rng.nextDouble() * 0.4);
      if (o.wave == 5) o.pw = 0.1 + rng.nextDouble() * 0.6;
      oscs.add(o);
    }
    clamp();
  }

  /// Nudge everything a little — explore around a sound you half-like.
  void mutate(math.Random rng) {
    double m(double v, double amt, double lo, double hi) {
      return _c(v + (rng.nextDouble() * 2 - 1) * amt, lo, hi);
    }
    duration = m(duration, 0.05, 0.02, 4.0);
    a = m(a, 0.01, 0.0, 2.0); d = m(d, 0.03, 0.0, 2.0);
    s = m(s, 0.1, 0.0, 1.0); r = m(r, 0.05, 0.0, 2.0);
    if (sweepStart > 0 || sweepEnd > 0) {
      sweepStart = m(sweepStart, 60.0, 0.0, 8000.0);
      sweepEnd = m(sweepEnd, 60.0, 0.0, 8000.0);
    }
    noiseMix = m(noiseMix, 0.05, 0.0, 1.0);
    for (var o in oscs) {
      o.freq = m(o.freq, o.freq * 0.08, 1.0, 8000.0);
      o.amp = m(o.amp, 0.06, 0.0, 1.0);
    }
    clamp();
  }

  // --- the saved form --------------------------------------------------------

  static final RegExp _kName = new RegExp(r'^[A-Z][A-Za-z0-9]*$');
  static bool validName(String x) { return x != null && _kName.hasMatch(x); }

  static String _num(num v) {
    if (v is int) return v.toString();
    var t = v.toString();
    return t.contains('.') || t.contains('e') ? t : (t + '.0');
  }

  String sheetSource() {
    var p = paramsList();
    var b = new StringBuffer();
    b.write('"SoundFx: ');
    b.write(name);
    b.write(' - WRITTEN BY THE SOUND EDITOR (Games menu). ');
    b.write(_num(duration));
    b.write('s, ');
    b.write(oscs.length.toString());
    b.write(' osc(s). Edit it here if you like - it is only source. ');
    b.write('In a game: ');
    b.write(name);
    b.write(' playOn: 3."\n');
    b.write('Object subclass: ');
    b.write(name);
    b.write(' [\n    ');
    b.write(name);
    b.write(' class >> isSoundSheet [ ^true ]\n    ');
    b.write(name);
    b.write(' class >> params [\n        ^#(');
    for (var v in p) { b.write(' '); b.write(_num(v)); }
    b.write(' )\n    ]\n    ');
    b.write(name);
    b.write(' class >> playOn: slot [\n');
    b.write('        Sound effect: self params slot: slot.\n');
    b.write('        Sound playSlot: slot\n    ]\n    ');
    b.write(name);
    b.write(' class >> play [ ^self playOn: 0 ]\n');
    b.write(']\n');
    return b.toString();
  }

  String codeSnippet() {
    var p = paramsList();
    var b = new StringBuffer();
    b.write('Sound effect: #(');
    for (var v in p) { b.write(' '); b.write(_num(v)); }
    b.write(' ) slot: 3.\n');
    b.write('Sound playSlot: 3.\n');
    return b.toString();
  }
}
