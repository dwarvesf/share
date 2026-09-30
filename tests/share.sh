#!/bin/bash
# Local self-test for share: every behavior except the Cloudflare tunnel and setup.
# Runs on a spare port with SHARE_TUNNEL=0 and a throwaway config dir, so it
# needs no credentials and never touches a live server. Markdown checks run
# only when pandoc is installed. Ends with the host-guard negative control.
# SHARE_TEST_PORT_BASE overrides the port base (default 18787) so two runs can go at once.
set -uo pipefail

SH="$(cd "$(dirname "$0")/.." && pwd)/bin/share"
WORK=$(mktemp -d)
base=${SHARE_TEST_PORT_BASE:-18787}
export SHARE_ROOT="$WORK/root" SHARE_CONFIG_DIR="$WORK/config" SHARE_PORT=$base
export SHARE_TUNNEL=0 SHARE_CLIPBOARD=0 SHARE_HOSTNAME=s.example.test
# A label no machine has, so an installed share service is never started or stopped by the test.
export SHARE_SERVICE_LABEL="share-selftest-$$"
h="$(uname -n)"; export SHARE_HOSTS="${h%%.*}"
# The suite must never reach the real launchctl or systemctl: a fake HOME does not stop
# `launchctl bootstrap` from loading a plist into the real login session (a profile's job
# once outlived its mktemp HOME, exit 78). Stubs shadow both for the whole run, and the
# guard at the end reads the real job list and fails the run on any share job that appeared.
real_launchctl="$(command -v launchctl || true)"; real_systemctl="$(command -v systemctl || true)"
real_jobs() { # every foundation.d.share* job the real launchd or systemd --user knows
  {
    [[ -n $real_launchctl ]] && "$real_launchctl" list 2>/dev/null | awk '$3 ~ /^foundation\.d\.share/ {print $3}'
    [[ -n $real_systemctl ]] && "$real_systemctl" --user list-units --all --no-legend 'foundation.d.share*' 2>/dev/null | awk '{print $1}'
  } | sort
}
jobs_before="$(real_jobs)"
mkdir -p "$WORK/stubsvc"
# shellcheck disable=SC2016 # literal code for the stub, not this shell's expansion
printf '#!/bin/bash\n[[ $1 == print ]] && exit 1\nexit 0\n' >"$WORK/stubsvc/launchctl"   # print fails, so the unload wait returns at once
printf '#!/bin/bash\nexit 0\n' >"$WORK/stubsvc/systemctl"
chmod +x "$WORK/stubsvc/launchctl" "$WORK/stubsvc/systemctl"
export PATH="$WORK/stubsvc:$PATH"
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
check "forged rows absent from the Caddyfile" "0" "$(grep -c "dd\.example\.test\|19993\|Bad_Host\|^http://$SHARE_HOSTNAME:$SHARE_PORT {" "$SHARE_ROOT/Caddyfile")"
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
  "$(awk '/^http:\/\//{f=1} f && /handle \/healthz/{print NR; exit} f && /^\thandle \{/{exit}' "$SHARE_ROOT/Caddyfile" | grep -c .)"
check "main host block names the hostname and loopback, never any Host" "1" "$(grep -c "^http://$SHARE_HOSTNAME:$SHARE_PORT, http://127.0.0.1:$SHARE_PORT, http://localhost:$SHARE_PORT {" "$SHARE_ROOT/Caddyfile")"
check "a foreign Host gets the 404 catch-all, not the pub tree" 404 "$(hcode "$dir_url" other.example.test)"
check "the hostname itself answers" 200 "$(hcode "$dir_url" "$SHARE_HOSTNAME")"

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
FIX_PORT=$((base + 204))
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
cat >"$SHARE_ROOT/host-fixture.json" <<EOF
{"config":{"ingress":[{"service":"http_status:404"},{"hostname":"s.example.test","service":"http://127.0.0.1:$SHARE_PORT"}]}}
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
# profile c never serves: install writes the file, then the 10s wait for a server dies (exit 1), which is expected here
psh c service install >/dev/null 2>&1
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
perm() { stat -c '%a' "$@" 2>/dev/null || stat -f '%Lp' "$@"; }   # GNU first: on GNU, -f is filesystem status and would succeed
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
check "not_setup: writes nothing" "" "$(find "$WORK/state-ns-root" "$WORK/state-ns-config" -newer "$ns_marker" ! -name '*.log' 2>/dev/null)"

echo "--- stopped: host is always the configured hostname in named mode, ready false ---"
printf 'hostname=stopped.example.test\nhosts=nowhere-host\n' >"$WORK/state-ns-config/config"
touch "$ns_marker"; sleep 1.1
out=$(env -u SHARE_HOSTNAME -u SHARE_HOSTS SHARE_ROOT="$WORK/state-ns-root" SHARE_CONFIG_DIR="$WORK/state-ns-config" SHARE_TUNNEL=0 bash "$SH" state); rc=$?
echo "$out" >"$WORK/state-stopped.json"
check "stopped: exit 0" "0" "$rc"
check "stopped: schema valid" "0" "$(state_schema_ok "$WORK/state-stopped.json" stopped; echo $?)"
check "stopped: host is the configured hostname" "stopped.example.test" "$(jq -r .host "$WORK/state-stopped.json")"
check "stopped: ready is false" "false" "$(jq -c .ready "$WORK/state-stopped.json")"
check "stopped: writes nothing" "" "$(find "$WORK/state-ns-root" "$WORK/state-ns-config" -newer "$ns_marker" ! -name '*.log' 2>/dev/null)"

echo "--- serving (SHARE_TUNNEL=0): snapshot, live, host, expired, 5-field, malformed rows ---"
ST_ROOT="$WORK/state-root"; ST_CFG="$WORK/state-config"
mkdir -p "$ST_ROOT" "$ST_CFG" "$WORK/state-src"
st_env=(SHARE_ROOT="$ST_ROOT" SHARE_CONFIG_DIR="$ST_CFG" SHARE_PORT=$((base + 9)) SHARE_TUNNEL=0 SHARE_CLIPBOARD=0 SHARE_HOSTNAME=state.example.test SHARE_HOSTS="${h%%.*}")
stsh() { env "${st_env[@]}" bash "$SH" "$@"; }

printf '# Doc\n\nbody\n' >"$WORK/state-src/doc.md"
snap_out=$(stsh add "$WORK/state-src/doc.md" 2>/dev/null)
snap_url=$(head -1 <<<"$snap_out")
snap_id=$(cut -d/ -f4 <<<"$snap_url")
live_out=$(stsh add "$((base + 10009))" 2>/dev/null)
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
check "serving: writes nothing" "" "$(find "$ST_ROOT" "$ST_CFG" -newer "$st_marker" ! -name '*.log' 2>/dev/null)"
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
{ time env SHARE_ROOT="$PERF_ROOT" SHARE_CONFIG_DIR="$PERF_CFG" SHARE_HOSTNAME=perf.example.test SHARE_HOSTS="${h%%.*}" SHARE_TUNNEL=0 \
    bash "$SH" state >/dev/null; } 2>>"$WORK/state-perf.time"
perf_secs=$(sort -n "$WORK/state-perf.time" | head -1)   # min of two runs: a busy machine inflates the wall clock, never shrinks it
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

echo "=== access: a login gate per link (SHARE_ACCESS_DRY=1, every Cloudflare call answered from fixtures) ==="
alog="$SHARE_ROOT/access-calls.log"
adry="$SHARE_ROOT/.access-dry"
afix="$SHARE_ROOT/access-probe-fixture"
gfix="$SHARE_ROOT/access-groups-fixture.json"
apending="$SHARE_ROOT/access-pending"
acc() { SHARE_ACCESS_DRY=1 SHARE_ACCESS_POLL="${SHARE_ACCESS_POLL:-0}" CLOUDFLARE_API_TOKEN=faketoken bash "$SH" "$@"; }   # a caller's POLL wins
aline() { grep -n "$1" "$alog" | head -1 | cut -d: -f1; }   # first line number of a log entry
alast() { grep -n "$1" "$alog" | tail -1 | cut -d: -f1; }  # last line number
row_of() { awk -F'\t' -v id="$1" '$1 == id' "$SHARE_ROOT/index.tsv"; }
app_of() { row_of "$1" | sed -n 's/.*access=\([^ ]*\).*/\1/p'; }
areset() { : >"$alog"; rm -rf "$afix" "$gfix"; : >"$apending"; }   # the dry app store stays: it is the account
plant_app() { # plant_app <id> [name]: the dry answer for GET app <uuid of id>, so a hand-seeded line can be deleted
  mkdir -p "$adry"; jq -nc --arg id "00000000-0000-4000-8000-000000$1" --arg n "${2:-share $1 $SHARE_HOSTNAME 00000000}" '{id:$id, name:$n}' >"$adry/00000000-0000-4000-8000-000000$1.json"
}
bash "$SH" start >/dev/null 2>&1   # the main server, SHARE_TUNNEL=0, in case an earlier section left it down
echo asset >"$WORK/gated.txt"

echo "--- row 1: the three rule forms, normalized into the row and the policy include ---"
areset
e_url=$(acc add "$WORK/gated.txt" --access email:A@X.io,b@y.io 2>"$WORK/acc.err" | head -1); e_id=$(cut -d/ -f4 <<<"$e_url")
check "email: add prints a link" "1" "$(grep -cE "^https://$SHARE_HOSTNAME/[0-9a-f]{6}/gated\.txt$" <<<"$e_url")"
check "email: row carries the lowercased rule" "1" "$(row_of "$e_id" | grep -c 'access_rule=email:a@x.io,b@y.io')"
check "email: row carries the app uuid" "1" "$(row_of "$e_id" | grep -cE "access=00000000-0000-4000-8000-000000$e_id")"
check "email: include is one email object per address" '[{"email":{"email":"a@x.io"}},{"email":{"email":"b@y.io"}}]' "$(jq -c '.policies[0].include' "$adry/$(app_of "$e_id").json")"
check "email: destinations are <host>/<id> and <host>/<id>/*" "$SHARE_HOSTNAME/$e_id $SHARE_HOSTNAME/$e_id/*" "$(jq -r '[.destinations[].uri] | join(" ")' "$adry/$(app_of "$e_id").json")"
check "email: app name is 'share <id> <host> <nonce>'" "1" "$(jq -r .name "$adry/$(app_of "$e_id").json" | grep -cE "^share $e_id $SHARE_HOSTNAME [0-9a-f]{8}$")"
check "email: the preflight ran first (zones, orgs, the {} probe before POST app)" "1" "$([[ $(aline 'GET zones') -lt $(aline 'POST app$') && $(aline 'POST app {}') -lt $(aline 'POST app$') ]] && echo 1 || echo 0)"
check "email: the gated file answers locally" "200" "$(wait_code 200 "$e_url")"
check "email: ls shows access= after expires=" "1" "$(acc ls 2>/dev/null | grep -c "id=$e_id .*expires=[^ ]*  access=email:a@x.io,b@y.io")"
d_url=$(acc add "$WORK/gated.txt" --access domain:D.Foundation 2>"$WORK/acc.err" | head -1); d_id=$(cut -d/ -f4 <<<"$d_url")
check "domain: row carries the lowercased rule" "1" "$(row_of "$d_id" | grep -c 'access_rule=domain:d.foundation')"
check "domain: include is email_domain" '[{"email_domain":{"domain":"d.foundation"}}]' "$(jq -c '.policies[0].include' "$adry/$(app_of "$d_id").json")"
check "domain: warns that it admits everyone at the domain" "1" "$(grep -c 'admits every address at d.foundation, contractors included' "$WORK/acc.err")"
jq -nc '[{id:"11111111-2222-4333-8444-555555555555", name:"dwarves-ops"}, {id:"aaaaaaaa-2222-4333-8444-555555555555", name:"other"}]' >"$gfix"
g_url=$(acc add "$WORK/gated.txt" --access group:dwarves-ops 2>"$WORK/acc.err" | head -1); g_id=$(cut -d/ -f4 <<<"$g_url")
check "group: row carries the rule" "1" "$(row_of "$g_id" | grep -c 'access_rule=group:dwarves-ops')"
check "group: include is the group id from the lookup" '[{"group":{"id":"11111111-2222-4333-8444-555555555555"}}]' "$(jq -c '.policies[0].include' "$adry/$(app_of "$g_id").json")"
check "row 14: state carries the rule per share and access_pending" "email:a@x.io,b@y.io|null|0" "$(acc state | jq -r --arg e "$e_id" --arg m "$md_id" '[(.shares[] | select(.id == $e) | .access), (.shares[] | select(.id == $m) | .access), .access_pending] | map(tostring) | join("|")')"
check "row 14: schema stays 1" "1" "$(acc state | jq .schema)"

echo "--- row 2: a bad rule is refused before any write ---"
areset
idx_before=$(cksum <"$SHARE_ROOT/index.tsv")
many=$(for i in $(seq 1 51); do printf 'u%s@x.io,' "$i"; done); many="${many%,}"
for bad in bad 'group:' 'email:nope' 'domain:-x' "email:$many" 'group:a b' 'email:a@x' 'nope:x' $'email:a@x.io\nb@y.io'; do
  out=$(acc add "$WORK/gated.txt" --access "$bad" 2>&1 1>/dev/null); rc=$?
  check "--access '${bad:0:24}' exits 1 with the usage line" "1" "$([[ $rc == 1 ]] && grep -c 'usage: --access group:<name> | email:<a>\[,<b>...\] | domain:<domain>' <<<"$out")"
done
check "row 2: no row was written" "$idx_before" "$(cksum <"$SHARE_ROOT/index.tsv")"
check "row 2: no POST app was logged" "0" "$(grep -c 'POST app' "$alog")"

echo "--- row 3: quick mode and the seam with the tunnel on are refused ---"
printf 'mode=quick\n' >"$SHARE_CONFIG_DIR/config"
out=$(acc add "$WORK/gated.txt" --access email:a@x.io 2>&1 1>/dev/null); rc=$?
check "quick mode refuses --access" "1" "$([[ $rc == 1 ]] && grep -c "needs a named tunnel on a Cloudflare account with Access: 'share teardown', then 'share setup <hostname>'" <<<"$out")"
out=$(SHARE_ACCESS_DRY=1 SHARE_TUNNEL=1 CLOUDFLARE_API_TOKEN=faketoken bash "$SH" api-token --check 2>&1 1>/dev/null); rc=$?
check "api-token refuses quick mode too" "1" "$([[ $rc == 1 ]] && grep -c 'needs a named tunnel' <<<"$out")"
rm -f "$SHARE_CONFIG_DIR/config"
out=$(SHARE_ACCESS_DRY=1 SHARE_TUNNEL=1 CLOUDFLARE_API_TOKEN=faketoken bash "$SH" add "$WORK/gated.txt" --access email:a@x.io 2>&1 1>/dev/null); rc=$?
check "the dry seam dies with the tunnel on" "1" "$([[ $rc == 1 ]] && grep -c 'SHARE_ACCESS_DRY=1 is a test seam for SHARE_TUNNEL=0 only' <<<"$out")"
check "row 3: nothing logged, no row" "$idx_before" "$([[ ! -s $alog ]] && cksum <"$SHARE_ROOT/index.tsv")"

