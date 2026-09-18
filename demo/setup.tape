# Story: install share and set up a hostname, from nothing to a live link.
# Record from the repo root: vhs demo/setup.tape
# Needs a Cloudflare domain and CLOUDFLARE_API_TOKEN in the environment
# (without it, setup opens the browser login instead). Clean up after:
#   source demo/env.sh && share teardown --yes && brew uninstall share

Output demo/.frames/setup/

Set Shell "bash"
Set FontFamily "Lilex"
Set FontSize 16
Set Width 1200
Set Height 660
Set TypingSpeed 35ms
Set Theme { "name": "zed-onedark", "background": "#282c34", "foreground": "#abb2bf", "cursor": "#abb2bf", "selection": "#3e4451", "black": "#282c34", "red": "#e06c75", "green": "#98c379", "yellow": "#e5c07b", "blue": "#61afef", "purple": "#c678dd", "cyan": "#56b6c2", "white": "#abb2bf", "brightBlack": "#636d83", "brightRed": "#ea858b", "brightGreen": "#aad581", "brightYellow": "#ffd885", "brightBlue": "#85c1ff", "brightPurple": "#d398eb", "brightCyan": "#6ed5de", "brightWhite": "#fafafa" }

Hide
Type "source demo/env.sh && clear"
Enter
Sleep 1s
Show

Type "# 1. install: pulls in caddy, cloudflared, and jq"
Enter
Type "brew install dwarvesf/tools/share"
Sleep 400ms
Enter
Wait@180s /^\$$/
Sleep 2s

Hide
Type "clear"
Enter
Sleep 300ms
Show

Type "# 2. one-time setup: tunnel, DNS, login service, live check"
Enter
Type "share setup share-demo.han.ws"
Sleep 400ms
Enter
Wait@180s /^\$$/
Sleep 4s
