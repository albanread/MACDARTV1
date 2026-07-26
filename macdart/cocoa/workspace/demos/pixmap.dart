// Pixmap — a pixel buffer a demo isolate fills and hands to the UI isolate.
// (Deliberately no demo-title header line: the Demos menu lists only demo
// programs; this is a library they import.)
//
// Per-pixel drawing over the command protocol would mean one ['rect', …] per
// pixel — thousands of messages' worth of overhead for one image. A Pixmap
// crosses the port as ONE command instead: blit() wraps the RGB buffer as a
// BMP (encoded right here in Dart — 54-byte header, bottom-up BGR rows), then
// base64, and the UI isolate hands that to NSImage via NSData
// initWithBase64EncodedString:. No native code, one message, scaled on arrival
// by drawInRect: — so compute at whatever resolution suits the demo.
//
//   var px = new Pixmap(320, 200);
//   px.set(x, y, r, g, b);                // 0..1 doubles, top-left origin
//   ui.send(['draw', [px.blit(0, 0, w, h)]]);
library pixmap;

import 'dart:convert';
import 'dart:typed_data';

class Pixmap {
  final int width, height;
  final Uint8List _px;   // rgb, row-major, top-left origin

  Pixmap(int w, int h)
      : width = w, height = h, _px = new Uint8List(w * h * 3);

  /// Set pixel (x,y) — components are 0..1 doubles like the draw protocol.
  void set(int x, int y, double r, double g, double b) {
    if (x < 0 || y < 0 || x >= width || y >= height) return;
    var i = (y * width + x) * 3;
    _px[i]     = (r * 255.0).round().clamp(0, 255);
    _px[i + 1] = (g * 255.0).round().clamp(0, 255);
    _px[i + 2] = (b * 255.0).round().clamp(0, 255);
  }

  /// The fast path: components already 0..255 ints (a palette table, say).
  /// No clamping — a Uint8List store truncates anyway.
  void set8(int x, int y, int r, int g, int b) {
    if (x < 0 || y < 0 || x >= width || y >= height) return;
    var i = (y * width + x) * 3;
    _px[i] = r; _px[i + 1] = g; _px[i + 2] = b;
  }

  /// The draw command that paints this pixmap with its top-left at (x,y),
  /// scaled to [dw]x[dh] (defaults to the pixmap's own size).
  List blit(num x, num y, [num dw, num dh]) {
    return <dynamic>['blit', x, y,
                     dw != null ? dw : width, dh != null ? dh : height,
                     BASE64.encode(_toBmp())];
  }

  /// A 24-bit uncompressed BMP: the one image format simple enough to emit by
  /// hand, and one NSImage decodes natively. Rows are stored bottom-up in BGR,
  /// padded to 4 bytes.
  Uint8List _toBmp() {
    var rowSize = (3 * width + 3) & ~3;
    var imageSize = rowSize * height;
    var out = new Uint8List(54 + imageSize);
    var b = new ByteData.view(out.buffer);
    out[0] = 0x42; out[1] = 0x4D;                    // 'BM'
    b.setUint32(2, 54 + imageSize, Endianness.LITTLE_ENDIAN);
    b.setUint32(10, 54, Endianness.LITTLE_ENDIAN);   // pixel data offset
    b.setUint32(14, 40, Endianness.LITTLE_ENDIAN);   // BITMAPINFOHEADER
    b.setUint32(18, width, Endianness.LITTLE_ENDIAN);
    b.setUint32(22, height, Endianness.LITTLE_ENDIAN);
    b.setUint16(26, 1, Endianness.LITTLE_ENDIAN);    // planes
    b.setUint16(28, 24, Endianness.LITTLE_ENDIAN);   // bits per pixel
    b.setUint32(34, imageSize, Endianness.LITTLE_ENDIAN);
    b.setUint32(38, 2835, Endianness.LITTLE_ENDIAN); // 72dpi, by convention
    b.setUint32(42, 2835, Endianness.LITTLE_ENDIAN);
    var o = 54;
    for (var y = height - 1; y >= 0; y--) {
      var i = y * width * 3;
      var end = i + width * 3;
      while (i < end) {
        out[o]     = _px[i + 2];                     // BGR
        out[o + 1] = _px[i + 1];
        out[o + 2] = _px[i];
        o += 3; i += 3;
      }
      o += rowSize - width * 3;                      // row padding
    }
    return out;
  }
}
