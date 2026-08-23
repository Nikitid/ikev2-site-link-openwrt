#!/bin/sh

set -eu
root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM
mkdir -p "$tmp/bin" "$tmp/config"

cat >"$tmp/bin/uci" <<'EOF'
#!/bin/sh
state="${SITE_LINK_TEST_UCI_STATE:?}"
[ "${1:-}" = -c ] && shift 2
[ "${1:-}" = -q ] && shift
case "${1:-}" in
	get)
		awk -F= -v key="${2:-}" '$1 == key { sub(/^[^=]*=/, ""); print; found=1 } END { exit !found }' "$state"
		;;
	set)
		key="${2%%=*}"
		value="${2#*=}"
		awk -F= -v key="$key" -v value="$value" '
			$1 == key { print key "=" value; found=1; next }
			{ print }
			END { if (!found) print key "=" value }
		' "$state" >"$state.next"
		mv "$state.next" "$state"
		;;
	delete)
		awk -F= -v key="${2:-}" '$1 != key { print }' "$state" >"$state.next"
		mv "$state.next" "$state"
		;;
	reorder | commit) ;;
	*) exit 1 ;;
esac
EOF

cat >"$tmp/bin/ip" <<'EOF'
#!/bin/sh
log="${SITE_LINK_TEST_IP_LOG:?}"
route="${SITE_LINK_TEST_EXIT_ROUTE:?}"
case "$*" in
	'-d link show ipsec-site-exit')
		echo '9: ipsec-site-exit: <NOARP,UP,LOWER_UP> mtu 1360 state UNKNOWN mode DEFAULT group default qlen 1000 xfrm if_id 0x2d'
		;;
	'link show ipsec-site-exit')
		echo '9: ipsec-site-exit: <NOARP,UP,LOWER_UP> mtu 1360 state UNKNOWN mode DEFAULT group default qlen 1000'
		;;
	'-o link show ipsec-site-exit')
		echo '9: ipsec-site-exit: <NOARP,UP,LOWER_UP> mtu 1360 state UNKNOWN mode DEFAULT group default qlen 1000'
		;;
	'-4 route show 10.253.44.2/32')
		cat "$route"
		;;
	'-4 route del 10.253.44.2/32')
		[ -s "$route" ] || exit 2
		: >"$route"
		printf '%s\n' 'route-del' >>"$log"
		;;
	'-4 route replace 10.253.44.2/32 dev ipsec-site-exit')
		# iproute2 normally omits /32 when rendering a host route.
		printf '%s\n' '10.253.44.2 dev ipsec-site-exit' >"$route"
		printf '%s\n' 'route-replace' >>"$log"
		;;
	*)
		printf 'unexpected ip command: %s\n' "$*" >&2
		exit 1
		;;
esac
EOF

cat >"$tmp/bin/swanctl" <<'EOF'
#!/bin/sh
case "$*" in
	'--list-conns --raw')
		echo 'list-conn event {site-link-in {children {site-link-net {}}}}'
		;;
	'--list-sas --raw') [ ! -s "$SITE_LINK_TEST_EXIT_SA" ] || cat "$SITE_LINK_TEST_EXIT_SA" ;;
	*) printf 'unexpected swanctl command: %s\n' "$*" >&2; exit 1 ;;
esac
EOF

cat >"$tmp/bin/pbr-init" <<'EOF'
#!/bin/sh
case "$1" in
	running) exit 0 ;;
	reload)
		printf '%s\n' reload >>"$SITE_LINK_TEST_PBR_LOG"
		printf '%s\n' ready >"$SITE_LINK_TEST_NFT_STATE"
		;;
	*) printf 'unexpected pbr command: %s\n' "$*" >&2; exit 1 ;;
esac
EOF

cat >"$tmp/bin/service-reload" <<'EOF'
#!/bin/sh
case "${1:-}" in
	check | reload) printf '%s %s\n' "${0##*/}" "$1" >>"$SITE_LINK_TEST_SERVICE_LOG" ;;
	*) exit 1 ;;
esac
EOF

cat >"$tmp/bin/nft" <<'EOF'
#!/bin/sh
case "$*" in
	'list chain inet fw4 pbr_prerouting')
		[ -s "$SITE_LINK_TEST_NFT_STATE" ] || exit 1
		echo 'meta mark set 0x10000 comment "IKEv2 Site Link: direct exit WAN"'
		;;
	'list chain inet fw4 forward_siteexit')
		echo 'jump accept_to_wan comment "!fw4: Accept siteexit to wan forwarding"'
		;;
	'list chain inet fw4 dstnat_wan')
		echo 'meta nfproto ipv4 udp dport 1500 counter redirect to :4500 comment "!fw4: IKEv2 Site Link: dedicated IKE port"'
		;;
	*) printf 'unexpected nft command: %s\n' "$*" >&2; exit 1 ;;
esac
EOF

