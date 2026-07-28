// MACDART game pane — the SFX synthesizer (pure C++, no ObjC, no GPU).
//
// A literal port of MacGamePane's audio/src/synth.rs (itself distilled from
// MacModula2's Audio.mod): an oscillator stack, a linear-frequency sweep, a
// noise blend, a fixed-duration ADSR, tanh soft-clip, in-place echo taps, and
// eleven hand-tuned presets. Deterministic given a seed — its own LCG, no
// global RNG. Everything renders 44.1kHz stereo interleaved doubles; the
// AVFoundation side (gp_engine.mm) converts to float32 deinterleaved at
// define time.
//
// Porting notes carried from the Rust (do NOT "fix" these — they are the
// sound): the saw's floor(n + 0.5) form; the sweep evaluated as sin(2πf(t)·t)
// rather than a phase-integrated chirp; echo taps that re-read samples earlier
// taps already wrote (deliberate extra feedback); normalize that only ever
// attenuates (peak > 1.0), never boosts.
#ifndef MACDART_GAMEPANE_GP_SYNTH_H_
#define MACDART_GAMEPANE_GP_SYNTH_H_

#include <stdint.h>
#include <vector>

namespace macdart_gamepane {

const uint32_t kSampleRate = 44100;
const size_t kMaxSamples = 882000;   // 10s stereo, interleaved sample count

enum Waveform {
  kSine = 0, kSquare = 1, kSaw = 2, kTriangle = 3, kNoise = 4, kPulse = 5,
};

// The LCG from synth.rs:158 — u32 state, x = x*1103515245 + 12345; the
// high-ish bits ((x/65536) % 32768) feed the float mappings.
struct Lcg {
  uint32_t state;
  explicit Lcg(uint32_t seed) : state(seed) {}
  uint32_t step() { state = state * 1103515245u + 12345u; return state; }
  double next_signed() {           // [-1, 1)
    return ((step() / 65536u) % 32768u) / 16384.0 - 1.0;
  }
  double next_unit() {             // [0, 1)
    return ((step() / 65536u) % 32768u) / 32768.0;
  }
};

struct Adsr {                      // attack/decay/release seconds; sustain a level
  double attack, decay, sustain, release;
};

struct Oscillator {
  Waveform wave;
  double frequency;                // Hz
  double amplitude;                // linear, summed unnormalized
  double phase;                    // radians offset
  double pulse_width;              // 0..1, Pulse only
};

// The recipe (synth.rs Effect): what to render.
struct Effect {
  double duration;                 // seconds; unclamped value feeds the ADSR
  std::vector<Oscillator> oscillators;   // capped at 4
  Adsr env;
  double sweep_start, sweep_end;   // Hz; sweep skipped when equal
  double noise_mix;                // 0..1 dry/wet with white noise
  double distortion;               // tanh drive amount; skipped when <= 0
  uint32_t echo_count;
  double echo_delay;               // seconds per tap
  double echo_decay;               // per-tap gain base

  explicit Effect(double dur);
  void add_osc(Waveform w, double freq, double amp);
  void set_env(double a, double d, double s, double r);
};

// A rendered PCM buffer: interleaved stereo doubles, nominally [-1,1].
struct Sound {
  uint32_t sample_rate;
  uint32_t channels;
  std::vector<double> samples;
};

// Render the recipe (synth.rs::render): osc stack + sweep + noise mix, then
// ADSR, then distortion, both channels at half amplitude, echo taps in place,
// normalize to 0.9 (attenuate-only).
Sound render(const Effect& e, Lcg& rng);

// Shaped noise bursts (synth.rs::noise): kind 0 white, 1 pink (Paul Kellet),
// 2 brown; (1-t)^2 envelope, 0.6 gain, normalize 0.95.
Sound noise_burst(int kind, double duration, Lcg& rng);

// The presets, parameter-for-parameter from synth.rs:390-505.
Sound preset_beep(double freq, double dur);
Sound preset_coin(double dur);
Sound preset_jump(double dur);
Sound preset_zap(double dur, Lcg& rng);
Sound preset_shoot(double dur, Lcg& rng);
Sound preset_explode(double size, double dur, Lcg& rng);
Sound preset_powerup(double dur);
Sound preset_hurt(double dur, Lcg& rng);
Sound preset_click(double dur, Lcg& rng);
Sound preset_bang(double dur, Lcg& rng);
Sound preset_blip(double pitch, double dur);
Sound preset_tone(double freq, double dur, Waveform wave);

}  // namespace macdart_gamepane

#endif  // MACDART_GAMEPANE_GP_SYNTH_H_
