'use strict';
'require baseclass';

var STYLE_ID = 'ikev2-site-link-styles';
var CSS = `
.ikev2-page {
	--ikev2-accent:#4f7dff; --ikev2-accent-2:#8b5cf6;
	--ikev2-grad:linear-gradient(135deg,#4f7dff,#8b5cf6);
	--ikev2-border:rgba(128,128,128,.22); --ikev2-border-strong:rgba(128,128,128,.34);
	--ikev2-surface:rgba(128,128,128,.06); --ikev2-surface-2:rgba(128,128,128,.11);
	--ikev2-muted:rgba(128,128,128,.85); --ikev2-good:#16a34a;
	--ikev2-warn:#d97706; --ikev2-bad:#e11d48; --ikev2-info:#2f6fbe;
	--ikev2-radius:16px; --ikev2-radius-sm:11px;
	--ikev2-shadow:0 1px 2px rgba(0,0,0,.05),0 10px 30px -18px rgba(0,0,0,.45);
	max-width:1220px;
}
.ikev2-page *{box-sizing:border-box}
.ikev2-header{display:flex;align-items:flex-start;justify-content:space-between;gap:1.25rem;margin:0 0 1.35rem}
.ikev2-header h2{margin:0 0 .35rem;font-size:clamp(1.45rem,2.6vw,1.85rem);font-weight:750;letter-spacing:-.015em}
.ikev2-subtitle{margin:0;max-width:780px;color:var(--ikev2-muted);line-height:1.55}
.ikev2-hero{display:grid;grid-template-columns:minmax(0,1.6fr) minmax(15rem,.75fr);gap:1.25rem;margin:0 0 1rem;padding:1.35rem 1.45rem;border:1px solid var(--ikev2-border);border-radius:var(--ikev2-radius);background:radial-gradient(120% 140% at 0 0,color-mix(in srgb,var(--ikev2-accent) 18%,transparent),transparent 55%),radial-gradient(120% 160% at 100% 0,color-mix(in srgb,var(--ikev2-accent-2) 16%,transparent),transparent 55%),var(--ikev2-surface);box-shadow:var(--ikev2-shadow)}
.ikev2-hero h3{margin:0 0 .4rem;font-size:1.3rem;font-weight:720}.ikev2-hero p{margin:0;color:var(--ikev2-muted);line-height:1.55}
.ikev2-hero-side{display:flex;align-items:center;justify-content:flex-end;gap:.65rem;flex-wrap:wrap}
.ikev2-grid{display:grid;grid-template-columns:repeat(12,minmax(0,1fr));gap:1rem;margin:1rem 0}
.ikev2-card{grid-column:span 3;min-width:0;position:relative;overflow:hidden;padding:1.05rem 1.1rem;border:1px solid var(--ikev2-border);border-radius:var(--ikev2-radius);background:var(--ikev2-surface);box-shadow:var(--ikev2-shadow)}
.ikev2-card:before{content:"";position:absolute;inset:0 0 auto;height:3px;background:var(--ikev2-grad);opacity:.35}
.ikev2-card-label{margin-bottom:.5rem;font-size:.72rem;font-weight:650;letter-spacing:.07em;text-transform:uppercase;color:var(--ikev2-muted)}
.ikev2-card-value{min-height:1.8rem;font-size:clamp(1.25rem,2.2vw,1.55rem);font-weight:740;line-height:1.15;overflow-wrap:anywhere}
.ikev2-card-detail{margin-top:.5rem;font-size:.84rem;line-height:1.5;color:var(--ikev2-muted);overflow-wrap:anywhere}
.ikev2-pill{display:inline-flex;align-items:center;gap:.35rem;padding:.28rem .62rem;border:1px solid var(--ikev2-border);border-radius:999px;background:var(--ikev2-surface);font-size:.78rem;font-weight:650;white-space:nowrap}
.ikev2-pill:before{content:"";width:.45rem;height:.45rem;border-radius:50%;background:currentColor}
.ikev2-pill.good{color:var(--ikev2-good)}.ikev2-pill.warn{color:var(--ikev2-warn)}.ikev2-pill.bad{color:var(--ikev2-bad)}.ikev2-pill.info{color:var(--ikev2-info)}
.ikev2-page .cbi-map{margin-top:1rem}.ikev2-page .cbi-section{border:1px solid var(--ikev2-border);border-radius:var(--ikev2-radius);background:var(--ikev2-surface);box-shadow:var(--ikev2-shadow);padding:1rem 1.15rem}
.ikev2-page .cbi-section h3{font-size:1.1rem;margin:.2rem 0 .9rem}.ikev2-page .cbi-value{border-bottom-color:var(--ikev2-border)}
.ikev2-page .cbi-button{border-radius:999px!important}.ikev2-page .cbi-button-apply{background:var(--ikev2-grad)!important;border:0!important}
@media(max-width:900px){.ikev2-card{grid-column:span 6}.ikev2-hero{grid-template-columns:1fr}.ikev2-hero-side{justify-content:flex-start}}
@media(max-width:560px){.ikev2-header{display:block}.ikev2-card{grid-column:1/-1}.ikev2-grid{gap:.7rem}.ikev2-hero{padding:1.1rem}}
`;

function styles() {
	if (typeof document === 'undefined')
		return '';
	if (!document.getElementById(STYLE_ID))
		document.head.appendChild(E('style', { 'id': STYLE_ID }, [ CSS ]));
	return document.createDocumentFragment();
}

function pill(text, tone) {
	return E('span', { 'class': 'ikev2-pill ' + (tone || 'neutral') }, [ text ]);
}

function card(label, value, detail) {
	return E('div', { 'class': 'ikev2-card' }, [
		E('div', { 'class': 'ikev2-card-label' }, [ label ]),
		E('div', { 'class': 'ikev2-card-value' }, [ value ]),
		E('div', { 'class': 'ikev2-card-detail' }, [ detail || '—' ])
	]);
}

return baseclass.extend({
	styles: styles,
	pill: pill,
	card: card
});
