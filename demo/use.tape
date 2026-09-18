# Story: share a folder, open it like a visitor, see who opened it, take it down.
# Record from the repo root after setup.tape: vhs demo/use.tape

Output demo/.frames/use/

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

Type "# a folder to share; the .env must stay private"
Enter
Type "ls -A team-guide"
Enter
Sleep 1.5s

Type "share add team-guide"
Enter
Wait@60s /^\$$/
Sleep 1.5s

Type `link=$(pbpaste)    # share add copied the link`
Enter
Type `curl -s -o /dev/null -w '%{http_code}\n' $link`
Enter
Wait@30s /^\$$/
Sleep 1s
Type `curl -s -o /dev/null -w '%{http_code}\n' ${link}.env    # dotfiles never ship`
Enter
Wait@30s /^\$$/
Sleep 1.5s

Type "share hits $link"
Enter
Wait@30s /^\$$/
Sleep 1.5s

Type "share rm $link"
Enter
Wait@30s /^\$$/
Type `curl -s -o /dev/null -w '%{http_code}\n' $link`
Enter
Wait@30s /^\$$/
Sleep 3s
