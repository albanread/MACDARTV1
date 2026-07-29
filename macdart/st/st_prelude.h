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
]

"Class-side `Error signal: 'msg'` needs no method here: the IL builder
 desugars a class-side signal/signal: send to `Cls new signal[: msg]`
 (the ANSI Exception-class behaviour) — a static method of the same name
 would collide with the instance member under Dart's rules."
Exception subclass: Error [ ]

"── System utilities: the VM's Become, exposed ───────────────────────"
Object subclass: STSystem [
    STSystem class >> forward: a to: b [ <stprim: stBecomeForward> ]
    STSystem class >> become: a with: b [ <stprim: stBecome> ]
    STSystem class >> newList [ <stprim: stNewList> ]
    STSystem class >> sizeOf: c [ <stprim: stSizeOf> ]
    STSystem class >> removeFirst: l [ <stprim: stListRemoveFirst> ]
    STSystem class >> insertFirst: l value: x [ <stprim: stListInsertFirst> ]
]

"── The collection bridge (Sprint 11: corpus breadth) ────────────────
 An Array IS a Dart fixed-length List (1-based at:/at:put: through the
 universal helpers); an OrderedCollection wraps a growable Dart List.
 Enough protocol for the app-tier corpus; grown as files demand."
Object subclass: Array [
    Array class >> new: n [ <stprim: stNewListSized> ]
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
    asOrderedCollection [ ^self ]
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
