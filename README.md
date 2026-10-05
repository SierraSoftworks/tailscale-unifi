# Tailscale on UniFi OS

This repo provides the scripts needed to install and run [Tailscale](https://tailscale.com) on your [UniFi Cloud Gateways](https://ui.com/cloud-gateways). It provides a persistent service, automatic updates, and a default configuration which works well on most [UniFi Cloud Gateways](https://ui.com/cloud-gateways) out of the box.

## Installation

1. Run the `install.sh` script to install the latest version of the Tailscale UniFi package on your device.

   ```sh
   # Install the latest version of Tailscale UniFi
   curl -sSLq https://raw.githubusercontent.com/SierraSoftworks/tailscale-unifi/main/install.sh | sh
   ```

2. Run `tailscale up` to start Tailscale.
3. Follow the on-screen steps to configure Tailscale and connect it to your network.
4. Confirm that Tailscale is working by running `tailscale status`

## Compatibility

> [!TIP]
> You can confirm your UniFi OS (UOS) version by running `/usr/bin/ubnt-device-info firmware_detail`

This package is compatible with UniFi OS 2.x or later and works on the following UniFi families:

- Any variant of the UniFi Cloud Gateway family
- Any variant of the UniFi Control Plane family
- Any variant of the UniFi Independent Gateway family
- Any UniFi device running UniFi OS 2.x or later and not listed above or below

> [!NOTE]
> These devices are supported only in userspace networking mode, because their kernel does not support the required modules. See [Userspace networking on NVR and NAS devices](#userspace-networking-on-nvr-and-nas-devices).

- Any variant of the UniFi Next-Gen NVR family
- Any variant of the UniFi Next-Gen Storage family

> [!IMPORTANT]
> This package is **NOT** compatible with these UniFi device variants:

- Any variant of the UniFi Cloud Key Gen 1 (UCK-G1)
- Any variant of the UniFi Security Gateway (USG)
- Any variant of the UniFi Travel Router (UTR)
- Any variant of a UniFi device running BusyBox
- Any variant of a UniFi device running UniFi OS 1.x (Legacy OS w/ Podman)
- Any variant of a UniFi device that has reached end-of-life (EoL) and is not listed above

We expect this to work on most UniFi devices, but if you run into any problems, please [open an issue](https://github.com/SierraSoftworks/tailscale-unifi/issues) and include the device you are running on, the UniFi OS version you are running, and the steps you took to install Tailscale, along with any errors you encountered.

> [!WARNING]
> This package is no longer compatible with UniFi OS 1.x (Legacy OS w/ Podman). If you cannot upgrade to the latest stable UniFi OS version, use the [latest v2.x release](https://github.com/SierraSoftworks/tailscale-unifi/releases/tag/v2.8.0) from the `legacy` branch of this repository. We no longer maintain support for UniFi OS 1.x.

## Management

### Configuring Tailscale

You can configure Tailscale using the normal `tailscale up` options; it should be on your path after installation.

```sh
tailscale up --advertise-routes=10.0.0.0/24 --advertise-exit-node
```

### Restarting Tailscale

Tailscale is managed using `systemd` and the `tailscaled` service (in the same way as any other Linux system). You can restart it using the following command.

```sh
systemctl restart tailscaled
```

### Upgrading Tailscale

Upgrading Tailscale on UniFi OS can be done with `apt` or the `manage.sh` helper script.

#### Using `apt`

```sh
apt update && apt install -y tailscale
```

#### Using `manage.sh`

```sh
/data/tailscale/manage.sh update

# Or, if you are connected over Tailscale and want to run the update anyway
nohup /data/tailscale/manage.sh update!
```

### Remove Tailscale

To remove Tailscale, run the following command.

```sh
/data/tailscale/manage.sh uninstall
```

## Contributing

If you have an idea for how this can be improved, please create a [PR](https://github.com/SierraSoftworks/tailscale-unifi/pulls), and we’ll be happy to incorporate the changes.

## Troubleshooting

The installer and `manage.sh status` print a `NOTICE:` for hardware with known device-specific issues, linking to the relevant entry below. Notices are informational only and never change your configuration. To silence them, set `TAILSCALE_ADVISORIES="false"` in `/data/tailscale/tailscale-env`.

### Slow TCP throughput on Cloud Gateway devices

**Affects:** UniFi Cloud Gateway Max (reported in [#205](https://github.com/SierraSoftworks/tailscale-unifi/issues/205)); other Cloud Gateway models may be affected.

**Symptoms:** With Tailscale running in TUN mode as a subnet router, TCP connections from tailnet peers to LAN hosts behind the gateway are unusably slow (hundreds of kbps, heavy retransmits) while `ping` works and userspace networking mode runs at full speed.

**Cause:** Tailscale coalesces decrypted TCP segments into large GSO super-packets before handing them to the kernel. The Cloud Gateway's LAN port TSO engine mishandles these forwarded packets, so only small retransmitted segments get through. This is an upstream issue between Tailscale and UniFi OS; the settings below work around it.

**Confirm the cause:** Before changing Tailscale's configuration, prove that TSO on the LAN bridge is responsible. Disable it at runtime and re-run your throughput test (`iperf3` from a tailnet peer to a LAN host, or a large file transfer):

```sh
# Substitute the bridge for the affected network; br0 is the default LAN
ethtool -K br0 tso off
```

If throughput recovers, this entry applies to you. Re-enable TSO afterwards with `ethtool -K br0 tso on`, since this setting affects all routed traffic on the bridge, is lost on reboot, and can be silently reverted when UniFi reconfigures the bridge. If throughput does not recover, the cause is elsewhere; see [Reporting device-specific issues](#reporting-device-specific-issues).

**Fix:** Tell Tailscale not to build the super-packets in the first place, so the LAN port never receives them.

```sh
# 1. Add the setting to your tailscale-env file
echo 'TS_TUN_DISABLE_TCP_GRO=1' >> /data/tailscale/tailscale-env

# 2. Apply the configuration and restart tailscaled
#    (install! is required while tailscaled is running)
/data/tailscale/manage.sh install!
```

This persists across reboots and package upgrades and only affects Tailscale traffic.

> [!NOTE]
> `TS_TUN_DISABLE_TCP_GRO=1` trades a hardware offload for correctness. On a device that is not affected by this issue, Tailscale has to hand every decrypted segment to the kernel individually rather than in batches, which raises CPU usage per packet and can lower peak TCP throughput over the tunnel. Only set it once the confirmation step above shows that it is needed.

### Userspace networking on NVR and NAS devices

**Affects:** UniFi Next-Gen NVR and Next-Gen Storage families (UNVR, UNVR Pro, UNAS Pro, and similar).

**Symptoms:** No `tailscale0` interface. Machines on the local network cannot reach tailnet addresses or subnets advertised by other nodes, and connections arriving from the tailnet appear to LAN hosts to originate from the device itself.

**Cause:** These kernels do not ship the TUN module, so the installer configures `--tun userspace-networking` automatically. In this mode Tailscale terminates tailnet connections in its own network stack and re-originates them from the device, effectively NAT-ing all traffic. Using the device as an exit node or as a subnet router for inbound access to the local network still works, but local machines see the device's address rather than the tailnet peer's, and traffic from the local network cannot be routed into the tailnet, so site-to-site routing is not possible.

**Fix:** None available on this hardware. If you need site-to-site routing or want local machines to reach the tailnet, run that subnet router on a Cloud Gateway or another device with TUN support.

### Reporting device-specific issues

When [opening an issue](https://github.com/SierraSoftworks/tailscale-unifi/issues), include the output of the following commands so the problem can be tied to a specific model, firmware and kernel:

```sh
ubnt-device-info model
ubnt-device-info firmware_detail
uname -r
tailscale version
cat /data/tailscale/tailscale-env
```

## Frequently Asked Questions

### How do I configure environment variables for tailscaled?

Add any `TS_` environment variables to `/data/tailscale/tailscale-env`, one per line. For example, the setting used in [Slow TCP throughput on Cloud Gateway devices](#slow-tcp-throughput-on-cloud-gateway-devices):

```sh
TS_TUN_DISABLE_TCP_GRO=1
```

Then run `/data/tailscale/manage.sh install!`. The installer replaces the managed environment section in `/etc/default/tailscaled` (and removes/overwrites any existing `TS_*` entries there). Removing a `TS_` entry from `tailscale-env` and running the installer again also removes it from the managed section. `install!` restarts `tailscaled`, so no separate restart is needed. These settings survive `manage.sh update` and package upgrades.

> [!NOTE]
> Plain `manage.sh install` exits early when `tailscaled` is already running, so configuration changes only take effect with `install!`.

### How do I advertise routes?

Set your Tailscale configuration as you would on any other machine.

```sh
# Specify the routes you'd like to advertise using their CIDR notation
tailscale up --advertise-routes="10.0.0.0/24,192.168.0.0/24"
```

### Can I automatically route traffic from machines on my local network to Tailscale endpoints?

Yes! As of January 30, 2025, [two][tailscale-pr10828] [changes][tailscale-pr14452] to Tailscale made this possible. Much credit goes to @tomvoss and @jasonwbarnett, who contributed significant effort to the initial implementation, detailed in [this GitHub discussion][tailnet-routing-discussion]. Before continuing, review Tailscale’s [subnet router documentation][tailscale-subnet-router-docs] and make sure you understand subnet routers independently of UniFi OS.

#### Prerequisites

> [!NOTE]
> You do not need to manually enable `net.ipv4.ip_forward` on your UniFi OS device, as it is enabled by default. If you want to confirm its status, run:

```sh
sysctl net.ipv4.ip_forward
```

> [!WARNING]
> Make these changes over a direct network connection to your UniFi OS device, as you may lose access if you misconfigure Tailscale or other network settings.

#### Switch to TUN mode

The quickest way to switch to TUN mode is to install the latest version of tailscale-unifi, which automatically configures Tailscale to use TUN mode on compatible devices. Keep in mind that devices which only support userspace networking mode cannot be used in this manner.

```sh
curl -sSLq https://raw.githubusercontent.com/SierraSoftworks/tailscale-unifi/main/install.sh | sh
```

##### Manually Switching to TUN Mode

If you have been running Tailscale on your UniFi device for a while, you may be using “userspace” networking mode. This mode is not compatible with advertising routes, so you need to switch to TUN mode first.

Edit your `/data/tailscale/tailscale-env` file and ensure that the `TAILSCALED_FLAGS` variable does **NOT** include the `--tun userspace-networking` flag. Unless you have manually configured any other options, it should look like this:

```sh
PORT="41641"
TAILSCALED_FLAGS=""
TAILSCALE_FLAGS=""
TAILSCALE_AUTOUPDATE="true"
TAILSCALE_CHANNEL="stable"
TAILSCALE_ADVISORIES="true"
```

Then re-configure Tailscale by running `/data/tailscale/manage.sh install!`, which updates your `/etc/default/tailscaled` file to use the new configuration and restarts the `tailscaled` service.

#### Verifying Your Setup

To ensure that Tailscale is running correctly, check for the existence of the `tailscale0` network interface:

```sh
ip link show tailscale0
```

A successful setup should return output similar to:

```text
129: tailscale0: <POINTOPOINT,MULTICAST,NOARP,UP,LOWER_UP> mtu 1280 qdisc pfifo_fast state UNKNOWN mode DEFAULT group default qlen 500
    link/none
```

If you see `Device "tailscale0" does not exist`, you are still running in [userspace networking mode][tailscale-userspace-networking-docs], which will not work. Follow the steps above to switch to TUN mode and try again.

#### Final Configuration

Once you have verified that you are not running in userspace networking mode, proceed with configuring Tailscale:

```sh
tailscale up --advertise-exit-node --advertise-routes="<one-or-more-local-subnets>" --snat-subnet-routes=false --accept-routes --reset
```

Example:

```sh
tailscale up --advertise-exit-node --advertise-routes="10.0.0.0/24" --snat-subnet-routes=false --accept-routes --reset
```

For more details on available options, see the official [tailscale up command documentation][tailscale-up-docs].

### Why can’t I see a Tailscale network interface?

Legacy versions of the tailscale-unifi script configured Tailscale to run in userspace networking mode on the device instead of as a TUN interface, so you wouldn’t see it in the `ip addr` list.

If you are running an older version of tailscale-unifi, you can switch to TUN mode by following the [instructions above](#manually-switching-to-tun-mode).

### Does this support Tailscale SSH?

You bet. Make sure you’re running the latest version of Tailscale, then run `tailscale up --ssh` to enable it. You’ll need to set up SSH ACLs in your account by following [this guide](https://tailscale.com/kb/1193/tailscale-ssh/).

```sh
# Update Tailscale to its latest version
/data/tailscale/manage.sh update!

# Enable SSH advertisement through Tailscale
tailscale up --ssh
```

### How do I generate HTTPS certificates with Tailscale?

Tailscale can generate valid HTTPS certificates for your device using Let’s Encrypt. This requires MagicDNS and HTTPS to be enabled in your Tailscale admin console.

```sh
# Generate a certificate
/data/tailscale/manage.sh cert generate

# Renew an existing certificate before it expires. If it is the active UniFi
# certificate, the same UniFi certificate record is updated automatically.
/data/tailscale/manage.sh cert renew

# Install certificate into UniFi OS
/data/tailscale/manage.sh cert install-unifi

# Restart UniFi Core after the initial installation
systemctl restart unifi-core
```

Certificates expire after 90 days. The hostname is automatically determined from your Tailscale configuration.

On UniFi OS, a systemd timer is automatically installed when you generate your first certificate. This timer runs weekly to check and renew certificates before they expire. If the active UniFi certificate was installed from Tailscale (it matches the Tailscale certificate, or was issued for this device's Tailscale hostname) and differs from the current Tailscale certificate, renewal updates its files and database record and restarts UniFi Core. This also catches up after Tailscale renews the certificate in the background, which it does once the certificate is inside its renewal window. A certificate for any other hostname is left untouched.

[tailscale-pr10828]: https://github.com/tailscale/tailscale/pull/10828
[tailscale-pr14452]: https://github.com/tailscale/tailscale/pull/14452
[tailnet-routing-discussion]: https://github.com/SierraSoftworks/tailscale-unifi/discussions/51
[tailscale-subnet-router-docs]: https://tailscale.com/kb/1019/subnets
[tailscale-up-docs]: https://tailscale.com/kb/1241/tailscale-up
[tailscale-userspace-networking-docs]: https://tailscale.com/kb/1112/userspace-networking
