#!/bin/sh

set -eu

fail() {
	printf 'build-apk: %s\n' "$*" >&2
	exit 1
}

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
. "$root/release.env"
. "$root/apk-feed.env"

sdk="${OPENWRT_SDK_DIR:-}"
signing_key="${OPENWRT_APK_SIGNING_KEY:-}"
public_key="$root/$OPENWRT_APK_KEY_FILE"

[ -n "$sdk" ] || fail 'OPENWRT_SDK_DIR is required'
[ -d "$sdk" ] || fail "SDK directory not found: $sdk"
[ -n "$signing_key" ] || fail 'OPENWRT_APK_SIGNING_KEY is required'
[ -r "$signing_key" ] || fail "signing key not readable: $signing_key"
[ -r "$public_key" ] || fail "public key not found: $OPENWRT_APK_KEY_FILE"

case "$(basename "$sdk")" in
	"${OPENWRT_APK_SDK_ARCHIVE%.tar.zst}") ;;
	*) fail "unexpected SDK directory: $(basename "$sdk")" ;;
esac

apk_tool="$sdk/staging_dir/host/bin/apk"
[ -x "$apk_tool" ] || fail "SDK apk tool not found: $apk_tool"
fakeroot_bin="$sdk/staging_dir/host/bin/fakeroot"
[ -x "$fakeroot_bin" ] || fail "SDK fakeroot not found: $fakeroot_bin"

for command in openssl python3 sha256sum; do
	command -v "$command" >/dev/null 2>&1 || fail "required command is missing: $command"
done

actual_key_hash="$(sha256sum "$public_key" | awk '{ print $1 }')"
[ "$actual_key_hash" = "$OPENWRT_APK_TRUST_SHA256" ] ||
	fail "public key checksum mismatch: $actual_key_hash"

tmp="$(mktemp -d)"
cleanup() {
	rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

openssl ec -in "$signing_key" -pubout -out "$tmp/derived-public.pem" >/dev/null 2>&1 ||
	fail 'invalid EC signing key'
cmp -s "$tmp/derived-public.pem" "$public_key" ||
	fail 'signing key does not match the tracked public release key'

"$root/scripts/check-version-sync.sh"

stage="$tmp/root"
mkdir "$stage"
"$root/scripts/stage-package.sh" "$stage"

output="$root/dist/apk"
mkdir -p "$output"
rm -f "$output"/*.apk
artifact="$output/$PKG_NAME-$PKG_VERSION.apk"

# Package metadata must never depend on the uid that happens to run CI. The
# SDK's fakeroot records every directory and file as root:root without needing
# privileged filesystem writes in the workspace.
STAGING_DIR_HOST="$sdk/staging_dir/host" "$fakeroot_bin" "$apk_tool" mkpkg \
	--info "name:$PKG_NAME" \
	--info "version:$PKG_VERSION" \
	--info 'description:Monitored fail-closed IKEv2 site link for OpenWrt' \
	--info "arch:$OPENWRT_APK_ARCH" \
	--info 'license:MIT' \
	--info "origin:$PKG_NAME" \
	--info 'maintainer:nikitid' \
	--info 'depends:libc luci-base rpcd-mod-file pbr strongswan-swanctl kmod-xfrm-interface openssl-util curl' \
	--script "post-install:$root/scripts/package-postinst.sh" \
	--script "post-upgrade:$root/scripts/package-postinst.sh" \
	--script "pre-deinstall:$root/scripts/package-prerm.sh" \
	--files "$stage" \
	--output "$artifact"

"$apk_tool" --allow-untrusted adbsign --sign-key "$signing_key" "$artifact"
"$apk_tool" --keys-dir "$root/keys" verify "$artifact"
"$apk_tool" --keys-dir "$root/keys" adbdump --format json \
	"$artifact" >"$tmp/package.json"

python3 - "$tmp/package.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as package_file:
    package = json.load(package_file)

for path in package.get("paths", []):
    nodes = [(path.get("name", "/"), path.get("acl", {}))]
    nodes.extend((entry.get("name", "?"), entry.get("acl", {}))
                 for entry in path.get("files", []))
    for name, acl in nodes:
        if acl.get("user") != "root" or acl.get("group") != "root":
            raise SystemExit(f"non-root package ownership: {name}: {acl}")
PY

# apk-tools 3 runs pre-deinstall on upgrade too, with "upgrade" as the first
# argument; without that guard an upgrade tears down the live site link. A
# catch-all case is equally wrong: real removal passes the old version string.
python3 - "$tmp/package.json" >"$tmp/pre-deinstall" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as package_file:
    package = json.load(package_file)
print(package.get("scripts", {}).get("pre-deinstall", ""), end="")
PY
grep -Fq 'PKG_UPGRADE:-0' "$tmp/pre-deinstall" ||
	fail 'built APK pre-deinstall lacks the opkg upgrade guard'
grep -Fq 'upgrade) exit 0' "$tmp/pre-deinstall" ||
	fail 'built APK pre-deinstall lacks the apk upgrade guard'
if grep -Fq '*) exit 0' "$tmp/pre-deinstall"; then
	fail 'built APK pre-deinstall rejects the apk old-version argument'
fi

(
	cd "$output"
	sha256sum "$(basename "$artifact")" >SHA256SUMS
)

printf 'signed APK built in %s\n' "$output"
