// gzip (RFC 1952) around one deflate block (RFC 1951): what a response becomes when the client accepts gzip and the
// body is big enough to gain from it (in practice the feed, about 4 to 5 KB). The block's Huffman codes are ISA-L's
// default table, the one its fastest level uses: a dynamic block header that ships with the library, whose code
// lengths are read out of it once. So a body is compressed in one pass, each literal or match written out as it is
// found, with no codes to build for it. Matches are found greedily through a hash of the next four bytes, as the
// fastest levels of zlib, libdeflate and ISA-L find them. The CRC-32 runs on the CPU's carry-less multiply where it
// has one (CRCExtensions), and eight bytes per step from tables otherwise. The tables live as long as the compressor,
// so compressing a body allocates nothing.
//
// The block header below is ISA-L 2.31.1's (igzip/hufftables_c.c, hufftables_default for a 32 KB window), under
// this notice:
//
//   Copyright(c) 2011-2016 Intel Corporation All rights reserved.
//
//   Redistribution and use in source and binary forms, with or without modification, are permitted provided that the
//   following conditions are met:
//     * Redistributions of source code must retain the above copyright notice, this list of conditions and the
//       following disclaimer.
//     * Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the
//       following disclaimer in the documentation and/or other materials provided with the distribution.
//     * Neither the name of Intel Corporation nor the names of its contributors may be used to endorse or promote
//       products derived from this software without specific prior written permission.
//
//   THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES,
//   INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
//   DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
//   SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
//   SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
//   WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE
//   USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#if arch(x86_64)
import CRCExtensions
import Syscalls
#endif

/// A compressor, owned by one thread.
public struct Gzip: ~Copyable, ~Sendable {
    /// The last position each 4-byte hash was seen at, plus `base`: entries below `base` are from an earlier body.
    private let head: UnsafeMutablePointer<Int32>
    private var base: Int32 = 1
    /// The table's codes (bit-reversed, as deflate sends them) and lengths: literals and end of block (0...256).
    private let literalCode: UnsafeMutablePointer<UInt16>
    private let literalBits: UnsafeMutablePointer<UInt8>
    /// A match length's whole code (3...258): its length symbol's code with the extra bits after it, and their count.
    private let lengthCode: UnsafeMutablePointer<UInt32>
    private let lengthBits: UnsafeMutablePointer<UInt8>
    /// The distance codes (0...29).
    private let distanceCode: UnsafeMutablePointer<UInt16>
    private let distanceBits: UnsafeMutablePointer<UInt8>
    /// CRC-32 tables for eight bytes at a time.
    private let crcTable: UnsafeMutablePointer<UInt32>
    /// `header`, kept here so a body doesn't go through the static array.
    private let headerBytes: UnsafeMutablePointer<UInt8>
    /// Whether the CRC runs on the carry-less multiply: the CPU has it, and it agreed with the tables at start.
    private var carryless = false

    private static let hashBits = 13
    private static let windowSize = 32768

    /// ISA-L's block header: BFINAL = 1, BTYPE = 2 (dynamic codes), the code lengths of all 286 literal/length and 30
    /// distance symbols; 110 bytes and 6 bits.
    private static let header: [UInt8] = [
        0xed, 0xfd, 0x09, 0x80, 0x1c, 0x45, 0xf9, 0xbf, 0x81, 0xf7, 0x66, 0x37, 0xd7, 0x24, 0x9b, 0x04,
        0x40, 0x45, 0x45, 0x52, 0x04, 0x20, 0x09, 0xcc, 0x2e, 0xbb, 0x9b, 0x3b, 0x81, 0x24, 0xbb, 0xb9,
        0x21, 0x17, 0x49, 0xb8, 0x04, 0x85, 0xde, 0x99, 0xde, 0x9d, 0x26, 0x33, 0xd3, 0x43, 0xf7, 0x4c,
        0x36, 0x8b, 0x08, 0xf1, 0x56, 0x51, 0xc1, 0xfb, 0x56, 0x54, 0xc4, 0x5b, 0x51, 0xf1, 0x16, 0x0d,
        0x89, 0x8a, 0x37, 0x78, 0xdf, 0x1a, 0x45, 0x05, 0xef, 0x20, 0xaa, 0xa0, 0x90, 0xfd, 0xff, 0x9f,
        0xf7, 0xad, 0x9e, 0xa9, 0xdd, 0xdd, 0x70, 0xfa, 0xfd, 0xfd, 0xbe, 0xbf, 0xff, 0xdf, 0xcd, 0x66,
        0x67, 0xba, 0xbb, 0xaa, 0xea, 0x7d, 0xdf, 0x7a, 0xeb, 0xad, 0x4f, 0xbd, 0xf5, 0x56, 0x35,
    ]
    private static let headerBits = 110 * 8 + 6

