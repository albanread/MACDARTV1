// dart:cocoa — MACDART's native macOS bridge.
//
// A bootstrap library (wired like dart:io). Phase 1 proved the pipeline with a
// POSIX call and a typed NSString round-trip; Phase 2/3 adds the GENERAL
// dynamic send: `noSuchMethod` forwards any Dart method call to objc_msgSend,
// with the method's AAPCS64 argument/return marshaling driven by the runtime
// @encode. See MACDART/COCOA_PLAN.md.
library dart.cocoa;

import 'dart:mirrors' show MirrorSystem;

/// The process id — a POSIX FFI smoke test (getpid()).
int processId() native "Cocoa_getpid";

/// Evaluate [src] as a Dart expression against the workspace's live library and
/// return its `toString()`, or an `"ERR: ..."` string on failure. The heart of
/// the live workspace's Do-it/Print-it (see WORKSPACE_PLAN.md §5). `src` must be
/// a single expression; wrap statements as an immediately-invoked closure
/// `(){ ... }()`. (Temporary home in dart:cocoa; moves to dart:workspace.)
String wsEval(String src) native "Workspace_eval";

/// Hot-reload the workspace's sources after rewriting its scratch file: changed
/// method bodies go live on existing instances, and structural class changes
/// MORPH live instances (same-named fields preserved, new fields initialized).
/// Returns `""` on success or `"ERR: ..."` if the reload was cancelled (an
/// unsafe change → restart the isolate). See WORKSPACE_PLAN.md §5.
String wsReload() native "Workspace_reload";

/// This isolate's live VM counters, for the workspace toolbar:
/// `[newUsed, newCapacity, oldUsed, oldCapacity, scavenges, markSweeps,
///   functionsCompiled, functionsOptimized, codeBytes]` — bytes and counts.
/// The last three are 0 unless the VM was started with `--compiler_stats`
/// (the counters are compiled behind that flag), and there is deliberately no
/// allocation rate: this VM keeps no cumulative allocation counter, so one
/// could only be guessed.
List wsVmStats() native "Workspace_vmStats";

/// Ask the HOST to hot-reload this (UI) isolate from its source on disk.
/// Returns immediately: the reload happens at the top of the host's pump, with
/// no Dart frames live — an isolate cannot safely rewrite the code it is
/// standing in. Poll [wsUiReloadStatus] for the outcome.
String wsRequestUiReload() native "Workspace_requestUiReload";

/// The outcome of the last [wsRequestUiReload]: "" if none yet, "ok", or
/// "ERR: ..." if the reload was cancelled (in which case the running code is
/// untouched — ReloadSources is atomic). Reading it clears it.
String wsUiReloadStatus() native "Workspace_uiReloadStatus";

/// Tell the host the window is up. Before this, the host treats a UI-isolate
/// error as fatal — a workspace that failed to load would otherwise sit there as
/// a running process with no window and no control socket.
String wsUiReady() native "Workspace_uiReady";

// --- Low-level natives ------------------------------------------------------
int _nsStringFromCString(String s) native "Cocoa_nsStringFromCString";
int _nsStringLength(int handle) native "Cocoa_nsStringLength";
String _nsStringUtf8(int handle) native "Cocoa_nsStringUtf8";

int _getClass(String name) native "Cocoa_getClass";
/// The general dynamic send: [receiver] a Cocoa, [selector] like
/// "colorWithRed:...:", [args] the ordered arguments. Returns a Cocoa (for an
/// object result — retained, released on GC), a String (char*), an int
/// (integer id), a double, a List of numbers (struct), or null (void).
dynamic _send(Cocoa receiver, String selector, List args) native "Cocoa_send";
int _retain(int handle) native "Cocoa_retain";
void _release(int handle) native "Cocoa_release";
int _poolPush() native "Cocoa_poolPush";
void _poolPop(int token) native "Cocoa_poolPop";

/// `[wraps, releases]` — retain-on-wrap vs release-on-GC counts. A gap that
/// never settles across GCs indicates a leak.
List cocoaStats() native "Cocoa_stats";

