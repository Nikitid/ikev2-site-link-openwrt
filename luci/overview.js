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
			L.resolveDefault(fs.exec(helper, [ 'sources' ]), { code: 1, stdout: '' })
		]);
	},

	render: function(data) {
		var status = parse(data[0] && data[0].stdout);
		var sources = parseNamedValues(data[2] && data[2].stdout);
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
		option.datatype = 'uciname';
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

		var section = map.section(form.NamedSection, 'main', 'main', _('Credentials and actions'));
		section.addremove = false;

		var secret = section.option(form.DummyValue, '_secret', _('Peer secret'));
		secret.rawhtml = true;
		secret.cfgvalue = function() {
			return '<input class="cbi-input-password" id="site-link-secret" type="password" autocomplete="new-password" placeholder="' +
				_('Leave empty to keep the current secret') + '">';
		};

		var saveSecret = section.option(form.Button, '_secret_apply', _('Update peer secret'));
		saveSecret.inputstyle = 'action';
		saveSecret.onclick = function() {
			var node = document.getElementById('site-link-secret');
			var value = node ? node.value : '';
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
				node.value = '';
				ui.addNotification(null, E('p', {}, [ _('Peer secret updated.') ]), 'info');
			});
		};

		var actions = section.option(form.Button, '_apply', _('Apply and connect'));
		actions.inputstyle = 'apply';
		actions.onclick = function() {
			return map.save().then(function() {
				return fs.exec(helper, [ 'apply' ]);
			}).then(function(result) {
				if (result.code)
					throw new Error(result.stderr || _('Apply failed.'));
				window.location.reload();
			});
		};

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
				node
			]);
		});
	}
});
