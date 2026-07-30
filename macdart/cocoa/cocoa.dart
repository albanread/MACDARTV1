// dart:cocoa — MACDART's native macOS bridge.
//
// A bootstrap library (wired like dart:io). Phase 1 proved the pipeline with a
// POSIX call and a typed NSString round-trip; Phase 2/3 adds the GENERAL
// dynamic send: `noSuchMethod` forwards any Dart method call to objc_msgSend,
// with the method's AAPCS64 argument/return marshaling driven by the runtime
// @encode. See MACDART/COCOA_PLAN.md.
library dart.cocoa;

import 'dart:_internal' as internal show VMLibraryHooks;
import 'dart:math' as math show sqrt;
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

/// Load MACVM Smalltalk source [src] (a `.mst` string) into the live VM object
/// model: its classes/methods/fields are REGISTERED in the class table (method
/// bodies are not compiled yet — that is ST_PLAN.md Sprint 3). Returns a
/// human-readable summary of what was registered, or an `"ERR: ..."` string on
/// a lex/parse/finalize failure (never throws). Verification surface only:
/// registered ST methods must not be invoked until the Sprint 3 compiler hook.
String _stLoadRaw(String src) native "ST_load";
String _stRunRaw(String src) native "ST_run";
String _stLoadFreshRaw(String src) native "ST_loadFresh";

String stLoad(String src) { _stEnsureHooks(); return _stLoadRaw(src); }

/// Load AND run: like [stLoad], then execute the file's bare top-level
/// statements (MACVM do-it semantics — a corpus file's own driver lines).
String stRun(String src) { _stEnsureHooks(); return _stRunRaw(src); }

/// The workspace image reload: a FRESH layer — same-name classes fully
/// shadow earlier loads instead of being reopened in place, so a
/// re-Accepted class's edits always win (and no stale inline caches).
String stLoadFresh(String src) { _stEnsureHooks(); return _stLoadFreshRaw(src); }

/// Parse-only outline for the import slicer: List of [type, name, startLine]
/// per top-level item ('class'/'extend'/'extmethod'/'vardecl'/'stmt'), or an
/// "ERR: ..." String on a parse failure.
stOutline(String src) native "ST_outline";

/// Probe-mode class-side dispatch: answers [result] on a hit (even a nil
/// result), or null when the class has no such class-side method — WITHOUT
/// masking ST exceptions raised inside a found method (they propagate).
_stClassSendTry(type, String sel, List args) native "ST_classSendTry";

/// Probe-mode EXTENSION dispatch (Sprint 11c): the world image's core-class
/// extensions, tried by Object.noSuchMethod on any genuine miss.
_stExtSendTry(recv, String sel, List args) native "ST_extSendTry";

/// `x class` — the receiver's class VALUE (canonical Type; natives answer
/// their extension holder's Type when the world image is loaded).
stClassOf(r) native "ST_classOf";

/// Probe-mode instance dispatch: [result] on a hit, null on a MISS — never an
/// ApiError (an ApiError is not catchable by Dart try/catch; the print
/// protocol's printOn: fallback must degrade, not crash the Release GUI).
_stSendTry(recv, String sel, List args) native "ST_sendTry";

/// Lookup-only probe: does the receiver's class chain define the selector?
/// (No invoke, no prelude requirement — safe before any ST has loaded.)
bool _stHasMethod(recv, String sel) native "ST_hasMethod";

/// Public alias for the --with-st boot path (C++ enters via Dart_Invoke,
/// which cannot reach the private installer).
void stEnsureHooks() { _stEnsureHooks(); }

bool _stHooked = false;

