# The Long and Winding Road to High-Performance Smalltalk

*How building an assembler, then a Smalltalk VM, then porting a completely
different language's virtual machine, ended with Smalltalk running faster than
any of it.*

---

## Where this ends up

One virtual machine. Two languages — Dart and Smalltalk — sharing a single
object model, a single garbage collector, a single optimizing compiler, and a
single ARM64 backend. Smalltalk methods and Dart methods call each other
directly, and when the compiler is finished with them, the Smalltalk ones run
at **exactly** the speed of the Dart ones: same intermediate code in, same
machine code out.

The benchmarks that used to take a quarter of a second now take five
milliseconds.

That's the destination. The road there went through three complete projects and
one genuinely humbling detour, and the detour is the interesting part.

---

## Chapter 1 — You can't write a JIT without an assembler

A just-in-time compiler's final act is writing machine code into memory and
jumping to it. So the first thing needed was something that could turn
instructions into bytes for Apple Silicon: **AArch64**.

The first version, **JASM**, took the easy road and used LLVM. LLVM's machine-code
layer (LLVM-MC) already knows every instruction encoding on every architecture,
and MCJIT can put the result in executable memory. Wrap it in a macro assembler
with 1990s MASM ergonomics — named subroutines, typed structs, calling the whole
Win32 API by name — and you have a working tool quickly.

But depending on LLVM means shipping a 100-megabyte dependency to emit a
four-byte instruction. So the assembler was rewritten from scratch, in Rust,
with no LLVM at all.

### The oracle trick

Here's the move that makes this tractable, and it's the single most reusable idea
in the whole story.

**Don't verify the new encoder by reading the manual. Verify it against LLVM.**

Both encoders get handed the same instruction. Both produce bytes. A differential
harness compares them byte for byte. LLVM is treated as an **oracle** — a
referee that is assumed correct and cannot be argued with. Any disagreement is a
bug in the new code, full stop, and the diff says exactly which bits are wrong.

Then you close the instruction set family by family: integer and memory, control
flow, scalar floating point, the whole NEON vector surface. The x86 side ended up
gated on **3,393 instruction forms**. Each verified encoding is recorded into a
corpus file, so afterwards the tests replay from the corpus and **LLVM is no
longer needed at all** — 165 tests pass with no LLVM present, 172 with it.

The dependency became a temporary scaffold. You climb it, then remove it.

That hand-written Rust encoder is the one that ended up inside the Smalltalk JIT.

---

## Chapter 2 — Standing on Strongtalk's shoulders

**Strongtalk** was a Smalltalk system released to the public in 2002 — first as
documentation, later as full C++ source. It was fast, and more importantly it was
*well explained*. Its lineage matters: Self pioneered adaptive optimization,
Strongtalk carried it forward and added an optional type system, and those ideas
went on to power Java's HotSpot, then V8, and then Dart. (Remember that last one.
It comes back.)

**MACVM** is not a port of Strongtalk. It's a from-scratch Apple Silicon VM built
to Strongtalk's *design*, in Rust. Reimplementing a strong, well-documented
design turns out to be one of the most rewarding ways to work: the hard thinking
was done in 1996, and it was written down.

What got built:

- **The object model** — classes with direct tagged pointers, no object table, a
  two-word header. Strongtalk's representation, not Squeak's.
- **A two-tier engine** — a plain bytecode interpreter for cold code, and a
  tier-1 optimizing JIT that takes over when code gets hot. Inline caches,
  polymorphic inline caches, type feedback, per-class customization, method and
  block inlining, and **deoptimization** — the ability to unwind an
  over-optimistic optimization safely, mid-execution, when an assumption breaks.
- **Garbage collection**, the one part that had to be entirely new: a
  generational scavenger plus a full compacting collector, both able to run
  **underneath live compiled stack frames** and move the objects those frames are
  holding, using precise maps of which register and stack slot contains what.

The payoff: on real workloads, **98.6–99.8% of executed work runs as compiled
native code**, and roughly 98.7% of methods that actually run get compiled. The
JIT is 30–130× faster than the interpreter it replaced.

---

## Chapter 3 — A VM you can actually live in

A fast VM you can't touch isn't much fun. Smalltalk's tradition is a *live
environment*, so MACVM grew one — via a foreign function interface that reaches
POSIX through `dlsym` and Cocoa through `objc_msgSend`, which turns out to be a
simpler dispatch story than it sounds.

On top of that, **two** complete GUIs sharing the same primitives:

1. **A faithful recreation of Strongtalk's 1996 hypertext programming
   environment** — rendered as HTML in a native Cocoa window. The truer read of
   what the original interface actually was.
2. **A native AppKit shell whose own interface is written in Smalltalk.** Real
   `NSButton`s and `NSOutlineView`s, driven by a Smalltalk VM pinned to the main
   thread. No HTML, no JavaScript. The environment *is* the language, all the way
   up.

Both ship a live class browser whose accepts compile straight into the running
VM, find-tools over an indexed image, a workspace, and a metrics dashboard.

