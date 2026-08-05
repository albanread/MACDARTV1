// sounded_model_test.dart — the sound editor's document, asserted headless.
// Pure Dart, no world; the window imports the SAME file (spriteed precedent).
import 'dart:math' as math;
import '../../cocoa/workspace/sounded_model.dart';

int fails = 0;
void check(String name, bool ok, [String detail = '']) {
  if (ok) { print('  ok    ' + name); }
  else { fails++; print('  FAIL  ' + name + (detail.isEmpty ? '' : ' - ' + detail)); }
}

main() {
  print('MACDART sound editor model test (headless)');

  var d = new SoundDoc();
  var p = d.paramsList();
  check('fresh doc: 14 header params + 1 osc', p.length == 19 && p[13] == 1);
  check('contract order holds',
      p[0] == 0.3 && p[1] == 0.01 && p[3] == 0.7 && p[12] == 12345,
      p.toString());

  d.duration = 99.0; d.s = 7.0; d.echoCount = 55; d.oscs[0].freq = 90000.0;
  d.clamp();
  check('clamps hold the engine ranges',
      d.duration == 4.0 && d.s == 1.0 && d.echoCount == 8 &&
      d.oscs[0].freq == 8000.0);

  // round-trip: params -> fromParams -> identical params
  var src = SoundDoc.preset('explode');
  var back = new SoundDoc();
  check('fromParams loads', back.fromParams(src.paramsList()));
  check('round-trip exact',
      back.paramsList().join(',') == src.paramsList().join(','),
      back.paramsList().toString());
  check('fromParams refuses a short list', !back.fromParams(<dynamic>[1, 2, 3]));
  check('fromParams refuses bad osc count',
      !back.fromParams(<dynamic>[0.3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 9]));

  // presets: transcription sanity
  var coin = SoundDoc.preset('coin');
  check('coin: two sines at the transcribed pitches',
      coin.oscs.length == 2 && coin.oscs[0].freq == 987.77 &&
      coin.oscs[1].freq == 1318.51 && coin.s == 0.3);
  var zap = SoundDoc.preset('zap');
  check('zap: oscillator-free sweep + noise',
      zap.oscs.isEmpty && zap.sweepStart == 1000.0 && zap.noiseMix == 0.2);
  check('the preset list is the eleven', SoundDoc.kPresets.length == 11);

  // randomize/mutate stay inside the clamps and change something
  var rng = new math.Random(42);
  var r1 = new SoundDoc();
  r1.randomize(rng);
  var before = r1.paramsList().join(',');
  check('randomize stays in range',
      r1.duration <= 4.0 && r1.oscs.length >= 1 && r1.oscs.length <= 4);
  r1.mutate(rng);
  check('mutate changes the sound', r1.paramsList().join(',') != before);

  // the saved form
  d = SoundDoc.preset('coin');
  d.name = 'CoinTest';
  var sheet = d.sheetSource();
  check('sheet: marker comment', sheet.startsWith('"SoundFx: CoinTest'));
  check('sheet: discovery marker', sheet.contains('isSoundSheet [ ^true ]'));
  check('sheet: params literal has floats ST can read',
      sheet.contains('987.77') && sheet.contains(' 0.3 '));
  check('sheet: playOn: is the two sends',
      sheet.contains('Sound effect: self params slot: slot') &&
      sheet.contains('Sound playSlot: slot'));
  check('sheet: play convenience', sheet.contains('play [ ^self playOn: 0 ]'));
  check('snippet: effect + play', d.codeSnippet().contains('Sound effect: #(') &&
      d.codeSnippet().contains('Sound playSlot: 3'));
  check('name validation',
      SoundDoc.validName('Laser2') && !SoundDoc.validName('laser') &&
      !SoundDoc.validName('My Laser'));

  print(fails == 0 ? 'SOUNDED-MODEL OK' : ('SOUNDED-MODEL ' + fails.toString() + ' FAILED'));
}