/// Installed once, before the first ST load: lets _Type.noSuchMethod route a
/// send to a CLASS VALUE held in a variable into ST class-side dispatch, and
/// Object.noSuchMethod route misses on native receivers into the world
/// image's extension holders (Integer>>fib, ...).
void _stEnsureHooks() {
  if (_stHooked) return;
  _stHooked = true;
  // A class value first tries class-side dispatch; a miss then tries the
  // Behavior/Object extension holders (the world's reflective protocol)
  // with the Type itself as receiver.
  internal.VMLibraryHooks.stTypeNSM = (t, String sel, List args) {
    var r = _stClassSendTry(t, sel, args);
    if (r != null) return r;
    return _stExtSendTry(t, sel, args);
  };
  internal.VMLibraryHooks.stObjNSM = (r, String sel, List args) {
    var hit = _stExtSendTry(r, sel, args);
    if (hit != null) return hit;
    // Sprint 13: real doesNotUnderstand: — after the inherited protocol
    // (the extension holders) misses, a receiver whose chain defines
    // doesNotUnderstand: gets the send REIFIED as an STMessage (selector
    // un-mangled back to its keyword spelling). This is what the world's
    // ObjcRef passthrough and ObjcMainProxy are built on.
    if (_stHasMethod(r, 'doesNotUnderstand:')) {
      var stSel = sel.endsWith('_') ? sel.replaceAll('_', ':') : sel;
      var msg = stNew('STMessage');
      stSend(msg, 'setSelector:arguments:', [stSel, args]);
      return _stSendTry(r, 'doesNotUnderstand:', [msg]);
    }
    return null;
  };
}

/// Invoke a class-side (static) method [selector] on a loaded ST class
/// [className], passing [args], and return the result. The first call JIT-
/// compiles the ST method body through the Sprint 3 IL builder
/// (`st::BuildGraph`). E.g. `stInvokeStatic("Calc", "double:", [21])` → 42.
dynamic stInvokeStatic(String className, String selector, List args)
    native "ST_invokeStatic";

/// Allocate an instance of a loaded ST class [className] (ST_PLAN.md Sprint 5).
/// The class is member-finalized on demand; returns the new ST instance.
dynamic stNew(String className) native "ST_new";

/// Send instance method [selector] with [args] to an ST [receiver] (Sprint 5);
/// the first call lazily compiles the method body. Returns the result.
dynamic stSend(receiver, String selector, List args) native "ST_send";

// --- Smalltalk non-local return (ST_PLAN.md closures Stage C) ---------------
// A `^expr` inside a FIRST-CLASS closure returns from the closure's HOME
// method activation. The ST IL builder desugars it to stNlrThrow(home, value)
// where `home` is the home activation's Context object (unique per
// activation); the home method's body is wrapped in a catch that returns
// `value` when the carrier's home is ITS context, and rethrows otherwise. A
// carrier that reaches the top means the home frame already returned — the
// classic "block cannot return" error, reported as an unhandled _STNlr.
class _STNlr {
  var home;
  var value;
  _STNlr(this.home, this.value);
  String toString() => "Smalltalk non-local return: the block's home method"
      " has already returned (BlockContext>>cannotReturn)";
}

stNlrThrow(home, value) {
  throw new _STNlr(home, value);
}

stNlrHome(e) {
  if (e is _STNlr) return e.home;
  return false; // never identical to a Context: forces a rethrow
}

stNlrValue(e) {
  return e.value;
}

// --- Smalltalk exceptions (ST_PLAN.md Sprint 9) -----------------------------
// ST `signal` throws the exception INSTANCE inside an _STException carrier;
// `[..] on: Cls do: [:e | ..]` lowers to stOnDo(protected, type, handler) —
// ST closures are directly callable as Dart closures, so the whole protocol
// is ordinary Dart try/catch/finally. ensure: therefore runs during a
// non-local return (the _STNlr carrier passes through `finally`) — exact
// Smalltalk unwind semantics for free. _STNlr always rethrows: a `^` is not
// a Smalltalk exception and must never be caught by on:do:.
class _STException {
  var instance; // the ST exception object (an Exception subclass instance)
  _STException(this.instance);
  String toString() {
    var t = null;
    try {
      t = stSend(instance, 'messageText', []);
    } catch (_) {}
    return "Smalltalk exception: " + (t == null ? "(no message)" : t.toString());
  }
}

stSignal(instance) {
  throw new _STException(instance);
}

stOnDo(protected, type, handler) {
  try {
    return protected();
  } catch (e) {
    if (e is _STNlr) rethrow; // non-local ^ is not an exception
    if (e is _STException && stIsKindOf(e.instance, type)) {
      return handler(e.instance);
    }
    rethrow;
  }
}

