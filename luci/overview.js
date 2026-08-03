'use strict';
'require view';
'require form';
'require fs';
'require ui';
'require uci';
'require ikev2-site-link.shared as common';

var helper = '/usr/libexec/ikev2-site-link';

// "device=hint" lines from the runtime helper, matching the shape the other
// Nikitid LuCI applications use for their selector sources.
function parseNamedValues(output) {
	return String(output || '').replace(/\r/g, '').split('\n').map(function(line) {
		var at = line.indexOf('=');
		return at > 0 ? { name: line.slice(0, at), value: line.slice(at + 1).trim() } : null;
	}).filter(Boolean);
}

// Mirrors the runtime's own checks, so the page refuses what apply would.
function validIfId(value, otherOption) {
	if (!/^\d+$/.test(String(value || '')))
		return _('Enter a number.');
	var number = Number(value);
	if (number < 1 || number > 4294967295)
		return _('Must be between 1 and 4294967295.');
	if (number === 42 || number === 43)
		return _('42 and 43 are reserved by IKEv2 Manager.');
	var other = uci.get('ikev2-site-link', 'main', otherOption);
	if (other && Number(other) === number)
		return _('The source and exit identifiers must differ.');
	return true;
}

function parse(output) {
	var result = {};
	String(output || '').split(/\n/).forEach(function(line) {
		var at = line.indexOf('=');
		if (at > 0)
			result[line.slice(0, at)] = line.slice(at + 1);
	});
	return result;
}

function bytes(value) {
	var number = Number(value || 0);
	var units = [ 'B', 'KiB', 'MiB', 'GiB', 'TiB' ];
	var unit = 0;
	while (number >= 1024 && unit < units.length - 1) {
		number /= 1024;
		unit++;
	}
	return (unit ? number.toFixed(number >= 10 ? 1 : 2) : number.toFixed(0)) + ' ' + units[unit];
}

function statusPanel(status) {
	var connected = status.sa === 'connected';
	var healthy = status.state === 'ok';
	var role = status.role === 'exit' ? _('Exit router') : _('Source router');
	var health = healthy ? _('Healthy') : (status.state === 'idle' ? _('Waiting') : _('Needs attention'));
	var detail = status.detail || _('Live state has not been reported yet.');
	return E('div', {}, [
		E('div', { 'class': 'ikev2-hero' }, [
			E('div', {}, [
				E('h3', {}, [ connected ? _('Site link is connected') : _('Site link is not connected') ]),
				E('p', {}, [ detail ])
			]),
			E('div', { 'class': 'ikev2-hero-side' }, [
				common.pill(connected ? _('Tunnel online') : _('Tunnel offline'), connected ? 'good' : 'bad'),
				common.pill(health, healthy ? 'good' : (status.state === 'idle' ? 'info' : 'warn'))
			])
		]),
		E('div', { 'class': 'ikev2-grid' }, [
			common.card(_('Role'), role, status.interface || '—'),
			common.card(_('Traffic'), '↓ ' + bytes(status.rx_bytes), _('Sent: ') + bytes(status.tx_bytes)),
			common.card(_('Tunnel address'), status.vip || '—', _('Dedicated XFRM address')),
			common.card(_('Protection'), status.fail_closed === 'active' ? _('Fail-closed') :
				(status.role === 'exit' ? _('WAN only') : _('Unavailable')),
				_('External IKE port: ') + (status.ike_port || '1500'))
		])
	]);
}

