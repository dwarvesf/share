#!/bin/bash
# release.sh: sign + notarize the menu bar app for a tag, upload the zip to
# that tag's GitHub release, then bump the homebrew-tools cask (and add a
# formula caveats line naming it) through a throwaway tap clone + PR, the
# same pattern bin/release uses for the formula bump. Idempotent: a rerun
# for the same tag force-updates an already-open cask PR branch instead of
# failing; if the cask is already merged for this tag, it is a no-op.
#
# bin/release calls this after its formula bump, on a Mac with the Developer
# ID signing identity. A notarization failure (build.sh dies and prints the
# notary log) skips the upload and the cask, and this script exits non-zero.
#
# Usage: mac/release.sh <tag>          (tag looks like v1.2.3)
# Env:
#   RELEASE_DRY=1   skip the build, the release wait/upload, and every tap
#                   write; print the cask (placeholder sha256), the formula
#                   caveats edit, and the upload command instead
#   NOTARY_KEY, NOTARY_KEY_ID, NOTARY_ISSUER
#                   App Store Connect API key auth for notarytool, passed
#                   through to build.sh (see mac/build.sh's header). When
#                   NOTARY_KEY is already set, this script leaves it alone.
#   NOTARY_KEY_OP   an op:// reference to the notary key's .p8 field. When
#                   NOTARY_KEY is unset and NOTARY_KEY_OP, NOTARY_KEY_ID,
#                   and NOTARY_ISSUER are all set, this script reads the
#                   key with `op read` into a mode-600 temp file, exports
#                   NOTARY_KEY to point at it for the build.sh call, and
#                   discards the file on exit. This is the mode an
#                   unattended release uses; leave NOTARY_KEY_OP unset to
#                   keep using the notarytool keychain profile instead.
set -euo pipefail

REPO="dwarvesf/share"
TAP_REPO="dwarvesf/homebrew-tools"
CASK_NAME="share-bar"
CASK_CAVEATS_LINE="Menu bar app: brew install --cask dwarvesf/tools/$CASK_NAME"

die() { echo "release.sh: $*" >&2; exit 1; }

TAG="${1:-}"
[[ -n "$TAG" ]] || die "usage: mac/release.sh <tag>"
VERSION="${TAG#v}"

MAC_DIR="$(cd "$(dirname "$0")" && pwd)"
DRY="${RELEASE_DRY:-0}"
ZIP_NAME="Share-Bar-$VERSION.zip"

KEYFILE=""
WORK=""
cleanup() {
  if [[ -n "$KEYFILE" && -f "$KEYFILE" ]]; then
    if command -v trash >/dev/null 2>&1; then
      trash "$KEYFILE" >/dev/null 2>&1 || true
    else
      local discard
      discard="$(mktemp -d)"
      mv "$KEYFILE" "$discard/" 2>/dev/null || true
    fi
  fi
  # An EXIT trap's own last exit status becomes the script's exit status, so
  # this must not end on a false test (e.g. WORK unset in the dry-run path).
  if [[ -n "$WORK" ]]; then
    rm -rf "$WORK"
  fi
  return 0
}
trap cleanup EXIT