    public init() {
        head = .allocate(capacity: 1 << Self.hashBits)
        head.initialize(repeating: 0, count: 1 << Self.hashBits)
        literalCode = .allocate(capacity: 257)
        literalBits = .allocate(capacity: 257)
        lengthCode = .allocate(capacity: 259)
        lengthBits = .allocate(capacity: 259)
        distanceCode = .allocate(capacity: 30)
        distanceBits = .allocate(capacity: 30)
        crcTable = .allocate(capacity: 8 * 256)
        headerBytes = .allocate(capacity: Self.header.count)
        headerBytes.initialize(from: Self.header, count: Self.header.count)

        let (literalLengths, distanceLengths) = Self.codeLengths()
        let literalCodes = Self.canonicalCodes(literalLengths)
        let distanceCodes = Self.canonicalCodes(distanceLengths)
        for s in 0...256 {
            literalCode[s] = literalCodes[s]
            literalBits[s] = literalLengths[s]
        }
        lengthCode.initialize(repeating: 0, count: 259)
        lengthBits.initialize(repeating: 0, count: 259)
        for length in 3...258 {
            let (symbol, extraBits, extra) = Self.lengthSymbol(length)
            let bits = Int(literalLengths[symbol])
            lengthCode[length] = UInt32(literalCodes[symbol]) | UInt32(extra) << UInt32(bits)
            lengthBits[length] = UInt8(bits + extraBits)
        }
        for s in 0..<30 {
            distanceCode[s] = distanceCodes[s]
            distanceBits[s] = distanceLengths[s]
        }

        for n in 0..<256 {
            var c = UInt32(n)
            for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
            crcTable[n] = c
        }
        for n in 0..<256 {
            var c = crcTable[n]
            for k in 1..<8 {
                c = crcTable[Int(c & 0xFF)] ^ (c >> 8)
                crcTable[k * 256 + n] = c
            }
        }
        #if arch(x86_64)
        // Made-up bytes, both ways, at lengths that take every path of the fold.
        if Self.hasCarrylessMultiply {
            let sample = (0..<4103).map { UInt8(truncatingIfNeeded: $0 &* 131 &+ $0 >> 5) }
            var agree = true
            sample.withUnsafeBufferPointer { p in
                for n in [64, 80, 128, 1000, 4103] {
                    let tables = crc32(p.baseAddress!, n)
                    carryless = true
                    agree = agree && crc32(p.baseAddress!, n) == tables
                    carryless = false
                }
            }
            carryless = agree
        }
        #endif
    }

    #if arch(x86_64)
    /// PCLMULQDQ and SSE4.1, usable: CPUID leaf 1's ECX bits 1 and 19, read through glibc (<sys/platform/x86.h>:
    /// `CPUID_INDEX_1` is 0, and the usable ECX is word 4 + 2).
    private static var hasCarrylessMultiply: Bool {
        guard let leaf1 = sys_x86_get_cpuid_feature_leaf(0) else { return false }
        return leaf1[4 + 2] >> 1 & 1 != 0 && leaf1[4 + 2] >> 19 & 1 != 0
    }
    #endif

    deinit {
        head.deallocate()
        literalCode.deallocate()
        literalBits.deallocate()
        lengthCode.deallocate()
        lengthBits.deallocate()
        distanceCode.deallocate()
        distanceBits.deallocate()
        crcTable.deallocate()
        headerBytes.deallocate()
    }

    /// The most bytes `compress` writes for `count` bytes of input: no code is longer than 15 bits, so at most two
    /// bytes per input byte, plus the headers and the trailer.
    public static func bound(_ count: Int) -> Int { 2 * count + 256 }

    /// `input` as a gzip member into `out`, which has room for `bound(input.count)` bytes; returns how many it wrote.
    public mutating func compress(_ input: UnsafeRawBufferPointer, into out: UnsafeMutableRawBufferPointer) -> Int {
        let n = input.count
        precondition(n > 0 && out.count >= Self.bound(n))
        let src = input.baseAddress!.assumingMemoryBound(to: UInt8.self)
        let dst = out.baseAddress!.assumingMemoryBound(to: UInt8.self)
        // ID1 ID2, CM = deflate, no flags, no mtime, no extra flags, OS = Unix; then the block header.
        var w = BitWriter(dst)
        w.uint32LE(0x0008_8B1F)
        w.uint32LE(0)
        w.byte(0x00)
        w.byte(0x03)
        w.copy(headerBytes, bits: Self.headerBits)
        writeBody(src, n, &w)
        w.put(UInt64(literalCode[256]), Int(literalBits[256]))
        w.alignToByte()
        w.uint32LE(crc32(src, n))
        w.uint32LE(UInt32(truncatingIfNeeded: n))
        return w.offset
    }

    // ---------- the body ----------

