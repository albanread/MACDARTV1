// The Smalltalk PRELUDE (ST_PLAN.md Sprint 9) — auto-loaded into its own
// `st:prelude` library by the first stLoad, so every user program sees the
// exception hierarchy and the system utilities. Written in the same .mst
// dialect user code uses; the `<stprim: name>` pragma makes a method body a
// direct call to the named dart:cocoa helper (self + params as arguments) —
// the same primitive mechanism MACVM's own kernel uses.
//
// Deliberately small: Exception/Error carry a messageText and signal through
// the Dart exception machinery (so ensure:/NLR unwinding are exact), and
// STSystem exposes the VM's Become primitive — the feature MACVM had to drop.

#ifndef MACDART_ST_ST_PRELUDE_H_
#define MACDART_ST_ST_PRELUDE_H_

namespace st {

static const char* kPreludeSource = R"PRELUDE(
"── The exception hierarchy ──────────────────────────────────────────"
Object subclass: Exception [
    | messageText |
    messageText [ ^messageText ]
    messageText: t [ messageText := t ]
    description [ ^messageText ]
    signal [ <stprim: stSignal> ]
    signal: t [ messageText := t. ^ self signal ]
    "Handler actions (ANSI), valid only while my handler runs: return: forces
     the on:do: value, retry re-evaluates the protected block, pass resignals to
     the next enclosing handler. Each unwinds to the stOnDo that caught me."
    return: aValue [ <stprim: stExcReturn> ]
    return [ <stprim: stExcReturnNil> ]
    retry [ <stprim: stExcRetry> ]
    pass [ <stprim: stExcPass> ]
]

"Class-side `Error signal: 'msg'` needs no method here: the IL builder
 desugars a class-side signal/signal: send to `Cls new signal[: msg]`
 (the ANSI Exception-class behaviour) — a static method of the same name
 would collide with the instance member under Dart's rules."
Exception subclass: Error [ ]

"The standard error hierarchy (so `on: ZeroDivide do:` names a real class, not
 nil). A native Dart division by zero is reified as a ZeroDivide by stOnDo;
 other native errors reify as a plain Error."
Error subclass: ArithmeticError [ ]
ArithmeticError subclass: ZeroDivide [ ]
Error subclass: MessageNotUnderstood [ ]
Exception subclass: Warning [ ]

"── The system object (corpus surface: Smalltalk millisecondClock) ──"
Object subclass: Smalltalk [
    Smalltalk class >> millisecondClock [ <stprim: stMillisecondClock> ]
    Smalltalk class >> microsecondClock [ <stprim: stMicrosecondClock> ]
    Smalltalk class >> gcScavenge [ <stprim: stGcScavenge> ]
    Smalltalk class >> gcFull [ <stprim: stGcFull> ]
    Smalltalk class >> gcStats [ <stprim: stGcStats> ]
]

"── WriteStream (the print protocol's other half) ────────────────────
 Buffers string pieces in a Dart List; contents joins. printOn: methods
 drive it via nextPutAll:/space/<<; `x printString` (the stPrintOf
 helper) builds one, sends printOn:, and answers the contents."
Object subclass: WriteStream [
    | buf |
    WriteStream class >> on: aCollection [ | s | s := self basicNew. s initWS. ^s ]
    WriteStream class >> new [ | s | s := self basicNew. s initWS. ^s ]
    initWS [ buf := STSystem newList ]
    nextPutAll: aString [ buf add: aString. ^aString ]
    nextPut: aChar [ buf add: aChar. ^aChar ]
    space [ ^self nextPutAll: ' ' ]
    tab [ ^self nextPutAll: '	' ]
    << x [ ^ self nextPutAll: (STSystem displayOf: x) ]
    print: x [ ^ self nextPutAll: (STSystem printOf: x) ]
    show: x [ ^ self nextPutAll: (STSystem displayOf: x) ]
    contents [ ^ STSystem joinList: buf ]
]

