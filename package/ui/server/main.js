'use strict';
// Entry point of the Tailscale panel backend (started by ../start.sh).
//
// On the console it listens on a Unix socket that UniFi's nginx proxies
// /proxy/tailscale-unifi/ to. --listen is for local development only.
//
// Usage: node main.js [--socket PATH] [--socket-group nginx] [--manage PATH]
//                     [--env PATH] [--tailscale PATH] [--unifi-self URL]
//        node main.js --listen 127.0.0.1:8099 --mock --dev-noauth [--dev-harness FILE]

const fs = require('fs');
const http = require('http');
const net = require('net');
const path = require('path');
const { UniFiAuth, noAuth } = require('./auth');
const { createHandler } = require('./handler');
const { System } = require('./tailscale');

const VERSION = readVersion();

const DEFAULTS = {
  socket: '/run/tailscale-unifi/ui.sock',
  'socket-group': 'nginx',
  manage: '/data/tailscale/manage.sh',
  env: '/data/tailscale/tailscale-env',
  tailscale: 'tailscale',
  'unifi-self': 'https://127.0.0.1/api/users/self',
  'web-dir': path.join(__dirname, '..', 'web'),
};
const FLAGS = new Set(['mock', 'dev-noauth', 'version']);

function parseArgs(argv) {
  const opts = { ...DEFAULTS };
  for (let i = 0; i < argv.length; i++) {
    const name = argv[i].replace(/^--?/, '');
    if (FLAGS.has(name)) opts[name] = true;
    else if (name in DEFAULTS || name === 'listen' || name === 'dev-harness') opts[name] = argv[++i];
    else throw new Error(`unknown option ${argv[i]}`);
  }
  return opts;
}

function readVersion() {
  try {
    return fs.readFileSync(path.join(__dirname, '..', 'VERSION'), 'utf8').trim();
  } catch (e) {
    return 'dev';
  }
}

function groupId(name) {
  const line = fs.readFileSync('/etc/group', 'utf8').split('\n').find((l) => l.split(':')[0] === name);
  if (!line) throw new Error(`group ${name} not found`);
  return Number(line.split(':')[2]);
}

function listenSocket(server, file, group) {
  // Replace a stale socket, but nothing else.
  try {
    if (!fs.lstatSync(file).isSocket()) throw new Error(`${file} exists and is not a socket`);
    fs.unlinkSync(file);
  } catch (e) {
    if (e.code !== 'ENOENT') throw e;
  }
  const oldMask = process.umask(0o177);
  server.listen(file, () => {
    process.umask(oldMask);
    if (group) {
      fs.chownSync(file, 0, groupId(group));
      fs.chmodSync(file, 0o660);
    }
    console.log(`tailscale-unifi-ui ${VERSION} listening on ${file}`);
  });
}

function listenLoopback(server, address) {
  const [host, port] = address.split(/:(?=\d+$)/);
  if (!net.isIP(host) || !(host === '::1' || host.startsWith('127.'))) {
    throw new Error(`--listen must be a loopback address such as 127.0.0.1:8099, got ${address}`);
  }
  server.listen(Number(port), host, () => console.log(`tailscale-unifi-ui ${VERSION} listening on http://${address}/`));
}

function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (opts.version) return console.log(VERSION);
  if (!opts.listen && (opts['dev-noauth'] || opts['dev-harness'])) {
    throw new Error('--dev-noauth and --dev-harness are only allowed together with --listen on a loopback address');
  }

  const backend = opts.mock
    ? new (require('./mock').Mock)()
    : new System({ tailscale: opts.tailscale, manage: opts.manage, envFile: opts.env });
  const auth = opts['dev-noauth'] ? noAuth : new UniFiAuth(opts['unifi-self']);
  const handle = createHandler({ backend, auth, webDir: opts['web-dir'], version: VERSION });

  const server = http.createServer((req, res) => {
    // Development only: serve a saved copy of UniFi's VPN page for /network/...
    if (opts['dev-harness'] && req.method === 'GET' && req.url.startsWith('/network/')) {
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      return res.end(fs.readFileSync(opts['dev-harness']));
    }
    return handle(req, res);
  });
  server.headersTimeout = 10e3;
  server.requestTimeout = 30e3;

  if (opts.listen) listenLoopback(server, opts.listen);
  else listenSocket(server, opts.socket, opts['socket-group']);

  const stop = () => server.close(() => process.exit(0));
  process.on('SIGTERM', stop);
  process.on('SIGINT', stop);
}

try {
  main();
} catch (e) {
  console.error(e.message);
  process.exit(1);
}