cat >"$tmp/exit.uci" <<'EOF'
ikev2-site-link.main.enabled=1
ikev2-site-link.main.role=exit
ikev2-site-link.main.remote_id=vpn.example.net
ikev2-site-link.main.peer_user=site-link
ikev2-site-link.main.exit_device=ipsec-site-exit
ikev2-site-link.main.exit_if_id=45
ikev2-site-link.main.exit_pool=10.253.44.2
ikev2-site-link.main.mtu=1360
ikev2-site-link.main.monitor_interval=15
ikev2-site-link.applied=state
ikev2-site-link.applied.enabled=1
ikev2-site-link.applied.role=exit
ikev2-site-link.applied.remote_id=vpn.example.net
ikev2-site-link.applied.peer_user=site-link
ikev2-site-link.applied.ike_port=1500
ikev2-site-link.applied.exit_interface=siteexit
ikev2-site-link.applied.exit_device=ipsec-site-exit
ikev2-site-link.applied.exit_if_id=45
ikev2-site-link.applied.exit_pool=10.253.44.2
ikev2-site-link.applied.exit_wan=wan
ikev2-site-link.applied.exit_wan_zone=wan
ikev2-site-link.applied.mtu=1360
ikev2-site-link.applied.monitor_interval=15
pbr.config.enabled=1
pbr.config.strict_enforcement=1
network.siteexit=interface
network.siteexit.proto=none
network.siteexit.device=ipsec-site-exit
firewall.ikev2_site_link_exit=zone
firewall.ikev2_site_link_exit.name=siteexit
firewall.ikev2_site_link_exit.network=siteexit
firewall.ikev2_site_link_exit.input=REJECT
firewall.ikev2_site_link_exit.output=ACCEPT
firewall.ikev2_site_link_exit.forward=REJECT
firewall.ikev2_site_link_exit.mtu_fix=1
firewall.ikev2_site_link_exit_wan=forwarding
firewall.ikev2_site_link_exit_wan.src=siteexit
firewall.ikev2_site_link_exit_wan.dest=wan
firewall.ikev2_site_link_ike=redirect
firewall.ikev2_site_link_ike.name=IKEv2 Site Link: dedicated IKE port
firewall.ikev2_site_link_ike.src=wan
firewall.ikev2_site_link_ike.proto=udp
firewall.ikev2_site_link_ike.src_dport=1500
firewall.ikev2_site_link_ike.dest_port=4500
firewall.ikev2_site_link_ike.family=ipv4
firewall.ikev2_site_link_ike.target=DNAT
pbr.ikev2_site_link=policy
pbr.ikev2_site_link.name=IKEv2 Site Link: direct exit WAN
pbr.ikev2_site_link.interface=wan
pbr.ikev2_site_link.src_addr=@ipsec-site-exit
pbr.ikev2_site_link.proto=all
pbr.ikev2_site_link.enabled=1
EOF
chmod 755 "$tmp/bin"/*
: >"$tmp/ip.log"
: >"$tmp/pbr.log"
printf '%s\n' ready >"$tmp/nft.state"
printf '%s\n' '10.253.44.2 dev wan' >"$tmp/exit.route"
: >"$tmp/exit.sa"
: >"$tmp/service.log"
: >"$tmp/server-cert.pem"
: >"$tmp/server-key.pem"
printf '%s\n' fixture >"$tmp/server-cert.pem"

# Releases before the full applied snapshot could leave only an applied role.
# Treat that section as incomplete and migrate the active candidate instead of
# leaving procd without a monitor after package upgrade.
cat >"$tmp/migrate.uci" <<'EOF'
ikev2-site-link.main.enabled=1
ikev2-site-link.main.role=source
ikev2-site-link.main.endpoint=vpn.example.net
ikev2-site-link.main.remote_id=vpn.example.net
ikev2-site-link.main.peer_user=site-link
ikev2-site-link.main.source_devices=@br-lan
ikev2-site-link.applied=state
ikev2-site-link.applied.role=source
firewall.ikev2_site_link=zone
firewall.ikev2_site_link.name=sitehome
EOF
PATH="$tmp/bin:/usr/bin:/bin" \
SITE_LINK_TEST_UCI_STATE="$tmp/migrate.uci" \
SITE_LINK_UCI_DIR="$tmp/config" \
SITE_LINK_LOCK="$tmp/migrate-site.lock" \
IKEV2_ACTION_LOCK="$tmp/migrate-action.lock" \
IKEV2_ACTION_LOCK_STATUS="$tmp/migrate-action.status" \
	sh "$root/runtime/ikev2-site-link.sh" migrate-applied
grep -Fxq 'ikev2-site-link.applied.enabled=1' "$tmp/migrate.uci"
grep -Fxq 'ikev2-site-link.applied.role=source' "$tmp/migrate.uci"
grep -Fxq 'ikev2-site-link.applied.endpoint=vpn.example.net' "$tmp/migrate.uci"
printf '%s\n' fixture >"$tmp/server-key.pem"

run_exit_monitor() {
	PATH="$tmp/bin:/usr/bin:/bin" \
	SITE_LINK_TEST_UCI_STATE="$tmp/exit.uci" \
	SITE_LINK_TEST_IP_LOG="$tmp/ip.log" \
	SITE_LINK_TEST_EXIT_ROUTE="$tmp/exit.route" \
	SITE_LINK_TEST_PBR_LOG="$tmp/pbr.log" \
	SITE_LINK_TEST_NFT_STATE="$tmp/nft.state" \
	SITE_LINK_UCI_DIR="$tmp/config" \
	SITE_LINK_STATE="$tmp/status" \
	SITE_LINK_EXIT_TRAFFIC_STATE="$tmp/exit-traffic.status" \
	SITE_LINK_TEST_EXIT_SA="$tmp/exit.sa" \
	SITE_LINK_LOCK="$tmp/site.lock" \
	SITE_LINK_MONITOR_LOCK="$tmp/monitor.lock" \
	IKEV2_ACTION_LOCK="$tmp/action.lock" \
	IKEV2_ACTION_LOCK_STATUS="$tmp/action.status" \
	SITE_LINK_PBR_INIT="$tmp/bin/pbr-init" \
	SITE_LINK_NFT="$tmp/bin/nft" \
	SITE_LINK_NETWORK_INIT="$tmp/bin/service-reload" \
	SITE_LINK_FIREWALL_INIT="$tmp/bin/service-reload" \
	SITE_LINK_FW4="$tmp/bin/service-reload" \
	SITE_LINK_TEST_SERVICE_LOG="$tmp/service.log" \
	SITE_LINK_SERVER_CERT="$tmp/server-cert.pem" \
	SITE_LINK_SERVER_KEY="$tmp/server-key.pem" \
	SITE_LINK_MONITOR_ONCE=1 \
		sh "$root/runtime/ikev2-site-link.sh" monitor
}

run_exit_monitor_continuous() {
	PATH="$tmp/bin:/usr/bin:/bin" \
	SITE_LINK_TEST_UCI_STATE="$tmp/exit.uci" \
	SITE_LINK_TEST_IP_LOG="$tmp/ip.log" \
	SITE_LINK_TEST_EXIT_ROUTE="$tmp/exit.route" \
	SITE_LINK_TEST_PBR_LOG="$tmp/pbr.log" \
	SITE_LINK_TEST_NFT_STATE="$tmp/nft.state" \
	SITE_LINK_UCI_DIR="$tmp/config" \
	SITE_LINK_STATE="$tmp/status" \
	SITE_LINK_EXIT_TRAFFIC_STATE="$tmp/exit-traffic.status" \
	SITE_LINK_TEST_EXIT_SA="$tmp/exit.sa" \
	SITE_LINK_LOCK="$tmp/site.lock" \
	SITE_LINK_MONITOR_LOCK="$tmp/monitor.lock" \
	IKEV2_ACTION_LOCK="$tmp/action.lock" \
	IKEV2_ACTION_LOCK_STATUS="$tmp/action.status" \
	SITE_LINK_PBR_INIT="$tmp/bin/pbr-init" \
	SITE_LINK_NFT="$tmp/bin/nft" \
	SITE_LINK_NETWORK_INIT="$tmp/bin/service-reload" \
	SITE_LINK_FIREWALL_INIT="$tmp/bin/service-reload" \
	SITE_LINK_FW4="$tmp/bin/service-reload" \
	SITE_LINK_TEST_SERVICE_LOG="$tmp/service.log" \
	SITE_LINK_SERVER_CERT="$tmp/server-cert.pem" \
	SITE_LINK_SERVER_KEY="$tmp/server-key.pem" \
		exec sh "$root/runtime/ikev2-site-link.sh" monitor
}

# A wrong /32 route is replaced immediately, then a stable pass is read-only.
run_exit_monitor
grep -Fxq '10.253.44.2 dev ipsec-site-exit' "$tmp/exit.route"
[ "$(grep -c '^route-replace$' "$tmp/ip.log")" = 1 ]
grep -Fxq 'state=idle' "$tmp/status"
run_exit_monitor
[ "$(grep -c '^route-replace$' "$tmp/ip.log")" = 1 ]

# Editing candidate values alone must not retarget a live monitor iteration.
sed 's/ikev2-site-link.main.exit_pool=10.253.44.2/ikev2-site-link.main.exit_pool=10.253.44.99/' \
	"$tmp/exit.uci" >"$tmp/exit.uci.next"
mv "$tmp/exit.uci.next" "$tmp/exit.uci"
run_exit_monitor
grep -Fxq '10.253.44.2 dev ipsec-site-exit' "$tmp/exit.route"
if grep -Fq '10.253.44.99' "$tmp/ip.log"; then
	echo 'monitor consumed candidate exit_pool instead of applied state' >&2
	exit 1
fi

# Exact managed UCI invariants are reconciled, including the forwarding, DNAT
# and concrete PBR fields; this is intentionally stronger than a chain comment.
for key in firewall.ikev2_site_link_exit_wan.dest \
	firewall.ikev2_site_link_ike.target pbr.ikev2_site_link.interface; do
	awk -F= -v key="$key" '$1 != key { print }' "$tmp/exit.uci" >"$tmp/exit.uci.next"
	mv "$tmp/exit.uci.next" "$tmp/exit.uci"
done
: >"$tmp/service.log"
run_exit_monitor
grep -Fxq 'firewall.ikev2_site_link_exit_wan.dest=wan' "$tmp/exit.uci"
grep -Fxq 'firewall.ikev2_site_link_ike.target=DNAT' "$tmp/exit.uci"
grep -Fxq 'pbr.ikev2_site_link.interface=wan' "$tmp/exit.uci"
grep -q 'service-reload reload' "$tmp/service.log"

# A repair must not erase the monitor's outer TERM/EXIT handlers. Otherwise a
# later procd stop needs SIGKILL and leaves its PID lock behind.
: >"$tmp/ip.log"
printf '%s\n' '10.253.44.2 dev wan' >"$tmp/exit.route"
run_exit_monitor_continuous &
monitor_pid=$!
tries=0
while ! grep -q '^route-replace$' "$tmp/ip.log" 2>/dev/null; do
	tries=$((tries + 1))
	if [ "$tries" -ge 50 ]; then
		kill -KILL "$monitor_pid" 2>/dev/null || true
		wait "$monitor_pid" 2>/dev/null || true
		echo 'continuous monitor did not perform its fixture repair' >&2
		exit 1
	fi
	sleep 0.1
done
kill -TERM "$monitor_pid"
wait "$monitor_pid"
[ ! -d "$tmp/monitor.lock" ]
[ ! -d "$tmp/site.lock" ]
[ ! -d "$tmp/action.lock" ]

# Exit health is tied to recent progress in both directions on the current
# CHILD_SA, not to counters that became non-zero at any time in the past.
cat >"$tmp/exit.sa" <<'EOF'
list-sa event {site-link-in {child-sas {site-link-net-7 {name=site-link-net uniqueid=7 state=INSTALLED bytes-in=100 bytes-out=200}}}}
EOF
run_exit_monitor
grep -Fxq 'state=ok' "$tmp/status"
sed 's/^last_in=.*/last_in=0/;s/^last_out=.*/last_out=0/' \
	"$tmp/exit-traffic.status" >"$tmp/exit-traffic.next"
