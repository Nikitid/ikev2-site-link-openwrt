#!/bin/sh

set -eu
umask 077

config_name="${SITE_LINK_CONFIG:-ikev2-site-link}"
uci_dir="${SITE_LINK_UCI_DIR:-/etc/config}"
state_file="${SITE_LINK_STATE:-/var/run/ikev2-site-link.status}"
secret_file="${SITE_LINK_SECRET:-/etc/ikev2-site-link/client.secret}"
pending_secret_file="${SITE_LINK_PENDING_SECRET:-/etc/ikev2-site-link/client.secret.pending}"
previous_secret_file="${SITE_LINK_PREVIOUS_SECRET:-/etc/ikev2-site-link/client.secret.previous}"
domains_file="${SITE_LINK_DOMAINS:-/etc/ikev2-site-link/domains.txt}"
addresses_file="${SITE_LINK_ADDRESSES:-/etc/ikev2-site-link/addresses.txt}"
conn_file="${SITE_LINK_CONN:-/etc/swanctl/conf.d/40-site-link.conf}"
cred_file="${SITE_LINK_CRED:-/etc/swanctl/conf.d/92-site-link-secret.conf}"
exit_conn_file="${SITE_LINK_EXIT_CONN:-/etc/swanctl/conf.d/41-site-link-exit.conf}"
exit_cred_file="${SITE_LINK_EXIT_CRED:-/etc/swanctl/conf.d/93-site-link-exit-secret.conf}"
pbr_helper="${SITE_LINK_PBR_HELPER:-/usr/share/pbr/pbr.user.site-link}"
pbr_runtime_config="${SITE_LINK_PBR_RUNTIME_CONFIG:-/var/run/ikev2-site-link-pbr.conf}"
lock_dir="${SITE_LINK_LOCK:-/var/run/ikev2-site-link.lock}"
monitor_lock_dir="${SITE_LINK_MONITOR_LOCK:-/var/run/ikev2-site-link-monitor.lock}"
action_lock_dir="${IKEV2_ACTION_LOCK:-/var/run/ikev2-action.lock}"
action_lock_status="${IKEV2_ACTION_LOCK_STATUS:-/var/run/ikev2-action.lock.status}"
pbr_init="${SITE_LINK_PBR_INIT:-/etc/init.d/pbr}"
site_init="${SITE_LINK_INIT:-/etc/init.d/ikev2-site-link}"
network_init="${SITE_LINK_NETWORK_INIT:-/etc/init.d/network}"
firewall_init="${SITE_LINK_FIREWALL_INIT:-/etc/init.d/firewall}"
fw4_bin="${SITE_LINK_FW4:-fw4}"
nft_bin="${SITE_LINK_NFT:-/usr/sbin/nft}"
probe_state="${SITE_LINK_PROBE_STATE:-/var/run/ikev2-site-link-probe.status}"
exit_traffic_state="${SITE_LINK_EXIT_TRAFFIC_STATE:-/var/run/ikev2-site-link-exit-traffic.status}"
probe_url="${SITE_LINK_PROBE_URL:-https://www.youtube.com/generate_204}"
probe_fallback_url="${SITE_LINK_PROBE_FALLBACK_URL:-https://cloudflare.com/cdn-cgi/trace}"
probe_rule_priority="${SITE_LINK_PROBE_RULE_PRIORITY:-10444}"
set_dump4="${SITE_LINK_SET_DUMP4:-/var/run/ikev2-site-link-set4.dump}"
set_dump6="${SITE_LINK_SET_DUMP6:-/var/run/ikev2-site-link-set6.dump}"
persistent_set_dump4="${SITE_LINK_PERSISTENT_SET_DUMP4:-/etc/ikev2-site-link/pbr-set4.dump}"
persistent_set_dump6="${SITE_LINK_PERSISTENT_SET_DUMP6:-/etc/ikev2-site-link/pbr-set6.dump}"
set_dump_max_age="${SITE_LINK_SET_DUMP_MAX_AGE:-3600}"
guard_nft_table="${SITE_LINK_GUARD_NFT_TABLE:-ikev2_site_link_guard}"
guard_route_table="${SITE_LINK_GUARD_ROUTE_TABLE:-10445}"
guard_rule_priority="${SITE_LINK_GUARD_RULE_PRIORITY:-10445}"
guard_mark="${SITE_LINK_GUARD_MARK:-0x01000000}"
guard_mask="${SITE_LINK_GUARD_MASK:-0x01000000}"
guard_config_file="${SITE_LINK_GUARD_CONFIG:-/var/run/ikev2-site-link-guard.nft}"
rollback_root="${SITE_LINK_ROLLBACK_ROOT:-/var/run}"
secret_input_dir="${SITE_LINK_SECRET_INPUT_DIR:-/var/run}"
server_cert_file="${SITE_LINK_SERVER_CERT:-/etc/swanctl/x509/ikev2.pem}"
server_key_file="${SITE_LINK_SERVER_KEY:-/etc/swanctl/private/ikev2.key}"
server_cert_state="${SITE_LINK_CERT_STATE:-/var/run/ikev2-site-link-cert.status}"
config_section=main
action_lock_owned=0

uci() {
	command uci -c "$uci_dir" "$@"
}

getv() {
	uci -q get "$config_name.$config_section.$1" 2>/dev/null || printf '%s\n' "${2:-}"
}

applied_exists() {
	[ "$(uci -q get "$config_name.applied" 2>/dev/null || true)" = state ] &&
	[ "$(uci -q get "$config_name.applied.enabled" 2>/dev/null || true)" = 1 ] &&
	case "$(uci -q get "$config_name.applied.role" 2>/dev/null || true)" in
		source | exit) return 0 ;;
		*) return 1 ;;
	esac
}

use_candidate_config() {
	config_section=main
}

use_applied_config() {
	applied_exists || return 1
	config_section=applied
}

die() {
	printf 'ikev2-site-link: %s\n' "$*" >&2
	exit 1
}

valid_name() {
	case "$1" in '' | *[!A-Za-z0-9_.@-]*) return 1 ;; esac
}

valid_uci_name() {
	case "$1" in '' | *[!A-Za-z0-9_]* | [0-9]*) return 1 ;; esac
}

valid_device() {
	case "$1" in '' | *[!A-Za-z0-9_.-]*) return 1 ;; esac
	[ "${#1}" -le 15 ]
}

valid_source_selectors() {
	[ -n "$1" ] || return 1
	for selector in $1; do
		case "$selector" in @*) valid_device "${selector#@}" || return 1 ;; *) return 1 ;; esac
	done
}

valid_uint() {
	case "$1" in '' | *[!0-9]*) return 1 ;; esac
}

valid_hex() {
	printf '%s\n' "$1" | grep -Eq '^0x[0-9A-Fa-f]{1,8}$'
}

valid_ipv4() {
	printf '%s\n' "$1" | awk -F. '
		NF != 4 { exit 1 }
		{ for (i = 1; i <= 4; i++)
			if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255) exit 1 }
	'
}

valid_private_ipv4() {
	valid_ipv4 "$1" || return 1
	printf '%s\n' "$1" | awk -F. '
		$1 == 10 { ok=1 }
		$1 == 172 && $2 >= 16 && $2 <= 31 { ok=1 }
		$1 == 192 && $2 == 168 { ok=1 }
		END { exit !ok }
	'
}

atomic_install() {
	source="$1"
	target="$2"
	mode="$3"
	chmod "$mode" "$source" || return 1
	mv -f "$source" "$target"
}

file_mtime() {
	date -r "$1" +%s 2>/dev/null ||
		stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

sha256_stream() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum
	else
		shasum -a 256
	fi
}

pid_lock_acquire() {
	dir="$1"
	if ! mkdir "$dir" 2>/dev/null; then
		pid="$(cat "$dir/pid" 2>/dev/null || true)"
		if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
			return 1
		fi
		rm -f "$dir/pid"
		rmdir "$dir" 2>/dev/null || return 1
		mkdir "$dir" 2>/dev/null || return 1
	fi
	printf '%s\n' "$$" >"$dir/pid"
}

pid_lock_release() {
	dir="$1"
	[ "$(cat "$dir/pid" 2>/dev/null || true)" = "$$" ] || return 0
	rm -f "$dir/pid"
	rmdir "$dir" 2>/dev/null || true
}

action_lock_acquire() {
	action="$1"
	max_tries="${2:-${SITE_LINK_ACTION_LOCK_WAIT:-60}}"
	case "$max_tries" in '' | *[!0-9]*) max_tries=60 ;; esac
	tries=0
	while ! mkdir "$action_lock_dir" 2>/dev/null; do
		pid="$(sed -n 's/^pid=//p' "$action_lock_status" 2>/dev/null | tail -n1)"
		updated="$(sed -n 's/^updated=//p' "$action_lock_status" 2>/dev/null | tail -n1)"
		now="$(date +%s)"
		case "$updated" in '' | *[!0-9]*) updated=0 ;; esac
		if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null &&
		   [ $((now - updated)) -le 3600 ]; then
			tries=$((tries + 1))
			[ "$tries" -lt "$max_tries" ] || return 1
			sleep 1
			continue
		fi
		# mkdir() and publishing the owner file are separate. Do not steal a
		# fresh, empty lock during that hand-off window.
		if [ -z "$pid" ] && [ "$tries" -lt 3 ]; then
			[ "$max_tries" -gt 1 ] || return 1
			tries=$((tries + 1))
			sleep 1
			continue
		fi
		rm -f "$action_lock_status"
		rmdir "$action_lock_dir" 2>/dev/null || true
	done
	action_lock_owned=1
	{
		printf 'owner=site-link\n'
		printf 'action_id=%s\n' "$action"
		printf 'pid=%s\n' "$$"
		printf 'updated=%s\n' "$(date +%s)"
	} >"$action_lock_status.new.$$"
	mv "$action_lock_status.new.$$" "$action_lock_status"
	logger -t ikev2-action "begin owner=site-link action_id=$action pid=$$" 2>/dev/null || true
}

action_lock_release() {
	[ "$action_lock_owned" = 1 ] || return 0
	owner_pid="$(sed -n 's/^pid=//p' "$action_lock_status" 2>/dev/null | tail -n1)"
	[ -z "$owner_pid" ] || [ "$owner_pid" = "$$" ] || return 0
	rm -f "$action_lock_status"
	rmdir "$action_lock_dir" 2>/dev/null || true
	logger -t ikev2-action "end owner=site-link pid=$$" 2>/dev/null || true
	action_lock_owned=0
}

locks_release() {
	action_lock_release
	pid_lock_release "$lock_dir"
}

with_lock() {
	action="$1"
	shift
	pid_lock_acquire "$lock_dir" || die 'another site-link action is still running'
	action_lock_acquire "$action" || {
		pid_lock_release "$lock_dir"
		die 'another network action is still running'
	}
	trap 'locks_release' EXIT
	trap 'locks_release; exit 130' HUP INT TERM
	"$@"
	locks_release
	trap - EXIT HUP INT TERM
}

