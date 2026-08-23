#!/bin/sh

set -eu
root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
policy="$root/luci/policy.js"
shared="$root/luci/shared.js"

fail() {
	printf 'policy UI contract failed: %s\n' "$1" >&2
	exit 1
}

# The prepared catalog keeps the canonical category order and a distinct
# trailing group for user-created definitions.
categories="$(sed -n '/^var SERVICE_CATEGORIES = \[/,/^\];/p' "$policy")"
previous=0
for title in 'AI' 'Social & messaging' 'Video & music' 'Games & stores' \
	'Infrastructure (broad — use with care)'; do
	line="$(printf '%s\n' "$categories" | grep -n "title:'$title'" | cut -d: -f1)"
	[ -n "$line" ] || fail "missing service category: $title"
	[ "$line" -gt "$previous" ] || fail "service category order changed: $title"
	previous="$line"
done
grep -Fq "record.origin === 'custom'" "$policy" || fail 'custom service group missing'
grep -Fq "class':'ikev2-community-service'" "$policy" || fail 'selection chips missing'
grep -Fq "common.icon('warning')" "$policy" || fail 'broad service SVG marker missing'
grep -Fq "common.icon('network')" "$policy" || fail 'IP-network SVG marker missing'
if grep -Eq '⚠|⚙|🔧|🛠' "$policy"; then
	fail 'emoji or Unicode control icon found'
fi

# Chip changes only mutate staged page state. The only policy application is
# the main Save path that writes all three inputs before schedule.
chip_handler="$(sed -n "/input.addEventListener('change'/,/^\t});/p" "$policy")"
printf '%s\n' "$chip_handler" | grep -Fq 'serviceSelection[name]' || fail 'chip selection is not staged'
if printf '%s\n' "$chip_handler" | grep -Eq "schedule|service-schedule|fs\.write"; then
	fail 'chip selection applies policy immediately'
fi
grep -Fq "prefix + '.services', selectedValue" "$policy" || fail 'main Save does not publish staged services'
grep -Fq "[ 'schedule', token ]" "$policy" || fail 'main Save does not schedule detached rebuild'

# Service definition lifecycle matches the reference editor and preserves the
# independently staged selection for save/reset.
for operation in save reset delete; do
	grep -Fq "operation === '$operation'" "$policy" || fail "missing $operation service operation"
done
grep -Fq "selected='+(operation==='delete'?'0':'keep')" "$policy" || fail 'service edit changes selection'
grep -Fq "[ 'service-schedule',token ]" "$policy" || fail 'service operations are not detached'
grep -Fq "refreshServiceRecords()" "$policy" || fail 'catalog is not refreshed in place'
grep -Fq "reconcileServiceRecord(" "$policy" || fail 'catalog refresh fallback missing'
grep -Fq "Restore prepared service" "$policy" || fail 'prepared reset action missing'
grep -Fq "record.origin === 'custom'" "$policy" || fail 'custom-only delete contract missing'

# Dirty editor navigation is guarded, while save/reset/delete use the exact
# split validation errors from the canonical implementation.
grep -Fq 'serviceDirty = true' "$policy" || fail 'dirty tracking missing'
grep -Fq "window.confirm(_('Discard unsaved service changes?'))" "$policy" || fail 'dirty confirmation missing'
grep -Fq 'Service identifier must contain 2–48 lowercase letters, digits or underscores.' "$policy" || fail 'identifier validation missing'
grep -Fq 'Enter a service name up to 80 characters.' "$policy" || fail 'name validation missing'
grep -Fq 'Add at least one domain or IPv4 network.' "$policy" || fail 'empty service validation missing'

# Saving and service actions update the existing DOM. A page reload is allowed
# only in shared.js for an explicit language change, never in the policy page.
if grep -Fq 'window.location.reload' "$policy"; then
	fail 'policy action reloads the page'
fi
grep -Fq 'updateStatusLine(status)' "$policy" || fail 'inline status refresh missing'
grep -Fq 'renderCatalog()' "$policy" || fail 'in-place chip refresh missing'

