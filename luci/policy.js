'use strict';
'require view';
'require fs';
'require uci';
'require ikev2-site-link.shared as common';

var _ = common.t;
var helper = '/usr/libexec/ikev2-site-link-policy';
var manualFile = '/etc/ikev2-site-link/domains.manual.txt';
var addressFile = '/etc/ikev2-site-link/addresses.manual.txt';
var selectedFile = '/etc/ikev2-site-link/services.selected.txt';
var statusFile = '/tmp/ikev2-site-link-policy.status';
var serviceSelection = {};
var serviceRecords = [];
var policySelectionChanged = function() {};

function normalizeDomains(value) {
	var lines = (value || '').replace(/\r/g, '').split('\n');
	var domains = [], seen = {};
	for (var i = 0; i < lines.length; i++) {
		var domain = lines[i].trim().toLowerCase();
		if (!domain || domain.charAt(0) === '#') continue;
		var labels = domain.split('.');
		if (domain.length > 253 || domain.charAt(0) === '.' ||
		    domain.charAt(domain.length - 1) === '.' || domain.indexOf('..') !== -1 ||
		    labels.some(function(label) { return !label || label.length > 63 ||
			    label.charAt(0) === '-' || label.charAt(label.length - 1) === '-'; }) ||
		    /\s/.test(domain) || domain.indexOf('@') !== -1 || domain.indexOf('/') !== -1 ||
		    domain.indexOf('full:') === 0 || domain.indexOf('regexp:') === 0 ||
		    !/^[a-z0-9._-]+$/.test(domain))
			throw new Error(_('Invalid entry on line %d: %s').format(i + 1, domain));
		if (!seen[domain]) { seen[domain] = true; domains.push(domain); }
	}
	return domains;
}

function normalizeAddresses(value) {
	var lines = (value || '').replace(/\r/g, '').split('\n');
	var addresses = [], seen = {};
	for (var i = 0; i < lines.length; i++) {
		var entry = lines[i].trim();
		if (!entry || entry.charAt(0) === '#') continue;
		var parts = entry.split('/');
		if (parts.length > 2 || (parts.length === 2 && (!/^\d+$/.test(parts[1]) || +parts[1] > 32)))
			throw new Error(_('Invalid IPv4 address or network on line %d: %s').format(i + 1, entry));
		var octets = parts[0].split('.');
		if (octets.length !== 4 || octets.some(function(octet) { return !/^\d+$/.test(octet) || +octet > 255; }))
			throw new Error(_('Invalid IPv4 address or network on line %d: %s').format(i + 1, entry));
		var normalized = parts[0] + '/' + (parts.length === 2 ? +parts[1] : 32);
		if (!seen[normalized]) { seen[normalized] = true; addresses.push(normalized); }
	}
	return addresses;
}

function serviceLabel(name) {
	var labels = { openai:'OpenAI', anthropic_ai:'Anthropic', google_ai:'Google AI', x_ai:'xAI',
		hdrezka:'HDRezka', google_play:'Google Play', google_meet:'Google Meet',
		digitalocean:'DigitalOcean', cloudfront:'CloudFront' };
	return labels[name] || name.replace(/_/g, ' ').replace(/\b\w/g, function(letter) { return letter.toUpperCase(); });
}

var SERVICE_CATEGORIES = [
	{ title:'AI', names:[ 'openai','anthropic_ai','google_ai','midjourney','perplexity','mistral','huggingface','stability_ai','x_ai' ] },
	{ title:'Social & messaging', names:[ 'telegram','discord','twitter','meta','linkedin' ] },
	{ title:'Video & music', names:[ 'youtube','tiktok','hdrezka','spotify','google_meet' ] },
	{ title:'Games & stores', names:[ 'roblox','google_play' ] },
	{ title:'Infrastructure (broad — use with care)', names:[ 'cloudflare','cloudfront','digitalocean','hetzner','ovh' ] }
];
var BROAD_SERVICES = /^(cloudflare|cloudfront|digitalocean|hetzner|ovh)$/;