try_with_lock() {
	action="$1"
	shift
	pid_lock_acquire "$lock_dir" || return 1
	action_lock_acquire "$action" 1 || {
		pid_lock_release "$lock_dir"
		return 1
	}
	# This helper runs inside monitor_loop. Do not replace its signal traps:
	# clearing a nested trap here leaves the long-running monitor unable to
	# perform a clean procd stop after its first repair attempt.
	result=0
	"$@" || result=$?
	locks_release
	return "$result"
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
	probe_interval="$(getv probe_interval 60)"
	ike_port="$(getv ike_port 1500)"
	for value in "$if_id" "$exit_if_id" "$mtu" "$dpd" "$interval" "$threshold" "$cooldown" "$probe_interval" "$ike_port"; do
		valid_uint "$value" || die 'numeric setting contains a non-number'
	done
	[ "$if_id" -ge 1 ] && [ "$if_id" -le 4294967295 ] || die 'invalid XFRM if_id'
	[ "$exit_if_id" -ge 1 ] && [ "$exit_if_id" -le 4294967295 ] || die 'invalid exit XFRM if_id'
	[ "$if_id" != "$exit_if_id" ] || die 'source and exit XFRM if_id values must differ'
	case "$if_id:$exit_if_id" in
		42:* | 43:* | *:42 | *:43) die 'XFRM if_id 42 and 43 are reserved by IKEv2 Manager' ;;
	esac
	[ "$mtu" -ge 1200 ] && [ "$mtu" -le 1500 ] || die 'MTU must be 1200-1500'
	[ "$dpd" -ge 5 ] && [ "$dpd" -le 300 ] || die 'DPD interval must be 5-300 seconds'
	[ "$interval" -ge 5 ] && [ "$interval" -le 300 ] || die 'monitor interval must be 5-300 seconds'
	[ "$threshold" -ge 1 ] && [ "$threshold" -le 20 ] || die 'failure threshold must be 1-20'
	[ "$cooldown" -ge 15 ] && [ "$cooldown" -le 3600 ] || die 'reconnect cooldown must be 15-3600 seconds'
	[ "$probe_interval" -ge 30 ] && [ "$probe_interval" -le 3600 ] || die 'probe interval must be 30-3600 seconds'
	[ "$ike_port" -ge 1024 ] && [ "$ike_port" -le 65535 ] || die 'external IKE port must be 1024-65535'
	[ "$ike_port" != 4500 ] || die 'external IKE port 4500 conflicts with standard IKE NAT-T'
	case "$probe_url:$probe_fallback_url" in
		https://*:https://*) ;;
		*) die 'data-plane probe URLs must use HTTPS' ;;
	esac
	valid_uci_name "$guard_nft_table" || die 'invalid guard nftables table name'
	valid_uint "$guard_route_table" && [ "$guard_route_table" -ge 1 ] &&
		[ "$guard_route_table" -le 4294967295 ] || die 'invalid guard route table'
	valid_uint "$guard_rule_priority" && [ "$guard_rule_priority" -ge 1 ] &&
		[ "$guard_rule_priority" -le 4294967295 ] || die 'invalid guard rule priority'
	[ "$guard_rule_priority" != "$probe_rule_priority" ] ||
		die 'guard and probe rule priorities must differ'
	valid_hex "$guard_mark" && valid_hex "$guard_mask" || die 'invalid guard mark or mask'
	[ $((guard_mark & guard_mask)) -eq $((guard_mark)) ] && [ $((guard_mark)) -ne 0 ] ||
		die 'guard mark must be non-zero and contained by its mask'
	interface="$(getv interface sitehome)"
	exit_interface="$(getv exit_interface siteexit)"
	device="$(getv xfrm_device ipsec-home)"
	exit_device="$(getv exit_device ipsec-site-exit)"
	exit_wan="$(getv exit_wan wan)"
	exit_wan_zone="$(getv exit_wan_zone "$exit_wan")"
	source_wan="$(getv source_wan wan)"
	valid_uci_name "$interface" || die 'invalid source network name'
	valid_uci_name "$exit_interface" || die 'invalid exit network name'
	valid_device "$device" || die 'invalid source XFRM device name'
	valid_device "$exit_device" || die 'invalid exit XFRM device name'
	valid_uci_name "$exit_wan" || die 'invalid exit WAN network/interface name'
	valid_uci_name "$exit_wan_zone" || die 'invalid exit WAN firewall zone name'
	valid_uci_name "$source_wan" || die 'invalid source WAN network name'
	[ "$interface" != "$exit_interface" ] || die 'source and exit network names must differ'
	[ "$device" != "$exit_device" ] || die 'source and exit XFRM device names must differ'
	exit_pool="$(getv exit_pool 10.253.44.2)"
	valid_private_ipv4 "$exit_pool" || die 'exit pool must be one RFC1918 IPv4 address'
	if [ "$current_role" = source ]; then
		endpoint="$(getv endpoint)"
		remote_id="$(getv remote_id)"
		[ -n "$endpoint" ] || die 'source endpoint is required'
		valid_name "$endpoint" || die 'invalid source endpoint'
		[ -n "$remote_id" ] || die 'remote identity is required'
		valid_name "$remote_id" || die 'invalid remote identity'
		valid_source_selectors "$(getv source_devices '@br-lan')" ||
			die 'protected sources must be @device selectors'
	else
		remote_id="$(getv remote_id)"
		if [ -z "$remote_id" ] || ! valid_name "$remote_id"; then
			die 'exit certificate identity is required'
		fi
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
	input="$secret_input_dir/ikev2-site-link-secret-$token.in"
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
	target="$pending_secret_file"
	# Initial provisioning has nothing to rotate and is made active immediately.
	# Every later update is staged so editing one router cannot silently replace
	# the credential used by a live peer.
	[ -s "$secret_file" ] || target="$secret_file"
	cp "$input" "$target.new"
	rm -f "$input"
	atomic_install "$target.new" "$target" 600
}

secret_pending() {
	[ -s "$pending_secret_file" ]
}

restore_previous_secret() {
	[ -s "$previous_secret_file" ] || return 1
	cp "$previous_secret_file" "$secret_file.new" || return 1
	atomic_install "$secret_file.new" "$secret_file" 600
}

load_active_secret() {
	if [ "$(role)" = exit ]; then
		render_exit || return 1
		swanctl --load-creds --noprompt >/dev/null 2>&1
	else
		render_source || return 1
		swanctl --load-creds --noprompt >/dev/null 2>&1
	fi
}

activate_secret_impl() {
	live=1
	use_applied_config || { use_candidate_config; live=0; }
	secret_pending || die 'no replacement secret is staged'
	secret_configured || die 'active peer secret is missing'
	cp "$secret_file" "$previous_secret_file.new" || die 'unable to back up active secret'
	atomic_install "$previous_secret_file.new" "$previous_secret_file" 600 ||
		die 'unable to back up active secret'
	cp "$pending_secret_file" "$secret_file.new" || die 'unable to activate staged secret'
	atomic_install "$secret_file.new" "$secret_file" 600 || die 'unable to activate staged secret'
	if [ "$live" = 0 ]; then
		rm -f "$pending_secret_file"
		return 0
	fi
	if [ "$(role)" = exit ]; then
		if ! load_active_secret; then
			restore_previous_secret >/dev/null 2>&1 || true
			load_active_secret >/dev/null 2>&1 || true
			die 'secret activation failed; previous exit credential restored'
		fi
		# Do not terminate the current SA. Activate the exit first, then the
		# source; the established tunnel survives the short credential handoff.
		rm -f "$pending_secret_file"
		return 0
	fi
	if load_active_secret && reset_source_sa && connect_source && source_control_ready; then
		rm -f "$pending_secret_file"
		if data_plane_ready; then probe_save 1; else probe_save 0; fi
		return 0
	fi
	restore_previous_secret >/dev/null 2>&1 || true
	load_active_secret >/dev/null 2>&1 || true
	reset_source_sa >/dev/null 2>&1 || true
	connect_source >/dev/null 2>&1 || true
	die 'secret activation failed; previous source credential restored locally; restore the previous exit credential before reconnecting'
}

rollback_secret_impl() {
	live=1
	use_applied_config || { use_candidate_config; live=0; }
	restore_previous_secret || die 'no previous secret is available'
	[ "$live" = 1 ] || return 0
	load_active_secret || die 'previous secret restored on disk but credential reload failed'
	if [ "$(role)" = source ]; then
		reset_source_sa >/dev/null 2>&1 || true
		connect_source || die 'previous secret restored but source reconnect failed'
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
	modprobe xfrm_interface || return 1
	if ip link show "$device" >/dev/null 2>&1; then
		xfrm_device_matches "$device" "$if_id" ||
			die "device $device exists but is not the configured XFRM interface"
	else
		ip link add "$device" type xfrm if_id "$if_id" || return 1
	fi
	ip link set "$device" mtu "$mtu" up
}

xfrm_device_matches() {
	device="$1"
	if_id="$2"
	if_id_hex="$(printf '%x' "$if_id")"
	ip -d link show "$device" 2>/dev/null |
		grep -Eq "xfrm .*if_id (0x0*$if_id_hex|$if_id)( |$)"
}

xfrm_ready() {
	device="$1"
	if_id="$2"
	mtu="$(getv mtu 1360)"
	xfrm_device_matches "$device" "$if_id" || return 1
	ip link show "$device" 2>/dev/null | grep -Eq '<[^>]*UP([,>])' || return 1
	ip -o link show "$device" 2>/dev/null |
		awk -v wanted="$mtu" '{ for (i = 1; i <= NF; i++) if ($i == "mtu") exit ($(i + 1) != wanted); exit 1 }'
}

delete_owned_xfrm() {
	device="$1"
	if_id="$2"
	ip link show "$device" >/dev/null 2>&1 || return 0
	xfrm_device_matches "$device" "$if_id" || {
		printf 'ikev2-site-link: refusing to delete foreign device %s\n' "$device" >&2
		return 1
	}
	ip link delete "$device"
}

