#!/bin/bash
# Install handout: dependencies (Homebrew when present) plus handout on PATH, and share as its alias.
#   ./install.sh                 required deps + symlinks into ~/.local/bin
#   ./install.sh --with-extras   also pandoc (markdown rendering) and gh (private-repo warning)
#   PREFIX=/usr/local/bin ./install.sh
#   curl -fsSL https://raw.githubusercontent.com/consolelabs/handout/main/install.sh | bash
# In a checkout the symlink points into it, so `git pull` updates handout in place.
# Piped over curl there is no checkout: bin/handout is downloaded into the bindir.
# Either way a `share` symlink next to handout keeps the old command name working.
set -euo pipefail

repo="$(cd "$(dirname "$0")" && pwd)"
bindir="${PREFIX:-$HOME/.local/bin}"
raw="${SHARE_RAW_URL:-https://raw.githubusercontent.com/consolelabs/handout/main/bin/handout}"
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

backup_unless() { # backup_unless <path> <link target>...: move <path> aside unless it is a symlink to one of the targets
  local p=$1 cur t backup; shift
  [[ -e $p || -L $p ]] || return 0
  cur="$(readlink "$p" || true)"
  for t in "$@"; do [[ $cur != "$t" ]] || return 0; done
  backup="$p.bak.$(date +%s)"
  mv -f "$p" "$backup"
  echo "moved the existing $p to $backup"
}

mkdir -p "$bindir"
target="$bindir/handout"
alias_link="$bindir/share"
if [[ -f $repo/bin/handout ]]; then
  backup_unless "$target" "$repo/bin/handout"
  ln -sfn "$repo/bin/handout" "$target"
  echo "linked $target -> $repo/bin/handout"
else
  curl -fsSL "$raw" -o "$target"
  chmod +x "$target"
  echo "installed $target"
fi
backup_unless "$alias_link" handout "$repo/bin/share"   # an older checkout install linked share into the repo
ln -sfn handout "$alias_link"
echo "linked $alias_link -> handout (the old command name)"

case ":$PATH:" in
  *":$bindir:"*) ;;
  *) echo "note: $bindir is not on PATH; add it to your shell profile" ;;
esac
for c in $extras; do
  command -v "$c" >/dev/null || echo "optional: $c is not installed (./install.sh --with-extras)"
done
echo "next: handout setup <hostname>   (a browser opens for the Cloudflare login)"
