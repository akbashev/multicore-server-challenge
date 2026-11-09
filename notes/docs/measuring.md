# Measuring

## Build microbenchmarks the way you ship

SwiftPM's release build compiles each module whole (`-wmo`). A microbenchmark built file by file, or with plain
`swiftc -O` on separate files, can inline differently and land on different code. In one case a JSON reader looked
70–185 ns slower per call in a non-WMO build, and turned out faster once built whole-module: 490 ns against 800–1,000
for an article body.

```sh
swiftc -O -wmo -enforce-exclusivity=unchecked -module-name bench Bench.swift Code.swift -o bench
```

## Read what the compiler made

Count the calls a hot function makes. Anything into the runtime is suspect.

```sh
objdump -d --no-show-raw-insn .build/release/App > d.txt
awk '/^[0-9a-f]+ <.*>:$/ { p = index($0, "writeString") > 0 } p' d.txt \
  | grep -oE 'call\s+[0-9a-f]+ <[^>]+>' | sort | uniq -c | sort -rn
```

What turned up this way:

- `Array.append(contentsOf:)`: generic and not inlined, called once per JSON field.
- `swift_isUniquelyReferenced_nonNull_native`: each `[UInt8]` mutation checks the buffer is unique.
- `swift_once`: a file-scope `let` read inside a loop.
- A sort's comparison closure: called once per comparison, not inlined.

## Profile per thread, on the CPU that matters

Local numbers on an Apple-silicon laptop swung ±30% between runs, too much to see a 3% change. On x86 GitHub runners,
two things gave stable answers:

- CPU per request split by thread kind (reactors, read lanes, write lanes, bcrypt workers), from each thread's
  `/proc/<pid>/task/<tid>/stat` before and after a window.
- `perf report --sort comm,dso,symbol`, summed per kind of thread. That turned "the reactors cost 1.8 µs more than the
  reference" into "1.05 µs of it is SHA-256, 0.34 µs base64".

Run each build twice in the same job, and compare only within a job: runners differ (AMD Zen 3, Zen 4, Zen 5 and
Intel all turned up), and the difference between them is often bigger than the change being measured.

## Count allocations

An `LD_PRELOAD` shim that counts `malloc`, `calloc` and `realloc` per caller, over a window of the load, shows what
allocates per request. One server went from 7.8 allocations per request to 3.4; another ended at 0.72, all of them
inside SQLite's writes.

## Compare with the code that actually runs

A library's portable reference is often not what runs. ISA-L's `isal_deflate_body_base` (C) is not what runs on
x86: that is `isal_deflate_body_04`, AVX2 assembly that handles two positions per step. Its AVX-512 code is only in
the CRC. Porting the C reference got within 1.45×; porting what the assembly does got level. See the
[gzip case](case-gzip.md).

## The test that matters

Optimizations here touched sorting, hashing and JSON escaping, so the last check was byte-for-byte: hundreds of
responses from the old and new builds on copies of the same database, compared exactly.
