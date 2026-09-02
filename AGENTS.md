# Repository Guidelines

## Start of Work

- Read `docs/MAP.md` to find the files a task touches, and `docs/TRAPS.md`
  before changing runtime or LuCI code. Read the sibling repository's
  `docs/TRAPS.md` too: both packages share a router and most of its entries
  apply here.
- Locate a function with `grep -n <name> docs/INDEX.md` rather than reading a
  file whole. `runtime/ikev2-site-link.sh` alone is 2666 lines.
- Read the `AGENTS.md` in the directory you are editing.
- Run `git status -sb` and preserve unrelated changes.

## Rules

- Keep the project independent from IKEv2 Manager package ownership.
- Reuse an existing IKEv2 Manager inbound server only through its documented
  user-management interface; do not edit its credential database directly.
- Router-side scripts must work with BusyBox ash and OpenWrt 25.12 utilities.
- Never restart WAN or reboot a router as part of apply, recovery, or tests.
- Treat secrets, router addresses, hostnames, and deployment state as private.
- Apply routing changes atomically and retain a fail-closed route whenever the
  site tunnel is unavailable.
- Run shell syntax, fixture, package-staging, and router health checks before
  deployment.

## Verification

- Run `./scripts/check.sh` before completion; it runs the contract assertions,
  the function index check and every test.
- Mutate a new check before trusting it: break what it guards, watch it fail,
  restore.
- Regenerate `docs/INDEX.md` with `scripts/gen-index.sh` when you add or rename
  a function in a file over 300 lines.
- Add to `docs/TRAPS.md` whenever a bug takes more than an hour to find.
