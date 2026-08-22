#!/bin/sh

set -eu

helper="${SITE_LINK_POLICY_HELPER:-/usr/libexec/ikev2-site-link}"

case "${1:-}" in
	--check)
		exec "$helper" policy-check
		;;
	--wait)
		# The runtime owns the common IKEv2/PBR action lock and verifies the
		# resulting route, nftables policy and fail-closed table.
		exec "$helper" policy-reload
		;;
	*)
		echo 'usage: ikev2-site-link-policy-reload {--check|--wait [--lock-held]}' >&2
		exit 2
		;;
esac
