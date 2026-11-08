# profile/bykind.py <report> <kind>... (not for upstream): from `perf report --sort comm,dso,symbol`, the top symbols
# of each kind of thread (its name without the number), summed over the threads of that kind, as shares of all samples.
import re
import sys
from collections import defaultdict

path, kinds = sys.argv[1], sys.argv[2:]
line = re.compile(r'^\s*([\d.]+)%\s+(\S+)\s+(\S+)\s+\[(.)\]\s+(.*?)\s*$')
shares = defaultdict(lambda: defaultdict(float))
totals = defaultdict(float)
for text in open(path, errors='replace'):
    m = line.match(text)
    if not m:
        continue
    pct, comm, _, where, sym = m.groups()
    kind = re.sub(r'[-_ #]*\d+$', '', comm)
    shares[kind][f'[{where}] {sym}'] += float(pct)
    totals[kind] += float(pct)
for kind in kinds:
    print(f'   [{kind}] {totals[kind]:.2f}% of samples')
    for sym, pct in sorted(shares[kind].items(), key=lambda x: -x[1])[:25]:
        print(f'   {pct:7.2f}%  {sym[:150]}')