echo "--- rows 4 and 27: no token source prints the guided block and leaves no stage ---"
mkdir -p "$WORK/fakesec"
cat >"$WORK/fakesec/security" <<'EOF'
#!/bin/bash
# records the verb and the -s service name it was asked for, never the -w value; find answers nothing unless SEC_ITEM is set
log="${SEC_LOG:?}"
if [[ $1 == -i ]]; then
  while IFS= read -r line; do svc="${line#*-s \"}"; echo "${line%% *} ${svc%%\"*}" >>"$log"; done
  exit 0
fi
prev=""; for a in "$@"; do [[ $prev == -s ]] && echo "$1 $a" >>"$log"; prev="$a"; done
[[ $1 == find-generic-password ]] && { [[ -n ${SEC_ITEM:-} ]] && echo "$SEC_ITEM"; exit 0; }
exit 0
EOF
chmod +x "$WORK/fakesec/security"
: >"$WORK/sec.log"
out=$(env -u CLOUDFLARE_API_TOKEN SEC_LOG="$WORK/sec.log" PATH="$WORK/fakesec:$PATH" bash "$SH" add "$WORK/gated.txt" --access group:dwarves-ops 2>&1 1>/dev/null); rc=$?
check "no token: exit 1" "1" "$rc"
check "no token: the block names the host and the two api-token forms" "3" "$(grep -c -e "needs a Cloudflare API token for $SHARE_HOSTNAME; none is set" -e '^  New token (opens the prefilled form, then paste):  share api-token$' -e '^  Already have a token with Access scopes:          share api-token --cmd '"'"'op read "op://<vault>/<item>/credential"'"'"'$' <<<"$out")"
o1_url=$(grep -o 'https://dash.cloudflare.com/[^ ]*' <<<"$out")
check "no token: the template URL is the account-token form" "1" "$(grep -c '^https://dash.cloudflare.com/?to=/:account/api-tokens&permissionGroupKeys=' <<<"$o1_url")"
urldec() { local s="${1//+/ }"; printf '%b' "${s//%/\\x}"; }
keys=$(sed -n 's/.*permissionGroupKeys=\([^&]*\).*/\1/p' <<<"$o1_url")
check "no token: the keys decode to exactly the three key/type pairs" '[{"key":"access","type":"edit"},{"key":"access_acct","type":"read"},{"key":"zone","type":"read"}]' "$(urldec "$keys" | jq -c .)"
check "no token: name decodes to 'share access (default)'" "share access (default)" "$(urldec "$(sed -n 's/.*&name=\([^&]*\).*/\1/p' <<<"$o1_url")")"
check "no token: no stage left under the root" "0" "$(find "$SHARE_ROOT" -maxdepth 1 -name '.stage.*' | grep -c .)"
check "no token: no row, no call" "$idx_before" "$([[ ! -s $alog ]] && cksum <"$SHARE_ROOT/index.tsv")"
check "no token: the profile form names --profile" "2" "$(env -u CLOUDFLARE_API_TOKEN SEC_LOG="$WORK/sec.log" PATH="$WORK/fakesec:$PATH" SHARE_PROFILE=dfoundation SHARE_HOSTNAME=s.d.foundation bash "$SH" add "$WORK/gated.txt" --access email:a@x.io 2>&1 1>/dev/null | grep -c 'share --profile dfoundation api-token')"

echo "--- row 5: group lookup by exact name over every page ---"
areset
jq -nc '[{id:"aaaaaaaa-2222-4333-8444-555555555555", name:"other"}]' >"$gfix"
out=$(acc add "$WORK/gated.txt" --access group:dwarves-ops 2>&1 1>/dev/null); rc=$?
check "missing group: exit 1 with the rule-group path" "1" "$([[ $rc == 1 ]] && grep -c "no Access group named 'dwarves-ops' on the account that owns example.test" <<<"$out")"
check "missing group: the block names where to create it and to rerun" "3" "$(grep -c -e 'Zero Trust > Access controls > Policies > Rule groups tab > Add a group' -e '^    Name: dwarves-ops$' -e 'then rerun the same share add' <<<"$out")"
check "missing group: no POST app" "0" "$(grep -c 'POST app$' "$alog")"
jq -nc '[{id:"a", name:"dwarves-ops"}, {id:"b", name:"dwarves-ops"}]' >"$gfix"
out=$(acc add "$WORK/gated.txt" --access group:dwarves-ops 2>&1 1>/dev/null); rc=$?
check "two groups of one name: refused by name" "1" "$([[ $rc == 1 ]] && grep -c "two Access groups are named 'dwarves-ops'; rename one" <<<"$out")"
check "two groups: no POST app" "0" "$(grep -c 'POST app$' "$alog")"
jq -nc '[range(0; 120) | {id: ("g" + tostring), name: ("group" + tostring)}] + [{id:"cccccccc-2222-4333-8444-555555555555", name:"dwarves-ops"}]' >"$gfix"
: >"$alog"
p_url=$(acc add "$WORK/gated.txt" --access group:dwarves-ops 2>/dev/null | head -1); p_id=$(cut -d/ -f4 <<<"$p_url")
check "paged group: found on page 2, two GET groups logged" "2" "$(grep -c 'GET groups' "$alog")"
check "paged group: include carries its id" '[{"group":{"id":"cccccccc-2222-4333-8444-555555555555"}}]' "$(jq -c '.policies[0].include' "$adry/$(app_of "$p_id").json")"

echo "--- rows 6 and 7: the bytes go public only after the gate is observed ---"
areset
printf 'fail\nfail\npass\npass\npass\n' >"$afix"
pub_before="$(find "$SHARE_ROOT/pub" -maxdepth 1 | sort)"
watch_bad="$WORK/watch.bad"; rm -f "$watch_bad"
( while ! grep -q PUBLISH "$alog" 2>/dev/null; do
    if grep -q 'PROBE fail' "$alog" 2>/dev/null && [[ "$(find "$SHARE_ROOT/pub" -maxdepth 1 | sort)" != "$pub_before" ]]; then echo bad >"$watch_bad"; fi
    sleep 0.05
  done ) & watch_pid=$!
o6_url=$(SHARE_ACCESS_POLL=1 acc add "$WORK/gated.txt" --access email:a@x.io 2>/dev/null | head -1); o6_id=$(cut -d/ -f4 <<<"$o6_url")
kill "$watch_pid" 2>/dev/null; wait "$watch_pid" 2>/dev/null
check "row 6: POST app < every PROBE < PUBLISH" "1" "$([[ $(aline 'POST app$') -lt $(aline 'PROBE') && $(alast 'PROBE') -lt $(aline 'PUBLISH') ]] && echo 1 || echo 0)"
check "row 6: five probe rounds (2 fail, 3 pass)" "fail fail pass pass pass" "$(sed -n 's/^PROBE //p' "$alog" | tr '\n' ' ' | sed 's/ $//')"
check "row 6: pub/<id> absent while a PROBE fail was logged" "0" "$([[ -e $watch_bad ]] && echo 1 || echo 0)"
check "row 6: the gated file answers after the gate" "200" "$(wait_code 200 "$o6_url")"
areset
printf 'fail\nfail\npass\n' >"$afix"
rows_before="$(cut -f1 "$SHARE_ROOT/index.tsv" | sort)"
rm -f "$watch_bad"
( while ! grep -q PUBLISH "$alog" 2>/dev/null && ! grep -q 'PROBE pass' "$alog" 2>/dev/null; do
    if grep -q 'PROBE fail' "$alog" 2>/dev/null && [[ "$(cut -f1 "$SHARE_ROOT/index.tsv" | sort)" != "$rows_before" ]]; then echo bad >"$watch_bad"; fi
    sleep 0.05
  done ) & watch_pid=$!
l6_url=$(SHARE_ACCESS_POLL=1 acc add "$FIX_PORT" --access email:a@x.io 2>/dev/null | head -1); l6_id=$(cut -d/ -f4 <<<"$l6_url")
kill "$watch_pid" 2>/dev/null; wait "$watch_pid" 2>/dev/null
check "row 7: no row while a PROBE fail was logged" "0" "$([[ -e $watch_bad ]] && echo 1 || echo 0)"
check "row 7: the live row and its handle_path land after the last PROBE pass" "1" "$([[ -n $(row_of "$l6_id") && $(alast 'PROBE pass') -lt $(alast 'RELOAD') ]] && grep -c "handle_path /$l6_id/\*" "$SHARE_ROOT/Caddyfile")"
check "row 7: the live gated share proxies" "hello fixture" "$(wait_code 200 "${l6_url}hello.txt" >/dev/null; curl -s "$(local_url "${l6_url}hello.txt")")"

echo "--- row 8: a gate that never passes publishes nothing and deletes the app ---"
areset
printf 'fail\n' >"$afix"
idx_before=$(cksum <"$SHARE_ROOT/index.tsv")
out=$(SHARE_ACCESS_WAIT=2 SHARE_ACCESS_POLL=1 acc add "$WORK/gated.txt" --access email:a@x.io 2>&1 1>/dev/null); rc=$?
check "timeout: exit 1 naming the wait and the rerun" "1" "$([[ $rc == 1 ]] && grep -c "did not enforce on $SHARE_HOSTNAME/[0-9a-f]* within 2s; nothing was published; rerun the same share add (Access can take several minutes on a new app)" <<<"$out")"
check "timeout: the gate said up front how long and that Ctrl-C is safe" "1" "$(grep -c 'waiting up to 2s for Cloudflare Access to enforce on .* Ctrl-C is safe: nothing is published' <<<"$out")"
check "timeout: DELETE app logged, no PUBLISH" "1" "$([[ $(grep -c 'DELETE app' "$alog") == 1 && $(grep -c PUBLISH "$alog") == 0 ]] && echo 1 || echo 0)"
check "timeout: no row" "$idx_before" "$(cksum <"$SHARE_ROOT/index.tsv")"
t8_id=$(sed -n 's/^DELETE app 00000000-0000-4000-8000-000000//p' "$alog")
check "timeout: no pub/<id>, no stage, pending empty" "1" "$([[ ! -e $SHARE_ROOT/pub/$t8_id && -z $(find "$SHARE_ROOT" -maxdepth 1 -name '.stage.*') && ! -s $apending ]] && echo 1 || echo 0)"

echo "--- row 9: rm removes the bytes and the row, then the app ---"
areset
acc rm "$e_id" >/dev/null 2>"$WORK/acc.err"; rc=$?
check "rm gated: exit 0" "0" "$rc"
check "rm gated: RELOAD precedes DELETE app" "1" "$([[ $(aline RELOAD) -lt $(aline 'DELETE app') ]] && echo 1 || echo 0)"
check "rm gated: the link 404s" "404" "$(wait_code 404 "$e_url")"
check "rm gated: access-pending empty after" "0" "$(awk 'NF' "$apending" | wc -l | tr -d ' ')"
out=$(env -u CLOUDFLARE_API_TOKEN SEC_LOG="$WORK/sec.log" PATH="$WORK/fakesec:$PATH" bash "$SH" rm "$d_id" 2>&1 1>/dev/null); rc=$?
check "rm gated without a token: refused with the guided block, row intact" "1" "$([[ $rc == 1 && -n $(row_of "$d_id") ]] && grep -c 'needs a Cloudflare API token' <<<"$out")"

echo "--- rows 10 and 11: expiry without a token defers the app; prune with the token sweeps it ---"
areset
d_app=$(app_of "$d_id")
awk -F'\t' -v OFS='\t' -v id="$d_id" '$1 == id {$5 = 1} {print}' "$SHARE_ROOT/index.tsv" >"$WORK/i" && mv "$WORK/i" "$SHARE_ROOT/index.tsv"
out=$(env -u CLOUDFLARE_API_TOKEN SHARE_ACCESS_DRY=1 bash "$SH" prune 2>&1 1>/dev/null); rc=$?
check "prune without a token: exit 0, names the deferred app" "1" "$([[ $rc == 0 ]] && grep -c "Access app for $d_id awaits deletion; run 'share prune' with a token (the stored one, or CLOUDFLARE_API_TOKEN)" <<<"$out")"
check "prune without a token: row and bytes gone" "1" "$([[ -z $(row_of "$d_id") && ! -e $SHARE_ROOT/pub/$d_id ]] && echo 1 || echo 0)"
check "prune without a token: the app waits in access-pending" "1" "$(grep -c "^$d_id	$d_app	" "$apending")"
check "prune without a token: no DELETE" "0" "$(grep -c 'DELETE app' "$alog")"
check "status prints the pending count" "1" "$(env -u CLOUDFLARE_API_TOKEN bash "$SH" status 2>&1 >/dev/null | grep -c "1 Access app(s) await deletion; run 'share prune' with a token (the stored one, or CLOUDFLARE_API_TOKEN)")"
check "state counts it" "1" "$(bash "$SH" state | jq .access_pending)"
check "ls with a token for another account warns and skips, exit 0" "1" "$(SHARE_ACCESS_DRY=1 SHARE_ACCESS_DRY_ZONES=0 CLOUDFLARE_API_TOKEN=faketoken bash "$SH" ls >/dev/null 2>&1; echo "rc=$?" | grep -c 'rc=0')"
check "ls with a token for another account names the skip" "1" "$(SHARE_ACCESS_DRY=1 SHARE_ACCESS_DRY_ZONES=0 CLOUDFLARE_API_TOKEN=faketoken bash "$SH" ls 2>&1 >/dev/null | grep -c 'skipping the Access check')"
acc prune >/dev/null 2>&1
check "row 11: prune with the token deletes that app" "1" "$(grep -c "^DELETE app $d_app$" "$alog")"
check "ls with an unproven read never calls a link PUBLIC" "0" "$(SHARE_ACCESS_DRY=1 SHARE_ACCESS_DRY_ORGS=deny CLOUDFLARE_API_TOKEN=faketoken bash "$SH" ls 2>&1 >/dev/null | grep -c 'PUBLIC')"
: >"$alog"; printf 'c4c4c4\t00000000-0000-4000-8000-000000c4c4c4\t0\t-\t%s\n' "$(date +%s)" >"$apending"   # no dry app: a 404
SHARE_ACCESS_DRY_ORGS=deny acc prune >/dev/null 2>&1
check "a 404 with an unproven Access read is not 'done': the line stays" "1" "$(grep -c '^c4c4c4' "$apending")"
acc prune >/dev/null 2>&1
check "the same 404 once the read is proven drops the line" "0" "$(grep -c '^c4c4c4' "$apending")"
check "row 11: access-pending empty" "0" "$(awk 'NF' "$apending" | wc -l | tr -d ' ')"
areset
mkdir -p "$SHARE_ROOT/pub/b1b1b1" && echo x >"$SHARE_ROOT/pub/b1b1b1/f.txt"
plant_app b1b1b1
sh -c 'exit 0' & dead=$!; wait "$dead"
printf 'b1b1b1\t00000000-0000-4000-8000-000000b1b1b1\t%s\tMon Jan  1 00:00:00 2001\t%s\n' "$dead" "$(date +%s)" >"$apending"
acc prune >/dev/null 2>&1
check "row 11b: orphaned bytes are trashed before the app is deleted" "1" "$([[ $(aline 'TRASH b1b1b1') -lt $(aline 'DELETE app') && ! -e $SHARE_ROOT/pub/b1b1b1 ]] && echo 1 || echo 0)"
check "row 11b: the line is gone" "0" "$(awk 'NF' "$apending" | wc -l | tr -d ' ')"
areset
plant_app f0f0f0 "chat-staff"
printf 'f0f0f0\t00000000-0000-4000-8000-000000f0f0f0\t%s\tMon Jan  1 00:00:00 2001\t%s\n' "$dead" "$(date +%s)" >"$apending"
printf '..\t00000000-0000-4000-8000-000000f0f0f1\t0\t-\t%s\n' "$(date +%s)" >>"$apending"
printf 'f0f0f2\tnot-a-uuid\t0\t-\t%s\n' "$(date +%s)" >>"$apending"
out=$(acc prune 2>&1 1>/dev/null)
check "a pending line whose app is not this share's is never deleted" "1" "$([[ $(grep -c 'DELETE app' "$alog") == 0 ]] && grep -c "Access app 00000000-0000-4000-8000-000000f0f0f0 is not the app of share f0f0f0 (its name is 'chat-staff'); left alone" <<<"$out")"
check "malformed pending lines are kept and never acted on" "3" "$(awk 'NF' "$apending" | wc -l | tr -d ' ')"
check "ls counts the malformed lines apart and names them as the user's to remove" "1" "$(bash "$SH" ls 2>&1 >/dev/null | grep -c "2 malformed line(s) in $apending; a sweep never acts on them; remove them by hand")"
check "state counts every line" "3" "$(bash "$SH" state | jq .access_pending)"
check "the share root survived a '..' id" "1" "$([[ -d $SHARE_ROOT/pub && -f $SHARE_ROOT/index.tsv ]] && echo 1 || echo 0)"
: >"$apending"

