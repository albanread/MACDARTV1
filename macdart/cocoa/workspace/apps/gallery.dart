// App: Control gallery
//
// One of every widget the App pane knows, wired to react — the live reference
// for what a Dart app can put on its surface. A slider drives a progress bar
// and a readout; a checkbox enables/disables the button; a popup and a password
// field echo into a status line. Everything is one class with a build(ui).
class Gallery {
  var level = 0.4;
  var armed = true;
  var colour = 'Amber';
  var secret = '';

  build(ui) {
    ui.title('Control gallery');

    ui.box('gInput', title: 'Inputs', frame: [8.0, 96.0, 300.0, 260.0]);

    ui.label('lS', text: 'Slider', frame: [20.0, 320.0, 70.0, 18.0]);
    ui.slider('sld', frame: [92.0, 318.0, 180.0, 22.0], min: 0.0, max: 1.0,
              value: level, onSlide: (v) { level = v; showLevel(ui); });

    ui.label('lC', text: 'Checkbox', frame: [20.0, 288.0, 70.0, 18.0]);
    ui.checkbox('cb', label: 'arm the button', frame: [92.0, 286.0, 180.0, 20.0],
                value: armed, onToggle: (on) { armed = on; ui.set('go', enabled: on);
                                               status(ui, 'armed: ' + on.toString()); });

    ui.label('lP', text: 'Popup', frame: [20.0, 256.0, 70.0, 18.0]);
    ui.popup('pop', items: ['Amber', 'Green', 'Cyan', 'Magenta'], selected: colour,
             frame: [92.0, 254.0, 140.0, 24.0],
             onSelect: (c) { colour = c; status(ui, 'colour: ' + c); });

    ui.label('lPw', text: 'Password', frame: [20.0, 224.0, 70.0, 18.0]);
    ui.secure('pw', frame: [92.0, 222.0, 180.0, 24.0],
              onText: (s) { secret = s; status(ui, 'password: ' + s.length.toString() + ' chars'); });

    ui.button('go', title: 'Fire', frame: [92.0, 186.0, 90.0, 28.0], enabled: armed,
              onClick: (_) { status(ui, 'fired at level ' + _pct(level) + ' (' + colour + ')'); });

    // outputs
    ui.label('lL', text: 'Level', frame: [20.0, 60.0, 70.0, 18.0]);
    ui.progress('bar', frame: [92.0, 60.0, 180.0, 16.0], min: 0.0, max: 1.0, value: level);
    ui.label('read', text: _pct(level), frame: [278.0, 60.0, 60.0, 18.0]);

    ui.label('status', text: 'ready', frame: [8.0, 20.0, 400.0, 18.0]);
    showLevel(ui);
  }

  showLevel(ui) {
    ui.set('bar', value: level);
    ui.set('read', text: _pct(level));
  }

  status(ui, String s) { ui.set('status', text: s); }

  _pct(double v) => (v * 100.0).round().toString() + '%';
}