    @inline(__always) private static func load32(_ p: UnsafePointer<UInt8>, _ i: Int) -> UInt32 {
        UnsafeRawPointer(p + i).loadUnaligned(as: UInt32.self)
    }

    /// Greedy matching: at each position, the last one with the same 4-byte hash, if its bytes match and it is in the
    /// window, written as a match; else the byte, as a literal.
    private mutating func writeBody(_ src: UnsafePointer<UInt8>, _ n: Int, _ w: inout BitWriter) {
        if Int(base) > Int(Int32.max) - n - 1 {
            head.update(repeating: 0, count: 1 << Self.hashBits)
            base = 1
        }
        let b = Int(base)
        var i = 0
        while i + 4 <= n {
            let v = Self.load32(src, i)
            let h = Int((v &* 0x9E37_79B1) >> UInt32(32 - Self.hashBits))
            let candidate = Int(head[h]) - b
            head[h] = Int32(b + i)
            if candidate >= 0 && i - candidate <= Self.windowSize && Self.load32(src, candidate) == v {
                var length = 4
                let limit = min(258, n - i)
                while length + 8 <= limit {
                    let x = UnsafeRawPointer(src + i + length).loadUnaligned(as: UInt64.self)
                        ^ UnsafeRawPointer(src + candidate + length).loadUnaligned(as: UInt64.self)
                    if x != 0 {
                        length += x.trailingZeroBitCount >> 3
                        break
                    }
                    length += 8
                }
                if length + 8 > limit {
                    while length < limit && src[i + length] == src[candidate + length] { length += 1 }
                }
                w.put(UInt64(lengthCode[length]), Int(lengthBits[length]))
                let distance = Self.distanceSymbol(i - candidate)
                let bits = Int(distanceBits[distance.code])
                w.put(UInt64(distanceCode[distance.code]) | UInt64(distance.extra) << UInt64(bits), bits + distance.extraBits)
                i += length
            } else {
                w.put(UInt64(literalCode[Int(src[i])]), Int(literalBits[Int(src[i])]))
                i += 1
            }
        }
        while i < n {
            w.put(UInt64(literalCode[Int(src[i])]), Int(literalBits[Int(src[i])]))
            i += 1
        }
        base = Int32(b + n + 1)
    }

    /// The literal/length code of a match length (3...258), its extra bits and their value.
    private static func lengthSymbol(_ length: Int) -> (code: Int, extraBits: Int, extra: Int) {
        let l = length - 3
        if l < 8 { return (257 + l, 0, 0) }
        if l == 255 { return (285, 0, 0) }
        let k = Int.bitWidth - 1 - l.leadingZeroBitCount
        let low = (l >> (k - 2)) & 3
        return (257 + 4 * (k - 1) + low, k - 2, l - ((4 | low) << (k - 2)))
    }

    /// The distance code of a distance (1...32768), its extra bits and their value.
    @inline(__always) private static func distanceSymbol(_ distance: Int) -> (code: Int, extraBits: Int, extra: Int) {
        let x = distance - 1
        if x < 4 { return (x, 0, 0) }
        let k = Int.bitWidth - 1 - x.leadingZeroBitCount
        let low = (x >> (k - 1)) & 1
        return (2 * k + low, k - 1, x - ((2 | low) << (k - 1)))
    }

    // ---------- the table ----------

    /// The code lengths the header carries: 286 literal/length and 30 distance ones (RFC 1951 3.2.7).
    private static func codeLengths() -> ([UInt8], [UInt8]) {
        var r = BitReader(header)
        // Read first, then checked: -Ounchecked drops a precondition's condition, reads and all.
        let final = r.take(1)
        let type = r.take(2)
        precondition(final == 1 && type == 2)
        let literalCount = r.take(5) + 257
        let distanceCount = r.take(5) + 1
        let codeLengthCount = r.take(4) + 4
        let order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
        var codeLengthLengths = [UInt8](repeating: 0, count: 19)
        for k in 0..<codeLengthCount { codeLengthLengths[order[k]] = UInt8(r.take(3)) }
        let codeLengthCodes = canonicalCodes(codeLengthLengths)
        var lengths: [UInt8] = []
        while lengths.count < literalCount + distanceCount {
            // The symbol whose (bit-reversed) code the next bits are: codes are prefix-free, so try them shortest first.
            var symbol = -1
            var code = 0
            for bits in 1...7 {
                code |= r.take(1) << (bits - 1)
                if let s = (0..<19).first(where: { Int(codeLengthLengths[$0]) == bits && Int(codeLengthCodes[$0]) == code }) {
                    symbol = s
                    break
                }
            }
            switch symbol {
            case 0..<16: lengths.append(UInt8(symbol))
            case 16: lengths += repeatElement(lengths.last!, count: 3 + r.take(2))
            case 17: lengths += repeatElement(0, count: 3 + r.take(3))
            case 18: lengths += repeatElement(0, count: 11 + r.take(7))
            default: preconditionFailure("not a code in the header")
            }
        }
        precondition(r.position == headerBits && literalCount == 286 && distanceCount == 30)
        return (Array(lengths[0..<286]), Array(lengths[286..<316]))
    }

