// dart:cocoa — MACDART's native macOS bridge.
//
// A bootstrap library (wired like dart:io). Phase 1 proved the pipeline with a
// POSIX call and a typed NSString round-trip; Phase 2/3 adds the GENERAL
// dynamic send: `noSuchMethod` forwards any Dart method call to objc_msgSend,
// with the method's AAPCS64 argument/return marshaling driven by the runtime
// @encode. See MACDART/COCOA_PLAN.md.
library dart.cocoa;

import 'dart:_internal' as internal show VMLibraryHooks;
import 'dart:math' as math show sqrt, log, exp, sin, cos, tan, atan;
import 'dart:mirrors' show MirrorSystem;
import 'dart:developer' as developer show debugger;

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

/// `respondsTo:` — does [recv] understand [sel] via its own class chain OR the
/// native extension holders? The 76_reflection overlay routes Object>>respondsTo:
/// here; [sel] arrives as a Symbol (or String), so name it before the probe.
bool stRespondsTo(recv, sel) {
  var s = _stStr(sel);
  return s == null ? false : _stRespondsToImpl(recv, s);
}
bool _stRespondsToImpl(recv, String sel) native "ST_respondsTo";

/// Public alias for the --with-st boot path (C++ enters via Dart_Invoke,
/// which cannot reach the private installer).
void stEnsureHooks() { _stEnsureHooks(); }

bool _stHooked = false;

/// Installed once, before the first ST load: lets _Type.noSuchMethod route a
/// send to a CLASS VALUE held in a variable into ST class-side dispatch, and
/// Object.noSuchMethod route misses on native receivers into the world
/// image's extension holders (Integer>>fib, ...).
/// Forward a String-protocol send from a native Symbol / mutable String to the
/// Dart String [s] the way a plain String receiver is handled: the "String ext"
/// holder chain FIRST (tokenize:, substrings:, asUppercase, replaceAll:, …),
/// then stSend as a last resort. Answers the [result] box the hook contract
/// wants. (stSend alone does not walk the extension holders, so symbols and
/// mutable strings used to miss the whole String extension protocol.)
List _stStrForward(String s, String sel, List args) {
  var hit = _stExtSendTry(s, sel, args);      // already a [result] box, or null
  if (hit != null) return hit;
  return [stSend(s, sel, args)];
}

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
    // A Symbol IS a String (subclass): its own protocol is a short list; every
    // other message forwards to the spelling, so all String protocol answers.
    // The hook contract: return a 1-element LIST [result] on a hit (noSuchMethod
    // unboxes r[0]), null to fall through. A bare value would be `[0]`-indexed.
    if (r is StSymbol) {
      if (sel == 'isSymbol') return const [true];
      if (sel == 'asSymbol' || sel == 'yourself') return [r];
      if (sel == 'hash' || sel == 'identityHash') return [r.hashCode];
      if (sel == '=' || sel == '==') return [identical(r, args[0])];
      // isKindOf:/class must see the SYMBOL, not its spelling — a Symbol is-a
      // Symbol (and a String), which forwarding to r.name would answer as a bare
      // String. (class already routes through the stClassOf helper, not here.)
      if (sel == 'isKindOf_') return [stIsKindOf(r, args[0])];
      return _stStrForward(r.name, sel, args);    // full String protocol
    }
    if (r is StMutableString) {
      var v = _stMutProtocol(r, sel, args);
      if (!identical(v, _noStMut)) return [v];
      return _stStrForward(r.toString(), sel, args);  // full String protocol
    }
    if (r is StChar) {
      var v = _stCharProtocol(r, sel, args);
      if (!identical(v, _noStChar)) return [v];
      // not Character protocol — a Character IS NOT a String, so anything else
      // is a genuine doesNotUnderstand (fall through to the reify path).
    }
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

// --- native Symbol (representation fix, phase 1) ----------------------------
// A Smalltalk Symbol is `String subclass: Symbol` — it answers all String
// protocol but its `=` is IDENTITY (the interned-string contract). Dart's
// String cannot be subclassed, so Symbol is a DISTINCT class that carries the
// spelling and FORWARDS String protocol to it (via the stObjNSM hook below),
// while `==`/`=`/hash are its own. Distinct class identity is what lets `=`
// tell a Symbol from a String — the whole point.
class StSymbol {
  final String name;
  StSymbol._(this.name);
  bool operator ==(o) => identical(this, o);   // interned -> identity is `=`
  int get hashCode => name.hashCode;            // hashes with its spelling
  toString() => name;                           // join/marshal see the chars
}

final Map<String, StSymbol> _stSymbolTable = <String, StSymbol>{};

/// The canonical Symbol for [name] — interned, so `#foo == #foo` by identity.
StSymbol stSymbol(String name) =>
    _stSymbolTable.putIfAbsent(name, () => new StSymbol._(name));

bool stIsSymbol(x) => x is StSymbol;

// --- native Character (representation fix, phase 2) -------------------------
// A Smalltalk Character is a distinct class ordered by code point, NOT a
// 1-char string. Latin-1 (0..255) is a shared FLYWEIGHT so `$a == $a` holds by
// identity (09_character.mst's documented promise), and being its own class is
// what makes `$a = 'a'` false. Its `toString` is the character, so it drops
// into a WriteStream / join / marshal as the glyph.
class StChar {
  final int code;
  const StChar._(this.code);
  bool operator ==(o) => o is StChar && o.code == code;  // value = by code point
  int get hashCode => code;
  toString() => new String.fromCharCode(code);
}