delete_xfrm_candidate() {
	device="$1"
	if_id="$2"
	valid_device "$device" && valid_uint "$if_id" || return 0
	delete_owned_xfrm "$device" "$if_id"
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

zone_for_device() {
	wanted="$1"
	for section in $(uci show firewall 2>/dev/null |
		sed -n 's/^firewall\.\([^.=]*\)=zone$/\1/p'); do
		zone="$(uci -q get "firewall.$section.name" 2>/dev/null || true)"
		valid_uci_name "$zone" || continue
		for zone_device in $(uci -q get "firewall.$section.device" 2>/dev/null || true); do
			[ "$zone_device" = "$wanted" ] && {
				printf '%s\n' "$zone"
				return 0
			}
		done
		for network in $(uci -q get "firewall.$section.network" 2>/dev/null || true); do
			[ "$(uci -q get "network.$network.device" 2>/dev/null || true)" = "$wanted" ] && {
				printf '%s\n' "$zone"
				return 0
			}
		done
	done
	return 1
}

source_forwarding_zones() {
	seen=' '
	for selector in $(getv source_devices '@br-lan'); do
		zone="$(zone_for_device "${selector#@}")" || return 1
		case "$seen" in *" $zone "*) continue ;; esac
		printf '%s\n' "$zone"
		seen="$seen$zone "
	done
}

remove_source_forwardings() {
	for section in $(uci show firewall 2>/dev/null |
		sed -n 's/^firewall\.\(ikev2_site_link_src_[0-9][0-9]*\)=forwarding$/\1/p'); do
		uci -q delete "firewall.$section" || true
	done
	uci -q delete firewall.ikev2_site_link_forward || true
	uci -q delete firewall.ikev2_site_link_inbound || true
}

pbr_reload_checked() {
	# pbr/procd may return 1 even after completing a successful reload. Treat
	# the init-script status only as a trigger result and decide from the live
	# runtime: the service must be running and its fw4 chain must exist.
	logger -t ikev2-pbr-action "begin owner=site-link action=reload pid=$$" 2>/dev/null || true
	"$pbr_init" reload >/dev/null 2>&1 || true
	tries=0
	while [ "$tries" -lt 30 ]; do
		if "$pbr_init" running >/dev/null 2>&1 &&
		   "$nft_bin" list chain inet fw4 pbr_prerouting >/dev/null 2>&1; then
			logger -t ikev2-pbr-action "end owner=site-link action=reload pid=$$" 2>/dev/null || true
			return 0
		fi
		tries=$((tries + 1))
		sleep 1
	done
	logger -t ikev2-pbr-action "error owner=site-link action=reload pid=$$" 2>/dev/null || true
	return 1
}

reload_routing_services() {
	"$fw4_bin" check >/dev/null || return 1
	"$network_init" reload >/dev/null || return 1
	"$firewall_init" reload >/dev/null || return 1
	pbr_reload_checked
}

render_pbr_runtime_config() {
	interface="$(getv interface sitehome)"
	device="$(getv xfrm_device ipsec-home)"
	force_tcp="$(getv force_tcp 1)"
	valid_uci_name "$interface" && valid_device "$device" || return 1
	[ "$force_tcp" = 0 ] || [ "$force_tcp" = 1 ] || return 1
	mkdir -p "${pbr_runtime_config%/*}"
	{
		printf 'interface=%s\n' "$interface"
		printf 'device=%s\n' "$device"
		printf 'force_tcp=%s\n' "$force_tcp"
	} >"$pbr_runtime_config.new"
	atomic_install "$pbr_runtime_config.new" "$pbr_runtime_config" 600
}

source_uci_apply() {
	device="$(getv xfrm_device ipsec-home)"
	interface="$(getv interface sitehome)"
	sources="$(getv source_devices '@br-lan')"
	zones="$(source_forwarding_zones)" || return 1
	render_pbr_runtime_config || return 1
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
	remove_source_forwardings
	index=1
	for source_zone in $zones; do
		section="ikev2_site_link_src_$index"
		uci set "firewall.$section=forwarding"
		uci set "firewall.$section.src=$source_zone"
		uci set "firewall.$section.dest=$interface"
		index=$((index + 1))
	done
	if ! uci -q get pbr.config.supported_interface 2>/dev/null |
		tr ' ' '\n' | grep -Fxq "$interface"; then
		uci add_list "pbr.config.supported_interface=$interface"
	fi
	uci set pbr.ikev2_site_link=policy
	uci set pbr.ikev2_site_link.name='IKEv2 Site Link: selected services'
	uci set pbr.ikev2_site_link.interface="$interface"
	uci set pbr.ikev2_site_link.src_addr="$sources"
	uci set pbr.ikev2_site_link.dest_addr="file://$domains_file file://$addresses_file"
	uci set pbr.ikev2_site_link.proto='all'
	uci set pbr.ikev2_site_link.enabled=1
	# The narrow site-link policy must win before broader application policies
	# when two DNS names temporarily resolve to the same CDN address. Keep the
	# global PBR config first and place this policy immediately after it.
	uci reorder pbr.ikev2_site_link=1
	uci set pbr.ikev2_site_link_include=include
	uci set pbr.ikev2_site_link_include.path="$pbr_helper"
	uci set pbr.ikev2_site_link_include.enabled=1
	uci commit network || return 1
	uci commit firewall || return 1
	uci commit pbr || return 1
	reload_routing_services || return 1
	ensure_probe_rule || return 1
	repair_source_aux
}

exit_uci_apply() {
	interface="$(getv exit_interface siteexit)"
	device="$(getv exit_device ipsec-site-exit)"
	wan="$(getv exit_wan wan)"
	wan_zone="$(getv exit_wan_zone "$wan")"
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
	uci set firewall.ikev2_site_link_exit_wan.dest="$wan_zone"
	# A custom IKE port carries both IKE (with a non-ESP marker) and UDP-
	# encapsulated ESP. Translate it to strongSwan's NAT-T socket, not its
	# plain UDP/500 socket. The distinct public five-tuple avoids collisions
	# with a road-warrior IKE session between the same two public routers.
	uci set firewall.ikev2_site_link_ike=redirect
	uci set firewall.ikev2_site_link_ike.name='IKEv2 Site Link: dedicated IKE port'
	uci set firewall.ikev2_site_link_ike.src="$wan_zone"
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
	uci commit network || return 1
	uci commit firewall || return 1
	uci commit pbr || return 1
	reload_routing_services
	ip -4 route replace "$exit_pool/32" dev "$device"
}

all_uci_remove() {
	source_interface="$(getv interface sitehome)"
	exit_interface="$(getv exit_interface siteexit)"
	applied_source_interface="$(applied_get interface "$source_interface")"
	applied_exit_interface="$(applied_get exit_interface "$exit_interface")"
	for managed_interface in "$source_interface" "$exit_interface" \
		"$applied_source_interface" "$applied_exit_interface"; do
		valid_uci_name "$managed_interface" || continue
		uci -q delete "network.$managed_interface" || true
	done
	for section in ikev2_site_link ikev2_site_link_forward ikev2_site_link_inbound \
		ikev2_site_link_exit ikev2_site_link_exit_wan ikev2_site_link_ike; do
		uci -q delete "firewall.$section" || true
	done
	remove_source_forwardings
	uci -q delete pbr.ikev2_site_link || true
	uci -q delete pbr.ikev2_site_link_include || true
	uci -q del_list "pbr.config.supported_interface=$source_interface" || true
	uci -q del_list "pbr.config.supported_interface=$applied_source_interface" || true
	uci commit network || return 1
	uci commit firewall || return 1
	uci commit pbr || return 1
	reload_routing_services
	rm -f "$pbr_runtime_config"
}

inactive_role_present() {
	if [ "$(role)" = source ]; then
		uci -q get "network.$(getv exit_interface siteexit)" >/dev/null 2>&1 ||
			grep -Fq 'site-link-in {' "$exit_conn_file" 2>/dev/null
	else
		uci -q get "network.$(getv interface sitehome)" >/dev/null 2>&1 ||
			grep -Fq 'site-link {' "$conn_file" 2>/dev/null
	fi
}

applied_get() {
	uci -q get "$config_name.applied.$1" 2>/dev/null || printf '%s\n' "${2:-}"
}

applied_resources_match() {
	if applied_exists; then
		[ "$(applied_get role)" = "$(role)" ] &&
		[ "$(applied_get interface)" = "$(getv interface sitehome)" ] &&
		[ "$(applied_get xfrm_device)" = "$(getv xfrm_device ipsec-home)" ] &&
		[ "$(applied_get if_id)" = "$(getv if_id 44)" ] &&
		[ "$(applied_get exit_interface)" = "$(getv exit_interface siteexit)" ] &&
		[ "$(applied_get exit_device)" = "$(getv exit_device ipsec-site-exit)" ] &&
		[ "$(applied_get exit_if_id)" = "$(getv exit_if_id 45)" ] &&
		[ "$(applied_get exit_pool)" = "$(getv exit_pool 10.253.44.2)" ]
		return
	fi
	# Migration from releases without applied-state: the generated firewall
	# section and swanctl profile still reveal the active source resources.
	if uci -q get firewall.ikev2_site_link >/dev/null 2>&1; then
		old_interface="$(uci -q get firewall.ikev2_site_link.name 2>/dev/null || true)"
		old_device="$(uci -q get "network.$old_interface.device" 2>/dev/null || true)"
		old_if_id="$(sed -n 's/^[[:space:]]*if_id_in = //p' "$conn_file" 2>/dev/null | head -n1)"
		[ "$(role)" = source ] &&
		[ "$old_interface" = "$(getv interface sitehome)" ] &&
		[ "$old_device" = "$(getv xfrm_device ipsec-home)" ] &&
		[ "$old_if_id" = "$(getv if_id 44)" ]
		return
	fi
	if uci -q get firewall.ikev2_site_link_exit >/dev/null 2>&1; then
		old_interface="$(uci -q get firewall.ikev2_site_link_exit.name 2>/dev/null || true)"
		old_device="$(uci -q get "network.$old_interface.device" 2>/dev/null || true)"
		old_if_id="$(sed -n 's/^[[:space:]]*if_id_in = //p' "$exit_conn_file" 2>/dev/null | head -n1)"
		[ "$(role)" = exit ] &&
		[ "$old_interface" = "$(getv exit_interface siteexit)" ] &&
		[ "$old_device" = "$(getv exit_device ipsec-site-exit)" ] &&
		[ "$old_if_id" = "$(getv exit_if_id 45)" ]
		return
	fi
	return 0
}

record_applied_resources() {
	uci set "$config_name.applied=state"
	for option in enabled role endpoint remote_id peer_user ike_port source_devices \
		source_wan interface xfrm_device if_id exit_interface exit_device \
		exit_if_id exit_pool exit_wan exit_wan_zone mtu dpd monitor_interval \
		probe_interval failure_threshold reconnect_cooldown force_tcp; do
		value="$(getv "$option")"
		[ -n "$value" ] && uci set "$config_name.applied.$option=$value" ||
			uci -q delete "$config_name.applied.$option" || true
	done
	uci set "$config_name.applied.enabled=1"
	uci commit "$config_name"
}

migrate_applied_impl() {
	applied_exists && return 0
	[ "$(getv enabled 0)" = 1 ] || return 0
	if uci -q get firewall.ikev2_site_link >/dev/null 2>&1 ||
	   uci -q get firewall.ikev2_site_link_exit >/dev/null 2>&1; then
		validate_config
		record_applied_resources
	fi
}

candidate_applied_match() {
	applied_exists || return 1
	for option in enabled role endpoint remote_id peer_user ike_port source_devices \
		source_wan interface xfrm_device if_id exit_interface exit_device exit_if_id exit_pool \
		exit_wan exit_wan_zone mtu dpd monitor_interval probe_interval \
		failure_threshold reconnect_cooldown force_tcp; do
		[ "$(uci -q get "$config_name.main.$option" 2>/dev/null || true)" = \
			"$(uci -q get "$config_name.applied.$option" 2>/dev/null || true)" ] || return 1
	done
}

rollback_cleanup() {
	directory="$1"
	for file in network firewall pbr app-config conn cred pbr-runtime \
		app-config.missing conn.missing cred.missing pbr-runtime.missing; do
		rm -f "$directory/$file"
	done
	rmdir "$directory" 2>/dev/null || true
}

rollback_file_backup() {
	source="$1"
	target="$2"
	if [ -f "$source" ] && [ ! -L "$source" ]; then
		cp "$source" "$target"
	else
		: >"$target.missing"
	fi
}

rollback_file_restore() {
	backup="$1"
	target="$2"
	if [ -f "$backup.missing" ]; then
		rm -f "$target"
	else
		cp "$backup" "$target.new"
		atomic_install "$target.new" "$target" 600
	fi
}

reset_source_sa() {
	source_sa_ready || return 0
	swanctl --terminate --ike site-link --timeout 5 >/dev/null 2>&1
}

reset_exit_sa() {
	exit_sa_ready || return 0
	swanctl --terminate --ike site-link-in --timeout 5 >/dev/null 2>&1
}

source_apply_transaction() {
	rollback_dir="$rollback_root/ikev2-site-link-rollback-$$"
	mkdir "$rollback_dir" || die 'unable to create routing rollback snapshot'
	for file in network firewall pbr; do
		cp "$uci_dir/$file" "$rollback_dir/$file" || {
			rollback_cleanup "$rollback_dir"
			die 'unable to create routing rollback snapshot'
		}
	done
	rollback_file_backup "$uci_dir/$config_name" "$rollback_dir/app-config" || {
		rollback_cleanup "$rollback_dir"
		die 'unable to back up applied configuration state'
	}
	rollback_file_backup "$conn_file" "$rollback_dir/conn" || {
		rollback_cleanup "$rollback_dir"
		die 'unable to back up source profile'
	}
	rollback_file_backup "$cred_file" "$rollback_dir/cred" || {
		rollback_cleanup "$rollback_dir"
		die 'unable to back up source credential'
	}
	rollback_file_backup "$pbr_runtime_config" "$rollback_dir/pbr-runtime" || {
		rollback_cleanup "$rollback_dir"
		die 'unable to back up PBR runtime snapshot'
	}
	had_previous=0
	grep -Fq 'site-link {' "$rollback_dir/conn" 2>/dev/null && had_previous=1
	# Do not validate a changed endpoint, identity or credential through an SA
	# established from the previous profile.
	if render_source && ensure_xfrm && source_uci_apply && guard_sync && reset_source_sa &&
	   connect_source && guard_sync && source_control_ready && data_plane_ready &&
	   persist_pbr_sets && record_applied_resources; then
		rollback_cleanup "$rollback_dir"
		return 0
	fi
	swanctl --terminate --ike site-link --timeout 5 >/dev/null 2>&1 || true
	rollback_ok=1
	rollback_file_restore "$rollback_dir/app-config" "$uci_dir/$config_name" || rollback_ok=0
	for file in network firewall pbr; do
		cp "$rollback_dir/$file" "$uci_dir/$file" || rollback_ok=0
	done
	rollback_file_restore "$rollback_dir/conn" "$conn_file" || rollback_ok=0
	rollback_file_restore "$rollback_dir/cred" "$cred_file" || rollback_ok=0
	rollback_file_restore "$rollback_dir/pbr-runtime" "$pbr_runtime_config" || rollback_ok=0
	"$network_init" reload >/dev/null 2>&1 || rollback_ok=0
	"$firewall_init" reload >/dev/null 2>&1 || rollback_ok=0
	pbr_reload_checked >/dev/null 2>&1 || rollback_ok=0
	swanctl --load-conns >/dev/null 2>&1 || rollback_ok=0
	swanctl --load-creds --noprompt >/dev/null 2>&1 || rollback_ok=0
	device="$(getv xfrm_device ipsec-home)"
	if [ "$had_previous" = 1 ]; then
		connect_source >/dev/null 2>&1 || true
		guard_sync >/dev/null 2>&1 || rollback_ok=0
	else
		guard_remove >/dev/null 2>&1 || rollback_ok=0
		delete_probe_rule "$device" "$(getv interface sitehome)" >/dev/null 2>&1 || true
		ip -4 addr flush dev "$device" scope global 2>/dev/null || true
		delete_xfrm_candidate "$device" "$(getv if_id 44)" >/dev/null 2>&1 || true
	fi
	rollback_cleanup "$rollback_dir"
	if [ "$rollback_ok" != 1 ]; then
		"$site_init" stop >/dev/null 2>&1 || true
		die 'tunnel validation failed and rollback is incomplete; monitor stopped'
	fi
	die 'tunnel validation failed; previous routing configuration restored'
}

exit_apply_transaction() {
	rollback_dir="$rollback_root/ikev2-site-link-rollback-$$"
	mkdir "$rollback_dir" || die 'unable to create routing rollback snapshot'
	for file in network firewall pbr; do
		cp "$uci_dir/$file" "$rollback_dir/$file" || {
			rollback_cleanup "$rollback_dir"
			die 'unable to create routing rollback snapshot'
		}
	done
	rollback_file_backup "$uci_dir/$config_name" "$rollback_dir/app-config" || {
		rollback_cleanup "$rollback_dir"
		die 'unable to back up applied configuration state'
	}
	rollback_file_backup "$exit_conn_file" "$rollback_dir/conn" || {
		rollback_cleanup "$rollback_dir"
		die 'unable to back up exit profile'
	}
	rollback_file_backup "$exit_cred_file" "$rollback_dir/cred" || {
		rollback_cleanup "$rollback_dir"
		die 'unable to back up exit credential'
	}
	had_previous=0
	grep -Fq 'site-link-in {' "$rollback_dir/conn" 2>/dev/null && had_previous=1
	if render_exit &&
	   ensure_xfrm "$(getv exit_device ipsec-site-exit)" "$(getv exit_if_id 45)" &&
	   exit_uci_apply && reset_exit_sa && swanctl --load-conns >/dev/null 2>&1 &&
	   swanctl --load-pools >/dev/null 2>&1 && swanctl --load-creds >/dev/null 2>&1 &&
	   exit_control_ready && record_applied_resources; then
		rollback_cleanup "$rollback_dir"
		return 0
	fi
	swanctl --terminate --ike site-link-in --timeout 5 >/dev/null 2>&1 || true
	rollback_ok=1
	rollback_file_restore "$rollback_dir/app-config" "$uci_dir/$config_name" || rollback_ok=0
	for file in network firewall pbr; do
		cp "$rollback_dir/$file" "$uci_dir/$file" || rollback_ok=0
	done
	rollback_file_restore "$rollback_dir/conn" "$exit_conn_file" || rollback_ok=0
	rollback_file_restore "$rollback_dir/cred" "$exit_cred_file" || rollback_ok=0
	"$network_init" reload >/dev/null 2>&1 || rollback_ok=0
	"$firewall_init" reload >/dev/null 2>&1 || rollback_ok=0
	pbr_reload_checked >/dev/null 2>&1 || rollback_ok=0
	swanctl --load-conns >/dev/null 2>&1 || rollback_ok=0
	swanctl --load-pools >/dev/null 2>&1 || rollback_ok=0
	swanctl --load-creds --noprompt >/dev/null 2>&1 || rollback_ok=0
	if [ "$had_previous" != 1 ]; then
		delete_xfrm_candidate "$(getv exit_device ipsec-site-exit)" \
			"$(getv exit_if_id 45)" >/dev/null 2>&1 || true
	fi
	rollback_cleanup "$rollback_dir"
	if [ "$rollback_ok" != 1 ]; then
		"$site_init" stop >/dev/null 2>&1 || true
		die 'exit validation failed and rollback is incomplete; monitor stopped'
	fi
	die 'exit configuration validation failed; previous routing configuration restored'
}

sync_vip() {
	device="$(getv xfrm_device ipsec-home)"
	vip="$(swanctl --list-sas --raw 2>/dev/null |
		sed -n 's/.*site-link {.*local-vips=\[\([^]]*\)\].*/\1/p' |
		tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' |
		awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && !found { value=$0; found=1 } END { if (found) print value }')"
	[ -n "$vip" ] || return 1
	current="$(ip -4 -o addr show dev "$device" scope global 2>/dev/null |
		awk 'NR == 1 { sub(/\/.*/, "", $4); print $4 }')"
	if [ "$current" != "$vip" ]; then
		ip -4 addr flush dev "$device" scope global || return 1
		ip -4 addr add "$vip/32" dev "$device" || return 1
	fi
	reconcile_source_routes
}

