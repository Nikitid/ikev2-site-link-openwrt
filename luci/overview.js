'use strict';
'require view';
'require form';
'require fs';
'require ui';
'require uci';
'require ikev2-site-link.shared as common';

var helper = '/usr/libexec/ikev2-site-link';

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
			uci.load('ikev2-site-link')
		]);
	},

	render: function(data) {
		var status = parse(data[0] && data[0].stdout);
		common.styles();
		var map = new form.Map('ikev2-site-link', null, null);
		var section = map.section(form.NamedSection, 'main', 'main', _('Configuration'));
		section.addremove = false;

		var option = section.option(form.Flag, 'enabled', _('Enabled'));
		option.rmempty = false;

		option = section.option(form.ListValue, 'role', _('Role'));
		option.value('source', _('Source router'));
		option.value('exit', _('Exit router'));
		option.rmempty = false;

		option = section.option(form.Value, 'endpoint', _('Exit endpoint'));
		option.depends('role', 'source');
		option.placeholder = 'vpn.example.net';
		option.datatype = 'host';

		option = section.option(form.Value, 'ike_port', _('Dedicated external IKE port'));
		option.datatype = 'range(1024,65535)';
		option.rmempty = false;
		option.description = _('UDP port exposed by the exit router for this link. Port 1500 avoids conflicts with ordinary IKEv2 clients. Do not use 4500.');

		option = section.option(form.Value, 'remote_id', _('Server identity'));
		option.placeholder = 'vpn.example.net';
		option.description = _('Certificate identity of the exit router. It must be identical on both routers.');

		option = section.option(form.Value, 'peer_user', _('Peer identity'));
		option.rmempty = false;
		option.datatype = 'uciname';

		option = section.option(form.Value, 'source_devices', _('Protected sources'));
		option.depends('role', 'source');
		option.rmempty = false;
		option.description = _('Space-separated PBR source selectors, for example @br-lan @ipsec-in.');

		option = section.option(form.Value, 'mtu', _('Tunnel MTU'));
		option.depends('role', 'source');
		option.datatype = 'range(1200,1500)';
		option.rmempty = false;

		option = section.option(form.Value, 'exit_pool', _('Dedicated tunnel address'));
		option.depends('role', 'exit');
		option.datatype = 'ip4addr';
		option.rmempty = false;
		option.description = _('One private IPv4 address which does not overlap either router LAN or VPN pool.');

		option = section.option(form.Value, 'monitor_interval', _('Monitor interval'));
		option.datatype = 'range(5,300)';
		option.rmempty = false;

		option = section.option(form.Value, 'failure_threshold', _('Reconnect threshold'));
		option.datatype = 'range(1,20)';
		option.rmempty = false;

		option = section.option(form.Value, 'reconnect_cooldown', _('Reconnect cooldown'));
		option.datatype = 'range(15,3600)';
		option.rmempty = false;
		option.description = _('Minimum seconds between connection attempts. This prevents restart storms while the peer is unavailable.');

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
