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

// --- Low-level natives ------------------------------------------------------
int _nsStringFromCString(String s) native "Cocoa_nsStringFromCString";
int _nsStringLength(int handle) native "Cocoa_nsStringLength";
String _nsStringUtf8(int handle) native "Cocoa_nsStringUtf8";

int _getClass(String name) native "Cocoa_getClass";
/// The general dynamic send: [target] id, [selector] like "colorWithRed:...:",
/// [args] the ordered arguments. Returns int (id/integer), double, a List of
/// numbers (struct), or null (void), per the method's return type.
dynamic _send(int target, String selector, List args) native "Cocoa_send";
int _retain(int handle) native "Cocoa_retain";
void _release(int handle) native "Cocoa_release";
int _poolPush() native "Cocoa_poolPush";
void _poolPop(int token) native "Cocoa_poolPop";

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
  final int handle;
  Cocoa(this.handle);

  /// Look up a class by name — the receiver for class methods.
  static Cocoa cls(String name) => new Cocoa(_getClass(name));

  bool get isNil => handle == 0;

  /// Send [selector] with [args] explicitly (bypassing noSuchMethod).
  dynamic send(String selector, [List args = const []]) =>
      _send(handle, selector, _unwrap(args));

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
    return _send(handle, selector, _unwrap(args));
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
