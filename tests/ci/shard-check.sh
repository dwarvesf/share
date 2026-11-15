#!/usr/bin/env bash
# Every section of the suite runs in exactly one CI shard. Exit 0 when true, 1 with the offenders listed, 2 on a bad shard file.
# SHARD_CHECK_ROOT overrides the repo root (the negative-control test points it at a copy).
set -u
root="${SHARD_CHECK_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
shards="$root/tests/ci/shards.txt"
files=("$root/tests/share.sh" "$root/tests/members.sh")

# Section names that need a shard: every `section "<name>"`; `section_always` runs in every shard.
names=()
while IFS= read -r n; do names+=("$n"); done < <(grep -hE '^(if )?section "' "${files[@]}" | sed -E 's/^(if )?section "(.*)"(; then)?$/\2/')
[[ ${#names[@]} -gt 0 ]] || { echo "shard-check: no sections found in $root/tests" >&2; exit 2; }

gname=(); gre=(); gpull=()
while IFS= read -r line; do
  n="${line#\# group }"; n="${n%% = *}"
  gname+=("$n"); gre+=("${line#* = }"); gpull+=("")
done < <(grep -E '^# group [a-z0-9-]+ = ' "$root/tests/share.sh")
while IFS= read -r line; do
  n="${line#\# pull }"; n="${n%% -> *}"
  for i in "${!gname[@]}"; do [[ ${gname[i]} == "$n" ]] && gpull[i]="${line#* -> }"; done
done < <(grep -E '^# pull [a-z0-9-]+ -> ' "$root/tests/share.sh")

bad=0; sname=(); sre=()
while IFS=$'\t' read -r n re; do
  [[ -z $n || $n == \#* ]] && continue
  [[ -n $re ]] || { echo "shard-check: shard $n has no regex" >&2; exit 2; }
  [[ x =~ $re ]]; [[ $? == 2 ]] && { echo "shard-check: shard $n has an invalid regex: $re" >&2; exit 2; }
  sname+=("$n"); sre+=("$re")
done <"$shards"
[[ ${#sname[@]} -gt 0 ]] || { echo "shard-check: no shards in $shards" >&2; exit 2; }

# effective[k] = newline-joined regexes that shard k runs: its own plus every group it names or is pulled into
declare -a eff
for k in "${!sname[@]}"; do
  on=(); for i in "${!gname[@]}"; do on[i]=0; done
  for i in "${!gname[@]}"; do
    for n in "${names[@]}"; do
      [[ $n =~ ${gre[i]} && $n =~ ${sre[k]} ]] && { on[i]=1; break; }
    done
  done
  changed=1
  while [[ $changed == 1 ]]; do
    changed=0
    for i in "${!gname[@]}"; do
      [[ ${on[i]} == 1 && -n ${gpull[i]} ]] || continue
      for t in ${gpull[i]}; do
        for j in "${!gname[@]}"; do [[ ${gname[j]} == "$t" && ${on[j]} == 0 ]] && { on[j]=1; changed=1; }; done
      done
    done
  done
  e="${sre[k]}"; for i in "${!gname[@]}"; do [[ ${on[i]} == 1 ]] && e="$e"$'\n'"${gre[i]}"; done
  eff[k]="$e"
done

for n in "${names[@]}"; do
  hit=()
  for k in "${!sname[@]}"; do
    while IFS= read -r re; do
      [[ -n $re && $n =~ $re ]] && { hit+=("${sname[k]}"); break; }
    done <<<"${eff[k]}"
  done
  if [[ ${#hit[@]} == 0 ]]; then echo "shard-check: no shard runs section: $n"; bad=1
  elif [[ ${#hit[@]} -gt 1 ]]; then echo "shard-check: ${#hit[@]} shards run section: $n (${hit[*]})"; bad=1; fi
done
for k in "${!sname[@]}"; do
  any=0; for n in "${names[@]}"; do [[ $n =~ ${sre[k]} ]] && { any=1; break; }; done
  [[ $any == 1 ]] || { echo "shard-check: shard ${sname[k]} names no section"; bad=1; }
done
[[ $bad == 0 ]] && echo "shard-check: ${#names[@]} sections, ${#sname[@]} shards, each section in exactly one"
exit "$bad"
