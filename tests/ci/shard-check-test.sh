#!/usr/bin/env bash
# Negative controls for shard-check.sh: a new section in no shard, and a section in two shards, each turn it red; the real tree is green.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$here/../.."
work="$(mktemp -d)"; trap 'mv "$work" "${TMPDIR:-/tmp}/shard-check-test.$$.old"' EXIT
fail=0
expect() { # expect <want rc> <label> <root>
  out="$(SHARD_CHECK_ROOT="$3" bash "$here/shard-check.sh" 2>&1)"; rc=$?
  if [[ $rc == "$1" ]]; then echo "  ok    $2 (exit $rc)"; else echo "  FAIL  $2: exit $rc, want $1"; echo "$out"; fail=1; fi
  printf '%s\n' "$out" | sed 's/^/        /'
}
fresh() { rm -rf "$work/t"; mkdir -p "$work/t/tests/ci"; cp "$repo"/tests/share.sh "$repo"/tests/members.sh "$work/t/tests/"; cp "$repo"/tests/ci/shards.txt "$work/t/tests/ci/"; }

fresh; expect 0 "the committed shards cover every section once" "$work/t"
fresh; printf '%s\n' 'if section "members: a section no shard names"; then' 'true' 'fi' >>"$work/t/tests/members.sh"
expect 1 "a new section in no shard turns it red" "$work/t"
fresh; sed -i.bak -E 's/^members-b\t\^members: \(/members-b\t^members: (member rm and member purge|/' "$work/t/tests/ci/shards.txt"
expect 1 "a section in two shards turns it red" "$work/t"
fresh; printf 'extra\t^no such section$\n' >>"$work/t/tests/ci/shards.txt"
expect 1 "a shard that names no section turns it red" "$work/t"
exit "$fail"
