# IKEv2 Site Link for OpenWrt

[Русский](README.ru.md)

[![CI](https://github.com/Nikitid/luci-app-ikev2-site-link/actions/workflows/ci.yml/badge.svg)](https://github.com/Nikitid/luci-app-ikev2-site-link/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/Nikitid/luci-app-ikev2-site-link)](https://github.com/Nikitid/luci-app-ikev2-site-link/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

The `luci-app-ikev2-site-link` package is a LuCI application that sends selected
services and addresses from one OpenWrt router out through another over IKEv2.
The original case: YouTube traffic from an office router leaves through a home
router, which keeps applying its usual DPI-circumvention strategy to it.

## Features

- one package, two roles - `source` and `exit` - chosen in the settings;
- fail-closed: while the tunnel is down, selected traffic never falls back to
  the plain WAN;
- services and addresses are chosen on the **Policy Routing** page, applied
  atomically with a checked PBR reload;
- a reversible pause that keeps the verified configuration, and a full
  disable;
- shared-secret rotation during which the exit keeps its established SA;
- works on its own, without the IKEv2 Manager package.

## Requirements

- OpenWrt `25.12.5`, `mediatek/filogic`, `aarch64_cortex-a53` - as for the rest
  of the feed;
- `pbr` with strict enforcement, and on the `source` side the
  `dnsmasq.nftset` resolver;
- the same `ike_port` on both routers (UDP/1500 by default);
- a dedicated `/32` tunnel address that overlaps neither the LAN nor a VPN pool.

## Installation

The package is published through the shared signed feed: one trust anchor and
one feed entry for every Nikitid OpenWrt application.

```sh
wget -O /tmp/nikitid-feed.sh \
  https://raw.githubusercontent.com/Nikitid/openwrt-feed/feed/install.sh
sh /tmp/nikitid-feed.sh luci-app-ikev2-site-link
```

If the router already trusts the feed, a scoped upgrade is enough. The whole
router is never upgraded:

```sh
apk update
apk upgrade luci-app-ikev2-site-link
```

## Two roles

- **`source`** - the side that hands traffic to the tunnel. It owns the
  outbound connection, a dedicated PBR interface, SNAT and a fail-closed
  routing table: while the tunnel is down the selected traffic does not fall
  back to the ordinary WAN, it hits an unreachable route.
- **`exit`** - the side that puts traffic on the internet. It runs its own
  strongSwan responder with exact identity matching, its own XFRM interface and
  a single-address pool. Its firewall zone can forward only to the ordinary
  WAN - not to the router, not to the LAN.

Both roles ship in one package; the role is chosen in the settings.

Why it is built this way, what the runtime guarantees and where the ownership
boundaries run: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Relation to IKEv2 Manager

There is no package dependency on IKEv2 Manager: Site Link installs and runs on
its own. It reuses only two certificate files on the exit side
(`/etc/swanctl/x509/ikev2.pem` and `/etc/swanctl/private/ikev2.key`), which
Manager normally maintains. Without it, an administrator maintains their
lifecycle.

Site Link checks the global PBR and DNS contract and reports a mismatch, but
never takes ownership of it.

## Commands

```sh
/usr/libexec/ikev2-site-link status
/usr/libexec/ikev2-site-link check
/usr/libexec/ikev2-site-link apply
/usr/libexec/ikev2-site-link connect
/usr/libexec/ikev2-site-link disable
/usr/libexec/ikev2-site-link secret-activate
/usr/libexec/ikev2-site-link secret-rollback
```

Link configuration lives in `/etc/config/ikev2-site-link`. Policy state, manual
destinations, service selection, caches and administrator-created service
definitions are under `/etc/ikev2-site-link/`. The **Policy Routing** page
updates them atomically and performs a checked PBR reload under the shared
network action lock. On an exit router the same catalogue is visible but
read-only.

## Pause and disable

**Pause** is reversible: it terminates the SAs, stops the monitor and clears
PBR's own enable flag on the site-link policy, so selected traffic returns to
this router's WAN instead of the fail-closed route. The applied snapshot, the
generated network and firewall sections, the XFRM device and the peer secret
are all retained, so Resume restores a configuration that was already verified,
with no form input.

**Disable** is a complete role-independent teardown: both profiles, the SAs,
the XFRM devices, the policy rules and the cached DNS-set state. The monitor
performs no repair while the link is paused, and Apply clears the pause.

## Secret rotation

Rotation is a deliberate two-router operator action, not a pairing protocol.
Stage the same value on both, activate the exit, then activate the source. The
exit keeps its established SA through the handoff. If source authentication
fails it restores its own previous secret - the exit then needs
`secret-rollback` run by hand.

## Development

```sh
./scripts/check.sh
```

Building, signing and releasing: [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## Documentation

- [Repository map](docs/MAP.md) - where things live
- [Traps](docs/TRAPS.md) - failures that already cost hours
- [Architecture](docs/ARCHITECTURE.md)
- [Development](docs/DEVELOPMENT.md) - building, signing and releasing

## Support

Questions and bug reports go to
[Issues](https://github.com/Nikitid/luci-app-ikev2-site-link/issues/new/choose): pick the form that
fits. Report a vulnerability privately through
[a security advisory](https://github.com/Nikitid/luci-app-ikev2-site-link/security/advisories/new).
English or Russian is fine.

## License

[MIT](LICENSE)
