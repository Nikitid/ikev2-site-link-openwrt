#!/bin/sh

set -eu
umask 077

config_name="${SITE_LINK_CONFIG:-ikev2-site-link}"
uci_dir="${SITE_LINK_UCI_DIR:-/etc/config}"
state_file="${SITE_LINK_STATE:-/var/run/ikev2-site-link.status}"
secret_file="${SITE_LINK_SECRET:-/etc/ikev2-site-link/client.secret}"
domains_file="${SITE_LINK_DOMAINS:-/etc/ikev2-site-link/youtube-domains.txt}"
conn_file="${SITE_LINK_CONN:-/etc/swanctl/conf.d/40-site-link.conf}"
cred_file="${SITE_LINK_CRED:-/etc/swanctl/conf.d/92-site-link-secret.conf}"
exit_conn_file="${SITE_LINK_EXIT_CONN:-/etc/swanctl/conf.d/41-site-link-exit.conf}"
exit_cred_file="${SITE_LINK_EXIT_CRED:-/etc/swanctl/conf.d/93-site-link-exit-secret.conf}"
pbr_helper="${SITE_LINK_PBR_HELPER:-/usr/share/pbr/pbr.user.site-link}"
lock_dir="${SITE_LINK_LOCK:-/var/run/ikev2-site-link.lock}"

uci() {
	command uci -c "$uci_dir" "$@"
}

getv() {
	uci -q get "$config_name.main.$1" 2>/dev/null || printf '%s\n' "${2:-}"
}

die() {
	printf 'ikev2-site-link: %s\n' "$*" >&2
	exit 1
}

valid_name() {
	case "$1" in '' | *[!A-Za-z0-9_.@-]*) return 1 ;; esac
}

valid_uint() {
	case "$1" in '' | *[!0-9]*) return 1 ;; esac
}

valid_ipv4() {
	printf '%s\n' "$1" | awk -F. '
		NF != 4 { exit 1 }
		{ for (i = 1; i <= 4; i++)
			if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255) exit 1 }
	'
}

atomic_install() {
	source="$1"
	target="$2"
	mode="$3"
	chmod "$mode" "$source"
	mv -f "$source" "$target"
}

with_lock() {
	tries=0
	while ! mkdir "$lock_dir" 2>/dev/null; do
		tries=$((tries + 1))
		[ "$tries" -lt 20 ] || die 'another action is still running'
		sleep 1
	done
	trap 'rmdir "$lock_dir" 2>/dev/null || true' EXIT INT TERM
	"$@"
	rmdir "$lock_dir" 2>/dev/null || true
	trap - EXIT INT TERM
}

role() {
	getv role source
}

