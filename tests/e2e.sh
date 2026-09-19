#!/bin/bash
# End-to-end test against a real Cloudflare zone: setup, publish, fetch, remove, teardown,
# then prove through the API that nothing is left behind. Run it by hand before a release
# that touches setup, teardown, or serving; CI has no zone or token.
#
#   SHARE_E2E_HOST=share-e2e.example.com CLOUDFLARE_API_TOKEN=... tests/e2e.sh           # API-token setup
#   SHARE_E2E_HOST=share-e2e.example.com CLOUDFLARE_API_TOKEN=... tests/e2e.sh --login   # browser-login setup
#
# SHARE_E2E_HOST must be an unused hostname on a zone the token can edit. The token is also
# used for teardown in both modes, because the browser-login token cannot delete DNS records.
# --login opens a browser tab once: pick the zone and click Authorize.
# Everything runs under its own config, root, port, and service label, so a real share setup
# on the same machine is never touched. It tests the share on PATH; set SHARE_BIN to test another.
set -uo pipefail

host="${SHARE_E2E_HOST:?set SHARE_E2E_HOST to an unused hostname on your Cloudflare zone}"
token="${CLOUDFLARE_API_TOKEN:?set CLOUDFLARE_API_TOKEN (Tunnel Edit, DNS Edit, Zone Read)}"
mode=api; [[ ${1:-} == --login ]] && mode=login
share="${SHARE_BIN:-share}"
WORK=$(mktemp -d)
export SHARE_CONFIG_DIR="$WORK/cfg" SHARE_ROOT="$WORK/root" SHARE_PORT=8797
export SHARE_SERVICE_LABEL="foundation.d.share-e2e" SHARE_CLIPBOARD=0
trap 'CLOUDFLARE_API_TOKEN="$token" "$share" teardown --yes >/dev/null 2>&1; rm -rf "$WORK"' EXIT

