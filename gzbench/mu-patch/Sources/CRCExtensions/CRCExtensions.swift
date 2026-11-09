// CRC-32 (gzip's polynomial) on the x86 carry-less multiply (PCLMULQDQ): 64 bytes folded per step, then down to 32
// bits with a Barrett reduction, as in Intel's "Fast CRC Computation for Generic Polynomials Using PCLMULQDQ
// Instruction" (2009), with the constants Linux's crc32-pclmul uses for this polynomial. Swift reaches the instruction
// only through its `Builtin` module, which this module imports (with the compiler's hidden -enable-builtin-module
// flag, as SHAExtensions does), and it is built with PCLMULQDQ and SSE4.1 enabled (Package.swift): only a CPU that has
// them may run any of it. Gzip checks CPUID and the result against its table first; nothing here is inlinable.
#if arch(x86_64)
import Builtin

/// The CRC register (not complemented) after the `count` bytes at `data`, a multiple of 16 and at least 64, starting
/// from `crc`. Never inlined: its instructions must stay in this module.
@inline(never) public func crc32Fold(_ crc: UInt32, _ data: UnsafeRawPointer, count: Int) -> UInt32 {
    // x^(4*128+32) and x^(4*128-32), x^(128+32) and x^(128-32), x^64, all mod P, bit-reflected; then P and floor(x^64 / P).
    let fold4 = SIMD2<UInt64>(0x1_5444_2BD4, 0x1_C6E4_1596)
    let fold1 = SIMD2<UInt64>(0x1_7519_97D0, 0x0_CCAA_009E)
    let fold64 = SIMD2<UInt64>(0x1_63CD_6124, 0)
    let barrett = SIMD2<UInt64>(0x1_DB71_0641, 0x1_F701_1641)
    let low32 = SIMD2<UInt64>(0xFFFF_FFFF, 0)
    var x1 = load(data, 0) ^ SIMD2(UInt64(crc), 0)
    var x2 = load(data, 16)
    var x3 = load(data, 32)
    var x4 = load(data, 48)
    var i = 64
    while count - i >= 64 {
        x1 = fold(x1, fold4) ^ load(data, i)
        x2 = fold(x2, fold4) ^ load(data, i + 16)
        x3 = fold(x3, fold4) ^ load(data, i + 32)
        x4 = fold(x4, fold4) ^ load(data, i + 48)
        i += 64
    }
    x1 = fold(x1, fold1) ^ x2
    x1 = fold(x1, fold1) ^ x3
    x1 = fold(x1, fold1) ^ x4
    while count - i >= 16 {
        x1 = fold(x1, fold1) ^ load(data, i)
        i += 16
    }
    // 128 bits to 64 (with 32 zero bits appended), then to 32 more.
    x1 = multiply(fold1, x1, 0x01) ^ SIMD2(x1[1], 0)
    x1 = multiply(x1 & low32, fold64, 0x00) ^ SIMD2(x1[0] >> 32 | x1[1] << 32, x1[1] >> 32)
    // Barrett: q = (x mod x^32) * floor(x^64 / P), then x + (q mod x^32) * P; the CRC is bits 32...63.
    var q = multiply(x1 & low32, barrett, 0x10)
    q = multiply(q & low32, barrett, 0x00)
    return UInt32(truncatingIfNeeded: (q ^ x1)[0] >> 32)
}

@inline(__always) private func load(_ data: UnsafeRawPointer, _ offset: Int) -> SIMD2<UInt64> {
    data.loadUnaligned(fromByteOffset: offset, as: SIMD2<UInt64>.self)
}

/// One 128-bit fold: the low half times `k`'s low, the high half times `k`'s high.
@inline(__always) private func fold(_ x: SIMD2<UInt64>, _ k: SIMD2<UInt64>) -> SIMD2<UInt64> {
    multiply(x, k, 0x00) ^ multiply(x, k, 0x11)
}

/// PCLMULQDQ: the carry-less product of `a`'s half chosen by `select`'s bit 0 and `b`'s chosen by its bit 4.
@_transparent private func multiply(_ a: SIMD2<UInt64>, _ b: SIMD2<UInt64>, _ select: Int8) -> SIMD2<UInt64> {
    var r = SIMD2<UInt64>()
    r._storage._value = Builtin.int_x86_pclmulqdq(a._storage._value, b._storage._value, select._value)
    return r
}
#endif
