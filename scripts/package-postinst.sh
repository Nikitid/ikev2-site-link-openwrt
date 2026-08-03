#!/bin/sh
[ -n "${IPKG_INSTROOT:-}" ] && exit 0
rm -f /tmp/luci-indexcache
rm -rf /tmp/luci-modulecache
exit 0