/// Run [body] inside an Objective-C autorelease pool. Any autoreleased
/// temporaries created while it runs (bridged NSStrings, `+0` method results)
/// are released when it returns — the scoped equivalent of MACVM's `poolDo:`.
void autoreleasePool(void body()) {
  var token = _poolPush();
  try {
    body();
  } finally {
    _poolPop(token);
  }
}

// --- Reverse callbacks (target-action, delegates, table sources) ------------
// AppKit controls call back into Dart. A ticket keys the Dart handler; the
// native side stores only the ticket (never a Dart handle). See cocoa_callbacks.mm.

/// A control-action handler; [sender] is the control that fired.
typedef void CocoaAction(Cocoa sender);
typedef int RowCountFn();
typedef String CellFn(int row);
typedef void SelectFn(int row);

class _TableSource {
  final RowCountFn rowCount;
  final CellFn cellAt;
  final SelectFn onSelect;
  _TableSource(this.rowCount, this.cellAt, this.onSelect);
}

int _cbNext = 1;
final Map<int, dynamic> _cbHandlers = <int, dynamic>{};   // CocoaAction | _TableSource
bool _cbDispatchRegistered = false;

void _registerCallbackDispatch(Function f) native "Cocoa_registerCallbackDispatch";
int _makeActionTarget(int ticket) native "Cocoa_makeActionTarget";
void _wireAction(int control, int target) native "Cocoa_wireAction";

// The single entry every native callback funnels through (see cocoa_callbacks.mm).
// kind: 0 action, 1 textDidChange, 2 tableRowCount, 3 tableValue(arg=row),
// 4 tableSelect(arg=row). Returns void for 0/1/4, an int for 2, a String for 3.
dynamic _cocoaDispatch(int ticket, int kind, int arg) {
  var h = _cbHandlers[ticket];
  if (h == null) return null;
  if (kind <= 1) { if (h is CocoaAction) h(new Cocoa._adopt(arg)); return null; }
  if (h is _TableSource) {
    if (kind == 2) return h.rowCount();
    if (kind == 3) return h.cellAt(arg);
    if (kind == 4) { h.onSelect(arg); return null; }
  }
  return null;
}

void _ensureDispatch() {
  if (!_cbDispatchRegistered) {
    _registerCallbackDispatch(_cocoaDispatch);
    _cbDispatchRegistered = true;
  }
}

/// Forget every callback registered so far. Called when the UI tears its view
/// tree down: the ObjC targets outlive it (AppKit holds them unretained and we
/// never owned a reference), but their tickets are gone, so a stale one now
/// fails closed in [_cocoaDispatch] instead of firing into a dead handler.
void disposeCallbacks() {
  _cbHandlers.clear();
}

/// Wire [control]'s action to [fn] (e.g. an `NSButton`'s click). Returns the
/// target object; AppKit holds targets weakly, so keep a reference to it alive.
Cocoa onAction(Cocoa control, CocoaAction fn) {
  _ensureDispatch();
  var ticket = _cbNext++;
  _cbHandlers[ticket] = fn;
  var target = new Cocoa._adopt(_makeActionTarget(ticket));
  _wireAction(control.handle, target.handle);
  return target;
}

/// Wire [textView]'s text-change notification (`textDidChange:`) to [fn] — e.g.
/// to re-highlight as the user types. Keep the returned delegate alive.
Cocoa onTextChange(Cocoa textView, CocoaAction fn) {
  _ensureDispatch();
  var ticket = _cbNext++;
  _cbHandlers[ticket] = fn;
  var target = new Cocoa._adopt(_makeActionTarget(ticket));
  textView.setDelegate(target);
  return target;
}

/// Make [tableView] data-driven: [rowCount] rows, [cellAt] gives a row's text,
/// [onSelect] fires when the selection changes. Returns the source object — keep
/// it alive. Call `tableView.reloadData()` after the underlying data changes.
Cocoa onTable(Cocoa tableView, RowCountFn rowCount, CellFn cellAt, SelectFn onSelect) {
  _ensureDispatch();
  var ticket = _cbNext++;
  _cbHandlers[ticket] = new _TableSource(rowCount, cellAt, onSelect);
  var target = new Cocoa._adopt(_makeActionTarget(ticket));
  tableView.setDataSource(target);
  tableView.setDelegate(target);
  return target;
}

