# luci-app-wifi-presence

OpenWrt LuCI app for WiFi presence monitoring with Telegram notifications.

Track when devices connect and disconnect from your WiFi, automatically block network traffic for specific devices based on who's home, and get alerts when unknown devices join your network.

## Features

- **Presence Alerts** — Telegram notifications when watched devices connect or disconnect from WiFi
- **Privacy Rules** — Block any device's network traffic via nftables when household members are home (e.g., disable an indoor camera when you're home, re-enable when you leave)
- **Unknown Device Detection** — One-time Telegram alert when a never-seen-before device joins WiFi
- **LuCI Web Interface** — Configure everything from the browser: devices, rules, Telegram credentials, check interval
- **Status Dashboard** — Live view of device presence, privacy rule states, and recent unknown devices with auto-refresh

## Screenshots

*Services > WiFi Presence*

The interface has four sections:
- **General Settings** — Enable/disable, check interval, Telegram bot token and chat ID, test notification button
- **Watched Devices** — Add devices by name, MAC address, and description. MAC dropdown shows known hosts from DHCP/ARP
- **Privacy Rules** — Define rules to block devices when household members are home. Each rule has its own target device and trigger list
- **Status** — Live presence data with colored indicators, privacy rule states, and recent unknown devices

## Requirements

- OpenWrt 22.03+ (tested on 24.10)
- `luci-base` (LuCI JS framework)
- `iwinfo` (WiFi client enumeration — installed by default)
- `nftables` (for privacy rules — installed by default with fw4)
- A Telegram bot token and chat ID for notifications ([how to create a bot](https://core.telegram.org/bots#how-do-i-create-a-bot))

## Installation

### From GitHub Release (recommended)

1. Download the latest `.ipk` from [Releases](https://github.com/qwertyuiope/luci-app-wifi-presence/releases)
2. In LuCI, go to **System > Software > Upload Package**
3. Select the `.ipk` file and click **Install**
4. Navigate to **Services > WiFi Presence** to configure

### Manual install via scp

```bash
scp -O -r root/* root@<router-ip>:/
scp -O -r htdocs/* root@<router-ip>:/www/
ssh root@<router-ip> "chmod +x /etc/init.d/wifi-presence /usr/libexec/wifi-presence.sh && \
  service rpcd restart && \
  /etc/init.d/wifi-presence enable && \
  /etc/init.d/wifi-presence start"
```

## Configuration

All configuration is done through LuCI at **Services > WiFi Presence**, or via UCI on the command line:

```bash
# Enable the service
uci set wifi-presence.global.enabled='1'

# Set Telegram credentials
uci set wifi-presence.global.bot_token='YOUR_BOT_TOKEN'
uci set wifi-presence.global.chat_id='YOUR_CHAT_ID'

# Add a watched device
uci add wifi-presence device
uci set wifi-presence.@device[-1].name='Phone'
uci set wifi-presence.@device[-1].mac='AA:BB:CC:DD:EE:FF'
uci set wifi-presence.@device[-1].device_desc='My Phone'

# Add a privacy rule (block camera when home)
uci set wifi-presence.indoor_cam=privacy_rule
uci set wifi-presence.indoor_cam.enabled='1'
uci set wifi-presence.indoor_cam.target_mac='11:22:33:44:55:66'
uci set wifi-presence.indoor_cam.description='Indoor Camera'
uci set wifi-presence.indoor_cam.action='block_when_home'
uci add_list wifi-presence.indoor_cam.household='Phone'

# Apply changes
uci commit wifi-presence
/etc/init.d/wifi-presence restart
```

## How It Works

A shell script (`/usr/libexec/wifi-presence.sh`) runs every N minutes via cron:

1. Queries `iwinfo` for connected WiFi clients on all radios
2. Compares against the watched device list from UCI config
3. Sends Telegram notifications on connect/disconnect state changes
4. For each privacy rule, checks if household members are connected and manages nftables firewall rules to block/unblock target devices
5. Scans for unknown MACs not in `/etc/wifi-known-macs` and alerts once
6. Writes `/tmp/wifi-presence/status.json` for the LuCI status dashboard

Privacy rules use nftables (`inet fw4 forward`) to drop traffic by MAC address. Rules are inserted at the top of the chain to run before flow offloading. Existing conntrack entries are killed to prevent offloaded flows from bypassing the block.

## File Locations

| File | Purpose |
|------|---------|
| `/etc/config/wifi-presence` | UCI configuration (persists across reboots) |
| `/usr/libexec/wifi-presence.sh` | Check script (runs via cron) |
| `/etc/init.d/wifi-presence` | Service init script (manages cron entry) |
| `/www/luci-static/resources/view/wifi-presence.js` | LuCI web interface |
| `/tmp/wifi-presence/` | Runtime state (tmpfs, resets on reboot) |
| `/etc/wifi-known-macs` | Known MAC addresses (persists across reboots) |

## Releases

To create a new release, tag and push:

```bash
git tag v1.1.0
git push origin v1.1.0
```

GitHub Actions builds the `.ipk` and publishes it as a release automatically.

## License

MIT
