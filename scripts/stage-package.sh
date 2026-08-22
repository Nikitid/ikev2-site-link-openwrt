#!/bin/sh

set -eu
[ "$#" -eq 1 ] || { echo "usage: $0 STAGE" >&2; exit 1; }
root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
stage="$1"
[ -d "$stage" ] || { echo 'stage directory does not exist' >&2; exit 1; }
[ -z "$(ls -A "$stage")" ] || { echo 'stage directory must be empty' >&2; exit 1; }

put() {
	mode="$1"
	source="$2"
	target="$stage$3"
	mkdir -p "${target%/*}"
	install -m "$mode" "$root/$source" "$target"
}

put 600 openwrt/files/etc/config/ikev2-site-link /etc/config/ikev2-site-link
put 600 openwrt/files/etc/ikev2-site-link/youtube-domains.txt /etc/ikev2-site-link/youtube-domains.txt
put 600 openwrt/files/etc/ikev2-site-link/domains.txt /etc/ikev2-site-link/domains.txt
put 600 openwrt/files/etc/ikev2-site-link/domains.manual.txt /etc/ikev2-site-link/domains.manual.txt
put 600 openwrt/files/etc/ikev2-site-link/addresses.txt /etc/ikev2-site-link/addresses.txt
put 600 openwrt/files/etc/ikev2-site-link/addresses.manual.txt /etc/ikev2-site-link/addresses.manual.txt
put 600 openwrt/files/etc/ikev2-site-link/services.selected.txt /etc/ikev2-site-link/services.selected.txt
put 755 runtime/ikev2-site-link.init /etc/init.d/ikev2-site-link
put 755 runtime/90-ikev2-site-link /etc/hotplug.d/iface/90-ikev2-site-link
put 755 runtime/ikev2-site-link.sh /usr/libexec/ikev2-site-link
put 755 runtime/ikev2-site-link-policy.sh /usr/libexec/ikev2-site-link-policy
put 755 runtime/ikev2-site-link-policy-reload.sh /usr/libexec/ikev2-site-link-policy-reload
put 644 runtime/lib/actions.sh /usr/libexec/ikev2-site-link.d/actions.sh
put 755 runtime/pbr.user.site-link /usr/share/pbr/pbr.user.site-link
put 644 luci/menu.json /usr/share/luci/menu.d/luci-app-ikev2-site-link.json
put 644 luci/acl.json /usr/share/rpcd/acl.d/luci-app-ikev2-site-link.json
put 644 luci/overview.js /www/luci-static/resources/view/ikev2-site-link/overview.js
put 644 luci/policy.js /www/luci-static/resources/view/ikev2-site-link/policy.js
put 644 luci/shared.js /www/luci-static/resources/ikev2-site-link/shared.js
put 644 openwrt/files/lib/upgrade/keep.d/ikev2-site-link /lib/upgrade/keep.d/ikev2-site-link
put 644 LICENSE /usr/share/licenses/luci-app-ikev2-site-link/LICENSE

for source in "$root"/policy/services/*; do
	put 644 "${source#$root/}" "/usr/share/ikev2-site-link/services/local/${source##*/}"
done
# The catalog is metadata, not a service definition.
mkdir -p "$stage/usr/share/ikev2-site-link/services"
mv "$stage/usr/share/ikev2-site-link/services/local/community-services" \
	"$stage/usr/share/ikev2-site-link/services/community-services"
mkdir -p "$stage/etc/ikev2-site-link/services.d"

mkdir -p "$stage/lib/apk/packages"
package='luci-app-ikev2-site-link'
find "$stage" -type f ! -path "$stage/lib/apk/packages/*" |
	sed "s#^$stage##" | sort >"$stage/lib/apk/packages/$package.list"
cat >"$stage/lib/apk/packages/$package.conffiles" <<'EOF'
/etc/config/ikev2-site-link
/etc/ikev2-site-link/youtube-domains.txt
/etc/ikev2-site-link/domains.txt
/etc/ikev2-site-link/domains.manual.txt
/etc/ikev2-site-link/addresses.txt
/etc/ikev2-site-link/addresses.manual.txt
/etc/ikev2-site-link/services.selected.txt
EOF
: >"$stage/lib/apk/packages/$package.conffiles_static"
while IFS= read -r file; do
	printf '%s %s\n' "$file" "$(sha256sum "$stage$file" | awk '{ print $1 }')" \
		>>"$stage/lib/apk/packages/$package.conffiles_static"
done <"$stage/lib/apk/packages/$package.conffiles"
