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
.ikev2-page .cbi-map{margin-top:1rem}
.ikev2-page .cbi-section{border:1px solid var(--ikev2-border);border-radius:var(--ikev2-radius);background:var(--ikev2-surface);box-shadow:var(--ikev2-shadow);padding:1rem 1.15rem;margin:0}
.ikev2-page .cbi-section h3{font-size:1.05rem;margin:.1rem 0 .8rem}
.ikev2-page .cbi-value{border-bottom-color:var(--ikev2-border);padding:.45rem 0}
.ikev2-page .cbi-value:last-child{border-bottom:0}
/* Descriptions are guidance, not body copy: keep them quiet and compact. */
.ikev2-page .cbi-value-description{font-size:.78rem;line-height:1.45;color:var(--ikev2-muted);margin-top:.25rem}
/* Two columns on wide screens: this page has few, short sections and should not
   run the whole length of the viewport. Columns rather than a grid, because the
   sections differ a lot in height — a grid row is as tall as its tallest cell
   and leaves a hole beside it, while columns let the short sections stack. */
@media(min-width:1000px){
.ikev2-page .cbi-map{column-count:2;column-gap:1rem}
.ikev2-page .cbi-map>.cbi-section{break-inside:avoid;-webkit-column-break-inside:avoid;page-break-inside:avoid;display:inline-block;width:100%;margin:0 0 1rem}
}
/* Buttons follow the shared look: rounded, gradient for the primary action. */
.ikev2-page .cbi-button{border-radius:var(--ikev2-radius-sm);padding:.5rem 1rem;border:1px solid var(--ikev2-border);background:var(--ikev2-surface-2);font-weight:620;line-height:1.2;cursor:pointer;transition:transform .12s ease,box-shadow .14s ease,background .14s ease,border-color .14s ease,filter .14s ease}
.ikev2-page .cbi-button:hover{background:color-mix(in srgb,currentColor 12%,transparent);border-color:var(--ikev2-border-strong);transform:translateY(-1px)}
.ikev2-page .cbi-button:active{transform:translateY(0)}
.ikev2-page .cbi-button-apply,.ikev2-page .cbi-button-positive,.ikev2-page .cbi-button-save{background-image:var(--ikev2-grad);border-color:transparent;color:#fff;box-shadow:0 8px 20px -10px var(--ikev2-accent)}
.ikev2-page .cbi-button-apply:hover,.ikev2-page .cbi-button-positive:hover,.ikev2-page .cbi-button-save:hover{filter:brightness(1.06);background-image:var(--ikev2-grad)}
.ikev2-page .cbi-button-action{border-color:color-mix(in srgb,var(--ikev2-accent) 45%,var(--ikev2-border));color:var(--ikev2-accent)}
.ikev2-page button[disabled]{opacity:.55;cursor:wait;transform:none}
/* Action bar: the secret field and the two operations that use it. */
.ikev2-actions{display:flex;flex-wrap:wrap;align-items:flex-end;gap:.75rem;margin-top:.35rem}
.ikev2-actions .ikev2-field{display:flex;flex-direction:column;gap:.3rem;min-width:16rem;max-width:24rem;flex:1 1 16rem}
.ikev2-actions label{font-size:.78rem;font-weight:650;color:var(--ikev2-muted)}
.ikev2-actions input{height:2.15rem;padding:0 .6rem;border:1px solid var(--ikev2-border);border-radius:var(--ikev2-radius-sm);background:var(--ikev2-surface);width:100%}
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
