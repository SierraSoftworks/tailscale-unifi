#!/bin/sh
set -e

# Determine the latest version of the Tailscale UniFi package
VERSION="${1:-latest}"

if [ "${VERSION}" = "latest" ]; then
  # shellcheck disable=SC2034 # Disable incorrect unused variable warning
  PACKAGE_URL="https://github.com/SierraSoftworks/tailscale-unifi/releases/latest/download/tailscale-unifi.tgz"
else
  PACKAGE_URL="https://github.com/SierraSoftworks/tailscale-unifi/releases/download/${VERSION}/tailscale-unifi.tgz"
fi

# Setup a temporary directory to download the package
WORKDIR="$(mktemp -d || exit 1)"
trap 'rm -rf ${WORKDIR}' EXIT

# Download the Tailscale-UniFi package
curl -sSLf --ipv4 -o "${WORKDIR}/tailscale.tgz" "$PACKAGE_URL"

if [ -x "$(which ubnt-device-info)" ]; then
  OS_VERSION="${FW_VERSION:-$(ubnt-device-info firmware_detail | grep -oE '^[0-9]+')}"
elif [ -f "/usr/lib/version" ]; then
  # UCKP == Unifi CloudKey Gen2 Plus
  # example /usr/lib/version file contents:
  # UCKP.apq8053.v2.5.11.b2ebfc7.220801.1419
  # UCKP.apq8053.v3.0.17.8102bbc.230210.1526
  # UCKG2 == UniFi CloudKey Gen2
  # example /usr/lib/version file contents:
  # UCKG2.apq8053.v3.1.13.3584673.230626.2239
  # UNASPRO == Unas Pro
  # example /usr/lib/version file contents:
  # UNASPRO.al324.v4.2.9.3ec2ce6.250417.1324
  if [ "$(grep -c '^UCKP.*\.v[0-9]\.' /usr/lib/version)" = '1' ]; then
    OS_VERSION="$(sed -e 's/UCKP.*.v\(.\)\..*/\1/' /usr/lib/version)"
  elif [ "$(grep -c '^UCKG2.*\.v[0-9]\.' /usr/lib/version)" = '1' ]; then
    OS_VERSION="$(sed -e 's/UCKG2.*.v\(.\)\..*/\1/' /usr/lib/version)"
  elif [ "$(grep -c '^UNASPRO.*\.v[0-9]\.' /usr/lib/version)" = '1' ]; then
    OS_VERSION="$(sed -e 's/UNASPRO.*.v\(.\)\..*/\1/' /usr/lib/version)"
  elif [ "$(grep -c '^UNAS.*\.v[0-9]\.' /usr/lib/version)" = '1' ]; then
    OS_VERSION="$(sed -e 's/UNAS.*.v\(.\)\..*/\1/' /usr/lib/version)"
  else
    echo "Could not detect OS Version.  /usr/lib/version contains:"
    cat /usr/lib/version
    exit 1
  fi
else
  echo "Could not detect OS Version.  No ubnt-device-info, no version file."
  exit 1
fi

if [ "$OS_VERSION" = '1' ]; then
  export PACKAGE_ROOT="/mnt/data/tailscale"
else
  export PACKAGE_ROOT="/data/tailscale"
fi

# Extract the package
tar xzf "${WORKDIR}/tailscale.tgz" -C "$(dirname -- "${PACKAGE_ROOT}")"

# Update tailscale-env with modified values
if [ -n "${TAILSCALED_FLAGS:-}" ]; then
  echo "TAILSCALED_FLAGS=\"${TAILSCALED_FLAGS}\"" >> "$PACKAGE_ROOT/tailscale-env"
elif ! modprobe tun 2>/dev/null; then
  echo "TUN kernel module not available, defaulting to userspace networking."
  echo 'TAILSCALED_FLAGS="--tun userspace-networking"' >> "$PACKAGE_ROOT/tailscale-env"
fi

# Run the setup script to ensure that Tailscale is installed
# shellcheck source=package/manage.sh
"$PACKAGE_ROOT/manage.sh" install "${TAILSCALE_VERSION}"

# Start the tailscaled daemon
# shellcheck source=package/manage.sh
"$PACKAGE_ROOT/manage.sh" start
