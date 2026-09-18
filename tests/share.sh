#!/bin/bash
# Local self-test for share: every behavior except the Cloudflare tunnel and setup.
# Runs on a spare port with SHARE_TUNNEL=0 and a throwaway config dir, so it
# needs no credentials and never touches a live server. Markdown checks run
# only when pandoc is installed. Ends with the host-guard negative control.
set -uo pipefail

SH="$(cd "$(dirname "$0")/.." && pwd)/bin/share"
WORK=$(mktemp -d)
export SHARE_ROOT="$WORK/root" SHARE_CONFIG_DIR="$WORK/config" SHARE_PORT=18787
export SHARE_TUNNEL=0 SHARE_CLIPBOARD=0 SHARE_HOSTNAME=s.example.test
# A label no machine has, so an installed share service is never started or stopped by the test.
export SHARE_SERVICE_LABEL="share-selftest-$$"
h="$(uname -n)"; export SHARE_HOSTS="${h%%.*}"
trap 'bash "$SH" stop >/dev/null 2>&1; rm -rf "$WORK"' EXIT

fails=0
check() { # check <label> <expected> <actual>
  if [[ $2 == "$3" ]]; then echo "  ok    $1"; else echo "  FAIL  $1: expected '$2', got '$3'"; fails=$((fails + 1)); fi
}
local_url() { echo "${1/https:\/\/$SHARE_HOSTNAME/http://127.0.0.1:$SHARE_PORT}"; }
code() { curl -s -o /dev/null -w '%{http_code}' "$(local_url "$1")"; }
header() { curl -s -D - -o /dev/null "$(local_url "$1")" | tr -d '\r' | awk -v h="$2" 'tolower($0) ~ "^"tolower(h)":" {sub(/^[^:]*: /, ""); print}'; }

# Fixture: a folder with an asset, a dotfile, a symlink out, and markdown.
src="$WORK/wt/guide"
mkdir -p "$src/img"
echo '<h1>guide</h1>' >"$src/index.html"
echo asset >"$src/img/a.txt"
echo SECRET=x >"$src/.env"
echo outside >"$WORK/outside.txt"
ln -s "$WORK/outside.txt" "$src/leak.txt"
printf '# Notes\n\nSee [other](other.md).\n' >"$src/notes.md"
echo '# Other' >"$src/other.md"
printf '# Math\n\nArea %sx^2%s.\n' '$' '$' >"$src/math.md"
mkdir -p "$WORK/wt/docs" && echo '# Readme' >"$WORK/wt/docs/README.md" && echo '<p>docs</p>' >"$WORK/wt/docs/index.html"
echo 'single' >"$WORK/wt/one.md"

echo "=== add + auto-start ==="
dir_url=$(bash "$SH" add "$src" 2>/dev/null | head -1)
md_url=$(bash "$SH" add "$WORK/wt/one.md" | head -1)
docs_url=$(bash "$SH" add --ttl 1h "$WORK/wt/docs" | head -1)
check "server auto-started" "0" "$([[ -f $SHARE_ROOT/serve.pid ]] && kill -0 "$(cat "$SHARE_ROOT/serve.pid")"; echo $?)"
check "link carries a 6-hex id" "1" "$(grep -cE "^https://$SHARE_HOSTNAME/[0-9a-f]{6}/guide/\$" <<<"$dir_url")"
bash "$SH" add "$src/.env" >/dev/null 2>&1
check "a bare dotfile is refused" 1 "$?"

echo "=== serving ==="
check "folder page" 200 "$(code "$dir_url")"
check "asset" 200 "$(code "${dir_url}img/a.txt")"
check "dotfile skipped" 404 "$(code "${dir_url}.env")"
check "outside symlink skipped" 404 "$(code "${dir_url}leak.txt")"
check "root has no listing" 404 "$(code "https://$SHARE_HOSTNAME/")"
check "index.tsv not served" 404 "$(code "https://$SHARE_HOSTNAME/index.tsv")"
check "Cache-Control" "no-store" "$(header "$dir_url" Cache-Control)"
check "X-Robots-Tag" "noindex, nofollow" "$(header "$dir_url" X-Robots-Tag)"

echo "=== markdown ==="
if command -v pandoc >/dev/null; then
  check "single .md links to .html" "1" "$(grep -c '/one\.html$' <<<"$md_url")"
  check "single .md renders" 200 "$(code "$md_url")"
  check ".md link rewritten to .html" "1" "$(curl -s "$(local_url "${dir_url}notes.html")" | grep -c 'href="other.html"')"
  check "README.html renders" 200 "$(code "${docs_url}README.html")"
  check "render carries the stylesheet" "1" "$(curl -s "$(local_url "${dir_url}notes.html")" | grep -c 'max-width:42em')"
  check "no math, no KaTeX" "0" "$(curl -s "$(local_url "${dir_url}notes.html")" | grep -c 'katex')"
  check "math loads KaTeX" "1" "$(curl -s "$(local_url "${dir_url}math.html")" | grep -c 'katex.min.js')"
else
  echo "  skip  pandoc not installed"
  check "single .md served raw" 200 "$(code "$md_url")"
fi

echo "=== source removed (worktree gone) ==="
mv "$WORK/wt" "$WORK/wt.gone"
check "folder still served" 200 "$(code "$dir_url")"
check "ls flags the gone source" "3" "$(bash "$SH" ls | grep -c 'source gone')"
dir_id=$(cut -d/ -f4 <<<"$dir_url")
bash "$SH" refresh "$dir_id" >/dev/null 2>&1
check "refresh on a gone source fails" 1 "$?"

echo "=== refresh keeps the link ==="
mv "$WORK/wt.gone" "$WORK/wt"
echo '<h1>guide v2</h1>' >"$src/index.html"
bash "$SH" refresh "$dir_id" >/dev/null 2>&1
check "refreshed content, same link" "1" "$(curl -s "$(local_url "$dir_url")" | grep -c 'v2')"

echo "=== hits, ttl, rm ==="
check "hits by link" "1" "$(bash "$SH" hits "$dir_url" | grep -cE '^[1-9][0-9]* hits?, 1 visitor(,|$)')"
bash "$SH" add --ttl 3x "$WORK/wt/one.md" >/dev/null 2>&1
check "bad ttl rejected" 1 "$?"
docs_id=$(cut -d/ -f4 <<<"$docs_url")
awk -F'\t' -v OFS='\t' -v id="$docs_id" '$1 == id {$5 = 1} {print}' "$SHARE_ROOT/index.tsv" >"$WORK/i" && mv "$WORK/i" "$SHARE_ROOT/index.tsv"
bash "$SH" prune >/dev/null
check "expired share pruned" 404 "$(code "$docs_url")"
bash "$SH" rm "$dir_url" >/dev/null
check "rm by link unpublishes" 404 "$(code "$dir_url")"

echo "=== stop ==="
bash "$SH" stop >/dev/null
check "stop takes links down" 000 "$(code "$md_url")"

echo "=== NEGATIVE CONTROL: a host outside hosts must not serve ==="
SHARE_HOSTS=not-this-host bash "$SH" start >/dev/null 2>&1
check "start refused on another host" 1 "$?"

echo
if [[ $fails -gt 0 ]]; then
  echo "$fails FAILED"
  for log in serve.log caddy.log; do
    echo "--- $log"; tail -20 "$SHARE_ROOT/$log" 2>/dev/null
  done
  exit 1
fi
echo "PASS"