stEnsure(protected, cleanup) {
  try {
    return protected();
  } finally {
    cleanup();
  }
}

stIfCurtailed(protected, cleanup) {
  try {
    return protected();
  } catch (e) {
    cleanup();
    rethrow;
  }
}

/// Is [obj]'s class the [type]'s class or one of its subclasses?
bool stIsKindOf(obj, type) native "ST_isKindOf";

// --- corpus-breadth helpers (ST_PLAN Sprint 11) -----------------------------
/// Class-side `self <sel>`: dispatch on the RECEIVING class (a Type value)
/// at runtime — walks the metaclass shadow chain; falls back to allocation
/// for new/basicNew and to create-and-signal for signal/signal:.
_stClassSend(type, String sel, List args) native "ST_classSend";
stClassSend0(t, sel) => _stClassSend(t, sel, []);
stClassSend1(t, sel, a) => _stClassSend(t, sel, [a]);
stClassSend2(t, sel, a, b) => _stClassSend(t, sel, [a, b]);
stClassSend3(t, sel, a, b, c) => _stClassSend(t, sel, [a, b, c]);
stClassSend4(t, sel, a, b, c, d) => _stClassSend(t, sel, [a, b, c, d]);
stClassSend5(t, sel, a, b, c, d, e) => _stClassSend(t, sel, [a, b, c, d, e]);

// Universal ST-protocol shims: bridged Dart receivers (List/Map/String) get
// direct semantics — including Smalltalk's 1-BASED indexing — and any other
// receiver falls back to real ST dispatch via stSend, so an ST class defining
// its own at:/size keeps working through the same selectors.
stNot(b) => b == true ? false : true;

/// value-family sends: a real closure invokes directly (the optimizer inlines
/// these helpers, restoring per-site monomorphic ICs); anything else — e.g. a
/// DeltaBlue Variable with its own `value` method — goes to ST dispatch.
stValue0(r) { if (r is Function) return r(); return stSend(r, 'value', []); }
stValue1(r, a) { if (r is Function) return r(a); return stSend(r, 'value:', [a]); }
stValue2(r, a, b) { if (r is Function) return r(a, b); return stSend(r, 'value:value:', [a, b]); }
stValue3(r, a, b, c) { if (r is Function) return r(a, b, c); return stSend(r, 'value:value:value:', [a, b, c]); }
stValue4(r, a, b, c, d) { if (r is Function) return r(a, b, c, d); return stSend(r, 'value:value:value:value:', [a, b, c, d]); }

/// ST `&`/`|`: Boolean non-short-circuit and/or (Dart 1.24 bool has no
/// operator&). Ints keep bitwise semantics; anything else -> ST dispatch.
stBoolAnd(a, b) {
  if (a is bool && b is bool) return a && b;
  if (a is int && b is int) return a & b;
  return stSend(a, '&', [b]);
}

stBoolOr(a, b) {
  if (a is bool && b is bool) return a || b;
  if (a is int && b is int) return a | b;
  return stSend(a, '|', [b]);
}

stAt1(c, k) {
  if (c is List) return c[k - 1]; // Smalltalk indexes from 1
  if (c is Map) return c[k];
  if (c is String) return c[k - 1]; // a Character = a 1-char string
  return stSend(c, 'at:', [k]);
}

stAtPut1(c, k, v) {
  if (c is List) { c[k - 1] = v; return v; }
  if (c is Map) { c[k] = v; return v; }
  return stSend(c, 'at:put:', [k, v]);
}

stSizeOf(c) {
  if (c is List || c is Map || c is String) return c.length;
  return stSend(c, 'size', []);
}

stAddU(c, x) {
  if (c is List) { c.add(x); return x; }   // ST add: answers the argument
  return stSend(c, 'add:', [x]);
}

stDo(c, f) {
  if (c is List) { for (var e in c) f(e); return c; }
  if (c is Map) { for (var v in c.values) f(v); return c; }
  return stSend(c, 'do:', [f]);
}

stIsEmptyU(c) {
  if (c is List || c is Map || c is String) return c.isEmpty;
  return stSend(c, 'isEmpty', []);
}

