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
lock_count() { find "$SHARE_ROOT" -maxdepth 1 -name '.lock-*' | grep -c .; }
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

printf 'zzzzzz\tbroken\n' >>"$SHARE_ROOT/index.tsv"   # malformed: fewer than 5 tab fields
check "malformed row does not crash ls" "0" "$(bash "$SH" ls >/dev/null 2>&1; echo $?)"
check "malformed row is skipped from ls" "0" "$(bash "$SH" ls | grep -c zzzzzz)"
grep -v '^zzzzzz' "$SHARE_ROOT/index.tsv" >"$WORK/i" && mv "$WORK/i" "$SHARE_ROOT/index.tsv"

echo "=== forged rows: a newline path is refused, untrusted rows never reach a reader ==="
nl_dir="$WORK/wt/evil"$'\n'"row"
mkdir -p "$nl_dir" && echo x >"$nl_dir/f.txt"
idx_before=$(cksum <"$SHARE_ROOT/index.tsv")
out=$(bash "$SH" add "$nl_dir/f.txt" 2>&1 1>/dev/null); rc=$?
check "a newline in a parent folder is refused" "1" "$rc"
check "the refusal names paths" "1" "$(grep -c 'paths with tabs or newlines' <<<"$out")"
check "the refusal leaves the index unchanged" "$idx_before" "$(cksum <"$SHARE_ROOT/index.tsv")"
{
  printf '..\tforged-dotdot\t/x\t2026-01-01\t0\thost=dd.example.test\n'                     # id is not 6 hex
  printf 'f0f0f1\tforged-main\thttp://127.0.0.1:19993\t2026-01-01\t0\tlive host=%s\n' "$SHARE_HOSTNAME"
  printf 'f0f0f2\tforged-badhost\t/x\t2026-01-01\t0\thost=Bad_Host{\n'                     # not a hostname
} >>"$SHARE_ROOT/index.tsv"
bash "$SH" refresh "$(cut -d/ -f4 <<<"$md_url")" >/dev/null 2>&1   # re-renders the Caddyfile with the forged rows present
check "forged rows absent from ls" "0" "$(bash "$SH" ls | grep -c 'forged-\|f0f0f\|dd\.example')"
check "forged rows absent from the Caddyfile" "0" "$(grep -c "dd\.example\.test\|19993\|Bad_Host\|http://$SHARE_HOSTNAME:" "$SHARE_ROOT/Caddyfile")"
bash "$SH" state >"$WORK/forged.json"
check "forged rows absent from state" "0" "$(jq '[.shares[] | select(.name | startswith("forged-"))] | length' "$WORK/forged.json")"
check "forged rows counted in skipped" "3" "$(jq '.skipped' "$WORK/forged.json")"
grep -v $'\tforged-' "$SHARE_ROOT/index.tsv" >"$WORK/i" && mv "$WORK/i" "$SHARE_ROOT/index.tsv"
hostrm_probe="$WORK/hostrm-probe.sh"
{
  sed -n '/^die() {/p' "$SH"
  sed -n '/^host_rm() {/,/^}/p' "$SH"
  # shellcheck disable=SC2016 # literal code for the probe script, not this shell's expansion
  echo 'host_name="$1" root="$2" SHARE_HOST_DRY=1; host_lock() { :; }; host_unlock() { :; }; host_rm "$1"'
} >"$hostrm_probe"
out=$(bash "$hostrm_probe" "$SHARE_HOSTNAME" "$WORK/hostrm-root" 2>&1); rc=$?
check "host_rm refuses the main hostname" "1" "$rc"
check "host_rm refusal names it" "1" "$(grep -c 'is the main hostname' <<<"$out")"
check "host_rm refusal made no call" "0" "$([[ -e $WORK/hostrm-root/host-calls.log ]] && echo 1 || echo 0)"

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
check "/healthz responds ok" 200 "$(code "https://$SHARE_HOSTNAME/healthz")"
check "main host block has handle /healthz before the catch-all" "1" \
  "$(awk '/^http:\/\/:/{f=1} f && /handle \/healthz/{print NR; exit} f && /^\thandle \{/{exit}' "$SHARE_ROOT/Caddyfile" | grep -c .)"

echo "=== markdown ==="
if command -v pandoc >/dev/null; then
  check "single .md links to .html" "1" "$(grep -c '/one\.html$' <<<"$md_url")"
  check "single .md renders" 200 "$(code "$md_url")"
  check ".md link rewritten to .html" "1" "$(curl -s "$(local_url "${dir_url}notes.html")" | grep -c 'href="other.html"')"
  check "README.html renders" 200 "$(code "${docs_url}README.html")"
  check "render carries the stylesheet" "1" "$(curl -s "$(local_url "${dir_url}notes.html")" | grep -c 'max-width:44rem')"
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

echo "=== refresh racing rm: no republish after unpublish ==="
# copy() runs outside the index lock, so a slow copy widens the window for a
# concurrent rm to finish first; 300 files makes that window wide enough to
# hit reliably across a handful of rounds instead of by luck on one.
race_src="$WORK/race"
mkdir -p "$race_src"
for i in $(seq 1 300); do echo "line $i" >"$race_src/f$i.txt"; done
race_bad=0
for round in 1 2 3 4 5 6 7 8 9 10; do
  race_url=$(bash "$SH" add "$race_src" 2>/dev/null | head -1)
  race_id=$(cut -d/ -f4 <<<"$race_url")
  bash "$SH" refresh "$race_id" >"$WORK/race.refresh.$round" 2>&1 & refresh_pid=$!
  bash "$SH" rm "$race_id" >"$WORK/race.rm.$round" 2>&1 & rm_pid=$!
  wait "$rm_pid"; rm_rc=$?
  wait "$refresh_pid"
  { [[ $rm_rc -eq 0 ]] && grep -qx "unpublished $race_id" "$WORK/race.rm.$round"; } || race_bad=1
  [[ -e "$SHARE_ROOT/pub/$race_id" ]] && race_bad=1
done
check "refresh racing rm: rm always succeeds and pub/<id> never survives" "0" "$race_bad"

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