final List<StChar> _stCharTable =
    new List<StChar>.generate(256, (i) => new StChar._(i));

/// The Character for [code] — the shared flyweight for Latin-1, else a fresh
/// instance (so `$a == $a` but `$λ == $λ` need not, exactly as documented).
StChar stChar(int code) =>
    (code >= 0 && code < 256) ? _stCharTable[code] : new StChar._(code);

bool stIsChar(x) => x is StChar;

// --- mutable String (representation fix, phase 3) ---------------------------
// Smalltalk strings are MUTABLE; Dart strings are not. The hybrid: an immutable
// literal stays a fast Dart String, but `String new:` / at:put: / WriteStream's
// backing use StMutableString — a real growable code-unit buffer whose
// `toString` is the string, so it reads and marshals as one. (Was a bare Dart
// List, so `contents` answered a char-list — the "bad canvas JSON" bug.)
class StMutableString {
  List<int> units;
  StMutableString(this.units);
  int get length => units.length;
  toString() => new String.fromCharCodes(units);
  bool operator ==(o) {
    if (o is StMutableString) {
      if (o.units.length != units.length) return false;
      for (var i = 0; i < units.length; i++) if (o.units[i] != units[i]) return false;
      return true;
    }
    if (o is String) return toString() == o;
    return false;
  }
  int get hashCode => toString().hashCode;
}

bool stIsMutStr(x) => x is StMutableString;

/// The code unit for a value written INTO a string: a Character, an int code,
/// or a 1-char string (legacy). Anything else is a bug the caller surfaces.
int _stCode(v) {
  if (v is StChar) return v.code;
  if (v is int) return v;
  if (v is String && v.length >= 1) return v.codeUnitAt(0);
  if (v is StMutableString && v.units.isNotEmpty) return v.units[0];
  return 32;
}

/// The Character/String-building protocol on a mutable string (replaceFrom:to:
/// with:, asString/contents, concatenation, do:); the reads a Symbol-style
/// forward would miss because it is a distinct class. Returns _noStMut to fall
/// through. (Reads like size/at: go through the universal helpers below.)
const _noStMut = const Object();
_stMutProtocol(StMutableString r, String sel, List args) {
  switch (sel) {
    case 'asString': case 'yourself': case 'contents': return r;
    case 'isString': return true;
    case 'asSymbol': return stSymbol(r.toString());
    case 'printString': return "'" + r.toString() + "'";
    case 'displayString': return r.toString();
    case 'hash': return r.hashCode;
    case 'reversed': case 'reverse':
      return new StMutableString(r.units.reversed.toList());
    // NB: selectors arrive MANGLED (noSuchMethod hands us the Dart method
    // name, `:` -> `_`), so keyword cases match the underscore form.
    case 'replaceFrom_to_with_': {          // memcpy: dst[a..b] := src[1..]
      var a = args[0], b = args[1], src = args[2];
      for (var i = a; i <= b; i++) r.units[i - 1] = _stCode(stAt1(src, i - a + 1));
      return r;
    }
    case 'replaceFrom_to_with_startingAt_': {
      var a = args[0], b = args[1], src = args[2], s = args[3];
      for (var i = a; i <= b; i++) r.units[i - 1] = _stCode(stAt1(src, s + i - a));
      return r;
    }
  }
  return _noStMut;
}

/// `\$a` literal -> the flyweight Character (the code from the parser's glyph).
StChar stCharLit(String glyph) => stChar(glyph.codeUnitAt(0));

/// The Character protocol answered directly (the receiver is an StChar, not a
/// String, so String forwarding would be wrong). Returns a sentinel _noStChar
/// when the selector isn't Character protocol, so the caller falls through.
const _noStChar = const Object();
_stCharProtocol(StChar r, String sel, List args) {
  var c = r.code;
  switch (sel) {
    case 'asInteger': case 'value': case 'codePoint': case 'asciiValue':
      return c;
    case 'asCharacter': case 'yourself': return r;
    case 'isCharacter': return true;
    case 'asString': case 'printString': return r.toString();  // printString handled in stPrintOf too
    case 'asSymbol': return stSymbol(r.toString());
    case 'hash': case 'identityHash': return c;
    case 'asUppercase':
      return stChar(new String.fromCharCode(c).toUpperCase().codeUnitAt(0));
    case 'asLowercase':
      return stChar(new String.fromCharCode(c).toLowerCase().codeUnitAt(0));
    case 'isDigit': return c >= 48 && c <= 57;
    case 'isLetter':
      return (c >= 65 && c <= 90) || (c >= 97 && c <= 122);
    case 'isUppercase': return c >= 65 && c <= 90;
    case 'isLowercase': return c >= 97 && c <= 122;
    case 'isVowel':
      return c==97||c==101||c==105||c==111||c==117||c==65||c==69||c==73||c==79||c==85;
    case 'isSpace': case 'isSeparator':
      return c == 32 || c == 9 || c == 10 || c == 13 || c == 12;
    case 'isLetterOrDigit': case 'isAlphaNumeric':
      return (c>=48&&c<=57)||(c>=65&&c<=90)||(c>=97&&c<=122);
    case 'digitValue':
      if (c >= 48 && c <= 57) return c - 48;
      if (c >= 65 && c <= 90) return c - 55;   // A..Z -> 10..35
      if (c >= 97 && c <= 122) return c - 87;
      return -1;
    case '<': return args[0] is StChar ? c < args[0].code : stSend(r, '<', args);
    case '<=': return args[0] is StChar ? c <= args[0].code : stSend(r, '<=', args);
    case '>': return args[0] is StChar ? c > args[0].code : stSend(r, '>', args);
    case '>=': return args[0] is StChar ? c >= args[0].code : stSend(r, '>=', args);
    case '=': return stEquals(r, args[0]);
    case '==': return identical(r, args[0]);
  }
  return _noStChar;
}

