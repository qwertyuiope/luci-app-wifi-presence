#!/bin/sh
# WiFi Presence Monitoring — UCI-aware check script
# Reads config from /etc/config/wifi-presence
# Called by cron every $interval minutes

STATE_DIR="/tmp/wifi-presence"
KNOWN_MACS="/etc/wifi-known-macs"
STATUS_FILE="$STATE_DIR/status.json"

mkdir -p "$STATE_DIR"

# ---- Read global config ----
enabled=$(uci -q get wifi-presence.global.enabled)
[ "$enabled" = "1" ] || exit 0

BOT_TOKEN=$(uci -q get wifi-presence.global.bot_token)
CHAT_ID=$(uci -q get wifi-presence.global.chat_id)

# ---- Test mode: send test message and exit ----
if [ "$1" = "--test" ]; then
	wget -qO- "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
		--post-data="chat_id=${CHAT_ID}&text=✅ WiFi Presence test message — Telegram integration working" > /dev/null 2>&1
	echo "Test message sent"
	exit 0
fi

# ---- Collect WiFi clients from all radios ----
CLIENTS=""
for iface in phy0-ap0 phy1-ap0; do
	CLIENTS="$CLIENTS$(iwinfo "$iface" assoclist 2>/dev/null)"
done

send_telegram() {
	[ -z "$BOT_TOKEN" ] || [ -z "$CHAT_ID" ] && return
	wget -qO- "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
		--post-data="chat_id=${CHAT_ID}&text=$1" > /dev/null 2>&1
}

# ---- JSON helpers ----
# We build JSON manually since the router has no jq.
json_devices=""
json_rules=""
json_unknown="[]"

# ---- Track watched devices ----
device_index=0
while true; do
	name=$(uci -q get wifi-presence.@device[$device_index].name)
	[ -z "$name" ] && break
	mac=$(uci -q get wifi-presence.@device[$device_index].mac)
	device_desc=$(uci -q get wifi-presence.@device[$device_index].device_desc)
	device_index=$((device_index + 1))

	[ -z "$mac" ] && continue

	STATE_FILE="$STATE_DIR/$(echo "$mac" | tr : -)"
	SINCE_FILE="${STATE_FILE}.since"

	if echo "$CLIENTS" | grep -qi "$mac"; then
		CONNECTED=1
	else
		CONNECTED=0
	fi

	PREV_STATE=$(cat "$STATE_FILE" 2>/dev/null || echo "unknown")

	if [ "$CONNECTED" = "1" ] && [ "$PREV_STATE" != "1" ]; then
		send_telegram "📱 ${name} connected to WiFi
Device: ${device_desc}
MAC: ${mac}"
		echo "1" > "$STATE_FILE"
		date +%s > "$SINCE_FILE"
	elif [ "$CONNECTED" = "0" ] && [ "$PREV_STATE" != "0" ]; then
		send_telegram "📱 ${name} disconnected from WiFi
Device: ${device_desc}
MAC: ${mac}"
		echo "0" > "$STATE_FILE"
		date +%s > "$SINCE_FILE"
	fi

	# Add to known MACs
	touch "$KNOWN_MACS"
	grep -qi "$mac" "$KNOWN_MACS" || echo "$mac" >> "$KNOWN_MACS"

	# Build JSON entry for this device
	since=$(cat "$SINCE_FILE" 2>/dev/null || echo "0")
	connected_str="false"
	[ "$CONNECTED" = "1" ] && connected_str="true"
	entry="\"$name\":{\"mac\":\"$mac\",\"device_desc\":\"$device_desc\",\"connected\":$connected_str,\"since\":$since}"
	if [ -z "$json_devices" ]; then
		json_devices="$entry"
	else
		json_devices="$json_devices,$entry"
	fi
done

