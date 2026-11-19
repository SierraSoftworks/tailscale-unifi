'use strict';
// Access to the local Tailscale installation through the `tailscale` CLI.
//
// The CLI comes from the same package as tailscaled, so it always matches the
// daemon's version; the LocalAPI it wraps is internal to Tailscale. Commands
// run with a fixed argv (no shell), and user input is validated here first.

const { execFile, spawn } = require('child_process');
const fs = require('fs');
const net = require('net');
const os = require('os');
const path = require('path');

// Long-running actions and their timeouts. Anything else is rejected.
const ACTIONS = {
  connect: 90e3,
  disconnect: 30e3,
  login: 15 * 60e3,
  logout: 60e3,
  restart: 120e3,
  start: 120e3,
  update: 20 * 60e3,
  install: 20 * 60e3,
  netcheck: 60e3,
};

// These run in their own systemd unit (systemd-run), outside the backend's
// cgroup and lifetime, so apt is never killed halfway through an upgrade.
const DETACHED = new Set(['update', 'install', 'restart', 'start']);

const EXIT_ROUTES = new Set(['0.0.0.0/0', '::/0']);

class ValidationError extends Error {}

function run(file, args, timeout = 20e3) {
  return new Promise((resolve) => {
    execFile(file, args, { timeout, maxBuffer: 16 << 20 }, (err, stdout, stderr) => {
      resolve({ ok: !err, stdout, stderr, err });
    });
  });
}

function failure(res) {
  return new Error((res.stderr || res.stdout || String(res.err)).trim());
}

function findExecutable(name) {
  if (name.includes('/')) return isExecutable(name) ? name : null;
  for (const dir of (process.env.PATH || '').split(':')) {
    const file = path.join(dir, name);
    if (isExecutable(file)) return file;
  }
  return null;
}

function isExecutable(file) {
  try {
    fs.accessSync(file, fs.constants.X_OK);
    return fs.statSync(file).isFile();
  } catch (e) {
    return false;
  }
}

class System {
  constructor({ tailscale = 'tailscale', manage, envFile }) {
    this.tailscale = tailscale;
    this.manage = manage;
    this.envFile = envFile;
  }

  installed() {
    return findExecutable(this.tailscale) !== null;
  }

  async daemonRunning() {
    return (await run('systemctl', ['is-active', '--quiet', 'tailscaled'])).ok;
  }

  // `status --json` exits non-zero while stopped or logged out but still
  // prints the status, so parse the output either way.
  async status() {
    const res = await run(this.tailscale, ['status', '--json']);
    try {
      return JSON.parse(res.stdout);
    } catch (e) {
      throw res.ok ? new Error('could not parse tailscale status') : failure(res);
    }
  }

  async prefs() {
    const res = await run(this.tailscale, ['debug', 'prefs']);
    if (!res.ok) throw failure(res);
    return JSON.parse(res.stdout);
  }

  async version(upstream = false) {
    const args = ['version', '--json'];
    if (upstream) args.push('--upstream');
    const res = await run(this.tailscale, args, 30e3);
    if (!res.ok) throw failure(res);
    return JSON.parse(res.stdout);
  }

  async set(args) {
    const res = await run(this.tailscale, ['set', ...args]);
    if (!res.ok) throw failure(res);
  }

  // IPv4 subnets of the UniFi LAN bridges (br*), offered as route suggestions.
  suggestedRoutes() {
    const routes = new Set();
    for (const [name, addrs] of Object.entries(os.networkInterfaces())) {
      if (!name.startsWith('br')) continue;
      for (const a of addrs) {
        if (a.family === 'IPv4' && !a.internal && isPrivateIPv4(a.address) && a.cidr) {
          routes.add(normalizeRoute(a.cidr));
        }
      }
    }
    return [...routes].sort();
  }

  packageSettings() {
    const env = readEnvFile(this.envFile);
    return {
      autoUpdate: (env.TAILSCALE_AUTOUPDATE || 'true') === 'true',
      channel: env.TAILSCALE_CHANNEL || 'stable',
      uiRequireOptIn: env.TAILSCALE_UI_REQUIRE_OPTIN === 'true',
    };
  }

  setPackageAutoUpdate(enabled) {
    setEnvValue(this.envFile, 'TAILSCALE_AUTOUPDATE', String(enabled));
  }