# Fetches NOTARY_KEY from 1Password when asked (NOTARY_KEY unset, the other
# three set); otherwise a no-op, so build.sh falls back to the keychain
# profile exactly as before.
fetch_notary_key() {
  [[ -z "${NOTARY_KEY:-}" ]] || return 0
  [[ -n "${NOTARY_KEY_OP:-}" && -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER:-}" ]] || return 0

  if [[ "$DRY" == "1" ]]; then
    echo "would read notary key from $NOTARY_KEY_OP"
    return 0
  fi

  command -v op >/dev/null 2>&1 || die "op (1Password CLI) not found; needed to read NOTARY_KEY_OP"
  local keyfile
  keyfile="$(mktemp)"
  chmod 600 "$keyfile"
  KEYFILE="$keyfile"
  op read "$NOTARY_KEY_OP" >| "$keyfile" || die "op read failed for NOTARY_KEY_OP"
  [[ -s "$keyfile" ]] || die "op read returned an empty notary key for NOTARY_KEY_OP"
  export NOTARY_KEY="$keyfile"
}

cask_body() {
  cat <<RUBY
cask "$CASK_NAME" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/$REPO/releases/download/$TAG/$ZIP_NAME"
  name "Share Bar"
  desc "Menu bar app for share: live status, quick links, drag-to-publish"
  homepage "https://github.com/$REPO"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on formula: "dwarvesf/tools/share"
  depends_on macos: :ventura

  app "Share Bar.app"

  uninstall quit: "foundation.d.share.bar"

  zap trash: "~/Library/Preferences/foundation.d.share.bar.plist"
end
RUBY
}

# --- build, sign, notarize -----------------------------------------------------
fetch_notary_key

if [[ "$DRY" == "1" ]]; then
  echo "== build (skipped: RELEASE_DRY=1)"
  SHA="sha256-placeholder-dry-run-not-a-real-digest"
else
  echo "== build + sign + notarize"
  ZIP="$(bash "$MAC_DIR/build.sh" --sign --notarize "$VERSION" | tail -1)"
  [[ -f "$ZIP" ]] || die "build.sh did not report a zip path"
  ZIP_NAME="$(basename "$ZIP")"
  SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
fi

# --- wait for the GitHub release, then upload -----------------------------------
if [[ "$DRY" == "1" ]]; then
  echo "== upload (skipped: RELEASE_DRY=1)"
  echo "would run: gh release upload $TAG $ZIP_NAME --repo $REPO --clobber"
else
  echo "== wait for the $TAG release on $REPO"
  found=0 i=0
  while [[ $i -lt 30 ]]; do
    if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then found=1; break; fi
    sleep 10
    i=$((i + 1))
  done
  [[ $found -eq 1 ]] || die "no release $TAG on $REPO after 5 minutes (release.yml creates it asynchronously)"
  echo "== upload $ZIP_NAME"
  gh release upload "$TAG" "$ZIP" --repo "$REPO" --clobber
fi

# --- dry run: print the cask + caveats edit, stop ------------------------------
if [[ "$DRY" == "1" ]]; then
  echo "== Casks/$CASK_NAME.rb (placeholder sha256)"
  cask_body
  echo "== Formula/share.rb caveats addition (skipped when the line is already present)"
  echo "      $CASK_CAVEATS_LINE"
  echo "        Installs Share Bar, a menu bar app that shows shares and status."
  exit 0
fi

# --- tap: cask + formula caveats, through a throwaway clone --------------------
WORK="$(mktemp -d)"
BRANCH="chore/$CASK_NAME-$TAG"
git clone --quiet --depth 1 "https://github.com/$TAP_REPO.git" "$WORK/tap"

cask_body >"$WORK/tap/Casks/$CASK_NAME.rb"

FORMULA_FILE="$WORK/tap/Formula/share.rb"
if ! grep -qF "$CASK_CAVEATS_LINE" "$FORMULA_FILE"; then
  awk -v line="      $CASK_CAVEATS_LINE" '
    /Optional: brew install pandoc gh/ && !done {
      print line
      print "        Installs Share Bar, a menu bar app that shows shares and status."
      print ""
      done = 1
    }
    { print }
  ' "$FORMULA_FILE" >"$FORMULA_FILE.tmp"
  mv "$FORMULA_FILE.tmp" "$FORMULA_FILE"
fi

cd "$WORK/tap"
git checkout -q -b "$BRANCH"
git add "Casks/$CASK_NAME.rb" Formula/share.rb
if git diff --cached --quiet; then
  echo "cask already up to date for $TAG"
  exit 0
fi
git commit -q -m "feat: $CASK_NAME $VERSION"
git push -q -f "https://github.com/$TAP_REPO.git" "HEAD:$BRANCH"

pr="$(gh pr list --repo "$TAP_REPO" --head "$BRANCH" --state open --json url -q '.[0].url' 2>/dev/null || true)"
if [[ -z "$pr" ]]; then
  pr="$(gh pr create --repo "$TAP_REPO" --title "feat: $CASK_NAME $VERSION" \
        --head "$BRANCH" --body "Adds/bumps the $CASK_NAME cask for $TAG." 2>&1 | tail -1)"
  echo "cask PR: $pr"
else
  echo "cask PR (updated): $pr"
fi
gh pr merge --repo "$TAP_REPO" "$pr" --squash --delete-branch >/dev/null
echo "done: $CASK_NAME $VERSION"