/// `self error: 'msg'` — construct and signal a prelude Error.
stError(recv, msg) {
  var e = stNew('Error');
  stSend(e, 'messageText:', [msg]);
  return stSignal(e);
}

/// `Smalltalk millisecondClock` — the corpus benchmark clock.
stMillisecondClock() => new DateTime.now().millisecondsSinceEpoch;

/// ST `/` is EXACT: int/int divides evenly to an int, else answers a world
/// Fraction (when 23_fraction is loaded; a plain double otherwise). The
/// world-presence probe is cached — no per-divide exception cost.
bool _stFractionKnown = false;
bool _stFractionPresent = false;
stDivide(a, b) {
  if (a is int && b is int && b != 0) {
    if (a % b == 0) return a ~/ b;
    if (!_stFractionKnown) {
      _stFractionKnown = true;
      try {
        stInvokeStatic('Fraction', 'numerator:denominator:', [1, 2]);
        _stFractionPresent = true;
      } catch (_) {
        _stFractionPresent = false;
      }
    }
    if (_stFractionPresent) {
      return stInvokeStatic('Fraction', 'numerator:denominator:', [a, b]);
    }
    return a / b;
  }
  if (a is num && b is num) return a / b;
  return stSend(a, '/', [b]);
}

// Numeric conversions/negation: Dart-num fast paths (the world kernel's
// versions are <primitive:>-backed and must never be reached via the NSM
// hook, whose ignored-pragma bodies would answer self).
stAsDouble(r) => r is num ? r.toDouble() : stSend(r, 'asDouble', []);
stTruncated(r) => r is num ? r.truncate() : stSend(r, 'truncated', []);
stRounded(r) => r is num ? r.round() : stSend(r, 'rounded', []);
stFloorU(r) => r is num ? r.floor() : stSend(r, 'floor', []);
stCeilingU(r) => r is num ? r.ceil() : stSend(r, 'ceiling', []);
stNegated(r) => r is num ? -r : stSend(r, 'negated', []);
stSqrt(r) => r is num ? math.sqrt(r) : stSend(r, 'sqrt', []);

// Ordering (Sprint 14): Dart Strings have no operator< — a miss walked
// into the world's Magnitude circularity (whose primitive stubs answer
// self) and overflowed the stack. Nums stay fast, Strings compare
// lexically, everything else is real ST dispatch.
stLess(a, b) {
  if (a is num && b is num) return a < b;
  if (a is String && b is String) return a.compareTo(b) < 0;
  return stSend(a, '<', [b]);
}
stLessEq(a, b) {
  if (a is num && b is num) return a <= b;
  if (a is String && b is String) return a.compareTo(b) <= 0;
  return stSend(a, '<=', [b]);
}
stGreater(a, b) {
  if (a is num && b is num) return a > b;
  if (a is String && b is String) return a.compareTo(b) > 0;
  return stSend(a, '>', [b]);
}
stGreaterEq(a, b) {
  if (a is num && b is num) return a >= b;
  if (a is String && b is String) return a.compareTo(b) >= 0;
  return stSend(a, '>=', [b]);
}

stMax(a, b) {
  if (a is num && b is num) return a > b ? a : b;
  return stSend(a, 'max:', [b]);
}

stMin(a, b) {
  if (a is num && b is num) return a < b ? a : b;
  return stSend(a, 'min:', [b]);
}

/// `'foo' asSymbol` — canonicalize through the VM symbol table, so runtime
/// symbols are IDENTICAL to `#foo` literals (which are Symbols::New strings).
_stInternNative(String s) native "ST_asSymbol";
stAsSymbol(s) {
  if (s is String) return _stInternNative(s);
  return stSend(s, 'asSymbol', []);
}

/// Sorted copy of a Dart list (prelude asSortedCollection plumbing).
stSortedOf(l) { var c = new List.from(l); c.sort(); return c; }

stJoinList(l) => l.join('');

