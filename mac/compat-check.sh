#!/bin/bash
# compat-check.sh: does a shipped Share Bar still read what the new CLI prints?
#
# Usage: mac/compat-check.sh <release tag>     e.g. mac/compat-check.sh v0.9.0
#
# Builds the ShareBarCore sources of the tag in a temp package, then decodes every
# new-CLI fixture with them: each `profiles --json` fixture (the test fixtures and every
# scenario of the fake CLI) and each single `state` fixture. A fixture fails when the old
# decoder cannot read it, or when a profile it reports maps to Health.error (the shipped
# app's "Error:" or "Update Share Bar" text). A scenario with no profiles.json
# (cli-old, a TSV listing) is skipped on purpose: it stands for a CLI older than the tag.
# Exit 0 when every fixture reads clean.
set -euo pipefail

MAC_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$MAC_DIR/.." && pwd)"
TAG="${1:-}"
[[ -n $TAG ]] || { echo "usage: mac/compat-check.sh <release tag>" >&2; exit 2; }
git -C "$REPO_DIR" rev-parse --verify --quiet "$TAG^{commit}" >/dev/null || { echo "compat-check: no such tag: $TAG" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/compat-check.XXXXXX")"
cleanup() { mv "$WORK" "$WORK.gone.$$" 2>/dev/null || true; }
trap cleanup EXIT

mkdir -p "$WORK/Sources/Compat"
git -C "$REPO_DIR" archive "$TAG" mac/Sources/ShareBarCore | tar -x -C "$WORK"
mv "$WORK/mac/Sources/ShareBarCore" "$WORK/Sources/ShareBarCore"

cat > "$WORK/Package.swift" <<'SWIFT'
// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "Compat",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "ShareBarCore"),
        .executableTarget(name: "Compat", dependencies: ["ShareBarCore"]),
    ]
)
SWIFT

cat > "$WORK/Sources/Compat/main.swift" <<'SWIFT'
import Foundation
import ShareBarCore

// One argument per fixture file. A file with a top-level "profiles" array is a
// `profiles --json` output; any other JSON object is one profile's `state` output.
var failed = 0
for path in CommandLine.arguments.dropFirst() {
    guard let data = FileManager.default.contents(atPath: path), let text = String(data: data, encoding: .utf8) else {
        print("FAIL \(path): unreadable")
        failed += 1
        continue
    }
    var entries: [ProfileEntry] = []
    let isProfiles = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["profiles"] != nil
    if isProfiles {
        switch ProfilesSnapshot.from(CLIResult(status: 0, stdout: text, stderr: "", timedOut: false)) {
        case .success(let snapshot): entries = snapshot.profiles
        case .failure(let failure):
            print("FAIL \(path): profiles --json did not decode (\(failure))")
            failed += 1
            continue
        }
    } else {
        guard let state = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            print("FAIL \(path): state did not decode")
            failed += 1
            continue
        }
        entries = [ProfileEntry(name: "state", state: state, error: nil)]
    }
    var bad: [String] = []
    for entry in entries where Health.of(entry) == .error {
        bad.append("\(entry.name): \(Health.statusText(of: entry))")
    }
    if bad.isEmpty {
        print("ok   \(path) (\(entries.count) profile\(entries.count == 1 ? "" : "s"))")
    } else {
        print("FAIL \(path): \(bad.joined(separator: "; "))")
        failed += 1
    }
}
exit(failed == 0 ? 0 : 1)
SWIFT

FIXTURES=()
for f in "$MAC_DIR"/Tests/ShareBarCoreTests/Fixtures/{profiles,profiles-tenant,state,state-full}.json \
         "$MAC_DIR"/Tests/fixtures/scenarios/*/profiles.json; do
  [[ -f $f ]] && FIXTURES+=("$f")
done
[[ ${#FIXTURES[@]} -gt 0 ]] || { echo "compat-check: no fixtures found" >&2; exit 2; }

echo "== build ShareBarCore at $TAG"
swift build --package-path "$WORK" >"$WORK/build.log" 2>&1 || { cat "$WORK/build.log" >&2; echo "compat-check: the $TAG sources did not build" >&2; exit 1; }
BIN="$(swift build --package-path "$WORK" --show-bin-path)/Compat"

echo "== decode ${#FIXTURES[@]} fixtures with the $TAG decoder"
"$BIN" "${FIXTURES[@]}"