source_sa_ready() {
	swanctl --list-sas --raw 2>/dev/null |
		grep -Eq 'site-link4-[0-9]+ .*name=site-link4 .*state=INSTALLED'
}

source_sa_id() {
	swanctl --list-sas --raw 2>/dev/null |
		tr '{}' '\n' |
		awk '
			$0 ~ /^[[:space:]]*site-link[[:space:]]*$/ { wanted=1; next }
			wanted {
				value=$0
				sub(/.*uniqueid=/, "", value)
				sub(/[^0-9].*/, "", value)
				if (value != "" && result == "") result=value
				wanted=0
			}
			END { if (result != "") print result }
		'
}

source_conn_loaded() {
	swanctl --list-conns --raw 2>/dev/null |
		grep -Eq 'site-link .*site-link4'
}

source_pbr_ready() {
	"$pbr_init" running >/dev/null 2>&1 &&
		"$nft_bin" list chain inet fw4 pbr_prerouting 2>/dev/null |
		grep -Eq 'comment "IKEv2 Site Link: (YouTube|selected services)"'
}

policy_configuration_ready() {
	[ -r "$domains_file" ] && [ -r "$addresses_file" ] || return 1
	[ "$(uci -q get pbr.ikev2_site_link 2>/dev/null || true)" = policy ] || return 1
	[ "$(uci -q get pbr.ikev2_site_link.name 2>/dev/null || true)" = \
		'IKEv2 Site Link: selected services' ] || return 1
	[ "$(uci -q get pbr.ikev2_site_link.interface 2>/dev/null || true)" = \
		"$(getv interface sitehome)" ] || return 1
	[ "$(uci -q get pbr.ikev2_site_link.src_addr 2>/dev/null || true)" = \
		"$(getv source_devices '@br-lan')" ] || return 1
	[ "$(uci -q get pbr.ikev2_site_link.dest_addr 2>/dev/null || true)" = \
		"file://$domains_file file://$addresses_file" ] || return 1
	[ "$(uci -q get pbr.ikev2_site_link.proto 2>/dev/null || true)" = all ] || return 1
	[ "$(uci -q get pbr.ikev2_site_link.enabled 2>/dev/null || true)" = 1 ] || return 1
	[ "$(uci -q get pbr.ikev2_site_link_include 2>/dev/null || true)" = include ] || return 1
	[ "$(uci -q get pbr.ikev2_site_link_include.path 2>/dev/null || true)" = "$pbr_helper" ] || return 1
	[ "$(uci -q get pbr.ikev2_site_link_include.enabled 2>/dev/null || true)" = 1 ]
}

global_pbr_contract_ready() {
	[ "$(uci -q get pbr.config.enabled 2>/dev/null || echo 0)" = 1 ] &&
	[ "$(uci -q get pbr.config.strict_enforcement 2>/dev/null || echo 0)" = 1 ] &&
	{ [ "$(role)" != source ] ||
	  [ "$(uci -q get pbr.config.ipv6_enabled 2>/dev/null || echo 0)" = 1 ]; }
}

global_dns_contract_ready() {
	[ "$(uci -q get pbr.config.resolver_set 2>/dev/null || true)" = dnsmasq.nftset ] &&
		command -v dnsmasq >/dev/null 2>&1 &&
		dnsmasq -v 2>&1 | tr ' ' '\n' | grep -qx nftset
}

server_certificate_validate_raw() {
	local cert_public key_public identity result
	[ -s "$server_cert_file" ] && [ -s "$server_key_file" ] || {
		printf '%s\n' 'ikev2-site-link: exit certificate or private key is missing' >&2
		return 1
	}
	command -v openssl >/dev/null 2>&1 || {
		printf '%s\n' 'ikev2-site-link: openssl is unavailable for exit certificate validation' >&2
		return 1
	}
	openssl x509 -in "$server_cert_file" -noout -checkend 300 >/dev/null 2>&1 || {
		printf '%s\n' 'ikev2-site-link: exit certificate is invalid or expires within five minutes' >&2
		return 1
	}
	openssl pkey -in "$server_key_file" -noout -check >/dev/null 2>&1 || {
		printf '%s\n' 'ikev2-site-link: exit private key is invalid' >&2
		return 1
	}
	identity="$(getv remote_id)"
	[ -n "$identity" ] || return 1
	# OpenSSL 3 `x509 -checkhost` prints a mismatch but still exits zero. Use
	# the verifier so hostname mismatch is represented by a reliable status.
	openssl verify -no-CAfile -no-CApath -partial_chain \
		-trusted "$server_cert_file" -verify_hostname "$identity" \
		"$server_cert_file" >/dev/null 2>&1 || {
		printf 'ikev2-site-link: exit certificate does not match %s\n' "$identity" >&2
		return 1
	}
	cert_public="${TMPDIR:-/tmp}/ikev2-site-link-cert-public.$$"
	key_public="${TMPDIR:-/tmp}/ikev2-site-link-key-public.$$"
	if ! openssl x509 -in "$server_cert_file" -pubkey -noout 2>/dev/null |
		openssl pkey -pubin -outform DER >"$cert_public" 2>/dev/null ||
	   ! openssl pkey -in "$server_key_file" -pubout -outform DER \
		>"$key_public" 2>/dev/null; then
		rm -f "$cert_public" "$key_public"
		printf '%s\n' 'ikev2-site-link: unable to compare exit certificate and private key' >&2
		return 1
	fi
	cmp -s "$cert_public" "$key_public"
	result=$?
	rm -f "$cert_public" "$key_public"
	[ "$result" = 0 ] || printf '%s\n' 'ikev2-site-link: exit certificate and private key do not match' >&2
	return "$result"
}

server_certificate_ready() {
	local metadata signature cached status
	metadata="$({ sha256_stream <"$server_cert_file"; sha256_stream <"$server_key_file"; } |
		awk '{ print $1 }')" || return 1
	signature="$({ printf '%s\n' "$metadata"; printf '%s\n' "$(getv remote_id)"; } |
		sha256_stream | awk '{ print $1 }')"
	[ -n "$signature" ] || return 1
	cached="$(sed -n "s/^$signature=//p" "$server_cert_state" 2>/dev/null | tail -n1)"
	case "$cached" in 1) return 0 ;; 0) return 1 ;; esac
	status=0
	server_certificate_validate_raw || status=1
	if { printf '%s=%s\n' "$signature" "$([ "$status" = 0 ] && echo 1 || echo 0)" \
		>"$server_cert_state.new" && chmod 600 "$server_cert_state.new" &&
		mv "$server_cert_state.new" "$server_cert_state"; } 2>/dev/null; then
		:
	else
		rm -f "$server_cert_state.new" 2>/dev/null || true
	fi
	return "$status"
}

validate_dependency_contract() {
	global_pbr_contract_ready ||
		die 'global PBR contract requires enabled=1, strict_enforcement=1 and IPv6 fail-closed processing on the source'
	if [ "$(role)" = source ]; then
		global_dns_contract_ready ||
			die 'source DNS classifier contract requires pbr resolver_set=dnsmasq.nftset'
	else
		server_certificate_ready ||
			die 'exit certificate contract requires ikev2.pem and ikev2.key files'
	fi
}

source_forwardings_ready() {
	interface="$(getv interface sitehome)"
	zones="$(source_forwarding_zones)" || return 1
	index=1
	for source_zone in $zones; do
		section="ikev2_site_link_src_$index"
		[ "$(uci -q get "firewall.$section" 2>/dev/null || true)" = forwarding ] || return 1
		[ "$(uci -q get "firewall.$section.src" 2>/dev/null || true)" = "$source_zone" ] || return 1
		[ "$(uci -q get "firewall.$section.dest" 2>/dev/null || true)" = "$interface" ] || return 1
		index=$((index + 1))
	done
	[ "$(uci show firewall 2>/dev/null |
		sed -n 's/^firewall\.ikev2_site_link_src_\([0-9][0-9]*\)=forwarding$/\1/p' |
		wc -l | tr -d ' ')" = "$((index - 1))" ]
}

source_firewall_runtime_ready() {
	interface="$(getv interface sitehome)"
	zones="$(source_forwarding_zones)" || return 1
	for source_zone in $zones; do
		"$nft_bin" list chain inet fw4 "forward_$source_zone" 2>/dev/null |
			grep -Fq "jump accept_to_$interface" || return 1
	done
}

exit_firewall_runtime_ready() {
	interface="$(getv exit_interface siteexit)"
	wan_zone="$(getv exit_wan_zone "$(getv exit_wan wan)")"
	ike_port="$(getv ike_port 1500)"
	"$nft_bin" list chain inet fw4 "forward_$interface" 2>/dev/null |
		grep -Fq "jump accept_to_$wan_zone" || return 1
	"$nft_bin" list chain inet fw4 "dstnat_$wan_zone" 2>/dev/null |
		grep -F "udp dport $ike_port" |
		grep -Fq 'comment "!fw4: IKEv2 Site Link: dedicated IKE port"'
}

source_managed_config_ready() {
	interface="$(getv interface sitehome)"
	device="$(getv xfrm_device ipsec-home)"
	[ "$(uci -q get "network.$interface" 2>/dev/null || true)" = interface ] &&
	[ "$(uci -q get "network.$interface.proto" 2>/dev/null || true)" = none ] &&
	[ "$(uci -q get "network.$interface.device" 2>/dev/null || true)" = "$device" ] &&
	[ "$(uci -q get firewall.ikev2_site_link 2>/dev/null || true)" = zone ] &&
	[ "$(uci -q get firewall.ikev2_site_link.name 2>/dev/null || true)" = "$interface" ] &&
	[ "$(uci -q get firewall.ikev2_site_link.network 2>/dev/null || true)" = "$interface" ] &&
	[ "$(uci -q get firewall.ikev2_site_link.input 2>/dev/null || true)" = REJECT ] &&
	[ "$(uci -q get firewall.ikev2_site_link.output 2>/dev/null || true)" = ACCEPT ] &&
	[ "$(uci -q get firewall.ikev2_site_link.forward 2>/dev/null || true)" = REJECT ] &&
	[ "$(uci -q get firewall.ikev2_site_link.mtu_fix 2>/dev/null || true)" = 1 ] &&
	[ "$(uci -q get firewall.ikev2_site_link.masq 2>/dev/null || true)" = 1 ] &&
	source_forwardings_ready && source_firewall_runtime_ready && policy_configuration_ready
}

