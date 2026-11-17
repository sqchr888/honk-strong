include $(TOPDIR)/rules.mk

PKG_NAME:=honk-strong
PKG_VERSION:=0.1.0-beta.6-strong1
PKG_RELEASE:=1
PKG_LICENSE:=GPL-3.0-only
PKG_LICENSE_FILE:=LICENSE
PKG_MAINTAINER:=sqchr888

# 增强版 honk：在官方 v0.1.0-beta.6 之上加入
#   * geosite overlay（honk-ads.dat）DNS 广告拦截，category=honk-ads
#   * native API readiness 协议（HONK_READY_TOKEN）
#   * 广告订阅引擎 + mosdns 式 DNS 分流面板 + 中文 LuCI
# 源码随本仓库提供；编译时用仓库根目录下的 build 脚本交叉产物，
# 若 target 二进制已随仓库提供则直接安装（见 Build/InstallDev 说明）。

include $(INCLUDE_DIR)/package.mk

define Package/honk-strong
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Enhanced honk with adblock + DNS split (honk-strong)
  DEPENDS:=+ca-certificates +kmod-nfnetlink +kmod-nft-queue +lua +rpcd
  PROVIDES:=honk
  CONFLICTS:=honk
endef

define Package/honk-strong/description
Enhanced honk core (v0.1.0-beta.6) with:
  - geosite overlay adblock via /etc/honk/honk-ads.dat (category: honk-ads)
  - vendor readiness protocol (HONK_READY_TOKEN)
  - ad-subscription engine, mosdns-style DNS split panel, Chinese LuCI pages
The overlay path is whitelisted in the patched core (GEOSITE_OVERLAY_NAME).
endef

# 二进制来源：优先用随仓库提供的预编译 aarch64 musl 产物；
# 若不存在则回退到仓库内 build 脚本现场编译（需要 Rust/zig 工具链）。
HONK_BIN:=$(CURDIR)/target/aarch64-unknown-linux-musl/release/honk-core

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./files/* $(PKG_BUILD_DIR)/ 2>/dev/null || true
endef

define Build/Compile
	@if [ -f "$(HONK_BIN)" ]; then \
		echo "honk-strong: using prebuilt core $(HONK_BIN)"; \
	else \
		echo "honk-strong: prebuilt core missing, run build_aarch64.sh first"; \
		exit 1; \
	fi
endef

define Package/honk-strong/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(HONK_BIN) $(1)/usr/bin/honk-core

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/honk $(1)/etc/init.d/honk

	$(INSTALL_DIR) $(1)/etc/honk
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_DATA) ./files/etc/config/honk-adblock $(1)/etc/config/honk-adblock
	$(INSTALL_DATA) ./files/etc/config/honk-dns $(1)/etc/config/honk-dns

	$(INSTALL_DIR) $(1)/usr/libexec
	$(INSTALL_BIN) ./files/usr/libexec/adblock-engine.sh $(1)/usr/libexec/adblock-engine.sh
	$(INSTALL_BIN) ./files/usr/libexec/dns-engine.sh $(1)/usr/libexec/dns-engine.sh
	$(INSTALL_DATA) ./files/usr/libexec/geosite_gen.lua $(1)/usr/libexec/geosite_gen.lua

	$(INSTALL_DIR) $(1)/usr/libexec/rpcd
	$(INSTALL_BIN) ./files/usr/libexec/rpcd/honk-adblock $(1)/usr/libexec/rpcd/honk-adblock
	$(INSTALL_BIN) ./files/usr/libexec/rpcd/honk-dns $(1)/usr/libexec/rpcd/honk-dns

	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./files/usr/share/rpcd/acl.d/honk-adblock.json $(1)/usr/share/rpcd/acl.d/honk-adblock.json
	$(INSTALL_DATA) ./files/usr/share/rpcd/acl.d/honk-dns.json $(1)/usr/share/rpcd/acl.d/honk-dns.json

	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/honk
	$(CP) ./files/www/luci-static/resources/view/honk/* $(1)/www/luci-static/resources/view/honk/ 2>/dev/null || true
endef

define Package/honk-strong/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
chmod 0755 /usr/bin/honk-core /etc/init.d/honk /usr/libexec/adblock-engine.sh \
  /usr/libexec/dns-engine.sh /usr/libexec/rpcd/honk-adblock /usr/libexec/rpcd/honk-dns
/etc/init.d/honk enable 2>/dev/null
logger -t honk-strong "installed; overlay=/etc/honk/honk-ads.dat category=honk-ads"
exit 0
endef

$(eval $(call BuildPackage,honk-strong))
