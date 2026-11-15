# Verification: multi-member Share Bar

## Share Bar

### VoiceOver and keyboard checklist (TASK-4b22)

No live VoiceOver pass ran: this run was headless and the owner rule (DEC-84) bars input on the desktop. Each line below names the code that VoiceOver and the keyboard read, and the check that holds it. An owner pass with VoiceOver on remains open.

| Item | Where | Check |
|---|---|---|
| Row label is the name plus the meta line, one per `link_state` | `RowModel.accessibilityLabel` | `AppStateTests.testRowLabelsCarryTheNameAndTheMetaLineForEveryLinkState` |
| Row exposes every menu item as an action, plus More actions | `ListBody.swift` `accessibilityActions`, `RowAccessibility.actions` | `testRowsExposeTheMenuItemsAsAccessibilityActions` |
| Arrow Down twice moves by row id; focus survives a reorder | `RowFocus`, `PopoverStore.update` | `testFocusRestoresByIDAfterARefreshThatReordersRows`; scene `focus-third` |
| Shift-F10 and the ContextMenu key open the row menu | `PopoverController.handle(key:)` | scene `menu-shift-f10` |
| Status item label carries the count | `PopoverViewModel.statusItemLabel` | `testTheStatusItemLabelCarriesTheCount` |
| Footer toast is a live region (`updatesFrequently`), the All links toast too | `FooterBar.status`, `AllLinksView.footer` | AX trait in the views |
| Members rows: label is name, sub line, chip or presence, link count; Actions action | `MemberRowModel.accessibilityLabel` | `MembersModelTests` |
| All links rows: label is name, state word, owner, place, expiry, views | `AllLinksRow.accessibilityLabel` | `AllLinksModelTests` |
| Working line is a live region | `ListBody.swift` `footer-working` | AX trait in the view |
| Esc closes every sheet but progress; arrows move Settings tabs | `SettingsStore.escape`, `SettingsRootView` | settings-a checks |

Color is never the only signal: every state word, chip text and the Working line say it in words.

### Screens

Images, argv logs and parity sheets: `docs/verification/share-bar/settings-b/` (see `docs/verification/share-bar/settings-b.md`).