void _setSelectorAction(int control, String selector, int target)
    native "Cocoa_setSelectorAction";

/// Point [control] at a STANDARD Cocoa selector by name (e.g. "cut:"). With no
/// [target] the action goes to nil, so AppKit routes it down the responder chain
/// to whatever has focus — which is how Cut/Copy/Paste/Undo reach the focused
/// text view. A SEL cannot be built from Dart, hence the native.
void setSelectorAction(Cocoa control, String selector, [Cocoa target]) {
  _setSelectorAction(control.handle, selector, target == null ? 0 : target.handle);
}

// --- gamestate key poller ----------------------------------------------------
void _keyWatch() native "Cocoa_keyWatch";
void _keyCapture(int on) native "Cocoa_keyCapture";
List _keyState() native "Cocoa_keyState";

/// Install the app-wide key monitor (idempotent; call once at boot). From then
/// on [keyState] answers with what is held down RIGHT NOW.
void keyWatch() => _keyWatch();

/// While on, plain key events are consumed (no beep, no typing into views) so
/// a game owns the keyboard; Command shortcuts always pass through. Toggling
/// clears the held-key board.
void keyCapture(bool on) => _keyCapture(on ? 1 : 0);

/// `[downKeycodes, modifierFlags]` — the gamestate at the instant of the call:
/// a `List<int>` of macOS virtual keycodes currently held (left 123, right 124,
/// down 125, up 126, space 49, A 0, D 2, …) and the NSEvent modifier mask.
List keyState() => _keyState();

// --- game pane (GAMEPANE_PLAN.md) --------------------------------------------
int _gpOpen(int w, int h, int worldW, int worldH) native "Cocoa_gpOpen";
void _gpClose() native "Cocoa_gpClose";
dynamic _gpApply(List cmds) native "Cocoa_gpApply";
String _gpSnap(String path) native "Cocoa_gpSnap";
List _gpStat() native "Cocoa_gpStat";

/// Open (or re-open at a new size) the Metal game pane and return its NSView
/// to embed. Logical resolution [w]x[h] (the layer upscales, nearest); the
/// indexed world is [worldW]x[worldH] (clamped up to the viewport).
Cocoa gpOpen(int w, int h, int worldW, int worldH) =>
    new Cocoa._adopt(_gpOpen(w, h, worldW, worldH));

/// Tear the engine's panes down (the view survives for reuse).
void gpClose() => _gpClose();

/// Apply one frame's gp* command list and present it. Returns null, or the
/// first error as a String (the frame is still applied best-effort).
dynamic gpApply(List cmds) => _gpApply(cmds);

/// Write the last-rendered frame (the offscreen texture — the honest pixels
/// a window snapshot cannot see) as a PNG. "" on success, else the error.
String gpSnap(String path) => _gpSnap(path);

/// `[open, framesPresented, logicalW, logicalH]`.
List gpStat() => _gpStat();

void _setSplitMinSize(int splitView, double minSize) native "Cocoa_setSplitMinSize";

/// Stop the user dragging any pane of [splitView] below [minSize] points.
/// Enforced by a native delegate: AppKit asks on every frame of a drag, so this
/// must not round-trip into Dart.
void setSplitMinSize(Cocoa splitView, double minSize) {
  _setSplitMinSize(splitView.handle, minSize);
}

void _applySpans(int textStorage, List spans) native "Cocoa_applySpans";

/// Colour [textView] with syntax-highlight runs: a flat `[start, len, kind, …]`
/// list (kind: 1 keyword, 2 string, 3 comment, 4 number, 5 type, else default).
/// Attribute-only — the caret never moves. Offsets are UTF-16 units (Dart string
/// indices), which is exactly what `NSRange` wants.
void applySpans(Cocoa textView, List spans) {
  _applySpans(textView.textStorage().handle, spans);
}

// --- SQLite image store (macOS libsqlite3) ----------------------------------
int _sqlOpen(String path) native "Sqlite_open";
void _sqlClose(int db) native "Sqlite_close";
String _sqlExec(int db, String sql, List params) native "Sqlite_exec";
List _sqlQuery(int db, String sql, List params) native "Sqlite_query";

