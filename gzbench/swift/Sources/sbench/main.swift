// sbench <dir> <count> <rounds> <out dir> (not for upstream): each feed gzipped by million's Gzip module, as cbench
// times the C libraries.
import Glibc
import Gzip

func now() -> UInt64 {
    var t = timespec()
    clock_gettime(CLOCK_MONOTONIC, &t)
    return UInt64(t.tv_sec) * 1_000_000_000 + UInt64(t.tv_nsec)
}

let args = CommandLine.arguments
let (dir, count, rounds, outDir) = (args[1], Int(args[2])!, Int(args[3])!, args[4])
var bodies: [[UInt8]] = []
for i in 0..<count {
    let name = dir + "/" + String(repeating: "0", count: 4 - String(i).count) + String(i) + ".json"
    let f = fopen(name, "rb")!
    fseek(f, 0, SEEK_END)
    let n = ftell(f)
    fseek(f, 0, SEEK_SET)
    var b = [UInt8](repeating: 0, count: n)
    _ = b.withUnsafeMutableBytes { fread($0.baseAddress, 1, n, f) }
    fclose(f)
    bodies.append(b)
}
var gzip = Gzip()
let out = UnsafeMutableRawBufferPointer.allocate(byteCount: 1 << 20, alignment: 16)
var total = 0
for (i, b) in bodies.enumerated() {
    let m = b.withUnsafeBytes { gzip.compress($0, into: out) }
    total += m
    let name = outDir + "/swift-" + String(repeating: "0", count: 4 - String(i).count) + String(i) + ".gz"
    let f = fopen(name, "wb")!
    fwrite(out.baseAddress, 1, m, f)
    fclose(f)
}
let t0 = now()
var sink = 0
for _ in 0..<rounds {
    for b in bodies { sink &+= b.withUnsafeBytes { gzip.compress($0, into: out) } }
}
let ns = Double(now() - t0) / Double(rounds * count)
print("swift (ours)   \(Int(ns)) ns per feed, mean \(total / count) bytes (\(sink & 1))")