exit_managed_config_ready() {
	interface="$(getv exit_interface siteexit)"
	device="$(getv exit_device ipsec-site-exit)"
	wan="$(getv exit_wan wan)"
	wan_zone="$(getv exit_wan_zone "$wan")"
	ike_port="$(getv ike_port 1500)"
	[ "$(uci -q get "network.$interface" 2>/dev/null || true)" = interface ] &&
	[ "$(uci -q get "network.$interface.proto" 2>/dev/null || true)" = none ] &&
	[ "$(uci -q get "network.$interface.device" 2>/dev/null || true)" = "$device" ] &&
	[ "$(uci -q get firewall.ikev2_site_link_exit 2>/dev/null || true)" = zone ] &&
	[ "$(uci -q get firewall.ikev2_site_link_exit.name 2>/dev/null || true)" = "$interface" ] &&
	[ "$(uci -q get firewall.ikev2_site_link_exit.network 2>/dev/null || true)" = "$interface" ] &&
	[ "$(uci -q get firewall.ikev2_site_link_exit.input 2>/dev/null || true)" = REJECT ] &&
	[ "$(uci -q get firewall.ikev2_site_link_exit.output 2>/dev/null || true)" = ACCEPT ] &&
	[ "$(uci -q get firewall.ikev2_site_link_exit.forward 2>/dev/null || true)" = REJECT ] &&
	[ "$(uci -q get firewall.ikev2_site_link_exit.mtu_fix 2>/dev/null || true)" = 1 ] &&
	[ "$(uci -q get firewall.ikev2_site_link_exit_wan 2>/dev/null || true)" = forwarding ] &&
	[ "$(uci -q get firewall.ikev2_site_link_exit_wan.src 2>/dev/null || true)" = "$interface" ] &&
	[ "$(uci -q get firewall.ikev2_site_link_exit_wan.dest 2>/dev/null || true)" = "$wan_zone" ] &&
	[ "$(uci -q get firewall.ikev2_site_link_ike 2>/dev/null || true)" = redirect ] &&
	[ "$(uci -q get firewall.ikev2_site_link_ike.src 2>/dev/null || true)" = "$wan_zone" ] &&
	[ "$(uci -q get firewall.ikev2_site_link_ike.name 2>/dev/null || true)" = 'IKEv2 Site Link: dedicated IKE port' ] &&
	[ "$(uci -q get firewall.ikev2_site_link_ike.proto 2>/dev/null || true)" = udp ] &&
	[ "$(uci -q get firewall.ikev2_site_link_ike.src_dport 2>/dev/null || true)" = "$ike_port" ] &&
	[ "$(uci -q get firewall.ikev2_site_link_ike.dest_port 2>/dev/null || true)" = 4500 ] &&
	[ "$(uci -q get firewall.ikev2_site_link_ike.family 2>/dev/null || true)" = ipv4 ] &&
	[ "$(uci -q get firewall.ikev2_site_link_ike.target 2>/dev/null || true)" = DNAT ] &&
	[ "$(uci -q get pbr.ikev2_site_link 2>/dev/null || true)" = policy ] &&
	[ "$(uci -q get pbr.ikev2_site_link.name 2>/dev/null || true)" = 'IKEv2 Site Link: direct exit WAN' ] &&
	[ "$(uci -q get pbr.ikev2_site_link.interface 2>/dev/null || true)" = "$wan" ] &&
	[ "$(uci -q get pbr.ikev2_site_link.src_addr 2>/dev/null || true)" = "@$device" ] &&
	[ "$(uci -q get pbr.ikev2_site_link.proto 2>/dev/null || true)" = all ] &&
	[ "$(uci -q get pbr.ikev2_site_link.enabled 2>/dev/null || true)" = 1 ] &&
	exit_firewall_runtime_ready
}

policy_reload_impl() {
	# Exit routers never classify destinations. Disabled source routers retain
	# the saved policy files but must not create a live PBR path.
	[ "$(getv enabled 0)" = 1 ] && [ "$(role)" = source ] || return 0
	validate_config
	render_pbr_runtime_config || return 1
	policy_configuration_ready || {
		uci set pbr.ikev2_site_link=policy
		uci set pbr.ikev2_site_link.name='IKEv2 Site Link: selected services'
		uci set pbr.ikev2_site_link.interface="$(getv interface sitehome)"
		uci set pbr.ikev2_site_link.src_addr="$(getv source_devices '@br-lan')"
		uci set pbr.ikev2_site_link.dest_addr="file://$domains_file file://$addresses_file"
		uci set pbr.ikev2_site_link.proto='all'
		uci set pbr.ikev2_site_link.enabled=1
		uci reorder pbr.ikev2_site_link=1
		uci set pbr.ikev2_site_link_include=include
		uci set pbr.ikev2_site_link_include.path="$pbr_helper"
		uci set pbr.ikev2_site_link_include.enabled=1
		uci commit pbr
	}
	pbr_reload_checked || return 1
	reconcile_source_routes || return 1
	repair_source_aux || return 1
	guard_sync || return 1
	persist_pbr_sets || return 1
	source_pbr_ready && policy_configuration_ready && guard_runtime_ready
}

policy_check() {
	[ "$(getv enabled 0)" = 1 ] && [ "$(role)" = source ] || return 0
	policy_configuration_ready && source_pbr_ready && source_routes_ready &&
		source_aux_rules_ready && guard_runtime_ready
}

source_aux_rules_ready() {
	mss_count="$("$nft_bin" list chain inet fw4 mangle_forward 2>/dev/null |
		grep -c 'comment "ikev2-site-link-mss-clamp"' || true)"
	[ "$mss_count" = 1 ] || return 1
	[ "$(getv force_tcp 1)" != 1 ] && return 0
	quic_count="$("$nft_bin" list chain inet fw4 pbr_forward 2>/dev/null |
		grep -c 'comment "ikev2-site-link-force-youtube-tcp"' || true)"
	[ "$quic_count" = 1 ]
}

repair_source_aux() {
	"$pbr_helper" >/dev/null 2>&1 || return 1
	source_aux_rules_ready
}

source_ipv4_terminal_ready() {
	table="pbr_$(getv interface sitehome)"
	ip -4 route show table "$table" 2>/dev/null |
		awk '
			$1 == "unreachable" && $2 == "default" {
				unreachable++
				for (i = 1; i <= NF; i++) if ($i == "metric" && $(i + 1) == 32767) terminal++
			}
			END { exit !(unreachable == 1 && terminal == 1) }
		'
}

source_ipv6_terminal_ready() {
	table="pbr_$(getv interface sitehome)"
	[ "$(uci -q get pbr.config.ipv6_enabled 2>/dev/null || echo 0)" != 1 ] ||
		ip -6 route show table "$table" 2>/dev/null |
		awk '
			$1 == "unreachable" && $2 == "default" {
				unreachable++
				for (i = 1; i <= NF; i++) if ($i == "metric" && $(i + 1) == 32767) terminal++
			}
			$1 == "default" { defaults++ }
			END { exit !(unreachable == 1 && terminal == 1 && defaults == 0) }
		'
}

source_fail_closed_ready() {
	source_ipv4_terminal_ready && source_ipv6_terminal_ready && ! source_live_route_ready
}

source_live_route_ready() {
	device="$(getv xfrm_device ipsec-home)"
	ip -4 route show table "pbr_$(getv interface sitehome)" 2>/dev/null |
		grep -Eq "^default dev $device( |$).*metric 10( |$)"
}

source_routes_ready() {
	device="$(getv xfrm_device ipsec-home)"
	table="pbr_$(getv interface sitehome)"
	ip -4 route show table "$table" 2>/dev/null |
		awk -v device="$device" '
			$1 == "unreachable" && $2 == "default" {
				unreachable++
				for (i = 1; i <= NF; i++) if ($i == "metric" && $(i + 1) == 32767) terminal++
			}
			$1 == "default" { defaults++; if ($2 == "dev" && $3 == device && $0 ~ /metric 10([ ]|$)/) live++ }
			END { exit !(unreachable == 1 && terminal == 1 && defaults == 1 && live == 1) }
		' && source_ipv6_terminal_ready
}

probe_rule_ready() {
	device="$(getv xfrm_device ipsec-home)"
	table="pbr_$(getv interface sitehome)"
	ip -4 rule show 2>/dev/null |
		awk -v priority="$probe_rule_priority:" -v device="$device" -v table="$table" '
			$1 == priority {
				total++
				for (i = 1; i <= NF; i++) {
					if ($i == "oif" && $(i + 1) == device) oif=1
					if (($i == "lookup" || $i == "table") && $(i + 1) == table) lookup=1
				}
				if (oif && lookup) correct++
			}
			END { exit !(total == 1 && correct == 1) }
		'
}

ensure_probe_rule() {
	probe_rule_ready && return 0
	if ip -4 rule show 2>/dev/null | awk -v priority="$probe_rule_priority:" '$1 == priority { found=1 } END { exit !found }'; then
		return 1
	fi
	device="$(getv xfrm_device ipsec-home)"
	table="pbr_$(getv interface sitehome)"
	ip -4 rule add priority "$probe_rule_priority" oif "$device" lookup "$table" || return 1
	probe_rule_ready
}

delete_probe_rule() {
	device="$1"
	interface="$2"
	valid_device "$device" && valid_uci_name "$interface" || return 0
	while ip -4 rule show 2>/dev/null |
		awk -v priority="$probe_rule_priority:" -v device="$device" -v table="pbr_$interface" '
			$1 == priority {
				for (i = 1; i <= NF; i++) {
					if ($i == "oif" && $(i + 1) == device) oif=1
					if (($i == "lookup" || $i == "table") && $(i + 1) == table) lookup=1
				}
			}
			END { exit !(oif && lookup) }
		'; do
		ip -4 rule del priority "$probe_rule_priority" oif "$device" lookup "pbr_$interface" || return 1
	done
}

reconcile_source_routes() {
	"$pbr_helper" routes-only >/dev/null 2>&1 || return 1
	if source_sa_ready; then
		source_routes_ready
	else
		source_fail_closed_ready && ! source_live_route_ready
	fi
}

exit_sa_ready() {
	swanctl --list-sas --raw 2>/dev/null |
		grep -Eq 'site-link-net-[0-9]+ .*state=INSTALLED'
}

exit_conn_loaded() {
	swanctl --list-conns --raw 2>/dev/null |
		grep -Eq 'site-link-in .*site-link-net'
}

child_counters() {
	child="$1"
	swanctl --list-sas --raw 2>/dev/null |
		tr '{}' '\n' |
		awk -v child="$child" '
			{
				header=$0
				gsub(/^[[:space:]]+|[[:space:]]+$/, "", header)
				if (header ~ ("^" child "-[0-9]+$")) {
					id=header
					sub("^" child "-", "", id)
					wanted=1
					next
				}
			}
			wanted {
				wanted=0
				if (index($0, "name=" child) == 0 || index($0, "state=INSTALLED") == 0) next
				for (i=1; i<=NF; i++) {
					if ($i ~ /^bytes-in=[0-9]+$/) { in_bytes=$i; sub(/^bytes-in=/, "", in_bytes) }
					if ($i ~ /^bytes-out=[0-9]+$/) { out_bytes=$i; sub(/^bytes-out=/, "", out_bytes) }
				}
				if (!found && id != "" && in_bytes != "" && out_bytes != "") {
					print id, in_bytes, out_bytes
					found=1
				}
			}
			END { exit !found }
		'
}

exit_traffic_update() {
	metrics="$(child_counters site-link-net)" || return 1
	set -- $metrics
	[ "$#" = 3 ] || return 1
	current_id="$1"
	current_in="$2"
	current_out="$3"
	previous_id="$(sed -n 's/^sa_id=//p' "$exit_traffic_state" 2>/dev/null | tail -n1)"
	previous_in="$(sed -n 's/^bytes_in=//p' "$exit_traffic_state" 2>/dev/null | tail -n1)"
	previous_out="$(sed -n 's/^bytes_out=//p' "$exit_traffic_state" 2>/dev/null | tail -n1)"
	last_in="$(sed -n 's/^last_in=//p' "$exit_traffic_state" 2>/dev/null | tail -n1)"
	last_out="$(sed -n 's/^last_out=//p' "$exit_traffic_state" 2>/dev/null | tail -n1)"
	for value in "$current_id" "$current_in" "$current_out"; do
		valid_uint "$value" || return 1
	done
	case "$previous_in" in '' | *[!0-9]*) previous_in=0 ;; esac
	case "$previous_out" in '' | *[!0-9]*) previous_out=0 ;; esac
	case "$last_in" in '' | *[!0-9]*) last_in=0 ;; esac
	case "$last_out" in '' | *[!0-9]*) last_out=0 ;; esac
	now="$(date +%s)"
	if [ "$previous_id" != "$current_id" ]; then
		last_in=0
		last_out=0
		[ "$current_in" -gt 0 ] && last_in="$now"
		[ "$current_out" -gt 0 ] && last_out="$now"
	else
		[ "$current_in" = "$previous_in" ] || last_in="$now"
		[ "$current_out" = "$previous_out" ] || last_out="$now"
	fi
	{
		printf 'sa_id=%s\n' "$current_id"
		printf 'bytes_in=%s\n' "$current_in"
		printf 'bytes_out=%s\n' "$current_out"
		printf 'last_in=%s\n' "$last_in"
		printf 'last_out=%s\n' "$last_out"
	} >"$exit_traffic_state.new"
	chmod 600 "$exit_traffic_state.new"
	mv "$exit_traffic_state.new" "$exit_traffic_state"
}

exit_traffic_recent() {
	metrics="$(child_counters site-link-net)" || return 1
	set -- $metrics
	[ "$#" = 3 ] || return 1
	state_id="$(sed -n 's/^sa_id=//p' "$exit_traffic_state" 2>/dev/null | tail -n1)"
	last_in="$(sed -n 's/^last_in=//p' "$exit_traffic_state" 2>/dev/null | tail -n1)"
	last_out="$(sed -n 's/^last_out=//p' "$exit_traffic_state" 2>/dev/null | tail -n1)"
	[ "$state_id" = "$1" ] && valid_uint "$last_in" && valid_uint "$last_out" || return 1
	[ "$last_in" -gt 0 ] && [ "$last_out" -gt 0 ] || return 1
	now="$(date +%s)"
	interval="$(getv probe_interval 60)"
	valid_uint "$interval" || return 1
	[ "$interval" -ge 30 ] && [ "$interval" -le 3600 ] || return 1
	timeout=$((interval * 3))
	[ "$now" -ge "$last_in" ] && [ "$now" -ge "$last_out" ] &&
		[ $((now - last_in)) -le "$timeout" ] && [ $((now - last_out)) -le "$timeout" ]
}

exit_route_ready() {
	device="$(getv exit_device ipsec-site-exit)"
	pool="$(getv exit_pool 10.253.44.2)"
	ip -4 route show "$pool/32" 2>/dev/null |
		awk -v pool="$pool" -v cidr="$pool/32" -v device="$device" '
			$1 == pool || $1 == cidr {
				total++
				if ($2 == "dev" && $3 == device) correct++
			}
			END { exit !(total == 1 && correct == 1) }
		'
}