validate_config() {
	current_role="$(role)"
	[ "$current_role" = source ] || [ "$current_role" = exit ] ||
		die 'role must be source or exit'
	peer_user="$(getv peer_user site-link)"
	valid_name "$peer_user" || die 'invalid peer user'
	if_id="$(getv if_id 44)"
	exit_if_id="$(getv exit_if_id 45)"
	mtu="$(getv mtu 1360)"
	dpd="$(getv dpd 20)"
	interval="$(getv monitor_interval 15)"
	threshold="$(getv failure_threshold 3)"
	cooldown="$(getv reconnect_cooldown 30)"
	ike_port="$(getv ike_port 1500)"
	for value in "$if_id" "$exit_if_id" "$mtu" "$dpd" "$interval" "$threshold" "$cooldown" "$ike_port"; do
		valid_uint "$value" || die 'numeric setting contains a non-number'
	done
	[ "$if_id" -ge 1 ] && [ "$if_id" -le 4294967295 ] || die 'invalid XFRM if_id'
	[ "$exit_if_id" -ge 1 ] && [ "$exit_if_id" -le 4294967295 ] || die 'invalid exit XFRM if_id'
	[ "$if_id" != "$exit_if_id" ] || die 'source and exit XFRM if_id values must differ'
	case "$if_id:$exit_if_id" in
		42:* | 43:* | *:42 | *:43) die 'XFRM if_id 42 and 43 are reserved by IKEv2 Manager' ;;
	esac
	[ "$mtu" -ge 1200 ] && [ "$mtu" -le 1500 ] || die 'MTU must be 1200-1500'
	[ "$interval" -ge 5 ] && [ "$interval" -le 300 ] || die 'monitor interval must be 5-300 seconds'
	[ "$threshold" -ge 1 ] && [ "$threshold" -le 20 ] || die 'failure threshold must be 1-20'
	[ "$cooldown" -ge 15 ] && [ "$cooldown" -le 3600 ] || die 'reconnect cooldown must be 15-3600 seconds'
	[ "$ike_port" -ge 1024 ] && [ "$ike_port" -le 65535 ] || die 'external IKE port must be 1024-65535'
	[ "$ike_port" != 4500 ] || die 'external IKE port 4500 conflicts with standard IKE NAT-T'
	if [ "$current_role" = source ]; then
		endpoint="$(getv endpoint)"
		remote_id="$(getv remote_id)"
		[ -n "$endpoint" ] || die 'source endpoint is required'
		valid_name "$endpoint" || die 'invalid source endpoint'
		[ -n "$remote_id" ] || die 'remote identity is required'
		valid_name "$remote_id" || die 'invalid remote identity'
	else
		remote_id="$(getv remote_id)"
		[ -n "$remote_id" ] && valid_name "$remote_id" || die 'exit certificate identity is required'
		exit_pool="$(getv exit_pool 10.253.44.2)"
		valid_ipv4 "$exit_pool" || die 'exit pool must be one IPv4 address'
	fi
}

secret_configured() {
	[ -s "$secret_file" ]
}

read_secret() {
	[ -s "$secret_file" ] || die 'peer secret is not configured'
	cat "$secret_file"
}

consume_secret_input() {
	token="${1:-}"
	case "$token" in '' | *[!A-Za-z0-9-]*) die 'invalid secret token' ;; esac
	[ "${#token}" -ge 8 ] && [ "${#token}" -le 64 ] || die 'invalid secret token'
	input="/var/run/ikev2-site-link-secret-$token.in"
	[ -f "$input" ] && [ ! -L "$input" ] || die 'secret input is missing'
	chmod 600 "$input"
	bytes="$(wc -c <"$input" | tr -d ' ')"
	case "$bytes" in '' | *[!0-9]*) rm -f "$input"; die 'invalid secret size' ;; esac
	[ "$bytes" -ge 1 ] && [ "$bytes" -le 256 ] || {
		rm -f "$input"
		die 'secret must be 1-256 bytes'
	}
	if LC_ALL=C grep -q '[[:cntrl:]]' "$input"; then
		rm -f "$input"
		die 'secret must not contain control characters'
	fi
	mkdir -p "${secret_file%/*}"
	cp "$input" "$secret_file.new"
	rm -f "$input"
	atomic_install "$secret_file.new" "$secret_file" 600
	if [ "$(role)" = exit ]; then
		render_exit
		swanctl --load-creds --noprompt >/dev/null 2>&1
	else
		render_source
		# Load the complete on-disk credential set without clearing the live
		# credential store first. Clearing creates an avoidable authentication
		# gap for unrelated IKEv2 Manager connections on the same router.
		swanctl --load-creds --noprompt >/dev/null 2>&1
	fi
}

