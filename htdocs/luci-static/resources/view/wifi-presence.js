'use strict';
'require view';
'require form';
'require uci';
'require fs';
'require ui';
'require network';

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('wifi-presence'),
			network.getHostHints()
		]);
	},

	pollStatus: function(container) {
		return fs.read('/tmp/wifi-presence/status.json').then(function(data) {
			var status;
			try {
				status = JSON.parse(data);
			} catch(e) {
				container.innerHTML = '<em>' + _('No status data available. The service may not have run yet.') + '</em>';
				return;
			}

			var now = Math.floor(Date.now() / 1000);
			var html = '';

			// Last check info
			var ago = now - status.timestamp;
			var agoText = ago < 60 ? ago + 's ago' : Math.floor(ago / 60) + 'm ago';
			html += '<div style="margin-bottom:1em;padding:0.5em;background:#f0f0f0;border-left:3px solid #0069d9;border-radius:0 4px 4px 0">';
			html += '<strong>' + _('Last check:') + '</strong> ' + agoText;
			html += '</div>';

			// Watched devices table
			html += '<h4>' + _('Watched Devices') + '</h4>';
			html += '<table class="table"><tr class="tr table-titles">';
			html += '<th class="th">' + _('Status') + '</th>';
			html += '<th class="th">' + _('Name') + '</th>';
			html += '<th class="th">' + _('Device') + '</th>';
			html += '<th class="th">' + _('MAC') + '</th>';
			html += '<th class="th">' + _('Since') + '</th>';
			html += '</tr>';

			for (var name in status.devices) {
				var dev = status.devices[name];
				var dot = dev.connected ? '\u{1F7E2}' : (dev.since === 0 ? '\u{1F7E1}' : '\u{1F534}');
				var sinceText = '';
				if (dev.since === 0) {
					sinceText = _('Unknown');
				} else {
					var diff = now - dev.since;
					if (diff < 60) sinceText = diff + 's ago';
					else if (diff < 3600) sinceText = Math.floor(diff / 60) + 'm ago';
					else if (diff < 86400) sinceText = Math.floor(diff / 3600) + 'h ago';
					else sinceText = Math.floor(diff / 86400) + 'd ago';
					sinceText = (dev.connected ? _('Connected ') : _('Disconnected ')) + sinceText;
				}

				html += '<tr class="tr">';
				html += '<td class="td" style="text-align:center">' + dot + '</td>';
				html += '<td class="td"><strong>' + name + '</strong></td>';
				html += '<td class="td">' + (dev.device_desc || '') + '</td>';
				html += '<td class="td"><code>' + dev.mac + '</code></td>';
				html += '<td class="td">' + sinceText + '</td>';
				html += '</tr>';
			}
			html += '</table>';

			// Privacy rules
			html += '<h4>' + _('Privacy Rules') + '</h4>';
			var hasRules = false;
			for (var ruleName in status.privacy_rules) {
				hasRules = true;
				var rule = status.privacy_rules[ruleName];
				var badge = rule.state === 'blocked'
					? '<span style="color:#d32f2f;font-weight:bold">\u{1F512} ' + _('BLOCKED') + '</span>'
					: '<span style="color:#388e3c;font-weight:bold">\u{1F513} ' + _('ACTIVE') + '</span>';

				var ruleSince = '';
				if (rule.since > 0) {
					var rdiff = now - rule.since;
					if (rdiff < 60) ruleSince = rdiff + 's ago';
					else if (rdiff < 3600) ruleSince = Math.floor(rdiff / 60) + 'm ago';
					else if (rdiff < 86400) ruleSince = Math.floor(rdiff / 3600) + 'h ago';
					else ruleSince = Math.floor(rdiff / 86400) + 'd ago';
				}

				html += '<div style="border:1px solid #ddd;border-radius:4px;padding:0.7em;margin-bottom:0.5em">';
				html += '<div style="display:flex;justify-content:space-between;align-items:center">';
				html += '<span><strong>' + (rule.description || ruleName) + '</strong> <code style="font-size:0.85em">' + rule.target_mac + '</code></span>';
				html += badge;
				html += '</div>';
				if (rule.triggered_by && rule.triggered_by.length > 0) {
					html += '<div style="margin-top:0.3em;font-size:0.9em;color:#666">';
					html += _('Triggered by ') + '<strong>' + rule.triggered_by.join(', ') + '</strong>';
					if (ruleSince) html += ' \u00B7 ' + rule.state + ' ' + ruleSince;
					html += '</div>';
				} else if (ruleSince) {
					html += '<div style="margin-top:0.3em;font-size:0.9em;color:#666">' + rule.state + ' ' + ruleSince + '</div>';
				}
				html += '</div>';
			}
			if (!hasRules) {
				html += '<em>' + _('No privacy rules configured') + '</em>';
			}

			// Unknown devices
			html += '<h4>' + _('Recent Unknown Devices') + '</h4>';
			if (status.unknown_recent && status.unknown_recent.length > 0) {
				html += '<table class="table"><tr class="tr table-titles">';
				html += '<th class="th">' + _('Hostname') + '</th>';
				html += '<th class="th">' + _('IP') + '</th>';
				html += '<th class="th">' + _('MAC') + '</th>';
				html += '<th class="th">' + _('First Seen') + '</th>';
				html += '</tr>';
				status.unknown_recent.forEach(function(unk) {
					var unkDiff = now - unk.first_seen;
					var unkTime = unkDiff < 3600 ? Math.floor(unkDiff / 60) + 'm ago' : Math.floor(unkDiff / 3600) + 'h ago';
					html += '<tr class="tr">';
					html += '<td class="td">' + unk.hostname + '</td>';
					html += '<td class="td">' + unk.ip + '</td>';
					html += '<td class="td"><code>' + unk.mac + '</code></td>';
					html += '<td class="td">' + unkTime + '</td>';
					html += '</tr>';
				});
				html += '</table>';
			} else {
				html += '<em>' + _('No unknown devices detected in the last 24 hours') + '</em>';
			}

			container.innerHTML = html;
		}).catch(function() {
			container.innerHTML = '<em>' + _('No status data available. The service may not have run yet.') + '</em>';
		});
	},

	render: function(data) {
		var m, s, o;
		var hosts = data[1];

		m = new form.Map('wifi-presence', _('WiFi Presence'),
			_('Monitor WiFi device presence, manage privacy rules, and detect unknown devices with Telegram notifications.'));

		// ---- General Settings ----
		s = m.section(form.NamedSection, 'global', 'wifi-presence', _('General Settings'));

		o = s.option(form.Flag, 'enabled', _('Enable'),
			_('Enable WiFi presence monitoring service'));
		o.rmempty = false;

		o = s.option(form.ListValue, 'interval', _('Check Interval'),
			_('How often to check for device presence (minutes)'));
		o.value('1', _('1 minute'));
		o.value('2', _('2 minutes'));
		o.value('5', _('5 minutes'));
		o.value('10', _('10 minutes'));
		o.value('15', _('15 minutes'));
		o.value('30', _('30 minutes'));
		o.default = '1';

		o = s.option(form.Value, 'bot_token', _('Telegram Bot Token'),
			_('Bot token from @BotFather'));
		o.password = true;
		o.rmempty = false;

		o = s.option(form.Value, 'chat_id', _('Telegram Chat ID'),
			_('Chat ID for notifications'));
		o.rmempty = false;

		o = s.option(form.Flag, 'unknown_detect', _('Unknown Device Alerts'),
			_('Send Telegram alert when an unrecognized device joins WiFi'));
		o.rmempty = false;

		o = s.option(form.Button, '_test', _('Test Notification'));
		o.inputtitle = _('Send Test Message');
		o.inputstyle = 'apply';
		o.onclick = function() {
			return fs.exec('/usr/libexec/wifi-presence.sh', ['--test']).then(function(res) {
				ui.addNotification(null, E('p', _('Test message sent to Telegram')), 'info');
			}).catch(function(err) {
				ui.addNotification(null, E('p', _('Failed to send test message: ') + err.message), 'danger');
			});
		};

		// ---- Watched Devices ----
		s = m.section(form.GridSection, 'device', _('Watched Devices'),
			_('Devices to monitor for WiFi connect/disconnect events. Telegram alerts are sent on state changes.'));
		s.addremove = true;
		s.anonymous = true;
		s.sortable = true;
		s.nodescriptions = true;

		o = s.option(form.Value, 'name', _('Name'));
		o.rmempty = false;
		o.datatype = 'string';

		o = s.option(form.Value, 'mac', _('MAC Address'));
		o.rmempty = false;
		o.datatype = 'macaddr';
		hosts.getMACHints().forEach(function(hint) {
			o.value(hint[0], hint[0] + ' (' + hint[1] + ')');
		});

		o = s.option(form.Value, 'device_desc', _('Device Description'));
		o.datatype = 'string';

		// ---- Privacy Rules ----
		s = m.section(form.GridSection, 'privacy_rule', _('Privacy Rules'),
			_('Block network traffic for devices when household members are home. Uses nftables firewall rules.'));
		s.addremove = true;
		s.anonymous = false;
		s.nodescriptions = true;

		o = s.option(form.Flag, 'enabled', _('Enabled'));
		o.rmempty = false;
		o.default = '1';

		o = s.option(form.Value, 'description', _('Description'));
		o.rmempty = false;

		o = s.option(form.Value, 'target_mac', _('Target MAC'),
			_('MAC address of the device to block'));
		o.rmempty = false;
		o.datatype = 'macaddr';
		hosts.getMACHints().forEach(function(hint) {
			o.value(hint[0], hint[0] + ' (' + hint[1] + ')');
		});

		o = s.option(form.ListValue, 'action', _('Action'));
		o.value('block_when_home', _('Block when home'));
		o.value('block_when_away', _('Block when away'));
		o.default = 'block_when_home';

		o = s.option(form.DynamicList, 'household', _('Household Members'),
			_('Device names that trigger this rule'));
		// Populate from current device list
		uci.sections('wifi-presence', 'device').forEach(function(dev) {
			if (dev.name)
				o.value(dev.name, dev.name + ' (' + (dev.device_desc || '') + ')');
		});

		// ---- Status ----
		var self = this;
		var statusSection = E('div', { 'class': 'cbi-section' }, [
			E('h3', _('Status')),
			E('div', { 'id': 'wifi-presence-status' },
				E('em', _('Loading status...')))
		]);

		return m.render().then(function(mapNode) {
			mapNode.appendChild(statusSection);

			var statusDiv = mapNode.querySelector('#wifi-presence-status');
			self.pollStatus(statusDiv);

			// Auto-refresh every 30 seconds
			self._statusInterval = window.setInterval(function() {
				self.pollStatus(statusDiv);
			}, 30000);

			return mapNode;
		});
	}
});
