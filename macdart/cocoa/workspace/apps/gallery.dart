// App: Control gallery
//
// One of every widget the App pane knows, wired to react — the live reference
// for what a Dart app can put on its surface. THREE tabs (laid out with the
// column helper): Inputs (a slider driving a progress bar, a readout, and a
// custom-drawn canvas bar in the popup's colour; a checkbox enabling the
// button; a popup and password echoing to a status line), Data (a
// scrolling list reporting its selection), and Form (a scroll container holding
// a 12-field form taller than the tab). Everything is one class with a build(ui).
class Gallery {
  var level = 0.4;
  var armed = true;
  var colour = 'Amber';
  var picked = '';

  build(ui) {
    ui.title('Control gallery');

    // outputs, on the surface itself (above the tabs)
    ui.label('lL', text: 'Level', frame: [8.0, 8.0, 60.0, 18.0]);
    ui.progress('bar', frame: [72.0, 8.0, 180.0, 16.0], min: 0.0, max: 1.0, value: level);
    ui.label('read', text: _pct(level), frame: [258.0, 8.0, 60.0, 18.0]);
    ui.label('status', text: 'ready', frame: [8.0, 32.0, 420.0, 18.0]);

    ui.tabs('tabs', items: ['Inputs', 'Data', 'Form'], frame: [8.0, 56.0, 420.0, 288.0]);

    // --- tab 0: the interactive controls, laid out in a column ---------------
    ui.tab('tabs', 0);
    var rows = ui.column(90.0, 16.0, 190.0, 24.0, 5, gap: 12.0);
    label(ui, 'lS', 'Slider', rows[0]);
    ui.slider('sld', frame: rows[0], min: 0.0, max: 1.0, value: level,
              onSlide: (v) { level = v; showLevel(ui); });
    label(ui, 'lC', 'Checkbox', rows[1]);
    ui.checkbox('cb', label: 'arm the button', frame: rows[1], value: armed,
                onToggle: (on) { armed = on; ui.set('go', enabled: on);
                                 status(ui, 'armed: ' + on.toString()); });
    label(ui, 'lP', 'Popup', rows[2]);
    ui.popup('pop', items: ['Amber', 'Green', 'Cyan', 'Magenta'], selected: colour,
             frame: rows[2], onSelect: (c) { colour = c; status(ui, 'colour: ' + c); drawCanvas(ui); });
    label(ui, 'lPw', 'Password', rows[3]);
    ui.secure('pw', frame: rows[3],
              onText: (s) => status(ui, 'password: ' + s.length.toString() + ' chars'));
    ui.button('go', title: 'Fire', frame: rows[4], enabled: armed,
              onClick: (_) => status(ui, 'fired at level ' + _pct(level) + ' (' + colour + ')'));
    // a canvas the slider fills, in the popup's colour — custom drawing beside
    // the native controls, on the same surface
    ui.canvas('cv', frame: [12.0, 198.0, 380.0, 40.0], bg: [0.12, 0.12, 0.14]);

    // --- tab 1: a scrolling list --------------------------------------------
    ui.tab('tabs', 1);
    ui.label('lLi', text: 'Pick a planet:', frame: [12.0, 12.0, 200.0, 18.0]);
    ui.list('planets',
            items: ['Mercury', 'Venus', 'Earth', 'Mars', 'Jupiter', 'Saturn', 'Uranus', 'Neptune'],
            frame: [12.0, 36.0, 200.0, 190.0],
            onSelect: (name) { picked = name; status(ui, 'picked: ' + name); });

    // --- tab 2: a scroll container holding a form taller than the tab --------
    ui.tab('tabs', 2);
    ui.scroll('form', frame: [8.0, 8.0, 400.0, 232.0], width: 380.0, height: 560.0);
    ui.into('form');
    var fr = ui.column(96.0, 12.0, 260.0, 24.0, 12, gap: 14.0);
    var names = ['Name', 'Street', 'City', 'Region', 'Postcode', 'Country',
                 'Phone', 'Email', 'Company', 'Role', 'Notes', 'Referrer'];
    for (var i = 0; i < names.length; i++) {
      ui.label('fl' + i.toString(), text: names[i], frame: [8.0, fr[i][1] + 3.0, 84.0, 18.0]);
      ui.field('ff' + i.toString(), frame: fr[i]);
    }

    ui.pane();                          // done routing into tabs
    showLevel(ui);
  }

  label(ui, String id, String name, List rowFrame) {
    ui.label(id, text: name, frame: [12.0, rowFrame[1] + 3.0, 72.0, 18.0]);
  }

  showLevel(ui) {
    ui.set('bar', value: level);
    ui.set('read', text: _pct(level));
    drawCanvas(ui);
  }

  // Custom drawing: wipe, draw a filled bar proportional to level in the
  // popup's colour, and label it — the same op vocabulary the demos use.
  drawCanvas(ui) {
    var rgb = _rgb(colour);
    ui.draw('cv', [
      ['clear', 0.12, 0.12, 0.14],
      ['rect', 6.0, 6.0, (368.0 * level), 28.0, rgb[0], rgb[1], rgb[2], true],
      ['text', 12.0, 9.0, _pct(level) + '  ' + colour, 15.0, 1.0, 1.0, 1.0],
    ]);
  }

  _rgb(String name) {
    if (name == 'Green') return [0.31, 0.78, 0.47];
    if (name == 'Cyan') return [0.30, 0.78, 0.86];
    if (name == 'Magenta') return [0.86, 0.35, 0.70];
    return [0.94, 0.62, 0.24];               // Amber
  }

  status(ui, String s) { ui.set('status', text: s); }

  _pct(double v) => (v * 100.0).round().toString() + '%';
}
