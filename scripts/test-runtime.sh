#!/bin/sh

set -eu
root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

mkdir -p "$tmp/bin" "$tmp/config" "$tmp/swanctl"
cat >"$tmp/bin/uci" <<'EOF'
#!/bin/sh
state="${SITE_LINK_TEST_UCI_STATE:?}"
[ "${1:-}" = -c ] && shift 2
[ "${1:-}" = -q ] && shift
[ "${1:-}" = get ] || exit 1
awk -F= -v key="${2:-}" '$1 == key { sub(/^[^=]*=/, ""); print; found=1 } END { exit !found }' "$state"
EOF
chmod 755 "$tmp/bin/uci"
cat >"$tmp/uci.state" <<'EOF'
ikev2-site-link.main.role=source
ikev2-site-link.main.endpoint=vpn.example.net
ikev2-site-link.main.remote_id=vpn.example.net
ikev2-site-link.main.peer_user=site-link
ikev2-site-link.main.ike_port=1500
ikev2-site-link.main.if_id=44
ikev2-site-link.main.exit_if_id=45
ikev2-site-link.main.mtu=1360
ikev2-site-link.main.dpd=20
ikev2-site-link.main.monitor_interval=15
ikev2-site-link.main.probe_interval=60
ikev2-site-link.main.failure_threshold=3
ikev2-site-link.main.reconnect_cooldown=30
EOF

PATH="$tmp/bin:$PATH" SITE_LINK_TEST_UCI_STATE="$tmp/uci.state" \
SITE_LINK_UCI_DIR="$tmp/config" \
SITE_LINK_CONN="$tmp/swanctl/site-link.conf" \
SITE_LINK_CRED="$tmp/swanctl/site-link-secret.conf" \
SITE_LINK_SECRET="$tmp/client.secret" \
	sh "$root/runtime/ikev2-site-link.sh" render

grep -Fq 'remote_addrs = vpn.example.net' "$tmp/swanctl/site-link.conf"
grep -Fq 'remote_port = 1500' "$tmp/swanctl/site-link.conf"
grep -Fq 'local_port = 4500' "$tmp/swanctl/site-link.conf"
grep -Fq 'if_id_in = 44' "$tmp/swanctl/site-link.conf"
grep -Fq 'if_id_out = 44' "$tmp/swanctl/site-link.conf"
grep -Fq 'start_action = none' "$tmp/swanctl/site-link.conf"

# Updating a secret while disabled must not reload or recreate a runtime
# connection. It only replaces the protected secret file.
cp "$tmp/swanctl/site-link.conf" "$tmp/swanctl/site-link.before-secret"
token=deadbeef12345678
printf '%s' 'new fixture secret' >"$tmp/ikev2-site-link-secret-$token.in"
PATH="$tmp/bin:$PATH" SITE_LINK_TEST_UCI_STATE="$tmp/uci.state" \
SITE_LINK_UCI_DIR="$tmp/config" \
SITE_LINK_CONN="$tmp/swanctl/site-link.conf" \
SITE_LINK_CRED="$tmp/swanctl/site-link-secret.conf" \
SITE_LINK_SECRET="$tmp/client.secret" \
SITE_LINK_PENDING_SECRET="$tmp/client.secret.pending" \
SITE_LINK_PREVIOUS_SECRET="$tmp/client.secret.previous" \
SITE_LINK_SECRET_INPUT_DIR="$tmp" \
SITE_LINK_LOCK="$tmp/site.lock" \
IKEV2_ACTION_LOCK="$tmp/action.lock" \
IKEV2_ACTION_LOCK_STATUS="$tmp/action.status" \
	sh "$root/runtime/ikev2-site-link.sh" secret-set "$token"
cmp -s "$tmp/swanctl/site-link.before-secret" "$tmp/swanctl/site-link.conf"
[ "$(cat "$tmp/client.secret")" = 'new fixture secret' ]

# A later edit is a staged rotation. It must not replace the credential used by
# the live peer until the explicit role-aware activation step.
token=feedface12345678
printf '%s' 'replacement fixture secret' >"$tmp/ikev2-site-link-secret-$token.in"
PATH="$tmp/bin:$PATH" SITE_LINK_TEST_UCI_STATE="$tmp/uci.state" \
SITE_LINK_UCI_DIR="$tmp/config" \
SITE_LINK_SECRET="$tmp/client.secret" \
SITE_LINK_PENDING_SECRET="$tmp/client.secret.pending" \
SITE_LINK_PREVIOUS_SECRET="$tmp/client.secret.previous" \
SITE_LINK_SECRET_INPUT_DIR="$tmp" \
SITE_LINK_LOCK="$tmp/site.lock" \
IKEV2_ACTION_LOCK="$tmp/action.lock" \
IKEV2_ACTION_LOCK_STATUS="$tmp/action.status" \
	sh "$root/runtime/ikev2-site-link.sh" secret-set "$token"