render_source() {
	validate_config
	[ "$(role)" = source ] || return 0
	endpoint="$(getv endpoint)"
	remote_id="$(getv remote_id)"
	peer_user="$(getv peer_user site-link)"
	ike_port="$(getv ike_port 1500)"
	if_id="$(getv if_id 44)"
	dpd="$(getv dpd 20)"
	mkdir -p "${conn_file%/*}" "${secret_file%/*}"
	cat >"$conn_file.new" <<EOF
connections {
	site-link {
		version = 2
		remote_addrs = $endpoint
		remote_port = $ike_port
		# OpenWrt's socket backend requires the NAT-T source socket to keep
		# a custom remote port instead of floating the peer back to UDP/4500.
		local_port = 4500
		proposals = aes256gcm16-prfsha384-ecp384
		vips = 0.0.0.0
		mobike = no
		fragmentation = yes
		dpd_delay = ${dpd}s
		reauth_time = 0
		keyingtries = 0
		local {
			auth = eap-mschapv2
			id = $peer_user
			eap_id = $peer_user
		}
		remote {
			auth = pubkey
			id = $remote_id
		}
		children {
			site-link4 {
				local_ts = 0.0.0.0/0
				remote_ts = 0.0.0.0/0
				esp_proposals = aes256gcm16-ecp384
				if_id_in = $if_id
				if_id_out = $if_id
				start_action = none
				dpd_action = clear
				close_action = none
			}
		}
	}
}
EOF
	atomic_install "$conn_file.new" "$conn_file" 600
	if secret_configured; then
		encoded="$(read_secret | openssl base64 -A)"
		cat >"$cred_file.new" <<EOF
secrets {
	eap-site-link {
		id = "$peer_user"
		secret = 0s$encoded
	}
}
EOF
	else
		printf '%s\n' '# IKEv2 Site Link secret is not configured.' >"$cred_file.new"
	fi
	atomic_install "$cred_file.new" "$cred_file" 600
}

render_exit() {
	[ "$(role)" = exit ] || return 0
	validate_config
	peer_user="$(getv peer_user site-link)"
	remote_id="$(getv remote_id)"
	exit_if_id="$(getv exit_if_id 45)"
	exit_pool="$(getv exit_pool 10.253.44.2)"
	dpd="$(getv dpd 20)"
	mkdir -p "${exit_conn_file%/*}" "${exit_cred_file%/*}"
	cat >"$exit_conn_file.new" <<EOF
connections {
	site-link-in {
		version = 2
		send_cert = always
		proposals = aes256gcm16-prfsha384-ecp384
		unique = replace
		dpd_delay = ${dpd}s
		reauth_time = 0
		mobike = no
		fragmentation = yes
		pools = site_link_pool4
		local {
			auth = pubkey
			certs = ikev2.pem
			id = $remote_id
		}
		remote {
			auth = eap-mschapv2
			id = $peer_user
			eap_id = $peer_user
		}
		children {
			site-link-net {
				local_ts = 0.0.0.0/0
				esp_proposals = aes256gcm16-ecp384
				if_id_in = $exit_if_id
				if_id_out = $exit_if_id
				dpd_action = clear
				close_action = none
				start_action = none
			}
		}
	}
}
pools {
	site_link_pool4 {
		addrs = $exit_pool-$exit_pool
	}
}
EOF
	atomic_install "$exit_conn_file.new" "$exit_conn_file" 600
	if secret_configured; then
		encoded="$(read_secret | openssl base64 -A)"
		cat >"$exit_cred_file.new" <<EOF
secrets {
	eap-site-link-exit {
		id = "$peer_user"
		secret = 0s$encoded
	}
}
EOF
	else
		printf '%s\n' '# IKEv2 Site Link exit secret is not configured.' >"$exit_cred_file.new"
	fi
	atomic_install "$exit_cred_file.new" "$exit_cred_file" 600
}

ensure_xfrm() {
	device="${1:-$(getv xfrm_device ipsec-home)}"
	if_id="${2:-$(getv if_id 44)}"
	mtu="$(getv mtu 1360)"
	modprobe xfrm_interface
	ip link show "$device" >/dev/null 2>&1 ||
		ip link add "$device" type xfrm if_id "$if_id"
	ip link set "$device" mtu "$mtu" up
}

firewall_zone_exists() {
	wanted="$1"
	for section in $(uci show firewall 2>/dev/null |
		sed -n 's/^firewall\.\([^.=]*\)=zone$/\1/p'); do
		[ "$(uci -q get "firewall.$section.name" 2>/dev/null || true)" = "$wanted" ] &&
			return 0
	done
	return 1
}

