# Development

## Checks

```sh
./scripts/check.sh
```

Runs the contract assertions and every test.

## Release

Tagging `v<version>` builds the APK with the pinned OpenWrt SDK, signs it with
the shared publisher key and publishes it as a release asset, with notes made
by `scripts/release-notes.sh` from the commit subjects since the previous tag.
The feed collects the asset and rebuilds the signed index; this repository
never writes to the feed.

Building by hand needs the SDK and the private half of the publisher key:

```sh
OPENWRT_SDK_DIR=/path/to/openwrt-sdk \
OPENWRT_APK_SIGNING_KEY=/path/to/release.pem \
  ./scripts/build-apk.sh
```

Build and feed identity is in [`apk-feed.env`](../apk-feed.env);
`keys/nikitid-openwrt-release.pem` is the publisher public key.
