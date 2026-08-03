#!/bin/sh

set -eu
root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"

for script in "$root"/runtime/*.sh "$root"/runtime/*.init "$root"/runtime/90-* "$root"/runtime/pbr.*; do
	sh -n "$script"
done

for file in "$root"/luci/*.json; do
	python3 -m json.tool "$file" >/dev/null
done

grep -q '^googlevideo.com$' "$root/openwrt/files/etc/ikev2-site-link/youtube-domains.txt"
grep -q '^youtube.com$' "$root/openwrt/files/etc/ikev2-site-link/youtube-domains.txt"
grep -Fq "firewall.ikev2_site_link_ike.dest_port='4500'" \
	"$root/runtime/ikev2-site-link.sh"

# A dropped UDP/443 datagram costs the client a full QUIC handshake timeout
# before it falls back to TCP. The rule must reject, and it must sit in a hook
# where nftables honours reject.
grep -Fq 'reject with icmp type port-unreachable' "$root/runtime/pbr.user.site-link"
grep -Fq 'insert rule inet fw4 pbr_forward' "$root/runtime/pbr.user.site-link"
if grep -Eq 'udp dport 443 counter drop' "$root/runtime/pbr.user.site-link"; then
	echo 'UDP/443 is dropped instead of rejected' >&2
	exit 1
fi
if grep -Eq '^(google\.com|googleapis\.com|googleusercontent\.com|cloudfront\.net|cloudflare\.com)$' \
	"$root/openwrt/files/etc/ikev2-site-link/youtube-domains.txt"; then
	echo 'generic domain found in the YouTube list' >&2
	exit 1
fi

if grep -R -n -E 'grep[[:space:]]+-[A-Za-z]*P|find[^;|]*-printf|sort[^;|]*[[:space:]]-o([[:space:]]|$)|(^|[;&|[:space:]])\[\[[[:space:]]' \
	"$root/runtime" "$root/Makefile"; then
	echo 'BusyBox-incompatible construct found' >&2
	exit 1
fi

node -e 'new Function("window", "document", "L", "baseclass", require("fs").readFileSync(process.argv[1], "utf8"))' \
	"$root/luci/overview.js"
node -e 'new Function("window", "document", "L", "baseclass", require("fs").readFileSync(process.argv[1], "utf8"))' \
	"$root/luci/shared.js"

# LuCI require() rejects any module whose factory does not return a Class subclass.
grep -q "^'require baseclass';" "$root/luci/shared.js"
grep -q 'return baseclass.extend(' "$root/luci/shared.js"

# Source selectors are offered from the router's own devices, and the list is
# stored as one space-separated UCI option, so both overrides must stay.
grep -Fq "section.option(form.DynamicList, 'source_devices'" \
	"$root/luci/overview.js" ||
	grep -Fq "sourceRole.option(form.DynamicList, 'source_devices'" \
		"$root/luci/overview.js"
grep -Fq 'option.cfgvalue = function(section_id)' "$root/luci/overview.js"
grep -Fq 'option.write = function(section_id, value)' "$root/luci/overview.js"
grep -Fq "fs.exec(helper, [ 'sources' ])" "$root/luci/overview.js"
grep -Fq '"/usr/libexec/ikev2-site-link sources"' "$root/luci/acl.json"
grep -Fq 'sources) sources_emit ;;' "$root/runtime/ikev2-site-link.sh"

"$root/scripts/test-runtime.sh"

printf 'checks OK\n'
