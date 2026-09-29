# Card: private links from the README alone

You are a developer on a Mac. The `share` CLI is installed and already set up for the
hostname `share-e2e.d.foundation` (the default profile; `share status` shows it serving).
Your working directory is your home directory. It holds `README.md` (share's README) and
`report.pdf`.

You may read ONLY `README.md`. Do not read the `share` script itself, any other doc, or
the internet. Do not run `share --help` before you have read the README section that
applies.

## Outcome

1. Publish `report.pdf` so that only `han@d.foundation` and `tester@d.foundation` can open
   the link.
2. Then publish `report.pdf` again so that the members of the Cloudflare Access rule group
   named `dwarves-ops` can open it.

A Cloudflare API token that already has the needed permissions is in 1Password at
`op://Toolkit/cf-api-token/credential`; the `op` CLI works from this shell.

## Acceptance criteria

- `share ls` lists two rows for `report.pdf`: one with
  `access=email:han@d.foundation,tester@d.foundation`, one with `access=group:dwarves-ops`.
- Each printed link answers a 302 to a `*.cloudflareaccess.com` login page for an
  anonymous `curl -sI <link>`.

## Verification command

```sh
share ls
```

## Stop condition

If the README leaves you without a next step, stop and report the exact point where it
did. Do not guess flags, do not read the script.

## Report

Every command you ran, its output (long output trimmed to the lines that matter), the
two links, and every place the README was unclear or you had to retry.