function serviceChip(record, selected, readOnly) {
	var name = record.id, broad = BROAD_SERVICES.test(name), ipNetworks = record.ip === '1';
	var input = E('input', { 'type':'checkbox', 'class':'ikev2-community-service', 'value':name,
		'checked':selected[name] ? '' : null, 'disabled':readOnly ? '' : null });
	var chip = E('label', { 'class':'ikev2-chip' }, [
		input, E('span', {}, [ record.label && record.label !== name ? record.label : serviceLabel(name) ]),
		broad ? E('span', { 'class':'ikev2-chip-mark', 'title':_('Broad — may also route unrelated sites') }, [ common.icon('warning') ]) : '',
		ipNetworks ? E('span', { 'class':'ikev2-chip-mark', 'title':_('Includes direct service IP networks') }, [ common.icon('network') ]) : ''
	]);
	chip.className += (broad ? ' broad' : '') + (selected[name] ? ' selected' : '');
	input.addEventListener('change', function() {
		chip.classList.toggle('selected', input.checked);
		if (input.checked) serviceSelection[name] = true; else delete serviceSelection[name];
		policySelectionChanged();
	});
	return chip;
}

function renderServiceGroups(services, selected, readOnly) {
	var available = {}, used = {}, blocks = [];
	services.forEach(function(record) { available[record.id] = record; });
	function block(title, names) {
		var items = names.filter(function(name) { return available[name] && available[name].origin !== 'custom'; })
			.map(function(name) { used[name] = true; return serviceChip(available[name], selected, readOnly); });
		if (items.length) blocks.push(E('div', { 'class':'ikev2-chip-group' }, [ E('h4', {}, [ _(title) ]), E('div', { 'class':'ikev2-chips' }, items) ]));
	}
	SERVICE_CATEGORIES.forEach(function(category) { block(category.title, category.names); });
	var others = services.filter(function(record) { return record.origin !== 'custom' && !used[record.id]; })
		.map(function(record) { return record.id; }).sort();
	block('Other', others);
	var custom = services.filter(function(record) { return record.origin === 'custom'; })
		.sort(function(a,b) { return (a.label || a.id).localeCompare(b.label || b.id); });
	if (custom.length) blocks.push(E('div', { 'class':'ikev2-chip-group' }, [ E('h4', {}, [ _('Custom services') ]),
		E('div', { 'class':'ikev2-chips' }, custom.map(function(record) { return serviceChip(record, selected, readOnly); })) ]));
	return blocks;
}

function parseServiceRecords(text) {
	return (text || '').replace(/\r/g, '').split('\n').map(function(line) {
		var fields = line.split('|');
		if (fields.length !== 5 || !/^[a-z0-9_]+$/.test(fields[0])) return null;
		return { id:fields[0], label:fields[1], origin:fields[2], customized:fields[3], ip:fields[4] };
	}).filter(Boolean);
}

function parseServiceDetails(text) {
	var details = { domains:'', cidrs:'' }, section = '';
	(text || '').replace(/\r/g, '').split('\n').forEach(function(line) {
		if (line === '---domains---') { section = 'domains'; return; }
		if (line === '---cidrs---') { section = 'cidrs'; return; }
		if (section) { details[section] += line + '\n'; return; }
		var eq = line.indexOf('='); if (eq > 0) details[line.slice(0, eq)] = line.slice(eq + 1);
	});
	return details;
}

function parseStatus(text) {
	var out = {};
	(text || '').replace(/\r/g, '').split('\n').forEach(function(line) { var eq = line.indexOf('='); if (eq > 0) out[line.slice(0, eq)] = line.slice(eq + 1); });
	return out;
}

function pollStatus(actionId, deadline, onProgress) {
	return L.resolveDefault(fs.exec(helper, [ 'status', actionId ]), { stdout:'' }).then(function(response) {
		var status = parseStatus((response && response.stdout) || '');
		if (status.action_id === actionId && status.state === 'running' && onProgress) onProgress(status);
		if (status.action_id === actionId && (status.state === 'ok' || status.state === 'error')) return status;
		if (Date.now() >= deadline) return null;
		return new Promise(function(resolve) { window.setTimeout(resolve, 1500); }).then(function() { return pollStatus(actionId, deadline, onProgress); });
	});
}

