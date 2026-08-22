'use strict';
'require view';
'require fs';
'require uci';
'require ui';
'require ikev2-site-link.shared as common';

var helper = '/usr/libexec/ikev2-site-link-policy';
var manualFile = '/etc/ikev2-site-link/domains.manual.txt';
var addressFile = '/etc/ikev2-site-link/addresses.manual.txt';
var selectedFile = '/etc/ikev2-site-link/services.selected.txt';

var CATEGORIES = [
	[ 'AI', [ 'openai', 'anthropic_ai', 'google_ai', 'midjourney', 'perplexity', 'mistral', 'huggingface', 'stability_ai', 'x_ai' ] ],
	[ 'Social & messaging', [ 'telegram', 'discord', 'twitter', 'meta', 'linkedin' ] ],
	[ 'Video & music', [ 'youtube', 'tiktok', 'hdrezka', 'spotify', 'google_meet' ] ],
	[ 'Games & stores', [ 'roblox', 'google_play' ] ],
	[ 'Infrastructure (broad — use with care)', [ 'cloudflare', 'cloudfront', 'digitalocean', 'hetzner', 'ovh' ] ]
];
var BROAD = /^(cloudflare|cloudfront|digitalocean|hetzner|ovh)$/;

function parseLines(value) {
	return String(value || '').replace(/\r/g, '').split('\n').map(function(v) { return v.trim(); }).filter(Boolean);
}

function normalizeDomains(value) {
	var seen = {}, out = [];
	String(value || '').replace(/\r/g, '').split('\n').forEach(function(raw, index) {
		var value = raw.trim().toLowerCase();
		if (!value || value.charAt(0) === '#') return;
		var labels = value.split('.');
		if (value.length > 253 || value.indexOf('..') >= 0 || !/^[a-z0-9._-]+$/.test(value) ||
			labels.some(function(label) { return !label || label.length > 63 || label.charAt(0) === '-' || label.charAt(label.length - 1) === '-'; }))
			throw new Error(_('Invalid domain on line %d: %s').format(index + 1, value));
		if (!seen[value]) { seen[value] = true; out.push(value); }
	});
	return out.sort();
}

function normalizeAddresses(value) {
	var seen = {}, out = [];
	String(value || '').replace(/\r/g, '').split('\n').forEach(function(raw, index) {
		var value = raw.trim();
		if (!value || value.charAt(0) === '#') return;
		var parts = value.split('/'), octets = parts[0].split('.');
		if (parts.length > 2 || octets.length !== 4 || octets.some(function(o) { return !/^\d+$/.test(o) || +o > 255; }) ||
			(parts.length === 2 && (!/^\d+$/.test(parts[1]) || +parts[1] > 32)))
			throw new Error(_('Invalid IPv4 address or CIDR on line %d: %s').format(index + 1, value));
		value = parts[0] + '/' + (parts.length === 2 ? +parts[1] : 32);
		if (!seen[value]) { seen[value] = true; out.push(value); }
	});
	return out.sort();
}

function token() {
	return Array.prototype.map.call(crypto.getRandomValues(new Uint8Array(12)), function(v) { return v.toString(16).padStart(2, '0'); }).join('');
}

function checked(args, message) {
	return fs.exec(helper, args).then(function(result) {
		if (!result || result.code) throw new Error((result && result.stderr) || message);
		return result;
	});
}

function statusMap(text) {
	var out = {};
	String(text || '').split('\n').forEach(function(line) { var at = line.indexOf('='); if (at > 0) out[line.slice(0, at)] = line.slice(at + 1); });
	return out;
}

function poll(actionId, deadline) {
	return L.resolveDefault(fs.exec(helper, [ 'status', actionId ]), { stdout: '' }).then(function(result) {
		var state = statusMap((result || {}).stdout || '');
		if (state.state === 'ok' || state.state === 'error') return state;
		if (Date.now() > deadline) return null;
		return new Promise(function(resolve) { window.setTimeout(resolve, 1200); }).then(function() { return poll(actionId, deadline); });
	});
}

