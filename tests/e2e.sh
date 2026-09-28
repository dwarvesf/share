#!/bin/bash
# End-to-end test against a real Cloudflare zone: setup, publish, fetch, remove, teardown,
# then prove through the API that nothing is left behind. Run it by hand before a release
# that touches setup, teardown, or serving; CI has no zone or token.
#
#   SHARE_E2E_HOST=share-e2e.example.com CLOUDFLARE_API_TOKEN=... tests/e2e.sh           # API-token setup
#   SHARE_E2E_HOST=share-e2e.example.com CLOUDFLARE_API_TOKEN=... tests/e2e.sh --login   # browser-login setup
#   ... SHARE_E2E_ACCESS_EMAIL=you@example.com tests/e2e.sh   # also the private-link leg (Access on the zone's account;
#                                                              # the token needs Access Apps Edit + Orgs/IdPs/Groups Read)
#   ... SHARE_E2E_OTHER_HOST=s.other.example tests/e2e.sh     # and: the gated id is a 404 on another setup's hostname
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

if [[ $mode == api && -n ${SHARE_E2E_ACCESS_EMAIL:-} ]]; then
  echo "=== private link (--access): the bytes are never public, the gate is this app's, rm leaves no app ==="
  mkdir -p "$WORK/gated" && echo "gated $mode" >"$WORK/gated/index.html"
  # the watcher learns the id from the intent line (written before the app exists) and polls the
  # public link during the whole wait: a 200 at any point means bytes went out ungated
  rm -f "$WORK/gate.seen" "$WORK/gate.done"
  ( gid=""
    while [[ -z $gid && ! -f $WORK/gate.done ]]; do gid="$(cut -f1 "$SHARE_ROOT/access-pending" 2>/dev/null | head -1)"; sleep 0.2; done
    while [[ ! -f $WORK/gate.done ]]; do
      c="$(code "https://$host/$gid/index.html")"; [[ $c == 200 ]] && echo "$c" >>"$WORK/gate.seen"
      sleep 1
    done ) &
  watch_pid=$!
  t0=$(date +%s)
  glink="$("$share" add "$WORK/gated" --access "email:$SHARE_E2E_ACCESS_EMAIL" 2>"$WORK/gate.err" | head -1)"
  touch "$WORK/gate.done"; wait "$watch_pid" 2>/dev/null
  gate_secs=$(( $(date +%s) - t0 ))
  gid="$(cut -d/ -f4 <<<"$glink")"
  gapp="$(awk -F'\t' -v id="$gid" '$1 == id' "$SHARE_ROOT/index.tsv" | sed -n 's/.*access=\([^ ]*\).*/\1/p')"
  gaud="$(api "/accounts/$account/access/apps/$gapp" | jq -r '.result.aud // empty')"
  echo "  | gated add took ${gate_secs}s from start to the printed link (app $gapp)"
  check "gated add printed a link" "https://$host/$gid/gated/" "$glink"
  check "the preflight passed every scope" 3 "$(grep -c '^  ok       \(Zone\|Access\)' "$WORK/gate.err")"
  check "no 200 on the link during the wait" 0 "$(wc -l <"$WORK/gate.seen" 2>/dev/null | tr -d ' ' || echo 0)"
  check "the app reads back with an aud" 1 "$([[ -n $gaud ]] && echo 1 || echo 0)"
  probe() { fetch -o /dev/null -w '%{http_code} %{redirect_url}' --path-as-is "$1"; }
  gid_up="$(tr '[:lower:]' '[:upper:]' <<<"$gid")"
  gid_enc="%$(printf '%02x' "'${gid:0:1}")${gid:1}"
  for p in "/$gid/" "/$gid" "/$gid_up/" "/$gid_enc/" "//$gid/" "/x/%2e%2e/$gid/"; do
    out="$(probe "https://$host$p")"
    check "$p redirects to Access with kid == aud" 1 "$([[ $out == 30* && $out == *".cloudflareaccess.com/cdn-cgi/access/login/$host"* && $out == *"kid=$gaud"* ]] && echo 1 || echo "0 ($out)")"
  done
  for p in "/x/..%2F$gid/gated/index.html" "/%2F$gid/gated/index.html" "/x/..%5C$gid/gated/index.html"; do
    check "$p answers 400" 400 "$(fetch -o /dev/null -w '%{http_code}' --path-as-is "https://$host$p")"
  done
  check "the ungated share still answers 200" 200 "$(code "$link")"
  if [[ -n ${SHARE_E2E_OTHER_HOST:-} ]]; then
    check "the gated id never answers 200 on another setup's hostname ($SHARE_E2E_OTHER_HOST)" 1 "$(c=$(code "https://$SHARE_E2E_OTHER_HOST/$gid/"); [[ $c != 200 ]] && echo 1 || echo "0 ($c)")"
  fi

  echo "--- --host plus --access: the fqdn and the main-host path both redirect ---"
  ghost="g-${host%%.*}.$zone_name"
  ghlink="$("$share" add "$WORK/gated" --host "$ghost" --access "email:$SHARE_E2E_ACCESS_EMAIL" 2>>"$WORK/gate.err" | head -1)"
  ghid="$(awk -F'\t' -v h="host=$ghost" 'index($6, h) {print $1}' "$SHARE_ROOT/index.tsv")"
  check "host gated link is the fqdn" "https://$ghost/" "$ghlink"
  for u in "https://$ghost/" "https://$host/$ghid/"; do
    out="$(probe "$u")"
    check "$u redirects to Access" 1 "$([[ $out == 30* && $out == *.cloudflareaccess.com/cdn-cgi/access/login/* ]] && echo 1 || echo "0 ($out)")"
  done
  ghapp="$(awk -F'\t' -v id="$ghid" '$1 == id' "$SHARE_ROOT/index.tsv" | sed -n 's/.*access=\([^ ]*\).*/\1/p')"
  "$share" rm "$ghlink" >/dev/null 2>&1
  check "host gated rm: no DNS record left" 0 "$(api "/zones/$zone/dns_records?name=$ghost" | jq '.result | length')"
  check "host gated rm: app gone (GET 404)" 404 "$(curl -s -o /dev/null -w '%{http_code}' "https://api.cloudflare.com/client/v4/accounts/$account/access/apps/$ghapp" -H @<(printf 'Authorization: Bearer %s\n' "$token"))"

  echo "--- rm: the app is gone and the link never answers 200 ---"
  "$share" rm "$gid" >/dev/null 2>&1
  check "rm gated exits 0" 0 "$?"
  check "GET access/apps/<app> is 404" 404 "$(curl -s -o /dev/null -w '%{http_code}' "https://api.cloudflare.com/client/v4/accounts/$account/access/apps/$gapp" -H @<(printf 'Authorization: Bearer %s\n' "$token"))"
  check "no app named for this share remains" 0 "$(api "/accounts/$account/access/apps" | jq --arg s "share $gid " '[.result[] | select(.name | startswith($s))] | length')"
  check "no app named for the host share remains" 0 "$(api "/accounts/$account/access/apps" | jq --arg s "share $ghid " '[.result[] | select(.name | startswith($s))] | length')"
  check "the link never answers 200 after rm" 1 "$(c=$(code "https://$host/$gid/gated/index.html"); [[ $c != 200 ]] && echo 1 || echo "0 ($c)")"
  check "access-pending is empty" 0 "$(awk 'NF' "$SHARE_ROOT/access-pending" 2>/dev/null | wc -l | tr -d ' ')"
fi

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
