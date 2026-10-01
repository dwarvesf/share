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
# The highest port the run uses is base+10009 (the live-port share), so the base tops out at 55526.
(( base > 55526 )) && { echo "SHARE_TEST_PORT_BASE=$base clamped to 55526 so base+10009 stays a valid port" >&2; base=55526; }
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
# The same holds for credentials: a fake HOME does not hide the login Keychain, so a token-free
# check once found a real share-api:<host> item on the machine and swept with it. The security
# stub answers as an empty keychain and logs the verb and -s service of every call (never a value),
# so a check can prove a lookup landed here; op answers signed out. A section that wants a stored
# token puts its own fake security first on PATH.
cat >"$WORK/stubsvc/security" <<'EOF'
#!/bin/bash
svc=""; prev=""; for a in "$@"; do [[ $prev == -s ]] && svc="$a"; prev="$a"; done
echo "$1 $svc" >>"${STUBSEC_LOG:?}"
[[ $1 == -i ]] && cat >/dev/null
[[ $1 == find-* || $1 == delete-* ]] && exit 44
exit 0
EOF
printf '#!/bin/bash\necho "op: stubbed by tests/share.sh (signed out)" >&2\nexit 1\n' >"$WORK/stubsvc/op"
chmod +x "$WORK/stubsvc/launchctl" "$WORK/stubsvc/systemctl" "$WORK/stubsvc/security" "$WORK/stubsvc/op"
export STUBSEC_LOG="$WORK/stubsec.log"; : >"$STUBSEC_LOG"
real_security="$(command -v security || true)"
real_keychain_share() { # service name and modify date of every share* item in the real keychain, never a value
  [[ -n $real_security ]] && "$real_security" dump-keychain 2>/dev/null |
    awk '/^keychain: /{m=""} /"mdat"<timedate>/{m=$NF} /"svce"<blob>="share/{sub(/.*<blob>=/, ""); print $0, m}' | sort
}
keychain_before="$(real_keychain_share)"
export PATH="$WORK/stubsvc:$PATH"
fix_pid=""
fails=0
total=0
reached_end=0
on_exit() { # a crash or an interrupt leaves reached_end unset, so this never reports a clean summary for a run that never finished
  local rc=$?
  bash "$SH" stop >/dev/null 2>&1
  [[ -n ${fix_pid:-} ]] && kill "$fix_pid" 2>/dev/null
  rm -rf "$WORK"
  if [[ ${reached_end:-0} != 1 ]]; then
    echo "ABORTED after ${total:-0} check(s), ${fails:-0} failed so far" >&2
    exit 2
  fi
  exit "$rc"
}
trap on_exit EXIT

check() { # check <label> <expected> <actual>
  total=$((total + 1))
  if [[ $2 == "$3" ]]; then echo "  ok    $1"; else echo "  FAIL  $1: expected '$2', got '$3'"; fails=$((fails + 1)); fi
}
# share-test-abort-anchor: a truncation of this file ending here (everything above runs,
# nothing below) must still make on_exit report ABORTED and exit 2, never a clean summary
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
ls_url=$(bash "$SH" ls | grep -B1 "id=$hash_id" | head -1 | grep -o 'https://.*')
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

echo "--- share profiles --json: every profile's state in one call ---"
marker="$WORK/json.marker"; touch "$marker"; sleep 0.2
psh a profiles --json >"$WORK/profiles.json"
check "profiles --json exits 0" "0" "$?"
check "profiles --json output parses" "0" "$(jq -e . "$WORK/profiles.json" >/dev/null 2>&1; echo $?)"
check "profiles --json schema is 1" "1" "$(jq -r .schema "$WORK/profiles.json")"
check "profiles --json names in listing order" "default a b" "$(jq -r '[.profiles[].name] | join(" ")' "$WORK/profiles.json")"
for p in default a b; do
  own="$(env -u SHARE_ROOT -u SHARE_CONFIG_DIR -u SHARE_PORT -u SHARE_HOSTNAME -u SHARE_HOSTS -u SHARE_SERVICE_LABEL -u XDG_CONFIG_HOME \
    HOME="$PHOME" SHARE_LIVE_CHECK=0 SHARE_TUNNEL=1 PATH="$QPATH" SHARE_PROFILE="$p" bash "$SH" state)"
  check "profiles --json: $p's state equals its own share state" "true" \
    "$(jq --arg name "$p" --argjson own "$own" -r '[.profiles[] | select(.name == $name) | .state == $own][0]' "$WORK/profiles.json")"
done
check "profiles --json wrote nothing under HOME" "0" "$(find "$PHOME" -newer "$marker" | wc -l | tr -d ' ')"
out=$(psh a profiles --bogus 2>&1); rc=$?
check "profiles --bogus exits 1" "1" "$rc"
check "profiles --bogus prints the usage" "share: usage: share profiles [--json]" "$out"
out=$(psh a profiles --json --bogus 2>&1); rc=$?
check "profiles --json plus a second arg exits 1" "1" "$rc"
check "plain profiles is still the TSV listing" "$(printf 'default\tnot_setup\t-\na\tserving\tprof-a.trycloudflare.com\nb\tserving\tprof-b.trycloudflare.com')" "$(psh a profiles)"
# an exported SHARE_ROOT must not leak into the JSON children either: the listing is the same
env -u SHARE_CONFIG_DIR -u SHARE_PORT -u SHARE_HOSTNAME -u SHARE_SERVICE_LABEL -u XDG_CONFIG_HOME HOME="$PHOME" SHARE_ROOT="$WORK/elsewhere" \
  SHARE_LIVE_CHECK=0 SHARE_TUNNEL=1 PATH="$QPATH" bash "$SH" --profile a profiles --json >"$WORK/profiles-root.json"
check "profiles --json ignores an exported SHARE_ROOT" "$(jq -Sc . "$WORK/profiles.json")" "$(jq -Sc . "$WORK/profiles-root.json")"

echo "--- profiles --json: a bad slug, a quote in a name, and profiles/default are error entries ---"
mkdir -p "$PHOME/.config/share/profiles/Bad" "$PHOME/.config/share/profiles/default" "$PHOME/.config/share/profiles/a\"b"
psh a profiles --json >"$WORK/profiles-badnames.json"
check "profiles --json with bad names exits 0 and parses" "0" "$(jq -e . "$WORK/profiles-badnames.json" >/dev/null 2>&1; echo $?)"
check "profiles --json: Bad is an error entry" "share: bad profile name 'Bad' (a-z, 0-9, -; 32 chars max)" \
  "$(jq -r '.profiles[] | select(.name == "Bad") | .error' "$WORK/profiles-badnames.json")"
check "profiles --json: a quote in a name stays one escaped entry" "share: bad profile name 'a\"b' (a-z, 0-9, -; 32 chars max)" \
  "$(jq -r '.profiles[] | select(.name == "a\"b") | .error' "$WORK/profiles-badnames.json")"
check "profiles --json: profiles/default is the reserved-name entry" "reserved name; rename or remove $PHOME/.config/share/profiles/default" \
  "$(jq -r '.profiles[] | select(.name == "profiles/default") | .error' "$WORK/profiles-badnames.json")"
check "profiles --json: exactly one entry is named default" "1" "$(jq '[.profiles[] | select(.name == "default")] | length' "$WORK/profiles-badnames.json")"
check "profiles --json: the good profiles still carry state" "3" "$(jq '[.profiles[] | select(.state != null)] | length' "$WORK/profiles-badnames.json")"
rmdir "$PHOME/.config/share/profiles/Bad" "$PHOME/.config/share/profiles/default" "$PHOME/.config/share/profiles/a\"b"

echo "--- the child-env strip lists agree between bash and Swift ---"
MAC_CLI="$(cd "$(dirname "$0")/.." && pwd)/mac/Sources/ShareBarCore/CLI.swift"
bash_list="$(sed -n '/^profiles_child_env()/,/^}/p' "$SH" | grep -o '\-u [A-Z_]*' | awk '{print $2}' | sort -u | tr '\n' ' ' | sed 's/ $//')"
swift_list="$(sed -n '/static let strippedEnvironmentKeys/,/^ *\]$/p' "$MAC_CLI" | grep -o '"SHARE_[A-Z_]*"' | tr -d '"' | grep -v '^SHARE_PROFILE$' | sort -u | tr '\n' ' ' | sed 's/ $//')"
check "the env -u list and the Swift strip list name the same overrides" "$bash_list" "$swift_list"

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

echo "--- the service PATH keeps the caller's own precedence (a stub ahead of /usr/bin must stay ahead) ---"
mkdir -p "$WORK/svcpath-stub"
printf '#!/bin/bash\nexit 0\n' >"$WORK/svcpath-stub/security"
chmod +x "$WORK/svcpath-stub/security"
env -u SHARE_ROOT -u SHARE_CONFIG_DIR -u SHARE_PORT -u SHARE_HOSTNAME -u SHARE_SERVICE_LABEL -u XDG_CONFIG_HOME \
  HOME="$PHOME" SHARE_LIVE_CHECK=0 SHARE_TUNNEL=1 PATH="$WORK/svcpath-stub:$QPATH" bash "$SH" --profile c service install >/dev/null 2>&1
svc_file=""
for f in "$PHOME/Library/LaunchAgents/foundation.d.share.c.plist" "$PHOME/.config/systemd/user/foundation.d.share.c.service"; do [[ -f $f ]] && svc_file="$f"; done
pathval="$(grep -oE 'PATH</key><string>[^<]*|PATH=[^ "]*' "$svc_file" 2>/dev/null | head -1)"
check "the baked service PATH keeps a caller stub dir ahead of /usr/bin, never the fixed tool-list order" "1" \
  "$([[ $pathval == *"$WORK/svcpath-stub"*"/usr/bin"* ]] && echo 1 || echo 0)"
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
  ls_url=$(grep -B1 "id=$id" <<<"$ls_out" | head -1 | grep -o 'https://.*')
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
: >"$STUBSEC_LOG"
out=$(env -u CLOUDFLARE_API_TOKEN SHARE_ACCESS_DRY=1 bash "$SH" prune 2>&1 1>/dev/null); rc=$?
check "prune without a token: exit 0, names the deferred app" "1" "$([[ $rc == 0 ]] && grep -c "Access app for $d_id awaits deletion; run 'share prune' with a token (the stored one, or CLOUDFLARE_API_TOKEN)" <<<"$out")"
check "prune without a token: row and bytes gone" "1" "$([[ -z $(row_of "$d_id") && ! -e $SHARE_ROOT/pub/$d_id ]] && echo 1 || echo 0)"
check "prune without a token: the app waits in access-pending" "1" "$(grep -c "^$d_id	$d_app	" "$apending")"
check "prune without a token: no DELETE" "0" "$(grep -c 'DELETE app' "$alog")"
check "prune without a token: the Keychain lookup hit the stub, not the real keychain" "1" "$(grep -c "^find-generic-password share-api:$SHARE_HOSTNAME$" "$STUBSEC_LOG")"
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
set timeout 60
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
  prompt_count=$(grep -c 'Paste the new token (input hidden):' <<<"$tty_out")
  echo_count=$(grep -c 'tty-token' <<<"$tty_out")
  check "tty: the prompt appeared and the token did not echo" "prompt-seen=1 token-echoed=0" "prompt-seen=$prompt_count token-echoed=$echo_count"
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
check "skill teaches the r2 backend" "1" "$(bash "$SH" skill | grep -c -- 'setup <hostname> --backend r2 --bucket <name>. | An R2 profile')"
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
  check "$verb names no local server" "1" "$(grep -c 'nothing runs on this machine' <<<"$out")"
done
out=$(r2p service install 2>&1); rc=$?
check "r2 profile: service install refuses" "1" "$rc"
check "install names no local server" "1" "$(grep -c 'nothing runs on this machine' <<<"$out")"
out=$(r2p teardown --purge 2>&1 </dev/null); rc=$?
check "r2 profile: teardown without --yes refuses" "1" "$rc"
check "the teardown refusal names --yes --purge" "1" "$(grep -c "rerun 'share --profile r2x teardown --yes --purge' to confirm" <<<"$out")"
out=$(r2p add 9999 2>&1); rc=$?
check "r2 profile: live add refuses" "1" "$rc"
check "live add names the tunnel profile" "1" "$(grep -c 'live shares and --host need a tunnel profile' <<<"$out")"
out=$(r2p add "$WORK/wt/one.md" --host hh.example.test 2>&1); rc=$?
check "r2 profile: --host add refuses" "1" "$rc"
check "--host add names the tunnel profile" "1" "$(grep -c 'live shares and --host need a tunnel profile' <<<"$out")"
out=$(CLOUDFLARE_API_TOKEN="" r2p add "$WORK/wt/one.md" 2>&1); rc=$?
check "r2 profile: add with no token source refuses" "1" "$rc"
check "the no-token block names api-token" "1" "$(grep -c 'needs a publisher token' <<<"$out")"
check "no root, so nothing was staged or written" "0" "$([[ -d $R2H/share/profiles/r2x ]] && echo 1 || echo 0)"
out=$(r2p setup other.example.test 2>&1); rc=$?
check "tunnel setup on an r2 profile refuses" "1" "$rc"
check "names the r2 backend" "1" "$(grep -c 'set up with the r2 backend' <<<"$out")"
out=$(r2p setup --quick 2>&1); rc=$?
check "quick setup on an r2 profile refuses" "1" "$rc"
rm -f "$r2conf"

