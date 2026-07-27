// MACDART game pane — engine implementation. MRC (no ARC): the VM owns the
// ObjC refcount discipline, same as the rest of the bridge. Every MSL string
// below is carried verbatim from MacGamePane's Rust (the distilled, tested
// statement of this engine — see GAMEPANE_PLAN.md §5).
#include "gp_engine.h"

#import <AVFoundation/AVFoundation.h>

#include <math.h>
#include <string.h>

namespace macdart_gamepane {

// --- MSL, verbatim from the Rust engine -------------------------------------

// indexed_pane.rs:28-58
static const char* kIndexedMsl =
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct VOut { float4 pos [[position]]; float2 uv; };\n"
    "struct Uniforms { float scroll_x; float scroll_y; float viewport_w; float viewport_h; };\n"
    "vertex VOut vmain(uint vid [[vertex_id]]) {\n"
    "    float2 positions[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };\n"
    "    VOut out;\n"
    "    float2 pos = positions[vid];\n"
    "    out.pos = float4(pos, 0.0, 1.0);\n"
    "    out.uv = float2((pos.x + 1.0) * 0.5, 1.0 - (pos.y + 1.0) * 0.5);\n"
    "    return out;\n"
    "}\n"
    "fragment float4 fmain(VOut in [[stage_in]],\n"
    "                       constant Uniforms& u [[buffer(0)]],\n"
    "                       texture2d<uint> indexTex [[texture(0)]],\n"
    "                       constant float4* palette [[buffer(1)]]) {\n"
    "    uint screenX = uint(in.uv.x * u.viewport_w);\n"
    "    uint screenY = uint(in.uv.y * u.viewport_h);\n"
    "    uint worldX = uint(int(screenX) + int(u.scroll_x));\n"
    "    uint worldY = uint(int(screenY) + int(u.scroll_y));\n"
    "    uint ci = indexTex.read(uint2(worldX, worldY)).r;\n"
    "    if (ci == 0u) { discard_fragment(); }\n"
    "    uint k;\n"
    "    if (ci < 16u) { k = screenY * 16u + ci; } else { k = uint(u.viewport_h) * 16u + (ci - 16u); }\n"
    "    return palette[k];\n"
    "}\n";

// sprites.rs:20-47
static const char* kSpriteMsl =
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct VIn { float2 pos; float2 uv; };\n"
    "struct VOut { float4 pos [[position]]; float2 uv; };\n"
    "struct Uniforms { float alpha; };\n"
    "vertex VOut vmain(constant VIn* verts [[buffer(0)]], uint vid [[vertex_id]]) {\n"
    "    VOut out;\n"
    "    out.pos = float4(verts[vid].pos, 0.0, 1.0);\n"
    "    out.uv = verts[vid].uv;\n"
    "    return out;\n"
    "}\n"
    "fragment float4 fmain(VOut in [[stage_in]],\n"
    "                       constant Uniforms& u [[buffer(0)]],\n"
    "                       texture2d<uint> indexTex [[texture(0)]],\n"
    "                       constant float4* palette [[buffer(1)]]) {\n"
    "    uint2 size = uint2(indexTex.get_width(), indexTex.get_height());\n"
    "    uint2 texel = uint2(in.uv.x * float(size.x), in.uv.y * float(size.y));\n"
    "    uint ci = indexTex.read(texel).r;\n"
    "    if (ci == 0u) { discard_fragment(); }\n"
    "    float4 c = palette[ci];\n"
    "    c.a *= u.alpha;\n"
    "    return c;\n"
    "}\n";

// blitter.rs:21-70
static const char* kBlitterMsl =
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct BlitParams {\n"
    "    uint src_x, src_y, dst_x, dst_y, w, h, op, value;\n"
    "};\n"
    "kernel void blit_copy(texture2d<uint, access::read> src [[texture(0)]],\n"
    "                       texture2d<uint, access::write> dst [[texture(1)]],\n"
    "                       constant BlitParams& p [[buffer(0)]],\n"
    "                       uint2 gid [[thread_position_in_grid]]) {\n"
    "    if (gid.x >= p.w || gid.y >= p.h) return;\n"
    "    uint v = src.read(uint2(p.src_x + gid.x, p.src_y + gid.y)).r;\n"
    "    dst.write(uint4(v, 0, 0, 0), uint2(p.dst_x + gid.x, p.dst_y + gid.y));\n"
    "}\n"
    "kernel void blit_transparent(texture2d<uint, access::read> src [[texture(0)]],\n"
    "                              texture2d<uint, access::read_write> dst [[texture(1)]],\n"
    "                              constant BlitParams& p [[buffer(0)]],\n"
    "                              uint2 gid [[thread_position_in_grid]]) {\n"
    "    if (gid.x >= p.w || gid.y >= p.h) return;\n"
    "    uint v = src.read(uint2(p.src_x + gid.x, p.src_y + gid.y)).r;\n"
    "    if (v == 0u) return;\n"
    "    dst.write(uint4(v, 0, 0, 0), uint2(p.dst_x + gid.x, p.dst_y + gid.y));\n"
    "}\n"
    "kernel void blit_minterm(texture2d<uint, access::read> src [[texture(0)]],\n"
    "                          texture2d<uint, access::read_write> dst [[texture(1)]],\n"
    "                          constant BlitParams& p [[buffer(0)]],\n"
    "                          uint2 gid [[thread_position_in_grid]]) {\n"
    "    if (gid.x >= p.w || gid.y >= p.h) return;\n"
    "    uint s = src.read(uint2(p.src_x + gid.x, p.src_y + gid.y)).r;\n"
    "    uint2 dpos = uint2(p.dst_x + gid.x, p.dst_y + gid.y);\n"
    "    uint d = dst.read(dpos).r;\n"
    "    uint result;\n"
    "    if (p.op == 0u) { result = s & d; }\n"
    "    else if (p.op == 1u) { result = s | d; }\n"
    "    else if (p.op == 2u) { result = s ^ d; }\n"
    "    else { result = s; }\n"
    "    dst.write(uint4(result, 0, 0, 0), dpos);\n"
    "}\n"
    "kernel void blit_clear(texture2d<uint, access::write> dst [[texture(0)]],\n"
    "                        constant BlitParams& p [[buffer(0)]],\n"
    "                        uint2 gid [[thread_position_in_grid]]) {\n"
    "    if (gid.x >= p.w || gid.y >= p.h) return;\n"
    "    dst.write(uint4(p.value, 0, 0, 0), uint2(p.dst_x + gid.x, p.dst_y + gid.y));\n"
    "}\n";

// text_overlay.rs:23-42
static const char* kTextMsl =
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct VOut { float4 pos [[position]]; float2 uv; };\n"
    "vertex VOut vmain(uint vid [[vertex_id]]) {\n"
    "    float2 positions[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };\n"
    "    VOut out;\n"
    "    float2 pos = positions[vid];\n"
    "    out.pos = float4(pos, 0.0, 1.0);\n"
    "    out.uv = float2((pos.x + 1.0) * 0.5, 1.0 - (pos.y + 1.0) * 0.5);\n"
    "    return out;\n"
    "}\n"
    "fragment float4 fmain(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {\n"
    "    constexpr sampler s(coord::normalized, filter::nearest);\n"
    "    return tex.sample(s, in.uv);\n"
    "}\n";

// shader_pane.rs:15-30 — the game's fmain body is appended to this.
static const char* kShaderHeader =
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct VOut { float4 pos [[position]]; float2 uv; };\n"
    "struct Uniforms { float time; float aspect; float p[8]; };\n"
    "vertex VOut vmain(uint vid [[vertex_id]]) {\n"
    "    float2 positions[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };\n"
    "    VOut out;\n"
    "    float2 pos = positions[vid];\n"
    "    out.pos = float4(pos, 0.0, 1.0);\n"
    "    out.uv = float2((pos.x + 1.0) * 0.5, 1.0 - (pos.y + 1.0) * 0.5);\n"
    "    return out;\n"
    "}\n";

// --- shared pipeline helper --------------------------------------------------

static id<MTLRenderPipelineState> MakeRenderPipeline(
    id<MTLDevice> device, const char* src, bool blending, std::string* err) {
  NSError* nserr = nil;
  id<MTLLibrary> lib = [device
      newLibraryWithSource:[NSString stringWithUTF8String:src]
                   options:nil
                     error:&nserr];
  if (lib == nil) {
    if (err) *err = nserr ? [[nserr localizedDescription] UTF8String]
                          : "shader compile failed";
    return nil;
  }
  id<MTLFunction> vfn = [lib newFunctionWithName:@"vmain"];
  id<MTLFunction> ffn = [lib newFunctionWithName:@"fmain"];
  [lib release];
  if (vfn == nil || ffn == nil) {
    if (vfn) [vfn release];
    if (ffn) [ffn release];
    if (err) *err = "shader missing vmain/fmain";
    return nil;
  }
  MTLRenderPipelineDescriptor* desc =
      [[[MTLRenderPipelineDescriptor alloc] init] autorelease];
  desc.vertexFunction = vfn;
  desc.fragmentFunction = ffn;
  MTLRenderPipelineColorAttachmentDescriptor* att = desc.colorAttachments[0];
  att.pixelFormat = MTLPixelFormatBGRA8Unorm;
  if (blending) {                     // straight src-alpha over
    att.blendingEnabled = YES;
    att.rgbBlendOperation = MTLBlendOperationAdd;
    att.alphaBlendOperation = MTLBlendOperationAdd;
    att.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    att.sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
    att.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    att.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
  }
  id<MTLRenderPipelineState> pipe =
      [device newRenderPipelineStateWithDescriptor:desc error:&nserr];
  [vfn release];
  [ffn release];
  if (pipe == nil && err) {
    *err = nserr ? [[nserr localizedDescription] UTF8String]
                 : "pipeline build failed";
  }
  return pipe;
}

static id<MTLTexture> MakeIndexTexture(id<MTLDevice> device, int w, int h,
                                       bool writable) {
  MTLTextureDescriptor* td = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Uint
                                   width:(NSUInteger)w
                                  height:(NSUInteger)h
                               mipmapped:NO];
  td.usage = writable ? (MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite)
                      : MTLTextureUsageShaderRead;
  td.storageMode = MTLStorageModeShared;   // replaceRegion legal; Apple Silicon
  return [device newTextureWithDescriptor:td];
}

// --- GpIndexedPane -----------------------------------------------------------

GpIndexedPane::GpIndexedPane(id<MTLDevice> device, int world_w, int world_h,
                             int viewport_w, int viewport_h, std::string* err)
    : world_w_(world_w), world_h_(world_h),
      viewport_w_(viewport_w), viewport_h_(viewport_h),
      active_(kFront), scroll_x_(0), scroll_y_(0),
      palette_buf_(nil), palette_dirty_(true), pipeline_(nil) {
  if (world_w_ < viewport_w_ || world_h_ < viewport_h_) {
    if (err) *err = "gamepane: world smaller than viewport";
    return;
  }
  size_t n = (size_t)world_w_ * (size_t)world_h_;
  for (int i = 0; i < kNumBuffers; i++) {
    buffers_[i].assign(n, 0);
    textures_[i] = MakeIndexTexture(device, world_w_, world_h_, true);
    dirty_[i] = true;
  }
  size_t entries = (size_t)viewport_h_ * 16 + 240;
  palette_.assign(entries * 4, 0.0f);
  palette_buf_ = [device newBufferWithLength:entries * 16
                                     options:MTLResourceStorageModeShared];
  pipeline_ = MakeRenderPipeline(device, kIndexedMsl, false, err);
  load_default_palette();
}

GpIndexedPane::~GpIndexedPane() {
  for (int i = 0; i < kNumBuffers; i++) {
    if (textures_[i]) [textures_[i] release];
  }
  if (palette_buf_) [palette_buf_ release];
  if (pipeline_) [pipeline_ release];
}

void GpIndexedPane::set_active(int slot) { active_ = slot; }

void GpIndexedPane::swap_buffers() {
  buffers_[kFront].swap(buffers_[kBack]);
  id<MTLTexture> t = textures_[kFront];
  textures_[kFront] = textures_[kBack];
  textures_[kBack] = t;
  bool d = dirty_[kFront];
  dirty_[kFront] = dirty_[kBack];
  dirty_[kBack] = d;
  if (active_ == kFront) active_ = kBack;
  else if (active_ == kBack) active_ = kFront;
}

void GpIndexedPane::set_scroll(int64_t x, int64_t y) {
  int64_t mx = world_w_ - viewport_w_, my = world_h_ - viewport_h_;
  scroll_x_ = x < 0 ? 0 : (x > mx ? mx : x);
  scroll_y_ = y < 0 ? 0 : (y > my ? my : y);
}

void GpIndexedPane::set_rgb(uint8_t index, uint8_t r, uint8_t g, uint8_t b) {
  if (index < 16) return;                      // callers validate; belt+braces
  size_t k = ((size_t)viewport_h_ * 16 + (index - 16)) * 4;
  palette_[k] = r / 255.0f;
  palette_[k + 1] = g / 255.0f;
  palette_[k + 2] = b / 255.0f;
  palette_[k + 3] = 1.0f;
  palette_dirty_ = true;
}

void GpIndexedPane::set_line_rgb(int line, uint8_t index,
                                 uint8_t r, uint8_t g, uint8_t b) {
  if (index < 1 || index > 15 || line < 0 || line >= viewport_h_) return;
  size_t k = ((size_t)line * 16 + index) * 4;
  palette_[k] = r / 255.0f;
  palette_[k + 1] = g / 255.0f;
  palette_[k + 2] = b / 255.0f;
  palette_[k + 3] = 1.0f;
  palette_dirty_ = true;
}

// indexed_pane.rs:433 — enough of HSV for the default hue wheel.
static void HsvToRgb(double h, double s, double v,
                     uint8_t* r, uint8_t* g, uint8_t* b) {
  double i = floor(h * 6.0);
  double f = h * 6.0 - i;
  double p = v * (1.0 - s);
  double q = v * (1.0 - f * s);
  double t = v * (1.0 - (1.0 - f) * s);
  double rr = 0, gg = 0, bb = 0;
  switch (((int)i) % 6) {
    case 0: rr = v; gg = t; bb = p; break;
    case 1: rr = q; gg = v; bb = p; break;
    case 2: rr = p; gg = v; bb = t; break;
    case 3: rr = p; gg = q; bb = v; break;
    case 4: rr = t; gg = p; bb = v; break;
    case 5: rr = v; gg = p; bb = q; break;
  }
  *r = (uint8_t)(rr * 255.0);
  *g = (uint8_t)(gg * 255.0);
  *b = (uint8_t)(bb * 255.0);
}

void GpIndexedPane::load_default_palette() {
  for (int line = 0; line < viewport_h_; line++) {
    for (int i = 1; i < 16; i++) {
      uint8_t v = (uint8_t)(i * 255 / 15);
      set_line_rgb(line, (uint8_t)i, v, v, v);
    }
  }
  for (int i = 16; i < 256; i++) {
    uint8_t r, g, b;
    HsvToRgb((i - 16) / 240.0, 1.0, 1.0, &r, &g, &b);
    set_rgb((uint8_t)i, r, g, b);
  }
}

void GpIndexedPane::cls(uint8_t index) {
  memset(buffers_[active_].data(), index, buffers_[active_].size());
  dirty_[active_] = true;
}

void GpIndexedPane::pset(int64_t x, int64_t y, uint8_t index) {
  if (x < 0 || y < 0 || x >= world_w_ || y >= world_h_) return;
  buffers_[active_][(size_t)y * world_w_ + x] = index;
  dirty_[active_] = true;
}

uint8_t GpIndexedPane::pget(int64_t x, int64_t y) {
  if (x < 0 || y < 0 || x >= world_w_ || y >= world_h_) return 0;
  return buffers_[active_][(size_t)y * world_w_ + x];
}

void GpIndexedPane::load(const uint8_t* data, size_t len) {
  size_t n = buffers_[active_].size();
  if (len > n) len = n;
  memcpy(buffers_[active_].data(), data, len);
  dirty_[active_] = true;
}

void GpIndexedPane::fill_rect(int64_t x, int64_t y, int64_t w, int64_t h,
                              uint8_t index) {
  for (int64_t yy = y; yy < y + h; yy++) {
    if (yy < 0 || yy >= world_h_) continue;
    int64_t x0 = x < 0 ? 0 : x;
    int64_t x1 = x + w > world_w_ ? world_w_ : x + w;
    if (x0 >= x1) continue;
    memset(&buffers_[active_][(size_t)yy * world_w_ + x0], index,
           (size_t)(x1 - x0));
  }
  dirty_[active_] = true;
}

void GpIndexedPane::line(int64_t x0, int64_t y0, int64_t x1, int64_t y1,
                         uint8_t index) {
  int64_t dx = llabs(x1 - x0), dy = -llabs(y1 - y0);
  int64_t sx = x0 < x1 ? 1 : -1, sy = y0 < y1 ? 1 : -1;
  int64_t e = dx + dy;
  for (;;) {
    pset(x0, y0, index);
    if (x0 == x1 && y0 == y1) break;
    int64_t e2 = 2 * e;
    if (e2 >= dy) { e += dy; x0 += sx; }
    if (e2 <= dx) { e += dx; y0 += sy; }
  }
}

void GpIndexedPane::circle(int64_t cx, int64_t cy, int64_t r, uint8_t index) {
  if (r < 0) return;
  int64_t x = r, y = 0, e = 1 - r;
  while (x >= y) {
    pset(cx + x, cy + y, index); pset(cx - x, cy + y, index);
    pset(cx + x, cy - y, index); pset(cx - x, cy - y, index);
    pset(cx + y, cy + x, index); pset(cx - y, cy + x, index);
    pset(cx + y, cy - x, index); pset(cx - y, cy - x, index);
    y++;
    if (e < 0) { e += 2 * y + 1; }
    else { x--; e += 2 * (y - x) + 1; }
  }
}

void GpIndexedPane::disc(int64_t cx, int64_t cy, int64_t r, uint8_t index) {
  if (r < 0) return;
  int64_t x = r, y = 0, e = 1 - r;
  while (x >= y) {
    fill_rect(cx - x, cy + y, 2 * x + 1, 1, index);
    fill_rect(cx - x, cy - y, 2 * x + 1, 1, index);
    fill_rect(cx - y, cy + x, 2 * y + 1, 1, index);
    fill_rect(cx - y, cy - x, 2 * y + 1, 1, index);
    y++;
    if (e < 0) { e += 2 * y + 1; }
    else { x--; e += 2 * (y - x) + 1; }
  }
}

void GpIndexedPane::upload() {
  if (palette_dirty_) {
    memcpy([palette_buf_ contents], palette_.data(),
           palette_.size() * sizeof(float));
    palette_dirty_ = false;
  }
  MTLRegion region = MTLRegionMake2D(0, 0, (NSUInteger)world_w_,
                                     (NSUInteger)world_h_);
  for (int i = 0; i < kNumBuffers; i++) {
    if (!dirty_[i]) continue;
    [textures_[i] replaceRegion:region
                    mipmapLevel:0
                      withBytes:buffers_[i].data()
                    bytesPerRow:(NSUInteger)world_w_];
    dirty_[i] = false;
  }
}

void GpIndexedPane::render(id<MTLCommandBuffer> cb, id<MTLTexture> target,
                           MTLLoadAction load_action) {
  if (pipeline_ == nil) return;
  MTLRenderPassDescriptor* rp =
      [MTLRenderPassDescriptor renderPassDescriptor];
  rp.colorAttachments[0].texture = target;
  rp.colorAttachments[0].loadAction = load_action;
  rp.colorAttachments[0].storeAction = MTLStoreActionStore;
  rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
  id<MTLRenderCommandEncoder> enc =
      [cb renderCommandEncoderWithDescriptor:rp];
  [enc setRenderPipelineState:pipeline_];
  float uniforms[4] = { (float)scroll_x_, (float)scroll_y_,
                        (float)viewport_w_, (float)viewport_h_ };
  [enc setFragmentBytes:uniforms length:sizeof(uniforms) atIndex:0];
  [enc setFragmentTexture:textures_[kFront] atIndex:0];
  [enc setFragmentBuffer:palette_buf_ offset:0 atIndex:1];
  [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
  [enc endEncoding];
}

// --- GpSprites ---------------------------------------------------------------

GpSprites::GpSprites(id<MTLDevice> device, std::string* err)
    : device_(device), pipeline_(nil) {
  pipeline_ = MakeRenderPipeline(device, kSpriteMsl, true, err);
}

GpSprites::~GpSprites() {
  for (size_t i = 0; i < defs_.size(); i++) {
    for (size_t f = 0; f < defs_[i].frames.size(); f++) {
      [defs_[i].frames[f] release];
    }
    if (defs_[i].palette_buf) [defs_[i].palette_buf release];
  }
  if (pipeline_) [pipeline_ release];
}

// sprites.rs::parse_sprite_rows — '/'-separated hex rows, '.' = transparent.
static bool ParseSpriteRows(const char* rows, int* w, int* h,
                            std::vector<uint8_t>* px) {
  if (rows == NULL || rows[0] == '\0') return false;
  std::vector<std::string> lines;
  std::string cur;
  for (const char* p = rows; ; p++) {
    if (*p == '/' || *p == '\0') {
      lines.push_back(cur);
      cur.clear();
      if (*p == '\0') break;
    } else {
      cur.push_back(*p);
    }
  }
  if (lines.empty() || lines[0].empty()) return false;
  size_t width = lines[0].size();
  px->clear();
  for (size_t i = 0; i < lines.size(); i++) {
    if (lines[i].size() != width) return false;      // ragged: reject
    for (size_t j = 0; j < width; j++) {
      char c = lines[i][j];
      uint8_t v;
      if (c == '.') v = 0;
      else if (c >= '0' && c <= '9') v = (uint8_t)(c - '0');
      else if (c >= 'a' && c <= 'f') v = (uint8_t)(c - 'a' + 10);
      else if (c >= 'A' && c <= 'F') v = (uint8_t)(c - 'A' + 10);
      else return false;
      px->push_back(v);
    }
  }
  *w = (int)width;
  *h = (int)lines.size();
  return true;
}

static id<MTLTexture> MakeFrameTexture(id<MTLDevice> device, int w, int h,
                                       const std::vector<uint8_t>& px) {
  id<MTLTexture> t = MakeIndexTexture(device, w, h, false);
  [t replaceRegion:MTLRegionMake2D(0, 0, (NSUInteger)w, (NSUInteger)h)
       mipmapLevel:0
         withBytes:px.data()
       bytesPerRow:(NSUInteger)w];
  return t;
}

int GpSprites::define(const char* rows) {
  int w = 0, h = 0;
  std::vector<uint8_t> px;
  if (!ParseSpriteRows(rows, &w, &h, &px)) return -1;
  GpSpriteDef def;
  def.w = w;
  def.h = h;
  def.frames.push_back(MakeFrameTexture(device_, w, h, px));
  memset(def.palette, 0, sizeof(def.palette));
  for (int i = 0; i < 16; i++) def.palette[i][3] = 1.0f;
  def.palette_buf = [device_ newBufferWithLength:256
                                         options:MTLResourceStorageModeShared];
  def.palette_dirty = true;
  defs_.push_back(def);
  return (int)defs_.size() - 1;
}

bool GpSprites::add_frame(int def, const char* rows) {
  if (def < 0 || def >= (int)defs_.size()) return false;
  int w = 0, h = 0;
  std::vector<uint8_t> px;
  if (!ParseSpriteRows(rows, &w, &h, &px)) return false;
  if (w != defs_[def].w || h != defs_[def].h) return false;
  defs_[def].frames.push_back(MakeFrameTexture(device_, w, h, px));
  return true;
}

void GpSprites::set_rgb(int def, int index, uint8_t r, uint8_t g, uint8_t b) {
  if (def < 0 || def >= (int)defs_.size() || index < 0 || index > 15) return;
  defs_[def].palette[index][0] = r / 255.0f;
  defs_[def].palette[index][1] = g / 255.0f;
  defs_[def].palette[index][2] = b / 255.0f;
  defs_[def].palette[index][3] = 1.0f;
  defs_[def].palette_dirty = true;
}

int GpSprites::place(int def, double x, double y) {
  if (def < 0 || def >= (int)defs_.size()) return -1;
  GpSpriteInstance inst;
  inst.def = def;
  inst.x = x; inst.y = y;
  inst.scale = 1.0; inst.rot_deg = 0.0; inst.alpha = 1.0;
  inst.frame = 0; inst.visible = true;
  inst.fps = 0.0; inst.accum = 0.0;
  instances_.push_back(inst);
  return (int)instances_.size() - 1;
}

GpSpriteInstance* GpSprites::instance(int id) {
  if (id < 0 || id >= (int)instances_.size()) return NULL;
  return &instances_[id];
}

bool GpSprites::hit(int a, int b) {
  GpSpriteInstance* ia = instance(a);
  GpSpriteInstance* ib = instance(b);
  if (ia == NULL || ib == NULL) return false;
  const GpSpriteDef& da = defs_[ia->def];
  const GpSpriteDef& db = defs_[ib->def];
  double ahw = da.w * ia->scale / 2.0, ahh = da.h * ia->scale / 2.0;
  double bhw = db.w * ib->scale / 2.0, bhh = db.h * ib->scale / 2.0;
  return ia->x - ahw < ib->x + bhw && ia->x + ahw > ib->x - bhw &&
         ia->y - ahh < ib->y + bhh && ia->y + ahh > ib->y - bhh;
}

void GpSprites::tick(double dt) {
  for (size_t i = 0; i < instances_.size(); i++) {
    GpSpriteInstance& inst = instances_[i];
    if (inst.fps <= 0.0) continue;
    size_t frames = defs_[inst.def].frames.size();
    if (frames <= 1) continue;
    inst.accum += dt;
    double period = 1.0 / inst.fps;
    while (inst.accum >= period) {          // catch-up, as the Rust does
      inst.accum -= period;
      inst.frame = (int)((inst.frame + 1) % (int)frames);
    }
  }
}

void GpSprites::render(id<MTLCommandBuffer> cb, id<MTLTexture> target,
                       double scroll_x, double scroll_y,
                       double vw, double vh) {
  if (pipeline_ == nil || instances_.empty()) return;
  // Lazy palette uploads (sprites.rs uploads at the top of render()).
  for (size_t i = 0; i < defs_.size(); i++) {
    if (defs_[i].palette_dirty) {
      memcpy([defs_[i].palette_buf contents], defs_[i].palette, 256);
      defs_[i].palette_dirty = false;
    }
  }
  MTLRenderPassDescriptor* rp =
      [MTLRenderPassDescriptor renderPassDescriptor];
  rp.colorAttachments[0].texture = target;
  rp.colorAttachments[0].loadAction = MTLLoadActionLoad;
  rp.colorAttachments[0].storeAction = MTLStoreActionStore;
  id<MTLRenderCommandEncoder> enc =
      [cb renderCommandEncoderWithDescriptor:rp];
  [enc setRenderPipelineState:pipeline_];
  for (size_t i = 0; i < instances_.size(); i++) {
    const GpSpriteInstance& inst = instances_[i];
    if (!inst.visible) continue;
    const GpSpriteDef& def = defs_[inst.def];
    double hw = def.w * inst.scale / 2.0, hh = def.h * inst.scale / 2.0;
    double theta = inst.rot_deg * (3.14159265358979323846 / 180.0);
    double c = cos(theta), s = sin(theta);
    double cx = inst.x - scroll_x, cy = inst.y - scroll_y;
    // TL, TR, BL, BR strip; rotation in screen space, y down (sprites.rs:372).
    double lx[4] = { -hw, hw, -hw, hw };
    double ly[4] = { -hh, -hh, hh, hh };
    float uv[4][2] = { {0, 0}, {1, 0}, {0, 1}, {1, 1} };
    float verts[16];
    for (int v = 0; v < 4; v++) {
      double rx = lx[v] * c - ly[v] * s;
      double ry = lx[v] * s + ly[v] * c;
      double sxp = cx + rx, syp = cy + ry;
      verts[v * 4] = (float)((sxp / vw) * 2.0 - 1.0);
      verts[v * 4 + 1] = (float)(1.0 - (syp / vh) * 2.0);
      verts[v * 4 + 2] = uv[v][0];
      verts[v * 4 + 3] = uv[v][1];
    }
    float alpha = (float)inst.alpha;
    int frame = inst.frame;
    if (frame >= (int)def.frames.size()) frame = (int)def.frames.size() - 1;
    [enc setVertexBytes:verts length:sizeof(verts) atIndex:0];
    [enc setFragmentBytes:&alpha length:sizeof(alpha) atIndex:0];
    [enc setFragmentTexture:def.frames[frame] atIndex:0];
    [enc setFragmentBuffer:def.palette_buf offset:0 atIndex:1];
    [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip
             vertexStart:0
             vertexCount:4];
  }
  [enc endEncoding];
}

// --- GpBlitter ---------------------------------------------------------------

static id<MTLComputePipelineState> MakeKernel(id<MTLDevice> device,
                                              id<MTLLibrary> lib,
                                              NSString* name,
                                              std::string* err) {
  id<MTLFunction> fn = [lib newFunctionWithName:name];
  if (fn == nil) {
    if (err) *err = "gamepane: missing blit kernel";
    return nil;
  }
  NSError* nserr = nil;
  id<MTLComputePipelineState> p =
      [device newComputePipelineStateWithFunction:fn error:&nserr];
  [fn release];
  if (p == nil && err) {
    *err = nserr ? [[nserr localizedDescription] UTF8String]
                 : "blit pipeline build failed";
  }
  return p;
}

GpBlitter::GpBlitter(id<MTLDevice> device, std::string* err)
    : copy_(nil), transparent_(nil), minterm_(nil), clear_(nil) {
  NSError* nserr = nil;
  id<MTLLibrary> lib = [device
      newLibraryWithSource:[NSString stringWithUTF8String:kBlitterMsl]
                   options:nil
                     error:&nserr];
  if (lib == nil) {
    if (err) *err = nserr ? [[nserr localizedDescription] UTF8String]
                          : "blitter compile failed";
    return;
  }
  copy_ = MakeKernel(device, lib, @"blit_copy", err);
  transparent_ = MakeKernel(device, lib, @"blit_transparent", err);
  minterm_ = MakeKernel(device, lib, @"blit_minterm", err);
  clear_ = MakeKernel(device, lib, @"blit_clear", err);
  [lib release];
}

GpBlitter::~GpBlitter() {
  if (copy_) [copy_ release];
  if (transparent_) [transparent_ release];
  if (minterm_) [minterm_ release];
  if (clear_) [clear_ release];
}

void GpBlitter::blit(GpIndexedPane* pane, id<MTLCommandBuffer> cb, int mode,
                     int src, int dst, int64_t sx, int64_t sy,
                     int64_t dx, int64_t dy, int64_t w, int64_t h,
                     uint8_t value) {
  if (pane == NULL || cb == nil) return;
  int ww = pane->world_w(), wh = pane->world_h();
  // Clip: shrink the rect so both source and destination stay in bounds
  // (the Rust panicked out of range; GAMEPANE_PLAN.md §5 mandates clipping).
  if (sx < 0) { dx -= sx; w += sx; sx = 0; }
  if (sy < 0) { dy -= sy; h += sy; sy = 0; }
  if (dx < 0) { sx -= dx; w += dx; dx = 0; }
  if (dy < 0) { sy -= dy; h += dy; dy = 0; }
  if (mode == 5) { sx = 0; sy = 0; }        // clear has no source
  if (w > ww - sx) w = ww - sx;
  if (h > wh - sy) h = wh - sy;
  if (w > ww - dx) w = ww - dx;
  if (h > wh - dy) h = wh - dy;
  if (w <= 0 || h <= 0) return;

  // Both sides current before the GPU reads them (fixes the Rust's silent
  // CPU/GPU divergence when a dirty slot was blitted).
  pane->upload();

  id<MTLComputePipelineState> pipe = nil;
  uint32_t op = 0;
  switch (mode) {
    case 0: pipe = copy_; break;
    case 1: pipe = transparent_; break;
    case 2: pipe = minterm_; op = 0; break;
    case 3: pipe = minterm_; op = 1; break;
    case 4: pipe = minterm_; op = 2; break;
    case 5: pipe = clear_; break;
    default: return;
  }
  if (pipe == nil) return;

  struct { uint32_t sx, sy, dx, dy, w, h, op, value; } params = {
    (uint32_t)sx, (uint32_t)sy, (uint32_t)dx, (uint32_t)dy,
    (uint32_t)w, (uint32_t)h, op, value
  };
  id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
  [enc setComputePipelineState:pipe];
  if (mode == 5) {
    [enc setTexture:pane->texture(dst) atIndex:0];
  } else {
    [enc setTexture:pane->texture(src) atIndex:0];
    [enc setTexture:pane->texture(dst) atIndex:1];
  }
  [enc setBytes:&params length:sizeof(params) atIndex:0];
  MTLSize group = MTLSizeMake(16, 16, 1);
  MTLSize grid = MTLSizeMake((NSUInteger)((w + 15) / 16),
                             (NSUInteger)((h + 15) / 16), 1);
  [enc dispatchThreadgroups:grid threadsPerThreadgroup:group];
  [enc endEncoding];

  // Mirror the op on the CPU copy so pget stays truthful; the slots now
  // match the GPU, so clearing the dirty bit is safe.
  std::vector<uint8_t>& sbuf = pane->buffer(mode == 5 ? dst : src);
  std::vector<uint8_t>& dbuf = pane->buffer(dst);
  for (int64_t yy = 0; yy < h; yy++) {
    for (int64_t xx = 0; xx < w; xx++) {
      size_t si = (size_t)(sy + yy) * ww + (sx + xx);
      size_t di = (size_t)(dy + yy) * ww + (dx + xx);
      uint8_t s = sbuf[si];
      switch (mode) {
        case 0: dbuf[di] = s; break;
        case 1: if (s != 0) dbuf[di] = s; break;
        case 2: dbuf[di] = (uint8_t)(s & dbuf[di]); break;
        case 3: dbuf[di] = (uint8_t)(s | dbuf[di]); break;
        case 4: dbuf[di] = (uint8_t)(s ^ dbuf[di]); break;
        case 5: dbuf[di] = value; break;
      }
    }
  }
  pane->set_dirty(dst, false);
}

// --- GpTextOverlay -----------------------------------------------------------

static const int kCellW = 8, kCellH = 12, kThick = 2;
static const uint8_t kDigitSegments[10] = {
  0x3F, 0x06, 0x5B, 0x4F, 0x66, 0x6D, 0x7D, 0x07, 0x7F, 0x6F
};

GpTextOverlay::GpTextOverlay(id<MTLDevice> device, int w, int h,
                             std::string* err)
    : w_(w), h_(h), dirty_(true), texture_(nil), pipeline_(nil) {
  rgba_.assign((size_t)w * h * 4, 0);
  MTLTextureDescriptor* td = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                   width:(NSUInteger)w
                                  height:(NSUInteger)h
                               mipmapped:NO];
  td.usage = MTLTextureUsageShaderRead;
  td.storageMode = MTLStorageModeShared;
  texture_ = [device newTextureWithDescriptor:td];
  pipeline_ = MakeRenderPipeline(device, kTextMsl, true, err);
}

GpTextOverlay::~GpTextOverlay() {
  if (texture_) [texture_ release];
  if (pipeline_) [pipeline_ release];
}

void GpTextOverlay::clear() {
  memset(rgba_.data(), 0, rgba_.size());
  dirty_ = true;
}

void GpTextOverlay::set_px(int64_t x, int64_t y,
                           uint8_t r, uint8_t g, uint8_t b) {
  if (x < 0 || y < 0 || x >= w_ || y >= h_) return;
  size_t i = ((size_t)y * w_ + x) * 4;
  rgba_[i] = r; rgba_[i + 1] = g; rgba_[i + 2] = b; rgba_[i + 3] = 255;
}

void GpTextOverlay::fill_px(int64_t x, int64_t y, int64_t w, int64_t h,
                            uint8_t r, uint8_t g, uint8_t b) {
  for (int64_t yy = y; yy < y + h; yy++) {
    for (int64_t xx = x; xx < x + w; xx++) set_px(xx, yy, r, g, b);
  }
}

void GpTextOverlay::draw_text(int64_t x, int64_t y, const char* text,
                              uint8_t r, uint8_t g, uint8_t b) {
  const int w = kCellW, h = kCellH, t = kThick, half = kCellH / 2;
  for (const char* p = text; *p != '\0'; p++, x += kCellW) {
    char c = *p;
    if (c == ' ') continue;
    if (c == ':') {
      fill_px(x + w / 2 - t / 2, y + h / 3, t, t, r, g, b);
      fill_px(x + w / 2 - t / 2, y + 2 * h / 3, t, t, r, g, b);
      continue;
    }
    if (c == '-') {
      fill_px(x, y + h / 2 - t / 2, w, t, r, g, b);
      continue;
    }
    if (c >= '0' && c <= '9') {
      uint8_t seg = kDigitSegments[c - '0'];
      if (seg & 0x01) fill_px(x, y, w, t, r, g, b);                 // a
      if (seg & 0x02) fill_px(x + w - t, y, t, half, r, g, b);      // b
      if (seg & 0x04) fill_px(x + w - t, y + half, t, half, r, g, b);  // c
      if (seg & 0x08) fill_px(x, y + h - t, w, t, r, g, b);         // d
      if (seg & 0x10) fill_px(x, y + half, t, half, r, g, b);       // e
      if (seg & 0x20) fill_px(x, y, t, half, r, g, b);              // f
      if (seg & 0x40) fill_px(x, y + half - t / 2, w, t, r, g, b);  // g
      continue;
    }
    // Everything else: a visible placeholder box, never a silent vanish.
    fill_px(x, y, w, t, r, g, b);
    fill_px(x, y + h - t, w, t, r, g, b);
    fill_px(x, y, t, h, r, g, b);
    fill_px(x + w - t, y, t, h, r, g, b);
  }
  dirty_ = true;
}

void GpTextOverlay::upload() {
  if (!dirty_) return;
  [texture_ replaceRegion:MTLRegionMake2D(0, 0, (NSUInteger)w_, (NSUInteger)h_)
              mipmapLevel:0
                withBytes:rgba_.data()
              bytesPerRow:(NSUInteger)w_ * 4];
  dirty_ = false;
}

void GpTextOverlay::render(id<MTLCommandBuffer> cb, id<MTLTexture> target) {
  if (pipeline_ == nil) return;
  MTLRenderPassDescriptor* rp =
      [MTLRenderPassDescriptor renderPassDescriptor];
  rp.colorAttachments[0].texture = target;
  rp.colorAttachments[0].loadAction = MTLLoadActionLoad;
  rp.colorAttachments[0].storeAction = MTLStoreActionStore;
  id<MTLRenderCommandEncoder> enc =
      [cb renderCommandEncoderWithDescriptor:rp];
  [enc setRenderPipelineState:pipeline_];
  [enc setFragmentTexture:texture_ atIndex:0];
  [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
  [enc endEncoding];
}

// --- GpShaderPane ------------------------------------------------------------

GpShaderPane::GpShaderPane(id<MTLDevice> device)
    : device_(device), pipeline_(nil), start_time_(CACurrentMediaTime()),
      aspect_(1.0f) {
  for (int i = 0; i < 8; i++) params_[i] = 0.0f;
}

GpShaderPane::~GpShaderPane() {
  if (pipeline_) [pipeline_ release];
}

std::string GpShaderPane::compile(const char* frag_msl) {
  std::string src = std::string(kShaderHeader) + "\n" + frag_msl;
  std::string err;
  id<MTLRenderPipelineState> pipe =
      MakeRenderPipeline(device_, src.c_str(), false, &err);
  if (pipe == nil) return err.empty() ? "shader compile failed" : err;
  if (pipeline_) [pipeline_ release];
  pipeline_ = pipe;
  start_time_ = CACurrentMediaTime();
  return "";
}

void GpShaderPane::set_param(int i, float v) {
  if (i >= 0 && i < 8) params_[i] = v;
}

void GpShaderPane::render(id<MTLCommandBuffer> cb, id<MTLTexture> target) {
  if (pipeline_ == nil) return;
  MTLRenderPassDescriptor* rp =
      [MTLRenderPassDescriptor renderPassDescriptor];
  rp.colorAttachments[0].texture = target;
  rp.colorAttachments[0].loadAction = MTLLoadActionClear;
  rp.colorAttachments[0].storeAction = MTLStoreActionStore;
  rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
  id<MTLRenderCommandEncoder> enc =
      [cb renderCommandEncoderWithDescriptor:rp];
  [enc setRenderPipelineState:pipeline_];
  float uniforms[10];
  uniforms[0] = (float)(CACurrentMediaTime() - start_time_);
  uniforms[1] = aspect_;
  for (int i = 0; i < 8; i++) uniforms[2 + i] = params_[i];
  [enc setFragmentBytes:uniforms length:sizeof(uniforms) atIndex:0];
  [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
  [enc endEncoding];
}

// --- GpSfx -------------------------------------------------------------------

GpSfx::GpSfx() : engine_(nil), player_(nil), format_(nil), started_(false) {
  for (int i = 0; i < kMaxSfxSlots; i++) buffers_[i] = nil;
}

GpSfx::~GpSfx() {
  for (int i = 0; i < kMaxSfxSlots; i++) {
    if (buffers_[i]) [buffers_[i] release];
  }
  if (started_) {
    [(AVAudioPlayerNode*)player_ stop];
    [(AVAudioEngine*)engine_ stop];
  }
  if (player_) [player_ release];
  if (format_) [format_ release];      // the Rust leaked this; we don't
  if (engine_) [engine_ release];
}

// playback.rs::start — the wiring order is load-bearing.
bool GpSfx::start() {
  if (started_) return true;
  AVAudioEngine* engine = [[AVAudioEngine alloc] init];
  AVAudioPlayerNode* player = [[AVAudioPlayerNode alloc] init];
  [engine attachNode:player];
  AVAudioFormat* format =
      [[AVAudioFormat alloc] initStandardFormatWithSampleRate:44100.0
                                                     channels:2];
  [engine connect:player to:[engine mainMixerNode] format:format];
  NSError* err = nil;
  [engine startAndReturnError:&err];
  if (err != nil) {
    [player release];
    [format release];
    [engine release];
    return false;
  }
  [player play];
  engine_ = engine;
  player_ = player;
  format_ = format;
  started_ = true;
  return true;
}

void GpSfx::define(int slot, const Sound& sound) {
  if (!started_ || slot < 0 || slot >= kMaxSfxSlots || sound.samples.empty()) {
    return;
  }
  AVAudioFrameCount frames = (AVAudioFrameCount)(sound.samples.size() / 2);
  AVAudioPCMBuffer* buffer =
      [[AVAudioPCMBuffer alloc] initWithPCMFormat:(AVAudioFormat*)format_
                                    frameCapacity:frames];
  if (buffer == nil) return;
  buffer.frameLength = frames;            // capacity != length; must set
  float* const* channels = buffer.floatChannelData;
  if (channels != NULL) {
    float* left = channels[0];
    float* right = channels[1];
    for (AVAudioFrameCount f = 0; f < frames; f++) {
      left[f] = (float)sound.samples[(size_t)f * 2];
      right[f] = (float)sound.samples[(size_t)f * 2 + 1];
    }
  }
  if (buffers_[slot]) [buffers_[slot] release];
  buffers_[slot] = buffer;
}

void GpSfx::play(int slot) {
  if (!started_ || slot < 0 || slot >= kMaxSfxSlots || buffers_[slot] == nil) {
    return;
  }
  [(AVAudioPlayerNode*)player_
      scheduleBuffer:(AVAudioPCMBuffer*)buffers_[slot]
      completionHandler:nil];
}

// --- GpEngine ----------------------------------------------------------------

GpEngine* GpEngine::instance() {
  static GpEngine* g = NULL;
  if (g == NULL) g = new GpEngine();
  return g;
}

GpEngine::GpEngine()
    : device_(nil), queue_(nil), view_(nil), layer_(nil), offscreen_(nil),
      frame_cb_(nil), pane_(NULL), sprites_(NULL), blitter_(NULL),
      text_(NULL), shader_(NULL), sfx_(NULL), open_(false),
      logical_w_(0), logical_h_(0), frames_(0), last_tick_time_(0.0) {}

bool GpEngine::ensure_device(std::string* err) {
  if (device_ != nil) return true;
  device_ = MTLCreateSystemDefaultDevice();
  if (device_ == nil) {
    if (err) *err = "gamepane: no Metal device";
    return false;
  }
  queue_ = [device_ newCommandQueue];
  layer_ = [[CAMetalLayer alloc] init];
  layer_.device = device_;
  layer_.pixelFormat = MTLPixelFormatBGRA8Unorm;
  layer_.framebufferOnly = NO;              // drawable is a blit destination
  layer_.magnificationFilter = kCAFilterNearest;   // crisp retro upscale
  view_ = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 64, 64)];
  [view_ setLayer:layer_];                  // layer-hosting: tracks the frame
  [view_ setWantsLayer:YES];
  return true;
}

NSView* GpEngine::open(int w, int h, int world_w, int world_h,
                       std::string* err) {
  if (!ensure_device(err)) return nil;
  close();                                  // panes free; device/view reused
  if (world_w < w) world_w = w;             // world >= viewport, always
  if (world_h < h) world_h = h;
  logical_w_ = w;
  logical_h_ = h;
  layer_.drawableSize = CGSizeMake(w, h);   // logical pixels; layer upscales

  MTLTextureDescriptor* td = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                   width:(NSUInteger)w
                                  height:(NSUInteger)h
                               mipmapped:NO];
  td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
  td.storageMode = MTLStorageModeShared;    // gpsnap reads it back
  offscreen_ = [device_ newTextureWithDescriptor:td];

