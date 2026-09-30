#!/bin/bash
# Live leg of the R2 backend against a real Cloudflare account: admin setup, a publisher joining
# with a bucket-scoped token, publishing from two installs, the Worker's path and expiry rules,
# hits, a gated link, local and purging teardown, then proof through the API that nothing is left.
# Run it by hand before a release that touches the r2 backend; CI has no account or token.
#
#   SHARE_E2E_R2_HOST=share-e2e-x1.example.com CLOUDFLARE_API_TOKEN=<admin> \
#     SHARE_E2E_R2_TOKEN_ADMIN=<token with User API Tokens: Edit> tests/e2e-r2.sh
#   ... SHARE_E2E_ACCESS_RULE=group:<name> (or SHARE_E2E_ACCESS_EMAIL=you@example.com)   # also the gated leg
#
# Inputs:
#   SHARE_E2E_R2_HOST    an unused hostname whose first label starts with share-e2e, on a zone the admin token edits
#   CLOUDFLARE_API_TOKEN the admin token: Workers Scripts Edit and Workers R2 Storage Edit (account), Zone Read and
#                        DNS Read (zone), Access Organizations Read, and Access Apps Edit for the cleanup checks
#   SHARE_E2E_R2_TOKEN_ADMIN  mints the two publisher tokens (POST /user/tokens), each bucket-scoped with a 2 h expiry,
#                        and revokes them on exit. Without it, pass SHARE_E2E_R2_BUCKET plus a token already scoped
#                        to that bucket in SHARE_E2E_R2_PUBLISHER_TOKEN (both installs use it), and optionally
#                        SHARE_E2E_R2_GATED_TOKEN (the same scope plus Access Apps Edit and Access Groups Read)
#   SHARE_E2E_R2_BUCKET  default share-e2e-<6 hex>; any name without that shape is refused, so no existing bucket is reachable
#
# Every install runs under its own mktemp HOME with a stub `security` first on PATH (the real Keychain
# pops a GUI prompt from a script and must not keep a test token). Tokens reach share through the
# environment and `api-token --cmd`, never argv or a file. It tests the share on PATH; set SHARE_BIN to test another.
set -uo pipefail

host="${SHARE_E2E_R2_HOST:?set SHARE_E2E_R2_HOST to an unused share-e2e* hostname on your Cloudflare zone}"
admin="${CLOUDFLARE_API_TOKEN:?set CLOUDFLARE_API_TOKEN to the admin token}"
share="${SHARE_BIN:-share}"
bucket="${SHARE_E2E_R2_BUCKET:-share-e2e-$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')}"
[[ $bucket =~ ^share-e2e-[0-9a-f]{6}$ ]] || { echo "refused: bucket '$bucket' is not share-e2e-<6 hex>"; exit 2; }
[[ ${host%%.*} == share-e2e* ]] || { echo "refused: the hostname's first label must start with share-e2e"; exit 2; }
minter="${SHARE_E2E_R2_TOKEN_ADMIN:-}"
rule="${SHARE_E2E_ACCESS_RULE:-${SHARE_E2E_ACCESS_EMAIL:+email:$SHARE_E2E_ACCESS_EMAIL}}"
worker="share-${host//./-}"
unset SHARE_CONFIG_DIR SHARE_ROOT SHARE_PROFILE XDG_CONFIG_HOME SHARE_HOSTNAME SHARE_BACKEND SHARE_PORT SHARE_R2_TOKEN SHARE_R2_DRY SHARE_R2_KEY_ID

WORK=$(mktemp -d)
A="$WORK/a" B="$WORK/b"
mkdir -p "$A" "$B" "$WORK/bin"
printf '#!/bin/bash\nexit 44\n' >"$WORK/bin/security"   # 44: item not found; nothing is ever stored
chmod +x "$WORK/bin/security"
export PATH="$WORK/bin:$PATH" SHARE_CLIPBOARD=0