echo "=== r2 backend: an older share refuses an r2 profile (compat) ==="
# v0.7.1 is the last release without the r2 backend; origin/main learned r2 once it merged
main_bin="$WORK/share-main" old_bin="$WORK/share-v0.7.1"
git -C "$(dirname "$SH")/.." show origin/main:bin/share >"$main_bin" 2>/dev/null || : >"$main_bin"
if git -C "$(dirname "$SH")/.." show v0.7.1:bin/share >"$old_bin" 2>/dev/null; then
  R22="$WORK/r22home"; mkdir -p "$R22/.config/share/profiles/r2x"
  printf 'backend=r2\nhostname=r2x.example.test\nzone=example.test\nbucket=ok-bucket\nport=r2\n' >"$R22/.config/share/profiles/r2x/config"
  r22() { # r22 <verb...>: v0.7.1's share against the r2 profile
    env -u SHARE_ROOT -u SHARE_CONFIG_DIR -u SHARE_PORT -u SHARE_HOSTNAME -u SHARE_SERVICE_LABEL -u XDG_CONFIG_HOME -u SHARE_PROFILE -u SHARE_BACKEND \
      HOME="$R22" SHARE_TUNNEL=0 bash "$old_bin" --profile r2x "$@"
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
  [[ ${CI:-} == true ]] && check "tag v0.7.1 fetched for the compat row" "yes" "missing"
  echo "  SKIP  tag v0.7.1 not fetched; compat rows skipped"
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
    env "${envs[@]}" bash "$bin" profiles --json >"$out/profiles.out" 2>"$out/profiles.err"
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
  check "row 1: ls tags each link (machine or live), its type, and by=" "$(grep -c . "$WORK/compat-new/index.tsv") 1" \
    "$(grep -cE '^(machine|live) +[a-z]+ +by=[a-z0-9.-]+  https://' "$WORK/compat-new/ls.out") $(grep -cE '^live +site +by=' "$WORK/compat-new/ls.out")"
  check "row 1: state rows gain storage, type, by; the top gains r2: false" "machine false" \
    "$(jq -r '([.shares[] | select(.type and .by) | .storage] | unique | join(" ")) + " " + (.r2 | tostring)' "$WORK/compat-new/state.out")"
  for c in main new; do   # the listing additions are the one allowed difference
    sed -i.bak -E 's/^(machine|live|cloud) +[a-z]+ +by=[a-z0-9.-]+  (https:)/\2/' "$WORK/compat-$c/ls.out"
    jq -S 'del(.r2, .storage_default, .cloud_error, .cloud_more) | .shares |= map(del(.storage, .type, .by))' "$WORK/compat-$c/state.out" >"$WORK/compat-$c/state.tmp" && mv -f "$WORK/compat-$c/state.tmp" "$WORK/compat-$c/state.out"
    jq -S '.profiles |= map(if .state then .state |= (del(.r2, .storage_default, .cloud_error, .cloud_more) | .shares |= map(del(.storage, .type, .by))) else . end)' "$WORK/compat-$c/profiles.out" >"$WORK/compat-$c/p.tmp" && mv -f "$WORK/compat-$c/p.tmp" "$WORK/compat-$c/profiles.out"
    # another allowed difference: svc_path (TASK-7b) now walks the caller's own PATH directories in
    # their own order instead of resolving each tool from a fixed list, so a plist's baked PATH value
    # reorders even though the directory set is the same; normalize it like the binary's own path above
    find "$WORK/compat-$c" -name '*.plist' -exec sed -i.bak -E 's#(<key>PATH</key><string>)[^<]*(</string>)#\1PATH\2#' {} + 2>/dev/null
    find "$WORK/compat-$c" -name '*.bak' -delete 2>/dev/null
    rm -f "$WORK/compat-$c/ls.out.bak"
  done
  check "row 1: every artifact byte-identical but the listing additions" "" "$(diff -r "$WORK/compat-main" "$WORK/compat-new" 2>&1)"
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
: >"$WORK/shim.log"; rm -f "$WORK/shim.log.count"
SHARE_STATE_BRIEF=1 r2l state >/dev/null 2>&1
check "shim: the healthz probe resolves over DoH first (a new name's NXDOMAIN may sit in the local cache)" "2" "$(awk '/^---$/ {exit} {print}' "$WORK/shim.log" | grep -c -e '^--doh-url$' -e '/healthz$')"

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
check "ls shows the snapshot row with by=" "1" "$(grep -c '^    id=.*by=mini' <<<"$out")"
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
out=$(SHARE_R2_TOKEN=drytoken SHARE_R2_DRY_LIST=500 r2d add "$WORK/wt/one.md" 2>&1); rc=$?
check "LIST 500: add exits 1" "1" "$rc"
check "LIST 500: add dies in the id check, no id picked" "1" "$(grep -c 'prefix check for .* failed (HTTP 500); no id was picked' <<<"$out")"
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

echo "=== r2 backend: add (rows 5, 6) ==="
DRYA="$WORK/r2-add-bucket"; mkdir -p "$DRYA"
r2a() { # r2a <verb...>: the r2x profile on its own dry bucket with a publisher token source
  env -u SHARE_ROOT -u SHARE_CONFIG_DIR -u SHARE_PORT -u SHARE_HOSTNAME -u SHARE_SERVICE_LABEL -u XDG_CONFIG_HOME -u SHARE_PROFILE -u SHARE_BACKEND \
    HOME="$R2H" SHARE_TUNNEL=0 SHARE_R2_DRY=1 SHARE_R2_DRY_DIR="$DRYA" SHARE_R2_TOKEN="${R2_TOK-drytoken}" bash "$SH" --profile r2x "$@"
}
r2root="$R2H/share/profiles/r2x"
aline() { grep -n -- "$1" "$rlog" | head -1 | cut -d: -f1; }
alast() { grep -n -- "$1" "$rlog" | tail -1 | cut -d: -f1; }
AF="$WORK/r2fold/deck"; mkdir -p "$AF/sub"
for n in 'a%b.txt' 'q?.txt' 'h#.txt' 'sp ace.txt'; do printf '%s\n' "$n" >"$AF/$n"; done
printf '# Deck\n' >"$AF/README.md"; printf 'SECRET=1\n' >"$AF/.env"; ln -s /etc/hosts "$AF/hosts-link"; printf 'z\n' >"$AF/sub/z.txt"
: >"$rlog"
out=$(SHARE_TEST_IDS=add001 r2a add "$AF" 2>/dev/null); rc=$?
check "row 5: folder add exits 0" "0" "$rc"
check "row 5: the link is https://<host>/<id>/<name>/" "https://r2x.example.test/add001/deck/" "$(head -1 <<<"$out")"
anonce="$(sed -n 's/^PUT o\/add001\.\([0-9a-f]\{8\}\)\/.*/\1/p' "$rlog" | head -1)"
check "row 5: the prefix is o/<id>.<8 hex>/" "1" "$(grep -c '^[0-9a-f]\{8\}$' <<<"$anonce")"
alist="$(cd "$DRYA/o/add001.$anonce" 2>/dev/null && find . -type f | sed 's|^\./||' | LC_ALL=C sort | tr '\n' '|')"
if command -v pandoc >/dev/null; then want5="README.html|README.md|a%b.txt|h#.txt|q?.txt|sp ace.txt|sub/z.txt|"
else want5="README.md|a%b.txt|h#.txt|index.html|q?.txt|sp ace.txt|sub/z.txt|"; fi
check "row 5: the prefix holds the stage tree (no dotfile, no symlink, the four names intact)" "$want5" "$(sed 's/deck\///g' <<<"$alist")"
check "row 5: every object PUT precedes PUT m/<id>" "1" "$([[ -n $(aline '^PUT m/add001$') && $(alast '^PUT o/') -lt $(aline '^PUT m/add001$') ]] && echo 1 || echo 0)"
check "row 5: the prefix listing is read back before the publish" "1" "$([[ $(alast '^LIST o/add001\.') -lt $(aline '^PUT m/add001$') ]] && echo 1 || echo 0)"
check "row 5: the record" "1 add001 deck o/add001.$anonce/ " "$(jq -r '"\(.v) \(.id) \(.name) \(.prefix) \(.opts)"' "$DRYA/m/add001")"
check "row 5: the record's by= passes rows()" "1" "$(jq -r '.by' "$DRYA/m/add001" | grep -c '^[a-z0-9.-]*$')"
check "row 5: no pub/ tree" "0" "$([[ -e $r2root/pub ]] && echo 1 || echo 0)"
check "row 5: no stage left" "0" "$(find "$r2root" -maxdepth 1 -name '.stage.*' | grep -c . || true)"
check "row 5: r2-own names the prefix and source" "add001	o/add001.$anonce/	$(realpath "$AF")" "$(r2a r2-own get add001)"
printf 'note\n' >"$WORK/note.txt"
out=$(SHARE_TEST_IDS=add002 r2a add --ttl 7d "$WORK/note.txt" 2>/dev/null); rc=$?
check "row 5: a file add links the file" "0 https://r2x.example.test/add002/note.txt" "$rc $(head -1 <<<"$out")"
check "row 5: a file add's expiry is seven days out" "1" "$(jq --argjson now "$(date +%s)" '.expires > $now + 604000 and .expires <= $now + 604800' "$DRYA/m/add002" | grep -c true)"
out=$(r2a ls 2>&1)
check "row 5: ls lists both adds" "2" "$(grep -c ' https://r2x.example.test/add00[12]/' <<<"$out")"
# If-None-Match: a record that lands while the add waits at its publish wins; the add deletes only its own prefix
: >"$rlog"; rm -f "$DRYA/.resume"
(SHARE_TEST_IDS=add003 SHARE_R2_DRY_PAUSE="PUT m/add003" r2a add "$WORK/wt/one.md" >"$WORK/add3.out" 2>"$WORK/add3.err"; echo $? >"$WORK/add3.rc") &
for _ in $(seq 1 200); do grep -q '^LIST o/add003\.[0-9a-f]\{8\}/$' "$rlog" 2>/dev/null && break; sleep 0.05; done
printf '%s\n' '{"v":1,"id":"add003","name":"x.txt","src":"/x","added":"2026-09-30","expires":0,"opts":"","prefix":"o/add003.00000000/","by":"peer"}' >"$DRYA/m/add003"
mkdir -p "$DRYA/o/add003.00000000"; printf 'theirs\n' >"$DRYA/o/add003.00000000/x.txt"
: >"$DRYA/.resume"; wait "$!"; rm -f "$DRYA/.resume"
check "row 5: a taken id answers 412 and the add exits 1" "1" "$(cat "$WORK/add3.rc")"
check "row 5: the 412 is named" "1" "$(grep -c 'another publisher took id add003' "$WORK/add3.err")"
check "row 5: the other publisher's record and prefix stay" "o/add003.00000000/ x.txt" "$(jq -r .prefix "$DRYA/m/add003") $(ls "$DRYA/o/add003.00000000")"
check "row 5: the loser's own prefix is deleted" "o/add003.00000000/x.txt" "$(r2a r2-list o/add003. | tr -d '\n')"
check "row 5: the loser keeps no r2-own line" "" "$(r2a r2-own get add003 || true)"
r6() { # r6 <label> <message> <cmd...>: exit 1, the message, no object PUT
  : >"$rlog"
  out=$("${@:3}" 2>&1); rc=$?
  check "row 6: $1 exits 1" "1" "$rc"
  check "row 6: $1 named" "1" "$(grep -c -- "$2" <<<"$out")"
  check "row 6: $1 puts no object" "0" "$(grep -c '^PUT ' "$rlog" || true)"
}
printf '%2048s' x >"$WORK/two-k.bin"
mkdir -p "$WORK/three"; for n in 1 2 3; do echo "$n" >"$WORK/three/$n.txt"; done
mkdir -p "$WORK/ctl"; printf 'x\n' >"$WORK/ctl/bad$(printf '\001')name.txt"
r6 "a live port" "live shares and --host need a tunnel profile" r2a add 3000
r6 "--host" "live shares and --host need a tunnel profile" r2a add --host x.example.test "$WORK/wt/one.md"
SHARE_R2_MAX_BYTES=1024 r6 "a file over SHARE_R2_MAX_BYTES" "over the r2 cap of 1024 bytes" r2a add "$WORK/two-k.bin"
SHARE_R2_MAX_FILES=2 r6 "three files over SHARE_R2_MAX_FILES=2" "over the r2 cap of 2 per add" r2a add "$WORK/three"
r6 "a control character in a name" "holds a control character" r2a add "$WORK/ctl"
R2_TOK="" CLOUDFLARE_API_TOKEN="" r6 "no token source" "needs a publisher token" r2a add "$WORK/wt/one.md"
# a token from CLOUDFLARE_API_TOKEN gets the same publisher check a stored one gets (DEC-007), once, before any write
mkdir -p "$DRYA/.cf"; echo '{}' >"$DRYA/.cf/script.json"   # the admin token reads the Worker's settings
R2_TOK="" CLOUDFLARE_API_TOKEN=admintoken r6 "an admin token in CLOUDFLARE_API_TOKEN" "it is an admin token.*from CLOUDFLARE_API_TOKEN" r2a add "$WORK/wt/one.md"
rm -f "$DRYA/.cf/script.json"
R2_TOK="" CLOUDFLARE_API_TOKEN=widetoken SHARE_R2_DRY_ROLE=deny SHARE_R2_DRY_BUCKETS="ok-bucket payout" \
  r6 "an account-wide R2 token in CLOUDFLARE_API_TOKEN" "reaches other buckets (payout).*from CLOUDFLARE_API_TOKEN" r2a add "$WORK/wt/one.md"
: >"$rlog"
out=$(R2_TOK="" CLOUDFLARE_API_TOKEN=pubtoken SHARE_R2_DRY_ROLE=deny SHARE_TEST_IDS=e0e001 r2a add "$WORK/wt/one.md" 2>&1); rc=$?
check "row 6: a bucket token in CLOUDFLARE_API_TOKEN publishes" "0 1" "$rc $(grep -c '^https://r2x.example.test/e0e001/one\.' <<<"$out")"
check "row 6: its check ran once" "1 1" "$(grep -c '/workers/scripts/.*/settings$' "$rlog") $(grep -c '/r2/buckets$' "$rlog")"
# curl unescapes a -K config value, so a backslash or a double quote in a staged name could name a file outside the stage
mkdir -p "$WORK/bs1/a/"'\.\./\.\.'; printf 'in\n' >"$WORK/bs1/a/"'\.\./\.\./outside.txt'
mkdir -p "$WORK/bs2"; printf 'x\n' >"$WORK/bs2/"'x\y'
mkdir -p "$WORK/bs3"; printf 'q\n' >"$WORK/bs3/"'q"t.txt'
r6 "a backslash path that walks out of the stage" 'holds a backslash or a double quote (bs1/a/.*outside.txt)' r2a add "$WORK/bs1"
r6 "a backslash in a name" 'holds a backslash or a double quote (bs2/x.y)' r2a add "$WORK/bs2"
r6 "a double quote in a name" 'holds a backslash or a double quote (bs3/q"t.txt)' r2a add "$WORK/bs3"
check "row 6: no stage left after the refusals" "0" "$(find "$r2root" -maxdepth 1 -name '.stage.*' | grep -c . || true)"

echo "=== r2 backend: the real curl -K upload path, byte for byte ==="
# r2_put_tree outside the dry seam, against a local S3 stand-in: every uploaded object must equal its staged file
RC="$WORK/r2curl"; RCS="$RC/stage"; RCR="$RC/recv"; mkdir -p "$RCS/a/"'\.\./\.\.' "$RCS/sub" "$RCR" "$RC/home/.config/share/profiles/r2c"
printf 'in\n' >"$RCS/a/"'\.\./\.\./outside.txt'; printf 'LEAKED\n' >"$RC/outside.txt"   # an unescaped path reads the parent's file
printf 'bs\n' >"$RCS/"'x\y'; printf 'plain\n' >"$RCS/xy"; printf 'q\n' >"$RCS/"'q"t.txt'
printf 'pct\n' >"$RCS/a%b.txt"; printf 'sp\n' >"$RCS/sp ace.txt"; printf 'd\n' >"$RCS/sub/deep.txt"
node -e '
const http = require("http"), fs = require("fs"), path = require("path");
const [root, portFile] = process.argv.slice(1);
http.createServer((q, r) => {
  const b = []; q.on("data", (c) => b.push(c));
  q.on("end", () => {
    const key = decodeURIComponent(new URL(q.url, "http://x").pathname).slice(1);   // <bucket>/<key>
    const f = path.join(root, key);
    if (q.method !== "PUT" || !f.startsWith(root + "/")) { r.writeHead(400); return r.end(); }
    fs.mkdirSync(path.dirname(f), { recursive: true }); fs.writeFileSync(f, Buffer.concat(b));
    r.writeHead(200); r.end();
  });
}).listen(0, "127.0.0.1", function () { fs.writeFileSync(portFile, String(this.address().port)); });
' "$RCR" "$RC/port" & rc_srv=$!
for _ in $(seq 1 100); do [[ -s $RC/port ]] && break; sleep 0.05; done
printf 'backend=r2\nhostname=r2c.example.test\nzone=example.test\nbucket=ok-bucket\nport=r2\nr2_endpoint=http://127.0.0.1:%s\nr2_key_id=keyid42\n' "$(cat "$RC/port")" \
  >"$RC/home/.config/share/profiles/r2c/config"
out=$(env -u SHARE_R2_DRY -u SHARE_ROOT -u SHARE_CONFIG_DIR -u SHARE_PORT -u SHARE_HOSTNAME -u SHARE_SERVICE_LABEL -u XDG_CONFIG_HOME -u SHARE_PROFILE -u SHARE_BACKEND \
  HOME="$RC/home" SHARE_TUNNEL=0 SHARE_R2_TOKEN=curltoken bash "$SH" --profile r2c r2-put-tree "$RCS" 'o/c0c0c0.deadbeef/' 2>&1); rc=$?
kill "$rc_srv" 2>/dev/null; wait "$rc_srv" 2>/dev/null
check "real curl: put_tree exits 0" "0" "$rc"
rc_got="$(cd "$RCR/ok-bucket/o/c0c0c0.deadbeef" 2>/dev/null && find . -type f | LC_ALL=C sort | tr '\n' '|')"
check "real curl: one object per staged file" "$(cd "$RCS" && find . -type f | LC_ALL=C sort | tr '\n' '|')" "$rc_got"
rc_bad=0
while IFS= read -r -d '' f; do cmp -s "$RCS/$f" "$RCR/ok-bucket/o/c0c0c0.deadbeef/$f" || { rc_bad=$((rc_bad + 1)); echo "    differs: $f"; }; done < <(cd "$RCS" && find . -type f -print0)
check "real curl: every object's bytes equal its staged file" "0" "$rc_bad"

echo "=== r2 backend: two publishers, ls, refresh, rm (rows 7, 8, 9, 25a) ==="
R2B="$WORK/r2b"; mkdir -p "$R2B/.config/share/profiles/r2x"; cp "$r2conf" "$R2B/.config/share/profiles/r2x/config"
r2b() { # r2b <verb...>: a second install (its own HOME) publishing to the same dry bucket as r2a
  env -u SHARE_ROOT -u SHARE_CONFIG_DIR -u SHARE_PORT -u SHARE_HOSTNAME -u SHARE_SERVICE_LABEL -u XDG_CONFIG_HOME -u SHARE_PROFILE -u SHARE_BACKEND \
    HOME="$R2B" SHARE_TUNNEL=0 SHARE_R2_DRY=1 SHARE_R2_DRY_DIR="$DRYA" SHARE_R2_TOKEN=drytoken bash "$SH" --profile r2x "$@"
}
blog="$R2B/share/profiles/r2x/r2-calls.log"
bline() { grep -n -- "$1" "$blog" | head -1 | cut -d: -f1; }
wnode() { # wnode <path>...: "<code> <path>" per path from the real Worker over the dry bucket (integration mode)
  node "$(dirname "$SH")/../tests/worker.mjs" --dir "$DRYA" --host r2x.example.test "$@" 2>/dev/null | grep -E '^[0-9]{3} /'
}
rm -rf "$DRYA"; mkdir -p "$DRYA"; rm -f "$r2root/r2-own"
printf 'alpha\n' >"$WORK/a7.txt"; printf 'beta\n' >"$WORK/b7.txt"
a7=$(SHARE_TEST_IDS=a70001 r2a add "$WORK/a7.txt" 2>/dev/null | head -1)
b7=$(SHARE_TEST_IDS=b70001 r2b add "$WORK/b7.txt" 2>/dev/null | head -1)
check "row 7: A and B each publish" "https://r2x.example.test/a70001/a7.txt https://r2x.example.test/b70001/b7.txt" "$a7 $b7"
out=$(r2a ls 2>&1)
check "row 7: A's ls shows both rows with by=" "2" "$(grep -c 'id=[ab]70001 .* by=[a-z0-9.-]' <<<"$out")"
out=$(r2b ls 2>&1)
check "row 7: B's ls shows both rows with by=" "2" "$(grep -c 'id=[ab]70001 .* by=[a-z0-9.-]' <<<"$out")"
out=$(r2b refresh a70001 2>&1); rc=$?
check "row 7: B's refresh of A's share is refused" "1" "$rc"
check "row 7: the refusal names the other install" "1" "$(grep -c 'a70001 was added from another install; refresh it there' <<<"$out")"
if command -v node >/dev/null; then
  check "row 5: the real Worker serves A's link from the dry bucket" "200 /a70001/a7.txt" "$(wnode /a70001/a7.txt)"
fi

aprefix="$(jq -r .prefix "$DRYA/m/a70001")"
printf 'forged\n' >"$WORK/forged.txt"
jq -c --arg s "$WORK/forged.txt" '.src = $s' "$DRYA/m/a70001" >"$WORK/m.tmp" && mv -f "$WORK/m.tmp" "$DRYA/m/a70001"
printf 'alpha two\n' >"$WORK/a7.txt"
: >"$rlog"
out=$(r2a refresh a70001 2>&1); rc=$?
nprefix="$(jq -r .prefix "$DRYA/m/a70001")"
check "row 8: refresh exits 0" "0" "$rc"
check "row 8: the record names a new prefix" "1" "$([[ $nprefix != "$aprefix" && $nprefix == o/a70001.????????/ ]] && echo 1 || echo 0)"
check "row 8: the upload came from r2-own, not the forged src" "alpha two" "$(cat "$DRYA/${nprefix}a7.txt" 2>/dev/null)"
check "row 8: the record's src is the r2-own path again" "$(realpath "$WORK/a7.txt")" "$(jq -r .src "$DRYA/m/a70001")"
check "row 8: new objects < PUT m/<id> < old-prefix DELETEs" "1" "$([[ -n $(aline "^DELETE $aprefix") && $(alast "^PUT $nprefix") -lt $(aline '^PUT m/a70001$') && $(aline '^PUT m/a70001$') -lt $(aline "^DELETE $aprefix") ]] && echo 1 || echo 0)"
check "row 8: the old prefix is gone" "" "$(r2a r2-list "$aprefix")"
check "row 8: r2-own names the new prefix" "$nprefix" "$(r2a r2-own get a70001 | cut -f2)"

mkdir -p "$DRYA/o/b70001.0000beef"; printf 'left\n' >"$DRYA/o/b70001.0000beef/old.txt"   # a second nonce under the same id
: >"$rlog"
out=$(r2a rm b70001 2>&1); rc=$?
check "row 7: A's rm of B's share works" "0" "$rc"
check "row 9: DELETE m/<id> < GET m/<id> < object DELETEs" "1" "$([[ -n $(aline '^DELETE o/b70001\.') && $(aline '^DELETE m/b70001$') -lt $(alast '^GET m/b70001$') && $(alast '^GET m/b70001$') -lt $(aline '^DELETE o/b70001\.') ]] && echo 1 || echo 0)"
check "row 9: no record and no object under any nonce" "" "$(ls "$DRYA/m/b70001" 2>/dev/null)$(r2a r2-list o/b70001.)"
check "row 7: B's ls no longer lists it" "0" "$(r2b ls 2>&1 | grep -c 'id=b70001' || true)"
: >"$rlog"
out=$(SHARE_R2_DRY_DELETE=lost r2a rm a70001 2>&1); rc=$?
check "row 9: a lost record DELETE exits 1" "1" "$rc"
check "row 9: named, nothing else deleted" "1 0" "$(grep -c 'still answers HTTP 200 after its delete' <<<"$out") $(grep -c '^DELETE o/' "$rlog" || true)"
check "row 9: the record and objects stay" "1" "$([[ -f $DRYA/m/a70001 && -n $(r2a r2-list o/a70001.) ]] && echo 1 || echo 0)"
out=$(r2a rm ffffff 2>&1); rc=$?
check "rm of an unknown id exits 1" "1 1" "$rc $(grep -c "no share with id 'ffffff'" <<<"$out")"

printf 'gamma\n' >"$WORK/g.txt"
SHARE_TEST_IDS=a25001 r2a add "$WORK/g.txt" >/dev/null 2>&1
g_old="$(jq -r .prefix "$DRYA/m/a25001")"
: >"$rlog"; rm -f "$DRYA/.resume"
(SHARE_R2_DRY_PAUSE="PUT m/a25001" r2a refresh a25001 >"$WORK/r25.out" 2>"$WORK/r25.err"; echo $? >"$WORK/r25.rc") &
for _ in $(seq 1 200); do grep -q '^LIST o/a25001\.[0-9a-f]\{8\}/$' "$rlog" 2>/dev/null && break; sleep 0.05; done
g_new="$(sed -n 's/^LIST \(o\/a25001\.[0-9a-f]\{8\}\/\)$/\1/p' "$rlog" | head -1)"
out=$(r2b rm a25001 2>&1); brc=$?
: >"$DRYA/.resume"; wait "$!"; rm -f "$DRYA/.resume"
check "row 25a: B's rm during A's refresh exits 0" "0" "$brc"
check "row 25a: A's refresh answers 412 and exits 1" "1" "$(cat "$WORK/r25.rc")"
check "row 25a: named" "1" "$(grep -c 'a25001 changed during the refresh' "$WORK/r25.err")"
check "row 25a: no record resurrected, no object left" "" "$(ls "$DRYA/m/a25001" 2>/dev/null)$(r2a r2-list o/a25001.)"
SHARE_TEST_IDS=a25002 r2a add "$WORK/g.txt" >/dev/null 2>&1
g_old="$(jq -r .prefix "$DRYA/m/a25002")"
: >"$rlog"
(SHARE_R2_DRY_PAUSE="PUT m/a25002" r2a refresh a25002 >"$WORK/r25.out" 2>"$WORK/r25.err"; echo $? >"$WORK/r25.rc") &
for _ in $(seq 1 200); do grep -q '^LIST o/a25002\.[0-9a-f]\{8\}/$' "$rlog" 2>/dev/null && break; sleep 0.05; done
g_new="$(sed -n 's/^LIST \(o\/a25002\.[0-9a-f]\{8\}\/\)$/\1/p' "$rlog" | head -1)"
jq -c '.name = "renamed"' "$DRYA/m/a25002" >"$WORK/m.tmp" && mv -f "$WORK/m.tmp" "$DRYA/m/a25002"   # another refresh won: a new etag
: >"$DRYA/.resume"; wait "$!"; rm -f "$DRYA/.resume"
check "row 25a: a record changed mid-refresh answers 412" "1 1" "$(cat "$WORK/r25.rc") $(grep -c 'a25002 changed during the refresh' "$WORK/r25.err")"
check "row 25a: the winner's record and prefix stay" "$g_old renamed" "$(jq -r '"\(.prefix) \(.name)"' "$DRYA/m/a25002")"
check "row 25a: the loser deleted its own new prefix" "0 1" "$(r2a r2-list "$g_new" | grep -c . || true) $([[ -n $(r2a r2-list "$g_old") ]] && echo 1 || echo 0)"

echo "=== r2 backend: expiry, concurrent prune, orphan sweep (rows 10, 24, 25c) ==="
rm -rf "$DRYA"; mkdir -p "$DRYA"; rm -f "$r2root/r2-own" "$R2B/share/profiles/r2x/r2-own"
forge() { # forge <id> <expires> [opts] [aud]: a record and one object, as another publisher would leave them
  local id=$1 n; n="00000${id: -3}"
  mkdir -p "$DRYA/m" "$DRYA/o/$id.$n"; printf 'f %s\n' "$id" >"$DRYA/o/$id.$n/f.txt"
  jq -nc --arg id "$id" --argjson e "$2" --arg o "${3:-}" --arg a "${4:-}" --arg p "o/$id.$n/" \
    '{v: 1, id: $id, name: "f.txt", src: "/elsewhere/f.txt", added: "2026-09-01", expires: $e, opts: $o, prefix: $p, by: "peer"} + (if $a == "" then {} else {aud: $a} end)' >"$DRYA/m/$id"
}
aud64="$(printf 'a%.0s' $(seq 1 64))"
forge 100001 1000
forge 100002 1000 "access=00000000-0000-4000-8000-000000000a0a access_rule=email:a@x.io" "$aud64"
forge 100003 0
if command -v node >/dev/null; then
  check "row 10: the Worker answers 404 for both expired records before any prune, 200 for a live one" "404 /100001/f.txt|404 /100002/f.txt|200 /100003/f.txt|" \
    "$(wnode /100001/f.txt /100002/f.txt /100003/f.txt | tr '\n' '|')"
fi
: >"$rlog"
out=$(r2a ls 2>&1); rc=$?
check "row 10: ls with a publisher token exits 0" "0" "$rc"
check "row 10: the expired ungated record and prefix are gone" "" "$(ls "$DRYA/m/100001" 2>/dev/null)$(r2a r2-list o/100001.)"
check "row 10: ls prints the expiry" "1" "$(grep -c '^unpublished 100001 (expired)$' <<<"$out")"
check "row 10: the expired gated record and prefix stay" "1" "$([[ -f $DRYA/m/100002 && -n $(r2a r2-list o/100002.) ]] && echo 1 || echo 0)"
check "row 10: the waiting line names the gated share" "1" "$(grep -c 'expired gated share 100002 waits for a publisher with the Access token' <<<"$out")"
check "row 10: ls lists the live share, not the removed one" "1 0" "$(grep -c 'id=100003' <<<"$out") $(grep -c 'id=100001' <<<"$out")"
check "row 10: no DELETE touched the gated share" "0" "$(grep -c '100002' <<<"$(grep '^DELETE' "$rlog")" || true)"

forge 250001 1000
(r2a prune >"$WORK/p1.out" 2>&1; echo $? >"$WORK/p1.rc") & p1=$!
(r2b prune >"$WORK/p2.out" 2>&1; echo $? >"$WORK/p2.rc") & p2=$!
wait "$p1" "$p2"   # never a bare wait: the suite's fixture server is a background job too
check "row 25c: two prunes of one expired id both exit 0" "0 0" "$(cat "$WORK/p1.rc") $(cat "$WORK/p2.rc")"
check "row 25c: the record and every object are gone" "" "$(ls "$DRYA/m/250001" 2>/dev/null)$(r2a r2-list o/250001.)"
check "row 25c: at least one prune reported it" "1" "$([[ $(cat "$WORK/p1.out" "$WORK/p2.out" | grep -c '^unpublished 250001 (expired)$') -ge 1 ]] && echo 1 || echo 0)"

rm -rf "$DRYA"; mkdir -p "$DRYA"
aged() { # aged <seconds> <file>...: set the mtime that many seconds back (the dry LastModified)
  local t=$(($(date +%s) - $1)) s; s="$(date -r "$t" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$t" +%Y%m%d%H%M.%S)"
  touch -t "$s" "${@:2}"
}
obj() { mkdir -p "$DRYA/${1%/*}"; printf 'x\n' >"$DRYA/$1"; }
obj o/aaa001.00000001/f.txt; aged 90000 "$DRYA/o/aaa001.00000001/f.txt"
obj o/aaa002.00000002/f.txt; aged 3600 "$DRYA/o/aaa002.00000002/f.txt"
forge aaa003 0; aged 90000 "$DRYA/o/aaa003.00000003/f.txt"
: >"$rlog"
out=$(r2a ls 2>&1)
check "row 24: ls never sweeps" "0" "$(grep -c '^DELETE' "$rlog" || true)"
: >"$rlog"
out=$(r2a prune 2>&1); rc=$?
check "row 24: bare prune exits 0" "0" "$rc"
check "row 24: only the old unreferenced prefix is deleted" "DELETE o/aaa001.00000001/f.txt" "$(grep '^DELETE' "$rlog")"
check "row 24: the removal is printed" "1" "$(grep -c '^removed orphan upload o/aaa001.00000001/$' <<<"$out")"
check "row 24: the young and the referenced prefixes stay" "2" "$(find "$DRYA/o" -maxdepth 1 -name 'aaa00[23].*' | grep -c .)"
obj o/aaa005.00000005/f.txt; aged 90000 "$DRYA/o/aaa005.00000005/f.txt"
printf '%s\n' '{"v":2,"id":"aaa004","name":"f.txt","src":"/x","added":"2026-09-01","expires":0,"opts":"","prefix":"o/aaa004.00000004/","by":"peer"}' >"$DRYA/m/aaa004"
obj o/aaa004.00000004/f.txt; aged 90000 "$DRYA/o/aaa004.00000004/f.txt"
: >"$rlog"
out=$(r2a prune 2>&1); rc=$?
check "row 24: a v:2 record skips the sweep" "0 0" "$rc $(grep -c '^DELETE' "$rlog" || true)"
check "row 24: the warning names the record" "1" "$(grep -c 'orphan sweep skipped: m/aaa004 is unreadable or newer' <<<"$out")"
printf 'not json\n' >"$DRYA/m/aaa004"
: >"$rlog"
out=$(r2a prune 2>&1); rc=$?
check "row 24: a broken record skips the sweep" "0 0" "$rc $(grep -c '^DELETE' "$rlog" || true)"
check "row 24: the warning names it" "1" "$(grep -c 'orphan sweep skipped: m/aaa004' <<<"$out")"
check "row 24: every prefix is still there" "4" "$(find "$DRYA/o" -maxdepth 1 -name 'aaa00[2345].*' | grep -c .)"

