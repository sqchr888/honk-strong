include $(TOPDIR)/rules.mk

PKG_NAME:=honk-strong
PKG_VERSION:=0.1.0_beta6
PKG_RELEASE:=2
PKG_LICENSE:=GPL-3.0-only
PKG_LICENSE_FILE:=LICENSE
PKG_MAINTAINER:=sqchr888

# 自包含增强版 honk（self-contained）：
#   基于官方 honk v0.1.0-beta.6，集成 kenzok8/openwrt-honk 的完整运行底座
#   （init/control/lifecycle、主 rpcd、LuCI 菜单/ACL、Doona 静态界面），
#   再加入 honk-strong 的增强：
#     * geosite overlay（honk-ads.dat）DNS 广告拦截，category=honk-ads
#     * native API readiness 协议（HONK_READY_TOKEN）
#     * 广告订阅引擎 + mosdns 式 DNS 分流面板 + 中文 LuCI 页
#   不再依赖 kenzok8 feed，本包单独即可编译出完整可用的 honk。
# 二进制：预编译 aarch64 musl 产物（含 eBPF BTF），由 CI 注入到
#   $(CURDIR)/target/aarch64-unknown-linux-musl/release/honk-core。

include $(INCLUDE_DIR)/package.mk

define Package/honk-strong
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Enhanced honk (self-contained: adblock + DNS split + Doona + LuCI)
  DEPENDS:=+ca-certificates +kmod-nfnetlink +kmod-nft-queue +kmod-sched-core \
           +kmod-sched-bpf +kmod-veth +ip-full +luci-base +rpcd +cgi-io \
           +jsonfilter +jshn +lua
  PROVIDES:=honk
endef

define Package/honk-strong/description
Self-contained enhanced honk (v0.1.0-beta.6):
  - full honk runtime base (init/control/lifecycle, main rpcd, Doona web UI)
  - geosite overlay adblock via /etc/honk/honk-ads.dat (category: honk-ads)
  - native API readiness protocol (HONK_READY_TOKEN)
  - ad-subscription engine, mosdns-style DNS split panel, Chinese LuCI pages
Requires kernel BTF (/sys/kernel/btf/vmlinux) and kmod-sched-bpf at runtime.
endef

HONK_BIN:=$(CURDIR)/target/aarch64-unknown-linux-musl/release/honk-core
HONK_FILES:=./files

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
endef

define Build/Compile
	@if [ -f "$(HONK_BIN)" ]; then \
		echo "honk-strong: using prebuilt core $(HONK_BIN)"; \
	else \
		echo "honk-strong: prebuilt core missing at $(HONK_BIN)"; \
		exit 1; \
	fi
endef

