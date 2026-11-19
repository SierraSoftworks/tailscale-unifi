/*
 * Adds a "Tailscale" card to UniFi Network's VPN settings card list and shows
 * the Tailscale panel (an iframe) over the content pane when it is selected.
 *
 * UniFi's class names are generated per build, so none are used here. The
 * card list is located through its /settings/vpn/<name> links, the content
 * pane by its position next to the list, and the theme from
 * body[data-theme]. The card itself is a copy of one of UniFi's cards.
 *
 * UniFi's own elements are not moved or removed. Our elements carry a
 * data-tsui attribute. While the panel is open, data-tsui-dim attributes on
 * the card UniFi has highlighted remove that highlight; they are cleared when
 * the panel closes.
 *
 * If the page does not look as expected, nothing is added. If the added card
 * renders at an unexpected size or errors repeat, everything is removed and
 * the script stays off for the rest of the browser session.
 *
 * ?tsui=off disables it in a browser, ?tsui=on re-enables it.
 */
(function () {
  'use strict';

  var VERSION = '2';
  // The backend replaces this marker according to TAILSCALE_UI_REQUIRE_OPTIN.
  var REQUIRE_OPT_IN = /*TSUI_REQUIRE_OPT_IN*/false;

  var w = window, doc = document;
  if (w.__tailscaleUnifiUI) return;

  function log() {
    try {
      var a = Array.prototype.slice.call(arguments);
      a.unshift('[tailscale-unifi]');
      w.console.debug.apply(w.console, a);
    } catch (e) { /* ignore */ }
  }
  function store(kind, op, key, val) {
    try {
      var s = kind === 'session' ? w.sessionStorage : w.localStorage;
      if (op === 'get') return s.getItem(key);
      if (op === 'set') s.setItem(key, val);
      if (op === 'del') s.removeItem(key);
    } catch (e) { /* storage blocked */ }
    return null;
  }

  // Switches
  try {
    var qs = w.location.search || '';
    if (/[?&]tsui=off(&|$)/.test(qs)) { store('local', 'set', 'tsui.disabled', '1'); store('local', 'del', 'tsui.optin'); }
    if (/[?&]tsui=on(&|$)/.test(qs)) { store('local', 'del', 'tsui.disabled'); store('local', 'set', 'tsui.optin', '1'); store('session', 'del', 'tsui.tripped'); }
  } catch (e) { /* ignore */ }
  if (store('local', 'get', 'tsui.disabled') === '1') { log('disabled (?tsui=on re-enables)'); return; }
  if (REQUIRE_OPT_IN && store('local', 'get', 'tsui.optin') !== '1') { log('opt-in required: add ?tsui=on to the URL'); return; }
  if (store('session', 'get', 'tsui.tripped')) { log('switched off for this session:', store('session', 'get', 'tsui.tripped')); return; }

  var BASE = (function () {
    try {
      var src = doc.currentScript && doc.currentScript.src;
      if (src) return new URL('.', src).pathname;
    } catch (e) { /* ignore */ }
    return '/proxy/tailscale-unifi/';
  })();

  var VPN_PAGE = /^\/network\/[^/]+\/.*settings\/vpn(\/|$)/;
  var CARD_LINK = /\/settings\/vpn\/([a-z0-9][a-z0-9-]*)\/?$/;
  var HASH = '#tailscale';
  var ATTR = 'data-tsui';
  var DIM = 'data-tsui-dim';
  var LABEL = 'Tailscale';
  var CAPTION = 'Connect this gateway to your Tailscale network.';
  var DIAGRAM_END = 'Tailnet';

  var stopped = false, errors = 0, timer = null, why = 'not run yet';
  var st = {
    card: null, cardVariant: '', overlay: null, frame: null, style: null,
    dimmed: [], dimFor: null, pane: null, ro: null, lastTheme: ''
  };

  function trip(reason) {
    log('switching off:', reason);
    store('session', 'set', 'tsui.tripped', String(reason).slice(0, 200));
    shutdown();
  }
  function guard(fn) {
    return function () {
      if (stopped) return undefined;
      try {
        return fn.apply(this, arguments);
      } catch (e) {
        errors++;
        log('error', e);
        if (errors >= 3) trip('repeated errors: ' + (e && e.message));
        return undefined;
      }
    };
  }

  function own(el) {
    for (; el; el = el.parentNode) if (el.nodeType === 1 && el.hasAttribute(ATTR)) return true;
    return false;
  }
  function linkSlug(a) {
    try {
      var m = CARD_LINK.exec(new URL(a.getAttribute('href'), w.location.href).pathname);
      return m ? m[1] : null;
    } catch (e) { return null; }
  }
  function pageSlug() {
    var m = CARD_LINK.exec(w.location.pathname);
    return m ? m[1] : null;
  }
  function rect(el) { return el.getBoundingClientRect(); }

  // Discovery

  // Card links: <a> elements pointing at /settings/vpn/<slug>.
  function cardLinks() {
    var out = [], all = doc.querySelectorAll('a[href*="/settings/vpn/"]');
    for (var i = 0; i < all.length && i < 300; i++) {
      if (!own(all[i]) && linkSlug(all[i])) out.push(all[i]);
    }
    return out;
  }

  // The card list: an element with at least 3 children that each contain one
  // card link, all to different pages. Returns {list, cards: [{el, slug, link}]}.
  function findCards() {
    var links = cardLinks();
    if (links.length < 3) { why = 'only ' + links.length + ' VPN links on the page'; return null; }
    var best = null;
    var seen = [];
    for (var i = 0; i < links.length; i++) {
      var el = links[i];
      for (var depth = 0; depth < 10 && el.parentElement && el.parentElement !== doc.body; depth++) {
        var list = el.parentElement;
        if (seen.indexOf(list) < 0) {
          seen.push(list);
          var cards = [], slugs = {}, ok = true;
          var kids = list.children;
          if (kids.length <= 16) {
            for (var k = 0; k < kids.length; k++) {
              if (own(kids[k])) continue;
              var inside = links.filter(function (l) { return kids[k].contains(l); });
              if (inside.length === 1) {
                var slug = linkSlug(inside[0]);
                if (slugs[slug]) { ok = false; break; }
                slugs[slug] = 1;
                cards.push({ el: kids[k], slug: slug, link: inside[0] });
              } else if (inside.length > 1) {
                ok = false; break;
              }
            }
            if (ok && cards.length >= 3 && cards.length <= 12 && (!best || cards.length > best.cards.length)) {
              best = { list: list, cards: cards };
            }
          }
        }
        el = list;
      }
    }
    if (!best) { why = 'no card list found (' + links.length + ' VPN links)'; return null; }
    // Sanity: cards must be small, visible, stacked blocks of similar width.
    var w0 = rect(best.cards[0].el).width;
    for (var c = 0; c < best.cards.length; c++) {
      var r = rect(best.cards[c].el);
      var n = best.cards[c].el.getElementsByTagName('*').length;
      if (r.height < 24 || r.height > 400 || r.width < 120 || Math.abs(r.width - w0) > 40 || n > 400) {
        why = 'card "' + best.cards[c].slug + '" failed the size check (' + Math.round(r.width) + 'x' + Math.round(r.height) + ', ' + n + ' elements)';
        return null;
      }
    }
    why = 'ok';
    return best;
  }

  // The content pane: a large element to the right of the card column that
  // shares an ancestor with it.
  function findPane(list) {
    var col = list, colRect = rect(list);
    for (var depth = 0; depth < 8 && col.parentElement && col.parentElement !== doc.body; depth++) {
      var parent = col.parentElement, kids = parent.children;
      for (var i = 0; i < kids.length; i++) {
        if (kids[i] === col || own(kids[i])) continue;
        var r = rect(kids[i]);
        if (r.left >= colRect.right - 4 && r.width >= 320 && r.height >= 200 &&
            r.top < colRect.bottom && r.bottom > colRect.top) {
          return kids[i];
        }
      }
      col = parent;
    }
    return null;
  }

  function theme() {
    var b = doc.body;
    var t = (b.getAttribute('data-theme') || b.getAttribute('motif-theme') || '').toLowerCase();
    if (t.indexOf('dark') >= 0) return 'dark';
    if (t.indexOf('light') >= 0) return 'light';
    var m = /rgba?\((\d+),\s*(\d+),\s*(\d+)/.exec(w.getComputedStyle(b).backgroundColor || '');
    return m && (0.2126 * m[1] + 0.7152 * m[2] + 0.0722 * m[3]) < 128 ? 'dark' : 'light';
  }
  function solidBackground(el) {
    for (; el && el.nodeType === 1; el = el.parentElement) {
      var c = w.getComputedStyle(el).backgroundColor;
      if (c && c !== 'transparent' && !/rgba\([^)]*,\s*0\)$/.test(c)) return c;
    }
    return '';
  }

  // Our card

  function leafTextElements(root, exclude) {
    var out = [], els = root.querySelectorAll('*');
    for (var i = 0; i < els.length; i++) {
      var el = els[i];
      if (exclude && exclude.contains(el)) continue;
      var direct = '';
      for (var n = el.firstChild; n; n = n.nextSibling) if (n.nodeType === 3) direct += n.nodeValue;
      if (direct.trim()) out.push(el);
    }
    return out;
  }

  function buildCard(template, active) {
    var clone = template.el.cloneNode(true);
    clone.setAttribute(ATTR, 'card');
    var all = [clone].concat(Array.prototype.slice.call(clone.querySelectorAll('*')));
    if (all.length > 400) return null;
    for (var i = 0; i < all.length; i++) {
      ['id', 'data-testid', 'aria-current', 'aria-selected', 'aria-controls', 'aria-describedby', 'aria-labelledby'].forEach(function (a) { all[i].removeAttribute(a); });
    }

    // The main link: same position as the template's card link.
    var links = clone.querySelectorAll('a[href]');
    var main = null;
    for (var l = 0; l < links.length; l++) if (linkSlug(links[l]) === template.slug) { main = links[l]; break; }
    if (!main) return null;
    main.setAttribute('href', w.location.pathname + HASH);
    main.removeAttribute('target');

    // Other links (e.g. "SD-WAN" in the caption) become plain text.
    for (var o = 0; o < links.length; o++) {
      if (links[o] !== main && links[o].parentNode) {
        links[o].parentNode.replaceChild(doc.createTextNode(links[o].textContent), links[o]);
      }
    }

    // Title: the text inside the main link.
    var walker = doc.createTreeWalker(main, NodeFilter.SHOW_TEXT, null);
    var titled = false;
    while (walker.nextNode()) {
      if (!walker.currentNode.nodeValue.trim()) continue;
      walker.currentNode.nodeValue = titled ? '' : LABEL;
      titled = true;
    }
    if (!titled) return null;

    // Caption: the longest text block outside the title; diagram labels: the rest.
    var texts = leafTextElements(clone, main);
    if (texts.length) {
      var caption = texts.reduce(function (a, b) { return b.textContent.length > a.textContent.length ? b : a; });
      caption.textContent = CAPTION;
      var labels = texts.filter(function (t) { return t !== caption && !caption.contains(t) && !t.contains(caption); });
      if (labels.length >= 2) labels[labels.length - 1].textContent = DIAGRAM_END;
    }
    clone.setAttribute(ATTR + '-variant', active ? 'active' : 'inactive');
    return clone;
  }

  function pickTemplates(found) {
    var current = pageSlug();
    var active = null, bySlug = {}, first = null;
    found.cards.forEach(function (c) {
      if (c.slug === current) active = c;
      else {
        bySlug[c.slug] = c;
        first = first || c;
      }
    });
    // Prefer Site-to-Site as the template (its diagram reads "Gateway <-> 3rd
    // Party Gateway"), then VPN Client (also has a diagram), then any card.
    return {
      inactive: bySlug['site-to-site'] || bySlug.client || first,
      active: active,
      last: found.cards[found.cards.length - 1]
    };
  }

  function placeCard(found, viewOn) {
    var tpl = pickTemplates(found);
    var variant = viewOn && tpl.active ? 'active' : 'inactive';
    if (st.card && st.card.isConnected && st.cardVariant === variant && st.card.parentNode === found.list) return;

    var template = variant === 'active' ? tpl.active : tpl.inactive;
    if (!template) return;
    var card = buildCard(template, variant === 'active');
    if (!card) { trip('could not build a card from UniFi\'s card template'); return; }
    card.addEventListener('click', guard(onCardClick));
    card.addEventListener('keydown', guard(function (ev) {
      if (ev.key === 'Enter' || ev.key === ' ') onCardClick(ev);
      ev.stopPropagation();
    }));

    if (st.card && st.card.parentNode) st.card.parentNode.removeChild(st.card);
    found.list.insertBefore(card, tpl.last.el.nextSibling);
    st.card = card;
    st.cardVariant = variant;

    // Post-check: our card must render like a UniFi card.
    var r = rect(card), tr = rect(template.el);
    if (r.height < tr.height * 0.5 || r.height > tr.height * 1.6 + 8 || Math.abs(r.width - tr.width) > 24) {
      trip('inserted card renders unexpectedly (' + Math.round(r.width) + 'x' + Math.round(r.height) +
        ' vs ' + Math.round(tr.width) + 'x' + Math.round(tr.height) + ')');
    }
  }

  function onCardClick(ev) {
    ev.preventDefault();
    ev.stopPropagation();
    if (w.location.hash !== HASH) {
      // Keep React Router's history state so its own navigation stays consistent.
      w.history.pushState(w.history.state, '', w.location.pathname + w.location.search + HASH);
    }
    update();
  }

  // Un-highlighting UniFi's active card while our view is open

  // Compare the highlighted card with a plain one, element by element, and
  // override the colours that differ (attributes plus our own stylesheet).
  // Elements only the highlighted card has, such as the connector to the
  // pane, are hidden.
  var DIM_PROPS = ['background-color', 'border-top-color', 'border-right-color', 'border-bottom-color', 'border-left-color', 'box-shadow', 'outline-color'];

  function dimActive(active, inactive) {
    undim();
    if (!active || !inactive) return;
    var rules = [], n = 0;
    (function walk(a, b, depth) {
      if (depth > 6 || n > 60) return;
      var ca = w.getComputedStyle(a), cb = w.getComputedStyle(b), decl = [];
      DIM_PROPS.forEach(function (p) {
        var va = ca.getPropertyValue(p), vb = cb.getPropertyValue(p);
        if (va !== vb) decl.push(p + ':' + vb + ' !important');
      });
      if (decl.length) {
        a.setAttribute(DIM, String(++n));
        st.dimmed.push(a);
        rules.push('[' + DIM + '="' + n + '"]{' + decl.join(';') + '}');
      }
      var ka = a.children, kb = b.children;
      for (var i = 0; i < ka.length; i++) {
        if (i < kb.length && ka[i].tagName === kb[i].tagName) {
          walk(ka[i], kb[i], depth + 1);
        } else if (depth === 0) {
          ka[i].setAttribute(DIM, 'x');
          st.dimmed.push(ka[i]);
        }
      }
    })(active.el, inactive.el, 0);
    rules.push('[' + DIM + '="x"]{visibility:hidden !important}');
    st.style = doc.createElement('style');
    st.style.setAttribute(ATTR, 'style');
    st.style.textContent = rules.join('\n');
    doc.head.appendChild(st.style);
  }

  function undim() {
    st.dimFor = null;
    st.dimmed.forEach(function (el) { el.removeAttribute(DIM); });
    st.dimmed = [];
    if (st.style && st.style.parentNode) st.style.parentNode.removeChild(st.style);
    st.style = null;
  }

  // The panel overlay

  function showOverlay(pane) {
    if (!st.overlay || !st.overlay.isConnected) {
      var host = doc.createElement('div');
      host.setAttribute(ATTR, 'panel');
      host.style.cssText = 'position:fixed;z-index:20;margin:0;padding:0;border:0;box-sizing:border-box;display:block;';
      var f = doc.createElement('iframe');
      f.title = 'Tailscale';
      f.src = BASE + '?embed=pane&theme=' + theme();
      f.style.cssText = 'display:block;width:100%;height:100%;border:0;background:transparent;';
      f.addEventListener('load', guard(function () { postTheme(true); }));
      host.appendChild(f);
      doc.body.appendChild(host);
      st.overlay = host;
      st.frame = f;
    }
    if (st.pane !== pane) {
      if (st.ro) st.ro.disconnect();
      st.pane = pane;
      if (w.ResizeObserver) {
        st.ro = new w.ResizeObserver(guard(positionOverlay));
        st.ro.observe(pane);
      }
    }
    positionOverlay();
    postTheme(false);
  }

  function positionOverlay() {
    if (!st.overlay || !st.pane) return;
    var r = rect(st.pane);
    if (r.width < 200 || r.height < 120) { st.overlay.style.display = 'none'; return; }
    var s = st.overlay.style;
    s.display = 'block';
    s.left = r.left + 'px';
    s.top = r.top + 'px';
    s.width = r.width + 'px';
    s.height = r.height + 'px';
    s.background = solidBackground(st.pane) || solidBackground(doc.body) || 'transparent';
  }

  function postTheme(force) {
    var t = theme();
    if (!st.frame || !st.frame.contentWindow || (!force && t === st.lastTheme)) return;
    st.lastTheme = t;
    st.frame.contentWindow.postMessage({
      type: 'tsui:theme', dark: t === 'dark',
      font: w.getComputedStyle(doc.body).fontFamily || ''
    }, w.location.origin);
  }

  function hideOverlay() {
    if (st.ro) st.ro.disconnect();
    st.ro = null;
    st.pane = null;
    if (st.overlay && st.overlay.parentNode) st.overlay.parentNode.removeChild(st.overlay);
    st.overlay = st.frame = null;
  }

  // Main loop

  function removeAll() {
    hideOverlay();
    undim();
    if (st.card && st.card.parentNode) st.card.parentNode.removeChild(st.card);
    st.card = null;
    st.cardVariant = '';
  }

  var update = guard(function () {
    if (doc.visibilityState === 'hidden') return;
    if (!VPN_PAGE.test(w.location.pathname)) { why = 'not a VPN settings page'; if (st.card || st.overlay) removeAll(); return; }

    var found = findCards();
    if (!found) { if (st.card || st.overlay) removeAll(); return; }

    var viewOn = w.location.hash === HASH;
    var pane = viewOn ? findPane(found.list) : null;
    if (viewOn && !pane) viewOn = false; // no safe place for the panel: just show the card

    placeCard(found, viewOn);
    if (stopped) return;

    if (viewOn) {
      var tpl = pickTemplates(found);
      if (tpl.active && st.dimFor !== tpl.active.el) {
        dimActive(tpl.active, found.cards.filter(function (c) { return c !== tpl.active; })[0]);
        st.dimFor = tpl.active.el;
      }
      showOverlay(pane);
    } else {
      undim();
      hideOverlay();
    }
  });

  var onMessage = guard(function (ev) {
    if (!st.frame || ev.source !== st.frame.contentWindow || ev.origin !== w.location.origin) return;
    if (ev.data && ev.data.type === 'tsui:theme-request') postTheme(true);
  });

  function shutdown() {
    stopped = true;
    if (timer) clearInterval(timer);
    timer = null;
    try { w.removeEventListener('message', onMessage); } catch (e) { /* ignore */ }
    try { w.removeEventListener('popstate', update); w.removeEventListener('hashchange', update); w.removeEventListener('resize', update); } catch (e) { /* ignore */ }
    try { removeAll(); } catch (e) { /* ignore */ }
  }

  w.__tailscaleUnifiUI = {
    version: VERSION,
    disable: function () { store('local', 'set', 'tsui.disabled', '1'); shutdown(); },
    status: function () { return { stopped: stopped, errors: errors, card: !!st.card, overlay: !!st.overlay, why: why, tripped: store('session', 'get', 'tsui.tripped') }; }
  };

  w.addEventListener('message', onMessage);
  w.addEventListener('popstate', update);
  w.addEventListener('hashchange', update);
  w.addEventListener('resize', update);
  timer = setInterval(update, 500);
  log('loaded', VERSION);
})();
