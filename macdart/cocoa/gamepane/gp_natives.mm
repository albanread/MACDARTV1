// MACDART game pane — the Dart boundary (GAMEPANE_PLAN.md §2, §6).
//
// Five natives: open/close, apply (a whole frame's command list walked in ONE
// native call — the wire's atomicity is what kills MACVM's mid-frame-present
// flicker class), snap (honest offscreen readback; window snapshots cannot
// see a CAMetalLayer), and stat. Every argument is validated HERE and a bad
// one costs an error string, never an abort — the engine setters trust their
// callers, so this boundary is where raw wire numbers get checked.
#include "gp_engine.h"

#include "../../../sdk/runtime/include/dart_api.h"

#include <string>
#include <vector>

namespace dart {
namespace bin {

using namespace macdart_gamepane;

// --- small wire readers ------------------------------------------------------

static int64_t ElInt(Dart_Handle list, intptr_t i) {
  Dart_Handle h = Dart_ListGetAt(list, i);
  if (Dart_IsInteger(h)) {
    int64_t v = 0;
    Dart_IntegerToInt64(h, &v);
    return v;
  }
  if (Dart_IsDouble(h)) {
    double d = 0;
    Dart_DoubleValue(h, &d);
    return (int64_t)d;
  }
  return 0;
}

static double ElDouble(Dart_Handle list, intptr_t i) {
  Dart_Handle h = Dart_ListGetAt(list, i);
  if (Dart_IsDouble(h)) {
    double d = 0;
    Dart_DoubleValue(h, &d);
    return d;
  }
  if (Dart_IsInteger(h)) {
    int64_t v = 0;
    Dart_IntegerToInt64(h, &v);
    return (double)v;
  }
  return 0.0;
}

static const char* ElStr(Dart_Handle list, intptr_t i) {
  Dart_Handle h = Dart_ListGetAt(list, i);
  if (!Dart_IsString(h)) return NULL;
  const char* c = NULL;
  Dart_StringToCString(h, &c);              // scope-allocated
  return c;
}

static uint8_t ClampByte(int64_t v) {
  return (uint8_t)(v < 0 ? 0 : (v > 255 ? 255 : v));
}

// Standard base64 (the same alphabet Dart's BASE64.encode emits).
static bool DecodeB64(const char* s, std::vector<uint8_t>* out) {
  static int8_t table[256];
  static bool init = false;
  if (!init) {
    for (int i = 0; i < 256; i++) table[i] = -1;
    const char* alpha =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    for (int i = 0; i < 64; i++) table[(uint8_t)alpha[i]] = (int8_t)i;
    init = true;
  }
  out->clear();
  uint32_t acc = 0;
  int bits = 0;
  for (const char* p = s; *p != '\0'; p++) {
    if (*p == '=' || *p == '\n' || *p == '\r') continue;
    int8_t v = table[(uint8_t)*p];
    if (v < 0) return false;
    acc = (acc << 6) | (uint32_t)v;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out->push_back((uint8_t)(acc >> bits));
    }
  }
  return true;
}

// --- the natives -------------------------------------------------------------

// _gpOpen(w, h, worldW, worldH, mode) -> NSView handle. mode 1 = direct (§6b).
void Cocoa_gpOpen(Dart_NativeArguments args) {
  int64_t w = 0, h = 0, ww = 0, wh = 0, mode = 0;
  Dart_IntegerToInt64(Dart_GetNativeArgument(args, 0), &w);
  Dart_IntegerToInt64(Dart_GetNativeArgument(args, 1), &h);
  Dart_IntegerToInt64(Dart_GetNativeArgument(args, 2), &ww);
  Dart_IntegerToInt64(Dart_GetNativeArgument(args, 3), &wh);
  Dart_IntegerToInt64(Dart_GetNativeArgument(args, 4), &mode);
  if (w < 32 || h < 32 || w > 2048 || h > 2048) {
    Dart_ThrowException(Dart_NewStringFromCString(
        "gamepane: viewport must be 32..2048"));
    return;
  }
  if (ww > 8192 || wh > 8192) {
    Dart_ThrowException(Dart_NewStringFromCString(
        "gamepane: world must be <= 8192"));
    return;
  }
  std::string err;
  NSView* view = GpEngine::instance()->open((int)w, (int)h,
                                            (int)ww, (int)wh, mode != 0, &err);
  if (view == nil) {
    Dart_ThrowException(Dart_NewStringFromCString(
        err.empty() ? "gamepane: open failed" : err.c_str()));
    return;
  }
  Dart_SetReturnValue(args, Dart_NewInteger((int64_t)view));
}

void Cocoa_gpClose(Dart_NativeArguments args) {
  GpEngine::instance()->close();
  Dart_SetReturnValue(args, Dart_Null());
}

// _gpApply(cmds) -> null, or the FIRST error as a String (frame still
// applied best-effort — a typo'd verb costs that verb, never the window).
void Cocoa_gpApply(Dart_NativeArguments args) {
  GpEngine* eng = GpEngine::instance();
  if (!eng->is_open()) {
    Dart_SetReturnValue(args,
        Dart_NewStringFromCString("gamepane: not open"));
    return;
  }
  Dart_Handle cmds = Dart_GetNativeArgument(args, 0);
  intptr_t n = 0;
  if (!Dart_IsList(cmds) || Dart_IsError(Dart_ListLength(cmds, &n))) {
    Dart_SetReturnValue(args,
        Dart_NewStringFromCString("gamepane: apply needs a list"));
    return;
  }

  std::string first_err;
  @autoreleasepool {
    eng->begin_frame();
    GpIndexedPane* pane = eng->pane();
    GpSprites* sprites = eng->sprites();

    for (intptr_t ci = 0; ci < n; ci++) {
      Dart_Handle c = Dart_ListGetAt(cmds, ci);
      intptr_t cn = 0;
      if (!Dart_IsList(c) || Dart_IsError(Dart_ListLength(c, &cn)) || cn < 1) {
        continue;
      }
      const char* op = ElStr(c, 0);
      if (op == NULL) continue;
      std::string verr;

      // Direct-framebuffer mode (§6b) has no retained panes: the game writes
      // pixels itself. Only its own verbs apply here; anything pane/sprite/
      // shader-shaped is skipped so a stray one cannot deref a NULL pane.
      if (eng->is_direct()) {
        if (strcmp(op, "gpdpal") == 0 && cn >= 5) {
          int64_t i = ElInt(c, 1);
          if (i < 0 || i > 255) verr = "gpdpal: index 0..255";
          else eng->direct_pane()->set_pal((int)i, ClampByte(ElInt(c, 2)),
                   ClampByte(ElInt(c, 3)), ClampByte(ElInt(c, 4)));
        } else if (strcmp(op, "gptextclear") == 0) {
          eng->text()->clear();
        } else if (strcmp(op, "gptext") == 0 && cn >= 7) {
          const char* s = ElStr(c, 3);
          if (s != NULL) eng->text()->draw_text(ElInt(c, 1), ElInt(c, 2), s,
              ClampByte(ElInt(c, 4)), ClampByte(ElInt(c, 5)), ClampByte(ElInt(c, 6)),
              cn > 7 ? (int)ElInt(c, 7) : 1);      // optional pixel scale
        } else if (strcmp(op, "gpfull") == 0 && cn >= 2) {
          eng->set_fullscreen(ElInt(c, 1) != 0);
        } else if (strcmp(op, "gpsound") != 0 && strcmp(op, "gpeffect") != 0 &&
                   strcmp(op, "gpplay") != 0 &&
                   strcmp(op, "gptune") != 0 && strcmp(op, "gpmusic") != 0 &&
                   strcmp(op, "gpopen") != 0) {
          // silently ignore retained verbs; audio verbs fall through below
        }
        if (strcmp(op, "gpsound") != 0 && strcmp(op, "gpeffect") != 0 &&
            strcmp(op, "gpplay") != 0 &&
            strcmp(op, "gptune") != 0 && strcmp(op, "gpmusic") != 0) {
          if (!verr.empty() && first_err.empty()) first_err = verr;
          continue;                            // audio verbs share the code below
        }
      }

      if (strcmp(op, "gppal") == 0 && cn >= 5) {
        int64_t i = ElInt(c, 1);
        if (i < 16 || i > 255) verr = "gppal: index must be 16..255";
        else pane->set_rgb((uint8_t)i, ClampByte(ElInt(c, 2)),
                           ClampByte(ElInt(c, 3)), ClampByte(ElInt(c, 4)));
      } else if (strcmp(op, "gplinepal") == 0 && cn >= 6) {
        int64_t line = ElInt(c, 1), i = ElInt(c, 2);
        if (i < 1 || i > 15) verr = "gplinepal: index must be 1..15";
        else if (line < 0 || line >= pane->viewport_h()) {
          verr = "gplinepal: line out of range";
        } else {
          pane->set_line_rgb((int)line, (uint8_t)i, ClampByte(ElInt(c, 3)),
                             ClampByte(ElInt(c, 4)), ClampByte(ElInt(c, 5)));
        }
      } else if (strcmp(op, "gpsprite") == 0 && cn >= 3) {
        int64_t want = ElInt(c, 1);
        const char* rows = ElStr(c, 2);
        int got = rows ? sprites->define(rows) : -1;
        if (got < 0) verr = "gpsprite: bad art rows";
        else if (got != want) verr = "gpsprite: id out of sequence";
      } else if (strcmp(op, "gpframe") == 0 && cn >= 3) {
        const char* rows = ElStr(c, 2);
        if (rows == NULL || !sprites->add_frame((int)ElInt(c, 1), rows)) {
          verr = "gpframe: bad def or mismatched art";
        }
      } else if (strcmp(op, "gpspritepal") == 0 && cn >= 6) {
        sprites->set_rgb((int)ElInt(c, 1), (int)ElInt(c, 2),
                         ClampByte(ElInt(c, 3)), ClampByte(ElInt(c, 4)),
                         ClampByte(ElInt(c, 5)));
      } else if (strcmp(op, "gpspawn") == 0 && cn >= 5) {
        int64_t want = ElInt(c, 1);
        int got = sprites->place((int)ElInt(c, 2), ElDouble(c, 3),
                                 ElDouble(c, 4));
        if (got < 0) verr = "gpspawn: bad def id";
        else if (got != want) verr = "gpspawn: id out of sequence";
      } else if (strcmp(op, "gpplace") == 0 && cn >= 8) {
        GpSpriteInstance* inst = sprites->instance((int)ElInt(c, 1));
        if (inst == NULL) verr = "gpplace: bad instance";
        else {
          inst->x = ElDouble(c, 2);
          inst->y = ElDouble(c, 3);
          inst->frame = (int)ElInt(c, 4);
          if (inst->frame < 0) inst->frame = 0;
          inst->scale = ElDouble(c, 5);
          inst->rot_deg = ElDouble(c, 6);
          double a = ElDouble(c, 7);
          inst->alpha = a < 0.0 ? 0.0 : (a > 1.0 ? 1.0 : a);
          inst->visible = true;
        }
      } else if (strcmp(op, "gphide") == 0 && cn >= 2) {
        GpSpriteInstance* inst = sprites->instance((int)ElInt(c, 1));
        if (inst != NULL) inst->visible = false;
      } else if (strcmp(op, "gpanim") == 0 && cn >= 3) {
        GpSpriteInstance* inst = sprites->instance((int)ElInt(c, 1));
        if (inst != NULL) inst->fps = ElDouble(c, 2);
      } else if (strcmp(op, "gpscroll") == 0 && cn >= 3) {
        pane->set_scroll(ElInt(c, 1), ElInt(c, 2));
      } else if (strcmp(op, "gpactive") == 0 && cn >= 2) {
        int64_t slot = ElInt(c, 1);
        if (slot < 0 || slot >= kNumBuffers) verr = "gpactive: slot 0..7";
        else pane->set_active((int)slot);
      } else if (strcmp(op, "gpswap") == 0) {
        pane->swap_buffers();
      } else if (strcmp(op, "gpcls") == 0 && cn >= 2) {
        pane->cls(ClampByte(ElInt(c, 1)));
      } else if (strcmp(op, "gppset") == 0 && cn >= 4) {
        pane->pset(ElInt(c, 1), ElInt(c, 2), ClampByte(ElInt(c, 3)));
      } else if (strcmp(op, "gpline") == 0 && cn >= 6) {
        pane->line(ElInt(c, 1), ElInt(c, 2), ElInt(c, 3), ElInt(c, 4),
                   ClampByte(ElInt(c, 5)));
      } else if (strcmp(op, "gpfill") == 0 && cn >= 6) {
        pane->fill_rect(ElInt(c, 1), ElInt(c, 2), ElInt(c, 3), ElInt(c, 4),
                        ClampByte(ElInt(c, 5)));
      } else if (strcmp(op, "gpcircle") == 0 && cn >= 5) {
        pane->circle(ElInt(c, 1), ElInt(c, 2), ElInt(c, 3),
                     ClampByte(ElInt(c, 4)));
      } else if (strcmp(op, "gpdisc") == 0 && cn >= 5) {
        pane->disc(ElInt(c, 1), ElInt(c, 2), ElInt(c, 3),
                   ClampByte(ElInt(c, 4)));
      } else if (strcmp(op, "gpload") == 0 && cn >= 3) {
        int64_t slot = ElInt(c, 1);
        const char* b64 = ElStr(c, 2);
        std::vector<uint8_t> bytes;
        if (slot < 0 || slot >= kNumBuffers) verr = "gpload: slot 0..7";
        else if (b64 == NULL || !DecodeB64(b64, &bytes)) {
          verr = "gpload: bad base64";
        } else {
          int prev = pane->active();
          pane->set_active((int)slot);
          pane->load(bytes.data(), bytes.size());
          pane->set_active(prev);
        }
      } else if (strcmp(op, "gpblit") == 0 && cn >= 10) {
        // ['gpblit', mode, src, dst, sx, sy, dx, dy, w, h, value?]
        int64_t mode = ElInt(c, 1);
        int64_t src = ElInt(c, 2), dst = ElInt(c, 3);
        if (mode < 0 || mode > 5) verr = "gpblit: mode 0..5";
        else if (src < 0 || src >= kNumBuffers ||
                 dst < 0 || dst >= kNumBuffers) {
          verr = "gpblit: slot 0..7";
        } else {
          eng->blitter()->blit(pane, eng->frame_cb(), (int)mode,
                               (int)src, (int)dst,
                               ElInt(c, 4), ElInt(c, 5),
                               ElInt(c, 6), ElInt(c, 7),
                               ElInt(c, 8), ElInt(c, 9),
                               cn > 10 ? ClampByte(ElInt(c, 10)) : 0);
        }
      } else if (strcmp(op, "gptextclear") == 0) {
        eng->text()->clear();
      } else if (strcmp(op, "gptext") == 0 && cn >= 7) {
        const char* s = ElStr(c, 3);
        if (s != NULL) {
          eng->text()->draw_text(ElInt(c, 1), ElInt(c, 2), s,
                                 ClampByte(ElInt(c, 4)),
                                 ClampByte(ElInt(c, 5)),
                                 ClampByte(ElInt(c, 6)),
                                 cn > 7 ? (int)ElInt(c, 7) : 1);   // pixel scale
        }
      } else if (strcmp(op, "gpshader") == 0 && cn >= 2) {
        const char* body = ElStr(c, 1);
        if (body == NULL) verr = "gpshader: body must be a string";
        else verr = eng->shader()->compile(body);
      } else if (strcmp(op, "gpparam") == 0 && cn >= 3) {
        eng->shader()->set_param((int)ElInt(c, 1), (float)ElDouble(c, 2));
      } else if (strcmp(op, "gpsound") == 0 && cn >= 3) {
        int64_t slot = ElInt(c, 1);
        const char* preset = ElStr(c, 2);
        if (slot < 0 || slot >= kMaxSfxSlots) verr = "gpsound: slot 0..63";
        else if (preset == NULL) verr = "gpsound: preset name needed";
        else {
          // Deterministic across a session. Static-local, but single-threaded
          // by construction: gpApply only ever runs on the UI isolate's
          // mutator (the pane's whole contract), so no lock.
          static Lcg rng(12345);
          double a1 = cn > 3 ? ElDouble(c, 3) : 0.0;
          double a2 = cn > 4 ? ElDouble(c, 4) : 0.0;
          Sound snd;
          if (strcmp(preset, "beep") == 0) {
            snd = preset_beep(a1 > 0 ? a1 : 440.0, a2 > 0 ? a2 : 0.15);
          } else if (strcmp(preset, "coin") == 0) {
            snd = preset_coin(a1 > 0 ? a1 : 0.3);
          } else if (strcmp(preset, "jump") == 0) {
            snd = preset_jump(a1 > 0 ? a1 : 0.2);
          } else if (strcmp(preset, "zap") == 0) {
            snd = preset_zap(a1 > 0 ? a1 : 0.2, rng);
          } else if (strcmp(preset, "shoot") == 0) {
            snd = preset_shoot(a1 > 0 ? a1 : 0.15, rng);
          } else if (strcmp(preset, "explode") == 0) {
            snd = preset_explode(a1 > 0 ? a1 : 1.0, a2 > 0 ? a2 : 0.5, rng);
          } else if (strcmp(preset, "wah") == 0) {
            // a1 = base Hz (280 = the saucer), a2 = detune Hz = the wah rate
            snd = preset_wah(a1 > 0 ? a1 : 280.0, a2 > 0 ? a2 : 5.0, 0.9);
          } else if (strcmp(preset, "hum") == 0) {
            // The capture boss's tractor hum: the same beating trick an octave
            // and a half down, slower — the original's AudioBoot bakes it as
            // Wah(110, 4).
            snd = preset_wah(a1 > 0 ? a1 : 110.0, a2 > 0 ? a2 : 4.0, 1.1);
          } else if (strcmp(preset, "powerup") == 0) {
            snd = preset_powerup(a1 > 0 ? a1 : 0.4);
          } else if (strcmp(preset, "hurt") == 0) {
            snd = preset_hurt(a1 > 0 ? a1 : 0.25, rng);
          } else if (strcmp(preset, "click") == 0) {
            snd = preset_click(a1 > 0 ? a1 : 0.05, rng);
          } else if (strcmp(preset, "bang") == 0) {
            snd = preset_bang(a1 > 0 ? a1 : 0.3, rng);
          } else if (strcmp(preset, "blip") == 0) {
            snd = preset_blip(a1 > 0 ? a1 : 1.0, a2 > 0 ? a2 : 0.08);
          } else if (strcmp(preset, "tone") == 0) {
            int64_t wf = cn > 5 ? ElInt(c, 5) : 0;
            if (wf < 0 || wf > 5) wf = 0;
            snd = preset_tone(a1 > 0 ? a1 : 440.0, a2 > 0 ? a2 : 0.2,
                              (Waveform)wf);
          } else if (strcmp(preset, "noise") == 0) {
            snd = noise_burst((int)a1, a2 > 0 ? a2 : 0.3, rng);
          } else {
            verr = std::string("gpsound: unknown preset ") + preset;
          }
          if (verr.empty()) eng->sfx()->define((int)slot, snd);
        }
      } else if (strcmp(op, "gpeffect") == 0 && cn >= 16) {
        // The FULL synth recipe over the wire — the parameter space the
        // eleven gpsound presets are hand-tuned points in, opened up for the
        // sound editor (SOUND_EDITOR_PLAN.md, which pins this exact order):
        //   ['gpeffect', slot, duration, a, d, s, r, sweepStart, sweepEnd,
        //    noiseMix, distortion, echoCount, echoDelay, echoDecay, seed,
        //    oscCount, (wave, freq, amp, phase, pulseWidth) * oscCount]
        // The seed crosses too, so a recipe with noise in it renders the
        // SAME sound every time — a saved effect is reproducible source.
        int64_t slot = ElInt(c, 1);
        if (slot < 0 || slot >= kMaxSfxSlots) {
          verr = "gpeffect: slot 0..63";
        } else {
          double dur = ElDouble(c, 2);
          if (dur <= 0.0) dur = 0.2;
          if (dur > 4.0) dur = 4.0;            // echo tail fits kMaxSamples
          Effect e(dur);
          e.set_env(ElDouble(c, 3), ElDouble(c, 4), ElDouble(c, 5),
                    ElDouble(c, 6));
          e.sweep_start = ElDouble(c, 7);
          e.sweep_end = ElDouble(c, 8);
          e.noise_mix = ElDouble(c, 9);
          e.distortion = ElDouble(c, 10);
          int64_t taps = ElInt(c, 11);
          e.echo_count = (uint32_t)(taps < 0 ? 0 : (taps > 8 ? 8 : taps));
          e.echo_delay = ElDouble(c, 12);
          e.echo_decay = ElDouble(c, 13);
          int64_t osc_n = ElInt(c, 15);
          if (osc_n < 0) osc_n = 0;
          if (osc_n > 4) osc_n = 4;            // add_osc caps there anyway
          for (int64_t i = 0; i < osc_n; i++) {
            intptr_t base = 16 + (intptr_t)i * 5;
            if (base + 4 >= cn) break;         // short list: keep what parsed
            int64_t wf = ElInt(c, base);
            if (wf < 0 || wf > 5) wf = 0;
            e.add_osc((Waveform)wf, ElDouble(c, base + 1),
                      ElDouble(c, base + 2));
            e.oscillators.back().phase = ElDouble(c, base + 3);
            e.oscillators.back().pulse_width = ElDouble(c, base + 4);
          }
          Lcg rng((uint32_t)ElInt(c, 14));
          Sound snd = render(e, rng);
          if (snd.samples.empty()) verr = "gpeffect: rendered no samples";
          else eng->sfx()->define((int)slot, snd);
        }
      } else if (strcmp(op, "gpplay") == 0 && cn >= 2) {
        eng->sfx()->play((int)ElInt(c, 1));
      } else if (strcmp(op, "gptune") == 0 && cn >= 4) {
        // ['gptune', slot, bpm, [timeMs, status, d1, d2, ...]]
        int64_t slot = ElInt(c, 1);
        Dart_Handle flat = Dart_ListGetAt(c, 3);
        intptr_t fn = 0;
        if (slot < 0 || slot >= kMaxTunes) verr = "gptune: slot 0..7";
        else if (!Dart_IsList(flat) ||
                 Dart_IsError(Dart_ListLength(flat, &fn)) || fn < 4) {
          verr = "gptune: events must be a flat int list";
        } else {
          std::vector<int32_t> events;
          events.reserve((size_t)fn);
          for (intptr_t k = 0; k < fn; k++) {
            events.push_back((int32_t)ElInt(flat, k));
          }
          if (!eng->music()->define((int)slot, (int)ElInt(c, 2), events)) {
            verr = "gptune: define failed";
          }
        }
      } else if (strcmp(op, "gpmusic") == 0 && cn >= 3) {
        // mode: 0 stop, 1 play once, 2 loop
        eng->music()->control((int)ElInt(c, 1), (int)ElInt(c, 2));
      } else if (strcmp(op, "gpfull") == 0 && cn >= 2) {
        eng->set_fullscreen(ElInt(c, 1) != 0);
      } else if (strcmp(op, "gpopen") == 0) {
        // Consumed Dart-side before apply; seeing it here is harmless.
      } else {
        verr = std::string("gamepane: unknown verb ") + op;
      }

      if (!verr.empty() && first_err.empty()) first_err = verr;
    }

    eng->render_present();
  }

  if (first_err.empty()) {
    Dart_SetReturnValue(args, Dart_Null());
  } else {
    Dart_SetReturnValue(args, Dart_NewStringFromCString(first_err.c_str()));
  }
}

// _gpSnap(path) -> "" on success, else the error
void Cocoa_gpSnap(Dart_NativeArguments args) {
  const char* path = NULL;
  Dart_StringToCString(Dart_GetNativeArgument(args, 0), &path);
  std::string err;
  @autoreleasepool {
    if (path == NULL || !GpEngine::instance()->snap(path, &err)) {
      Dart_SetReturnValue(args, Dart_NewStringFromCString(
          err.empty() ? "gamepane: snap failed" : err.c_str()));
      return;
    }
  }
  Dart_SetReturnValue(args, Dart_NewStringFromCString(""));
}

// _gpStat() -> [open, framesPresented, logicalW, logicalH, fullscreen,
//               direct, stride]  (stride = the direct framebuffer's bytesPerRow)
void Cocoa_gpStat(Dart_NativeArguments args) {
  GpEngine* eng = GpEngine::instance();
  int stride = (eng->is_direct() && eng->direct_pane() != NULL)
                   ? eng->direct_pane()->stride() : 0;
  Dart_Handle l = Dart_NewList(7);
  Dart_ListSetAt(l, 0, Dart_NewInteger(eng->is_open() ? 1 : 0));
  Dart_ListSetAt(l, 1, Dart_NewInteger(eng->frames_presented()));
  Dart_ListSetAt(l, 2, Dart_NewInteger(eng->logical_w()));
  Dart_ListSetAt(l, 3, Dart_NewInteger(eng->logical_h()));
  Dart_ListSetAt(l, 4, Dart_NewInteger(eng->fullscreen() ? 1 : 0));
  Dart_ListSetAt(l, 5, Dart_NewInteger(eng->is_direct() ? 1 : 0));
  Dart_ListSetAt(l, 6, Dart_NewInteger(stride));
  Dart_SetReturnValue(args, l);
}

// _gpBackbuffer() -> a Uint8List backed by the current direct write buffer's
// GPU memory (external typed data — no copy, no finalizer; thread 0 owns it),
// or null when not in direct mode. Each caller/isolate gets its own view of
// the same buffer (§6b). Length is stride*h; address as fb[y*stride + x].
void Cocoa_gpBackbuffer(Dart_NativeArguments args) {
  GpEngine* eng = GpEngine::instance();
  if (!eng->is_open() || !eng->is_direct() || eng->direct_pane() == NULL) {
    Dart_SetReturnValue(args, Dart_Null());
    return;
  }
  void* p = eng->direct_pane()->backbuffer_ptr();
  intptr_t len = (intptr_t)eng->direct_pane()->buffer_size();
  if (p == NULL || len <= 0) { Dart_SetReturnValue(args, Dart_Null()); return; }
  Dart_SetReturnValue(args,
      Dart_NewExternalTypedData(Dart_TypedData_kUint8, p, len));
}

// _gpFullscreen(on) — the workspace-side handle on the same switch the
// 'gpfull' verb flips (the Full button, and Esc bringing the screen back).
void Cocoa_gpFullscreen(Dart_NativeArguments args) {
  int64_t on = 0;
  Dart_IntegerToInt64(Dart_GetNativeArgument(args, 0), &on);
  GpEngine::instance()->set_fullscreen(on != 0);
  Dart_SetReturnValue(args, Dart_Null());
}

}  // namespace bin
}  // namespace dart
