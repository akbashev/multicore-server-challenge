#!/usr/bin/env python3
# threads.py snap <cgroup>                 -> prints "tid<TAB>comm<TAB>ticks" for every thread in the cgroup
# threads.py diff <before> <after> <seconds> <requests/s>
#                                          -> CPU by thread name (digits stripped), in cores and in us per request
import os, re, sys

def snap(cgroup):
    for pid in open(os.path.join(cgroup, "cgroup.procs")).read().split():
        try:
            tids = os.listdir(f"/proc/{pid}/task")
        except OSError:
            continue
        for tid in tids:
            try:
                s = open(f"/proc/{pid}/task/{tid}/stat").read()
            except OSError:
                continue
            comm = s[s.index("(") + 1:s.rindex(")")]
            rest = s[s.rindex(")") + 2:].split()
            print(f"{tid}\t{comm}\t{int(rest[11]) + int(rest[12])}")

def load(path):
    out = {}
    for line in open(path):
        tid, comm, ticks = line.rstrip("\n").split("\t")
        out[tid] = (comm, int(ticks))
    return out

def diff(a, b, secs, rps):
    before, after = load(a), load(b)
    tck = os.sysconf("SC_CLK_TCK")
    groups, counts = {}, {}
    for tid, (comm, ticks) in after.items():
        name = re.sub(r"[-_ #]*\d+$", "", comm) or comm
        groups[name] = groups.get(name, 0) + ticks - before.get(tid, (comm, 0))[1]
        counts[name] = counts.get(name, 0) + 1
    total = sum(groups.values())
    for name, ticks in sorted(groups.items(), key=lambda kv: -kv[1]):
        if ticks <= 0:
            continue
        cores = ticks / tck / secs
        print(f"  {name:<20} x{counts[name]:<3} {cores:5.2f} cores  {cores * 1e6 / rps:6.1f} us/req  {100 * ticks / total:4.0f}%")

if sys.argv[1] == "snap":
    snap(sys.argv[2])
else:
    diff(sys.argv[2], sys.argv[3], float(sys.argv[4]), float(sys.argv[5]))
