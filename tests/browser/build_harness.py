#!/usr/bin/env python3
"""Build browser-test harnesses from a real UniFi Network DOM snapshot.

The snapshot is document.documentElement.outerHTML of the VPN settings page,
saved from a browser. Keep it in the git-ignored fixture directory; it
contains details of the network. UniFi's scripts are removed, and since
UniFi's generated CSS cannot be captured this way, a few layout rules are
added. The class names in those rules are only used by this fixture, not by
inject.js.

Usage: build_harness.py <snapshot.html> <outdir>
Writes harness-real.html and harness-restructured.html.
"""
import json
import sys
from pathlib import Path

from bs4 import BeautifulSoup, Comment, NavigableString

snapshot, outdir = Path(sys.argv[1]), Path(sys.argv[2])
html = snapshot.read_text(encoding="utf-8")

LAYOUT_CSS = """
/* test-only approximation of the uncaptured UniFi layout */
.css-network-qimdtr { display: flex; align-items: stretch; height: 820px; }
.css-network-1wus74d { width: 312px; flex: none; overflow: auto; }
.css-network-1ea3rdz { flex: 1; min-width: 420px; overflow: auto; background: #fff; }
.css-network-m4txge > div { display: block; margin: 8px; padding: 10px 12px; border: 1px solid #dfe1e4; border-radius: 8px; background: #fff; }
.css-network-m4txge > div:first-child { border: 0; padding: 0; margin: 0; }
.css-network-13on2f4 { border-color: #006fff !important; background: #eaf3ff !important; }
"""

TEST_JS = r"""
(function () {
  var results = [], out = document.getElementById('tsui-test-result');
  function check(name, ok, extra) {
    results.push((ok ? 'PASS ' : 'FAIL ') + name + (ok || !extra ? '' : ' :: ' + extra));
    out.textContent = results.join('\n');
  }
  function q(sel) { return document.querySelector(sel); }
  // Fingerprint of UniFi's DOM: everything except our own elements/attributes.
  function fingerprint() {
    var c = document.body.cloneNode(true);
    c.querySelectorAll('[data-tsui]').forEach(function (e) { e.remove(); });
    c.querySelectorAll('[data-tsui-dim]').forEach(function (e) { e.removeAttribute('data-tsui-dim'); });
    var r = c.querySelector('#tsui-test-result'); if (r) r.remove();
    return c.innerHTML;
  }
  var fp0 = fingerprint();
  var expectNone = document.body.hasAttribute('data-test-expect-none');
  window.addEventListener('error', function () { window.__errs = (window.__errs || 0) + 1; });
  var steps = [];
  function step(ms, fn) { steps.push([ms, fn]); }

  if (expectNone) {
    step(2500, function () {
      check('nothing added on a restructured page', !q('[data-tsui]') && !q('[data-tsui-dim]'));
      check('UniFi DOM unchanged', fingerprint() === fp0);
    });
  } else {
    step(2500, function () {
      var card = q('[data-tsui="card"]');
      check('card added', !!card, JSON.stringify(window.__tailscaleUnifiUI && window.__tailscaleUnifiUI.status()));
      if (!card) { steps.splice(1, steps.length - 2); return; }
      var s2s = document.querySelector('a[href="/network/default/settings/vpn/site-to-site"]');
      var s2sCard = s2s; while (s2sCard && s2sCard.parentElement !== card.parentElement) s2sCard = s2sCard.parentElement;
      check('card is directly below Site-to-Site', s2sCard && s2sCard.nextElementSibling === card);
      check('card title is Tailscale', /\bTailscale\b/.test(card.querySelector('a').textContent));
      check('card has caption', /Tailscale network/.test(card.textContent));
      check('diagram ends in Tailnet', /Tailnet/.test(card.textContent));
      check('no SD-WAN link copied', !card.querySelector('a[href*="sd-wan"]'));
      check('inactive variant', card.getAttribute('data-tsui-variant') === 'inactive');
      check('no overlay yet', !q('[data-tsui="panel"]'));
      check('no dimming yet', !q('[data-tsui-dim]'));
      check('UniFi DOM unchanged (card added)', fingerprint() === fp0);
      card.querySelector('a').click();
    });
    step(1500, function () {
      check('click sets #tailscale', location.hash === '#tailscale');
      var ov = q('[data-tsui="panel"]'), pane = document.querySelector('.css-network-1ea3rdz');
      check('overlay shown', !!ov);
      if (ov && pane) {
        var a = ov.getBoundingClientRect(), b = pane.getBoundingClientRect();
        check('overlay covers the content pane exactly', Math.abs(a.left - b.left) < 2 && Math.abs(a.top - b.top) < 2 && Math.abs(a.width - b.width) < 2 && Math.abs(a.height - b.height) < 2,
          JSON.stringify([a.left, a.top, a.width, a.height, b.left, b.top, b.width, b.height]));
        check('overlay is not inside UniFi DOM', ov.parentElement === document.body);
        check('overlay iframe uses pane mode + light theme', /embed=pane&theme=light/.test(ov.querySelector('iframe').src));
      }
      check('UniFi active card un-highlighted', !!q('[data-tsui-dim]'));
      check('our card shows as active', (q('[data-tsui="card"]') || {}).getAttribute && q('[data-tsui="card"]').getAttribute('data-tsui-variant') === 'active');
      check('UniFi DOM unchanged (view open)', fingerprint() === fp0);
      if (location.hash === '#tailscale') history.back();
    });
    step(1500, function () {
      check('back closes the panel', !q('[data-tsui="panel"]') && location.hash === '');
      check('dimming removed', !q('[data-tsui-dim]') && !q('style[data-tsui]'));
      check('card back to inactive', q('[data-tsui="card"]') && q('[data-tsui="card"]').getAttribute('data-tsui-variant') === 'inactive');
      // Simulate a React re-render that replaces the card list.
      var list = q('[data-tsui="card"]').parentElement;
      var fresh = list.cloneNode(true);
      fresh.querySelectorAll('[data-tsui]').forEach(function (e) { e.remove(); });
      list.parentElement.replaceChild(fresh, list);
      fp0 = fingerprint();
    });
    step(1500, function () {
      check('card restored after re-render', document.querySelectorAll('[data-tsui="card"]').length === 1);
      check('UniFi DOM unchanged after re-render', fingerprint() === fp0);
    });
  }
  step(10, function () {
    var st = window.__tailscaleUnifiUI && window.__tailscaleUnifiUI.status();
    check('integration not tripped', st && !st.stopped && !st.tripped, JSON.stringify(st));
    check('no page errors', !window.__errs);
    out.textContent = results.join('\n') + '\n' + (results.every(function (r) { return r.indexOf('PASS') === 0; }) ? 'ALL PASS' : 'SOME FAILED');
  });
  (function run(i) { if (i < steps.length) setTimeout(function () { steps[i][1](); run(i + 1); }, steps[i][0]); })(0);
})();
"""


