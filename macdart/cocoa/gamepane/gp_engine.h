// MACDART game pane — the layered Metal engine (ObjC++, thread 0 only).
//
// A C++ port of MacGamePane's graphics crate (indexed_pane / sprites /
// blitter / text_overlay / shader_pane), composited per frame in the fixed
// order: shader background → indexed framebuffer → sprites → text overlay.
// Owned exclusively by the UI isolate: every method here is reached from a
// dart:cocoa native, so it runs on thread 0 by construction — no locks, no
// cross-thread Metal (GAMEPANE_PLAN.md §1).
//
// Frames render into a persistent OFFSCREEN BGRA texture, then copy to the
// CAMetalLayer drawable. Two reasons: gpsnap reads honest pixels back from
// the offscreen at any time (a window snapshot cannot see a CAMetalLayer),
// and a nil drawable skips presentation without losing the frame.
#ifndef MACDART_GAMEPANE_GP_ENGINE_H_
#define MACDART_GAMEPANE_GP_ENGINE_H_

#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include <stdint.h>
#include <string>
#include <vector>

#include "gp_synth.h"

namespace macdart_gamepane {

const int kNumBuffers = 8;         // FRONT=0, BACK=1, 2..7 asset slots
const int kFront = 0;
const int kBack = 1;
const int kMaxSfxSlots = 64;

// --- layer 1: the 8-bit indexed framebuffer ---------------------------------
// World-sized buffers (>= viewport), panned by a scroll offset the fragment
// shader applies. Palette: index 0 transparent (discard), 1-15 per-SCREEN-
// scanline (the copper behaviour — raster-locked, does not scroll), 16-255
// global. One flat float4 palette buffer: viewport_h*16 entries then 240.
class GpIndexedPane {
 public:
  GpIndexedPane(id<MTLDevice> device, int world_w, int world_h,
                int viewport_w, int viewport_h, std::string* err);
  ~GpIndexedPane();

  void set_active(int slot);       // callers validate slot 0..7
  void swap_buffers();
  void set_scroll(int64_t x, int64_t y);
  void set_rgb(uint8_t index, uint8_t r, uint8_t g, uint8_t b);        // 16..255
  void set_line_rgb(int line, uint8_t index, uint8_t r, uint8_t g, uint8_t b);
  void load_default_palette();
  void cls(uint8_t index);
  void pset(int64_t x, int64_t y, uint8_t index);
  uint8_t pget(int64_t x, int64_t y);
  void load(const uint8_t* data, size_t len);   // bulk into active slot
  void fill_rect(int64_t x, int64_t y, int64_t w, int64_t h, uint8_t index);
  void line(int64_t x0, int64_t y0, int64_t x1, int64_t y1, uint8_t index);
  void circle(int64_t cx, int64_t cy, int64_t r, uint8_t index);
  void disc(int64_t cx, int64_t cy, int64_t r, uint8_t index);
  void upload();                   // dirty slots + palette -> GPU
  void render(id<MTLCommandBuffer> cb, id<MTLTexture> target,
              MTLLoadAction load_action);

  int world_w() const { return world_w_; }
  int world_h() const { return world_h_; }
  int viewport_w() const { return viewport_w_; }
  int viewport_h() const { return viewport_h_; }
  int64_t scroll_x() const { return scroll_x_; }
  int64_t scroll_y() const { return scroll_y_; }
  int active() const { return active_; }
  std::vector<uint8_t>& buffer(int slot) { return buffers_[slot]; }
  id<MTLTexture> texture(int slot) { return textures_[slot]; }
  bool dirty(int slot) const { return dirty_[slot]; }
  void set_dirty(int slot, bool d) { dirty_[slot] = d; }

 private:
  int world_w_, world_h_, viewport_w_, viewport_h_;
  int active_;
  int64_t scroll_x_, scroll_y_;
  std::vector<uint8_t> buffers_[kNumBuffers];
  id<MTLTexture> textures_[kNumBuffers];
  bool dirty_[kNumBuffers];
  std::vector<float> palette_;     // float4 per entry
  id<MTLBuffer> palette_buf_;
  bool palette_dirty_;
  id<MTLRenderPipelineState> pipeline_;
};

// --- layer 2: sprites --------------------------------------------------------
// 16-colour hex-row art, one R8Uint texture per FRAME (uploaded once at
// definition), a 16-float4 palette per definition, per-instance transform
// applied CPU-side into a 4-vertex strip. x,y is the world-space CENTRE.
struct GpSpriteDef {
  int w, h;
  std::vector<id<MTLTexture> > frames;
  float palette[16][4];
  id<MTLBuffer> palette_buf;
  bool palette_dirty;
};

struct GpSpriteInstance {
  int def;
  double x, y, scale, rot_deg, alpha;
  int frame;
  bool visible;
  double fps, accum;
};

class GpSprites {
 public:
  GpSprites(id<MTLDevice> device, std::string* err);
  ~GpSprites();

