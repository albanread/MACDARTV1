// ABC notation — a practical subset compiled to flat MIDI events, in Dart.
// (A library games import; no demo-title header.)
//
// The parse runs in the GAME isolate — pure computation, hot-reloadable,
// debuggable — and only the compiled event list crosses the wire; the native
// side just wraps it in a Standard MIDI File for AVMIDIPlayer. This mirrors
// MacGamePane's boundary (Tune{events, bpm, endMs}) while keeping its 1,100-
// line Rust parser out of the VM: the subset below covers game chiptunes.
//
// Supported: X/T/M/L/Q/K headers, %%MIDI program N, notes A-G/a-g with
// ' , octaves and ^ ^^ _ __ = accidentals (bar-scoped, key-signature aware),
// durations (2, 3/2, /2, //), dotted pairs > <, rests z/x, chords [ceg],
// triplets (3, bar lines (reset accidentals), and one level of |: ... :|
// repeats (textually expanded). Velocity fixed at 80, channel 0.
library abc;

class AbcTune {
  /// Flat [timeMs, status, data1, data2, ...] — status already carries
  /// channel 0 (0x90 on, 0x80 off, 0xC0 program; d2 ignored for 0xC0).
  final List<int> events;
  final int bpm;
  final int endMs;
  AbcTune(this.events, this.bpm, this.endMs);
}

// Key signature -> the set of note letters sharpened (+1) or flattened (-1).
// Sharps enter F C G D A E B; flats B E A D G C F. Minors map to their
// relative major. Unknown keys fall back to C.
Map<String, int> _keySig(String k) {
  k = k.trim();
  var minor = false;
  var m = k.toLowerCase();
  if (m.endsWith('min')) { k = k.substring(0, k.length - 3); minor = true; }
  else if (m.endsWith('m') && k.length > 1) { k = k.substring(0, k.length - 1); minor = true; }
  else if (m.endsWith('maj')) { k = k.substring(0, k.length - 3); }
  k = k.trim();
  const order = 'FCGDAEB';
  const majors = const <String, int>{                 // name -> sharps(+)/flats(-)
    'C': 0, 'G': 1, 'D': 2, 'A': 3, 'E': 4, 'B': 5, 'F#': 6, 'C#': 7,
    'F': -1, 'BB': -2, 'EB': -3, 'AB': -4, 'DB': -5, 'GB': -6, 'CB': -7,
  };
  const relMajorOfMinor = const <String, String>{     // Am -> C etc.
    'A': 'C', 'E': 'G', 'B': 'D', 'F#': 'A', 'C#': 'E', 'G#': 'B',
    'D': 'F', 'G': 'BB', 'C': 'EB', 'F': 'AB', 'BB': 'DB', 'EB': 'GB',
  };
  var name = k.toUpperCase().replaceAll('♭', 'B');
  if (minor && relMajorOfMinor.containsKey(name)) name = relMajorOfMinor[name];
  var n = majors.containsKey(name) ? majors[name] : 0;
  var sig = <String, int>{};
  if (n > 0) for (var i = 0; i < n; i++) sig[order[i]] = 1;
  if (n < 0) for (var i = 0; i < -n; i++) sig[order[6 - i]] = -1;
  return sig;
}

const Map<String, int> _letterSemi = const {
  'C': 0, 'D': 2, 'E': 4, 'F': 5, 'G': 7, 'A': 9, 'B': 11,
};