fails=0
check() { # check <label> <expected> <actual>
  if [[ $2 == "$3" ]]; then echo "  ok    $1"; else echo "  FAIL  $1: expected '$2', got '$3'"; fails=$((fails + 1)); fi
}
# DNS over HTTPS, like share's own live check: the local resolver may still cache
# "no such host" from an earlier run on the same hostname.
fetch() { curl -s --max-time 10 --doh-url https://1.1.1.1/dns-query "$@"; }
code() { fetch -o /dev/null -w '%{http_code}' "$1"; }
api() { curl -s "https://api.cloudflare.com/client/v4$1" -H @<(printf 'Authorization: Bearer %s\n' "$token"); }

echo "=== setup ($mode) ==="
if [[ $mode == login ]]; then
  env -u CLOUDFLARE_API_TOKEN "$share" setup "$host" 2>&1 | sed 's/^/  | /'
else
  "$share" setup "$host" 2>&1 | sed 's/^/  | /'
fi
check "setup succeeded" 0 "${PIPESTATUS[0]}"
check "service is running" 0 "$("$share" status >/dev/null; [[ -f $SHARE_ROOT/serve.pid ]] && kill -0 "$(cat "$SHARE_ROOT/serve.pid")"; echo $?)"

echo "=== rerun setup (must reuse) ==="
out="$("$share" setup "$host" 2>&1)"
check "tunnel reused" 1 "$(grep -c 'tunnel:     reusing' <<<"$out")"

echo "=== publish ==="
mkdir -p "$WORK/doc" && echo "e2e $mode" >"$WORK/doc/index.html" && echo SECRET=x >"$WORK/doc/.env"
link="$("$share" add "$WORK/doc" | head -1)"
check "link answers" 200 "$(code "$link")"
check "content is the snapshot" "e2e $mode" "$(fetch "$link")"
check "dotfile not served" 404 "$(code "${link}.env")"
check "no-store header" 1 "$(fetch -D - -o /dev/null "$link" | grep -ci '^cache-control: no-store')"

echo "=== restart (links must answer the moment start returns) ==="
"$share" stop >/dev/null
check "links down after stop" 1 "$(c=$(code "$link"); [[ $c == 530 || $c == 502 || $c == 000 ]] && echo 1 || echo "$c")"
"$share" start >/dev/null
check "link answers right after start" 200 "$(code "$link")"
"$share" service install >/dev/null 2>&1
check "link answers right after a service reinstall" 200 "$(code "$link")"

echo "=== own hostname (--host) ==="
tunnel_id="$(awk -F= '$1 == "tunnel_id" {print $2}' "$SHARE_CONFIG_DIR/config")"
zone_json="$(api "/zones?name=${host#*.}")"
zone="$(jq -r '.result[0].id // empty' <<<"$zone_json")"
account="$(jq -r '.result[0].account.id // empty' <<<"$zone_json")"
zone_name="$(jq -r '.result[0].name // empty' <<<"$zone_json")"
hhost="x-${host%%.*}.$zone_name"   # one label under the zone, namespaced by the e2e hostname
BPORT=8998
mkdir -p "$WORK/be" && echo "e2e live $mode" >"$WORK/be/index.html"
cat >"$WORK/BeCaddyfile" <<EOF
{
	admin off
	auto_https off
}
http://127.0.0.1:$BPORT {
	bind 127.0.0.1
	root * "$WORK/be"
	file_server
}
EOF
caddy run --config "$WORK/BeCaddyfile" --adapter caddyfile >>"$WORK/be.log" 2>&1 &
be_pid=$!
n=0; until curl -s -o /dev/null "http://127.0.0.1:$BPORT/" || [[ $n -ge 50 ]]; do sleep 0.2; n=$((n + 1)); done
if [[ $mode == login ]]; then
  out="$(env -u CLOUDFLARE_API_TOKEN "$share" add "$BPORT" --host "$hhost" 2>&1)"; rc=$?
  check "host add refused under login auth" 1 "$rc"
  check "login cert message" 1 "$(grep -c 'login cert cannot edit DNS' <<<"$out")"
  check "login: no DNS record left" 0 "$(api "/zones/$zone/dns_records?name=$hhost" | jq '.result | length')"
  check "login: ingress reverted" 0 "$(api "/accounts/$account/cfd_tunnel/$tunnel_id/configurations" | jq --arg h "$hhost" '[.result.config.ingress[] | select(.hostname == $h)] | length')"
else
  hlink="$("$share" add "$BPORT" --host "$hhost" | head -1)"
  check "host link is the fqdn" "https://$hhost/" "$hlink"
  n=0; until [[ $(code "$hlink") == 200 || $n -ge 30 ]]; do sleep 2; n=$((n + 1)); done
  check "host share answers" 200 "$(code "$hlink")"
  check "host share content" "e2e live $mode" "$(fetch "$hlink")"
  "$share" rm "$hlink" >/dev/null
  check "no DNS record left" 0 "$(api "/zones/$zone/dns_records?name=$hhost" | jq '.result | length')"
  check "no ingress rule left" 0 "$(api "/accounts/$account/cfd_tunnel/$tunnel_id/configurations" | jq --arg h "$hhost" '[.result.config.ingress[] | select(.hostname == $h)] | length')"
fi
kill "$be_pid" 2>/dev/null || true

echo "=== remove ==="
"$share" rm "$link" >/dev/null
check "rm takes the link down" 404 "$(code "$link")"

echo "=== teardown ==="
CLOUDFLARE_API_TOKEN="$token" "$share" teardown --yes 2>&1 | sed 's/^/  | /'
check "DNS record removed" 0 "$(api "/zones/$zone/dns_records?name=$host" | jq '.result | length')"
check "tunnel deleted" true "$(api "/accounts/$account/cfd_tunnel/$tunnel_id" | jq '.result.deleted_at != null')"
check "service removed" 1 "$([[ -e ~/Library/LaunchAgents/$SHARE_SERVICE_LABEL.plist || -e ~/.config/systemd/user/$SHARE_SERVICE_LABEL.service ]] && echo 0 || echo 1)"

echo
if [[ $fails -gt 0 ]]; then echo "$fails FAILED"; exit 1; fi
echo "PASS ($mode)"
