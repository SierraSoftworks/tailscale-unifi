/* Tailscale panel for UniFi OS. Plain JS without dependencies or a build step.
 * Text is inserted with textContent rather than innerHTML because peer names
 * come from other devices. */
(function () {
  'use strict';

  var params = new URLSearchParams(location.search);
  var MODE = params.get('embed') || '';   // '' standalone, '1' auto-height embed, 'pane' fills a fixed pane
  var EMBED = MODE !== '';
  var app = document.getElementById('app');

  // Theme
  function applyTheme(dark, font) {
    document.documentElement.setAttribute('data-theme', dark ? 'dark' : 'light');
    if (font) document.documentElement.style.setProperty('--font', font + ', Inter, -apple-system, "Segoe UI", Roboto, sans-serif');
  }
  if (params.get('theme')) {
    applyTheme(params.get('theme') === 'dark');
  } else {
    applyTheme(window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches);
  }
  document.body.classList.add(MODE === 'pane' ? 'pane' : EMBED ? 'embed' : 'standalone');

  if (EMBED && window.parent !== window) {
    window.addEventListener('message', function (ev) {
      if (ev.source !== window.parent || ev.origin !== location.origin) return;
      var d = ev.data;
      if (d && d.type === 'tsui:theme') applyTheme(!!d.dark, typeof d.font === 'string' ? d.font : '');
    });
    var postHeight = function () {
      var hgt = Math.ceil(document.documentElement.getBoundingClientRect().height);
      window.parent.postMessage({ type: 'tsui:height', height: hgt }, location.origin);
    };
    if (MODE !== 'pane') {
      if (window.ResizeObserver) new ResizeObserver(postHeight).observe(document.documentElement);
      window.addEventListener('load', postHeight);
    }
    window.parent.postMessage({ type: 'tsui:theme-request' }, location.origin);
  }

  // Tiny DOM helper
  function h(tag, attrs) {
    var el = document.createElement(tag);
    if (attrs) {
      Object.keys(attrs).forEach(function (k) {
        var v = attrs[k];
        if (v === undefined || v === null || v === false) return;
        if (k === 'class') el.className = v;
        else if (k === 'text') el.textContent = v;
        else if (k.slice(0, 2) === 'on') el.addEventListener(k.slice(2), v);
        else if (k === 'value') el.value = v;
        else if (k === 'checked' || k === 'disabled' || k === 'selected') el[k] = !!v;
        else el.setAttribute(k, v === true ? '' : v);
      });
    }
    for (var i = 2; i < arguments.length; i++) append(el, arguments[i]);
    return el;
  }
  function append(el, c) {
    if (c === null || c === undefined || c === false) return;
    if (Array.isArray(c)) { c.forEach(function (x) { append(el, x); }); return; }
    el.appendChild(typeof c === 'string' || typeof c === 'number' ? document.createTextNode(String(c)) : c);
  }
  function svg(path) {
    var ns = 'http://www.w3.org/2000/svg';
    var s = document.createElementNS(ns, 'svg');
    s.setAttribute('viewBox', '0 0 24 24'); s.setAttribute('fill', 'none');
    s.setAttribute('stroke', 'currentColor'); s.setAttribute('stroke-width', '2');
    s.setAttribute('stroke-linecap', 'round'); s.setAttribute('stroke-linejoin', 'round');
    s.setAttribute('aria-hidden', 'true');
    var p = document.createElementNS(ns, 'path'); p.setAttribute('d', path); s.appendChild(p);
    return s;
  }
  var ICON_REFRESH = 'M21 12a9 9 0 1 1-2.64-6.36M21 3v6h-6';
  function logo() {
    var ns = 'http://www.w3.org/2000/svg';
    var s = document.createElementNS(ns, 'svg');
    s.setAttribute('viewBox', '0 0 24 24'); s.setAttribute('class', 'logo'); s.setAttribute('aria-hidden', 'true');
    [[4, 4, .35], [12, 4, .35], [20, 4, .35], [4, 12, 1], [12, 12, 1], [20, 12, 1], [4, 20, .35], [12, 20, 1], [20, 20, .35]].forEach(function (d) {
      var c = document.createElementNS(ns, 'circle');
      c.setAttribute('cx', d[0]); c.setAttribute('cy', d[1]); c.setAttribute('r', '2.6');
      c.setAttribute('fill', 'currentColor'); c.setAttribute('opacity', d[2]); s.appendChild(c);
    });
    return s;
  }

  // API
  function api(path, body) {
    var opts = { credentials: 'same-origin', headers: { Accept: 'application/json' } };
    if (body !== undefined) {
      opts.method = 'POST';
      opts.headers['Content-Type'] = 'application/json';
      opts.headers['X-TSUI-Request'] = '1';
      opts.body = JSON.stringify(body);
    }
    return fetch(path, opts).then(function (r) {
      return r.text().then(function (t) {
        var data = null;
        try { data = t ? JSON.parse(t) : null; } catch (e) { /* not JSON */ }
        if (!r.ok) {
          var err = new Error((data && data.error) || ('Request failed (' + r.status + ')'));
          err.status = r.status;
          throw err;
        }
        return data;
      });
    });
  }

  // State
  var S = {
    state: null,
    error: null,
    loading: false,
    draft: null,        // editable copy of prefs
    saving: false,
    formError: '',
    formOK: '',
    confirm: null,      // {action, title, text}
    actionError: '',
    filter: '',
    routeInput: '',
    routeError: ''
  };
  var pollTimer = null;

  function clone(o) { return JSON.parse(JSON.stringify(o)); }

  function load(manual) {
    if (S.loading) return Promise.resolve();
    S.loading = true;
    if (manual) render();
    return api('api/state').then(function (st) {
      var prev = S.state;
      S.state = st;
      S.error = null;
      // Keep the user's unsaved edits; otherwise follow the device.
      if (!S.draft || !isDirty(prev)) S.draft = st.prefs ? clone(st.prefs) : null;
    }).catch(function (e) {
      S.error = e;
    }).then(function () {
      S.loading = false;
      render();
      schedule();
    });
  }

  function schedule() {
    clearTimeout(pollTimer);
    var running = S.state && S.state.job && S.state.job.running;
    var delay = running ? 1500 : 10000;
    pollTimer = setTimeout(function () {
      if (document.visibilityState === 'hidden') { schedule(); return; }
      load(false);
    }, delay);
  }
  document.addEventListener('visibilitychange', function () {
    if (document.visibilityState === 'visible') load(false);
  });

  function isDirty(prevState) {
    var base = (prevState || S.state) && (prevState || S.state).prefs;
    if (!base || !S.draft) return false;
    return Object.keys(diff(base, S.draft)).length > 0;
  }

  var EDITABLE = ['hostname', 'acceptRoutes', 'acceptDNS', 'advertiseRoutes', 'advertiseExitNode', 'exitNode',
    'exitNodeAllowLANAccess', 'ssh', 'shieldsUp', 'snatSubnetRoutes', 'webClient', 'autoUpdate'];

  function diff(a, b) {
    var out = {};
    EDITABLE.forEach(function (k) {
      var x = a[k], y = b[k];
      if (Array.isArray(x) || Array.isArray(y)) {
        if (JSON.stringify((x || []).slice().sort()) !== JSON.stringify((y || []).slice().sort())) out[k] = y || [];
      } else if ((x || '') !== (y || '') && !(x === false && y === false)) {
        out[k] = y;
      }
    });
    return out;
  }

  // Actions
  var ACTION_LABELS = {
    connect: 'Connect', disconnect: 'Disconnect', login: 'Log in', logout: 'Log out',
    restart: 'Restart Tailscale', start: 'Start Tailscale', update: 'Update Tailscale',
    install: 'Install Tailscale', netcheck: 'Network diagnostics'
  };
  // These run outside the panel (systemd-run) and cannot be cancelled.
  var DETACHED = { update: true, install: true, restart: true, start: true };
  var CONFIRM = {
    disconnect: 'Devices that reach this network through Tailscale will lose access until you reconnect. If you are using Tailscale to view this page, you will be disconnected.',
    logout: 'This removes the device from your tailnet. You will need to log in again, and subnet routes and the exit node will stop working.',
    restart: 'Tailscale will be unavailable for a few seconds. If you are using Tailscale to view this page, the connection will drop briefly.',
    update: 'Tailscale will be upgraded with apt and restarted. Connections over Tailscale will drop briefly.'
  };

  function runAction(action, confirmed) {
    if (CONFIRM[action] && !confirmed) {
      S.confirm = { action: action };
      render();
      return;
    }
    S.confirm = null;
    S.actionError = '';
    api('api/action', { action: action }).then(function (res) {
      if (S.state) S.state.job = res.job;
      render();
      setTimeout(function () { load(false); }, 600);
    }).catch(function (e) {
      S.actionError = e.message;
      render();
    });
  }

  function cancelJob() {
    api('api/job/cancel', {}).then(function () { load(false); }).catch(function (e) {
      S.actionError = e.message; render();
    });
  }

  function saveSettings() {
    var ch = diff(S.state.prefs, S.draft);
    if (!Object.keys(ch).length) return;
    S.saving = true; S.formError = ''; S.formOK = '';
    render();
    api('api/prefs', ch).then(function (st) {
      S.state = st;
      S.draft = st.prefs ? clone(st.prefs) : null;
      S.formOK = 'Settings applied.';
      setTimeout(function () { if (S.formOK) { S.formOK = ''; render(); } }, 4000);
    }).catch(function (e) {
      S.formError = e.message;
    }).then(function () {
      S.saving = false;
      render();
    });
  }

  function setPackageAutoUpdate(v) {
    api('api/package', { autoUpdate: v }).then(function (st) {
      S.state = st; render();
    }).catch(function (e) { S.formError = e.message; render(); });
  }

  // Formatting
  function bytes(n) {
    if (!n) return '0 B';
    var u = ['B', 'KB', 'MB', 'GB', 'TB'], i = 0;
    while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
    return (n >= 10 || i === 0 ? Math.round(n) : n.toFixed(1)) + ' ' + u[i];
  }
  function ago(iso) {
    if (!iso || iso.indexOf('0001-') === 0) return '';
    var t = Date.parse(iso);
    if (isNaN(t)) return '';
    var s = Math.max(0, (Date.now() - t) / 1000);
    if (s < 60) return 'just now';
    if (s < 3600) return Math.floor(s / 60) + ' min ago';
    if (s < 86400) return Math.floor(s / 3600) + ' h ago';
    return Math.floor(s / 86400) + ' d ago';
  }
  function copyable(text) {
    return h('span', {
      class: 'copy', title: 'Click to copy', text: text,
      onclick: function () { try { navigator.clipboard.writeText(text); } catch (e) { /* ignore */ } }
    });
  }

  var STATES = {
    Running: ['Connected', 'ok'],
    Stopped: ['Disconnected', ''],
    Starting: ['Connecting', 'info'],
    NeedsLogin: ['Needs login', 'warn'],
    NeedsMachineAuth: ['Awaiting approval', 'warn'],
    NoState: ['Starting', 'info'],
    NotInstalled: ['Not installed', ''],
    DaemonDown: ['Service stopped', 'bad'],
    Unavailable: ['Unavailable', 'bad'],
    InUseOtherUser: ['In use by another user', 'warn']
  };

  // Rendering
  function render() {
    var focus = document.activeElement && document.activeElement.getAttribute('data-key');
    var sel = null;
    if (focus && document.activeElement.selectionStart !== undefined) {
      try { sel = [document.activeElement.selectionStart, document.activeElement.selectionEnd]; } catch (e) { /* ignore */ }
    }

    var nodes = [];
    if (S.error && !S.state) {
      nodes.push(renderFatal());
    } else if (!S.state) {
      nodes.push(h('div', { class: 'boot', text: 'Loading' }));
    } else {
      nodes.push(renderOverview());
      if (S.state.job && (S.state.job.running || recent(S.state.job))) nodes.push(renderJob());
      if (S.state.prefs && S.draft) nodes.push(renderSettings());
      if (S.state.self || S.state.peers.length) nodes.push(renderDevices());
    }
    app.replaceChildren.apply(app, nodes);

    if (focus) {
      var el = app.querySelector('[data-key="' + focus + '"]');
      if (el) {
        el.focus();
        if (sel && el.setSelectionRange) try { el.setSelectionRange(sel[0], sel[1]); } catch (e) { /* ignore */ }
      }
    }
  }

  function recent(job) {
    if (!job.finished) return true;
    return Date.now() - Date.parse(job.finished) < 5 * 60 * 1000;
  }

  function renderFatal() {
    var e = S.error;
    var msg = e.status === 401 ? 'Your UniFi OS session has expired. Sign in to UniFi OS again, then reload this page.'
      : e.status === 403 ? e.message
      : 'Could not reach the Tailscale add-on: ' + e.message;
    return h('section', { class: 'card' },
      h('div', { class: 'card-head' }, logo(), h('h2', { text: 'Tailscale' })),
      h('div', { class: 'card-body' },
        h('div', { class: 'notice bad' }, h('p', { text: msg }),
          h('button', { class: 'btn btn-secondary', onclick: function () { load(true); }, text: 'Retry' }))));
  }

  function refreshButton() {
    return h('button', {
      class: 'btn btn-secondary' + (S.loading ? ' spin' : ''), title: 'Refresh', 'aria-label': 'Refresh',
      onclick: function () { load(true); }
    }, svg(ICON_REFRESH), 'Refresh');
  }

  function renderOverview() {
    var st = S.state;
    var admin = st.user && st.user.admin;
    var info = STATES[st.backendState] || [st.backendState || 'Unknown', ''];
    var busy = st.job && st.job.running;

    var head = h('div', { class: 'card-head' },
      logo(),
      h('h2', { text: 'Tailscale' }),
      h('span', { class: 'pill ' + info[1], text: info[0] }),
      h('span', { class: 'spacer' }),
      h('span', { class: 'sub', text: S.error ? 'Refresh failed: ' + S.error.message : 'Updated ' + new Date(st.fetchedAt).toLocaleTimeString() }),
      refreshButton());

    var body = h('div', { class: 'card-body' });

    if (!admin) body.appendChild(h('div', { class: 'notice' }, h('p', { text: 'You have view-only access. Only UniFi administrators can change Tailscale.' })));
    if (st.error && st.backendState !== 'NotInstalled') body.appendChild(h('div', { class: 'notice bad' }, h('p', { text: st.error })));
    (st.health || []).forEach(function (m) {
      body.appendChild(h('div', { class: 'notice warn' }, h('p', { text: m })));
    });
    if (st.backendState === 'NeedsLogin' && st.authURL) {
      body.appendChild(h('div', { class: 'notice warn' },
        h('p', { text: 'Finish logging in to add this device to your tailnet.' }),
        h('a', { class: 'btn btn-primary', href: st.authURL, target: '_blank', rel: 'noopener noreferrer', text: 'Open login page' })));
    }
    if (st.backendState === 'NeedsMachineAuth') {
      body.appendChild(h('div', { class: 'notice warn' }, h('p', { text: 'This device is waiting for approval in the Tailscale admin console.' })));
    }

    if (S.confirm) {
      var a = S.confirm.action;
      body.appendChild(h('div', { class: 'notice warn' },
        h('p', null, h('strong', { text: ACTION_LABELS[a] + '? ' }), CONFIRM[a]),
        h('div', { class: 'btn-row' },
          h('button', { class: 'btn btn-secondary', text: 'Cancel', onclick: function () { S.confirm = null; render(); } }),
          h('button', { class: a === 'update' ? 'btn btn-primary' : 'btn btn-danger', text: ACTION_LABELS[a], onclick: function () { runAction(a, true); } }))));
    }
    if (S.actionError) body.appendChild(h('div', { class: 'notice bad' }, h('p', { text: S.actionError })));

    if (st.installed) {
      var self = st.self || {};
      var kv = h('dl', { class: 'kv' });
      var item = function (label, value) {
        if (value === undefined || value === null || value === '') return;
        kv.appendChild(h('div', null, h('dt', { text: label }), h('dd', null, value)));
      };
      item('Device name', self.name || (st.prefs && st.prefs.hostname));
      item('Tailscale IPv4', (self.ips || []).filter(function (x) { return x.indexOf(':') < 0; }).map(copyable)[0]);
      item('Tailscale IPv6', (self.ips || []).filter(function (x) { return x.indexOf(':') >= 0; }).map(copyable)[0]);
      item('MagicDNS name', self.dnsName ? copyable(self.dnsName) : '');
      item('Tailnet', st.tailnet);
      item('Account', st.loginName);
      var routes = st.prefs ? st.prefs.advertiseRoutes : [];
      item('Advertised subnets', routes && routes.length ? routes.join(', ') : 'None');
      item('Exit node', st.prefs && st.prefs.advertiseExitNode ? 'Offered by this device' : exitNodeName(st));
      item('Version', st.version ? [st.version, st.updateAvailable ? h('span', { class: 'badge', style: 'margin-left:6px', text: st.upstreamVersion + ' available' }) : (st.upstreamVersion ? h('span', { class: 'muted', text: ' (latest)' }) : '')] : '');
      item('Package auto-update', st.package.autoUpdate ? 'Daily (' + st.package.channel + ')' : 'Off');
      body.appendChild(kv);
    } else {
      body.appendChild(h('p', { class: 'muted', style: 'margin:0', text: 'Tailscale is not installed on this console.' }));
    }

    var btns = [];
    var B = function (action, cls) {
      btns.push(h('button', {
        class: 'btn ' + (cls || 'btn-secondary'), disabled: !admin || busy,
        onclick: function () { runAction(action); }, text: ACTION_LABELS[action]
      }));
    };
    var bs = st.backendState;
    if (!st.installed) B('install', 'btn-primary');
    else if (bs === 'DaemonDown') B('start', 'btn-primary');
    else {
      if (bs === 'NeedsLogin') B('login', 'btn-primary');
      if (bs === 'Stopped') B('connect', 'btn-primary');
      if (bs === 'Running' || bs === 'Starting') B('disconnect');
      if (bs === 'Running' || bs === 'Stopped' || bs === 'NeedsMachineAuth') B('logout', 'btn-danger');
      B('restart');
      if (bs === 'Running') B('netcheck');
      if (st.updateAvailable) B('update', 'btn-primary');
    }
    var foot = h('div', { class: 'card-foot' },
      h('span', { class: 'hint', text: 'tailscale-unifi ' + st.addonVersion + (st.user ? ', signed in as ' + st.user.name : '') }),
      btns);

    return h('section', { class: 'card', id: 'overview' }, head, body, foot);
  }

  function exitNodeName(st) {
    var ip = st.prefs && st.prefs.exitNode;
    if (!ip) return 'Not used';
    var p = st.peers.filter(function (x) { return x.ips.indexOf(ip) >= 0; })[0];
    return p ? 'Using ' + p.name : 'Using ' + ip;
  }

  function renderJob() {
    var j = S.state.job;
    var status = j.running ? h('span', { class: 'pill info', text: 'Running' })
      : j.ok ? h('span', { class: 'pill ok', text: 'Completed' })
      : h('span', { class: 'pill bad', text: 'Failed' + (j.error ? ': ' + j.error : '') });
    var body = h('div', { class: 'card-body' });
    if (j.action === 'login' && j.running && S.state.authURL) {
      body.appendChild(h('div', { class: 'notice' },
        h('p', { text: 'Open the Tailscale login page to authorize this device. This panel updates automatically when you are done.' }),
        h('a', { class: 'btn btn-primary', href: S.state.authURL, target: '_blank', rel: 'noopener noreferrer', text: 'Open login page' })));
    }
    body.appendChild(h('pre', { class: 'output', text: (j.output || '').trim() || (j.running ? 'Working' : 'No output.') }));
    return h('section', { class: 'card', id: 'activity' },
      h('div', { class: 'card-head' },
        h('h3', { text: ACTION_LABELS[j.action] || j.action }), status, h('span', { class: 'spacer' }),
        h('span', { class: 'sub', text: (j.user ? j.user + ', ' : '') + new Date(j.started).toLocaleTimeString() }),
        j.running && S.state.user && S.state.user.admin && !DETACHED[j.action] ? h('button', { class: 'btn btn-secondary', text: 'Cancel', onclick: cancelJob }) : null),
      body);
  }

  // Settings form
  function toggleRow(key, label, desc, opts) {
    opts = opts || {};
    var admin = S.state.user && S.state.user.admin;
    var disabled = !admin || S.saving || opts.disabled;
    var id = 'f-' + key;
    return h('div', { class: 'row toggle-row' + (opts.disabled ? ' disabled' : '') },
      h('label', { for: id }, label, desc ? h('span', { class: 'desc', text: desc }) : null),
      h('div', { class: 'ctl' },
        h('label', { class: 'switch' },
          h('input', {
            type: 'checkbox', id: id, 'data-key': key, checked: !!(opts.value !== undefined ? opts.value : S.draft[key]), disabled: disabled,
            onchange: function (e) {
              if (opts.onchange) opts.onchange(e.target.checked);
              else { S.draft[key] = e.target.checked; S.formOK = ''; render(); }
            }
          }),
          h('span', { class: 'track' }))));
  }

  function renderSettings() {
    var st = S.state, d = S.draft;
    var admin = st.user && st.user.admin;
    var disabled = !admin || S.saving;
    var dirty = Object.keys(diff(st.prefs, d)).length > 0;

    var body = h('div', { class: 'card-body' });
    var rows = [];

    rows.push(h('div', { class: 'group-title', text: 'General' }));
    rows.push(h('div', { class: 'row' },
      h('label', { for: 'f-hostname' }, 'Device name', h('span', { class: 'desc', text: 'Name of this console in your tailnet. Leave empty to use the system hostname.' })),
      h('div', { class: 'ctl' }, h('input', {
        class: 'input', id: 'f-hostname', 'data-key': 'hostname', value: d.hostname || '', placeholder: (st.self && st.self.name) || 'System hostname',
        maxlength: '63', disabled: disabled, spellcheck: 'false', autocomplete: 'off',
        oninput: function (e) { d.hostname = e.target.value; S.formOK = ''; render(); }
      }))));

    rows.push(h('div', { class: 'group-title', text: 'Routing' }));
    rows.push(renderRoutesRow(disabled));
    rows.push(toggleRow('advertiseExitNode', 'Offer as exit node', 'Let other devices route all their internet traffic through this console. Must also be approved in the Tailscale admin console.'));
    rows.push(toggleRow('snatSubnetRoutes', 'Source NAT subnet traffic', 'Traffic from the tailnet to advertised subnets appears to come from this console. Turn off only if your LAN routes 100.64.0.0/10 back to this console.'));
    rows.push(toggleRow('acceptRoutes', 'Accept routes', 'Use subnet routes advertised by other devices in the tailnet.'));

    var exitPeers = st.peers.filter(function (p) { return p.exitNodeOption; });
    rows.push(h('div', { class: 'row' + (d.advertiseExitNode ? ' disabled' : '') },
      h('label', { for: 'f-exitNode' }, 'Use exit node', h('span', { class: 'desc', text: 'Send this console\'s own internet traffic through another device. LAN clients are not affected.' })),
      h('div', { class: 'ctl' }, h('select', {
        class: 'input', id: 'f-exitNode', 'data-key': 'exitNode', disabled: disabled || d.advertiseExitNode,
        onchange: function (e) { d.exitNode = e.target.value; S.formOK = ''; render(); }
      }, h('option', { value: '', text: 'None', selected: !d.exitNode }),
      exitPeers.map(function (p) {
        var ip = p.ips.filter(function (x) { return x.indexOf(':') < 0; })[0] || p.ips[0];
        return h('option', { value: ip, selected: d.exitNode === ip, text: p.name + ' (' + ip + ')' + (p.online ? '' : ', offline') });
      })))));
    rows.push(toggleRow('exitNodeAllowLANAccess', 'Allow local network access', 'While using an exit node, keep direct access to this console\'s local networks.', { disabled: !d.exitNode }));

    rows.push(h('div', { class: 'group-title', text: 'Services' }));
    rows.push(toggleRow('acceptDNS', 'Use Tailscale DNS', 'Apply the tailnet\'s DNS settings (MagicDNS) on this console. LAN clients keep using UniFi\'s DNS.'));
    rows.push(toggleRow('ssh', 'Tailscale SSH', 'Allow SSH to this console over Tailscale, authorized by your tailnet access rules.'));
    rows.push(toggleRow('webClient', 'Tailscale web interface', 'Serve Tailscale\'s own web interface on port 5252 over the tailnet.'));
    rows.push(toggleRow('shieldsUp', 'Block incoming connections', 'Shields up: refuse all incoming connections from the tailnet. Subnet routing and exit node traffic still work.'));

    rows.push(h('div', { class: 'group-title', text: 'Updates' }));
    rows.push(toggleRow('pkgAutoUpdate', 'Automatic updates', 'Check for Tailscale updates once a day and install them.', {
      value: st.package.autoUpdate, onchange: setPackageAutoUpdate
    }));
    rows.push(toggleRow('autoUpdate', 'Tailscale built-in auto-update', 'Tailscale\'s own updater. Usually not needed when automatic updates above are on.'));

    append(body, rows);
    if (S.formError) body.appendChild(h('div', { class: 'notice bad', style: 'margin:12px 0 0' }, h('p', { text: S.formError })));

    var foot = h('div', { class: 'card-foot' },
      h('span', { class: 'hint', text: S.formOK || (dirty ? 'You have unsaved changes.' : '') }),
      h('button', {
        class: 'btn btn-secondary', disabled: !dirty || S.saving, text: 'Discard',
        onclick: function () { S.draft = clone(st.prefs); S.formError = ''; S.routeError = ''; render(); }
      }),
      h('button', { class: 'btn btn-primary', disabled: !dirty || disabled, text: S.saving ? 'Applying' : 'Apply Changes', onclick: saveSettings }));

    return h('section', { class: 'card', id: 'settings' },
      h('div', { class: 'card-head' }, h('h3', { text: 'Settings' }), h('span', { class: 'sub', text: st.prefs.controlURL ? 'Control server: ' + st.prefs.controlURL.replace(/^https?:\/\//, '') : '' })),
      body, foot);
  }

  var CIDR_RE = /^(\d{1,3}\.){3}\d{1,3}\/\d{1,2}$|^[0-9a-fA-F:]+\/\d{1,3}$/;

  function renderRoutesRow(disabled) {
    var d = S.draft, st = S.state;
    var routes = d.advertiseRoutes || [];
    var chips = h('div', { class: 'chips' },
      routes.length ? routes.map(function (r) {
        return h('span', { class: 'chip' }, r, h('button', {
          type: 'button', title: 'Remove ' + r, 'aria-label': 'Remove ' + r, disabled: disabled, text: '×',
          onclick: function () { d.advertiseRoutes = routes.filter(function (x) { return x !== r; }); S.formOK = ''; render(); }
        }));
      }) : h('span', { class: 'empty', text: 'No subnets advertised.' }));

    var add = function () {
      var v = S.routeInput.trim();
      if (!v) return;
      if (!CIDR_RE.test(v)) { S.routeError = 'Use CIDR notation, for example 192.168.1.0/24.'; render(); return; }
      if (/^0\.0\.0\.0\/0$|^::\/0$/.test(v)) { S.routeError = 'Use "Offer as exit node" to route all traffic.'; render(); return; }
      if (routes.indexOf(v) < 0) d.advertiseRoutes = routes.concat([v]);
      S.routeInput = ''; S.routeError = ''; S.formOK = '';
      render();
    };
    var input = h('div', { class: 'inline' },
      h('input', {
        class: 'input' + (S.routeError ? ' invalid' : ''), 'data-key': 'route-input', placeholder: '192.168.1.0/24',
        value: S.routeInput, disabled: disabled, spellcheck: 'false', autocomplete: 'off', 'aria-label': 'Subnet to advertise',
        oninput: function (e) { S.routeInput = e.target.value; },
        onkeydown: function (e) { if (e.key === 'Enter') { e.preventDefault(); add(); } }
      }),
      h('button', { type: 'button', class: 'btn btn-secondary', disabled: disabled, text: 'Add', onclick: add }));

    var suggestions = (st.suggestedRoutes || []).filter(function (r) { return routes.indexOf(r) < 0; });
    var sugg = suggestions.length ? h('div', { class: 'chips' },
      h('span', { class: 'muted', text: 'UniFi networks:' }),
      suggestions.map(function (r) {
        return h('button', {
          type: 'button', class: 'btn btn-link', disabled: disabled, text: '+ ' + r,
          onclick: function () { d.advertiseRoutes = routes.concat([r]); S.formOK = ''; render(); }
        });
      })) : null;

    return h('div', { class: 'row' },
      h('div', { class: 'label' }, 'Advertised subnets', h('span', { class: 'desc', text: 'Make these local networks reachable from your tailnet (subnet router). New routes must be approved in the Tailscale admin console.' })),
      h('div', { class: 'ctl' }, chips, input, S.routeError ? h('span', { class: 'field-error', text: S.routeError }) : null, sugg));
  }

  // Devices table
  function renderDevices() {
    var st = S.state;
    var q = S.filter.trim().toLowerCase();
    var list = st.peers.filter(function (p) {
      if (!q) return true;
      return (p.name + ' ' + p.dnsName + ' ' + p.os + ' ' + p.ips.join(' ')).toLowerCase().indexOf(q) >= 0;
    });
    var online = st.peers.filter(function (p) { return p.online; }).length;

    var row = function (p, isSelf) {
      var badges = [];
      if (isSelf) badges.push(h('span', { class: 'badge grey', text: 'This device' }));
      if (p.exitNode) badges.push(h('span', { class: 'badge', text: 'Exit node in use' }));
      else if (p.exitNodeOption) badges.push(h('span', { class: 'badge grey', text: 'Exit node' }));
      if (p.routes && p.routes.length) badges.push(h('span', { class: 'badge grey', title: p.routes.join(', '), text: 'Subnets' }));
      if (p.expired) badges.push(h('span', { class: 'badge', style: 'background:var(--red-soft);color:var(--red)', text: 'Key expired' }));
      var ip4 = p.ips.filter(function (x) { return x.indexOf(':') < 0; })[0] || p.ips[0] || '';
      return h('tr', { class: isSelf ? 'self' : '' },
        h('td', null, h('div', null, h('strong', { text: p.name })), h('div', { class: 'muted', text: p.os || '' })),
        h('td', null, ip4 ? copyable(ip4) : ''),
        h('td', null, h('span', { class: 'dot' + (p.online ? ' on' : '') }), p.online ? 'Online' : ('Offline' + (ago(p.lastSeen) ? ', last seen ' + ago(p.lastSeen) : ''))),
        h('td', null, isSelf ? '' : (p.online ? (p.connection || '') : '')),
        h('td', { class: 'wrap' }, badges),
        h('td', { class: 'muted' }, isSelf ? '' : '↓ ' + bytes(p.rxBytes) + '  ↑ ' + bytes(p.txBytes)));
    };

    var rows = [];
    if (st.self && !q) rows.push(row(st.self, true));
    list.forEach(function (p) { rows.push(row(p, false)); });

    return h('section', { class: 'card', id: 'devices' },
      h('div', { class: 'card-head' },
        h('h3', { text: 'Devices' }),
        h('span', { class: 'sub', text: online + ' of ' + st.peers.length + ' online' }),
        h('span', { class: 'spacer' }),
        h('input', {
          class: 'input search', type: 'search', placeholder: 'Search devices', 'aria-label': 'Search devices', 'data-key': 'filter', value: S.filter,
          oninput: function (e) { S.filter = e.target.value; render(); }
        })),
      h('div', { class: 'table-wrap' },
        h('table', null,
          h('thead', null, h('tr', null, ['Name', 'Tailscale IP', 'Status', 'Connection', '', 'Traffic'].map(function (t) { return h('th', { text: t }); }))),
          h('tbody', null, rows.length ? rows : h('tr', null, h('td', { colspan: '6', class: 'muted', text: q ? 'No matching devices.' : 'No other devices in this tailnet.' }))))));
  }

  load(true);
})();