    /// Canonical codes for `lengths` (RFC 1951 3.2.2), bit-reversed: deflate sends Huffman codes from the high bit.
    private static func canonicalCodes(_ lengths: [UInt8]) -> [UInt16] {
        var perLength = [UInt16](repeating: 0, count: 16)
        for l in lengths where l > 0 { perLength[Int(l)] += 1 }
        var nextCode = [UInt16](repeating: 0, count: 16)
        var code: UInt16 = 0
        for bits in 1..<16 {
            code = (code + perLength[bits - 1]) << 1
            nextCode[bits] = code
        }
        return lengths.map { length in
            let l = Int(length)
            guard l > 0 else { return 0 }
            let c = nextCode[l]
            nextCode[l] += 1
            var reversed: UInt16 = 0
            for k in 0..<l { reversed |= (c >> UInt16(k) & 1) << UInt16(l - 1 - k) }
            return reversed
        }
    }

    // ---------- CRC-32 ----------

    /// CRC-32 (the gzip polynomial): whole 16-byte blocks on the carry-less multiply when it is in use, the rest eight
    /// bytes per step from the tables.
    private func crc32(_ p: UnsafePointer<UInt8>, _ n: Int) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        var i = 0
        #if arch(x86_64)
        if carryless && n >= 64 {
            i = n & ~15
            c = crc32Fold(c, p, count: i)
        }
        #endif
        let t = crcTable
        while i + 8 <= n {
            let lo = UnsafeRawPointer(p + i).loadUnaligned(as: UInt32.self).littleEndian ^ c
            let hi = UnsafeRawPointer(p + i + 4).loadUnaligned(as: UInt32.self).littleEndian
            c = t[7 * 256 + Int(lo & 0xFF)] ^ t[6 * 256 + Int((lo >> 8) & 0xFF)]
                ^ t[5 * 256 + Int((lo >> 16) & 0xFF)] ^ t[4 * 256 + Int(lo >> 24)]
                ^ t[3 * 256 + Int(hi & 0xFF)] ^ t[2 * 256 + Int((hi >> 8) & 0xFF)]
                ^ t[1 * 256 + Int((hi >> 16) & 0xFF)] ^ t[Int(hi >> 24)]
            i += 8
        }
        while i < n {
            c = t[Int((c ^ UInt32(p[i])) & 0xFF)] ^ (c >> 8)
            i += 1
        }
        return ~c
    }
}

/// Bits into bytes, least significant first, as deflate packs them.
private struct BitWriter {
    let out: UnsafeMutablePointer<UInt8>
    private(set) var offset = 0
    private var bits: UInt64 = 0
    private var count = 0

    init(_ out: UnsafeMutablePointer<UInt8>) {
        self.out = out
    }

    @inline(__always) mutating func put(_ value: UInt64, _ n: Int) {
        bits |= value << UInt64(count)
        count += n
        if count >= 32 {
            UnsafeMutableRawPointer(out + offset).storeBytes(of: UInt32(truncatingIfNeeded: bits).littleEndian, as: UInt32.self)
            offset += 4
            bits >>= 32
            count -= 32
        }
    }

    /// The first `bits` bits of `bytes`, at a byte boundary.
    mutating func copy(_ bytes: UnsafePointer<UInt8>, bits n: Int) {
        precondition(count == 0)
        let whole = n / 8
        (out + offset).update(from: bytes, count: whole)
        offset += whole
        if n % 8 > 0 { put(UInt64(bytes[whole]) & ((1 << UInt64(n % 8)) - 1), n % 8) }
    }

    mutating func alignToByte() {
        while count > 0 {
            out[offset] = UInt8(truncatingIfNeeded: bits)
            offset += 1
            bits >>= 8
            count = max(count - 8, 0)
        }
        bits = 0
    }

    @inline(__always) mutating func byte(_ b: UInt8) {
        out[offset] = b
        offset += 1
    }

    mutating func uint32LE(_ v: UInt32) {
        for k in 0..<4 { out[offset + k] = UInt8(truncatingIfNeeded: v >> UInt32(8 * k)) }
        offset += 4
    }
}

/// Bits out of bytes, least significant first: for reading the header once.
private struct BitReader {
    let bytes: [UInt8]
    private(set) var position = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func take(_ n: Int) -> Int {
        var v = 0
        for k in 0..<n {
            v |= Int(bytes[(position + k) / 8] >> UInt8((position + k) % 8) & 1) << k
        }
        position += n
        return v
    }
}
