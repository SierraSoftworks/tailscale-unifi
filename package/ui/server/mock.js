'use strict';
// A simulated Tailscale for development and tests: a logged-in gateway with a
// few peers. Implements the same methods as tailscale.System.

const EXIT_ROUTES = ['0.0.0.0/0', '::/0'];

function peer(id, host, os, ip, online, exitNodeOption, rx, tx) {
  return {
    ID: id, HostName: host, DNSName: `${host}.tail1234.ts.net.`, OS: os,
    TailscaleIPs: [ip, `fd7a:115c:a1e0::${id}`], Online: online, ExitNodeOption: exitNodeOption,
    RxBytes: rx, TxBytes: tx, CurAddr: online ? '203.0.113.7:41641' : '',
    LastSeen: new Date(Date.now() - 3 * 3600e3).toISOString(),
  };
}

class Mock {
  constructor() {
    this.isInstalled = true;
    this.running = true;
    this.loggedIn = true;
    this.authURL = '';
    this.currentVersion = '1.90.6';
    this.pkg = { autoUpdate: true, channel: 'stable', uiRequireOptIn: false };
    this.p = {
      ControlURL: 'https://controlplane.tailscale.com', RouteAll: false, CorpDNS: true,
      WantRunning: true, Hostname: '', AdvertiseRoutes: ['192.168.10.0/24'], ExitNodeIP: '',
      ExitNodeAllowLANAccess: false, RunSSH: false, ShieldsUp: false, NoSNAT: false,
      RunWebClient: false, AutoUpdate: { Check: true, Apply: null },
    };
  }

  installed() { return this.isInstalled; }

  async daemonRunning() { return this.isInstalled && this.running; }

  async status() {
    if (!this.isInstalled || !this.running) {
      throw new Error("failed to connect to local tailscaled; it doesn't appear to be running");
    }
    if (!this.loggedIn) return { BackendState: 'NeedsLogin', AuthURL: this.authURL, Peer: {}, User: {} };
    const host = this.p.Hostname || 'Dream-Router-7';
    const self = peer('1', host, 'linux', '100.101.102.103', this.p.WantRunning, false, 0, 0);
    self.DNSName = `${host.toLowerCase()}.tail1234.ts.net.`;
    self.PrimaryRoutes = this.p.AdvertiseRoutes.filter((r) => !EXIT_ROUTES.includes(r));
    self.UserID = 1;
    const status = {
      BackendState: this.p.WantRunning ? 'Running' : 'Stopped', AuthURL: '',
      Self: self, TailscaleIPs: self.TailscaleIPs, Health: [], Peer: {},
      CurrentTailnet: { Name: 'example.github', MagicDNSSuffix: 'tail1234.ts.net' },
      User: { 1: { LoginName: 'admin@example.com' } },
    };
    if (!this.p.WantRunning) return status;
    const peers = [
      peer('2', 'proxmox', 'linux', '100.64.0.2', true, true, 123456789, 9876543),
      peer('3', 'laptop', 'windows', '100.64.0.3', true, false, 5555555, 444444),
      peer('4', 'phone', 'android', '100.64.0.4', false, false, 0, 0),
      peer('5', 'vps-fra', 'linux', '100.64.0.5', true, true, 999, 888),
    ];
    for (const p of peers) {
      p.ExitNode = p.TailscaleIPs[0] === this.p.ExitNodeIP;
      status.Peer[`nodekey:${p.ID}`] = p;
    }
    if (this.p.ShieldsUp) status.Health.push('Shields up: incoming connections are blocked');
    return status;
  }

  async prefs() {
    if (!this.isInstalled || !this.running) throw new Error('failed to connect to local tailscaled');
    return { ...this.p, AdvertiseRoutes: [...this.p.AdvertiseRoutes], LoggedOut: !this.loggedIn };
  }

  async version(upstream) {
    if (!this.isInstalled) throw new Error('tailscale not installed');
    return { short: this.currentVersion, long: `${this.currentVersion}-mock`, upstream: upstream ? '1.92.1' : undefined };
  }

  async set(args) {
    for (const arg of args) {
      const [flag, value = ''] = arg.replace(/^--/, '').split(/=(.*)/s);
      const on = value === 'true';
      const subnets = this.p.AdvertiseRoutes.filter((r) => !EXIT_ROUTES.includes(r));
      const exit = this.p.AdvertiseRoutes.some((r) => EXIT_ROUTES.includes(r));
      switch (flag) {
        case 'hostname': this.p.Hostname = value; break;
        case 'accept-routes': this.p.RouteAll = on; break;
        case 'accept-dns': this.p.CorpDNS = on; break;
        case 'advertise-routes':
          this.p.AdvertiseRoutes = [...(value ? value.split(',') : []), ...(exit ? EXIT_ROUTES : [])];
          break;
        case 'advertise-exit-node': this.p.AdvertiseRoutes = [...subnets, ...(on ? EXIT_ROUTES : [])]; break;
        case 'exit-node': this.p.ExitNodeIP = value; break;
        case 'exit-node-allow-lan-access': this.p.ExitNodeAllowLANAccess = on; break;
        case 'ssh': this.p.RunSSH = on; break;
        case 'shields-up': this.p.ShieldsUp = on; break;
        case 'snat-subnet-routes': this.p.NoSNAT = !on; break;
        case 'webclient': this.p.RunWebClient = on; break;
        case 'auto-update': this.p.AutoUpdate = { Check: true, Apply: value }; break;
        default: throw new Error(`flag provided but not defined: -${flag}`);
      }
    }
    if (this.p.ExitNodeIP && this.p.AdvertiseRoutes.some((r) => EXIT_ROUTES.includes(r))) {
      throw new Error('cannot advertise an exit node and use an exit node at the same time');
    }
  }

  suggestedRoutes() { return ['192.168.10.0/24', '192.168.20.0/24']; }

  packageSettings() { return { ...this.pkg }; }

  setPackageAutoUpdate(enabled) { this.pkg.autoUpdate = enabled; }

  // Simulates an action with short pauses between lines of output.
  async runAction(action, onOutput, signal) {
    const step = (line) => new Promise((resolve, reject) => {
      if (line !== undefined) onOutput(`${line}\n`);
      if (signal && signal.aborted) return reject(new Error('cancelled'));
      const t = setTimeout(resolve, 400);
      if (signal) signal.addEventListener('abort', () => { clearTimeout(t); reject(new Error('cancelled')); }, { once: true });
    });
    switch (action) {
      case 'connect': this.p.WantRunning = true; return step('Success.');
      case 'disconnect': this.p.WantRunning = false; return undefined;
      case 'logout': this.loggedIn = false; return step('Logged out.');
      case 'login':
        this.authURL = 'https://login.tailscale.com/a/mock123456';
        await step(`To authenticate, visit:\n\n\t${this.authURL}\n`);
        for (let i = 0; i < 15; i++) await step();
        this.loggedIn = true;
        this.authURL = '';
        this.p.WantRunning = true;
        return step('Success.');
      case 'restart':
      case 'start': this.running = true; return step('Tailscaled started successfully');
      case 'update':
        await step('Reading package lists...');
        await step('Setting up tailscale (1.92.1) ...');
        this.currentVersion = '1.92.1';
        return undefined;
      case 'install': this.isInstalled = true; this.running = true; return step('Installed.');
      case 'netcheck': return step('Report:\n\t* UDP: true\n\t* Nearest DERP: Frankfurt');
      default: throw new Error(`unknown action ${action}`);
    }
  }
}

module.exports = { Mock };