  actionCommand(action) {
    switch (action) {
      case 'connect': return [this.tailscale, 'up', '--timeout=60s'];
      case 'disconnect': return [this.tailscale, 'down'];
      case 'login': return [this.tailscale, 'login', '--timeout=14m'];
      case 'logout': return [this.tailscale, 'logout'];
      case 'netcheck': return [this.tailscale, 'netcheck'];
      case 'restart': return [this.manage, 'restart'];
      case 'start': return [this.manage, 'start'];
      case 'update': return [this.manage, 'update!'];
      case 'install': return [this.manage, 'install'];
      default: throw new ValidationError(`unknown action ${action}`);
    }
  }

  // Runs an action, passing its output to onOutput. Resolves when it exits
  // successfully. `signal` cancels actions that are not detached.
  runAction(action, onOutput, signal) {
    let argv = this.actionCommand(action);
    const detached = DETACHED.has(action) && findExecutable('systemd-run');
    if (detached) {
      const unit = `tailscale-unifi-ui-${action}-${Date.now()}`;
      argv = ['systemd-run', '--quiet', '--collect', '--wait', '--pipe', `--unit=${unit}`,
        '--property=Nice=10', '--setenv=DEBIAN_FRONTEND=noninteractive', '--', ...argv];
    }
    return new Promise((resolve, reject) => {
      const child = spawn(argv[0], argv.slice(1), {
        stdio: ['ignore', 'pipe', 'pipe'],
        env: { ...process.env, DEBIAN_FRONTEND: 'noninteractive' },
      });
      child.stdout.on('data', onOutput);
      child.stderr.on('data', onOutput);
      const cancel = () => { if (!detached) child.kill('SIGTERM'); };
      if (signal) signal.addEventListener('abort', cancel, { once: true });
      child.on('error', reject);
      child.on('close', (code) => {
        if (signal) signal.removeEventListener('abort', cancel);
        if (code === 0) resolve();
        else reject(new Error(`exit status ${code}`));
      });
    });
  }
}

// --- Settings changes -----------------------------------------------------

const HOSTNAME_RE = /^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$/;

// Maps each accepted field of a settings change to its `tailscale set` flag.
const BOOL_FLAGS = {
  acceptRoutes: 'accept-routes',
  acceptDNS: 'accept-dns',
  advertiseExitNode: 'advertise-exit-node',
  exitNodeAllowLANAccess: 'exit-node-allow-lan-access',
  ssh: 'ssh',
  shieldsUp: 'shields-up',
  snatSubnetRoutes: 'snat-subnet-routes',
  webClient: 'webclient',
  autoUpdate: 'auto-update',
};
const CHANGE_FIELDS = new Set(['hostname', 'advertiseRoutes', 'exitNode', ...Object.keys(BOOL_FLAGS)]);

// Converts a settings change ({field: value}) into `tailscale set` arguments.
// isExitNode(ip) reports whether ip belongs to a peer offering to be an exit node.
function changeToArgs(change, isExitNode) {
  if (!change || typeof change !== 'object' || Array.isArray(change)) {
    throw new ValidationError('invalid request');
  }
  const args = [];
  for (const [key, value] of Object.entries(change)) {
    if (!CHANGE_FIELDS.has(key)) throw new ValidationError(`unknown setting ${key}`);
    if (key in BOOL_FLAGS) {
      if (typeof value !== 'boolean') throw new ValidationError(`${key} must be true or false`);
      args.push(`--${BOOL_FLAGS[key]}=${value}`);
    }
  }
  if ('hostname' in change) {
    const name = String(change.hostname).trim();
    if (name && !HOSTNAME_RE.test(name)) {
      throw new ValidationError(`invalid hostname "${name}": use letters, digits and dashes (max 63)`);
    }
    args.push(`--hostname=${name}`);
  }
  if ('advertiseRoutes' in change) {
    if (!Array.isArray(change.advertiseRoutes)) throw new ValidationError('advertiseRoutes must be a list');
    args.push(`--advertise-routes=${normalizeRoutes(change.advertiseRoutes).join(',')}`);
  }
  if ('exitNode' in change) {
    const ip = String(change.exitNode).trim();
    if (ip) {
      if (!net.isIP(ip)) throw new ValidationError(`invalid exit node "${ip}"`);
      if (!isExitNode || !isExitNode(ip)) throw new ValidationError(`${ip} is not an available exit node`);
    }
    args.push(`--exit-node=${ip}`);
  }
  if (!args.length) throw new ValidationError('no settings to change');
  return args;
}

