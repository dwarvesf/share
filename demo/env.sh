# Hidden prelude for the demo tapes: a clean prompt, Homebrew's share first on
# PATH, and a config, root, port, and service label of its own, so a recording
# never touches a real share setup on the same machine.
export PS1='$ ' BASH_SILENCE_DEPRECATION_WARNING=1
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_INSTALL_CLEANUP=1
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export SHARE_CONFIG_DIR=/private/tmp/share-demo/.cfg SHARE_ROOT=/private/tmp/share-demo/.root
export SHARE_PORT=8795 SHARE_SERVICE_LABEL=foundation.d.share-demo

demo_src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p /private/tmp/share-demo
[[ -d /private/tmp/share-demo/team-guide ]] || cp -R "$demo_src/team-guide" /private/tmp/share-demo/
printf 'DEMO_SECRET=never-published\n' >|/private/tmp/share-demo/team-guide/.env
cd /private/tmp/share-demo || return
