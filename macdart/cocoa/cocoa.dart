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

// --- Reverse callbacks (target-action) --------------------------------------
// AppKit controls call back into Dart. A ticket keys the Dart handler; the
// native side stores only the ticket (never a Dart handle). See cocoa_callbacks.mm.

/// A control-action handler; [sender] is the control that fired.
typedef void CocoaAction(Cocoa sender);

int _cbNext = 1;
final Map<int, CocoaAction> _cbHandlers = <int, CocoaAction>{};
bool _cbDispatchRegistered = false;

void _registerCallbackDispatch(Function f) native "Cocoa_registerCallbackDispatch";
int _makeActionTarget(int ticket) native "Cocoa_makeActionTarget";
void _wireAction(int control, int target) native "Cocoa_wireAction";

// The single entry every native callback funnels through (see cocoa_callbacks.mm).
void _cocoaDispatch(int ticket, int sender) {
  var fn = _cbHandlers[ticket];
  if (fn != null) fn(new Cocoa._adopt(sender));
}

/// Wire [control]'s action to [fn] (e.g. an `NSButton`'s click). Returns the
/// target object; AppKit holds targets weakly, so keep a reference to it alive.
Cocoa onAction(Cocoa control, CocoaAction fn) {
  if (!_cbDispatchRegistered) {
    _registerCallbackDispatch(_cocoaDispatch);
    _cbDispatchRegistered = true;
  }
  var ticket = _cbNext++;
  _cbHandlers[ticket] = fn;
  var target = new Cocoa._adopt(_makeActionTarget(ticket));
  _wireAction(control.handle, target.handle);
  return target;
}

/// Wire [textView]'s text-change notification (`textDidChange:`) to [fn] — e.g.
/// to re-highlight as the user types. Returns the delegate; AppKit holds it
/// weakly, so keep a reference alive.
Cocoa onTextChange(Cocoa textView, CocoaAction fn) {
  if (!_cbDispatchRegistered) {
    _registerCallbackDispatch(_cocoaDispatch);
    _cbDispatchRegistered = true;
  }
  var ticket = _cbNext++;
  _cbHandlers[ticket] = fn;
  var target = new Cocoa._adopt(_makeActionTarget(ticket));
  textView.setDelegate(target);
  return target;
}

void _applySpans(int textStorage, List spans) native "Cocoa_applySpans";

/// Colour [textView] with syntax-highlight runs: a flat `[start, len, kind, …]`
/// list (kind: 1 keyword, 2 string, 3 comment, 4 number, 5 type, else default).
/// Attribute-only — the caret never moves. Offsets are UTF-16 units (Dart string
/// indices), which is exactly what `NSRange` wants.
void applySpans(Cocoa textView, List spans) {
  _applySpans(textView.textStorage().handle, spans);
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