function updateStatusLine(status) {
	var pre = document.querySelector('#ikev2-status-line');
	if (!pre || !status) return;
	var lines = [];
	[ 'state','updated','services','domains','cidrs','custom_cidrs','selected','cached_services','message' ].forEach(function(key) {
		if (status[key] != null && status[key] !== '') lines.push(key + '=' + status[key]);
	});
	pre.textContent = lines.join('\n'); pre.style.display = lines.length ? '' : 'none';
}

return view.extend({
	load: function() {
		return Promise.all([
			L.resolveDefault(fs.read(manualFile), ''), L.resolveDefault(fs.read(selectedFile), ''),
			L.resolveDefault(fs.read(statusFile), ''), L.resolveDefault(common.execChecked(helper, [ 'services' ], _('Unable to refresh the service catalog')), { stdout:'' }),
			L.resolveDefault(fs.read(addressFile), ''), uci.load('ikev2-site-link')
		]);
	},

	doSave: function(result, onUpdated) {
		var domainBox = document.querySelector('#ikev2-domain-list');
		var addressBox = document.querySelector('#ikev2-address-list');
		if (!domainBox || !addressBox) { result.err(_('Editor is not ready.')); return Promise.reject(new Error('textarea-missing')); }
		var domains, addresses;
		try { domains = normalizeDomains(domainBox.value); addresses = normalizeAddresses(addressBox.value); }
		catch (error) { result.err(error.message); return Promise.reject(error); }
		var selected = Object.keys(serviceSelection).sort();
		var domainValue = domains.join('\n') + (domains.length ? '\n' : '');
		var addressValue = addresses.join('\n') + (addresses.length ? '\n' : '');
		var selectedValue = selected.join('\n') + (selected.length ? '\n' : '');
		var token = common.inputToken(), prefix = '/tmp/ikev2-site-link-policy-input-' + token;
		return Promise.all([ fs.write(prefix + '.domains', domainValue, 384), fs.write(prefix + '.cidrs', addressValue, 384), fs.write(prefix + '.services', selectedValue, 384) ])
			.then(function() {
				result.busy(_('Rebuilding the PBR list…'));
				return common.execChecked(helper, [ 'schedule', token ], _('Unable to start the PBR rebuild'));
			}).then(function(response) {
				domainBox.value = domainValue; addressBox.value = addressValue;
				var actionId = parseStatus(response.stdout || '').action_id;
				if (!actionId) throw new Error(_('Action did not start'));
				return pollStatus(actionId, Date.now() + 120000, function(status) { if (status.message) result.busy(_(status.message)); });
			}).then(function(status) {
				updateStatusLine(status); if (onUpdated) onUpdated(status);
				if (!status) { result.warn(_('Saved; rebuild continues in the background.')); return; }
				if (status.state === 'ok') result.ok(_('%s domains active').format(status.domains != null ? status.domains : '?'));
				else result.err(_('Rebuild failed: %s').format(status.message || _('unknown error')));
			}).catch(function(error) { if (error.message !== 'textarea-missing') result.err(_('Unable to save: %s').format(error.message)); });
	},

	render: function(data) {
		var self = this, manual = data[0] || '', manualAddresses = data[4] || '';
		var selected = {}, selectedLines = (data[1] || '').trim().split(/\s+/).filter(Boolean);
		var statusText = (data[2] || '').trim(), statusData = parseStatus(statusText);
		var candidateRole = uci.get('ikev2-site-link', 'main', 'role') || 'source';
		var applied = uci.get('ikev2-site-link', 'applied', 'enabled') === '1';
		var appliedRole = uci.get('ikev2-site-link', 'applied', 'role') || candidateRole;
		var readOnly = candidateRole !== 'source' || (applied && appliedRole !== 'source');
		serviceRecords = parseServiceRecords(((data[3] || {}).stdout) || '');
		selectedLines.forEach(function(id) { selected[id] = true; });
		serviceSelection = Object.assign({}, selected);

		var policyPill = common.pill('', 'neutral');
		function updatePolicyStatus(status) {
			if (status && status.state === 'error') return common.setPill(policyPill, _('Policy error'), 'bad');
			var active = applied && (status ? status.state === 'ok' : statusData.state === 'ok');
			common.setPill(policyPill, active ? _('Applied') : _('Prepared'), active ? 'good' : 'warn');
		}
		function markPolicyPrepared() { common.setPill(policyPill, _('Prepared'), 'warn'); }
		policySelectionChanged = markPolicyPrepared;
		updatePolicyStatus(null);

		var serviceResult = common.inlineResult();
		var serviceCatalog = E('div');
		var serviceEditor = E('div', { 'class':'ikev2-service-editor', 'style':'display:none;' });
		var serviceId = E('input', { 'class':'cbi-input-text', 'type':'text', 'placeholder':'my_service' });
		var serviceName = E('input', { 'class':'cbi-input-text', 'type':'text', 'placeholder':_('My service') });
		var serviceDomains = E('textarea', { 'class':'cbi-input-textarea ikev2-domain-editor', 'spellcheck':'false', 'placeholder':'example.com\nstatic.example.com' });
		var serviceCidrs = E('textarea', { 'class':'cbi-input-textarea ikev2-domain-editor ikev2-domain-editor-small', 'spellcheck':'false', 'placeholder':'203.0.113.0/24' });
		var serviceEditorTitle = E('h3');
		var servicePicker = E('select', { 'class':'cbi-input-select' });
		var servicePickerRow = E('div', { 'class':'ikev2-form-grid ikev2-service-picker' }, [ common.fieldLabel(_('Service to edit'), _('Choose a service to inspect or edit.')), servicePicker ]);
		var serviceSave = E('button', { 'class':'cbi-button cbi-button-apply', 'type':'button' }, [ _('Save service') ]);
		var serviceReset = E('button', { 'class':'cbi-button cbi-button-reset', 'type':'button' }, [ _('Restore prepared service') ]);
		var serviceDelete = E('button', { 'class':'cbi-button cbi-button-negative', 'type':'button' }, [ _('Delete service') ]);
		var serviceCancel = E('button', { 'class':'cbi-button', 'type':'button' }, [ _('Cancel') ]);
		var editingService = null, serviceLoadSequence = 0, serviceBusy = false, serviceDirty = false;
		var manageServicesButton, addServiceButton, saveBtn;
		var serviceFields = [ serviceId, serviceName, serviceDomains, serviceCidrs ];
		serviceFields.forEach(function(field) { field.addEventListener('input', function() { serviceDirty = true; }); field.addEventListener('change', function() { serviceDirty = true; }); });

		function serviceEditorVisible() { return serviceEditor.style.display !== 'none'; }
		function confirmDiscardServiceChanges() { return !serviceEditorVisible() || !serviceDirty || window.confirm(_('Discard unsaved service changes?')); }
		function recordById(id) { for (var i=0;i<serviceRecords.length;i++) if (serviceRecords[i].id === id) return serviceRecords[i]; return null; }
		function setServiceControlsBusy(busy, activeButton) {
			serviceBusy = busy;
			serviceFields.forEach(function(field) { field.disabled = readOnly || busy || (field === serviceId && !!editingService); });
			[ serviceSave,serviceReset,serviceDelete,serviceCancel,manageServicesButton,addServiceButton,saveBtn ].forEach(function(button) {
				if (!button || button === activeButton) return;
				button.disabled = (readOnly && button !== manageServicesButton && button !== serviceCancel) || busy;
			});
			servicePicker.disabled = busy;
			var chips = serviceCatalog.querySelectorAll('input.ikev2-community-service');
			for (var i=0;i<chips.length;i++) chips[i].disabled = readOnly || busy;
		}
		function runPageAction(options) {
			if (serviceBusy || readOnly) return Promise.resolve(null);
			setServiceControlsBusy(true, options.button);
			return common.runAction(options).finally(function() { setServiceControlsBusy(false, options.button); });
		}
		function runServiceAction(button, busyLabel, operation) {
			if (serviceBusy || readOnly) return Promise.resolve(null);
			common.setBusy(button, true, busyLabel); setServiceControlsBusy(true, button); serviceResult.busy(busyLabel);
			return Promise.resolve().then(operation).catch(function(error) { serviceResult.err(error.message || _('Service update failed')); return null; })
				.finally(function() { setServiceControlsBusy(false, button); common.setBusy(button, false); });
		}
		function renderCatalog() {
			while (serviceCatalog.firstChild) serviceCatalog.removeChild(serviceCatalog.firstChild);
			var nodes = renderServiceGroups(serviceRecords, serviceSelection, readOnly);
			if (!nodes.length) nodes.push(E('p', { 'class':'alert-message warning' }, [ _('The service catalog is unavailable. Saved selections and local services are preserved.') ]));
			nodes.forEach(function(node) { serviceCatalog.appendChild(node); });
		}
		function refreshServicePicker() {
			var current = servicePicker.value;
			var records = serviceRecords.slice().sort(function(a,b) { return (a.label || serviceLabel(a.id)).localeCompare(b.label || serviceLabel(b.id)); });
			while (servicePicker.firstChild) servicePicker.removeChild(servicePicker.firstChild);
			records.forEach(function(record) { servicePicker.appendChild(E('option', { 'value':record.id }, [ record.label && record.label !== record.id ? record.label : serviceLabel(record.id) ])); });
			if (recordById(current)) servicePicker.value = current; else if (editingService && recordById(editingService.id)) servicePicker.value = editingService.id;
		}
		function refreshServiceRecords() {
			return common.execChecked(helper, [ 'services' ], _('Unable to refresh the service catalog')).then(function(response) { serviceRecords = parseServiceRecords(response.stdout || ''); refreshServicePicker(); });
		}
		function showServiceEditor(record, details) {
			editingService = record || null; serviceEditorTitle.textContent = record ? _('Edit service') : _('New service');
			servicePickerRow.style.display = record ? '' : 'none'; if (record) servicePicker.value = record.id;
			serviceId.value = record ? record.id : ''; serviceName.value = details ? (details.label === record.id ? serviceLabel(record.id) : details.label) : '';
			serviceDomains.value = details ? details.domains.replace(/\n$/, '') : ''; serviceCidrs.value = details ? details.cidrs.replace(/\n$/, '') : '';
			serviceReset.style.display = record && record.origin !== 'custom' && record.customized === '1' ? '' : 'none';
			serviceDelete.style.display = record && record.origin === 'custom' ? '' : 'none';
			serviceEditor.style.display = ''; serviceDirty = false; serviceResult.clear(); setServiceControlsBusy(false, null);
			if (!readOnly) (record ? serviceName : serviceId).focus();
		}
		function openService(record, sourceButton) {
			if (serviceBusy) return Promise.resolve(null);
			var sequence = ++serviceLoadSequence; if (sourceButton) common.setBusy(sourceButton, true, _('Loading service...'));
			setServiceControlsBusy(true, sourceButton); serviceResult.busy(_('Loading service...'));
			return common.execChecked(helper, [ 'service-read', record.id ], _('Unable to load service')).then(function(response) {
				if (sequence === serviceLoadSequence) showServiceEditor(record, parseServiceDetails(response.stdout || ''));
			}, function(error) { if (sequence === serviceLoadSequence) serviceResult.err(error.message); }).finally(function() {
				setServiceControlsBusy(false, sourceButton); if (sourceButton) common.setBusy(sourceButton, false);
			});
		}
		function requestService(record, sourceButton) {
			if (!record || serviceBusy) return Promise.resolve(null);
			if (serviceEditorVisible() && editingService && editingService.id === record.id) { serviceEditor.scrollIntoView({ block:'nearest' }); if (!readOnly) serviceName.focus(); return Promise.resolve(record); }
			if (!confirmDiscardServiceChanges()) { if (editingService) servicePicker.value = editingService.id; return Promise.resolve(null); }
			serviceDirty = false; return openService(record, sourceButton);
		}
		function serviceMeta(operation,id,label) { return 'operation='+operation+'\nid='+id+'\nlabel='+label+'\nselected='+(operation==='delete'?'0':'keep')+'\n'; }
		function reconcileServiceRecord(operation, previous, id, label, hasCidrs) {
			serviceRecords = serviceRecords.filter(function(record) { return record.id !== id; });
			if (operation === 'delete') return;
			if (operation === 'reset') { serviceRecords.push({ id:id,label:id,origin:'builtin',customized:'0',ip:previous&&previous.ip==='1'?'1':'0' }); return; }
			serviceRecords.push({ id:id,label:label,origin:previous&&previous.origin==='custom'?'custom':(previous?'override':'custom'),customized:'1',ip:hasCidrs?'1':'0' });
		}
		function runServiceOperation(operation) {
			var id=(serviceId.value||'').trim().toLowerCase(), label=(serviceName.value||'').trim(), previous=editingService, domains=[], cidrs=[];
			if (!/^[a-z0-9_]{2,48}$/.test(id)) return Promise.reject(new Error(_('Service identifier must contain 2–48 lowercase letters, digits or underscores.')));
			if (!editingService && recordById(id)) return Promise.reject(new Error(_('A service with this identifier already exists.')));
			if (operation === 'save') {
				if (!label || label.length > 80 || /[|\r\n]/.test(label)) return Promise.reject(new Error(_('Enter a service name up to 80 characters.')));
				try { domains=normalizeDomains(serviceDomains.value); cidrs=normalizeAddresses(serviceCidrs.value); } catch(error) { return Promise.reject(error); }
				if (!domains.length && !cidrs.length) return Promise.reject(new Error(_('Add at least one domain or IPv4 network.')));
			}
			var token=common.inputToken(), prefix='/tmp/ikev2-site-link-service-input-'+token;
			return Promise.all([ fs.write(prefix+'.meta',serviceMeta(operation,id,label),384), fs.write(prefix+'.domains',domains.join('\n')+(domains.length?'\n':''),384), fs.write(prefix+'.cidrs',cidrs.join('\n')+(cidrs.length?'\n':''),384) ])
				.then(function(){return common.execChecked(helper,[ 'service-schedule',token ],_('Unable to start service update'));})
				.then(function(response){var actionId=parseStatus(response.stdout||'').action_id;if(!actionId)throw new Error(_('Action did not start'));return pollStatus(actionId,Date.now()+120000,function(status){if(status.message)serviceResult.busy(_(status.message));});})
				.then(function(status){if(!status)throw new Error(_('The operation is still running in the background.'));if(status.state!=='ok')throw new Error(status.message||_('Service update failed'));if(operation==='delete')delete serviceSelection[id];return refreshServiceRecords().then(function(){return true;},function(){return false;});})
				.then(function(refreshed){if(!refreshed){reconcileServiceRecord(operation,previous,id,label,cidrs.length>0);refreshServicePicker();}serviceEditor.style.display='none';serviceDirty=false;renderCatalog();var success=operation==='delete'?_('Custom service deleted and policy rebuilt.'):(operation==='reset'?_('Prepared service restored and policy rebuilt.'):_('Service saved. Active policy was rebuilt when required.'));if(refreshed)serviceResult.ok(success);else serviceResult.warn(success+' '+_('Reload the page to refresh the service catalog.'));});
		}

		serviceSave.addEventListener('click',function(){return runServiceAction(serviceSave,_('Saving service...'),function(){return runServiceOperation('save');});});
		serviceReset.addEventListener('click',function(){if(!window.confirm(_('Discard this local override and restore the prepared service?')))return;return runServiceAction(serviceReset,_('Restoring service...'),function(){return runServiceOperation('reset');});});
		serviceDelete.addEventListener('click',function(){if(!window.confirm(_('Delete this custom service?')))return;return runServiceAction(serviceDelete,_('Deleting service...'),function(){return runServiceOperation('delete');});});
		serviceCancel.addEventListener('click',function(){if(serviceBusy||!confirmDiscardServiceChanges())return;serviceLoadSequence++;serviceEditor.style.display='none';serviceDirty=false;serviceResult.clear();});
		servicePicker.addEventListener('change',function(){var record=recordById(servicePicker.value);if(record)requestService(record,null);});
		addServiceButton=E('button',{'class':'cbi-button cbi-button-action','type':'button','disabled':readOnly?'':null},[_('Add service')]);
		addServiceButton.addEventListener('click',function(){if(readOnly||serviceBusy||!confirmDiscardServiceChanges())return;serviceLoadSequence++;showServiceEditor(null,null);});
		serviceEditor.appendChild(E('div',{'class':'ikev2-service-editor-heading'},[serviceEditorTitle,addServiceButton]));
		serviceEditor.appendChild(servicePickerRow);
		serviceEditor.appendChild(E('div',{'class':'ikev2-form-grid'},[common.fieldLabel(_('Identifier'),_('Stable internal name; it cannot be changed after creation.')),serviceId,common.fieldLabel(_('Service name')),serviceName,common.fieldLabel(_('Domain suffixes'),_('One domain suffix per line. Subdomains are included automatically.')),serviceDomains,common.fieldLabel(_('IPv4 addresses and networks'),_('Optional; one IPv4 address or CIDR per line.')),serviceCidrs]));
		serviceEditor.appendChild(E('div',{'class':'ikev2-actions end'},[serviceCancel,serviceReset,serviceDelete,serviceSave]));
		manageServicesButton=E('button',{'class':'cbi-button cbi-button-action ikev2-icon-button','type':'button'},[common.icon('settings'),E('span',{},[_('Manage services')])]);
		manageServicesButton.addEventListener('click',function(){var record=recordById(servicePicker.value)||serviceRecords[0];if(record)requestService(record,manageServicesButton);else if(!readOnly)showServiceEditor(null,null);});
		refreshServicePicker();renderCatalog();setServiceControlsBusy(false,null);

		var domainBox=E('textarea',{'id':'ikev2-domain-list','class':'cbi-input-textarea ikev2-domain-editor','spellcheck':'false','disabled':readOnly?'':null},[manual]);
		var addressBox=E('textarea',{'id':'ikev2-address-list','class':'cbi-input-textarea ikev2-domain-editor','spellcheck':'false','disabled':readOnly?'':null,'placeholder':'203.0.113.10\n198.51.100.0/24'},[manualAddresses]);
		domainBox.addEventListener('input', markPolicyPrepared);
		addressBox.addEventListener('input', markPolicyPrepared);
		var domainsContent=E('div',{},[
			readOnly?E('div',{'class':'alert-message warning ikev2-readonly-notice'},[_('Policies are applied only on the source router. This router is configured as the exit; settings are read-only.')]):'',
			common.section(_('Services'),_('Prepared and user-created services stay in separate lists. Chips stage policy selection; the page Save button applies it. Service definitions are managed independently.'),E('div',{},[serviceCatalog,serviceEditor,serviceResult.node,E('pre',{'id':'ikev2-status-line','class':'ikev2-status-box','style':statusText?'':'display:none;'},[statusText])]),E('div',{'class':'ikev2-actions'},[manageServicesButton])),
			E('div',{'class':'ikev2-destination-editors'},[
				common.section(_('Custom domains'),_('One plain domain per line. Custom entries are never overwritten by service updates.'),domainBox),
				common.section(_('Custom IP addresses and networks'),_('One IPv4 address or CIDR network per line. A single address is stored as /32.'),addressBox)
			])
		]);
		var saveResult=common.inlineResult();
		saveBtn=E('button',{'class':'cbi-button cbi-button-apply','type':'button','disabled':readOnly?'':null},[_('Save')]);
		saveBtn.addEventListener('click',function(){return runPageAction({button:saveBtn,result:saveResult,busy:_('Saving...'),run:function(){return self.doSave(saveResult,updatePolicyStatus);}});});

		return E([common.styles(),E('div',{'class':'ikev2-page'},[
			common.header(_('Policy Routing'),_('Select services and destinations that must use the monitored Site Link. Matching traffic remains fail-closed while the tunnel is unavailable.'),readOnly?common.pill(_('Read-only on the exit router'),'warn'):policyPill),
			domainsContent,E('div',{'class':'ikev2-actions end','style':'margin-top:1.1rem'},[saveResult.node,saveBtn])
		])]);
	},
	handleSave:null,handleSaveApply:null,handleReset:null
});
