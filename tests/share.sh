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
fix_pid=""
trap 'bash "$SH" stop >/dev/null 2>&1; [[ -n $fix_pid ]] && kill "$fix_pid" 2>/dev/null; rm -rf "$WORK"' EXIT

fails=0
check() { # check <label> <expected> <actual>
  if [[ $2 == "$3" ]]; then echo "  ok    $1"; else echo "  FAIL  $1: expected '$2', got '$3'"; fails=$((fails + 1)); fi
}
local_url() { echo "${1/https:\/\/$SHARE_HOSTNAME/http://127.0.0.1:$SHARE_PORT}"; }
code() { curl -s -o /dev/null -w '%{http_code}' "$(local_url "$1")"; }
hcode() { curl -s -o /dev/null -w '%{http_code}' -H "Host: $2" "$(local_url "$1")"; }
header() { curl -s -D - -o /dev/null "$(local_url "$1")" | tr -d '\r' | awk -v h="$2" 'tolower($0) ~ "^"tolower(h)":" {sub(/^[^:]*: /, ""); print}'; }
wait_for_port() { # wait_for_port <port>: poll until something answers, 10s cap
  local _
  for _ in $(seq 1 100); do curl -s -o /dev/null "http://127.0.0.1:$1/" && return 0; sleep 0.1; done
  return 1
}
wait_code() { # wait_code <expected> <url> [host]: poll the status for 5s, print the last one
  local c="" _
  for _ in $(seq 1 50); do
    if [[ -n ${3:-} ]]; then c="$(hcode "$2" "$3")"; else c="$(code "$2")"; fi
    [[ $c == "$1" ]] && break
    sleep 0.1
  done
  echo "$c"
}

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

echo "=== compat: a five-column row still lists and removes ==="
printf 'aa11bb\toldsnap\t%s\t2026-01-01\t0\n' "$WORK" >>"$SHARE_ROOT/index.tsv"
check "five-column row lists" "1" "$(bash "$SH" ls | grep -c aa11bb)"
bash "$SH" rm aa11bb >/dev/null
check "five-column row removes" "0" "$(grep -c aa11bb "$SHARE_ROOT/index.tsv")"

echo "=== serving ==="
check "folder page" 200 "$(code "$dir_url")"
check "asset" 200 "$(code "${dir_url}img/a.txt")"
check "dotfile skipped" 404 "$(code "${dir_url}.env")"
check "outside symlink skipped" 404 "$(code "${dir_url}leak.txt")"
check "root has no listing" 404 "$(code "https://$SHARE_HOSTNAME/")"
check "index.tsv not served" 404 "$(code "https://$SHARE_HOSTNAME/index.tsv")"
check "Cache-Control" "no-store" "$(header "$dir_url" Cache-Control)"
check "X-Robots-Tag" "noindex, nofollow" "$(header "$dir_url" X-Robots-Tag)"
check "admin socket, not admin off" "0" "$(grep -c 'admin off' "$SHARE_ROOT/Caddyfile")"
check "admin socket exists" "1" "$([[ -S $SHARE_ROOT/admin.sock ]] && echo 1 || echo 0)"

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

echo "=== live shares ==="
FIX_PORT=18991
mkdir -p "$WORK/backend" && echo "hello fixture" >"$WORK/backend/hello.txt"
cat >"$WORK/BackendCaddyfile" <<EOF
{
	admin off
	auto_https off
}
http://127.0.0.1:$FIX_PORT {
	bind 127.0.0.1
	root * "$WORK/backend"
	file_server
}
EOF
caddy run --config "$WORK/BackendCaddyfile" --adapter caddyfile >"$WORK/backend.log" 2>&1 &
fix_pid=$!
check "backend fixture answers" "0" "$(wait_for_port "$FIX_PORT"; echo $?)"

live_url=$(bash "$SH" add "$FIX_PORT" 2>"$WORK/err" | head -1)
live_id=$(cut -d/ -f4 <<<"$live_url")
check "live link ends /<id>/" "1" "$(grep -cE "^https://$SHARE_HOSTNAME/[0-9a-f]{6}/\$" <<<"$live_url")"
check "live warning on stderr" "1" "$(grep -c 'live share: anyone with the link reaches 127.0.0.1' "$WORK/err")"
check "absolute-paths caveat" "1" "$(grep -c 'absolute asset paths' "$WORK/err")"
check "live proxies, prefix stripped" "hello fixture" "$(wait_code 200 "${live_url}hello.txt" >/dev/null; curl -s "$(local_url "${live_url}hello.txt")")"
check "live row in ls" "1" "$(bash "$SH" ls | grep -c "live -> http://127.0.0.1:$FIX_PORT")"

out=$(bash "$SH" add 80 2>&1 1>/dev/null); rc=$?
check "add 80 refused" "1" "$rc"
check "80 reason named" "1" "$(grep -c 'below 1024' <<<"$out")"
out=$(bash "$SH" add "$SHARE_PORT" 2>&1 1>/dev/null); rc=$?
check "add caddy port refused" "1" "$rc"
check "caddy port reason" "1" "$(grep -c 'own port' <<<"$out")"
out=$(bash "$SH" add $((SHARE_PORT + 1)) 2>&1 1>/dev/null); rc=$?
check "add metrics port refused" "1" "$rc"
check "metrics port reason" "1" "$(grep -c 'metrics' <<<"$out")"
out=$(bash "$SH" add 99999 2>&1 1>/dev/null); rc=$?
check "add 99999 refused" "1" "$rc"
check "99999 reason" "1" "$(grep -c '65535' <<<"$out")"
check "refused adds left no rows" "1" "$(awk -F'\t' '$6 ~ /live/' "$SHARE_ROOT/index.tsv" | wc -l | tr -d ' ')"

out=$(bash "$SH" refresh "$live_id" 2>&1 1>/dev/null); rc=$?
check "refresh live exits 0" "0" "$rc"
check "nothing to refresh" "1" "$(grep -c 'nothing to refresh' <<<"$out")"

rm_url=$(bash "$SH" add "$FIX_PORT" 2>/dev/null | head -1)
rm_id=$(cut -d/ -f4 <<<"$rm_url")
check "second live share answers" "200" "$(wait_code 200 "${rm_url}hello.txt")"
bash "$SH" rm "$rm_id" >/dev/null
check "rm reloads caddy, prefix 404s" "404" "$(wait_code 404 "${rm_url}hello.txt")"

hits_url=$(bash "$SH" add "$FIX_PORT" 2>/dev/null | head -1)
hits_id=$(cut -d/ -f4 <<<"$hits_url")
curl -s -o /dev/null "$(local_url "${hits_url}hello.txt")"
curl -s -o /dev/null "$(local_url "${hits_url}hello.txt")"
sleep 0.3
check "hits counts live share" "1" "$(bash "$SH" hits "$hits_id" | grep -cE '^2 hits, [0-9]+ visitors?')"

bash "$SH" add 19991 >"$WORK/o19" 2>"$WORK/e19"; rc=$?
dead_url=$(head -1 "$WORK/o19")
check "dead backend still adds" "0" "$rc"
check "warns nothing answers" "1" "$(grep -c 'nothing answers on 127.0.0.1:19991 yet' "$WORK/e19")"
check "dead share returns 502" "502" "$(wait_code 502 "${dead_url}hello.txt")"

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
