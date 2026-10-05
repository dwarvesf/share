#!/bin/bash
# Live rehearsal R2 of SPEC-008: moving a tenant's origin with `share migrate`, on throwaway names, against a
# real Cloudflare account. Three legs, each with proof through the API that nothing is left:
#   M0  a remote-setup failure after the switch, then the printed rollback: the hostname serves from A's tunnel again
#   M1  the same name migrated again (B already holds the copies): every snapshot link answers from B at the same
#       URL, the gated one keeps its 302 and AUD, the live link is reported as not moved, A's tunnel is gone and the
#       DNS record points at B's tunnel; the 530 gap is measured and logged
#   M2  (optional) a second throwaway name moved from a real second machine (SHARE_E2E_AIR_SSH) to this one over ssh
# Run it by hand before the personal move (P2). CI has no account or token. TASK-9b of SPEC-008.
#
#   SHARE_E2E_TENANT_HOST=share-e2e-m1.example.com SHARE_E2E_AIR_HOST=share-e2e-m2.example.com \
#     CLOUDFLARE_API_TOKEN=<admin> SHARE_E2E_ACCESS_RULE=group:<name> SHARE_E2E_AIR_SSH=air \
#     SHARE_E2E_MINI_TARGET=mini-tieubao SHARE_BIN=bin/share tests/e2e-migrate.sh
#
# Inputs:
#   SHARE_E2E_TENANT_HOST   an unused hostname whose first label starts with share-e2e, on a zone the admin token edits
#   SHARE_E2E_AIR_HOST      a second such name in the same zone; with SHARE_E2E_AIR_SSH unset the M2 leg is skipped
#   CLOUDFLARE_API_TOKEN    the admin token: Tunnel Edit, DNS Edit, Zone Read, Access Apps Edit, Access Organizations Read
#   SHARE_E2E_ACCESS_RULE   group:<name>, email:<a@b>, or domain:<d>: the gated snapshot (without it the gated checks SKIP)
#   SHARE_E2E_AIR_SSH       the ssh alias of the machine that stands in for the Air; it must reach SHARE_E2E_MINI_TARGET
#   SHARE_E2E_MINI_TARGET   how that machine reaches THIS one over ssh (a Host alias or user@host)
# The script refuses a hostname without the share-e2e prefix, so no real tenant is reachable. Every leg runs under
# mktemp HOMEs and its own share profiles (mga, mgb), so a real login service on either machine is never touched.
# A stub `security` first on PATH keeps the real Keychain out of it. Tokens reach share through the environment and
# stdin, never argv. It tests the share it is pointed at: SHARE_BIN (default: share on PATH).
set -uo pipefail

tenant="${SHARE_E2E_TENANT_HOST:?set SHARE_E2E_TENANT_HOST to an unused share-e2e* hostname}"
air_host="${SHARE_E2E_AIR_HOST:-}"
admin="${CLOUDFLARE_API_TOKEN:?set CLOUDFLARE_API_TOKEN to the admin token}"
rule="${SHARE_E2E_ACCESS_RULE:-}"
air_ssh="${SHARE_E2E_AIR_SSH:-}"
mini_target="${SHARE_E2E_MINI_TARGET:-}"
share="${SHARE_BIN:-share}"
for h in "$tenant" ${air_host:+"$air_host"}; do
  [[ ${h%%.*} == share-e2e* ]] || { echo "refused: hostname '$h' must have a first label starting with share-e2e"; exit 2; }