Then, because it's more fun than not: a **GamePane** — a Metal-backed drawing
surface with retained GPU sprites, a 60fps frame loop, keyboard input, and sound
effects and music written in ABC notation. Retro games, in Smalltalk. Breakout, a
live zooming Mandelbrot, and a version of that zoom where **four separate worker
VMs** — each with its own heap, JIT, and collector on its own core — compute
alternating bands of every frame, hitting about 2.65 CPUs of real utilization.
Those workers are share-nothing and message-passing, with Erlang/OTP-style
supervision trees: a crashed worker is reported as an ordinary message and
restarted by policy.

And an optional static type checker in Strongtalk's spirit — advisory, never
changing what runs. The **entire core library** is annotated: 739 method
signatures, zero findings. Running it against a real 155-class world flushed out
five genuine soundness bugs *in the checker itself*, which is the only way that
ever happens.

---

## Chapter 4 — The honest yardstick

A JIT needs a real comparison, and for Smalltalk that's **Cog** — the mature JIT
behind Squeak and Pharo, with decades of engineering behind it.

The first comparisons were wrong. Not slightly wrong — wrong in *both
directions*. Millisecond clocks were truncating benchmarks that finish in under
five milliseconds, and the Pharo-side translation of the benchmark wasn't
faithful, so the two systems weren't running the same work.

Fixing the harness mattered more than any optimization: microsecond clocks on
both sides, checksum-verified identical workloads, interleaved rounds in the same
session. And the honest numbers pointed at real gaps, which produced real
fixes — inlining the special selectors, sizing the nursery properly, frameless
leaf methods.

The scoreboard afterwards, seven benchmarks, all ahead:

| benchmark | MACVM | Cog | |
|---|---:|---:|---|
| arith | 34.0 | 51.1 | **1.50× faster** |
| fib | 135.4 | 181.0 | **1.34× faster** |
| sieve | 2.3 | 3.5 | **1.48× faster** |
| dict | 7.7 | 12.0 | **1.55× faster** |
| alloc | 12.5 | 14.2 | **1.13× faster** |
| richards | 18.8 | 21.9 | **1.17× faster** |
| deltablue | 2.7 | 3.5 | **1.27× faster** |

**The lesson: your measuring instrument is part of your result.** A benchmark you
haven't tried to break is a rumour.

---

## Chapter 5 — The humbling

Faster than Cog. Good. So: faster than what else?

**Dart.** Specifically Dart 1.x — the last version of the language before Dart 2
threw away the optional-typing model. Dart's designers came out of Strongtalk;
Dart 1 is arguably the last member of that family to keep Strongtalk's defining
idea. Same lineage, different branch. A fair fight.

It wasn't close. Dart was *much* faster.

To be sure that was real and not a measurement artifact, the Dart VM had to run
on the same machine, natively. Which meant porting it — and here's the surprise:
the port was nearly trivial.

Dart 1.24.3 already shipped a **complete, Apple-ABI-aware ARM64 backend**. It had
compiled Flutter apps for iPhones in 2017. It even already reserved the platform
register macOS requires. But on Apple hardware, that backend had only ever run in
**ahead-of-time** mode — code generated on a build machine, never patched at
runtime. The proof was a comment in the source: on iOS, the instruction-cache
flush is marked unreachable, *because iOS Dart never generates code at runtime*.

So the entire macOS-ARM64-JIT gap was: teach it to allocate executable memory
Apple's way, and flush the instruction cache. **Roughly ten lines and a code-signing
entitlement.** A 2017 VM woke up on 2026 hardware.

Then Cocoa support was added to Dart the same way it had been added to Smalltalk,
and the benchmarks ran again on equal ground. The result held. Digging into *why*
produced several genuine speedups for MACVM — but the remaining gap wasn't a
missing trick. **Dart's compiler was simply better than mine**, and it was better
by an amount I wasn't going to close by hand.

That's a bad afternoon. It's also useful information.

---

## Chapter 6 — If you can't beat it, run on it

Here's the reframe. I wanted fast Smalltalk. I had built a Smalltalk VM to *get*
fast Smalltalk. The VM was the means, not the goal.

There was a better compiler sitting right there. **What if Smalltalk ran on it?**

Not transpiled to Dart source. Compiled by Dart's own optimizing compiler, as a
second front-end to the same machine.

And the Dart VM turned out to be built for exactly this, almost by accident. It
selects a front-end **per function** — every function object carries a marker
saying which parser produced it, so the VM can already host more than one
language. In Dart 1 that machinery is compiled but dormant.

So: reuse that slot for Smalltalk. Add a Smalltalk reader and IL emitter,
structured exactly the way the Cocoa bridge was. Hook **one branch** into the
compiler. Everything downstream is reused *unchanged* — the SSA construction, the
optimizer, the inliner, the register allocator, the ARM64 backend, the garbage
collector, the inline caches, deoptimization, and the whole of `dart:core`.

Smalltalk's genuinely alien bits get desugared on the way in: `^` returning
through enclosing blocks, the metaclass tower, and `doesNotUnderstand:` mapping
onto Dart's `noSuchMethod`.

The milestone that defined success was deliberately small: *one Smalltalk method,
JIT-compiled by the Dart VM, returning the right answer when called from Dart.*
Everything before it was scaffolding. Everything after it was breadth.