/// ST `=` with recovered class identity — the representation fix. `==` stays a
/// StrictCompare (identity) in the builder; this is `=` (value). Fast path:
/// identical objects (incl. interned Symbols and equal Smis) and numbers.
/// Slow path: a Symbol's `=` is identity (so `#foo = 'foo'` is false); a String
/// compares elements, treating a Symbol as its spelling (so `'foo' = #foo` is
/// true); any real ST object dispatches to its OWN `=` method — which is what
/// finally makes Fraction and every user-defined `=` work.
/// A string-ish value (Dart String, native mutable String, Symbol, Character)
/// as a real Dart String; null for anything that is not string-ish.
String _stStr(x) {
  if (x is String) return x;
  if (x is StMutableString) return x.toString();
  if (x is StSymbol) return x.name;
  if (x is StChar) return x.toString();
  return null;
}

stEquals(a, b) {
  if (identical(a, b)) return true;
  if (a is num) return a == b;
  return _stEqualsSlow(a, b);
}
_stEqualsSlow(a, b) {
  if (a == null) return false;                  // nil = x (nil=nil took identical)
  if (a is StSymbol) return false;              // identity already failed
  if (a is StChar) return b is StChar && a.code == b.code;  // $a = 'a' -> false
  if (a is StMutableString) {                   // (String new:..) = 'abc'
    var s = _stStr(b); return s != null && s is String && a.toString() == s;
  }
  if (a is String) {
    if (b is StSymbol) return a == b.name;      // 'foo' = #foo  -> true
    if (b is StMutableString) return a == b.toString();
    if (b is String) return a == b;
    return false;                               // 'a' = $a  -> false
  }
  if (a is List) {                              // a literal #(...) is a Dart
    if (b is! List || a.length != b.length) return false;  // List, with no ST
    for (var i = 0; i < a.length; i++) {        // `=` — compare element-wise
      if (!stEquals(a[i], b[i])) return false;  // (Array>>= semantics),
    }                                           // recursively so nested arrays
    return true;                                // and ST elements compare too.
  }
  return stSend(a, '=', [b]);                   // Fraction / user classes
}

