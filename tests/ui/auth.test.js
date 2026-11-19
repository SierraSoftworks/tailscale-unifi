'use strict';
const assert = require('assert');
const { test } = require('node:test');
const { AuthError, UniFiAuth, parseUser, sessionCookie } = require('../../package/ui/server/auth');

test('users/self responses map to admin, read-only or no access', () => {
  const cases = [
    ['{"username":"owner","isOwner":true,"isSuperAdmin":true,"role":"owner"}', true],
    ['{"username":"a","role":"admin","isSuperAdmin":true}', true],
    ['{"username":"n","role":"custom","permissions":{"network.management":["admin"]}}', true],
    ['{"username":"v","role":"custom","permissions":{"network.management":["readonly"]}}', false],
    ['{"data":{"username":"w","isOwner":true}}', true],
    ['{"data":[{"username":"x","role":"viewer"}]}', false],
  ];
  for (const [body, admin] of cases) assert.strictEqual(parseUser(body).admin, admin, body);
  assert.throws(() => parseUser('{"username":"p","role":"custom","permissions":{"protect.management":["admin"]}}'),
    (e) => e instanceof AuthError && e.status === 403);
  assert.throws(() => parseUser('<html>'));
});

test('the session cookie is found regardless of case', () => {
  assert.deepStrictEqual(sessionCookie('a=1; TOKEN=abc'), { name: 'TOKEN', value: 'abc' });
  assert.deepStrictEqual(sessionCookie('token=xyz'), { name: 'token', value: 'xyz' });
  assert.strictEqual(sessionCookie('other=1'), null);
  assert.strictEqual(sessionCookie(undefined), null);
});

test('session checks are cached and invalid sessions rejected', async () => {
  const auth = new UniFiAuth('https://127.0.0.1/api/users/self');
  let calls = 0;
  auth.lookup = async (cookie) => {
    calls++;
    if (cookie.value !== 'good') throw new AuthError(401, 'not signed in');
    return { name: 'owner', admin: true };
  };
  const req = (cookie) => ({ headers: { cookie } });
  for (let i = 0; i < 3; i++) assert.deepStrictEqual(await auth.authenticate(req('TOKEN=good')), { name: 'owner', admin: true });
  assert.strictEqual(calls, 1);
  await assert.rejects(auth.authenticate(req('TOKEN=bad')), (e) => e.status === 401);
  await assert.rejects(auth.authenticate(req('')), (e) => e.status === 401);
});