"── The reified message (Sprint 13: doesNotUnderstand:) ──────────────
 When a send misses everything — the receiver's chain AND the inherited
 extension-holder protocol — and the receiver defines doesNotUnderstand:,
 the runtime builds one of me (selector in keyword spelling, arguments as
 an Array) and dispatches doesNotUnderstand: with it. The ObjcRef
 passthrough (`pi processName`) is built on exactly this."
Object subclass: STMessage [
    | selector arguments |
    setSelector: s arguments: a [ selector := s. arguments := a ]
    selector [ ^selector ]
    arguments [ ^arguments ]
    argument [ ^arguments at: 1 ]
    printOn: ws [ ws nextPutAll: 'message(' , selector , ')' ]
]

"── Global variables (Sprint 11c) ────────────────────────────────────
 The world image's globals (Transcript := TranscriptStream new,
 CharacterTable, ...) live as static Fields on this holder, created by
 the compiler on first reference. Class names win READS, so the prelude
 bridge classes stay authoritative."
Object subclass: STGlobals [ ]

"── System utilities: the VM's Become, exposed ───────────────────────"
Object subclass: STSystem [
    STSystem class >> forward: a to: b [ <stprim: stBecomeForward> ]
    STSystem class >> become: a with: b [ <stprim: stBecome> ]
    STSystem class >> newList [ <stprim: stNewList> ]
    STSystem class >> sizeOf: c [ <stprim: stSizeOf> ]
    STSystem class >> removeFirst: l [ <stprim: stListRemoveFirst> ]
    STSystem class >> insertFirst: l value: x [ <stprim: stListInsertFirst> ]
    STSystem class >> remove: l value: x [ <stprim: stListRemove> ]
    STSystem class >> includes: l value: x [ <stprim: stListIncludes> ]
    STSystem class >> sortedOf: l [ <stprim: stSortedOf> ]
    STSystem class >> joinList: l [ <stprim: stJoinList> ]
    STSystem class >> displayOf: x [ <stprim: stDisplayOf> ]
    STSystem class >> printOf: x [ <stprim: stPrintOf> ]
    STSystem class >> split: s by: charCode [ <stprim: stSplitByChar> ]
]

"── Alien: raw memory access behind the FFI floor (ST_PORTING_PLAN §3a) ──
 MACVM's built-in FFI wrapper. The corpus ASSUMES it (61_posix_io's
 NativeBuffer, 30_date_time's clock, 61a_accelerate's NativeFloatArray) but
 never defines it, so MACDART provides it here. addr+size name a span (an
 mmap page or an FFI result address); accessors are 1-BASED byte offsets,
 bounds-checked HERE so the raw peek/poke native never reads out of the span."
Object subclass: Alien [
    | addr size |
    Alien class >> forAddress: a size: n [ ^self new setAddr: a size: n ]
    setAddr: a size: n [
        (a > 0 and: [ n >= 0 ]) ifFalse: [ ^self error: 'Alien: bad address or size' ].
        addr := a. size := n ]
    address [ ^addr ]
    size [ ^size ]
    byteAt: i [
        (i < 1 or: [ i > size ]) ifTrue: [ ^self error: 'Alien byteAt: out of bounds' ].
        ^Alien peekByte: addr + i - 1 ]
    byteAt: i put: v [
        (i < 1 or: [ i > size ]) ifTrue: [ ^self error: 'Alien byteAt:put: out of bounds' ].
        ^Alien pokeByte: addr + i - 1 value: v ]
    doubleAt: i [
        (i < 1 or: [ i + 7 > size ]) ifTrue: [ ^self error: 'Alien doubleAt: out of bounds' ].
        ^Alien peekDouble: addr + i - 1 ]
    doubleAt: i put: v [
        (i < 1 or: [ i + 7 > size ]) ifTrue: [ ^self error: 'Alien doubleAt:put: out of bounds' ].
        ^Alien pokeDouble: addr + i - 1 value: v ]
    signedLongAt: i [
        (i < 1 or: [ i + 7 > size ]) ifTrue: [ ^self error: 'Alien signedLongAt: out of bounds' ].
        ^Alien peekLong: addr + i - 1 ]
    signedLongAt: i put: v [
        (i < 1 or: [ i + 7 > size ]) ifTrue: [ ^self error: 'Alien signedLongAt:put: out of bounds' ].
        ^Alien pokeLong: addr + i - 1 value: v ]
    Alien class >> peekByte: a [ <stprim: stPeekByte> ]
    Alien class >> pokeByte: a value: v [ <stprim: stPokeByte> ]
    Alien class >> peekDouble: a [ <stprim: stPeekF64> ]
    Alien class >> pokeDouble: a value: v [ <stprim: stPokeF64> ]
    Alien class >> peekLong: a [ <stprim: stPeekI64> ]
    Alien class >> pokeLong: a value: v [ <stprim: stPokeI64> ]
]