echo "=== r2 backend: hits, status, state, profiles (rows 13, 14) ==="
rm -rf "$DRYA"; mkdir -p "$DRYA/.cf"
forge 130001 0; forge 130002 0
printf '%s\n' '{"meta":[],"data":[{"hits":"3","visitors":"2","last":"2026-09-30 09:21:35"}],"rows":1}' >"$DRYA/.cf/sql.json"
: >"$rlog"
out=$(CLOUDFLARE_API_TOKEN=faketoken r2a hits 130001 2>&1); rc=$?
check "row 13: hits exits 0" "0" "$rc"
check "row 13: the count line" "1" "$(grep -c '^3 hits, 2 visitors, last 2026-09-[0-9]* [0-9][0-9]:[0-9][0-9]$' <<<"$out")"
check "row 13: the SQL names the dataset and the id" "1" "$(grep -c "^SQL SELECT SUM(_sample_interval) AS hits, COUNT(DISTINCT blob2) AS visitors, MAX(timestamp) AS last FROM share_r2x_example_test WHERE index1 = '130001' FORMAT JSON$" "$rlog")"
check "row 13: one account call and no bucket read" "API POST /accounts/acct/analytics_engine/sql" "$(grep -v '^SQL ' "$rlog")"
out=$(CLOUDFLARE_API_TOKEN=faketoken r2a hits https://r2x.example.test/130001/f.txt 2>&1)
check "row 13: hits takes the pasted link" "1" "$(grep -c '^3 hits, 2 visitors' <<<"$out")"
: >"$rlog"
out=$(CLOUDFLARE_API_TOKEN=faketoken r2a hits "abc' OR '1'='1" 2>&1); rc=$?
check "row 13: an injected id is refused before any call" "1 0" "$rc $(grep -c . "$rlog" || true)"
printf '%s\n' '{"meta":[],"data":[{"hits":"0","visitors":"0","last":"1970-01-01 00:00:00"}],"rows":1}' >"$DRYA/.cf/sql.json"
hnote130002="this machine counts cloud links only; if 130002 is a machine link, its stats are on the tenant's origin: share --profile r2x hits 130002 there"
check "row 13: no visits on an id another publisher added: the count plus the machine-link note" "0 hits, 0 visitors|$hnote130002" "$(CLOUDFLARE_API_TOKEN=faketoken r2a hits 130002 2>&1 | paste -sd'|' -)"
r2a r2-own put 130002 o/130002.0badf00d/ "$WORK/x"
check "row 13: no visits on this install's own cloud link: the bare count" "0 hits, 0 visitors" "$(CLOUDFLARE_API_TOKEN=faketoken r2a hits 130002 2>&1)"
r2a r2-own drop 130002
out=$(CLOUDFLARE_API_TOKEN="" r2a hits 130001 2>&1); rc=$?
check "row 13: hits with no API token exits 1 naming the scope" "1 1" "$rc $(grep -c 'Account Analytics: Read' <<<"$out")"

forge 130003 1000   # expired: status must list it and delete nothing
wv14="$(sed -n 's/^WORKER_VERSION=\([0-9]*\).*/\1/p' "$SH")"; wsha14="$(sed -n 's/^WORKER_SHA=\([0-9a-f]*\).*/\1/p' "$SH")"
printf '{"hostname":"r2x.example.test","service":"share-r2x-example-test"}\n' >"$DRYA/.cf/domain.json"
printf '{"bindings":[{"type":"plain_text","name":"VERSION","text":"%s"},{"type":"plain_text","name":"SHA","text":"%s"}]}\n' "$wv14" "$wsha14" >"$DRYA/.cf/script.json"
: >"$rlog"
out=$(r2a status 2>&1); rc=$?
check "row 14: status exits 0" "0" "$rc"
check "row 14: status names the backend and a Worker that is up" "2" "$(grep -cE '^r2 backend: https://r2x.example.test/$|^worker: +up \(' <<<"$out")"
check "row 14: status lists every row, the expired one included" "3" "$(grep -c '^    id=13000[123] ' <<<"$out")"
check "row 14: status logs no DELETE and keeps the expired record" "0 1" "$(grep -c '^DELETE' "$rlog" || true) $([[ -f $DRYA/m/130003 ]] && echo 1 || echo 0)"
check "row 14: status says gated links are off on a Worker with no TEAM" "1" "$(grep -c '^gated: *off (the Worker has no Access team' <<<"$out")"
check "row 14: status prints no version line when the pair matches" "0" "$(grep -c 'whoever holds the admin token' <<<"$out" || true)"
printf '{"bindings":[{"type":"plain_text","name":"VERSION","text":"%s"},{"type":"plain_text","name":"SHA","text":"000000000000"}]}\n' "$wv14" >"$DRYA/.cf/script.json"
out=$(r2a status 2>&1)
check "row 14: status names a Worker on another version" "1" "$(grep -c "runs $wv14 000000000000; this share ships $wv14 $wsha14" <<<"$out")"
out=$(SHARE_R2_DRY_HEALTHZ=down r2a status 2>&1)
check "row 14: status names a Worker that is down" "1" "$(grep -c '^worker: *DOWN: 000$' <<<"$out")"
printf 'not json\n' >"$DRYA/m/130009"
out=$(r2a status 2>&1)
check "row 14: status names a record that blocks the orphan sweep" "1" "$(grep -c '^orphan sweep blocked by m/130009$' <<<"$out")"
mv -f "$DRYA/m/130009" "$WORK/130009.broken"
: >"$rlog"
out=$(r2a state 2>/dev/null); rc=$?
check "row 14: state exits 0" "0" "$rc"
check "row 14: state: backend, mode, serves_here, schema, state" "r2 named false 1 serving" "$(jq -r '"\(.backend) \(.mode) \(.serves_here) \(.schema) \(.state)"' <<<"$out")"
check "row 14: state has every field Share Bar's Snapshot decodes, typed" "true" "$(jq '(.schema | type) == "number" and (.state | type) == "string" and (.ready | type) == "boolean"
  and (.mode | type) == "string" and (.host | type) == "string" and (.hosts | type) == "string" and (.serves_here | type) == "boolean"
  and (.service | type) == "boolean" and (.shares | type) == "array"
  and all(.shares[]; (.id | type) == "string" and (.name | type) == "string" and (.url | type) == "string" and .kind == "snapshot" and (.expires | type) == "number")' <<<"$out")"
check "row 14: state lists the rows with their links" "130001 https://r2x.example.test/130001/f.txt|130002|130003|" "$(jq -r '.shares | sort_by(.id) | .[0] as $f | [$f.id + " " + $f.url] + [.[1:][] | .id] | join("|")' <<<"$out")|"
check "row 14: state logs no DELETE" "0" "$(grep -c '^DELETE' "$rlog" || true)"
check "row 14: a tunnel profile's state has no backend key" "false" "$(bash "$SH" state | jq 'has("backend")')"
mkdir -p "$R2H/.config/share/profiles/tunx"
printf 'hostname=tunx.example.test\ntunnel_id=00000000-0000-4000-8000-00000000abcd\ntunnel_name=tunx\nport=38997\n' >"$R2H/.config/share/profiles/tunx/config"
: >"$rlog"
out=$(r2a profiles 2>&1)
check "row 14: profiles lists the r2 profile" "1" "$(grep -c $'^r2x\tserving\tr2x.example.test$' <<<"$out")"
check "row 14: profiles lists the tunnel profile beside it" "1" "$(grep -c $'^tunx\tstopped\ttunx.example.test$' <<<"$out")"
check "row 14: profiles reads no m/ for the r2 profile" "0 1" "$(grep -c '^LIST m/' "$rlog" || true) $(grep -c '^HEALTHZ$' "$rlog")"
forge 130004 0 "access=00000000-0000-4000-8000-000000000a0a access_rule=email:a@x.io" "$aud64"
out=$(r2a profiles --json 2>/dev/null); rc=$?
check "profiles --json exits 0 beside a tunnel profile" "0" "$rc"
check "profiles --json: the r2 entry's backend, host, state, and gated share" "r2 r2x.example.test serving false email:a@x.io" \
  "$(jq -r '.profiles[] | select(.name == "r2x") | .state | "\(.backend) \(.host) \(.state) \(.serves_here) \([.shares[] | select(.id == "130004") | .access][0])"' <<<"$out")"
check "profiles --json: the r2 entry lists every row" "130001 130002 130003 130004" "$(jq -r '.profiles[] | select(.name == "r2x") | [.state.shares[].id] | sort | join(" ")' <<<"$out")"
check "profiles --json: the r2 entry equals its own state" "true" "$(jq --argjson own "$(r2a state 2>/dev/null)" '.profiles[] | select(.name == "r2x") | .state == $own' <<<"$out")"
check "profiles --json: the tunnel entry has no backend key" "false" "$(jq '.profiles[] | select(.name == "tunx") | .state | has("backend")' <<<"$out")"
rm -f "$DRYA/m/130004"
mv -f "$R2H/.config/share/profiles/tunx/config" "$WORK/tunx.config"

echo "=== r2 backend: gated add, rm, prune, and the sweep (rows 9, 10, 11, 12, 25b, 25d, 29) ==="
rm -rf "$DRYA"; mkdir -p "$DRYA/.cf"; rm -f "$r2root/r2-own"
wvg="$(sed -n 's/^WORKER_VERSION=\([0-9]*\).*/\1/p' "$SH")"; wshag="$(sed -n 's/^WORKER_SHA=\([0-9a-f]*\).*/\1/p' "$SH")"
printf '{"hostname":"r2x.example.test","service":"share-r2x-example-test"}\n' >"$DRYA/.cf/domain.json"
gteam() { # gteam <team>: the deployed Worker's bindings, with TEAM set or empty
  printf '{"bindings":[{"type":"plain_text","name":"VERSION","text":"%s"},{"type":"plain_text","name":"SHA","text":"%s"},{"type":"plain_text","name":"TEAM","text":"%s"}]}\n' "$wvg" "$wshag" "$1" >"$DRYA/.cf/script.json"
}
gteam team.cloudflareaccess.com
r2g() { # r2g <verb...>: r2a with the Access seam and an Access-capable token in the environment
  SHARE_ACCESS_DRY=1 SHARE_ACCESS_POLL="${SHARE_ACCESS_POLL:-0}" CLOUDFLARE_API_TOKEN="${G_TOK-faketoken}" r2a "$@"
}
gpend="$r2root/access-pending"; gfix="$r2root/access-probe-fixture"; gdry="$r2root/.access-dry"
greset() { : >"$rlog"; rm -f "$gfix"; : >"$gpend"; }
gapp() { jq -r '.opts' "$DRYA/m/$1" | tr ' ' '\n' | sed -n 's/^access=//p'; }
gpfx() { jq -r '.prefix' "$DRYA/m/$1"; }
printf 'gated\n' >"$WORK/g.txt"
sh -c 'exit 0' & gdead=$!; wait "$gdead"

echo "--- row 11: the record lands only after the gate is observed ---"
greset; printf 'fail\nfail\npass\npass\npass\n' >"$gfix"
rm -f "$WORK/g11.bad"
( while ! grep -q '^PUT m/ab1101$' "$rlog" 2>/dev/null; do
    if grep -q 'PROBE fail' "$rlog" 2>/dev/null && [[ -e $DRYA/m/ab1101 ]]; then echo bad >"$WORK/g11.bad"; fi
    sleep 0.05
  done ) & gw=$!
out=$(SHARE_TEST_IDS=ab1101 r2g add --access email:A@x.io "$WORK/g.txt" 2>"$WORK/g11.err"); rc=$?
kill "$gw" 2>/dev/null; wait "$gw" 2>/dev/null
check "row 11: gated add exits 0 and prints the link" "0 https://r2x.example.test/ab1101/g.txt" "$rc $(head -1 <<<"$out")"
check "row 11: the preflight's {} probe precedes the first object PUT" "1" "$([[ $(aline '^POST app {}') -lt $(aline '^PUT o/ab1101\.') ]] && echo 1 || echo 0)"
check "row 11: object PUTs < POST app < every PROBE < PUT m/<id>" "1" "$([[ $(alast '^PUT o/ab1101\.') -lt $(aline '^POST app$') && $(aline '^POST app$') -lt $(aline '^PROBE') && $(alast '^PROBE') -lt $(aline '^PUT m/ab1101$') ]] && echo 1 || echo 0)"
check "row 11: five probe rounds (2 fail, 3 pass)" "fail fail pass pass pass" "$(sed -n 's/^PROBE //p' "$rlog" | tr '\n' ' ' | sed 's/ $//')"
check "row 11: m/<id> absent while a PROBE fail was logged" "0" "$([[ -e $WORK/g11.bad ]] && echo 1 || echo 0)"
g11app="$(gapp ab1101)"
check "row 11: the record names the app, the rule, and the app's aud" "1 email:a@x.io 1" \
  "$(grep -c '^00000000-0000-4000-8000-000000ab1101$' <<<"$g11app") $(jq -r '.opts' "$DRYA/m/ab1101" | tr ' ' '\n' | sed -n 's/^access_rule=//p') $([[ $(jq -r .aud "$DRYA/m/ab1101") == "$(jq -r .aud "$gdry/$g11app.json")" ]] && jq -r .aud "$DRYA/m/ab1101" | grep -c '^[0-9a-f]\{64\}$')"
check "row 11: the app's nonce names the upload prefix" "$(gpfx ab1101)" "o/ab1101.$(jq -r '.name | split(" ") | last' "$gdry/$g11app.json")/"
check "row 11: access-pending empty after the publish" "0" "$(awk 'NF' "$gpend" | wc -l | tr -d ' ')"
check "row 11: no public-link warning on a gated add" "0" "$(grep -c 'public to anyone' "$WORK/g11.err" || true)"
check "row 11: ls shows the rule" "1" "$(r2g ls 2>/dev/null | grep -c 'id=ab1101 .*access=email:a@x.io')"
if command -v node >/dev/null; then
  check "row 11: the integration Worker answers 404 without an Access JWT" "404 /ab1101/g.txt" "$(wnode /ab1101/g.txt)"
fi
gteam ""
r6 "a gated add on a Worker with no Access team" "has no Access team" r2g add --access email:a@x.io "$WORK/g.txt"
check "row 11: the no-team refusal creates no app" "0" "$(grep -c '^POST app' "$rlog" || true)"
gteam team.cloudflareaccess.com
check "status says gated links are on once the Worker has a TEAM" "1" "$(r2a status 2>/dev/null | grep -c '^gated: *on ')"

echo "--- row 12: SPEC-004 row 8 on r2: a gate that never passes publishes nothing ---"
greset; printf 'fail\n' >"$gfix"
out=$(SHARE_TEST_IDS=ab0801 SHARE_ACCESS_WAIT=2 SHARE_ACCESS_POLL=1 r2g add --access email:a@x.io "$WORK/g.txt" 2>&1); rc=$?
check "row 12/8: exit 1 naming the wait" "1 1" "$rc $(grep -c 'did not enforce on r2x.example.test/ab0801 within 2s; nothing was published' <<<"$out")"
check "row 12/8: DELETE app logged, no record PUT" "1 0" "$(grep -c '^DELETE app ' "$rlog") $(grep -c '^PUT m/' "$rlog" || true)"
check "row 12/8: no record, no prefix, pending empty" "0 0 0" "$([[ -e $DRYA/m/ab0801 ]] && echo 1 || echo 0) $(r2a r2-list o/ab0801. | grep -c . || true) $(awk 'NF' "$gpend" | wc -l | tr -d ' ')"
check "row 12/8: no stage left" "0" "$(find "$r2root" -maxdepth 1 -name '.stage.*' | grep -c . || true)"

echo "--- row 12: SPEC-004 row 25 on r2: a live owner's line is never swept ---"
greset; printf 'fail\nfail\npass\n' >"$gfix"
(SHARE_TEST_IDS=ab2501 SHARE_ACCESS_POLL=1 r2g add --access email:a@x.io "$WORK/g.txt" >"$WORK/g25.out" 2>&1; echo $? >"$WORK/g25.rc") &
gadd=$!
for _ in $(seq 1 100); do grep -q 'PROBE fail' "$rlog" 2>/dev/null && break; sleep 0.1; done
r2g prune >/dev/null 2>&1
wait "$gadd"
check "row 12/25: the prune skipped the live owner's line (no DELETE app)" "0" "$(grep -c '^DELETE app' "$rlog" || true)"
check "row 12/25: the add then published" "0 1" "$(cat "$WORK/g25.rc") $([[ -e $DRYA/m/ab2501 ]] && echo 1 || echo 0)"

echo "--- row 12: SPEC-004 row 23c on r2: a sweep that claims the line during the wait stops the publish ---"
greset; printf 'fail\nfail\nfail\nfail\npass\n' >"$gfix"
(SHARE_TEST_IDS=ab2301 SHARE_ACCESS_POLL=1 r2g add --access email:a@x.io "$WORK/g.txt" >"$WORK/g23.out" 2>"$WORK/g23.err"; echo $? >"$WORK/g23.rc") &
gadd=$!
for _ in $(seq 1 100); do grep -q 'PROBE fail' "$rlog" 2>/dev/null && break; sleep 0.1; done
awk -F'\t' -v OFS='\t' -v d="$gdead" '{$3 = d} {print}' "$gpend" >"$WORK/gp" && mv "$WORK/gp" "$gpend"   # the owner forged dead
SHARE_ACCESS_DRY_DELETE=lost r2g prune >/dev/null 2>&1
wait "$gadd"
check "row 12/23c: the sweep read m/<id> fresh (after rand_id's read), then claimed the app" "2" "$(awk '/^GET m\/ab2301$/ {n++} /^DELETE app .* \(lost\)$/ {print n + 0; exit}' "$rlog")"
check "row 12/23c: the add finds its line gone, publishes nothing, dies" "1 1 0" "$(cat "$WORK/g23.rc") $(grep -c 'claimed by a sweep during the wait; nothing was published' "$WORK/g23.err") $(grep -c '^PUT m/ab2301' "$rlog" || true)"
check "row 12/23c: no record, and the add's trap deleted its upload" "0 0" "$([[ -e $DRYA/m/ab2301 ]] && echo 1 || echo 0) $(r2a r2-list o/ab2301. | grep -c . || true)"
r2g prune >/dev/null 2>&1   # the app the lost DELETE kept goes on the next sweep
check "row 12/23c: the next sweep deletes the kept app and drops the line" "1 0" "$(grep -c '^DELETE app 00000000-0000-4000-8000-000000ab2301$' "$rlog") $(grep -c '^ab2301' "$gpend" || true)"

echo "--- rows 9 and 12: gated rm: record, a 404 read, every nonce, then the app ---"
greset
out=$(SHARE_R2_DRY_DELETE=lost r2g rm ab2501 2>&1); rc=$?
check "row 9: a lost record DELETE: exit 1 naming the kept app" "1 1" "$rc $(grep -c 'm/ab2501 still answers HTTP 200 after its delete (HTTP 000); its objects and its Access app were kept' <<<"$out")"
check "row 9: lost: no DELETE app, no object DELETE, the pending line kept" "0 0 1" "$(grep -c '^DELETE app' "$rlog" || true) $(grep -c '^DELETE o/' "$rlog" || true) $(grep -c '^ab2501	' "$gpend")"
check "row 9: lost: the record is still there" "1" "$([[ -e $DRYA/m/ab2501 ]] && echo 1 || echo 0)"
g25app="$(gapp ab2501)"; greset
mkdir -p "$DRYA/o/ab2501.0badf00d"; printf 'old\n' >"$DRYA/o/ab2501.0badf00d/x.txt"   # a second nonce: rm deletes every one
out=$(r2g rm ab2501 2>&1); rc=$?
check "row 9: gated rm exits 0" "0" "$rc"
check "row 9: DELETE m/<id> < GET m/<id> (404) < every object DELETE < DELETE app" "DELETE m GET m DELETE o DELETE app" \
  "$(awk -v app="$g25app" '$0 == "DELETE m/ab2501" || (seen && $0 == "GET m/ab2501") {print $1, "m"; seen = 1} /^DELETE o\/ab2501\./ {print "DELETE o"} $0 == "DELETE app " app {print "DELETE app"}' "$rlog" | uniq | tr '\n' ' ' | sed 's/ $//')"
check "row 9: both nonces deleted (the add's and a second one), the record gone, pending empty" "0 0 0" "$(r2a r2-list o/ab2501. | grep -c . || true) $([[ -e $DRYA/m/ab2501 ]] && echo 1 || echo 0) $(awk 'NF' "$gpend" | wc -l | tr -d ' ')"
check "row 9: the app is gone" "0" "$([[ -e $gdry/$g25app.json ]] && echo 1 || echo 0)"
forge ab9001 0 "access=00000000-0000-4000-8000-000000ab9001 access_rule=email:a@x.io" "$aud64"
out=$(G_TOK="" r2g rm ab9001 2>&1); rc=$?
check "row 9: gated rm with no token: the guided block, record intact" "1 1 1" "$rc $(grep -c 'needs a Cloudflare API token' <<<"$out") $([[ -e $DRYA/m/ab9001 ]] && echo 1 || echo 0)"

echo "--- row 29: a token without Access: Apps and Policies Edit never touches a gated share ---"
greset
out=$(SHARE_ACCESS_DRY_APPS=deny r2g rm ab9001 2>&1); rc=$?
check "row 29: rm exits 1 naming the missing scope" "1 1" "$rc $(grep -c "the token lacks 'Access: Apps and Policies Edit'" <<<"$out")"
check "row 29: rm logged no DELETE and wrote no pending line" "0 0" "$(grep -c '^DELETE' "$rlog" || true) $(awk 'NF' "$gpend" | wc -l | tr -d ' ')"
forge ab2901 1000 "access=00000000-0000-4000-8000-000000ab2901 access_rule=email:a@x.io" "$aud64"
out=$(SHARE_ACCESS_DRY_APPS=deny r2g prune 2>&1); rc=$?
check "row 29: prune exits 0 and prints the waiting line" "0 1" "$rc $(grep -c 'expired gated share ab2901 waits for a publisher with the Access token' <<<"$out")"
check "row 29: prune kept the record and the bytes" "1 1" "$([[ -e $DRYA/m/ab2901 ]] && echo 1 || echo 0) $(r2a r2-list o/ab2901. | grep -c .)"

echo "--- row 10: ls with a publisher token keeps an expired gated share; prune with the Access token removes it ---"
plant_g() { mkdir -p "$gdry"; jq -nc --arg id "00000000-0000-4000-8000-000000$1" --arg n "share $1 r2x.example.test 00000${1: -3}" '{id:$id, name:$n}' >"$gdry/00000000-0000-4000-8000-000000$1.json"; }
plant_g ab2901; greset
out=$(G_TOK="" r2g ls 2>&1); rc=$?
check "row 10: ls with no Access token keeps the gated record and names the wait" "0 1 1" "$rc $([[ -e $DRYA/m/ab2901 ]] && echo 1 || echo 0) $(grep -c 'expired gated share ab2901 waits' <<<"$out")"
greset
out=$(r2g prune 2>&1); rc=$?
check "row 10: prune with an Access-capable token exits 0" "0" "$rc"
check "row 10: the gated record, its prefix, and its app are gone" "0 0 0" "$([[ -e $DRYA/m/ab2901 ]] && echo 1 || echo 0) $(r2a r2-list o/ab2901. | grep -c . || true) $([[ -e $gdry/00000000-0000-4000-8000-000000ab2901.json ]] && echo 1 || echo 0)"
check "row 10: the record's 404 read precedes DELETE app" "1" "$([[ $(alast '^GET m/ab2901$') -lt $(aline '^DELETE app 00000000-0000-4000-8000-000000ab2901$') ]] && echo 1 || echo 0)"
r2g rm ab9001 >/dev/null 2>&1

echo "--- row 25b: another publisher takes the id while the add waits in its gate ---"
greset; printf 'fail\nfail\npass\npass\npass\n' >"$gfix"
(SHARE_TEST_IDS=ab25b1 SHARE_ACCESS_POLL=1 r2g add --access email:a@x.io "$WORK/g.txt" >"$WORK/g25b.out" 2>"$WORK/g25b.err"; echo $? >"$WORK/g25b.rc") &
gadd=$!
for _ in $(seq 1 100); do grep -q 'PROBE fail' "$rlog" 2>/dev/null && break; sleep 0.1; done
mkdir -p "$DRYA/m" "$DRYA/o/ab25b1.00000000"; printf 'theirs\n' >"$DRYA/o/ab25b1.00000000/x.txt"
printf '%s\n' '{"v":1,"id":"ab25b1","name":"x.txt","src":"/x","added":"2026-09-30","expires":0,"opts":"","prefix":"o/ab25b1.00000000/","by":"peer"}' >"$DRYA/m/ab25b1"
wait "$gadd"
check "row 25b: the publish answers 412 and the add exits 1 naming it" "1 1" "$(cat "$WORK/g25b.rc") $(grep -c 'another publisher took id ab25b1' "$WORK/g25b.err")"
check "row 25b: the add deleted its app and kept no pending line" "1 0" "$(grep -c '^DELETE app 00000000-0000-4000-8000-000000ab25b1$' "$rlog") $(awk 'NF' "$gpend" | wc -l | tr -d ' ')"
check "row 25b: the other publisher's record and prefix stay; the add's own prefix is gone" "o/ab25b1.00000000/ o/ab25b1.00000000/x.txt" "$(gpfx ab25b1) $(r2a r2-list o/ab25b1. | tr -d '\n')"

echo "--- row 25d: a lost gated publish that committed; the sweep keeps the app ---"
greset
out=$(SHARE_TEST_IDS=ab25d1 SHARE_R2_DRY_PUT=lost-record r2g add --access email:a@x.io "$WORK/g.txt" 2>&1); rc=$?
check "row 25d: the add dies naming the prune" "1 1" "$rc $(grep -c "answered HTTP 000; rerun the same share --profile r2x add (the next 'share --profile r2x prune' with the token settles its Access app)" <<<"$out")"
check "row 25d: the record landed, the trap kept its prefix, the line stays" "1 1 1" "$([[ -e $DRYA/m/ab25d1 ]] && echo 1 || echo 0) $([[ -n $(r2a r2-list "$(gpfx ab25d1)") ]] && echo 1 || echo 0) $(grep -c '^ab25d1	' "$gpend")"
: >"$rlog"
r2g prune >/dev/null 2>&1
check "row 25d: the sweep read the record fresh (after the snapshot's read), dropped the line, deleted no app" "2 0 0" "$(grep -c '^GET m/ab25d1$' "$rlog") $(grep -c '^ab25d1	' "$gpend" || true) $(grep -c '^DELETE app' "$rlog" || true)"
check "row 25d: the share still lists" "1" "$(r2a ls 2>/dev/null | grep -c 'id=ab25d1 ')"
r2g rm ab25d1 >/dev/null 2>&1; r2g rm ab1101 >/dev/null 2>&1

echo "--- DEC-007: share api-token on r2 refuses an admin or account-wide token ---"
mkdir -p "$WORK/r2sec"
cat >"$WORK/r2sec/security" <<'EOF2'
#!/bin/bash
# logs each verb (the -i script's too), never a value; finds nothing
if [[ $1 == -i ]]; then while read -r v _; do echo "$v"; done; else echo "$1"; fi >>"${R2SEC_LOG:?}"
exit 0
EOF2
chmod +x "$WORK/r2sec/security"
: >"$WORK/r2sec.log"
gat() { R2SEC_LOG="$WORK/r2sec.log" PATH="$WORK/r2sec:$PATH" G_TOK="" r2g api-token "$@"; }
out=$(printf 'admintoken' | gat 2>&1); rc=$?
check "api-token: a token that reads the Worker settings is refused as admin" "1 1" "$rc $(grep -c 'it is an admin token' <<<"$out")"
out=$(printf 'widetoken' | SHARE_R2_DRY_ROLE=deny SHARE_R2_DRY_BUCKETS="ok-bucket payout" gat 2>&1); rc=$?
check "api-token: a token that lists another bucket is refused, naming it" "1 1" "$rc $(grep -c 'reaches other buckets (payout): an account-wide R2 token' <<<"$out")"
check "api-token: neither refused token reached the keychain" "0" "$(grep -c . "$WORK/r2sec.log" || true)"
out=$(SHARE_R2_DRY_ROLE=deny SHARE_R2_DRY_BUCKETS="ok-bucket payout" gat --cmd 'printf widetoken' 2>&1); rc=$?
check "api-token --cmd: the command's token is checked before the line is stored" "1 0" "$rc $(grep -c '^api_token_cmd=' "$r2conf" || true)"
out=$(printf 'pubtoken' | SHARE_R2_DRY_ROLE=deny gat 2>&1); rc=$?
check "api-token: a bucket-scoped token is stored, exit 0" "0 1" "$rc $(grep -c '^add-generic-password$' "$WORK/r2sec.log")"
check "api-token: the check names the publisher token" "1" "$(grep -c 'a publisher token for bucket ok-bucket: not an admin token, no other bucket in reach' <<<"$out")"
out=$(CLOUDFLARE_API_TOKEN=admintoken R2SEC_LOG="$WORK/r2sec.log" PATH="$WORK/r2sec:$PATH" SHARE_ACCESS_DRY=1 r2a api-token --check 2>&1); rc=$?
check "api-token --check refuses an admin token too" "1 1" "$rc $(grep -c 'it is an admin token' <<<"$out")"

echo "=== r2 backend: api-token with no argument opens the publisher token form ==="
if command -v expect >/dev/null; then
  cat >"$WORK/tty-r2.exp" <<'EXP'
set timeout 20
log_user 1
spawn bash [lindex $argv 0] --profile r2x api-token
expect {
  "Paste the new token (input hidden): " { send "pubtoken\r" }
  timeout { puts "NO-PROMPT"; exit 2 }
}
expect eof
EXP
  : >"$WORK/r2sec.log"
  out=$(env -u SHARE_ROOT -u SHARE_CONFIG_DIR -u SHARE_PORT -u SHARE_HOSTNAME -u SHARE_SERVICE_LABEL -u XDG_CONFIG_HOME -u SHARE_PROFILE -u SHARE_BACKEND \
    HOME="$R2H" SHARE_TUNNEL=0 SHARE_R2_DRY=1 SHARE_R2_DRY_DIR="$DRYA" SHARE_R2_DRY_ROLE=deny SHARE_ACCESS_DRY=1 SSH_CONNECTION="1.2.3.4 1 5.6.7.8 22" \
    R2SEC_LOG="$WORK/r2sec.log" PATH="$WORK/r2sec:$PATH" expect -f "$WORK/tty-r2.exp" "$SH" 2>&1 | tr -d '\r')
  p_url=$(grep -o 'https://dash.cloudflare.com/[^ ]*' <<<"$out" | head -1)
  check "r2 api-token: the link is the user-token form, not the Access one" "1 0" "$(grep -c '^https://dash.cloudflare.com/profile/api-tokens?permissionGroupKeys=' <<<"$p_url") $(sed '/Paste the new token/q' <<<"$out" | grep -c 'share%20access')"
  check "r2 api-token: the keys decode to Zone Read" '[{"key":"zone","type":"read"}]' "$(urldec "$(sed -n 's/.*permissionGroupKeys=\([^&]*\).*/\1/p' <<<"$p_url")" | jq -c .)"
  check "r2 api-token: the account is the profile's, zones all" "acct all" "$(sed -n 's/.*&accountId=\([^&]*\)&zoneId=\([^&]*\)&.*/\1 \2/p' <<<"$p_url")"
  check "r2 api-token: the name is 'share publisher (r2x)'" "share publisher (r2x)" "$(urldec "$(sed -n 's/.*&name=\([^&]*\).*/\1/p' <<<"$p_url")")"
  check "r2 api-token: the prompt names the bucket permission to add" "1" "$(grep -c 'add Workers R2 Storage Bucket Item Write with the resource bucket ok-bucket only' <<<"$out")"
  check "r2 api-token: the pasted token passed the publisher check and was stored" "1 1" "$(grep -c '^add-generic-password$' "$WORK/r2sec.log") $(grep -c 'a publisher token for bucket ok-bucket' <<<"$out")"
else
  echo "  skip  expect not installed (the pseudo-terminal paste is covered on macOS)"
fi

echo "=== r2 backend: teardown, local and --purge (rows 15, 29) ==="
command cp "$r2conf" "$WORK/r2x.config.keep"
rm -rf "$DRYA"; mkdir -p "$DRYA/.cf"; rm -f "$r2root/r2-own"
printf '{"v":1,"host":"r2x.example.test"}\n' >"$DRYA/share.json"; : >"$DRYA/.cf/bucket"
printf '{"hostname":"r2x.example.test","service":"share-r2x-example-test"}\n' >"$DRYA/.cf/domain.json"
pscript() { # pscript <host>: the deployed Worker's bindings, naming <host> and bucket ok-bucket, TEAM set
  printf '{"bindings":[{"type":"r2_bucket","name":"BUCKET","bucket_name":"ok-bucket"},{"type":"plain_text","name":"HOST","text":"%s"},{"type":"plain_text","name":"VERSION","text":"%s"},{"type":"plain_text","name":"SHA","text":"%s"},{"type":"plain_text","name":"TEAM","text":"team.cloudflareaccess.com"}]}\n' "$1" "$wvg" "$wshag" >"$DRYA/.cf/script.json"
}
pscript r2x.example.test
tsec() { R2SEC_LOG="$WORK/r2sec.log" PATH="$WORK/r2sec:$PATH" "$@"; }   # api_token_forget reaches the stub, never the real keychain
greset
SHARE_TEST_IDS=ab1501 r2a add "$WORK/g.txt" >/dev/null 2>&1
SHARE_TEST_IDS=ab1502 r2g add --access email:a@x.io "$WORK/g.txt" >/dev/null 2>&1
printf 'not json\n' >"$DRYA/m/ab1503"                                                   # a record no share can read
mkdir -p "$DRYA/o/ab1504.0000abcd"; printf 'x\n' >"$DRYA/o/ab1504.0000abcd/f.txt"         # an upload no record names
plant_g ab1509                                                                            # an app parked in a teammate's pending file
check "row 15: the fixture holds an ungated and a gated share" "2" "$(r2a ls 2>/dev/null | grep -c 'id=ab150[12] ')"
bsum() { (cd "$DRYA" && find . -type f ! -path './.cf/*' -exec cksum {} + | LC_ALL=C sort | cksum); }

before="$(bsum)"; : >"$rlog"
out=$(tsec r2a teardown --yes 2>&1); rc=$?
check "row 15: plain teardown exits 0" "0" "$rc"
check "row 15: plain: the config and r2-own are gone" "0 0" "$([[ -e $r2conf ]] && echo 1 || echo 0) $([[ -e $r2root/r2-own ]] && echo 1 || echo 0)"
check "row 15: plain: the bucket is unchanged and no call was logged" "$before 0" "$(bsum) $(grep -c . "$rlog" || true)"
check "row 15: plain: the stored token went, and it says what stays" "1 1" "$(grep -c '^delete-generic-password$' "$WORK/r2sec.log") $(grep -c 'bucket ok-bucket, the Worker, and every share on r2x.example.test stay for the other publishers' <<<"$out")"
mkdir -p "${r2conf%/*}"; command cp "$WORK/r2x.config.keep" "$r2conf"
out=$(r2a teardown 2>&1 </dev/null); rc=$?
check "row 15: teardown without --yes and no terminal refuses" "1 1" "$rc $(grep -c "rerun 'share --profile r2x teardown --yes' to confirm" <<<"$out")"
out=$(r2a teardown --yes --bogus 2>&1); rc=$?
check "row 15: an unknown teardown flag refuses" "1 1" "$rc $(grep -c 'usage: share teardown \[--yes\] \[--purge\]' <<<"$out")"

rpurge() { # rpurge <label> <message> <cmd...>: exit 1, the message, no write logged, the config and bucket untouched
  : >"$rlog"; local b; b="$(bsum)"
  out=$("${@:3}" 2>&1); rc=$?
  check "row 15: $1 exits 1" "1" "$rc"
  check "row 15: $1 named" "1" "$(grep -c -- "$2" <<<"$out")"
  check "row 15: $1 logged nothing past the reads" "0" "$(grep -cE '^(PUT|DELETE) |^API (PUT|DELETE|POST) |^POST app$|^DELETE app' "$rlog" || true)"
  check "row 15: $1 kept the config and the bucket" "1 $b" "$([[ -e $r2conf ]] && echo 1 || echo 0) $(bsum)"
}
G_TOK="" rpurge "--purge with no admin token" "reads the admin token from CLOUDFLARE_API_TOKEN only" tsec r2g teardown --yes --purge
SHARE_R2_DRY_ROLE=deny rpurge "--purge with a publisher token" "purge needs the admin token" tsec r2g teardown --yes --purge
pscript other.example.test
rpurge "--purge with a foreign Worker (bindings name another host)" "is not share's Worker for r2x.example.test on bucket ok-bucket" tsec r2g teardown --yes --purge
pscript r2x.example.test
printf '{"v":1,"host":"other.example.test"}\n' >"$DRYA/share.json"
rpurge "--purge with a marker for another host" "share.json does not name r2x.example.test" tsec r2g teardown --yes --purge
printf '{"v":1,"host":"r2x.example.test"}\n' >"$DRYA/share.json"
SHARE_ACCESS_DRY_APPS=deny rpurge "--purge with a gated record and no Apps Edit (row 29)" "lacks 'Access: Apps and Policies Edit'" tsec r2g teardown --yes --purge

: >"$rlog"
out=$(tsec r2g teardown --yes --purge 2>&1); rc=$?
check "row 15: purge exits 0" "0" "$rc"
check "row 15: purge: every record and object is gone" "0" "$(cd "$DRYA" && { find m o -type f 2>/dev/null | grep -c . || true; })"
check "row 15: purge: the gated share goes first" "1" "$([[ $(aline '^DELETE m/ab1502$') -lt $(aline '^DELETE m/ab1501$') ]] && echo 1 || echo 0)"
check "row 15: purge: the gated share's app and the parked app are deleted" "1 1" "$(grep -c '^DELETE app 00000000-0000-4000-8000-000000ab1502$' "$rlog") $(grep -c '^DELETE app 00000000-0000-4000-8000-000000ab1509$' "$rlog")"
check "row 15: purge: DELETE share.json < domain DELETE < script DELETE < bucket DELETE" "1" \
  "$([[ $(alast '^DELETE o/') -lt $(aline '^DELETE share.json$') && $(aline '^DELETE share.json$') -lt $(aline '^API DELETE /accounts/.*/workers/domains/dom-dry$') &&
      $(aline '^API DELETE /accounts/.*/workers/domains/') -lt $(aline '^API DELETE /accounts/.*/workers/scripts/share-r2x-example-test$') &&
      $(aline '^API DELETE /accounts/.*/workers/scripts/') -lt $(aline '^API DELETE /accounts/.*/r2/buckets/ok-bucket$') ]] && echo 1 || echo 0)"