/// `,` concatenation. String+String is the hot path (plain Dart `+`). Any pair
/// of string-ish operands (mutable String / Symbol / Character mixed with a
/// literal) coerces to a Dart String; List,List concatenates; anything else is
/// sent on as a real ST `,` message so world collections keep their own method.
stConcat(a, b) {
  if (a is String && b is String) return a + b;
  var sa = _stStr(a);
  if (sa != null) {
    var sb = _stStr(b);
    if (sb != null) return sa + sb;
  }
  if (a is List) {
    var r = new List.from(a);
    if (b is List) r.addAll(b); else r.add(b);
    return r;
  }
  return stSend(a, ',', [b]);
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

dynamic _stGetField(receiver, String name) native "ST_getField";

/// Universal ST send for selectors that collide with a dart:core GETTER (`7
/// sign`, `#(1 2 3) first`, `aList reversed`). A plain InstanceCall would let
/// Dart resolve the getter and getter-CALL its result — `(7.sign).call()` — and
/// crash. Dispatch in Smalltalk-correct order: (1) the native ext-chain
/// (Integer ext, Array ext, ... — an ST override wins), (2) the receiver's own
/// ST class chain (an ST object: Fraction>>sign, OrderedCollection>>first), (3)
/// only for a NATIVE receiver, the dart:core getter itself, read as a plain
/// field so it is NOT invoked — there the getter is the intended ST value
/// (List.first, num.sign). Non-native misses fall to stSend for an honest DNU.
stSendExt(receiver, String selector, List args) {
  var hit = _stExtSendTry(receiver, selector, args); // [result] box, or null
  if (hit != null) return hit[0];
  var box = _stSendTry(receiver, selector, args); // ST class chain, no throw
  if (box != null) return box[0];
  if (args.isEmpty &&
      (receiver is num ||
          receiver is String ||
          receiver is List ||
          receiver is bool)) {
    return _stGetField(receiver, selector);
  }
  return stSend(receiver, selector, args); // throws the proper doesNotUnderstand
}

/// Like stSendExt but GRACEFUL on a total miss: answers nil instead of throwing.
/// The class-name send fallback uses it so a reflective send that resolves
/// (`Integer superclass`) works, while a genuinely unknown class-side send
/// (`Transcript basicPrint:`) answers nil exactly as the old compile-time
/// bailout did — no surprise doesNotUnderstand where there used to be none.
stSendExtOrNil(receiver, String selector, List args) {
  var hit = _stExtSendTry(receiver, selector, args);
  if (hit != null) return hit[0];
  var box = _stSendTry(receiver, selector, args);
  if (box != null) return box[0];
  return null;
}

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

// A handler action (`e return:`/`retry`/`pass`/`return`). Thrown from inside a
// running handler, it unwinds to the stOnDo that established THAT handler,
// identified by `token`. An Expando maps each in-flight exception instance to
// its handler's token so the instance's own method can find its stOnDo.
class _STHandlerAction {
  final token;
  final String kind; // 'return' | 'retry' | 'pass'
  final value;
  _STHandlerAction(this.token, this.kind, this.value);
}
final Expando _stExcTokens = new Expando('stExcTokens');

// A native Dart error caught by `on: Error do:` is reified as an ST exception so
// the handler sees a real object (`e messageText`): ZeroDivide for a division by
// zero, a plain Error otherwise. A narrower handler class simply won't match.
_stWrapNativeError(e) {
  var name = (e is IntegerDivisionByZeroException) ? 'ZeroDivide' : 'Error';
  var err = stNew(name);
  try {
    stSend(err, 'messageText:', [e.toString()]);
  } catch (_) {}
  return err;
}

stOnDo(protected, type, handler) {
  var token = new Object(); // identifies THIS handler activation (for retry etc.)
  while (true) {
    var exc;
    try {
      return protected();
    } catch (e) {
      if (e is _STNlr) rethrow; // non-local ^ is not an exception
      if (e is _STHandlerAction) rethrow; // belongs to an ancestor handler
      if (e is _STException) {
        exc = e.instance;
        if (!stIsKindOf(exc, type)) rethrow;
      } else {
        exc = _stWrapNativeError(e); // a native Dart error, if Error-catchable
        if (!stIsKindOf(exc, type)) rethrow;
      }
      var saved = _stExcTokens[exc];
      _stExcTokens[exc] = token;
      var action;
      try {
        return handler(exc); // handler falls off its end -> its value wins
      } on _STHandlerAction catch (a) {
        if (a.token != token) rethrow; // an enclosing handler's action
        action = a;
      } finally {
        _stExcTokens[exc] = saved;
      }
      if (action.kind == 'return') return action.value;
      if (action.kind == 'pass') { // resignal to the next enclosing handler
        if (e is _STException) rethrow;
        throw e;
      }
      // 'retry' -> loop and re-run the protected block from the top.
    }
  }
}

// `e return: v` / `return` / `retry` / `pass`, sent to the exception INSIDE a
// handler: throw the carrier keyed to the handler's stOnDo (found via the
// Expando). Outside a handler the token is null and no stOnDo matches -> the
// action surfaces as an ordinary unhandled error.
stExcReturn(exc, v) { throw new _STHandlerAction(_stExcTokens[exc], 'return', v); }
stExcReturnNil(exc) { throw new _STHandlerAction(_stExcTokens[exc], 'return', null); }
stExcRetry(exc) { throw new _STHandlerAction(_stExcTokens[exc], 'retry', null); }
stExcPass(exc) { throw new _STHandlerAction(_stExcTokens[exc], 'pass', null); }

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
stBasicNew(type) native "ST_basicNewFromType";
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
stValue0(r) { if (r is Function) return r(); return _stValue0Slow(r); }
_stValue0Slow(r) => r.value();
stValue1(r, a) { if (r is Function) return r(a); return _stValue1Slow(r, a); }
_stValue1Slow(r, a) => r.value_(a);
stValue2(r, a, b) { if (r is Function) return r(a, b); return _stValue2Slow(r, a, b); }
_stValue2Slow(r, a, b) => r.value_value_(a, b);
stValue3(r, a, b, c) { if (r is Function) return r(a, b, c); return _stValue3Slow(r, a, b, c); }
_stValue3Slow(r, a, b, c) => r.value_value_value_(a, b, c);
stValue4(r, a, b, c, d) { if (r is Function) return r(a, b, c, d); return _stValue4Slow(r, a, b, c, d); }
_stValue4Slow(r, a, b, c, d) => r.value_value_value_value_(a, b, c, d);

/// ST `&`/`|`: Boolean non-short-circuit and/or (Dart 1.24 bool has no
/// operator&). Ints keep bitwise semantics; anything else -> ST dispatch.
stBoolAnd(a, b) {
  if (a is bool && b is bool) return a && b;
  if (a is int && b is int) return a & b;
  return _stAmpSlow(a, b);
}
_stAmpSlow(a, b) => a & b;

stBoolOr(a, b) {
  if (a is bool && b is bool) return a || b;
  if (a is int && b is int) return a | b;
  return _stPipeSlow(a, b);
}
_stPipeSlow(a, b) => a | b;

stAt1(c, k) {
  if (c is StMutableString) return stChar(c.units[k - 1]);
  if (c is StSymbol) return stChar(c.name.codeUnitAt(k - 1));
  if (c is List) return c[k - 1]; // Smalltalk indexes from 1
  if (c is Map) return c[k];
  if (c is String) return stChar(c.codeUnitAt(k - 1));  // a Character, not a 1-char string
  return _stAtSlow(c, k);
}
_stAtSlow(c, k) => c.at_(k);

stAtPut1(c, k, v) {
  if (c is StMutableString) { c.units[k - 1] = _stCode(v); return v; }
  if (c is List) { c[k - 1] = v; return v; }
  if (c is Map) { c[k] = v; return v; }
  return _stAtPutSlow(c, k, v);
}
_stAtPutSlow(c, k, v) => c.at_put_(k, v);

/// `basicByteAt: i put: v` — the raw 1-based byte store the world's
/// String>>at:put: delegates to. at:put: has its own fast path (stAtPut1), so
/// this only mattered on a DIRECT call — where it used to throw, because a
/// mutable string forwards unknown selectors to its immutable copy. Same
/// receiver handling as stAtPut1; the world returns the stored value (`^v`).
stBasicBytePut(r, i, v) {
  var code = _stCode(v);
  if (r is StMutableString) { r.units[i - 1] = code; return code; }
  if (r is List) { r[i - 1] = v; return v; }
  return _stBasicBytePutSlow(r, i, v);
}
_stBasicBytePutSlow(r, i, v) => r.basicByteAt_put_(i, v);

/// `self halt` — the programmer's breakpoint. The world's contract is precise:
/// "open the debugger WHEN ONE IS ARMED, otherwise a no-op, answer self".
///
/// The arming is not optional bookkeeping — it is a safety requirement.
/// dart:developer's debugger() pauses the isolate and BLOCKS until a service
/// client resumes it; with no client (every headless run, every plain `dart`)
/// it hangs forever. So halt pauses ONLY when the workspace has told this
/// isolate a debugger is attached to catch it (stHaltArm below, set from
/// dbgAttach). Unarmed, it is the no-op the world promises. Answers self both
/// ways.
bool stHaltArmed = false;
stHalt(recv) {
  if (stHaltArmed) developer.debugger(message: 'Smalltalk halt');
  return recv;
}

/// The workspace arms halt while its Debugger tab is attached to this isolate,
/// and disarms it otherwise — so a halt only pauses when something will resume.
stHaltArm(on) { stHaltArmed = (on == true || on == 'on'); return stHaltArmed; }

stSizeOf(c) {
  if (c is StMutableString) return c.units.length;
  if (c is StSymbol) return c.name.length;
  if (c is List || c is Map || c is String) return c.length;
  if (c is int) return stIntByteSize(c);   // Integer>>size = magnitude byte count
  return _stSizeSlow(c);
}

/// LargeInteger byte protocol (little-endian, 1-based, index 1 = least
/// significant — the corpus's own convention). A Dart int (Mint/Bigint) is
/// immutable, so these are the READS; byteAt:put: (construction) is unused
/// because MACDART does bignum arithmetic natively. The 07a overlay <stprim:>s
/// LargeInteger>>byteAt:/hash onto these; size rides the stSizeOf helper above.
int stIntByteSize(n) { n = n.abs(); return n == 0 ? 0 : (n.bitLength + 7) ~/ 8; }
int stIntByteAt(n, i) => (n.abs() >> (8 * (i - 1))) & 0xFF;
_stSizeSlow(c) => c.size();

stAddU(c, x) {
  if (c is List) { c.add(x); return x; }   // ST add: answers the argument
  return _stAddSlow(c, x);
}
_stAddSlow(c, x) => c.add_(x);

stDo(c, f) {
  if (c is StMutableString) { for (var i = 0; i < c.units.length; i++) f(stChar(c.units[i])); return c; }
  if (c is StSymbol) { for (var i = 0; i < c.name.length; i++) f(stChar(c.name.codeUnitAt(i))); return c; }
  if (c is String) { for (var i = 0; i < c.length; i++) f(stChar(c.codeUnitAt(i))); return c; }
  if (c is List) { for (var e in c) f(e); return c; }
  if (c is Map) { for (var v in c.values) f(v); return c; }
  return _stDoSlow(c, f);
}
_stDoSlow(c, f) => c.do_(f);

stIsEmptyU(c) {
  if (c is StMutableString) return c.units.isEmpty;
  if (c is StSymbol) return c.name.isEmpty;
  if (c is List || c is Map || c is String) return c.isEmpty;
  return _stIsEmptySlow(c);
}
_stIsEmptySlow(c) => c.isEmpty();

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
  return _stDivSlow(a, b);
}
_stDivSlow(a, b) => a / b;

