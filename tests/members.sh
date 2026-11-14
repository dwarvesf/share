# shellcheck shell=bash
# tests/members.sh: SPEC-009 Phase 1 (TASK-1b to 1i), sourced by tests/share.sh (it reads check, SH, WORK, base and h from there).
# Every Cloudflare call goes to the dry account (SHARE_R2_DRY=1, state files under <bucket>/.cf), every bucket call to the dry bucket.
# shellcheck disable=SC2154 # check, SH, WORK, base and h come from tests/share.sh

echo "=== members: shared fixtures ==="
MX="$WORK/mx"; mkdir -p "$MX/bin" "$MX/kv"
MX_HOME="$MX/home"; MX_DRY="$MX/bucket"; MX_ROOT="$MX_HOME/share/profiles/ten"; MX_CONF="$MX_HOME/.config/share/profiles/ten/config"
MX_LOG="$MX_ROOT/r2-calls.log"
mx_this="${h%%.*}"
# a Keychain stand-in that keeps values in files under $MX/kv (the suite's global stub keeps none), and a Trash into a folder
cat >"$MX/bin/security" <<EOF
#!/bin/bash
kv="\${MX_KV:-$MX/kv}"; mkdir -p "\$kv"
svc=""; val=""; prev=""; for a in "\$@"; do case \$prev in -s) svc="\$a" ;; -w) val="\$a" ;; esac; prev="\$a"; done
case \$1 in
  -i) line="\$(cat)"; svc="\$(sed -n 's/.* -s "\\([^"]*\\)".*/\\1/p' <<<"\$line")"; val="\$(sed -n 's/.* -w "\\([^"]*\\)".*/\\1/p' <<<"\$line")"; [[ -n \$svc ]] && printf '%s' "\$val" >"\$kv/\$svc"; exit 0 ;;
  add-generic-password) printf '%s' "\$val" >"\$kv/\$svc"; exit 0 ;;
  find-generic-password) [[ -f "\$kv/\$svc" ]] || exit 44; [[ " \$* " == *" -w "* ]] && cat "\$kv/\$svc"; exit 0 ;;
  delete-generic-password) rm -f "\$kv/\$svc"; exit 0 ;;
