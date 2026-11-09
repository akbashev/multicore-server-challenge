// crccheck <wide: 0|1> (not for upstream): random data, every 16-byte length from 256 to 8 KB at offsets 0, 1, 7 and 15
// with tails of 0, 1, 9 and 15 bytes, each fold against a bytewise table; then ns per 3,734 bytes for each.
import CRCExtensions
import CRCExtensions512
import Glibc

let wide = CommandLine.arguments[1] == "1"
var table = [UInt32](repeating: 0, count: 256)
for n in 0..<256 {
    var c = UInt32(n)
    for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
    table[n] = c
}
func bytewise(_ c0: UInt32, _ p: UnsafePointer<UInt8>, _ n: Int) -> UInt32 {
    var c = c0
    for i in 0..<n { c = table[Int((c ^ UInt32(p[i])) & 0xFF)] ^ (c >> 8) }
    return c
}
func fold(_ p: UnsafePointer<UInt8>, _ n: Int, _ use512: Bool) -> UInt32 {
    let body = n & ~15
    let c = use512 ? crc32Fold512(0xFFFF_FFFF, p, count: body) : crc32Fold(0xFFFF_FFFF, p, count: body)
    return ~bytewise(c, p + body, n - body)
}
var rng = SystemRandomNumberGenerator()
var data = [UInt8](repeating: 0, count: 8192 + 64)
for i in data.indices { data[i] = UInt8.random(in: 0...255, using: &rng) }
func now() -> UInt64 { var t = timespec(); clock_gettime(CLOCK_MONOTONIC, &t); return UInt64(t.tv_sec) * 1_000_000_000 + UInt64(t.tv_nsec) }
data.withUnsafeBufferPointer { b in
    for (name, use512) in [("PCLMULQDQ, 8 lanes", false), ("VPCLMULQDQ", true)] where !use512 || wide {
        var bad = 0, checked = 0
        for len in stride(from: 256, through: 8192, by: 16) {
            for offset in [0, 1, 7, 15] {
                for tail in [0, 1, 9, 15] {
                    checked += 1
                    let p = b.baseAddress! + offset
                    if fold(p, len + tail, use512) != ~bytewise(0xFFFF_FFFF, p, len + tail) { bad += 1 }
                }
            }
        }
        let t0 = now()
        var sink: UInt32 = 0
        for _ in 0..<200_000 { sink ^= fold(b.baseAddress!, 3734, use512) }
        print("\(name): \(checked) lengths checked, \(bad) different; \(Double(now() - t0) / 200_000) ns per 3,734 bytes (\(sink & 1))")
    }
    let t0 = now()
    var sink: UInt32 = 0
    for _ in 0..<20_000 { sink ^= bytewise(0xFFFF_FFFF, b.baseAddress!, 3734) }
    print("bytewise table (not the 8-per-step one): \(Double(now() - t0) / 20_000) ns per 3,734 bytes (\(sink & 1))")
}