# ---- Process privacy rules ----
rule_index=0
while true; do
	section=$(uci -q get wifi-presence.@privacy_rule[$rule_index])
	[ -z "$section" ] && break

	# Get the section name (e.g., "indoor_camera")
	rule_name=$(uci -q show wifi-presence.@privacy_rule[$rule_index] | head -1 | sed 's/wifi-presence\.\(.*\)=privacy_rule/\1/')
	rule_enabled=$(uci -q get wifi-presence.@privacy_rule[$rule_index].enabled)
	target_mac=$(uci -q get wifi-presence.@privacy_rule[$rule_index].target_mac)
	description=$(uci -q get wifi-presence.@privacy_rule[$rule_index].description)
	action=$(uci -q get wifi-presence.@privacy_rule[$rule_index].action)
	rule_index=$((rule_index + 1))

	[ "$rule_enabled" = "1" ] || continue
	[ -z "$target_mac" ] && continue

	# Check if any household member is connected
	SOMEONE_HOME=0
	WHO_HOME=""
	# uci get returns all list values space-separated (indexed access not supported in CLI)
	household=$(uci -q get wifi-presence.@privacy_rule[$((rule_index - 1))].household)

	for member in $household; do
		# Look up this member's MAC from the device list
		dev_idx=0
		while true; do
			dev_name=$(uci -q get wifi-presence.@device[$dev_idx].name)
			[ -z "$dev_name" ] && break
			if [ "$dev_name" = "$member" ]; then
				dev_mac=$(uci -q get wifi-presence.@device[$dev_idx].mac)
				if echo "$CLIENTS" | grep -qi "$dev_mac"; then
					SOMEONE_HOME=1
					if [ -z "$WHO_HOME" ]; then
						WHO_HOME="$member"
					else
						WHO_HOME="$WHO_HOME, $member"
					fi
				fi
				break
			fi
			dev_idx=$((dev_idx + 1))
		done
	done

	RULE_STATE_FILE="$STATE_DIR/rule-$(echo "$rule_name" | tr ' ' '-')"
	RULE_SINCE_FILE="${RULE_STATE_FILE}.since"
	PREV_RULE_STATE=$(cat "$RULE_STATE_FILE" 2>/dev/null || echo "unknown")
	NFT_COMMENT="wifi-presence-$rule_name"

	if [ "$action" = "block_when_home" ]; then
		if [ "$SOMEONE_HOME" = "1" ] && [ "$PREV_RULE_STATE" != "blocked" ]; then
			# Block: insert rules at top of forward chain (before flow offloading)
			nft insert rule inet fw4 forward ether saddr "$target_mac" drop comment \"$NFT_COMMENT\"
			nft insert rule inet fw4 forward ether daddr "$target_mac" drop comment \"$NFT_COMMENT\"
			# Kill existing offloaded connections
			TARGET_IP=$(grep -i "$target_mac" /tmp/dhcp.leases 2>/dev/null | awk '{print $3}')
			if [ -n "$TARGET_IP" ]; then
				conntrack -D -s "$TARGET_IP" 2>/dev/null
				conntrack -D -d "$TARGET_IP" 2>/dev/null
			fi
			echo "blocked" > "$RULE_STATE_FILE"
			date +%s > "$RULE_SINCE_FILE"
			send_telegram "🔒 ${description} blocked (${WHO_HOME} is home)
Device: ${description}
MAC: ${target_mac}"

		elif [ "$SOMEONE_HOME" = "0" ] && [ "$PREV_RULE_STATE" != "unblocked" ]; then
			# Unblock: remove rules by comment
			nft -a list chain inet fw4 forward 2>/dev/null | grep "$NFT_COMMENT" | awk '{print $NF}' | while read h; do
				nft delete rule inet fw4 forward handle "$h"
			done
			echo "unblocked" > "$RULE_STATE_FILE"
			date +%s > "$RULE_SINCE_FILE"
			send_telegram "🔓 ${description} unblocked (everyone left)
