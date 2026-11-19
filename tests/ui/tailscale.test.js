'use strict';
const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { test } = require('node:test');
const { changeToArgs, normalizeRoutes, readEnvFile, setEnvValue } = require('../../package/ui/server/tailscale');

const isExitNode = (ip) => ip === '100.64.0.2';

test('settings changes become tailscale set arguments', () => {
  const cases = [
    [{ acceptRoutes: true, ssh: false }, ['--accept-routes=true', '--ssh=false']],
    [{ hostname: ' udr7 ' }, ['--hostname=udr7']],
    [{ hostname: '' }, ['--hostname=']],
    [{ advertiseRoutes: ['192.168.10.5/24', '10.0.0.0/8', '192.168.10.0/24'] }, ['--advertise-routes=10.0.0.0/8,192.168.10.0/24']],
    [{ advertiseRoutes: [] }, ['--advertise-routes=']],
    [{ exitNode: '100.64.0.2' }, ['--exit-node=100.64.0.2']],
    [{ exitNode: '' }, ['--exit-node=']],
  ];
  for (const [change, want] of cases) assert.deepStrictEqual(changeToArgs(change, isExitNode), want);
});

test('invalid settings changes are rejected', () => {
  const cases = [
    [{}, /no settings/],
    [{ unknownField: true }, /unknown setting/],
    [{ ssh: 'yes' }, /true or false/],
    [{ hostname: 'a --ssh' }, /invalid hostname/],
    [{ hostname: '-x' }, /invalid hostname/],
    [{ advertiseRoutes: ['192.168.1.0'] }, /invalid subnet/],
    [{ advertiseRoutes: ['1.2.3.0/24,--ssh'] }, /invalid subnet/],
    [{ advertiseRoutes: ['0.0.0.0/0'] }, /default route/],
    [{ advertiseRoutes: '10.0.0.0/8' }, /must be a list/],
    [{ exitNode: '100.64.0.9' }, /not an available exit node/],
    [{ exitNode: 'proxmox' }, /invalid exit node/],
    [null, /invalid request/],
  ];
  for (const [change, error] of cases) assert.throws(() => changeToArgs(change, isExitNode), error);
});

test('routes are masked and IPv6 is written in canonical form', () => {
  assert.deepStrictEqual(normalizeRoutes(['fd00:0:0:1::5/64', '2001:DB8::1/32', ' ']), ['2001:db8::/32', 'fd00:0:0:1::/64']);
  assert.deepStrictEqual(normalizeRoutes(['10.1.2.3/32']), ['10.1.2.3/32']);
  assert.throws(() => normalizeRoutes(['::/0']), /default route/);
  assert.throws(() => normalizeRoutes(['10.0.0.0/33']), /invalid subnet/);
});

test('tailscale-env is updated without touching other lines', () => {
  const file = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'tsui-')), 'tailscale-env');
  fs.writeFileSync(file, 'PORT="41641"\nTAILSCALED_FLAGS="--tun userspace-networking"\nTAILSCALE_AUTOUPDATE="true"\nTAILSCALE_CHANNEL="unstable"\n');
  setEnvValue(file, 'TAILSCALE_AUTOUPDATE', 'false');
  assert.strictEqual(fs.readFileSync(file, 'utf8'),
    'PORT="41641"\nTAILSCALED_FLAGS="--tun userspace-networking"\nTAILSCALE_AUTOUPDATE="false"\nTAILSCALE_CHANNEL="unstable"\n');
  assert.deepStrictEqual(readEnvFile(file).TAILSCALE_CHANNEL, 'unstable');

  fs.writeFileSync(file, 'PORT="1"\n');
  setEnvValue(file, 'TAILSCALE_AUTOUPDATE', 'true');
  assert.strictEqual(fs.readFileSync(file, 'utf8'), 'PORT="1"\nTAILSCALE_AUTOUPDATE="true"\n');
  assert.ok(!fs.existsSync(`${file}.tsui.tmp`));
});