  int define(const char* rows);              // -> def id, or -1 (bad art)
  bool add_frame(int def, const char* rows);
  void set_rgb(int def, int index, uint8_t r, uint8_t g, uint8_t b);
  int place(int def, double x, double y);    // -> instance id, or -1
  GpSpriteInstance* instance(int id);        // NULL when out of range
  bool hit(int a, int b);                    // AABB, rotation ignored
  void tick(double dt);                      // catch-up frame animation
  void render(id<MTLCommandBuffer> cb, id<MTLTexture> target,
              double scroll_x, double scroll_y, double vw, double vh);

 private:
  id<MTLDevice> device_;
  id<MTLRenderPipelineState> pipeline_;
  std::vector<GpSpriteDef> defs_;
  std::vector<GpSpriteInstance> instances_;
};

// --- the GPU compute blitter -------------------------------------------------
// Slot-to-slot rectangle ops. Each op first flushes dirty CPU mirrors of the
// slots involved, encodes the kernel, then applies the SAME op to the CPU
// mirror — so mirror == GPU afterwards and pget stays truthful. (The Rust
// original could silently diverge here; GAMEPANE_PLAN.md §5 records the fix.)
// Rects are clipped CPU-side; the Rust panicked on out-of-range.
class GpBlitter {
 public:
  GpBlitter(id<MTLDevice> device, std::string* err);
  ~GpBlitter();
  // mode: 0 copy, 1 transparent, 2 and, 3 or, 4 xor, 5 clear(value)
  void blit(GpIndexedPane* pane, id<MTLCommandBuffer> cb, int mode,
            int src, int dst, int64_t sx, int64_t sy,
            int64_t dx, int64_t dy, int64_t w, int64_t h, uint8_t value);

 private:
  id<MTLComputePipelineState> copy_, transparent_, minterm_, clear_;
};

// --- layer 3: the text overlay ----------------------------------------------
// A viewport-sized RGBA8 CPU buffer carrying the full printable ASCII range
// (0x20..0x7E) from a baked 5x7 pixel atlas, uploaded when dirty, sampled over
// everything. Six pixels of advance per glyph, eight per line; `\n` starts a
// new line at the string's own left edge, and `scale` blocks each atlas pixel
// for HUD-to-title-screen sizes off one font.
class GpTextOverlay {
 public:
  GpTextOverlay(id<MTLDevice> device, int w, int h, std::string* err);
  ~GpTextOverlay();
  void clear();
  void draw_text(int64_t x, int64_t y, const char* text,
                 uint8_t r, uint8_t g, uint8_t b, int scale = 1);
  void upload();
  void render(id<MTLCommandBuffer> cb, id<MTLTexture> target);

 private:
  void set_px(int64_t x, int64_t y, uint8_t r, uint8_t g, uint8_t b);
  void fill_px(int64_t x, int64_t y, int64_t w, int64_t h,
               uint8_t r, uint8_t g, uint8_t b);
  void draw_glyph(int64_t x, int64_t y, unsigned char c,
                  uint8_t r, uint8_t g, uint8_t b, int s);
  int w_, h_;
  std::vector<uint8_t> rgba_;
  bool dirty_;
  id<MTLTexture> texture_;
  id<MTLRenderPipelineState> pipeline_;
};

// --- layer 0: the shader background -----------------------------------------
// A fullscreen fragment shader compiled AT RUNTIME from the game's MSL body
// (just fmain; the header supplies Uniforms{time, aspect, p[8]} and the
// big-triangle vertex fn). A bad shader returns its compile error as a
// string — logged, never an abort.
class GpShaderPane {
 public:
  GpShaderPane(id<MTLDevice> device);
  ~GpShaderPane();
  std::string compile(const char* frag_msl);   // "" on success, else error
  bool ready() const { return pipeline_ != nil; }
  void set_param(int i, float v);
  void set_aspect(float a) { aspect_ = a; }
  void render(id<MTLCommandBuffer> cb, id<MTLTexture> target);

 private:
  id<MTLDevice> device_;
  id<MTLRenderPipelineState> pipeline_;
  double start_time_;
  float params_[8];
  float aspect_;
};

// --- music: compiled tunes through the built-in GM synth ---------------------
// The game isolate compiles ABC to a flat event list (demos/abc.dart); here
// it becomes an in-memory Standard MIDI File wrapped by an AVMIDIPlayer per
// slot. Looping is a per-frame poll (render_present), not a completion block
// — main-thread, MRC-safe, no block gymnastics.
const int kMaxTunes = 8;

class GpMusic {
 public:
  GpMusic();
  ~GpMusic();
  // events: [timeMs, status, d1, d2]*n — status carries the channel already.
  bool define(int slot, int bpm, const std::vector<int32_t>& events);
  void control(int slot, int mode);  // 0 stop, 1 play once, 2 loop
  void poll();                       // restart looping slots that finished
  void stop_all();

