'use strict';
// Stands in for the UniFi OS services that UniFi's nginx config talks to, so
// tests/e2e can run nginx with UniFi's config in a container. For tests only.
//
// Usage: node fakeuos.js <http-dir>
// Valid session cookie: TOKEN=good (admin) or TOKEN=viewer (read-only).

const fs = require('fs');
const http = require('http');
const path = require('path');

const httpDir = process.argv[2];
const users = {
  good: { username: 'owner', isOwner: true, isSuperAdmin: true, role: 'owner', permissions: { 'network.management': ['admin'] } },
  viewer: { username: 'viewer', role: 'custom', permissions: { 'network.management': ['readonly'] } },
};

function serveSocket(file, handler) {
  try { fs.unlinkSync(file); } catch (e) { /* not there */ }
  http.createServer(handler).listen(file, () => fs.chmodSync(file, 0o666));
}

// nginx auth_request backend: 200 plus identity headers for a valid session.
serveSocket(path.join(httpDir, 'uos-auth.sock'), (req, res) => {
  const token = req.headers['x-token'];
  if (!users[token]) return res.writeHead(401).end();
  res.writeHead(200, { 'X-Token': token, 'X-Username': token }).end();
});

// UniFi OS API. auth.conf passes the session on as X-Token.
serveSocket(path.join(httpDir, 'uos-http.sock'), (req, res) => {
  if (req.url === '/api/ping') return res.end('pong');
  if (req.url === '/api/users/self') {
    const user = users[req.headers['x-token']];
    if (!user) return res.writeHead(401).end();
    return res.writeHead(200, { 'Content-Type': 'application/json' }).end(JSON.stringify(user));
  }
  res.writeHead(404).end();
});

// UniFi Network API (network_api_backend = 127.0.0.1:8081).
http.createServer((req, res) => res.end('{"meta":{"rc":"ok"}}')).listen(8081, '127.0.0.1');

console.log(`fakeuos serving in ${httpDir}`);