/// A Dart-side stream for the print protocol: its method names ARE the
/// mangled ST selectors, so an ST `printOn:` body drives it directly via
/// ordinary dispatch (`nextPutAll:` -> nextPutAll_, `<<` -> operator<<) —
/// independent of whichever WriteStream class (prelude or world) is loaded.
class STWriteBuffer {
  final StringBuffer _b = new StringBuffer();
  nextPutAll_(s) { _b.write(s is String ? s : stDisplayOf(s)); return s; }
  nextPut_(c) { _b.write(c is String ? c : c.toString()); return c; }
  space() { _b.write(' '); return this; }
  tab() { _b.write('\t'); return this; }
  cr() { _b.write('\n'); return this; }
  show_(x) { _b.write(stDisplayOf(x)); return this; }
  print_(x) { _b.write(stPrintOf(x)); return x; }
  operator <<(x) { _b.write(stDisplayOf(x)); return this; }
  contents() => _b.toString();
}

/// The print protocol. printString of a string is QUOTED (ST convention);
/// displayString is the bare text. An ST object prints via its printOn:
/// into an STWriteBuffer; one without printOn: falls back to the VM default
/// text. (The catch intentionally narrows only the no-method case in
/// spirit — a printOn: that itself signals is pathological.)
stPrintOf(x) {
  if (x is String) return "'" + x + "'";
  if (x is num || x is bool || x == null || x is List || x is Map) {
    return x.toString();
  }
  if (x is Function) return 'a Block';
  var ws = new STWriteBuffer();
  var r = _stSendTry(x, 'printOn:', [ws]);
  if (r == null) return x.toString();   // no printOn: — the VM default text
  return ws.contents();
}

stDisplayOf(x) => x is String ? x : stPrintOf(x);

/// `x printOn: aStream` with a bridged x: write its text into the stream.
stPrintOn(r, s) {
  if (r is num || r is String || r is bool || r == null || r is List ||
      r is Map || r is Function) {
    return stSend(s, 'nextPutAll:', [stPrintOf(r)]);
  }
  var v = _stSendTry(r, 'printOn:', [s]);
  if (v == null) return stSend(s, 'nextPutAll:', [r.toString()]);
  return v[0];
}

stGcFull() native "ST_gcFull";

// Bridged String/Character constructors: a "new" ST String is a MUTABLE char
// buffer (Dart strings are immutable) — a List speaking at:put:/size through
// the universal helpers; a Character is a 1-char string.
stStringNew(n) => new List(n);
stStringNew0() => [];
stCharValue(c) => new String.fromCharCode(c);

// Array with:* constructors.
stList1(a) => [a];
stList2(a, b) => [a, b];
stList3(a, b, c) => [a, b, c];
stList4(a, b, c, d) => [a, b, c, d];

// GC introspection (`Smalltalk gcScavenge` / `gcStats` — the MACVM SPEC
// 8-element order; counters the Dart heap doesn't expose stay 0).
stGcScavenge() native "ST_gcScavenge";
stGcStats() native "ST_gcStats";

// List plumbing for the prelude's OrderedCollection/Array (via <stprim:>).
stNewList() => new List();
stNewListSized(n) => new List(n);
stNewMap() => new Map();
stListRemoveFirst(l) => l.removeAt(0);
stListInsertFirst(l, x) { l.insert(0, x); return x; }
stListRemove(l, x) { l.remove(x); return x; }
stListIncludes(l, x) => l.contains(x);
stListAppend(l, x) { l.add(x); return l; }  // literal-array build chain
stSplitByChar(s, code) => s.toString().split(new String.fromCharCode(code));
stStringWith(c) => c.toString();  // a Character IS a 1-char string here
stStrLf() => '\n';
stStrTab() => '\t';
stStrCr() => '\r';
stStrSpace() => ' ';

/// One-hop table snapshot: rows joined on US (char 31) for setRowsJoined:.
stJoinRows(l) {
  if (l == null) return '';
  var out = new StringBuffer();
  var first = true;
  for (var e in (l as List)) {
    if (!first) out.write(new String.fromCharCode(31));
    out.write(e == null ? '' : e.toString());
    first = false;
  }
  return out.toString();
}

/// 1-based copyFrom:to: — Dart Strings slice as STRINGS (the world's
/// species-based fallback rebuilt them as char Lists, so 'OK'-prefix reply
/// checks never matched).
stCopyFromTo(c, a, b) {
  if (c is String) return c.substring(a - 1, b);
  if (c is List) return c.sublist(a - 1, b);
  return stSend(c, 'copyFrom:to:', [a, b]);
}

