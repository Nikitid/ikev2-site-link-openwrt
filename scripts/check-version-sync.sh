#!/bin/sh
#
# Fail if the package identity drifts between release.env, which the build and
# staging scripts read, and the OpenWrt SDK Makefile literals. Run before the
# package is staged so a divergent Makefile is caught at build time instead of
# shipping mismatched packages.

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
. "$root/release.env"

fail=0
note() {
	printf 'check-version-sync: %s\n' "$*" >&2
	fail=1
}

mk="$root/Makefile"
mk_field() { sed -n "s/^$1:=//p" "$mk" | head -n1; }

mk_name="$(mk_field PKG_NAME)"
mk_ver="$(mk_field PKG_VERSION)"
mk_rel="$(mk_field PKG_RELEASE)"
mk_arch="$(mk_field PKGARCH)"

[ "$mk_name" = "$PKG_NAME" ] ||
	note "Makefile PKG_NAME='$mk_name' != release.env PKG_NAME='$PKG_NAME'"
[ "$mk_ver" = "$PKG_VERSION" ] ||
	note "Makefile PKG_VERSION='$mk_ver' != release.env PKG_VERSION='$PKG_VERSION'"
[ "$mk_rel" = "$PKG_RELEASE" ] ||
	note "Makefile PKG_RELEASE='$mk_rel' != release.env PKG_RELEASE='$PKG_RELEASE'"
[ "$mk_arch" = "$PKG_ARCH" ] ||
	note "Makefile PKGARCH='$mk_arch' != release.env PKG_ARCH='$PKG_ARCH'"

if [ "$fail" -eq 0 ]; then
	printf 'check-version-sync OK: %s %s %s\n' \
		"$PKG_NAME" "$PKG_VERSION" "$PKG_ARCH"
fi
exit "$fail"
