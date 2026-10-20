#!/usr/bin/env bash
# Regression guard: a loop over the declared databases must not read its rows from stdin.
# psql_admin runs `docker exec -i`, which reads stdin; inside `while read … <<< "$rows"` it swallowed the remaining rows,
# so an app declaring two databases only ever got its first one created, wiped or injected.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0

# 1. behaviour of the pattern itself, with a stand-in that reads stdin like `docker exec -i`
reader() { cat >/dev/null; }
rows=$'a|1\nb|2\nc|3'
old=0; while IFS='|' read -r id _; do reader <<<"" || true; old=$((old+1)); done <<< "$rows"
new=0; while IFS='|' read -r -u 3 id _; do reader </dev/null || true; new=$((new+1)); done 3<<< "$rows"
[[ $new == 3 ]] || { echo "fd-3 loop handled $new of 3 rows" >&2; fail=1; }
# the failure mode: a stdin reader that is NOT redirected eats the rest
eat=0; while IFS='|' read -r id _; do cat >/dev/null; eat=$((eat+1)); done <<< "$rows"
[[ $eat == 1 ]] || { echo "test premise broken: expected the unprotected loop to stop after 1 row, saw $eat" >&2; fail=1; }

# 2. the real scripts: every loop over database rows reads from fd 3
for f in scripts/db.sh scripts/deploy.sh; do
  while IFS= read -r line; do
    n=${line%%:*}; text=${line#*:}
    echo "$text" | grep -q 'read -r -u 3' || { echo "$f:$n loops over database rows without 'read -u 3'" >&2; fail=1; }
  done < <(grep -nE "while IFS='\|' read -r .*inject" "$ROOT/$f" | sed "s|^|$f:|" | sed -E 's/^[^:]+:([0-9]+):/\1:/')
done
grep -nE 'done <<< "\$(rows|declared)"' "$ROOT/scripts/db.sh" "$ROOT/scripts/deploy.sh" && { echo "a database loop still feeds stdin" >&2; fail=1; } || true

(( fail == 0 )) && echo "db loops: rows are read from fd 3, never from stdin" || exit 1
