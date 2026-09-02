# Repository map

Where things live, so a task starts at the right file instead of a search.
Pair it with `docs/INDEX.md`, which locates a function by name.

## The shape of it

One OpenWrt package, `luci-app-ikev2-site-link`: a site-to-site IKEv2 link
between two routers, with its own policy routing for the traffic that crosses
it. It ships and releases independently of `ikev2-openwrt`, but shares a router
with it - see the ownership note below.

A link has a **role**: `exit` publishes the far side's route out, `source`
sends selected traffic into it.

## Runtime

Installed to `/usr/libexec`, driven by the procd init script and by the LuCI
pages through the rpcd ACL in `luci/acl.json`.

| helper | source | owns |
| --- | --- | --- |
| `ikev2-site-link` | `runtime/ikev2-site-link.sh` | the link itself: swanctl profile, XFRM interface, firewall, state and status |
| `ikev2-site-link-policy` | `runtime/ikev2-site-link-policy.sh` | which destinations cross the link |
| `ikev2-site-link-policy-reload` | `runtime/ikev2-site-link-policy-reload.sh` | reapplying policy without touching the tunnel |
| `ikev2-site-link.d/actions.sh` | `runtime/lib/actions.sh` | the detached action and status-file plumbing |

`runtime/ikev2-site-link.init` is the procd service.
`runtime/pbr.user.site-link` hooks the link into PBR.
`runtime/90-ikev2-site-link` is the hotplug entry.

## LuCI pages

| page | source | installed as |
| --- | --- | --- |
| Overview | `luci/overview.js` | `view/ikev2-site-link/overview.js` |
| Policy | `luci/policy.js` | `view/ikev2-site-link/policy.js` |

`luci/shared.js` is the design system and the Russian dictionary.
`luci/menu.json` wires the pages, `acl.json` grants every helper call.

Note: these resource names carry no version suffix. See `docs/TRAPS.md`.

## Policy data

- `policy/services/*.lst` - packaged destination lists
- `policy/community-services` - the catalogue the Policy page offers

## Checks

`scripts/check.sh` runs everything: its own inline contract assertions first,
then `check-index.sh`, `test-runtime.sh`, `test-package-lifecycle.sh`,
`test-policy.sh` and `test-recovery.sh`. The UI harnesses
(`test-overview-ui.sh`, `test-policy-ui.sh`, `test-translations.sh`) stub LuCI
and actually render the pages.

## Build and release

`release.env` holds package identity; the SDK `Makefile` repeats the literals
and `check-version-sync.sh` fails on drift. `scripts/build-apk.sh` builds the
signed APK through `stage-package.sh`. The release workflow publishes it, and
`Nikitid/openwrt-feed` collects it into the shared feed.

## Shared ownership with ikev2-openwrt

Both packages live on the same router and both touch PBR, firewall and XFRM.
The contract is that each keeps its own last applied state and neither tears
down what it did not create. When changing anything that writes routing rules,
check the sibling repository for the other half of the contract.
