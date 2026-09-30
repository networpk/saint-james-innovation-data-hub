/*
 * Saint James – attribúció-átadó script a lassjol.hu-ra (szülő oldal).
 * Tedd be Google Tag Managerbe (Custom HTML, <script> tagek közé) vagy közvetlenül az oldalra,
 * minden oldalon, ahol az időpontfoglaló/kvíz iframe megjelenhet.
 *
 * Mit csinál:
 *  1. Első betöltéskor elmenti az UTM-eket és click ID-kat (first-touch + last-touch).
 *  2. Az iframe src-jéhez hozzáfűzi őket (a_* előtaggal), és postMessage-szel is átadja.
 *  3. Válaszol az iframe "sj-attribution-request" kérésére (csak engedélyezett origin-nek).
 *
 * Nem küld semmit sehova, csak az iframe-nek ad át adatot. Nem ír Pixelt, nem kezel egészségügyi adatot.
 * A GA4 client_id csak akkor kerül át, ha a _ga süti már létezik (vagyis az analitikai hozzájárulás megvolt).
 */
(function () {
  "use strict";

  var CFG = {
    // TODO: a foglaló app valódi origin-je (pl. https://idopont.lassjol.hu) – enélkül nem fut semmi.
    bookingOrigins: ["https://REPLACE_BOOKING_ORIGIN"],
    storageKey: "sj_attr_v1",
    maxAgeDays: 90,
    paramKeys: [
      "utm_source", "utm_medium", "utm_campaign", "utm_content", "utm_term",
      "fbclid", "gclid", "wbraid", "gbraid", "ttclid",
    ],
  };

  if (CFG.bookingOrigins[0].indexOf("REPLACE_") !== -1) return;

  function read() {
    try { return JSON.parse(localStorage.getItem(CFG.storageKey) || "null"); } catch (e) { return null; }
  }
  function write(v) {
    try { localStorage.setItem(CFG.storageKey, JSON.stringify(v)); } catch (e) { /* privát mód */ }
  }

  function currentParams() {
    var out = {}, q = new URLSearchParams(location.search), any = false;
    CFG.paramKeys.forEach(function (k) {
      var v = q.get(k);
      if (v) { out[k] = v.slice(0, 200); any = true; }
    });
    return any ? out : null;
  }

  function externalReferrer() {
    try {
      if (!document.referrer) return "";
      var h = new URL(document.referrer).hostname;
      return h === location.hostname ? "" : document.referrer.slice(0, 300);
    } catch (e) { return ""; }
  }

  function gaClientId() {
    var m = document.cookie.match(/(?:^|;\s*)_ga=GA\d\.\d\.(\d+\.\d+)/);
    return m ? m[1] : "";
  }

  function touch(params) {
    return { params: params || {}, referrer: externalReferrer(), landing: location.href.split("#")[0].slice(0, 300), ts: new Date().toISOString() };
  }

  // --- állapot frissítése (first-touch megmarad, last-touch csak marketing paraméteres látogatásnál változik) ---
  var now = Date.now(), state = read();
  var expired = state && state.savedAt && now - state.savedAt > CFG.maxAgeDays * 864e5;
  var params = currentParams();
  if (!state || expired) {
    state = { first: touch(params), last: touch(params), savedAt: now };
  } else if (params) {
    state.last = touch(params);
  }
  write(state);

  function payload() {
    return {
      type: "sj-attribution", v: 1,
      first: state.first, last: state.last,
      ga_client_id: gaClientId(),
      parent_host: location.hostname,
    };
  }

  // --- 1) iframe src kiegészítése (a_* paraméterek: az utolsó marketing-érintés, ennek hiányában az első) ---
  function effective() {
    var l = state.last.params || {}, f = state.first.params || {};
    return Object.keys(l).length ? l : f;
  }
  function decorate(iframe) {
    try {
      var u = new URL(iframe.src, location.href);
      if (CFG.bookingOrigins.indexOf(u.origin) === -1 || u.searchParams.has("a_done")) return;
      var eff = effective();
      Object.keys(eff).forEach(function (k) { u.searchParams.set("a_" + k, eff[k]); });
      var cid = gaClientId();
      if (cid) u.searchParams.set("a_ga_cid", cid);
      u.searchParams.set("a_host", location.hostname);
      u.searchParams.set("a_done", "1");
      iframe.src = u.toString();
    } catch (e) { /* ignore */ }
  }

  // --- 2) postMessage ---
  function send(iframe) {
    try {
      var origin = new URL(iframe.src, location.href).origin;
      if (CFG.bookingOrigins.indexOf(origin) === -1) return;
      iframe.contentWindow.postMessage(payload(), origin);
    } catch (e) { /* ignore */ }
  }

  function bookingIframes() {
    return Array.prototype.filter.call(document.getElementsByTagName("iframe"), function (f) {
      try { return CFG.bookingOrigins.indexOf(new URL(f.src, location.href).origin) !== -1; } catch (e) { return false; }
    });
  }

  function handle(iframe) {
    if (iframe.__sjAttr) return;
    iframe.__sjAttr = true;
    iframe.addEventListener("load", function () { send(iframe); });
  }

  // --- 3) az iframe kéréseire válasz (kizárólag engedélyezett origin-ből) ---
  window.addEventListener("message", function (ev) {
    if (CFG.bookingOrigins.indexOf(ev.origin) === -1) return;
    if (!ev.data || ev.data.type !== "sj-attribution-request") return;
    if (ev.source && ev.source.postMessage) ev.source.postMessage(payload(), ev.origin);
  });

  function scan() { bookingIframes().forEach(function (f) { decorate(f); handle(f); }); }
  scan();
  new MutationObserver(scan).observe(document.documentElement, { childList: true, subtree: true });
})();
