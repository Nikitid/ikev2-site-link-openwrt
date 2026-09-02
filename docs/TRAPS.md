# Traps

Failures that looked like something else and cost hours. Each is here because
the obvious reading of the evidence was wrong, and because nothing in the code
makes the real rule visible at the point where you would break it.

Where a check now guards a trap, it is named. Add to this file whenever a bug
takes more than an hour to locate.

The sibling repository has its own `docs/TRAPS.md`, and most of it applies here
too - both packages are POSIX shell on BusyBox behind LuCI pages on the same
router. Read that one as well before changing runtime or UI code.

## Pausing is not tearing down

Pause has to stop carrying traffic while leaving the link's identity intact:
the profile, the interface, the policy. An implementation that reuses the
teardown path looks correct in a test and destroys the configuration in
production, because the state it removes is the state resume needs.

`pause_impl` and `resume_impl` exist for exactly this. `scripts/check.sh`
asserts that pause calls none of the teardown functions.

## The health watcher will undo a pause

The watcher repairs what looks broken on its own schedule, and a paused link
looks broken. The guard has to sit **ahead** of the repair, not after it, or
the pause is reverted within seconds and the failure seems to come from
nowhere. The same trap exists in the Manager's watcher.

## `applied` and `enabled` drift apart

`enabled` is what the operator asked for; `applied` is what the runtime last
successfully put in place. When the operator disables the link and nothing
reconciles `applied`, status reports `degraded` - which reads as a fault -
instead of `disabled`. Any state the page shows has to be derived from both,
and a disable has to reconcile, not just flip a flag.

## `set -eu` turns `cmd && die` into a silent pass

Under `set -e`, a command joined with `&&` is part of a compound expression, so
its non-zero exit stops being fatal. `link_paused && die '...'` therefore does
nothing when `link_paused` returns false, and the script continues into the
branch it was supposed to refuse. Write these as `if ... then ... fi`.

## The PBR snapshot must not restore FakeIP addresses

The Manager hands out FakeIP addresses from `198.18.0.0/15`. They are valid
only while its sing-box runtime is up, so restoring them from a PBR snapshot
points traffic at addresses that mean nothing. `runtime/pbr.user.site-link`
filters them out with `grep -Ev '^198\.(18|19)\.'`; the check pins that filter.

## Policy destinations must not overlap the Manager's

Both packages write routing policy on the same router. A destination claimed by
both gets whichever rule loads last, which changes between boots. The policy
helper refuses a policy whose domains appear in the Manager's
`/etc/pbr-ikev2-domains.txt` - see `manager_domains_file`.

## A check pinned to an exact line breaks on reformatting

Several assertions in `check.sh` used to compare a literal line from the
runtime. Reformatting a dispatcher broke the check while the behaviour was
untouched, which teaches whoever hits it to edit the check rather than look at
the code. Assert the invariant instead.

## The LuCI resources here carry no version - live issue

`overview.js`, `policy.js` and `shared.js` install under names that never
change. LuCI's cache key does not move when the package is upgraded, so a
browser can serve the previous page after an install - and, worse, new page
code against cached stylesheet rules.

The Manager hit this and fixed it with `-vN` suffixes plus deletion of the
superseded names on install. **This repository has not been fixed yet.** Until
it is, a page change may need a hard reload to be visible, and "the change did
not apply" is more likely to be the cache than the code.