check "row 15: purge: the marker, domain, script, and bucket are gone" "0 0 0 0" "$([[ -e $DRYA/share.json ]] && echo 1 || echo 0) $([[ -e $DRYA/.cf/domain.json ]] && echo 1 || echo 0) $([[ -e $DRYA/.cf/script.json ]] && echo 1 || echo 0) $([[ -e $DRYA/.cf/bucket ]] && echo 1 || echo 0)"
check "row 15: purge: the dataset line" "1" "$(grep -c '^dataset: the Analytics Engine dataset share_r2x_example_test cannot be deleted; it ages out on its own$' <<<"$out")"
check "row 15: purge: the config is gone and nothing waits in access-pending" "0 0" "$([[ -e $r2conf ]] && echo 1 || echo 0) $(awk 'NF' "$gpend" 2>/dev/null | wc -l | tr -d ' ')"
mkdir -p "${r2conf%/*}"; command cp "$WORK/r2x.config.keep" "$r2conf"

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
check "no token: the block names the Access scope teardown --purge needs" "1" "$(grep -c 'Access: Apps and Policies Edit (teardown --purge needs it' <<<"$out")"
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

echo "=== r2 backend: join as publisher (row 23) ==="
R2J="$WORK/r2join"; mkdir -p "$R2J"
jconf="$R2J/.config/share/profiles/r2s/config"; jlog="$R2J/share/profiles/r2s/r2-calls.log"
r2j() { # r2j [env...]: a second HOME joins r2s.example.test with a publisher token (script and bucket reads answer 403)
  env -u SHARE_ROOT -u SHARE_CONFIG_DIR -u SHARE_PORT -u SHARE_HOSTNAME -u SHARE_SERVICE_LABEL -u XDG_CONFIG_HOME -u SHARE_PROFILE -u SHARE_BACKEND \
    HOME="$R2J" SHARE_TUNNEL=0 SHARE_R2_DRY=1 SHARE_R2_DRY_DIR="$DRYS" CLOUDFLARE_API_TOKEN=pubtoken SHARE_R2_WAIT="${SHARE_R2_WAIT:-2}" \
    SHARE_R2_DRY_ROLE=deny SHARE_R2_DRY_BUCKETDOM=deny "$@" bash "$SH" --profile r2s setup r2s.example.test --backend r2 --bucket ok-bucket
}
jwrites() { grep -cE '^(API (PUT|POST|DELETE) |PUT |DELETE )' "$jlog" || true; }
s_fresh; echo dwarves.cloudflareaccess.com >"$DRYS/.cf/team"
out=$(r2s 2>&1); rc=$?
check "join fixture: admin setup exits 0" "0" "$rc"
jq -c '(.bindings[] | select(.name == "SHA")).text = "000000000000"' "$DRYS/.cf/script.json" >"$DRYS/.cf/s.tmp" && mv -f "$DRYS/.cf/s.tmp" "$DRYS/.cf/script.json"
before="$(objs)"
mkdir -p "${jlog%/*}"; : >"$jlog"
out=$(r2j 2>&1); rc=$?
check "join: exit 0" "0" "$rc"
check "join: role printed" "1" "$(grep -c '^joining as publisher$' <<<"$out")"
check "join: public-route skip printed" "1" "$(grep -c '^public-route check skipped (publisher token)$' <<<"$out")"
check "join: no write logged" "0" "$(jwrites)"
check "join: the marker was read" "1" "$(grep -c '^GET share.json$' "$jlog")"
check "join: no DNS, domain, or Access read" "0" "$(grep -cE 'dns_records|workers/domains|access/organizations' "$jlog" || true)"
check "join: bucket unchanged" "$before" "$(objs)"
check "join: config written" "1" "$(grep -c '^backend=r2$' "$jconf")"
check "join: config bucket and sentinel" "2" "$(grep -cE '^(bucket=ok-bucket|port=r2)$' "$jconf")"
check "join: the version mismatch line" "1" "$(grep -c "runs $wv 000000000000; this share ships $wv $wsha; whoever holds the admin token reruns" <<<"$out")"
check "join: next step names api-token" "1" "$(grep -c 'api-token' <<<"$out")"
rm -f "$jconf" "$DRYS/share.json"; : >"$jlog"
out=$(r2j 2>&1); rc=$?
check "join, no marker: exit 1" "1" "$rc"
check "join, no marker: names the admin step" "1" "$(grep -c 'has no share.json; whoever holds the admin token' <<<"$out")"
check "join, no marker: no write, no config" "0 0" "$(jwrites) $([[ -f $jconf ]] && echo 1 || echo 0)"
rm -f "$DRYS/.cf/bucket"; : >"$jlog"
out=$(r2j SHARE_R2_DRY_BUCKETDOM= 2>&1); rc=$?
check "join, no bucket: exit 1" "1" "$rc"
check "join, no bucket: named" "1" "$(grep -c 'bucket ok-bucket does not exist' <<<"$out")"
s_fresh; out=$(r2s 2>&1); : >"$jlog"
out=$(r2j SHARE_R2_DRY_HEALTHZ=down SHARE_R2_WAIT=1 2>&1); rc=$?
check "join, Worker down: exit 1, no config" "1 0" "$rc $([[ -f $jconf ]] && echo 1 || echo 0)"
rm -f "$s2conf"

echo "=== tenant: per-link storage on the origin (rows 2, 4, 5) ==="
T2H="$WORK/tenant-home"; DRYT="$WORK/tenant-bucket"; mkdir -p "$T2H/.config/share/profiles/org" "$T2H/.config/share/profiles/off" "$DRYT"
torg="$T2H/.config/share/profiles/org/config"; troot="$T2H/share/profiles/org"; tlog="$troot/r2-calls.log"; toffroot="$T2H/share/profiles/off"
printf 'hostname=org.example.test\ntunnel_id=tid-org\ntunnel_name=share-org-example-test\nhosts=not-this-host\nport=%s\nbucket=ok-bucket\nr2_endpoint=https://acct.example.r2.cloudflarestorage.com\nstorage_default=local\n' $((base + 40)) >"$torg"
printf 'hostname=off.example.test\ntunnel_id=tid-off\ntunnel_name=share-off-example-test\nhosts=not-this-host\nport=%s\n' $((base + 42)) >"$T2H/.config/share/profiles/off/config"
tn() { # tn <profile> <verb...>: a tunnel origin under its own HOME on a dry bucket, Access dry; hosts names no machine, so nothing serves
  local p=$1; shift
  env -u SHARE_ROOT -u SHARE_CONFIG_DIR -u SHARE_PORT -u SHARE_HOSTNAME -u XDG_CONFIG_HOME -u SHARE_PROFILE -u SHARE_BACKEND -u SHARE_HOSTS \
    HOME="$T2H" SHARE_TUNNEL=0 SHARE_R2_DRY=1 SHARE_R2_DRY_DIR="$DRYT" SHARE_R2_TOKEN="${TN_TOK-drytoken}" \
    SHARE_ACCESS_DRY=1 SHARE_ACCESS_POLL=0 CLOUDFLARE_API_TOKEN="${TN_CF-faketoken}" bash "$SH" --profile "$p" "$@"
}
tline() { grep -n -- "$1" "$tlog" | head -1 | cut -d: -f1; }
trow() { awk -F'\t' -v id="$1" '$1 == id' "$2/index.tsv" 2>/dev/null; }
tnrows() { [[ -f $1/index.tsv ]] && grep -c . "$1/index.tsv" || echo 0; }
tputs() { grep -c '^PUT ' "$tlog" 2>/dev/null || true; }
mkdir -p "$WORK/tn"; printf '%%PDF-1.4\n' >"$WORK/tn/Report.PDF"; tf="$WORK/tn/Report.PDF"
lport=$((base + 45))
# R2 off: today's add, no bucket call; --cloud is refused with the admin's command
out=$(SHARE_TEST_IDS=f00001 tn off add "$tf" 2>&1); rc=$?
check "row 2: R2 off, add f is local" "0 1 1" "$rc $(trow f00001 "$toffroot" | grep -c .) $([[ -d $toffroot/pub/f00001 ]] && echo 1 || echo 0)"
out=$(SHARE_TEST_IDS=f00002 tn off add --local "$tf" 2>&1); rc=$?
check "row 2: R2 off, add --local f is local" "0 1" "$rc $(trow f00002 "$toffroot" | grep -c .)"
out=$(SHARE_TEST_IDS=f00003 tn off add --cloud "$tf" 2>&1); rc=$?
check "row 2: R2 off, add --cloud f is refused" "1" "$rc"
check "row 2: R2 off, the refusal names the admin's command" "1" "$(grep -c "R2 is off for off.example.test; the tenant admin enables it with 'share --profile off setup off.example.test --r2 --bucket <name>'" <<<"$out")"
check "row 2: R2 off, no bucket call and no new row" "0 2" "$([[ -e $toffroot/r2-calls.log ]] && echo 1 || echo 0) $(tnrows "$toffroot")"
# R2 on, storage_default=local
mkdir -p "$troot"; : >"$tlog"
out=$(SHARE_TEST_IDS=a00001 tn org add "$tf" 2>&1); rc=$?
check "row 2: R2 on, add f is local" "0 1 1" "$rc $(trow a00001 "$troot" | grep -c .) $([[ -d $troot/pub/a00001 ]] && echo 1 || echo 0)"
check "row 2: R2 on, add f writes its pointer" "2 machine Report.PDF pdf " "$(jq -r '"\(.v) \(.storage) \(.name) \(.type) \(.opts)"' "$DRYT/m/a00001" 2>/dev/null)"
check "row 2: the pointer's by and added" "1 $(date +%F)" "$(jq -r '.by' "$DRYT/m/a00001" | grep -c '^[a-z0-9.-]*$') $(jq -r .added "$DRYT/m/a00001")"
out=$(SHARE_TEST_IDS=a00002 tn org add --cloud "$tf" 2>&1); rc=$?
check "row 2: R2 on, add --cloud f is cloud" "0 0 0 1 pdf" "$rc $(trow a00002 "$troot" | grep -c .) $([[ -e $troot/pub/a00002 ]] && echo 1 || echo 0) $(jq -r .v "$DRYT/m/a00002" 2>/dev/null) $(jq -r .type "$DRYT/m/a00002" 2>/dev/null)"
check "row 2: the cloud link" "https://org.example.test/a00002/Report.PDF" "$(grep '^https://' <<<"$out")"
check "row 2: the cloud upload sits under its own prefix" "1" "$(find "$DRYT/o" -path '*/a00002.*/Report.PDF' | grep -c .)"
out=$(SHARE_TEST_IDS=a00003 tn org add "$lport" 2>&1); rc=$?
check "row 2: R2 on, add <port> is live with a pointer" "0 1 2 live site" "$rc $(trow a00003 "$troot" | grep -c .) $(jq -r '"\(.v) \(.opts) \(.type)"' "$DRYT/m/a00003" 2>/dev/null)"
nrows="$(tnrows "$troot")"; nput="$(tputs)"
out=$(SHARE_TEST_IDS=a00009 tn org add --cloud "$lport" 2>&1); rc=$?
check "row 2: R2 on, add --cloud <port> is refused" "1 1" "$rc $(grep -c "live links and --host stay on the origin's tunnel" <<<"$out")"
out=$(SHARE_TEST_IDS=a00009 tn org add --cloud --host x.example.test "$tf" 2>&1); rc=$?
check "row 2: R2 on, add --cloud --host is refused" "1 1" "$rc $(grep -c "live links and --host stay on the origin's tunnel" <<<"$out")"
out=$(SHARE_TEST_IDS=a00009 tn org add --cloud --local "$tf" 2>&1); rc=$?
check "row 2: R2 on, add --cloud --local is a usage error" "1 1" "$rc $(grep -c 'usage: share add' <<<"$out")"
check "row 2: the refusals log no PUT and write no row" "$nput $nrows 0" "$(tputs) $(tnrows "$troot") $([[ -e $DRYT/m/a00009 ]] && echo 1 || echo 0)"
# R2 on, storage_default=cloud
sed -i.bak 's/^storage_default=local$/storage_default=cloud/' "$torg" && rm -f "$torg.bak"
out=$(SHARE_TEST_IDS=a00004 tn org add "$tf" 2>&1); rc=$?
check "row 2: default cloud, add f is cloud" "0 0 1" "$rc $(trow a00004 "$troot" | grep -c .) $(jq -r .v "$DRYT/m/a00004" 2>/dev/null)"
out=$(SHARE_TEST_IDS=a00005 tn org add --local "$tf" 2>&1); rc=$?
check "row 2: default cloud, add --local f is local with a pointer" "0 1 2" "$rc $(trow a00005 "$troot" | grep -c .) $(jq -r .v "$DRYT/m/a00005" 2>/dev/null)"
sed -i.bak 's/^storage_default=cloud$/storage_default=local/' "$torg" && rm -f "$torg.bak"
# row 4: the pointer is the first write; a 412 takes a fresh id; the record carries the gated flag, never the rule or the host
: >"$tlog"; rm -rf "$DRYT/.fx"
out=$(SHARE_TEST_IDS="b00001 b00002" SHARE_R2_DRY_PUT=race-once tn org add --access email:a@example.test "$tf" 2>&1); rc=$?
check "row 4: the gated add exits 0 on the second id" "0 1 0" "$rc $(trow b00002 "$troot" | grep -c .) $(trow b00001 "$troot" | grep -c .)"
check "row 4: GET m/<id> and the prefix scan precede the pointer PUT" "1" "$([[ -n $(tline '^PUT m/b00001$') && $(tline '^GET m/b00001$') -lt $(tline '^LIST o/b00001\.$') && $(tline '^LIST o/b00001\.$') -lt $(tline '^PUT m/b00001$') ]] && echo 1 || echo 0)"
check "row 4: the 412 leaves the other publisher's record (If-None-Match: *)" "1 theirs.txt" "$(jq -r '"\(.v) \(.name)"' "$DRYT/m/b00001")"
check "row 4: the fresh id is checked, then reserved" "1" "$([[ $(tline '^PUT m/b00001$') -lt $(tline '^GET m/b00002$') && $(tline '^GET m/b00002$') -lt $(tline '^PUT m/b00002$') ]] && echo 1 || echo 0)"
check "row 4: the pointer: v:2, machine, gated, no rule, no host" "2 machine gated 0" "$(jq -r '"\(.v) \(.storage) \(.opts)"' "$DRYT/m/b00002") $(grep -c 'access\|host=\|example.test' "$DRYT/m/b00002" || true)"
check "row 4: a gated add's pointer PUT precedes POST app" "1" "$([[ -n $(tline '^POST app$') && $(tline '^PUT m/b00002$') -lt $(tline '^POST app$') ]] && echo 1 || echo 0)"
: >"$tlog"; rm -f "$DRYT/.resume" "$DRYT/.paused"
(SHARE_TEST_IDS=c00001 SHARE_R2_DRY_PAUSE="PUT m/c00001" tn org add "$tf" >/dev/null 2>&1; echo $? >"$WORK/tn/c1.rc") &
for _ in $(seq 1 200); do [[ -f $DRYT/.paused ]] && break; sleep 0.05; done
check "row 4: held at the pointer PUT, pub/<id> does not exist yet" "1 0" "$([[ -f $DRYT/.paused ]] && echo 1 || echo 0) $([[ -e $troot/pub/c00001 ]] && echo 1 || echo 0)"
: >"$DRYT/.resume"; wait "$!"; rm -f "$DRYT/.resume" "$DRYT/.paused"
check "row 4: released, the add publishes" "0 1" "$(cat "$WORK/tn/c1.rc") $([[ -d $troot/pub/c00001 ]] && echo 1 || echo 0)"
# row 5: the pointer PUT fails: nothing is served, no row, no app
for g in "" "--access email:a@example.test"; do
  : >"$tlog"
  # shellcheck disable=SC2086 # $g is zero or two words on purpose
  out=$(SHARE_TEST_IDS=d00001 SHARE_R2_DRY_PUT=500 tn org add $g "$tf" 2>&1); rc=$?
  check "row 5: pointer PUT 500 ${g:+(gated) }exits 1 naming R2" "1 1" "$rc $(grep -c 'R2 did not take the pointer record m/d00001 (HTTP 500' <<<"$out")"
  check "row 5: ${g:+(gated) }no pub/<id>, no row, no app, no stage" "0 0 0 0" "$([[ -e $troot/pub/d00001 ]] && echo 1 || echo 0) $(trow d00001 "$troot" | grep -c .) $(grep -c '^POST app$' "$tlog") $(find "$troot" -maxdepth 1 -name '.stage.*' | grep -c .)"
