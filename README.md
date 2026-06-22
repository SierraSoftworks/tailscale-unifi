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
> These devices are supported only in userspace networking mode, because their kernel does not support the required modules.

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

## Frequently Asked Questions

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
```

Then re-configure Tailscale by running `/data/tailscale/manage.sh install`, which updates your `/etc/default/tailscaled` file to use the new configuration and restarts the `tailscaled` service.

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

# Renew an existing certificate before it expires
/data/tailscale/manage.sh cert renew

# Install certificate into UniFi OS
/data/tailscale/manage.sh cert install-unifi

# Restart UniFi Core to apply
systemctl restart unifi-core
```

Certificates expire after 90 days. The hostname is automatically determined from your Tailscale configuration.

On UniFi OS, a systemd timer is automatically installed when you generate your first certificate. This timer runs weekly to check and renew certificates before they expire.

[tailscale-pr10828]: https://github.com/tailscale/tailscale/pull/10828
[tailscale-pr14452]: https://github.com/tailscale/tailscale/pull/14452
[tailnet-routing-discussion]: https://github.com/SierraSoftworks/tailscale-unifi/discussions/51
[tailscale-subnet-router-docs]: https://tailscale.com/kb/1019/subnets
[tailscale-up-docs]: https://tailscale.com/kb/1241/tailscale-up
[tailscale-userspace-networking-docs]: https://tailscale.com/kb/1112/userspace-networking
