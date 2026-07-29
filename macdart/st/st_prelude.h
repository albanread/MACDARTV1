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
