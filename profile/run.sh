#!/usr/bin/env bash
# profile/run.sh <submission>... (not for upstream): each submission in turn as a systemd service, as on the box,
# on a fresh copy of the full seed, all under the same loads on this machine:
#   1. logins only (bench/cmd/logins): logins per second and the server's CPU per login (mostly bcrypt);
#   2. a warm-up, then each LEVELS step of the load generator's mix: req/s and latency, the server's and Postgres's
#      CPU per request from their cgroups over a WINDOW of the measured part, the server's CPU by thread name, then
#      perf stat and a perf profile of the server.
# Everything also lands in profile/out.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD OUT=$PWD/profile/out; mkdir -p "$OUT"
LEVELS=${LEVELS:-"3000 6000"} THINK=${THINK:-0.1} RAMP=${RAMP:-20} MEASURE=${MEASURE:-60} WINDOW=${WINDOW:-30}
PERF=${PERF:-15} LOGIN_C=${LOGIN_C:-64} LOGIN_S=${LOGIN_S:-20}
SECRET=x86-profile-secret
export PGHOST=127.0.0.1 PGUSER=postgres PGPASSWORD=postgres PGPORT=${PGPORT:-5432}
PSQL="psql -X -q -v ON_ERROR_STOP=1 -d postgres"
PGCG=/sys/fs/cgroup$(systemctl show -p ControlGroup --value postgresql@18-main)
sudo sysctl -q kernel.perf_event_paranoid=-1 kernel.kptr_restrict=0
demangle() { if [ -x /opt/swift/usr/bin/swift-demangle ]; then /opt/swift/usr/bin/swift-demangle --simplified; else cat; fi; }
usec() { awk '$1=="usage_usec" {print $2}' "$1/cpu.stat"; }
usersys() { awk '$1=="user_usec" {u=$2} $1=="system_usec" {s=$2} END {print u, s}' "$1/cpu.stat"; }
run=0
for sub in "$@"; do
  run=$((run + 1)); tag="$run-$sub"; unit="srv-$run"; DB="prof_$run"
  echo; echo "================ $tag"
  $PSQL -c "DROP DATABASE IF EXISTS $DB WITH (FORCE)" -c "CREATE DATABASE $DB TEMPLATE conduit_seed STRATEGY FILE_COPY"
  $PSQL -c CHECKPOINT
  sudo systemd-run --quiet --unit="$unit" --uid="$(id -u)" --gid="$(id -g)" -p LimitNOFILE=200000 \
    -p WorkingDirectory="$ROOT/submissions/$sub" --setenv=HOME="$HOME" \
    --setenv=DATABASE_URL="postgres://conduit:conduit@127.0.0.1:$PGPORT/$DB" --setenv=JWT_SECRET=$SECRET \
    --setenv=HOST=127.0.0.1 --setenv=PORT=3000 bash "$ROOT/submissions/$sub/start.sh"
  CG=/sys/fs/cgroup$(systemctl show -p ControlGroup --value "$unit")
  for _ in $(seq 120); do curl -sf -o /dev/null http://127.0.0.1:3000/api/tags && break; sleep 0.5; done
  if ! curl -sf -o /dev/null http://127.0.0.1:3000/api/tags; then
    echo "$sub not answering"; sudo journalctl -u "$unit" --no-pager | tail -30; sudo systemctl stop "$unit"; continue
  fi
  sleep 3
  echo "threads: $(python3 profile/threads.py snap "$CG" | cut -f2 | sed -E 's/[-_ #]*[0-9]+$//' | sort | uniq -c | xargs)"

  echo "-- logins only, $LOGIN_C clients"
  bench/.logins -target http://127.0.0.1:3000 -c "$LOGIN_C" -warmup 5s -d "${LOGIN_S}s" -cgroup "$CG" | tee "$OUT/$tag.logins.txt"
  sleep 5

  step() {  # step <users> <name> <measured seconds> [measure]
    local users=$1 name=$2
    bench/.loadgen run -target http://127.0.0.1:3000 -users "$users" -ramp "${RAMP}s" -measure "${3}s" -tail 5s \
      -secret $SECRET -run-id "p${run}${name}" -articles 500000 -think-scale "$THINK" -out "$OUT/$tag.$name.json" \
      > "$OUT/$tag.$name.txt" 2>&1 &
    local lg=$!
    [ "${4:-}" = measure ] || { wait $lg; return; }
    sleep $((RAMP + 3))
    local a0 p0 a1 p1 t0 t1 u0 s0 u1 s1
    python3 profile/threads.py snap "$CG" > "$OUT/$tag.$name.th0"
    a0=$(usec "$CG"); p0=$(usec "$PGCG"); read -r u0 s0 < <(usersys "$CG"); t0=$(date +%s.%N)
    sleep "$WINDOW"
    a1=$(usec "$CG"); p1=$(usec "$PGCG"); read -r u1 s1 < <(usersys "$CG"); t1=$(date +%s.%N)
    python3 profile/threads.py snap "$CG" > "$OUT/$tag.$name.th1"
    local pids; pids=$(paste -sd, "$CG/cgroup.procs")
    sudo perf stat -e task-clock,context-switches,cpu-migrations,cycles,instructions -p "$pids" -- sleep 5 \
      > "$OUT/$tag.$name.stat.txt" 2>&1
    sudo perf record -q -F 999 -p "$pids" -o "$OUT/$tag.$name.perf.data" -- sleep "$PERF" > /dev/null 2>&1
    wait $lg
    local all rps; all=$(grep -E '^ALL ' "$OUT/$tag.$name.txt"); rps=$(echo "$all" | awk '{print $3}')
    echo "-- $users users: $(echo "$all" | awk '{printf "%s req/s, p50 %s p95 %s p99 %s ms, err %s%%", $3, $4, $6, $7, $9}')"
    python3 - "$rps" "$t0" "$t1" "$a0" "$a1" "$p0" "$p1" "$u0" "$u1" "$s0" "$s1" <<'P'
import sys
rps, t0, t1, a0, a1, p0, p1, u0, u1, s0, s1 = map(float, sys.argv[1:])
secs = t1 - t0
c = lambda d: d / 1e6 / secs
us = lambda d: d / secs / rps
print(f"   server   {c(a1 - a0):5.2f} cores = {us(a1 - a0):6.1f} us/req ({us(u1 - u0):.1f} user + {us(s1 - s0):.1f} kernel)")
print(f"   postgres {c(p1 - p0):5.2f} cores = {us(p1 - p0):6.1f} us/req")
P
    secs=$(python3 -c "print($t1 - $t0)")
    python3 profile/threads.py diff "$OUT/$tag.$name.th0" "$OUT/$tag.$name.th1" "$secs" "$rps"
    grep -E 'context-switches|cpu-migrations|cycles|instructions|not supported' "$OUT/$tag.$name.stat.txt" | sed 's/^ */   /'
    echo "   by DSO:"
    sudo perf report -i "$OUT/$tag.$name.perf.data" --stdio --no-children --sort dso 2>/dev/null \
      | grep -v '^#' | grep -v '^$' | head -6 | sed 's/^/   /'
    echo "   by symbol (top 45):"
    sudo perf report -i "$OUT/$tag.$name.perf.data" --stdio --no-children --sort symbol 2>/dev/null \
      | grep -v '^#' | grep -v '^$' | head -45 | demangle | cut -c1-160 | sed 's/^/   /'
  }

  step 2000 warmup 20
  sleep 5
  for users in $LEVELS; do
    step "$users" "u$users" "$MEASURE" measure
    sleep 5
  done
  echo "-- server log head:"; sudo journalctl -u "$unit" --no-pager -o cat | head -12
  sudo systemctl stop "$unit"
  sleep 3
  $PSQL -c "DROP DATABASE IF EXISTS $DB WITH (FORCE)"
  sleep 10
done
sudo chmod -R a+r "$OUT"