echo "--- row 13: a forged access= or access_rule= row never reaches a reader ---"
{
  printf 'f1f1f1\tforged-app\t/x\t2026-01-01\t0\taccess=../x access_rule=email:a@x.io\n'
  printf 'f1f1f2\tforged-rule\t/x\t2026-01-01\t0\taccess=00000000-0000-4000-8000-000000f1f1f2 access_rule=group:a/b\n'
  printf 'f1f1f3\tforged-half\t/x\t2026-01-01\t0\taccess=00000000-0000-4000-8000-000000f1f1f3\n'
} >>"$SHARE_ROOT/index.tsv"
check "forged gated rows absent from ls" "0" "$(bash "$SH" ls | grep -c 'forged-')"
check "forged gated rows counted in skipped" "3" "$(bash "$SH" state | jq .skipped)"
grep -v $'\tforged-' "$SHARE_ROOT/index.tsv" >"$WORK/i" && mv "$WORK/i" "$SHARE_ROOT/index.tsv"

echo "--- row 22: Caddy answers 400 to an encoded separator on the main host ---"
rawcode() { curl -s -o /dev/null -w '%{http_code}' --path-as-is "http://127.0.0.1:$SHARE_PORT$1"; }
for p in "/x/..%2F$g_id/gated.txt" "/%2f$g_id/gated.txt" "/x/..%5C$g_id/gated.txt" "/x/%2e%2e/$g_id/gated.txt" "/x/..%2F$l6_id/"; do
  check "encoded path $p answers 400" "400" "$(rawcode "$p")"
done
check "the plain link still answers" "200" "$(rawcode "/$g_id/gated.txt")"
echo pct >"$WORK/50%.v1.txt"
pct_url=$(bash "$SH" add "$WORK/50%.v1.txt" 2>/dev/null | head -1)
check "a %25 in a file name is not an encoded separator" "200" "$(wait_code 200 "$pct_url")"
check "a %2F in the query string passes" "200" "$(rawcode "/$g_id/gated.txt?next=%2Fhome")"
check "the @encsep route precedes file_server in the adapted config" "1" "$(caddy adapt --config "$SHARE_ROOT/Caddyfile" --adapter caddyfile 2>/dev/null | jq -r '[.apps.http.servers[] | select(.listen[0] | endswith(":'"$SHARE_PORT"'")) | .routes[] | select(.match[0].host? // [] | index("'"$SHARE_HOSTNAME"'")) | .. | objects | select(has("handle")) | if ((.match[0].expression.expr? // "") | test("%2f")) then "encsep" elif any(.handle[]; .handler == "file_server") then "file_server" else empty end] | join(" ")' | grep -c '^encsep .*file_server')"

echo "--- rows 23, 23b, 23c, 23d: a lost POST is found by its nonce, only after Access read is proven ---"
areset
out=$(SHARE_ACCESS_DRY_POST=lost acc add "$WORK/gated.txt" --access email:a@x.io 2>&1 1>/dev/null); rc=$?
check "lost POST: the add dies naming the rerun" "1" "$([[ $rc == 1 ]] && grep -c 'did not answer the Access app create.*rerun the same share add' <<<"$out")"
nonce=$(awk -F'\t' '{print $2}' "$apending" | sed -n 's/^-://p')
check "lost POST: the pending line is -:<nonce>" "1" "$(grep -cE "^[0-9a-f]{6}	-:[0-9a-f]{8}	" "$apending")"
check "lost POST: the logged body's name ends in that nonce" "1" "$(sed -n 's/^POST app (lost) //p' "$alog" | jq -r .name | grep -c " $nonce\$")"
check "lost POST: no PUBLISH, no row" "0" "$(grep -c PUBLISH "$alog")"
awk -F'\t' -v OFS='\t' '{$5 = $5 - 660} {print}' "$apending" >"$WORK/p" && mv "$WORK/p" "$apending"   # forged 11 minutes old
: >"$alog"
SHARE_ACCESS_DRY_ORGS=deny acc prune >/dev/null 2>&1
check "row 23b: an unproven sweep looks up nothing and deletes nothing" "0" "$(grep -c 'GET apps\|DELETE app' "$alog")"
check "row 23b: the -:<nonce> line stays" "1" "$(grep -c "^[0-9a-f]*	-:$nonce	" "$apending")"
: >"$alog"
acc prune >/dev/null 2>&1
check "row 23: a proven sweep logs GET orgs, then the name lookup, then DELETE app" "1" "$([[ $(aline 'GET orgs') -lt $(aline 'GET apps') && $(aline 'GET apps') -lt $(aline 'DELETE app') ]] && echo 1 || echo 0)"
check "row 23: the file is empty after" "0" "$(awk 'NF' "$apending" | wc -l | tr -d ' ')"
: >"$alog"; rm -rf "$adry"
printf 'c3c3c3\t-:0badc0de\t%s\tMon Jan  1 00:00:00 2001\t%s\n' "$dead" "$(( $(date +%s) - 60 ))" >"$apending"
acc prune >/dev/null 2>&1
check "row 23d: a young no-match line is kept, nothing deleted" "1" "$([[ $(grep -c 'DELETE' "$alog") == 0 ]] && grep -c '^c3c3c3	-:0badc0de	' "$apending")"
: >"$apending"
areset
printf 'fail\nfail\nfail\nfail\npass\n' >"$afix"
rows23=$(grep -c . "$SHARE_ROOT/index.tsv")
SHARE_ACCESS_POLL=1 acc add "$WORK/gated.txt" --access email:a@x.io >"$WORK/c23.out" 2>"$WORK/c23.err" & add23=$!
for _ in $(seq 1 50); do grep -q 'PROBE fail' "$alog" 2>/dev/null && break; sleep 0.1; done
awk -F'\t' -v OFS='\t' -v d="$dead" '{$3 = d} {print}' "$apending" >"$WORK/p" && mv "$WORK/p" "$apending"   # the owner forged dead
SHARE_ACCESS_DRY_DELETE=lost acc prune >/dev/null 2>&1
wait "$add23"; rc=$?
check "row 23c: the prune claimed the line (a lost DELETE keeps it)" "1" "$(grep -c 'DELETE app .* (lost)' "$alog")"
check "row 23c: the add finds its line gone, publishes nothing, dies" "1" "$([[ $rc == 1 && $(grep -c PUBLISH "$alog") == 0 ]] && grep -c 'claimed by a sweep during the wait; nothing was published' "$WORK/c23.err")"
check "row 23c: no row for it" "$rows23" "$(grep -c . "$SHARE_ROOT/index.tsv")"
check "row 23c: no stage left" "0" "$(find "$SHARE_ROOT" -maxdepth 1 -name '.stage.*' | grep -c .)"
: >"$apending"

echo "--- rows 24, 25, 25b: pending ids are skipped, a live owner is never swept, a reused pid is dead ---"
areset
plant_app abc123
printf 'abc123\t00000000-0000-4000-8000-000000abc123\t%s\tMon Jan  1 00:00:00 2001\t%s\n' "$dead" "$(date +%s)" >"$apending"
r24_url=$(SHARE_TEST_IDS="abc123 abc124" bash "$SH" add "$WORK/gated.txt" 2>/dev/null | head -1)
check "row 24: a pending id is never handed out" "1" "$(grep -c '/abc124/' <<<"$r24_url")"
bash "$SH" rm abc124 >/dev/null; : >"$apending"
areset
printf 'fail\nfail\npass\n' >"$afix"
SHARE_ACCESS_POLL=1 acc add "$WORK/gated.txt" --access email:a@x.io >"$WORK/c25.out" 2>/dev/null & add25=$!
for _ in $(seq 1 50); do grep -q 'PROBE fail' "$alog" 2>/dev/null && break; sleep 0.1; done
acc prune >/dev/null 2>&1
wait "$add25"; rc=$?
check "row 25: the prune skipped the live owner's line (no DELETE)" "0" "$(grep -c 'DELETE app' "$alog")"
check "row 25: the add then published" "1" "$([[ $rc == 0 ]] && grep -c PUBLISH "$alog")"
acc rm "$(cut -d/ -f4 <"$WORK/c25.out")" >/dev/null 2>&1
areset
serve_pid="$(cat "$SHARE_ROOT/serve.pid")"
plant_app d5d5d5
printf 'd5d5d5\t00000000-0000-4000-8000-000000d5d5d5\t%s\tMon Jan  1 00:00:00 2001\t%s\n' "$serve_pid" "$(date +%s)" >"$apending"
acc prune >/dev/null 2>&1
check "row 25b: serve's pid with another start time is a dead owner" "1" "$(grep -c '^DELETE app 00000000-0000-4000-8000-000000d5d5d5$' "$alog")"
: >"$apending"

echo "--- serve never sweeps: a pending line survives a start with the token in the environment ---"
areset
plant_app e6e6e6
printf 'e6e6e6\t00000000-0000-4000-8000-000000e6e6e6\t%s\tMon Jan  1 00:00:00 2001\t%s\n' "$dead" "$(date +%s)" >"$apending"
bash "$SH" stop >/dev/null
SHARE_LIVE_CHECK=0 acc start >/dev/null 2>&1
check "serve's startup prune makes no Access call" "0" "$(grep -c 'GET orgs\|DELETE app' "$alog")"
check "the line is still there" "1" "$(grep -c '^e6e6e6' "$apending")"
: >"$apending"; areset
x_url=$(acc add "$WORK/gated.txt" --access email:a@x.io 2>/dev/null | head -1); x_id=$(cut -d/ -f4 <<<"$x_url"); x_app=$(app_of "$x_id")
awk -F'\t' -v OFS='\t' -v id="$x_id" '$1 == id {$5 = 1} {print}' "$SHARE_ROOT/index.tsv" >"$WORK/i" && mv "$WORK/i" "$SHARE_ROOT/index.tsv"
bash "$SH" stop >/dev/null; : >"$alog"
SHARE_LIVE_CHECK=0 acc start >/dev/null 2>&1   # serve's startup prune expires it with no token
check "serve's own expiry defers the app with no live owner" "1" "$(grep -c "^$x_id	$x_app	0	-	" "$apending")"
acc prune >/dev/null 2>&1
check "the next interactive prune deletes it" "1" "$(grep -c "^DELETE app $x_app$" "$alog")"
: >"$apending"