/// Parse-check `.mst` source WITHOUT loading it: returns '' when it parses,
/// else "ERR: line:col: message" — the editor's cheap pre-Accept validation.
String stCheck(String src) native "ST_check";

// --- the Smalltalk Transcript (ST_PLAN.md Sprint 10) ------------------------
// The prelude's `Transcript show:`/`cr` land here (via <stprim:>). show:
// buffers; cr emits one whole line — to [stTranscriptSink] when a host (the
// workspace's language isolate) installed one, else to stdout. Each isolate
// has its own copy of these globals, so demo/game isolates print to stdout
// while the workspace's language isolate feeds the GUI Transcript.
var stTranscriptSink; // void Function(String line), or null
String _stTrBuf = '';

stTrShow(s) {
  _stTrBuf = _stTrBuf + (s == null ? 'nil' : s.toString());
  return null;
}

stTrCr() {
  var line = _stTrBuf;
  _stTrBuf = '';
  if (stTranscriptSink != null) {
    stTranscriptSink(line);
  } else {
    print(line);
  }
  return null;
}

// --- Smalltalk become (Sprint 9) --------------------------------------------
/// One-way: every reference to [a] becomes a reference to [b] (the VM's
/// reload-morphing primitive). Returns [b].
stBecomeForward(a, b) native "ST_becomeForward";

/// Two-way identity swap via shallow copies (identity hashes are the copies').
stBecome(a, b) native "ST_become";

// --- Low-level natives ------------------------------------------------------
int _nsStringFromCString(String s) native "Cocoa_nsStringFromCString";
int _nsStringLength(int handle) native "Cocoa_nsStringLength";
String _nsStringUtf8(int handle) native "Cocoa_nsStringUtf8";

int _getClass(String name) native "Cocoa_getClass";

// --- checking sends against the runtime (COCOA_STATIC_CHECK_PLAN.md) ---------
bool _cocoaClassExists(String name) native "Cocoa_classExists";
List _cocoaSelectorInfo(String cls, String sel) native "Cocoa_selectorInfo";
List _cocoaNearestSelectors(String cls, String typo) native "Cocoa_nearestSelectors";

/// True if [name] is an Objective-C class loaded in THIS binary (the linked
/// frameworks on this OS) — the authoritative Cocoa database we own.
bool cocoaClassExists(String name) => _cocoaClassExists(name);

/// `[1, msgArgc, "@encode"]` if [cls] responds to [sel] (instance or class
/// method), else null. `msgArgc` is the number of keyword arguments (colons);
/// the encoding string carries the argument and return types.
List cocoaSelectorInfo(String cls, String sel) => _cocoaSelectorInfo(cls, sel);

/// Up to five real selectors on [cls] nearest (edit distance) to a mistyped
/// [typo] — the "did you mean" list for the Accept-time lint.
List cocoaNearestSelectors(String cls, String typo) =>
    _cocoaNearestSelectors(cls, typo);
/// The general dynamic send: [receiver] a Cocoa, [selector] like
/// "colorWithRed:...:", [args] the ordered arguments. Returns a Cocoa (for an
/// object result — retained, released on GC), a String (char*), an int
/// (integer id), a double, a List of numbers (struct), or null (void).
dynamic _send(Cocoa receiver, String selector, List args) native "Cocoa_send";
dynamic _sendMain(Cocoa receiver, String selector, List args)
    native "Cocoa_sendMain";

// --- Sprint 13: the ST face of the ONE Cocoa bridge -------------------------
// The world's Cocoa/ObjcRef API (49_cocoa.mst) binds its former MACVM
// primitives to these helpers; the handle an ObjcRef carries in its ivar IS
// the Dart Cocoa wrapper, so retain/release/GC policy stays in one place.
stObjcClassNamed(String name) {
  var c = Cocoa.cls(name);
  return c.isNil ? null : c;             // ST nil for an unknown class
}