done
# rm of a local row deletes its own pointer; never a cloud record on the same id; without a token the pointer stays
: >"$tlog"
out=$(tn org rm a00001 2>&1); rc=$?
check "rm: a local row's pointer goes after the row" "0 0 1" "$rc $([[ -e $DRYT/m/a00001 ]] && echo 1 || echo 0) $(grep -c '^DELETE m/a00001$' "$tlog")"
cp "$DRYT/m/a00002" "$WORK/tn/cloud-a00002"; jq -c '.id = "a00005"' "$WORK/tn/cloud-a00002" >"$DRYT/m/a00005"   # a cloud record shadows the local a00005
: >"$tlog"
out=$(tn org rm a00005 2>&1); rc=$?
check "rm: a cloud record on the same id is never deleted" "0 1 0" "$rc $(jq -r .v "$DRYT/m/a00005") $(grep -c '^DELETE m/a00005$' "$tlog")"
: >"$tlog"
out=$(TN_TOK="" TN_CF="" tn org rm a00003 2>&1); rc=$?
check "rm: with no token the pointer stays and is named" "0 2 1" "$rc $(jq -r .v "$DRYT/m/a00003") $(grep -c 'the pointer m/a00003 stays' <<<"$out")"
# api-token on an origin keys the publisher refusals on bucket=, and the Access preflight still runs
: >"$tlog"
out=$(SHARE_R2_DRY_ROLE=deny tn org api-token --check 2>&1); rc=$?
check "api-token, R2-on origin: a publisher token passes and the Access preflight runs" "0 1 1" "$rc $(grep -c 'a publisher token for bucket ok-bucket' <<<"$out") $(grep -c '^GET orgs$' "$tlog")"
mkdir -p "$DRYT/.cf"; echo '{}' >"$DRYT/.cf/script.json"
out=$(tn org api-token --check 2>&1); rc=$?
check "api-token, R2-on origin: an admin token is refused" "1 1" "$rc $(grep -c 'it is an admin token' <<<"$out")"
rm -f "$DRYT/.cf/script.json"

echo "=== tenant: storage dispatch, member refusals, reconcile, sweep (rows 3, 6, 26, 27) ==="
rm -rf "$DRYT" "$troot"; mkdir -p "$DRYT" "$troot"; : >"$tlog"
TMH="$WORK/tenant-member"; mkdir -p "$TMH/.config/share/profiles/org"
printf 'backend=r2\nhostname=org.example.test\nzone=example.test\nbucket=ok-bucket\nport=r2\nr2_endpoint=https://acct.example.r2.cloudflarestorage.com\nr2_key_id=keyid42\n' >"$TMH/.config/share/profiles/org/config"
tm() { # tm <verb...>: a member of the same tenant, an r2 profile on the origin's dry bucket
  env -u SHARE_ROOT -u SHARE_CONFIG_DIR -u SHARE_PORT -u SHARE_HOSTNAME -u XDG_CONFIG_HOME -u SHARE_PROFILE -u SHARE_BACKEND -u SHARE_HOSTS \
    HOME="$TMH" SHARE_TUNNEL=0 SHARE_R2_DRY=1 SHARE_R2_DRY_DIR="$DRYT" SHARE_R2_TOKEN=drytoken \
    SHARE_ACCESS_DRY=1 SHARE_ACCESS_POLL=0 CLOUDFLARE_API_TOKEN=faketoken bash "$SH" --profile org "$@"
}
mlog="$TMH/share/profiles/org/r2-calls.log"; mkdir -p "$TMH/share/profiles/org"
mdel() { grep -c "^DELETE m/$1\$" "$2" 2>/dev/null || true; }
md5of() { [[ -f $1 ]] && r2_md5_of "$1" || echo none; }
r2_md5_of() { if command -v md5 >/dev/null; then md5 -q "$1"; else md5sum "$1" | cut -d' ' -f1; fi; }
printf 'hello\n' >"$WORK/tn/note.txt"; tn2="$WORK/tn/note.txt"
out=$(SHARE_TEST_IDS=e10001 tn org add "$tn2" 2>&1); rc=$?
check "row 3: the origin's local add, with its pointer" "0 2" "$rc $(jq -r .v "$DRYT/m/e10001" 2>/dev/null)"
# row 3: a member publishes cloud links only and never removes, refreshes, or counts a machine link
out=$(SHARE_TEST_IDS=e20001 tm add "$tn2" 2>&1); rc=$?
check "row 3: member add f is cloud" "0 1" "$rc $(jq -r .v "$DRYT/m/e20001" 2>/dev/null)"
out=$(SHARE_TEST_IDS=e20002 tm add --local "$tn2" 2>&1); rc=$?
check "row 3: member add --local f is refused" "1 1" "$rc $(grep -c 'org.example.test serves local links from its origin; this machine publishes cloud links only' <<<"$out")"
out=$(SHARE_TEST_IDS=e20003 tm add "$lport" 2>&1); rc=$?
check "row 3: member add <port> is refused" "1 0" "$rc $([[ -e $DRYT/m/e20003 ]] && echo 1 || echo 0)"
: >"$mlog"
out=$(tm rm e10001 2>&1); rc=$?
check "row 3: member rm of a machine row is refused" "1 1" "$rc $(grep -c "e10001 is served from the tenant's origin; remove it there" <<<"$out")"
check "row 3: no DELETE m/<id>, the pointer stays" "0 2" "$(mdel e10001 "$mlog") $(jq -r .v "$DRYT/m/e10001")"
: >"$mlog"
out=$(tm refresh e10001 2>&1); rc=$?
check "row 3: member refresh of a machine row is refused" "1 1 0" "$rc $(grep -c "e10001 is served from the tenant's origin; remove it there" <<<"$out") $(grep -c '^PUT\|^DELETE' "$mlog")"
: >"$mlog"
out=$(tm hits e10001 2>&1); rc=$?
check "row 3: member hits keeps one account call and no bucket read (SPEC-007 row 13)" "0 0 1" "$rc $(grep -c '^GET' "$mlog") $(grep -c '^SQL' "$mlog")"
check "row 3: member hits of a machine id never prints a bare 0" "0 hits, 0 visitors|this machine counts cloud links only; if e10001 is a machine link, its stats are on the tenant's origin: share --profile org hits e10001 there" "$(paste -sd'|' - <<<"$out")"
out=$(tm hits e20001 2>&1)
check "row 3: member hits of its own cloud link is the bare count" "0 hits, 0 visitors" "$out"
: >"$mlog"
out=$(tm rm e20001 2>&1); rc=$?
check "row 3: member rm of a cloud row runs the r2 path" "0 1 0" "$rc $(mdel e20001 "$mlog") $([[ -e $DRYT/m/e20001 ]] && echo 1 || echo 0)"
# row 27: on the origin each verb dispatches on the row's storage
out=$(SHARE_TEST_IDS=e30001 tn org add --cloud "$tn2" 2>&1); rc=$?
check "row 27: the origin's cloud add" "0 1" "$rc $(jq -r .v "$DRYT/m/e30001" 2>/dev/null)"
idx0="$(md5of "$troot/index.tsv")"; cad0="$(md5of "$troot/Caddyfile")"
mkdir -p "$DRYT/.cf"; printf '{"meta":[],"data":[{"hits":"3","visitors":"2","last":"2026-10-01 10:00:00"}],"rows":1}' >"$DRYT/.cf/sql.json"
: >"$tlog"
out=$(tn org hits e30001 2>&1); rc=$?
check "row 27: hits of a cloud row reads Analytics Engine" "0 1 1" "$rc $(grep -c "^SQL .*index1 = 'e30001'" "$tlog") $(grep -c '^3 hits, 2 visitors' <<<"$out")"
: >"$tlog"
out=$(tn org hits e10001 2>&1); rc=$?
check "row 27: hits of a machine row reads the access log" "0 0 0 hits" "$rc $(grep -c '^SQL' "$tlog") $out"
rm -f "$DRYT/.cf/sql.json"
out=$(tn org hits e9e9e9 2>&1); rc=$?
check "row 27: hits of an unknown id" "1 1" "$rc $(grep -c "no share with id 'e9e9e9'" <<<"$out")"
: >"$tlog"; p0="$(jq -r .prefix "$DRYT/m/e30001")"
out=$(tn org refresh e30001 2>&1); rc=$?
check "row 27: refresh of a cloud row swaps its prefix" "0 1 1" "$rc $(grep -c '^refreshed e30001 from' <<<"$out") $([[ $(jq -r .prefix "$DRYT/m/e30001") != "$p0" ]] && echo 1 || echo 0)"
check "row 27: the cloud refresh ran S3 calls under If-Match" "1" "$(grep -c '^PUT m/e30001$' "$tlog")"
: >"$tlog"
out=$(tn org refresh e10001 2>&1); rc=$?
check "row 27: refresh of a machine row re-copies locally, no S3 write" "0 1 0" "$rc $(grep -c '^refreshed e10001 from' <<<"$out") $(grep -c '^PUT\|^DELETE' "$tlog")"
: >"$tlog"
out=$(tn org rm e30001 2>&1); rc=$?
check "row 27: rm of a cloud row takes the r2 path" "0 1 0 1" "$rc $(mdel e30001 "$tlog") $([[ -e $DRYT/m/e30001 ]] && echo 1 || echo 0) $(grep -c '^unpublished e30001$' <<<"$out")"
check "row 27: the cloud upload is gone" "0" "$(find "$DRYT/o" -path '*/e30001.*' -type f | grep -c .)"
check "row 27: the cloud rm never wrote index.tsv or the Caddyfile" "$idx0 $cad0" "$(md5of "$troot/index.tsv") $(md5of "$troot/Caddyfile")"
: >"$tlog"
out=$(tn org rm e10001 2>&1); rc=$?
check "row 27: rm of a machine row takes the tunnel path plus the pointer DELETE" "0 1 0 0" "$rc $(mdel e10001 "$tlog") $(trow e10001 "$troot" | grep -c .) $([[ -e $troot/pub/e10001 ]] && echo 1 || echo 0)"
# the origin's cloud expiry runs through its own reader: a cloud row expires, index.tsv is never written
out=$(SHARE_TEST_IDS=e40001 tn org add "$tn2" 2>&1)
jq -nc '{v: 1, id: "e00001", name: "f.txt", src: "/elsewhere/f.txt", added: "2026-09-01", expires: 1000, opts: "", prefix: "o/e00001.00000001/", by: "peer"}' >"$DRYT/m/e00001"
mkdir -p "$DRYT/o/e00001.00000001"; printf 'x\n' >"$DRYT/o/e00001.00000001/f.txt"
idx0="$(md5of "$troot/index.tsv")"; cad0="$(md5of "$troot/Caddyfile")"
out=$(tn org ls 2>&1); rc=$?
check "origin ls: an expired cloud record expires" "0 1 0" "$rc $(grep -c '^unpublished e00001 (expired)$' <<<"$out") $([[ -e $DRYT/m/e00001 ]] && echo 1 || echo 0)"
check "origin ls: index.tsv and the Caddyfile are untouched by the cloud expiry" "$idx0 $cad0" "$(md5of "$troot/index.tsv") $(md5of "$troot/Caddyfile")"
check "origin ls: the local row still lists" "1" "$(grep -c 'id=e40001' <<<"$out")"
# a member's prune deletes a machine pointer past its expiry, never a live one
jq -nc '{v: 2, id: "e50001", storage: "machine", name: "old.txt", by: "mac-mini", added: "2026-09-01", expires: 1000, opts: "", type: "text"}' >"$DRYT/m/e50001"
: >"$mlog"
out=$(tm prune 2>&1); rc=$?
check "member prune: the expired pointer goes, the live one stays" "0 1 1 2" "$rc $(grep -c '^removed expired pointer m/e50001$' <<<"$out") $(mdel e50001 "$mlog") $(jq -r .v "$DRYT/m/e40001")"
# row 6: the origin's reconcile on ls
rm -rf "$DRYT" "$troot"; mkdir -p "$DRYT" "$troot"
out=$(SHARE_TEST_IDS=f10001 tn org add "$tn2" 2>&1); rm -f "$DRYT/m/f10001"   # a local row with no pointer (an older CLI added it)
out=$(SHARE_TEST_IDS=f10002 tn org add "$tn2" 2>&1)   # a local row whose id holds a cloud record (a pre-existing collision)
jq -nc '{v: 1, id: "f10002", name: "x.txt", src: "/x", added: "2026-09-01", expires: 0, opts: "", prefix: "o/f10002.00000002/", by: "peer"}' >"$DRYT/m/f10002"
orphan() { jq -nc --arg id "$1" --arg by "$2" '{v: 2, id: $id, storage: "machine", name: "gone.txt", by: $by, added: "2026-09-01", expires: 0, opts: "", type: "text"}' >"$DRYT/m/$1"; aged "$3" "$DRYT/m/$1"; }
orphan f20001 "$(uname -n | cut -d. -f1 | tr '[:upper:]' '[:lower:]')" 660
orphan f20002 other-mac 660
orphan f20003 other-mac 60
orphan f20004 other-mac 660; printf 'f20004\t-:0000abcd\t0\t-\t%s\n' "$(date +%s)" >>"$troot/access-pending"
orphan f20005 other-mac 660; ln -s "$$" "$troot/.lock-add-f20005"
: >"$tlog"
out=$(tn org ls 2>&1); rc=$?
check "row 6: ls exits 0" "0" "$rc"
check "row 6: both old orphan pointers deleted" "1 1 2" "$(mdel f20001 "$tlog") $(mdel f20002 "$tlog") $(grep -c '^removed orphan pointer m/f2000[12]$' <<<"$out")"
check "row 6: the young, the pending, and the held one kept" "2 2 2 0" "$(jq -r .v "$DRYT/m/f20003") $(jq -r .v "$DRYT/m/f20004") $(jq -r .v "$DRYT/m/f20005") $(grep -c '^DELETE m/f2000[345]$' "$tlog")"
check "row 6: a pointer written for the bare row (If-None-Match, its own added date)" "2 machine note.txt text $(date +%F)" "$(jq -r '"\(.v) \(.storage) \(.name) \(.type) \(.added)"' "$DRYT/m/f10001" 2>/dev/null)"
check "row 6: the shadow is named, nothing written or deleted" "1 1 0 0" "$(grep -c 'f10002 is shadowed by a cloud link; rm one of them' <<<"$out") $(jq -r .v "$DRYT/m/f10002") $(grep -c '^PUT m/f10002$' "$tlog") $(mdel f10002 "$tlog")"
rm -f "$troot/.lock-add-f20005"
# rm and prune of local rows: the pointer goes with a token, stays without one
out=$(SHARE_TEST_IDS=f30001 tn org add "$tn2" 2>&1); out=$(SHARE_TEST_IDS=f30002 tn org add "$tn2" 2>&1)
awk -F'\t' 'BEGIN {OFS = "\t"} $1 == "f30001" || $1 == "f30002" {$5 = 1000} {print}' "$troot/index.tsv" >"$troot/index.tmp" && mv "$troot/index.tmp" "$troot/index.tsv"
out=$(TN_TOK="" TN_CF="" tn org prune 2>&1); rc=$?
check "row 6: prune with no token expires both rows, the pointers stay" "0 0 2 2" "$rc $(trow f30001 "$troot" | grep -c .) $(jq -r .v "$DRYT/m/f30001") $(jq -r .v "$DRYT/m/f30002")"
check "row 6: prune with no token says the cloud side was not checked" "1" "$(grep -c 'were not checked: no publisher token' <<<"$out")"
out=$(SHARE_TEST_IDS=f30003 tn org add "$tn2" 2>&1)
awk -F'\t' 'BEGIN {OFS = "\t"} $1 == "f30003" {$5 = 1000} {print}' "$troot/index.tsv" >"$troot/index.tmp" && mv "$troot/index.tmp" "$troot/index.tsv"
: >"$tlog"
out=$(tn org prune 2>&1); rc=$?
check "row 6: prune with a token deletes the expired row's pointer" "0 1 0" "$rc $(mdel f30003 "$tlog") $([[ -e $DRYT/m/f30003 ]] && echo 1 || echo 0)"
# row 26: pointers never block the orphan sweep, on the origin and on a member
rm -rf "$DRYT" "$troot"; mkdir -p "$DRYT" "$troot"
out=$(SHARE_TEST_IDS=d10001 tn org add "$tn2" 2>&1)
mkdir -p "$DRYT/o/d20001.00000001"; printf 'x\n' >"$DRYT/o/d20001.00000001/f.txt"; aged 90000 "$DRYT/o/d20001.00000001/f.txt"
: >"$tlog"
out=$(tn org prune 2>&1); rc=$?
check "row 26: origin prune with a pointer present sweeps the old upload" "0 1 0" "$rc $(grep -c '^removed orphan upload o/d20001.00000001/$' <<<"$out") $(grep -c 'orphan sweep skipped' <<<"$out")"
mkdir -p "$DRYT/o/d20002.00000002"; printf 'x\n' >"$DRYT/o/d20002.00000002/f.txt"; aged 90000 "$DRYT/o/d20002.00000002/f.txt"
out=$(tm prune 2>&1); rc=$?
check "row 26: member prune with a pointer present sweeps the old upload" "0 1 0" "$rc $(grep -c '^removed orphan upload o/d20002.00000002/$' <<<"$out") $(grep -c 'orphan sweep skipped' <<<"$out")"
printf 'not json\n' >"$DRYT/m/d30001"
mkdir -p "$DRYT/o/d20003.00000003"; printf 'x\n' >"$DRYT/o/d20003.00000003/f.txt"; aged 90000 "$DRYT/o/d20003.00000003/f.txt"
: >"$tlog"
out=$(tn org prune 2>&1); rc=$?
check "row 26: a record that is not JSON skips the sweep and is named" "0 0 1" "$rc $(grep -c '^DELETE o/' "$tlog") $(grep -c 'orphan sweep skipped: m/d30001' <<<"$out")"
rm -f "$DRYT/m/d30001"
# the access sweep decides per id: a stale line of a published gated cloud link keeps its app
uuid="00000000-0000-4000-8000-0000000c0001"
jq -nc --arg u "$uuid" --arg a "$aud64" '{v: 1, id: "c00c01", name: "f.txt", src: "/x", added: "2026-09-01", expires: 0, opts: ("access=" + $u + " access_rule=email:a@example.test"), prefix: "o/c00c01.0000000c/", by: "peer", aud: $a}' >"$DRYT/m/c00c01"
mkdir -p "$troot/.access-dry"; jq -nc --arg u "$uuid" '{id: $u, name: "share c00c01 org.example.test 0000000c", aud: "x"}' >"$troot/.access-dry/$uuid.json"
printf 'c00c01\t%s\t0\t-\t%s\n' "$uuid" "$(date +%s)" >>"$troot/access-pending"
: >"$tlog"
out=$(tn org prune 2>&1); rc=$?
check "sweep: a published gated cloud link's stale line is dropped, its app kept" "0 0 1 0" "$rc $(grep -c "^DELETE app $uuid" "$tlog") $([[ -f $troot/.access-dry/$uuid.json ]] && echo 1 || echo 0) $(grep -c '^c00c01' "$troot/access-pending")"
rm -f "$DRYT/m/c00c01"
# api-token warns 14 days before the publisher token expires
fut() { date -u -v+"$1"d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "+$1 days" +%Y-%m-%dT%H:%M:%SZ; }
out=$(SHARE_R2_DRY_ROLE=deny SHARE_R2_DRY_EXPIRES="$(fut 5)" tn org api-token --check 2>&1); rc=$?
check "expiry: an origin token five days from expiry warns" "0 1" "$rc $(grep -Ec 'the publisher token expires on [0-9-]{10} \(in [45] days\); then every add to org.example.test fails' <<<"$out")"
out=$(SHARE_R2_DRY_ROLE=deny SHARE_R2_DRY_EXPIRES="$(fut 60)" tn org api-token --check 2>&1); rc=$?
check "expiry: sixty days out says nothing" "0 0" "$rc $(grep -c 'the publisher token expire' <<<"$out")"
out=$(SHARE_R2_DRY_ROLE=deny SHARE_R2_DRY_EXPIRES="2026-01-01T00:00:00Z" tm api-token --check 2>&1); rc=$?
check "expiry: a member token already expired says so" "0 1" "$rc $(grep -c 'the publisher token expired on 2026-01-01' <<<"$out")"

echo "=== tenant: the Worker is up while the origin is off (row 29) ==="
# the dry Worker answers 503 with this CLI's pair and X-Share-Tunnel: 0; r2_healthz reads the headers, never the status alone
rm -rf "$DRYA"; mkdir -p "$DRYA/.cf"; rm -f "$r2root/r2-own"
printf '{"hostname":"r2x.example.test","service":"share-r2x-example-test"}\n' >"$DRYA/.cf/domain.json"
gteam team.cloudflareaccess.com
for mode in tunnel-down 503-bare; do
  out=$(SHARE_R2_DRY_HEALTHZ=$mode r2a state 2>/dev/null); rc=$?
  check "row 29 ($mode): state" "$([[ $mode == tunnel-down ]] && echo '0 true' || echo '0 false')" "$rc $(jq -r .ready <<<"$out")"
  greset; printf 'pass\npass\npass\n' >"$gfix"
  out=$(SHARE_R2_DRY_HEALTHZ=$mode SHARE_TEST_IDS=ab2901 r2g add --access email:A@x.io "$WORK/g.txt" 2>&1); rc=$?
  if [[ $mode == tunnel-down ]]; then
    check "row 29 (tunnel-down): a member's gated add publishes" "0 https://r2x.example.test/ab2901/g.txt 1" "$rc $(grep '^https://' <<<"$out") $(jq -r .v "$DRYA/m/ab2901" 2>/dev/null)"
  else
    check "row 29 (503-bare): the gated add fails before any write" "1 1 0" "$rc $(grep -c 'healthz answered 503; nothing was published' <<<"$out") $(grep -c '^PUT' "$rlog")"
  fi
  s_fresh; echo dwarves.cloudflareaccess.com >"$DRYS/.cf/team"; out=$(r2s 2>&1)
  rm -f "$jconf"; mkdir -p "${jlog%/*}"; : >"$jlog"
  out=$(r2j SHARE_R2_DRY_HEALTHZ=$mode SHARE_R2_WAIT=1 2>&1); rc=$?
  check "row 29 ($mode): a member joins" "$([[ $mode == tunnel-down ]] && echo '0 1' || echo '1 0')" "$rc $([[ -f $jconf ]] && echo 1 || echo 0)"
done
rm -f "$jconf" "$s2conf"

echo "=== tenant: setup --r2 and --no-r2 on the origin (rows 11, 12, 13, 32) ==="
T5H="$WORK/tenant-admin"; DRYV="$WORK/tenant-admin-bucket"
vdir="$T5H/.config/share/profiles/ten"; vconf="$vdir/config"; vroot="$T5H/share/profiles/ten"; vlog="$vroot/r2-calls.log"
tv() { # tv <verb...>: the tunnel origin of ten.example.test with the admin token; hosts names this machine only through SHARE_HOSTS (TV_HOSTS=nobody for adds, so nothing serves)
  env -u SHARE_ROOT -u SHARE_CONFIG_DIR -u SHARE_PORT -u SHARE_HOSTNAME -u XDG_CONFIG_HOME -u SHARE_PROFILE -u SHARE_BACKEND \
    HOME="$T5H" SHARE_TUNNEL=0 SHARE_R2_DRY=1 SHARE_R2_DRY_DIR="$DRYV" SHARE_R2_TOKEN=drytoken SHARE_ACCESS_DRY=1 SHARE_ACCESS_POLL=0 \
    CLOUDFLARE_API_TOKEN="${TV_TOK-admintoken}" SHARE_R2_WAIT="${SHARE_R2_WAIT:-2}" SHARE_HOSTS="${TV_HOSTS-$SHARE_HOSTS}" bash "$SH" --profile ten "$@"
}
tvsetup() { tv setup ten.example.test --r2 --bucket ok-bucket; }
vwrites() { grep -cE '^(API (PUT|POST|DELETE) |PUT |DELETE )' "$vlog" 2>/dev/null || true; }
vord() { # vord <pattern>...: 1 when each first match in the setup log sits below the previous one
  local p prev=0 n
  for p in "$@"; do n="$(grep -n -- "$p" "$vlog" | head -1 | cut -d: -f1)"; [[ -n $n && $n -gt $prev ]] || { echo "0 at $p"; return; }; prev=$n; done
  echo 1
}
vfresh() { # the origin with three local rows (a file, a live port, a gated file) and R2 off; the bucket exists with its marker and one member's cloud link
  rm -rf "$T5H" "$DRYV"; mkdir -p "$vdir" "$DRYV/.cf" "$DRYV/m" "$DRYV/o/0b0001.0000000b"
  printf 'hostname=ten.example.test\ntunnel_id=tid-ten\ntunnel_name=share-ten-example-test\nauth=api\nhosts=nobody\nport=%s\n' $((base + 50)) >"$vconf"
  SHARE_TEST_IDS=0a0001 TV_HOSTS=nobody tv add "$tn2" >/dev/null 2>&1
  SHARE_TEST_IDS=0a0002 TV_HOSTS=nobody tv add $((base + 55)) >/dev/null 2>&1
  mkdir -p "$vroot/pub/0a0003"; printf 'g\n' >"$vroot/pub/0a0003/g.txt"
  printf '0a0003\tg.txt\t/x/g.txt\t2026-10-01\t0\taccess=00000000-0000-4000-8000-0000000a0003 access_rule=email:a@example.test\n' >>"$vroot/index.tsv"
  : >"$DRYV/.cf/bucket"; printf '{"v":1,"host":"ten.example.test"}\n' >"$DRYV/share.json"
  printf 'x\n' >"$DRYV/o/0b0001.0000000b/f.txt"
  jq -nc '{v: 1, id: "0b0001", name: "f.txt", src: "/m/f.txt", added: "2026-10-01", expires: 0, opts: "", prefix: "o/0b0001.0000000b/", by: "member"}' >"$DRYV/m/0b0001"
  : >"$vlog"
}
vfresh
cp "$vconf" "$WORK/ten.config.before"; cp "$vroot/index.tsv" "$WORK/ten.index.before"; sec0="$(grep -c 'add-generic' "$STUBSEC_LOG" || true)"
check "row 11 fixture: three local rows, R2 off, no pointer" "3 0" "$(tnrows "$vroot") $(find "$DRYV/m" -name '0a*' | grep -c .)"
out=$(tvsetup 2>&1); rc=$?
check "row 11: setup --r2 exits 0" "0" "$rc"
check "row 11: the call order" "1" "$(vord '^API GET /accounts/acct-dry/workers/scripts/share-ten-example-test/settings$' '^API GET /accounts/acct-dry/r2/buckets/ok-bucket$' \
  '^GET share.json$' '^API GET /zones/zone-dry/workers/routes$' '^LIST m/$' '^API PUT /accounts/acct-dry/workers/scripts/share-ten-example-test$' \
  '^API POST .*/subdomain$' '^API GET .*/subdomain$' '^PUT m/0a000' '^CONFIG r2 on$' '^API POST /zones/zone-dry/workers/routes$' '^HEALTHZ$' '^TUNNEL-PROBE$')"