echo "--- rows 28, 29: share api-token stores, then the read-only preflight names each scope ---"
areset
rm -f "$SHARE_CONFIG_DIR/config"
out=$(acc api-token --cmd 'printf faketoken' 2>&1 1>/dev/null); rc=$?
check "--cmd: exit 0, config has one api_token_cmd line" "1" "$([[ $rc == 0 ]] && grep -c '^api_token_cmd=printf faketoken$' "$SHARE_CONFIG_DIR/config")"
check "--cmd: the preflight names the source and every scope ok" "4" "$(grep -c -e '^  ok       token found (api_token_cmd)$' -e '^  ok       Zone: Read' -e '^  ok       Access: Organizations, Identity Providers, and Groups Read' -e '^  ok       Access: Apps and Policies Edit' <<<"$out")"
acc api-token --cmd 'printf faketoken' >/dev/null 2>&1
check "--cmd rerun replaces, never duplicates" "1" "$(grep -c '^api_token_cmd=' "$SHARE_CONFIG_DIR/config")"
rm -f "$SHARE_CONFIG_DIR/config"
: >"$WORK/sec.log"
out=$(printf 'tok-from-stdin' | SEC_LOG="$WORK/sec.log" PATH="$WORK/fakesec:$PATH" SEC_ITEM=tok-from-stdin acc api-token 2>&1 1>/dev/null); rc=$?
check "stdin: stored through the Keychain under share-api:<host>" "1" "$(grep -c "^add-generic-password share-api:$SHARE_HOSTNAME$" "$WORK/sec.log")"
check "stdin: the value never reached the stub's argv or log" "0" "$(grep -c 'tok-from-stdin' "$WORK/sec.log")"
check "stdin: the preflight ran and read the keychain item" "1" "$([[ $rc == 0 ]] && grep -c "^  ok       token found (keychain share-api:$SHARE_HOSTNAME)$" <<<"$out")"
check "the stored token wins over the environment" "1" "$(SEC_LOG="$WORK/sec.log" PATH="$WORK/fakesec:$PATH" SEC_ITEM=stored acc api-token --check 2>&1 1>/dev/null | grep -c 'token found (keychain')"
out=$(acc api-token --cmd $'printf a\nprintf b' 2>&1 1>/dev/null); rc=$?
check "row 37: api-token --cmd with a line break is refused" "1" "$([[ $rc == 1 ]] && grep -c 'usage: share api-token' <<<"$out")"
# shellcheck disable=SC2002 # cat keeps a missing file a count of 0; a redirect would fail instead
check "row 37: the refused --cmd wrote no config line" "0" "$(cat "$SHARE_CONFIG_DIR/config" 2>/dev/null | grep -c '^api_token_cmd=')"
seclines=$(wc -l <"$WORK/sec.log" | tr -d ' ')
out=$(printf %s "bad'token" | SEC_LOG="$WORK/sec.log" PATH="$WORK/fakesec:$PATH" acc api-token 2>&1 1>/dev/null); rc=$?
check "row 37: a pasted token outside the token alphabet is refused" "1" "$([[ $rc == 1 ]] && grep -c 'does not look like a Cloudflare API token' <<<"$out")"
check "row 37: the refused token was never stored" "$seclines" "$(wc -l <"$WORK/sec.log" | tr -d ' ')"
# shellcheck disable=SC2069 # stderr only, on purpose: the preflight prints there
pre() { SHARE_ACCESS_DRY=1 CLOUDFLARE_API_TOKEN=faketoken "$@" bash "$SH" api-token --check 2>&1 1>/dev/null; }
mark="$WORK/pre-marker"; touch "$mark"; sleep 1.1; : >"$alog"
out=$(pre env); rc=$?
check "--check all ok: exit 0" "0" "$rc"
check "--check: identical output on a rerun" "$out" "$(pre env)"
check "--check: no write other than the {} probe in the call log" "GET zones GET orgs POST app {} GET zones GET orgs POST app {}" "$(tr '\n' ' ' <"$alog" | sed 's/ $//')"
check "--check: nothing written under the root or the config dir" "" "$(find "$SHARE_ROOT" "$SHARE_CONFIG_DIR" -newer "$mark" ! -name '*.log' 2>/dev/null)"
out=$(pre env SHARE_ACCESS_DRY_ORGS=deny); rc=$?
check "Groups Read denied: MISSING names the scope, exit 1" "1" "$([[ $rc == 1 ]] && grep -c '^  MISSING  Access: Organizations, Identity Providers, and Groups Read' <<<"$out")"
out=$(pre env SHARE_ACCESS_DRY_APPS=deny); rc=$?
check "Apps Edit denied: MISSING names the scope, exit 1" "1" "$([[ $rc == 1 ]] && grep -c '^  MISSING  Access: Apps and Policies Edit .*-> 10000$' <<<"$out")"
check "a MISSING line ends with the fix command" "1" "$(grep -c "then run: share api-token --check$" <<<"$out")"
out=$(pre env SHARE_ACCESS_DRY_ORGS=off); rc=$?
check "Access not enabled: the enable hint, exit 1" "1" "$([[ $rc == 1 ]] && grep -c 'enable Zero Trust for this account in the Cloudflare dashboard, then: share api-token --check$' <<<"$out")"
out=$(pre env SHARE_ACCESS_DRY_ZONES=2); rc=$?
check "two active zones: ambiguous, exit 1" "1" "$([[ $rc == 1 ]] && grep -c '^  MISSING  ambiguous: 2 active zones named example.test' <<<"$out")"
out=$(pre env SHARE_ACCESS_DRY_ZONES=0); rc=$?
check "no zone: Zone: Read MISSING, exit 1" "1" "$([[ $rc == 1 ]] && grep -c '^  MISSING  Zone: Read' <<<"$out")"

echo "--- row 32: every error line names its fix (a command or a URL) ---"
printf 'api_token_cmd=false\n' >"$SHARE_CONFIG_DIR/config"
out=$(acc add "$WORK/gated.txt" --access email:a@x.io 2>&1 1>/dev/null)
check "api_token_cmd failure names the exit code and the replacement" "1" "$(grep -c "api_token_cmd failed (exit 1); run it by hand to see why, or replace it: share api-token --cmd '<command>'$" <<<"$out")"
rm -f "$SHARE_CONFIG_DIR/config"
fix_lines() { grep -E '^share: |^  fix:' | grep -v 'checking the API token\|waiting .*for Cloudflare Access' | grep -vE '(share (api-token|add|prune|teardown|setup|rm)[^;]*|https?://[^ ]+|\(hostname\)>'"'"'|share add \(Access can take several minutes on a new app\))$' ; }
check "no fix-naming line ends without a command or a URL" "" "$( { pre env SHARE_ACCESS_DRY_APPS=deny; pre env SHARE_ACCESS_DRY_ORGS=off; SHARE_ACCESS_WAIT=1 SHARE_ACCESS_POLL=1 acc add "$WORK/gated.txt" --access email:a@x.io 2>&1 1>/dev/null; printf 'mode=quick\n' >"$SHARE_CONFIG_DIR/config"; acc add "$WORK/gated.txt" --access email:a@x.io 2>&1 1>/dev/null; rm -f "$SHARE_CONFIG_DIR/config"; } | fix_lines)"
rm -f "$afix"

echo "--- row 33: share api-token with no argument opens the prefilled form and reads a hidden paste ---"
if command -v expect >/dev/null; then
  mkdir -p "$WORK/fakeopen"
  # shellcheck disable=SC2016 # literal code for the stub, not this shell's expansion
  # the pty closes the moment share exits and HUPs the backgrounded opener; the stub must still land its line
  printf '#!/bin/bash\ntrap "" HUP\nprintf "%%s\\n" "$@" >>"${OPEN_LOG:?}"\n' >"$WORK/fakeopen/open"
  cp "$WORK/fakeopen/open" "$WORK/fakeopen/xdg-open"; chmod +x "$WORK/fakeopen/open" "$WORK/fakeopen/xdg-open"
  cat >"$WORK/tty.exp" <<'EXP'
set timeout 20
log_user 1
spawn bash [lindex $argv 0] api-token
expect {
  "Paste the new token (input hidden): " { send "tty-token\r" }
  timeout { puts "NO-PROMPT"; exit 2 }
}
expect eof
EXP
  tty_run() { # tty_run [VAR=value]...: share api-token under a pseudo-terminal, the token typed at the prompt
    env "$@" OPEN_LOG="$WORK/open.log" SEC_LOG="$WORK/sec.log" SEC_ITEM=tty-token PATH="$WORK/fakeopen:$WORK/fakesec:$PATH" \
      SHARE_ACCESS_DRY=1 CLOUDFLARE_API_TOKEN=faketoken expect -f "$WORK/tty.exp" "$SH" 2>&1 | tr -d '\r'
  }
  : >"$WORK/open.log"; : >"$WORK/sec.log"
  tty_out=$(tty_run DISPLAY=:0 SSH_CONNECTION=)
  for _ in $(seq 1 50); do [[ -s $WORK/open.log ]] && break; sleep 0.1; done
  if [[ ! -s $WORK/open.log ]]; then   # diagnostic on the failure path only
    echo "  (open.log empty; tty_out head: $(head -c 400 <<<"$tty_out" | tr '\n' '|')"
    # shellcheck disable=SC2016 # $0 is the script path handed to bash -c, not this shell's
    env DISPLAY=:0 SSH_CONNECTION= OPEN_LOG="$WORK/open.log" PATH="$WORK/fakeopen:$WORK/fakesec:$PATH" bash -x -c 'source <(sed -n "/^access_open_url() {/,/^}/p" "$0"); access_open_url https://diag/' "$SH" 2>&1 | sed 's/^/  (diag) /'
    sleep 0.5; echo "  (diag) open.log after a direct call: $(cat "$WORK/open.log")"
  fi
  check "tty: the opener ran once with the template URL as its only argument" "1" "$([[ $(wc -l <"$WORK/open.log" | tr -d ' ') == 1 ]] && grep -c '^https://dash.cloudflare.com/?to=/:account/api-tokens&permissionGroupKeys=.*&name=share%20access%20%28default%29$' "$WORK/open.log")"
  check "tty: the prompt appeared and the token did not echo" "1" "$([[ $(grep -c 'Paste the new token (input hidden):' <<<"$tty_out") == 1 && $(grep -c 'tty-token' <<<"$tty_out") == 0 ]] && echo 1 || echo 0)"
  check "tty: the token was stored and the preflight ran" "1" "$([[ $(grep -c "^add-generic-password share-api:$SHARE_HOSTNAME$" "$WORK/sec.log") == 1 ]] && grep -c 'token found (keychain' <<<"$tty_out")"
  : >"$WORK/open.log"
  tty_out=$(tty_run SSH_CONNECTION="1.2.3.4 1 5.6.7.8 22")
  check "tty over ssh: the URL is printed, the opener is not called, the prompt still appears" "1" "$([[ ! -s $WORK/open.log && $(grep -c 'https://dash.cloudflare.com/' <<<"$tty_out") -ge 1 ]] && grep -c 'Paste the new token (input hidden):' <<<"$tty_out")"
else
  echo "  skip  expect not installed (the pseudo-terminal paste is covered on macOS)"
fi

echo "--- row 26: the token never appears in argv (a curl shim on PATH, dry mode off) ---"
mkdir -p "$WORK/shimcurl"
cat >"$WORK/shimcurl/curl" <<'CURLEOF'
#!/bin/bash
# records argv, then answers as the Cloudflare API or the Access edge would
printf '%s\n' "$@" >>"${SHIM_LOG:?}"
url="" data="" method=GET fmt=""; prev=""
for a in "$@"; do
  case $prev in --data) data="$a" ;; -X) method="$a" ;; -w) fmt="$a" ;; esac
  case $a in http*) url="$a" ;; esac
  prev="$a"
