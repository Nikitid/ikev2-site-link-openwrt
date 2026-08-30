# Changelog

## 0.7.0 - 2026-08-30

- Moved Reconnect and Apply to the right of the page, where every other action
  in both applications sits.
- Rebuilt the peer secret block. Three buttons were crowded into its heading and
  the input was too narrow to read its own placeholder. The field now sits in the
  form with the rest, the staging actions appear only once a replacement is
  actually staged, and a pill says whether a secret is set at all.
- Made the exit WAN a selector over the router's own networks. It was free text,
  so a typo was only discovered at Apply.
- Moved the dedicated tunnel address to the advanced group. It is an internal
  /32 with a working default that nobody sets by hand.
- Showed the installed package version beside the state, stamped at packaging
  time so status stays cheap.
- Translated the rest of the page, including the status words that came straight
  from the runtime — `unverified`, `healthy`, `configured` — and added the same
  translation check the other application uses.

## 0.6.0 - 2026-08-30

- Renamed Disable to Remove link and said in the confirmation exactly what it
  deletes: the interface, the firewall zone and forwardings, the routing policy
  and the applied state. It sat next to Pause and read as the same kind of
  toggle, which it is not.
- Split the actions by what they change. Pause, Resume and Remove decide whether
  the link exists at all and stay at the top with the status; Reconnect and Apply
  act on the running configuration and are now the only buttons at the bottom.
  Apply no longer claims to connect.
- Added Reconnect, which was reachable only from the command line.
- Translated the overview page. Only the policy page had Russian strings.
- Showed a spinner on a busy button instead of only greying it out, matching the
  other application.

## 0.5.0 - 2026-08-30

- Rebuilt the overview on the application's own design system instead of stock
  CBI, so it matches every other page. A select whose stored value was outside
  its choices used to render as unset and be rewritten by the next save; the
  value is now preserved.
- Reduced the page to Link, Traffic and one advanced group. Interface names and
  XFRM identifiers are no longer settings: they exist only to avoid colliding
  with IKEv2 Manager, the runtime already refuses a conflict, and changing one
  requires a Disable first.
- Reported whether a sampled classifier address can actually be reached through
  the tunnel. Destinations are resolved on the source but connected from the
  exit, so a CDN cache inside the source operator's network can be unreachable
  from the exit while every other signal stays healthy. This is telemetry and
  never triggers a reconnect.
- Added a render harness that executes the page against a stubbed LuCI
  environment, because a parse check passes while a page dies at render time.

## 0.4.0 - 2026-08-29

- Split the single off switch into Pause and Disable. Pause is reversible: it
  terminates the SAs, stops the monitor and clears PBR's own enable flag on the
  site-link policy, so selected traffic returns to this router's WAN instead of
  reaching the fail-closed terminal route. The applied snapshot, generated
  network, firewall and routing sections, XFRM device and peer secret are all
  retained, and Resume restores the verified configuration with no form input.
- Removed the Enabled checkbox from the settings form. Clearing it and pressing
  Apply used to run the complete teardown, which could not be undone from the
  page. Running state is now changed only by explicit Pause, Resume and Disable
  actions, and Disable asks for confirmation.
- Reported a paused link as its own state instead of a fault, and stopped the
  monitor, policy reload and policy check from repairing through a pause.
- Grouped timings, interface names and XFRM identifiers into one advanced
  section, reducing the page from five sections to three.
- Refused a policy whose domains are already routed by IKEv2 Manager. Such a
  domain is answered from a FakeIP range, which would fill this classifier with
  synthetic addresses and break both routes while every health signal still
  reported success.
- Logged every live-traffic state transition with its invoking process, so an
  unexplained teardown can be attributed from the system log.
- Dropped IKEv2 Manager's FakeIP range from the classifier snapshot restore, so
  a snapshot taken before the overlap check cannot reintroduce a synthetic
  destination the peer is unable to reach.
