#!/usr/bin/env bash
# Memory of the deployed test host (make test-memory): the host container's cgroup (the stand-in for
# the VM's RAM, capped with TT_TEST_HOST_MEM), each container of the stack (docker stats inside the
# host) and the sum of the Compose mem_limits. With the "tiny" profile the limits must stay at or under
# 900 MiB, the budget of a 1 GiB VM.
set -euo pipefail

HOST=tt-test-host
APP_DIR=/opt/te-tengo
PROFILE="${TT_TEST_MEMORY_PROFILE:-tiny}"
TINY_BUDGET_MIB=900

mib() { awk -v b="$1" 'BEGIN { printf "%.0f", b / 1048576 }'; }
cg() { docker exec "$HOST" cat "/sys/fs/cgroup/$1" 2>/dev/null || echo 0; }

docker exec "$HOST" test -f "$APP_DIR/.env" || { echo "Run make test-deploy first" >&2; exit 2; }

limit=$(cg memory.max)
echo "== Test host (memory profile $PROFILE)"
echo "cgroup limit:     $([ "$limit" = max ] && echo unlimited || echo "$(mib "$limit") MiB")"
echo "memory.current:   $(mib "$(cg memory.current)") MiB (includes page cache)"
echo "memory.peak:      $(mib "$(cg memory.peak)") MiB"
echo "swap.current:     $(mib "$(cg memory.swap.current)") MiB"
echo "anon (stat):      $(mib "$(cg memory.stat | awk '$1 == "anon" { print $2 }')") MiB"
echo "file (stat):      $(mib "$(cg memory.stat | awk '$1 == "file" { print $2 }')") MiB"
echo
echo "== Containers of the stack (docker stats inside the host)"
docker exec "$HOST" docker stats --no-stream --format 'table {{.Name}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.CPUPerc}}'
echo
echo "== Compose mem_limits ($APP_DIR/.env)"
limits=$(docker exec "$HOST" grep -E '^(POSTGRES|API|MEDIAMTX|CADDY)_MEM_LIMIT=' "$APP_DIR/.env" | tr -d "'")
echo "$limits"
total=$(sed -E 's/.*=([0-9]+)([mg])$/\1 \2/' <<<"$limits" | awk '{ total += ($2 == "g" ? $1 * 1024 : $1) } END { print total }')
echo "sum: $total MiB"
if [ "$PROFILE" = tiny ] && [ "$total" -gt "$TINY_BUDGET_MIB" ]; then
  echo "FAIL  the tiny profile's limits exceed $TINY_BUDGET_MIB MiB" >&2
  exit 1
fi
