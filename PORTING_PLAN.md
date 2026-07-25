# MACDART — Porting Plan

**Goal:** A native **darwin-arm64 (Apple Silicon) JIT** build of the Dart **V1** VM, based on the last V1 release (**1.24.3**). We port the source; we do **not** reproduce Google's gclient/gyp/GN/CI machinery. ARM64 JIT only — no DBC interpreter, no Intel/ia32/x64, no other architectures.

**Reference repo:** `sdk/` (dart-lang/sdk @ tag 1.24.3, branch `macdart`). Treat as **read-only quarry**. We extract from it into our own owned tree and never edit it, so we can always `diff` our port against pristine upstream.

**Cross-version reference tags** (fetched into `sdk/`'s object store, depth-1, for study only — *not* our base):
- `1.25.0-dev.16.4` — the true last V1-language commit. Verified: adds only Fuchsia support over 1.24.3; **zero** Apple-Silicon content. Confirms 1.24.3 is the right base.
- `2.14.4` — earliest stable Dart with **native macOS arm64 JIT**. This is our implementation oracle.
- `3.5.0` — modern Dart; confirms the macOS arm64 JIT approach never changed. Ships the entitlement plists we'll copy.

Read any reference file without a checkout, e.g. `git show 2.14.4:runtime/vm/virtual_memory_posix.cc`.

---

## 1. The core insight — and why the hard part is already done

Dart 1.24.3 already ships a **complete, Apple-ABI-aware ARM64 backend** (assembler, disassembler, code patcher, stubs, intrinsics, flow-graph compiler). It compiled Flutter for iPhones in 2017 and already reserves `x18` as the platform register — exactly what macOS requires. But that backend ran on Apple hardware **only in AOT mode**. Proof, [cpu_arm64.cc:22](sdk/runtime/vm/cpu_arm64.cc:22):

```c
void CPU::FlushICache(uword start, uword size) {
#if HOST_OS_IOS
  // Precompilation never patches code so there should be no I cache flushes.
  UNREACHABLE();
#endif
```

On iOS the I-cache flush is `UNREACHABLE()` because iOS Dart never generates or patches code at runtime. So the runtime code-gen + self-modifying-code path has **never executed on Apple arm64.** That defines the project: make an already-correct arm64 backend emit into *live executable memory* under Apple's W^X rules.

**The pleasant surprise (established by mining V2):** the W^X mechanism this needs is **already present in 1.24.3** and is *the same mechanism upstream Dart still uses on macOS today*. I verified:

- `FLAG_write_protect_code` exists and **defaults to `true`** ([code_patcher.cc:13](sdk/runtime/vm/code_patcher.cc:13)) — the same macOS default as Dart 3.5.0.
- The full heap-level page-flip chain is present: `PageSpace::WriteProtectCode(bool)` → `HeapPage::WriteProtect` → `VirtualMemory::Protect` ([pages.cc:823,158](sdk/runtime/vm/pages.cc:823)). Executable pages are created **non-executable** (`create_executable = !FLAG_write_protect_code && is_executable`, [pages.cc:64](sdk/runtime/vm/pages.cc:64)), written while RW, then flipped to RX — never simultaneously writable+executable. That is strict W^X, exactly what Apple Silicon demands.
- `become.cc` and `object.cc` already bracket code mutation with the same flag.

This infrastructure was built for x64/ia32 JIT W^X and is **architecture-neutral** — it works unchanged on arm64. Upstream Dart 2.14→3.5 runs its macOS arm64 JIT on this exact model (`mprotect`-based page flips), and **never adopted the per-thread `pthread_jit_write_protect_np` toggle** — I confirmed the symbol appears nowhere in 2.14.4 or 3.5.0.

**Consequence:** the macOS-arm64-JIT delta from 1.24.3 is not a subsystem — it is ~10 lines plus an entitlement (§3). The QBEJIT per-thread-toggle pattern is **not needed**; it's demoted to a documented fallback (§4).

---

## 2. What we inherit vs. what we must build

| Concern | Status in 1.24.3 | Action |
|---|---|---|
| ARM64 codegen (assembler/compiler/stubs/intrinsics), Apple-ABI aware, `x18` reserved | ✅ Complete | Extract as-is |
| Object model, generational GC, isolates | ✅ Mature | Extract as-is |
| Language front-end (parser, checked mode, mirrors) — this *is* V1 | ✅ In-VM C++ | Extract as-is |
| Core libraries (`dart:core`, `async`, …) | ✅ 266k lines Dart in `sdk/sdk/lib` | Extract; snapshot at build |
| **W^X page-flip infra** (`write_protect_code`, `WriteProtectCode`, `HeapPage::WriteProtect`) | ✅ **Present, arch-neutral, default on** | **Reuse as-is** |
| Darwin OS layer (threads, signals, vm) | ✅ Exists for macOS-x64 + iOS | Extract; audit for arm64 |
| **`MAP_JIT` on executable allocations** | ❌ Absent (2017) | **Add ~5 lines** ([virtual_memory_macos.cc](sdk/runtime/vm/virtual_memory_macos.cc)) |
| **`CPU::FlushICache` on macOS arm64** | ❌ `#error` | **Add ~3 lines** (copy 2.14.4) |
| **`allow-jit` entitlement + codesign** | ❌ N/A in 2017 | **Add** (copy 3.5.0 plists) — or run ad-hoc for dev |
| Build system | gyp + early GN + gclient | **Replace** with our own CMake/ninja |
| Snapshot bootstrap | Google-hosted prebuilt SDK (sha1 stub only) | **Self-host** `gen_snapshot` natively |

---

## 3. The actual macOS-arm64-JIT delta (small, and each line has an upstream reference)

1. **I-cache flush** — [cpu_arm64.cc:41](sdk/runtime/vm/cpu_arm64.cc:41) is `#error`. Replace with the 2.14.4 body:
   ```c
   #if defined(DART_HOST_OS_MACOS) || defined(DART_HOST_OS_IOS)
     sys_icache_invalidate(reinterpret_cast<void*>(start), size);   // <libkern/OSCacheControl.h>
   ```
   Also stop the iOS `UNREACHABLE()` guard from applying to macOS (macOS *does* patch code).

2. **`MAP_JIT` allocation** — add to the executable-memory mmap in [virtual_memory_macos.cc](sdk/runtime/vm/virtual_memory_macos.cc), mirroring 2.14.4:
   ```c
   #if defined(DART_HOST_OS_MACOS) && !defined(DART_HOST_OS_IOS)
     if (is_executable && IsAtLeastOS10_14()) map_flags |= MAP_JIT;
   #endif
   ```
   Plus the small `IsAtLeastOS10_14()` helper. Note: 1.24.3 uses a `Reserve`+`Commit` split rather than 2.14's `AllocateAligned`, so the insertion point is the commit/reserve of the executable region, not a verbatim copy — but the logic is identical.

3. **Entitlement** — code-sign `dart`, `gen_snapshot`, and `run_vm_tests` with `com.apple.security.cs.allow-jit` (plists exist at `3.5.0:runtime/tools/entitlements/*.plist` — copy them). For local dev we can start **unsigned / ad-hoc**, which also works (see §4).

That is the whole W^X-specific delta. Everything else in Phase 2 is ordinary bring-up (getting the JIT pipeline to actually run), not W^X design.

---

## 4. Why `mprotect` + `MAP_JIT` is correct here (and the toggle isn't needed)

The QBEJIT house note (`MACVM/QBEJIT/design/macjitbuffer.md`) says "you cannot `mprotect` MAP_JIT pages — you must use `pthread_jit_write_protect_np`." Upstream Dart does the opposite and works. The reconciliation is the **hardened-runtime + entitlement** matrix:

| Config | How code memory is toggled | Dart uses it for |
|---|---|---|
| **Non-hardened** (unsigned / ad-hoc-signed dev binary) | plain `mprotect` RW↔RX; `MAP_JIT` optional | our **Phase-2 dev** path — zero friction |
| **Hardened + `com.apple.security.cs.allow-jit`** | `MAP_JIT` required; `mprotect` RW↔RX **permitted** by this entitlement | Dart's shipped **JIT `dart`** binary |
| Hardened + `allow-unsigned-executable-memory` | `mprotect` anywhere, no `MAP_JIT` | Dart's **AOT** runtime (not us) |

The `allow-jit` entitlement is precisely what makes `mprotect`-toggling of `MAP_JIT` pages legal under hardened runtime — so the QBEJIT constraint and Dart's practice are both correct, in different columns. Dart deliberately keeps strict W^X (`write_protect_code = true`, never maps RWX) so the *same binary* degrades gracefully to the non-hardened column when unsigned. The 3.5.0 rationale, verbatim at [code_patcher.cc:16] of that tag: *"allow-jit entitlement allows WX memory regions to be created — but we should not rely on this entitlement to be present."*

**Plan:** follow upstream exactly — dev unsigned (column 1), distribute with `allow-jit` (column 2), **no code change between them**. Keep the QBEJIT per-thread toggle in our back pocket only if a future hardened-runtime edge case ever rejects `mprotect`-on-`MAP_JIT`; upstream's multi-year track record says it won't.

---

## 5. Phased plan

### Phase 0 — Owned tree + it compiles
- Deterministic **extraction script** `sdk/ → macdart/`: copy `runtime/{vm,bin,platform,lib,include}` + `sdk/lib` + vendored `third_party/double-conversion`, **excluding** all `*_test.cc`, all non-arm64 arch files (`*_ia32*`, `*_x64*`, `*_arm.*`/`*_arm_*`, `*_mips*`, `*_dbc*`), simulators, observatory. Keeps `sdk/` pristine and the port reproducible.
- Hand-written **CMakeLists** with three targets: `libdart`, `gen_snapshot`, `dart`. Seed source lists from the `.gypi` manifests.
- Defines: `TARGET_ARCH_ARM64`, `HOST_OS_MACOS`, `HOST_ARCH_ARM64`, `DART_PRECOMPILED_RUNTIME=0` (JIT), `SECURE_SOCKET_DISABLED` (defer TLS).
- **Exit:** every extracted `.cc` compiles and links into `gen_snapshot` + `dart` (runtime crashes OK).

### Phase 1 — Snapshot bootstrap
- Build `gen_snapshot` (arm64, native) and run it to parse the core libs → emit `vm_isolate_snapshot.bin` + `isolate_snapshot.bin`. In-VM V1 front-end means it's self-contained; no prebuilt SDK, no cross-compile, no Rosetta.
- Link snapshots into `dart`; debug object-model / class-table init on darwin-arm64.
- **Exit:** `dart` boots, loads core libs from snapshot, reaches user-code execution.

### Phase 2 — ARM64 JIT bring-up
- Apply the three §3 changes (FlushICache, MAP_JIT, run unsigned).
- Bring up incrementally: stub/trampoline generation → first JIT-compiled function → inline-cache patching → full optimizing pipeline. The W^X page-flips are inherited, so debugging is "does our codegen run," not "does W^X work."
- **Exit:** `dart hello.dart` executes JIT-compiled arm64 code and prints. **This is the milestone.**

### Phase 3 — Platform completeness (`dart:io`)
- Audit `runtime/bin` darwin sources for arm64; bring up file/socket/process/stdio. Re-enable TLS (BoringSSL / system Security) only after core JIT is solid.
- **Exit:** real V1 programs (pub packages, file/network I/O) run.

### Phase 4 — Hardening & packaging
- Code-sign with `allow-jit` (copy 3.5.0 plists); verify hardened-runtime behavior.
- Port `run_vm_tests` (C++ unit tests) as the regression net, then the `language/` + `corelib/` Dart suites as the conformance oracle.
- Package a relocatable `dart-sdk`.

---

## 6. Primary risks (re-ranked after the V2 investigation)

1. **Snapshot format / pointer assumptions on arm64+macOS** (Phase 1) — now the highest *technical* unknown. Mostly de-risked by the iOS-arm64 work already in-tree, but the JIT snapshot path (vs. iOS's AOT path) is less trodden.
2. **Build-system + toolchain drift** (Phase 0) — 435k lines of 2017 C++ under clang 17; mechanical but broad. Front-loaded.
3. **`dart:io` / TLS scope creep** (Phase 3) — fenced off behind `SECURE_SOCKET_DISABLED` so it can't block the JIT milestone.
4. **W^X** — *downgraded from "the crux" to minor.* Infra inherited; delta is §3's ~10 lines with a line-for-line upstream reference. Residual risk only if we later need hardened runtime AND hit an `mprotect`-on-`MAP_JIT` refusal, for which QBEJIT's toggle is the ready fallback.

---

## 7. Immediate next action

Write the Phase 0 extraction script and first CMakeLists, then run the first compile to turn unknowns into a concrete error list. Everything after is burn-down.