define Package/honk-strong/install
	# ---- core binary ----
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(HONK_BIN) $(1)/usr/bin/honk-core

	# ---- init / UCI defaults / config ----
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) $(HONK_FILES)/etc/init.d/honk $(1)/etc/init.d/honk
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) $(HONK_FILES)/etc/uci-defaults/90-honk $(1)/etc/uci-defaults/90-honk
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) $(HONK_FILES)/etc/config/honk $(1)/etc/config/honk
	$(INSTALL_DATA) $(HONK_FILES)/etc/config/honk-adblock $(1)/etc/config/honk-adblock
	$(INSTALL_DATA) $(HONK_FILES)/etc/config/honk-dns $(1)/etc/config/honk-dns
	$(INSTALL_DIR) $(1)/etc/honk
	$(INSTALL_DATA) $(HONK_FILES)/etc/honk/system.dae $(1)/etc/honk/system.dae
	chmod 0600 $(1)/etc/honk/system.dae
	$(INSTALL_DIR) $(1)/etc/honk/state
	chmod 0700 $(1)/etc/honk/state

	# ---- honk runtime scripts (base) ----
	$(INSTALL_DIR) $(1)/usr/share/honk
	$(INSTALL_DATA) $(HONK_FILES)/usr/share/honk/default-config.dae $(1)/usr/share/honk/default-config.dae
	$(INSTALL_DATA) $(HONK_FILES)/usr/share/honk/provenance.json $(1)/usr/share/honk/provenance.json
	$(INSTALL_BIN) $(HONK_FILES)/usr/share/honk/control.sh $(1)/usr/share/honk/control.sh
	$(INSTALL_BIN) $(HONK_FILES)/usr/share/honk/lock.sh $(1)/usr/share/honk/lock.sh
	$(INSTALL_BIN) $(HONK_FILES)/usr/share/honk/lifecycle.sh $(1)/usr/share/honk/lifecycle.sh
	$(INSTALL_BIN) $(HONK_FILES)/usr/share/honk/maintenance.sh $(1)/usr/share/honk/maintenance.sh
	$(INSTALL_BIN) $(HONK_FILES)/usr/share/honk/job.sh $(1)/usr/share/honk/job.sh
	$(INSTALL_BIN) $(HONK_FILES)/usr/share/honk/update.sh $(1)/usr/share/honk/update.sh
	$(INSTALL_BIN) $(HONK_FILES)/usr/share/honk/redact-log.sh $(1)/usr/share/honk/redact-log.sh
	$(INSTALL_BIN) $(HONK_FILES)/usr/share/honk/log-level-filter.sh $(1)/usr/share/honk/log-level-filter.sh
	$(INSTALL_DATA) $(HONK_FILES)/usr/share/honk/log-lines.sh $(1)/usr/share/honk/log-lines.sh

	# ---- enhanced engines ----
	$(INSTALL_DIR) $(1)/usr/libexec
	$(INSTALL_BIN) $(HONK_FILES)/usr/libexec/adblock-engine.sh $(1)/usr/libexec/adblock-engine.sh
	$(INSTALL_BIN) $(HONK_FILES)/usr/libexec/dns-engine.sh $(1)/usr/libexec/dns-engine.sh
	$(INSTALL_DATA) $(HONK_FILES)/usr/libexec/geosite_gen.lua $(1)/usr/libexec/geosite_gen.lua

	# ---- rpcd scripts (main + enhanced) ----
	$(INSTALL_DIR) $(1)/usr/libexec/rpcd
	$(INSTALL_BIN) $(HONK_FILES)/usr/libexec/rpcd/honk $(1)/usr/libexec/rpcd/honk
	$(INSTALL_BIN) $(HONK_FILES)/usr/libexec/rpcd/honk-adblock $(1)/usr/libexec/rpcd/honk-adblock
	$(INSTALL_BIN) $(HONK_FILES)/usr/libexec/rpcd/honk-dns $(1)/usr/libexec/rpcd/honk-dns

	# ---- rpcd ACLs (main + enhanced) ----
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) $(HONK_FILES)/usr/share/rpcd/acl.d/luci-app-honk.json $(1)/usr/share/rpcd/acl.d/luci-app-honk.json
	$(INSTALL_DATA) $(HONK_FILES)/usr/share/rpcd/acl.d/honk-adblock.json $(1)/usr/share/rpcd/acl.d/honk-adblock.json
	$(INSTALL_DATA) $(HONK_FILES)/usr/share/rpcd/acl.d/honk-dns.json $(1)/usr/share/rpcd/acl.d/honk-dns.json

	# ---- luci-app-honk helper scripts (ACL exec targets) ----
	$(INSTALL_DIR) $(1)/usr/share/luci-app-honk
	$(CP) $(HONK_FILES)/usr/share/luci-app-honk/*.sh $(1)/usr/share/luci-app-honk/

	# ---- LuCI menu ----
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) $(HONK_FILES)/usr/share/luci/menu.d/luci-app-honk.json $(1)/usr/share/luci/menu.d/luci-app-honk.json

	# ---- Doona static web UI ----
	$(INSTALL_DIR) $(1)/usr/share/doona
	$(CP) $(HONK_FILES)/usr/share/doona/* $(1)/usr/share/doona/

	# ---- LuCI JS views (includes enhanced adblock/dns + js-yaml vendor) ----
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/honk
	$(CP) $(HONK_FILES)/www/luci-static/resources/view/honk/* $(1)/www/luci-static/resources/view/honk/
endef

define Package/honk-strong/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
chmod 0755 /usr/bin/honk-core /etc/init.d/honk /usr/libexec/adblock-engine.sh \
  /usr/libexec/dns-engine.sh /usr/libexec/rpcd/honk /usr/libexec/rpcd/honk-adblock /usr/libexec/rpcd/honk-dns \
  /usr/share/honk/*.sh
rm -f /tmp/luci-indexcache.* 2>/dev/null
rm -rf /tmp/luci-modulecache/ 2>/dev/null
/etc/init.d/rpcd reload 2>/dev/null
/etc/init.d/honk enable 2>/dev/null
logger -t honk-strong "installed (self-contained); overlay=/etc/honk/honk-ads.dat category=honk-ads"
exit 0
endef

$(eval $(call BuildPackage,honk-strong))
