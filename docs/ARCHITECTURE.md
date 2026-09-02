# Architecture

How the two roles fit together, what each side owns, and which guarantees the
runtime is built to keep. `docs/MAP.md` says where the code for any of this
lives; `docs/TRAPS.md` records where it has already gone wrong.

LuCI application for routing selected services and destinations from one
OpenWrt router through another over IKEv2. The initial deployment sends YouTube
traffic from an office router through a home router while the home router
continues to apply its normal Zapret strategy.

The project has two roles:

- `source`: owns `ipsec-home` (XFRM if_id 44), the outbound IKEv2 connection,
  a dedicated PBR interface, tunnel SNAT and a fail-closed routing table;
- `exit`: owns a separate exact-identity strongSwan responder,
  `ipsec-site-exit` (XFRM if_id 45) and a one-address private pool. Its firewall
  zone can forward only to the ordinary WAN. A highest-priority PBR source
  policy keeps this traffic out of the exit router's outbound PBR tunnel.

The exit responder reuses `/etc/swanctl/x509/ikev2.pem` and
`/etc/swanctl/private/ikev2.key`, normally maintained by IKEv2 Manager, but not
its road-warrior connection or address pool. Site Link has no package dependency
on Manager: a standalone installation is supported when another administrator
maintains those two certificate files with the same lifecycle contract.

The source policy is built from selectable prepared services, administrator
defined services, custom domain suffixes, and explicit IPv4 addresses or CIDR
networks. The default selection contains only YouTube-owned domains and does
not add Google or generic CDN suffixes. PBR sends resolved destinations into
the site link; UDP/443 is rejected for that destination set so clients
immediately retry over TCP through the exit router's Zapret strategy. If the CHILD_SA or virtual
address is unavailable, the PBR table keeps an unreachable default and matching
traffic cannot fall back to the source WAN.

The source also keeps an application-owned fallback classifier built from the
last confirmed PBR destination sets. Its RPDB rule matches only while no normal
PBR routing bits are present, so Manager device overrides, Reliable-mode TProxy
and the active PBR policy retain their normal precedence. If a firewall/PBR
rebuild temporarily removes the normal classifier, the fallback sends the
confirmed destinations to the same XFRM interface or its unreachable terminal
route; it does not rebuild global PBR state.

The monitor treats an installed SA as only one health signal. Status separates
the tunnel data plane, destination classifier, and configured client-forwarding
path. The source HTTPS probe verifies the router-originated tunnel path; it does
not claim to originate from a LAN client. Client forwarding therefore reports
`configured`, not `verified`, and is based on exact managed network, firewall,
forwarding and PBR invariants. The exit also requires its permanent `/32` return
route, dedicated-port DNAT and evidence of traffic in both CHILD_SA directions.
Cheap runtime drift (XFRM device, VIP, peer route and owned auxiliary nftables
rules) is reconciled under the shared action lock. Managed UCI, firewall and PBR
drift is reported as degraded and requires an explicit Apply; the background
monitor never starts a forwarding-disruptive PBR rebuild.
Status also samples one address from the live classifier and tries to reach it
through the tunnel. Destinations are resolved on the source but connected from
the exit, so a CDN cache inside the source operator's network can be
unreachable from the exit while the SA, the classifier and the ordinary probe
all look healthy. The result is reported as `classifier_reachable`; it is
telemetry and never triggers a reconnect, because one unreachable cache node is
not a reason to tear down a working tunnel.

The source installs one narrow RPDB rule for locally generated sockets bound to
its XFRM device, so the HTTPS probe uses the PBR table instead of the router's
ordinary main-table default.

## Safety properties

- no router reboot or WAN restart;
- package upgrades restart only the Site Link monitor so the installed runtime
  takes effect without terminating the live SA or rebuilding PBR;
- separate connection, XFRM interface and generated UCI sections;
- atomic strongSwan profile and secret installation;
- actions and PBR reloads serialized with IKEv2 Manager through the shared
  network-action lock;
- bounded health-monitor interval and reconnect threshold;
- current-CHILD RX/TX progress tracking on the exit router, so counters from an
  earlier successful transfer cannot keep a stalled data plane healthy;
- a dedicated external IKE port, translated to the existing UDP/4500 NAT-T
  socket only on the exit router,
  so a reverse road-warrior session between the same public addresses cannot
  collide with the site link;
- automatic restoration of PBR domain rules after an independent firewall
  reload;
- short-lived IPv4 and IPv6 PBR set snapshots for clients with warm DNS caches,
  plus an unreachable IPv6 policy route because the tunnel is IPv4-only;
