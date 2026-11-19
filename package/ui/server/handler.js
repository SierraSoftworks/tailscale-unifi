'use strict';
// HTTP routes of the panel: static files and a small JSON API. nginx proxies
// /proxy/tailscale-unifi/ to this server; API calls are checked against the
// caller's UniFi OS session.

const fs = require('fs');
const path = require('path');
const { AuthError } = require('./auth');
const { Jobs } = require('./jobs');
const { ACTIONS, ValidationError, changeToArgs } = require('./tailscale');

const STATIC = {
  '/': ['index.html', 'text/html; charset=utf-8'],
  '/inject.js': ['inject.js', 'text/javascript; charset=utf-8'],
  '/assets/app.js': ['app.js', 'text/javascript; charset=utf-8'],
  '/assets/app.css': ['app.css', 'text/css; charset=utf-8'],
};

// Replaced in inject.js according to TAILSCALE_UI_REQUIRE_OPTIN.
const OPT_IN_MARKER = '/*TSUI_REQUIRE_OPT_IN*/false';

const CSP = "default-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; " +
  "frame-ancestors 'self'; base-uri 'none'; form-action 'none'";

class HttpError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

function createHandler({ backend, auth, webDir, version = 'dev', log = console.log }) {
  const upstream = new UpstreamVersion(backend);
  const jobs = new Jobs(backend, (action) => {
    if (action === 'update' || action === 'install') upstream.invalidate();
  });

  const api = {
    'GET /api/state': async (req, user) => buildState(backend, user, jobs, upstream, version),
    'GET /api/job': async () => ({ job: jobs.snapshot() }),
    'POST /api/prefs': async (req, user, body) => {
      const isExitNode = await exitNodeCheck(backend, body);
      const args = toArgs(body, isExitNode);
      log(`user "${user.name}": tailscale set ${args.join(' ')}`);
      try {
        await backend.set(args);
      } catch (e) {
        throw new HttpError(422, e.message);
      }
      return buildState(backend, user, jobs, upstream, version);
    },
    'POST /api/action': async (req, user, body) => {
      if (!body || !(body.action in ACTIONS)) throw new HttpError(400, 'unknown action');
      log(`user "${user.name}": action ${body.action}`);
      try {
        return { status: 202, body: { job: jobs.start(body.action, user.name) } };
      } catch (e) {
        throw new HttpError(409, e.message);
      }
    },
    'POST /api/job/cancel': async () => ({ cancelled: jobs.cancel() }),
    'POST /api/package': async (req, user, body) => {
      if (!body || typeof body.autoUpdate !== 'boolean') throw new HttpError(400, 'invalid request');
      log(`user "${user.name}": package auto-update=${body.autoUpdate}`);
      backend.setPackageAutoUpdate(body.autoUpdate);
      return buildState(backend, user, jobs, upstream, version);
    },
  };

  return async function handle(req, res) {
    const url = new URL(req.url, 'http://localhost');
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('Cache-Control', 'no-store');
    res.setHeader('Referrer-Policy', 'no-referrer');
    if (url.pathname !== '/inject.js') res.setHeader('Content-Security-Policy', CSP);

    try {
      if (req.method === 'GET' && url.pathname === '/healthz') {
        return send(res, 200, 'ok\n', 'text/plain');
      }
      if (req.method === 'GET' && STATIC[url.pathname]) {
        return serveStatic(res, webDir, url.pathname, backend);
      }
      const route = api[`${req.method} ${url.pathname}`];
      if (!route) {
        const known = Object.keys(api).some((k) => k.endsWith(` ${url.pathname}`));
        throw new HttpError(known ? 405 : 404, known ? 'method not allowed' : 'not found');
      }

      const user = await authenticate(auth, req, log);
      let body;
      if (req.method === 'POST') {
        checkCSRF(req);
        if (!user.admin) throw new HttpError(403, 'only UniFi administrators can change Tailscale settings');
        body = await readJSON(req);
      }
      const result = await route(req, user, body);
      if (result && result.status) return sendJSON(res, result.status, result.body);
      return sendJSON(res, 200, result);
    } catch (e) {
      const status = e.status || (e instanceof ValidationError ? 400 : 500);
      if (status === 500) log(`error: ${e.stack || e}`);
      return sendJSON(res, status, { error: e.message });
    }
  };
}