  pane_ = new GpIndexedPane(device_, world_w, world_h, w, h, err);
  sprites_ = new GpSprites(device_, err);
  blitter_ = new GpBlitter(device_, err);
  text_ = new GpTextOverlay(device_, w, h, err);
  shader_ = new GpShaderPane(device_);
  open_ = true;
  frames_ = 0;
  last_tick_time_ = 0.0;
  if (err != NULL && !err->empty()) {       // any sub-init failure aborts open
    close();
    return nil;
  }
  return view_;
}

void GpEngine::close() {
  delete pane_; pane_ = NULL;
  delete sprites_; sprites_ = NULL;
  delete blitter_; blitter_ = NULL;
  delete text_; text_ = NULL;
  delete shader_; shader_ = NULL;
  if (offscreen_) { [offscreen_ release]; offscreen_ = nil; }
  frame_cb_ = nil;
  open_ = false;
}

GpSfx* GpEngine::sfx() {
  if (sfx_ == NULL) {
    sfx_ = new GpSfx();
    sfx_->start();                          // one engine per process, lazily
  }
  return sfx_;
}

void GpEngine::begin_frame() {
  if (!open_) return;
  frame_cb_ = [queue_ commandBuffer];       // autoreleased; apply() owns pool
}

void GpEngine::render_present() {
  if (!open_ || frame_cb_ == nil) return;
  double now = CACurrentMediaTime();
  double dt = last_tick_time_ == 0.0 ? 0.0 : now - last_tick_time_;
  if (dt > 0.1) dt = 0.1;
  last_tick_time_ = now;
  sprites_->tick(dt);
  pane_->upload();
  text_->upload();

  bool has_shader = shader_->ready();
  if (has_shader) shader_->render(frame_cb_, offscreen_);
  pane_->render(frame_cb_, offscreen_,
                has_shader ? MTLLoadActionLoad : MTLLoadActionClear);
  sprites_->render(frame_cb_, offscreen_,
                   (double)pane_->scroll_x(), (double)pane_->scroll_y(),
                   (double)logical_w_, (double)logical_h_);
  text_->render(frame_cb_, offscreen_);

  id<CAMetalDrawable> drawable = [layer_ nextDrawable];
  if (drawable != nil) {
    id<MTLBlitCommandEncoder> blit = [frame_cb_ blitCommandEncoder];
    [blit copyFromTexture:offscreen_
              sourceSlice:0
              sourceLevel:0
             sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake((NSUInteger)logical_w_,
                                      (NSUInteger)logical_h_, 1)
                toTexture:drawable.texture
         destinationSlice:0
         destinationLevel:0
        destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];
    [frame_cb_ presentDrawable:drawable];
  }
  [frame_cb_ commit];
  frame_cb_ = nil;
  frames_++;
}