done
st="${SHIM_STATE:?}"; mkdir -p "$st"
case "$method $url" in
  "GET https://cloudflare-dns.com/dns-query?"*) printf '{"Authority":[{"name":"example.test.","type":6}]}'; exit 0 ;;
  "GET https://api.cloudflare.com/client/v4/zones?"*) body='{"success":true,"result":[{"id":"z1","account":{"id":"a1"}}]}'; code=200 ;;
  "GET "*/access/organizations) body='{"success":true,"result":{}}'; code=200 ;;
  "POST "*/access/apps)
    if [[ $data == '{}' ]]; then body='{"success":false,"errors":[{"code":12130}]}'; code=400
    else body="$(jq -c '{success:true, result: (. + {id:"11111111-1111-4111-8111-111111111111", aud:"aud-shim"})}' <<<"$data")"; printf '%s' "$body" >"$st/app.json"; code=201; fi ;;
  "GET "*/access/apps/*) body="$(cat "$st/app.json" 2>/dev/null || echo '{"success":false,"errors":[{"code":12103}]}')"; code=200; [[ -s $st/app.json ]] || code=404 ;;
  "DELETE "*/access/apps/*) rm -f "$st/app.json"; body='{"success":true}'; code=200 ;;
  "GET https://s.example.test/"*)   # SHIM_EDGE: an edge answer the probe must refuse, or dohfail (a network that blocks DoH)
    login="https://team.cloudflareaccess.com/cdn-cgi/access/login/s.example.test?kid=aud-shim"
    case ${SHIM_EDGE:-} in
      kid) login="${login%=*}=aud-other" ;;
      host) login="${login/login\/s.example.test/login/other.example.test}" ;;
      offsite) login="${login/team.cloudflareaccess.com/team.example.com}" ;;
      200) printf '200 '; exit 0 ;;
      dohfail) [[ " $* " == *" --doh-url "* ]] && { printf '000 '; exit 6; } ;;
    esac
    printf '302 %s' "$login"; exit 0 ;;
  *) exit 0 ;;
esac
[[ $fmt == *http_code* ]] && printf '%s\n%s' "$body" "$code" || printf '%s' "$body"
CURLEOF
chmod +x "$WORK/shimcurl/curl"
: >"$WORK/shim.log"; rm -rf "$WORK/shim-state"
s26_url=$(SHIM_LOG="$WORK/shim.log" SHIM_STATE="$WORK/shim-state" PATH="$WORK/shimcurl:$PATH" CLOUDFLARE_API_TOKEN=sentinel-t0k3n SHARE_ACCESS_POLL=0 SHARE_CLIPBOARD=0 bash "$SH" add "$WORK/gated.txt" --access email:a@x.io 2>"$WORK/s26.err" | head -1); s26_id=$(cut -d/ -f4 <<<"$s26_url")
check "shim: the gated add went through the real cf_try path and published" "1" "$([[ -n $s26_id ]] && row_of "$s26_id" | grep -c 'access=11111111-1111-4111-8111-111111111111')"
check "shim: three probe rounds hit the edge URLs" "1" "$([[ $(grep -c '^https://s.example.test/' "$WORK/shim.log") -ge 6 ]] && echo 1 || echo 0)"
SHIM_LOG="$WORK/shim.log" SHIM_STATE="$WORK/shim-state" PATH="$WORK/shimcurl:$PATH" CLOUDFLARE_API_TOKEN=sentinel-t0k3n bash "$SH" rm "$s26_id" >/dev/null 2>&1
check "shim: rm deleted the app through the shim" "1" "$([[ ! -e $WORK/shim-state/app.json && -z $(row_of "$s26_id") ]] && echo 1 || echo 0)"
check "shim: the sentinel token never appeared in argv" "0" "$(grep -c 'sentinel-t0k3n' "$WORK/shim.log")"
check "shim: nor in share's own stdout or stderr" "0" "$(grep -c 'sentinel-t0k3n' "$WORK/s26.err" <<<"$s26_url" | awk '{s += $1} END {print s + 0}')"
check "shim: every API call carried the token through a header file" "$(grep -c '^https://api.cloudflare.com/' "$WORK/shim.log")" "$(grep -c '^@/dev/fd/' "$WORK/shim.log")"
check "shim: at least the add's five calls and rm's three reached the API" "1" "$([[ $(grep -c '^https://api.cloudflare.com/' "$WORK/shim.log") -ge 8 ]] && echo 1 || echo 0)"
rm -f "$SHARE_CONFIG_DIR/config"   # host_zone learned zone= through the shim's DoH answer

echo "--- the real probe parser: every wrong edge answer keeps the share unpublished and deletes the app ---"
shim() { SHIM_LOG="$WORK/shim.log" SHIM_STATE="$WORK/shim-state" PATH="$WORK/shimcurl:$PATH" CLOUDFLARE_API_TOKEN=sentinel-t0k3n SHARE_ACCESS_POLL=1 SHARE_CLIPBOARD=0 bash "$SH" "$@"; }
for edge in kid host 200 offsite; do
  rm -rf "$WORK/shim-state"; : >"$apending"
  idx_before=$(cksum <"$SHARE_ROOT/index.tsv"); pub_before="$(find "$SHARE_ROOT/pub" -maxdepth 1 | sort)"
  # 12 s fits three passing rounds 5 s apart, so a parser that accepted this answer would publish before the timeout
  out=$(SHIM_EDGE=$edge SHARE_ACCESS_WAIT=12 shim add "$WORK/gated.txt" --access email:a@x.io 2>&1 1>/dev/null); rc=$?
  check "edge $edge: refused, no row, no pub/<id>, app deleted, pending empty" "1" "$([[ $rc == 1 && $(cksum <"$SHARE_ROOT/index.tsv") == "$idx_before" && "$(find "$SHARE_ROOT/pub" -maxdepth 1 | sort)" == "$pub_before" && ! -e $WORK/shim-state/app.json && ! -s $apending ]] && grep -c 'did not enforce on' <<<"$out")"
done

echo "--- a network that blocks DoH: the probe falls back to the system resolver ---"
rm -rf "$WORK/shim-state"
d4_url=$(SHIM_EDGE=dohfail SHARE_ACCESS_WAIT=40 shim add "$WORK/gated.txt" --access email:a@x.io 2>/dev/null | head -1); d4_id=$(cut -d/ -f4 <<<"$d4_url")
check "DoH blocked: the gated add passes through the fallback probe and publishes" "1" "$([[ -n $d4_id ]] && row_of "$d4_id" | grep -c 'access=11111111-1111-4111-8111-111111111111')"
[[ -n $d4_id ]] && shim rm "$d4_id" >/dev/null 2>&1
rm -f "$SHARE_CONFIG_DIR/config"

echo "--- ls with an expired gated row and another account's token still lists ---"
areset
x2_url=$(acc add "$WORK/gated.txt" --access email:a@x.io 2>/dev/null | head -1); x2_id=$(cut -d/ -f4 <<<"$x2_url"); x2_app=$(app_of "$x2_id")
awk -F'\t' -v OFS='\t' -v id="$x2_id" '$1 == id {$5 = 1} {print}' "$SHARE_ROOT/index.tsv" >"$WORK/i" && mv "$WORK/i" "$SHARE_ROOT/index.tsv"
out=$(SHARE_ACCESS_DRY=1 SHARE_ACCESS_DRY_ZONES=0 CLOUDFLARE_API_TOKEN=faketoken bash "$SH" ls 2>/dev/null); rc=$?
check "ls, expired gated row, another account's token: exit 0 and the list printed" "1" "$([[ $rc == 0 ]] && grep -c "id=$md_id " <<<"$out")"
check "ls, expired gated row: unpublished, the app waits with no owner, no DELETE" "1" "$([[ -z $(row_of "$x2_id") && ! -e $SHARE_ROOT/pub/$x2_id && $(grep -c 'DELETE app' "$alog") == 0 ]] && grep -c "^$x2_id	$x2_app	0	" "$apending")"
acc prune >/dev/null 2>&1

echo "--- bare prune with a failing api_token_cmd still expires ---"
areset
x7_url=$(acc add "$WORK/gated.txt" --access email:a@x.io 2>/dev/null | head -1); x7_id=$(cut -d/ -f4 <<<"$x7_url"); x7_app=$(app_of "$x7_id")
awk -F'\t' -v OFS='\t' -v id="$x7_id" '$1 == id {$5 = 1} {print}' "$SHARE_ROOT/index.tsv" >"$WORK/i" && mv "$WORK/i" "$SHARE_ROOT/index.tsv"
printf 'api_token_cmd=false\n' >"$SHARE_CONFIG_DIR/config"
out=$(env -u CLOUDFLARE_API_TOKEN SHARE_ACCESS_DRY=1 bash "$SH" prune 2>&1 1>/dev/null); rc=$?
rm -f "$SHARE_CONFIG_DIR/config"
check "prune, api_token_cmd fails: exit 0, one warning naming it" "1" "$([[ $rc == 0 ]] && grep -c 'api_token_cmd failed (exit 1)' <<<"$out")"
check "prune, api_token_cmd fails: row and bytes gone, the app waits" "1" "$([[ -z $(row_of "$x7_id") && ! -e $SHARE_ROOT/pub/$x7_id ]] && grep -c "^$x7_id	$x7_app	0	" "$apending")"
y7_url=$(acc add "$WORK/gated.txt" --access email:a@x.io 2>/dev/null | head -1); y7_id=$(cut -d/ -f4 <<<"$y7_url")
awk -F'\t' -v OFS='\t' -v id="$y7_id" '$1 == id {$5 = 1} {print}' "$SHARE_ROOT/index.tsv" >"$WORK/i" && mv "$WORK/i" "$SHARE_ROOT/index.tsv"
SHARE_ACCESS_DRY=1 SHARE_ACCESS_DRY_ZONES=0 CLOUDFLARE_API_TOKEN=faketoken bash "$SH" prune >/dev/null 2>&1; rc=$?
check "prune, pending apps and another account's token: exit 0, the expired row still goes" "1" "$([[ $rc == 0 && -z $(row_of "$y7_id") ]] && echo 1 || echo 0)"
acc prune >/dev/null 2>&1

echo "--- a failed Caddy reload on rm keeps a live gated share's app ---"
areset
r5_url=$(acc add "$FIX_PORT" --access email:a@x.io 2>/dev/null | head -1); r5_id=$(cut -d/ -f4 <<<"$r5_url"); r5_app=$(app_of "$r5_id")
mkdir -p "$WORK/badcaddy"
# shellcheck disable=SC2016 # literal code for the stub, not this shell's expansion
printf '#!/bin/bash\n[[ $1 == reload ]] && { echo "reload refused" >&2; exit 1; }\nexec "%s" "$@"\n' "$(command -v caddy)" >"$WORK/badcaddy/caddy"; chmod +x "$WORK/badcaddy/caddy"
out=$(PATH="$WORK/badcaddy:$PATH" acc rm "$r5_id" 2>&1 1>/dev/null); rc=$?
check "reload fails on rm of a live gated share: exit 1, no DELETE app, the app waits" "1" "$([[ $rc == 1 && $(grep -c 'DELETE app' "$alog") == 0 ]] && grep -c "^$r5_id	$r5_app	" "$apending")"
check "reload fails on rm: the stale route still proxies, which is why the gate stays" "hello fixture" "$(curl -s "$(local_url "${r5_url}hello.txt")")"
PATH="$WORK/badcaddy:$PATH" acc prune >/dev/null 2>&1
check "a sweep whose reload fails keeps the app too" "0" "$(grep -c 'DELETE app' "$alog")"
acc prune >/dev/null 2>&1
check "a sweep with a working reload drops the route, then deletes the app" "1" "$([[ $(alast RELOAD) -lt $(aline 'DELETE app') && $(grep -c "^$r5_id	" "$apending") == 0 ]] && echo 1 || echo 0)"
check "the live gated link is gone after that sweep" "404" "$(wait_code 404 "${r5_url}hello.txt")"

echo "--- SHARE_ACCESS_DRY=1 with the tunnel on never fakes a Cloudflare answer ---"
areset
g9_url=$(acc add "$WORK/gated.txt" --access email:a@x.io 2>/dev/null | head -1); g9_id=$(cut -d/ -f4 <<<"$g9_url")
out=$(SHARE_TUNNEL=1 SHARE_ACCESS_DRY=1 CLOUDFLARE_API_TOKEN=faketoken bash "$SH" rm "$g9_id" 2>&1 1>/dev/null); rc=$?
check "dry seam, tunnel on: rm refuses, row and app intact, no DELETE" "1" "$([[ $rc == 1 && -n $(row_of "$g9_id") && -e $adry/$(app_of "$g9_id").json && $(grep -c 'DELETE app' "$alog") == 0 ]] && grep -c 'SHARE_ACCESS_DRY=1 is a test seam for SHARE_TUNNEL=0 only' <<<"$out")"
acc rm "$g9_id" >/dev/null 2>&1

echo "--- a token file wider than 600 is tightened on store (no security binary) ---"
mkdir -p "$WORK/nosec"
for f in /usr/bin/*; do [[ ${f##*/} == security ]] || ln -sf "$f" "$WORK/nosec/${f##*/}"; done
nosec_path="$WORK/nosec:$(dirname "$(command -v jq)"):$(dirname "$(command -v caddy)"):/bin:/usr/sbin:/sbin"
(umask 022; echo old >"$SHARE_CONFIG_DIR/api-token")
echo newtok | env PATH="$nosec_path" SHARE_ACCESS_DRY=1 CLOUDFLARE_API_TOKEN=faketoken bash "$SH" api-token >/dev/null 2>&1
check "an existing 644 token file is 600 after a store" "600 newtok" "$(perm "$SHARE_CONFIG_DIR/api-token") $(cat "$SHARE_CONFIG_DIR/api-token")"
rm -f "$SHARE_CONFIG_DIR/api-token"

echo "--- rows 12 and 12b: teardown never leaves a gated share behind ---"
areset
acc rm "$g_id" >/dev/null 2>&1; acc rm "$p_id" >/dev/null 2>&1; acc rm "$o6_id" >/dev/null 2>&1; acc rm "$l6_id" >/dev/null 2>&1
: >"$alog"
t_url=$(acc add "$WORK/gated.txt" --access email:a@x.io 2>/dev/null | head -1); t_id=$(cut -d/ -f4 <<<"$t_url"); t_app=$(app_of "$t_id")
printf 'hostname=%s\ntunnel_id=abc123\ntunnel_name=share-test\nauth=api\nhosts=%s\nport=%s\nzone=example.test\n' "$SHARE_HOSTNAME" "$SHARE_HOSTS" "$SHARE_PORT" >"$SHARE_CONFIG_DIR/config"
cfg_before=$(cksum <"$SHARE_CONFIG_DIR/config")
# the tunnel legs call cf() for real, so a curl that answers `success:false` ends a setup that got past the refusal
mkdir -p "$WORK/nocurl"; printf '#!/bin/bash\necho "{\\"success\\":false,\\"errors\\":[{\\"code\\":0}]}"\n' >"$WORK/nocurl/curl"; chmod +x "$WORK/nocurl/curl"
out=$(PATH="$WORK/nocurl:$PATH" acc setup other.example.test --no-service 2>&1 1>/dev/null); rc=$?
check "row 12: setup with a new hostname over a gated share is refused before any change" "1" "$([[ $rc == 1 && $(cksum <"$SHARE_CONFIG_DIR/config") == "$cfg_before" && -n $(row_of "$t_id") ]] && grep -c "$SHARE_HOSTNAME has gated shares or Access apps awaiting deletion" <<<"$out")"
out=$(PATH="$WORK/nocurl:$PATH" acc setup "$SHARE_HOSTNAME" --no-service 2>&1 1>/dev/null)
check "row 12: setup with the same hostname is not refused for a gated share" "0" "$(grep -c 'has gated shares' <<<"$out")"
out=$(env -u CLOUDFLARE_API_TOKEN SEC_LOG="$WORK/sec.log" PATH="$WORK/fakesec:$PATH" SHARE_ACCESS_DRY=1 bash "$SH" teardown --yes 2>&1 1>/dev/null); rc=$?
check "row 12: teardown without a token dies before any change" "1" "$([[ $rc == 1 ]] && grep -c 'teardown would orphan 1 Access app(s); rerun with CLOUDFLARE_API_TOKEN$' <<<"$out")"
check "row 12: teardown printed the guided block first" "1" "$(grep -c 'needs a Cloudflare API token' <<<"$out")"
check "row 12: config, row, bytes, server intact" "1" "$([[ $(cksum <"$SHARE_CONFIG_DIR/config") == "$cfg_before" && -n $(row_of "$t_id") && -e $SHARE_ROOT/pub/$t_id ]] && bash "$SH" status | grep -c '^serving')"
plant_app f3f3f3 "chat-staff"
printf 'f3f3f3\t00000000-0000-4000-8000-000000f3f3f3\t0\t-\t%s\n' "$(date +%s)" >"$apending"
out=$(acc teardown --yes 2>&1 1>/dev/null); rc=$?
check "row 38: teardown dies before the tunnel goes when a delete is refused" "1" "$([[ $rc == 1 ]] && grep -c '1 Access app(s) could not be deleted (see above); teardown stops before the tunnel goes' <<<"$out")"
check "row 38: the refused app was named, config and server intact" "1" "$([[ $(cksum <"$SHARE_CONFIG_DIR/config") == "$cfg_before" ]] && grep -c "not the app of share f3f3f3" <<<"$out")"
: >"$apending"
# the Access legs run dry; the tunnel legs after them hit cf() for real, so a curl that answers `success:false` ends teardown there
mkdir -p "$WORK/nocurl"; printf '#!/bin/bash\necho "{\\"success\\":false,\\"errors\\":[{\\"code\\":0}]}"\n' >"$WORK/nocurl/curl"; chmod +x "$WORK/nocurl/curl"
PATH="$WORK/nocurl:$PATH" acc teardown --yes >"$WORK/td.out" 2>&1
check "row 12b: the gated row and its bytes are gone, DELETE app logged" "1" "$([[ -z $(row_of "$t_id") && ! -e $SHARE_ROOT/pub/$t_id ]] && grep -c "^DELETE app $t_app$" "$alog")"
check "row 12b: the ungated row and its bytes stay" "1" "$([[ -n $(row_of "$md_id") && -e $SHARE_ROOT/pub/$md_id ]] && echo 1 || echo 0)"
check "row 12b: access-pending empty" "0" "$(awk 'NF' "$apending" 2>/dev/null | wc -l | tr -d ' ')"
rm -f "$SHARE_CONFIG_DIR/config"; : >"$apending"
SHARE_LIVE_CHECK=0 bash "$SH" start >/dev/null 2>&1
bash "$SH" rm "$(cut -d/ -f4 <<<"$pct_url")" >/dev/null 2>&1
check "help shows the --access and api-token lines" "2" "$(bash "$SH" --help | grep -c '^  share add ... --access\|^  share api-token')"