// Numeric conversions/negation: Dart-num fast paths (the world kernel's
// versions are <primitive:>-backed and must never be reached via the NSM
// hook, whose ignored-pragma bodies would answer self).
stAsDouble(r) => r is num ? r.toDouble() : _stAsDoubleSlow(r);
_stAsDoubleSlow(r) => r.asDouble();
// `asInteger` (aliased here): a number truncates, a Character answers its code,
// a String PARSES (leading optional-sign digits, nil if none) — Smalltalk's
// String>>asInteger, which the helper alias would otherwise route to .truncated.
stTruncated(r) {
  if (r is num) return r.truncate();
  if (r is StChar) return r.code;
  var s = _stStr(r);                       // String / mutable String
  if (s != null) {
    var m = new RegExp(r'-?[0-9]+').firstMatch(s);
    return m == null ? null : int.parse(m.group(0));
  }
  return _stTruncSlow(r);
}
_stTruncSlow(r) => r.truncated();
stRounded(r) => r is num ? r.round() : _stRoundSlow(r);
_stRoundSlow(r) => r.rounded();
stFloorU(r) => r is num ? r.floor() : _stFloorSlow(r);
_stFloorSlow(r) => r.floor();
stCeilingU(r) => r is num ? r.ceil() : _stCeilSlow(r);
_stCeilSlow(r) => r.ceiling();
stNegated(r) => r is num ? -r : _stNegSlow(r);
_stNegSlow(r) => r.negated();
stSqrt(r) => r is num ? math.sqrt(r) : _stSqrtSlow(r);
_stSqrtSlow(r) => r.sqrt();

