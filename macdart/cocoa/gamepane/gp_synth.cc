// MACDART game pane — SFX synthesizer implementation. See gp_synth.h for the
// porting laws; every formula here mirrors MacGamePane audio/src/synth.rs.
#include "gp_synth.h"

#include <math.h>
#include <algorithm>

namespace macdart_gamepane {

static const double kPi = 3.14159265358979323846;
static const double kTwoPi = 2.0 * kPi;

static double rem_euclid(double x, double m) { return x - m * floor(x / m); }

// synth.rs::wave_sample — phase in radians.
static double wave_sample(Waveform w, double phase, double pw, Lcg& rng) {
  switch (w) {
    case kSine: return sin(phase);
    case kSquare: return rem_euclid(phase, kTwoPi) < kPi ? 1.0 : -1.0;
    case kSaw: {
      double n = phase / kTwoPi;
      return 2.0 * (n - floor(n + 0.5));       // the non-standard form, kept
    }
    case kTriangle: {
      double t = rem_euclid(phase / kTwoPi, 1.0);
      return 4.0 * fabs(t - 0.5) - 1.0;
    }
    case kNoise: return rng.next_signed();
    case kPulse: {
      double t = rem_euclid(phase, kTwoPi) / kTwoPi;
      return t < pw ? 1.0 : -1.0;
    }
  }
  return 0.0;
}

// synth.rs::adsr_value_at — the fixed-duration envelope.
static double adsr_value_at(const Adsr& env, double time, double note_dur) {
  if (time < 0.0) return 0.0;
  double total = env.attack + env.decay + env.release;
  double sustain_time = note_dur - total;
  if (sustain_time < 0.0) sustain_time = 0.0;
  double t = time;
  if (t <= env.attack) return env.attack <= 0.0 ? 1.0 : t / env.attack;
  t -= env.attack;
  if (t <= env.decay) {
    return env.decay <= 0.0 ? env.sustain
                            : 1.0 - (t / env.decay) * (1.0 - env.sustain);
  }
  t -= env.decay;
  if (t <= sustain_time) return env.sustain;
  t -= sustain_time;
  if (t <= env.release) {
    return env.release <= 0.0 ? 0.0 : env.sustain * (1.0 - t / env.release);
  }
  return 0.0;
}

// synth.rs::normalize — only ever attenuates.
static void normalize(Sound* s, double target) {
  double peak = 0.0;
  for (size_t i = 0; i < s->samples.size(); i++) {
    double a = fabs(s->samples[i]);
    if (a > peak) peak = a;
  }
  if (peak > 1.0) {
    double t = target < 0.0 ? 0.0 : (target > 1.0 ? 1.0 : target);
    double k = t / peak;
    for (size_t i = 0; i < s->samples.size(); i++) s->samples[i] *= k;
  }
}

Effect::Effect(double dur)
    : duration(dur),
      env(),
      sweep_start(0.0), sweep_end(0.0),
      noise_mix(0.0), distortion(0.0),
      echo_count(0), echo_delay(0.0), echo_decay(0.0) {
  env.attack = 0.01; env.decay = 0.1; env.sustain = 0.7; env.release = 0.2;
}

void Effect::add_osc(Waveform w, double freq, double amp) {
  if (oscillators.size() >= 4) return;       // silently capped, as in Rust
  Oscillator o;
  o.wave = w; o.frequency = freq; o.amplitude = amp;
  o.phase = 0.0; o.pulse_width = 0.5;
  oscillators.push_back(o);
}

void Effect::set_env(double a, double d, double s, double r) {
  env.attack = a; env.decay = d; env.sustain = s; env.release = r;
}

Sound render(const Effect& e, Lcg& rng) {
  double clamped = e.duration;
  if (clamped < 0.0) clamped = 0.0;
  if (clamped > 10.0) clamped = 10.0;
  if (clamped <= 0.0) clamped = 0.01;

  Sound out;
  out.sample_rate = kSampleRate;
  out.channels = 2;
  size_t total = (size_t)(kSampleRate * clamped) * 2;
  if (total > kMaxSamples) total = kMaxSamples;
  if (total < 2) total = 2;
  size_t frames = total / 2;
  out.samples.assign(total, 0.0);

  double dt = 1.0 / kSampleRate;
  for (size_t f = 0; f < frames; f++) {
    double time = f * dt;
    double sample = 0.0;
    for (size_t i = 0; i < e.oscillators.size(); i++) {
      const Oscillator& o = e.oscillators[i];
      double phase = kTwoPi * o.frequency * time + o.phase;
      sample += wave_sample(o.wave, phase, o.pulse_width, rng) * o.amplitude;
    }
    if (e.sweep_start != e.sweep_end) {
      double sweep_t = time / clamped;
      double freq = e.sweep_start + (e.sweep_end - e.sweep_start) * sweep_t;
      sample += sin(kTwoPi * freq * time) * 0.5;   // sin(2πf(t)·t), kept
    }
    if (e.noise_mix > 0.0) {
      double n = rng.next_signed();
      sample = sample * (1.0 - e.noise_mix) + n * e.noise_mix;
    }
    sample *= adsr_value_at(e.env, time, e.duration);   // unclamped duration
    if (e.distortion > 0.0) {
      double drive = 1.0 + e.distortion * 10.0;
      double denom = tanh(drive);
      if (denom != 0.0) sample = tanh(sample * drive) / denom;
    }
    out.samples[f * 2] = sample * 0.5;
    out.samples[f * 2 + 1] = sample * 0.5;
  }

  // Echo taps, in place; later taps deliberately re-read earlier taps' output.
  if (e.echo_count > 0 && e.echo_delay > 0.0) {
    size_t delay_frames = (size_t)(e.echo_delay * kSampleRate);
    for (uint32_t echo = 0; echo < e.echo_count; echo++) {
      size_t echo_start = delay_frames * (echo + 1);
      double amp = pow(e.echo_decay, (double)(echo + 1));
      if (echo_start >= frames) continue;
      for (size_t frame = 0; frame < frames - echo_start; frame++) {
        for (int ch = 0; ch < 2; ch++) {
          out.samples[(frame + echo_start) * 2 + ch] +=
              out.samples[frame * 2 + ch] * amp;
        }
      }
    }
  }

  normalize(&out, 0.9);
  return out;
}

Sound noise_burst(int kind, double duration, Lcg& rng) {
  if (duration < 0.01) duration = 0.01;
  Sound out;
  out.sample_rate = kSampleRate;
  out.channels = 2;
  size_t total = (size_t)(kSampleRate * duration) * 2;
  if (total > kMaxSamples) total = kMaxSamples;
  if (total < 2) total = 2;
  size_t frames = total / 2;
  out.samples.assign(total, 0.0);

  double p0 = 0.0, p1 = 0.0, p2 = 0.0, brown = 0.0;
  for (size_t f = 0; f < frames; f++) {
    double value = rng.next_signed();
    if (kind == 1) {                          // pink (Paul Kellet)
      p0 = 0.99765 * p0 + value * 0.0990460;
      p1 = 0.96300 * p1 + value * 0.2965164;
      p2 = 0.57000 * p2 + value * 1.0526913;
      value = (p0 + p1 + p2 + value * 0.1848) * 0.25;
    } else if (kind == 2) {                   // brown
      brown += value * 0.02;
      if (brown < -1.0) brown = -1.0;
      if (brown > 1.0) brown = 1.0;
      value = brown;
    }
    double t = (double)f / (double)frames;
    double env = (1.0 - t) * (1.0 - t);
    value *= env * 0.6;
    out.samples[f * 2] = value;               // no extra *0.5 here (as Rust)
    out.samples[f * 2 + 1] = value;
  }
  normalize(&out, 0.95);
  return out;
}

// --- presets, parameter-for-parameter from synth.rs:390-505 -----------------

Sound preset_beep(double freq, double dur) {
  Effect e(dur);
  e.add_osc(kSine, freq, 0.5);
  e.set_env(0.01, 0.05, 0.7, 0.1);
  Lcg rng(0);
  return render(e, rng);
}

Sound preset_coin(double dur) {
  Effect e(dur);
  e.add_osc(kSine, 987.77, 0.5);
  e.add_osc(kSine, 1318.51, 0.3);
  e.set_env(0.01, 0.1, 0.3, 0.15);
  Lcg rng(0);
  return render(e, rng);
}

Sound preset_jump(double dur) {
  Effect e(dur);
  e.sweep_start = 300.0; e.sweep_end = 600.0;
  e.set_env(0.01, 0.05, 0.5, 0.1);
  Lcg rng(0);
  return render(e, rng);
}

Sound preset_zap(double dur, Lcg& rng) {
  Effect e(dur);
  e.sweep_start = 1000.0; e.sweep_end = 100.0;
  e.noise_mix = 0.2;
  e.set_env(0.01, 0.05, 0.3, 0.08);
  return render(e, rng);
}

Sound preset_shoot(double dur, Lcg& rng) {
  Effect e(dur);
  e.sweep_start = 800.0; e.sweep_end = 200.0;
  e.noise_mix = 0.3;
  e.set_env(0.01, 0.05, 0.4, 0.08);
  return render(e, rng);
}

Sound preset_explode(double size, double dur, Lcg& rng) {
  Effect e(dur);
  e.add_osc(kSine, 58.0, 0.95);
  e.add_osc(kTriangle, 86.0, 0.28);
  double mix = 0.06 * size;
  if (mix < 0.0) mix = 0.0;
  if (mix > 0.12) mix = 0.12;
  e.noise_mix = mix;
  e.sweep_start = 135.0; e.sweep_end = 32.0;
  e.distortion = 0.08;
  e.set_env(0.0015, 0.14, 0.0, 0.10);
  return render(e, rng);
}

Sound preset_powerup(double dur) {
  Effect e(dur);
  e.add_osc(kSquare, 400.0, 0.4);
  e.sweep_start = 200.0; e.sweep_end = 800.0;
  e.set_env(0.1, 0.1, 0.8, 0.2);
  Lcg rng(0);
  return render(e, rng);
}

Sound preset_hurt(double dur, Lcg& rng) {
  Effect e(dur);
  e.sweep_start = 600.0; e.sweep_end = 200.0;
  e.noise_mix = 0.4;
  e.set_env(0.01, 0.1, 0.2, 0.15);
  return render(e, rng);
}

Sound preset_click(double dur, Lcg& rng) {
  Effect e(dur);
  e.add_osc(kNoise, 440.0, 0.3);
  e.set_env(0.001, 0.01, 0.0, 0.03);
  return render(e, rng);
}

Sound preset_bang(double dur, Lcg& rng) {
  Effect e(dur);
  e.noise_mix = 0.8;
  e.set_env(0.01, 0.05, 0.0, 0.1);
  return render(e, rng);
}

Sound preset_blip(double pitch, double dur) {
  return preset_beep(800.0 * pitch, dur);
}

Sound preset_tone(double freq, double dur, Waveform wave) {
  Effect e(dur);
  e.set_env(0.01, 0.05, 0.8, 0.1);
  if (freq < 1.0) freq = 1.0;
  e.add_osc(wave, freq, 0.75);
  if (!e.oscillators.empty()) {
    e.oscillators.back().pulse_width = (wave == kPulse) ? 0.25 : 0.5;
  }
  Lcg rng(0);
  return render(e, rng);
}

}  // namespace macdart_gamepane