/// Map an ST-side argument onto the bridge: Cocoa wrappers and scalars pass
/// through; an ST ObjcRef contributes its wrapped handle (via its
/// `objcHandle` accessor); anything else passes as-is.
_stObjcArg(a) {
  if (a is Cocoa || a == null || a is num || a is String || a is bool) {
    return a;
  }
  var r = _stSendTry(a, 'objcHandle', []);
  if (r != null && r[0] is Cocoa) return r[0];
  return a;
}

List _stObjcArgs(args) {
  var out = <dynamic>[];
  if (args is List) {
    for (var a in args) out.add(_stObjcArg(a));
  }
  return out;
}

/// Auto-shaped send on the isolate thread (headless-safe work).
stObjcSend(h, String sel, args) {
  if (h == null) throw 'Cocoa: send to a released or nil reference';
  return (h as Cocoa).send(sel, _stObjcArgs(args));
}

/// The C3 hop: the same send with objc_msgSend on the MAIN thread (AppKit).
stObjcSendMain(h, String sel, args) {
  if (h == null) throw 'Cocoa: send to a released or nil reference';
  return (h as Cocoa).sendMain(sel, _stObjcArgs(args));
}

stObjcIsRef(x) => x is Cocoa;

/// Sprint 13b: the action trampoline. The mint needs a live action HOST —
/// the workspace language isolate installs its port (it owns dart:isolate);
/// posts arrive there as [ticket, selector] and dispatch through the world's
/// own MacvmDelegate registry (ticket -> receiver, pure Smalltalk).
_stMakeActionTarget(port, int ticket) native "Cocoa_makeActionTarget";
_stMakeTableSource(port, int ticket) native "Cocoa_makeTableSource";
var stActionPort;
stObjcActionTarget(int ticket) {
  if (stActionPort == null) {
    throw 'Cocoa: no action host — the workspace language isolate installs '
        'the action port (buttons need the GUI, not a headless CLI)';
  }
  return _stMakeActionTarget(stActionPort, ticket);
}

/// Sprint 13c: the SNAPSHOT table source — rows live ObjC-side (AppKit's
/// synchronous questions never enter a VM); selection changes come back
/// through the same async post as actions, carrying the row index.
stObjcTableSource(int ticket) {
  if (stActionPort == null) {
    throw 'Cocoa: no action host — the workspace language isolate installs '
        'the action port (tables need the GUI, not a headless CLI)';
  }
  return _stMakeTableSource(stActionPort, ticket);
}

/// One posted action, dispatched: MacvmDelegate looks the ticket up and
/// performs the selector on the registered receiver (sender crosses as nil —
/// wrap-on-post would root an ObjC object against a maybe-dead isolate).
stActionDispatch(ticket, String sel, arg) {
  return stInvokeStatic('MacvmDelegate', 'dispatchTicket:selector:arguments:',
      [ticket, sel, [arg]]);
}

/// Sprint 14: the browser HOST hook — the workspace language isolate
/// installs a closure (verb, args) -> String over its image decls; the
/// STHostService prims below route through it. Null hook = clear ERR.
var stHostHook;
_stHost(String verb, List args) {
  if (stHostHook == null) return 'ERR no image host in this isolate';
  var r = stHostHook(verb, args);
  return r == null ? '' : r.toString();
}

stHostPackageTree(svc) => _stHost('packageTree', const []);
stHostBrowseRecords(svc) => _stHost('browseRecords', const []);
stHostComment(svc, cls) => _stHost('comment', [cls]);
stHostClassSource(svc, cls) => _stHost('classSource', [cls]);
stHostMethodSource(svc, cls, side, sel) =>
    _stHost('methodSource', [cls, side, sel]);
stHostSaveMethod(svc, cls, side, text) =>
    _stHost('saveMethod', [cls, side, text]);
stHostRemoveMethod(svc, cls, side, sel) =>
    _stHost('removeMethod', [cls, side, sel]);
stHostNewClass(svc, text) => _stHost('newClass', [text]);
stHostAcceptClass(svc, text) => _stHost('acceptClass', [text]);
stHostSetComment(svc, cls, text) => _stHost('setComment', [cls, text]);
stHostRemoveClass(svc, cls) => _stHost('removeClass', [cls]);

/// `Worker classNamed:` — the engine's class lookup (a class VALUE or nil).
stClassNamed(name) native "ST_classNamed";

