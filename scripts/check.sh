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
grep -Fq 'date -r "$action_lock_dir" +%s' "$root/runtime/lib/actions.sh"
grep -Fq 'pid_start=' "$root/runtime/ikev2-site-link.sh"
if grep -Eq 'now - updated.*3600' \
	"$root/runtime/ikev2-site-link.sh" "$root/runtime/lib/actions.sh"; then
	echo 'live global lock still expires by wall-clock age' >&2
	exit 1
fi
grep -Fq 'date -r "$site_link_dump" +%s' "$root/runtime/pbr.user.site-link"
if grep -Fq 'file_stamp()' "$root/runtime/ikev2-site-link.sh"; then
	echo 'certificate cache still depends on file metadata' >&2
	exit 1
fi
if grep -Fq '"$pbr_init" reload >/dev/null || return 1' \
	"$root/runtime/ikev2-site-link.sh"; then
	echo 'PBR reload still trusts the init-script exit code' >&2
	exit 1
fi
grep -Fq "grep -Eq 'jump forward_[A-Za-z0-9_]+'" \
	"$root/runtime/ikev2-site-link.sh"
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
"$root/scripts/test-overview-ui.sh"

# LuCI require() rejects any module whose factory does not return a Class subclass.
grep -q "^'require baseclass';" "$root/luci/shared.js"
grep -q 'return baseclass.extend(' "$root/luci/shared.js"

# The overview is built from the shared design system, like every other page in
# this application. Stock CBI produced a layout that did not match the rest and
# silently reset a select whose stored value was not among its choices.
if grep -Fq 'form.Map' "$root/luci/overview.js"; then
	echo 'overview must not use CBI' >&2
	exit 1
fi
grep -Fq 'common.section(' "$root/luci/overview.js"
grep -Fq 'common.fieldLabel(' "$root/luci/overview.js"
grep -Fq "class': 'ikev2-form-grid'" "$root/luci/overview.js"
# A stored value outside the offered choices must survive a render.
grep -Fq 'if (!seen && value)' "$root/luci/overview.js"

# Source selectors are offered from the router's own devices, and the list is
# stored as one space-separated UCI option.
grep -Fq "fs.exec(helper, [ 'sources' ])" "$root/luci/overview.js"
grep -Fq "uci.set(config, 'main', 'source_devices', chips.values().join(' '))" \
	"$root/luci/overview.js"

# Interface names and XFRM identifiers are fixed defaults, not settings: editing
# one requires a Disable first, so the page must not offer them.
grep -Fq 'var fixedDefaults' "$root/luci/overview.js"

# A destination resolved here can be a cache the exit cannot reach. Sample the
# live classifier through the tunnel and report it; never reconnect on it.
grep -Fq 'classifier_reachable()' "$root/runtime/ikev2-site-link.sh"
grep -Fq 'classifier_reach_state()' "$root/runtime/ikev2-site-link.sh"
grep -Fq 'classifier_reachable=%s' "$root/runtime/ikev2-site-link.sh"
grep -Fq 'status.classifier_reachable' "$root/luci/overview.js"
if sed -n '/^classifier_reachable()/,/^}/p' "$root/runtime/ikev2-site-link.sh" |
	grep -Eq 'connect_source|reconnect|swanctl'; then
	echo 'classifier reachability must stay telemetry' >&2
	exit 1
fi
for identifier in if_id xfrm_device exit_if_id exit_device; do
	if grep -Fq "common.fieldLabel(_('$identifier" "$root/luci/overview.js"; then
		echo "overview must not expose $identifier as a setting" >&2
		exit 1
	fi
done
grep -Fq '"/usr/libexec/ikev2-site-link sources"' "$root/luci/acl.json"
grep -Fq '"/usr/libexec/ikev2-site-link zones"' "$root/luci/acl.json"
grep -Fq '"/usr/libexec/ikev2-site-link pause"' "$root/luci/acl.json"
grep -Fq '"/usr/libexec/ikev2-site-link resume"' "$root/luci/acl.json"

# Running state is changed by explicit actions. An "Enabled" checkbox on the
# settings form made Apply run the irreversible teardown.
if grep -Fq "form.Flag, 'enabled'" "$root/luci/overview.js"; then
	echo 'overview must not expose enabled as a form flag' >&2
	exit 1
