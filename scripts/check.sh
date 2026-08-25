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

# The zone's mtu_fix only clamps ingress, where "rt mtu" is the LAN MTU and the
# clamp does nothing. The egress clamp into the tunnel has to be installed by
# hand, and it has to survive a firewall reload like the QUIC rule does.
grep -Fq 'tcp option maxseg size set rt mtu' "$root/runtime/pbr.user.site-link"
grep -Fq 'mangle_forward' "$root/runtime/pbr.user.site-link"
if grep -Eq '/etc/init\.d/pbr[[:space:]]+restart|pbr_init.*restart' \
	"$root/runtime/ikev2-site-link.sh" "$root/runtime/pbr.user.site-link"; then
	echo 'direct PBR restart found in runtime' >&2
	exit 1
fi
if grep -Fq '(set -e;' "$root/runtime/ikev2-site-link.sh"; then
	echo 'conditional transaction still relies on suppressed shell errexit semantics' >&2
	exit 1
fi
if grep -Fq '"$pbr_init" reload >/dev/null || return 1' \
	"$root/runtime/ikev2-site-link.sh"; then
	echo 'PBR reload still trusts the init-script exit code' >&2
	exit 1
fi
grep -Fq '/var/run/ikev2-action.lock' "$root/runtime/ikev2-site-link.sh"
grep -Fq 'routes-only' "$root/runtime/pbr.user.site-link"
if grep -Fq 'ikev2-site-link.main.' "$root/runtime/pbr.user.site-link"; then
	echo 'PBR include reads candidate configuration' >&2
	exit 1
fi
grep -Fq 'ikev2-site-link.applied.interface' "$root/runtime/pbr.user.site-link"
grep -Fq 'ip -6 route replace unreachable default metric 32767' \
	"$root/runtime/pbr.user.site-link"
grep -Fq 'SITE_LINK_SET_DUMP4' \
	"$root/runtime/pbr.user.site-link"
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
	"$root/luci/policy.js"
node -e 'new Function("window", "document", "L", "baseclass", require("fs").readFileSync(process.argv[1], "utf8"))' \
	"$root/luci/shared.js"

"$root/scripts/test-policy-ui.sh"

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
grep -Fq '"/usr/libexec/ikev2-site-link zones"' "$root/luci/acl.json"
grep -Fq 'zones) zones_emit ;;' "$root/runtime/ikev2-site-link.sh"
grep -Fq 'sources) sources_emit ;;' "$root/runtime/ikev2-site-link.sh"
grep -Fq 'policy-reload) use_applied_config || exit 0; with_lock policy-reload policy_reload_impl ;;' "$root/runtime/ikev2-site-link.sh"
grep -Fq 'monitor) monitor_loop ;;' "$root/runtime/ikev2-site-link.sh"
grep -Fq "use_applied_config || die 'no applied configuration exists'" "$root/runtime/ikev2-site-link.sh"
grep -Fq 'ikev2-site-link.applied.enabled' "$root/runtime/ikev2-site-link.init"
grep -Fq 'ikev2-site-link.applied.role' "$root/runtime/90-ikev2-site-link"
grep -Fq 'tunnel_data_plane=%s' "$root/runtime/ikev2-site-link.sh"
grep -Fq 'classifier=%s' "$root/runtime/ikev2-site-link.sh"
grep -Fq 'client_forwarding=%s' "$root/runtime/ikev2-site-link.sh"
grep -Fq 'guard_rule_match()' "$root/runtime/ikev2-site-link.sh"
grep -Fq 'combined_mask=$((guard_mask | pbr_mask))' "$root/runtime/ikev2-site-link.sh"
grep -Fq 'pbr.config.ipv6_enabled' "$root/runtime/ikev2-site-link.sh"
grep -Fq 'dnsmasq -v' "$root/runtime/ikev2-site-link.sh"
grep -Fq 'openssl x509 -in "$server_cert_file" -noout -checkhost "$identity"' \
	"$root/runtime/ikev2-site-link.sh"
grep -Fq 'probe_fallback_url=' "$root/runtime/ikev2-site-link.sh"
grep -Fq 'firewall.ikev2_site_link_ike.target' "$root/runtime/ikev2-site-link.sh"
grep -Fq 'exit_wan_zone' "$root/openwrt/files/etc/config/ikev2-site-link"
grep -Fq 'file://$domains_file file://$addresses_file' "$root/runtime/ikev2-site-link.sh"
if sed -n '/^policy_configuration_ready()/,/^}/p' "$root/runtime/ikev2-site-link.sh" |
	grep -Eq '" = *$'; then
	echo 'unterminated policy comparison found' >&2
	exit 1
fi
grep -Fq 'user_services_dir="${SITE_LINK_POLICY_USER_SERVICES_DIR:-/etc/ikev2-site-link/services.d}"' \
	"$root/runtime/ikev2-site-link-policy.sh"
grep -Fxq youtube "$root/openwrt/files/etc/ikev2-site-link/services.selected.txt"

for dependency in ip-full strongswan-charon strongswan-mod-eap-mschapv2 \
	strongswan-mod-kernel-netlink openssl-util curl; do
	grep -Fq "+$dependency" "$root/Makefile"
	grep -Fq "$dependency" "$root/scripts/build-apk.sh"
done

"$root/scripts/test-runtime.sh"
"$root/scripts/test-policy.sh"
"$root/scripts/test-recovery.sh"

printf 'checks OK\n'