def tree(node):
    """Serialise a node for DOM-API reconstruction (no HTML re-parsing)."""
    if isinstance(node, NavigableString):
        if isinstance(node, Comment):
            return None
        return str(node)
    attrs = {k: (" ".join(v) if isinstance(v, list) else v) for k, v in node.attrs.items()}
    kids = [t for t in (tree(c) for c in node.children) if t is not None]
    return [node.name, attrs, kids]


# Rebuilds <body> with createElement/createElementNS, exactly like React does.
# Re-parsing outerHTML is NOT faithful: UniFi nests <div> in <p> in <a>, which
# the HTML parser "repairs" by splitting and duplicating elements.
LOADER_JS = r"""
(function () {
  var SVG = 'http://www.w3.org/2000/svg';
  function make(t, ns) {
    if (typeof t === 'string') return document.createTextNode(t);
    var name = t[0], attrs = t[1], kids = t[2];
    var nns = name === 'svg' ? SVG : ns;
    var el = nns ? document.createElementNS(nns, name) : document.createElement(name);
    for (var k in attrs) { try { el.setAttribute(k, attrs[k]); } catch (e) {} }
    for (var i = 0; i < kids.length; i++) el.appendChild(make(kids[i], name === 'foreignObject' ? null : nns));
    return el;
  }
  var body = JSON.parse(document.getElementById('tsui-body').textContent);
  for (var k in body[1]) document.body.setAttribute(k, body[1][k]);
  var frag = document.createDocumentFragment();
  body[2].forEach(function (t) { frag.appendChild(make(t, null)); });
  document.body.insertBefore(frag, document.body.firstChild);
  var pre = document.createElement('pre'); pre.id = 'tsui-test-result'; pre.textContent = 'pending';
  document.body.appendChild(pre);
  var test = document.createElement('script'); test.textContent = document.getElementById('tsui-test').textContent;
  document.body.appendChild(test);
  var inj = document.createElement('script'); inj.src = '/inject.js';
  document.head.appendChild(inj);
})();
"""


def build(soup, title_suffix=""):
    for s in soup.find_all("script"):
        s.decompose()
    for l in soup.find_all("link", rel="stylesheet"):
        l.decompose()
    head = "".join(str(c) for c in soup.head.children)
    title = (soup.title.string if soup.title else "") + title_suffix
    if title_suffix:
        soup.body["data-test-expect-none"] = "1"
    body = json.dumps(tree(soup.body)).replace("</", "<\\/")
    test = TEST_JS.replace("</", "<\\/")
    return (
        "<!doctype html><html lang=\"en\"><head>" + head +
        "<title>" + title + "</title><style>" + LAYOUT_CSS + "</style></head><body>" +
        "<script type=\"application/json\" id=\"tsui-body\">" + body + "</script>" +
        "<script type=\"text/plain\" id=\"tsui-test\">" + test + "</script>" +
        "<script>" + LOADER_JS + "</script></body></html>"
    )


outdir.mkdir(parents=True, exist_ok=True)
(outdir / "harness-real.html").write_text(build(BeautifulSoup(html, "html.parser")), encoding="utf-8")

# A "massively restructured" UniFi: the VPN pages are no longer a card list.
soup = BeautifulSoup(html, "html.parser")
for a in soup.select('a[href*="/settings/vpn/"]'):
    p = a
    while p.parent and p.parent.name != "body" and len(p.parent.find_all("a", href=lambda h: h and "/settings/vpn/" in h)) == 1:
        p = p.parent
    p.unwrap() if p is not a else None
    a.attrs.pop("href", None)
(outdir / "harness-restructured.html").write_text(build(soup, " RESTRUCTURED"), encoding="utf-8")
print("wrote", outdir / "harness-real.html", "and", outdir / "harness-restructured.html")