/// A minimal SQLite handle. Parameterised (`?`) queries only — never
/// string-concatenate SQL. The workspace's "image" (user-app source) lives here.
class Db {
  final int _h;
  const Db._(this._h);
  factory Db.open(String path) => new Db._(_sqlOpen(path));
  bool get isOpen => _h != 0;
  /// A non-SELECT statement (CREATE/INSERT/UPDATE/DELETE). "" ok, else "ERR: …".
  String exec(String sql, [List params = const []]) => _sqlExec(_h, sql, params);
  /// A SELECT — rows as a `List<List<String>>` (null on prepare error).
  List query(String sql, [List params = const []]) => _sqlQuery(_h, sql, params);
  void close() => _sqlClose(_h);
}

/// A minimal typed NSString wrapper (Phase 1; still handy for strings).
class NSString {
  final int handle;
  const NSString.fromHandle(this.handle);
  factory NSString(String s) => new NSString.fromHandle(_nsStringFromCString(s));
  int get length => _nsStringLength(handle);
  String toUtf8() => _nsStringUtf8(handle);
  String toString() => toUtf8();
}

/// A dynamically-dispatched Objective-C object.
///
/// Any method you call is forwarded to `objc_msgSend` via [noSuchMethod]. Dart
/// named arguments become the ObjC keyword-selector parts, so this:
///
///     final c = NSColor.colorWithRed(1.0, green: 0.0, blue: 0.0, alpha: 1.0);
///
/// sends `[NSColor colorWithRed:1.0 green:0.0 blue:0.0 alpha:1.0]`. Object
/// results come back as raw id handles (ints) — wrap them in a [Cocoa] to keep
/// sending; struct results (NSRect/NSRange) come back as a `List` of numbers.
class Cocoa {
  int _handle;      // the ObjC id; 0 once poisoned (consumed by init) or nil
  int _wph = 0;     // native weak-persistent-handle (release finalizer); 0 = none

  // Only the runtime constructs Cocoa objects: the native _send wraps object
  // results here (adding retain + a release finalizer for non-class objects),
  // and Cocoa.cls wraps a class (no finalizer). `_adopt` never retains — the
  // native owns that policy.
  Cocoa._adopt(this._handle);

  /// Look up a class by name — the receiver for class methods (not finalized).
  static Cocoa cls(String name) => new Cocoa._adopt(_getClass(name));

  /// The raw ObjC id (0 if nil / released).
  int get handle => _handle;
  bool get isNil => _handle == 0;

  /// Send [selector] with [args] explicitly (bypassing noSuchMethod).
  dynamic send(String selector, [List args = const []]) =>
      _send(this, selector, _unwrap(args));

  dynamic noSuchMethod(Invocation inv) {
    var name = MirrorSystem.getName(inv.memberName);
    var pos = inv.positionalArguments;
    var named = inv.namedArguments;
    String selector;
    var args = <dynamic>[];

    if (inv.isGetter || (pos.isEmpty && named.isEmpty)) {
      // A getter or a 0-argument method: bare selector, no colon.
      //   obj.frame     -> [obj frame]
      //   obj.alloc()   -> [obj alloc]
      selector = name;
    } else {
      // A keyword message. The first positional arg belongs to the leading
      // keyword; each named argument (now in source order — see the VM's
      // invocation_mirror_patch.dart) adds another `label:` keyword:
      //   obj.stringWithUTF8String(s)                  -> [obj stringWithUTF8String:s]
      //   NSColor.colorWithRed(r, green:g, blue:b, alpha:a)
      //     -> [NSColor colorWithRed:r green:g blue:b alpha:a]
      selector = name + ':';
      args.addAll(pos);
      named.forEach((label, value) {
        selector += MirrorSystem.getName(label) + ':';
        args.add(value);
      });
    }
    return _send(this, selector, _unwrap(args));
  }

  static List _unwrap(List args) {
    // Let callers pass Cocoa objects as arguments; send their id handles.
    var out = new List(args.length);
    for (var i = 0; i < args.length; i++) {
      var a = args[i];
      out[i] = (a is Cocoa) ? a.handle : a;
    }
    return out;
  }

  String toString() => 'Cocoa(0x${handle.toRadixString(16)})';
}
