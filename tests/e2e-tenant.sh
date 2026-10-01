#!/bin/bash
# Live leg of the one-host-per-tenant spec against a real Cloudflare account: a tunnel origin
# turns on R2 (L1-L3), a member and a fresh joiner publish cloud links through an outage (L4-L5),
# the encoded-path and rollback rows (L6-L9), an admin purge plus teardown (L10), then the Dwarves
# alias-fold rehearsal with its rollback (R1), each with proof through the API that nothing is left.
# Run it by hand before a release that touches setup --r2, --alias, or the tenant Worker; CI has
# no account or token. TASK-9a of SPEC-008.
#
#   SHARE_E2E_TENANT_HOST=share-e2e-t1.example.com SHARE_E2E_ALIAS_HOST=share-e2e-a1.example.com \
#     CLOUDFLARE_API_TOKEN=<admin> SHARE_E2E_R2_PUBLISHER_TOKEN=<token already scoped to a share-e2e-* bucket> \
#     SHARE_E2E_ACCESS_EMAIL=you@example.com tests/e2e-tenant.sh
#   ... SHARE_E2E_R2_TOKEN_ADMIN=<token with User API Tokens: Edit>   # mints fresh 2h publisher tokens instead
#
# Inputs:
#   SHARE_E2E_TENANT_HOST, SHARE_E2E_ALIAS_HOST   unused hostnames whose first label starts with
#                          share-e2e, on a zone the admin token edits; never s.d.foundation,
#                          f.d.foundation, s.han.ws, or any real tenant hostname
#   CLOUDFLARE_API_TOKEN  the admin token: Tunnel Edit, DNS Edit, Zone Read, Workers Scripts Edit,
#                         Workers Routes Edit, Workers R2 Storage Edit, Access Apps Edit, Access
#                         Organizations Read (account), DNS Read (zone)
#   SHARE_E2E_R2_PUBLISHER_TOKEN   a bucket-scoped publisher token for a member join. With
#                         SHARE_E2E_R2_TOKEN_ADMIN set instead, the script mints its own 2h tokens
#                         (POST /user/tokens) and revokes them on exit, the tests/e2e-r2.sh model.
#   SHARE_E2E_ACCESS_EMAIL   the gated-link leg; without it the gated checks SKIP (recorded, not failed)
#   SHARE_E2E_ACCESS_RULE    group:<name> or domain:<domain>, in place of SHARE_E2E_ACCESS_EMAIL (tests/e2e-r2.sh model)
#
# The bucket is share-e2e-<6 hex> each run; the script refuses a hostname or bucket without the
# share-e2e- prefix, so no existing tenant is reachable. Everything runs under mktemp HOMEs with a
# stub `security` first on PATH (never a real Keychain prompt) and SHARE_TEST_PORT_BASE so a
# concurrent run on the same machine does not collide. Tokens reach share through the environment
# and `api-token --cmd`, never argv or a file, and are never printed. It tests the share on PATH;
# set SHARE_BIN to test another.
set -uo pipefail

tenant="${SHARE_E2E_TENANT_HOST:?set SHARE_E2E_TENANT_HOST to an unused share-e2e* hostname}"
alias_host="${SHARE_E2E_ALIAS_HOST:?set SHARE_E2E_ALIAS_HOST to a second unused share-e2e* hostname}"
admin="${CLOUDFLARE_API_TOKEN:?set CLOUDFLARE_API_TOKEN to the admin token}"
share="${SHARE_BIN:-share}"
rule="${SHARE_E2E_ACCESS_RULE:-${SHARE_E2E_ACCESS_EMAIL:+email:$SHARE_E2E_ACCESS_EMAIL}}"
minter="${SHARE_E2E_R2_TOKEN_ADMIN:-}"
for h in "$tenant" "$alias_host"; do
  [[ ${h%%.*} == share-e2e* ]] || { echo "refused: hostname '$h' must have a first label starting with share-e2e"; exit 2; }
