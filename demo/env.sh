# Hidden prelude for the demo tapes: a clean prompt, Homebrew's handout first on
# PATH (or HANDOUT_DEMO_BIN, a checkout's bin/, to record unreleased code), and a
# config, root, port, and service label of its own, so a recording never touches a
# real handout setup on the same machine.
export PS1='$ ' BASH_SILENCE_DEPRECATION_WARNING=1
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_INSTALL_CLEANUP=1
export PATH="${HANDOUT_DEMO_BIN:+$HANDOUT_DEMO_BIN:}/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export SHARE_CONFIG_DIR=/private/tmp/handout-demo/.cfg SHARE_ROOT=/private/tmp/handout-demo/.root
export SHARE_PORT=8795 SHARE_SERVICE_LABEL=handout-demo

demo_src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p /private/tmp/handout-demo
[[ -d /private/tmp/handout-demo/team-guide ]] || cp -R "$demo_src/team-guide" /private/tmp/handout-demo/
printf 'DEMO_SECRET=never-published\n' >|/private/tmp/handout-demo/team-guide/.env
cd /private/tmp/handout-demo || return
