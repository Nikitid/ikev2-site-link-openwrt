# Runtime

POSIX shell running on the router as root. Read `../docs/TRAPS.md` and the
sibling repository's `docs/TRAPS.md` before changing anything here.

Locate a function with `grep -n <name> ../docs/INDEX.md`;
`ikev2-site-link.sh` is 2666 lines.

## Rules

- Target BusyBox applets, not coreutils. Verify an option on a router before
  relying on it.
- Never write `cmd && die '...'` under `set -eu`. The failure stops being
  fatal and the script continues into the branch it meant to refuse. Use
  `if ... then ... fi`.
- Keep pause and teardown separate. Pause stops traffic and leaves the
  profile, interface and policy in place; anything resume needs must survive.
- Reconcile `applied` with `enabled` when the operator changes intent, or the
  page reports a fault where the operator made a choice.
- Guard state the health watcher repairs, and put the guard ahead of the
  repair.
- Report through `key=value` lines on stdout. The pages parse them.
- Never tear down what this package did not create. The Manager shares this
  router's PBR, firewall and XFRM state.

## Adding a subcommand

1. Add the case to the dispatcher.
2. Grant it in `luci/acl.json`, or the page gets `Permission denied`. rpcd
   resolves a path before checking it, so a `/var/...` grant needs its
   `/tmp/...` twin.
3. Install it from **both** `scripts/stage-package.sh` and the `Makefile`.
4. Cover it in `scripts/test-*.sh` and mutate the test to prove it fails.