fi
grep -Fq "runHelper(pauseButton, 'pause'" "$root/luci/overview.js"
grep -Fq "runHelper(pauseButton, 'resume'" "$root/luci/overview.js"
grep -Fq "runHelper(disableButton, 'disable'" "$root/luci/overview.js"
# Disable is irreversible from this page, so it must ask and must point at Pause.
grep -Fq 'ui.showModal(_(' "$root/luci/overview.js"
grep -Fq 'use Pause instead' "$root/luci/overview.js"

# Every live-traffic state transition is attributable in the system log.
grep -Fq 'log_state_transition()' "$root/runtime/ikev2-site-link.sh"
grep -Fq 'log_state_transition "disable' "$root/runtime/ikev2-site-link.sh"
grep -Fq 'log_state_transition pause' "$root/runtime/ikev2-site-link.sh"
grep -Fq 'log_state_transition resume' "$root/runtime/ikev2-site-link.sh"
grep -Fq 'log_state_transition apply' "$root/runtime/ikev2-site-link.sh"
grep -Fq 'zones) zones_emit ;;' "$root/runtime/ikev2-site-link.sh"
grep -Fq 'sources) sources_emit ;;' "$root/runtime/ikev2-site-link.sh"
# policy-reload and policy-check must refuse to touch PBR without an applied
# snapshot, and must stay inert while the link is paused.
sed -n '/^	policy-reload)/,/;;/p' "$root/runtime/ikev2-site-link.sh" |
	grep -Fq 'use_applied_config || exit 0'
sed -n '/^	policy-reload)/,/;;/p' "$root/runtime/ikev2-site-link.sh" |
	grep -Fq 'if link_paused; then exit 0; fi'
sed -n '/^	policy-check)/,/;;/p' "$root/runtime/ikev2-site-link.sh" |
	grep -Fq 'if link_paused; then exit 0; fi'
grep -Fq 'monitor) monitor_loop ;;' "$root/runtime/ikev2-site-link.sh"

# Pause is a reversible stop: it must never delete the applied snapshot or the
# generated routing configuration, and the monitor must not repair through it.
grep -Fq 'pause) with_lock pause pause_impl ;;' "$root/runtime/ikev2-site-link.sh"
grep -Fq 'resume) with_lock resume resume_impl ;;' "$root/runtime/ikev2-site-link.sh"
if sed -n '/^pause_impl()/,/^}/p' "$root/runtime/ikev2-site-link.sh" |
	grep -Eq 'all_uci_remove|delete .*\.applied|delete_xfrm_candidate'; then
	echo 'pause must not perform disable teardown' >&2
	exit 1
fi
sed -n '/^pause_impl()/,/^}/p' "$root/runtime/ikev2-site-link.sh" |
	grep -Fq 'uci set pbr.ikev2_site_link.enabled=0'
sed -n '/^resume_impl()/,/^}/p' "$root/runtime/ikev2-site-link.sh" |
	grep -Fq 'uci set pbr.ikev2_site_link.enabled=1'
sed -n '/^monitor_loop()/,/^}/p' "$root/runtime/ikev2-site-link.sh" |
	grep -Fq 'if link_paused; then'
# Disable stays the complete teardown and must clear the pause flag with it.
sed -n '/^disable_impl()/,/^}/p' "$root/runtime/ikev2-site-link.sh" |
	grep -Fq 'uci -q delete "$config_name.main.paused"'
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
grep -Fq 'openssl verify -no-CAfile -no-CApath -partial_chain' \
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

# A domain claimed by both applications poisons this classifier with IKEv2
# Manager's FakeIP addresses, so the policy build refuses the overlap.
grep -Fq 'manager_domains_file="${SITE_LINK_MANAGER_DOMAINS_FILE:-/etc/pbr-ikev2-domains.txt}"' \
	"$root/runtime/ikev2-site-link-policy.sh"
grep -Fq 'domains are already routed by IKEv2 Manager' \
	"$root/runtime/ikev2-site-link-policy.sh"
# A snapshot taken before that check must not reintroduce FakeIP addresses.
grep -Fq "grep -Ev '^198\\.(18|19)\\.'" "$root/runtime/pbr.user.site-link"

for dependency in ip-full strongswan-charon strongswan-mod-eap-mschapv2 \
	strongswan-mod-kernel-netlink openssl-util curl; do
	grep -Fq "+$dependency" "$root/Makefile"
	grep -Fq "$dependency" "$root/scripts/build-apk.sh"
done

"$root/scripts/test-runtime.sh"
"$root/scripts/test-package-lifecycle.sh"
"$root/scripts/test-policy.sh"
"$root/scripts/test-recovery.sh"

printf 'checks OK\n'
