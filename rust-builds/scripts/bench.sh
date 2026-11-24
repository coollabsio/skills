#!/bin/bash
# Cold-build benchmark for one checkout copy. Prints wall time, CPU (cargo + sccache server children),
# cache hits and target/ size.
#
# usage: bench.sh <label> <checkout> <cargo args...>
#   bench.sh base-1   ~/src/bench-a build -p mycrate                 # baseline: run with RUSTC_WRAPPER= set
#   bench.sh warm-new ~/src/bench-b build -p mycrate                 # with the wrapper
#
# For sccache runs, start a private server first, so its CPU can be counted:
#   export SCCACHE_SERVER_PORT=4227 SCCACHE_DIR=/tmp/bench-sccache
#   sccache-wrap --start-server
# Results are appended to ./bench-results.txt.
set -u
label=$1; dir=$2; shift 2
out="$PWD/bench-results.txt"

server_pid=""
if [ -n "${SCCACHE_SERVER_PORT:-}" ]; then
    for p in $(pgrep -x sccache); do
        tr '\0' '\n' </proc/$p/environ 2>/dev/null | grep -qx "SCCACHE_SERVER_PORT=$SCCACHE_SERVER_PORT" && server_pid=$p
    done
fi
server_cpu() { [ -n "$server_pid" ] && awk '{print ($14+$15+$16+$17)/100}' /proc/$server_pid/stat || echo 0; }

cd "$dir" || exit 1
rm -rf target
[ -n "$server_pid" ] && sccache --zero-stats >/dev/null
load=$(cut -d' ' -f1 /proc/loadavg)
s0=$(server_cpu)
/usr/bin/time -f "%e %U %S" -o /tmp/bench.time cargo "$@" >"/tmp/bench-$label.log" 2>&1
rc=$?
read -r wall user sys < <(tail -1 /tmp/bench.time)
s1=$(server_cpu)
cpu=$(echo "$user + $sys + $s1 - $s0" | bc)
hits=""
[ -n "$server_pid" ] && hits=$(sccache --show-stats | awk '/^Cache hits  /{h=$3} /^Cache misses  /{m=$3} END{print "hits="h" misses="m}')
printf '%-24s rc=%s wall=%6.1fs cpu=%7.1fs load=%s target=%s %s\n' \
    "$label" "$rc" "$wall" "$cpu" "$load" "$(du -sh target | cut -f1)" "$hits" | tee -a "$out"