echo "=== skill ==="
check "skill prints a SKILL.md" "1" "$(bash "$SH" skill | grep -c '^name: share')"
check "skill teaches --access and api-token" "2" "$(bash "$SH" skill | grep -c -- '--access email:<a>,<b>\|share api-token \[--cmd')"
check "skill teaches --profile and share profiles" "1" "$(bash "$SH" skill | grep -c -- '--profile <name> <command>.*share profiles')"
SHARE_SKILL_DIR="$WORK/skilldir" bash "$SH" skill --install >/dev/null
check "skill --install writes SKILL.md" "share" "$(sed -n 's/^name: //p' "$WORK/skilldir/SKILL.md")"

echo "=== r2 backend: setup argument refusals ==="
R2H="$WORK/r2home"; mkdir -p "$R2H"
r2p() { # r2p <verb...>: the r2 test profile under its own HOME, no SHARE_* path or port overrides
  env -u SHARE_ROOT -u SHARE_CONFIG_DIR -u SHARE_PORT -u SHARE_HOSTNAME -u SHARE_SERVICE_LABEL -u XDG_CONFIG_HOME -u SHARE_PROFILE -u SHARE_BACKEND \
    HOME="$R2H" SHARE_TUNNEL=0 bash "$SH" --profile r2x "$@"
}
r2conf="$R2H/.config/share/profiles/r2x/config"
out=$(r2p setup r2x.example.test --backend r2 2>&1); rc=$?
check "r2 setup without --bucket refuses" "1" "$rc"
check "r2 usage line printed" "1" "$(grep -c 'usage: share setup <hostname> --backend r2 --bucket <name>' <<<"$out")"
out=$(r2p setup r2x.example.test --backend r2 --bucket Bad_Bucket 2>&1); rc=$?
check "bad bucket name refuses" "1" "$rc"
check "bad bucket named" "1" "$(grep -c 'bad bucket name' <<<"$out")"
out=$(r2p setup r2x.example.test --backend r2 --bucket ok-bucket --quick 2>&1); rc=$?
check "--backend r2 with --quick refuses" "1" "$rc"
out=$(r2p setup r2x.example.test --backend r2 --bucket ok-bucket --no-service 2>&1); rc=$?
check "--backend r2 with --no-service refuses" "1" "$rc"
out=$(r2p setup r2x.example.test --backend r2 --bucket ok-bucket --login 2>&1); rc=$?
check "--backend r2 with --login refuses" "1" "$rc"
out=$(r2p setup r2x.example.test --backend r2 --bucket ok-bucket --tunnel-name t 2>&1); rc=$?
check "--backend r2 with --tunnel-name refuses" "1" "$rc"
out=$(r2p setup r2x.example.test --backend bogus --bucket ok-bucket 2>&1); rc=$?
check "--backend bogus refuses" "1" "$rc"
check "bogus backend named" "1" "$(grep -c -- "--backend must be" <<<"$out")"
out=$(r2p setup r2x.example.test --bucket ok-bucket 2>&1); rc=$?
check "--bucket without --backend r2 refuses" "1" "$rc"
mkdir -p "${r2conf%/*}"
printf 'hostname=r2x.example.test\ntunnel_id=abc123\nport=8787\n' >"$r2conf"
out=$(r2p setup r2x.example.test --backend r2 --bucket ok-bucket 2>&1); rc=$?
check "r2 setup over a tunnel config refuses" "1" "$rc"
check "the refusal names teardown" "1" "$(grep -c 'teardown' <<<"$out")"
check "tunnel config untouched by the refusal" "1" "$(grep -c 'tunnel_id=abc123' "$r2conf")"
rm -f "$r2conf"
out=$(CLOUDFLARE_API_TOKEN="" r2p setup r2x.example.test --backend r2 --bucket ok-bucket 2>&1); rc=$?
check "valid r2 args with no token exit 1" "1" "$rc"
check "the refusal names CLOUDFLARE_API_TOKEN" "1" "$(grep -c 'reads its token from CLOUDFLARE_API_TOKEN only' <<<"$out")"
check "no config written" "0" "$([[ -f $r2conf ]] && echo 1 || echo 0)"
printf 'backend=r2\nhostname=r2x.example.test\nzone=example.test\nbucket=ok-bucket\nport=r2\n' >"$r2conf"
for verb in start stop serve; do
  out=$(r2p "$verb" 2>&1); rc=$?
  check "r2 profile: $verb refuses" "1" "$rc"
  check "$verb names no local server" "1" "$(grep -c 'no local server' <<<"$out")"
done
out=$(r2p service install 2>&1); rc=$?
check "r2 profile: service install refuses" "1" "$rc"
check "install names no local server" "1" "$(grep -c 'no local server' <<<"$out")"
out=$(r2p teardown --yes 2>&1); rc=$?
check "r2 profile: teardown refuses" "1" "$rc"
check "teardown names r2" "1" "$(grep -c 'r2 teardown is not implemented yet' <<<"$out")"
out=$(r2p add 9999 2>&1); rc=$?
check "r2 profile: live add refuses" "1" "$rc"
check "live add names local" "1" "$(grep -c 'live shares stay local' <<<"$out")"
out=$(r2p add "$WORK/wt/one.md" --host hh.example.test 2>&1); rc=$?
check "r2 profile: --host add refuses" "1" "$rc"
check "--host add names the tunnel" "1" "$(grep -c 'needs a named tunnel' <<<"$out")"
out=$(r2p add "$WORK/wt/one.md" 2>&1); rc=$?
check "r2 profile: file add still a stub" "1" "$rc"
check "add stub names r2" "1" "$(grep -c 'r2 backend: add is not implemented yet' <<<"$out")"
out=$(r2p setup other.example.test 2>&1); rc=$?
check "tunnel setup on an r2 profile refuses" "1" "$rc"
check "names the r2 backend" "1" "$(grep -c 'set up with the r2 backend' <<<"$out")"
out=$(r2p setup --quick 2>&1); rc=$?
check "quick setup on an r2 profile refuses" "1" "$rc"
rm -f "$r2conf"

echo "=== r2 backend: an older share refuses an r2 profile (compat) ==="
main_bin="$WORK/share-main"
if git -C "$(dirname "$SH")/.." show origin/main:bin/share >"$main_bin" 2>/dev/null; then
  R22="$WORK/r22home"; mkdir -p "$R22/.config/share/profiles/r2x"
  printf 'backend=r2\nhostname=r2x.example.test\nzone=example.test\nbucket=ok-bucket\nport=r2\n' >"$R22/.config/share/profiles/r2x/config"
  r22() { # r22 <verb...>: origin/main's share against the r2 profile
    env -u SHARE_ROOT -u SHARE_CONFIG_DIR -u SHARE_PORT -u SHARE_HOSTNAME -u SHARE_SERVICE_LABEL -u XDG_CONFIG_HOME -u SHARE_PROFILE -u SHARE_BACKEND \
      HOME="$R22" SHARE_TUNNEL=0 bash "$main_bin" --profile r2x "$@"
  }
  for verb in "add" "ls" "gated" "setup"; do
    case $verb in
      add) out=$(r22 add "$WORK/wt/one.md" 2>&1); rc=$? ;;
      ls) out=$(r22 ls 2>&1); rc=$? ;;
      gated) out=$(r22 add --access email:a@x.io "$WORK/wt/one.md" 2>&1); rc=$? ;;
      setup) out=$(r22 setup 2>&1); rc=$? ;;
    esac
    check "old share dies at load: $verb" "1" "$rc"
    check "the port sentinel is named: $verb" "1" "$(grep -c "port 'r2' is not a number" <<<"$out")"
  done
  check "nothing under the r2 profile's root" "0" "$([[ -d $R22/share/profiles/r2x ]] && echo 1 || echo 0)"
else
  [[ ${CI:-} == true ]] && check "origin/main fetched for the compat row" "yes" "missing"
  echo "  SKIP  origin/main not fetched; compat rows skipped"
fi

echo "=== r2 backend: byte identity of existing installs (compat) ==="
if [[ -s $main_bin ]]; then
  CHOME="$WORK/compat-home"
  compat_run() { # compat_run <bin> <tag>: one install's whole verb set under one HOME, artifacts into $WORK/compat-<tag>
    local bin=$1 out="$WORK/compat-$2"
    rm -rf "$CHOME" "$out" 2>/dev/null; mkdir -p "$CHOME" "$out"
    local envs=(
      -u SHARE_ROOT -u SHARE_CONFIG_DIR -u SHARE_PORT -u SHARE_HOSTNAME -u SHARE_PROFILE -u SHARE_BACKEND -u XDG_CONFIG_HOME
      "HOME=$CHOME" SHARE_TUNNEL=1 SHARE_LIVE_CHECK=0 SHARE_CLIPBOARD=0
      "SHARE_TEST_PORT_BASE=$base" SHARE_FAKE_QUICK_URL=compat-q "SHARE_SERVICE_LABEL=share-selftest-$$" "SHARE_HOSTS=${h%%.*}"
      "PATH=$QPATH"
    )
    env "${envs[@]}" bash "$bin" setup --quick --no-service >"$out/setup.out" 2>"$out/setup.err"
    env "${envs[@]}" SHARE_TEST_IDS=c0a011 bash "$bin" add --ttl never "$WORK/wt/one.md" >"$out/add-file.out" 2>"$out/add-file.err"
    env "${envs[@]}" SHARE_TEST_IDS=c0a012 bash "$bin" add --ttl never "$src" >"$out/add-dir.out" 2>"$out/add-dir.err"
    env "${envs[@]}" SHARE_TEST_IDS=c0a013 bash "$bin" add --ttl never "$FIX_PORT" >"$out/add-live.out" 2>"$out/add-live.err"
    env "${envs[@]}" SHARE_TEST_IDS=c0a014 SHARE_HOST_DRY=1 bash "$bin" add "$WORK/wt/one.md" --host hh.example.test >"$out/add-host.out" 2>"$out/add-host.err"
    env "${envs[@]}" bash "$bin" ls >"$out/ls.out" 2>"$out/ls.err"
    env "${envs[@]}" bash "$bin" state >"$out/state.out" 2>"$out/state.err"
    env "${envs[@]}" bash "$bin" service install >"$out/svc.out" 2>"$out/svc.err"
    env "${envs[@]}" bash "$bin" stop >/dev/null 2>&1
    for f in .config/share/config share/index.tsv share/Caddyfile share/host-calls.log share/quick.url; do
      [[ -f $CHOME/$f ]] && cp "$CHOME/$f" "$out/${f##*/}"
    done
    find "$CHOME/Library" "$CHOME/.config/systemd" -name '*.plist' -o -name 'foundation.d.share*' 2>/dev/null | while IFS= read -r p; do cp "$p" "$out/"; done
    # the binary's own path is the one legitimate difference between the two installs;
    # the realpath goes first: /private/var/... contains /var/... as a suffix
    for b in "$(realpath "$bin")" "$bin"; do
      find "$out" -type f -exec sed -i.bak "s|$b|SHAREBIN|g" {} + 2>/dev/null
    done
    find "$out" -name '*.bak' -delete 2>/dev/null; true
  }
  compat_run "$main_bin" main
  compat_run "$SH" new
  check "row 1: every artifact byte-identical" "" "$(diff -r "$WORK/compat-main" "$WORK/compat-new" 2>&1)"
else
  echo "  SKIP  origin/main not fetched; byte-identity row skipped"
fi

echo "=== r2 backend: dry seam and r2_call ==="
DRYD="$WORK/r2-dry-bucket"; mkdir -p "$DRYD"
r2d() { # r2d <verb...>: the r2 profile with the dry bucket seam
  env -u SHARE_ROOT -u SHARE_CONFIG_DIR -u SHARE_PORT -u SHARE_HOSTNAME -u SHARE_SERVICE_LABEL -u XDG_CONFIG_HOME -u SHARE_PROFILE -u SHARE_BACKEND \
    HOME="$R2H" SHARE_TUNNEL=0 SHARE_R2_DRY=1 SHARE_R2_DRY_DIR="$DRYD" bash "$SH" --profile r2x "$@"
}
printf 'backend=r2\nhostname=r2x.example.test\nzone=example.test\nbucket=ok-bucket\nport=r2\nr2_endpoint=https://acct.example.r2.cloudflarestorage.com\nr2_key_id=keyid42\n' >"$r2conf"
rlog="$R2H/share/profiles/r2x/r2-calls.log"
out=$(r2d r2-call PUT m/a1b2c3 "$WORK/wt/one.md" 2>&1); rc=$?
check "dry PUT 200" "0" "$rc"
check "dry PUT code" "code=200" "$(head -1 <<<"$out" | cut -d' ' -f1)"
check "dry object written" "1" "$([[ -f $DRYD/m/a1b2c3 ]] && echo 1 || echo 0)"
check "dry etag is md5 hex" "1" "$([[ $out =~ etag=[0-9a-f]{32} ]] && echo 1 || echo 0)"
check "dry log has the call" "1" "$(grep -c '^PUT m/a1b2c3$' "$rlog")"
out=$(r2d r2-call GET m/a1b2c3 2>&1); rc=$?
check "dry GET 200" "0" "$rc"
check "dry GET body" "single" "$(sed -n 2p <<<"$out")"
out=$(r2d r2-call GET m/missing 2>&1); rc=$?
check "dry GET missing 404" "code=404" "$(head -1 <<<"$out" | cut -d' ' -f1)"
out=$(r2d r2-call PUT m/a1b2c3 "$WORK/wt/one.md" -H 'If-None-Match: *' 2>&1); rc=$?
check "dry PUT if-none-match 412" "code=412" "$(head -1 <<<"$out" | cut -d' ' -f1)"
check "if-none-match did not write" "1" "$(cmp -s "$DRYD/m/a1b2c3" "$WORK/wt/one.md" && echo 1 || echo 0)"
etag=$(r2d r2-call HEAD m/a1b2c3 | sed 's/.*etag=\([0-9a-f]*\).*/\1/')
out=$(r2d r2-call PUT m/a1b2c3 "$WORK/wt/one.md" -H "If-Match: \"$etag\"" 2>&1); rc=$?
check "dry PUT if-match right etag 200" "code=200" "$(head -1 <<<"$out" | cut -d' ' -f1)"
out=$(r2d r2-call PUT m/a1b2c3 "$WORK/wt/one.md" -H 'If-Match: "0000"' 2>&1); rc=$?
check "dry PUT if-match wrong etag 412" "code=412" "$(head -1 <<<"$out" | cut -d' ' -f1)"
printf 'x\n' >"$WORK/weird.txt"
out=$(r2d r2-call PUT 'o/a1b2c3.12345678/a b%q?.txt' "$WORK/weird.txt" 2>&1); rc=$?
check "dry weird-key PUT" "0" "$rc"
out=$(r2d r2-call GET 'o/a1b2c3.12345678/a b%q?.txt' 2>&1); rc=$?
check "dry weird-key GET body" "x" "$(sed -n 2p <<<"$out")"
out=$(r2d r2-call LIST 'o/a1b2c3.' 2>&1); rc=$?
check "dry LIST 200" "code=200" "$(head -1 <<<"$out" | cut -d' ' -f1)"
check "dry LIST encoded key" "1" "$(grep -c 'a%20b%25q%3F.txt' <<<"$out")"
out=$(SHARE_R2_DRY_LIST=500 r2d r2-call LIST 'o/' 2>&1); rc=$?
check "dry LIST=500 knob" "code=500" "$(head -1 <<<"$out" | cut -d' ' -f1)"
out=$(SHARE_R2_DRY_PUT=lost r2d r2-call PUT m/lost99 "$WORK/wt/one.md" 2>&1); rc=$?
check "dry PUT lost answers 000" "code=000" "$(head -1 <<<"$out" | cut -d' ' -f1)"
check "dry PUT lost still commits" "1" "$([[ -f $DRYD/m/lost99 ]] && echo 1 || echo 0)"
out=$(SHARE_R2_DRY_DELETE=lost r2d r2-call DELETE m/a1b2c3 2>&1); rc=$?
check "dry DELETE lost answers 000" "code=000" "$(head -1 <<<"$out" | cut -d' ' -f1)"
check "dry DELETE lost keeps the object" "1" "$([[ -f $DRYD/m/a1b2c3 ]] && echo 1 || echo 0)"
out=$(r2d r2-call DELETE m/a1b2c3 2>&1); rc=$?
check "dry DELETE 204" "code=204" "$(head -1 <<<"$out" | cut -d' ' -f1)"
check "dry object gone" "0" "$([[ -f $DRYD/m/a1b2c3 ]] && echo 1 || echo 0)"
SHARE_R2_DRY_PAUSE="PUT m/paused" r2d r2-call PUT m/paused "$WORK/wt/one.md" >/dev/null 2>&1 &
ppid=$!
sleep 0.3
check "dry PAUSE knob holds the call" "0" "$([[ -f $DRYD/m/paused ]] && echo 1 || echo 0)"
sleep 0.6; : >"$DRYD/.resume"; wait "$ppid"
check "dry PAUSE resumes on the file" "1" "$([[ -f $DRYD/m/paused ]] && echo 1 || echo 0)"
rm -f "$DRYD/.resume"
out=$(env -u SHARE_R2_DRY -u SHARE_ROOT -u SHARE_CONFIG_DIR -u SHARE_PORT -u SHARE_HOSTNAME -u SHARE_SERVICE_LABEL -u XDG_CONFIG_HOME -u SHARE_PROFILE -u SHARE_BACKEND \
    HOME="$R2H" SHARE_TUNNEL=0 SHARE_R2_DRY_DIR="$DRYD" bash "$SH" --profile r2x r2-call GET m/x 2>&1); rc=$?
