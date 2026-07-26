// Demo: Analog clock — a face, three hands, one Timer
import 'dart:async';
import 'dart:isolate';
import 'dart:math';

main(List args, SendPort ui) {
  var w = double.parse(args[0]), h = double.parse(args[1]);
  var cx = w / 2, cy = h / 2, r = h / 2 - 30.0;

  List hand(double frac, double len, double width, double cr, double cg, double cb) {
    var a = frac * 2 * PI - PI / 2;
    return <dynamic>['line', cx, cy, cx + cos(a) * len, cy + sin(a) * len,
                     cr, cg, cb, width];
  }

  String two(int n) => n.toString().padLeft(2, '0');

  void tick() {
    var now = new DateTime.now();
    var cmds = <List>[];
    cmds.add(<dynamic>['clear', 0.08, 0.08, 0.11]);
    cmds.add(<dynamic>['oval', cx - r, cy - r, r * 2, r * 2, 0.85, 0.85, 0.92, false]);
    for (var i = 0; i < 60; i++) {
      var a = i / 60 * 2 * PI;
      var inner = (i % 5 == 0) ? r - 12.0 : r - 5.0;
      var wgt = (i % 5 == 0) ? 2.0 : 1.0;
      cmds.add(<dynamic>['line', cx + cos(a) * inner, cy + sin(a) * inner,
                         cx + cos(a) * r, cy + sin(a) * r, 0.55, 0.58, 0.68, wgt]);
    }
    cmds.add(hand(((now.hour % 12) + now.minute / 60.0) / 12.0, r * 0.50, 5.0, 0.90, 0.90, 0.95));
    cmds.add(hand((now.minute + now.second / 60.0) / 60.0,      r * 0.74, 3.0, 0.90, 0.90, 0.95));
    cmds.add(hand(now.second / 60.0,                            r * 0.88, 1.2, 0.95, 0.32, 0.32));
    cmds.add(<dynamic>['oval', cx - 4.0, cy - 4.0, 8.0, 8.0, 0.95, 0.32, 0.32, true]);
    cmds.add(<dynamic>['text', cx - 32.0, cy + r + 2.0,
                       two(now.hour) + ':' + two(now.minute) + ':' + two(now.second),
                       13.0, 0.75, 0.78, 0.86]);
    ui.send(['draw', cmds]);
  }

  ui.send(['status', 'ticking once a second in this demo isolate']);
  tick();
  new Timer.periodic(const Duration(seconds: 1), (t) => tick());
}
