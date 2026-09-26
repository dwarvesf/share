# ADR-0003: the menu bar app reads state only through the CLI

Status: accepted
Date: 2026-09-27

## Context

A macOS menu bar app shows share's state and runs its actions. The state lives in files the CLI owns (`index.tsv`, `config`, `serve.pid`, `quick.url`, `access.log`). A share's link depends on its opts, the served tree, and the tunnel mode, which `share_url` in `bin/share` resolves.

## Decision

The app never reads share's files. It gets state from `share status --json`, a read-only snapshot with a `schema` integer, and changes state only by running CLI verbs (`add`, `rm`, `refresh`, `hits`, `start`, `stop`, `setup`). The serve daemon stays owned by share's own login service; the app neither starts it at login nor supervises it.

## Consequences

- Link logic exists once, in bash. A new share kind changes no Swift.
- The JSON is a public contract. Removing or renaming a field bumps `schema`; adding one does not.
- Each menu open spawns one bash process, a cost a menu opened by a click can carry.
- The app and CLI can be different versions; the app degrades on an unknown schema instead of failing.
