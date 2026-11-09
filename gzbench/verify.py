# verify.py <feeds dir> <out dir> <count> (not for upstream): every compressor's output decompresses to its input.
import gzip, sys
d, o, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
for name in ["swift-old", "swift-new", "isal-l0", "libdeflate-l1", "zlib-l1"]:
    bad = sum(gzip.decompress(open(f"{o}/{name}-{i:04d}.gz", "rb").read()) != open(f"{d}/{i:04d}.json", "rb").read() for i in range(n))
    print(f"{name}: {n - bad}/{n} decompress to their input")