mv "$tmp/exit-traffic.next" "$tmp/exit-traffic.status"
run_exit_monitor
grep -Fxq 'state=degraded' "$tmp/status"
sed 's/bytes-in=100/bytes-in=101/;s/bytes-out=200/bytes-out=201/' \
	"$tmp/exit.sa" >"$tmp/exit.sa.next"
mv "$tmp/exit.sa.next" "$tmp/exit.sa"
run_exit_monitor
grep -Fxq 'state=ok' "$tmp/status"

# A missing PBR rule uses verified reload and never the destructive restart path.
: >"$tmp/nft.state"
: >"$tmp/pbr.log"
run_exit_monitor
[ "$(grep -c '^reload$' "$tmp/pbr.log")" = 1 ]
if grep -Fq restart "$tmp/pbr.log"; then
	echo 'monitor used PBR restart' >&2
	exit 1
fi

# The monitor never repairs across another package's live global action lock.
: >"$tmp/ip.log"
printf '%s\n' '10.253.44.2 dev wan' >"$tmp/exit.route"
mkdir "$tmp/action.lock"
now="$(date +%s)"
printf 'owner=test\naction_id=test\npid=%s\nupdated=%s\n' "$$" "$now" >"$tmp/action.status"
run_exit_monitor
[ ! -s "$tmp/ip.log" ]
grep -Fxq 'state=degraded' "$tmp/status"
rm -f "$tmp/action.status"
rmdir "$tmp/action.lock"

# Exercise the actual PBR include: repair is fail-closed-first, removes a wrong
# live default, installs the tunnel default, and becomes read-only when healthy.
cat >"$tmp/bin/uci-pbr" <<'EOF'
#!/bin/sh
[ "${1:-}" = -q ] && shift
case "${1:-}:${2:-}" in
	get:ikev2-site-link.applied.interface) echo sitehome ;;
	get:ikev2-site-link.applied.xfrm_device) echo ipsec-home ;;
	get:ikev2-site-link.applied.force_tcp) echo "${SITE_LINK_TEST_FORCE_TCP:-1}" ;;
	get:pbr.config.ipv6_enabled) echo "${SITE_LINK_TEST_IPV6:-0}" ;;
	*) exit 1 ;;
esac
EOF
cat >"$tmp/bin/swanctl-pbr" <<'EOF'
#!/bin/sh
[ "$*" = '--list-sas --raw' ] || exit 1
echo 'list-sa event {site-link {local-vips=[10.253.44.2] child-sas {site-link4-1 {name=site-link4 state=INSTALLED}}}}'
EOF
cat >"$tmp/bin/ip-pbr" <<'EOF'
#!/bin/sh
state="${SITE_LINK_TEST_SOURCE_ROUTES:?}"
log="${SITE_LINK_TEST_SOURCE_LOG:?}"
case "$*" in
	'link show ipsec-home') echo '8: ipsec-home: <NOARP,UP,LOWER_UP> mtu 1360 state UNKNOWN' ;;
	'-4 -o addr show dev ipsec-home scope global') echo '8: ipsec-home inet 10.253.44.2/32 scope global ipsec-home' ;;
	'-4 route show table pbr_sitehome') cat "$state" ;;
	'-6 route show table pbr_sitehome') cat "$SITE_LINK_TEST_SOURCE_ROUTES6" ;;
	'-6 route replace unreachable default metric 32767 table pbr_sitehome')
		printf '%s\n' 'unreachable default dev lo metric 32767 pref medium' >>"$SITE_LINK_TEST_SOURCE_ROUTES6"
		printf '%s\n' ipv6-failclosed >>"$log"
		;;
	'-6 route del unreachable default dev lo metric 1024 pref medium table pbr_sitehome')
		grep -v '^unreachable default dev lo metric 1024' "$SITE_LINK_TEST_SOURCE_ROUTES6" >"$SITE_LINK_TEST_SOURCE_ROUTES6.next" || true
		mv "$SITE_LINK_TEST_SOURCE_ROUTES6.next" "$SITE_LINK_TEST_SOURCE_ROUTES6"
		printf '%s\n' ipv6-stale-unreachable-delete >>"$log"
		;;
	'-6 route del default via 2001:db8::1 dev wan metric 5 table pbr_sitehome')
		grep -q '^default ' "$SITE_LINK_TEST_SOURCE_ROUTES6" || exit 2
		grep -v '^default ' "$SITE_LINK_TEST_SOURCE_ROUTES6" >"$SITE_LINK_TEST_SOURCE_ROUTES6.next" || true
		mv "$SITE_LINK_TEST_SOURCE_ROUTES6.next" "$SITE_LINK_TEST_SOURCE_ROUTES6"
		printf '%s\n' ipv6-default-delete >>"$log"
		;;
	'-4 route replace unreachable default metric 32767 table pbr_sitehome')
		printf '%s\n' failclosed-replace >>"$log"
		grep -v '^unreachable default' "$state" >"$state.next" || true
		printf '%s\n' 'unreachable default metric 32767' >>"$state.next"
		mv "$state.next" "$state"
		;;
	'-4 route del unreachable default metric 0 table pbr_sitehome') exit 2 ;;
	'-4 route del default dev wan metric 5 table pbr_sitehome')
		grep -q '^default ' "$state" || exit 2
		printf '%s\n' default-delete >>"$log"
		grep -v '^default ' "$state" >"$state.next" || true
		mv "$state.next" "$state"
		;;
	'-4 route replace default dev ipsec-home metric 10 table pbr_sitehome')
		printf '%s\n' tunnel-replace >>"$log"
		printf '%s\n' 'default dev ipsec-home metric 10' >>"$state"
		;;
	*) printf 'unexpected PBR ip command: %s\n' "$*" >&2; exit 1 ;;