return view.extend({
	load: function() {
		return Promise.all([
			L.resolveDefault(fs.exec(helper, [ 'status' ]), { code: 1, stdout: '' }),
			uci.load('ikev2-site-link'),
			L.resolveDefault(fs.exec(helper, [ 'sources' ]), { code: 1, stdout: '' }),
			L.resolveDefault(fs.exec(helper, [ 'zones' ]), { code: 1, stdout: '' })
		]);
	},

	render: function(data) {
		var self = this;
		var status = parse(data[0] && data[0].stdout);
		var sources = parseNamedValues(data[2] && data[2].stdout);
		var zones = parseNamedValues(data[3] && data[3].stdout);
		common.styles();
		var map = new form.Map('ikev2-site-link', null, null);
		var option;

		var link = map.section(form.NamedSection, 'main', 'main', _('Link'));
		link.addremove = false;

		option = link.option(form.Flag, 'enabled', _('Enabled'));
		option.rmempty = false;

		option = link.option(form.ListValue, 'role', _('Role'));
		option.value('source', _('Source router') + ' — ' + _('sends selected traffic out'));
		option.value('exit', _('Exit router') + ' — ' + _('receives it and reaches the Internet'));
		option.rmempty = false;

		option = link.option(form.Value, 'endpoint', _('Exit endpoint'));
		option.depends('role', 'source');
		option.placeholder = 'vpn.example.net';
		option.datatype = 'host';
		option.description = _('Address of the exit router, as published by IKEv2 Manager.');

		option = link.option(form.Value, 'remote_id', _('Server identity'));
		option.placeholder = 'vpn.example.net';
		option.description = _('Certificate identity of the exit router. It must be identical on both routers.');

		option = link.option(form.Value, 'peer_user', _('Peer identity'));
		option.rmempty = false;
		// Not a UCI name: the runtime accepts letters, digits and _ . @ -,
		// which is what an EAP identity like site-link-office needs.
		option.validate = function(section_id, value) {
			if (!value)
				return _('A peer identity is required.');
			return /^[A-Za-z0-9_.@-]+$/.test(value) ? true :
				_('Use letters, digits and _ . @ - only.');
		};
		option.description = _('EAP identity this link authenticates with. It must exist on the exit router and be used by nothing else.');

		option = link.option(form.Value, 'ike_port', _('Dedicated external IKE port'));
		option.value('1500', '1500 — ' + _('recommended'));
		option.datatype = 'range(1024,65535)';
		option.rmempty = false;
		option.description = _('UDP port the exit router publishes for this link, kept apart from ordinary IKEv2 clients. Both routers must use the same value. Do not use 4500.');

		// One section for both roles: CBI has no section-level dependency, so
		// separate per-role sections would leave an empty box on the router
		// that does not use them. The options below hide themselves instead.
		var sourceRole = map.section(form.NamedSection, 'main', 'main', _('Role settings'));
		sourceRole.addremove = false;

		// PBR takes "@device" selectors; offer the router's own devices and
		// still accept anything typed in, the way the sibling applications do.
		option = sourceRole.option(form.DynamicList, 'source_devices', _('Protected sources'));
		option.depends('role', 'source');
		option.rmempty = false;
		option.placeholder = '@br-lan';
		option.description = _('Networks whose traffic may enter the link. Anything not listed here keeps using this router\'s own connection.');
		sources.forEach(function(entry) {
			option.value('@' + entry.name, '@' + entry.name + (entry.value ? ' — ' + entry.value : ''));
		});
		option.cfgvalue = function(section_id) {
			var raw = uci.get('ikev2-site-link', section_id, 'source_devices');
			if (Array.isArray(raw))
				return raw;
			return String(raw || '').split(/\s+/).filter(Boolean);
		};
		option.write = function(section_id, value) {
			var list = Array.isArray(value) ? value : [ value ];
			return uci.set('ikev2-site-link', section_id, 'source_devices',
				list.filter(Boolean).join(' '));
		};

		option = sourceRole.option(form.Value, 'mtu', _('Tunnel MTU'));
		option.depends('role', 'source');
		option.value('1360', '1360 — ' + _('recommended'));
		option.value('1400', '1400');
		option.value('1280', '1280 — ' + _('minimum'));
		option.datatype = 'range(1200,1500)';
		option.rmempty = false;
		option.description = _('Lower values cost throughput; higher ones risk fragmentation inside the tunnel.');

		option = sourceRole.option(form.Value, 'exit_pool', _('Dedicated tunnel address'));
		option.depends('role', 'exit');
		option.datatype = 'ip4addr';
		option.rmempty = false;
		option.placeholder = '10.253.44.2';
		option.description = _('One private IPv4 address for this link alone. It must not overlap either router\'s LAN or any VPN pool.');

		var health = map.section(form.NamedSection, 'main', 'main', _('Monitoring'));
		health.addremove = false;

		option = health.option(form.Value, 'monitor_interval', _('Monitor interval'));
		option.value('15', '15 ' + _('seconds') + ' — ' + _('recommended'));
		option.value('30', '30 ' + _('seconds'));
		option.value('60', '60 ' + _('seconds'));
		option.datatype = 'range(5,300)';
		option.rmempty = false;

		option = health.option(form.Value, 'failure_threshold', _('Reconnect threshold'));
		option.value('3', '3 ' + _('checks') + ' — ' + _('recommended'));
		option.value('5', '5 ' + _('checks'));
		option.datatype = 'range(1,20)';
		option.rmempty = false;
		option.description = _('Consecutive failed checks before the link is reconnected.');

		option = health.option(form.Value, 'reconnect_cooldown', _('Reconnect cooldown'));
		option.value('30', '30 ' + _('seconds') + ' — ' + _('recommended'));
		option.value('60', '60 ' + _('seconds'));
		option.value('300', '5 ' + _('minutes'));
		option.datatype = 'range(15,3600)';
		option.rmempty = false;
		option.description = _('Minimum time between connection attempts. This prevents restart storms while the peer is unavailable.');

		// Everything the runtime reads but the page never showed. These have
		// working defaults and are rarely touched, so they live apart from the
		// settings above rather than being hidden from the admin entirely.
		var advanced = map.section(form.NamedSection, 'main', 'main', _('Interfaces and identifiers'));
		advanced.addremove = false;

		function zoneOption(name, title, fallback, description) {
			var opt = advanced.option(form.Value, name, title);
			opt.placeholder = fallback;
			opt.description = description;
			zones.forEach(function(zone) {
				opt.value(zone.name, zone.name + (zone.value ? ' — ' + zone.value : ''));
			});
			return opt;
		}

		option = advanced.option(form.Value, 'interface', _('Link network'));
		option.depends('role', 'source');
		option.value('sitehome', 'sitehome — ' + _('default'));
		option.description = _('UCI network and firewall zone this link creates on the source router.');

		option = advanced.option(form.Value, 'xfrm_device', _('Link device'));
		option.depends('role', 'source');
		option.value('ipsec-home', 'ipsec-home — ' + _('default'));

		option = advanced.option(form.Value, 'if_id', _('XFRM identifier'));
		option.depends('role', 'source');
		option.value('44', '44 — ' + _('default'));
		option.description = _('42 and 43 are reserved by IKEv2 Manager. It must differ from the exit identifier.');
		option.validate = function(section_id, value) { return validIfId(value, 'exit_if_id'); };

		option = advanced.option(form.Value, 'exit_interface', _('Exit network'));
		option.depends('role', 'exit');
		option.value('siteexit', 'siteexit — ' + _('default'));
		option.description = _('UCI network and firewall zone this link creates on the exit router.');

		option = advanced.option(form.Value, 'exit_device', _('Exit device'));
		option.depends('role', 'exit');
		option.value('ipsec-site-exit', 'ipsec-site-exit — ' + _('default'));

		option = advanced.option(form.Value, 'exit_if_id', _('Exit XFRM identifier'));
		option.depends('role', 'exit');
		option.value('45', '45 — ' + _('default'));
		option.description = _('42 and 43 are reserved by IKEv2 Manager. It must differ from the source identifier.');
		option.validate = function(section_id, value) { return validIfId(value, 'if_id'); };

		zoneOption('inbound_zone', _('Inbound VPN zone'), 'ikev2in',
			_('Zone whose clients may also use the link. Skipped when the zone does not exist.'))
			.depends('role', 'source');

		zoneOption('exit_wan', _('Exit uplink zone'), 'wan',
			_('The only zone the link may forward to on the exit router.'))
			.depends('role', 'exit');

		option = advanced.option(form.Value, 'dpd', _('Dead peer detection'));
		option.value('20', '20 ' + _('seconds') + ' — ' + _('default'));
		option.value('30', '30 ' + _('seconds'));
		option.value('60', '60 ' + _('seconds'));
		option.datatype = 'range(5,300)';

		option = advanced.option(form.Flag, 'force_tcp', _('Force TCP for selected traffic'));
		option.depends('role', 'source');
		option.default = '1';
		option.description = _('Rejects UDP/443 to the selected destinations so clients fall back to TCP immediately instead of waiting out a QUIC timeout.');

		// The secret and the two operations that use it are an action bar, not
		// three labelled settings rows: the secret is write-only and is never
		// read back from UCI, and both buttons act on the whole page.
		function updateSecret(input) {
			var value = input.value;
			if (!value)
				return Promise.reject(new Error(_('Enter a peer secret first.')));
			var bytes = new TextEncoder().encode(value);
			var token = Array.prototype.map.call(crypto.getRandomValues(new Uint8Array(12)), function(v) {
				return v.toString(16).padStart(2, '0');
			}).join('');
			var path = '/var/run/ikev2-site-link-secret-' + token + '.in';
			return fs.write(path, bytes).then(function() {
				return fs.exec(helper, [ 'secret-set', token ]);
			}).then(function(result) {
				if (result.code)
					throw new Error(result.stderr || _('Unable to update the peer secret.'));
				input.value = '';
				ui.addNotification(null, E('p', {}, [ _('Peer secret updated.') ]), 'info');
			});
		}

		function applyAndConnect() {
			return map.save().then(function() {
				return fs.exec(helper, [ 'apply' ]);
			}).then(function(result) {
				if (result.code)
					throw new Error(result.stderr || _('Apply failed.'));
				window.location.reload();
			});
		}

		function actionBar() {
			var input = E('input', {
				'type': 'password',
				'autocomplete': 'new-password',
				'placeholder': _('Leave empty to keep the current secret')
			});
			return E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, [ _('Peer secret and actions') ]),
				E('p', { 'class': 'cbi-value-description' }, [
					_('The secret is shared with the exit router and is never stored in the configuration or shown here. Settings above are saved by "Apply and connect".')
				]),
				E('div', { 'class': 'ikev2-actions' }, [
					E('div', { 'class': 'ikev2-field' }, [
						E('label', {}, [ _('New peer secret') ]),
						input
					]),
					E('button', {
						'class': 'cbi-button cbi-button-action',
						'click': ui.createHandlerFn(self, function() { return updateSecret(input); })
					}, [ _('Update secret') ]),
					E('button', {
						'class': 'cbi-button cbi-button-apply',
						'click': ui.createHandlerFn(self, applyAndConnect)
					}, [ _('Apply and connect') ])
				])
			]);
		}

		return map.render().then(function(node) {
			return E('div', { 'class': 'ikev2-page' }, [
				E('div', { 'class': 'ikev2-header' }, [
					E('div', {}, [
						E('h2', {}, [ _('IKEv2 Site Link') ]),
						E('p', { 'class': 'ikev2-subtitle' }, [
							_('Routes selected services between two OpenWrt routers over a monitored, fail-closed IKEv2 link.')
						])
					])
				]),
				statusPanel(status),
				node,
				actionBar()
			]);
		});
	},

	// The page applies through its own button, which also runs the helper.
	// Leaving LuCI's stock footer in place would show a second, competing
	// Save/Apply pair that does not connect the link.
	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
