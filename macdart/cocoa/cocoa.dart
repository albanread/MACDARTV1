// dart:cocoa — MACDART's native macOS bridge (Phase 1).
//
// A bootstrap library (wired like dart:io) whose `native` functions call into
// the ObjC runtime via the VM. Phase 1 proves the pipeline end-to-end: a POSIX
// call and a real NSString round-trip. The general dynamic send + noSuchMethod
// ergonomic layer arrives in later phases (see MACDART/COCOA_PLAN.md).
library dart.cocoa;

/// The process id — a POSIX FFI smoke test (getpid()).
int processId() native "Cocoa_getpid";

// --- Phase-1 NSString round-trip (typed sends; validates class/sel/msgSend) --
int _nsStringFromCString(String s) native "Cocoa_nsStringFromCString";
int _nsStringLength(int handle) native "Cocoa_nsStringLength";
String _nsStringUtf8(int handle) native "Cocoa_nsStringUtf8";

/// A minimal NSString wrapper over a retained ObjC id (held as an int handle).
/// Phase 1 keeps this hand-written; later phases replace it with a noSuchMethod
/// proxy so any selector works without a per-method binding.
class NSString {
  final int handle;
  const NSString.fromHandle(this.handle);
  factory NSString(String s) => new NSString.fromHandle(_nsStringFromCString(s));

  /// -[NSString length]
  int get length => _nsStringLength(handle);

  /// -[NSString UTF8String] back to a Dart string.
  String toUtf8() => _nsStringUtf8(handle);

  String toString() => toUtf8();
}