Device: ${description}
MAC: ${target_mac}"
		fi
	fi

	# Build JSON for this rule
	current_state=$(cat "$RULE_STATE_FILE" 2>/dev/null || echo "unknown")
	since=$(cat "$RULE_SINCE_FILE" 2>/dev/null || echo "0")
	# Build triggered_by as JSON array
	triggered_json="[]"
	if [ "$SOMEONE_HOME" = "1" ]; then
		triggered_json="[$(echo "$WHO_HOME" | sed 's/\([^,]*\)/"\1"/g')]"
	fi
	entry="\"$rule_name\":{\"description\":\"$description\",\"target_mac\":\"$target_mac\",\"state\":\"$current_state\",\"since\":$since,\"triggered_by\":$triggered_json}"
	if [ -z "$json_rules" ]; then
		json_rules="$entry"
	else
		json_rules="$json_rules,$entry"
	fi
done

# ---- Detect unknown devices ----
unknown_detect=$(uci -q get wifi-presence.global.unknown_detect)
json_unknown_entries=""
if [ "$unknown_detect" = "1" ]; then
	echo "$CLIENTS" | grep -oE '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' | while read -r MAC; do
		MAC_UPPER=$(echo "$MAC" | tr 'a-f' 'A-F')
		if ! grep -qi "$MAC" "$KNOWN_MACS"; then
			HOSTNAME=$(grep -i "$MAC" /tmp/dhcp.leases 2>/dev/null | awk '{print $4}')
			[ -z "$HOSTNAME" ] && HOSTNAME="unknown"
			IP=$(grep -i "$MAC" /tmp/dhcp.leases 2>/dev/null | awk '{print $3}')
			[ -z "$IP" ] && IP="unknown"

			send_telegram "⚠️ New device connected to WiFi
Hostname: ${HOSTNAME}
IP: ${IP}
MAC: ${MAC_UPPER}"

			echo "$MAC_UPPER" >> "$KNOWN_MACS"

			# Write unknown entry to temp file for JSON (subshell can't set parent vars)
			echo "{\"mac\":\"$MAC_UPPER\",\"hostname\":\"$HOSTNAME\",\"ip\":\"$IP\",\"first_seen\":$(date +%s)}" >> "$STATE_DIR/unknown-recent.tmp"
		fi
	done
fi

# Build unknown_recent JSON array from temp file + existing recent entries
# Keep entries from the last 24 hours
json_unknown="["
now=$(date +%s)
cutoff=$((now - 86400))
first=1

# Add entries from this run
if [ -f "$STATE_DIR/unknown-recent.tmp" ]; then
	while IFS= read -r line; do
		if [ "$first" = "1" ]; then
			json_unknown="$json_unknown$line"
			first=0
		else
			json_unknown="$json_unknown,$line"
		fi
	done < "$STATE_DIR/unknown-recent.tmp"
	# Append to persistent recent file
	cat "$STATE_DIR/unknown-recent.tmp" >> "$STATE_DIR/unknown-recent.jsonl"
	rm -f "$STATE_DIR/unknown-recent.tmp"
fi

# Add recent entries from previous runs (last 24h)
if [ -f "$STATE_DIR/unknown-recent.jsonl" ]; then
	while IFS= read -r line; do
		ts=$(echo "$line" | sed 's/.*"first_seen":\([0-9]*\).*/\1/')
		if [ -n "$ts" ] && [ "$ts" -ge "$cutoff" ] 2>/dev/null; then
			if [ "$first" = "1" ]; then
				json_unknown="$json_unknown$line"
				first=0
			else
				json_unknown="$json_unknown,$line"
			fi
		fi
	done < "$STATE_DIR/unknown-recent.jsonl"
fi
json_unknown="$json_unknown]"

# ---- Write status JSON ----
cat > "$STATUS_FILE" <<EOF
{"timestamp":$(date +%s),"devices":{$json_devices},"privacy_rules":{$json_rules},"unknown_recent":$json_unknown}
EOF