async function authenticate(auth, req, log) {
  try {
    return await auth.authenticate(req);
  } catch (e) {
    if (e instanceof AuthError) throw new HttpError(e.status, e.message);
    log(`session check failed: ${e.message}`);
    throw new HttpError(502, 'could not verify your UniFi OS session');
  }
}

// Requires a custom header (cross-site pages cannot send one without a CORS
// preflight, which this path does not allow), a JSON body, and a same-origin
// Origin/Sec-Fetch-Site when the browser sends them.
function checkCSRF(req) {
  const reject = () => new HttpError(403, 'request rejected (cross-site request protection)');
  const h = req.headers;
  if (h['x-tsui-request'] !== '1') throw reject();
  if (!String(h['content-type'] || '').startsWith('application/json')) throw reject();
  if (h['sec-fetch-site'] && h['sec-fetch-site'] !== 'same-origin') throw reject();
  if (h.origin) {
    let host;
    try {
      host = new URL(h.origin).host;
    } catch (e) {
      throw reject();
    }
    if (host.toLowerCase() !== String(h['x-forwarded-host'] || h.host || '').toLowerCase()) throw reject();
  }
}

function readJSON(req) {
  return new Promise((resolve, reject) => {
    let body = '';
    req.setEncoding('utf8');
    req.on('data', (chunk) => {
      body += chunk;
      if (body.length > 64 << 10) {
        reject(new HttpError(413, 'request too large'));
        req.destroy();
      }
    });
    req.on('end', () => {
      try {
        resolve(JSON.parse(body || 'null'));
      } catch (e) {
        reject(new HttpError(400, 'invalid JSON'));
      }
    });
    req.on('error', reject);
  });
}

function toArgs(body, isExitNode) {
  try {
    return changeToArgs(body, isExitNode);
  } catch (e) {
    throw new HttpError(400, e.message);
  }
}

// Exit node changes are checked against the peers that offer to be one.
async function exitNodeCheck(backend, body) {
  if (!body || !body.exitNode) return null;
  const status = await backend.status();
  const ips = new Set();
  for (const peer of Object.values(status.Peer || {})) {
    if (peer.ExitNodeOption) (peer.TailscaleIPs || []).forEach((ip) => ips.add(ip));
  }
  return (ip) => ips.has(ip);
}

function serveStatic(res, webDir, pathname, backend) {
  const [file, type] = STATIC[pathname];
  let data = fs.readFileSync(path.join(webDir, file), 'utf8');
  if (file === 'inject.js' && backend.packageSettings().uiRequireOptIn) {
    data = data.replace(OPT_IN_MARKER, '/*TSUI_REQUIRE_OPT_IN*/true');
  }
  send(res, 200, data, type);
}

function send(res, status, body, type) {
  res.writeHead(status, { 'Content-Type': type });
  res.end(body);
}

function sendJSON(res, status, value) {
  send(res, status, JSON.stringify(value), 'application/json');
}

// --- State ----------------------------------------------------------------

// The latest Tailscale version, refreshed in the background because the
// check needs internet access.
class UpstreamVersion {
  constructor(backend) {
    this.backend = backend;
    this.value = '';
    this.checkedAt = 0;
    this.checking = false;
  }

  get() {
    const maxAge = this.value ? 6 * 3600e3 : 10 * 60e3;
    if (!this.checking && Date.now() - this.checkedAt > maxAge) {
      this.checking = true;
      this.backend.version(true)
        .then((v) => { if (v.upstream) this.value = v.upstream; })
        .catch(() => {})
        .finally(() => { this.checking = false; this.checkedAt = Date.now(); });
    }
    return this.value;
  }

  invalidate() {
    this.checkedAt = 0;
  }
}