source_uci_apply() {
	device="$(getv xfrm_device ipsec-home)"
	interface="$(getv interface sitehome)"
	sources="$(getv source_devices '@br-lan @ipsec-in')"
	inbound_zone="$(getv inbound_zone ikev2in)"
	uci set "network.$interface=interface"
	uci set "network.$interface.proto=none"
	uci set "network.$interface.device=$device"
	uci set firewall.ikev2_site_link=zone
	uci set firewall.ikev2_site_link.name="$interface"
	uci set firewall.ikev2_site_link.network="$interface"
	uci set firewall.ikev2_site_link.input=REJECT
	uci set firewall.ikev2_site_link.output=ACCEPT
	uci set firewall.ikev2_site_link.forward=REJECT
	uci set firewall.ikev2_site_link.mtu_fix=1
	uci set firewall.ikev2_site_link.masq=1
	uci set firewall.ikev2_site_link_forward=forwarding
	uci set firewall.ikev2_site_link_forward.src=lan
	uci set firewall.ikev2_site_link_forward.dest="$interface"
	if firewall_zone_exists "$inbound_zone"; then
		uci set firewall.ikev2_site_link_inbound=forwarding
		uci set firewall.ikev2_site_link_inbound.src="$inbound_zone"
		uci set firewall.ikev2_site_link_inbound.dest="$interface"
	else
		uci -q delete firewall.ikev2_site_link_inbound || true
	fi
	if ! uci -q get pbr.config.supported_interface 2>/dev/null |
		tr ' ' '\n' | grep -Fxq "$interface"; then
		uci add_list "pbr.config.supported_interface=$interface"
	fi
	uci set pbr.ikev2_site_link=policy
	uci set pbr.ikev2_site_link.name='IKEv2 Site Link: YouTube'
	uci set pbr.ikev2_site_link.interface="$interface"
	uci set pbr.ikev2_site_link.src_addr="$sources"
	uci set pbr.ikev2_site_link.dest_addr="file://$domains_file"
	uci set pbr.ikev2_site_link.proto='all'
	uci set pbr.ikev2_site_link.enabled=1
	# The narrow site-link policy must win before broader application policies
	# when two DNS names temporarily resolve to the same CDN address. Keep the
	# global PBR config first and place this policy immediately after it.
	uci reorder pbr.ikev2_site_link=1
	uci set pbr.ikev2_site_link_include=include
	uci set pbr.ikev2_site_link_include.path="$pbr_helper"
	uci set pbr.ikev2_site_link_include.enabled=1
	uci commit network
	uci commit firewall
	uci commit pbr
	fw4 check >/dev/null
	/etc/init.d/network reload >/dev/null
	/etc/init.d/firewall reload >/dev/null
	/etc/init.d/pbr restart >/dev/null
	"$pbr_helper" >/dev/null 2>&1 || true
}

exit_uci_apply() {
	interface="$(getv exit_interface siteexit)"
	device="$(getv exit_device ipsec-site-exit)"
	wan="$(getv exit_wan wan)"
	exit_pool="$(getv exit_pool 10.253.44.2)"
	ike_port="$(getv ike_port 1500)"
	uci set "network.$interface=interface"
	uci set "network.$interface.proto=none"
	uci set "network.$interface.device=$device"
	uci set firewall.ikev2_site_link_exit=zone
	uci set firewall.ikev2_site_link_exit.name="$interface"
	uci set firewall.ikev2_site_link_exit.network="$interface"
	uci set firewall.ikev2_site_link_exit.input=REJECT
	uci set firewall.ikev2_site_link_exit.output=ACCEPT
	uci set firewall.ikev2_site_link_exit.forward=REJECT
	uci set firewall.ikev2_site_link_exit.mtu_fix=1
	uci set firewall.ikev2_site_link_exit_wan=forwarding
	uci set firewall.ikev2_site_link_exit_wan.src="$interface"
	uci set firewall.ikev2_site_link_exit_wan.dest="$wan"
	# A custom IKE port carries both IKE (with a non-ESP marker) and UDP-
	# encapsulated ESP. Translate it to strongSwan's NAT-T socket, not its
	# plain UDP/500 socket. The distinct public five-tuple avoids collisions
	# with a road-warrior IKE session between the same two public routers.
	uci set firewall.ikev2_site_link_ike=redirect
	uci set firewall.ikev2_site_link_ike.name='IKEv2 Site Link: dedicated IKE port'
	uci set firewall.ikev2_site_link_ike.src="$wan"
	uci set firewall.ikev2_site_link_ike.proto='udp'
	uci set firewall.ikev2_site_link_ike.src_dport="$ike_port"
	uci set firewall.ikev2_site_link_ike.dest_port='4500'
	uci set firewall.ikev2_site_link_ike.family='ipv4'
	uci set firewall.ikev2_site_link_ike.target='DNAT'
	uci set pbr.ikev2_site_link=policy
	uci set pbr.ikev2_site_link.name='IKEv2 Site Link: direct exit WAN'
	uci set pbr.ikev2_site_link.interface="$wan"
	uci set pbr.ikev2_site_link.src_addr="@$device"
	uci set pbr.ikev2_site_link.proto='all'
	uci set pbr.ikev2_site_link.enabled=1
	uci reorder pbr.ikev2_site_link=1
	uci -q delete pbr.ikev2_site_link_include || true
	uci commit network
	uci commit firewall
	uci commit pbr
	fw4 check >/dev/null
	/etc/init.d/network reload >/dev/null
	/etc/init.d/firewall reload >/dev/null
	/etc/init.d/pbr restart >/dev/null
	ip -4 route replace "$exit_pool/32" dev "$device"
}

