# Repository Guidelines

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

