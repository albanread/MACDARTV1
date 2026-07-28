// App: Stopwatch
//
// The app that proves the push channel. Everything else here reacts to a click
// — a message arrives, the app answers, the reply carries the new widget state.
// This one has nothing to answer: a Timer fires inside the language isolate and
// the app pushes an update on its own, which is exactly why the UI isolate
// keeps its port open after the handshake (see spawnLanguage).
//
// `stop()` is the optional teardown hook: without it the Timer would keep
// ticking against a surface nobody can see after you press Stop App.
class Chrono {
  var watch = new Stopwatch();
  var ticker;
  var laps = <String>[];

  build(ui) {
    ui.title('Stopwatch');
    ui.label('t', text: _shown(), frame: [8.0, 8.0, 300.0, 34.0]);
    ui.button('go', title: watch.isRunning ? 'Stop' : 'Start',
              frame: [8.0, 50.0, 90.0, 30.0], onClick: (_) => toggle(ui));
    ui.button('lap', title: 'Lap', frame: [104.0, 50.0, 70.0, 30.0],
              onClick: (_) => lap(ui));
    ui.button('rst', title: 'Reset', frame: [180.0, 50.0, 80.0, 30.0],
              onClick: (_) => reset(ui));
    for (var i = 0; i < 5; i++) {
      ui.label('lap' + i.toString(),
               text: i < laps.length ? laps[i] : '',
               frame: [8.0, 92.0 + i * 20.0, 300.0, 18.0]);
    }
    if (watch.isRunning) _startTicking(ui);
  }

  toggle(ui) {
    if (watch.isRunning) {
      watch.stop();
      stop();                              // no point ticking while stopped
    } else {
      watch.start();
      _startTicking(ui);
    }
    ui.set('go', title: watch.isRunning ? 'Stop' : 'Start');
    ui.set('t', text: _shown());
  }

  lap(ui) {
    if (laps.length >= 5) laps.removeAt(0);
    laps.add('lap ' + (laps.length + 1).toString() + '   ' + _shown());
    for (var i = 0; i < 5; i++) {
      ui.set('lap' + i.toString(), text: i < laps.length ? laps[i] : '');
    }
  }

  reset(ui) {
    watch.reset();
    laps = <String>[];
    ui.set('t', text: _shown());
    for (var i = 0; i < 5; i++) ui.set('lap' + i.toString(), text: '');
  }

  _startTicking(ui) {
    stop();
    // No event to answer: each tick pushes on its own.
    ticker = new Timer.periodic(const Duration(milliseconds: 50), (t) {
      ui.set('t', text: _shown());
    });
  }

  /// Optional lifecycle hook — the workspace calls it when the app is stopped.
  stop() {
    if (ticker != null) { ticker.cancel(); ticker = null; }
  }

  _shown() {
    var ms = watch.elapsedMilliseconds;
    var m = ms ~/ 60000;
    var s = (ms ~/ 1000) % 60;
    var h = (ms % 1000) ~/ 10;
    return _two(m) + ':' + _two(s) + '.' + _two(h);
  }

  _two(int v) => v < 10 ? '0' + v.toString() : v.toString();
}