# All action paths restore their controls after success, rejection or timeout.
grep -Fq "if(!status)throw new Error(_('The operation is still running in the background.'))" "$policy" || fail 'service timeout path missing'
grep -Fq '.finally(function() { setServiceControlsBusy(false, button); common.setBusy(button, false); });' "$policy" || fail 'service busy cleanup missing'
grep -Fq '.finally(function() { setServiceControlsBusy(false, options.button); });' "$policy" || fail 'page busy cleanup missing'
grep -Fq ".finally(function(){setBusy(options.button,false);});" "$shared" || fail 'shared busy cleanup missing'

# Exercise the shared action lifecycle rather than relying only on source
# inspection: success, rejection and a timeout-shaped result must all restore
# the original label, disabled state and aria-busy marker.
node - "$shared" <<'NODE'
const fsNode = require('fs');
const source = fsNode.readFileSync(process.argv[2], 'utf8');
const document = {
  documentElement: { lang: 'en' },
  getElementById: () => null,
  head: { appendChild: () => {} },
  createDocumentFragment: () => ({})
};
const window = { localStorage: { getItem: () => 'en' }, setTimeout };
function E(tag, attrs, children) {
  return { tagName: String(tag).replace(/[^a-z]/gi, ''), dataset: {}, disabled: false,
    innerHTML: children ? String(children[0] || '') : '', textContent: children ? String(children[0] || '') : '',
    style: {}, setAttribute(k, v) { this[k] = v; }, removeAttribute(k) { delete this[k]; } };
}
const common = new Function('window', 'document', 'L', 'baseclass', 'fs', 'E', source)(
  window, document, {}, { extend: value => value }, { exec: () => Promise.resolve({ code: 0 }) }, E);
async function exercise(run) {
  const button = E('button', {}, [ 'Save' ]);
  button.innerHTML = '<svg></svg><span>Save</span>';
  await common.runAction({ button, run });
  if (button.disabled || button['aria-busy'] || button.innerHTML !== '<svg></svg><span>Save</span>')
    throw new Error('busy state was not restored');
}
(async () => {
  await exercise(() => Promise.resolve('ok'));
  await exercise(() => Promise.reject(new Error('failed')));
  await exercise(() => Promise.resolve({ state: 'timeout' }));
})().catch(error => { console.error(error.message); process.exit(1); });
NODE

# Exit role remains inspectable, but every mutating control and field is
# disabled. Manage and Cancel remain available because they do not mutate.
grep -Fq "var readOnly = candidateRole !== 'source' || (applied && appliedRole !== 'source')" "$policy" || fail 'candidate/applied exit role detection missing'
grep -Fq "common.setPill(policyPill, active ? _('Applied') : _('Prepared')" "$policy" || fail 'prepared/applied policy state missing'
grep -Fq "'disabled':readOnly ? '' : null" "$policy" || fail 'read-only fields missing'
grep -Fq "chips[i].disabled = readOnly || busy" "$policy" || fail 'read-only chips missing'
grep -Fq "if (serviceBusy || readOnly)" "$policy" || fail 'mutation guard missing'
grep -Fq 'settings are read-only.' "$policy" || fail 'exit read-only notice missing'

# The shared translator is module-local, has required Russian strings and does
# not replace LuCI's global translator.
grep -Fq "var _ = common.t;" "$policy" || fail 'module-local translator missing'
if grep -Eq 'window\._[[:space:]]*=' "$policy" "$shared"; then
	fail 'window._ is assigned'
fi
for russian in 'Маршрутизация по правилам' 'Управление сервисами' \
	'Пользовательские домены' 'Восстановить готовый сервис' 'Только чтение'; do
	grep -Fq "$russian" "$shared" || fail "missing Russian string: $russian"
done

# Services span the page. Destination editors are equal columns on desktop and
# collapse to one column at the same breakpoint as the canonical editor.
grep -Fq "common.section(_('Services')" "$policy" || fail 'full-width Services section missing'
grep -Fq '.ikev2-destination-editors{display:grid;grid-template-columns:repeat(2,minmax(0,1fr))' "$shared" || fail 'desktop two-column layout missing'
grep -Fq '.ikev2-destination-editors{grid-template-columns:1fr}' "$shared" || fail 'mobile stacked layout missing'
grep -Fq "E('div',{'class':'ikev2-actions end','style':'margin-top:1.1rem'},[saveResult.node,saveBtn])" "$policy" || fail 'single bottom Save bar missing'

printf 'policy UI tests OK\n'