[ "$(cat "$tmp/client.secret")" = 'new fixture secret' ]
[ "$(cat "$tmp/client.secret.pending")" = 'replacement fixture secret' ]
PATH="$tmp/bin:$PATH" SITE_LINK_TEST_UCI_STATE="$tmp/uci.state" \
SITE_LINK_UCI_DIR="$tmp/config" \
SITE_LINK_SECRET="$tmp/client.secret" \
SITE_LINK_PENDING_SECRET="$tmp/client.secret.pending" \
SITE_LINK_PREVIOUS_SECRET="$tmp/client.secret.previous" \
SITE_LINK_LOCK="$tmp/site.lock" \
IKEV2_ACTION_LOCK="$tmp/action.lock" \
IKEV2_ACTION_LOCK_STATUS="$tmp/action.status" \
	sh "$root/runtime/ikev2-site-link.sh" secret-activate
[ "$(cat "$tmp/client.secret")" = 'replacement fixture secret' ]
[ "$(cat "$tmp/client.secret.previous")" = 'new fixture secret' ]
[ ! -e "$tmp/client.secret.pending" ]

sed 's/\.if_id=44$/.if_id=46/' "$tmp/uci.state" >"$tmp/uci.next"
mv "$tmp/uci.next" "$tmp/uci.state"
PATH="$tmp/bin:$PATH" SITE_LINK_TEST_UCI_STATE="$tmp/uci.state" \
SITE_LINK_UCI_DIR="$tmp/config" \
SITE_LINK_CONN="$tmp/swanctl/site-link.conf" \
SITE_LINK_CRED="$tmp/swanctl/site-link-secret.conf" \
SITE_LINK_SECRET="$tmp/client.secret" \
	sh "$root/runtime/ikev2-site-link.sh" render
grep -Fq 'if_id_in = 46' "$tmp/swanctl/site-link.conf"

sed 's/\.role=source$/.role=exit/' "$tmp/uci.state" >"$tmp/uci.next"
cat >>"$tmp/uci.next" <<'EOF'
ikev2-site-link.main.exit_pool=10.253.44.2
EOF
mv "$tmp/uci.next" "$tmp/uci.state"
PATH="$tmp/bin:$PATH" SITE_LINK_TEST_UCI_STATE="$tmp/uci.state" \
SITE_LINK_UCI_DIR="$tmp/config" \
SITE_LINK_EXIT_CONN="$tmp/swanctl/site-link-exit.conf" \
SITE_LINK_EXIT_CRED="$tmp/swanctl/site-link-exit-secret.conf" \
SITE_LINK_SECRET="$tmp/client.secret" \
	sh "$root/runtime/ikev2-site-link.sh" render
grep -Fq 'site-link-in {' "$tmp/swanctl/site-link-exit.conf"
grep -Fq 'if_id_in = 45' "$tmp/swanctl/site-link-exit.conf"
grep -Fq 'addrs = 10.253.44.2-10.253.44.2' "$tmp/swanctl/site-link-exit.conf"

sed 's/\.role=exit$/.role=source/' "$tmp/uci.state" >"$tmp/uci.next"
mv "$tmp/uci.next" "$tmp/uci.state"

sed 's/\.if_id=46$/.if_id=43/' "$tmp/uci.state" >"$tmp/uci.next"
mv "$tmp/uci.next" "$tmp/uci.state"
if PATH="$tmp/bin:$PATH" SITE_LINK_TEST_UCI_STATE="$tmp/uci.state" \
	SITE_LINK_UCI_DIR="$tmp/config" \
	SITE_LINK_CONN="$tmp/swanctl/site-link.conf" \
	SITE_LINK_CRED="$tmp/swanctl/site-link-secret.conf" \
	SITE_LINK_SECRET="$tmp/client.secret" \
	sh "$root/runtime/ikev2-site-link.sh" render >/dev/null 2>&1; then
	echo 'reserved XFRM if_id was accepted' >&2
	exit 1
fi

sed 's/\.if_id=43$/.if_id=46/;s/\.ike_port=1500$/.ike_port=4500/' \
	"$tmp/uci.state" >"$tmp/uci.next"
mv "$tmp/uci.next" "$tmp/uci.state"
if PATH="$tmp/bin:$PATH" SITE_LINK_TEST_UCI_STATE="$tmp/uci.state" \
	SITE_LINK_UCI_DIR="$tmp/config" \
	SITE_LINK_CONN="$tmp/swanctl/site-link.conf" \
	SITE_LINK_CRED="$tmp/swanctl/site-link-secret.conf" \
	SITE_LINK_SECRET="$tmp/client.secret" \
	sh "$root/runtime/ikev2-site-link.sh" render >/dev/null 2>&1; then
	echo 'conflicting external IKE port was accepted' >&2
	exit 1
fi

printf 'runtime tests OK\n'