esac
EOF
cat >"$tmp/bin/nft-pbr" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$SITE_LINK_TEST_NFT_LOG"
exit 1
EOF
chmod 755 "$tmp/bin/uci-pbr" "$tmp/bin/swanctl-pbr" "$tmp/bin/ip-pbr" "$tmp/bin/nft-pbr"
mkdir "$tmp/pbr-bin"
ln -s "$tmp/bin/uci-pbr" "$tmp/pbr-bin/uci"
ln -s "$tmp/bin/swanctl-pbr" "$tmp/pbr-bin/swanctl"
ln -s "$tmp/bin/ip-pbr" "$tmp/pbr-bin/ip"
printf '%s\n' 'unreachable default metric 32767' 'default dev wan metric 5' >"$tmp/source.routes"
: >"$tmp/source.routes6"
: >"$tmp/source.log"
: >"$tmp/nft.log"
PATH="$tmp/pbr-bin:/usr/bin:/bin" \
SITE_LINK_TEST_SOURCE_ROUTES="$tmp/source.routes" \
SITE_LINK_TEST_SOURCE_ROUTES6="$tmp/source.routes6" \
SITE_LINK_TEST_SOURCE_LOG="$tmp/source.log" \
SITE_LINK_TEST_NFT_LOG="$tmp/nft.log" \
SITE_LINK_NFT="$tmp/bin/nft-pbr" \
	sh "$root/runtime/pbr.user.site-link" routes-only
grep -Fxq 'unreachable default metric 32767' "$tmp/source.routes"
grep -Fxq 'default dev ipsec-home metric 10' "$tmp/source.routes"
[ "$(sed -n '1p' "$tmp/source.log")" = failclosed-replace ]
[ "$(sed -n '2p' "$tmp/source.log")" = default-delete ]
[ "$(sed -n '3p' "$tmp/source.log")" = tunnel-replace ]
[ ! -s "$tmp/nft.log" ]
: >"$tmp/source.log"
PATH="$tmp/pbr-bin:/usr/bin:/bin" \
SITE_LINK_TEST_SOURCE_ROUTES="$tmp/source.routes" \
SITE_LINK_TEST_SOURCE_ROUTES6="$tmp/source.routes6" \
SITE_LINK_TEST_SOURCE_LOG="$tmp/source.log" \
SITE_LINK_TEST_NFT_LOG="$tmp/nft.log" \
SITE_LINK_NFT="$tmp/bin/nft-pbr" \
	sh "$root/runtime/pbr.user.site-link" routes-only
[ ! -s "$tmp/source.log" ]

: >"$tmp/source.log"
printf '%s\n' 'unreachable default dev lo metric 1024 pref medium' \
	'default via 2001:db8::1 dev wan metric 5' >"$tmp/source.routes6"
SITE_LINK_TEST_IPV6=1 \
PATH="$tmp/pbr-bin:/usr/bin:/bin" \
SITE_LINK_TEST_SOURCE_ROUTES="$tmp/source.routes" \
SITE_LINK_TEST_SOURCE_ROUTES6="$tmp/source.routes6" \
SITE_LINK_TEST_SOURCE_LOG="$tmp/source.log" \
SITE_LINK_TEST_NFT_LOG="$tmp/nft.log" \
SITE_LINK_NFT="$tmp/bin/nft-pbr" \
	sh "$root/runtime/pbr.user.site-link" routes-only
grep -Fxq 'unreachable default dev lo metric 32767 pref medium' "$tmp/source.routes6"
[ "$(grep -c '^default ' "$tmp/source.routes6")" = 0 ]
grep -Fxq ipv6-failclosed "$tmp/source.log"
grep -Fxq ipv6-stale-unreachable-delete "$tmp/source.log"
grep -Fxq ipv6-default-delete "$tmp/source.log"

cat >"$tmp/bin/nft-pbr-restore" <<'EOF'
#!/bin/sh
printf 'nft %s\n' "$*" >>"$SITE_LINK_TEST_NFT_LOG"
case "$*" in
	'list set inet fw4 pbr_sitehome_4_dst_ip_ikev2_site_link')
		echo 'set pbr_sitehome_4_dst_ip_ikev2_site_link { type ipv4_addr; }'
		;;
	'list set inet fw4 pbr_sitehome_6_dst_ip_ikev2_site_link') exit 1 ;;
	'add element inet fw4 pbr_sitehome_4_dst_ip_ikev2_site_link { 203.0.113.7-203.0.113.9 }')
		printf '%s\n' restore-set >>"$SITE_LINK_TEST_NFT_LOG"
		;;
	'add rule inet fw4 mangle_forward '*)
		printf '%s\n' mss-rule >>"$SITE_LINK_TEST_NFT_LOG"
		;;
	*) exit 1 ;;
esac
EOF
cat >"$tmp/bin/stat-pbr" <<'EOF'
#!/bin/sh
[ "$1" = -c ] && [ "$2" = %Y ] || exit 1
date +%s
EOF
chmod 755 "$tmp/bin/nft-pbr-restore" "$tmp/bin/stat-pbr"
ln -s "$tmp/bin/stat-pbr" "$tmp/pbr-bin/stat"
printf '%s\n' 203.0.113.7-203.0.113.9 >"$tmp/set4.dump"
: >"$tmp/nft.log"
PATH="$tmp/pbr-bin:/usr/bin:/bin" \
SITE_LINK_TEST_SOURCE_ROUTES="$tmp/source.routes" \
SITE_LINK_TEST_SOURCE_ROUTES6="$tmp/source.routes6" \
SITE_LINK_TEST_SOURCE_LOG="$tmp/source.log" \
SITE_LINK_TEST_NFT_LOG="$tmp/nft.log" \
SITE_LINK_TEST_FORCE_TCP=0 \
SITE_LINK_SET_DUMP4="$tmp/set4.dump" \
SITE_LINK_PERSISTENT_SET_DUMP4="$tmp/missing-persistent4.dump" \
SITE_LINK_SET_DUMP6="$tmp/missing-set6.dump" \
SITE_LINK_PERSISTENT_SET_DUMP6="$tmp/missing-persistent6.dump" \
SITE_LINK_NFT="$tmp/bin/nft-pbr-restore" \
	sh "$root/runtime/pbr.user.site-link"
grep -Fxq restore-set "$tmp/nft.log" || {
	cat "$tmp/nft.log" >&2
	exit 1
}

