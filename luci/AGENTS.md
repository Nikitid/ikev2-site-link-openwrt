# LuCI pages

Two views on a shared design system in `shared.js`. Read `../docs/TRAPS.md`
first, and the sibling repository's - the Manager hit most of these earlier.

## Rules

- Grant every helper call and input-file write in `acl.json`. rpcd resolves a
  path before checking it, so a `/var/...` grant needs its `/tmp/...` twin.
- Never assign `window._`. Each resource shadows the translator locally, or
  the dictionary leaks into every other LuCI application.
- Add a Russian entry to the `ru` dictionary in `shared.js` for every new
  string, including labels that reach `_()` through a variable.
- Run actions through the shared action lifecycle so the busy state, the
  spinner and the inline result are handled in one place.
- Report failures in the section's own inline result, never a global
  notification.
- Scope component CSS as `.ikev2-page .ikev2-thing`. A bare class loses to the
  page-wide control rules, and an override must come after what it narrows.
- Keep the destructive action honest: "Remove link" removes, "Pause" pauses.
  A control named for the wrong verb is how configuration gets destroyed.

## Before you call it done

Render it. `scripts/test-overview-ui.sh` and `test-policy-ui.sh` stub LuCI and
call `render()`; a page that parses can still die there. Add a contract
assertion for whatever you just fixed, then break it deliberately and confirm
the check fails.

Note: these resources carry no version suffix yet, so a change may need a hard
reload to appear. See `../docs/TRAPS.md`.
