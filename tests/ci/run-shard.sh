#!/usr/bin/env bash
# run-shard.sh <name>: run one CI shard of the bash suite (the regex comes from tests/ci/shards.txt).
set -eu
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
name="${1:?usage: run-shard.sh <shard name>}"
re="$(awk -F'\t' -v n="$name" '$1 == n { print $2 }' "$here/shards.txt")"
[[ -n $re ]] || { echo "run-shard: no shard named $name in tests/ci/shards.txt" >&2; exit 2; }
echo "shard $name: SHARE_TEST_ONLY=$re"
SHARE_TEST_ONLY="$re" exec bash "$here/../share.sh"