// The transcendentals and bitShift:, added because st/test/primitive_coverage
// caught them ANSWERING THE RECEIVER. The world declares them on Double and
// SmallInteger as bare <primitive: N> bodies; MACDART ignores numbered
// primitives, so with no fast path the method compiled to an empty body — and
// an empty Smalltalk body returns self. `2 sin` was 2, silently.
stLn(r) => r is num ? math.log(r) : _stLnSlow(r);
_stLnSlow(r) => r.ln();
stExp(r) => r is num ? math.exp(r) : _stExpSlow(r);
_stExpSlow(r) => r.exp();
stSin(r) => r is num ? math.sin(r) : _stSinSlow(r);
_stSinSlow(r) => r.sin();
stCos(r) => r is num ? math.cos(r) : _stCosSlow(r);
_stCosSlow(r) => r.cos();
stTan(r) => r is num ? math.tan(r) : _stTanSlow(r);
_stTanSlow(r) => r.tan();
stAtan(r) => r is num ? math.atan(r) : _stAtanSlow(r);
_stAtanSlow(r) => r.atan();

/// Smalltalk `bitShift:` is signed: positive shifts left, negative right.
stBitShift(r, n) {
  if (r is int && n is int) return n >= 0 ? (r << n) : (r >> -n);
  return _stBitShiftSlow(r, n);
}
_stBitShiftSlow(r, n) => r.bitShift(n);

/// `compare:` answers an Integer the world tests against 0 (String>>= is
/// `(self compare: other) = 0`, `<` is `< 0`), so compareTo's
/// negative/zero/positive contract is exactly right.
stCompare(a, b) {
  if (a is StSymbol) a = a.name;
  if (b is StSymbol) b = b.name;
  if (a is String && b is String) return a.compareTo(b);
  return _stCompareSlow(a, b);
}
_stCompareSlow(a, b) {
  // A ByteArray is a Dart List, which has no compare — element-wise, same
  // negative/zero/positive contract. Adding stCompare for Strings alone just
  // moved the bug: `#[1 2 3] compare:` went from silently answering self to
  // throwing "List has no method compare".
  if (a is List && b is List) {
    var n = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < n; i++) {
      var d = (a[i] as Comparable).compareTo(b[i]);
      if (d != 0) return d < 0 ? -1 : 1;
    }
    return a.length == b.length ? 0 : (a.length < b.length ? -1 : 1);
  }
  return a.compare(b);
}

/// `basicByteAt:` is the raw byte behind a String, 1-BASED.
stBasicByteAt(r, i) {
  if (r is StSymbol) r = r.name;
  if (r is StMutableString && i is int) return r.units[i - 1];  // String new:..
  if (r is String && i is int) return r.codeUnitAt(i - 1);
  if (r is List && i is int) return r[i - 1];
  return _stBasicByteAtSlow(r, i);
}
_stBasicByteAtSlow(r, i) => r.basicByteAt(i);

/// `valueWithArguments:` — a closure applied to a list of arguments.
stValueWithArgs(r, a) {
  if (r is Function && a is List) return Function.apply(r, a);
  return _stValueWithArgsSlow(r, a);
}
_stValueWithArgsSlow(r, a) => r.valueWithArguments(a);

/// Double>>printDigits answers the digits as a String — the world uses it as
/// `s nextPutAll: self printDigits` (19_printing.mst).
stPrintDigits(r) => r is num ? r.toString() : _stPrintDigitsSlow(r);
_stPrintDigitsSlow(r) => r.printDigits();

// Ordering (Sprint 14): Dart Strings have no operator< — a miss walked
// into the world's Magnitude circularity (whose primitive stubs answer
// self) and overflowed the stack. Nums stay fast, Strings compare
// lexically, everything else is real ST dispatch.
stLess(a, b) {
  if (a is StSymbol) a = a.name; if (b is StSymbol) b = b.name;
  if (a is StChar) a = a.code; if (b is StChar) b = b.code;
  if (a is num && b is num) return a < b;
  if (a is String && b is String) return a.compareTo(b) < 0;
  return _stLtSlow(a, b);
}
// A native number vs an ST numeric object (a Fraction, a ScaledDecimal) can't
// go through Dart's own operator: `int.<` is `other > this`, and the corpus's
// `Fraction>>` is `^aNumber < self` — two reversals that form an infinite
// 2-cycle (`0 < (3/4)` → `(3/4) > 0` → `0 < (3/4)` → stack overflow). Only the
// ST object's FORWARD `<` does real work (cross-multiplication), so derive all
// four from it: with lt = (b < a) and eq = (a = b) — both computed on the ST
// side, which terminates — a<b ⟺ ¬lt∧¬eq, a≤b ⟺ ¬lt, a>b ⟺ lt, a≥b ⟺ lt∨eq.
_stLtSlow(a, b) {
  if (a is num && b is! num) return !stLess(b, a) && !stEquals(a, b);
  return a < b;
}
stLessEq(a, b) {
  if (a is StSymbol) a = a.name; if (b is StSymbol) b = b.name;
  if (a is StChar) a = a.code; if (b is StChar) b = b.code;
  if (a is num && b is num) return a <= b;
  if (a is String && b is String) return a.compareTo(b) <= 0;
  return _stLeSlow(a, b);
}
_stLeSlow(a, b) {
  if (a is num && b is! num) return !stLess(b, a);
  return a <= b;
}
stGreater(a, b) {
  if (a is StSymbol) a = a.name; if (b is StSymbol) b = b.name;
  if (a is StChar) a = a.code; if (b is StChar) b = b.code;
  if (a is num && b is num) return a > b;
  if (a is String && b is String) return a.compareTo(b) > 0;
  return _stGtSlow(a, b);
}
_stGtSlow(a, b) {
  if (a is num && b is! num) return stLess(b, a);
  return a > b;
}
stGreaterEq(a, b) {
  if (a is StSymbol) a = a.name; if (b is StSymbol) b = b.name;
  if (a is StChar) a = a.code; if (b is StChar) b = b.code;
  if (a is num && b is num) return a >= b;
  if (a is String && b is String) return a.compareTo(b) >= 0;
  return _stGeSlow(a, b);
}
_stGeSlow(a, b) {
  if (a is num && b is! num) return stLess(b, a) || stEquals(a, b);
  return a >= b;
}