exit_pool_route_available() {
	pool="$(getv exit_pool 10.253.44.2)"
	source_device="$(getv xfrm_device ipsec-home)"
	exit_device="$(getv exit_device ipsec-site-exit)"
	matched="$(ip -4 route show match "$pool" 2>/dev/null | sed -n '1p')"
	case "$matched" in
		'' | default*) return 0 ;;
		"$pool dev $source_device"* | "$pool/32 dev $source_device"* | \
			"$pool dev $exit_device"* | "$pool/32 dev $exit_device"*) return 0 ;;
		*) return 1 ;;
	esac
}

ensure_exit_route() {
	exit_route_ready && return 0
	device="$(getv exit_device ipsec-site-exit)"
	pool="$(getv exit_pool 10.253.44.2)/32"
	ip -4 route replace "$pool" dev "$device"
	exit_route_ready
}

exit_pbr_ready() {
	"$pbr_init" running >/dev/null 2>&1 &&
		"$nft_bin" list chain inet fw4 pbr_prerouting 2>/dev/null |
		grep -Fq 'comment "IKEv2 Site Link: direct exit WAN"'
}

data_plane_ready() {
	local device url
	device="$(getv xfrm_device ipsec-home)"
	command -v curl >/dev/null 2>&1 || return 1
	for url in "$probe_url" "$probe_fallback_url"; do
		curl -4fsS --interface "$device" --connect-timeout 3 --max-time 6 \
			-o /dev/null "$url" && return 0
	done
	return 1
}

probe_due() {
	now="$1"
	last="$(sed -n 's/^last=//p' "$probe_state" 2>/dev/null | tail -n1)"
	case "$last" in '' | *[!0-9]*) last=0 ;; esac
	[ "$now" -lt "$last" ] || [ $((now - last)) -ge "$(getv probe_interval 60)" ]
}

time_due() {
	now="$1"
	last="$2"
	interval="$3"
	[ "$now" -lt "$last" ] || [ $((now - last)) -ge "$interval" ]
}

probe_save() {
	result="$1"
	previous="$(sed -n 's/^failures=//p' "$probe_state" 2>/dev/null | tail -n1)"
	previous_sa_id="$(sed -n 's/^sa_id=//p' "$probe_state" 2>/dev/null | tail -n1)"
	current_sa_id="$(source_sa_id)"
	case "$previous" in '' | *[!0-9]*) previous=0 ;; esac
	[ "$previous_sa_id" = "$current_sa_id" ] || previous=0
	if [ "$result" = 1 ]; then
		probe_failures_value=0
	else
		probe_failures_value=$((previous + 1))
	fi
	{
		printf 'last=%s\n' "$(date +%s)"
		printf 'success=%s\n' "$result"
		printf 'failures=%s\n' "$probe_failures_value"
		printf 'sa_id=%s\n' "$current_sa_id"
	} >"$probe_state.new"
	mv "$probe_state.new" "$probe_state"
}

probe_recent_success() {
	[ "$(sed -n 's/^success=//p' "$probe_state" 2>/dev/null | tail -n1)" = 1 ] || return 1
	probe_sa_id="$(sed -n 's/^sa_id=//p' "$probe_state" 2>/dev/null | tail -n1)"
	[ -n "$probe_sa_id" ] && [ "$probe_sa_id" = "$(source_sa_id)" ] || return 1
	last="$(sed -n 's/^last=//p' "$probe_state" 2>/dev/null | tail -n1)"
	case "$last" in '' | *[!0-9]*) return 1 ;; esac
	now="$(date +%s)"
	interval="$(getv probe_interval 60)"
	[ "$now" -ge "$last" ] && [ $((now - last)) -le $((interval * 2)) ]
}

dump_pbr_set() {
	family="$1"
	dump="$2"
	set_name="pbr_$(getv interface sitehome)_${family}_dst_ip_ikev2_site_link"
	"$nft_bin" list set inet fw4 "$set_name" 2>/dev/null |
		sed -n '/elements = {/,/}/p' | tr -d '\n\t' |
		sed 's/.*{//; s/}.*//' | tr ',' '\n' |
		tr -d ' ' | grep -v '^$' >"$dump.new" || true
	if [ -s "$dump.new" ]; then
		mv "$dump.new" "$dump"
	else
		rm -f "$dump.new"
	fi
}

dump_pbr_sets() {
	source_pbr_ready || return 0
	dump_pbr_set 4 "$set_dump4"
	dump_pbr_set 6 "$set_dump6"
}

persist_pbr_sets() {
	dump_pbr_sets
	mkdir -p "${persistent_set_dump4%/*}" "${persistent_set_dump6%/*}" || return 1
	if [ -s "$set_dump4" ]; then
		cp "$set_dump4" "$persistent_set_dump4.new" || return 1
		chmod 600 "$persistent_set_dump4.new" || return 1
		mv "$persistent_set_dump4.new" "$persistent_set_dump4" || return 1
	fi
	if [ -s "$set_dump6" ]; then
		cp "$set_dump6" "$persistent_set_dump6.new" || return 1
		chmod 600 "$persistent_set_dump6.new" || return 1
		mv "$persistent_set_dump6.new" "$persistent_set_dump6" || return 1
	fi
}

guard_pbr_mask() {
	local mask
	mask="$(uci -q get pbr.config.fw_mask 2>/dev/null || true)"
	valid_hex "$mask" || mask=0x00ff0000
	printf '%s\n' "$mask"
}

guard_rule_match() {
	local pbr_mask combined_mask
	pbr_mask="$(guard_pbr_mask)"
	[ $((guard_mark & pbr_mask)) -eq 0 ] || return 1
	combined_mask=$((guard_mask | pbr_mask))
	printf '0x%x/0x%x\n' "$((guard_mark))" "$combined_mask"
}

guard_rule_ready() {
	local family mark_canonical
	family="$1"
	mark_canonical="$(guard_rule_match)" || return 1
	ip "-$family" rule show 2>/dev/null |
		awk -v priority="$guard_rule_priority:" -v mark="$mark_canonical" \
			-v table="$guard_route_table" '
			$1 == priority {
				total++
				for (i = 1; i <= NF; i++) {
					if ($i == "fwmark" && $(i + 1) == mark) marked=1
					if (($i == "lookup" || $i == "table") && $(i + 1) == table) routed=1
				}
				if (marked && routed) correct++
			}
			END { exit !(total == 1 && correct == 1) }
		'
}

guard_route_ready() {
	local device
	device="$(getv xfrm_device ipsec-home)"
	ip -4 route show table "$guard_route_table" 2>/dev/null |
		awk -v device="$device" -v live="$(source_sa_ready && echo 1 || echo 0)" '
			$1 == "unreachable" && $2 == "default" { terminal++ }
			$1 == "default" { defaults++; if ($2 == "dev" && $3 == device) active++ }
			END {
				if (terminal != 1) exit 1
				if (live == 1) exit !(defaults == 1 && active == 1)
				exit !(defaults == 0 && active == 0)
			}
		' || return 1
	ip -6 route show table "$guard_route_table" 2>/dev/null |
		awk '$1 == "unreachable" && $2 == "default" { terminal++ }
			 $1 == "default" { active++ }
			 END { exit !(terminal == 1 && active == 0) }'
}

guard_classifier_ready() {
	"$nft_bin" list table inet "$guard_nft_table" 2>/dev/null |
		grep -Fq 'comment "ikev2-site-link:classifier"'
}

guard_runtime_ready() {
	guard_classifier_ready && guard_rule_ready 4 && guard_rule_ready 6 && guard_route_ready
}

guard_ensure_rule() {
	local family rule_match
	family="$1"
	guard_rule_ready "$family" && return 0
	if ip "-$family" rule show 2>/dev/null |
		awk -v priority="$guard_rule_priority:" '$1 == priority { found=1 } END { exit !found }'; then
		return 1
	fi
	rule_match="$(guard_rule_match)" || return 1
	ip "-$family" rule add priority "$guard_rule_priority" \
		fwmark "$rule_match" lookup "$guard_route_table"
}

guard_resources_available() {
	local family mark_canonical routes
	mark_canonical="$(guard_rule_match)" || return 1
	for family in 4 6; do
		ip "-$family" rule show 2>/dev/null |
			awk -v priority="$guard_rule_priority:" -v mark="$mark_canonical" \
				-v table="$guard_route_table" '
				{
					uses_table=0; uses_mark=0
					for (i = 1; i <= NF; i++) {
						if (($i == "lookup" || $i == "table") && $(i + 1) == table) uses_table=1
						if ($i == "fwmark" && $(i + 1) == mark) uses_mark=1
					}
					if ((uses_table || uses_mark) && $1 != priority) conflict=1
				}
				END { exit conflict }
			' || return 1
		routes="$(ip "-$family" route show table "$guard_route_table" 2>/dev/null || true)"
		[ -z "$routes" ] || [ -s "$guard_config_file" ] || guard_classifier_ready || return 1
	done
}

guard_reconcile_routes() {
	local device
	guard_resources_available || return 1
	device="$(getv xfrm_device ipsec-home)"
	ip -4 route replace unreachable default metric 32767 table "$guard_route_table" || return 1
	if source_sa_ready; then
		ip -4 route replace default dev "$device" metric 10 table "$guard_route_table" || return 1
	else
		ip -4 route del default dev "$device" metric 10 table "$guard_route_table" 2>/dev/null || true
	fi
	ip -6 route replace unreachable default metric 32767 table "$guard_route_table" || return 1
	guard_ensure_rule 4 || return 1
	guard_ensure_rule 6 || return 1
	guard_route_ready
}

guard_set_elements() {
	local file
	file="$1"
	[ -s "$file" ] || return 0
	awk 'BEGIN { first=1 } NF { if (!first) printf ", "; printf "%s", $0; first=0 }' "$file"
}

guard_prepare_dump() {
	local family output current persistent pattern input saved now max_age
	family="$1"
	output="$2"
	if [ "$family" = 4 ]; then
		current="$set_dump4"
		persistent="$persistent_set_dump4"
		pattern='^[0-9./-]+$'
	else
		current="$set_dump6"
		persistent="$persistent_set_dump6"
		pattern='^[0-9A-Fa-f:./-]+$'
	fi
	input="$current"
	if [ ! -s "$input" ]; then
		input="$persistent"
		max_age="$set_dump_max_age"
		case "$max_age" in '' | *[!0-9]*) max_age=3600 ;; esac
		saved="$(file_mtime "$input" 2>/dev/null || echo 0)"
		now="$(date +%s)"
		case "$saved" in '' | *[!0-9]*) input='' ;; esac
		if [ -n "$input" ] && { [ "$now" -lt "$saved" ] ||
		   [ $((now - saved)) -gt "$max_age" ]; }; then
			input=''
		fi
	fi
	if [ -s "$input" ]; then
		grep -E "$pattern" "$input" | sort -u >"$output" || true
	else
		: >"$output"
	fi
}

guard_write_set() {
	local name type file
	name="$1"
	type="$2"
	file="$3"
	printf '  set %s {\n    type %s\n    flags interval\n' "$name" "$type"
	if [ -s "$file" ]; then
		printf '    elements = { '
		guard_set_elements "$file"
		printf ' }\n'
	fi
	printf '  }\n\n'
}

guard_render_classifier() {
	local output work selector device pbr_mask
	output="$1"
	work="${TMPDIR:-/tmp}/ikev2-site-link-guard.$$"
	mkdir "$work" || return 1
	guard_prepare_dump 4 "$work/dest4"
	guard_prepare_dump 6 "$work/dest6"
	: >"$work/sources"
	for selector in $(getv source_devices '@br-lan'); do
		device="${selector#@}"
		valid_device "$device" || { rm -rf "$work"; return 1; }
		printf '%s\n' "$device" >>"$work/sources"
	done
	pbr_mask="$(guard_pbr_mask)"
	[ $((guard_mark & pbr_mask)) -eq 0 ] || { rm -rf "$work"; return 1; }
	{
		printf 'table inet %s {\n' "$guard_nft_table"
		printf '  set source_ifaces {\n    type ifname\n    elements = { '
		awk 'BEGIN { first=1 } NF { if (!first) printf ", "; printf "\"%s\"", $0; first=0 }' "$work/sources"
		printf ' }\n  }\n\n'
		guard_write_set dest4 ipv4_addr "$work/dest4"
		guard_write_set dest6 ipv6_addr "$work/dest6"
		printf '  chain prerouting {\n'
		printf '    type filter hook prerouting priority -151; policy accept;\n'
		printf '    meta mark & %s != 0 return comment "ikev2-site-link:prior-policy"\n' "$pbr_mask"
		printf '    iifname @source_ifaces ip daddr @dest4 meta mark set meta mark | %s counter comment "ikev2-site-link:classifier"\n' "$guard_mark"
		printf '    iifname @source_ifaces ip6 daddr @dest6 meta mark set meta mark | %s counter comment "ikev2-site-link:classifier6"\n' "$guard_mark"
		printf '  }\n}\n'
	} >"$output"
	rm -rf "$work"
}

