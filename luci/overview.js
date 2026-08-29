'use strict';
'require view';
'require fs';
'require ui';
'require uci';
'require ikev2-site-link.shared as common';

// Shadow the global _() with the project translator for this module only;
// see the note in shared.js about not replacing window._.
var _ = common.t;

var config = 'ikev2-site-link';
var helper = '/usr/libexec/ikev2-site-link';

// Resource names and XFRM identifiers are no longer editable. They exist only
// to keep the link from colliding with IKEv2 Manager's reserved 42 and 43, the
// runtime already refuses a conflict, and changing one requires a full Disable
// first. Presenting them as settings invited exactly that mistake.
var fixedDefaults = {
	interface: 'sitehome', xfrm_device: 'ipsec-home', if_id: '44',
	exit_interface: 'siteexit', exit_device: 'ipsec-site-exit', exit_if_id: '45'
};

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

function get(option, fallback) {
	var value = uci.get(config, 'main', option);
	return (value == null || value === '') ? (fallback || '') : String(value);
}

function textField(option, fallback, attrs) {
	return E('input', Object.assign({
		'type': 'text', 'class': 'cbi-input-text', 'value': get(option, fallback)
	}, attrs || {}));
}

// A stored value that is not among the offered choices must still be shown, or
// the control silently reads as "-- Please choose --" and a save rewrites it.
function selectField(option, fallback, choices) {
	var value = get(option, fallback);
	var seen = false;
	var node = E('select', { 'class': 'cbi-input-select' },
		choices.map(function(choice) {
			if (choice[0] === value)
				seen = true;
			return E('option', { 'value': choice[0] }, [ choice[1] ]);
		}));
	if (!seen && value)
		node.insertBefore(E('option', { 'value': value }, [ value ]), node.firstChild);
	node.value = value;
	return node;
}

function checkboxField(option, fallback) {
	var node = E('input', { 'type': 'checkbox', 'class': 'cbi-input-checkbox' });
	node.checked = get(option, fallback) !== '0';
	return node;
}

// Protected sources are a small fixed set of the router's own devices, so they
// read better as chips than as a free-text list.
function sourceChips(sources) {
	var selected = get('source_devices', '@br-lan').split(/\s+/).filter(Boolean);
	var boxes = [];
	var chips = sources.map(function(entry) {
		var name = '@' + entry.name;
		var box = E('input', { 'type': 'checkbox', 'value': name });
		box.checked = selected.indexOf(name) >= 0;
		boxes.push(box);
		var chip = E('label', { 'class': 'ikev2-chip' }, [
			box, name, entry.value ? E('span', { 'class': 'ikev2-chip-mark' }, [ entry.value ]) : ''
		]);
		box.addEventListener('change', function() {
			chip.classList.toggle('selected', box.checked);
		});
		chip.classList.toggle('selected', box.checked);
		return chip;
	});
	// Anything configured by hand that is not an offered device stays selected
	// instead of being dropped by the next save.
	selected.forEach(function(name) {
		if (sources.some(function(entry) { return '@' + entry.name === name; }))
			return;
		var box = E('input', { 'type': 'checkbox', 'value': name });
		box.checked = true;
		boxes.push(box);
		var chip = E('label', { 'class': 'ikev2-chip selected' }, [ box, name ]);
		box.addEventListener('change', function() {
			chip.classList.toggle('selected', box.checked);
		});
		chips.push(chip);
	});
	return {
		node: E('div', { 'class': 'ikev2-chips' }, chips),
		values: function() {
			return boxes.filter(function(box) { return box.checked; })
				.map(function(box) { return box.value; });
		}
	};
}

function statusCards(status) {
	var role = status.role === 'exit' ? _('Exit router') : _('Source router');
	return E('div', { 'class': 'ikev2-grid' }, [
		common.card(_('Role'), role, status.interface || '—'),
		common.card(_('Traffic'), '↓ ' + bytes(status.rx_bytes),
			_('Sent: ') + bytes(status.tx_bytes)),
		common.card(_('Tunnel data plane'), status.tunnel_data_plane || _('unverified'),
			_('Tunnel address: ') + (status.vip || '—')),
		common.card(_('Routing path'), status.fail_closed === 'active' ? _('Fail-closed') :
			(status.role === 'exit' ? _('WAN only') : _('Unavailable')),
			_('Classifier: ') + (status.classifier || '—') + ' · ' +
			_('Reachable from exit: ') + (status.classifier_reachable || '—') + ' · ' +
			_('Client forwarding: ') + (status.client_forwarding || '—'))
	]);
}

