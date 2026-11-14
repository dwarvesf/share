# SG-10 Share Bar settings and flows (SPEC-009 TASK-4b14 to 4b23)
Model: opus
Effort: high
**Branch:** feat/sharebar-settings
Design: bearing
Done-mode: proof
Wall budget: 600 min
Port base: 33000

## Done =
SPEC-009 TASK-4b14 to 4b23 pass their AC, including the Minter key source in Advanced (D5) and the D4 rule: the Share Bar never offers Clean up from inference. The same screenshot bar as SG-09: every AC screen through real interactions, light, dark and narrow, self-scored against revision 8 and the interactions doc, fixed until clean, compared with Mobbin references, recorded in `docs/verification/share-bar/settings.md`. The fake CLI's `argv.log` matches the interactions doc command for every action an AC names. The VoiceOver and keyboard checklist (TASK-4b22) is run and recorded in `docs/verification/multi-member.md` under a Share Bar section. swift build, test, `mac/build.sh 0.0.0` and `mac/compat-check.sh v0.9.0` pass.

## Touches
mac/**
docs/verification/share-bar/**
docs/implementation-notes/share-bar.md