guard_apply_classifier() {
	local canonical batch
	canonical="${TMPDIR:-/tmp}/ikev2-site-link-guard-canonical.$$"
	batch="${TMPDIR:-/tmp}/ikev2-site-link-guard-batch.$$"
	guard_render_classifier "$canonical" || { rm -f "$canonical" "$batch"; return 1; }
	if [ -f "$guard_config_file" ] && cmp -s "$canonical" "$guard_config_file" &&
	   guard_classifier_ready; then
		rm -f "$canonical" "$batch"
		return 0
	fi
	if "$nft_bin" list table inet "$guard_nft_table" >/dev/null 2>&1; then
		guard_classifier_ready || { rm -f "$canonical" "$batch"; return 1; }
		printf 'delete table inet %s\n' "$guard_nft_table" >"$batch"
	fi
	cat "$canonical" >>"$batch"
	"$nft_bin" -c -f "$batch" >/dev/null 2>&1 || { rm -f "$canonical" "$batch"; return 1; }
	"$nft_bin" -f "$batch" >/dev/null 2>&1 || { rm -f "$canonical" "$batch"; return 1; }
	mkdir -p "${guard_config_file%/*}"
	chmod 600 "$canonical"
	mv "$canonical" "$guard_config_file"
	rm -f "$batch"
	guard_classifier_ready
}

guard_sync() {
	dump_pbr_sets >/dev/null 2>&1 || true
	guard_reconcile_routes || return 1
	guard_apply_classifier || return 1
	guard_runtime_ready
}

guard_remove() {
	local family rule_match
	guard_resources_available || return 1
	rule_match="$(guard_rule_match)" || return 1
	if "$nft_bin" list table inet "$guard_nft_table" >/dev/null 2>&1; then
		guard_classifier_ready || return 1
		"$nft_bin" delete table inet "$guard_nft_table" || return 1
	fi
	for family in 4 6; do
		while guard_rule_ready "$family"; do
			ip "-$family" rule del priority "$guard_rule_priority" \
				fwmark "$rule_match" lookup "$guard_route_table" || return 1
		done
		if ip "-$family" rule show 2>/dev/null |
			awk -v priority="$guard_rule_priority:" '$1 == priority { found=1 } END { exit !found }'; then
			return 1
		fi
		ip "-$family" route flush table "$guard_route_table" 2>/dev/null || true
	done
	rm -f "$guard_config_file"
}

source_vip_ready() {
	device="$(getv xfrm_device ipsec-home)"
	vip="$(swanctl --list-sas --raw 2>/dev/null |
		sed -n 's/.*site-link {.*local-vips=\[\([^]]*\)\].*/\1/p' |
		tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' |
		awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && !found { value=$0; found=1 } END { if (found) print value }')"
	[ -n "$vip" ] || return 1
	[ "$(ip -4 -o addr show dev "$device" scope global 2>/dev/null |
		awk 'NR == 1 { sub(/\/.*/, "", $4); print $4 }')" = "$vip" ]
}

source_control_ready() {
	device="$(getv xfrm_device ipsec-home)"
	if_id="$(getv if_id 44)"
	global_pbr_contract_ready && global_dns_contract_ready && source_managed_config_ready &&
	xfrm_ready "$device" "$if_id" && source_conn_loaded && source_sa_ready && probe_rule_ready &&
		source_aux_rules_ready && guard_runtime_ready &&
		[ -n "$(source_sa_id)" ] && source_vip_ready && source_pbr_ready && source_routes_ready
}

exit_control_ready() {
	device="$(getv exit_device ipsec-site-exit)"
	if_id="$(getv exit_if_id 45)"
	server_certificate_ready && global_pbr_contract_ready && exit_managed_config_ready &&
	xfrm_ready "$device" "$if_id" && exit_conn_loaded && exit_route_ready && exit_pbr_ready
}

disabled_runtime_ready() {
	! source_sa_ready && ! exit_sa_ready && ! source_conn_loaded && ! exit_conn_loaded || return 1
	for device in "$(getv xfrm_device ipsec-home)" "$(getv exit_device ipsec-site-exit)" \
		"$(applied_get xfrm_device)" "$(applied_get exit_device)"; do
		[ -n "$device" ] || continue
		valid_device "$device" || return 1
		! ip link show "$device" >/dev/null 2>&1 || return 1
	done
	for interface in "$(getv interface sitehome)" "$(getv exit_interface siteexit)" \
		"$(applied_get interface)" "$(applied_get exit_interface)"; do
		[ -n "$interface" ] || continue
		valid_uci_name "$interface" || return 1
		! uci -q get "network.$interface" >/dev/null 2>&1 || return 1
	done
	! uci -q get pbr.ikev2_site_link >/dev/null 2>&1 || return 1
	! uci -q get pbr.ikev2_site_link_include >/dev/null 2>&1 || return 1
	! ip -4 rule show 2>/dev/null |
		awk -v priority="$probe_rule_priority:" '$1 == priority { found=1 } END { exit !found }' || return 1
	! ip -4 rule show 2>/dev/null |
		awk -v priority="$guard_rule_priority:" '$1 == priority { found=1 } END { exit !found }' || return 1
	! ip -6 rule show 2>/dev/null |
		awk -v priority="$guard_rule_priority:" '$1 == priority { found=1 } END { exit !found }' || return 1
	! "$nft_bin" list table inet "$guard_nft_table" >/dev/null 2>&1 || return 1
	for chain in pbr_prerouting pbr_forward mangle_forward; do
		! "$nft_bin" list chain inet fw4 "$chain" 2>/dev/null |
			grep -Eq 'IKEv2 Site Link: (YouTube|selected services|direct exit WAN)|ikev2-site-link-(force-youtube-tcp|mss-clamp)' || return 1
	done
}

repair_source_structure() {
	device="$(getv xfrm_device ipsec-home)"
	if_id="$(getv if_id 44)"
	xfrm_ready "$device" "$if_id" || ensure_xfrm "$device" "$if_id" || return 1
	ensure_probe_rule || return 1
	if ! source_conn_loaded; then
		swanctl --load-conns >/dev/null 2>&1 || return 1
		swanctl --load-creds --noprompt >/dev/null 2>&1 || return 1
	fi
	if source_sa_ready; then
		sync_vip || return 1
	else
		reconcile_source_routes || return 1
	fi
	guard_sync
}

repair_exit_structure() {
	device="$(getv exit_device ipsec-site-exit)"
	if_id="$(getv exit_if_id 45)"
	xfrm_ready "$device" "$if_id" || ensure_xfrm "$device" "$if_id" || return 1
	if ! exit_conn_loaded; then
		swanctl --load-conns >/dev/null 2>&1 || return 1
		swanctl --load-pools >/dev/null 2>&1 || return 1
		swanctl --load-creds --noprompt >/dev/null 2>&1 || return 1
	fi
	ensure_exit_route
}

connect_source() {
	ensure_xfrm || return 1
	swanctl --load-conns >/dev/null 2>&1 || return 1
	swanctl --load-creds >/dev/null 2>&1 || return 1
	swanctl --initiate --child site-link4 --timeout 20 >/dev/null 2>&1 || true
	sync_vip
}

connect_impl() {
	validate_config
	[ "$(getv enabled 0)" = 1 ] || die 'site link is disabled'
	[ "$(role)" = source ] || die 'connect is valid only on the source router'
	connect_source
}

apply_impl() {
	use_candidate_config
	validate_config
	if [ "$(getv enabled 0)" != 1 ]; then
		disable_impl
		return
	fi
	validate_dependency_contract
	inactive_role_present &&
		die 'disable the existing role before changing the router role'
	applied_resources_match ||
		die 'disable the existing link before changing its role, interface names, XFRM IDs or pool'
	exit_pool_route_available ||
		die 'dedicated tunnel address overlaps an existing local or routed network'
	if [ "$(role)" = exit ]; then
		secret_configured || die 'peer secret is not configured'
		exit_apply_transaction
	else
		secret_configured || die 'peer secret is not configured'
		source_apply_transaction
	fi
	"$site_init" enable >/dev/null 2>&1 || true
	"$site_init" restart >/dev/null 2>&1 || true
	if [ "$(role)" = source ]; then
		probe_save 1
		status_write ok 'configuration applied and data plane verified'
	else
		status_write idle 'configuration applied; waiting for peer traffic'
	fi
}

disable_impl() {
	from_monitor=0
	[ "${1:-}" != monitor ] || from_monitor=1
	cleanup_ok=1
	# Teardown targets the last successfully applied snapshot. Candidate values
	# may already contain a rejected role, interface or XFRM identifier.
	use_applied_config || use_candidate_config
	applied_source_interface="$(applied_get interface "$(getv interface sitehome)")"
	applied_source_device="$(applied_get xfrm_device "$(getv xfrm_device ipsec-home)")"
	applied_source_if_id="$(applied_get if_id "$(getv if_id 44)")"
	applied_exit_device="$(applied_get exit_device "$(getv exit_device ipsec-site-exit)")"
	applied_exit_if_id="$(applied_get exit_if_id "$(getv exit_if_id 45)")"
	applied_exit_pool="$(applied_get exit_pool "$(getv exit_pool 10.253.44.2)")"
	# Stop procd before touching an SA, address or route. Otherwise an iteration
	# already in flight can recreate runtime state during teardown.
	if [ "$from_monitor" = 0 ]; then
		"$site_init" stop >/dev/null 2>&1 || cleanup_ok=0
	fi
	# The command is a complete state transition, not just runtime cleanup. In
	# particular package removal and direct CLI use must not leave a logically
	# enabled configuration that can be started again later.
	uci set "$config_name.main.enabled=0" || cleanup_ok=0
	uci commit "$config_name" || cleanup_ok=0
	swanctl --terminate --ike site-link --timeout 5 >/dev/null 2>&1 || true
	swanctl --terminate --ike site-link-in --timeout 5 >/dev/null 2>&1 || true
	printf '%s\n' '# IKEv2 Site Link is disabled.' >"$conn_file.new"
	atomic_install "$conn_file.new" "$conn_file" 600
	printf '%s\n' '# IKEv2 Site Link secret is retained outside swanctl.' >"$cred_file.new"
	atomic_install "$cred_file.new" "$cred_file" 600
	printf '%s\n' '# IKEv2 Site Link exit is disabled.' >"$exit_conn_file.new"
	atomic_install "$exit_conn_file.new" "$exit_conn_file" 600
	printf '%s\n' '# IKEv2 Site Link exit secret is retained outside swanctl.' >"$exit_cred_file.new"
	atomic_install "$exit_cred_file.new" "$exit_cred_file" 600
	swanctl --load-conns >/dev/null 2>&1 || cleanup_ok=0
	swanctl --load-pools >/dev/null 2>&1 || cleanup_ok=0
	# load-creds tracks VICI shared-key identifiers and unloads only entries no
	# longer present on disk; unlike --clear this does not create an authentication
	# gap for unrelated IKEv2 Manager credentials.
	swanctl --load-creds --noprompt >/dev/null 2>&1 || cleanup_ok=0
	delete_probe_rule "$(getv xfrm_device ipsec-home)" "$(getv interface sitehome)" || cleanup_ok=0
	delete_probe_rule "$applied_source_device" "$applied_source_interface" || cleanup_ok=0
	guard_remove || cleanup_ok=0
	all_uci_remove || cleanup_ok=0
	source_device="$(getv xfrm_device ipsec-home)"
	exit_device="$(getv exit_device ipsec-site-exit)"
	exit_pool="$(getv exit_pool 10.253.44.2)"
	if valid_ipv4 "$exit_pool" && valid_device "$exit_device"; then
		ip -4 route del "$exit_pool/32" dev "$exit_device" 2>/dev/null || true
	fi
	if valid_ipv4 "$applied_exit_pool" && valid_device "$applied_exit_device"; then
		ip -4 route del "$applied_exit_pool/32" dev "$applied_exit_device" 2>/dev/null || true
	fi
	valid_device "$source_device" &&
		ip -4 addr flush dev "$source_device" scope global 2>/dev/null || true
	delete_xfrm_candidate "$source_device" "$(getv if_id 44)" || cleanup_ok=0
	delete_xfrm_candidate "$exit_device" "$(getv exit_if_id 45)" || cleanup_ok=0
	delete_xfrm_candidate "$applied_source_device" "$applied_source_if_id" || cleanup_ok=0
	delete_xfrm_candidate "$applied_exit_device" "$applied_exit_if_id" || cleanup_ok=0
	tries=0
	while { source_sa_ready || exit_sa_ready; } && [ "$tries" -lt 5 ]; do
		tries=$((tries + 1))
		sleep 1
	done
	! source_sa_ready && ! exit_sa_ready || cleanup_ok=0
	! source_conn_loaded && ! exit_conn_loaded || cleanup_ok=0
	# A later enable must not repopulate PBR sets with addresses learned before
	# the tunnel was explicitly disabled.
	rm -f "$probe_state" "$exit_traffic_state" "$set_dump4" "$set_dump6" \
		"$persistent_set_dump4" "$persistent_set_dump6"
	uci -q delete "$config_name.applied" || true
	uci commit "$config_name" || cleanup_ok=0
	"$site_init" disable >/dev/null 2>&1 || true
	[ "$cleanup_ok" = 1 ] || die 'site link disabled but runtime cleanup is incomplete'
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
	candidate_enabled="$(uci -q get "$config_name.main.enabled" 2>/dev/null || echo 0)"
	candidate_role="$(uci -q get "$config_name.main.role" 2>/dev/null || echo source)"
	if use_applied_config; then
		enabled="$(getv enabled 0)"
		printf 'prepared=%s\napplied=1\nconfiguration=%s\ncandidate_role=%s\n' \
			"$candidate_enabled" \
			"$(candidate_applied_match && echo applied || echo prepared)" "$candidate_role"
	else
		enabled=0
		config_section=main
		printf 'prepared=%s\napplied=0\nconfiguration=prepared\ncandidate_role=%s\n' \
			"$candidate_enabled" "$candidate_role"
	fi
	current_role="$(role)"
	device="$(getv xfrm_device ipsec-home)"
	valid_device "$device" || device=invalid
	printf 'enabled=%s\nrole=%s\nsecret=%s\nsecret_pending=%s\n' "$enabled" "$current_role" \
		"$(secret_configured && echo configured || echo missing)" \
		"$(secret_pending && echo staged || echo none)"
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
		printf 'fail_closed=%s\n' "$(source_ipv4_terminal_ready && source_ipv6_terminal_ready &&
			guard_route_ready &&
			echo active || echo missing)"
		printf 'route=%s\npbr=%s\nguard=%s\ndata_plane=%s\ntunnel_data_plane=%s\nclassifier=%s\nclient_forwarding=%s\n' \
			"$(source_routes_ready && echo healthy || echo missing)" \
			"$(source_pbr_ready && source_aux_rules_ready && echo healthy || echo missing)" \
			"$(guard_runtime_ready && echo healthy || echo missing)" \
			"$(probe_recent_success && echo verified || echo unverified)" \
			"$(probe_recent_success && echo verified || echo unverified)" \
			"$(global_pbr_contract_ready && global_dns_contract_ready && policy_configuration_ready &&
				source_pbr_ready && source_aux_rules_ready && guard_runtime_ready &&
				echo healthy || echo missing)" \
			"$(source_managed_config_ready && echo configured || echo missing)"
		printf 'pbr_contract=%s\ndns_contract=%s\ncertificate_contract=not-applicable\n' \
			"$(global_pbr_contract_ready && echo ready || echo missing)" \
			"$(global_dns_contract_ready && echo ready || echo missing)"
	else
		device="$(getv exit_device ipsec-site-exit)"
		valid_device "$device" || device=invalid
		printf 'interface=%s\ninterface_present=%s\n' "$device" \
			"$([ -d "/sys/class/net/$device" ] && echo 1 || echo 0)"
		printf 'sa=%s\n' "$(exit_sa_ready && echo connected || echo disconnected)"
		printf 'rx_bytes=%s\ntx_bytes=%s\n' \
			"$(cat "/sys/class/net/$device/statistics/rx_bytes" 2>/dev/null || echo 0)" \
			"$(cat "/sys/class/net/$device/statistics/tx_bytes" 2>/dev/null || echo 0)"
		printf 'vip=%s\nfail_closed=not-applicable\n' "$(getv exit_pool 10.253.44.2)"
		printf 'route=%s\npbr=%s\ndata_plane=%s\ntunnel_data_plane=%s\nclassifier=%s\nclient_forwarding=%s\n' \
			"$(exit_route_ready && echo healthy || echo missing)" \
			"$(exit_pbr_ready && echo healthy || echo missing)" \
			"$(exit_traffic_recent && echo verified || echo unverified)" \
			"$(exit_traffic_recent && echo verified || echo unverified)" \
			"$(global_pbr_contract_ready && exit_pbr_ready && echo healthy || echo missing)" \
			"$(exit_managed_config_ready && echo configured || echo missing)"
		printf 'pbr_contract=%s\ndns_contract=not-applicable\ncertificate_contract=%s\n' \
			"$(global_pbr_contract_ready && echo ready || echo missing)" \
			"$(server_certificate_ready && echo ready || echo missing)"
	fi
	updated="$(sed -n 's/^updated=//p' "$state_file" 2>/dev/null | tail -n1)"
	[ -z "$updated" ] || printf 'updated=%s\n' "$updated"
	if [ "$enabled" != 1 ]; then
		if disabled_runtime_ready; then
			printf 'state=disabled\ndetail=site link disabled\n'
		else
			printf 'state=degraded\ndetail=disable cleanup is incomplete\n'
		fi
	elif [ "$current_role" = source ]; then
		if source_control_ready && probe_recent_success; then
			printf 'state=ok\ndetail=control plane and bidirectional data plane are healthy\n'
		else
			printf 'state=degraded\ndetail=control-plane invariant or recent data-plane probe is missing\n'
		fi
	elif exit_control_ready && ! exit_sa_ready; then
		printf 'state=idle\ndetail=exit route is protected; waiting for peer\n'
	elif exit_control_ready && exit_sa_ready && exit_traffic_recent; then
		printf 'state=ok\ndetail=exit route, SA and bidirectional traffic are healthy\n'
	else
		printf 'state=degraded\ndetail=exit XFRM, route, PBR or bidirectional traffic is missing\n'
	fi
	return 0
}