source_uci_remove() {
	interface="$(getv interface sitehome)"
	uci -q delete "network.$interface" || true
	uci -q delete firewall.ikev2_site_link || true
	uci -q delete firewall.ikev2_site_link_forward || true
	uci -q delete firewall.ikev2_site_link_inbound || true
	uci -q delete pbr.ikev2_site_link || true
	uci -q delete pbr.ikev2_site_link_include || true
	uci -q del_list "pbr.config.supported_interface=$interface" || true
	uci commit network
	uci commit firewall
	uci commit pbr
	/etc/init.d/network reload >/dev/null
	/etc/init.d/firewall reload >/dev/null
	/etc/init.d/pbr restart >/dev/null
}

exit_uci_remove() {
	interface="$(getv exit_interface siteexit)"
	uci -q delete "network.$interface" || true
	uci -q delete firewall.ikev2_site_link_exit || true
	uci -q delete firewall.ikev2_site_link_exit_wan || true
	uci -q delete firewall.ikev2_site_link_ike || true
	uci -q delete pbr.ikev2_site_link || true
	uci commit network
	uci commit firewall
	uci commit pbr
	/etc/init.d/network reload >/dev/null
	/etc/init.d/firewall reload >/dev/null
	/etc/init.d/pbr restart >/dev/null
}

rollback_cleanup() {
	directory="$1"
	for file in network firewall pbr; do
		rm -f "$directory/$file"
	done
	rmdir "$directory" 2>/dev/null || true
}

source_apply_transaction() {
	rollback_dir="/var/run/ikev2-site-link-rollback-$$"
	mkdir "$rollback_dir"
	for file in network firewall pbr; do
		cp "/etc/config/$file" "$rollback_dir/$file"
	done
	if (set -e; source_uci_apply; connect_source; data_plane_ready); then
		rollback_cleanup "$rollback_dir"
		return 0
	fi
	for file in network firewall pbr; do
		cp "$rollback_dir/$file" "/etc/config/$file"
	done
	rollback_cleanup "$rollback_dir"
	/etc/init.d/network reload >/dev/null 2>&1 || true
	/etc/init.d/firewall reload >/dev/null 2>&1 || true
	/etc/init.d/pbr restart >/dev/null 2>&1 || true
	swanctl --terminate --ike site-link --timeout 5 >/dev/null 2>&1 || true
	device="$(getv xfrm_device ipsec-home)"
	ip -4 addr flush dev "$device" scope global 2>/dev/null || true
	die 'tunnel validation failed; previous routing configuration restored'
}

