#!/bin/bash
# Run the CI "changes" step against fake diffs: bash .github/scripts/ci-changes-test.sh .github/workflows/ci.yml
set -u
yml="$1"
dir=$(mktemp -d)
python3 -c 'import sys,yaml; print(yaml.safe_load(open(sys.argv[1]))["jobs"]["changes"]["steps"][1]["run"])' "$yml" >"$dir/step.sh"

run_case() {  # expected-bash expected-mac files...
  local eb="$1" em="$2"; shift 2
  local out="$dir/out.$RANDOM$RANDOM"
  printf '%s\n' "$@" >"$dir/files.$$"
  GITHUB_OUTPUT="$out" FILES="$dir/files.$$" bash -c 'git() { cat "$FILES"; }; '"$(cat "$dir/step.sh")" >/dev/null
  local got; got=$(tr '\n' ' ' <"$out")
  local want="bash=$eb mac=$em "
  if [ "$got" = "$want" ]; then echo "ok    [$*] -> $got"; else echo "FAIL  [$*] want '$want' got '$got'"; fi
  rm -f "$dir/files.$$"
}

run_case false true  mac/Sources/ShareBar/App.swift docs/verification/share-bar/x.md
run_case false true  mac/Tests/A.swift docs/implementation-notes/share-bar.md
run_case true  false bin/handout tests/members.sh
run_case true  true  mac/Sources/ShareBarCore/CLI.swift
run_case true  true  mac/a.swift bin/handout
run_case true  true  .github/workflows/ci.yml
run_case true  false docs/how-it-works.md
run_case true  false docs/verification/members-core.md

out="$dir/out.fail"
GITHUB_OUTPUT="$out" bash -c 'git() { return 128; }; '"$(cat "$dir/step.sh")" >/dev/null
[ "$(tr '\n' ' ' <"$out")" = "bash=true mac=true " ] && echo "ok    [git diff fails] -> run all" || echo "FAIL  [git diff fails] -> $(cat "$out")"
out="$dir/out.empty"
GITHUB_OUTPUT="$out" bash -c 'git() { :; }; '"$(cat "$dir/step.sh")" >/dev/null
[ "$(tr '\n' ' ' <"$out")" = "bash=true mac=true " ] && echo "ok    [empty diff] -> run all" || echo "FAIL  [empty diff] -> $(cat "$out")"