check "no dry seam means the live path" "1" "$rc"
check "live path names the missing token" "1" "$(grep -c 'no r2 publisher token' <<<"$out")"
out=$(env -u SHARE_ROOT -u SHARE_CONFIG_DIR -u SHARE_PORT -u SHARE_HOSTNAME -u SHARE_SERVICE_LABEL -u XDG_CONFIG_HOME -u SHARE_PROFILE -u SHARE_BACKEND \
    HOME="$R2H" SHARE_TUNNEL=1 SHARE_R2_DRY=1 SHARE_R2_DRY_DIR="$DRYD" bash "$SH" --profile r2x r2-call GET m/x 2>&1); rc=$?
check "dry seam refuses with the tunnel on" "1" "$rc"
check "the refusal names the seam" "1" "$(grep -c 'SHARE_R2_DRY=1 is a test seam' <<<"$out")"
out=$(r2d r2-call FROBNICATE m/x 2>&1); rc=$?
check "unknown dry method 400" "code=400" "$(head -1 <<<"$out" | cut -d' ' -f1)"
mkdir -p "$R2H/.config/share/profiles/tun"
printf 'hostname=tun.example.test\nport=8788\n' >"$R2H/.config/share/profiles/tun/config"
out=$(env -u SHARE_ROOT -u SHARE_CONFIG_DIR -u SHARE_PORT -u SHARE_HOSTNAME -u SHARE_SERVICE_LABEL -u XDG_CONFIG_HOME -u SHARE_PROFILE -u SHARE_BACKEND \
    HOME="$R2H" SHARE_TUNNEL=0 SHARE_R2_DRY=1 SHARE_R2_DRY_DIR="$DRYD" bash "$SH" --profile tun r2-call GET m/x 2>&1); rc=$?
check "r2-call refuses on a non-r2 profile" "1" "$rc"

