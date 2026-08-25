include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-ikev2-site-link
PKG_VERSION:=0.3.7
PKG_RELEASE:=
PKG_LICENSE:=MIT
PKG_MAINTAINER:=nikitid
PKGARCH:=all

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-ikev2-site-link
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=IKEv2 Site Link for OpenWrt
  DEPENDS:=+luci-base +rpcd-mod-file +pbr +ip-full +kmod-xfrm-interface \
	+strongswan +strongswan-charon +strongswan-swanctl \
	+strongswan-mod-aes +strongswan-mod-attr +strongswan-mod-constraints \
	+strongswan-mod-eap-identity +strongswan-mod-eap-mschapv2 \
	+strongswan-mod-gcm +strongswan-mod-gmp +strongswan-mod-hmac \
	+strongswan-mod-kdf +strongswan-mod-kernel-netlink +strongswan-mod-md4 \
	+strongswan-mod-openssl +strongswan-mod-pem +strongswan-mod-pkcs1 \
	+strongswan-mod-pubkey +strongswan-mod-random +strongswan-mod-sha2 \
	+strongswan-mod-socket-default +strongswan-mod-vici +strongswan-mod-x509 \
	+openssl-util +curl
endef

define Package/luci-app-ikev2-site-link/description
 LuCI application for a monitored, fail-closed IKEv2 link between an OpenWrt
 source router and an OpenWrt exit router.
endef

define Package/luci-app-ikev2-site-link/conffiles
/etc/config/ikev2-site-link
/etc/ikev2-site-link/youtube-domains.txt
/etc/ikev2-site-link/domains.txt
/etc/ikev2-site-link/domains.manual.txt
/etc/ikev2-site-link/addresses.txt
/etc/ikev2-site-link/addresses.manual.txt
/etc/ikev2-site-link/services.selected.txt
/etc/ikev2-site-link/client.secret
/etc/ikev2-site-link/client.secret.pending
/etc/ikev2-site-link/client.secret.previous
endef

define Build/Compile
endef

define Package/luci-app-ikev2-site-link/install
	$(INSTALL_DIR) $(1)/etc/config $(1)/etc/ikev2-site-link
	$(INSTALL_CONF) ./openwrt/files/etc/config/ikev2-site-link $(1)/etc/config/ikev2-site-link
	$(INSTALL_CONF) ./openwrt/files/etc/ikev2-site-link/youtube-domains.txt $(1)/etc/ikev2-site-link/youtube-domains.txt
	$(INSTALL_CONF) ./openwrt/files/etc/ikev2-site-link/domains.txt $(1)/etc/ikev2-site-link/domains.txt
	$(INSTALL_CONF) ./openwrt/files/etc/ikev2-site-link/domains.manual.txt $(1)/etc/ikev2-site-link/domains.manual.txt
	$(INSTALL_CONF) ./openwrt/files/etc/ikev2-site-link/addresses.txt $(1)/etc/ikev2-site-link/addresses.txt
	$(INSTALL_CONF) ./openwrt/files/etc/ikev2-site-link/addresses.manual.txt $(1)/etc/ikev2-site-link/addresses.manual.txt
	$(INSTALL_CONF) ./openwrt/files/etc/ikev2-site-link/services.selected.txt $(1)/etc/ikev2-site-link/services.selected.txt
	$(INSTALL_DIR) $(1)/etc/ikev2-site-link/services.d
	$(INSTALL_DIR) $(1)/etc/init.d $(1)/etc/hotplug.d/iface
	$(INSTALL_BIN) ./runtime/ikev2-site-link.init $(1)/etc/init.d/ikev2-site-link
	$(INSTALL_BIN) ./runtime/90-ikev2-site-link $(1)/etc/hotplug.d/iface/90-ikev2-site-link
	$(INSTALL_DIR) $(1)/usr/libexec $(1)/usr/share/pbr
	$(INSTALL_BIN) ./runtime/ikev2-site-link.sh $(1)/usr/libexec/ikev2-site-link
	$(INSTALL_BIN) ./runtime/ikev2-site-link-policy.sh $(1)/usr/libexec/ikev2-site-link-policy
	$(INSTALL_BIN) ./runtime/ikev2-site-link-policy-reload.sh $(1)/usr/libexec/ikev2-site-link-policy-reload
	$(INSTALL_DIR) $(1)/usr/libexec/ikev2-site-link.d
	$(INSTALL_DATA) ./runtime/lib/actions.sh $(1)/usr/libexec/ikev2-site-link.d/actions.sh
	$(INSTALL_BIN) ./runtime/pbr.user.site-link $(1)/usr/share/pbr/pbr.user.site-link
	$(INSTALL_DIR) $(1)/usr/share/ikev2-site-link/services/local
	$(INSTALL_DATA) ./policy/services/community-services $(1)/usr/share/ikev2-site-link/services/community-services
	$(INSTALL_DATA) ./policy/services/*.lst $(1)/usr/share/ikev2-site-link/services/local/
	$(INSTALL_DATA) ./policy/services/*.cidrs $(1)/usr/share/ikev2-site-link/services/local/
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./luci/menu.json $(1)/usr/share/luci/menu.d/luci-app-ikev2-site-link.json
	$(INSTALL_DATA) ./luci/acl.json $(1)/usr/share/rpcd/acl.d/luci-app-ikev2-site-link.json
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/ikev2-site-link $(1)/www/luci-static/resources/ikev2-site-link
	$(INSTALL_DATA) ./luci/overview.js $(1)/www/luci-static/resources/view/ikev2-site-link/overview.js
	$(INSTALL_DATA) ./luci/policy.js $(1)/www/luci-static/resources/view/ikev2-site-link/policy.js
	$(INSTALL_DATA) ./luci/shared.js $(1)/www/luci-static/resources/ikev2-site-link/shared.js
	$(INSTALL_DIR) $(1)/lib/upgrade/keep.d $(1)/usr/share/licenses/luci-app-ikev2-site-link
	$(INSTALL_DATA) ./openwrt/files/lib/upgrade/keep.d/ikev2-site-link $(1)/lib/upgrade/keep.d/ikev2-site-link
	$(INSTALL_DATA) ./LICENSE $(1)/usr/share/licenses/luci-app-ikev2-site-link/LICENSE
endef

define Package/luci-app-ikev2-site-link/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT:-}" ] && exit 0
rm -f /tmp/luci-indexcache
rm -rf /tmp/luci-modulecache
exit 0
endef

define Package/luci-app-ikev2-site-link/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT:-}" ] && exit 0
[ "$${PKG_UPGRADE:-0}" = 1 ] && exit 0
case "$${1:-}" in upgrade) exit 0 ;; esac
/usr/libexec/ikev2-site-link disable >/dev/null 2>&1 || exit 1
exit 0
endef

$(eval $(call BuildPackage,luci-app-ikev2-site-link))