return view.extend({
	load: function() {
		return Promise.all([
			L.resolveDefault(fs.exec(helper, [ 'status' ]), { code: 1, stdout: '' }),
			uci.load(config),
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

		var paused = status.state === 'paused';
		var connected = status.sa === 'connected';
		var applied = status.applied === '1';

		var role = selectField('role', 'source', [
			[ 'source', _('Source router') + ' — ' + _('sends selected traffic out') ],
			[ 'exit', _('Exit router') + ' — ' + _('receives it and reaches the Internet') ]
		]);
		var endpoint = textField('endpoint', '', { 'placeholder': 'vpn.example.net' });
		var remoteId = textField('remote_id', '', { 'placeholder': 'vpn.example.net' });
		var peerUser = textField('peer_user', '', { 'placeholder': 'site-link-office' });
		var ikePort = selectField('ike_port', '1500', [
			[ '1500', '1500 — ' + _('recommended') ], [ '1501', '1501' ], [ '1600', '1600' ]
		]);

		var chips = sourceChips(sources);
		var zoneChoices = zones.map(function(zone) {
			return [ zone.name, zone.name + (zone.value ? ' — ' + zone.value : '') ];
		});
		var exitWan = textField('exit_wan', 'wan', { 'placeholder': 'wan' });
		var exitWanZone = selectField('exit_wan_zone', 'wan',
			zoneChoices.length ? zoneChoices : [ [ 'wan', 'wan' ] ]);
		var exitPool = textField('exit_pool', '10.253.44.2', { 'placeholder': '10.253.44.2' });
		var mtu = selectField('mtu', '1360', [
			[ '1360', '1360 — ' + _('recommended') ], [ '1400', '1400' ],
			[ '1280', '1280 — ' + _('minimum') ]
		]);

		var monitorInterval = selectField('monitor_interval', '15', [
			[ '15', '15 ' + _('seconds') + ' — ' + _('recommended') ],
			[ '30', '30 ' + _('seconds') ], [ '60', '60 ' + _('seconds') ]
		]);
		var probeInterval = selectField('probe_interval', '60', [
			[ '60', '60 ' + _('seconds') + ' — ' + _('recommended') ],
			[ '120', '2 ' + _('minutes') ], [ '300', '5 ' + _('minutes') ]
		]);
		var failureThreshold = selectField('failure_threshold', '3', [
			[ '3', '3 ' + _('checks') + ' — ' + _('recommended') ], [ '5', '5 ' + _('checks') ]
		]);
		var reconnectCooldown = selectField('reconnect_cooldown', '30', [
			[ '30', '30 ' + _('seconds') + ' — ' + _('recommended') ],
			[ '60', '60 ' + _('seconds') ], [ '300', '5 ' + _('minutes') ]
		]);
		var dpd = selectField('dpd', '20', [
			[ '20', '20 ' + _('seconds') + ' — ' + _('recommended') ],
			[ '30', '30 ' + _('seconds') ], [ '60', '60 ' + _('seconds') ]
		]);
		var sourceWan = textField('source_wan', '', { 'placeholder': 'wan' });
		var forceTcp = checkboxField('force_tcp', '1');

		// One grid per section keeps the label column aligned; role-specific rows
		// are hidden rather than moved so the alignment does not jump.
		function grid(rows) {
			return E('div', { 'class': 'ikev2-form-grid' },
				rows.reduce(function(all, item) {
					return all.concat([ item.label, item.control ]);
				}, []));
		}

		function field(label, help, control, only) {
			return {
				label: common.fieldLabel(label, help), control: control, only: only || null
			};
		}

		var linkFields = [
			field(_('Role'), null, role),
			field(_('Exit endpoint'),
				_('Address of the exit router, as published by IKEv2 Manager.'), endpoint, 'source'),
			field(_('Server identity'),
				_('Certificate identity of the exit router. It must be identical on both routers.'), remoteId),
			field(_('Peer identity'),
				_('EAP identity this link authenticates with. It must exist on the exit router and be used by nothing else.'), peerUser),
			field(_('Dedicated external IKE port'),
				_('UDP port the exit router publishes for this link. Both routers must use the same value.'), ikePort)
		];
		var trafficFields = [
			field(_('Protected sources'),
				_('Networks whose traffic may enter the link. Anything not listed keeps using this router\'s own connection.'),
				chips.node, 'source'),
			field(_('Exit WAN network'),
				_('Network used to route Site Link traffic to the Internet.'), exitWan, 'exit'),
			field(_('Exit WAN firewall zone'),
				_('Zone used by the forwarding and dedicated-port rules.'), exitWanZone, 'exit'),
			field(_('Dedicated tunnel address'),
				_('One private IPv4 address for this link alone. It must not overlap either router\'s LAN or any VPN pool.'),
				exitPool, 'exit'),
			field(_('Tunnel MTU'),
				_('Lower values cost throughput; higher ones risk fragmentation inside the tunnel.'), mtu)
		];
		var advancedFields = [
			field(_('Monitor interval'), null, monitorInterval),
			field(_('Data-plane probe interval'),
				_('Use the same value on both routers.'), probeInterval),
			field(_('Reconnect threshold'),
				_('Consecutive failed checks before the link is reconnected.'), failureThreshold, 'source'),
			field(_('Reconnect cooldown'),
				_('Minimum time between connection attempts.'), reconnectCooldown, 'source'),
			field(_('Dead peer detection'), null, dpd),
			field(_('Source WAN network'),
				_('Network event that triggers an immediate reconnect after WAN recovery.'), sourceWan, 'source'),
			field(_('Reject QUIC to selected destinations'),
				_('Clients fall back to TCP immediately instead of waiting out a QUIC timeout.'), forceTcp, 'source')
		];

		function applyRoleVisibility() {
			[].concat(linkFields, trafficFields, advancedFields).forEach(function(item) {
				if (!item.only)
					return;
				var hide = item.only !== role.value;
				item.label.style.display = hide ? 'none' : '';
				item.control.style.display = hide ? 'none' : '';
			});
		}
		role.addEventListener('change', applyRoleVisibility);

		var secretInput = E('input', {
			'type': 'password', 'class': 'cbi-input-text', 'autocomplete': 'new-password',
			'placeholder': _('Leave empty to keep the current secret')
		});
		var result = common.inlineResult();

		function reload() { window.location.reload(); }

		function runHelper(button, verb, busy, failure) {
			return common.runAction({
				button: button, result: result, busy: busy, failure: failure,
				run: function() {
					return common.execChecked(helper, [ verb ], failure);
				},
				onSuccess: reload
			});
		}

		function persist() {
			uci.set(config, 'main', 'role', role.value);
			uci.set(config, 'main', 'endpoint', endpoint.value.trim());
			uci.set(config, 'main', 'remote_id', remoteId.value.trim());
			uci.set(config, 'main', 'peer_user', peerUser.value.trim());
			uci.set(config, 'main', 'ike_port', ikePort.value);
			uci.set(config, 'main', 'source_devices', chips.values().join(' '));
			uci.set(config, 'main', 'exit_wan', exitWan.value.trim() || 'wan');
			uci.set(config, 'main', 'exit_wan_zone', exitWanZone.value);
			uci.set(config, 'main', 'exit_pool', exitPool.value.trim());
			uci.set(config, 'main', 'mtu', mtu.value);
			uci.set(config, 'main', 'monitor_interval', monitorInterval.value);
			uci.set(config, 'main', 'probe_interval', probeInterval.value);
			uci.set(config, 'main', 'failure_threshold', failureThreshold.value);
			uci.set(config, 'main', 'reconnect_cooldown', reconnectCooldown.value);
			uci.set(config, 'main', 'dpd', dpd.value);
			uci.set(config, 'main', 'source_wan', sourceWan.value.trim());
			uci.set(config, 'main', 'force_tcp', forceTcp.checked ? '1' : '0');
			// The runtime reads these whether or not the page shows them, so an
			// installation that never had them keeps working.
			Object.keys(fixedDefaults).forEach(function(option) {
				if (!uci.get(config, 'main', option))
					uci.set(config, 'main', option, fixedDefaults[option]);
			});
			return uci.save();
		}

		var applyButton = E('button', { 'class': 'cbi-button cbi-button-apply' },
			[ _('Apply and connect') ]);
		applyButton.addEventListener('click', ui.createHandlerFn(self, function() {
			return common.runAction({
				button: applyButton, result: result,
				busy: _('Applying...'), failure: _('Apply failed.'),
				run: function() {
					return persist().then(function() {
						return common.execChecked(helper, [ 'apply' ], _('Apply failed.'));
					});
				},
				onSuccess: reload
			});
		}));

		var pauseButton = E('button', {
			'class': 'cbi-button ' + (paused ? 'cbi-button-positive' : 'cbi-button-action'),
			'disabled': applied ? null : 'disabled'
		}, [ paused ? _('Resume') : _('Pause') ]);
		pauseButton.addEventListener('click', ui.createHandlerFn(self, function() {
			return paused ?
				runHelper(pauseButton, 'resume', _('Resuming...'), _('Unable to resume the site link.')) :
				runHelper(pauseButton, 'pause', _('Pausing...'), _('Unable to pause the site link.'));
		}));

		var disableButton = E('button', {
			'class': 'cbi-button cbi-button-negative',
			'disabled': applied ? null : 'disabled'
		}, [ _('Disable') ]);
		disableButton.addEventListener('click', ui.createHandlerFn(self, function() {
			return new Promise(function(resolve) {
				ui.showModal(_('Disable site link'), [
					E('p', {}, [ _('This removes the tunnel together with the network, firewall and routing configuration it generated, and discards the applied snapshot. The peer secret is kept. Turning the link back on afterwards needs a full Apply.') ]),
					E('p', {}, [ _('To switch the link off temporarily, use Pause instead: it keeps everything configured and comes back in one click.') ]),
					E('div', { 'class': 'right' }, [
						E('button', { 'class': 'cbi-button', 'click': function() { ui.hideModal(); resolve(false); } }, [ _('Cancel') ]),
						' ',
						E('button', { 'class': 'cbi-button cbi-button-negative', 'click': function() { ui.hideModal(); resolve(true); } }, [ _('Disable') ])
					])
				]);
			}).then(function(confirmed) {
				if (!confirmed)
					return null;
				return runHelper(disableButton, 'disable', _('Disabling...'), _('Unable to disable the site link.'));
			});
		}));

		function secretButton(label, verb, busy, failure, cls) {
			var button = E('button', { 'class': 'cbi-button ' + (cls || 'cbi-button-action') }, [ label ]);
			button.addEventListener('click', ui.createHandlerFn(self, function() {
				return runHelper(button, verb, busy, failure);
			}));
			return button;
		}

		var stageButton = E('button', { 'class': 'cbi-button cbi-button-action' }, [ _('Stage replacement') ]);
		stageButton.addEventListener('click', ui.createHandlerFn(self, function() {
			return common.runAction({
				button: stageButton, result: result,
				busy: _('Storing the secret...'), failure: _('Unable to update the peer secret.'),
				run: function() {
					if (!secretInput.value)
						throw new Error(_('Enter a peer secret first.'));
					var token = common.inputToken().replace(/[^A-Za-z0-9-]/g, '');
					var path = '/var/run/ikev2-site-link-secret-' + token + '.in';
					return fs.write(path, new TextEncoder().encode(secretInput.value)).then(function() {
						return common.execChecked(helper, [ 'secret-set', token ],
							_('Unable to update the peer secret.'));
					}).then(function() {
						secretInput.value = '';
						result.ok(status.secret === 'configured' ?
							_('Replacement staged. Activate the exit router first, then the source.') :
							_('Initial peer secret configured.'));
					});
				}
			});
		}));

		var stateDescription = paused ?
			_('The link is paused. Selected traffic uses this router\'s own connection; the tunnel, routing policy and peer secret stay configured.') :
			_('Pause stops the tunnel and returns selected traffic to this router, keeping everything configured. Disable removes the link and its generated configuration.');

		applyRoleVisibility();

		return E('div', { 'class': 'ikev2-page' }, [
			common.header(_('IKEv2 Site Link'),
				_('Routes selected services between two OpenWrt routers over a monitored, fail-closed IKEv2 link.'),
				[
					common.pill(applied ? _('Applied') : _('Prepared'), applied ? 'good' : 'warn'),
					common.pill(paused ? _('Paused') : (connected ? _('Tunnel online') : _('Tunnel offline')),
						paused ? 'neutral' : (connected ? 'good' : 'bad'))
				]),
			E('p', { 'class': 'ikev2-subtitle' }, [
				status.detail || _('Live state has not been reported yet.')
			]),
			statusCards(status),
			common.section(_('Running state'), stateDescription,
				E('div', { 'class': 'ikev2-actions' }, [ pauseButton, disableButton ])),
			common.section(_('Link'),
				_('Identities and the dedicated port. Both routers must agree on every value here.'),
				grid(linkFields)),
			common.section(_('Traffic'),
				_('What enters the link on the source router, and how the exit router reaches the Internet.'),
				grid(trafficFields)),
			common.section(_('Peer secret'),
				_('The secret is write-only. Initial setup activates it immediately. Later changes are staged: activate the exit first, then the source, which verifies the new credential and rolls back on failure.'),
				E('div', { 'class': 'ikev2-form-grid' }, [
					common.fieldLabel(_('New peer secret')), secretInput
				]),
				E('div', { 'class': 'ikev2-actions' }, [
					stageButton,
					secretButton(_('Activate staged'), 'secret-activate',
						_('Activating...'), _('Unable to activate the staged secret.')),
					secretButton(_('Restore previous'), 'secret-rollback',
						_('Restoring...'), _('Unable to restore the previous secret.'), 'cbi-button-reset')
				])),
			E('details', { 'class': 'ikev2-section' }, [
				E('summary', {}, [ E('strong', {}, [ _('Advanced — timings and reconnection') ]) ]),
				E('p', { 'class': 'ikev2-subtitle', 'style': 'margin:.5rem 0 1rem' }, [
					_('Every value here has a working default. Interface names and XFRM identifiers are fixed by the application and are no longer editable, because changing one requires disabling the link first.')
				]),
				grid(advancedFields)
			]),
			E('div', { 'class': 'ikev2-actions end' }, [ result.node, applyButton ])
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