async function buildState(backend, user, jobs, upstream, addonVersion) {
  const state = {
    addonVersion, user, installed: backend.installed(), daemonRunning: false,
    backendState: 'NotInstalled', health: [], peers: [], suggestedRoutes: [],
    package: backend.packageSettings(), job: jobs.snapshot(), fetchedAt: new Date().toISOString(),
  };
  if (!state.installed) return state;

  const [running, status, prefs, version] = await Promise.all([
    backend.daemonRunning(),
    backend.status().catch((e) => e),
    backend.prefs().catch(() => null),
    backend.version().catch(() => null),
  ]);
  state.daemonRunning = running;
  state.version = version ? version.short : '';
  state.upstreamVersion = upstream.get();
  state.updateAvailable = Boolean(state.version && state.upstreamVersion && versionLess(state.version, state.upstreamVersion));
  state.suggestedRoutes = backend.suggestedRoutes();

  if (status instanceof Error) {
    state.backendState = running ? 'Unavailable' : 'DaemonDown';
    state.error = status.message;
    return state;
  }
  state.backendState = status.BackendState;
  state.authURL = status.AuthURL || '';
  state.health = status.Health || [];
  if (status.Self) {
    state.self = peerView(status.Self);
    const owner = (status.User || {})[String(status.Self.UserID)];
    if (owner) state.loginName = owner.LoginName;
  }
  const tailnet = status.CurrentTailnet || {};
  state.tailnet = tailnet.Name || '';
  state.magicDNSSuffix = tailnet.MagicDNSSuffix || status.MagicDNSSuffix || '';
  state.peers = Object.values(status.Peer || {}).map(peerView).sort((a, b) =>
    (a.online === b.online ? a.name.toLowerCase().localeCompare(b.name.toLowerCase()) : a.online ? -1 : 1));
  if (prefs) state.prefs = prefsView(prefs, status);
  return state;
}

function peerView(p) {
  const dnsName = String(p.DNSName || '').replace(/\.$/, '');
  return {
    id: p.ID || '',
    name: dnsName ? dnsName.split('.')[0] : p.HostName || '',
    dnsName,
    os: p.OS || '',
    ips: p.TailscaleIPs || [],
    online: Boolean(p.Online),
    exitNode: Boolean(p.ExitNode),
    exitNodeOption: Boolean(p.ExitNodeOption),
    routes: p.PrimaryRoutes || [],
    connection: p.CurAddr ? 'direct' : p.Relay ? `relay ${p.Relay}` : '',
    lastSeen: p.LastSeen || '',
    rxBytes: p.RxBytes || 0,
    txBytes: p.TxBytes || 0,
    tags: p.Tags || [],
    expired: Boolean(p.Expired),
  };
}

function prefsView(p, status) {
  const routes = p.AdvertiseRoutes || [];
  let exitNode = p.ExitNodeIP || '';
  if (!exitNode && p.ExitNodeID) {
    const peer = Object.values(status.Peer || {}).find((x) => x.ID === p.ExitNodeID);
    if (peer && peer.TailscaleIPs) exitNode = peer.TailscaleIPs[0];
  }
  // AutoUpdate.Apply is a string ("true") in some versions and a bool in others.
  const apply = p.AutoUpdate && p.AutoUpdate.Apply;
  return {
    hostname: p.Hostname || '',
    acceptRoutes: Boolean(p.RouteAll),
    acceptDNS: Boolean(p.CorpDNS),
    advertiseRoutes: routes.filter((r) => r !== '0.0.0.0/0' && r !== '::/0'),
    advertiseExitNode: routes.includes('0.0.0.0/0') || routes.includes('::/0'),
    exitNode,
    exitNodeAllowLANAccess: Boolean(p.ExitNodeAllowLANAccess),
    ssh: Boolean(p.RunSSH),
    shieldsUp: Boolean(p.ShieldsUp),
    snatSubnetRoutes: !p.NoSNAT,
    webClient: Boolean(p.RunWebClient),
    autoUpdate: apply === true || apply === 'true',
    wantRunning: Boolean(p.WantRunning),
    controlURL: p.ControlURL || '',
    tags: p.AdvertiseTags || [],
  };
}

// Compares dotted version numbers ("1.90.6" < "1.92.1").
function versionLess(a, b) {
  const pa = a.split('.').map((x) => parseInt(x, 10) || 0);
  const pb = b.split('.').map((x) => parseInt(x, 10) || 0);
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    if ((pa[i] || 0) !== (pb[i] || 0)) return (pa[i] || 0) < (pb[i] || 0);
  }
  return false;
}

module.exports = { createHandler, versionLess };
