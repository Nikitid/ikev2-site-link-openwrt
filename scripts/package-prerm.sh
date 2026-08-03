#!/bin/sh
[ -n "${IPKG_INSTROOT:-}" ] && exit 0
# Upgrades must not tear down live routing. opkg signals an upgrade through
# PKG_UPGRADE; apk-tools 3 passes "upgrade" as the first argument and the old
# version string on real removal, so no catch-all case is allowed here.
[ "${PKG_UPGRADE:-0}" = 1 ] && exit 0
case "${1:-}" in
	upgrade) exit 0 ;;
esac
[ -x /usr/libexec/ikev2-site-link ] || exit 1
/usr/libexec/ikev2-site-link disable
exit 0
