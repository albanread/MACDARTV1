// App: Temperature converter
//
// Three fields that are three views of ONE number: type in any of them and the
// other two follow. The field you are typing in is deliberately never written
// back to — setting a text field moves its caret to the end, which would fight
// you mid-number.
class Temperature {
  var c = 20.0;

  build(ui) {
    ui.title('Temperature');
    var row = (String id, String name, double y, String text) {
      ui.label('l' + id, text: name, frame: [8.0, y + 4.0, 90.0, 18.0]);
      ui.field(id, text: text, frame: [102.0, y, 130.0, 24.0], align: 'right',
               onText: (s) => from(id, s, ui));
    };
    row('c', 'Celsius', 8.0, _fmt(c));
    row('f', 'Fahrenheit', 40.0, _fmt(c * 9.0 / 5.0 + 32.0));
    row('k', 'Kelvin', 72.0, _fmt(c + 273.15));

    var preset = (String id, String name, double x, double v) {
      ui.button(id, title: name, frame: [x, 112.0, 104.0, 28.0],
                onClick: (_) { c = v; showAll(ui, null); });
    };
    preset('pf', 'Freezing', 8.0, 0.0);
    preset('pb', 'Boiling', 118.0, 100.0);
    preset('pk', 'Body', 228.0, 36.8);
    ui.label('note', text: 'type in any field — the other two follow',
             frame: [8.0, 152.0, 340.0, 18.0]);
  }

  from(String which, String s, ui) {
    var v = double.parse(s, (_) => null);
    if (v == null) return;                 // mid-typing ("-", "1.") — wait
    if (which == 'c') c = v;
    else if (which == 'f') c = (v - 32.0) * 5.0 / 9.0;
    else c = v - 273.15;
    showAll(ui, which);
  }

  showAll(ui, String except) {
    if (except != 'c') ui.set('c', text: _fmt(c));
    if (except != 'f') ui.set('f', text: _fmt(c * 9.0 / 5.0 + 32.0));
    if (except != 'k') ui.set('k', text: _fmt(c + 273.15));
  }

  _fmt(double v) {
    var r = (v * 100.0).round() / 100.0;
    if (r == r.roundToDouble()) return r.round().toString();
    return r.toString();
  }
}