bool GpEngine::snap(const char* path, std::string* err) {
  if (!open_ || offscreen_ == nil) {
    if (err) *err = "gamepane: not open";
    return false;
  }
  int w = logical_w_, h = logical_h_;
  std::vector<uint8_t> bgra((size_t)w * h * 4);
  [offscreen_ getBytes:bgra.data()
           bytesPerRow:(NSUInteger)w * 4
            fromRegion:MTLRegionMake2D(0, 0, (NSUInteger)w, (NSUInteger)h)
           mipmapLevel:0];
  NSBitmapImageRep* rep = [[[NSBitmapImageRep alloc]
      initWithBitmapDataPlanes:NULL
                    pixelsWide:w
                    pixelsHigh:h
                 bitsPerSample:8
               samplesPerPixel:4
                      hasAlpha:YES
                      isPlanar:NO
                colorSpaceName:NSDeviceRGBColorSpace
                   bytesPerRow:w * 4
                  bitsPerPixel:32] autorelease];
  if (rep == nil) {
    if (err) *err = "gamepane: bitmap rep failed";
    return false;
  }
  uint8_t* out = [rep bitmapData];
  for (size_t i = 0; i < (size_t)w * h; i++) {   // BGRA -> RGBA
    out[i * 4] = bgra[i * 4 + 2];
    out[i * 4 + 1] = bgra[i * 4 + 1];
    out[i * 4 + 2] = bgra[i * 4];
    out[i * 4 + 3] = 255;
  }
  NSData* png = [rep representationUsingType:NSBitmapImageFileTypePNG
                                  properties:@{}];
  if (png == nil || ![png writeToFile:[NSString stringWithUTF8String:path]
                           atomically:YES]) {
    if (err) *err = "gamepane: png write failed";
    return false;
  }
  return true;
}

}  // namespace macdart_gamepane