stMax(a, b) {
  if (a is num && b is num) return a > b ? a : b;
  return _stMaxSlow(a, b);
}
_stMaxSlow(a, b) => a.max_(b);

stMin(a, b) {
  if (a is num && b is num) return a < b ? a : b;
  return _stMinSlow(a, b);
}
_stMinSlow(a, b) => a.min_(b);

/// `'foo' asSymbol` — the CANONICAL interned Symbol, IDENTICAL to the `#foo`
/// literal. Both must go through stSymbol / the _stSymbolTable: Phase 1 made
/// Symbol its own class, so the old VM-Symbols-table native answered a
/// different object and `'foo' asSymbol == #foo` was false.
stAsSymbol(s) {
  if (s is StSymbol) return s;               // already canonical
  var str = _stStr(s);                       // String / mutable String / Char
  if (str != null) return stSymbol(str);
  return _stAsSymSlow(s);
}
_stAsSymSlow(s) => s.asSymbol();

/// The FFI floor (ST_PORTING_PLAN §3a): call a C function by name. The builder
/// lowers a `<primitive: FFI function: #name ret: #r args: #(c c)>` method to
/// stFfiCall([params], "name|ret|codes"). Word args/return for now (Posix +
/// Time); doubles (Accel) arrive with the FPR trampoline.
stFfiCall(List args, String desc) native "ST_ffiCall";

/// Alien peek/poke (stage b): raw read/write at an ABSOLUTE address (an int).
/// The prelude's Alien bounds-checks against its span before calling these.
stPeekByte(a) native "ST_peekByte";
stPokeByte(a, v) native "ST_pokeByte";
stPeekF64(a) native "ST_peekF64";
stPokeF64(a, v) native "ST_pokeF64";
stPeekI64(a) native "ST_peekI64";
stPokeI64(a, v) native "ST_pokeI64";

/// Class reflection (M5): a class VALUE's name/super and, class-side, the whole
/// ST class list + a behavior's own selectors/ivars/classvars — answered from
/// the VM's real Class API (MACVM read these off the class object's layout).
/// The 76_reflection.mst overlay <stprim:>s ClassMirror/Behavior onto these.
stClassNameOf(c) native "ST_classNameOf";
stSuperclassOf(c) native "ST_superclassOf";
stAllClasses() native "ST_allClasses";
stSelectorsOf(c) native "ST_selectorsOf";
stInstVarNamesOf(c) native "ST_instVarNamesOf";
stClassVarNamesOf(c) native "ST_classVarNamesOf";

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
  if (x is StMutableString) return "'" + x.toString() + "'";
  if (x is StChar) return r"$" + x.toString();     // Smalltalk prints a char as $a
  if (x is StSymbol) return "#" + x.name;        // Smalltalk prints symbols as #foo
  if (x is String) return "'" + x + "'";
  if (x == null) return 'nil';                   // Smalltalk nil, not Dart null
  if (x is List) {
    // An ST Array IS a Dart List (a literal #(...), Array new:, a collect:
    // result). Print it Smalltalk-style — `(e1 e2 e3 )` — instead of Dart's
    // `[e1, e2, e3]`; elements recurse through printString (strings quote,
    // nested arrays parenthesize). (GNU-Smalltalk Array form; Set/Bag add the
    // class-name prefix in their own printOn:.)
    var sb = new StringBuffer('(');
    for (var e in x) {
      sb.write(stPrintOf(e));
      sb.write(' ');
    }
    sb.write(')');
    return sb.toString();
  }
  if (x is num || x is bool || x is Map) {
    return x.toString();
  }
  if (x is Function) return 'a Block';
  // A class VALUE (a Type) prints as its ST name — `Number`, not `Number ext`
  // and not the generic Object>>printOn: text. stClassNameOf answers non-null
  // ONLY for a Type (it strips the bridged-holder suffix), so it doubles as the
  // is-a-class test. (Behavior>>printOn: lives in an ext holder that stPrintOf's
  // own-class-chain printOn: probe below can't reach for a Type receiver.)
  var cn = stClassNameOf(x);
  if (cn != null) return cn;
  var ws = new STWriteBuffer();
  var r = _stSendTry(x, 'printOn:', [ws]);
  if (r == null) return x.toString();   // no printOn: — the VM default text
  return ws.contents();
}

