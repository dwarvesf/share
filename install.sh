#!/bin/bash
# Install share: dependencies (Homebrew when present) plus a symlink on PATH.
#   ./install.sh                 required deps + symlink into ~/.local/bin
#   ./install.sh --with-extras   also pandoc (markdown rendering) and gh (private-repo warning)
#   PREFIX=/usr/local/bin ./install.sh
# The symlink points into this checkout, so `git pull` updates share in place.
set -euo pipefail

repo="$(cd "$(dirname "$0")" && pwd)"
bindir="${PREFIX:-$HOME/.local/bin}"
required="caddy cloudflared jq curl"
extras="pandoc gh"

missing=""
for c in $required; do command -v "$c" >/dev/null || missing="$missing $c"; done
if [[ ${1:-} == --with-extras ]]; then
  for c in $extras; do command -v "$c" >/dev/null || missing="$missing $c"; done
fi

if [[ -n $missing ]]; then
  if command -v brew >/dev/null; then
    echo "installing:$missing"
    # shellcheck disable=SC2086
    brew install $missing
  else
    echo "missing:$missing" >&2
    echo "install them with your package manager (cloudflared: https://pkg.cloudflare.com), then rerun" >&2
    exit 1
  fi
fi

mkdir -p "$bindir"
target="$bindir/share"
if [[ -e $target || -L $target ]] && [[ "$(readlink "$target" || true)" != "$repo/bin/share" ]]; then
  backup="$target.bak.$(date +%s)"
  mv -f "$target" "$backup"
  echo "moved the existing $target to $backup"
fi
ln -sfn "$repo/bin/share" "$target"
echo "linked $target -> $repo/bin/share"

case ":$PATH:" in
  *":$bindir:"*) ;;
  *) echo "note: $bindir is not on PATH; add it to your shell profile" ;;
esac
for c in $extras; do
  command -v "$c" >/dev/null || echo "optional: $c is not installed (./install.sh --with-extras)"
done
echo "next: share setup <hostname>   (a browser opens for the Cloudflare login)"