done
[[ ${tenant#*.} == "${alias_host#*.}" ]] || { echo "refused: $tenant and $alias_host must share one zone"; exit 2; }
for c in jq curl python3; do command -v "$c" >/dev/null || { echo "missing: $c"; exit 2; }; done
command -v "$share" >/dev/null || { echo "missing: $share on PATH (or set SHARE_BIN)"; exit 2; }
unset SHARE_CONFIG_DIR SHARE_ROOT SHARE_PROFILE XDG_CONFIG_HOME SHARE_HOSTNAME SHARE_BACKEND SHARE_R2_TOKEN SHARE_R2_DRY SHARE_R2_KEY_ID
export SHARE_CLIPBOARD=0 SHARE_TEST_PORT_BASE=$((20000 + (RANDOM % 8000)))

WORK=$(mktemp -d)
mkdir -p "$WORK/bin" "$WORK/kc"
# A file-backed stand-in for the Keychain (docs/verification/access.md's recipe): a real tunnel
# setup here needs a real round trip (store the tunnel token, read it back to start cloudflared),
# and the real Keychain pops a GUI ACL prompt on a first add-generic-password from a script with
# no one to click it. `security -i` batch-adds, `find-generic-password -w` reads, `delete-*` drops.
cat >"$WORK/bin/security" <<'PY'
#!/usr/bin/env python3
import sys, os, re
store = os.environ["SHARE_E2E_KC_STORE"]
def path(key): return os.path.join(store, re.sub(r"[^A-Za-z0-9_.-]", "_", key))
args = sys.argv[1:]
if args[:1] == ["-i"]:
    line = sys.stdin.readline()
    m_s = re.search(r'-s\s+"([^"]*)"', line); m_w = re.search(r'-w\s+"([^"]*)"', line)
    if m_s and m_w:
        with open(path(m_s.group(1)), "w") as f: f.write(m_w.group(1))
    sys.exit(0)
elif args[:1] == ["find-generic-password"]:
    key = args[args.index("-s") + 1] if "-s" in args else ""
    p = path(key)
    if os.path.isfile(p):
        with open(p) as f: sys.stdout.write(f.read())
        sys.exit(0)
    sys.exit(44)
elif args[:1] == ["delete-generic-password"]:
    key = args[args.index("-s") + 1] if "-s" in args else ""
    p = path(key)
    if os.path.isfile(p): os.remove(p); sys.exit(0)
    sys.exit(44)
sys.exit(44)
PY
chmod +x "$WORK/bin/security"
export PATH="$WORK/bin:$PATH" SHARE_E2E_KC_STORE="$WORK/kc"

RUNLOG="$WORK/run.log"
VERIF_DIR="$(cd "$(dirname "$0")/.." && pwd)/docs/verification"
mkdir -p "$VERIF_DIR"
RUNLOG_KEEP="$VERIF_DIR/e2e-tenant-$(date -u +%Y%m%dT%H%M%SZ).log"
exec > >(tee "$RUNLOG") 2>&1

fails=0 total=0
check() { # check <label> <expected> <actual>
  total=$((total + 1))
  if [[ $2 == "$3" ]]; then echo "  ok    $1"; else echo "  FAIL  $1: expected '$2', got '$3'"; fails=$((fails + 1)); fi
}
note() { echo "  | $1"; }
fetch() { curl -s --max-time 10 --doh-url https://1.1.1.1/dns-query "$@"; }
code() { fetch -o /dev/null -w '%{http_code}' --path-as-is "$1"; }
hdr() { fetch -D - -o /dev/null --path-as-is "$1"; }
apit() { local t=$1 p=$2; shift 2; curl -s "https://api.cloudflare.com/client/v4$p" -H @<(printf 'Authorization: Bearer %s\n' "$t") "$@"; }
api() { apit "$admin" "$@"; }
indent() { sed 's/^/  | /'; }
as() { local h=$1; shift; env -u CLOUDFLARE_API_TOKEN HOME="$h" "$share" "$@"; }
pubtoken_as() { local h=$1 t=$2; shift 2; env -u CLOUDFLARE_API_TOKEN HOME="$h" CLOUDFLARE_API_TOKEN="$t" "$share" "$@"; }
admin_as() { local h=$1; shift; HOME="$h" CLOUDFLARE_API_TOKEN="$admin" "$share" "$@"; }

zone_json="$(api "/zones?name=${tenant#*.}&status=active")"
zone="$(jq -r '.result[0].id // empty' <<<"$zone_json")"
acct="$(jq -r '.result[0].account.id // empty' <<<"$zone_json")"
[[ -n $zone && -n $acct ]] || { echo "refused: the admin token sees no active zone ${tenant#*.}"; exit 2; }
pair="$(awk -F= '/^WORKER_VERSION=/ {split($2, a, " "); v = a[1]} /^WORKER_SHA=/ {split($2, a, " "); s = a[1]} END {print v " " s}' "$(command -v "$share")")"

# --- token minting (tests/e2e-r2.sh model: a 2h token per bucket, revoked on exit) ---
minted=""
mint() { # mint <name> <bucket> <account-scope group ids, JSON array>: mint_val holds the value, never printed
  local body out exp bucket=$2
  exp="$(date -u -v+2H +%FT%TZ 2>/dev/null || date -u -d '+2 hours' +%FT%TZ)"
  body="$(jq -nc --arg n "$1" --arg exp "$exp" --argjson g "$3" \
    --arg b "com.cloudflare.edge.r2.bucket.${acct}_default_$bucket" --arg z "com.cloudflare.api.account.zone.$zone" --arg a "com.cloudflare.api.account.$acct" \
    '{name: $n, expires_on: $exp, policies: [
       {effect: "allow", permission_groups: [{id: "2efd5506f9c8494dacb1fa10a3e7d5b6"}], resources: {($b): "*"}},
       {effect: "allow", permission_groups: [{id: "c8fed203ed3043cba015a93ad1616f1f"}], resources: {($z): "*"}},
       {effect: "allow", permission_groups: ($g | map({id: .})), resources: {($a): "*"}}]}')"
  out="$(apit "$minter" /user/tokens -X POST -H 'Content-Type: application/json' --data "$body")"
  mint_id="$(jq -r '.result.id // empty' <<<"$out")"; mint_val="$(jq -r '.result.value // empty' <<<"$out")"
  [[ -n $mint_id && -n $mint_val ]] || { echo "  mint $1 failed: $(jq -c '.errors' <<<"$out")"; out=""; return 1; }
  out="" minted="$minted $mint_id"
  note "minted token $1 (id ${mint_id:0:8}..., expires $exp)"
}
revoke() { local t; for t in $minted; do apit "$minter" "/user/tokens/$t" -X DELETE -o /dev/null; done; }
pub_token() { # pub_token <name> <bucket>: PUBTOK holds the value
  if [[ -n $minter ]]; then
    mint "$1" "$2" '["b89a480218d04ceb98b4fe57ca29dc1f", "1e13c5124ca64b72b1969a67e8829049", "26bc23f853634eb4bff59983b9064fde"]' && PUBTOK="$mint_val"
  else
    PUBTOK="${SHARE_E2E_R2_PUBLISHER_TOKEN:?set SHARE_E2E_R2_TOKEN_ADMIN, or SHARE_E2E_R2_PUBLISHER_TOKEN already scoped to this bucket}"
  fi
  mint_val=""
}

# --- leftover tracking: every name this run mints, swept on exit regardless of where it stopped ---
HOSTS=() WORKERS=() BUCKETS=()
track_host() { HOSTS+=("$1"); WORKERS+=("share-${1//./-}"); }

leftovers() { # proof through the API that nothing named for this run remains; prints each leftover
  local h w b id ids
  for b in "${BUCKETS[@]}"; do
    ids="$(apit "$admin" "/accounts/$acct/r2/buckets/$b" -o /dev/null -w '%{http_code}')"
    if [[ $ids == 200 ]]; then
      # a bucket still exists: drain it key by key through the S3 listing, then delete it
      local kid sec; kid="$(api /user/tokens/verify | jq -r '.result.id // empty')"; sec="$(printf '%s' "$admin" | shasum -a 256 | cut -d' ' -f1)"
      local xml; xml="$(mktemp)"
      curl -s -o "$xml" "https://$acct.r2.cloudflarestorage.com/$b?list-type=2&encoding-type=url" --aws-sigv4 'aws:amz:auto:s3' -K <(printf 'user = "%s:%s"\n' "$kid" "$sec")
      grep -o '<Key>[^<]*</Key>' "$xml" 2>/dev/null | sed 's:</*Key>::g' | while IFS= read -r k; do
        k="$(python3 -c 'import sys,urllib.parse;print(urllib.parse.unquote(sys.argv[1]))' "$k")"
        curl -s -o /dev/null -X DELETE "https://$acct.r2.cloudflarestorage.com/$b/$k" --aws-sigv4 'aws:amz:auto:s3' -K <(printf 'user = "%s:%s"\n' "$kid" "$sec")
      done
      rm -f "$xml"
      api "/accounts/$acct/r2/buckets/$b" -X DELETE -o /dev/null
    fi
  done
  for h in "${HOSTS[@]}"; do
    w="share-${h//./-}"
    ids="$(api "/accounts/$acct/workers/domains?hostname=$h" | jq -r --arg h "$h" --arg w "$w" '.result[]? | select(.hostname == $h) | .id')"
    for id in $ids; do api "/accounts/$acct/workers/domains/$id" -X DELETE -o /dev/null; done
    ids="$(api "/zones/$zone/workers/routes" | jq -r --arg p "$h/*" '.result[]? | select(.pattern == $p) | .id')"
    for id in $ids; do api "/zones/$zone/workers/routes/$id" -X DELETE -o /dev/null; done
    api "/accounts/$acct/workers/scripts/$w" -X DELETE -o /dev/null
    ids="$(api "/accounts/$acct/access/apps?per_page=100" | jq -r --arg h "$h" '.result[]? | (.name | split(" ")) as $p
      | select(($p | length) >= 4 and $p[0] == "share" and $p[2] == $h) | .id')"
    for id in $ids; do api "/accounts/$acct/access/apps/$id" -X DELETE -o /dev/null; done
    ids="$(api "/zones/$zone/dns_records?name=$h" | jq -r '.result[]?.id')"
    for id in $ids; do api "/zones/$zone/dns_records/$id" -X DELETE -o /dev/null; done
  done
  # throwaway tunnels named for this run (tunnel names derive from the hostname's first label)
  local tun tid
  for h in "${HOSTS[@]}"; do
    tun="share-${h%%.*}"
    ids="$(api "/accounts/$acct/cfd_tunnel?name=$tun&is_deleted=false" | jq -r '.result[]?.id')"
    for tid in $ids; do
      api "/accounts/$acct/cfd_tunnel/$tid/connections" -X DELETE -o /dev/null
      api "/accounts/$acct/cfd_tunnel/$tid" -X DELETE -o /dev/null
    done
  done
  revoke
  local leftover=0
  for b in "${BUCKETS[@]}"; do
    local c; c="$(apit "$admin" "/accounts/$acct/r2/buckets/$b" -o /dev/null -w '%{http_code}')"
    [[ $c == 404 ]] || { echo "LEFTOVER: bucket $b ($c)"; leftover=1; }
  done
  for h in "${HOSTS[@]}"; do
    w="share-${h//./-}"
    local c; c="$(api "/accounts/$acct/workers/scripts/$w/settings" -o /dev/null -w '%{http_code}')"
    [[ $c == 404 ]] || { echo "LEFTOVER: Worker $w ($c)"; leftover=1; }
    c="$(api "/accounts/$acct/workers/domains?hostname=$h" | jq '.result | length')"
    [[ $c == 0 ]] || { echo "LEFTOVER: $c custom domain(s) for $h"; leftover=1; }
    c="$(api "/zones/$zone/workers/routes" | jq --arg p "$h/*" '[.result[]? | select(.pattern == $p)] | length')"
    [[ $c == 0 ]] || { echo "LEFTOVER: $c route(s) for $h/*"; leftover=1; }
    c="$(api "/zones/$zone/dns_records?name=$h" | jq '.result | length')"
    [[ $c == 0 ]] || { echo "LEFTOVER: $c DNS record(s) for $h"; leftover=1; }
    c="$(api "/accounts/$acct/access/apps?per_page=100" | jq --arg h "$h" '[.result[]? | select((.name | split(" ")) [2]? == $h)] | length')"
    [[ $c == 0 ]] || { echo "LEFTOVER: $c Access app(s) for $h"; leftover=1; }
  done
  for id in $minted; do
    local c; c="$(apit "$minter" "/user/tokens/$id" -o /dev/null -w '%{http_code}')"
    [[ $c == 404 ]] || { echo "LEFTOVER: token ${id:0:8}... ($c)"; leftover=1; }
  done
  [[ $leftover == 0 ]] && echo "cleanup: nothing left for this run's names"
  return 0
}
PIDS=()
cleanup() {
  local p; for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done
  leftovers
  cp "$RUNLOG" "$RUNLOG_KEEP" 2>/dev/null || true
  echo "run log: $RUNLOG_KEEP"
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "=== before: nothing named for this run exists ==="
check "no Worker for $tenant" 404 "$(api "/accounts/$acct/workers/scripts/share-${tenant//./-}/settings" -o /dev/null -w '%{http_code}')"
check "no Worker for $alias_host" 404 "$(api "/accounts/$acct/workers/scripts/share-${alias_host//./-}/settings" -o /dev/null -w '%{http_code}')"
check "no DNS record for $tenant" 0 "$(api "/zones/$zone/dns_records?name=$tenant" | jq '.result | length')"
check "no DNS record for $alias_host" 0 "$(api "/zones/$zone/dns_records?name=$alias_host" | jq '.result | length')"
[[ $fails == 0 ]] || { echo "refused: the run's names are in use"; trap - EXIT; cp "$RUNLOG" "$RUNLOG_KEEP" 2>/dev/null; rm -rf "$WORK"; exit 2; }

# a tiny stdlib HTTP+WebSocket echo server for the live-share legs (L1, L3): no new dependency,
# POST echoes its body, a single WS text frame is echoed back unmasked
cat >"$WORK/echo.py" <<'PY'
import socket, threading, hashlib, base64, sys
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
def handle(conn):
    try:
        data = conn.recv(65536)
        if not data: return
        head, _, body = data.partition(b"\r\n\r\n")
        lines = head.split(b"\r\n")
        method, _path, _ = lines[0].split(b" ")
        headers = {}
        for l in lines[1:]:
            if b":" in l:
                k, v = l.split(b":", 1); headers[k.strip().lower()] = v.strip()
        if headers.get(b"upgrade", b"").lower() == b"websocket":
            key = headers[b"sec-websocket-key"]
            accept = base64.b64encode(hashlib.sha1(key + GUID.encode()).digest())
            conn.sendall(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                         b"Sec-WebSocket-Accept: " + accept + b"\r\n\r\n")
            frame = conn.recv(65536)
            if frame and len(frame) >= 2:
                b2 = frame[1]; masked = b2 & 0x80; length = b2 & 0x7f; idx = 2
                if length == 126: length = int.from_bytes(frame[2:4], "big"); idx = 4
                mask = frame[idx:idx + 4] if masked else b""; idx += 4 if masked else 0
                payload = bytearray(frame[idx:idx + length])
                if masked:
                    for i in range(len(payload)): payload[i] ^= mask[i % 4]
                conn.sendall(bytes([0x81, len(payload)]) + bytes(payload))
            return
        resp = method + b" " + body
        conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: " + str(len(resp)).encode() + b"\r\n\r\n" + resp)
    except Exception:
        pass
    finally:
        conn.close()
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(50)
while True:
    c, _ = s.accept()
    threading.Thread(target=handle, args=(c,), daemon=True).start()
PY
cat >"$WORK/wsclient.py" <<'PY'
import socket, ssl, base64, os, sys
host, path, msg = sys.argv[1], sys.argv[2], sys.argv[3]
key = base64.b64encode(os.urandom(16)).decode()
ctx = ssl.create_default_context()
raw = socket.create_connection((host, 443), timeout=15)
s = ctx.wrap_socket(raw, server_hostname=host)
req = ("GET %s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
       "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n") % (path, host, key)
s.sendall(req.encode())
resp = s.recv(4096)
if b"101" not in resp.split(b"\r\n", 1)[0]:
    print("HANDSHAKE-FAILED " + resp.split(b"\r\n", 1)[0].decode(errors="replace")); sys.exit(1)
payload = msg.encode(); mask = os.urandom(4)
masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
frame = bytes([0x81, 0x80 | len(payload)]) + mask + masked
s.sendall(frame)
frame = s.recv(4096)
b2 = frame[1]; length = b2 & 0x7f; idx = 2
print(frame[idx:idx + length].decode(errors="replace"))
PY
serve_echo() { python3 "$WORK/echo.py" "$1" & PIDS+=("$!"); local n=0; until curl -s -o /dev/null "http://127.0.0.1:$1/" || [[ $n -ge 50 ]]; do sleep 0.1; n=$((n + 1)); done; }

APORT=8797 ADEVPORT=8991
A="$WORK/a"; mkdir -p "$A"
track_host "$tenant"
worker="share-${tenant//./-}"

echo "=== L1 origin A: tunnel setup; a local file, a gated local file, a live server ==="
export SHARE_PORT=$APORT
out="$(HOME="$A" CLOUDFLARE_API_TOKEN="$admin" "$share" setup "$tenant" 2>&1)"; rc=$?
indent <<<"$out"
check "A setup exits 0" 0 "$rc"
mkdir -p "$WORK/doc" "$WORK/gated"
echo "e2e tenant doc" >"$WORK/doc/index.html"
echo SECRET=x >"$WORK/doc/.env"
echo "gated tenant doc" >"$WORK/gated/index.html"
mlink="$(as "$A" add "$WORK/doc" 2>/dev/null | head -1)"; mid="$(cut -d/ -f4 <<<"$mlink")"
check "machine link answers" "e2e tenant doc" "$(fetch "$mlink")"
check "dotfile not served" 404 "$(code "${mlink}.env")"
serve_echo "$ADEVPORT"
llink="$(as "$A" add "$ADEVPORT" 2>/dev/null | head -1)"; lid="$(cut -d/ -f4 <<<"$llink")"
check "live link answers (plain HTTP through the tunnel)" "GET " "$(fetch "$llink")"
if [[ -n $rule ]]; then
  rm -f "$WORK/gate.seen" "$WORK/gate.done"
  ( gid=""
    while [[ -z $gid && ! -f $WORK/gate.done ]]; do gid="$(cut -f1 "$A/share/access-pending" 2>/dev/null | head -1)"; sleep 0.2; done
    while [[ ! -f $WORK/gate.done ]]; do c="$(code "https://$tenant/$gid/gated/")"; [[ $c == 200 ]] && echo "$c" >>"$WORK/gate.seen"; sleep 1; done ) &
  watch_pid=$!
  glink="$(as "$A" add "$WORK/gated" --access "$rule" 2>"$WORK/gate.err" | head -1)"
  touch "$WORK/gate.done"; wait "$watch_pid" 2>/dev/null
  indent <"$WORK/gate.err"
  gid="$(cut -d/ -f4 <<<"$glink")"
  check "gated add printed a link" "0 https://$tenant/$gid/gated/" "0 $glink"
  check "no 200 on the gated link during the wait" 0 "$(wc -l <"$WORK/gate.seen" 2>/dev/null | tr -d ' ')"
  gaud="$(api "/accounts/$acct/access/apps?per_page=100" | jq -r --arg s "share $gid $tenant " '[.result[]? | select(.name | startswith($s))] | first | .aud // empty')"
  out="$(fetch -o /dev/null -w '%{http_code} %{redirect_url}' --path-as-is "https://$tenant/$gid/gated/")"
  check "gated local link 302s to Access with kid == aud" 1 "$([[ $out == 302* && $out == *"kid=$gaud"* ]] && echo 1 || echo "0 ($out)")"
else
  echo "=== L1 gated leg: SKIP (no SHARE_E2E_ACCESS_EMAIL) ==="
fi

echo "=== L2 setup --r2 on A ==="
bucket="share-e2e-$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
BUCKETS+=("$bucket")
out="$(admin_as "$A" setup "$tenant" --r2 --bucket "$bucket" 2>&1)"; rc=$?
indent <<<"$out"
check "setup --r2 exits 0" 0 "$rc"
hz="$(fetch -D - -o "$WORK/hz" "https://$tenant/healthz" | awk 'tolower($1) == "x-share-tunnel:" {sub(/\r$/, ""); print $2}')"
check "/healthz carries X-Share-Tunnel: 1" 1 "$hz"
check "/healthz carries this CLI's pair" "$pair" "$(hdr "https://$tenant/healthz" | awk 'tolower($1) == "x-share-worker:" {sub(/\r$/, ""); print $2 " " $3}')"
for id in "$mid" "$lid"; do
  out="$(admin_as "$A" r2-call GET "m/$id")"
  check "pointer m/$id exists after setup --r2" 1 "$(grep -c '^code=200' <<<"$out")"
done
sub="$(api "/accounts/$acct/workers/subdomain" | jq -r '.result.subdomain // empty')"
check "workers.dev does not answer 200" 1 "$(c=$(code "https://$worker.$sub.workers.dev/healthz"); [[ $c != 200 ]] && echo 1 || echo "0 ($c)")"

echo "=== L3 through the Worker ==="
check "machine link unchanged through the Worker" "e2e tenant doc" "$(fetch "$mlink")"
if [[ -n ${gid:-} ]]; then
  out="$(fetch -o /dev/null -w '%{http_code} %{redirect_url}' --path-as-is "https://$tenant/$gid/gated/")"
  check "gated link still 302s unauthenticated" 1 "$([[ $out == 302* ]] && echo 1 || echo "0 ($out)")"
  echo "  | service-token fetch (SPEC-007 TASK-1(l)) not exercised: no SHARE_E2E_ACCESS_SERVICE_TOKEN_ID/SECRET input"
fi
check "live link answers a POST" "POST hello" "$(curl -s --doh-url https://1.1.1.1/dns-query -X POST -d hello "$llink")"
wsout="$(python3 "$WORK/wsclient.py" "$tenant" "/$lid/ws" "ping" 2>&1)"
check "live link answers a WebSocket echo" "ping" "$wsout"

echo "=== L4 A add --cloud; member B joins and adds ==="
echo "a cloud doc" >"$WORK/acloud.txt"
clink="$(as "$A" add "$WORK/acloud.txt" --cloud 2>/dev/null | head -1)"; cid="$(cut -d/ -f4 <<<"$clink")"
check "A's cloud link answers" "a cloud doc" "$(fetch "$clink")"
check "A's cloud link carries no-store" 1 "$(hdr "$clink" | grep -ci '^cache-control: no-store')"
B="$WORK/b"; mkdir -p "$B"
pub_token b-member "$bucket"; BTOK="$PUBTOK"
out="$(pubtoken_as "$B" "$BTOK" setup "$tenant" --backend r2 --bucket "$bucket" 2>&1)"; rc=$?
indent <<<"$out"
check "B join exits 0" 0 "$rc"
check "B join says joining as publisher" 1 "$(grep -c '^joining as publisher' <<<"$out")"
# shellcheck disable=SC2016 # share evals the command later; the variable must stay literal here
env -u CLOUDFLARE_API_TOKEN HOME="$B" BTOK_VALUE="$BTOK" "$share" api-token --cmd 'printf %s "$BTOK_VALUE"' >/dev/null 2>&1
echo "from b" >"$WORK/b.txt"
blink="$(as "$B" add "$WORK/b.txt" 2>/dev/null | head -1)"; bid="$(cut -d/ -f4 <<<"$blink")"
check "B's cloud link answers" "from b" "$(fetch "$blink")"
out_a="$(as "$A" ls 2>/dev/null)"; out_b="$(as "$B" ls 2>/dev/null)"
note "A ls: $(wc -l <<<"$out_a" | tr -d ' ') line(s); B ls: $(wc -l <<<"$out_b" | tr -d ' ') line(s)"
check "A's ls shows B's cloud row (TASK-6 merged list)" 1 "$(grep -c "id=$bid" <<<"$out_a")"
check "B's ls shows A's rows (TASK-6 merged list)" 3 "$(grep -c -e "id=$mid" -e "id=$lid" -e "id=$cid" <<<"$out_b")"

echo "=== L5 stop A's tunnel ==="
as "$A" stop >/dev/null
check "cloud link still answers while the tunnel is down" 200 "$(code "$clink")"
check "machine link answers the 503 offline page" 503 "$(code "$mlink")"
check "live link answers the 503 offline page" 503 "$(code "$llink")"
hz2="$(hdr "https://$tenant/healthz" | awk 'tolower($1) == "x-share-tunnel:" {sub(/\r$/, ""); print $2}')"
check "/healthz answers X-Share-Tunnel: 0 with the tunnel down" 0 "$hz2"
D="$WORK/d"; mkdir -p "$D"
pub_token d-fresh "$bucket"; DTOK="$PUBTOK"
out="$(pubtoken_as "$D" "$DTOK" setup "$tenant" --backend r2 --bucket "$bucket" 2>&1)"; rc=$?
indent <<<"$out"
check "fresh member D joins during the outage" 0 "$rc"
# shellcheck disable=SC2016 # share evals the command later; the variable must stay literal here
env -u CLOUDFLARE_API_TOKEN HOME="$D" DTOK_VALUE="$DTOK" "$share" api-token --cmd 'printf %s "$DTOK_VALUE"' >/dev/null 2>&1
dgid=""
if [[ -n $rule ]]; then
  mkdir -p "$WORK/dgated" && echo "d gated" >"$WORK/dgated/index.html"
  dglink="$(as "$D" add "$WORK/dgated" --access "$rule" 2>"$WORK/dgate.err" | head -1)"; drc=$?
  indent <"$WORK/dgate.err"
  dgid="$(cut -d/ -f4 <<<"$dglink")"
  check "D's gated cloud add succeeds during the outage" 0 "$drc"
fi
bstate="$(as "$B" state 2>/dev/null)"
check "B's state reads ready: true during the outage" true "$(jq -r '.ready' <<<"$bstate" 2>/dev/null)"
as "$A" start >/dev/null
n=0; until [[ $(code "$mlink") == 200 || $n -ge 30 ]]; do sleep 2; n=$((n + 1)); done
check "machine link back after start" 200 "$(code "$mlink")"
check "live link back after start" "GET " "$(fetch "$llink")"

echo "=== L6 encoded paths (a machine id and a cloud id) ==="
for id in "$mid" "$cid"; do
  for p in "/x/..%2F$id/doc/" "/%2F$id/doc/" "//$id/doc/"; do
    check "$p answers 400" 400 "$(code "https://$tenant$p")"
  done
done

echo "=== L7 --no-r2 ==="
out="$(admin_as "$A" setup "$tenant" --no-r2 2>&1)"; rc=$?
indent <<<"$out"
check "--no-r2 exits 0" 0 "$rc"
check "the route is gone" 0 "$(api "/zones/$zone/workers/routes" | jq --arg p "$tenant/*" '[.result[]? | select(.pattern == $p)] | length')"
check "machine link serves straight from the tunnel (no X-Share-Worker)" 0 "$(hdr "$mlink" | grep -ci '^x-share-worker:')"
check "cloud link 404s at Caddy (no route left to the Worker)" 404 "$(code "$clink")"

echo "=== L8 setup --r2 again ==="
etag_before="$(admin_as "$A" r2-call GET "m/$mid" | awk -F= '/^code=/ {split($0,a," "); print a[2]}')"
out="$(admin_as "$A" setup "$tenant" --r2 --bucket "$bucket" 2>&1)"; rc=$?
indent <<<"$out"
check "rerun --r2 exits 0" 0 "$rc"
etag_after="$(admin_as "$A" r2-call GET "m/$mid" | awk -F= '/^code=/ {split($0,a," "); print a[2]}')"
check "no new pointer PUT for an existing id (etag unchanged)" "$etag_before" "$etag_after"
check "cloud link answers again" "a cloud doc" "$(fetch "$clink")"

echo "=== L9 B's local teardown; A rm of each link ==="
as "$B" teardown --yes >/dev/null 2>&1
check "B's config is gone" 1 "$([[ ! -f $B/.config/share/config ]] && echo 1 || echo 0)"
check "the bucket is unaffected by B's local teardown" 200 "$(code "$blink")"
for id in "$mid" "$lid" "${gid:-}" "$cid" "$bid" "${dgid:-}"; do
  [[ -n $id ]] || continue
  admin_as "$A" rm "$id" >/dev/null 2>&1
done
check "A's ls is empty" "no shares" "$(as "$A" ls 2>&1)"
check "machine link gone" 1 "$(c=$(code "$mlink"); [[ $c != 200 ]] && echo 1 || echo "0 ($c)")"
check "cloud link gone" 1 "$(c=$(code "$clink"); [[ $c != 200 ]] && echo 1 || echo "0 ($c)")"
if [[ -n ${gid:-} ]]; then
  check "gated app gone" 0 "$(api "/accounts/$acct/access/apps?per_page=100" | jq --arg s "share $gid " '[.result[]? | select(.name | startswith($s))] | length')"
fi

echo "=== L10 admin purge and A teardown ==="
admin_as "$A" r2-delete-prefix "" >/dev/null 2>&1
api "/accounts/$acct/r2/buckets/$bucket" -X DELETE -o /dev/null
api "/accounts/$acct/workers/scripts/$worker" -X DELETE -o /dev/null
out="$(admin_as "$A" teardown --yes 2>&1)"; rc=$?
indent <<<"$out"
check "A teardown exits 0" 0 "$rc"
check "tunnel DNS gone" 0 "$(api "/zones/$zone/dns_records?name=$tenant" | jq '.result | length')"
check "bucket gone" 404 "$(api "/accounts/$acct/r2/buckets/$bucket" -o /dev/null -w '%{http_code}')"
check "Worker gone" 404 "$(api "/accounts/$acct/workers/scripts/$worker/settings" -o /dev/null -w '%{http_code}')"

echo
echo "=== R1 Dwarves alias-fold rehearsal on throwaway names ==="
track_host "$alias_host"
C="$WORK/c"; mkdir -p "$C"
bucket2="share-e2e-$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
BUCKETS+=("$bucket2")
out="$(HOME="$C" CLOUDFLARE_API_TOKEN="$admin" "$share" setup "$alias_host" --backend r2 --bucket "$bucket2" 2>&1)"; rc=$?
indent <<<"$out"
check "R1: C's standalone r2 origin on the alias exits 0" 0 "$rc"
pub_token c-admin "$bucket2"; CTOK="$PUBTOK"
# shellcheck disable=SC2016 # share evals the command later; the variable must stay literal here
env -u CLOUDFLARE_API_TOKEN HOME="$C" CTOK_VALUE="$CTOK" "$share" api-token --cmd 'printf %s "$CTOK_VALUE"' >/dev/null 2>&1
mkdir -p "$WORK/calias" && echo "alias gated" >"$WORK/calias/index.html"
if [[ -n $rule ]]; then
  cglink="$(as "$C" add "$WORK/calias" --access "$rule" 2>"$WORK/cgate.err" | head -1)"
  indent <"$WORK/cgate.err"
  cgid="$(cut -d/ -f4 <<<"$cglink")"
  check "R1: C's gated cloud link printed" "https://$alias_host/$cgid/calias/" "$cglink"
else
  echo "R1 gated leg: SKIP (no SHARE_E2E_ACCESS_EMAIL)"; cgid=""
fi

A2="$WORK/a2"; mkdir -p "$A2"; export SHARE_PORT=$((APORT + 1))
out="$(HOME="$A2" CLOUDFLARE_API_TOKEN="$admin" "$share" setup "$tenant" 2>&1)"; rc=$?
indent <<<"$out"
check "R1: A2's plain tunnel on the tenant exits 0" 0 "$rc"

out="$(HOME="$A2" CLOUDFLARE_API_TOKEN="$admin" "$share" setup "$tenant" --r2 --bucket "$bucket2" --alias "$alias_host" 2>&1)"; rc=$?
indent <<<"$out"
check "R1: the fold (setup --r2 --alias) exits 0" 0 "$rc"
aliasout="$(fetch -o /dev/null -w '%{http_code} %{redirect_url}' "https://$alias_host/healthz")"
check "R1 after fold: alias 301s to the tenant" 1 "$([[ $aliasout == 301* && $aliasout == *"https://$tenant"* ]] && echo 1 || echo "0 ($aliasout)")"
if [[ -n ${cgid:-} ]]; then
  gaud2="$(api "/accounts/$acct/access/apps?per_page=100" | jq -r --arg s "share $cgid $tenant " '[.result[]? | select(.name | startswith($s))] | first | .aud // empty')"
  out="$(fetch -o /dev/null -w '%{http_code} %{redirect_url}' --path-as-is "https://$tenant/$cgid/calias/")"
  check "R1 after fold: the folded gated link 302s on the tenant with kid == aud" 1 "$([[ $out == 302* && -n $gaud2 && $out == *"kid=$gaud2"* ]] && echo 1 || echo "0 ($out, aud=$gaud2)")"
fi

echo "--- R1 rollback (### Dwarves order, the admin token) ---"
r2call_admin() { HOME="$A2" CLOUDFLARE_API_TOKEN="$admin" SHARE_R2_TOKEN="$admin" "$share" r2-call "$@"; }
if [[ -n ${cgid:-} ]]; then
  appjson="$(api "/accounts/$acct/access/apps?per_page=100" | jq -c --arg s "share $cgid $tenant " '[.result[]? | select(.name | startswith($s))] | first')"
  appid="$(jq -r '.id' <<<"$appjson")"
  full="$(api "/accounts/$acct/access/apps/$appid")"
  dests="$(jq -c --arg h "$alias_host" --arg i "$cgid" '.result.self_hosted_domains + [$h + "/" + $i, $h + "/" + $i + "/*"]' <<<"$full")"
  body="$(jq -c --argjson d "$dests" '.result | .self_hosted_domains = $d | {name, self_hosted_domains: .self_hosted_domains, session_duration, type}' <<<"$full")"
  api "/accounts/$acct/access/apps/$appid" -X PUT -H 'Content-Type: application/json' --data "$body" >/dev/null
  echo "  1. restored $alias_host destinations on app $appid"
fi
api "/accounts/$acct/workers/domains" -X PUT -H 'Content-Type: application/json' \
  --data "{\"hostname\":\"$alias_host\",\"service\":\"share-${alias_host//./-}\",\"zone_id\":\"$zone\",\"environment\":\"production\",\"override_existing_origin\":true}" >/dev/null
echo "  2. rebound $alias_host to share-${alias_host//./-}"
marker_etag="$(r2call_admin GET share.json | awk -F= '/^etag=/ {print $2}')"
printf '{"v":1,"host":"%s"}\n' "$alias_host" >"$WORK/marker.json"
HOME="$A2" CLOUDFLARE_API_TOKEN="$admin" SHARE_R2_TOKEN="$admin" "$share" r2-call PUT share.json "$WORK/marker.json" -H "If-Match: \"$marker_etag\"" >/dev/null
echo "  3. restored share.json host to $alias_host in bucket $bucket2"
ptrs="$(admin_as "$A2" r2-list "m/" 2>/dev/null)"
grep -o '^m/[0-9a-f]\{6\}' <<<"$ptrs" | cut -d/ -f2 | while IFS= read -r pid; do r2call_admin DELETE "m/$pid" >/dev/null; done
echo "  4. deleted every v:2 machine record"
out="$(admin_as "$A2" setup "$tenant" --no-r2 2>&1)"; rc=$?
indent <<<"$out"
echo "  5. $share setup $tenant --no-r2 exited $rc"
check "R1 rollback: the alias serves itself again" 200 "$(code "https://$alias_host/")"
check "R1 rollback: the tenant is a plain tunnel (no route)" 0 "$(api "/zones/$zone/workers/routes" | jq --arg p "$tenant/*" '[.result[]? | select(.pattern == $p)] | length')"

echo "--- R1 the fold again ---"
out="$(admin_as "$A2" setup "$tenant" --r2 --bucket "$bucket2" --alias "$alias_host" 2>&1)"; rc=$?
indent <<<"$out"
check "R1: the second fold exits 0" 0 "$rc"
aliasout2="$(fetch -o /dev/null -w '%{http_code} %{redirect_url}' "https://$alias_host/healthz")"
check "R1 after the second fold: alias 301s to the tenant again" 1 "$([[ $aliasout2 == 301* && $aliasout2 == *"https://$tenant"* ]] && echo 1 || echo "0 ($aliasout2)")"

echo
echo "=== R1 cleanup ==="
admin_as "$A2" r2-delete-prefix "" >/dev/null 2>&1
api "/accounts/$acct/r2/buckets/$bucket2" -X DELETE -o /dev/null
api "/accounts/$acct/workers/scripts/share-${alias_host//./-}" -X DELETE -o /dev/null
admin_as "$A2" setup "$tenant" --no-r2 >/dev/null 2>&1 || true
admin_as "$A2" teardown --yes >/dev/null 2>&1
check "R1: tenant tunnel DNS gone" 0 "$(api "/zones/$zone/dns_records?name=$tenant" | jq '.result | length')"
check "R1: alias bucket gone" 404 "$(api "/accounts/$acct/r2/buckets/$bucket2" -o /dev/null -w '%{http_code}')"
check "R1: alias Worker gone" 404 "$(api "/accounts/$acct/workers/scripts/share-${alias_host//./-}/settings" -o /dev/null -w '%{http_code}')"

echo
echo "$((total - fails))/$total checks passed"
if [[ $fails -gt 0 ]]; then echo "$fails FAILED"; exit 1; fi
echo PASS