- an independent fallback classifier which is dormant whenever a normal PBR
  mark exists and retains the last confirmed route during classifier rebuilds;
- verified PBR reloads; the site-link runtime never uses the disruptive PBR
  restart path;
- no strongSwan-wide clear/reload during disable; the link never owns other
  applications' connections or credentials;
- a policy whose domains are already routed by IKEv2 Manager is refused: such a
  domain is answered from a FakeIP range, which would fill this classifier with
  synthetic addresses and break both routes while every health signal still
  reported success. Snapshot restores drop that range for the same reason;
- every live-traffic state transition records its invoking process in the system
  log, so an unexplained teardown can be attributed afterwards;
- package removal refuses to continue if managed routing cannot be disabled;
- explicit Disable performs a complete role-independent teardown, including
  both profiles, SAs, XFRM devices, policy rules and cached DNS-set state;
  the monitor reports incomplete teardown but never mutates global UCI/PBR;
- Pause is the reversible alternative to Disable. It terminates the SAs, stops
  the monitor and clears PBR's own enable flag on the site-link policy, so
  selected traffic returns to this router's WAN instead of reaching the
  fail-closed terminal route. The applied snapshot, generated network,
  firewall and routing sections, XFRM device and peer secret are all retained,
  so Resume restores the configuration that was already verified without any
  form input. The monitor performs no repair while the link is paused, and
  Apply clears the pause. Running state is changed only by these explicit
  actions; the settings form has no enable checkbox that could turn a save
  into a teardown;
- peer secrets are write-only in LuCI and are never stored in UCI; replacement
  secrets are staged, activated on the exit without terminating the live SA,
  then activated and authenticated on the source with automatic local rollback;
- exact IKE and EAP identity matching on the dedicated exit responder;
- distinct XFRM identifiers from IKEv2 Manager's reserved 42 and 43;
- a dedicated /32 tunnel address which must not overlap LAN or VPN pools;
- the exit firewall has no forwarding path to the router or LAN.

The editable `main` UCI section is candidate configuration. Apply snapshots the
application, network, firewall, PBR and generated-profile state, validates the
new control and data planes, and only then records every runtime option in the
credential-free `applied` section. A failed activation restores the previous
snapshot and never records the rejected candidate. Monitor, procd startup,
hotplug, reconnect and policy reload read only the applied snapshot, so saving
or rejecting a candidate cannot retarget a live repair.
Disable the link before changing resource identities or switching roles.

The explicit global contract is `pbr.config.enabled=1`,
`pbr.config.strict_enforcement=1`, and, on the source,
`pbr.config.ipv6_enabled=1` plus `pbr.config.resolver_set=dnsmasq.nftset` backed
by a dnsmasq binary which actually advertises nftset support. IKEv2 Manager
normally owns those global settings and the exit certificate. Without Manager,
the administrator must maintain them; Site Link checks and reports the contract
but does not take ownership of global PBR/DNS or certificate lifecycle. Exit
Apply also verifies certificate lifetime, configured hostname identity, private
key validity and the certificate/key public-key match.
Both roles must use the same `ike_port` value (UDP/1500 by default). The exit
router creates the narrow DNAT rule automatically; no additional strongSwan
listener or WAN restart is required. UDP/500 is deliberately not the DNAT
target: custom-port IKE packets carry the non-ESP marker expected by the NAT-T
socket.

`exit_wan` is the OpenWrt network/PBR interface. `exit_wan_zone` is the firewall
zone used for forwarding and DNAT; they may share the name `wan` but are not the
same object. Each protected source device must belong to a firewall zone. Site
Link creates one forwarding for every selected source zone and refuses an
unresolvable selector instead of silently classifying traffic the firewall
cannot pass.
`source_wan` names the source network whose hotplug recovery event accelerates
reconnect after a WAN outage; the monitor still retries independently if the
event is missed.

Secret rotation is deliberately a two-router operator action, not a pairing
protocol. Stage the same value on both routers, activate the exit, then activate
the source. The exit keeps the established SA during this short handoff. If
source authentication fails it restores its local previous secret; the operator
must also run `secret-rollback` on the exit. A WAN loss between the two activation
steps can therefore require that rollback, but normal unattended operation has
no partially staged credential transition.

Configuration changes are also deliberately coordinated rather than repaired
implicitly by either peer. Apply and validate the exit role first, without
removing its previous return path, then apply the source role and validate the
SA, virtual address and classifier. If the source activation fails, roll the
source back before changing the exit. Each monitor owns only cheap local runtime
state; neither monitor rewrites the peer, managed UCI or global PBR state.
