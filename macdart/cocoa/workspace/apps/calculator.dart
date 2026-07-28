// App: Calculator
//
// A user app: an ordinary class in the image with a `build(ui)` method. It runs
// in the LANGUAGE isolate — so it is hot-reloadable, debuggable and killable —
// and never imports dart:cocoa. It describes widgets; the UI isolate, the only
// one allowed near AppKit, materialises them and sends events back.
//
// Try the thing this exists for: run it, add up a few numbers, then edit the
// layout below (make the keys bigger, move the display) and press Accept. The
// keypad changes while the running total survives, because a hot reload MORPHS
// the live instance instead of replacing it.
//
// Note there is no layout engine here — a keypad is a `for` loop over frames.
// Layout is your code, in your isolate, which is why it needs no framework.
class Calculator {
  var acc = 0.0;          // the left-hand side of a pending operation
  var pending;            // '+', '-', '*', '/' — null when there is none
  var display = '0';
  var fresh = true;       // the next digit starts a new number

  build(ui) {
    ui.title('Calculator');
    ui.field('d', text: display, frame: [8.0, 8.0, 272.0, 32.0],
             align: 'right', readOnly: true);

    var keys = ['7', '8', '9', '/',
                '4', '5', '6', '*',
                '1', '2', '3', '-',
                '0', '.', '=', '+'];
    for (var i = 0; i < keys.length; i++) {
      var k = keys[i];
      ui.button('k' + k, title: k,
          frame: [8.0 + (i % 4) * 68.0, 48.0 + (i ~/ 4) * 46.0, 64.0, 40.0],
          onClick: (_) => press(k, ui));
    }
    ui.button('kC', title: 'C', frame: [8.0 + 4 * 68.0, 48.0, 64.0, 40.0],
        onClick: (_) => reset(ui));
    ui.label('hint', text: 'edit build() and press Accept — the total survives',
             frame: [8.0, 240.0, 400.0, 16.0]);
  }

  press(String k, ui) {
    if (k == '.' || (k.compareTo('0') >= 0 && k.compareTo('9') <= 0)) {
      if (fresh) {
        display = (k == '.') ? '0.' : k;
        fresh = false;
      } else if (k != '.' || !display.contains('.')) {
        display = display + k;
      }
    } else if (k == '=') {
      acc = _apply(_value());
      display = _format(acc);
      pending = null;
      fresh = true;
    } else {
      acc = _apply(_value());
      display = _format(acc);
      pending = k;
      fresh = true;
    }
    ui.set('d', text: display);
  }

  reset(ui) {
    acc = 0.0;
    pending = null;
    display = '0';
    fresh = true;
    ui.set('d', text: display);
  }

  // '0.' is a legal thing to have typed and an illegal thing to parse.
  _value() => double.parse(display, (_) => 0.0);

  _apply(double v) {
    if (pending == null) return v;
    if (pending == '+') return acc + v;
    if (pending == '-') return acc - v;
    if (pending == '*') return acc * v;
    if (pending == '/') return (v == 0.0) ? 0.0 : acc / v;
    return v;
  }

  _format(double v) {
    if (v == v.roundToDouble() && v.abs() < 1e15) return v.round().toString();
    return v.toString();
  }
}