done
[[ -z $air_host || ${tenant#*.} == "${air_host#*.}" ]] || { echo "refused: $tenant and $air_host must share one zone"; exit 2; }
[[ -z $air_ssh || ( -n $air_host && -n $mini_target ) ]] || { echo "refused: SHARE_E2E_AIR_SSH needs SHARE_E2E_AIR_HOST and SHARE_E2E_MINI_TARGET"; exit 2; }
for c in jq curl python3 cloudflared caddy; do command -v "$c" >/dev/null || { echo "missing: $c"; exit 2; }; done
# the M2 leg's target side runs under this account's own HOME (ssh gives it no other), so its profile must not exist yet
[[ -z $air_ssh || ! -e $HOME/.config/share/profiles/mgb ]] || { echo "refused: $HOME/.config/share/profiles/mgb already exists; the M2 leg needs that profile name free"; exit 2; }
command -v "$share" >/dev/null || { echo "missing: $share on PATH (or set SHARE_BIN)"; exit 2; }
share="$(command -v "$share")"; share="$(cd "$(dirname "$share")" && pwd)/$(basename "$share")"
unset SHARE_CONFIG_DIR SHARE_ROOT SHARE_PROFILE XDG_CONFIG_HOME SHARE_HOSTNAME SHARE_BACKEND SHARE_R2_TOKEN SHARE_R2_DRY SHARE_R2_KEY_ID SHARE_PORT
export SHARE_CLIPBOARD=0

WORK=$(mktemp -d)
mkdir -p "$WORK/bin" "$WORK/kc" "$WORK/failbin"
# A file-backed stand-in for the Keychain: a real tunnel setup needs a real round trip (store the tunnel token, read it
# back to start cloudflared), and the real Keychain prompts on a first write from a script with no one to click it, and
# is locked in a plain ssh session. `security -i` batch-adds, `add-generic-password` is migrate's own probe, `find-` reads.
cat >"$WORK/bin/security" <<'PY'
#!/usr/bin/env python3
import sys, os, re
store = os.environ.get("SHARE_E2E_KC_STORE") or os.path.join(os.path.dirname(os.path.realpath(__file__)), "..", "kc")
def path(key): return os.path.join(store, re.sub(r"[^A-Za-z0-9_.-]", "_", key))
args = sys.argv[1:]
def opt(flag): return args[args.index(flag) + 1] if flag in args and args.index(flag) + 1 < len(args) else ""
if args[:1] == ["-i"]:
    line = sys.stdin.readline()
    m_s = re.search(r'-s\s+"([^"]*)"', line); m_w = re.search(r'-w\s+"([^"]*)"', line)
    if m_s and m_w:
        with open(path(m_s.group(1)), "w") as f: f.write(m_w.group(1))
    sys.exit(0)
elif args[:1] == ["add-generic-password"]:
    with open(path(opt("-s")), "w") as f: f.write(opt("-w"))
    sys.exit(0)
elif args[:1] == ["find-generic-password"]:
    p = path(opt("-s"))
    if os.path.isfile(p):
        with open(p) as f: sys.stdout.write(f.read())
        sys.exit(0)
    sys.exit(44)
elif args[:1] == ["delete-generic-password"]:
    p = path(opt("-s"))
    if os.path.isfile(p): os.remove(p); sys.exit(0)
    sys.exit(44)
sys.exit(44)
PY
chmod +x "$WORK/bin/security"
export PATH="$WORK/bin:$PATH" SHARE_E2E_KC_STORE="$WORK/kc"
# the remote side runs this share through a wrapper, so the one remote bin dir holds the stub and the binary under test
printf '#!/bin/bash\nexec bash "%s" "$@"\n' "$share" >"$WORK/bin/share"; chmod +x "$WORK/bin/share"
# M0's remote bin: the real setup runs (the switch happens), then the wrapper reports a failure
cp "$WORK/bin/security" "$WORK/failbin/security"
# shellcheck disable=SC2016 # the wrapper's own $@ and $rc stay literal
printf '#!/bin/bash\nbash "%s" "$@"; rc=$?\nfor a in "$@"; do [[ $a == setup ]] && exit 1; done\nexit $rc\n' "$share" >"$WORK/failbin/share"
chmod +x "$WORK/failbin/share"

RUNLOG="$WORK/run.log"
VERIF_DIR="$(cd "$(dirname "$0")/.." && pwd)/docs/verification"
mkdir -p "$VERIF_DIR"
RUNLOG_KEEP="$VERIF_DIR/e2e-migrate-$(date -u +%Y%m%dT%H%M%SZ).log"
exec > >(tee "$RUNLOG") 2>&1

fails=0 total=0
check() { # check <label> <expected> <actual>
  total=$((total + 1))
  if [[ $2 == "$3" ]]; then echo "  ok    $1"; else echo "  FAIL  $1: expected '$2', got '$3'"; fails=$((fails + 1)); fi
}
note() { echo "  | $1"; }
indent() { sed 's/^/  | /'; }
fetch() { curl -s --max-time 10 --doh-url https://1.1.1.1/dns-query "$@"; }
code() { fetch -o /dev/null -w '%{http_code}' --path-as-is "$1"; }
apit() { local t=$1 p=$2; shift 2; curl -s "https://api.cloudflare.com/client/v4$p" -H @<(printf 'Authorization: Bearer %s\n' "$t") "$@"; }
api() { apit "$admin" "$@"; }

zone_json="$(api "/zones?name=${tenant#*.}&status=active")"
zone="$(jq -r '.result[0].id // empty' <<<"$zone_json")"
acct="$(jq -r '.result[0].account.id // empty' <<<"$zone_json")"
[[ -n $zone && -n $acct ]] || { echo "refused: the admin token sees no active zone ${tenant#*.}"; exit 2; }

# --- leftover tracking: every name this run uses, swept on exit regardless of where it stopped ---
HOSTS=()
track_host() { HOSTS+=("$1"); }
tunnels_of() { api "/accounts/$acct/cfd_tunnel?is_deleted=false&per_page=100" | jq -r --arg p "share-${1//./-}" '.result[]? | select(.name == $p or .name == ($p + "-m")) | .id'; }
dns_target() { api "/zones/$zone/dns_records?name=$1" | jq -r '.result[0].content // empty'; }
tunnel_of_dns() { local c; c="$(dns_target "$1")"; echo "${c%.cfargotunnel.com}"; }

leftovers() { # sweep and prove: nothing named for this run remains
  local h id tid leftover=0 c
  for h in "${HOSTS[@]}"; do
    for id in $(api "/accounts/$acct/access/apps?per_page=100" | jq -r --arg h "$h" '.result[]? | (.name | split(" ")) as $p | select(($p | length) >= 4 and $p[0] == "share" and $p[2] == $h) | .id'); do
      api "/accounts/$acct/access/apps/$id" -X DELETE -o /dev/null
    done
    for id in $(api "/zones/$zone/dns_records?name=$h" | jq -r '.result[]?.id'); do api "/zones/$zone/dns_records/$id" -X DELETE -o /dev/null; done
    for tid in $(tunnels_of "$h"); do
      api "/accounts/$acct/cfd_tunnel/$tid/connections" -X DELETE -o /dev/null
      api "/accounts/$acct/cfd_tunnel/$tid" -X DELETE -o /dev/null
    done
  done
  for h in "${HOSTS[@]}"; do
    c="$(api "/zones/$zone/dns_records?name=$h" | jq '.result | length')"
    [[ $c == 0 ]] || { echo "LEFTOVER: $c DNS record(s) for $h"; leftover=1; }
    c="$(tunnels_of "$h" | grep -c . || true)"
    [[ $c == 0 ]] || { echo "LEFTOVER: $c tunnel(s) for $h"; leftover=1; }
    c="$(api "/accounts/$acct/access/apps?per_page=100" | jq --arg h "$h" '[.result[]? | select((.name | split(" ")) [2]? == $h)] | length')"
    [[ $c == 0 ]] || { echo "LEFTOVER: $c Access app(s) for $h"; leftover=1; }
  done
  [[ $leftover == 0 ]] && echo "cleanup: nothing left for this run's names"
  return 0
}
PIDS=()
cleanup() {
  local p; for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done
  # the services this run installed, on this machine: tear each profile down so no launchd job outlives it
  local prof home
  for home in "$WORK"/h-*; do
    [[ -d $home ]] || continue
    for prof in mga mgb; do
      [[ -d $home/.config/share/profiles/$prof ]] || continue
      HOME="$home" CLOUDFLARE_API_TOKEN="$admin" SHARE_PORT=1 bash "$share" --profile "$prof" teardown --yes >/dev/null 2>&1 || true
    done
  done
  if [[ -n $air_ssh && -d $HOME/.config/share/profiles/mgb ]]; then   # the M2 target profile lives under the real HOME
    CLOUDFLARE_API_TOKEN="$admin" bash "$share" --profile mgb teardown --yes >/dev/null 2>&1 || true
    [[ ! -d $HOME/share/profiles/mgb ]] || mv -f "$HOME/share/profiles/mgb" "$WORK/mgb-root" 2>/dev/null || true
  fi
  leftovers
  cp "$RUNLOG" "$RUNLOG_KEEP" 2>/dev/null || true
  echo "run log: $RUNLOG_KEEP"
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "=== before: nothing named for this run exists ==="
for h in "$tenant" ${air_host:+"$air_host"}; do
  check "no DNS record for $h" 0 "$(api "/zones/$zone/dns_records?name=$h" | jq '.result | length')"
  check "no tunnel for $h" 0 "$(tunnels_of "$h" | grep -c . || true)"
done
[[ $fails == 0 ]] || { echo "refused: the run's names are in use"; trap - EXIT; cp "$RUNLOG" "$RUNLOG_KEEP" 2>/dev/null; rm -rf "$WORK"; exit 2; }

RB=$((20000 + (RANDOM % 6000)))
APORT=$RB BPORT=$((RB + 20)) LPORT=$((RB + 40))
track_host "$tenant"
[[ -z $air_host ]] || track_host "$air_host"

# the machine-B stand-in is this machine under another HOME: the seam joins the remote argv into one string and runs it
# through the login shell, as ssh would (the same shape tests/share.sh uses)
cat >"$WORK/mssh" <<EOF
#!/bin/bash
joined=""
for a in "\$@"; do joined="\$joined \$a"; done
sh=sh; command -v fish >/dev/null 2>&1 && sh=fish
exec env -u SHARE_ROOT -u SHARE_CONFIG_DIR -u SHARE_HOSTNAME -u XDG_CONFIG_HOME -u SHARE_PROFILE -u SHARE_BACKEND -u SHARE_HOSTS \\
  HOME="$WORK/h-b" SHARE_PORT=$BPORT SHARE_E2E_KC_STORE="$WORK/kc" PATH="$WORK/bin:\$PATH" "\$sh" -c "\$joined"
EOF
chmod +x "$WORK/mssh"
mkdir -p "$WORK/h-a" "$WORK/h-b"

mg_a() { env HOME="$WORK/h-a" SHARE_PORT=$APORT CLOUDFLARE_API_TOKEN="$admin" bash "$share" --profile mga "$@"; }
mg_b() { env HOME="$WORK/h-b" SHARE_PORT=$BPORT CLOUDFLARE_API_TOKEN="$admin" bash "$share" --profile mgb "$@"; }

echo "=== L0 origin A: tunnel setup; a snapshot, a folder, a gated snapshot, a live server ==="
out="$(mg_a setup "$tenant" 2>&1)"; rc=$?
indent <<<"$out"
check "A setup exits 0" 0 "$rc"
a_tunnel="$(tunnel_of_dns "$tenant")"
note "A's tunnel $(echo "$a_tunnel" | cut -c1-8)..."
mkdir -p "$WORK/src/folder"
echo "snapshot one" >"$WORK/src/one.txt"; echo "folder file" >"$WORK/src/folder/a.txt"; echo "<h1>folder</h1>" >"$WORK/src/folder/index.html"
echo "gated secret" >"$WORK/src/gated.txt"
mkdir -p "$WORK/live"; echo "live page" >"$WORK/live/index.html"
python3 -m http.server "$LPORT" --bind 127.0.0.1 --directory "$WORK/live" >/dev/null 2>&1 & PIDS+=("$!")
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$LPORT/" && break; sleep 0.1; done
l1="$(mg_a add "$WORK/src/one.txt" 2>/dev/null | head -1)"
l2="$(mg_a add "$WORK/src/folder" 2>/dev/null | head -1)"
l4="$(mg_a add "$LPORT" 2>/dev/null | head -1)"
l3=""
if [[ -n $rule ]]; then
  l3="$(mg_a add "$WORK/src/gated.txt" --access "$rule" 2>"$WORK/gate.err" | head -1)"; indent <"$WORK/gate.err"
  g_id="$(cut -d/ -f4 <<<"$l3")"
  g_aud="$(api "/accounts/$acct/access/apps?per_page=100" | jq -r --arg s "share $g_id $tenant " '[.result[]? | select(.name | startswith($s))] | first | .aud // empty')"
else
  echo "gated leg: SKIP (no SHARE_E2E_ACCESS_RULE)"
fi
check "the snapshot link answers from A" "snapshot one" "$(fetch "$l1")"
check "the folder link answers from A" 1 "$(fetch "$l2" | grep -c '<h1>folder</h1>')"
check "the live link answers from A" 1 "$(fetch "$l4" | grep -c 'live page')"
[[ -z $l3 ]] || check "the gated link 302s to Access with kid == aud" 1 "$([[ "$(fetch -o /dev/null -w '%{http_code} %{redirect_url}' --path-as-is "$l3")" == 302*"kid=$g_aud"* ]] && echo 1 || echo 0)"

verify_moved() { # verify_moved <label>: every moved link answers from the new origin at the same URL
  check "$1: the snapshot link answers at the same URL" "snapshot one" "$(fetch "$l1")"
  check "$1: the folder link answers at the same URL" 1 "$(fetch "$l2" | grep -c '<h1>folder</h1>')"
  [[ -z $l3 ]] || check "$1: the gated link keeps its 302 and AUD" 1 "$([[ "$(fetch -o /dev/null -w '%{http_code} %{redirect_url}' --path-as-is "$l3")" == 302*"kid=$g_aud"* ]] && echo 1 || echo 0)"
}

echo "=== M0 a remote-setup failure after the switch, then the printed rollback ==="
out="$(SHARE_MIGRATE_SSH="$WORK/mssh" mg_a migrate --to local-b --remote-profile mgb --remote-bin "$WORK/failbin" --yes 2>&1)"; rc=$?
indent <<<"$out"
check "M0: migrate exits 1 on the injected failure" 1 "$rc"
rollback="$(grep -o 'Rollback if .* is down: .*' <<<"$out" | head -1 | sed 's/^Rollback if .* is down: //')"
check "M0: the printed rollback names A's own tunnel name" 1 "$([[ $rollback == *"setup $tenant --tunnel-name share-"* ]] && echo 1 || echo 0)"
b_tunnel="$(tunnel_of_dns "$tenant")"
check "M0: the switch moved the DNS record off A's tunnel" 1 "$([[ -n $b_tunnel && $b_tunnel != "$a_tunnel" ]] && echo 1 || echo 0)"
check "M0: A kept its rows and its trees (nothing moved aside)" 1 "$([[ -f $WORK/h-a/share/profiles/mga/index.tsv && ! -f $WORK/h-a/share/profiles/mga/index.migrated ]] && echo 1 || echo 0)"
if [[ -n $rollback ]]; then
  note "running the printed rollback: $rollback"
  read -ra rb_args <<<"${rollback#share --profile mga }"
  out="$(mg_a "${rb_args[@]}" 2>&1)"; rc=$?
  indent <<<"$out"
  check "M0: the printed rollback exits 0" 0 "$rc"
fi
check "M0: the DNS record points at A's own tunnel again" "$a_tunnel" "$(tunnel_of_dns "$tenant")"
verify_moved "M0 after the rollback"

echo "=== M1 migrate again: B already holds the copies; the switch, the verify, the retire ==="
: >"$WORK/gap.log"
( while :; do printf '%s %s\n' "$(date +%s)" "$(code "$l1")" >>"$WORK/gap.log"; sleep 0.5; done ) & gap_pid=$!; PIDS+=("$gap_pid")
out="$(SHARE_MIGRATE_SSH="$WORK/mssh" mg_a migrate --to local-b --remote-profile mgb --remote-bin "$WORK/bin" --yes 2>&1)"; rc=$?
kill "$gap_pid" 2>/dev/null; wait "$gap_pid" 2>/dev/null
indent <<<"$out"
check "M1: migrate exits 0" 0 "$rc"
check "M1: a rerun skips the copies B already holds" 1 "$([[ $(grep -c 'already' <<<"$out") -ge 1 ]] && echo 1 || echo 0)"
check "M1: the live link is reported as not moved" 1 "$(grep -c "not moved:  live link .* (port $LPORT)" <<<"$out")"
verify_moved "M1"
b_tunnel2="$(tunnel_of_dns "$tenant")"
check "M1: the DNS record points at B's own tunnel, not A's" 1 "$([[ -n $b_tunnel2 && $b_tunnel2 != "$a_tunnel" ]] && echo 1 || echo 0)"
check "M1: A's tunnel is deleted" 0 "$(api "/accounts/$acct/cfd_tunnel?is_deleted=false&per_page=100" | jq --arg id "$a_tunnel" '[.result[]? | select(.id == $id)] | length')"
check "M1: A's rows moved aside, its trees under migrated/" 1 "$([[ -s $WORK/h-a/share/profiles/mga/index.migrated && -d $WORK/h-a/share/profiles/mga/migrated ]] && echo 1 || echo 0)"
non200="$(awk '$2 != 200' "$WORK/gap.log" | wc -l | tr -d ' ')"
first_bad="$(awk '$2 != 200 {print $1; exit}' "$WORK/gap.log")"; last_bad="$(awk '$2 != 200 {t = $1} END {print t}' "$WORK/gap.log")"
note "measured gap on $l1: $non200 probes (every 0.5 s) answered other than 200, spanning $(( ${last_bad:-0} - ${first_bad:-0} )) s of $(wc -l <"$WORK/gap.log" | tr -d ' ') probes; codes: $(awk '$2 != 200 {print $2}' "$WORK/gap.log" | sort | uniq -c | tr '\n' ' ')"
note "B's profile on this machine: $(mg_b state 2>/dev/null | jq -r '"\(.state) \(.hostname)"')"
mg_b teardown --yes >/dev/null 2>&1
check "M1 cleanup: the tenant's DNS and tunnels are gone after B's teardown" 0 "$(api "/zones/$zone/dns_records?name=$tenant" | jq '.result | length')"

if [[ -n $air_ssh ]]; then
  echo "=== M2 a second throwaway name moved from $air_ssh to this machine over ssh ==="
  umask 077; printf '%s' "$admin" >"$WORK/airtok"; umask 022
  cp "$WORK/bin/security" "$WORK/airsec"
  cat >"$WORK/air-leg.sh" <<'AIR'
#!/bin/bash
# runs on the stand-in machine, in a private dir: setup a throwaway origin, publish, migrate to the target, report the links
set -uo pipefail
host="$1" port="$2" lport="$3" target="$4" rbin="$5" rule="$6"
export CLOUDFLARE_API_TOKEN; CLOUDFLARE_API_TOKEN="$(cat ./airtok)"
H="$PWD/h"; mkdir -p "$H" "$PWD/bin" "$PWD/kc" "$PWD/src/folder" "$PWD/live"
cp ./airsec "$PWD/bin/security"; chmod +x "$PWD/bin/security"
chmod +x ./share
export PATH="$PWD/bin:$PATH" SHARE_E2E_KC_STORE="$PWD/kc" SHARE_CLIPBOARD=0
unset SHARE_CONFIG_DIR SHARE_ROOT SHARE_PROFILE XDG_CONFIG_HOME SHARE_HOSTNAME SHARE_BACKEND
a() { env HOME="$H" SHARE_PORT="$port" bash ./share --profile mga "$@"; }
trap 'a teardown --yes >/dev/null 2>&1 || true; kill %1 2>/dev/null || true' EXIT
a setup "$host" 2>&1 | sed 's/^/AIR setup: /' || exit 3
echo "snapshot one" >src/one.txt; echo "folder file" >src/folder/a.txt; echo "<h1>folder</h1>" >src/folder/index.html; echo "gated secret" >src/gated.txt
echo "live page" >live/index.html
python3 -m http.server "$lport" --bind 127.0.0.1 --directory "$PWD/live" >/dev/null 2>&1 &
sleep 1
echo "LINK1 $(a add src/one.txt 2>/dev/null | head -1)"
echo "LINK2 $(a add src/folder 2>/dev/null | head -1)"
echo "LINK4 $(a add "$lport" 2>/dev/null | head -1)"
if [[ -n $rule ]]; then echo "LINK3 $(a add src/gated.txt --access "$rule" 2>/dev/null | head -1)"; fi
echo "READY"
a migrate --to "$target" --remote-profile mgb --remote-bin "$rbin" --yes 2>&1 | sed 's/^/AIR migrate: /'
echo "MIGRATE-RC ${PIPESTATUS[0]}"
AIR
  chmod +x "$WORK/air-leg.sh"
  ( cd "$WORK" && mini-run --host "$air_ssh" --timeout 1500 --with "$share" --with airtok --with airsec "$WORK/air-leg.sh" "$air_host" $((RB + 60)) $((RB + 80)) "$mini_target" "$WORK/bin" "$rule" ) >"$WORK/air.out" 2>&1 &
  air_pid=$!
  : >"$WORK/gap2.log"
  until grep -q '^READY' "$WORK/air.out" 2>/dev/null || ! kill -0 "$air_pid" 2>/dev/null; do sleep 2; done
  : >|"$WORK/airtok"
  al1="$(sed -n 's/^LINK1 //p' "$WORK/air.out")"; al2="$(sed -n 's/^LINK2 //p' "$WORK/air.out")"; al3="$(sed -n 's/^LINK3 //p' "$WORK/air.out")";
  if [[ -n $al1 ]]; then
    ag_aud=""; [[ -z $al3 ]] || ag_aud="$(api "/accounts/$acct/access/apps?per_page=100" | jq -r --arg s "share $(cut -d/ -f4 <<<"$al3") $air_host " '[.result[]? | select(.name | startswith($s))] | first | .aud // empty')"
    check "M2: the snapshot link answers from the stand-in before the move" "snapshot one" "$(fetch "$al1")"
    ( while kill -0 "$air_pid" 2>/dev/null; do printf '%s %s\n' "$(date +%s)" "$(code "$al1")" >>"$WORK/gap2.log"; sleep 0.5; done ) & gap2_pid=$!; PIDS+=("$gap2_pid")
  fi
  wait "$air_pid"; air_rc=$?
  kill "${gap2_pid:-0}" 2>/dev/null; wait "${gap2_pid:-0}" 2>/dev/null
  indent <"$WORK/air.out"
  check "M2: the stand-in's script exits 0" 0 "$air_rc"
  check "M2: migrate exits 0 on the stand-in" 0 "$(sed -n 's/^MIGRATE-RC //p' "$WORK/air.out")"
  check "M2: the live link is reported as not moved" 1 "$(grep -c 'not moved:  live link' "$WORK/air.out")"
  check "M2: the snapshot link answers from this machine at the same URL" "snapshot one" "$(fetch "$al1")"
  check "M2: the folder link answers at the same URL" 1 "$(fetch "$al2" | grep -c '<h1>folder</h1>')"
  [[ -z $al3 ]] || check "M2: the gated link keeps its 302 and AUD" 1 "$([[ "$(fetch -o /dev/null -w '%{http_code} %{redirect_url}' --path-as-is "$al3")" == 302*"kid=$ag_aud"* ]] && echo 1 || echo 0)"
  check "M2: the DNS record points at a tunnel of this machine's profile" 1 "$([[ -n $(tunnel_of_dns "$air_host") ]] && echo 1 || echo 0)"
  check "M2: only one tunnel remains for the name (the stand-in's is deleted)" 1 "$(tunnels_of "$air_host" | grep -c . || true)"
  non200="$(awk '$2 != 200' "$WORK/gap2.log" | wc -l | tr -d ' ')"
  f2="$(awk '$2 != 200 {print $1; exit}' "$WORK/gap2.log")"; l2="$(awk '$2 != 200 {t = $1} END {print t}' "$WORK/gap2.log")"
  note "measured gap on $al1: $non200 probes answered other than 200, spanning $(( ${l2:-0} - ${f2:-0} )) s; codes: $(awk '$2 != 200 {print $2}' "$WORK/gap2.log" | sort | uniq -c | tr '\n' ' ')"
  CLOUDFLARE_API_TOKEN="$admin" bash "$share" --profile mgb teardown --yes >/dev/null 2>&1 || true
  check "M2 cleanup: the name's DNS is gone after B's teardown" 0 "$(api "/zones/$zone/dns_records?name=$air_host" | jq '.result | length')"
fi

echo
echo "$((total - fails))/$total checks passed"
if [[ $fails -gt 0 ]]; then echo "$fails FAILED"; exit 1; fi
echo PASS
