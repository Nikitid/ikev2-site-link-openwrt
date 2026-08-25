#!/bin/sh

set -eu
root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

cat >"$tmp/init" <<'EOF'
#!/bin/sh
case "${1:-}" in
	enabled) [ "${SITE_LINK_TEST_ENABLED:-0}" = 1 ] ;;
	restart) printf '%s\n' restart >>"${SITE_LINK_TEST_LOG:?}" ;;
	*) exit 1 ;;
esac
EOF
chmod 755 "$tmp/init"
: >"$tmp/log"

SITE_LINK_INIT="$tmp/init" SITE_LINK_TEST_ENABLED=1 SITE_LINK_TEST_LOG="$tmp/log" \
	sh "$root/scripts/package-postinst.sh"
[ "$(wc -l <"$tmp/log" | tr -d ' ')" = 1 ]
grep -Fxq restart "$tmp/log"

: >"$tmp/log"
SITE_LINK_INIT="$tmp/init" SITE_LINK_TEST_ENABLED=0 SITE_LINK_TEST_LOG="$tmp/log" \
	sh "$root/scripts/package-postinst.sh"
[ ! -s "$tmp/log" ]

IPKG_INSTROOT="$tmp/root" SITE_LINK_INIT="$tmp/init" SITE_LINK_TEST_ENABLED=1 \
	SITE_LINK_TEST_LOG="$tmp/log" sh "$root/scripts/package-postinst.sh"
[ ! -s "$tmp/log" ]

printf '%s\n' 'package lifecycle tests OK'
