#!/bin/sh
[ -n "${IPKG_INSTROOT:-}" ] && exit 0
rm -f /tmp/luci-indexcache
rm -rf /tmp/luci-modulecache

# The monitor is a long-lived shell process and therefore keeps the functions
# loaded before an upgrade. Restart only that procd service when it is enabled;
# the service stop/start does not terminate an SA or rebuild network/PBR state.
site_link_init="${SITE_LINK_INIT:-/etc/init.d/ikev2-site-link}"
if [ -x "$site_link_init" ] && "$site_link_init" enabled >/dev/null 2>&1; then
	"$site_link_init" restart >/dev/null 2>&1 || {
		printf '%s\n' 'unable to restart the IKEv2 Site Link monitor' >&2
		exit 1
	}
fi
exit 0