// Validates subnet routes, masks host bits, removes duplicates and sorts them.
// Default routes are rejected; advertiseExitNode controls those.
function normalizeRoutes(list) {
  const out = new Set();
  for (const raw of list) {
    const route = String(raw).trim();
    if (!route) continue;
    const normalized = normalizeRoute(route);
    if (EXIT_ROUTES.has(normalized)) {
      throw new ValidationError(`${route} is a default route; use "Offer as exit node" instead`);
    }
    out.add(normalized);
  }
  if (out.size > 64) throw new ValidationError('too many subnet routes (max 64)');
  return [...out].sort();
}

function normalizeRoute(route) {
  const invalid = () => new ValidationError(`invalid subnet "${route}": use CIDR notation such as 192.168.1.0/24`);
  const match = /^([0-9a-fA-F:.]+)\/(\d{1,3})$/.exec(route);
  if (!match) throw invalid();
  const family = net.isIP(match[1]);
  const width = family === 4 ? 32 : family === 6 ? 128 : 0;
  const bits = Number(match[2]);
  if (!width || bits > width || (family === 6 && match[1].includes('.'))) throw invalid();
  const value = family === 4 ? ipv4ToBigInt(match[1]) : ipv6ToBigInt(match[1]);
  const hostBits = BigInt(width - bits);
  const masked = (value >> hostBits) << hostBits;
  return `${family === 4 ? bigIntToIPv4(masked) : bigIntToIPv6(masked)}/${bits}`;
}

function ipv4ToBigInt(ip) {
  return ip.split('.').reduce((acc, part) => (acc << 8n) | BigInt(Number(part)), 0n);
}

function bigIntToIPv4(n) {
  return [24n, 16n, 8n, 0n].map((s) => String((n >> s) & 255n)).join('.');
}

function ipv6ToBigInt(ip) {
  const [head, tail] = ip.split('::');
  const left = head ? head.split(':') : [];
  const right = tail !== undefined && tail ? tail.split(':') : [];
  const zeros = tail === undefined ? [] : Array(8 - left.length - right.length).fill('0');
  return [...left, ...zeros, ...right].reduce((acc, g) => (acc << 16n) | BigInt(parseInt(g, 16)), 0n);
}

// Formats an IPv6 address in canonical form (RFC 5952).
function bigIntToIPv6(n) {
  const groups = [];
  for (let s = 112n; s >= 0n; s -= 16n) groups.push(Number((n >> s) & 0xffffn).toString(16));
  let best = -1, bestLen = 0;
  for (let i = 0; i < 8;) {
    if (groups[i] !== '0') { i++; continue; }
    let j = i;
    while (j < 8 && groups[j] === '0') j++;
    if (j - i > bestLen && j - i > 1) { best = i; bestLen = j - i; }
    i = j;
  }
  if (best < 0) return groups.join(':');
  return `${groups.slice(0, best).join(':')}::${groups.slice(best + bestLen).join(':')}`;
}

function isPrivateIPv4(ip) {
  const [a, b] = ip.split('.').map(Number);
  return a === 10 || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168);
}

// --- tailscale-env --------------------------------------------------------

// Reads KEY="VALUE" lines without executing the file.
function readEnvFile(file) {
  const env = {};
  let text = '';
  try {
    text = fs.readFileSync(file, 'utf8');
  } catch (e) {
    return env;
  }
  for (const line of text.split('\n')) {
    const m = /^\s*([A-Za-z_][A-Za-z0-9_]*)=("?)(.*)\2\s*$/.exec(line);
    if (m) env[m[1]] = m[3];
  }
  return env;
}

// Replaces or appends KEY="VALUE", leaving other lines as they are. Writes a
// temp file and renames it into place.
function setEnvValue(file, key, value) {
  const text = fs.readFileSync(file, 'utf8');
  const line = `${key}="${value}"`;
  const lines = text.split('\n');
  const index = lines.findIndex((l) => l.trim().startsWith(`${key}=`));
  if (index >= 0) lines[index] = line;
  else if (lines[lines.length - 1] === '') lines.splice(lines.length - 1, 0, line);
  else lines.push(line);
  const tmp = `${file}.tsui.tmp`;
  fs.writeFileSync(tmp, lines.join('\n'), { mode: fs.statSync(file).mode & 0o777 });
  fs.renameSync(tmp, file);
}

module.exports = {
  ACTIONS,
  DETACHED,
  EXIT_ROUTES,
  System,
  ValidationError,
  changeToArgs,
  normalizeRoutes,
  readEnvFile,
  setEnvValue,
};
