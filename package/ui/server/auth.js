'use strict';
// Checks who a request belongs to by asking UniFi OS, so the panel accepts
// exactly the sessions UniFi accepts.

const crypto = require('crypto');
const https = require('https');

class AuthError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

const SIGNED_OUT = () => new AuthError(401, 'not signed in to UniFi OS');
const NO_ACCESS = () => new AuthError(403, 'your UniFi account has no access to UniFi Network');

// UniFi names its session cookie TOKEN. nginx matches cookie names
// case-insensitively, so this does too.
function sessionCookie(header) {
  for (const part of String(header || '').split(';')) {
    const eq = part.indexOf('=');
    if (eq < 0) continue;
    const name = part.slice(0, eq).trim();
    const value = part.slice(eq + 1).trim();
    if (name.toLowerCase() === 'token' && value) return { name, value };
  }
  return null;
}

// Interprets a /api/users/self response: isOwner, isSuperAdmin, role, and a
// per-app permissions map such as {"network.management": ["admin"]}. The
// payload is sometimes wrapped in a "data" field.
function parseUser(body) {
  let user;
  try {
    user = JSON.parse(body);
  } catch (e) {
    throw new Error('unexpected /api/users/self response');
  }
  if (user && !user.username && !user.role && !user.isOwner && user.data) {
    user = Array.isArray(user.data) ? user.data[0] : user.data;
  }
  user = user || {};
  const role = String(user.role || '').toLowerCase();
  const network = (user.permissions && user.permissions['network.management']) || [];
  const admin = Boolean(user.isOwner || user.isSuperAdmin) || role === 'owner' || role === 'admin' ||
    network.some((p) => String(p).toLowerCase() === 'admin');
  if (!admin && network.length === 0 && role !== 'viewer') throw NO_ACCESS();
  return { name: user.username || user.name || user.first_name || '', admin };
}

class UniFiAuth {
  constructor(selfURL, ttl = 15e3) {
    this.selfURL = selfURL;
    this.ttl = ttl;
    this.cache = new Map();
  }

  async authenticate(req) {
    const cookie = sessionCookie(req.headers.cookie);
    if (!cookie) throw SIGNED_OUT();
    const key = crypto.createHash('sha256').update(cookie.value).digest('hex');
    const hit = this.cache.get(key);
    if (hit && hit.expires > Date.now()) {
      if (hit.error) throw hit.error;
      return hit.user;
    }
    let user, error;
    try {
      user = await this.lookup(cookie);
    } catch (e) {
      if (!(e instanceof AuthError)) throw e; // transient, don't cache
      error = e;
    }
    if (this.cache.size > 256) this.cache.clear();
    this.cache.set(key, { user, error, expires: Date.now() + this.ttl });
    if (error) throw error;
    return user;
  }

  lookup(cookie) {
    return new Promise((resolve, reject) => {
      const req = https.get(this.selfURL, {
        headers: { Cookie: `${cookie.name}=${cookie.value}`, Accept: 'application/json' },
        // The request goes to 127.0.0.1, where UniFi's certificate is self-signed.
        rejectUnauthorized: false,
        timeout: 6e3,
      }, (res) => {
        let body = '';
        res.setEncoding('utf8');
        res.on('data', (chunk) => { if (body.length < 1 << 20) body += chunk; });
        res.on('end', () => {
          if (res.statusCode === 401 || res.statusCode === 403) return reject(SIGNED_OUT());
          if (res.statusCode !== 200) return reject(new Error(`UniFi OS session check failed: HTTP ${res.statusCode}`));
          try {
            resolve(parseUser(body));
          } catch (e) {
            reject(e);
          }
        });
      });
      req.on('timeout', () => req.destroy(new Error('UniFi OS session check timed out')));
      req.on('error', reject);
    });
  }
}

// For local development only: every request is an administrator.
const noAuth = { authenticate: async () => ({ name: 'developer', admin: true }) };

module.exports = { AuthError, UniFiAuth, noAuth, parseUser, sessionCookie };