function records(text) {
	return String(text || '').split('\n').map(function(line) {
		var f = line.split('|');
		return f.length === 5 ? { id:f[0], label:f[1] || f[0], origin:f[2], customized:f[3], ip:f[4] } : null;
	}).filter(Boolean);
}

function label(id) {
	var names = { openai:'OpenAI', anthropic_ai:'Anthropic', google_ai:'Google AI', x_ai:'xAI', google_play:'Google Play', google_meet:'Google Meet', hdrezka:'HDRezka' };
	return names[id] || id.replace(/_/g, ' ').replace(/\b\w/g, function(c) { return c.toUpperCase(); });
}

return view.extend({
	load: function() {
		return Promise.all([
			L.resolveDefault(fs.read(manualFile), ''), L.resolveDefault(fs.read(addressFile), ''),
			L.resolveDefault(fs.read(selectedFile), ''), L.resolveDefault(checked([ 'services' ], _('Unable to read service catalog')), { stdout:'' }),
			uci.load('ikev2-site-link')
		]);
	},

	render: function(data) {
		var serviceRecords = records((data[3] || {}).stdout), selected = {};
		parseLines(data[2]).forEach(function(id) { selected[id] = true; });
		var role = uci.get('ikev2-site-link', 'main', 'role') || 'source';
		var domainBox = E('textarea', { 'class':'cbi-input-textarea', 'spellcheck':'false' }, [ data[0] ]);
		var addressBox = E('textarea', { 'class':'cbi-input-textarea', 'spellcheck':'false', 'placeholder':'203.0.113.10\n198.51.100.0/24' }, [ data[1] ]);
		var result = E('div');
		var save = E('button', { 'class':'cbi-button cbi-button-apply', 'type':'button' }, [ _('Save and rebuild policy') ]);

		function setResult(message, error) {
			result.className = error ? 'alert-message error' : 'alert-message success';
			result.textContent = message;
		}

		function chip(record) {
			var input = E('input', { 'type':'checkbox', 'value':record.id, 'checked':selected[record.id] ? '' : null });
			var node = E('label', { 'class':'ikev2-chip' + (selected[record.id] ? ' selected' : '') + (BROAD.test(record.id) ? ' broad' : '') }, [
				input, E('span', {}, [ record.label !== record.id ? record.label : label(record.id) ]),
				BROAD.test(record.id) ? E('span', { 'class':'ikev2-chip-mark', 'title':_('May route unrelated CDN traffic') }, [ '⚠' ]) : '',
				record.ip === '1' ? E('span', { 'class':'ikev2-chip-mark', 'title':_('Includes IPv4 networks') }, [ 'IP' ]) : ''
			]);
			input.addEventListener('change', function() { node.classList.toggle('selected', input.checked); });
			return node;
		}

		var byId = {};
		serviceRecords.forEach(function(record) { byId[record.id] = record; });
		var used = {}, groups = [];
		CATEGORIES.forEach(function(category) {
			var items = category[1].filter(function(id) { return byId[id] && byId[id].origin !== 'custom'; }).map(function(id) { used[id] = true; return chip(byId[id]); });
			if (items.length) groups.push(E('div', { 'class':'ikev2-chip-group' }, [ E('h4', {}, [ _(category[0]) ]), E('div', { 'class':'ikev2-chips' }, items) ]));
		});
		var others = serviceRecords.filter(function(r) { return r.origin !== 'custom' && !used[r.id]; }).sort(function(a,b) { return a.id.localeCompare(b.id); });
		if (others.length) groups.push(E('div', { 'class':'ikev2-chip-group' }, [ E('h4', {}, [ _('Other') ]), E('div', { 'class':'ikev2-chips' }, others.map(chip)) ]));
		var custom = serviceRecords.filter(function(r) { return r.origin === 'custom'; });
		if (custom.length) groups.push(E('div', { 'class':'ikev2-chip-group' }, [ E('h4', {}, [ _('Custom services') ]), E('div', { 'class':'ikev2-chips' }, custom.map(chip)) ]));

		function selectedIds() {
			return Array.prototype.map.call(document.querySelectorAll('.ikev2-chip input:checked'), function(input) { return input.value; }).sort();
		}

		function runScheduled(command, id) {
			return checked(command, _('Unable to start policy rebuild')).then(function(response) {
				var actionId = statusMap(response.stdout).action_id;
				if (!actionId) throw new Error(_('Background action did not start.'));
				return poll(actionId, Date.now() + 120000);
			}).then(function(state) {
				if (!state) throw new Error(_('The rebuild continues in the background.'));
				if (state.state !== 'ok') throw new Error(state.message || _('Policy rebuild failed.'));
				setResult(_('Policy active: %s services, %s domains, %s IPv4 networks.').format(state.services || '0', state.domains || '0', state.cidrs || '0'));
				return state;
			});
		}

		save.addEventListener('click', function() {
			var domains, addresses;
			try { domains = normalizeDomains(domainBox.value); addresses = normalizeAddresses(addressBox.value); }
			catch (error) { setResult(error.message, true); return; }
			var id = token(), prefix = '/tmp/ikev2-site-link-policy-input-' + id;
			save.disabled = true; setResult(_('Building policy…'));
			Promise.all([
				fs.write(prefix + '.domains', domains.join('\n') + (domains.length ? '\n' : ''), 384),
				fs.write(prefix + '.cidrs', addresses.join('\n') + (addresses.length ? '\n' : ''), 384),
				fs.write(prefix + '.services', selectedIds().join('\n') + (selectedIds().length ? '\n' : ''), 384)
			]).then(function() { return runScheduled([ 'schedule', id ]); }).catch(function(error) { setResult(error.message, true); }).finally(function() { save.disabled = false; });
		});

		var picker = E('select', { 'class':'cbi-input-select' });
		picker.appendChild(E('option', { 'value':'' }, [ _('New service…') ]));
		serviceRecords.slice().sort(function(a,b) { return a.label.localeCompare(b.label); }).forEach(function(r) { picker.appendChild(E('option', { 'value':r.id }, [ r.label !== r.id ? r.label : label(r.id) ])); });
		var idInput = E('input', { 'class':'cbi-input-text', 'placeholder':'my_service' });
		var nameInput = E('input', { 'class':'cbi-input-text', 'placeholder':_('My service') });
		var serviceDomains = E('textarea', { 'class':'cbi-input-textarea', 'spellcheck':'false', 'placeholder':'example.com' });
		var serviceCidrs = E('textarea', { 'class':'cbi-input-textarea', 'spellcheck':'false', 'placeholder':'203.0.113.0/24' });
		var serviceSave = E('button', { 'class':'cbi-button cbi-button-apply', 'type':'button' }, [ _('Save service') ]);
		var serviceReset = E('button', { 'class':'cbi-button cbi-button-reset', 'type':'button' }, [ _('Restore built-in') ]);
		var serviceDelete = E('button', { 'class':'cbi-button cbi-button-negative', 'type':'button' }, [ _('Delete custom service') ]);

		function currentRecord() { return byId[picker.value] || null; }
		function loadService() {
			var record = currentRecord();
			idInput.disabled = !!record; idInput.value = record ? record.id : ''; nameInput.value = record ? record.label : '';
			serviceDomains.value = ''; serviceCidrs.value = '';
			serviceReset.style.display = record && record.origin !== 'custom' && record.customized === '1' ? '' : 'none';
			serviceDelete.style.display = record && record.origin === 'custom' ? '' : 'none';
			if (record) checked([ 'service-read', record.id ], _('Unable to read service')).then(function(response) {
				var section = '', domains = [], cidrs = [];
				String(response.stdout || '').split('\n').forEach(function(line) { if (line === '---domains---') section='domains'; else if (line === '---cidrs---') section='cidrs'; else if (section === 'domains') domains.push(line); else if (section === 'cidrs') cidrs.push(line); });
				serviceDomains.value = domains.join('\n').replace(/\n+$/, ''); serviceCidrs.value = cidrs.join('\n').replace(/\n+$/, '');
			}).catch(function(error) { setResult(error.message, true); });
		}
		picker.addEventListener('change', loadService); loadService();

		function serviceOperation(operation) {
			var record = currentRecord(), id = (record ? record.id : idInput.value).trim().toLowerCase();
			var name = nameInput.value.trim(), domains = [], cidrs = [];
			if (!/^[a-z0-9_]{2,48}$/.test(id)) { setResult(_('Service identifier must contain 2–48 lowercase letters, digits or underscores.'), true); return; }
			if (operation === 'save') {
				try { domains = normalizeDomains(serviceDomains.value); cidrs = normalizeAddresses(serviceCidrs.value); } catch (error) { setResult(error.message, true); return; }
				if (!name || name.length > 80 || /[|\r\n]/.test(name) || (!domains.length && !cidrs.length)) { setResult(_('Enter a valid name and at least one domain or IPv4 network.'), true); return; }
			}
			var idToken = token(), prefix = '/tmp/ikev2-site-link-service-input-' + idToken;
			var meta = 'operation=' + operation + '\nid=' + id + '\nlabel=' + name + '\nselected=keep\n';
			Promise.all([
				fs.write(prefix + '.meta', meta, 384), fs.write(prefix + '.domains', domains.join('\n') + (domains.length ? '\n' : ''), 384),
				fs.write(prefix + '.cidrs', cidrs.join('\n') + (cidrs.length ? '\n' : ''), 384)
			]).then(function() { return runScheduled([ 'service-schedule', idToken ]); }).then(function() { window.location.reload(); }).catch(function(error) { setResult(error.message, true); });
		}
		serviceSave.addEventListener('click', function() { serviceOperation('save'); });
		serviceReset.addEventListener('click', function() { if (window.confirm(_('Discard the local override?'))) serviceOperation('reset'); });
		serviceDelete.addEventListener('click', function() { if (window.confirm(_('Delete this custom service?'))) serviceOperation('delete'); });

		common.styles();
		return E('div', { 'class':'ikev2-page' }, [
			E('div', { 'class':'ikev2-header' }, [ E('div', {}, [ E('h2', {}, [ _('Policy Routing') ]), E('p', { 'class':'ikev2-subtitle' }, [ _('Select services and destinations that must use the monitored Site Link. All matching traffic remains fail-closed while the tunnel is unavailable.') ]) ]) ]),
			role !== 'source' ? E('div', { 'class':'alert-message warning' }, [ _('Policies are applied only on the source router. This router is configured as the exit.') ]) : '',
			E('section', { 'class':'ikev2-policy-section' }, [ E('h3', {}, [ _('Services') ]), E('p', {}, [ _('Prepared services can be selected or overridden. User-created services are stored separately and survive package upgrades.') ]) ].concat(groups)),
			E('div', { 'class':'ikev2-policy-grid' }, [
				E('section', { 'class':'ikev2-policy-section' }, [ E('h3', {}, [ _('Custom domains') ]), E('p', {}, [ _('One domain suffix per line; subdomains are included automatically.') ]), domainBox ]),
				E('section', { 'class':'ikev2-policy-section' }, [ E('h3', {}, [ _('Custom IPv4 addresses and networks') ]), E('p', {}, [ _('One address or CIDR per line. A single address is stored as /32.') ]), addressBox ])
			]),
			E('section', { 'class':'ikev2-policy-section' }, [ E('h3', {}, [ _('Manage services') ]), E('p', {}, [ _('Create a service or override a prepared definition with your own domains and IPv4 networks.') ]), E('div', { 'class':'ikev2-service-grid' }, [
				E('label', {}, [ _('Service') ]), picker, E('label', {}, [ _('Identifier') ]), idInput, E('label', {}, [ _('Display name') ]), nameInput,
				E('label', {}, [ _('Domains') ]), serviceDomains, E('label', {}, [ _('IPv4/CIDR') ]), serviceCidrs
			]), E('div', { 'class':'ikev2-actions' }, [ serviceReset, serviceDelete, serviceSave ]) ]),
			result, E('div', { 'class':'ikev2-actions' }, [ save ])
		]);
	},
	handleSave: null, handleSaveApply: null, handleReset: null
});