# A corrupted snapshot is data, never an nft command stream.
printf '%s\n' '203.0.113.7 } ; flush ruleset; {' >"$tmp/set4.dump"
: >"$tmp/nft.log"
PATH="$tmp/pbr-bin:/usr/bin:/bin" \
SITE_LINK_TEST_SOURCE_ROUTES="$tmp/source.routes" \
SITE_LINK_TEST_SOURCE_ROUTES6="$tmp/source.routes6" \
SITE_LINK_TEST_SOURCE_LOG="$tmp/source.log" \
SITE_LINK_TEST_NFT_LOG="$tmp/nft.log" \
SITE_LINK_TEST_FORCE_TCP=0 \
SITE_LINK_SET_DUMP4="$tmp/set4.dump" \
SITE_LINK_PERSISTENT_SET_DUMP4="$tmp/missing-persistent4.dump" \
SITE_LINK_SET_DUMP6="$tmp/missing-set6.dump" \
SITE_LINK_PERSISTENT_SET_DUMP6="$tmp/missing-persistent6.dump" \
SITE_LINK_NFT="$tmp/bin/nft-pbr-restore" \
	sh "$root/runtime/pbr.user.site-link"
if grep -Fq 'add element' "$tmp/nft.log"; then
	echo 'corrupt PBR snapshot was passed to nft' >&2
	exit 1
fi

# Disable is role-independent and ordered: stop the monitor, terminate both
# possible SAs, unload both profiles, rebuild routing once, then delete both
# owned XFRM devices and the applied-state record.
cat >"$tmp/disable.uci" <<'EOF'
ikev2-site-link.main.enabled=1
ikev2-site-link.main.role=source
ikev2-site-link.main.interface=sitehome
ikev2-site-link.main.xfrm_device=ipsec-home
ikev2-site-link.main.if_id=44
ikev2-site-link.main.exit_interface=siteexit
ikev2-site-link.main.exit_device=ipsec-site-exit
ikev2-site-link.main.exit_if_id=45
ikev2-site-link.main.exit_pool=10.253.44.2
ikev2-site-link.applied=state
ikev2-site-link.applied.enabled=1
ikev2-site-link.applied.role=source
ikev2-site-link.applied.endpoint=new.example.net
ikev2-site-link.applied.remote_id=new.example.net
ikev2-site-link.applied.peer_user=site-link
ikev2-site-link.applied.ike_port=1500
ikev2-site-link.applied.source_devices=@br-lan
ikev2-site-link.applied.interface=sitehome
ikev2-site-link.applied.xfrm_device=ipsec-home
ikev2-site-link.applied.if_id=44
ikev2-site-link.applied.exit_interface=siteexit
ikev2-site-link.applied.exit_device=ipsec-site-exit
ikev2-site-link.applied.exit_if_id=45
ikev2-site-link.applied.exit_pool=10.253.44.2
pbr.config.ipv6_enabled=1
EOF
cat >"$tmp/bin/uci-disable" <<'EOF'
#!/bin/sh
state="${SITE_LINK_TEST_UCI_STATE:?}"
[ "${1:-}" = -c ] && shift 2
[ "${1:-}" = -q ] && shift
case "${1:-}" in
	get)
		awk -F= -v key="${2:-}" '$1 == key { sub(/^[^=]*=/, ""); print; found=1 } END { exit !found }' "$state"
		;;
	set)
		key="${2%%=*}"
		value="${2#*=}"
		awk -F= -v key="$key" -v value="$value" '
			$1 == key { print key "=" value; found=1; next }
			{ print }
			END { if (!found) print key "=" value }
		' "$state" >"$state.next"
		mv "$state.next" "$state"
		printf 'uci %s %s\n' "$1" "${2:-}" >>"$SITE_LINK_TEST_EVENTS"
		;;
	delete | del_list | commit)
		printf 'uci %s %s\n' "$1" "${2:-}" >>"$SITE_LINK_TEST_EVENTS"
		;;
	*) printf 'unexpected disable uci command: %s\n' "$*" >&2; exit 1 ;;
esac
EOF
cat >"$tmp/bin/ip-disable" <<'EOF'
#!/bin/sh
devices="${SITE_LINK_TEST_DEVICES:?}"
events="${SITE_LINK_TEST_EVENTS:?}"
rules="${SITE_LINK_TEST_RULES:?}"
case "$*" in
	'link show ipsec-home' | 'link show ipsec-site-exit')
		device="${3}"
		grep -Fxq "$device" "$devices" || exit 1
		echo "9: $device: <NOARP,UP,LOWER_UP> mtu 1360 state UNKNOWN"
		;;
	'-d link show ipsec-home') echo '9: ipsec-home: <NOARP,UP> mtu 1360 xfrm if_id 0x2c' ;;
	'-d link show ipsec-site-exit') echo '10: ipsec-site-exit: <NOARP,UP> mtu 1360 xfrm if_id 0x2d' ;;
	'link delete ipsec-home' | 'link delete ipsec-site-exit')
		device="${3}"
		grep -Fxv "$device" "$devices" >"$devices.next" || true
		mv "$devices.next" "$devices"
		printf 'ip delete %s\n' "$device" >>"$events"
		;;
	'-4 route del 10.253.44.2/32 dev ipsec-site-exit')
		printf '%s\n' 'ip route-delete' >>"$events"
		;;
	'-4 addr flush dev ipsec-home scope global')
		printf '%s\n' 'ip address-flush' >>"$events"
		;;
	'-4 rule show') cat "$rules" ;;
	'-4 rule del priority 10444 oif ipsec-home lookup pbr_sitehome')
		: >"$rules"
		printf '%s\n' 'ip probe-rule-delete' >>"$events"
		;;
	*) printf 'unexpected disable ip command: %s\n' "$*" >&2; exit 1 ;;
esac
EOF
cat >"$tmp/bin/swanctl-disable" <<'EOF'
#!/bin/sh
case "$*" in
	'--terminate --ike site-link --timeout 5' | '--terminate --ike site-link-in --timeout 5')
		printf 'swanctl %s\n' "$*" >>"$SITE_LINK_TEST_EVENTS" ;;
	'--load-conns' | '--load-pools' | '--load-creds --noprompt') printf 'swanctl %s\n' "$*" >>"$SITE_LINK_TEST_EVENTS" ;;
	'--list-sas --raw' | '--list-conns --raw') : ;;
	*) printf 'unexpected disable swanctl command: %s\n' "$*" >&2; exit 1 ;;
esac
EOF
cat >"$tmp/bin/service-disable" <<'EOF'
#!/bin/sh
printf 'service %s\n' "$1" >>"$SITE_LINK_TEST_EVENTS"
case "$1" in stop | disable | reload | check | running) exit 0 ;; *) exit 1 ;; esac
EOF
cat >"$tmp/bin/nft-disable" <<'EOF'
#!/bin/sh
[ "$*" = 'list chain inet fw4 pbr_prerouting' ] && exit 0
case "$*" in 'list chain inet fw4 '*) exit 0 ;; *) exit 1 ;; esac
EOF
chmod 755 "$tmp/bin/uci-disable" "$tmp/bin/ip-disable" "$tmp/bin/swanctl-disable" \
	"$tmp/bin/service-disable" "$tmp/bin/nft-disable"
mkdir "$tmp/disable-bin" "$tmp/swanctl-conf"
ln -s "$tmp/bin/uci-disable" "$tmp/disable-bin/uci"
ln -s "$tmp/bin/ip-disable" "$tmp/disable-bin/ip"
ln -s "$tmp/bin/swanctl-disable" "$tmp/disable-bin/swanctl"
printf '%s\n' ipsec-home ipsec-site-exit >"$tmp/devices"
printf '%s\n' '10444: from all oif ipsec-home lookup pbr_sitehome' >"$tmp/rules"
: >"$tmp/events"
mkdir -p "$tmp/persistent"
for snapshot in probe set4 set6; do
	printf '%s\n' stale >"$tmp/$snapshot.dump"