fails=0 total=0
check() { # check <label> <expected> <actual>
  total=$((total + 1))
  if [[ $2 == "$3" ]]; then echo "  ok    $1"; else echo "  FAIL  $1: expected '$2', got '$3'"; fails=$((fails + 1)); fi
}
fetch() { curl -s --max-time 10 --doh-url https://1.1.1.1/dns-query "$@"; }
code() { fetch -o /dev/null -w '%{http_code}' --path-as-is "$1"; }
apit() { local t=$1 p=$2; shift 2; curl -s "https://api.cloudflare.com/client/v4$p" -H @<(printf 'Authorization: Bearer %s\n' "$t") "$@"; }
api() { apit "$admin" "$@"; }
as_a() { env -u CLOUDFLARE_API_TOKEN HOME="$A" "$share" "$@"; }
as_b() { env -u CLOUDFLARE_API_TOKEN HOME="$B" "$share" "$@"; }
admin_as() { local h=$1; shift; HOME="$h" CLOUDFLARE_API_TOKEN="$admin" "$share" "$@"; }
indent() { sed 's/^/  | /'; }

zone_json="$(api "/zones?name=${host#*.}&status=active")"
zone="$(jq -r '.result[0].id // empty' <<<"$zone_json")"
acct="$(jq -r '.result[0].account.id // empty' <<<"$zone_json")"
[[ -n $zone && -n $acct ]] || { echo "refused: the admin token sees no active zone ${host#*.}"; exit 2; }

minted=""
mint() { # mint <name> <account-scope group ids, JSON array>: mint_id and mint_val; the value is never printed
  local body out exp
  exp="$(date -u -v+2H +%FT%TZ 2>/dev/null || date -u -d '+2 hours' +%FT%TZ)"
  body="$(jq -nc --arg n "$1" --arg exp "$exp" --argjson g "$2" \
    --arg b "com.cloudflare.edge.r2.bucket.${acct}_default_$bucket" --arg z "com.cloudflare.api.account.zone.$zone" --arg a "com.cloudflare.api.account.$acct" \
    '{name: $n, expires_on: $exp, policies: [
       {effect: "allow", permission_groups: [{id: "2efd5506f9c8494dacb1fa10a3e7d5b6"}], resources: {($b): "*"}},
       {effect: "allow", permission_groups: [{id: "c8fed203ed3043cba015a93ad1616f1f"}], resources: {($z): "*"}},
       {effect: "allow", permission_groups: ($g | map({id: .})), resources: {($a): "*"}}]}')"
  out="$(apit "$minter" /user/tokens -X POST -H 'Content-Type: application/json' --data "$body")"
  mint_id="$(jq -r '.result.id // empty' <<<"$out")"; mint_val="$(jq -r '.result.value // empty' <<<"$out")"
  [[ -n $mint_id && -n $mint_val ]] || { echo "  mint $1 failed: $(jq -c '.errors' <<<"$out")"; out=""; return 1; }
  out="" minted="$minted $mint_id"
  echo "  | minted token $1 (id ${mint_id:0:8}..., expires $exp)"
}
revoke() { local t; for t in $minted; do apit "$minter" "/user/tokens/$t" -X DELETE -o /dev/null; done; }

