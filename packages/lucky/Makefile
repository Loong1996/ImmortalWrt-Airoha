# SPDX-License-Identifier: MIT
#
# 用官方 release 里的 arm64 静态二进制打包，而不是 golang-package.mk 源码编译：
#   - lucky 是纯 Go 静态链接，产物与目标机 libc 无关，直接装即可
#   - 源码编译要额外拉一整套 Go 工具链（几百 MB，CI 上多十分钟以上），
#     而这条流水线四个机型共用缓存，加 Go 会让工具链缓存键多一个维度
#   - 上游只对 release 里的二进制做验证，自己编反而引入版本漂移
# 升级版本只需改 PKG_VERSION 与 PKG_HASH（sha256sum 官方 tar.gz 即可）。

include $(TOPDIR)/rules.mk

PKG_NAME:=lucky
PKG_VERSION:=3.5.0
PKG_RELEASE:=1

PKG_SOURCE:=lucky_$(PKG_VERSION)_Linux_arm64.tar.gz
PKG_SOURCE_URL:=https://github.com/gdy666/lucky/releases/download/v$(PKG_VERSION)
PKG_HASH:=e79982e1733d51b3237838e251bbc606e65aad1904884fb65a427d57bb6f83e3

PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=chstandard

include $(INCLUDE_DIR)/package.mk

define Package/lucky
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=Web Servers/Proxies
  TITLE:=Lucky - 动态域名 / 内网穿透 / 端口转发 / 反向代理
  URL:=https://github.com/gdy666/lucky
endef

define Package/lucky/description
  Lucky 是 Go 写的网络工具集：动态域名(DDNS)、端口转发、STUN 内网穿透、
  反向代理、Web 服务、WebDAV、网络唤醒等。自带 Web 管理界面，默认 16601 端口。
  注意：本包内置的是官方 arm64 静态二进制，只适用于 aarch64 目标。
endef

# 官方 tar.gz 是平铺结构（根目录直接是 lucky / LICENSE / scripts/），
# 没有 name-version 这层壳。默认解包会 strip 掉第一段路径，
# 结果 $PKG_BUILD_DIR 里只剩 scripts/，二进制丢了。显式解，不做 strip。
define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	tar -xzf $(DL_DIR)/$(PKG_SOURCE) -C $(PKG_BUILD_DIR)
endef

# 预编译二进制，没有源码可编
define Build/Compile
endef

define Package/lucky/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/lucky $(1)/usr/bin/lucky

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/lucky.init $(1)/etc/init.d/lucky

	# lucky 首次启动自己在 /etc/lucky 下生成 lucky.conf（含随机管理密码），
	# 所以不预置配置文件，只保证目录存在、且升级时不被清掉
	$(INSTALL_DIR) $(1)/etc/lucky
	$(INSTALL_DIR) $(1)/lib/upgrade/keep.d
	$(INSTALL_DATA) ./files/lucky.keep $(1)/lib/upgrade/keep.d/lucky

	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./files/luci-menu.json $(1)/usr/share/luci/menu.d/luci-app-lucky.json

	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/lucky
	$(INSTALL_DATA) ./files/luci-overview.js $(1)/www/luci-static/resources/view/lucky/overview.js
endef

define Package/lucky/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	/etc/init.d/lucky enable
	/etc/init.d/lucky restart
}
exit 0
endef

define Package/lucky/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	/etc/init.d/lucky stop
	/etc/init.d/lucky disable
}
exit 0
endef

$(eval $(call BuildPackage,lucky))