done
printf '%s\n' stale >"$tmp/persistent/set4.dump"
printf '%s\n' stale >"$tmp/persistent/set6.dump"
PATH="$tmp/disable-bin:/usr/bin:/bin" \
SITE_LINK_TEST_UCI_STATE="$tmp/disable.uci" \
SITE_LINK_TEST_DEVICES="$tmp/devices" \
SITE_LINK_TEST_RULES="$tmp/rules" \
SITE_LINK_TEST_EVENTS="$tmp/events" \
SITE_LINK_UCI_DIR="$tmp/config" \
SITE_LINK_STATE="$tmp/disabled.status" \
SITE_LINK_CONN="$tmp/swanctl-conf/source.conf" \
SITE_LINK_CRED="$tmp/swanctl-conf/source-secret.conf" \
SITE_LINK_EXIT_CONN="$tmp/swanctl-conf/exit.conf" \
SITE_LINK_EXIT_CRED="$tmp/swanctl-conf/exit-secret.conf" \
SITE_LINK_PROBE_STATE="$tmp/probe.dump" \
SITE_LINK_SET_DUMP4="$tmp/set4.dump" \
SITE_LINK_SET_DUMP6="$tmp/set6.dump" \
SITE_LINK_PERSISTENT_SET_DUMP4="$tmp/persistent/set4.dump" \
SITE_LINK_PERSISTENT_SET_DUMP6="$tmp/persistent/set6.dump" \
SITE_LINK_PBR_RUNTIME_CONFIG="$tmp/disabled-pbr-runtime.conf" \
SITE_LINK_LOCK="$tmp/disable-site.lock" \
IKEV2_ACTION_LOCK="$tmp/disable-action.lock" \
IKEV2_ACTION_LOCK_STATUS="$tmp/disable-action.status" \
SITE_LINK_INIT="$tmp/bin/service-disable" \
SITE_LINK_NETWORK_INIT="$tmp/bin/service-disable" \
SITE_LINK_FIREWALL_INIT="$tmp/bin/service-disable" \
SITE_LINK_PBR_INIT="$tmp/bin/service-disable" \
SITE_LINK_NFT="$tmp/bin/nft-disable" \
SITE_LINK_FW4="$tmp/bin/service-disable" \
	sh "$root/runtime/ikev2-site-link.sh" disable
[ ! -s "$tmp/devices" ]
[ ! -s "$tmp/rules" ]
[ ! -e "$tmp/probe.dump" ]
[ ! -e "$tmp/set4.dump" ]
[ ! -e "$tmp/set6.dump" ]
[ ! -e "$tmp/persistent/set4.dump" ]
[ ! -e "$tmp/persistent/set6.dump" ]
grep -Fxq 'state=disabled' "$tmp/disabled.status"
grep -Fxq 'ikev2-site-link.main.enabled=0' "$tmp/disable.uci"
grep -Fxq 'uci delete ikev2-site-link.applied' "$tmp/events"
[ "$(sed -n '1p' "$tmp/events")" = 'service stop' ]
stop_line="$(grep -n '^service stop$' "$tmp/events" | cut -d: -f1)"
terminate_line="$(grep -n '^swanctl --terminate --ike site-link --timeout 5$' "$tmp/events" | cut -d: -f1)"
load_line="$(grep -n '^swanctl --load-conns$' "$tmp/events" | cut -d: -f1)"
reload_line="$(grep -n '^service reload$' "$tmp/events" | tail -n1 | cut -d: -f1)"
delete_line="$(grep -n '^ip delete ipsec-home$' "$tmp/events" | cut -d: -f1)"
[ "$stop_line" -lt "$terminate_line" ]
[ "$terminate_line" -lt "$load_line" ]
[ "$load_line" -lt "$reload_line" ]
[ "$reload_line" -lt "$delete_line" ]

# A failed source apply restores the previous strongSwan profile as well as the
# routing files, reconnects the previous profile, and never enables/restarts the
# service with the rejected candidate.
cat >"$tmp/apply.uci" <<'EOF'
ikev2-site-link.main.enabled=1
ikev2-site-link.main.role=source
ikev2-site-link.main.endpoint=new.example.net
ikev2-site-link.main.remote_id=new.example.net
ikev2-site-link.main.peer_user=site-link
ikev2-site-link.main.ike_port=1500
ikev2-site-link.main.source_devices=@br-lan
ikev2-site-link.main.inbound_zone=ikev2in
ikev2-site-link.main.interface=sitehome
ikev2-site-link.main.xfrm_device=ipsec-home
ikev2-site-link.main.if_id=44
ikev2-site-link.main.exit_interface=siteexit
ikev2-site-link.main.exit_device=ipsec-site-exit
ikev2-site-link.main.exit_if_id=45
ikev2-site-link.main.exit_pool=10.253.44.2
ikev2-site-link.main.exit_wan=wan
ikev2-site-link.main.mtu=1360
ikev2-site-link.main.dpd=20
ikev2-site-link.main.monitor_interval=15
ikev2-site-link.main.probe_interval=60
ikev2-site-link.main.failure_threshold=3
ikev2-site-link.main.reconnect_cooldown=30
ikev2-site-link.applied=state
ikev2-site-link.applied.enabled=1
ikev2-site-link.applied.role=source
ikev2-site-link.applied.endpoint=new.example.net
ikev2-site-link.applied.remote_id=new.example.net
ikev2-site-link.applied.peer_user=site-link
ikev2-site-link.applied.ike_port=1500
ikev2-site-link.applied.source_devices=@br-lan
ikev2-site-link.applied.interface=sitehome
ikev2-site-link.applied.xfrm_device=ipsec-home
ikev2-site-link.applied.if_id=44
ikev2-site-link.applied.exit_interface=siteexit
ikev2-site-link.applied.exit_device=ipsec-site-exit
ikev2-site-link.applied.exit_if_id=45
ikev2-site-link.applied.exit_pool=10.253.44.2
ikev2-site-link.applied.exit_wan=wan
ikev2-site-link.applied.exit_wan_zone=wan
ikev2-site-link.applied.mtu=1360
ikev2-site-link.applied.dpd=20
ikev2-site-link.applied.monitor_interval=15
ikev2-site-link.applied.probe_interval=60
ikev2-site-link.applied.failure_threshold=3
ikev2-site-link.applied.reconnect_cooldown=30
ikev2-site-link.applied.force_tcp=1
pbr.config.enabled=1
pbr.config.strict_enforcement=1
pbr.config.resolver_set=dnsmasq.nftset
network.lan.device=br-lan
network.sitehome=interface
network.sitehome.proto=none
network.sitehome.device=ipsec-home
firewall.lan=zone
firewall.lan.name=lan
firewall.lan.network=lan
firewall.ikev2_site_link=zone
firewall.ikev2_site_link.name=sitehome
firewall.ikev2_site_link.network=sitehome
firewall.ikev2_site_link.input=REJECT
firewall.ikev2_site_link.output=ACCEPT
firewall.ikev2_site_link.forward=REJECT
firewall.ikev2_site_link.mtu_fix=1
firewall.ikev2_site_link.masq=1
firewall.ikev2_site_link_src_1=forwarding
firewall.ikev2_site_link_src_1.src=lan
firewall.ikev2_site_link_src_1.dest=sitehome
pbr.ikev2_site_link=policy
pbr.ikev2_site_link.name=IKEv2 Site Link: selected services
pbr.ikev2_site_link.interface=sitehome
pbr.ikev2_site_link.src_addr=@br-lan
pbr.ikev2_site_link.dest_addr=file://POLICY_DOMAINS file://POLICY_ADDRESSES
pbr.ikev2_site_link.proto=all
pbr.ikev2_site_link.enabled=1
pbr.ikev2_site_link_include=include
pbr.ikev2_site_link_include.path=PBR_HELPER
pbr.ikev2_site_link_include.enabled=1
EOF
cat >"$tmp/bin/uci-apply" <<'EOF'
#!/bin/sh
state="${SITE_LINK_TEST_UCI_STATE:?}"
[ "${1:-}" = -c ] && shift 2
[ "${1:-}" = -q ] && shift
case "${1:-}" in
	get)
		awk -F= -v key="${2:-}" '$1 == key { sub(/^[^=]*=/, ""); print; found=1 } END { exit !found }' "$state"
		;;
	show)
		case "${2:-}" in
			firewall)
				echo 'firewall.lan=zone'
				echo 'firewall.ikev2_site_link=zone'
				echo 'firewall.ikev2_site_link_src_1=forwarding'
				;;
			*) exit 1 ;;
		esac
		;;
	set | add_list | reorder | commit | delete | del_list)
		printf 'uci %s %s\n' "$1" "${2:-}" >>"$SITE_LINK_TEST_EVENTS"
		;;
	*) printf 'unexpected apply uci command: %s\n' "$*" >&2; exit 1 ;;