stDisplayOf(x) => x is String ? x : (x is StMutableString ? x.toString() : (x is StSymbol ? x.name : (x is StChar ? x.toString() : stPrintOf(x))));

/// `x printOn: aStream` with a bridged x: write its text into the stream.
stPrintOn(r, s) {
  if (r is num || r is String || r is bool || r == null || r is List ||
      r is Map || r is Function) {
    return _stNPASlow(s, stPrintOf(r));
  }
  var v = _stSendTry(r, 'printOn:', [s]);
  if (v == null) return _stNPASlow(s, r.toString());
  return v[0];
}

stGcFull() native "ST_gcFull";

// Bridged String/Character constructors: a "new" ST String is a MUTABLE char
// buffer (Dart strings are immutable) — an StMutableString speaking at:put:/
// size/replaceFrom: (its `toString` IS the string, so it reads and marshals as
// one); a Character value: answers the flyweight Character.
stStringNew(n) => new StMutableString(new List<int>.filled(n, 32, growable: true));  // n spaces, mutable
stStringNew0() => new StMutableString(<int>[]);
/// `String new: n withAll: aChar` — a mutable String of n copies of the char.
stStringNewWithAll(n, c) {
  var code = (c is StChar)
      ? c.code
      : (c is String && c.length == 1 ? c.codeUnitAt(0) : 32);
  return new StMutableString(new List<int>.filled(n, code, growable: true));
}
/// `[:a :b | ...] numArgs` — the block's declared argument count.
int stBlockNumArgs(block) native "ST_blockNumArgs";
stCharValue(c) => stChar(c);   // Character value: n -> the flyweight Character

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
stNewByteArray(n) => new List<int>.filled(n, 0);  // ByteArray new: n (0-filled)
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
  if (c is StSymbol) c = c.name;
  if (c is String) return c.substring(a - 1, b);
  if (c is List) return c.sublist(a - 1, b);
  return _stCopySlow(c, a, b);
}
_stCopySlow(c, a, b) => c.copyFrom_to_(a, b);

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

/// The world's Object>>instVarAt: — 1-based, super-chain-first. Declared as a
/// bare <primitive: 25> with nothing behind it, so it used to answer the
/// receiver.
stInstVarAt(r, i) native "ST_instVarAt";

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
_stMakeActionTarget(port, int ticket) native "ST_makeActionTarget";
_stMakeTableSource(port, int ticket) native "ST_makeTableSource";
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
_stClassNamedRaw(name) native "ST_classNamed";
/// `Worker classNamed: name` — the browser passes a Symbol (`#CocoaTableFace`),
/// and since Symbol became its own class the native's string lookup no longer
/// sees a Dart String. Coerce any string-ish name to its spelling first.
stClassNamed(name) => _stClassNamedRaw(name is String ? name : name.toString());

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
typedef void GutterClickFn(int line);   // debugger gutter click -> 1-based line

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
int _attachGutter(int scrollView, int ticket) native "Cocoa_attachGutter";
void _gutterSetLines(int gutter, String breaksCsv, int paused)
    native "Cocoa_gutterSetLines";

// The single entry every native callback funnels through (see cocoa_callbacks.mm).
// kind: 0 action, 1 textDidChange, 2 tableRowCount, 3 tableValue(arg=row),
// 4 tableSelect(arg=row). Returns void for 0/1/4, an int for 2, a String for 3.
dynamic _cocoaDispatch(int ticket, int kind, int arg) {
  var h = _cbHandlers[ticket];
  if (h == null) return null;
  if (kind <= 1) { if (h is CocoaAction) h(new Cocoa._adopt(arg)); return null; }
  if (kind == 5) { if (h is GutterClickFn) h(arg); return null; }  // gutter click
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

/// Attach a debugger-style breakpoint gutter (a vertical NSRulerView) to
/// [scrollView] (the enclosing scroll view of a source text view). A click in
/// the gutter calls [onLineClick] with the 1-based source line. Returns the
/// gutter handle — pass it to [gutterSetLines] to paint the dots. Keep it alive.
Cocoa attachGutter(Cocoa scrollView, GutterClickFn onLineClick) {
  _ensureDispatch();
  var ticket = _cbNext++;
  _cbHandlers[ticket] = onLineClick;
  return new Cocoa._adopt(_attachGutter(scrollView.handle, ticket));
}

/// Repaint [gutter]: a red dot on each line in [breakLines], a caret on
/// [pausedLine] (0 for none).
void gutterSetLines(Cocoa gutter, List<int> breakLines, int pausedLine) {
  if (gutter == null) return;
  var csv = new StringBuffer();
  for (var i = 0; i < breakLines.length; i++) {
    if (i > 0) csv.write(',');
    csv.write(breakLines[i]);
  }
  _gutterSetLines(gutter.handle, csv.toString(), pausedLine);
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

  /// Wrap a raw ObjC handle WITHOUT taking ownership (no retain, no
  /// finalizer). Sprint 15: how a view built by one isolate (the language
  /// isolate's ST browser) is parented by another (the UI isolate's tab) —
  /// the view hierarchy retains it; the builder keeps ownership.
  static Cocoa adoptHandle(int h) => new Cocoa._adopt(h);

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

_stNPASlow(s, t) => s.nextPutAll_(t);