check "row 11: every pointer PUT precedes the config write" "1" "$([[ $(grep -n '^PUT m/' "$vlog" | tail -1 | cut -d: -f1) -lt $(grep -n '^CONFIG' "$vlog" | cut -d: -f1) ]] && echo 1 || echo 0)"
check "row 11: config gains the four keys" "bucket=ok-bucket|r2_endpoint=https://acct-dry.r2.cloudflarestorage.com|storage_default=local|aliases=|" \
  "$(grep -E '^(bucket|r2_endpoint|storage_default|aliases)=' "$vconf" | tr '\n' '|')"
check "row 11: the tunnel config lines are unchanged" "$(cat "$WORK/ten.config.before")" "$(grep -vE '^(bucket|r2_endpoint|storage_default|aliases)=' "$vconf")"
check "row 11: no Keychain item written" "$sec0" "$(grep -c 'add-generic' "$STUBSEC_LOG" || true)"
check "row 11: a pointer per local row (file, live site, gated flag)" "2 machine text |2 machine site live|2 machine text gated|" \
  "$(for i in 0a0001 0a0002 0a0003; do jq -r '"\(.v) \(.storage) \(.type) \(.opts)"' "$DRYV/m/$i"; done | tr '\n' '|')"
check "row 11: the Worker binds PASS and an empty ALIASES" "PASS=1 ALIASES=" "$(jq -r '[.bindings[] | select(.name == "PASS" or .name == "ALIASES") | "\(.name)=\(.text)"] | join(" ")' "$DRYV/.cf/script.json")"
check "row 11: the route fails open and names the Worker" "ten.example.test/* share-ten-example-test true" "$(jq -r '.[0] | "\(.pattern) \(.script) \(.request_limit_fail_open)"' "$DRYV/.cf/routes.json")"
check "row 11: the member's cloud record is untouched" "1 member" "$(jq -r '"\(.v) \(.by)"' "$DRYV/m/0b0001")"
# a rerun converges: nothing deployed, written, or attached again
cp "$vconf" "$WORK/ten.config.on"; : >"$vlog"
out=$(tvsetup 2>&1); rc=$?
check "rerun: exit 0, no script PUT, no pointer PUT, no route POST" "0 0 0 0" "$rc $(grep -c '^API PUT .*/workers/scripts/' "$vlog") $(grep -c '^PUT m/' "$vlog") $(grep -c '^API POST /zones/' "$vlog")"
check "rerun: the config is the same" "$(cat "$WORK/ten.config.on")" "$(cat "$vconf")"
# a member's join sees the tenant Worker; the version hint names the tenant command; a member purge is refused
TVM="$WORK/tenant-admin-member"; mkdir -p "$TVM"
tvm() { env -u SHARE_ROOT -u SHARE_CONFIG_DIR -u SHARE_PORT -u SHARE_HOSTNAME -u XDG_CONFIG_HOME -u SHARE_PROFILE -u SHARE_BACKEND -u SHARE_HOSTS \
  HOME="$TVM" SHARE_TUNNEL=0 SHARE_R2_DRY=1 SHARE_R2_DRY_DIR="$DRYV" CLOUDFLARE_API_TOKEN="${TVM_TOK-pubtoken}" SHARE_R2_WAIT=2 ${TVM_ENV[@]+"${TVM_ENV[@]}"} bash "$SH" --profile ten "$@"; }
jq -c '(.bindings[] | select(.name == "SHA")).text = "000000000000"' "$DRYV/.cf/script.json" >"$DRYV/.cf/s.tmp" && cp "$DRYV/.cf/script.json" "$WORK/ten.script" && mv -f "$DRYV/.cf/s.tmp" "$DRYV/.cf/script.json"
TVM_ENV=(SHARE_R2_DRY_ROLE=deny SHARE_R2_DRY_BUCKETDOM=deny)
out=$(tvm setup ten.example.test --backend r2 --bucket ok-bucket 2>&1); rc=$?
check "join: a member joins a tenant; the hint names --r2 on the origin" "0 1" "$rc $(grep -c "runs '.* setup ten.example.test --r2 --bucket ok-bucket' on the tenant's origin" <<<"$out")"
cp "$WORK/ten.script" "$DRYV/.cf/script.json"; TVM_ENV=(); : >"$TVM/share/profiles/ten/r2-calls.log"
out=$(TVM_TOK=admintoken tvm teardown --yes --purge 2>&1); rc=$?
check "purge: a member purge of a tenant is refused before any write" "1 1 0" "$rc $(grep -c "its origin runs 'share --profile ten setup ten.example.test --no-r2' first" <<<"$out") $(grep -cE '^(API (PUT|POST|DELETE) |PUT |DELETE )' "$TVM/share/profiles/ten/r2-calls.log" || true)"
# row 13: --no-r2 is the rollback without an alias
: >"$vlog"
out=$(tv setup ten.example.test --no-r2 2>&1); rc=$?
check "row 13: --no-r2 exits 0 and deletes the route" "0 1 0" "$rc $(grep -c '^API DELETE /zones/zone-dry/workers/routes/route-1$' "$vlog") $(jq length "$DRYV/.cf/routes.json")"
check "row 13: the config is the one before setup --r2" "$(cat "$WORK/ten.config.before")" "$(cat "$vconf")"
: >"$vlog"
out=$(SHARE_TEST_IDS=0a0004 TV_HOSTS=nobody tv add "$tn2" 2>&1); rc=$?
check "row 13: the next add writes no pointer" "0 0" "$rc $(grep -c '^PUT m/' "$vlog" 2>/dev/null || true)"
check "row 13: index.tsv equals the one before setup --r2 plus that add" "$(cat "$WORK/ten.index.before")" "$(grep -v '^0a0004' "$vroot/index.tsv")"
check "row 13: the bucket, its records, and the Worker stay" "1 1 1" "$([[ -f $DRYV/m/0a0001 ]] && echo 1 || echo 0) $([[ -f $DRYV/m/0b0001 ]] && echo 1 || echo 0) $([[ -f $DRYV/.cf/script.json ]] && echo 1 || echo 0)"
# fresh bucket: the bucket and its marker come before any pointer
vfresh; rm -rf "$DRYV/m" "$DRYV/o" "$DRYV/share.json" "$DRYV/.cf/bucket"
out=$(tvsetup 2>&1); rc=$?
check "row 11 (fresh bucket): exit 0, bucket POST < marker PUT < script PUT < pointer PUTs < config < route" "0 1" \
  "$rc $(vord '^API POST /accounts/acct-dry/r2/buckets$' '^PUT share.json$' '^API PUT .*/workers/scripts/share-ten-example-test$' '^PUT m/0a000' '^CONFIG r2 on$' '^API POST /zones/zone-dry/workers/routes$')"
check "row 11 (fresh bucket): no m/ list on a bucket that did not exist" "0" "$(grep -c '^LIST m/' "$vlog")"
# row 12: refusals, each before any write
vrefuse() { # vrefuse <label> <message> <env...>: setup --r2 dies naming it, with no PUT, POST, or DELETE logged
  local label=$1 msg=$2; shift 2
  : >"$vlog"
  # shellcheck disable=SC2163 # each argument is a NAME=value pair to export, on purpose
  out=$(export "$@"; tvsetup 2>&1); rc=$?
  check "row 12: $label is refused before any write" "1 1 0" "$rc $(grep -c -- "$msg" <<<"$out") $(vwrites)"
}
vfresh
vrefuse "a non-origin" "run this on the origin, nobody" TV_HOSTS=nobody
vrefuse "a publisher token" "only the tenant admin enables R2" SHARE_R2_DRY_ROLE=deny
printf '[{"id":"route-9","pattern":"*.example.test/*","script":"other-worker","request_limit_fail_open":false}]\n' >"$DRYV/.cf/routes.json"
vrefuse "a wider route naming another script" "Worker route \*.example.test/\* names script other-worker" X=1
rm -f "$DRYV/.cf/routes.json"
jq -c '.id = "0a0001" | .prefix = "o/0a0001.0000000b/"' "$DRYV/m/0b0001" >"$DRYV/m/0a0001"
vrefuse "a local id holding a cloud record" "local links 0a0001 share an id with a record in bucket ok-bucket" X=1
rm -f "$DRYV/m/0a0001"
printf '{"v":1,"host":"third.example.test"}\n' >"$DRYV/share.json"
vrefuse "a marker naming a third host" "share.json names another hostname" X=1
printf '{"v":1,"host":"ten.example.test"}\n' >"$DRYV/share.json"
printf 'mode=quick\nport=%s\nhosts=nobody\n' $((base + 50)) >"$vconf"
: >"$vlog"; out=$(tv setup ten.example.test --r2 --bucket ok-bucket 2>&1); rc=$?
check "row 12: quick mode is refused before any call" "1 1 0" "$rc $(grep -c 'is a quick tunnel; R2 needs a named tunnel tenant' <<<"$out") $(grep -c . "$vlog" || true)"
# row 32: SPEC-007's r2 setup refuses a tenant host, even with --force; a 403 on the routes read alone is tolerated
s_fresh; echo dwarves.cloudflareaccess.com >"$DRYS/.cf/team"; out=$(r2s 2>&1)
jq -c '.bindings += [{"type": "plain_text", "name": "PASS", "text": "1"}, {"type": "plain_text", "name": "ALIASES", "text": ""}]' "$DRYS/.cf/script.json" >"$DRYS/.cf/s.tmp" && mv -f "$DRYS/.cf/s.tmp" "$DRYS/.cf/script.json"
: >"$slog"; out=$(r2s --force 2>&1); rc=$?
check "row 32: a tenant Worker (PASS) is refused with --force, before any write" "1 1 0" "$rc $(grep -c "run 'share --profile r2s setup r2s.example.test --r2 --bucket ok-bucket' on the origin" <<<"$out") $(grep -cE '^(API (PUT|POST|DELETE) |PUT |DELETE )' "$slog" || true)"
s_fresh; out=$(r2s 2>&1)
printf '{"v":1,"host":"r2s.example.test","aliases":["f.example.test"]}\n' >"$DRYS/share.json"
: >"$slog"; out=$(r2s --force 2>&1); rc=$?
check "row 32: a marker holding aliases is refused with --force, before any write" "1 1 0" "$rc $(grep -c 'its marker holds aliases' <<<"$out") $(grep -cE '^(API (PUT|POST|DELETE) |PUT |DELETE )' "$slog" || true)"
s_fresh; out=$(r2s 2>&1)
printf '[{"id":"route-1","pattern":"r2s.example.test/*","script":"share-r2s-example-test","request_limit_fail_open":true}]\n' >"$DRYS/.cf/routes.json"
: >"$slog"; out=$(r2s --force 2>&1); rc=$?
check "row 32: a route on <host>/* is refused with --force, before any write" "1 1 0" "$rc $(grep -c 'has a Worker route on r2s.example.test/\*' <<<"$out") $(grep -cE '^(API (PUT|POST|DELETE) |PUT |DELETE )' "$slog" || true)"
s_fresh; : >"$slog"; out=$(SHARE_R2_DRY_ROUTES=deny r2s 2>&1); rc=$?
check "row 32: a 403 on the routes read alone is tolerated" "0 1" "$rc $(grep -c '^API GET /zones/zone-dry/workers/routes$' "$slog")"
s_fresh; rm -f "$s2conf"

echo "=== tenant: setup --r2 --alias folds an r2 hostname in, and its rollback list (rows 14, 30) ==="
fu1="00000000-0000-4000-8000-0000000c0001"; fu2="00000000-0000-4000-8000-0000000c0002"; faud1="$(printf 'c1' | shasum -a 256 | cut -c1-64)"; faud2="$(printf 'c2' | shasum -a 256 | cut -c1-64)"
afold() { tv setup ten.example.test --r2 --bucket ok-bucket --alias f.example.test; }
afresh() { # vfresh, then the bucket is the alias's: its marker, its Worker on its custom domain, two gated cloud links whose apps are named for it, and the alias's own r2 profile here
  vfresh
  printf '{"v":1,"host":"f.example.test"}\n' >"$DRYV/share.json"
  echo dwarves.cloudflareaccess.com >"$DRYV/.cf/team"
  printf '{"hostname":"f.example.test","service":"share-f-example-test"}\n' >"$DRYV/.cf/domain.json"
  jq -nc '{bindings: [{type: "r2_bucket", name: "BUCKET", bucket_name: "ok-bucket"}, {type: "plain_text", name: "HOST", text: "f.example.test"}, {type: "plain_text", name: "VERSION", text: "2"}]}' >"$DRYV/.cf/script-share-f-example-test.json"
  mkdir -p "$vroot/.access-dry" "$DRYV/o/0c0001.0000000c" "$DRYV/o/0c0002.0000000d"
  local i u a n
  for i in 1 2; do
    if [[ $i == 1 ]]; then u=$fu1 a=$faud1 n=0000000c; else u=$fu2 a=$faud2 n=0000000d; fi
    printf 'g\n' >"$DRYV/o/0c000$i.$n/g.txt"
    jq -nc --arg id "0c000$i" --arg u "$u" --arg a "$a" --arg n "$n" '{v: 1, id: $id, name: "g.txt", src: "/m/g.txt", added: "2026-10-01", expires: 0,
      opts: "access=\($u) access_rule=email:a@example.test", prefix: "o/\($id).\($n)/", by: "files-host", aud: $a}' >"$DRYV/m/0c000$i"
    jq -nc --arg id "0c000$i" --arg u "$u" --arg a "$a" --arg n "$n" '{id: $u, aud: $a, name: "share \($id) f.example.test \($n)", type: "self_hosted",
      destinations: [{type: "public", uri: "f.example.test/\($id)"}, {type: "public", uri: "f.example.test/\($id)/*"}], app_launcher_visible: false,
      session_duration: "24h", policies: [{name: "share \($id)", decision: "allow", include: [{email: {email: "a@example.test"}}], precedence: 1}]}' >"$vroot/.access-dry/$u.json"
  done
  mkdir -p "$T5H/.config/share/profiles/f" "$T5H/share/profiles/f"
  printf 'backend=r2\nhostname=f.example.test\nzone=example.test\nbucket=ok-bucket\nport=r2\n' >"$T5H/.config/share/profiles/f/config"
  printf '0c0001\to/0c0001.0000000c/\t/m/g.txt\n' >"$T5H/share/profiles/f/r2-own"
  : >"$vlog"
}
adests() { jq -r '[.destinations[].uri] | join(" ")' "$vroot/.access-dry/$1.json" 2>/dev/null; }
aend() { # the end state of a finished fold, one line
  echo "$(jq -c . "$DRYV/share.json") $(jq -r .service "$DRYV/.cf/domain.json") $(grep '^aliases=' "$vconf") $(jq -r '.bindings[] | select(.name == "ALIASES") | .text' "$DRYV/.cf/script.json") | $(adests $fu1) | $(adests $fu2) | $(jq -r '"\(.aud) \(.app_launcher_visible) \(.name)"' "$vroot/.access-dry/$fu1.json")"
}
row14end="{\"v\":1,\"host\":\"ten.example.test\",\"aliases\":[\"f.example.test\"]} share-ten-example-test aliases=f.example.test f.example.test | ten.example.test/0c0001 ten.example.test/0c0001/* | ten.example.test/0c0002 ten.example.test/0c0002/* | $faud1 false share 0c0001 f.example.test 0000000c"
afresh
out=$(afold 2>&1); rc=$?
check "row 14: the fold exits 0" "0" "$rc"
check "row 14: the call order" "1" "$(vord "^GET app $fu1\$" '^API PUT /accounts/acct-dry/workers/scripts/share-ten-example-test$' '^PUT m/0a000' "^PUT app $fu1\$" '^PROBE ' '^CONFIG r2 on$' \
  '^PUT share.json$' '^API POST /zones/zone-dry/workers/routes$' '^API PUT /accounts/acct-dry/workers/domains$' '^HEALTHZ$' '^ALIAS-301 f.example.test$')"
check "row 14: the alias destinations are dropped last, after the 301" "1" "$([[ $(grep -n "^PUT app $fu1\$" "$vlog" | tail -1 | cut -d: -f1) -gt $(grep -n '^ALIAS-301' "$vlog" | tail -1 | cut -d: -f1) ]] && echo 1 || echo 0)"
check "row 14: marker, domain, config, ALIASES, both apps on the tenant host, AUD and fields kept" "$row14end" "$(aend)"
check "row 14: the alias profile's own shares are this profile's to refresh" "1" "$(grep -c '^0c0001	o/0c0001.0000000c/	/m/g.txt$' "$vroot/r2-own")"
check "row 14: the member's ungated cloud link is untouched" "1 member" "$(jq -r '"\(.v) \(.by)"' "$DRYV/m/0b0001")"
: >"$vlog"; out=$(afold 2>&1); rc=$?
check "row 14: a rerun converges with no write but the idempotent workers.dev off" "0 0 $row14end" "$rc $(grep -E '^(API (PUT|POST|DELETE) |PUT |DELETE |PUT app)' "$vlog" | grep -cv '/subdomain$') $(aend)"
: >"$vlog"; out=$(tv rm 0c0001 2>&1); rc=$?
check "row 14: rm of a folded gated link on the tenant deletes its app" "0 1 0 0" "$rc $(grep -c "^DELETE app $fu1\$" "$vlog") $([[ -f $vroot/.access-dry/$fu1.json ]] && echo 1 || echo 0) $([[ -f $DRYV/m/0c0001 ]] && echo 1 || echo 0)"
# a member joining after the fold keeps the alias the 301 confirms, and its rm of a folded link deletes the app too
rm -rf "$TVM"; mkdir -p "$TVM"
TVM_ENV=(SHARE_R2_DRY_ROLE=deny SHARE_R2_DRY_BUCKETDOM=deny)
out=$(tvm setup ten.example.test --backend r2 --bucket ok-bucket 2>&1); rc=$?
check "row 14 (member): the join keeps the alias the 301 confirms" "0 aliases=f.example.test 0" "$rc $(grep '^aliases=' "$TVM/.config/share/profiles/ten/config") $(grep -c 'not kept' <<<"$out")"
mkdir -p "$TVM/share/profiles/ten/.access-dry"; cp "$vroot/.access-dry/$fu2.json" "$TVM/share/profiles/ten/.access-dry/"
TVM_ENV=(SHARE_ACCESS_DRY=1 SHARE_ACCESS_POLL=0 SHARE_R2_TOKEN=drytoken); : >"$TVM/share/profiles/ten/r2-calls.log"
out=$(tvm rm 0c0002 2>&1); rc=$?
check "row 14 (member): rm of a folded gated link deletes its app" "0 1 0" "$rc $(grep -c "^DELETE app $fu2\$" "$TVM/share/profiles/ten/r2-calls.log") $([[ -f $TVM/share/profiles/ten/.access-dry/$fu2.json ]] && echo 1 || echo 0)"
TVM_ENV=()
printf '{"v":1,"host":"ten.example.test","aliases":["g.example.test"]}\n' >"$DRYV/share.json"; rm -rf "$TVM"; mkdir -p "$TVM"
TVM_ENV=(SHARE_R2_DRY_ROLE=deny SHARE_R2_DRY_BUCKETDOM=deny)
out=$(tvm setup ten.example.test --backend r2 --bucket ok-bucket 2>&1); rc=$?
check "row 14 (member): a marker alias that does not 301 here is not kept" "0 0 1" "$rc $(grep -c '^aliases=' "$TVM/.config/share/profiles/ten/config") $(grep -c 'alias g.example.test: .* not kept' <<<"$out")"
TVM_ENV=()
# refusals, each before any write
arefuse() { # arefuse <label> <message> <alias> <env...>
  local label=$1 msg=$2 al=$3; shift 3
  : >"$vlog"
  # shellcheck disable=SC2163 # each argument is a NAME=value pair to export, on purpose
  out=$(export "$@"; tv setup ten.example.test --r2 --bucket ok-bucket --alias "$al" 2>&1); rc=$?
  check "row 14: $label is refused before any write" "1 1 0" "$rc $(grep -c -- "$msg" <<<"$out") $(vwrites)"
}
afresh
arefuse "--alias equal to the host" "--alias needs another hostname, not 'ten.example.test'" ten.example.test X=1
arefuse "--alias that is not a hostname" "--alias needs another hostname" 'f_x' X=1
arefuse "--alias in another zone" "--alias f.other.test is not in zone example.test" f.other.test X=1
printf '{"hostname":"f.example.test","service":"other-worker"}\n' >"$DRYV/.cf/domain.json"
arefuse "the alias domain naming another service" "f.example.test is the custom domain of Worker other-worker, not share-f-example-test" f.example.test X=1
printf '{"hostname":"f.example.test","service":"share-f-example-test"}\n' >"$DRYV/.cf/domain.json"
jq -c '.name = "share 0c0001 third.example.test 0000000c"' "$vroot/.access-dry/$fu1.json" >"$WORK/app.tmp" && mv -f "$WORK/app.tmp" "$vroot/.access-dry/$fu1.json"
arefuse "a gated app named for a third host" "named 'share 0c0001 third.example.test 0000000c', not 'share 0c0001 f.example.test <nonce>'" f.example.test X=1
afresh
arefuse "a token without Access Apps Edit" "the token lacks Access: Apps and Policies Edit" f.example.test SHARE_ACCESS_DRY_APPS=deny
# the gate probe fails: the added destinations go again, no marker, no route, no config
afresh; printf 'fail\n' >"$vroot/access-probe-fixture"
out=$(SHARE_ACCESS_WAIT=1 afold 2>&1); rc=$?
check "row 14: a probe timeout dies naming Access" "1 1" "$rc $(grep -c 'Cloudflare Access did not enforce on ten.example.test/0c000[12]' <<<"$out")"
check "row 14: probe timeout: the added destinations removed, no marker PUT, no route, no config" "f.example.test/0c0001 f.example.test/0c0001/* 0 0 0 0" \
  "$(adests $fu1) $(grep -c '^PUT share.json$' "$vlog") $(grep -c '^API POST /zones/' "$vlog") $(grep -c '^CONFIG' "$vlog") $(grep -c '^aliases=' "$vconf")"
rm -f "$vroot/access-probe-fixture"
# row 30: a die at steps 12 to 15 prints the alias rollback list, --no-r2 refuses, a rerun converges
for inj in "PUT share.json" "API POST /zones/*/workers/routes" "API PUT /accounts/*/workers/domains" "ALIAS-301"; do
  afresh
  out=$(SHARE_R2_DRY_FAIL="$inj" afold 2>&1); rc=$?
  check "row 30 ($inj): the die prints the alias rollback list, not --no-r2 alone" "1 1 1 1 0" "$rc $(grep -c '^alias rollback for f.example.test, in this order' <<<"$out") \
$(grep -c '^  6. share --profile ten setup ten.example.test --no-r2$' <<<"$out") $(grep -c 'roll back with the alias rollback list above' <<<"$out") $(grep -c 'roll back with: share' <<<"$out")"
  : >"$vlog"; out=$(tv setup ten.example.test --no-r2 2>&1); rc=$?
  check "row 30 ($inj): --no-r2 refuses with the list while the alias is set" "1 1 1 0" "$rc $(grep -c '^share: f.example.test redirects here; run the alias rollback above first' <<<"$out") $(grep -c '^alias rollback for f.example.test' <<<"$out") $(vwrites)"
  [[ $inj == ALIAS-301 ]] && break
  out=$(afold 2>&1); rc=$?
  check "row 30 ($inj): a rerun converges to row 14's end state" "0 $row14end" "$rc $(aend)"
done
check "row 30: the list names the folded apps, the rebind, the marker, and every pointer" "1 1 1 1" \
  "$(grep -c "^  1\. .*: $fu1 (0c0001), $fu2 (0c0002)\$" <<<"$out") $(grep -c '^  2\. PUT /accounts/acct-dry/workers/domains {"hostname":"f.example.test","service":"share-f-example-test","zone_id":"zone-dry","environment":"production","override_existing_origin":true}$' <<<"$out") \
$(grep -c '^  3\. PUT share.json in bucket ok-bucket with If-Match on its ETag: {"v":1,"host":"f.example.test"}$' <<<"$out") $(grep -c '^  5\. DELETE every v:2 machine record: m/0a0001 m/0a0002 m/0a0003 $' <<<"$out")"
# run the printed list on the dry account, in its order
for u in $fu1 $fu2; do jq -c --arg i "$(jq -r '.name | split(" ")[1]' "$vroot/.access-dry/$u.json")" '.destinations = ([.destinations[] | select(.uri | startswith("f.example.test/") | not)] + [{type: "public", uri: "f.example.test/\($i)"}, {type: "public", uri: "f.example.test/\($i)/*"}])' "$vroot/.access-dry/$u.json" >"$WORK/app.tmp" && mv -f "$WORK/app.tmp" "$vroot/.access-dry/$u.json"; done
printf '{"hostname":"f.example.test","service":"share-f-example-test"}\n' >"$DRYV/.cf/domain.json"
printf '{"v":1,"host":"f.example.test"}\n' >"$DRYV/share.json"
grep -v '^aliases=' "$vconf" >"$WORK/vconf.tmp"; cat "$WORK/vconf.tmp" >"$vconf"
rm -f "$DRYV/m/0a0001" "$DRYV/m/0a0002" "$DRYV/m/0a0003"
: >"$vlog"; out=$(tv setup ten.example.test --no-r2 2>&1); rc=$?
check "row 30: after the list, --no-r2 removes the route" "0 1 0" "$rc $(grep -c '^API DELETE /zones/zone-dry/workers/routes/' "$vlog") $(jq length "$DRYV/.cf/routes.json")"
check "row 30: after the list, the alias's own Worker serves its cloud records again" "share-f-example-test f.example.test ok-bucket f.example.test 1 1" \
  "$(jq -r .service "$DRYV/.cf/domain.json") $(jq -r '[(.bindings[] | select(.name == "HOST") | .text), (.bindings[] | select(.name == "BUCKET") | .bucket_name)] | join(" ")' "$DRYV/.cf/script-share-f-example-test.json") $(jq -r .host "$DRYV/share.json") $(jq -r .v "$DRYV/m/0c0001") $(grep -c f.example.test/0c0001 "$vroot/.access-dry/$fu1.json")"