esac
EOF
cat >"$tmp/bin/ip-apply" <<'EOF'
#!/bin/sh
rules="${SITE_LINK_TEST_APPLY_RULES:?}"
case "$*" in
	'-4 route show match 10.253.44.2') echo 'default via 192.0.2.1 dev wan' ;;
	'-d link show ipsec-home') echo '8: ipsec-home: <NOARP,UP> mtu 1360 xfrm if_id 0x2c' ;;
	'link show ipsec-home') echo '8: ipsec-home: <NOARP,UP> mtu 1360 state UNKNOWN' ;;
	'-o link show ipsec-home') echo '8: ipsec-home: <NOARP,UP> mtu 1360 state UNKNOWN' ;;
	'link set ipsec-home mtu 1360 up') printf '%s\n' 'ip link-set' >>"$SITE_LINK_TEST_EVENTS" ;;
	'-4 -o addr show dev ipsec-home scope global') echo '8: ipsec-home inet 10.253.44.2/32 scope global ipsec-home' ;;
	'-4 route show table pbr_sitehome')
		printf '%s\n' 'unreachable default metric 32767' 'default dev ipsec-home metric 10'
		;;
	'-6 route show table pbr_sitehome') echo 'unreachable default dev lo metric 32767 pref medium' ;;
	'-4 rule show') cat "$rules" ;;
	'-4 rule add priority 10444 oif ipsec-home lookup pbr_sitehome')
		printf '%s\n' '10444: from all oif ipsec-home lookup pbr_sitehome' >"$rules"
		printf '%s\n' 'ip probe-rule-add' >>"$SITE_LINK_TEST_EVENTS"
		;;
	*) printf 'unexpected apply ip command: %s\n' "$*" >&2; exit 1 ;;
esac
EOF
cat >"$tmp/bin/swanctl-apply" <<'EOF'
#!/bin/sh
case "$*" in
	'--list-conns --raw') echo 'list-conn event {site-link {children {site-link4 {}}}}' ;;
	'--list-sas --raw')
		echo 'list-sa event {site-link {uniqueid=7 state=ESTABLISHED local-vips=[10.253.44.2] child-sas {site-link4-1 {name=site-link4 state=INSTALLED bytes-in=100 bytes-out=200}}}}'
		;;
	'--load-conns' | '--load-creds' | '--load-creds --noprompt' | '--initiate --child site-link4 --timeout 20' | '--terminate --ike site-link --timeout 5')
		printf 'swanctl %s\n' "$*" >>"$SITE_LINK_TEST_EVENTS"
		;;
	*) printf 'unexpected apply swanctl command: %s\n' "$*" >&2; exit 1 ;;
esac
EOF
cat >"$tmp/bin/nft-apply" <<'EOF'
#!/bin/sh
case "$*" in
	'list chain inet fw4 pbr_prerouting')
		echo 'meta mark set 0x10000 comment "IKEv2 Site Link: selected services"'
		;;
	'list chain inet fw4 pbr_forward')
		[ -s "$SITE_LINK_TEST_AUX_STATE" ] &&
			echo 'reject comment "ikev2-site-link-force-youtube-tcp"'
		;;
	'list chain inet fw4 mangle_forward')
		[ -s "$SITE_LINK_TEST_AUX_STATE" ] &&
			echo 'maxseg comment "ikev2-site-link-mss-clamp"'
		;;
	'list chain inet fw4 forward_lan')
		echo 'jump accept_to_sitehome comment "!fw4: Accept lan to sitehome forwarding"'
		;;
	*) exit 1 ;;
esac
EOF
cat >"$tmp/bin/curl-apply" <<'EOF'
#!/bin/sh
printf '%s\n' 'curl failed as fixture requires' >>"$SITE_LINK_TEST_EVENTS"
exit 1
EOF
cat >"$tmp/bin/modprobe-apply" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"$tmp/bin/pbr-helper-apply" <<'EOF'
#!/bin/sh
case "${1:-}" in
	routes-only) ;;
	'')
		printf '%s\n' ready >"$SITE_LINK_TEST_AUX_STATE"
		printf '%s\n' 'pbr aux-repair' >>"$SITE_LINK_TEST_EVENTS"
		;;
	*) exit 1 ;;
esac
EOF
chmod 755 "$tmp/bin/uci-apply" "$tmp/bin/ip-apply" "$tmp/bin/swanctl-apply" \
	"$tmp/bin/nft-apply" "$tmp/bin/curl-apply" "$tmp/bin/modprobe-apply" \
	"$tmp/bin/pbr-helper-apply"
mkdir "$tmp/apply-bin" "$tmp/apply-config" "$tmp/apply-swanctl"
ln -s "$tmp/bin/uci-apply" "$tmp/apply-bin/uci"
ln -s "$tmp/bin/ip-apply" "$tmp/apply-bin/ip"
ln -s "$tmp/bin/swanctl-apply" "$tmp/apply-bin/swanctl"
ln -s "$tmp/bin/curl-apply" "$tmp/apply-bin/curl"
ln -s "$tmp/bin/modprobe-apply" "$tmp/apply-bin/modprobe"
for config_file in network firewall pbr; do
	printf 'original-%s\n' "$config_file" >"$tmp/apply-config/$config_file"