exit_apply_transaction() {
	rollback_dir="/var/run/ikev2-site-link-rollback-$$"
	mkdir "$rollback_dir"
	for file in network firewall pbr; do
		cp "/etc/config/$file" "$rollback_dir/$file"
	done
	if (set -e; exit_uci_apply; swanctl --load-conns >/dev/null 2>&1;
		swanctl --load-pools >/dev/null 2>&1; swanctl --load-creds >/dev/null 2>&1); then
		rollback_cleanup "$rollback_dir"
		return 0
	fi
	for file in network firewall pbr; do
		cp "$rollback_dir/$file" "/etc/config/$file"
	done
	rollback_cleanup "$rollback_dir"
	/etc/init.d/network reload >/dev/null 2>&1 || true
	/etc/init.d/firewall reload >/dev/null 2>&1 || true
	/etc/init.d/pbr restart >/dev/null 2>&1 || true
	die 'exit configuration validation failed; previous routing configuration restored'
}

sync_vip() {
	device="$(getv xfrm_device ipsec-home)"
	vip="$(swanctl --list-sas --raw 2>/dev/null |
		sed -n 's/.*site-link {.*local-vips=\[\([^]]*\)\].*/\1/p' |
		tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' |
		grep -m1 -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)"
	[ -n "$vip" ] || return 1
	current="$(ip -4 -o addr show dev "$device" scope global 2>/dev/null |
		awk 'NR == 1 { sub(/\/.*/, "", $4); print $4 }')"
	if [ "$current" != "$vip" ]; then
		ip -4 addr flush dev "$device" scope global
		ip -4 addr add "$vip/32" dev "$device"
	fi
	"$pbr_helper" >/dev/null 2>&1 || true
}

source_sa_ready() {
	swanctl --list-sas --raw 2>/dev/null |
		grep -Eq 'site-link4-[0-9]+ .*name=site-link4 .*state=INSTALLED'
}

source_pbr_ready() {
	/usr/sbin/nft list chain inet fw4 pbr_prerouting 2>/dev/null |
		grep -Fq 'comment "IKEv2 Site Link: YouTube"'
}

source_fail_closed_ready() {
	ip -4 route show table "pbr_$(getv interface sitehome)" 2>/dev/null |
		grep -Eq '^unreachable default metric 32767( |$)'
}

source_live_route_ready() {
	device="$(getv xfrm_device ipsec-home)"
	ip -4 route show table "pbr_$(getv interface sitehome)" 2>/dev/null |
		grep -Eq "^default dev $device( |$).*metric 10( |$)"
}

repair_source_pbr() {
	/etc/init.d/pbr restart >/dev/null 2>&1 || return 1
	"$pbr_helper" >/dev/null 2>&1 || true
	source_pbr_ready
}

exit_sa_ready() {
	swanctl --list-sas --raw 2>/dev/null |
		grep -Eq 'site-link-net-[0-9]+ .*state=INSTALLED'
}

data_plane_ready() {
	device="$(getv xfrm_device ipsec-home)"
	command -v curl >/dev/null 2>&1 || return 0
	curl -4fsS --interface "$device" --connect-timeout 3 --max-time 6 \
		-o /dev/null https://www.youtube.com/generate_204
}

connect_source() {
	ensure_xfrm
	swanctl --load-conns >/dev/null 2>&1
	swanctl --load-creds >/dev/null 2>&1
	swanctl --initiate --child site-link4 --timeout 20 >/dev/null 2>&1 || true
	sync_vip
}

apply_impl() {
	validate_config
	if [ "$(getv enabled 0)" != 1 ]; then
		disable_impl
		return
	fi
	if [ "$(role)" = exit ]; then
		secret_configured || die 'peer secret is not configured'
		render_exit
		exit_device="$(getv exit_device ipsec-site-exit)"
		exit_if_id="$(getv exit_if_id 45)"
		ensure_xfrm "$exit_device" "$exit_if_id"
		exit_apply_transaction
	else
		secret_configured || die 'peer secret is not configured'
		render_source
		ensure_xfrm
		source_apply_transaction
	fi
	/etc/init.d/ikev2-site-link enable >/dev/null 2>&1 || true
	/etc/init.d/ikev2-site-link restart >/dev/null 2>&1 || true
	status_write ok 'configuration applied'
}

