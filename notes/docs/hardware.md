# Reaching the hardware without C

## Functions: @_extern(c)

Glibc's Swift module leaves out a lot (epoll, eventfd, `accept4`, `unshare`, `getrandom`). Declare them in Swift;
each is the C function itself, so a call is a direct call:

```swift
@_extern(c, "epoll_wait") public func sys_epoll_wait(_ epfd: Int32, _ events: UnsafeMutableRawPointer,
                                                     _ max: Int32, _ timeout: Int32) -> Int32
```

(`.enableExperimentalFeature("Extern")` on the target.) The same works for:

- **io_uring** (the [`IORing`](../Sources/IORing/IORing.swift) module): `syscall(2)` with numbers 425, 426 and 427
  (the same on x86-64 and arm64). Map the rings with `mmap`, move their heads and tails through `Atomic<UInt32>` over
  the mapped memory, and write the entries at the kernel's offsets (check them once with a C program). Kernel 6.8 and 7.0 lay out the provided-buffer registration's reserved
  words differently, so test on both.
- **SQLite's B-tree:** build the unmodified amalgamation with `SQLITE_PRIVATE` defined empty, and its internal
  functions (`sqlite3BtreeCursor`, `sqlite3BtreeIndexMoveto`, `sqlite3VdbeRecordUnpack`, ...) become callable with
  `@_extern(c)` and opaque pointers. Call `sqlite3BtreePayloadSize` before `sqlite3BtreePayloadFetch`: the first
  parses the cell, the second only reads what it left.

## Instructions: import Builtin

Swift has no counterpart to C's `<immintrin.h>`, but the compiler's `Builtin` module exposes LLVM's target
intrinsics. With the hidden `-enable-builtin-module` flag, a file can `import Builtin` and call, for example,
`llvm.x86.sha256rnds2` on a `SIMD4<UInt32>`'s storage:

```swift
#if arch(x86_64)
import Builtin

@inline(__always) private func rounds2(_ cdgh: SIMD4<UInt32>, _ abef: SIMD4<UInt32>, _ wk: SIMD4<UInt32>) -> SIMD4<UInt32> {
    var r = SIMD4<UInt32>()
    r._storage._value = Builtin.int_x86_sha256rnds2(cdgh._storage._value, abef._storage._value, wk._storage._value)
    return r
}
#endif
```

`-parse-stdlib` works too, but parses the whole file as the standard library; `-enable-builtin-module` changes
nothing else. Both are hidden flags, so pin the toolchain: a change would break the build, not the output.

What makes it safe:

1. **A module of its own, with the feature enabled for it alone.** Without the feature LLVM aborts ("Cannot select:
   intrinsic"); with it enabled for a whole app, the compiler may use those instructions anywhere. In `Package.swift`:
   `.unsafeFlags(["-enable-builtin-module", "-Xcc", "-msha", "-Xcc", "-mssse3", "-Xcc", "-msse4.1"])`, chosen by
   `#if arch(x86_64)`. AVX-512 code needs a module separate from 128-bit code for the same reason.
2. **An `@inline(never)` entry point**, so no optimization carries those instructions into a module built without
   them.
3. **CPUID, not `/proc/cpuinfo`.** glibc's `__x86_get_cpuid_feature_leaf` (`<sys/platform/x86.h>`) reports a feature
   *usable* (the CPU has it and the kernel enables it), and reads nothing outside the process. See `CPUFeatures`.
4. **A self-check at start-up** against the portable code, on inputs that take every path, before using it.
5. **Selector immediates must be constants.** `pclmulqdq`'s selector is an `immarg`. Passed through a
   `@_transparent` wrapper, it becomes a literal only once the optimizer runs: an unoptimized build fails with
   "immarg operand has non-immediate parameter". Build such modules with `-O` even in debug builds.

Results: SHA-NI took about 1 µs per request off token checks. PCLMULQDQ folding made the gzip CRC about four times
faster than eight-byte tables, and VPCLMULQDQ widened it to 256 bytes per step on AVX-512 CPUs. The fold follows
Intel's "Fast CRC Computation for Generic Polynomials Using PCLMULQDQ Instruction" (2009), with the constants Linux's
crc32-pclmul uses. Folding a lane D bits forward multiplies its halves by x^(D+32) and x^(D−32) mod P, bit-reflected;
that formula regenerates every constant, which is how to get the ones for new distances.

## What's still out of reach

No inline assembly. bcrypt's key schedule (the [`Bcrypt`](../Sources/Bcrypt/Bcrypt.swift) module), written out per
lane count and interleaved so the compiler only has registers to choose, still runs at 25 ms per cost-10 login on
x86 against 20 for hand-written assembly: LLVM spills registers at four or five lanes.
