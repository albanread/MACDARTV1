// App: Number bases
//
// Decimal, hex, binary and octal views of one integer — the conversion you
// actually reach for while reading a disassembly or a bitfield. Type in any
// base; the others follow. Bit width and a bit-pattern readout are there
// because "which bit is that" is the question underneath most of these.
class Bases {
  var n = 255;
  var bits = 32;

  build(ui) {
    ui.title('Number bases');
    var row = (String id, String name, double y, String text) {
      ui.label('l' + id, text: name, frame: [8.0, y + 4.0, 70.0, 18.0]);
      ui.field(id, text: text, frame: [82.0, y, 250.0, 24.0],
               onText: (s) => from(id, s, ui));
    };
    row('dec', 'Decimal', 8.0, n.toString());
    row('hex', 'Hex', 40.0, n.toRadixString(16));
    row('oct', 'Octal', 72.0, n.toRadixString(8));
    row('bin', 'Binary', 104.0, n.toRadixString(2));

    ui.label('pat', text: _pattern(), frame: [8.0, 140.0, 500.0, 18.0]);

    // Narrowing the width narrows the VALUE too: "8 bit" means read this as an
    // 8-bit register, so the decimal field must not keep claiming 510.
    var w = (String id, String name, double x, int b) {
      ui.button(id, title: name, frame: [x, 168.0, 62.0, 26.0],
                onClick: (_) { bits = b; n = _mask(n); showAll(ui, null); });
    };
    w('w8', '8 bit', 8.0, 8);
    w('w16', '16 bit', 74.0, 16);
    w('w32', '32 bit', 140.0, 32);
    w('w64', '64 bit', 206.0, 64);
    ui.button('shl', title: '<< 1', frame: [280.0, 168.0, 62.0, 26.0],
              onClick: (_) { n = _mask(n << 1); showAll(ui, null); });
    ui.button('shr', title: '>> 1', frame: [346.0, 168.0, 62.0, 26.0],
              onClick: (_) { n = n >> 1; showAll(ui, null); });
    ui.button('not', title: '~', frame: [412.0, 168.0, 62.0, 26.0],
              onClick: (_) { n = _mask(~n); showAll(ui, null); });
  }

  from(String which, String s, ui) {
    var t = s.trim().toLowerCase();
    if (t.startsWith('0x')) t = t.substring(2);
    var radix = (which == 'hex') ? 16 : (which == 'oct') ? 8
              : (which == 'bin') ? 2 : 10;
    var v = int.parse(t, radix: radix, onError: (_) => null);
    if (v == null) return;                 // mid-typing — wait for a valid one
    n = _mask(v);
    showAll(ui, which);
  }

  showAll(ui, String except) {
    if (except != 'dec') ui.set('dec', text: n.toString());
    if (except != 'hex') ui.set('hex', text: n.toRadixString(16));
    if (except != 'oct') ui.set('oct', text: n.toRadixString(8));
    if (except != 'bin') ui.set('bin', text: n.toRadixString(2));
    ui.set('pat', text: _pattern());
  }

  // Grouped in nibbles, which is how you read one off a register dump.
  _pattern() {
    var b = n.toRadixString(2);
    while (b.length < bits) b = '0' + b;
    if (b.length > bits) b = b.substring(b.length - bits);
    var out = '';
    for (var i = 0; i < b.length; i++) {
      if (i > 0 && (b.length - i) % 4 == 0) out = out + ' ';
      out = out + b[i];
    }
    return bits.toString() + '-bit:  ' + out;
  }

  _mask(int v) {
    if (bits >= 64) return v;
    return v & ((1 << bits) - 1);
  }
}