echo "=== r2 backend: live transport, retries, secrets ==="
shimd="$WORK/shim"; mkdir -p "$shimd"
cat >"$shimd/curl" <<'SHIM'
#!/bin/bash
{ for a in "$@"; do printf '%s\n' "$a"; done; printf -- '---\n'; } >>"$SHIM_LOG"
nfile="$SHIM_LOG.count"
n=$(( $(cat "$nfile" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$nfile"
hdrs=""; prev=""
for a in "$@"; do [[ $prev == -D ]] && hdrs="$a"; prev="$a"; done
[[ -n $hdrs ]] && printf 'HTTP/1.1 200 OK\r\nRetry-After: 0\r\nETag: "deadbeef01"\r\n' >"$hdrs"
if [[ ${SHIM_ALWAYS:-0} == 1 ]]; then printf '<Error/>\n500'
elif [[ $n -lt 3 ]]; then printf '<Error/>\n429'
else printf 'body-ok\n200'; fi
SHIM
chmod +x "$shimd/curl"
r2l() { # r2l <verb...>: the r2 profile through the curl shim, sentinel token in the environment only
  env -u SHARE_R2_DRY -u XDG_CONFIG_HOME -u SHARE_ROOT -u SHARE_CONFIG_DIR -u SHARE_PORT -u SHARE_HOSTNAME -u SHARE_SERVICE_LABEL -u SHARE_PROFILE -u SHARE_BACKEND \
    HOME="$R2H" SHARE_TUNNEL=0 SHARE_R2_TOKEN='SentInelT0ken_zzz' SHIM_LOG="$WORK/shim.log" PATH="$shimd:$PATH" bash "$SH" --profile r2x "$@"
}
: >"$WORK/shim.log"; rm -f "$WORK/shim.log.count"
out=$(r2l r2-call PUT m/shim01 "$WORK/wt/one.md" 2>&1); rc=$?
check "shim: two 429s retried to a 200" "0" "$rc"
check "shim: final code 200" "code=200" "$(head -1 <<<"$out" | cut -d' ' -f1)"
check "shim: three calls for 429 429 200" "3" "$(grep -c '^---$' "$WORK/shim.log")"
check "shim: the url is endpoint bucket key" "3" "$(grep -c '^https://acct.example.r2.cloudflarestorage.com/ok-bucket/m/shim01$' "$WORK/shim.log")"
check "shim: sigv4 amz auto s3" "3" "$(grep -c '^aws:amz:auto:s3$' "$WORK/shim.log")"
check "shim: credential config is an fd" "3" "$(grep -A1 '^-K$' "$WORK/shim.log" | grep -c 'dev/fd')"
check "shim: sentinel never in argv" "0" "$(grep -c 'SentInelT0ken' "$WORK/shim.log")"
check "shim: sentinel never in output" "0" "$(grep -c 'SentInelT0ken' <<<"$out")"
check "shim: sentinel in no file under home" "0" "$(grep -rl 'SentInelT0ken' "$R2H" 2>/dev/null | wc -l | tr -d ' ')"
: >"$WORK/shim.log"; rm -f "$WORK/shim.log.count"
out=$(SHIM_ALWAYS=1 r2l r2-call GET m/x 2>&1); rc=$?
check "shim: persistent 500 gives up after three" "3" "$(grep -c '^---$' "$WORK/shim.log")"
check "shim: final code 500" "code=500" "$(head -1 <<<"$out" | cut -d' ' -f1)"

echo "=== r2 backend: put_tree, list, delete_prefix (row 26) ==="
rm -rf "$DRYD"; mkdir -p "$DRYD"   # the r2_call section above leaves objects behind
STG="$WORK/r2stage"; mkdir -p "$STG/sub"
printf 'a\n' >"$STG/a%b.txt"; printf 'q\n' >"$STG/q?.txt"; printf 'h\n' >"$STG/h#.txt"
printf 's\n' >"$STG/sp ace.txt"; printf 'd\n' >"$STG/sub/deep.txt"
: >"$rlog"
out=$(r2d r2-put-tree "$STG" 'o/a1b2c3.deadbeef/' 2>&1); rc=$?
check "put_tree exits 0" "0" "$rc"
out=$(r2d r2-list 'o/a1b2c3.' 2>&1)
check "put_tree: the prefix listing equals the stage tree" "o/a1b2c3.deadbeef/a%b.txt
o/a1b2c3.deadbeef/h#.txt
o/a1b2c3.deadbeef/q?.txt
o/a1b2c3.deadbeef/sp ace.txt
o/a1b2c3.deadbeef/sub/deep.txt" "$out"
check "put_tree: bytes round-trip" "q" "$(cat "$DRYD/o/a1b2c3.deadbeef/q?.txt")"
rm -rf "$DRYD/.fx"; : >"$rlog"
out=$(SHARE_R2_DRY_PUT=500-once r2d r2-put-tree "$STG" 'o/b1b2c3.deadbeef/' 2>&1); rc=$?
check "put_tree with one 500 transfer still exits 0" "0" "$rc"
check "put_tree: the failed transfer was retried alone" "2" "$(awk '$1=="PUT" && $2=="o/b1b2c3.deadbeef/a%b.txt"' "$rlog" | grep -c .)"
out=$(r2d r2-list 'o/b1b2c3.' 2>&1)
check "put_tree: the 500 retried file landed" "1" "$(grep -c 'a%b.txt' <<<"$out")"
mkdir -p "$DRYD/o/c1c2c3.aaaabbbb" "$DRYD/o/c1c2c3.ccccdddd"
printf 'x\n' >"$DRYD/o/c1c2c3.aaaabbbb/f.txt"; printf 'y\n' >"$DRYD/o/c1c2c3.ccccdddd/g.txt"
out=$(r2d r2-delete-prefix 'o/c1c2c3.' 2>&1); rc=$?
check "delete_prefix exits 0" "0" "$rc"
out=$(r2d r2-list 'o/c1c2c3.' 2>&1)
check "delete_prefix: no key under either nonce remains" "" "$out"
out=$(SHARE_R2_DRY_LIST=500 r2d r2-delete-prefix 'o/c1c2c3.' 2>&1); rc=$?
check "delete_prefix dies on a bad list page" "1" "$rc"

echo "=== r2 backend: snapshot, rows, rand_id (rows 25e, 27) ==="
mkdir -p "$DRYD/m"
printf '%s\n' '{"v":1,"id":"abc001","name":"report.html","src":"/tmp/report.html","added":"2026-09-30","expires":0,"opts":"noindex","prefix":"o/abc001.deadbeef/","by":"mini"}' >"$DRYD/m/abc001"
printf '%s\n' '{"v":1,"id":"zzz999","name":"x.txt","src":"/x","added":"2026-09-30","expires":0,"opts":"","prefix":"o/def002.deadbeef/","by":"mini"}' >"$DRYD/m/def002"   # id differs from its key
printf '%s\n' '{"v":1,"id":"def003","name":"x.txt","src":"/x","added":"2026-09-30","expires":0,"opts":"","prefix":"o/def003.deadbeef/","by":"mini"}' | jq -c '.name += "\u0001"' >"$DRYD/m/def003"   # a control character in name
printf '%s\n' '{"v":1,"id":"def004","name":"x.txt","src":"/x","added":"2026-09-30","expires":0,"opts":"","prefix":"o/def004.99/","by":"mini"}' >"$DRYD/m/def004"   # a bad prefix
printf '%s\n' '{"v":2,"id":"def005","name":"x.txt","src":"/x","added":"2026-09-30","expires":0,"opts":"","prefix":"o/def005.deadbeef/","by":"mini"}' >"$DRYD/m/def005"   # a newer record version
printf 'not json at all\n' >"$DRYD/m/def006"
printf '%s\n' '{"v":1,"id":"def007","name":"x.txt","src":"/x","added":"2026-09-30","expires":1e300,"opts":"","prefix":"o/def007.deadbeef/","by":"mini"}' >"$DRYD/m/def007"   # expires past epoch range
printf '%s\n' '{"v":1,"id":"def008","name":"x.txt","src":"/x","added":"2026-09-30","expires":0,"opts":"prefix=o/def008.00000000/","prefix":"o/def008.deadbeef/","by":"mini"}' >"$DRYD/m/def008"   # opts forge a prefix
out=$(r2d r2-rows 2>&1); rc=$?
check "r2-rows exits 0" "0" "$rc"
snap_path="$(sed -n 's/^index=//p' <<<"$out" | head -1)"
check "index names the snapshot file" "1" "$(grep -c 'share/profiles/r2x/.r2-index\.' <<<"$snap_path")"
snap_rows="$(grep -v '^index=' <<<"$out")"
check "rows() yields only the good record" "abc001" "$(cut -f1 <<<"$snap_rows")"
check "the row carries prefix and by" "1" "$(grep -c 'prefix=o/abc001.deadbeef/ by=mini' <<<"$snap_rows")"
check "the row keeps its opts" "1" "$(grep -c 'noindex prefix=' <<<"$snap_rows")"
out=$(r2d ls 2>&1)
check "ls shows the snapshot row with by=" "1" "$(grep -c 'by=mini' <<<"$out")"
check "ls prints the link" "1" "$(grep -c 'https://r2x.example.test/abc001/' <<<"$out")"
out=$(SHARE_TEST_IDS="abc001 eee001" r2d r2-id 2>&1)
check "rand_id skips an id with a record" "eee001" "$out"
mkdir -p "$DRYD/o/f1f2f3.00000001"; printf 'x\n' >"$DRYD/o/f1f2f3.00000001/leftover.txt"
out=$(SHARE_TEST_IDS="f1f2f3 eee002" r2d r2-id 2>&1)
check "rand_id skips an id with leftover objects" "eee002" "$out"
: >"$rlog"
out=$(SHARE_R2_DRY_LIST=500 r2d ls 2>&1); rc=$?
check "LIST 500: ls exits 1" "1" "$rc"
out=$(SHARE_R2_DRY_LIST=500 r2d r2-id 2>&1); rc=$?
check "LIST 500: rand_id dies, no id picked" "1" "$rc"
out=$(SHARE_R2_DRY_LIST=500 r2d add "$WORK/wt/one.md" 2>&1); rc=$?
check "LIST 500: add exits 1" "1" "$rc"
check "LIST 500: no object write was attempted" "0" "$(grep -c '^PUT ' "$rlog" || true)"

echo "=== r2 backend: r2-own ==="
r2d r2-own put abc001 'o/abc001.deadbeef/' '/tmp/report.html'
r2d r2-own put abc002 'o/abc002.00000001/' '/tmp/two'
r2d r2-own put abc001 'o/abc001.cafebabe/' '/tmp/report.html'
out=$(r2d r2-own get abc001)
check "r2-own: a refresh replaces the line" "abc001	o/abc001.cafebabe/	/tmp/report.html" "$out"
check "r2-own: one line per id" "2" "$(wc -l <"$R2H/share/profiles/r2x/r2-own" | tr -d ' ')"
r2d r2-own put abc003 'o/abc009.00000001/' '/tmp/three'
check "r2-own: a prefix naming another id is not returned" "" "$(r2d r2-own get abc003 || true)"
r2d r2-own drop abc001
check "r2-own: drop forgets the id" "" "$(r2d r2-own get abc001 || true)"
check "r2-own: drop keeps the others" "1" "$(r2d r2-own get abc002 | grep -c '/tmp/two')"

echo "=== r2 backend: admin setup (rows 3, 4, 20) ==="
wv="$(sed -n 's/^WORKER_VERSION=\([0-9]*\).*/\1/p' "$SH")"; wsha="$(sed -n 's/^WORKER_SHA=\([0-9a-f]*\).*/\1/p' "$SH")"
DRYS="$WORK/r2-setup-bucket"
s2conf="$R2H/.config/share/profiles/r2s/config"; slog="$R2H/share/profiles/r2s/r2-calls.log"
r2s() { # r2s <setup args...>: dry admin setup of profile r2s against $DRYS
  env -u SHARE_ROOT -u SHARE_CONFIG_DIR -u SHARE_PORT -u SHARE_HOSTNAME -u SHARE_SERVICE_LABEL -u XDG_CONFIG_HOME -u SHARE_PROFILE -u SHARE_BACKEND \
    HOME="$R2H" SHARE_TUNNEL=0 SHARE_R2_DRY=1 SHARE_R2_DRY_DIR="$DRYS" CLOUDFLARE_API_TOKEN="${S_TOKEN-faketoken}" SHARE_R2_WAIT="${SHARE_R2_WAIT:-2}" \
    bash "$SH" --profile r2s setup r2s.example.test --backend r2 --bucket ok-bucket "$@"
}
s_fresh() { rm -rf "$DRYS" "$s2conf"; mkdir -p "$DRYS/.cf"; : >"$slog" 2>/dev/null || { mkdir -p "${slog%/*}"; : >"$slog"; }; }
lno() { grep -n -- "$1" "$slog" | head -1 | cut -d: -f1; }   # first log line matching a pattern
in_order() { # in_order <pattern>...: 1 when each first match sits below the previous one
  local p prev=0 n
  for p in "$@"; do n="$(lno "$p")"; [[ -n $n && $n -gt $prev ]] || { echo 0; return; }; prev=$n; done
  echo 1
}
writes() { grep -cE '^(API (PUT|POST|DELETE) |PUT |DELETE )' "$slog" || true; }
objs() { (cd "$DRYS" && find . -type f ! -path './.cf/*' | LC_ALL=C sort | xargs -I{} sh -c 'printf "%s " "{}"; cat "{}"'); }
bind() { jq -r --arg n "$1" '.bindings[] | select(.name == $n) | .text' "$DRYS/.cf/script.json"; }

s_fresh
out=$(S_TOKEN="" r2s 2>&1); rc=$?
check "no token: exit 1" "1" "$rc"
check "no token: the block names the admin scopes" "1" "$(grep -c 'Workers Scripts: Edit' <<<"$out")"
check "no token: the block names the publisher form" "1" "$(grep -c 'Bucket Item Write on bucket ok-bucket' <<<"$out")"
check "no token: no call logged" "0" "$(wc -l <"$slog" | tr -d ' ')"

s_fresh; echo dwarves.cloudflareaccess.com >"$DRYS/.cf/team"
out=$(r2s 2>&1); rc=$?
check "admin setup exits 0" "0" "$rc"
check "admin: role printed" "1" "$(grep -c '^deploying as admin$' <<<"$out")"
check "admin: log order, every read before the first write" "1" "$(in_order 'API GET .*/workers/scripts/share-r2s-example-test/settings' \
  'API GET .*/r2/buckets/ok-bucket$' 'API GET /zones/zone-dry/dns_records' 'API GET .*/workers/domains?hostname=' 'API GET .*/access/organizations' \
  'API POST .*/r2/buckets$' '^PUT share.json$' 'API PUT .*/workers/scripts/share-r2s-example-test$' 'API POST .*/subdomain$' 'API GET .*/subdomain$' \
  'API PUT .*/workers/domains$' '^HEALTHZ$')"
check "admin: marker names the host" '{"v":1,"host":"r2s.example.test"}' "$(cat "$DRYS/share.json")"
check "admin: config backend" "1" "$(grep -c '^backend=r2$' "$s2conf")"
check "admin: config bucket" "1" "$(grep -c '^bucket=ok-bucket$' "$s2conf")"
check "admin: config port sentinel" "1" "$(grep -c '^port=r2$' "$s2conf")"
check "admin: config endpoint" "1" "$(grep -c '^r2_endpoint=https://acct-dry.r2.cloudflarestorage.com$' "$s2conf")"
check "admin: no tunnel keys in config" "0" "$(grep -cE '^(tunnel_id|tunnel_name|hosts|auth)=' "$s2conf" || true)"
check "admin: no service file" "0" "$(find "$R2H/Library" "$R2H/.config/systemd" -name '*share*' 2>/dev/null | wc -l | tr -d ' ')"
check "admin: HOST binding" "r2s.example.test" "$(bind HOST)"
check "admin: VERSION and SHA bindings are this CLI's" "$wv $wsha" "$(bind VERSION) $(bind SHA)"
check "admin: TEAM from the Access organization" "dwarves.cloudflareaccess.com" "$(bind TEAM)"
check "admin: dataset derived" "share_r2s_example_test" "$(jq -r '.bindings[] | select(.name == "HITS") | .dataset' "$DRYS/.cf/script.json")"
check "admin: SALT is a secret binding with no stored value" "1" "$(jq '[.bindings[] | select(.name == "SALT" and .type == "secret_text" and (has("text") | not))] | length' "$DRYS/.cf/script.json")"
check "admin: workers.dev read back off" "false,false" "$(jq -r '"\(.enabled),\(.previews_enabled)"' "$DRYS/.cf/subdomain.json")"

: >"$slog"
out=$(r2s 2>&1); rc=$?
check "rerun: exit 0" "0" "$rc"
check "rerun: no script PUT" "0" "$(grep -c 'API PUT .*/workers/scripts/' "$slog" || true)"
check "rerun: no domain PUT, no bucket POST, no marker PUT" "0" "$(grep -cE 'API PUT .*/workers/domains$|API POST .*/r2/buckets$|^PUT share.json$' "$slog" || true)"
check "rerun: the existing bucket's reads come first" "1" "$(in_order 'API GET .*/r2/buckets/ok-bucket$' 'domains/managed' 'domains/custom' '^LIST $' '^GET share.json$' 'API GET /zones/zone-dry/dns_records')"

jq -c '(.bindings[] | select(.name == "SHA")).text = "000000000000"' "$DRYS/.cf/script.json" >"$DRYS/.cf/s.tmp" && mv -f "$DRYS/.cf/s.tmp" "$DRYS/.cf/script.json"
: >"$slog"
out=$(r2s 2>&1); rc=$?
check "new sha, same version: exit 0" "0" "$rc"
check "new sha: one script PUT" "1" "$(grep -c 'API PUT .*/workers/scripts/share-r2s-example-test$' "$slog")"
check "new sha: the deployed pair is this CLI's" "$wv $wsha" "$(bind VERSION) $(bind SHA)"

rm -f "$DRYS/.cf/team"; : >"$slog"
out=$(r2s 2>&1); rc=$?
check "no Access read: exit 0" "0" "$rc"
check "no Access read: the deployed TEAM is kept, no redeploy" "dwarves.cloudflareaccess.com 0" "$(bind TEAM) $(grep -c 'API PUT .*/workers/scripts/' "$slog" || true)"
echo other.cloudflareaccess.com >"$DRYS/.cf/team"; : >"$slog"
out=$(r2s 2>&1); rc=$?
check "TEAM drift: redeployed with the new team" "other.cloudflareaccess.com 1" "$(bind TEAM) $(grep -c 'API PUT .*/workers/scripts/' "$slog")"
check "TEAM drift: printed" "1" "$(grep -c "Access team: 'dwarves.cloudflareaccess.com' -> 'other.cloudflareaccess.com'" <<<"$out")"

jq -c '(.bindings[] | select(.name == "VERSION")).text = "99"' "$DRYS/.cf/script.json" >"$DRYS/.cf/s.tmp" && mv -f "$DRYS/.cf/s.tmp" "$DRYS/.cf/script.json"
: >"$slog"
out=$(r2s 2>&1); rc=$?
check "newer deployed version: refused" "1" "$rc"
check "newer: names --force" "1" "$(grep -c 'newer than this share' <<<"$out")"
check "newer: no write logged" "0" "$(writes)"
: >"$slog"
out=$(r2s --force 2>&1); rc=$?
check "newer with --force: exit 0" "0" "$rc"
check "newer with --force: one script PUT back to this CLI's version" "1 $wv" "$(grep -c 'API PUT .*/workers/scripts/' "$slog") $(bind VERSION)"

s_refuse() { # s_refuse <label> <message> [setup args...]: after fixtures are set, setup dies naming <message>, writes nothing
  local before; before="$(objs)"; : >"$slog"
  out=$(r2s "${@:3}" 2>&1); rc=$?
  check "refuse $1: exit 1" "1" "$rc"
  check "refuse $1: named" "1" "$(grep -c -- "$2" <<<"$out")"
  check "refuse $1: no write logged" "0" "$(writes)"
  check "refuse $1: bucket unchanged" "$before" "$(objs)"
  check "refuse $1: no config" "0" "$([[ -f $s2conf ]] && echo 1 || echo 0)"
}
s_fresh; : >"$DRYS/.cf/bucket"; echo x >"$DRYS/foreign.txt"
s_refuse "foreign objects" "not a share bucket"
s_fresh; : >"$DRYS/.cf/bucket"; printf '{"v":1,"host":"other.example.test"}\n' >"$DRYS/share.json"
s_refuse "marker for another host" "names another hostname"
s_fresh; : >"$DRYS/.cf/bucket"; : >"$DRYS/.cf/r2dev"
s_refuse "r2.dev on" "public r2.dev URL"
s_fresh; : >"$DRYS/.cf/bucket"; : >"$DRYS/.cf/bucket-domain"
s_refuse "bucket custom domain" "public custom domain"
s_fresh; echo '[{"type":"A","name":"r2s.example.test"}]' >"$DRYS/.cf/dns"
s_refuse "a DNS record" "already has a DNS record"
s_fresh; echo '{"hostname":"r2s.example.test","service":"df-memo"}' >"$DRYS/.cf/domain.json"
s_refuse "another Worker's domain, even with --force" "custom domain of another Worker" --force
s_fresh; echo '{"bindings":[{"type":"plain_text","name":"HOST","text":"other.example.test"},{"type":"r2_bucket","name":"BUCKET","bucket_name":"ok-bucket"},{"type":"plain_text","name":"VERSION","text":"1"}]}' >"$DRYS/.cf/script.json"
s_refuse "a script bound to another host" "not share's Worker"
s_fresh
SHARE_R2_DRY_DOMAINS=500 s_refuse "a 500 on the domains read" "custom domains answered HTTP 500"
s_fresh; : >"$slog"
out=$(SHARE_R2_DRY_SUBDOMAIN=stuck r2s 2>&1); rc=$?
check "subdomain read-back on: exit 1" "1" "$rc"
check "subdomain read-back on: named" "1" "$(grep -c 'still reads on' <<<"$out")"
check "subdomain read-back on: no domain PUT" "0" "$(grep -c 'API PUT .*/workers/domains' "$slog" || true)"
check "subdomain read-back on: no config" "0" "$([[ -f $s2conf ]] && echo 1 || echo 0)"
s_fresh
out=$(SHARE_R2_DRY_HEALTHZ=down SHARE_R2_WAIT=1 r2s 2>&1); rc=$?
check "healthz never up: exit 1" "1" "$rc"
check "healthz never up: names the host" "1" "$(grep -c 'https://r2s.example.test/healthz did not answer' <<<"$out")"
check "healthz never up: no config" "0" "$([[ -f $s2conf ]] && echo 1 || echo 0)"
rm -f "$s2conf"

echo "=== worker (tests/worker.mjs) ==="
if command -v node >/dev/null; then
  wout="$(node "$(dirname "$SH")/../tests/worker.mjs" 2>&1)"; wrc=$?
  echo "$wout"
  check "worker.mjs exits 0" "0" "$wrc"
else
  if [[ ${CI:-} == true ]]; then check "node installed for worker.mjs" "yes" "missing"
  else echo "  SKIP  no node on PATH; worker.mjs skipped"; fi
fi

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
# only an ORPHANED idler counts: a live serve's fake tunnel is still its own child (see the
# orphaned-prune-sleep comment below); this is what keeps a second suite's own idler off this count.
check "no fake tunnel idlers" "0" "$(ps -eo ppid,command | awk '$1==1 && $2=="sleep" && $3=="600"' | grep -c . || true)"
# only an ORPHANED sleep counts: a live service's prune loop keeps its own
check "no orphaned prune sleeps" "0" "$(ps -eo ppid,command | awk '$1==1 && $2=="sleep" && $3=="3600"' | grep -c . || true)"
check "serve.pid removed" "0" "$([[ -f $SHARE_ROOT/serve.pid ]] && echo 1 || echo 0)"
# The stubs above keep every service verb off the real launchd and systemd; this is the
# proof. A job listed here and not before the run was bootstrapped from a fake HOME.
check "no real launchd or systemd share job appeared during the run" "$jobs_before" "$(real_jobs)"

echo
if [[ $fails -gt 0 ]]; then
  echo "$fails FAILED"
  for log in serve.log caddy.log; do
    echo "--- $log"; tail -20 "$SHARE_ROOT/$log" 2>/dev/null
  done
  exit 1
fi
echo "PASS"