echo "=== TASK-004: hits streams the access log ==="
old_hits_jq() { # old_hits_jq <log> <id> <fqdn>: the pre-streaming jq -rs program, kept as the reference
  jq -rs --arg p "/$2/" --arg h "$3" '
    def n($k; $w): "\($k) \($w)\(if $k == 1 then "" else "s" end)";
    map(select((if $h == "" then (.request.uri | startswith($p)) else .request.host == $h end) and .status < 400)) as $h
    | n($h | length; "hit") + ", "
      + n($h | map(.request.headers["Cf-Connecting-Ip"][0] // .request.remote_ip) | unique | length; "visitor")
      + (if ($h | length) > 0 then ", last \($h[-1].ts | floor | strflocaltime("%F %H:%M"))" else "" end)' "$1"
}
new_hits_jq() { # new_hits_jq <log> <id> <fqdn>: the streamed program bin/share's cmd_hits now runs
  jq -rn --arg p "/$2/" --arg h "$3" '
    def n($k; $w): "\($k) \($w)\(if $k == 1 then "" else "s" end)";
    [inputs | select((if $h == "" then (.request.uri | startswith($p)) else .request.host == $h end) and .status < 400)] as $h
    | n($h | length; "hit") + ", "
      + n($h | map(.request.headers["Cf-Connecting-Ip"][0] // .request.remote_ip) | unique | length; "visitor")
      + (if ($h | length) > 0 then ", last \($h[-1].ts | floor | strflocaltime("%F %H:%M"))" else "" end)' "$1"
}
: >"$WORK/hits-empty.log"
check "streamed hits == slurped, empty log" "$(old_hits_jq "$WORK/hits-empty.log" abc123 "")" "$(new_hits_jq "$WORK/hits-empty.log" abc123 "")"
printf '{"request":{"uri":"/other000/x","host":"s.example.test","headers":{"Cf-Connecting-Ip":["1.2.3.4"]}},"status":200,"ts":1700000000}\n' >"$WORK/hits-nomatch.log"
check "streamed hits == slurped, non-matching share" "$(old_hits_jq "$WORK/hits-nomatch.log" notpresent "")" "$(new_hits_jq "$WORK/hits-nomatch.log" notpresent "")"
check "streamed hits == slurped, real access log" "$(old_hits_jq "$SHARE_ROOT/access.log" "$hits_id" "")" "$(new_hits_jq "$SHARE_ROOT/access.log" "$hits_id" "")"
check "share hits (now streamed) matches the slurped reference" "$(old_hits_jq "$SHARE_ROOT/access.log" "$hits_id" "")" "$(bash "$SH" hits "$hits_id")"

bash "$SH" add 19991 >"$WORK/o19" 2>"$WORK/e19"; rc=$?
dead_url=$(head -1 "$WORK/o19")
check "dead backend still adds" "0" "$rc"
check "warns nothing answers" "1" "$(grep -c 'nothing answers on 127.0.0.1:19991 yet' "$WORK/e19")"
check "dead share returns 502" "502" "$(wait_code 502 "${dead_url}hello.txt")"

echo "=== concurrent writers ==="
# Live rows are the ones the Caddyfile names by id (handle_path /<id>/*), so the render is checkable.
all_ids() { cut -f1 "$SHARE_ROOT/index.tsv" | sort; }
live_ids() { awk -F'\t' '$6 ~ /(^| )live( |$)/ && $6 !~ /host=/ {print $1}' "$SHARE_ROOT/index.tsv" | sort; }
caddy_ids() { sed -n 's|^	handle_path /\([0-9a-f]*\)/\* {$|\1|p' "$SHARE_ROOT/Caddyfile" | sort; }
md_id=$(cut -d/ -f4 <<<"$md_url")
# Inert rows (no payload, not live, never expire) stretch every render to ~100ms, so the
# first remover can be caught mid-publish below.
for n in $(seq 100 159); do printf 'fad%s\tpad\t/nonexistent\t2026-01-01\t0\t\n' "$n"; done >>"$SHARE_ROOT/index.tsv"
first_gone() { # first_gone <ids>: one of the ids no longer in the index
  awk -F'\t' -v ids="$1" 'BEGIN {n = split(ids, a, " "); for (i = 1; i <= n; i++) w[a[i]] = 1}
    {delete w[$1]} END {for (k in w) {print k; exit}}' "$SHARE_ROOT/index.tsv"
}
for round in 1 2; do
  old_ids=""
  for p in 1 2 3 4 5 6; do old_ids="$old_ids $(bash "$SH" add "191$round$p" 2>/dev/null | head -1 | cut -d/ -f4)"; done
  before=$(all_ids)
  mkdir -p "$WORK/par$round" "$WORK/rmpid$round"; pids=""
  for p in 1 2 3 4 5 6; do
    (bash "$SH" add "192$round$p" 2>/dev/null | head -1 | cut -d/ -f4 >"$WORK/par$round/$p") & pids="$pids $!"
  done
  for i in $old_ids; do bash "$SH" rm "$i" >/dev/null 2>&1 & pids="$pids $!"; echo $! >"$WORK/rmpid$round/$i"; done
  bash "$SH" refresh "$md_id" >/dev/null 2>&1 & pids="$pids $!"
  # Freeze the first remover 50ms after its row leaves the index, i.e. inside its render.
  # Holding index_lock it blocks every other publish, so a short freeze does; a render done
  # outside the lock would read a stale index, so it stays frozen until the others finish
  # and its stale Caddyfile lands last.
  gone=""
  for _ in $(seq 1 500); do gone=$(first_gone "$old_ids"); [[ -n $gone ]] && break; sleep 0.01; done
  frozen=$(cat "$WORK/rmpid$round/$gone")
  sleep 0.05; kill -STOP "$frozen"
  if [[ $(readlink "$SHARE_ROOT/.lock-index" 2>/dev/null) == "$frozen" ]]; then sleep 0.3
  else
    for _ in $(seq 1 100); do
      busy=0; for q in $pids; do [[ $q != "$frozen" ]] && kill -0 "$q" 2>/dev/null && busy=1; done
      [[ $busy == 0 ]] && break; sleep 0.05
    done
  fi
  kill -CONT "$frozen"
  # shellcheck disable=SC2086 # word-split pid list; a bare wait would also wait on the backend fixture
  wait $pids
  expected=$( (grep -vxF -f <(tr ' ' '\n' <<<"$old_ids" | grep .) <<<"$before"; cat "$WORK/par$round"/*) | sort)
  check "round $round: 6 adds each got an id" "6" "$(cat "$WORK/par$round"/* | grep -cE '^[0-9a-f]{6}$')"
  check "round $round: parallel add/rm/refresh keep exactly the expected rows" "$expected" "$(all_ids)"
  check "round $round: Caddyfile lists exactly the surviving live ids" "$(live_ids)" "$(caddy_ids)"
  check "round $round: no lock left behind" "0" "$(lock_count)"
done
grep -v $'\tpad\t' "$SHARE_ROOT/index.tsv" >"$WORK/i" && mv "$WORK/i" "$SHARE_ROOT/index.tsv"

sh -c 'exit 0' & dead=$!; wait "$dead"
ln -s "$dead" "$SHARE_ROOT/.lock-index"
bash "$SH" add 19131 >/dev/null 2>&1; rc=$?
check "a dead holder's index lock is broken, add succeeds" "0" "$rc"
check "the add behind the dead lock wrote its row" "1" "$(grep -c 'localhost:19131' "$SHARE_ROOT/index.tsv")"
check "the broken lock is gone" "0" "$(lock_count)"

echo "=== folder index ==="
mkdir -p "$WORK/listme" && echo data >"$WORK/listme/file.txt" && printf '# Doc\n' >"$WORK/listme/other.md"
list_url=$(bash "$SH" add "$WORK/listme" 2>/dev/null | head -1)
list_id=$(cut -d/ -f4 <<<"$list_url")
check "folder without index gets a listing" "200" "$(wait_code 200 "$list_url")"
list_body=$(curl -s "$(local_url "$list_url")")
check "txt linked by name" "1" "$(grep -c 'file.txt' <<<"$list_body")"
if command -v pandoc >/dev/null; then
  check ".md listed by its render" "1" "$(grep -c 'href="other.html"' <<<"$list_body")"
fi

noidx_url=$(bash "$SH" add --no-index "$WORK/listme" 2>/dev/null | head -1)
check "--no-index keeps the 404" "404" "$(wait_code 404 "$noidx_url")"

mkdir -p "$WORK/withreadme" && printf '# Readme\n' >"$WORK/withreadme/README.md" && echo x >"$WORK/withreadme/x.txt"
wr_url=$(bash "$SH" add "$WORK/withreadme" 2>/dev/null | head -1)
check "README folder answers" "200" "$(wait_code 200 "$wr_url")"
wr_body=$(curl -s "$(local_url "$wr_url")")
if command -v pandoc >/dev/null; then
  check "README render is the index" "1" "$(grep -c 'max-width:44rem' <<<"$wr_body")"
  check "no generated list under a README" "0" "$(grep -c '<ul' <<<"$wr_body")"
fi

bash "$SH" refresh "$list_id" >/dev/null
list_body=$(curl -s "$(local_url "$list_url")")
check "refresh keeps the listing" "1" "$(grep -c 'file.txt' <<<"$list_body")"

mkdir -p "$WORK/nested/sub" && echo top >"$WORK/nested/top.txt" && echo deep >"$WORK/nested/sub/deep.txt"
nested_url=$(bash "$SH" add "$WORK/nested" 2>/dev/null | head -1)
check "nested folder answers" "200" "$(wait_code 200 "$nested_url")"
nested_body=$(curl -s "$(local_url "$nested_url")")
check "nested file listed by path" "1" "$(grep -c 'href="sub/deep.txt"' <<<"$nested_body")"
check "no subfolder entry" "0" "$(grep -cE 'href="sub/?"' <<<"$nested_body")"

echo "=== TASK-003: pure-bash urlenc / fork-free share_url ==="
echo "--- urlenc matches jq @uri byte for byte, under bash and /bin/bash ---"
urlenc_probe="$WORK/urlenc-probe.sh"
{
  sed -n '/^urlenc() {/,/^}/p' "$SH"
  # shellcheck disable=SC2016 # literal code for the probe script, not this shell's expansion
  echo 'urlenc "$1"; printf %s "$urlenc_out"'
} >"$urlenc_probe"
jq_urlenc() { jq -rn --arg p "$1" '[$p | split("/")[] | @uri] | join("/")'; }
enc_fail=0
while IFS= read -r enc_name; do
  enc_want="$(jq_urlenc "$enc_name")"
  for enc_shell in bash /bin/bash; do
    enc_got="$("$enc_shell" "$urlenc_probe" "$enc_name")"
    [[ $enc_got == "$enc_want" ]] || { echo "  FAIL  urlenc($enc_shell) [$enc_name]: want [$enc_want] got [$enc_got]"; enc_fail=1; }
  done
done <<'ENCNAMES'
with space.md
a#b?c%d&e+f=g
bang!star'paren(x).txt
café.md
日本語.txt
emoji 🎉.png
dir/sub dir/file.html
ENCNAMES
check "urlenc matches jq @uri for the fixed name list, bash and /bin/bash" "0" "$enc_fail"

echo "--- a name with # and é serves 200 through the link share ls prints ---"
hash_name="hash#café.txt"
echo data >"$WORK/$hash_name"
hash_out=$(bash "$SH" add "$WORK/$hash_name" 2>/dev/null)
hash_url=$(head -1 <<<"$hash_out")
hash_id=$(cut -d/ -f4 <<<"$hash_url")
ls_url=$(bash "$SH" ls | grep -B1 "id=$hash_id" | head -1)
check "share ls prints the same link share add did" "$hash_url" "$ls_url"
check "the hash+accent link serves 200" "200" "$(wait_code 200 "$hash_url")"
bash "$SH" rm "$hash_id" >/dev/null

echo "=== own hostname (dry) ==="
mkdir -p "$WORK/dist" && echo '<h1>spa</h1>' >"$WORK/dist/index.html"
: >"$SHARE_ROOT/host-calls.log"
host_url=$(SHARE_HOST_DRY=1 bash "$SH" add "$WORK/dist" --host app.example.test 2>/dev/null | head -1)
host_id=$(awk -F'\t' '$6 ~ /host=app\.example\.test/ {print $1}' "$SHARE_ROOT/index.tsv")
check "host link is the fqdn" "https://app.example.test/" "$host_url"
check "host row in ls" "1" "$(bash "$SH" ls | grep -c 'https://app.example.test/')"
check "deep link serves index.html" "<h1>spa</h1>" "$(wait_code 200 "http://127.0.0.1:$SHARE_PORT/deep/link" app.example.test >/dev/null; curl -s -H 'Host: app.example.test' "http://127.0.0.1:$SHARE_PORT/deep/link")"
put_ln=$(grep -n 'PUT ingress +1' "$SHARE_ROOT/host-calls.log" | cut -d: -f1)
post_ln=$(grep -n 'POST CNAME' "$SHARE_ROOT/host-calls.log" | cut -d: -f1)
check "ingress PUT before CNAME POST" "1" "$([[ -n $put_ln && -n $post_ln && $put_ln -lt $post_ln ]] && echo 1 || echo 0)"

SHARE_HOST_DRY=1 bash "$SH" rm "$host_id" >/dev/null
del_ln=$(grep -n 'DELETE CNAME' "$SHARE_ROOT/host-calls.log" | cut -d: -f1)
prm_ln=$(grep -n 'PUT ingress -1' "$SHARE_ROOT/host-calls.log" | cut -d: -f1)
check "DELETE CNAME before ingress PUT" "1" "$([[ -n $del_ln && -n $prm_ln && $del_ln -lt $prm_ln ]] && echo 1 || echo 0)"
check "host share 404 after rm" "404" "$(wait_code 404 "http://127.0.0.1:$SHARE_PORT/deep/link" app.example.test)"

out=$(SHARE_HOST_DRY=1 bash "$SH" add --host dev.s.example.test "$WORK/dist" 2>&1 1>/dev/null); rc=$?
check "two-label host refused" "1" "$rc"
check "one-label message" "1" "$(grep -c 'one label under' <<<"$out")"
out=$(SHARE_HOST_DRY=1 bash "$SH" add --host other.zone "$WORK/dist" 2>&1 1>/dev/null); rc=$?
check "foreign zone refused" "1" "$rc"
check "one-label message again" "1" "$(grep -c 'one label under' <<<"$out")"

idx_before_main=$(cksum <"$SHARE_ROOT/index.tsv")
out=$(SHARE_HOST_DRY=1 bash "$SH" add --host "$SHARE_HOSTNAME" "$WORK/dist" 2>&1 1>/dev/null); rc=$?
check "--host the main hostname is refused" "1" "$rc"
check "main hostname message" "1" "$(grep -c 'cannot be the main hostname' <<<"$out")"
check "no row for the main hostname host" "$idx_before_main" "$(cksum <"$SHARE_ROOT/index.tsv")"

out=$(env -u CLOUDFLARE_API_TOKEN bash "$SH" add --host nope.example.test "$WORK/dist" 2>&1 1>/dev/null); rc=$?
check "no credential refused" "1" "$rc"
check "no row for refused host" "0" "$(grep -c 'nope.example.test' "$SHARE_ROOT/index.tsv")"

SHARE_HOST_DRY=1 bash "$SH" add "$WORK/dist" --host die.example.test >/dev/null 2>&1
die_id=$(awk -F'\t' '$6 ~ /host=die\.example\.test/ {print $1}' "$SHARE_ROOT/index.tsv")
cat >"$SHARE_ROOT/host-fixture.json" <<'EOF'
{"config":{"ingress":[{"service":"http_status:404"},{"hostname":"s.example.test","service":"http://127.0.0.1:18787"}]}}
EOF
: >"$SHARE_ROOT/host-calls.log"
out=$(SHARE_HOST_DRY=1 bash "$SH" add "$WORK/dist" --host broken.example.test 2>&1 1>/dev/null); rc=$?
check "tampered ingress refused" "1" "$rc"
check "dashboard hint" "1" "$(grep -c 'dashboard' <<<"$out")"
check "no PUT logged" "0" "$(grep -c PUT "$SHARE_ROOT/host-calls.log")"
SHARE_HOST_DRY=1 bash "$SH" rm "$die_id" >/dev/null 2>&1; rc=$?
check "host_rm on tampered ingress dies" "1" "$rc"
check "host_rm die leaves neither .lock-host nor .lock-index" "0" "$(lock_count)"
awk -F'\t' -v OFS='\t' -v id="$die_id" '$1 == id {$5 = 1} {print}' "$SHARE_ROOT/index.tsv" >"$WORK/i" && mv "$WORK/i" "$SHARE_ROOT/index.tsv"
# both shells: bash 5.3 and 3.2 differ on EXIT traps in pipeline subshells
for b in bash /bin/bash; do
  out=$(SHARE_HOST_DRY=1 "$b" "$SH" prune 2>&1 1>/dev/null)
  check "prune dies on the expired host row ($b)" "1" "$(grep -c 'tunnel ingress was edited outside share' <<<"$out")"
  check "a die inside prune's pipeline leaves no lock ($b)" "0" "$(lock_count)"
done
rm -f "$SHARE_ROOT/host-fixture.json"
SHARE_HOST_DRY=1 bash "$SH" rm "$die_id" >/dev/null 2>&1
check "the died share removes once ingress is sane" "0" "$(grep -c 'die.example.test' "$SHARE_ROOT/index.tsv")"

mkdir "$SHARE_ROOT/.lock-host"
out=$(SHARE_HOST_DRY=1 SHARE_HOST_LOCK_TIMEOUT=1 bash "$SH" add "$WORK/dist" --host locked.example.test 2>&1 1>/dev/null); rc=$?
check "held lock refuses" "1" "$rc"
check "lock message" "1" "$(grep -c 'another share command holds the host lock' <<<"$out")"
rmdir "$SHARE_ROOT/.lock-host"
ln -s $$ "$SHARE_ROOT/.lock-host"   # a live holder: this suite's own pid
out=$(SHARE_HOST_DRY=1 SHARE_HOST_LOCK_TIMEOUT=1 bash "$SH" add "$WORK/dist" --host locked.example.test 2>&1 1>/dev/null); rc=$?
check "live pid lock refuses" "1" "$rc"
check "live lock kept" "$$" "$(readlink "$SHARE_ROOT/.lock-host")"
rm -f "$SHARE_ROOT/.lock-host"
sh -c 'exit 0' & dead=$!; wait "$dead"
ln -s "$dead" "$SHARE_ROOT/.lock-host"
SHARE_HOST_DRY=1 bash "$SH" add "$WORK/dist" --host stale.example.test >/dev/null 2>&1; rc=$?
check "a dead holder's host lock is broken, add succeeds" "0" "$rc"
check "no lock after the stale break" "0" "$(lock_count)"
stale_id=$(awk -F'\t' '$6 ~ /host=stale\.example\.test/ {print $1}' "$SHARE_ROOT/index.tsv")
SHARE_HOST_DRY=1 bash "$SH" rm "$stale_id" >/dev/null 2>&1

echo "=== serve restart renders live and host rows ==="
SHARE_HOST_DRY=1 bash "$SH" add "$WORK/dist" --host fresh.example.test >/dev/null 2>&1
bash "$SH" stop >/dev/null
bash "$SH" start >/dev/null
check "Caddyfile has handle_path" "1" "$(grep -q 'handle_path' "$SHARE_ROOT/Caddyfile" && echo 1 || echo 0)"
check "Caddyfile has the host block" "1" "$(grep -c 'http://fresh.example.test:' "$SHARE_ROOT/Caddyfile")"
check "no admin off" "0" "$(grep -c 'admin off' "$SHARE_ROOT/Caddyfile")"
check "fresh host answers after restart" "200" "$(wait_code 200 "http://127.0.0.1:$SHARE_PORT/deep/link" fresh.example.test)"

echo "=== reload failure keeps the row ==="
out=$(PATH=/usr/bin:/bin bash "$SH" add 19992 2>&1 1>/dev/null); rc=$?
check "add still exits 0" "0" "$rc"
check "reload error names caddy.log" "1" "$(grep -c 'caddy.log' <<<"$out")"
check "row survives reload failure" "1" "$(grep -c 'localhost:19992' "$SHARE_ROOT/index.tsv")"

echo "=== quick tunnel mode ==="
# A fake cloudflared: prints the banner URL (or dies when SHARE_FAKE_QUICK_URL=none), then idles.
mkdir -p "$WORK/fakebin"
cat >"$WORK/fakebin/cloudflared" <<'EOF'
#!/bin/bash
u="${SHARE_FAKE_QUICK_URL:-fake-tunnel}"
[[ $u == none ]] && exit 1
echo "INF |  https://$u.trycloudflare.com  |" >&2
exec sleep 600
EOF
chmod +x "$WORK/fakebin/cloudflared"
QPATH="$WORK/fakebin:$PATH"
qurl() { echo "$1" | sed -E "s|https://[^/]+|http://127.0.0.1:$SHARE_PORT|"; }
qwait() { # qwait <fqdn>: poll quick.url for 5s
  local _; for _ in $(seq 1 50); do [[ $(cat "$SHARE_ROOT/quick.url" 2>/dev/null) == "$1" ]] && return 0; sleep 0.1; done; return 1
}

bash "$SH" stop >/dev/null
printf 'tunnel_id=abc123\nhostname=s.example.test\n' >"$SHARE_CONFIG_DIR/config"
out=$(SHARE_TUNNEL=1 PATH="$QPATH" bash "$SH" setup --quick 2>&1); rc=$?
check "quick setup refuses over a named config" "1" "$rc"
check "names teardown" "1" "$(grep -c 'share teardown' <<<"$out")"
rm -f "$SHARE_CONFIG_DIR/config"

SHARE_LIVE_CHECK=0 SHARE_TUNNEL=1 PATH="$QPATH" bash "$SH" setup --quick --no-service >/dev/null
check "config has mode=quick" "1" "$(grep -c '^mode=quick' "$SHARE_CONFIG_DIR/config")"
check "no tunnel_id written" "0" "$(grep -c 'tunnel_id' "$SHARE_CONFIG_DIR/config")"
check "no cert or token" "0" "$([[ -f $SHARE_CONFIG_DIR/cert.pem || -f $SHARE_CONFIG_DIR/tunnel-token ]] && echo 1 || echo 0)"
qwait fake-tunnel.trycloudflare.com
check "quick.url parsed from the log" "fake-tunnel.trycloudflare.com" "$(cat "$SHARE_ROOT/quick.url")"
check "status shows the quick URL" "1" "$(bash "$SH" status | grep -c 'https://fake-tunnel.trycloudflare.com (quick tunnel')"

out=$(SHARE_TUNNEL=1 PATH="$QPATH" bash "$SH" setup s2.example.test 2>&1); rc=$?
check "named setup refuses over a quick config" "1" "$rc"
check "names teardown again" "1" "$(grep -c 'share teardown' <<<"$out")"
SHARE_TUNNEL=1 PATH="$QPATH" bash "$SH" setup --quick s2.example.test >/dev/null 2>&1
check "setup --quick <host> is a usage error" "1" "$?"

q_file=$(bash "$SH" add "$WORK/outside.txt" 2>/dev/null | head -1)
check "quick link is on the trycloudflare host" "1" "$(grep -cE '^https://fake-tunnel\.trycloudflare\.com/[0-9a-f]{6}/outside\.txt$' <<<"$q_file")"
check "quick file answers locally" "200" "$(wait_code 200 "$(qurl "$q_file")")"

q_live=$(bash "$SH" add "$FIX_PORT" 2>/dev/null | head -1)
check "quick live link" "1" "$(grep -cE '^https://fake-tunnel\.trycloudflare\.com/[0-9a-f]{6}/$' <<<"$q_live")"
check "quick live proxies" "hello fixture" "$(curl -s "$(qurl "${q_live}hello.txt")")"

out=$(bash "$SH" add "$WORK/outside.txt" --host a.example.test 2>&1 1>/dev/null); rc=$?
check "--host refused in quick mode" "1" "$rc"
check "--host message names teardown" "1" "$(grep -c 'share teardown' <<<"$out")"
check "no host row written" "0" "$(grep -c 'host=a\.example\.test' "$SHARE_ROOT/index.tsv")"

# restart: a stale quick.url must never survive; the new URL wins
bash "$SH" stop >/dev/null
check "stop clears quick.url" "0" "$([[ -f $SHARE_ROOT/quick.url ]] && echo 1 || echo 0)"
SHARE_LIVE_CHECK=0 SHARE_FAKE_QUICK_URL=second-tunnel SHARE_TUNNEL=1 PATH="$QPATH" bash "$SH" start >/dev/null
qwait second-tunnel.trycloudflare.com
check "restart yields the new URL" "second-tunnel.trycloudflare.com" "$(cat "$SHARE_ROOT/quick.url")"
q2_file=$(bash "$SH" add "$WORK/outside.txt" 2>/dev/null | head -1)
q2_id=$(cut -d/ -f4 <<<"$q2_file")
check "links move to the new host" "1" "$(grep -c 'second-tunnel' <<<"$q2_file")"
bash "$SH" rm "$q2_file" >/dev/null
check "rm accepts a pasted quick link" "0" "$(grep -c "$q2_id" "$SHARE_ROOT/index.tsv")"

bash "$SH" stop >/dev/null
out=$(SHARE_FAKE_QUICK_URL=none SHARE_TUNNEL=1 PATH="$QPATH" bash "$SH" serve 2>&1); rc=$?
check "no URL dies" "1" "$rc"
check "die names cloudflared.log" "1" "$(grep -c 'cloudflared.log' <<<"$out")"
check "caddy reaped on parse death" "000" "$(wait_code 000 "http://127.0.0.1:$SHARE_PORT/x")"

SHARE_LIVE_CHECK=0 SHARE_FAKE_QUICK_URL=third SHARE_TUNNEL=1 PATH="$QPATH" bash "$SH" start >/dev/null
qwait third.trycloudflare.com
q3=$(bash "$SH" add "$WORK/outside.txt" 2>/dev/null | head -1)
check "third URL in use" "1" "$(grep -c 'third.trycloudflare' <<<"$q3")"

# the serve process's own EXIT trap must clear quick.url too, not only cmd_stop:
# kill the pid directly instead of going through `share stop`.
serve_pid="$(cat "$SHARE_ROOT/serve.pid")"
kill "$serve_pid"
for _ in $(seq 1 50); do kill -0 "$serve_pid" 2>/dev/null || break; sleep 0.1; done
check "quick.url gone once the serve process exits, not via stop" "0" "$([[ -f $SHARE_ROOT/quick.url ]] && echo 1 || echo 0)"

bash "$SH" stop >/dev/null
SHARE_LIVE_CHECK=0 SHARE_TUNNEL=0 PATH="$QPATH" bash "$SH" start >/dev/null
sleep 0.5
q4=$(bash "$SH" add "$WORK/outside.txt" 2>/dev/null | head -1)
check "tunnel=0 still serves locally" "200" "$(curl -s -o /dev/null -w '%{http_code}' "$(qurl "$q4")")"

bash "$SH" teardown --yes >/dev/null
check "quick teardown exits 0" "0" "$?"
check "config trashed" "0" "$([[ -f $SHARE_CONFIG_DIR/config ]] && echo 1 || echo 0)"
check "quick.url gone" "0" "$([[ -f $SHARE_ROOT/quick.url ]] && echo 1 || echo 0)"

echo "=== profiles ==="
echo "--- derived paths, label, and the name check (probe of the top block) ---"
prof_probe="$WORK/profile-probe.sh"
{
  sed -n '/^die() {/p' "$SH"
  sed -n '/^profile=/,/^root=/p' "$SH"          # the flag parse, the name check, config_dir, root
  sed -n '/^svc_label=/p' "$SH"
  # shellcheck disable=SC2016 # literal code for the probe script, not this shell's expansion
  echo 'printf "%s|%s|%s" "$config_dir" "$root" "$svc_label"'
} >"$prof_probe"
pp() { # pp [VAR=value]... [args]: the probe under a clean environment and HOME=/h
  local e=(); while [[ ${1:-} == *=* ]]; do e+=("$1"); shift; done
  env -u SHARE_ROOT -u SHARE_CONFIG_DIR -u SHARE_SERVICE_LABEL -u XDG_CONFIG_HOME -u SHARE_PROFILE HOME=/h ${e[@]+"${e[@]}"} bash "$prof_probe" "$@"
}
dflt_derived="/h/.config/share|/h/share|foundation.d.share"
a_derived="/h/.config/share/profiles/a|/h/share/profiles/a|foundation.d.share.a"
check "no profile: today's paths and label" "$dflt_derived" "$(pp)"
check "--profile default is the same as no profile" "$dflt_derived" "$(pp --profile default)"
check "SHARE_PROFILE= (empty) is the default" "$dflt_derived" "$(pp SHARE_PROFILE=)"
check "--profile a: paths under profiles/a, label suffixed" "$a_derived" "$(pp --profile a)"
check "SHARE_PROFILE=a: the same derivation" "$a_derived" "$(pp SHARE_PROFILE=a)"
check "the flag wins over SHARE_PROFILE" "$a_derived" "$(pp SHARE_PROFILE=b --profile a)"
check "--profile default wins over SHARE_PROFILE=a" "$dflt_derived" "$(pp SHARE_PROFILE=a --profile default)"
for bad in '../x' 'a b' 'A' 'x/y' '-a'; do
  out=$(pp --profile "$bad" 2>&1 1>/dev/null); rc=$?
  check "profile name '$bad' is refused" "1" "$rc"
  check "the refusal names the rule for '$bad'" "1" "$(grep -c 'bad profile name' <<<"$out")"
  out=$(pp SHARE_PROFILE="$bad" 2>&1 1>/dev/null); rc=$?
  check "SHARE_PROFILE='$bad' is refused too" "1" "$rc"
done
out=$(pp --profile 2>&1 1>/dev/null); rc=$?
check "--profile with no name is a usage error" "1" "$rc"
check "the usage names the flag" "1" "$(grep -c 'share --profile <name> <command>' <<<"$out")"
out=$(pp teardown --yes --profile a 2>&1 1>/dev/null); rc=$?
check "--profile after the verb is refused" "1" "$rc"
check "the refusal says where the flag goes" "1" "$(grep -c 'goes before the verb' <<<"$out")"
out=$(pp stop --profile=a 2>&1 1>/dev/null); rc=$?
check "--profile=<name> after the verb is refused" "1" "$rc"
check "help shows the --profile line and the profiles verb" "2" "$(bash "$SH" --help | grep -c 'share --profile <name> <command>\|^  share profiles')"
check "help reaches teardown (the last usage line)" "1" "$(bash "$SH" --help | grep -c '^  share teardown')"
# every hint that names a command builds it from the profile: a bare `share <verb>` outside the usage
# header, a usage: line, a comment, or the backticked skill text is a hint that points at the default install
check "no hint names a bare share <verb>" "0" "$(grep -nE '[^`]share (setup|teardown|start|stop|rm|refresh|add|service|status)([^a-z-]|$)' "$SH" | grep -v '^[0-9]*:#' | grep -vc 'usage:')"

echo "--- Keychain item keyed per profile (stubbed security; the token never reaches argv) ---"
mkdir -p "$WORK/fakesec"
cat >"$WORK/fakesec/security" <<'EOF'
#!/bin/bash
# records the verb and the -s service name it was asked for, never the -w value
log="${SEC_LOG:?}"
if [[ $1 == -i ]]; then
  while IFS= read -r line; do svc="${line#*-s \"}"; echo "${line%% *} ${svc%%\"*}" >>"$log"; done
  exit 0
fi
prev=""; for a in "$@"; do [[ $prev == -s ]] && echo "$1 $a" >>"$log"; prev="$a"; done
echo faketoken
EOF
chmod +x "$WORK/fakesec/security"
kc_probe="$WORK/kc-probe.sh"
{
  # setup's real order: the token code loads while the hostname is still empty (a first
  # setup has no config), setup assigns it later, then stores; a key fixed at load time misses
  # shellcheck disable=SC2016 # literal code for the probe script, not this shell's expansion
  echo 'profile="$1" host_name="" config="/nonexistent/config" config_dir="/nonexistent"'
  sed -n '/^cfg() {/p' "$SH"
  sed -n '/^token_file=/,/^token_forget() {/p' "$SH" | sed '$d'   # token_file, token_key, token_read, token_store
  # shellcheck disable=SC2016 # literal code for the probe script, not this shell's expansion
  echo 'host_name="$2"; token_store "s3cret-value" >/dev/null; token_read >/dev/null'
} >"$kc_probe"
: >"$WORK/sec.log"
SEC_LOG="$WORK/sec.log" PATH="$WORK/fakesec:$PATH" bash "$kc_probe" "" s.example.test
SEC_LOG="$WORK/sec.log" PATH="$WORK/fakesec:$PATH" bash "$kc_probe" a s.example.test
check "default profile stores share-tunnel:<host>" "1" "$(grep -c '^add-generic-password share-tunnel:s.example.test$' "$WORK/sec.log")"
check "default profile reads share-tunnel:<host>" "1" "$(grep -c '^find-generic-password share-tunnel:s.example.test$' "$WORK/sec.log")"
check "profile a stores share-tunnel.a:<host>" "1" "$(grep -c '^add-generic-password share-tunnel.a:s.example.test$' "$WORK/sec.log")"
check "profile a reads share-tunnel.a:<host>" "1" "$(grep -c '^find-generic-password share-tunnel.a:s.example.test$' "$WORK/sec.log")"
check "the two profiles never share an item" "2" "$(cut -d' ' -f2 "$WORK/sec.log" | sort -u | wc -l | tr -d ' ')"
check "no key was built before setup knew the hostname" "0" "$(grep -c ':$' "$WORK/sec.log")"
check "the token value never reached the stub's argv or log" "0" "$(grep -c 's3cret' "$WORK/sec.log")"

echo "--- two quick profiles serve at once under one HOME, each on its own port ---"
PHOME="$WORK/home"; mkdir -p "$PHOME"
psh() { # psh <profile> <verb...>: a profile command under a private HOME with no path or port override
  env -u SHARE_ROOT -u SHARE_CONFIG_DIR -u SHARE_PORT -u SHARE_HOSTNAME -u SHARE_SERVICE_LABEL -u XDG_CONFIG_HOME \
    HOME="$PHOME" SHARE_LIVE_CHECK=0 SHARE_TUNNEL=1 PATH="$QPATH" bash "$SH" --profile "$@"
}
pcfg() { sed -n "s/^port=//p" "$PHOME/.config/share/profiles/$1/config" 2>/dev/null; }
SHARE_FAKE_QUICK_URL=prof-a psh a setup --quick --no-service >"$WORK/prof-a.setup" 2>&1
check "profile a sets up" "0" "$?"
SHARE_FAKE_QUICK_URL=prof-b psh b setup --quick --no-service >"$WORK/prof-b.setup" 2>&1
check "profile b sets up" "0" "$?"
pa=$(pcfg a); pb=$(pcfg b)
check "profile a config holds a picked port" "1" "$([[ $pa =~ ^[0-9]+$ && $pa -ge 8789 ]] && echo 1 || echo 0)"
check "setup printed the picked port" "1" "$(grep -c "^port:       $pa (metrics $((pa + 1)))" "$WORK/prof-a.setup")"
check "the two profiles' ports differ" "1" "$([[ -n $pb && $pa != "$pb" ]] && echo 1 || echo 0)"
check "neither port pair overlaps the other or the default's 8787/8788" "1" \
  "$([[ $pa != 8787 && $pa != 8788 && $pb != 8787 && $pb != 8788 && $((pa + 1)) != "$pb" && $((pb + 1)) != "$pa" ]] && echo 1 || echo 0)"
# a live share of another profile (even a dead dev server) must not become a new profile's port:
# the default hostname would proxy the new profile's caddy
mkdir -p "$PHOME/share"; printf 'l1ve01\tlocalhost:%s\thttp://127.0.0.1:%s\t2026-01-01\t0\tlive\n' "$((pb + 2))" "$((pb + 2))" >"$PHOME/share/index.tsv"
SHARE_FAKE_QUICK_URL=prof-l psh l setup --quick --no-service >/dev/null 2>&1
check "the pick skips a port another profile live-shares" "1" "$([[ $(pcfg l) != "$((pb + 2))" && $(pcfg l) != "$((pb + 1))" ]] && echo 1 || echo 0)"
psh l teardown --yes >/dev/null 2>&1; rm -rf "$PHOME/share/profiles/l" "$PHOME/share/index.tsv"
check "profile a is serving" "1" "$(psh a status | grep -c '^serving')"
check "profile b is serving" "1" "$(psh b status | grep -c '^serving')"
check "profile config dirs are where the spec says" "1" "$([[ -d $PHOME/.config/share/profiles/a && -d $PHOME/.config/share/profiles/b ]] && echo 1 || echo 0)"
check "profile roots are where the spec says" "1" "$([[ -f $PHOME/share/profiles/a/serve.pid && -f $PHOME/share/profiles/b/serve.pid ]] && echo 1 || echo 0)"
check "the default root under this HOME was never created" "0" "$([[ -e $PHOME/share/pub || -e $PHOME/.config/share/config ]] && echo 1 || echo 0)"

pa_url=$(psh a add "$WORK/outside.txt" 2>/dev/null | head -1); pa_id=$(cut -d/ -f4 <<<"$pa_url")
pb_url=$(psh b add "$WORK/outside.txt" 2>/dev/null | head -1); pb_id=$(cut -d/ -f4 <<<"$pb_url")
check "profile a link is on its own quick host" "1" "$(grep -c '^https://prof-a\.trycloudflare\.com/' <<<"$pa_url")"
check "profile b link is on its own quick host" "1" "$(grep -c '^https://prof-b\.trycloudflare\.com/' <<<"$pb_url")"
check "a's share answers on a's port" "200" "$(wait_code 200 "http://127.0.0.1:$pa/$pa_id/outside.txt")"
check "a's share is absent on b's port" "404" "$(wait_code 404 "http://127.0.0.1:$pb/$pa_id/outside.txt")"
check "b's share answers on b's port" "200" "$(wait_code 200 "http://127.0.0.1:$pb/$pb_id/outside.txt")"
check "share ls under a shows only a" "$pa_id" "$(psh a ls | sed -n 's/.*id=\([0-9a-f]*\).*/\1/p' | tr '\n' ' ' | sed 's/ $//')"
check "share ls under b shows only b" "$pb_id" "$(psh b ls | sed -n 's/.*id=\([0-9a-f]*\).*/\1/p' | tr '\n' ' ' | sed 's/ $//')"
check "SHARE_PROFILE=b from the environment also lists b" "$pb_id" "$(env -u SHARE_ROOT -u SHARE_CONFIG_DIR -u SHARE_PORT -u SHARE_HOSTNAME HOME="$PHOME" SHARE_TUNNEL=1 SHARE_PROFILE=b bash "$SH" ls | sed -n 's/.*id=\([0-9a-f]*\).*/\1/p')"

echo "--- share profiles lists every profile with state and host ---"
psh a profiles >"$WORK/profiles.out"
check "profiles: three lines" "3" "$(wc -l <"$WORK/profiles.out" | tr -d ' ')"
check "profiles: default first, not set up under this HOME" "default	not_setup	-" "$(sed -n 1p "$WORK/profiles.out")"
check "profiles: a serving on its host" "a	serving	prof-a.trycloudflare.com" "$(grep '^a	' "$WORK/profiles.out")"
check "profiles: b serving on its host" "b	serving	prof-b.trycloudflare.com" "$(grep '^b	' "$WORK/profiles.out")"
# a profile whose state cannot be read (a port that is not a number breaks the script's arithmetic) is one error row, not a dead listing
mkdir -p "$PHOME/.config/share/profiles/bad" && echo 'port=1e3' >"$PHOME/.config/share/profiles/bad/config"
psh a profiles >"$WORK/profiles-bad.out"
check "profiles: an unreadable profile is an error row" "bad	error	-" "$(grep '^bad	' "$WORK/profiles-bad.out")"
check "profiles: the other rows survive the error" "3" "$(grep -c 'not_setup\|serving' "$WORK/profiles-bad.out")"
out=$(psh a add "$pb" 2>&1 1>/dev/null); rc=$?
check "another profile's corrupt port= does not break this profile's port refusal" "1" "$([[ $rc == 1 ]] && grep -c 'another share profile' <<<"$out")"
echo 'port=08789' >"$PHOME/.config/share/profiles/bad/config"   # a leading zero reads as octal in $(( )) and aborts bash
out=$(psh a add "$pb" 2>&1 1>/dev/null); rc=$?
check "another profile's leading-zero port= does not break this profile's port refusal" "1" "$([[ $rc == 1 ]] && grep -c 'another share profile' <<<"$out")"
check "profiles: a leading-zero port is an error row too" "bad	error	-" "$(psh a profiles | grep '^bad	')"
rm -rf "$PHOME/.config/share/profiles/bad"
# an exported SHARE_ROOT must not leak into the per-profile state reads: each row is its own setup
env -u SHARE_CONFIG_DIR -u SHARE_PORT -u SHARE_HOSTNAME -u SHARE_SERVICE_LABEL -u XDG_CONFIG_HOME HOME="$PHOME" SHARE_ROOT="$WORK/elsewhere" \
  SHARE_TUNNEL=1 PATH="$QPATH" bash "$SH" --profile a profiles >"$WORK/profiles-override.out"
check "profiles under an exported SHARE_ROOT still reads each profile's own state" "a	serving	prof-a.trycloudflare.com b	serving	prof-b.trycloudflare.com" \
  "$(grep '^[ab]	' "$WORK/profiles-override.out" | tr '\n' ' ' | sed 's/ $//')"

echo "--- rerun setup keeps the port; rm, refresh, hits, state act on one profile ---"
SHARE_FAKE_QUICK_URL=prof-a psh a setup --quick --no-service >/dev/null 2>&1
check "rerun keeps a's port" "$pa" "$(pcfg a)"
check "a's state has one share" "1" "$(psh a state | jq '.shares | length')"
check "a's hits counts a's fetches" "1" "$(psh a hits "$pa_id" | grep -cE '^[1-9][0-9]* hits?')"
psh a refresh "$pa_id" >/dev/null 2>&1
check "refresh under a exits 0" "0" "$?"
psh a rm "$pa_id" >/dev/null
check "rm under a removes a's row" "0" "$(psh a state | jq '.shares | length')"
check "rm under a leaves b's row" "1" "$(psh b state | jq '.shares | length')"
check "b's share still answers" "200" "$(code "http://127.0.0.1:$pb/$pb_id/outside.txt")"

echo "--- the service file of a profile carries SHARE_PROFILE (stubbed launchctl/systemctl) ---"
mkdir -p "$WORK/fakesvc"
# shellcheck disable=SC2016 # literal code for the stub, not this shell's expansion
printf '#!/bin/bash\n[[ $1 == print ]] && exit 1\nexit 0\n' >"$WORK/fakesvc/launchctl"
printf '#!/bin/bash\nexit 0\n' >"$WORK/fakesvc/systemctl"
chmod +x "$WORK/fakesvc/launchctl" "$WORK/fakesvc/systemctl"
# profile c never serves: install writes the file, then the 10s wait for a server dies (exit 1), which is expected here
PATH="$WORK/fakesvc:$QPATH" psh c service install >/dev/null 2>&1
svc_file=""
for f in "$PHOME/Library/LaunchAgents/foundation.d.share.c.plist" "$PHOME/.config/systemd/user/foundation.d.share.c.service"; do [[ -f $f ]] && svc_file="$f"; done
check "profile c's service file uses the suffixed label" "1" "$([[ -n $svc_file ]] && echo 1 || echo 0)"
check "profile c's service file carries SHARE_PROFILE=c" "1" "$(grep -c 'SHARE_PROFILE' "$svc_file")"
check "profile c's service file pins its own config dir and root" "1" "$({ grep -qF "SHARE_CONFIG_DIR</key><string>$PHOME/.config/share/profiles/c<" "$svc_file" || grep -qF "SHARE_CONFIG_DIR=$PHOME/.config/share/profiles/c\"" "$svc_file"; } && { grep -qF "SHARE_ROOT</key><string>$PHOME/share/profiles/c<" "$svc_file" || grep -qF "SHARE_ROOT=$PHOME/share/profiles/c\"" "$svc_file"; } && echo 1 || echo 0)"
rmdir "$PHOME/share/profiles/c" 2>/dev/null; rm -rf "$PHOME/.config/share/profiles/c"

echo "--- collisions between profiles are refused, never silent ---"
out=$(psh a add "$pb" 2>&1 1>/dev/null); rc=$?
check "add of another profile's caddy port is refused" "1" "$rc"
check "the refusal names the other profile" "1" "$(grep -c 'another share profile' <<<"$out")"
out=$(psh a add "$((pb + 1))" 2>&1 1>/dev/null); rc=$?
check "add of another profile's metrics port is refused" "1" "$rc"
out=$(psh a add 8787 2>&1 1>/dev/null); rc=$?
check "add of the default's 8787 is refused even before the default is set up" "1" "$rc"
check "the 8787 refusal names the other profile" "1" "$(grep -c 'another share profile' <<<"$out")"
mkdir -p "$PHOME/.config/share/profiles/d"; printf 'hostname=taken.example.test\nport=8999\n' >"$PHOME/.config/share/profiles/d/config"
out=$(psh e setup taken.example.test 2>&1 1>/dev/null); rc=$?
check "setup on another profile's hostname is refused" "1" "$rc"
check "the refusal names the other profile" "1" "$(grep -c 'already the hostname of another profile' <<<"$out")"
check "the refused setup wrote no config" "0" "$([[ -e $PHOME/.config/share/profiles/e ]] && echo 1 || echo 0)"
printf 'hostname=taken.example.test\ntunnel_name=share-taken-example-test\nport=8999\n' >"$PHOME/.config/share/profiles/d/config"
out=$(psh e setup other.example.test --tunnel-name share-taken-example-test 2>&1 1>/dev/null); rc=$?
check "setup on another profile's tunnel name is refused" "1" "$rc"
check "the refusal names the tunnel" "1" "$(grep -c 'share-taken-example-test already belongs to another profile' <<<"$out")"
rm -rf "$PHOME/.config/share/profiles/d"
perm() { stat -f '%Lp' "$@" 2>/dev/null || stat -c '%a' "$@"; }   # macOS, then GNU
check "a profile root's parents under ~/share are 700" "700 700" "$(perm "$PHOME/share" "$PHOME/share/profiles" | tr '\n' ' ' | sed 's/ $//')"
# a's serve on b's live port: the runtime guard, since a hand-edited port= bypasses the setup-time pick
psh a stop >/dev/null
sed -i.bak "s/^port=.*/port=$pb/" "$PHOME/.config/share/profiles/a/config" && rm -f "$PHOME/.config/share/profiles/a/config.bak"
out=$(psh a serve 2>&1 1>/dev/null); rc=$?
check "serve on a port another profile listens on dies" "1" "$rc"
check "the die names the port" "1" "$(grep -c "127.0.0.1:$pb is already in use" <<<"$out")"
check "the recovery hint names this profile's own setup" "1" "$(grep -c 'rerun share --profile a setup' <<<"$out")"
check "b still answers alone on its port" "200" "$(code "http://127.0.0.1:$pb/$pb_id/outside.txt")"
# only the metrics port collides: a's port one below b's, so a's metrics port is b's caddy port
sed -i.bak "s/^port=.*/port=$((pb - 1))/" "$PHOME/.config/share/profiles/a/config" && rm -f "$PHOME/.config/share/profiles/a/config.bak"
out=$(psh a serve 2>&1 1>/dev/null); rc=$?
check "serve whose metrics port another profile listens on dies" "1" "$rc"
check "the die names the metrics port" "1" "$(grep -c "127.0.0.1:$pb (metrics) is already in use" <<<"$out")"
sed -i.bak "s/^port=.*/port=$pa/" "$PHOME/.config/share/profiles/a/config" && rm -f "$PHOME/.config/share/profiles/a/config.bak"
SHARE_FAKE_QUICK_URL=prof-a psh a start >/dev/null 2>&1
check "a serves again on its own port" "1" "$(psh a status | grep -c '^serving')"

echo "--- teardown of one profile leaves the other serving and no empty profile dir ---"
psh a teardown --yes >/dev/null
check "profile a teardown exits 0" "0" "$?"
check "profile a config dir is gone" "0" "$([[ -e $PHOME/.config/share/profiles/a ]] && echo 1 || echo 0)"
check "profile a is no longer listed" "0" "$(psh b profiles | grep -c '^a	')"
check "profile b still serves after a's teardown" "1" "$(psh b status | grep -c '^serving')"
psh b stop >/dev/null
check "profile b stops" "0" "$([[ -f $PHOME/share/profiles/b/serve.pid ]] && echo 1 || echo 0)"

echo "=== TASK-016 hardening ==="

echo "--- cf() bounds a stalled Cloudflare call ---"
mkdir -p "$WORK/fakecurl"
cat >"$WORK/fakecurl/curl" <<'CURLEOF'
#!/bin/bash
mt="" prev=""
for a in "$@"; do
  [[ $prev == --max-time ]] && mt="$a"
  prev="$a"
done
sleep "${mt:-120}"
exit 28
CURLEOF
chmod +x "$WORK/fakecurl/curl"
cf_start=$(date +%s)
(CLOUDFLARE_API_TOKEN=faketoken PATH="$WORK/fakecurl:$PATH" bash "$SH" setup cf.max-time.test >/dev/null 2>&1) &
cf_pid=$!
for _ in $(seq 1 400); do kill -0 "$cf_pid" 2>/dev/null || break; sleep 0.1; done
pkill -f "$WORK/fakecurl/curl" 2>/dev/null
wait "$cf_pid" 2>/dev/null
cf_elapsed=$(( $(date +%s) - cf_start ))
check "cf() with a sleeping curl still returns within 35s" "1" "$([[ $cf_elapsed -le 35 ]] && echo 1 || echo 0)"
rm -rf "$WORK/fakecurl"

echo "--- rand_id loops past a collision ---"
printf 'cccccc\ttaken\t/nonexistent\t2026-01-01\t0\t\n' >>"$SHARE_ROOT/index.tsv"
echo hi >"$WORK/randid.txt"
rid_url=$(SHARE_TEST_IDS="cccccc cccccc dddddd" bash "$SH" add "$WORK/randid.txt" 2>/dev/null | head -1)
check "collision loop skips a taken id twice and lands on the third" "1" "$(grep -cE '/dddddd/' <<<"$rid_url")"
bash "$SH" rm dddddd >/dev/null 2>&1
grep -v '^cccccc' "$SHARE_ROOT/index.tsv" >"$WORK/i" && mv "$WORK/i" "$SHARE_ROOT/index.tsv"

echo "--- add refuses a tab or newline in the basename ---"
mkdir -p "$WORK/badnames"
tab_name=$'tab\tname.txt'
nl_name=$'nl\nname.txt'
: >"$WORK/badnames/$tab_name"
: >"$WORK/badnames/$nl_name"
out=$(bash "$SH" add "$WORK/badnames/$tab_name" 2>&1 1>/dev/null); rc=$?
check "tab name refused" "1" "$rc"
check "tab name message" "1" "$(grep -c 'tabs or newlines' <<<"$out")"
out=$(bash "$SH" add "$WORK/badnames/$nl_name" 2>&1 1>/dev/null); rc=$?
check "newline name refused" "1" "$rc"
check "newline name message" "1" "$(grep -c 'tabs or newlines' <<<"$out")"

echo "--- add refuses a Caddy-unsafe name ({ } \" or \\) ---"
brace_name='{query.p}'
quote_name='a"b'
: >"$WORK/badnames/$brace_name"
: >"$WORK/badnames/$quote_name"
idx_before_unsafe=$(cksum <"$SHARE_ROOT/index.tsv")
caddy_before_unsafe=$(cksum <"$SHARE_ROOT/Caddyfile")
out=$(bash "$SH" add "$WORK/badnames/$brace_name" 2>&1 1>/dev/null); rc=$?
check "brace name refused" "1" "$rc"
check "brace name message" "1" "$(grep -c 'names with' <<<"$out")"
out=$(bash "$SH" add "$WORK/badnames/$quote_name" 2>&1 1>/dev/null); rc=$?
check "quote name refused" "1" "$rc"
check "quote name message" "1" "$(grep -c 'names with' <<<"$out")"
check "unsafe names left the index unchanged" "$idx_before_unsafe" "$(cksum <"$SHARE_ROOT/index.tsv")"
check "unsafe names left the Caddyfile unchanged" "$caddy_before_unsafe" "$(cksum <"$SHARE_ROOT/Caddyfile")"

echo "--- rm refuses an own-host removal it cannot finish; prune does not ---"
mkdir -p "$SHARE_ROOT/pub/c0c0c1" "$SHARE_ROOT/pub/c0c0c2"
echo x >"$SHARE_ROOT/pub/c0c0c1/f.txt"
echo x >"$SHARE_ROOT/pub/c0c0c2/f.txt"
printf 'c0c0c1\tnocred1\t/nonexistent\t2026-01-01\t0\thost=nocred1.example.test\n' >>"$SHARE_ROOT/index.tsv"
printf 'c0c0c2\tnocred2\t/nonexistent\t2026-01-01\t1\thost=nocred2.example.test\n' >>"$SHARE_ROOT/index.tsv"

out=$(env -u CLOUDFLARE_API_TOKEN bash "$SH" rm c0c0c1 2>&1 1>/dev/null); rc=$?
check "rm refuses an own-host removal with no credential" "1" "$rc"
check "refusal names the host" "1" "$(grep -c 'no Cloudflare credential for nocred1.example.test' <<<"$out")"
check "row stays after refused rm" "1" "$(grep -c '^c0c0c1' "$SHARE_ROOT/index.tsv")"
check "payload stays after refused rm" "1" "$([[ -d $SHARE_ROOT/pub/c0c0c1 ]] && echo 1 || echo 0)"

out=$(env -u CLOUDFLARE_API_TOKEN bash "$SH" prune 2>&1 1>/dev/null); rc=$?
check "prune exits 0 despite no credential" "0" "$rc"
check "prune warns DNS stays behind" "1" "$(grep -c 'no Cloudflare credential; DNS and ingress' <<<"$out")"
check "prune still removes the expired row" "0" "$(grep -c '^c0c0c2' "$SHARE_ROOT/index.tsv")"
check "prune still removes the payload" "0" "$([[ -d $SHARE_ROOT/pub/c0c0c2 ]] && echo 1 || echo 0)"

SHARE_HOST_DRY=1 bash "$SH" rm c0c0c1 >/dev/null 2>&1
check "cleanup: nocred1 row gone" "0" "$(grep -c '^c0c0c1' "$SHARE_ROOT/index.tsv")"

echo "=== TASK-005: share state ==="
state_schema_ok() { # state_schema_ok <json-file> <expected-state>: the full field/type contract
  jq -e --arg st "$2" '
    .schema == 1
    and .state == $st
    and (.ready | type) == "boolean"
    and (.mode == "named" or .mode == "quick")
    and (.host == null or (.host | type) == "string")
    and (.hosts | type) == "string"
    and (.serves_here | type) == "boolean"
    and (.service | type) == "boolean"
    and (.shares | type) == "array"
    and (.shares | map(has("id") and has("name") and has("url") and has("kind") and has("expires")) | all)
  ' "$1" >/dev/null
}

echo "--- not_setup: schema valid, exit 0, nothing written ---"
mkdir -p "$WORK/state-ns-root" "$WORK/state-ns-config"
ns_marker="$WORK/state-ns-marker"; touch "$ns_marker"; sleep 1.1
out=$(env -u SHARE_HOSTNAME -u SHARE_HOSTS SHARE_ROOT="$WORK/state-ns-root" SHARE_CONFIG_DIR="$WORK/state-ns-config" SHARE_TUNNEL=0 bash "$SH" state); rc=$?
echo "$out" >"$WORK/state-ns.json"
check "not_setup: exit 0" "0" "$rc"
check "not_setup: schema valid" "0" "$(state_schema_ok "$WORK/state-ns.json" not_setup; echo $?)"
check "not_setup: shares empty" "[]" "$(jq -c .shares "$WORK/state-ns.json")"
check "not_setup: host is null" "null" "$(jq -c .host "$WORK/state-ns.json")"
check "not_setup: ready is false" "false" "$(jq -c .ready "$WORK/state-ns.json")"
check "not_setup: writes nothing" "" "$(find "$WORK/state-ns-root" "$WORK/state-ns-config" -newer "$ns_marker" 2>/dev/null)"

echo "--- stopped: host is always the configured hostname in named mode, ready false ---"
printf 'hostname=stopped.example.test\nhosts=nowhere-host\n' >"$WORK/state-ns-config/config"
touch "$ns_marker"; sleep 1.1
out=$(env -u SHARE_HOSTNAME -u SHARE_HOSTS SHARE_ROOT="$WORK/state-ns-root" SHARE_CONFIG_DIR="$WORK/state-ns-config" SHARE_TUNNEL=0 bash "$SH" state); rc=$?
echo "$out" >"$WORK/state-stopped.json"
check "stopped: exit 0" "0" "$rc"
check "stopped: schema valid" "0" "$(state_schema_ok "$WORK/state-stopped.json" stopped; echo $?)"
check "stopped: host is the configured hostname" "stopped.example.test" "$(jq -r .host "$WORK/state-stopped.json")"
check "stopped: ready is false" "false" "$(jq -c .ready "$WORK/state-stopped.json")"
check "stopped: writes nothing" "" "$(find "$WORK/state-ns-root" "$WORK/state-ns-config" -newer "$ns_marker" 2>/dev/null)"

echo "--- serving (SHARE_TUNNEL=0): snapshot, live, host, expired, 5-field, malformed rows ---"
ST_ROOT="$WORK/state-root"; ST_CFG="$WORK/state-config"
mkdir -p "$ST_ROOT" "$ST_CFG" "$WORK/state-src"
st_env=(SHARE_ROOT="$ST_ROOT" SHARE_CONFIG_DIR="$ST_CFG" SHARE_PORT=18796 SHARE_TUNNEL=0 SHARE_CLIPBOARD=0 SHARE_HOSTNAME=state.example.test SHARE_HOSTS="${h%%.*}")
stsh() { env "${st_env[@]}" bash "$SH" "$@"; }

printf '# Doc\n\nbody\n' >"$WORK/state-src/doc.md"
snap_out=$(stsh add "$WORK/state-src/doc.md" 2>/dev/null)
snap_url=$(head -1 <<<"$snap_out")
snap_id=$(cut -d/ -f4 <<<"$snap_url")
live_out=$(stsh add 28796 2>/dev/null)
live_url=$(head -1 <<<"$live_out")
live_id=$(cut -d/ -f4 <<<"$live_url")
echo x >"$WORK/state-src/hostfile.txt"
env "${st_env[@]}" SHARE_HOST_DRY=1 bash "$SH" add "$WORK/state-src/hostfile.txt" --host state-host.example.test >/dev/null 2>&1
host_id=$(awk -F'\t' '$6 ~ /host=state-host\.example\.test/ {print $1}' "$ST_ROOT/index.tsv")
# captured now, before the synthetic rows below and the marker: `share ls` runs
# cmd_prune, which would otherwise remove the e0e0e1 row and rewrite the index
# and Caddyfile right in the window the "writes nothing" check watches.
ls_out=$(stsh ls)
{
  printf 'e0e0e1\texpired.txt\t/nonexistent\t2020-01-01\t1\t\n'   # expired, not yet pruned
  printf '1e9ac1\tlegacy.txt\t/nonexistent\t2020-01-01\t0\n'      # 5-field, v0.1.x shape
  printf 'bad1\tbadrow\n'                                          # malformed: 2 fields
} >>"$ST_ROOT/index.tsv"

# caddy's reload from the last add flushes its own log lines a moment after the
# reload call returns; wait for caddy.log to go quiet before the marker, so that
# trailing write is never mistaken for one made by `state` itself.
settle=0; prev_sz=-1
for _ in $(seq 1 30); do
  sz=$(wc -c <"$ST_ROOT/caddy.log" 2>/dev/null || echo 0)
  [[ $sz == "$prev_sz" ]] && settle=$((settle + 1)) || settle=0
  [[ $settle -ge 3 ]] && break
  prev_sz=$sz; sleep 0.1
done
st_marker="$WORK/state-marker"; touch "$st_marker"; sleep 1.1
out=$(stsh state); rc=$?
echo "$out" >"$WORK/state-serving.json"

check "serving: exit 0" "0" "$rc"
check "serving: schema valid" "0" "$(state_schema_ok "$WORK/state-serving.json" serving; echo $?)"
check "serving: ready true under SHARE_TUNNEL=0" "true" "$(jq -c .ready "$WORK/state-serving.json")"
check "serving: writes nothing" "" "$(find "$ST_ROOT" "$ST_CFG" -newer "$st_marker" 2>/dev/null)"
check "serving: 5-field legacy row appears" "1" "$(jq '[.shares[] | select(.id == "1e9ac1")] | length' "$WORK/state-serving.json")"
check "serving: expired-not-pruned row appears" "1" "$(jq '[.shares[] | select(.id == "e0e0e1")] | length' "$WORK/state-serving.json")"
check "serving: malformed row counted in skipped" "1" "$(jq '.skipped' "$WORK/state-serving.json")"
check "serving: shares ordered newest-first" "1e9ac1 e0e0e1 $host_id $live_id $snap_id" \
  "$(jq -r '[.shares[].id] | join(" ")' "$WORK/state-serving.json")"

check "snapshot kind" "snapshot" "$(jq -r --arg id "$snap_id" '.shares[] | select(.id==$id) | .kind' "$WORK/state-serving.json")"
check "snapshot own_host null" "null" "$(jq -c --arg id "$snap_id" '.shares[] | select(.id==$id) | .own_host' "$WORK/state-serving.json")"
check "live kind" "live" "$(jq -r --arg id "$live_id" '.shares[] | select(.id==$id) | .kind' "$WORK/state-serving.json")"
check "live own_host null" "null" "$(jq -c --arg id "$live_id" '.shares[] | select(.id==$id) | .own_host' "$WORK/state-serving.json")"
check "own-host row's own_host is the fqdn" "state-host.example.test" \
  "$(jq -r --arg id "$host_id" '.shares[] | select(.id==$id) | .own_host' "$WORK/state-serving.json")"
check "own-host row's kind is snapshot" "snapshot" "$(jq -r --arg id "$host_id" '.shares[] | select(.id==$id) | .kind' "$WORK/state-serving.json")"

for id in "$snap_id" "$live_id" "$host_id"; do
  state_url=$(jq -r --arg id "$id" '.shares[] | select(.id==$id) | .url' "$WORK/state-serving.json")
  ls_url=$(grep -B1 "id=$id" <<<"$ls_out" | head -1)
  check "state url == share ls url for $id" "$ls_url" "$state_url"
done

stsh stop >/dev/null

echo "--- 500-row index answers fast ---"
PERF_ROOT="$WORK/state-perf-root"; PERF_CFG="$WORK/state-perf-config"
mkdir -p "$PERF_ROOT" "$PERF_CFG"
for n in $(seq 1 500); do printf '%06x\tfile%d.txt\t/nonexistent/file%d.txt\t2026-01-01\t0\t\n' "$n" "$n" "$n"; done >"$PERF_ROOT/index.tsv"
TIMEFORMAT='%R'
{ time env SHARE_ROOT="$PERF_ROOT" SHARE_CONFIG_DIR="$PERF_CFG" SHARE_HOSTNAME=perf.example.test SHARE_HOSTS="${h%%.*}" SHARE_TUNNEL=0 \
    bash "$SH" state >"$WORK/state-perf.json"; } 2>"$WORK/state-perf.time"
perf_secs=$(cat "$WORK/state-perf.time")
echo "  share state over 500 rows took ${perf_secs}s"
check "500-row index produces 500 shares" "500" "$(jq '.shares | length' "$WORK/state-perf.json")"
check "500-row index answers under 3s" "1" "$(awk -v t="$perf_secs" 'BEGIN{print (t<3)?1:0}')"

echo "--- state on the v0.5.1 CLI (predates the verb): exit 1, writes nothing ---"
OLD_SH="$WORK/share-v0.5.1"
git -C "$(cd "$(dirname "$SH")/.." && pwd)" show v0.5.1:bin/share >"$OLD_SH" 2>/dev/null
chmod +x "$OLD_SH"
OLD_ROOT="$WORK/state-old-root"; OLD_CFG="$WORK/state-old-config"
mkdir -p "$OLD_ROOT" "$OLD_CFG"
old_marker="$WORK/state-old-marker"; touch "$old_marker"; sleep 1.1
out=$(env SHARE_ROOT="$OLD_ROOT" SHARE_CONFIG_DIR="$OLD_CFG" SHARE_HOSTNAME=old.example.test SHARE_HOSTS="${h%%.*}" SHARE_TUNNEL=0 bash "$OLD_SH" state 2>&1); rc=$?
check "v0.5.1 CLI: git show fetched the old script" "1" "$([[ -s $OLD_SH ]] && echo 1 || echo 0)"
check "v0.5.1 CLI: state exits 1 (unknown verb)" "1" "$rc"
check "v0.5.1 CLI: state wrote nothing" "" "$(find "$OLD_ROOT" "$OLD_CFG" -newer "$old_marker" 2>/dev/null)"

echo "=== TASK-015: docs cover every share state field ==="
# Reuses $WORK/state-serving.json from TASK-005 above: real `share state` output
# from the suite's own isolated root, with a snapshot, a live, and an own-host
# share, so every JSON key name in the contract is present at least once.
doc="$(cd "$(dirname "$SH")/.." && pwd)/docs/how-it-works.md"
state_fields=()
while IFS= read -r f; do state_fields+=("$f"); done < <(jq -r '[paths | map(select(type == "string")) | .[-1]] | unique[]' "$WORK/state-serving.json")
doc_covers_fields() { # doc_covers_fields <file>: 0 iff every name in $state_fields appears in it
  local f
  for f in ${state_fields[@]+"${state_fields[@]}"}; do grep -qF -- "$f" "$1" || return 1; done
  return 0
}
check "share state produced a real field list" "1" "$([[ ${#state_fields[@]} -ge 10 ]] && echo 1 || echo 0)"
check "every share state field name appears in docs/how-it-works.md" "0" "$(doc_covers_fields "$doc"; echo $?)"

echo "--- negative control: a doc missing a field name fails the check ---"
# Works on a throwaway copy; the real docs/how-it-works.md is never written.
sed 's/own_host/XXX/g' "$doc" >"$WORK/how-it-works.missing-field"
check "negative control: doc missing own_host fails the check" "1" "$(doc_covers_fields "$WORK/how-it-works.missing-field"; echo $?)"
check "the real doc (restored by never touching it) still passes" "0" "$(doc_covers_fields "$doc"; echo $?)"

echo "=== skill ==="
check "skill prints a SKILL.md" "1" "$(bash "$SH" skill | grep -c '^name: share')"
check "skill teaches --profile and share profiles" "1" "$(bash "$SH" skill | grep -c -- '--profile <name> <command>.*share profiles')"
SHARE_SKILL_DIR="$WORK/skilldir" bash "$SH" skill --install >/dev/null
check "skill --install writes SKILL.md" "share" "$(sed -n 's/^name: //p' "$WORK/skilldir/SKILL.md")"

echo "=== stop ==="
bash "$SH" stop >/dev/null
check "stop takes links down" 000 "$(code "$md_url")"

echo "=== NEGATIVE CONTROL: a host outside hosts must not serve ==="
SHARE_HOSTS=not-this-host bash "$SH" start >/dev/null 2>&1
check "start refused on another host" 1 "$?"

echo "=== process leaks ==="
# The live-share backend fixture is the last suite-spawned process left; kill it
# now (the EXIT trap would) so the checks below can assert NOTHING is alive.
kill "$fix_pid" 2>/dev/null; wait "$fix_pid" 2>/dev/null

echo "=== stale pidfile, pid reused by another process ==="
sleep 20 & other_pid=$!
echo "$other_pid" >"$SHARE_ROOT/serve.pid"
check "a reused pid is not a running server" "0" "$(bash "$SH" status | grep -c '^serving' || true)"
kill "$other_pid" 2>/dev/null; wait "$other_pid" 2>/dev/null; rm -f "$SHARE_ROOT/serve.pid"
# Every serve path above ends in stop, die, or teardown: after all of them,
# nothing the suite spawned may still be alive. A leaked caddy holds the port
# (SO_REUSEPORT lets the next run bind anyway, so this is the only check that
# sees it); a leaked prune loop leaves a `sleep 3600` its subshell never reaped.
check "no listener on the share port" "0" "$(lsof -nP -iTCP:"$SHARE_PORT" -sTCP:LISTEN 2>/dev/null | grep -c .)"
check "no stray suite processes" "0" "$(pgrep -f "$WORK" | grep -vc $$ || true)"
check "no suite serve still running" "0" "$(pgrep -f "$SH serve" | grep -vc $$ || true)"
check "no cloudflared on the suite ports" "0" "$(pgrep -f "cloudflared.*$SHARE_PORT\|cloudflared.*$((SHARE_PORT + 1))" | grep -c . || true)"
check "no fake tunnel idlers" "0" "$(pgrep -f "sleep 600" | grep -c . || true)"
# only an ORPHANED sleep counts: a live service's prune loop keeps its own
check "no orphaned prune sleeps" "0" "$(ps -eo ppid,command | awk '$1==1 && $2=="sleep" && $3=="3600"' | grep -c . || true)"
check "serve.pid removed" "0" "$([[ -f $SHARE_ROOT/serve.pid ]] && echo 1 || echo 0)"

echo
if [[ $fails -gt 0 ]]; then
  echo "$fails FAILED"
  for log in serve.log caddy.log; do
    echo "--- $log"; tail -20 "$SHARE_ROOT/$log" 2>/dev/null
  done
  exit 1
fi
echo "PASS"
