// gp_synth_test.cc — the synth's presets, measured rather than described.
//
// The pane's SFX are rendered PCM, so a preset can be checked the way a person
// checks it: look at the shape of the sound. This one exists because "wah-wah"
// is a claim about an ENVELOPE — two sines a few Hz apart beating against each
// other — and a tremolo, a plain tone, or a detune typo would all still "play
// a sound". It counts the beats.
//
//   clang++ -std=c++17 -O1 gp_synth_test.cc gp_synth.cc -o gp_synth_test && ./gp_synth_test
//
// No Metal, no window, no Dart: gp_synth.cc is pure C++.
#include "gp_synth.h"

#include <cmath>
#include <cstdio>
#include <vector>

using namespace macdart_gamepane;

namespace {

int failures = 0;

void check(bool ok, const char* what, const char* detail) {
  printf("  %s  %s%s%s\n", ok ? "ok  " : "FAIL", what,
         detail[0] ? " — " : "", detail);
  if (!ok) failures++;
}

// Peak magnitude per 5 ms window: the sound's envelope, which is what the ear
// hears as the warble.
std::vector<double> envelope(const Sound& s) {
  std::vector<double> env;
  int win = (int)s.sample_rate / 200;
  size_t step = (size_t)win * s.channels;
  for (size_t i = 0; i + step < s.samples.size(); i += step) {
    double m = 0.0;
    for (size_t k = 0; k < step; k++) m = fmax(m, fabs(s.samples[i + k]));
    env.push_back(m);
  }
  return env;
}

// One beat = the envelope falling to a trough and climbing back out. Counted
// with hysteresis so ripple in the tops cannot inflate it.
int count_beats(const std::vector<double>& env, double lo, double hi) {
  int beats = 0;
  bool in_trough = false;
  for (double v : env) {
    if (!in_trough && v < lo) in_trough = true;
    else if (in_trough && v > hi) { in_trough = false; beats++; }
  }
  return beats;
}

}  // namespace

int main() {
  printf("== gp_synth ==\n");

  // The saucer warble: 280 Hz against 285 Hz for 0.9s. Five Hz of detune is
  // five beats a second, so a 0.9s note carries four of them.
  Sound wah = preset_wah(280.0, 5.0, 0.9);
  char buf[128];
  double secs = (double)(wah.samples.size() / wah.channels) / wah.sample_rate;
  snprintf(buf, sizeof buf, "%.2fs, %u Hz, %u ch", secs, wah.sample_rate,
           wah.channels);
  check(fabs(secs - 0.9) < 0.05, "wah is the length asked for", buf);

  std::vector<double> env = envelope(wah);
  int beats = count_beats(env, 0.10, 0.30);
  snprintf(buf, sizeof buf, "%d beats in %.2fs (5 Hz detune => 4-5)", beats, secs);
  check(beats >= 3 && beats <= 6, "wah warbles", buf);

  double peak = 0.0;
  for (double v : env) peak = fmax(peak, v);
  snprintf(buf, sizeof buf, "peak %.2f", peak);
  check(peak > 0.3, "wah is audible", buf);

  // The detune IS the rate: double it and the beats double with it.
  int fast = count_beats(envelope(preset_wah(280.0, 10.0, 0.9)), 0.10, 0.30);
  snprintf(buf, sizeof buf, "5 Hz -> %d beats, 10 Hz -> %d", beats, fast);
  check(fast > beats, "detune sets the wah rate", buf);

  // A single sine must NOT warble — the guard that says the beating comes from
  // interference and not from something in the envelope generator.
  int plain = count_beats(envelope(preset_beep(280.0, 0.9)), 0.10, 0.30);
  snprintf(buf, sizeof buf, "%d beats", plain);
  check(plain == 0, "a plain tone does not warble", buf);

  printf("== %s ==\n", failures == 0 ? "SYNTH OK" : "SYNTH FAILED");
  return failures == 0 ? 0 : 1;
}