done
cat >"$tmp/apply-swanctl/source.conf" <<'EOF'
connections { site-link { old-profile = yes } }
EOF
cat >"$tmp/apply-swanctl/source-secret.conf" <<'EOF'
secrets { eap-site-link { id = site-link secret = old-secret } }
EOF
cp "$tmp/apply-swanctl/source.conf" "$tmp/old-source.conf"
cp "$tmp/apply-swanctl/source-secret.conf" "$tmp/old-source-secret.conf"
printf '%s\n' fixture-secret >"$tmp/client.secret"
printf '%s\n' '10444: from all oif ipsec-home lookup pbr_sitehome' >"$tmp/apply.rules"
: >"$tmp/apply.aux"
: >"$tmp/apply.events"
printf '%s\n' youtube.com >"$tmp/policy.domains"
printf '%s\n' 203.0.113.0/24 >"$tmp/policy.addresses"
sed "s|POLICY_DOMAINS|$tmp/policy.domains|; s|POLICY_ADDRESSES|$tmp/policy.addresses|; s|PBR_HELPER|$tmp/bin/pbr-helper-apply|" \
	"$tmp/apply.uci" >"$tmp/apply.uci.next"
mv "$tmp/apply.uci.next" "$tmp/apply.uci"
if PATH="$tmp/apply-bin:/usr/bin:/bin" \
	SITE_LINK_TEST_UCI_STATE="$tmp/apply.uci" \
	SITE_LINK_TEST_EVENTS="$tmp/apply.events" \
	SITE_LINK_TEST_APPLY_RULES="$tmp/apply.rules" \
	SITE_LINK_TEST_AUX_STATE="$tmp/apply.aux" \
	SITE_LINK_UCI_DIR="$tmp/apply-config" \
	SITE_LINK_CONN="$tmp/apply-swanctl/source.conf" \
	SITE_LINK_CRED="$tmp/apply-swanctl/source-secret.conf" \
	SITE_LINK_SECRET="$tmp/client.secret" \
	SITE_LINK_PBR_RUNTIME_CONFIG="$tmp/apply-pbr-runtime.conf" \
	SITE_LINK_DOMAINS="$tmp/policy.domains" \
	SITE_LINK_ADDRESSES="$tmp/policy.addresses" \
	SITE_LINK_PBR_HELPER="$tmp/bin/pbr-helper-apply" \
	SITE_LINK_PBR_INIT="$tmp/bin/service-disable" \
	SITE_LINK_NETWORK_INIT="$tmp/bin/service-disable" \
	SITE_LINK_FIREWALL_INIT="$tmp/bin/service-disable" \
	SITE_LINK_FW4="$tmp/bin/service-disable" \
	SITE_LINK_INIT="$tmp/bin/service-disable" \
	SITE_LINK_NFT="$tmp/bin/nft-apply" \
	SITE_LINK_ROLLBACK_ROOT="$tmp" \
	SITE_LINK_LOCK="$tmp/apply-site.lock" \
	IKEV2_ACTION_LOCK="$tmp/apply-action.lock" \
	IKEV2_ACTION_LOCK_STATUS="$tmp/apply-action.status" \
		sh "$root/runtime/ikev2-site-link.sh" apply >"$tmp/apply.out" 2>&1; then
	echo 'failed candidate apply unexpectedly succeeded' >&2
	exit 1
fi
cmp -s "$tmp/old-source.conf" "$tmp/apply-swanctl/source.conf" || {
	cat "$tmp/apply.out" >&2
	cat "$tmp/apply.events" >&2
	diff -u "$tmp/old-source.conf" "$tmp/apply-swanctl/source.conf" >&2 || true
	exit 1
}
cmp -s "$tmp/old-source-secret.conf" "$tmp/apply-swanctl/source-secret.conf" || {
	diff -u "$tmp/old-source-secret.conf" "$tmp/apply-swanctl/source-secret.conf" >&2 || true
	exit 1
}
[ ! -e "$tmp/apply-pbr-runtime.conf" ] || {
	echo 'failed candidate left its PBR runtime snapshot active' >&2
	exit 1
}
[ "$(grep -c '^swanctl --terminate --ike site-link --timeout 5$' "$tmp/apply.events")" = 2 ]
[ "$(grep -c '^swanctl --initiate --child site-link4 --timeout 20$' "$tmp/apply.events")" = 2 ]
if grep -Eq '^service (enable|restart)$' "$tmp/apply.events"; then
	echo 'rejected candidate restarted the service' >&2
	exit 1
fi
grep -Fq 'uci set firewall.ikev2_site_link_src_1.src=lan' "$tmp/apply.events"
grep -Fq 'uci set firewall.ikev2_site_link_src_1.dest=sitehome' "$tmp/apply.events"

# Repeated end-to-end probe failures on the current SA trigger one bounded SA
# replacement; merely reporting degraded would leave a black-holed tunnel up.
printf '%s\n' 'last=0' 'success=0' 'failures=2' 'sa_id=7' >"$tmp/probe.status"
: >"$tmp/apply.rules"
: >"$tmp/apply.aux"
: >"$tmp/apply.events"
PATH="$tmp/apply-bin:/usr/bin:/bin" \
SITE_LINK_TEST_UCI_STATE="$tmp/apply.uci" \
SITE_LINK_TEST_EVENTS="$tmp/apply.events" \
SITE_LINK_TEST_APPLY_RULES="$tmp/apply.rules" \
SITE_LINK_TEST_AUX_STATE="$tmp/apply.aux" \
SITE_LINK_UCI_DIR="$tmp/apply-config" \
SITE_LINK_CONN="$tmp/apply-swanctl/source.conf" \
SITE_LINK_CRED="$tmp/apply-swanctl/source-secret.conf" \
SITE_LINK_SECRET="$tmp/client.secret" \
SITE_LINK_PBR_RUNTIME_CONFIG="$tmp/apply-pbr-runtime.conf" \
SITE_LINK_DOMAINS="$tmp/policy.domains" \
SITE_LINK_ADDRESSES="$tmp/policy.addresses" \
SITE_LINK_PBR_HELPER="$tmp/bin/pbr-helper-apply" \
SITE_LINK_PBR_INIT="$tmp/bin/service-disable" \
SITE_LINK_NETWORK_INIT="$tmp/bin/service-disable" \
SITE_LINK_FIREWALL_INIT="$tmp/bin/service-disable" \
SITE_LINK_FW4="$tmp/bin/service-disable" \
SITE_LINK_INIT="$tmp/bin/service-disable" \
SITE_LINK_NFT="$tmp/bin/nft-apply" \
SITE_LINK_PROBE_STATE="$tmp/probe.status" \
SITE_LINK_STATE="$tmp/source-monitor.status" \
SITE_LINK_LOCK="$tmp/source-monitor-site.lock" \
SITE_LINK_MONITOR_LOCK="$tmp/source-monitor.lock" \
IKEV2_ACTION_LOCK="$tmp/source-monitor-action.lock" \
IKEV2_ACTION_LOCK_STATUS="$tmp/source-monitor-action.status" \
SITE_LINK_MONITOR_ONCE=1 \
	sh "$root/runtime/ikev2-site-link.sh" monitor
[ "$(grep -c '^swanctl --terminate --ike site-link --timeout 5$' "$tmp/apply.events")" = 1 ]
[ "$(grep -c '^swanctl --initiate --child site-link4 --timeout 20$' "$tmp/apply.events")" = 1 ]
grep -Fxq 'ip probe-rule-add' "$tmp/apply.events"
grep -Fxq 'pbr aux-repair' "$tmp/apply.events"
grep -Fxq '10444: from all oif ipsec-home lookup pbr_sitehome' "$tmp/apply.rules"
grep -Fxq 'failures=4' "$tmp/probe.status"
grep -Fxq 'state=degraded' "$tmp/source-monitor.status"

printf '%s\n' 'recovery tests OK'