AbcTune parseAbc(String src) {
  var bpm = 120;
  var unitNum = 1, unitDen = 8;                 // L: default 1/8
  var meterDecimal = 1.0;                       // M: sets default L if no L:
  var sawL = false;
  var program = -1;
  var sig = <String, int>{};
  var body = new StringBuffer();

  // --- headers (line-based until K:, which ends the header) -----------------
  var lines = src.split('\n');
  var inBody = false;
  for (var line in lines) {
    var t = line.trim();
    if (t.isEmpty || t.startsWith('%')) {
      if (t.startsWith('%%MIDI')) {
        var parts = t.split(new RegExp(r'\s+'));
        if (parts.length >= 3 && parts[1] == 'program') {
          program = int.parse(parts[2], onError: (_) => -1);
        }
      }
      continue;
    }
    if (!inBody && t.length > 1 && t[1] == ':' && 'XTMLQKVRZNOHW'.contains(t[0])) {
      var field = t[0];
      var val = t.substring(2).trim();
      if (field == 'M') {
        var mm = val.split('/');
        if (mm.length == 2) {
          var a = int.parse(mm[0], onError: (_) => 4);
          var b = int.parse(mm[1], onError: (_) => 4);
          if (b != 0) meterDecimal = a / b;
        }
      } else if (field == 'L') {
        var ll = val.split('/');
        if (ll.length == 2) {
          unitNum = int.parse(ll[0], onError: (_) => 1);
          unitDen = int.parse(ll[1], onError: (_) => 8);
          sawL = true;
        }
      } else if (field == 'Q') {
        // "1/4=120" or bare "120"
        var eq = val.indexOf('=');
        var beat = eq >= 0 ? val.substring(eq + 1) : val;
        bpm = int.parse(beat.trim(), onError: (_) => 120);
        if (bpm <= 0) bpm = 120;
      } else if (field == 'K') {
        sig = _keySig(val);
        inBody = true;                          // K: ends the header
      }
      continue;
    }
    if (inBody) body.write(t + ' ');
    // Lines before any K: that aren't fields: treat as body too (lenient).
    if (!inBody && !(t.length > 1 && t[1] == ':')) { body.write(t + ' '); inBody = true; }
  }
  if (!sawL) { unitNum = 1; unitDen = meterDecimal < 0.75 ? 16 : 8; }

  // one level of |: ... :| expansion, textual (as the reference does)
  var text = body.toString();
  var open = text.indexOf('|:');
  var close = text.indexOf(':|');
  if (close >= 0) {
    var start = open >= 0 && open < close ? open + 2 : 0;
    var section = text.substring(start, close);
    text = text.substring(0, start) + section + ' | ' + section +
        text.substring(close + 2);
  }

  // --- the body -------------------------------------------------------------
  var events = <int>[];
  var wholeMs = 4.0 * 60000.0 / bpm;            // one whole note, ms
  var unit = unitNum / unitDen;                  // in whole notes
  var t = 0.0;
  var barAcc = <String, int>{};                  // "C4"-keyed bar accidentals
  var tupletLeft = 0;
  var tupletFactor = 1.0;
  var pendingBroken = 0;                        // +1: prev was '>', -1: '<'

  if (program >= 0 && program <= 127) {
    events.add(0); events.add(0xC0); events.add(program); events.add(0);
  }

  void emit(int midi, double durWhole) {
    var startMs = t.round();
    var offMs = (t + durWhole * wholeMs * 0.92).round();
    if (offMs <= startMs) offMs = startMs + 10;
    events.add(startMs); events.add(0x90); events.add(midi); events.add(80);
    events.add(offMs); events.add(0x80); events.add(midi); events.add(0);
  }

  var i = 0;
  double readDur() {                            // suffix duration multiplier
    var num = 0, den = 0, slashes = 0;
    while (i < text.length && text[i].compareTo('0') >= 0 &&
           text[i].compareTo('9') <= 0) {
      num = num * 10 + (text.codeUnitAt(i) - 48); i++;
    }
    while (i < text.length && text[i] == '/') { slashes++; i++; }
    if (slashes > 0) {
      while (i < text.length && text[i].compareTo('0') >= 0 &&
             text[i].compareTo('9') <= 0) {
        den = den * 10 + (text.codeUnitAt(i) - 48); i++;
      }
    }
    var mult = num == 0 ? 1.0 : num.toDouble();
    if (slashes > 0) {
      mult /= den != 0 ? den : (1 << slashes);  // "/" = /2, "//" = /4
    }
    return mult;
  }

  double applyMods(double d) {
    if (tupletLeft > 0) { d *= tupletFactor; tupletLeft--; }
    if (pendingBroken != 0) {
      d *= pendingBroken > 0 ? 0.5 : 1.5;       // this note is the second half
      pendingBroken = 0;
    }
    if (i < text.length && (text[i] == '>' || text[i] == '<')) {
      var c = text[i]; i++;
      d *= c == '>' ? 1.5 : 0.5;
      pendingBroken = c == '>' ? 1 : -1;
    }
    return d;
  }

  // One note starting at text[i] (accidental already parsed by caller).
  int readPitch(int accOverride, bool haveAcc) {
    var c = text[i];
    var upper = c.toUpperCase();
    var octave = c == upper ? 4 : 5;            // C = middle C (octave 4)
    i++;
    while (i < text.length && (text[i] == "'" || text[i] == ',')) {
      if (text[i] == "'") octave++; else octave--;
      i++;
    }
    var key = upper + octave.toString();
    var acc;
    if (haveAcc) { acc = accOverride; barAcc[key] = accOverride; }
    else if (barAcc.containsKey(key)) { acc = barAcc[key]; }
    else { acc = sig.containsKey(upper) ? sig[upper] : 0; }
    return 12 * (octave + 1) + _letterSemi[upper] + acc;
  }

  while (i < text.length) {
    var c = text[i];
    if (c == ' ' || c == '\t') { i++; continue; }
    if (c == '|' || c == ':') {                 // bar (and leftover repeat colons)
      barAcc.clear(); i++; continue;
    }
    if (c == '(') {                             // tuplet: only (3 supported
      i++;
      if (i < text.length && text[i] == '3') {
        tupletLeft = 3; tupletFactor = 2.0 / 3.0; i++;
      }
      continue;
    }
    if (c == 'z' || c == 'x' || c == 'Z') {     // rest
      i++;
      var d = applyMods(unit * readDur());
      t += d * wholeMs;
      continue;
    }
    if (c == '[') {                             // chord: notes share the start
      i++;
      var durs = <double>[];
      while (i < text.length && text[i] != ']') {
        var acc = 0; var haveAcc = false;
        while (i < text.length && (text[i] == '^' || text[i] == '_' || text[i] == '=')) {
          haveAcc = true;
          if (text[i] == '^') acc++;
          if (text[i] == '_') acc--;
          i++;
        }
        if (i < text.length && _letterSemi.containsKey(text[i].toUpperCase())) {
          var midi = readPitch(acc, haveAcc);
          var d = unit * readDur();
          durs.add(d);
          emit(midi, d);
        } else { i++; }
      }
      if (i < text.length) i++;                 // ']'
      var chordDur = 0.0;
      for (var d in durs) if (d > chordDur) chordDur = d;
      chordDur = applyMods(chordDur == 0.0 ? unit : chordDur);
      t += chordDur * wholeMs;
      continue;
    }
    var acc = 0; var haveAcc = false;
    while (i < text.length && (text[i] == '^' || text[i] == '_' || text[i] == '=')) {
      haveAcc = true;
      if (text[i] == '^') acc++;
      if (text[i] == '_') acc--;
      i++;
    }
    if (i < text.length && _letterSemi.containsKey(text[i].toUpperCase())) {
      var midi = readPitch(acc, haveAcc);
      var d = applyMods(unit * readDur());
      emit(midi, d);
      t += d * wholeMs;
      continue;
    }
    i++;                                        // anything else: skip
  }

  // sort by time (stable insertion keeps on-before-off at equal times sane)
  var idx = new List<int>.generate(events.length ~/ 4, (k) => k);
  idx.sort((a, b) => events[a * 4] - events[b * 4]);
  var sorted = <int>[];
  for (var k in idx) {
    sorted.add(events[k * 4]); sorted.add(events[k * 4 + 1]);
    sorted.add(events[k * 4 + 2]); sorted.add(events[k * 4 + 3]);
  }
  var end = 0;
  for (var k = 0; k < sorted.length; k += 4) {
    if (sorted[k] > end) end = sorted[k];
  }
  return new AbcTune(sorted, bpm, end + 200);
}