: >"$vlog"; out=$(afold 2>&1); rc=$?
check "row 30: the fold again converges to row 14's end state" "0 $row14end" "$rc $(aend)"
# without an alias the step-15 die names --no-r2
vfresh; out=$(SHARE_R2_DRY_HEALTHZ=down tvsetup 2>&1); rc=$?
check "row 30: with no alias the step-15 die names --no-r2" "1 1 0" "$rc $(grep -c 'roll back with: share --profile ten setup ten.example.test --no-r2$' <<<"$out") $(grep -c 'alias rollback' <<<"$out")"
rm -rf "$T5H/.config/share/profiles/f" "$T5H/share/profiles/f"

echo "=== tenant: one shared list in ls, state, profiles --json (rows 15, 16, 17, 28) ==="
L6H="$WORK/list-home"; DRYL="$WORK/list-bucket"; LMH="$WORK/list-member"
lroot="$L6H/share/profiles/lst"; llog="$lroot/r2-calls.log"; lconf="$L6H/.config/share/profiles/lst/config"
mkdir -p "$L6H/.config/share/profiles/lst" "$L6H/.config/share/profiles/off" "$DRYL/m" "$LMH/.config/share/profiles/lst"
printf 'hostname=lst.example.test\ntunnel_id=tid-lst\ntunnel_name=share-lst-example-test\nhosts=not-this-host\nport=%s\nbucket=ok-bucket\nr2_endpoint=https://acct.example.r2.cloudflarestorage.com\nstorage_default=local\n' $((base + 60)) >"$lconf"
printf 'hostname=off6.example.test\ntunnel_id=tid-off6\ntunnel_name=share-off6-example-test\nhosts=not-this-host\nport=%s\n' $((base + 62)) >"$L6H/.config/share/profiles/off/config"
printf 'backend=r2\nhostname=lst.example.test\nzone=example.test\nbucket=ok-bucket\nport=r2\nr2_endpoint=https://acct.example.r2.cloudflarestorage.com\nr2_key_id=keyid42\n' >"$LMH/.config/share/profiles/lst/config"
printf '{"v":1,"host":"lst.example.test"}\n' >"$DRYL/share.json"
tl() { # tl <verb...>: the origin of lst.example.test (R2 on) on its own dry bucket; TLP=off picks the R2-off profile
  env -u SHARE_ROOT -u SHARE_CONFIG_DIR -u SHARE_PORT -u SHARE_HOSTNAME -u XDG_CONFIG_HOME -u SHARE_PROFILE -u SHARE_BACKEND -u SHARE_HOSTS \
    HOME="$L6H" SHARE_TUNNEL=0 SHARE_R2_DRY=1 SHARE_R2_DRY_DIR="$DRYL" SHARE_R2_TOKEN="${TL_TOK-drytoken}" \
    SHARE_ACCESS_DRY=1 SHARE_ACCESS_POLL=0 CLOUDFLARE_API_TOKEN="${TL_CF-faketoken}" bash "$SH" --profile "${TLP:-lst}" "$@"
}
tml() { # tml <verb...>: a member of the same tenant
  env -u SHARE_ROOT -u SHARE_CONFIG_DIR -u SHARE_PORT -u SHARE_HOSTNAME -u XDG_CONFIG_HOME -u SHARE_PROFILE -u SHARE_BACKEND -u SHARE_HOSTS \
    HOME="$LMH" SHARE_TUNNEL=0 SHARE_R2_DRY=1 SHARE_R2_DRY_DIR="$DRYL" SHARE_R2_TOKEN=drytoken CLOUDFLARE_API_TOKEN=faketoken bash "$SH" --profile lst "$@"
}
lforge() { printf '%s\n' "$2" >"$DRYL/m/$1"; }
me_by="$(uname -n | cut -d. -f1 | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9.-')"; me_by="${me_by:-unknown}"
lport=$((base + 65))
mkdir -p "$WORK/l6"; printf '%%PDF-1.4\n' >"$WORK/l6/Report.PDF"; printf 'g\n' >"$WORK/l6/g.txt"
SHARE_TEST_IDS=1a0001 tl add "$WORK/l6/Report.PDF" >/dev/null 2>&1
SHARE_TEST_IDS=1a0002 tl add "$lport" >/dev/null 2>&1
SHARE_TEST_IDS=1a0003 tl add --access email:a@example.test "$WORK/l6/g.txt" >/dev/null 2>&1
lforge 1b0001 '{"v":1,"id":"1b0001","name":"pic.png","src":"/o/pic.png","added":"2026-10-01","expires":0,"opts":"","prefix":"o/1b0001.0000001b/","by":"other-mac","type":"image"}'
lforge 1b0002 "{\"v\":1,\"id\":\"1b0002\",\"name\":\"p.pdf\",\"src\":\"/o/p.pdf\",\"added\":\"2026-10-01\",\"expires\":0,\"opts\":\"access=00000000-0000-4000-8000-0000001b0002 access_rule=email:a@example.test\",\"prefix\":\"o/1b0002.0000001b/\",\"by\":\"other-mac\",\"type\":\"pdf\",\"aud\":\"$(printf x | shasum -a 256 | cut -c1-64)\"}"
lforge 1b0003 '{"v":1,"id":"1b0003","name":"guide","src":"/o/guide","added":"2026-10-01","expires":0,"opts":"","prefix":"o/1b0003.0000001b/","by":"other-mac"}'
check "row 15 fixture: three local rows with pointers, three cloud records" "3 6" "$(grep -c . "$lroot/index.tsv") $(find "$DRYL/m" -type f | grep -c .)"
out=$(tl ls 2>&1); rc=$?
check "row 15: origin ls lists six rows with their tags, types, and by=" "0 machine pdf $me_by|live site $me_by|machine text $me_by|cloud image other-mac|cloud pdf other-mac|cloud folder other-mac|" \
  "$rc $(sed -n -E 's/^(machine|live|cloud) +([a-z]+) +by=([a-z0-9.-]+)  https:.*/\1 \2 \3/p' <<<"$out" | tr '\n' '|')"
check "row 15: no id twice" "6 6" "$(grep -c '^    id=' <<<"$out") $(grep -o '^    id=[0-9a-f]*' <<<"$out" | sort -u | grep -c .)"
out=$(tl state 2>&1); rc=$?
check "row 15: state rows carry storage, type, by; r2 and storage_default on top" "0 6 true local" "$rc $(jq '[.shares[] | select(.storage and .type and .by)] | length' <<<"$out") $(jq -r '"\(.r2) \(.storage_default)"' <<<"$out")"
check "row 15: guide (a cloud record with no type and no extension) is a folder; the gated cloud row keeps its rule" "folder email:a@example.test" \
  "$(jq -r '[(.shares[] | select(.id == "1b0003") | .type), (.shares[] | select(.id == "1b0002") | .access)] | join(" ")' <<<"$out")"
cp "$DRYL/m/1a0001" "$WORK/l6/ptr"; jq -c '.v = 1 | del(.storage) | .prefix = "o/1a0001.0000001a/" | .opts = ""' "$WORK/l6/ptr" >"$DRYL/m/1a0001"
check "row 15: a shadowed id lists its local row once" "1 machine" "$(tl ls 2>/dev/null | grep -c '^    id=1a0001 ') $(tl state 2>/dev/null | jq -r '[.shares[] | select(.id == "1a0001") | .storage] | join(" ")')"
cp "$WORK/l6/ptr" "$DRYL/m/1a0001"
# a member's list: every bucket record, the origin's machine links from their pointers
out=$(tml ls 2>&1); rc=$?
check "row 15 (member): ls lists the same six rows" "0 cloud folder other-mac|cloud image other-mac|cloud pdf other-mac|live site $me_by|machine pdf $me_by|machine text $me_by|" \
  "$rc $(sed -n -E 's/^(machine|live|cloud) +([a-z]+) +by=([a-z0-9.-]+)  https:.*/\1 \2 \3/p' <<<"$out" | LC_ALL=C sort | tr '\n' '|')"
out=$(tml state 2>&1); rc=$?
check "row 15 (member): state shows the gated pointer as gated, the live one as live" "0 gated live machine true" \
  "$rc $(jq -r '[(.shares[] | select(.id == "1a0003") | .access), (.shares[] | select(.id == "1a0002") | .kind), (.shares[] | select(.id == "1a0001") | .storage), (.r2 | tostring)] | join(" ")' <<<"$out")"
# row 16: the type table on local rows; the extension match ignores case
for f in a.pdf b.PNG c.mp4 d.mp3 e.md f.zip a.tar.gz g.json h.html i.weird noext; do printf 'x\n' >"$WORK/l6/$f"; done
mkdir -p "$WORK/l6/plain" "$WORK/l6/site"; printf 'x\n' >"$WORK/l6/plain/x.txt"; printf '<p>\n' >"$WORK/l6/site/index.html"
n=0; for f in a.pdf b.PNG c.mp4 d.mp3 e.md f.zip a.tar.gz g.json h.html i.weird noext plain site Report.PDF; do
  n=$((n + 1)); SHARE_TEST_IDS="$(printf '2c%04d' "$n")" TLP=off tl add "$WORK/l6/$f" >/dev/null 2>&1
done
check "row 16: one type per table row, case ignored" "pdf image video audio markdown archive archive text site other other folder site pdf" \
  "$(TLP=off tl state 2>/dev/null | jq -r '[.shares | sort_by(.id)[] | .type] | join(" ")')"
check "row 16: an R2-off profile reads no bucket and says r2: false" "false 0" "$(TLP=off tl state 2>/dev/null | jq -r .r2) $([[ -e $L6H/share/profiles/off/r2-calls.log ]] && echo 1 || echo 0)"
# row 17: the menu never loses machine links to an R2 problem, and never runs a token command
out=$(SHARE_R2_DRY_LIST=500 tl state 2>/dev/null); rc=$?
check "row 17: a failing listing: local rows plus cloud_error, exit 0" "0 3 1" "$rc $(jq '.shares | length' <<<"$out") $(jq -r '.cloud_error // ""' <<<"$out" | grep -c 'HTTP 500')"
printf 'api_token_cmd=touch %s; echo tok\n' "$WORK/l6/sentinel" >>"$lconf"
out=$(TL_TOK="" TL_CF="" tl state 2>/dev/null); rc=$?
check "row 17: an api_token_cmd source: no command run, cloud_error names api-token" "0 0 3 1" \
  "$rc $([[ -e $WORK/l6/sentinel ]] && echo 1 || echo 0) $(jq '.shares | length' <<<"$out") $(jq -r '.cloud_error // ""' <<<"$out" | grep -c 'the menu reads cloud links only with a stored token: share --profile lst api-token')"
grep -v '^api_token_cmd=' "$lconf" >"$WORK/l6/c" && cat "$WORK/l6/c" >"$lconf"
out=$(TL_TOK="" TL_CF=faketoken tl state 2>/dev/null); rc=$?
check "row 17: an environment token: cloud_error, no bucket read" "0 1" "$rc $(jq -r '.cloud_error // ""' <<<"$out" | grep -c 'stored token')"
mkdir -p "$LMH/.config/share/profiles/tun"
printf 'hostname=tun.example.test\ntunnel_id=tid-tun\ntunnel_name=share-tun\nhosts=nobody\nport=%s\n' $((base + 66)) >"$LMH/.config/share/profiles/tun/config"
out=$(tml profiles --json 2>/dev/null); rc=$?
check "row 17: profiles --json: the member entry lists its rows, the tunnel entry says r2: false" "0 6 cloud machine false" \
  "$rc $(jq '.profiles[] | select(.name == "lst") | .state.shares | length' <<<"$out") $(jq -r '[.profiles[] | select(.name == "lst") | .state.shares[].storage] | unique | join(" ")' <<<"$out") $(jq -r '.profiles[] | select(.name == "tun") | .state.r2' <<<"$out")"
# row 28: forged records stay display data on the origin and on a member; nothing reaches the Caddyfile, the index, or arithmetic
lforge 1f0001 '{"v":1,"id":"1f0001","name":"evil","src":"x:22","added":"2026-10-01","expires":0,"opts":"live host=x.test","prefix":"o/1f0001.0000001f/","by":"evil"}'
lforge 1f0002 "{\"v\":2,\"id\":\"1f0002\",\"storage\":\"machine\",\"name\":\"evil\",\"src\":\"x:22\",\"by\":\"evil\",\"added\":\"2026-10-01\",\"expires\":\"a[\$(touch $WORK/l6/S)]\",\"opts\":\"live\",\"type\":\"site\"}"
lforge 1f0003 '{"v":2,"id":"1f0003","storage":"machine","name":"a\tb","by":"evil","added":"2026-10-01","expires":0,"opts":"","type":"text"}'
export SHARE_R2_DRY_LIST_EXTRA="m/../share.json"
: >"$llog"
for v in ls state "profiles --json"; do
  # shellcheck disable=SC2086 # the verb may be two words
  out=$(tl $v 2>&1); check "row 28 (origin): $v exits 0 and shows no forged pointer" "0" "$(grep -c '1f0002\|1f0003' <<<"$out")"
done
SHARE_TEST_IDS=1a0009 tl add "$WORK/l6/g.txt" >/dev/null 2>&1
lforge 0e0001 '{"v":1,"id":"0e0001","name":"old.txt","src":"/o/old.txt","added":"2026-01-01","expires":1000,"opts":"","prefix":"o/0e0001.0000000e/","by":"other-mac"}'
SHARE_TEST_IDS=0e0002 tl add "$WORK/l6/g.txt" >/dev/null 2>&1
awk -F'\t' -v OFS='\t' '$1 == "0e0002" {$5 = 1000} {print}' "$lroot/index.tsv" >"$WORK/l6/i" && cat "$WORK/l6/i" >"$lroot/index.tsv"
: >"$llog"; out=$(tl prune 2>&1); rc=$?
check "row 28: one prune expires the cloud row, then the local one" "0 1" "$rc $(awk '/^DELETE m\/0e0001$/ && !a {a = NR} /^DELETE m\/0e0002$/ && !b {b = NR} END {print (a && b && a < b) ? 1 : 0}' "$llog")"
check "row 28: the Caddyfile and index.tsv hold exactly the local rows" "0 0 1 1 1a0001 1a0002 1a0003 1a0009" \
  "$(grep -c 'x\.test\|1f000\|x:22\|0e000\|1b000' "$lroot/Caddyfile") $(grep -c '1f000\|1b000\|0e000' "$lroot/index.tsv") $(grep -c 'handle_path /1a0002/\*' "$lroot/Caddyfile") $([[ -d $lroot/pub/1a0009 ]] && echo 1 || echo 0) $(cut -f1 "$lroot/index.tsv" | sort | tr '\n' ' ' | sed 's/ $//')"
check "row 28: the odd key is skipped and share.json survives" "0 0 1" "$(grep -c 'm/\.\./share.json' "$llog") $(grep -c '^DELETE share.json' "$llog") $([[ -f $DRYL/share.json ]] && echo 1 || echo 0)"
for v in "rm 1f0002" "hits 1f0002" "refresh 1f0001" "refresh 1f0002" "refresh 1f0003"; do
  # shellcheck disable=SC2086 # the verb and id are two words
  out=$(tl $v 2>&1); rc=$?
  check "row 28: $v of a forged id dies" "1" "$rc"
done
for v in ls state "profiles --json"; do
  # shellcheck disable=SC2086 # the verb may be two words
  out=$(tml $v 2>&1); rc=$?
  check "row 28 (member): $v exits 0; the forged pointers are skipped; the forged cloud record is display text" "0 0" "$rc $(grep -c '1f0002\|1f0003' <<<"$out")"
done
check "row 28: no forged field reached the shell" "0" "$([[ -e $WORK/l6/S ]] && echo 1 || echo 0)"
unset SHARE_R2_DRY_LIST_EXTRA

echo "=== import: one share moved in by migrate, its tar on stdin (row 18) ==="
IMH="$WORK/import-home"; mkdir -p "$IMH" "$WORK/imp"
imp() { # imp <args...>: share import into the default profile of a HOME with no setup (not_setup), stdin passed through
  env -u SHARE_ROOT -u SHARE_CONFIG_DIR -u SHARE_PORT -u SHARE_HOSTNAME -u XDG_CONFIG_HOME -u SHARE_PROFILE -u SHARE_BACKEND -u SHARE_HOSTS \
    HOME="$IMH" SHARE_TUNNEL=0 bash "$SH" import "$@"
}
iroot="$IMH/share"
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
mktar() { # mktar <out.tar> <type:name[:link]>...: a ustar archive with exactly these members (f file "x", d dir, l symlink, h hardlink), built byte by byte so no tar tidies it
  node -e '
    const fs = require("fs"); const out = process.argv[1]; const blocks = [];
    const oct = (n, w) => n.toString(8).padStart(w - 1, "0") + "\0";
    for (const spec of process.argv.slice(2)) {
      const [t, name, link = ""] = spec.split(":"); const body = t === "f" ? Buffer.from("x\n") : Buffer.alloc(0);
      const h = Buffer.alloc(512); h.write(name, 0); h.write(oct(t === "d" ? 0o755 : 0o644, 8), 100); h.write(oct(0, 8), 108); h.write(oct(0, 8), 116);
      h.write(oct(body.length, 12), 124); h.write(oct(0, 12), 136); h.write("        ", 148);
      h.write({f: "0", d: "5", l: "2", h: "1"}[t], 156); h.write(link, 157); h.write("ustar\u000000", 257);
      let sum = 0; for (const b of h) sum += b; h.write(oct(sum, 7) + " ", 148);
      blocks.push(h, body, Buffer.alloc((512 - body.length % 512) % 512));
    }
    blocks.push(Buffer.alloc(1024)); fs.writeFileSync(out, Buffer.concat(blocks));' "$@"
}
inone() { # inone <label> <id> <tar> <name> [opts]: the import is refused, with no pub/<id> and no row
  local label=$1 id=$2 t=$3 nm=$4 o=${5:-}
  out=$(imp "$id" 0 air 2026-09-01 "$(b64 "$nm")" "$(b64 "/a/$nm")" "$(b64 "$o")" <"$t" 2>&1); rc=$?
  check "row 18: $label is refused, no pub/<id>, no row" "1 0 0" "$rc $([[ -e $iroot/pub/$id ]] && echo 1 || echo 0) $(awk -F'\t' -v id="$id" '$1 == id' "$iroot/index.tsv" 2>/dev/null | grep -c .)"
}
check "row 18: import --probe" "share-import 1" "$(imp --probe 2>&1)"
mkdir -p "$WORK/imp/src/doc/sub"; printf 'a\n' >"$WORK/imp/src/doc/a.txt"; printf 'b\n' >"$WORK/imp/src/doc/sub/b.md"
COPYFILE_DISABLE=1 tar -C "$WORK/imp/src" -cf "$WORK/imp/good.tar" . 2>/dev/null
iman="$(bash -c 'source <(sed -n "/^import_manifest() {/,/^}/p" "$1"); import_manifest "$2"' _ "$SH" "$WORK/imp/src")"
out=$(imp 3c0001 1893456000 air 2026-09-01 "$(b64 doc)" "$(b64 /Users/x/doc)" "$(b64 'noindex access=00000000-0000-4000-8000-0000003c0001 access_rule=email:a@example.test')" "$iman" <"$WORK/imp/good.tar" 2>&1); rc=$?
check "row 18: a regular tree is published with the original dates, by=, and src <by>:<src>" "0 imported 3c0001|3c0001	doc	air:/Users/x/doc	2026-09-01	1893456000	noindex access=00000000-0000-4000-8000-0000003c0001 access_rule=email:a@example.test by=air" \
  "$rc $out|$(cat "$iroot/index.tsv")"
check "row 18: the tree is byte for byte the source; no Access app was created" "1 0" "$(diff -r "$WORK/imp/src/doc" "$iroot/pub/3c0001/doc" >/dev/null && echo 1 || echo 0) $(cat "$iroot/access-calls.log" 2>/dev/null | grep -c POST)"
check "row 18: no spool or stage left" "0" "$(find "$iroot" -maxdepth 1 \( -name '.import.*' -o -name '.stage.*' \) | grep -c .)"
mktar "$WORK/imp/sym.tar" d:./doc/ f:./doc/a.txt l:./doc/l:/var/empty/target
inone "a symlink" 3c0002 "$WORK/imp/sym.tar" doc
mktar "$WORK/imp/hard.tar" d:./doc/ f:./doc/a.txt h:./doc/b.txt:./doc/a.txt
inone "a sibling hardlink" 3c0003 "$WORK/imp/hard.tar" doc
mktar "$WORK/imp/hardabs.tar" d:./doc/ h:./doc/b.txt:/var/empty/target
inone "an absolute hardlink" 3c0004 "$WORK/imp/hardabs.tar" doc
mktar "$WORK/imp/dot.tar" d:./doc/ f:./doc/a.txt f:./doc/.env
inone "a dotfile" 3c0005 "$WORK/imp/dot.tar" doc
mktar "$WORK/imp/up.tar" d:./doc/ f:./doc/../../x
inone "a ../x member" 3c0006 "$WORK/imp/up.tar" doc
mktar "$WORK/imp/abs.tar" f:/tmp/share-import-abs-x
inone "an absolute member" 3c0007 "$WORK/imp/abs.tar" doc
out=$(imp 3c0001 0 air 2026-09-01 "$(b64 doc)" "$(b64 /a/doc)" "" <"$WORK/imp/good.tar" 2>&1); rc=$?
check "row 18: an id already in the index is refused, the first import kept" "1 1 1" "$rc $(grep -c '3c0001 is already here' <<<"$out") $(grep -c '^3c0001' "$iroot/index.tsv")"
inone "opts live" 3c0008 "$WORK/imp/good.tar" doc live
inone "opts host=x" 3c0009 "$WORK/imp/good.tar" doc host=x.example.test
inone "a name with /" 3c000a "$WORK/imp/good.tar" doc/x
inone "a dotfile name" 3c000b "$WORK/imp/good.tar" .doc
inone "a name the archive does not hold" 3c000c "$WORK/imp/good.tar" other
inone "an access= without its rule" 3c000d "$WORK/imp/good.tar" doc access=00000000-0000-4000-8000-0000003c000d
out=$(imp 3c000e 0 air 2026-09-01 "$(b64 doc)" "$(b64 /a/doc)" "" "1:$(printf '%064d' 0)" <"$WORK/imp/good.tar" 2>&1); rc=$?
check "row 18: a manifest mismatch (a truncated copy) is refused" "1 1 0" "$rc $(grep -c 'arrived as' <<<"$out") $([[ -e $iroot/pub/3c000e ]] && echo 1 || echo 0)"
out=$(SHARE_IMPORT_MAX_BYTES=1000 imp 3c000f 0 air 2026-09-01 "$(b64 doc)" "$(b64 /a/doc)" "" <"$WORK/imp/good.tar" 2>&1); rc=$?
check "row 18: an archive over SHARE_IMPORT_MAX_BYTES is refused" "1 1 0" "$rc $(grep -c 'over 1000 bytes' <<<"$out") $([[ -e $iroot/pub/3c000f ]] && echo 1 || echo 0)"
for bad in "zz0001 0 air 2026-09-01" "3c0010 1e5 air 2026-09-01" "3c0010 0 Air 2026-09-01" "3c0010 0 air 2026-9-1"; do
  # shellcheck disable=SC2086 # four words on purpose
  out=$(imp $bad "$(b64 doc)" "$(b64 /a/doc)" "" <"$WORK/imp/good.tar" 2>&1); rc=$?
  check "row 18: a bad id, expiry, by, or added is refused: $bad" "1 0" "$rc $([[ -e $iroot/pub/3c0010 ]] && echo 1 || echo 0)"
done
out=$(imp 3c0011 0 air 2026-09-01 "$(b64 doc)" "$(b64 $'/a/\tdoc')" "" <"$WORK/imp/good.tar" 2>&1); rc=$?
check "row 18: a source with a tab is refused" "1 0" "$rc $([[ -e $iroot/pub/3c0011 ]] && echo 1 || echo 0)"
out=$(env -u SHARE_ROOT -u SHARE_CONFIG_DIR -u SHARE_PORT -u SHARE_HOSTNAME -u XDG_CONFIG_HOME -u SHARE_PROFILE -u SHARE_BACKEND HOME="$IMH" SHARE_TUNNEL=0 bash "$SH" refresh 3c0001 2>&1); rc=$?
check "row 18: refresh of a moved row names where it came from" "1 1" "$rc $(grep -c '3c0001 was moved from air; re-add it from a source on this machine' <<<"$out")"
# setup --token-stdin: the token arrives on stdin, never argv
vfresh
out=$(printf 'admintoken\n' | TV_TOK="" tv setup ten.example.test --r2 --bucket ok-bucket --token-stdin 2>&1); rc=$?
check "setup --token-stdin: the admin token read from stdin runs setup --r2" "0 1" "$rc $(grep -c '^ready:      R2 is on' <<<"$out")"
vfresh
out=$(TV_TOK="" tv setup ten.example.test --r2 --bucket ok-bucket </dev/null 2>&1); rc=$?
check "setup --token-stdin: without it an empty token is refused" "1 1" "$rc $(grep -c 'read the tenant admin token from CLOUDFLARE_API_TOKEN only' <<<"$out")"
out=$(TV_TOK="" tv setup ten.example.test --r2 --bucket ok-bucket --token-stdin </dev/null 2>&1); rc=$?
check "setup --token-stdin: an empty stdin is refused before any call" "1 1 0" "$rc $(grep -c -- '--token-stdin read no token' <<<"$out") $(vwrites)"