### The numbers

Against MACVM — my own hand-built Smalltalk VM, the one that beat Cog on all
seven benchmarks:

| workload | MACVM | Smalltalk-on-Dart |
|---|---:|---:|
| fib(30) | 262 ms | **5 ms** |
| 50M-iteration loop | 5,066 ms | **22 ms** |
| 2M block calls | 331 ms | **4 ms** |
| 2M allocations | 358 ms | **5 ms** |

**52× to 230× faster.**

And the number I find most satisfying — the cost of *being Smalltalk* on this VM,
compared to writing the same thing in Dart: **1.00× on loops.** Not close to
free. Free. Same IL in, same machine code out; the compiler cannot tell which
language the code came from. Sends still cost about 2.5× while Smalltalk methods
remain non-inlinable, which is the next thing to fix rather than a wall.

The real corpus files — `richards.mst`, `deltablue.mst` — run **verbatim**,
unmodified, on the new VM.

---

## Chapter 7 — Building tools an agent can actually use

All three projects were built with AI agents doing a large share of the work, and
that changed how the tools themselves were designed. Not prompt tricks — the
*plumbing* is different. Five things mattered:

### 1. Give the machine a referee

The oracle from Chapter 1 is the template. An agent writing instruction encoders
will produce confident, plausible, wrong bytes. Arguing with it is useless;
LLVM's disagreement is not. A differential harness converts "I think this is
right" into a hard pass/fail with the wrong bits highlighted — and the corpus
turns every settled case into a permanent regression test.

Wherever a ground truth exists, wire it in and let it be the judge.

### 2. Give it one control plane, and make it a real language

MACVM embeds a full Tcl interpreter that can inspect a **live, running VM**:
disassemble a compiled method, dump the JIT code cache, read an inline cache's
resolved classes, toggle tracing flags without restarting. Because it's a real
language and not a command list, a diagnostic session is a *script* — loop over
every selector in a class, reproduce a fault, dump the exact state, replay it
tomorrow with one command.

MACDART took the same idea further and collapsed *everything* onto one channel:
the VM's own debug service. GUI control, introspection, and event streams all
ride a single socket, so an agent can click buttons, read panels, set
breakpoints, and inspect the heap through one connection. Three sockets became
one; the GUI became scriptable; nothing needed a second protocol.

### 3. Let it see

An agent cannot judge a user interface it cannot look at. So the workspace can
render any part of itself to a PNG offscreen — no screen recording permission, no
window needing to be visible — and the agent reads the image back and *checks*.
That closed loop caught a whole class of bug that passes every functional test:
a calculator whose display was silently centred instead of right-aligned, a
fractal that was rendering perfectly and compositing invisibly.

### 4. Write the constraints down before the code

Every subsystem here has a plan document written *first*, arguing the
constraints once: why user code must run in a particular isolate, why the wire
format carries absolute coordinates, what the failure containment rules are. They
exist because an agent starting fresh tomorrow reads the document instead of
re-deriving — usually differently.

### 5. Record the laws that failures teach you

This is the one I'd push hardest. Every hard-won trap became a written rule:

- *Driving a UI over a socket is not a faithful test of a mouse click* — the
  socket path drains a queue the click path doesn't, so one works while the other
  silently does nothing. Symptom of a whole bug family.
- *An offscreen snapshot force-renders*, so screenshots can look perfect while
  the live window is stale.
- *Probe a Cocoa selector before building on it* — an unknown one aborts the
  process, so a typo isn't a bug, it's a crash.
- *The dynamic bridge marshals only eight floating-point arguments in registers* —
  the ninth silently becomes garbage. A method took two rectangles, and everything
  drew invisibly with no error at all.

Each of those cost hours once. Written down, they cost nothing again — and they
are exactly the knowledge an agent has no way to acquire on its own.

There's also a knowledge base underneath all of it: a 158MB SQLite mirror of the
live Objective-C runtime — **482,000 method signatures** pre-classified into the
exact register shapes the calling convention needs. When the answer is
lookup-able, don't make anything guess.

---

## Where it stands

A single Apple Silicon VM that runs Dart and Smalltalk side by side, both JIT
compiled by the same optimizing compiler, sharing one heap and one collector.
A native workspace hosting both languages, with hot reload that preserves live
object state across a class redefinition, a working debugger, a game pane, and
searchable help generated from the VM's own sources so it can't drift from the
language actually running.

Three projects, one abandoned lead, and a Smalltalk that got fast by giving up on
having its own virtual machine.

The assembler is still in there, though. It's what MACVM writes its machine code
with.

---

### Notes for the video

Beats worth putting on screen: the byte-for-byte diff of two encoders
disagreeing; the ten-line diff that woke up a 2017 VM; the Cog scoreboard *before
and after* the harness was fixed; the 262ms → 5ms number, held on screen; and the
1.00× loop tax, which is the real punchline.

The emotional arc is: build everything yourself → beat the respected incumbent →
get beaten badly by an outsider → make the outsider work for you. Chapter 5 is
where the audience is on your side, so don't rush it.