disable_impl() {
	if [ "$(role)" = source ]; then
		swanctl --terminate --ike site-link --timeout 5 >/dev/null 2>&1 || true
		printf '%s\n' '# IKEv2 Site Link is disabled.' >"$conn_file.new"
		atomic_install "$conn_file.new" "$conn_file" 600
		printf '%s\n' '# IKEv2 Site Link secret is retained outside swanctl.' >"$cred_file.new"
		atomic_install "$cred_file.new" "$cred_file" 600
		source_uci_remove
		device="$(getv xfrm_device ipsec-home)"
		ip -4 addr flush dev "$device" scope global 2>/dev/null || true
		ip link set "$device" down 2>/dev/null || true
	else
		swanctl --terminate --ike site-link-in --timeout 5 >/dev/null 2>&1 || true
		printf '%s\n' '# IKEv2 Site Link exit is disabled.' >"$exit_conn_file.new"
		atomic_install "$exit_conn_file.new" "$exit_conn_file" 600
		printf '%s\n' '# IKEv2 Site Link exit secret is retained outside swanctl.' >"$exit_cred_file.new"
		atomic_install "$exit_cred_file.new" "$exit_cred_file" 600
		exit_uci_remove
		device="$(getv exit_device ipsec-site-exit)"
		ip link set "$device" down 2>/dev/null || true
	fi
	/etc/init.d/ikev2-site-link disable >/dev/null 2>&1 || true
	status_write disabled 'site link disabled'
}

status_write() {
	state="$1"
	detail="$2"
	now="$(date +%s)"
	cat >"$state_file.new" <<EOF
state=$state
detail=$detail
updated=$now
failures=${failures:-0}
EOF
	chmod 600 "$state_file.new"
	mv -f "$state_file.new" "$state_file"
}

status_emit() {
	enabled="$(getv enabled 0)"
	current_role="$(role)"
	device="$(getv xfrm_device ipsec-home)"
	printf 'enabled=%s\nrole=%s\nsecret=%s\n' "$enabled" "$current_role" \
		"$(secret_configured && echo configured || echo missing)"
	printf 'ike_port=%s\n' "$(getv ike_port 1500)"
	if [ "$current_role" = source ]; then
		printf 'interface=%s\ninterface_present=%s\n' "$device" \
			"$([ -d "/sys/class/net/$device" ] && echo 1 || echo 0)"
		printf 'sa=%s\n' "$(source_sa_ready && echo connected || echo disconnected)"
		printf 'vip=%s\n' "$(ip -4 -o addr show dev "$device" scope global 2>/dev/null |
			awk 'NR == 1 { print $4 }')"
		printf 'rx_bytes=%s\ntx_bytes=%s\n' \
			"$(cat "/sys/class/net/$device/statistics/rx_bytes" 2>/dev/null || echo 0)" \
			"$(cat "/sys/class/net/$device/statistics/tx_bytes" 2>/dev/null || echo 0)"
		printf 'fail_closed=%s\n' "$(ip -4 route show table "pbr_$(getv interface sitehome)" 2>/dev/null |
			grep -q '^unreachable default' && echo active || echo missing)"
	else
		device="$(getv exit_device ipsec-site-exit)"
		printf 'interface=%s\ninterface_present=%s\n' "$device" \
			"$([ -d "/sys/class/net/$device" ] && echo 1 || echo 0)"
		printf 'sa=%s\n' "$(exit_sa_ready && echo connected || echo disconnected)"
		printf 'rx_bytes=%s\ntx_bytes=%s\n' \
			"$(cat "/sys/class/net/$device/statistics/rx_bytes" 2>/dev/null || echo 0)" \
			"$(cat "/sys/class/net/$device/statistics/tx_bytes" 2>/dev/null || echo 0)"
		printf 'vip=%s\nfail_closed=not-applicable\n' "$(getv exit_pool 10.253.44.2)"
	fi
	[ ! -r "$state_file" ] || cat "$state_file"
	# Live invariants take precedence over a status file written just before a
	# PBR or SA transition. Never report OK while fail-closed protection, the
	# selected-service rule or the active tunnel route is missing.
	if [ "$enabled" = 1 ] && [ "$current_role" = source ]; then
		if source_sa_ready && source_pbr_ready && source_fail_closed_ready &&
		   source_live_route_ready; then
			printf 'state=ok\ndetail=tunnel and routing invariants are healthy\n'
		else
			printf 'state=degraded\ndetail=tunnel or routing invariant is missing\n'
		fi
	elif [ "$enabled" = 1 ] && [ "$current_role" = exit ]; then
		if exit_sa_ready; then
			printf 'state=ok\ndetail=peer is connected\n'
		else
			printf 'state=idle\ndetail=waiting for peer\n'
		fi
	fi
	return 0
}