echo "=== migrate: moving a tenant's origin (rows 19, 20, 21, 31) ==="
MW="$WORK/migrate"; mkdir -p "$MW/stubsvc" "$MW/remotebin" "$MW/seckv"
MHOST="mig.example.test"
GID="00000000-0000-4000-8000-000000000001"
GAUD="gated-aud-marker-for-row19-not-a-real-hex-digest"
GATEDID="bbbbbb"

cat > "$MW/stubsvc/security" <<SECEOF
#!/bin/bash
store_from_args() {
  local svc="" val="" prev=""
  for a in "\$@"; do case "\$prev" in -s) svc="\$a" ;; -w) val="\$a" ;; esac; prev="\$a"; done
  printf '%s' "\$val" > "$MW/seckv/\$svc"
}
case "\$1" in
  add-generic-password) shift; store_from_args "\$@"; exit 0 ;;
  find-generic-password)
    svc="" prev=""
    for a in "\$@"; do [[ "\$prev" == -s ]] && svc="\$a"; prev="\$a"; done
    [[ -f "$MW/seckv/\$svc" ]] && cat "$MW/seckv/\$svc" || exit 44
    exit 0 ;;
  delete-generic-password)
    svc="" prev=""
    for a in "\$@"; do [[ "\$prev" == -s ]] && svc="\$a"; prev="\$a"; done
    rm -f "$MW/seckv/\$svc"; exit 0 ;;
esac
exit 0
SECEOF
chmod +x "$MW/stubsvc/security"

cat > "$MW/remotebin/curl" <<CURLEOF
#!/bin/bash
url="" data="" method=GET fmt=""; prev=""
for a in "\$@"; do
  case \$prev in --data) data="\$a" ;; -X) method="\$a" ;; -w) fmt="\$a" ;; esac
  case \$a in http*) url="\$a" ;; esac
  prev="\$a"
done
echo "CURL \$method \$url" >> "\${CURL_LOG:?}"
body='{"success":true,"result":[]}'; code=200
case "\$method \$url" in
  "GET https://api.cloudflare.com/client/v4/user/tokens/verify") body='{"success":true,"result":{"status":"active"}}' ;;
  "GET https://api.cloudflare.com/client/v4/zones?"*) body='{"success":true,"result":[{"id":"zone1","account":{"id":"acct1"},"name":"$MHOST"}]}' ;;
  "GET https://api.cloudflare.com/client/v4/accounts/acct1/cfd_tunnel?"*)
    case "\$url" in
      *"name=tun-A&"*) body='{"success":true,"result":[{"id":"tid-A"}]}' ;;   # anchored on the trailing & so a migrate's "-m"-suffixed name never collides with this one
      *) body='{"success":true,"result":[]}' ;;
    esac ;;
  "POST https://api.cloudflare.com/client/v4/accounts/acct1/cfd_tunnel") body='{"success":true,"result":{"id":"tid-new"}}' ;;
  "PUT https://api.cloudflare.com/client/v4/accounts/acct1/cfd_tunnel/tid-new/configurations") body='{"success":true,"result":{}}' ;;
  "GET https://api.cloudflare.com/client/v4/zones/zone1/dns_records?"*) body='{"success":true,"result":[{"id":"rec1","type":"CNAME","content":"'"\${DNS_POINTS_AT:-tid-new}"'.cfargotunnel.com"}]}' ;;
  "POST https://api.cloudflare.com/client/v4/zones/zone1/dns_records") body='{"success":true,"result":{}}' ;;
  "GET https://api.cloudflare.com/client/v4/accounts/acct1/cfd_tunnel/tid-new/token") body='{"success":true,"result":"FAKE-TUNNEL-TOKEN"}' ;;
  "DELETE https://api.cloudflare.com/client/v4/zones/zone1/dns_records/rec1") body='{"success":true}' ;;
  "DELETE https://api.cloudflare.com/client/v4/accounts/acct1/cfd_tunnel/"*"/connections") body='{"success":true}' ;;
  "DELETE https://api.cloudflare.com/client/v4/accounts/acct1/cfd_tunnel/"*) body='{"success":true}' ;;
  "GET https://api.cloudflare.com/client/v4/accounts/acct1/access/apps/$GID") body='{"success":true,"result":{"aud":"$GAUD"}}' ;;
  "GET https://$MHOST/$GATEDID"*)
    printf '302 https://dwarves.cloudflareaccess.com/cdn-cgi/access/login/$MHOST?kid='"\${GATE_KID:-$GAUD}"''; exit 0 ;;
  "GET https://$MHOST/"*) printf '200'; exit 0 ;;
esac
[[ \$fmt == *http_code* ]] && printf '%s\n%s' "\$body" "\$code" || printf '%s' "\$body"
CURLEOF
chmod +x "$MW/remotebin/curl"
cp "$MW/stubsvc/security" "$MW/remotebin/security"; chmod +x "$MW/remotebin/security"
cat > "$MW/remotebin/share" <<EOF
#!/bin/bash
exec bash "$SH" "\$@"
EOF
chmod +x "$MW/remotebin/share"

: > "$MW/mssh.log"
cat > "$MW/mssh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$MW/mssh.log"
joined=""
for a in "\$@"; do joined="\$joined \$a"; done
sh=sh; command -v fish >/dev/null 2>&1 && sh=fish
exec env -u SHARE_ROOT -u SHARE_CONFIG_DIR -u SHARE_PORT -u SHARE_HOSTNAME -u XDG_CONFIG_HOME -u SHARE_PROFILE -u SHARE_BACKEND -u SHARE_HOSTS -u SHARE_TUNNEL \\
  HOME="\$MIG_B_HOME" PATH="$MW/remotebin:\$PATH" CURL_LOG="\$MIG_CURL_LOG" "\$sh" -c "\$joined"
EOF
chmod +x "$MW/mssh"

mig_a() { # mig_a <HOME> <B_HOME> <curl.log> <verb...>: share against the given A HOME, wired to migrate to B_HOME
  local ahome=$1 bhome=$2 clog=$3; shift 3
  env -u SHARE_ROOT -u SHARE_CONFIG_DIR -u SHARE_PORT -u SHARE_HOSTNAME -u XDG_CONFIG_HOME -u SHARE_PROFILE -u SHARE_BACKEND -u SHARE_HOSTS -u SHARE_TUNNEL \
    HOME="$ahome" PATH="$MW/stubsvc:$MW/remotebin:$PATH" CURL_LOG="$clog" CLOUDFLARE_API_TOKEN=migtoken \
    MIG_B_HOME="$bhome" MIG_CURL_LOG="$clog" SHARE_MIGRATE_SSH="$MW/mssh" \
    bash "$SH" "$@"
}
mig_fixture() { # mig_fixture <AHOME>: a snapshot, a folder, a gated snapshot, a live row
  local a=$1
  mkdir -p "$a/.config/share" "$a/share/pub/1a0001" "$a/share/pub/1a0002/doc" "$a/share/pub/$GATEDID"
  printf 'one\n' > "$a/share/pub/1a0001/one.txt"
  printf 'x\n' > "$a/share/pub/1a0002/doc/a.txt"
  printf 'y\n' > "$a/share/pub/1a0002/doc/sub.txt"
  printf 'secret\n' > "$a/share/pub/$GATEDID/g.txt"
  cat > "$a/.config/share/config" <<EOF
hostname=$MHOST
tunnel_id=tid-A
tunnel_name=tun-A
hosts=$mthis
port=18995
EOF
  {
    printf '1a0001\tone.txt\t/src/one.txt\t2026-09-01\t0\t\n'
    printf '1a0002\tdoc\t/src/doc\t2026-09-01\t0\t\n'
    printf '%s\tg.txt\t/src/g.txt\t2026-09-01\t0\taccess=%s access_rule=email:a@x.test\n' "$GATEDID" "$GID"
    printf '9b0001\tlocalhost:19580\thttp://127.0.0.1:19580\t2026-09-01\t0\tlive\n'
  } > "$a/share/index.tsv"
}
mthis="$(uname -n)"; mthis="${mthis%%.*}"

echo "--- row 19: a full migrate moves every snapshot, reports the live row, retires the origin ---"
AH="$MW/A19"; BH="$MW/B19"; rm -rf "$AH" "$BH"; mkdir -p "$AH" "$BH"
mig_fixture "$AH"
mkdir -p "$BH/.config/share"; printf 'hosts=nobody\nport=19561\n' > "$BH/.config/share/config"
: > "$MW/clog19"; : > "$MW/mssh.log"
out=$(mig_a "$AH" "$BH" "$MW/clog19" migrate --to m19-target --remote-bin "$MW/remotebin" --yes 2>&1); rc=$?
check "row 19: migrate exits 0" "0" "$rc"
check "row 19: B's index holds the three snapshots with A's ids and names" "1a0001 1a0002 $GATEDID" "$(cut -f1 "$BH/share/index.tsv" | sort | tr '\n' ' ' | sed 's/ $//')"
check "row 19: B's gated row keeps access= and access_rule=" "1" "$(awk -F'\t' -v id="$GATEDID" '$1==id' "$BH/share/index.tsv" | grep -c "access=$GID access_rule=email:a@x.test")"
check "row 19: B's pub/<id> trees equal A's migrated/<id> byte for byte" "1 1 1" \
  "$(diff -r "$AH/share/migrated/1a0001" "$BH/share/pub/1a0001" >/dev/null && echo 1 || echo 0) $(diff -r "$AH/share/migrated/1a0002" "$BH/share/pub/1a0002" >/dev/null && echo 1 || echo 0) $(diff -r "$AH/share/migrated/$GATEDID" "$BH/share/pub/$GATEDID" >/dev/null && echo 1 || echo 0)"
check "row 19: the live row is listed as not moved" "1" "$(grep -c 'not moved:  live link 9b0001 (port 19580)' <<<"$out")"
check "row 19: the switch ran --force --token-stdin; the token is in no logged argv" "1 0" \
  "$(grep -c -- '--force' "$MW/mssh.log") $(grep -c 'migtoken' "$MW/mssh.log" "$MW/clog19" | awk -F: '{s+=$2} END{print s+0}')"
check "row 19: A's rows moved to index.migrated, A's live row stays in index.tsv" "1a0001 1a0002 $GATEDID" "$(cut -f1 "$AH/share/index.migrated" | sort | tr '\n' ' ' | sed 's/ $//')"
check "row 19: A's live row is untouched in its own index" "9b0001" "$(cut -f1 "$AH/share/index.tsv")"
check "row 19: A's trees moved aside to migrated/, not pub/" "0 1" "$([[ -e $AH/share/pub/1a0001 ]] && echo 1 || echo 0) $([[ -d $AH/share/migrated/1a0001 ]] && echo 1 || echo 0)"
check "row 19: A's teardown path ran and logged no DELETE of an Access app" "0" "$(grep -c 'DELETE.*access/apps' "$MW/clog19")"

echo "--- row 19m: a source on the default tunnel name must not hand the target the same tunnel (DEC-010) ---"
AHD="$MW/A19m"; BHD="$MW/B19m"; rm -rf "$AHD" "$BHD"; mkdir -p "$AHD" "$BHD"
mig_fixture "$AHD"
DEFAULT_TUN="share-${MHOST//./-}"
sed -i.bak "s/^tunnel_name=.*/tunnel_name=$DEFAULT_TUN/" "$AHD/.config/share/config"
mkdir -p "$BHD/.config/share"; printf 'hosts=nobody\nport=19567\n' > "$BHD/.config/share/config"
MWDEF="$MW/remotebin-defaultname"; mkdir -p "$MWDEF"
cp "$MW/remotebin/security" "$MWDEF/security"; cp "$MW/remotebin/share" "$MWDEF/share"
chmod +x "$MWDEF/security" "$MWDEF/share"
cat > "$MWDEF/curl" <<CURLEOF
#!/bin/bash
url="" data="" method=GET fmt=""; prev=""
for a in "\$@"; do
  case \$prev in --data) data="\$a" ;; -X) method="\$a" ;; -w) fmt="\$a" ;; esac
  case \$a in http*) url="\$a" ;; esac
  prev="\$a"
done
echo "CALL \$method \$url" >> "\${CURL_LOG:?}"
body='{"success":true,"result":[]}'; code=200
case "\$method \$url" in
  "GET https://api.cloudflare.com/client/v4/user/tokens/verify") body='{"success":true,"result":{"status":"active"}}' ;;
  "GET https://api.cloudflare.com/client/v4/zones?"*) body='{"success":true,"result":[{"id":"zone1","account":{"id":"acct1"},"name":"$MHOST"}]}' ;;
  "GET https://api.cloudflare.com/client/v4/accounts/acct1/cfd_tunnel?"*)
    case "\$url" in
      *"name=$DEFAULT_TUN&"*) body='{"success":true,"result":[{"id":"tid-A"}]}' ;;   # the account already holds a tunnel under the default name: this IS the source's own tunnel
      *) body='{"success":true,"result":[]}' ;;
    esac ;;
  "POST https://api.cloudflare.com/client/v4/accounts/acct1/cfd_tunnel") body='{"success":true,"result":{"id":"tid-new"}}' ;;
  "PUT https://api.cloudflare.com/client/v4/accounts/acct1/cfd_tunnel/"*"/configurations") body='{"success":true,"result":{}}' ;;
  "GET https://api.cloudflare.com/client/v4/zones/zone1/dns_records?"*) body='{"success":true,"result":[{"id":"rec1","type":"CNAME","content":"tid-new.cfargotunnel.com"}]}' ;;
  "PUT https://api.cloudflare.com/client/v4/zones/zone1/dns_records/rec1") body='{"success":true,"result":{}}' ;;
  "GET https://api.cloudflare.com/client/v4/accounts/acct1/cfd_tunnel/"*"/token") body='{"success":true,"result":"FAKE-TUNNEL-TOKEN"}' ;;
  "DELETE https://api.cloudflare.com/client/v4/zones/zone1/dns_records/rec1") body='{"success":true}' ;;
  "DELETE https://api.cloudflare.com/client/v4/accounts/acct1/cfd_tunnel/"*"/connections") body='{"success":true}' ;;
  "DELETE https://api.cloudflare.com/client/v4/accounts/acct1/cfd_tunnel/"*) body='{"success":true}' ;;
  "GET https://\$MHOST/"*) printf '200'; exit 0 ;;
esac
[[ \$fmt == *http_code* ]] && printf '%s\n%s' "\$body" "\$code" || printf '%s' "\$body"
CURLEOF
chmod +x "$MWDEF/curl"
: > "$MW/clog19m"; : > "$MW/mssh.log"
out=$(mig_a "$AHD" "$BHD" "$MW/clog19m" migrate --to m19m-target --remote-bin "$MWDEF" --yes 2>&1); rc=$?
check "row 19: migrate still exits 0 (the danger is silent, not a reported failure)" "0" "$rc"
check "row 19: the target's own tunnel id never equals the source's (DEC-010, no shared-tunnel teardown)" "1" \
  "$([[ "$(sed -n 's/^tunnel_id=//p' "$BHD/.config/share/config")" != "$(sed -n 's/^tunnel_id=//p' "$AHD/.config/share/config")" ]] && echo 1 || echo 0)"

echo "--- row 20: refusals before any copy ---"
AH="$MW/A20"; BH="$MW/B20"; rm -rf "$AH" "$BH"; mkdir -p "$AH" "$BH"
mig_fixture "$AH"
printf '9c0001\town.txt\t/x\t2026-09-01\t0\thost=h.example.test\n' >> "$AH/share/index.tsv"
: > "$MW/clog20"
out=$(mig_a "$AH" "$BH" "$MW/clog20" migrate --to m20-target --remote-bin "$MW/remotebin" --yes 2>&1); rc=$?
check "row 20: a --host row on A refuses before any copy" "1 0" "$rc $(wc -l <"$MW/clog20" | tr -d ' ')"

AH="$MW/A20b"; BH="$MW/B20b"; rm -rf "$AH" "$BH"; mkdir -p "$AH" "$BH"
mig_fixture "$AH"
printf 'bucket=share-demo\n' >> "$AH/.config/share/config"
: > "$MW/clog20b"
out=$(mig_a "$AH" "$BH" "$MW/clog20b" migrate --to m20-target --remote-bin "$MW/remotebin" --yes 2>&1); rc=$?
check "row 20: bucket= on A (R2 on) refuses before any copy" "1 0" "$rc $(wc -l <"$MW/clog20b" | tr -d ' ')"

AH="$MW/A20c"; BH="$MW/B20c"; rm -rf "$AH" "$BH"; mkdir -p "$AH" "$BH"
mig_fixture "$AH"
mkdir -p "$BH/.config/share"; printf 'hostname=other.example.test\n' > "$BH/.config/share/config"
: > "$MW/clog20c"
out=$(mig_a "$AH" "$BH" "$MW/clog20c" migrate --to m20c-target --remote-bin "$MW/remotebin" --yes 2>&1); rc=$?
check "row 20: B already set up for another hostname refuses before any copy" "1 0" "$rc $(grep -c '^CURL POST' "$MW/clog20c")"

AH="$MW/A20d"; BH="$MW/B20d"; rm -rf "$AH" "$BH"; mkdir -p "$AH" "$BH"
mig_fixture "$AH"
mkdir -p "$BH/.config/share" "$BH/share/pub/zzzzzz"
printf 'hosts=nobody\nport=19562\n' > "$BH/.config/share/config"
printf 'zzzzzz\told.txt\t/old\t2026-01-01\t0\t\n' > "$BH/share/index.tsv"
: > "$MW/clog20d"
out=$(mig_a "$AH" "$BH" "$MW/clog20d" migrate --to m20d-target --remote-bin "$MW/remotebin" --yes 2>&1); rc=$?
check "row 20: B's not_setup profile already holding a row refuses before any copy" "1 0" "$rc $(grep -c '^CURL POST' "$MW/clog20d")"

echo "--- row 20/21: a copy failure stops before the switch; a rerun skips the moved id ---"
AH="$MW/A21"; BH="$MW/B21"; rm -rf "$AH" "$BH"; mkdir -p "$AH" "$BH"
mig_fixture "$AH"
mkdir -p "$BH/.config/share"; printf 'hosts=nobody\nport=19563\n' > "$BH/.config/share/config"
: > "$MW/clog21"; : > "$MW/mssh.log"
FAIL_SECOND="$MW/fail-second-remotebin"; mkdir -p "$FAIL_SECOND"
cp "$MW/remotebin/curl" "$FAIL_SECOND/curl"; cp "$MW/remotebin/security" "$FAIL_SECOND/security"
chmod +x "$FAIL_SECOND/curl" "$FAIL_SECOND/security"
cat > "$FAIL_SECOND/share" <<EOF
#!/bin/bash
if [[ "\$1" == import && "\$2" == 1a0002 ]]; then echo "share: import: simulated failure" >&2; exit 1; fi
exec bash "$SH" "\$@"
EOF
chmod +x "$FAIL_SECOND/share"
out=$(mig_a "$AH" "$BH" "$MW/clog21" migrate --to m21-target --remote-bin "$FAIL_SECOND" --yes 2>&1); rc=$?
check "row 20: the copy failing on the second id stops; the first id is on B, A unchanged" "1 1 1 1" \
  "$rc $(grep -qc '^1a0001	' "$AH/share/index.tsv" >/dev/null && echo 1 || echo 0) $(grep -qc '^1a0001	' "$BH/share/index.tsv" >/dev/null && echo 1 || echo 0) $([[ ! -f $AH/share/index.migrated ]] && echo 1 || echo 0)"
out=$(mig_a "$AH" "$BH" "$MW/clog21" migrate --to m21-target --remote-bin "$MW/remotebin" --yes 2>&1); rc=$?
check "row 21: a rerun skips the id already on B and copies the rest" "0 1 1" \
  "$rc $(grep -c '1a0001 already on' <<<"$out") $(grep -c '^1a0002	' "$BH/share/index.tsv")"

echo "--- row 20: a gated link that fails to gate correctly stops before retire ---"
AH="$MW/A20e"; BH="$MW/B20e"; rm -rf "$AH" "$BH"; mkdir -p "$AH" "$BH"
mig_fixture "$AH"
mkdir -p "$BH/.config/share"; printf 'hosts=nobody\nport=19564\n' > "$BH/.config/share/config"
: > "$MW/clog20e"
out=$(GATE_KID=wrong-aud mig_a "$AH" "$BH" "$MW/clog20e" migrate --to m20e-target --remote-bin "$MW/remotebin" --yes 2>&1); rc=$?
check "row 20: a gated link that fails to gate correctly stops before retire, naming it" "1 1 0" \
  "$rc $([[ $(grep -c "$GATEDID" <<<"$out") -ge 1 ]] && echo 1 || echo 0) $([[ -f $AH/share/index.migrated ]] && echo 1 || echo 0)"

echo "--- row 31: the printed rollback, run in dry mode, touches only A's own tunnel ---"
AH="$MW/A31"; BH="$MW/B31"; rm -rf "$AH" "$BH"; mkdir -p "$AH" "$BH"
mig_fixture "$AH"
mkdir -p "$BH/.config/share"; printf 'hosts=nobody\nport=19565\n' > "$BH/.config/share/config"
: > "$MW/clog31"
FAIL_SETUP="$MW/fail-setup-remotebin"; mkdir -p "$FAIL_SETUP"
cp "$MW/remotebin/curl" "$FAIL_SETUP/curl"; cp "$MW/remotebin/security" "$FAIL_SETUP/security"
chmod +x "$FAIL_SETUP/curl" "$FAIL_SETUP/security"
cat > "$FAIL_SETUP/share" <<EOF
#!/bin/bash
[[ "\$1" == setup ]] && { echo "share: setup: simulated remote-setup failure" >&2; exit 1; }
exec bash "$SH" "\$@"
EOF
chmod +x "$FAIL_SETUP/share"
out=$(mig_a "$AH" "$BH" "$MW/clog31" migrate --to m31-target --remote-bin "$FAIL_SETUP" --yes 2>&1); rc=$?
check "row 20: a remote-setup failure stops before retire, printing the rollback with A's own tunnel-name" "1 1 0" \
  "$rc $(grep -c -- '--tunnel-name tun-A' <<<"$out") $([[ -f $AH/share/index.migrated ]] && echo 1 || echo 0)"
: > "$MW/clog31b"
sed -i.bak 's/^hosts=.*/hosts=nobody/' "$AH/.config/share/config"   # the rollback check below is about the tunnel/DNS calls, not a live service; keep it off this machine's real launchd
out=$(mig_a "$AH" "$BH" "$MW/clog31b" setup "$MHOST" --tunnel-name tun-A --force 2>&1); rc=$?
check "row 31: the rollback in dry mode names A's own tunnel; no call names a new tunnel id" "0 1 0" \
  "$rc $(grep -c 'tunnel:     reusing tun-A' <<<"$out") $(grep -c 'tid-new' "$MW/clog31b")"
check "row 31: A's config keeps its own tunnel_id" "tid-A" "$(sed -n 's/^tunnel_id=//p' "$AH/.config/share/config")"

echo "--- setup: old_host empty must not skip the gated-share guard (import into a not_setup profile, then setup) ---"
OH="$MW/oldhostempty"; rm -rf "$OH"; mkdir -p "$OH/.config/share" "$OH/share/pub/aa0001"
printf 'secret\n' > "$OH/share/pub/aa0001/g.txt"
printf 'aa0001\tg.txt\t/src/g.txt\t2026-09-01\t0\taccess=00000000-0000-4000-8000-0000000000aa access_rule=email:a@x.test\n' > "$OH/share/index.tsv"
# no .config/share/config at all: cmd_import never writes one, so a profile fed only by `import` is not_setup
mkdir -p "$MW/nocurl-oh"
cat > "$MW/nocurl-oh/curl" <<'EOF'
#!/bin/bash
echo "CALL $*" >> "${OH_CURL_LOG:?}"
echo '{"success":false,"errors":[{"code":0}]}'
EOF
chmod +x "$MW/nocurl-oh/curl"
: > "$MW/clogoh"
out=$(env -u SHARE_ROOT -u SHARE_CONFIG_DIR -u SHARE_PORT -u SHARE_HOSTNAME -u XDG_CONFIG_HOME -u SHARE_PROFILE -u SHARE_BACKEND -u SHARE_HOSTS -u SHARE_TUNNEL \
  HOME="$OH" PATH="$MW/nocurl-oh:$PATH" CLOUDFLARE_API_TOKEN=faketoken OH_CURL_LOG="$MW/clogoh" bash "$SH" setup other.example.test --no-service 2>&1); rc=$?
check "setup on a not_setup profile already holding a gated row is refused" "1" "$rc"
check "the refusal names the gated row, not a Cloudflare error" "1" "$(grep -c 'already holds gated shares' <<<"$out")"
check "the refusal happens before any Cloudflare call" "0" "$(grep -c . "$MW/clogoh")"
check "the gated row is untouched" "1" "$(grep -c '^aa0001	' "$OH/share/index.tsv")"

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

echo "=== self-test: an aborted run reports ABORTED, never a clean summary ==="
ABORT_SELFTEST="$WORK/abort-selftest.sh"
sed -n '1,/^# share-test-abort-anchor:/p' "$0" >"$ABORT_SELFTEST"
aout=$(SHARE_TEST_PORT_BASE=$((base + 2000)) bash "$ABORT_SELFTEST" 2>&1); arc=$?
check "a run truncated before the end exits 2" "2" "$arc"
check "a run truncated before the end reports ABORTED" "1" "$(grep -c '^ABORTED' <<<"$aout")"

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
# The security stub keeps every token read and write off the login Keychain; a share* item
# added, changed, or removed here means a call reached the real binary.
check "no real Keychain share item changed during the run" "$keychain_before" "$(real_keychain_share)"

reached_end=1
echo
if [[ $fails -gt 0 ]]; then
  echo "$fails/$total FAILED"
  for log in serve.log caddy.log; do
    echo "--- $log"; tail -20 "$SHARE_ROOT/$log" 2>/dev/null
  done
  exit 1
fi
echo "$total checks, PASS"
