# Tailscale on UniFi OS

This repo contains the scripts necessary to install and run a [Tailscale](https://tailscale.com) instance on your [UniFi Cloud Gateways](https://ui.com/cloud-gateways).
It does so by piggybacking on the excellent [unifi-common](https://github.com/unifi-utilities/unifi-common) to provide a persistent service and run using Tailscale's networking features.

## Installation

1. Run the `install.sh` script to install the latest version of the
   Tailscale UniFi package on your device.

   ```sh
   # Install the latest version of Tailscale UniFi
   curl -sSLq https://raw.githubusercontent.com/SierraSoftworks/tailscale-unifi/main/install.sh | sh
   ```

2. Run `tailscale up` to start Tailscale.
3. Follow the on-screen steps to configure Tailscale and connect it to your network.
4. Confirm that Tailscale is working by running `tailscale status`

## Compatibility

**ⓘ You can confirm your UniFi OS (UOS) version by running `/usr/bin/ubnt-device-info firmware_detail`**

This package is compatible with UniFi OS 2.x or later and is known to work on the following UniFi families:

- Any variant of the UniFi Cloud Gateway families
- Any variant of the UniFi Control Plane families
- Any variant of the UniFi Independent Gateway families
- Any variant of the UniFi Next-Gen NVR families
  > **Note:** This device is only supported via userspace networking mode, as the kernel on this device does not support the required modules.
- Any variant of the UniFi Next-Gen Storage families
  > **Note:** This device is only supported via userspace networking mode, as the kernel on this device does not support the required modules.
- Any variant of a UniFi device running UniFi OS 2.x or later not listed above or below

This package is **NOT** compatible with the following variants of UniFi devices:

- Any variant of the UniFi Cloud Key Gen 1 (UCK-G1)
- Any variant of the UniFi Security Gateway (USG)
- Any variant of the UniFi Travel Router (UTR)
- Any variant of a UniFi device running BusyBox
- Any variant of a UniFi device running UniFi OS 1.x (Legacy OS w/ Podman)
- Any variant of an EoL UniFi device not listed above

We expect that it should function on most consumer-grade UniFi devices without issue, but if you run into any problems, please [open an issue](https://github.com/SierraSoftworks/tailscale-unifi/issues) and provide the following information:

- The device you are running on (e.g., UDM Pro)
- The UniFi OS version you are running (e.g., 2.4.8 - this can be found by running `/usr/bin/ubnt-device-info firmware_detail`)
- The steps you took to install Tailscale and any errors you encountered.

**WARNING:** This package is no longer compatible with UniFi OS 1.x (Legacy OS w/ Podman). If you are running UniFi OS 1.x and cannot upgrade to the latest stable version, use the legacy version of this package, available in the `legacy` branch of this repository. The legacy version is no longer maintained and may not work with the latest Tailscale release.

## Management

### Configuring Tailscale

You can configure Tailscale using all the normal `tailscale up` options; you should be able to find `tailscale` on your path after installation.

```sh
tailscale up --advertise-routes=10.0.0.0/24 --advertise-exit-node --advertise-tags=tag:it
```

### Restarting Tailscale

On UniFi OS 2.x+, Tailscale is managed using `systemd` and the `tailscaled` service. You can restart it using the following command.

```sh
systemctl restart tailscaled
```

### Upgrading Tailscale

Upgrading Tailscale on UniFi OS 2.x+ can be done either with `apt` or with the `manage.sh` helper script.

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

To remove Tailscale, you can run the following command or run the steps below manually.

```sh
/data/tailscale/manage.sh uninstall
```

#### Manual Steps

1. Kill the `tailscaled` daemon with `systemctl stop tailscaled`.
2. Remove the `tailscale` & `tailscale-archive-keyring` package using `dpkg -P tailscale tailscale-archive-keyring`.
3. Remove the management script and state using `rm -Rf /data/tailscale`.
4. Remove the `on_boot.d` script using `rm /data/on_boot.d/10-tailscaled.sh`.
5. Remove the `cache` folder using `rm -rf /var/cache/tailscale`.

## Contributing

There are clearly many folks interested in running Tailscale on their UDMs. If you're one of those people and have an idea for how this can be improved, please create a PR, and we'll be more than happy to incorporate the changes.

## Frequently Asked Questions

### How do I advertise routes?

You do this by updating your Tailscale configuration as you would on any other machine; remember to include the full path to the `tailscale` binary.

```sh
# Specify the routes you'd like to advertise using their CIDR notation

# UniFi OS 1.x
/mnt/data/tailscale/tailscale up --advertise-routes="10.0.0.0/24,192.168.0.0/24"

# UniFi OS 2.x/3.x
tailscale up --advertise-routes="10.0.0.0/24,192.168.0.0/24"
```

### Can I automatically route traffic from machines on my local network to Tailscale endpoints?

Yes! As of January 30, 2025, [two][tailscale-pr10828] [changes][tailscale-pr14452] to Tailscale have made this possible. Much credit goes to @tomvoss and @jasonwbarnett, who contributed significant effort to the initial implementation, detailed in this GitHub issue [tailnet-routing-discussion]. Before going further, please read Tailscale's [subnet router documentation][tailscale-subnet-router-docs] and familiarize yourself with the concepts of subnet routers, independent of UniFi OS.

#### Prerequisites

Before proceeding, please review Tailscale’s [subnet router documentation][tailscale-subnet-router-docs] to understand the core concepts of subnet routing, independent of UniFi OS.

**NOTE**: You do not need to manually enable `net.ipv4.ip_forward` on your UniFi OS device as it is enabled by default. If you want to confirm its status, run:

```sh
sysctl net.ipv4.ip_forward
```

**WARNING**: You should conduct all of these changes over a direct network connection to your UniFi OS device, as you may lose access to the device if you misconfigure Tailscale or other network settings.

#### Switch to TUN mode

The quickest way to switch to TUN mode is to install the latest version of tailscale-unifi, which will automatically configure Tailscale to use TUN mode.

```bash
curl -sSLq https://raw.githubusercontent.com/SierraSoftworks/tailscale-unifi/main/install.sh | sh
```

##### Manually Switching to TUN Mode

If you have been running Tailscale on your UniFi device for a while, there is a good chance you are using "userspace" networking mode. This mode is not compatible with advertising routes, so you will need to switch to TUN mode.

To do so, edit your `/data/tailscale/tailscale-env` file and ensure that the `TAILSCALED_FLAGS` variable does **NOT** include the `--tun userspace-networking` flag. Unless you have manually configured any other options, it should look like this:

```bash
PORT="41641"
TAILSCALED_FLAGS=""
TAILSCALE_FLAGS=""
TAILSCALE_AUTOUPDATE="true"
TAILSCALE_CHANNEL="stable"
```

Then re-configure Tailscale by running `/data/tailscale/manage.sh install`, which will update your `/etc/default/tailscaled` file to use the new configuration and restart the `tailscaled` service.

#### Verifying Your Setup

To ensure that Tailscale is running correctly, check for the existence of the tailscale0 network interface:

```sh
ip link show tailscale0
```

A successful setup should return output similar to:

```text
129: tailscale0: <POINTOPOINT,MULTICAST,NOARP,UP,LOWER_UP> mtu 1280 qdisc pfifo_fast state UNKNOWN mode DEFAULT group default qlen 500
    link/none
```

If you see `Device "tailscale0" does not exist.` instead, it means you are still running in [userspace networking mode][tailscale-userspace-networking-docs], which will not work. Follow the steps above to switch to TUN mode and try again.

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

### Why can't I see a network interface for Tailscale?

Legacy versions of the tailscale-udm script configured Tailscale to run in userspace networking mode on the UDM rather than as a TUN interface, which meant you wouldn't see it in the `ip addr` list.

If you are running an older version of tailscale-udm, you can switch to TUN mode by following the [instructions above](#manually-switching-to-tun-mode).

### Does this support Tailscale SSH?

You bet, make sure you're running the latest version of Tailscale and then run `tailscale up --ssh` to enable it. You'll need to set up SSH ACLs in your account by following [this guide](https://tailscale.com/kb/1193/tailscale-ssh/).

```sh
# UniFi OS 1.x
# Update Tailscale to its latest version
/mnt/data/tailscale/manage.sh update!

# Enable SSH advertisement through Tailscale
/mnt/data/tailscale/tailscale up --ssh

# UniFi OS 2.x/3.x
# Update Tailscale to its latest version
/data/tailscale/manage.sh update!

# Enable SSH advertisement through Tailscale
tailscale up --ssh
```

### How do I generate HTTPS certificates with Tailscale?

Tailscale can generate valid HTTPS certificates for your UDM using Let's Encrypt. This requires:

- MagicDNS enabled in your Tailscale admin console
- HTTPS enabled in your Tailscale admin console

```sh
# Generate a certificate
/data/tailscale/manage.sh cert generate

# Install certificate into UniFi OS (2.x+)
/data/tailscale/manage.sh cert install-unifi

# Restart UniFi Core to apply
systemctl restart unifi-core
```

Certificates expire after 90 days. Use `cert renew` to renew them.
The hostname is automatically determined from your Tailscale configuration.

On UniFi OS 2.x+, a systemd timer is automatically installed when you generate your first certificate. This timer runs weekly to check and renew certificates before they expire.

[tailscale-pr10828]: https://github.com/tailscale/tailscale/pull/10828
[tailscale-pr14452]: https://github.com/tailscale/tailscale/pull/14452
[tailnet-routing-discussion]: https://github.com/SierraSoftworks/tailscale-unifi/discussions/51
[tailscale-subnet-router-docs]: https://tailscale.com/kb/1019/subnets
[tailscale-up-docs]: https://tailscale.com/kb/1241/tailscale-up
[tailscale-userspace-networking-docs]: https://tailscale.com/kb/1112/userspace-networking
