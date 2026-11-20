#!/bin/bash
# prod-snapshot: a READ-ONLY snapshot of a live tenant's Cloudflare and machine state, taken before a production step so a
# rollback is exact. It never writes: no PUT, POST, or DELETE, no handout command that changes anything. Run it on the machine
# that serves the tenant.
#
#   tests/prod-snapshot.sh <out-file> <zone> <host>...    e.g. tests/prod-snapshot.sh snap.txt example.com s.example.com
#
# <zone> is the Cloudflare zone the hosts live in. Each <host> is probed at /healthz.
#
# The admin token comes from CLOUDFLARE_API_TOKEN, else from op://Toolkit/cf-api-token/credential through 1Password Connect
# (source ~/op-connect/op-connect-env.sh first). It is never printed. The file holds account ids, Access app uuids and AUDs:
# keep it out of git. Compare two snapshots with `diff <(grep -v '^https://' a) <(grep -v '^https://' b)`.
set -uo pipefail

out="${1:?usage: prod-snapshot.sh <out-file> <zone> <host>...}"
zname="${2:?usage: prod-snapshot.sh <out-file> <zone> <host>...}"
shift 2
(( $# )) || { echo "usage: prod-snapshot.sh <out-file> <zone> <host>..." >&2; exit 2; }
hosts=("$@"); probes=()
for h in "${hosts[@]}"; do probes+=("https://$h/healthz"); done
which_tenant="$zname"
admin="${CLOUDFLARE_API_TOKEN:-}"
if [[ -z $admin ]]; then
  # shellcheck disable=SC1090
  source ~/op-connect/op-connect-env.sh
  admin="$(op read 'op://Toolkit/cf-api-token/credential')"
fi
[[ -n $admin ]] || { echo "no admin token" >&2; exit 2; }
for c in jq curl; do command -v "$c" >/dev/null || { echo "missing: $c" >&2; exit 2; }; done
api() { curl -s "https://api.cloudflare.com/client/v4$1" -H @<(printf 'Authorization: Bearer %s\n' "$admin"); }
zj="$(api "/zones?name=$zname&status=active")"
zone="$(jq -r '.result[0].id // empty' <<<"$zj")"; acct="$(jq -r '.result[0].account.id // empty' <<<"$zj")"
[[ -n $zone && -n $acct ]] || { echo "the token sees no active zone $zname" >&2; exit 2; }
hjson="$(printf '%s\n' "${hosts[@]}" | jq -R . | jq -sc .)"
{
  echo "## taken $(date -u +%FT%TZ) on $(hostname) for $which_tenant"
  echo "## dns records"
  for h in "${hosts[@]}"; do api "/zones/$zone/dns_records?name=$h" | jq -c --arg h "$h" '{host:$h, records:[.result[]? | {id,type,content,proxied}]}'; done
  echo "## worker custom domains of these hosts"
  api "/accounts/$acct/workers/domains" | jq -c --argjson hs "$hjson" '[.result[]? | select(.hostname as $x | $hs | index($x)) | {id,hostname,service,environment}]'
  echo "## worker routes on the zone"
  api "/zones/$zone/workers/routes" | jq -c '[.result[]? | {id,pattern,script}]'
  echo "## worker scripts share-*"
  api "/accounts/$acct/workers/scripts" | jq -r '.result[]?.id' | grep '^share-' | sort
  echo "## access apps named share"
  api "/accounts/$acct/access/apps?per_page=100" | jq -c '[.result[]? | select(.name | startswith("share ")) | {id,name,aud,type,session_duration,destinations:[.destinations[]?|.uri], self_hosted_domains}]'
  echo "## tunnels share-* and air-share (not deleted)"
  api "/accounts/$acct/cfd_tunnel?is_deleted=false&per_page=100" | jq -c '[.result[]? | select(.name | test("^(share-|air-share)")) | {id,name,status}]'
  echo "## r2 buckets share-*"
  api "/accounts/$acct/r2/buckets?per_page=100" | jq -c '[.result.buckets[]? | select(.name | startswith("share-")) | {name}]'
  echo "## launchd jobs matching share (this machine)"
  launchctl list | awk '{print $3}' | grep -i share | grep -v apple | sort
  echo "## share on this machine"
  brew list --versions share 2>&1
  echo "## share profiles, config (secrets redacted), index, r2-own"
  cfgdir="$HOME/.config/share"
  for c in "$cfgdir/config" "$cfgdir"/profiles/*/config; do
    [[ -f $c ]] || continue
    d="${c%/config}"; n="${d##*/}"; [[ $d == "$cfgdir" ]] && n=default
    if [[ $n == default ]]; then r="$HOME/share"; else r="$HOME/share/profiles/$n"; fi
    echo "-- profile $n config"; sed -E 's/^(token[^=]*|api_token_cmd|r2_token_cmd)=.*/\1=<redacted>/' "$c"
    echo "-- profile $n index"; cut -c1-220 "$r/index.tsv" 2>/dev/null
    echo "-- profile $n r2-own"; cut -c1-160 "$r/r2-own" 2>/dev/null
  done
  echo "## live link probes (status and redirect)"
  for u in "${probes[@]}"; do printf '%s %s\n' "$u" "$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 10 "$u" | cut -c1-140)"; done
} >|"$out" 2>&1
echo "snapshot: $out ($(wc -l <"$out") lines)"
