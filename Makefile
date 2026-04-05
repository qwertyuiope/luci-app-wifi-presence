include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-wifi-presence
PKG_VERSION:=1.0.0
PKG_RELEASE:=1
PKG_LICENSE:=MIT

LUCI_TITLE:=LuCI WiFi Presence Monitoring
LUCI_DESCRIPTION:=WiFi presence alerts, privacy rules (firewall device blocking), and unknown device detection with Telegram notifications
LUCI_DEPENDS:=+luci-base +iwinfo

include $(TOPDIR)/feeds/luci/luci.mk

define Package/$(PKG_NAME)/conffiles
/etc/config/wifi-presence
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