monitor_loop() {
	use_applied_config || die 'no applied configuration exists'
	pid_lock_acquire "$monitor_lock_dir" || die 'monitor is already running'
	monitor_wait_pid=
	monitor_cleanup() {
		trap - EXIT HUP INT TERM
		if [ -n "${monitor_wait_pid:-}" ]; then
			kill "$monitor_wait_pid" >/dev/null 2>&1 || true
			wait "$monitor_wait_pid" 2>/dev/null || true
			monitor_wait_pid=
		fi
		# A signal can arrive while a repair owns both action locks. The monitor
		# handler, rather than the nested helper, owns signal cleanup.
		locks_release
		if [ "$(getv enabled 0)" = 1 ] && [ "$(role)" = source ]; then
			persist_pbr_sets >/dev/null 2>&1 || true
		fi
		pid_lock_release "$monitor_lock_dir"
	}
	trap 'monitor_cleanup; exit 0' HUP INT TERM
	trap 'monitor_cleanup' EXIT
	monitor_wait() {
		sleep "$1" &
		monitor_wait_pid=$!
		wait "$monitor_wait_pid" 2>/dev/null || true
		monitor_wait_pid=
	}
	failures=0
	first=1
	last_attempt=0
	last_aux_repair=0
	last_set_dump=0
	while :; do
		if [ "$(getv enabled 0)" != 1 ]; then
			if disabled_runtime_ready; then
				status_write disabled 'site link disabled'
			else
				# Cleanup mutates network, firewall and PBR configuration. Never let a
				# background monitor perform that transaction; require explicit Apply.
				status_write degraded 'disabled configuration still has runtime state; apply Disable manually'
			fi
			[ "${SITE_LINK_MONITOR_ONCE:-0}" = 1 ] && break
			monitor_wait 30
			continue
		fi
		if ! (validate_config >/dev/null 2>&1); then
			status_write degraded 'configuration validation failed; no repair attempted'
			[ "${SITE_LINK_MONITOR_ONCE:-0}" = 1 ] && break
			monitor_wait 30
			continue
		fi
		if [ "$(role)" = source ]; then
			now="$(date +%s)"
			if time_due "$now" "$last_set_dump" 60; then
				try_with_lock guard-sync guard_sync >/dev/null 2>&1 || true
				last_set_dump="$now"
			fi
			# XFRM/VIP/default drift is cheap to repair and must be corrected on
			# every iteration. The operation is skipped while another package owns
			# the shared network-action lock.
			if ! source_conn_loaded ||
			   ! xfrm_ready "$(getv xfrm_device ipsec-home)" "$(getv if_id 44)" ||
			   ! probe_rule_ready ||
			   ! guard_runtime_ready ||
			   { source_sa_ready && { ! source_vip_ready || ! source_routes_ready; }; } ||
			   { ! source_sa_ready && { ! source_fail_closed_ready || source_live_route_ready; }; }; then
				try_with_lock source-reconcile repair_source_structure >/dev/null 2>&1 || true
			fi
			# Managed UCI/PBR drift is intentionally not repaired here. A global PBR
			# reload disables forwarding on current OpenWrt PBR releases and must be
			# an explicit, visible transaction rather than a watchdog side effect.
			if source_pbr_ready && ! source_aux_rules_ready &&
			   time_due "$now" "$last_aux_repair" 60; then
				last_aux_repair="$now"
				try_with_lock nft-reconcile repair_source_aux >/dev/null 2>&1 || true
			fi
			if source_sa_ready; then
				failures=0
			else
				failures=$((failures + 1))
				threshold="$(getv failure_threshold 3)"
				[ "$first" = 1 ] && failures="$threshold"
				cooldown="$(getv reconnect_cooldown 30)"
				if [ "$failures" -ge "$threshold" ] &&
				   time_due "$now" "$last_attempt" "$cooldown"; then
					last_attempt="$now"
					try_with_lock reconnect connect_source >/dev/null 2>&1 || true
					failures="$threshold"
				fi
			fi
			if source_control_ready && probe_due "$now"; then
				if data_plane_ready; then probe_save 1; else probe_save 0; fi
			fi
			# Public probe failures are telemetry only. strongSwan DPD reconnects a
			# dead peer; the monitor must not reset an installed SA due to an external
			# service or path-specific failure.
			if source_control_ready && probe_recent_success; then
				status_write ok 'control plane and bidirectional data plane are healthy'
			else
				status_write degraded 'control-plane invariant or data-plane probe failed'
			fi
		else
			now="$(date +%s)"
			if ! exit_conn_loaded ||
			   ! xfrm_ready "$(getv exit_device ipsec-site-exit)" "$(getv exit_if_id 45)" ||
			   ! exit_route_ready; then
				try_with_lock exit-reconcile repair_exit_structure >/dev/null 2>&1 || true
			fi
			if exit_sa_ready; then
				exit_traffic_update >/dev/null 2>&1 || true
			fi
			if ! exit_control_ready; then
				status_write degraded 'exit XFRM, route or PBR invariant is missing'
			elif ! exit_sa_ready; then
				status_write idle 'exit route is protected; waiting for peer'
			elif exit_traffic_recent; then
				status_write ok 'exit route, SA and bidirectional traffic are healthy'
			else
				status_write degraded 'peer SA has no verified bidirectional traffic'
			fi
		fi
		first=0
		[ "${SITE_LINK_MONITOR_ONCE:-0}" = 1 ] && break
		monitor_wait "$(getv monitor_interval 15)"
	done
	monitor_cleanup
}

# Candidate PBR source selectors for the LuCI form, as "device=hint" lines.
# Enumerated here rather than over ubus so the page needs no broader ACL than
# the status commands it already runs.
sources_emit() {
	own="$(getv xfrm_device ipsec-home)"
	exit_own="$(getv exit_device ipsec-site-exit)"
	wan_device="$(ip -4 route show default 2>/dev/null |
		awk 'NR == 1 { for (i = 1; i <= NF; i++) if ($i == "dev") print $(i + 1) }')"
	ip -o link show up 2>/dev/null |
		awk -F': ' '{ print $2 }' |
		sed 's/@.*//' |
		while IFS= read -r device; do
			[ -n "$device" ] || continue
			case "$device" in
				lo | "$own" | "$exit_own" | "$wan_device") continue ;;
			esac
			name="$(uci -q show network 2>/dev/null |
				sed -n "s/^network\.\([^.]*\)\.device='$device'\$/\1/p" | head -n1)"
			address="$(ip -4 -o addr show dev "$device" scope global 2>/dev/null |
				awk 'NR == 1 { print $4 }')"
			# Switch ports and radio interfaces carry no routable source
			# traffic of their own; a candidate needs a configured network
			# or an address to be a meaningful selector.
			[ -n "$name" ] || [ -n "$address" ] || continue
			hint="$(printf '%s %s' "$name" "$address" | sed 's/^ *//; s/ *$//')"
			printf '%s=%s\n' "$device" "$hint"
		done
}

# Firewall zones for the form, as "name=networks" lines.
zones_emit() {
	uci -q show firewall 2>/dev/null |
		sed -n "s/^firewall\.\([^.]*\)\.name='\(.*\)'\$/\1 \2/p" |
		while read -r section name; do
			[ "$(uci -q get "firewall.$section" 2>/dev/null)" = zone ] || continue
			printf '%s=%s\n' "$name" \
				"$(uci -q get "firewall.$section.network" 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')"
		done
}

case "${1:-}" in
	apply) with_lock apply apply_impl ;;
	sources) sources_emit ;;
	zones) zones_emit ;;
	disable) with_lock disable disable_impl ;;
	connect) use_applied_config || die 'no applied configuration exists'; with_lock connect connect_impl ;;
	secret-set) with_lock secret-set consume_secret_input "${2:-}" ;;
	secret-activate) with_lock secret-activate activate_secret_impl ;;
	secret-rollback) with_lock secret-rollback rollback_secret_impl ;;
	migrate-applied) with_lock migrate-applied migrate_applied_impl ;;
	policy-reload) use_applied_config || exit 0; with_lock policy-reload policy_reload_impl ;;
	policy-check) use_applied_config || exit 0; policy_check ;;
	status) status_emit ;;
	check) validate_config; status_emit ;;
	monitor) monitor_loop ;;
	render) if [ "$(role)" = exit ]; then render_exit; else render_source; fi ;;
	*) die 'usage: ikev2-site-link {apply|disable|connect|secret-set TOKEN|secret-activate|secret-rollback|migrate-applied|policy-reload|policy-check|status|check|sources|zones|monitor|render}' ;;
esac
