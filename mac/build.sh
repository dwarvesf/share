#!/bin/bash
# build.sh: build the universal ShareBar executable, assemble it into
# "Share Bar.app", sign it (ad-hoc, or Developer ID with --sign), optionally
# notarize and staple with --notarize, then zip. Last stdout line is the zip
# path.
#
# Preconditions (checked, not created) when --sign or --notarize is given:
#   - the Developer ID Application identity for TEAM_ID in the login keychain
#   - notarytool auth: either a keychain profile
#     (xcrun notarytool store-credentials <name>), or NOTARY_KEY +
#     NOTARY_KEY_ID + NOTARY_ISSUER (an App Store Connect API key, its key ID,
#     and its issuer ID) when the profile can't be stored headlessly
#
# Env (defaults shown):
#   TEAM_ID=W777S7V8TN
#   SIGN_ID="Developer ID Application: Dwarves Foundation Company Limited ($TEAM_ID)"
#   NOTARY_PROFILE=DWARVES_NOTARY
#   NOTARY_KEY=       path to an App Store Connect API key .p8 file
#   NOTARY_KEY_ID=    that key's ID
#   NOTARY_ISSUER=    that key's issuer ID
#   When NOTARY_KEY, NOTARY_KEY_ID, and NOTARY_ISSUER are all set, notarytool
#   authenticates with them instead of NOTARY_PROFILE.
#
# Usage: mac/build.sh [--sign] [--notarize] <version>
set -euo pipefail

TEAM_ID="${TEAM_ID:-W777S7V8TN}"
SIGN_ID="${SIGN_ID:-Developer ID Application: Dwarves Foundation Company Limited ($TEAM_ID)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-DWARVES_NOTARY}"
NOTARY_KEY="${NOTARY_KEY:-}"
NOTARY_KEY_ID="${NOTARY_KEY_ID:-}"
NOTARY_ISSUER="${NOTARY_ISSUER:-}"

NOTARY_KEY_MODE=0
if [[ -n "$NOTARY_KEY" && -n "$NOTARY_KEY_ID" && -n "$NOTARY_ISSUER" ]]; then
  NOTARY_KEY_MODE=1
  NOTARY_AUTH_ARGS=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
else
  NOTARY_AUTH_ARGS=(--keychain-profile "$NOTARY_PROFILE")
fi

MAC_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Share Bar.app"

die() { echo "build.sh: $*" >&2; exit 1; }
# Capture, then match: `cmd | grep -q` under pipefail fails when grep exits
# early and the writer takes SIGPIPE, which reads as a failed check on a
# passing result.
has() { printf '%s' "$1" | grep -qF -- "$2"; }

SIGN=0
NOTARIZE=0
VERSION=""
for arg in "$@"; do
  case "$arg" in
    --sign) SIGN=1 ;;
    --notarize) NOTARIZE=1 ;;
    --*) die "unknown flag: $arg" ;;
    *) VERSION="$arg" ;;
  esac
done
[[ -n "$VERSION" ]] || die "usage: mac/build.sh [--sign] [--notarize] <version>"

# --- preconditions ---------------------------------------------------------
if [[ $SIGN -eq 1 || $NOTARIZE -eq 1 ]]; then
  has "$(security find-identity -v -p codesigning)" "\"$SIGN_ID\"" \
    || die "signing identity missing: $SIGN_ID"
fi
if [[ $NOTARIZE -eq 1 ]]; then
  if [[ $NOTARY_KEY_MODE -eq 1 ]]; then
    [[ -f "$NOTARY_KEY" ]] || die "NOTARY_KEY not found: $NOTARY_KEY"
    [[ -r "$NOTARY_KEY" ]] || die "NOTARY_KEY not readable: $NOTARY_KEY"
    xcrun notarytool history "${NOTARY_AUTH_ARGS[@]}" >/dev/null 2>&1 \
      || die "notarytool rejected NOTARY_KEY_ID/NOTARY_ISSUER (or the key at NOTARY_KEY)"
  else
    xcrun notarytool history "${NOTARY_AUTH_ARGS[@]}" >/dev/null 2>&1 \
      || die "notarytool profile '$NOTARY_PROFILE' missing; run: xcrun notarytool store-credentials $NOTARY_PROFILE"
  fi
fi

# --- build -------------------------------------------------------------------
echo "== build (universal release)"
swift build -c release --arch arm64 --arch x86_64 --package-path "$MAC_DIR"
BIN_PATH="$(swift build -c release --arch arm64 --arch x86_64 --package-path "$MAC_DIR" --show-bin-path)"
[[ -x "$BIN_PATH/ShareBar" ]] || die "build did not produce $BIN_PATH/ShareBar"

# --- bundle assembly ---------------------------------------------------------
echo "== assemble $APP_NAME"
APP="$MAC_DIR/build/$APP_NAME"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/ShareBar" "$APP/Contents/MacOS/ShareBar"
cp "$MAC_DIR/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleShortVersionString $VERSION" \
  -c "Set :CFBundleVersion $VERSION" \
  "$APP/Contents/Info.plist"

# --- sign --------------------------------------------------------------------
if [[ $SIGN -eq 1 ]]; then
  echo "== sign ($SIGN_ID)"
  codesign --force --sign "$SIGN_ID" --options runtime --timestamp "$APP"
  has "$(codesign -dvv "$APP" 2>&1)" "Authority=Developer ID Application" \
    || die "app is not signed with a Developer ID Application identity"
else
  echo "== sign (ad-hoc)"
  codesign --force --sign - "$APP"
fi

# --- notarize + staple ---------------------------------------------------------
if [[ $NOTARIZE -eq 1 ]]; then
  echo "== notarize"
  SUBMIT_ZIP="$MAC_DIR/build/submit.zip"
  ditto -c -k --keepParent "$APP" "$SUBMIT_ZIP"
  RESULT="$(xcrun notarytool submit "$SUBMIT_ZIP" "${NOTARY_AUTH_ARGS[@]}" \
    --wait --output-format json)"
  STATUS="$(printf '%s' "$RESULT" | /usr/bin/plutil -extract status raw -o - - 2>/dev/null || true)"
  if [[ "$STATUS" != "Accepted" ]]; then
    SUB_ID="$(printf '%s' "$RESULT" | /usr/bin/plutil -extract id raw -o - - 2>/dev/null || true)"
    if [[ -n "$SUB_ID" ]]; then
      xcrun notarytool log "$SUB_ID" "${NOTARY_AUTH_ARGS[@]}" >&2 || true
    fi
    die "notarization status: ${STATUS:-unknown}"
  fi
  rm -f "$SUBMIT_ZIP"
  xcrun stapler staple "$APP"
  has "$(spctl -a -vv -t exec "$APP" 2>&1 || true)" "source=Notarized Developer ID" \
    || die "Gatekeeper does not accept the stapled app"
fi

# --- zip -----------------------------------------------------------------------
echo "== zip"
ZIP="$MAC_DIR/build/Share-Bar-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "$ZIP"
