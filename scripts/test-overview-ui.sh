#!/bin/sh

# A parse check proves only that the file is syntactically valid. A LuCI page
# dies at render time instead - a helper that is not exported, a control built
# before its dependency, an option read from the wrong module - and every
# command-line check still passes while the page shows nothing. This harness
# stubs the LuCI environment and actually renders the view.

set -eu
root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"

node - "$root" <<'JS'
'use strict';
const fs = require('fs');
const path = require('path');
const root = process.argv[2];

function fail(message) {
	process.stderr.write('overview UI contract failed: ' + message + '\n');
	process.exit(1);
}

// Minimal DOM good enough for the design system and this page.
function makeNode(tag, attrs, children) {
	const node = {
		tagName: String(tag || 'div').toUpperCase(),
		attrs: attrs || {},
		children: [],
		style: {},
		dataset: {},
		listeners: {},
		value: (attrs && attrs.value != null) ? String(attrs.value) : '',
		checked: false,
		disabled: !!(attrs && attrs.disabled),
		textContent: '',
		className: (attrs && attrs['class']) || '',
		get firstChild() { return this.children[0] || null; },
		classList: {
			add() {}, remove() {}, contains() { return false; },
			toggle() {}
		},
		addEventListener(name, handler) { this.listeners[name] = handler; },
		removeAttribute() {}, setAttribute() {},
		appendChild(child) { this.children.push(child); return child; },
		insertBefore(child) { this.children.unshift(child); return child; },
		replaceChildren() { this.children = Array.prototype.slice.call(arguments); }
	};
	(children || []).forEach(function(child) {
		if (child) node.children.push(child);
	});
	return node;
}

function E(tag, attrs, children) {
	if (typeof tag === 'string' && tag.charAt(0) === '<')
		return makeNode('svg', {}, []);
	if (Array.isArray(attrs)) { children = attrs; attrs = {}; }
	return makeNode(tag, attrs, children);
}

const documentStub = {
	createTextNode(text) { const n = makeNode('#text', {}, []); n.textContent = String(text); return n; },
	getElementById() { return null; },
	head: { appendChild() {} },
	createDocumentFragment() { return makeNode('fragment', {}, []); },
	documentElement: { lang: 'en' },
	querySelectorAll() { return []; }
};
const windowStub = {
	localStorage: null,
	setTimeout() {},
	location: { reload() {} },
	_: null
};

const L = { resolveDefault: function(p, d) { return Promise.resolve(d); } };
const baseclass = { extend: function(o) { return o; } };
const fsStub = { exec: function() { return Promise.resolve({ code: 0, stdout: '' }); },
	write: function() { return Promise.resolve(); } };
const uiStub = {
	createHandlerFn: function(self, fn) { return fn; },
	showModal() {}, hideModal() {}, addNotification() {}
};

// Real UCI values, so a control that reads the wrong option is visible.
const uciValues = {
	role: 'exit', endpoint: '', remote_id: 'ikev2.example.net',
	peer_user: 'site-link-office', ike_port: '1500',
	source_devices: '@br-lan @ipsec-in', exit_wan: 'wan', exit_wan_zone: 'wan',
	exit_pool: '10.253.44.2', mtu: '1360', monitor_interval: '15',
	// Deliberately outside the offered choices: the control must keep it.
	probe_interval: '90',
	failure_threshold: '3', reconnect_cooldown: '30', dpd: '20',
	source_wan: '', force_tcp: '1'
};
const written = {};
const uciStub = {
	load: function() { return Promise.resolve(); },
	get: function(pkg, section, option) { return uciValues[option]; },
	set: function(pkg, section, option, value) { written[option] = value; },
	save: function() { return Promise.resolve(); }
};

function loadModule(file, extra) {
	const src = fs.readFileSync(path.join(root, 'luci', file), 'utf8');
	const names = [ 'window', 'document', 'L', 'baseclass', 'E', 'fs', 'ui', 'uci', 'view', 'common' ];
	const values = [ windowStub, documentStub, L, baseclass, E, fsStub, uiStub, uciStub,
		{ extend: function(o) { return o; } }, extra ];
	return new Function(names.join(','), src).apply(null, values);
}

const common = loadModule('shared.js', null);
[ 't', 'styles', 'card', 'pill', 'header', 'section', 'fieldLabel', 'inlineResult',
	'runAction', 'execChecked', 'inputToken' ].forEach(function(name) {
	if (typeof common[name] !== 'function')
		fail('shared.js does not export ' + name + ', which overview.js uses');
});

const view = loadModule('overview.js', common);
if (typeof view.render !== 'function')
	fail('overview.js does not return a view with render()');

const status = [
	'state=paused', 'sa=disconnected', 'role=exit', 'applied=1',
	'interface=siteexit', 'rx_bytes=426344448', 'tx_bytes=7122780160',
	'tunnel_data_plane=unverified', 'vip=10.253.44.2', 'fail_closed=not-applicable',
	'classifier=healthy', 'client_forwarding=configured', 'secret=configured',
	'secret_pending=staged', 'version=0.7.0',
	'detail=exit route is protected; waiting for peer'
].join('\n');

let page;
try {
	page = view.render([
		{ code: 0, stdout: status }, null,
		{ code: 0, stdout: 'br-lan=LAN\nipsec-in=VPN clients' },
		{ code: 0, stdout: 'lan=LAN\nwan=WAN' },
		{ code: 0, stdout: 'lan=static\nwan=dhcp' }
	]);
} catch (error) {
	fail('render() threw: ' + (error && error.stack ? error.stack : error));
}
if (!page || !page.children || !page.children.length)
	fail('render() produced an empty page');

// The page must not be built from stock CBI any more.
const source = fs.readFileSync(path.join(root, 'luci', 'overview.js'), 'utf8');
if (source.indexOf('form.Map') >= 0)
	fail('overview.js still builds the page with CBI');

// A stored value outside the offered choices must survive rendering, or the
// control silently reads as unset and the next save rewrites it.
if (source.indexOf('if (!seen && value)') < 0)
	fail('selectField does not preserve an out-of-range stored value');

// Rendering must not write configuration; only Apply may.
if (Object.keys(written).length)
	fail('render() wrote UCI options: ' + Object.keys(written).join(', '));

// A busy button must show that the action was accepted, not just go grey.
const probe = makeNode('button', {}, []);
common.setBusy(probe, true, 'Pausing...');
if (!probe.disabled) fail('setBusy did not disable the button');
if (!probe.children.some(function(c) { return c.attrs && c.attrs['class'] === 'ikev2-spin'; }))
	fail('setBusy did not render a spinner');
common.setBusy(probe, false);
if (probe.disabled) fail('setBusy did not restore the button');

process.stdout.write('overview UI render tests OK\n');
JS