/// ST `perform:` — dynamic dispatch by selector string.
stPerform1(r, sel) => stSend(r, stDisplayOf(sel), []);
stPerform2(r, sel, args) =>
    stSend(r, stDisplayOf(sel), args is List ? args : [args]);
int stObjcPoolPush() native "Cocoa_poolPush";
stObjcPoolPop(p) native "Cocoa_poolPop";

/// An ST String from a send result: NSString wrappers via UTF8String,
/// Dart strings as-is.
stObjcUTF8(x) {
  if (x is String) return x;
  var c = _stObjcArg(x);              // an ST ObjcRef unwraps to its Cocoa
  if (c is Cocoa) return c.isNil ? null : c.send('UTF8String', const []);
  return x == null ? null : x.toString();
}
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
int _gpOpen(int w, int h, int worldW, int worldH, int mode) native "Cocoa_gpOpen";
void _gpClose() native "Cocoa_gpClose";
dynamic _gpApply(List cmds) native "Cocoa_gpApply";
String _gpSnap(String path) native "Cocoa_gpSnap";
List _gpStat() native "Cocoa_gpStat";

/// Open (or re-open at a new size) the Metal game pane and return its NSView
/// to embed. Logical resolution [w]x[h] (the layer upscales, nearest); the
/// indexed world is [worldW]x[worldH] (clamped up to the viewport). [mode] 1
/// builds the direct framebuffer (§6b) instead of the retained sprite stack.
Cocoa gpOpen(int w, int h, int worldW, int worldH, [int mode = 0]) =>
    new Cocoa._adopt(_gpOpen(w, h, worldW, worldH, mode));

/// Tear the engine's panes down (the view survives for reuse).
void gpClose() => _gpClose();

/// Apply one frame's gp* command list and present it. Returns null, or the
/// first error as a String (the frame is still applied best-effort).
dynamic gpApply(List cmds) => _gpApply(cmds);

/// Write the last-rendered frame (the offscreen texture — the honest pixels
/// a window snapshot cannot see) as a PNG. "" on success, else the error.
String gpSnap(String path) => _gpSnap(path);

/// `[open, framesPresented, logicalW, logicalH, fullscreen, direct, stride]`.
List gpStat() => _gpStat();

dynamic _gpBackbuffer() native "Cocoa_gpBackbuffer";

/// The direct framebuffer's current write buffer as a `Uint8List` backed by GPU
/// memory (§6b) — write indices into it, present with a pull frame. Null unless
/// the pane was opened in direct mode. Call it fresh each frame (the buffer
/// rotates); address as `fb[y * stride + x]` with the stride from [gpStat].
dynamic gpBackbuffer() => _gpBackbuffer();

void _gpFullscreen(int on) native "Cocoa_gpFullscreen";

/// The pane view takes (or leaves) the whole screen; logical resolution
/// unchanged, upscaled crisp. No-op when the pane is closed.
void gpFullscreen(bool on) => _gpFullscreen(on ? 1 : 0);

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

  /// Same send, but the objc_msgSend runs ON THE MAIN THREAD (synchronously,
  /// via dispatch_sync) — AppKit's window/view work is main-thread-only.
  /// Sprint 13: the substance behind the ST world's `onMain` proxy.
  dynamic sendMain(String selector, [List args = const []]) =>
      _sendMain(this, selector, _unwrap(args));

  dynamic noSuchMethod(Invocation inv) {
    var name = MirrorSystem.getName(inv.memberName);
    var pos = inv.positionalArguments;
    var named = inv.namedArguments;
    String selector;
    var args = <dynamic>[];

    // Sprint 13: an ST send arrives with its keyword selector MANGLED
    // (':' -> '_' — `w setTitle: t` => setTitle_, `p colorWithRed: r green: g`
    // => colorWithRed_green_) and every argument positional. A '_' in the
    // member name never comes from dartui's own camelCase call sites, so it
    // marks the ST road: un-mangle and send. (Rare underscore-bearing ObjC
    // selectors remain reachable via send('the_sel:', [...]).)
    if (name.contains('_') && named.isEmpty) {
      return _send(this, name.replaceAll('_', ':'), _unwrap(pos));
    }

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