monitor_loop() {
	failures=0
	first=1
	last_attempt=0
	pbr_misses=0
	last_pbr_repair=0
	while :; do
		if [ "$(getv enabled 0)" != 1 ]; then
			status_write disabled 'site link disabled'
			sleep 30
			continue
		fi
		if [ "$(role)" = source ]; then
			# A standalone firewall reload can rebuild fw4 without PBR's dynamic
			# domain rules. Restore them before declaring the data plane healthy.
			if source_pbr_ready; then
				pbr_misses=0
			else
				pbr_misses=$((pbr_misses + 1))
				# Avoid racing PBR while it is still starting or intentionally
				# rebuilding fw4. Repair only persistent drift.
				if [ "$pbr_misses" -ge 2 ]; then
					now="$(date +%s)"
					# A PBR restart rebuilds fw4. Keep repairs bounded if another
					# service is repeatedly reloading the firewall.
					if [ $((now - last_pbr_repair)) -ge 120 ]; then
						last_pbr_repair="$now"
						repair_source_pbr >/dev/null 2>&1 || true
					fi
					pbr_misses=0
				fi
			fi
			if [ "$first" = 1 ]; then
				connect_source >/dev/null 2>&1 || true
			fi
			# Remove the live default immediately when the CHILD_SA disappears.
			# The terminal unreachable route then remains the only route in the
			# policy table until sync_vip restores the encrypted data path.
			if ! source_sa_ready; then
				"$pbr_helper" >/dev/null 2>&1 || true
			fi
			if source_sa_ready && sync_vip && source_pbr_ready &&
			   source_fail_closed_ready && source_live_route_ready && data_plane_ready; then
				failures=0
				status_write ok 'tunnel and route are healthy'
			else
				failures=$((failures + 1))
				status_write degraded 'tunnel health check failed'
				threshold="$(getv failure_threshold 3)"
				if [ "$failures" -ge "$threshold" ]; then
					now="$(date +%s)"
					cooldown="$(getv reconnect_cooldown 30)"
					if [ $((now - last_attempt)) -ge "$cooldown" ]; then
						last_attempt="$now"
						connect_source >/dev/null 2>&1 || true
					fi
					failures="$threshold"
				fi
			fi
		else
			if [ "$first" = 1 ]; then
				device="$(getv exit_device ipsec-site-exit)"
				if_id="$(getv exit_if_id 45)"
				ensure_xfrm "$device" "$if_id" >/dev/null 2>&1 || true
				swanctl --load-conns >/dev/null 2>&1 || true
				swanctl --load-pools >/dev/null 2>&1 || true
				swanctl --load-creds --noprompt >/dev/null 2>&1 || true
				ip -4 route replace "$(getv exit_pool 10.253.44.2)/32" dev "$device" >/dev/null 2>&1 || true
			fi
			if exit_sa_ready; then
				status_write ok 'peer is connected'
			else
				status_write idle 'waiting for peer'
			fi
		fi
		first=0
		sleep "$(getv monitor_interval 15)"
	done
}

case "${1:-}" in
	apply) with_lock apply_impl ;;
	disable) with_lock disable_impl ;;
	connect) with_lock connect_source ;;
	secret-set) with_lock consume_secret_input "${2:-}" ;;
	status) status_emit ;;
	check) validate_config; status_emit ;;
	monitor) monitor_loop ;;
	render) if [ "$(role)" = exit ]; then render_exit; else render_source; fi ;;
	*) die 'usage: ikev2-site-link {apply|disable|connect|secret-set TOKEN|status|check|monitor|render}' ;;
esac
