'use strict';
const assert = require('assert');
const http = require('http');
const path = require('path');
const { test } = require('node:test');
const { AuthError } = require('../../package/ui/server/auth');
const { createHandler, versionLess } = require('../../package/ui/server/handler');
const { Mock } = require('../../package/ui/server/mock');

const WEB_DIR = path.join(__dirname, '../../package/ui/web');
const ADMIN = { authenticate: async () => ({ name: 'admin', admin: true }) };
const VIEWER = { authenticate: async () => ({ name: 'viewer', admin: false }) };
const SIGNED_OUT = { authenticate: async () => { throw new AuthError(401, 'not signed in'); } };

// Starts the handler on a random port; returns a request helper.
async function serve(auth, backend = new Mock()) {
  const handle = createHandler({ backend, auth, webDir: WEB_DIR, log: () => {} });
  const server = http.createServer(handle);
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address();
  const request = (method, url, body, headers = {}) => new Promise((resolve, reject) => {
    const h = { Host: 'udr7.local', ...headers };
    if (method === 'POST') {
      h['Content-Type'] = h['Content-Type'] === undefined ? 'application/json' : h['Content-Type'];
      h['X-TSUI-Request'] = h['X-TSUI-Request'] === undefined ? '1' : h['X-TSUI-Request'];
      for (const k of Object.keys(h)) if (h[k] === null) delete h[k];
    }
    const req = http.request({ port, method, path: url, headers: h }, (res) => {
      let text = '';
      res.on('data', (c) => { text += c; });
      res.on('end', () => {
        let json = null;
        try { json = JSON.parse(text); } catch (e) { /* not JSON */ }
        resolve({ status: res.statusCode, headers: res.headers, text, json });
      });
    });
    req.on('error', reject);
    req.end(body === undefined ? undefined : JSON.stringify(body));
  });
  return { request, backend, close: () => server.close() };
}

test('static files and health check need no session; the API does', async () => {
  const s = await serve(SIGNED_OUT);
  for (const url of ['/healthz', '/', '/inject.js', '/assets/app.js', '/assets/app.css']) {
    assert.strictEqual((await s.request('GET', url)).status, 200, url);
  }
  assert.strictEqual((await s.request('GET', '/api/state')).status, 401);
  assert.strictEqual((await s.request('GET', '/../etc/passwd')).status, 404);
  assert.match((await s.request('GET', '/')).headers['content-security-policy'], /frame-ancestors 'self'/);
  s.close();
});

test('state and settings changes', async () => {
  const s = await serve(ADMIN);
  let res = await s.request('GET', '/api/state');
  assert.strictEqual(res.status, 200);
  assert.strictEqual(res.json.backendState, 'Running');
  assert.strictEqual(res.json.peers.length, 4);
  assert.ok(res.json.peers[0].online && !res.json.peers[3].online, 'online peers first');

  res = await s.request('POST', '/api/prefs', { acceptRoutes: true, exitNode: '100.64.0.2' });
  assert.strictEqual(res.status, 200, res.text);
  assert.strictEqual(res.json.prefs.acceptRoutes, true);
  assert.strictEqual(res.json.prefs.exitNode, '100.64.0.2');

  assert.strictEqual((await s.request('POST', '/api/prefs', { exitNode: '100.64.0.3' })).status, 400, 'peer is not an exit node');
  assert.strictEqual((await s.request('POST', '/api/prefs', { unknownField: true })).status, 400);
  assert.strictEqual((await s.request('POST', '/api/prefs', {})).status, 400);
  s.close();
});

test('writes need an admin and pass the CSRF checks', async () => {
  let s = await serve(VIEWER);
  assert.strictEqual((await s.request('GET', '/api/state')).status, 200);
  assert.strictEqual((await s.request('POST', '/api/prefs', { ssh: true })).status, 403);
  s.close();

  s = await serve(ADMIN);
  const rejected = {
    'missing header': { 'X-TSUI-Request': null },
    'form content type': { 'Content-Type': 'application/x-www-form-urlencoded' },
    'cross-site': { 'Sec-Fetch-Site': 'cross-site' },
    'foreign origin': { Origin: 'https://evil.example' },
  };
  for (const [name, headers] of Object.entries(rejected)) {
    assert.strictEqual((await s.request('POST', '/api/prefs', { ssh: true }, headers)).status, 403, name);
  }
  const ok = await s.request('POST', '/api/prefs', { ssh: true }, { Origin: 'https://udr7.local', 'Sec-Fetch-Site': 'same-origin' });
  assert.strictEqual(ok.status, 200, ok.text);
  assert.strictEqual((await s.request('GET', '/api/prefs')).status, 405);
  s.close();
});

test('one action at a time; apt-based actions cannot be cancelled', async () => {
  const s = await serve(ADMIN);
  const waitForJob = async () => {
    for (let i = 0; i < 200; i++) {
      const { job } = (await s.request('GET', '/api/job')).json;
      if (job && !job.running) return job;
      await new Promise((r) => setTimeout(r, 50));
    }
    throw new Error('job did not finish');
  };

  assert.strictEqual((await s.request('POST', '/api/action', { action: 'rm -rf /' })).status, 400);
  assert.strictEqual((await s.request('POST', '/api/action', { action: 'login' })).status, 202);
  assert.strictEqual((await s.request('POST', '/api/action', { action: 'restart' })).status, 409);
  assert.strictEqual((await s.request('POST', '/api/job/cancel', {})).json.cancelled, true);
  let job = await waitForJob();
  assert.strictEqual(job.ok, false);
  assert.strictEqual(job.error, 'cancelled');

  assert.strictEqual((await s.request('POST', '/api/action', { action: 'update' })).status, 202);
  assert.strictEqual((await s.request('POST', '/api/job/cancel', {})).json.cancelled, false);
  job = await waitForJob();
  assert.strictEqual(job.ok, true);
  s.close();
});

test('missing Tailscale and a stopped daemon are reported', async () => {
  const backend = new Mock();
  const s = await serve(ADMIN, backend);
  backend.isInstalled = false;
  let state = (await s.request('GET', '/api/state')).json;
  assert.strictEqual(state.installed, false);
  assert.strictEqual(state.backendState, 'NotInstalled');
  backend.isInstalled = true;
  backend.running = false;
  state = (await s.request('GET', '/api/state')).json;
  assert.strictEqual(state.backendState, 'DaemonDown');
  assert.ok(state.error);
  s.close();
});

test('inject.js follows TAILSCALE_UI_REQUIRE_OPTIN', async () => {
  const backend = new Mock();
  const s = await serve(ADMIN, backend);
  assert.match((await s.request('GET', '/inject.js')).text, /\/\*TSUI_REQUIRE_OPT_IN\*\/false/);
  backend.pkg.uiRequireOptIn = true;
  assert.match((await s.request('GET', '/inject.js')).text, /\/\*TSUI_REQUIRE_OPT_IN\*\/true/);
  s.close();
});

test('version comparison', () => {
  assert.strictEqual(versionLess('1.90.6', '1.92.1'), true);
  assert.strictEqual(versionLess('1.92.1', '1.92.1'), false);
  assert.strictEqual(versionLess('1.100.0', '1.92.1'), false);
  assert.strictEqual(versionLess('1.92', '1.92.1'), true);
});