esac
exit 0
EOF
# shellcheck disable=SC2016 # literal source for the stub
printf '#!/bin/bash\nmkdir -p "%s/trashed"; mv -f "$1" "%s/trashed/$(basename "$1").$$.$RANDOM"\n' "$MX" "$MX" >"$MX/bin/trash"
chmod +x "$MX/bin/security" "$MX/bin/trash"
mx_env=()   # extra VAR=value pairs for the next mxa call (cleared by mxa)
mxa() { # mxa <verb...>: the tenant origin profile ten of mx.example.test, R2 and Access dry; the admin token unless MX_TOK=- , the minter unless MX_MINT=-
  local e=(env -u SHARE_ROOT -u SHARE_CONFIG_DIR -u SHARE_PORT -u SHARE_HOSTNAME -u XDG_CONFIG_HOME -u SHARE_PROFILE -u SHARE_BACKEND -u CLOUDFLARE_API_TOKEN -u SHARE_MINTER_TOKEN
    HOME="$MX_HOME" PATH="$MX/bin:$PATH" SHARE_TUNNEL=0 SHARE_R2_DRY=1 SHARE_R2_DRY_DIR="$MX_DRY" SHARE_R2_TOKEN=drytoken SHARE_ACCESS_DRY=1 SHARE_ACCESS_POLL=0
    SHARE_R2_WAIT=2 SHARE_HOSTS="$mx_this" SHARE_LEASE_WAIT="${MX_LEASE_WAIT:-2}")
  [[ ${MX_TOK:-} == - ]] || e+=(CLOUDFLARE_API_TOKEN="${MX_TOK:-admintoken}")
  [[ ${MX_MINT:-} == - ]] || e+=(SHARE_MINTER_TOKEN="${MX_MINT:-mintertoken}")
  "${e[@]}" ${mx_env[@]+"${mx_env[@]}"} bash "${MX_SH:-$SH}" --profile ten "$@"
}
mx_fresh() { # a T1 tenant: the origin of mx.example.test with R2 on (setup --r2 ran), one local row, the dry bucket with its marker
  rm -rf "$MX_HOME" "$MX_DRY" "$MX/kv"/* "$MX/trashed"; mkdir -p "${MX_CONF%/*}" "$MX_DRY/.cf" "$MX_ROOT/pub/0c0001"
  printf 'hostname=mx.example.test\ntunnel_id=tid-mx\ntunnel_name=share-mx-example-test\nauth=api\nhosts=%s\nport=%s\n' "$mx_this" $((base + 360)) >"$MX_CONF"
  printf 'x\n' >"$MX_ROOT/pub/0c0001/x.txt"; printf '0c0001\tx.txt\t/src/x.txt\t2026-10-01\t0\t\n' >"$MX_ROOT/index.tsv"
  : >"$MX_DRY/.cf/bucket"; printf '{"v":1,"host":"mx.example.test"}\n' >"$MX_DRY/share.json"
  mxa setup mx.example.test --r2 --bucket mx-bucket >"$MX/setup.out" 2>&1 || { echo "  FAIL  mx_fresh: setup --r2 failed"; cat "$MX/setup.out"; }
  : >"$MX_LOG"
}
mx_t2() { # mx_fresh, then members on
  mx_fresh
  mxa setup mx.example.test --r2 --bucket mx-bucket --members --yes >"$MX/setup.out" 2>&1 || { echo "  FAIL  mx_t2: setup --members failed"; cat "$MX/setup.out"; }
  : >"$MX_LOG"
}
MXM_HOME="$MX/member"; MXM_ROOT="$MXM_HOME/share"; MXM_CONF="$MXM_HOME/.config/share/config"
mxm() { # mxm <verb...>: the default profile of a second machine's HOME (the member), on the same dry bucket and dry Worker; its own Keychain stand-in
  env -u SHARE_ROOT -u SHARE_CONFIG_DIR -u SHARE_PORT -u SHARE_HOSTNAME -u XDG_CONFIG_HOME -u SHARE_PROFILE -u SHARE_BACKEND -u CLOUDFLARE_API_TOKEN -u SHARE_MINTER_TOKEN -u SHARE_HOSTS \
    HOME="$MXM_HOME" MX_KV="$MX/kv-member" PATH="$MX/bin:$PATH" SHARE_TUNNEL=0 SHARE_JOIN_SERVICE=0 SHARE_CLIPBOARD=0 SHARE_R2_DRY=1 SHARE_R2_DRY_DIR="$MX_DRY" SHARE_R2_WAIT=2 \
    SHARE_R2_DRY_WORKER="node $(dirname "$SH")/../tests/worker.mjs --dir $MX_DRY --host mx.example.test" ${mxm_env[@]+"${mxm_env[@]}"} bash "${MXM_SH:-$SH}" "$@"
}
mxm_env=()
mxm_fresh() { mxm stop >/dev/null 2>&1; rm -rf "$MXM_HOME" "$MX/kv-member"; mkdir -p "$MXM_HOME"; }
mx_save() { rm -rf "$MX/snap.$1"; mkdir -p "$MX/snap.$1"; cp -R "$MX_HOME" "$MX_DRY" "$MX/snap.$1/"; }
mx_load() { rm -rf "$MX_HOME" "$MX_DRY"; cp -R "$MX/snap.$1/home" "$MX_HOME"; cp -R "$MX/snap.$1/bucket" "$MX_DRY"; : >"$MX_LOG"; }
mx_writes() { grep -cE '^(API (PUT|POST|DELETE) |PUT |DELETE )' "$MX_LOG" 2>/dev/null || true; }
mx_rec() { jq -c . "$MX_DRY/u/$1.json" 2>/dev/null; }   # mx_rec <member_id>: the record, compact
mx_bind() { jq -r '[.bindings[] | select(.type == "vpc_service" or .name == "MEMBERS" or .name == "PAUSED") | "\(.name)=\(.service_id // .text)"] | sort | join(" ")' "$MX_DRY/.cf/script.json"; }
mx_objs() { # every member object by kind, one line: live tunnels, services, tokens (all minter users), invites
  local t s k i
  t="$(cat "$MX_DRY"/.cf/tunnels/*.json 2>/dev/null | jq -rs '[.[] | select(.deleted_at == null) | .name] | sort | join(",")')"
  s="$(cat "$MX_DRY"/.cf/services/*.json 2>/dev/null | jq -rs '[.[].name] | sort | join(",")')"
  k="$(find "$MX_DRY/.cf/tokens" -name '*.json' -exec cat {} + 2>/dev/null | jq -rs '[.[].name] | sort | join(",")')"
  i="$(find "$MX_DRY/i" -type f 2>/dev/null | grep -c . || true)"
  echo "tunnels=[$t] services=[$s] tokens=[$k] invites=$i"
}
mx_wait_paused() { local _; for _ in $(seq 1 200); do [[ -f $MX_DRY/.paused ]] && return 0; sleep 0.05; done; return 1; }
mx_gone() { local _; for _ in $(seq 1 100); do kill -0 "$1" 2>/dev/null || return 0; sleep 0.1; done; return 1; }
mx_api() { mxa r2-api "$@" 2>&1; }   # mx_api [--minter] METHOD PATH [JSON]: "code=<n> err=<e>" then the body
mx_code() { head -1 <<<"$1" | sed 's/^code=\([0-9]*\).*/\1/'; }
mx_err() { head -1 <<<"$1" | sed -n 's/.* err=//p'; }
mx_body() { sed '1d' <<<"$1"; }
mx_fn() { mx_env=(SHARE_STATE_FN_WRITE=1); mxa state-fn "$@"; local rc=$?; mx_env=(); return $rc; }

echo "=== members: dry seams ==="
mx_fresh
A=/accounts/acct-dry
o=$(mx_api POST $A/cfd_tunnel '{"name":"share-mx-example-test-aaaaaaa1","config_src":"cloudflare"}'); t1="$(mx_body "$o" | jq -r .result.id)"
o2=$(mx_api POST $A/cfd_tunnel '{"name":"share-mx-example-test-aaaaaaa1","config_src":"cloudflare"}')
check "mm seam: a tunnel create answers its id; the same name again answers 409 1013" "200 1 409 1013" "$(mx_code "$o") $([[ $t1 =~ ^[0-9a-f-]{36}$ ]] && echo 1) $(mx_code "$o2") $(mx_err "$o2")"
o=$(mx_api GET "$A/cfd_tunnel?name=share-mx-example-test-aaaaaaa1&is_deleted=false")
check "mm seam: a tunnel is found by name" "$t1" "$(mx_body "$o" | jq -r '.result[0].id')"
o=$(mx_api PUT "$A/cfd_tunnel/$t1/configurations" '{"config":{"ingress":[{"service":"http_status:404"}]}}'); o2=$(mx_api GET "$A/cfd_tunnel/$t1/token")
check "mm seam: the config PUT and the token GET answer 200" "200 200 1" "$(mx_code "$o") $(mx_code "$o2") $(mx_body "$o2" | jq -r .result | grep -c '^ctok-SECRET-')"
echo 2 >"$MX_DRY/.cf/tunnels/$t1.conns"
o=$(mx_api GET "$A/cfd_tunnel/$t1/connections"); o2=$(mx_api DELETE "$A/cfd_tunnel/$t1")
check "mm seam: connections list one entry per connector (4 conns each); a delete with connectors answers 400 1022" "2 4 400 1022" \
  "$(mx_body "$o" | jq '.result | length') $(mx_body "$o" | jq '.result[0].conns | length') $(mx_code "$o2") $(mx_err "$o2")"
mx_api DELETE "$A/cfd_tunnel/$t1/connections" >/dev/null; o=$(mx_api DELETE "$A/cfd_tunnel/$t1"); o2=$(mx_api DELETE "$A/cfd_tunnel/$t1"); o3=$(mx_api GET "$A/cfd_tunnel?name=share-mx-example-test-aaaaaaa1&is_deleted=false")
check "mm seam: connections deleted, the tunnel deletes; again 404; is_deleted=false hides it" "200 404 0" "$(mx_code "$o") $(mx_code "$o2") $(mx_body "$o3" | jq '.result | length')"
sb() { jq -nc --arg n "$1" --arg t "$2" --argjson p "$3" '{type: "http", name: $n, host: {ipv4: "127.0.0.1", network: {tunnel_id: $t}}, http_port: $p}'; }
o=$(mx_api POST $A/connectivity/directory/services "$(sb svc-a tun-1 8801)"); s1="$(mx_body "$o" | jq -r .result.service_id)"
o2=$(mx_api POST $A/connectivity/directory/services "$(sb svc-a tun-2 8802)"); o3=$(mx_api POST $A/connectivity/directory/services "$(sb svc-b tun-1 8801)")
check "mm seam: a service create answers service_id; a taken name or (tunnel, ipv4, port) answers 400 5101" "200 1 400 5101 400 5101" \
  "$(mx_code "$o") $([[ -n $s1 && $s1 != null ]] && echo 1) $(mx_code "$o2") $(mx_err "$o2") $(mx_code "$o3") $(mx_err "$o3")"
for i in $(seq 2 12); do mx_api POST $A/connectivity/directory/services "$(sb "svc-$i" tun-1 $((8810 + i)))" >/dev/null; done
o=$(mx_api GET "$A/connectivity/directory/services?per_page=10&page=1"); o2=$(mx_api GET "$A/connectivity/directory/services?per_page=10&page=2&name=svc-a")
check "mm seam: the service list pages by per_page and page, has no result_info and ignores ?name=" "10 2 null" \
  "$(mx_body "$o" | jq '.result | length') $(mx_body "$o2" | jq '.result | length') $(mx_body "$o" | jq -c '.result_info')"
o=$(mx_api PUT "$A/connectivity/directory/services/$s1" '{"http_port":8899}'); o2=$(mx_api PUT "$A/connectivity/directory/services/$s1" "$(sb svc-a tun-1 8899)")
check "mm seam: a service PUT needs the whole body (5102), and then moves the port" "400 5102 200 8899" "$(mx_code "$o") $(mx_err "$o") $(mx_code "$o2") $(mx_body "$o2" | jq .result.http_port)"
o=$(mx_api DELETE "$A/connectivity/directory/services/$s1"); o2=$(mx_api DELETE "$A/connectivity/directory/services/$s1"); o3=$(mx_api GET "$A/connectivity/directory/services/$s1")
check "mm seam: a service delete answers 200, then 404 5104 for the delete and the GET" "200 404 5104 404" "$(mx_code "$o") $(mx_code "$o2") $(mx_err "$o2") $(mx_code "$o3")"
tb='{"name":"share mx.example.test m-an-aaaaaaa1","expires_on":"2027-01-01T00:00:00Z","policies":[]}'
o=$(mx_api --minter POST /user/tokens "$tb"); k1="$(mx_body "$o" | jq -r .result.id)"
o2=$(mx_api --minter GET "/user/tokens?per_page=50&page=1"); o3=$(MX_MINT=othermint mx_api --minter GET "/user/tokens?per_page=50&page=1")
check "mm seam: a mint answers its id and value once; the list never holds a value; another minter user sees none" "200 1 1 0 0" \
  "$(mx_code "$o") $(mx_body "$o" | jq -r .result.value | grep -c '^msec-') $(mx_body "$o2" | jq '.result | length') $(mx_body "$o2" | grep -c msec-) $(mx_body "$o3" | jq '.result | length')"
o=$(mx_env=(SHARE_R2_DRY_TOKENS_HELD=41); mx_api --minter GET "/user/tokens?per_page=50&page=1")
check "mm seam: total_count counts the tokens the minting user holds elsewhere (SHARE_R2_DRY_TOKENS_HELD)" "42" "$(mx_body "$o" | jq .result_info.total_count)"
o=$(mx_api --minter PUT "/user/tokens/$k1" '{"expires_on":"2027-06-01T00:00:00Z"}'); o2=$(mx_api --minter DELETE "/user/tokens/$k1"); o3=$(mx_api --minter DELETE "/user/tokens/$k1")
check "mm seam: a token PUT moves expires_on; DELETE 200, then 404 1003" "200 2027-06-01T00:00:00Z 200 404 1003" "$(mx_code "$o") $(mx_body "$o" | jq -r .result.expires_on) $(mx_code "$o2") $(mx_code "$o3") $(mx_err "$o3")"
o=$(mx_env=(SHARE_R2_DRY_MINTER_GROUPS="API Tokens Read"); mx_api --minter GET /user/tokens/verify); sid="$(mx_body "$o" | jq -r .result.id)"
o2=$(mx_env=(SHARE_R2_DRY_MINTER_GROUPS="API Tokens Read"); mx_api --minter GET "/user/tokens/$sid")
check "mm seam: the minter's own token lists its permission groups by name" "API Tokens Read" "$(mx_body "$o2" | jq -r '[.result.policies[].permission_groups[].name] | join(",")')"
o=$(mx_env=(SHARE_R2_DRY_FAIL='API POST */cfd_tunnel' SHARE_R2_DRY_FAIL_TIMES=1); mx_api POST $A/cfd_tunnel '{"name":"f1"}'); o2=$(mx_env=(SHARE_R2_DRY_FAIL='API POST */cfd_tunnel' SHARE_R2_DRY_FAIL_TIMES=1); mx_api POST $A/cfd_tunnel '{"name":"f1"}')
check "mm seam: SHARE_R2_DRY_FAIL fails a member call with no change; FAIL_TIMES lets a retry through" "500 200" "$(mx_code "$o") $(mx_code "$o2")"
o=$(mx_env=(SHARE_R2_DRY_DENY='API GET */cfd_tunnel*|API GET /user/tokens*'); mx_api GET "$A/cfd_tunnel?per_page=1"); o2=$(mx_env=(SHARE_R2_DRY_DENY='API GET */cfd_tunnel*|API GET /user/tokens*'); mx_api GET "$A/connectivity/directory/services?per_page=1")
check "mm seam: SHARE_R2_DRY_DENY answers 403 10000 for each glob, nothing else" "403 10000 200" "$(mx_code "$o") $(mx_err "$o") $(mx_code "$o2")"
o=$(mx_env=(SHARE_R2_DRY_COMMIT_FAIL='API POST */cfd_tunnel'); mx_api POST $A/cfd_tunnel '{"name":"cf1"}'); o2=$(mx_api GET "$A/cfd_tunnel?name=cf1&is_deleted=false")
check "mm seam: SHARE_R2_DRY_COMMIT_FAIL applies the create, then answers 500" "500 1" "$(mx_code "$o") $(mx_body "$o2" | jq '.result | length')"
( mx_env=(SHARE_R2_DRY_PAUSE='API POST */cfd_tunnel'); mx_api POST $A/cfd_tunnel '{"name":"p1"}' >/dev/null ) & pp=$!
mx_wait_paused; held="$(mx_body "$(mx_api GET "$A/cfd_tunnel?name=p1&is_deleted=false")" | jq '.result | length')"
: >"$MX_DRY/.resume"; wait "$pp"; rm -f "$MX_DRY/.resume" "$MX_DRY/.paused"
check "mm seam: SHARE_R2_DRY_PAUSE holds an API call until .resume (a kill point)" "0 1" "$held $(mx_body "$(mx_api GET "$A/cfd_tunnel?name=p1&is_deleted=false")" | jq '.result | length')"
o=$(SHARE_TEST_CODE=ABCDEFGHIJKLMNOPQRST mx_fn invite-seal <<<'{"x":1}' 2>&1); o2=$(SHARE_TEST_CODE=ABCDEFGHIJKLMNOPQRST mx_fn invite-seal <<<'{"x":1}' 2>&1)
check "mm seam: SHARE_TEST_CODE fixes the invite code, so its i/ hash is fixed" "$(printf 'share-invite-id:ABCDEFGHIJKLMNOPQRST' | shasum -a 256 | cut -c1-64) 1" "$(cut -d' ' -f1 <<<"$o") $([[ $(cut -d' ' -f1 <<<"$o") == $(cut -d' ' -f1 <<<"$o2") ]] && echo 1)"
mx_t2; mx_save t2
o=$(SHARE_TEST_MEMBER_IDS="m-x-aaaaaaa1 m-x-bbbbbbb2" mxa member add an --cloud 2>&1); o2=$(SHARE_TEST_MEMBER_IDS="m-x-ccccccc3" mxa member add bo --cloud 2>&1)
check "mm seam: SHARE_TEST_MEMBER_IDS makes member ids deterministic, in order" "1 1" "$([[ -f $MX_DRY/u/m-an-aaaaaaa1.json ]] && echo 1) $([[ -f $MX_DRY/u/m-bo-ccccccc3.json ]] && echo 1)"
H64="$(printf 'a%.0s' $(seq 1 64))"
mkdir -p "$MX_DRY/i"; printf '{"v":1,"member_id":"m-an-aaaaaaa1","expires":%s,"sealed":"c2VhbGVk","mac":"%s"}\n' $(( $(date +%s) + 3600 )) "$(printf 'b%.0s' $(seq 1 64))" >"$MX_DRY/i/$H64"
wk="node $(dirname "$SH")/../tests/worker.mjs --dir $MX_DRY --host mx.example.test"
o=$(mx_env=(SHARE_R2_DRY_WORKER="$wk"); mxa worker-call POST /_share/redeem "$H64" 2>&1)
check "mm seam: SHARE_R2_DRY_WORKER answers a dry redeem through the real Worker and deletes the claimed object" "code=200 m-an-aaaaaaa1 0" \
  "$(head -1 <<<"$o") $(sed -n 2p <<<"$o" | jq -r .member_id) $([[ -e $MX_DRY/i/$H64 ]] && echo 1 || echo 0)"
o=$(mx_env=(SHARE_R2_DRY_WORKER="$wk"); mxa worker-call POST /_share/redeem "$H64" 2>&1)
check "mm seam: the dry Worker's second redeem of the same object answers 404" "code=404" "$(head -1 <<<"$o")"
# every seam refuses outside SHARE_TUNNEL=0 and a .test hostname
o=$(env -u SHARE_ROOT -u SHARE_CONFIG_DIR -u SHARE_HOSTNAME -u XDG_CONFIG_HOME HOME="$MX_HOME" PATH="$MX/bin:$PATH" SHARE_TUNNEL=1 SHARE_R2_DRY=1 SHARE_R2_DRY_DIR="$MX_DRY" CLOUDFLARE_API_TOKEN=x bash "$SH" --profile ten r2-api POST $A/cfd_tunnel '{"name":"z"}' 2>&1)
o2=$(env -u SHARE_ROOT -u SHARE_CONFIG_DIR -u SHARE_HOSTNAME -u XDG_CONFIG_HOME HOME="$MX_HOME" PATH="$MX/bin:$PATH" SHARE_TUNNEL=1 SHARE_R2_DRY=1 SHARE_R2_DRY_DIR="$MX_DRY" SHARE_R2_DRY_WORKER="$wk" bash "$SH" --profile ten worker-call POST /_share/redeem x 2>&1)
check "mm seam: the dry account and the dry Worker refuse outside SHARE_TUNNEL=0 (no file written)" "1 code=000 1 0" \
  "$(grep -c 'test seam for SHARE_TUNNEL=0' <<<"$o") $(grep '^code=' <<<"$o2") $(grep -c 'SHARE_R2_DRY_WORKER, with SHARE_TUNNEL=0' <<<"$o2") $(mx_body "$(mx_api GET "$A/cfd_tunnel?name=z&is_deleted=false")" | jq '.result | length')"
mxo() { # mxo <verb...>: another admin machine with no profile, --tenant mx.example.test, on the same dry account and bucket
  env -u SHARE_ROOT -u SHARE_CONFIG_DIR -u SHARE_PORT -u SHARE_HOSTNAME -u XDG_CONFIG_HOME -u SHARE_PROFILE -u SHARE_BACKEND -u SHARE_HOSTS \
    HOME="$MX/other" PATH="$MX/bin:$PATH" SHARE_TUNNEL=0 SHARE_R2_DRY=1 SHARE_R2_DRY_DIR="$MX_DRY" SHARE_R2_WAIT=2 SHARE_LEASE_WAIT="${MX_LEASE_WAIT:-2}" \
    CLOUDFLARE_API_TOKEN=admintoken SHARE_MINTER_TOKEN=mintertoken ${mxo_env[@]+"${mxo_env[@]}"} bash "$SH" member "$@" --tenant mx.example.test
}
mxo_env=()
mx_aged() { local t=$(($(date +%s) - $1)) s; s="$(date -r "$t" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$t" +%Y%m%d%H%M.%S)"; touch -t "$s" "${@:2}"; }
mx_codes="$(bash "$SH" state-fn codes | tr '\n' ' ')"
mx_jcode() { # mx_jcode <output>: the code of the last line when it is the SHARE_ERROR_JSON line and the code is in state-fn codes, else "none"
  local c; c="$(tail -1 <<<"$1" | jq -r 'select(type == "object") | .error.code // empty' 2>/dev/null)"
  [[ -n $c && " $mx_codes " == *" $c "* ]] && echo "$c" || echo none
}
mx_lease() { # mx_lease <holder> <verb> <member> <step> [age secs]: a lock/admin another admin left, aged
  printf '{"v":1,"holder":"%s","verb":"%s","member":"%s","step":%s,"taken":%s}\n' "$1" "$2" "$3" "$4" "${6:-$(date +%s)}" >"$MX_DRY/lock/admin" 2>/dev/null ||
    { mkdir -p "$MX_DRY/lock"; printf '{"v":1,"holder":"%s","verb":"%s","member":"%s","step":%s,"taken":%s}\n' "$1" "$2" "$3" "$4" "${6:-$(date +%s)}" >"$MX_DRY/lock/admin"; }
  [[ -z ${5:-} ]] || mx_aged "$5" "$MX_DRY/lock/admin"
}

echo "=== members: admin context ==="
mx_load t2
printf '#!/bin/bash\necho x >>"%s/mark-admin"\necho "${MX_CMD_OUT:-admintoken}"\nexit "${MX_CMD_RC:-0}"\n' "$MX" >"$MX/bin/admin-cmd"
printf '#!/bin/bash\necho x >>"%s/mark-minter"\necho mintertoken\n' "$MX" >"$MX/bin/minter-cmd"
chmod +x "$MX/bin/admin-cmd" "$MX/bin/minter-cmd"
mx_marks() { echo "$(grep -c . "$MX/mark-admin" 2>/dev/null || echo 0)/$(grep -c . "$MX/mark-minter" 2>/dev/null || echo 0)"; }
printf 'admin_token_cmd=admin-cmd\nminter_token_cmd=minter-cmd\n' >>"$MX_CONF"
rm -f "$MX/mark-"*; out=$(mxa member ls 2>&1); rc=$?
check "mm CC-13: CLOUDFLARE_API_TOKEN wins: admin_token_cmd never runs; member ls never runs minter_token_cmd" "0 0/0" "$rc $(mx_marks)"
rm -f "$MX/mark-"*; out=$(MX_TOK=- MX_MINT=- mxa member ls 2>&1); rc=$?
check "mm CC-13: with only admin_token_cmd, member ls runs it once and proves admin; the minter command stays unrun" "0 1/0" "$rc $(mx_marks)"
rm -f "$MX/mark-"*; out=$(MX_TOK=- MX_MINT=- mxa member renew an 2>&1); rc=$?
check "mm TASK-1c1: member renew runs minter_token_cmd once" "1/1" "$(mx_marks)"
: >"$MX_LOG"; rm -f "$MX/mark-"*
out=$(MX_TOK=- mx_env=(MX_CMD_RC=1 MX_CMD_OUT=SENTINEL-OUT SHARE_ERROR_JSON=1); mxa member ls 2>&1); rc=$?
check "mm CC-13: admin_token_cmd exiting 1 dies admin_token_cmd_failed naming the status, never its output, before any call" "1 admin_token_cmd_failed 1 0 0" \
  "$rc $(mx_jcode "$out") $(grep -c '^share: admin_token_cmd exited 1' <<<"$out") $(grep -c SENTINEL-OUT <<<"$out") $(grep -c . "$MX_LOG")"
sed -i.bak '/^admin_token_cmd=/d; /^minter_token_cmd=/d' "$MX_CONF"
: >"$MX_LOG"; out=$(MX_TOK=- mx_env=(SHARE_ERROR_JSON=1); mxa member ls 2>&1); rc=$?
check "mm CC-13: with neither source, member ls dies admin_token_missing before any bucket or API call" "1 admin_token_missing 0" "$rc $(mx_jcode "$out") $(grep -c . "$MX_LOG")"
: >"$MX_LOG"; out=$(mx_env=(SHARE_R2_DRY_ROLE=deny SHARE_ERROR_JSON=1); mxa member ls 2>&1); rc=$?
check "mm WM-03: a token that cannot read the Worker settings is refused admin_token_not_admin, nothing written" "1 admin_token_not_admin 0" "$rc $(mx_jcode "$out") $(mx_writes)"
: >"$MX_LOG"; out=$(MX_MINT=- mx_env=(SHARE_ERROR_JSON=1); mxa member add an 2>&1); rc=$?
check "mm MB-04: no minter source: member add dies minter_token_missing before the lease" "1 minter_token_missing 0" "$rc $(mx_jcode "$out") $(grep -c 'lock/admin' "$MX_LOG")"
: >"$MX_LOG"; out=$(mx_env=(SHARE_R2_DRY_MINTER_GROUPS="API Tokens Read" SHARE_ERROR_JSON=1); mxa member add an 2>&1); rc=$?
check "mm MB-04: a minter lacking API Tokens Write is refused minter_token_scope before the lease" "1 minter_token_scope 0 1" "$rc $(mx_jcode "$out") $(grep -c 'lock/admin' "$MX_LOG") $(grep -c '^share: .*lacks API Tokens Write' <<<"$out")"
: >"$MX_LOG"; out=$(mx_env=(SHARE_R2_DRY_DENY='API GET */connectivity/directory/services*' SHARE_ERROR_JSON=1); mxa member add an 2>&1); rc=$?
check "mm MB-04, OT-16: an admin token lacking Connectivity Directory Admin is refused by name, before the lease and any write" "1 admin_token_scope 1 0" \
  "$rc $(mx_jcode "$out") $(grep -c '^share: .*lacks Connectivity Directory Admin' <<<"$out") $(mx_writes)"
out=$(mx_env=(SHARE_R2_DRY_DENY='API GET */cfd_tunnel*|API GET */connectivity/directory/services*' SHARE_ERROR_JSON=1); mxa member ls 2>&1)
check "mm TASK-1c1: each missing admin scope is named" "1 admin_token_scope" "$(grep -c '^share: .*lacks Cloudflare Tunnel Write, Connectivity Directory Admin' <<<"$out") $(mx_jcode "$out")"
out=$(env -u SHARE_ROOT -u SHARE_CONFIG_DIR -u SHARE_HOSTNAME -u SHARE_PROFILE -u XDG_CONFIG_HOME HOME="$MX/nohome" SHARE_R2_DRY=1 PATH="$MX/bin:$PATH" SHARE_TUNNEL=0 SHARE_ERROR_JSON=1 CLOUDFLARE_API_TOKEN=x bash "$SH" member ls 2>&1); rc=$?
check "mm OT-15: an admin verb with no --tenant on a machine with no profile is refused naming --tenant" "1 member_no_tenant 1" "$rc $(mx_jcode "$out") $(grep -c -- '^share: .*--tenant <host>' <<<"$out")"
out=$(env -u SHARE_ROOT -u SHARE_CONFIG_DIR -u SHARE_HOSTNAME -u SHARE_PROFILE -u XDG_CONFIG_HOME HOME="$MX/nohome" SHARE_R2_DRY=1 PATH="$MX/bin:$PATH" SHARE_TUNNEL=0 SHARE_R2_DRY=1 SHARE_R2_DRY_DIR="$MX_DRY" CLOUDFLARE_API_TOKEN=admintoken bash "$SH" member ls --tenant mx.example.test 2>&1); rc=$?
check "mm OT-15, OT-06: --tenant on a machine with no profile reads the tenant (admin token from the environment)" "0 1" "$rc $(grep -c '^an: \|^no members on mx.example.test' <<<"$out")"
mx_fresh; : >"$MX_LOG"; out=$(mx_env=(SHARE_ERROR_JSON=1); mxa member ls 2>&1); rc=$?
check "mm TASK-1c1: a T1 tenant (no members:true) refuses tenant_not_t2 naming setup --members" "1 tenant_not_t2 1 0" "$rc $(mx_jcode "$out") $(grep -c -- '--members' <<<"$out") $(mx_writes)"

echo "=== members: the admin lease ==="
mx_load t2; mkdir -p "$MX_DRY/lock"
mx_lease "otherhost:4242:0badf00d" add m-bo-bbbbbbb2 3
out=$(mxa member ls 2>&1); rc=$?
mx_lease "otherhost:4242:0badf00d" add m-bo-bbbbbbb2 3
: >"$MX_LOG"; t0=$SECONDS; out=$(mx_env=(SHARE_ERROR_JSON=1); MX_LEASE_WAIT=1 mxa member add an --cloud 2>&1); rc=$?
check "mm CC-09: a live lease of another host makes add wait, then refuse lease_held naming the holder's verb, member and step" "1 lease_held 1 0" \
  "$rc $(mx_jcode "$out") $(grep -c '^share: lease held by otherhost:4242:0badf00d (add m-bo-bbbbbbb2, step 3) (live)' <<<"$out") $(grep -c '^PUT \(u\|i\)/' "$MX_LOG")"
mx_lease "otherhost:4242:0badf00d" add m-bo-bbbbbbb2 3 1000
out=$(SHARE_TEST_MEMBER_IDS=m-an-aaaaaaa1 SHARE_TEST_CODE=ABCDEFGHIJKLMNOPQRST mxa member add an --cloud 2>&1); rc=$?
check "mm CC-09: past LastModified + 900 s the lease is taken over, and the verb runs" "0 1 invited 0" \
  "$rc $(grep -c 'took over from otherhost:4242:0badf00d (add m-bo-bbbbbbb2, step 3) (stale since' <<<"$out") $(jq -r .status "$MX_DRY/u/m-an-aaaaaaa1.json") $([[ -e $MX_DRY/lock/admin ]] && echo 1 || echo 0)"
mx_load t2; mx_lease "otherhost:4242:0badf00d" add m-bo-bbbbbbb2 3 "" "$(( $(date +%s) - 86400 ))"
out=$(MX_LEASE_WAIT=1 mxa member add an --cloud 2>&1); rc=$?
mx_lease "otherhost:4242:0badf00d" add m-bo-bbbbbbb2 3 1000 "$(( $(date +%s) + 7200 ))"
out2=$(SHARE_TEST_MEMBER_IDS=m-an-aaaaaaa1 mxa member add an --cloud 2>&1); rc2=$?
check "mm CK-01: staleness reads LastModified, never the holder's clock (an old taken stays live, a future taken goes stale)" "1 0" "$rc $rc2"
mx_load t2; mkdir -p "$MX_DRY/lock"; printf '{"v":1,"holder":"otherhost:1:00000000","verb":"add","member":"m-x-00000000","step":1,"expires":9999999999}\n' >"$MX_DRY/lock/admin"; mx_aged 1000 "$MX_DRY/lock/admin"
out=$(SHARE_TEST_MEMBER_IDS=m-an-aaaaaaa1 mxa member add an --cloud 2>&1); rc=$?
check "mm FG-10: a forged lock/admin with a far expires is ignored; its age by LastModified wins" "0 1" "$rc $(grep -c 'took over' <<<"$out")"
mx_load t2; mx_lease "$mx_this:$(gw_dp() { sh -c 'exit 0' & local p=$!; wait "$p"; echo "$p"; }; gw_dp):abcdef01" add m-an-aaaaaaa1 4
out=$(SHARE_TEST_MEMBER_IDS=m-an-aaaaaaa1 mxa member add an --cloud 2>&1); rc=$?
check "mm DP-add-1: a same-host holder whose pid is dead is taken over at once" "0 1" "$rc $(grep -c 'took over from' <<<"$out")"
# CC-10: two takers of one stale lease: If-Match, one wins
mx_load t2; mx_lease "otherhost:4242:0badf00d" sync - 1 1000
( mx_env=(SHARE_R2_DRY_PAUSE="PUT lock/admin"); MX_LEASE_WAIT=1 mxa member sync >"$MX/cc10a.out" 2>&1 ) & pa=$!
mx_wait_paused
MX_LEASE_WAIT=1 mxo sync >"$MX/cc10b.out" 2>&1 & pb=$!
sleep 1; : >"$MX_DRY/.resume"; wait "$pa"; ra=$?; wait "$pb"; rb=$?; rm -f "$MX_DRY/.resume" "$MX_DRY/.paused"
check "mm CC-10: two takers of one stale lease: the If-Match lets one take it over; the held one re-reads and never takes it over" "0 1 0 0" \
  "$(grep -c 'took over' "$MX/cc10a.out") $(grep -c 'took over from otherhost' "$MX/cc10b.out") $ra $rb"
# CC-15: a holder that slept past 900 s loses the lease and dies lease_lost before its next Cloudflare call
mx_load t2
( mx_env=(SHARE_R2_DRY_PAUSE='API POST */cfd_tunnel' SHARE_ERROR_JSON=1); SHARE_TEST_MEMBER_IDS=m-an-aaaaaaa1 mxa member add an --port $((base + 371)) >"$MX/cc15a.out" 2>&1 ) & pa=$!
mx_wait_paused; mx_aged 1000 "$MX_DRY/lock/admin"
mxa member sync >"$MX/cc15b.out" 2>&1; rb=$?
: >"$MX/lock-before"; mx_lease "otherhost:7:12345678" sync - 2
: >"$MX_DRY/.resume"; wait "$pa"; ra=$?; rm -f "$MX_DRY/.resume" "$MX_DRY/.paused"
check "mm CC-15: the first holder resumes after a takeover and dies lease_lost before its next Cloudflare call; the second's lease stays" "1 lease_lost 0 0 otherhost:7:12345678" \
  "$ra $(mx_jcode "$(cat "$MX/cc15a.out")") $rb $(grep -c 'connectivity/directory/services$' "$MX_LOG") $(jq -r .holder "$MX_DRY/lock/admin")"