s3() { # s3 METHOD <path after the bucket>: the admin token's own S3 pair, as share derives it; prints the HTTP code
  local kid sec; kid="$(api /user/tokens/verify | jq -r '.result.id // empty')"; sec="$(printf '%s' "$admin" | shasum -a 256 | cut -d' ' -f1)"
  curl -s -o "${S3_OUT:-/dev/null}" -w '%{http_code}' -X "$1" "https://$acct.r2.cloudflarestorage.com/$bucket$2" --aws-sigv4 'aws:amz:auto:s3' -K <(printf 'user = "%s:%s"\n' "$kid" "$sec")
}
leftovers() { # the by-name fallback: whatever the purge left, deleted by exact name; each thing it could not delete is printed
  local ids id c k
  if [[ -f $A/.config/share/config ]]; then SHARE_R2_TOKEN="$admin" as_a r2-delete-prefix "" >/dev/null 2>&1
  else   # a setup that died before its config: the keys straight from the listing (url-encoded, so any name is one path)
    S3_OUT="$WORK/keys.xml" s3 GET "?list-type=2&encoding-type=url" >/dev/null
    grep -o '<Key>[^<]*</Key>' "$WORK/keys.xml" 2>/dev/null | sed 's:</*Key>::g' | while IFS= read -r k; do s3 DELETE "/$k" >/dev/null; done
  fi
  ids="$(api "/accounts/$acct/workers/domains?hostname=$host" | jq -r --arg h "$host" --arg w "$worker" '.result[]? | select(.hostname == $h and .service == $w) | .id')"
  for id in $ids; do api "/accounts/$acct/workers/domains/$id" -X DELETE -o /dev/null; done
  api "/accounts/$acct/workers/scripts/$worker" -X DELETE -o /dev/null
  api "/accounts/$acct/r2/buckets/$bucket" -X DELETE -o /dev/null
  ids="$(api "/accounts/$acct/access/apps?per_page=100" | jq -r --arg h "$host" '.result[]? | (.name | split(" ")) as $w
    | select(($w | length) == 4 and $w[0] == "share" and $w[2] == $h) | .id')"
  for id in $ids; do api "/accounts/$acct/access/apps/$id" -X DELETE -o /dev/null; done
  ids="$(api "/zones/$zone/dns_records?name=$host" | jq -r '.result[]?.id')"
  for id in $ids; do api "/zones/$zone/dns_records/$id" -X DELETE -o /dev/null; done
  revoke
  c="$(api "/accounts/$acct/workers/scripts/$worker/settings" -o /dev/null -w '%{http_code}')"; [[ $c == 404 ]] || echo "LEFTOVER: Worker $worker ($c)"
  c="$(api "/accounts/$acct/r2/buckets/$bucket" -o /dev/null -w '%{http_code}')"; [[ $c == 404 ]] || echo "LEFTOVER: bucket $bucket ($c)"
  c="$(api "/accounts/$acct/workers/domains?hostname=$host" | jq '.result | length')"; [[ $c == 0 ]] || echo "LEFTOVER: $c custom domain(s) for $host"
  c="$(api "/zones/$zone/dns_records?name=$host" | jq '.result | length')"; [[ $c == 0 ]] || echo "LEFTOVER: $c DNS record(s) for $host"
  c="$(api "/accounts/$acct/access/apps?per_page=100" | jq --arg h "$host" '[.result[]? | select(.name | split(" ") | .[2] == $h)] | length')"; [[ $c == 0 ]] || echo "LEFTOVER: $c Access app(s) for $host"
  for id in $minted; do c="$(apit "$minter" "/user/tokens/$id" -o /dev/null -w '%{http_code}')"; [[ $c == 404 ]] || echo "LEFTOVER: token ${id:0:8}... ($c)"; done
  return 0
}
cleanup() {
  [[ -f $A/.config/share/config ]] && admin_as "$A" teardown --yes --purge >/dev/null 2>&1
  leftovers
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "=== before: nothing named for this run exists ==="
check "no bucket $bucket" 404 "$(api "/accounts/$acct/r2/buckets/$bucket" -o /dev/null -w '%{http_code}')"
check "no Worker $worker" 404 "$(api "/accounts/$acct/workers/scripts/$worker/settings" -o /dev/null -w '%{http_code}')"
check "no DNS record for $host" 0 "$(api "/zones/$zone/dns_records?name=$host" | jq '.result | length')"
[[ $fails == 0 ]] || { echo "refused: the run's names are in use"; trap - EXIT; rm -rf "$WORK"; exit 2; }

pair="$(awk -F= '/^WORKER_VERSION=/ {split($2, a, " "); v = a[1]} /^WORKER_SHA=/ {split($2, a, " "); s = a[1]} END {print v " " s}' "$(command -v "$share")")"

echo "=== L1 admin setup ==="
admin_as "$A" setup "$host" --backend r2 --bucket "$bucket" 2>&1 | indent
check "setup exits 0" 0 "${PIPESTATUS[0]}"
hz="$(fetch -D - -o "$WORK/hz" "https://$host/healthz" | awk 'tolower($1) == "x-share-worker:" {sub(/\r$/, ""); print $2 " " $3}')"
seen="" c=""   # run 4 saw one 500 right after setup's three 200s: the edge still warming the new deployment
for _ in $(seq 1 15); do c="$(code "https://$host/healthz")"; [[ $c == 200 ]] && break; seen="$seen $c"; sleep 2; done
[[ -z $seen ]] || echo "  | recorded: /healthz answered$seen before 200"
check "/healthz answers 200 ok" "200 ok" "$c $(cat "$WORK/hz" 2>/dev/null)"
check "/healthz carries this CLI's pair" "$pair" "$hz"
check "workers.dev and previews off" "false,false" "$(api "/accounts/$acct/workers/scripts/$worker/subdomain" | jq -r '"\(.result.enabled),\(.result.previews_enabled)"')"
sub="$(api "/accounts/$acct/workers/subdomain" | jq -r '.result.subdomain // empty')"
check "the workers.dev URL does not answer 200" 1 "$(c=$(code "https://$worker.$sub.workers.dev/healthz"); [[ $c != 200 ]] && echo 1 || echo "0 ($c)")"
check "the bucket has no r2.dev URL" false "$(api "/accounts/$acct/r2/buckets/$bucket/domains/managed" | jq -r '.result.enabled')"
check "config: backend r2, port sentinel" "r2 r2" "$(awk -F= '$1 == "backend" {b = $2} $1 == "port" {p = $2} END {print b " " p}' "$A/.config/share/config" 2>/dev/null)"
[[ $fails == 0 ]] || { echo "L1 failed: stopping here; the EXIT trap removes what setup created"; exit 1; }

echo "=== L2 rerun setup (no redeploy) ==="
deployed() { api "/accounts/$acct/workers/scripts" | jq -r --arg w "$worker" '.result[] | select(.id == $w) | "\(.deployment_id) \(.etag)"'; }   # modified_on moves with the subdomain POST every setup makes
before="$(deployed)"
out="$(admin_as "$A" setup "$host" --backend r2 --bucket "$bucket" 2>&1)"; rc=$?
indent <<<"$out"
check "rerun exits 0" 0 "$rc"
check "rerun says already deployed" 1 "$(grep -c 'already deployed' <<<"$out")"
check "no script PUT: deployment id and etag unchanged" "$before" "$(deployed)"

echo "=== publisher tokens ==="
if [[ -n $minter ]]; then
  mint "$bucket-a" '["b89a480218d04ceb98b4fe57ca29dc1f", "1e13c5124ca64b72b1969a67e8829049", "26bc23f853634eb4bff59983b9064fde"]' && export SHARE_E2E_TOK_A="$mint_val" && tok_a_id=$mint_id
  mint "$bucket-b" '["b89a480218d04ceb98b4fe57ca29dc1f"]' && export SHARE_E2E_TOK_B="$mint_val" && tok_b_id=$mint_id
  mint_val=""
else
  export SHARE_E2E_TOK_A="${SHARE_E2E_R2_GATED_TOKEN:-${SHARE_E2E_R2_PUBLISHER_TOKEN:?set SHARE_E2E_R2_TOKEN_ADMIN, or SHARE_E2E_R2_PUBLISHER_TOKEN with SHARE_E2E_R2_BUCKET}}"
  export SHARE_E2E_TOK_B="$SHARE_E2E_R2_PUBLISHER_TOKEN"
  [[ -n ${SHARE_E2E_R2_GATED_TOKEN:-} ]] || rule=""
fi
check "both publisher tokens resolved" 1 "$([[ -n ${SHARE_E2E_TOK_A:-} && -n ${SHARE_E2E_TOK_B:-} ]] && echo 1 || echo 0)"
for t in A B; do   # a new token reaches the S3 endpoint a few seconds after it is minted: wait for a bucket listing
  v="SHARE_E2E_TOK_$t"; n=0
  kid="$(apit "${!v}" /user/tokens/verify | jq -r '.result.id // empty')"
  sec="$(printf '%s' "${!v}" | shasum -a 256 | cut -d' ' -f1)"
  until [[ "$(curl -s -o /dev/null -w '%{http_code}' "https://$acct.r2.cloudflarestorage.com/$bucket?list-type=2&max-keys=1" --aws-sigv4 'aws:amz:auto:s3' -K <(printf 'user = "%s:%s"\n' "$kid" "$sec"))" == 200 || $n -ge 30 ]]; do
    sleep 2; n=$((n + 1))
  done
  echo "  | token $t lists the bucket after $((n * 2))s"
done
sec=""

echo "=== L3 publisher B joins with the bucket token ==="
out="$(HOME="$B" CLOUDFLARE_API_TOKEN="$SHARE_E2E_TOK_B" "$share" setup "$host" --backend r2 --bucket "$bucket" 2>&1)"; rc=$?
indent <<<"$out"
check "join exits 0" 0 "$rc"
check "join says joining as publisher" 1 "$(grep -c '^joining as publisher' <<<"$out")"
check "join skips the public-route check" 1 "$(grep -c 'public-route check skipped (publisher token)' <<<"$out")"
check "GET workers/scripts/<worker>/settings with B's token is refused" 1 "$(c=$(apit "$SHARE_E2E_TOK_B" "/accounts/$acct/workers/scripts/$worker/settings" -o /dev/null -w '%{http_code}'); [[ $c == 401 || $c == 403 ]] && echo 1 || echo "0 ($c)")"
check "PUT workers/scripts/<worker> with B's token is refused" 1 "$(c=$(apit "$SHARE_E2E_TOK_B" "/accounts/$acct/workers/scripts/$worker" -X PUT -F 'metadata={"main_module":"x.js"};type=application/json' -o /dev/null -w '%{http_code}'); [[ $c == 401 || $c == 403 ]] && echo 1 || echo "0 ($c)")"
out="$(apit "$SHARE_E2E_TOK_B" "/accounts/$acct/workers/scripts" -w '\n%{http_code}')"
echo "  | recorded: GET workers/scripts with B's token -> ${out##*$'\n'}, $(jq '.result | length' <<<"${out%$'\n'*}" 2>/dev/null) script(s) listed"
check "GET r2/buckets with B's token is refused" 1 "$(c=$(apit "$SHARE_E2E_TOK_B" "/accounts/$acct/r2/buckets" -o /dev/null -w '%{http_code}'); [[ $c == 401 || $c == 403 ]] && echo 1 || echo "0 ($c)")"
# shellcheck disable=SC2016 # share evals the command later; the variable must stay literal here
out="$(HOME="$B" "$share" api-token --cmd 'printf %s "$CLOUDFLARE_API_TOKEN"' 2>&1)"; rc=$?
check "api-token refuses the admin token as a publisher token" "1 1" "$rc $(grep -c 'it is an admin token' <<<"$out")"
# shellcheck disable=SC2016
out="$(as_b api-token --cmd 'printf %s "$SHARE_E2E_TOK_B"' 2>&1)"; rc=$?
indent <<<"$out"
check "api-token stores B's bucket token" "0 1" "$rc $(grep -c 'not an admin token, no other bucket in reach' <<<"$out")"
# shellcheck disable=SC2016
out="$(as_a api-token --cmd 'printf %s "$SHARE_E2E_TOK_A"' 2>&1)"; rc=$?
indent <<<"$out"
check "api-token stores A's publisher token" 0 "$rc"
check "no token value in either config" 0 "$(cat "$A/.config/share/config" "$B/.config/share/config" | grep -c -F -f <(printf '%s\n' "$SHARE_E2E_TOK_A" "$SHARE_E2E_TOK_B" "$admin"))"   # patterns through a pipe, never argv
check "B's ls is empty" "no shares" "$(as_b ls 2>&1)"

echo "=== L4 A publishes a folder ==="
mkdir -p "$WORK/doc/sub" "$WORK/doc/My Notes" && echo "e2e r2 doc" >"$WORK/doc/index.html" && echo SECRET=x >"$WORK/doc/.env" && echo "inner" >"$WORK/doc/sub/x.txt"
echo "spaced" >"$WORK/doc/My Notes/index.html"
echo "keep me" >"$WORK/keep.txt"
link="$(as_a add "$WORK/doc" 2>"$WORK/add.err" | head -1)"; indent <"$WORK/add.err"
id="$(cut -d/ -f4 <<<"$link")"
check "link shape" "https://$host/$id/doc/" "$link"
check "link answers 200 with no Content-Range" "200 0" "$(code "$link") $(fetch -D - -o /dev/null "$link" | grep -ci '^content-range:')"
check "content is the snapshot" "e2e r2 doc" "$(fetch "$link")"
check "dotfile not served" 404 "$(code "${link}.env")"
check "a subfolder with no index is 404" 404 "$(code "${link}sub/")"
check "a file in the subfolder answers" inner "$(fetch "${link}sub/x.txt")"
check "a subfolder named with a space serves its index" spaced "$(fetch "${link}My%20Notes/")"
hdrs="$(fetch -D - -o /dev/null "$link")"
check "no-store header" 1 "$(grep -ci '^cache-control: no-store' <<<"$hdrs")"
check "a Range request answers 206 with Content-Range" "206 bytes 0-3/11" "$(fetch -r 0-3 -D - -o /dev/null "$link" | awk 'NR == 1 {c = $2} tolower($1) == "content-range:" {sub(/\r$/, ""); r = $2 " " $3} END {print c " " r}')"
check "noindex header" 1 "$(grep -ci '^x-robots-tag: noindex, nofollow' <<<"$hdrs")"
check "/<id> redirects 308 to /<id>/" "308 https://$host/$id/" "$(fetch -o /dev/null -w '%{http_code} %{redirect_url}' "https://$host/$id")"
keep="$(as_a add "$WORK/keep.txt" 2>/dev/null | head -1)"
check "a second share answers" "keep me" "$(fetch "$keep")"

echo "=== L5 encoded paths ==="
for p in "/x/..%2F$id/doc/" "/%2F$id/doc/" "/x/..%5C$id/doc/" "//$id/doc/" "/$id/doc/%2e%2e/" "/$id/%zz"; do
  check "$p answers 400" 400 "$(code "https://$host$p")"
done
for p in "/x/..\\$id/doc/" "/x/%2e%2e/$id/doc/" "/%61${id:1}/doc/" "/$(tr '[:lower:]' '[:upper:]' <<<"$id")/doc/"; do
  echo "  | recorded: $p -> $(code "https://$host$p")"
done
check "a POST answers 405" 405 "$(fetch -o /dev/null -w '%{http_code}' -X POST "$link")"

echo "=== L6 B publishes; both installs list both ==="
echo "from b" >"$WORK/b.txt"
blink="$(as_b add "$WORK/b.txt" 2>/dev/null | head -1)"
bid="$(cut -d/ -f4 <<<"$blink")"
check "B's link answers" "from b" "$(fetch "$blink")"
for _ in 1 2; do fetch -o /dev/null "$blink"; done   # three hits in all for L8
check "A's ls shows B's row with by=" 1 "$(as_a ls 2>/dev/null | grep -c "id=$bid .*by=")"
check "B's ls shows A's two rows" 2 "$(as_b ls 2>/dev/null | grep -c -e "id=$id " -e "id=$(cut -d/ -f4 <<<"$keep") ")"
out="$(as_b refresh "$id" 2>&1)"; rc=$?
check "B cannot refresh A's share" "1 1" "$rc $(grep -c 'was added from another install' <<<"$out")"

echo "=== L7 expiry ==="
SHARE_R2_TOKEN="$admin" as_a r2-call GET "m/$id" | sed 1d | jq -c --argjson e "$(($(date +%s) + 20))" '.expires = $e' >"$WORK/rec.json"
SHARE_R2_TOKEN="$admin" as_a r2-call PUT "m/$id" "$WORK/rec.json" | head -1 | indent
check "the link still answers before the expiry" 200 "$(code "$link")"
sleep 25
check "the link is 404 after the expiry" 404 "$(code "$link")"
as_a ls >/dev/null 2>&1
check "A's ls removed the record" "" "$(as_a r2-list "m/$id")"
check "A's ls left no key under the prefix" "" "$(as_a r2-list "o/$id.")"

if [[ -n $rule ]]; then
  echo "=== L9 gated link ($rule) ==="
  mkdir -p "$WORK/gated" && echo "gated r2" >"$WORK/gated/index.html"
  rm -f "$WORK/gate.seen" "$WORK/gate.done"
  ( gid=""
    while [[ -z $gid && ! -f $WORK/gate.done ]]; do gid="$(cut -f1 "$A/share/access-pending" 2>/dev/null | head -1)"; sleep 0.2; done
    while [[ ! -f $WORK/gate.done ]]; do
      c="$(code "https://$host/$gid/gated/")"; [[ $c == 200 ]] && echo "$c" >>"$WORK/gate.seen"
      echo "$c" >>"$WORK/gate.polls"; sleep 1
    done ) &
  watch_pid=$!
  t0=$(date +%s)
  glink="$(as_a add "$WORK/gated" --access "$rule" 2>"$WORK/gate.err" | head -1)"; grc=$?
  touch "$WORK/gate.done"; wait "$watch_pid" 2>/dev/null
  indent <"$WORK/gate.err"
  gid="$(cut -d/ -f4 <<<"$glink")"
  echo "  | gated add took $(( $(date +%s) - t0 ))s; $(cat "$WORK/gate.polls" 2>/dev/null | wc -l | tr -d ' ') polls during the wait"
  check "gated add printed a link" "0 https://$host/$gid/gated/" "$grc $glink"
  # shellcheck disable=SC2002 # cat keeps a missing file a count of 0
  check "no 200 on the link during the wait" 0 "$(cat "$WORK/gate.seen" 2>/dev/null | wc -l | tr -d ' ')"
  app="$(api "/accounts/$acct/access/apps?per_page=100" | jq -r --arg s "share $gid $host " '[.result[] | select(.name | startswith($s))] | first | "\(.id) \(.aud)"')"
  gapp="${app% *}" gaud="${app#* }"
  check "one app named for the share, with an aud" 1 "$([[ $gaud =~ ^[0-9a-f]{64}$ ]] && echo 1 || echo "0 ($app)")"
  probe() { fetch -o /dev/null -w '%{http_code} %{redirect_url}' --path-as-is "$1"; }
  for p in "/$gid/" "/$gid" "/$(tr '[:lower:]' '[:upper:]' <<<"$gid")/" "/%$(printf '%02x' "'${gid:0:1}")${gid:1}/"; do
    out="$(probe "https://$host$p")"
    check "$p redirects to Access with kid == aud" 1 "$([[ $out == 302* && $out == *".cloudflareaccess.com/cdn-cgi/access/login/$host"* && $out == *"kid=$gaud"* ]] && echo 1 || echo "0 ($out)")"
  done
  for p in "/x/..\\$gid/gated/" "/x/%2e%2e/$gid/gated/" "//$gid/gated/" "/x/..%2F$gid/gated/"; do
    c="$(code "https://$host$p")"
    check "$p never answers 200 ($c)" 1 "$([[ $c != 200 ]] && echo 1 || echo 0)"
  done
  as_a rm "$gid" 2>&1 | indent
  check "gated rm exits 0" 0 "${PIPESTATUS[0]}"
  check "GET access/apps/<app> is 404" 404 "$(api "/accounts/$acct/access/apps/$gapp" -o /dev/null -w '%{http_code}')"
  check "the gated link never answers 200 after rm" 1 "$(c=$(code "https://$host/$gid/gated/"); [[ $c != 200 ]] && echo 1 || echo "0 ($c)")"
  check "access-pending is empty" 0 "$(awk 'NF' "$A/share/access-pending" 2>/dev/null | wc -l | tr -d ' ')"
else
  echo "=== L9 gated link: SKIP (no SHARE_E2E_ACCESS_RULE or SHARE_E2E_ACCESS_EMAIL, or no gated token) ==="
fi

echo "=== L8 hits (Analytics Engine lags; polled up to 4 min from B's first fetch) ==="
n=0 h=0
until [[ $h -ge 3 || $n -ge 24 ]]; do
  out="$(as_b hits "$bid" 2>&1)"; h="$(awk '{print $1 + 0; exit}' <<<"$out")"
  [[ $h -ge 3 ]] || { sleep 10; n=$((n + 1)); }
done
echo "  | $out"
check "hits counts the three fetches of B's link" 1 "$([[ $h -ge 3 ]] && echo 1 || echo "0 ($out)")"
out="$(as_b hits "abc' OR '1'='1" 2>&1)"; rc=$?
check "an injected id is refused" 1 "$rc"

echo "=== L10 B's local teardown ==="
keys_before="$(as_a r2-list "" | sort | shasum)"
as_b teardown --yes 2>&1 | indent
check "B's teardown exits 0" 0 "${PIPESTATUS[0]}"
check "B's config is gone" 1 "$([[ ! -f $B/.config/share/config ]] && echo 1 || echo 0)"
check "the bucket listing is unchanged" "$keys_before" "$(as_a r2-list "" | sort | shasum)"
check "A's link still answers" "keep me" "$(fetch "$keep")"
check "B's link still answers" "from b" "$(fetch "$blink")"

echo "=== L11 admin teardown --purge ==="
admin_as "$A" teardown --yes --purge 2>&1 | indent
check "purge exits 0" 0 "${PIPESTATUS[0]}"
check "A's config is gone" 1 "$([[ ! -f $A/.config/share/config ]] && echo 1 || echo 0)"
check "the links are down" 1 "$(c1=$(code "$keep"); c2=$(code "$blink"); [[ $c1 != 200 && $c2 != 200 ]] && echo 1 || echo "0 ($c1 $c2)")"

echo "=== cleanup, asserted through the API ==="
check "Worker settings 404" 404 "$(api "/accounts/$acct/workers/scripts/$worker/settings" -o /dev/null -w '%{http_code}')"
check "no custom domain for $host" 0 "$(api "/accounts/$acct/workers/domains?hostname=$host" | jq '.result | length')"
check "no DNS record for $host" 0 "$(api "/zones/$zone/dns_records?name=$host" | jq '.result | length')"
check "bucket 404" 404 "$(api "/accounts/$acct/r2/buckets/$bucket" -o /dev/null -w '%{http_code}')"
check "no Access app named share * $host *" 0 "$(api "/accounts/$acct/access/apps?per_page=100" | jq --arg h "$host" '[.result[] | select(.name | split(" ") | .[2] == $h)] | length')"
if [[ -n $minter ]]; then
  revoke
  check "publisher token A revoked" 404 "$(apit "$minter" "/user/tokens/${tok_a_id:-none}" -o /dev/null -w '%{http_code}')"
  check "publisher token B revoked" 404 "$(apit "$minter" "/user/tokens/${tok_b_id:-none}" -o /dev/null -w '%{http_code}')"
fi
echo "  | the Analytics Engine dataset share_${host//[.-]/_} cannot be deleted by API; it ages out"

echo
echo "$((total - fails))/$total checks passed"
if [[ $fails -gt 0 ]]; then echo "$fails FAILED"; exit 1; fi
echo PASS