 private:
  id players_[kMaxTunes];            // AVMIDIPlayer, typed in the .mm
  bool looping_[kMaxTunes];
};

// --- SFX playback ------------------------------------------------------------
// ONE AVAudioEngine per process (two concurrent starts abort uncatchably —
// the engine's own documented hazard), created lazily on first use. 64 fixed
// slots; define converts the synth's f64 interleaved to f32 deinterleaved.
class GpSfx {
 public:
  GpSfx();
  ~GpSfx();
  bool start();
  void define(int slot, const Sound& sound);
  void play(int slot);

 private:
  id engine_, player_, format_;    // AVFoundation classes, typed in the .mm
  id buffers_[kMaxSfxSlots];
  bool started_;
};

// --- the direct framebuffer (GAMEPANE_PLAN.md §6b) --------------------------
// A raw-speed escape hatch: N shared MTLBuffers of palette indices, each with a
// linear R8Uint texture VIEW over it, sampled by a 256-colour palette shader.
// The game writes indices straight into a buffer (exposed to Dart as external
// typed data — GPU memory, zero copy), then the pull tick presents it. Triple-
// buffered so the CPU never writes a buffer the GPU is still reading.
class GpDirectPane {
 public:
  GpDirectPane(id<MTLDevice> device, int w, int h, std::string* err);
  ~GpDirectPane();
  void* backbuffer_ptr();               // contents() of the current write buffer
  size_t buffer_size() const { return (size_t)stride_ * h_; }
  int stride() const { return stride_; }   // bytesPerRow (>= w, alignment-padded)
  int w() const { return w_; }
  int h() const { return h_; }
  void set_pal(int i, uint8_t r, uint8_t g, uint8_t b);
  // Render the buffer the game just wrote, then advance the write index.
  void present_render(id<MTLCommandBuffer> cb, id<MTLTexture> target);

 private:
  static const int kBuffers = 3;
  int w_, h_, stride_;
  id<MTLBuffer> buffers_[kBuffers];
  id<MTLTexture> textures_[kBuffers];
  volatile int write_;                  // rotated on thread 0; read by writers
  std::vector<float> pal_;              // 256 * float4
  id<MTLBuffer> pal_buf_;
  bool pal_dirty_;
  id<MTLRenderPipelineState> pipeline_;
};

// --- the engine --------------------------------------------------------------
// One per process, owned by the UI isolate. open() (re)builds the panes at a
// logical resolution and returns the NSView to embed; apply-time helpers are
// called by gp_natives.mm walking a frame's command list; render_present()
// composites the four layers into the offscreen and copies to the drawable.
class GpEngine {
 public:
  static GpEngine* instance();     // created on first use; never destroyed

  // direct: build the raw-framebuffer pane (§6b) instead of the retained
  // sprite/indexed stack. Both share the view, offscreen, present, and gpsnap.
  NSView* open(int w, int h, int world_w, int world_h, bool direct,
               std::string* err);
  void close();                    // free panes; keep device/queue/view
  bool is_open() const { return open_; }
  bool is_direct() const { return direct_; }

  GpIndexedPane* pane() { return pane_; }
  GpSprites* sprites() { return sprites_; }
  GpBlitter* blitter() { return blitter_; }
  GpTextOverlay* text() { return text_; }
  GpShaderPane* shader() { return shader_; }
  GpDirectPane* direct_pane() { return direct_pane_; }
  GpSfx* sfx();                    // lazily started
  GpMusic* music();                // lazily created

  // Fullscreen: the pane view takes the whole screen (logical resolution
  // unchanged — the layer upscales, nearest). Exit restores it to the tab.
  void set_fullscreen(bool on);
  bool fullscreen() const { return fullscreen_; }

  // Frame flow: begin() opens the command buffer (blit verbs encode into
  // it mid-apply), render_present() composites + presents + commits.
  void begin_frame();
  id<MTLCommandBuffer> frame_cb() { return frame_cb_; }
  void render_present();
  bool snap(const char* path, std::string* err);   // offscreen -> PNG

  int frames_presented() const { return frames_; }
  int logical_w() const { return logical_w_; }
  int logical_h() const { return logical_h_; }

 private:
  GpEngine();
  bool ensure_device(std::string* err);

  id<MTLDevice> device_;
  id<MTLCommandQueue> queue_;
  NSView* view_;
  CAMetalLayer* layer_;
  id<MTLTexture> offscreen_;
  id<MTLCommandBuffer> frame_cb_;
  GpIndexedPane* pane_;
  GpSprites* sprites_;
  GpBlitter* blitter_;
  GpTextOverlay* text_;
  GpShaderPane* shader_;
  GpDirectPane* direct_pane_;
  GpSfx* sfx_;
  GpMusic* music_;
  bool fullscreen_;
  bool direct_;
  bool open_;
  int logical_w_, logical_h_;
  int frames_;
  double last_tick_time_;
};

}  // namespace macdart_gamepane

#endif  // MACDART_GAMEPANE_GP_ENGINE_H_