"── The collection bridge (Sprint 11: corpus breadth) ────────────────
 An Array IS a Dart fixed-length List (1-based at:/at:put: through the
 universal helpers); an OrderedCollection wraps a growable Dart List.
 Enough protocol for the app-tier corpus; grown as files demand."
Object subclass: Array [
    Array class >> new: n [ <stprim: stNewListSized> ]
    Array class >> with: a [ <stprim: stList1> ]
    Array class >> with: a with: b [ <stprim: stList2> ]
    Array class >> with: a with: b with: c [ <stprim: stList3> ]
    Array class >> with: a with: b with: c with: d [ <stprim: stList4> ]
]

Object subclass: OrderedCollection [
    | l |
    OrderedCollection class >> new [ | c | c := self basicNew. c initOC. ^c ]
    initOC [ l := STSystem newList ]
    add: x [ l add: x. ^x ]
    addLast: x [ ^ self add: x ]
    addFirst: x [ ^ STSystem insertFirst: l value: x ]
    removeFirst [ ^ STSystem removeFirst: l ]
    do: b [ l do: b ]
    size [ ^ STSystem sizeOf: l ]
    isEmpty [ ^ (STSystem sizeOf: l) = 0 ]
    notEmpty [ ^ ((STSystem sizeOf: l) = 0) not ]
    at: i [ ^ l at: i ]
    at: i put: v [ ^ l at: i put: v ]
    first [ ^ l at: 1 ]
    last [ ^ l at: (STSystem sizeOf: l) ]
    remove: x [ ^ STSystem remove: l value: x ]
    includes: x [ ^ STSystem includes: l value: x ]
    copy [ | c | c := OrderedCollection new. l do: [:e | c add: e]. ^c ]
    asSortedCollection [ | c | c := OrderedCollection new.
        (STSystem sortedOf: l) do: [:e | c add: e]. ^c ]
    asOrderedCollection [ ^self ]
]

"A Dictionary IS a Dart Map: at:/at:put:/size/isEmpty/do: flow through the
 universal helpers, so the class supplies only construction and the
 Map-specific probes."
Object subclass: Dictionary [
    Dictionary class >> new [ <stprim: stNewMap> ]
]

"── The Transcript ───────────────────────────────────────────────────
 Class-side (a cascade to a class name sends class-side messages —
 `Transcript show: 'x'; cr`). show: buffers; cr emits the line — into
 the workspace's Transcript pane when hosted there, else stdout."
Object subclass: Transcript [
    Transcript class >> show: s [ <stprim: stTrShow> ]
    Transcript class >> cr [ <stprim: stTrCr> ]
    Transcript class >> showCr: s [ Transcript show: s. Transcript cr ]
]
)PRELUDE";

}  // namespace st

#endif  // MACDART_ST_ST_PRELUDE_H_
