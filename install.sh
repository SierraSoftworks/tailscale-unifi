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
  if [ "$(grep -c '^UCKG2.*\.v[0-9]\.' /usr/lib/version)" = '1' ]; then
    OS_VERSION="$(sed -e 's/UCKG2.*.v\(.\)\..*/\1/' /usr/lib/version)"
  elif [ "$(grep -c '^UCKP.*\.v[0-9]\.' /usr/lib/version)" = '1' ]; then
    OS_VERSION="$(sed -e 's/UCKP.*.v\(.\)\..*/\1/' /usr/lib/version)"
  elif [ "$(grep -c '^UNASPRO.*\.v[0-9]\.' /usr/lib/version)" = '1' ]; then
    OS_VERSION="$(sed -e 's/UNASPRO.*.v\(.\)\..*/\1/' /usr/lib/version)"
  elif [ "$(grep -c '^UNAS.*\.v[0-9]\.' /usr/lib/version)" = '1' ]; then
    OS_VERSION="$(sed -e 's/UNAS.*.v\(.\)\..*/\1/' /usr/lib/version)"
  elif [ "$(grep -c '^UNVRPRO.*\.v[0-9]\.' /usr/lib/version)" = '1' ]; then
    OS_VERSION="$(sed -e 's/UNVRPRO.*.v\(.\)\..*/\1/' /usr/lib/version)"
  elif [ "$(grep -c '^UNVR4.*\.v[0-9]\.' /usr/lib/version)" = '1' ]; then
    OS_VERSION="$(sed -e 's/UNVR4.*.v\(.\)\..*/\1/' /usr/lib/version)"
  elif [ "$(grep -c '^UNVRAI.*\.v[0-9]\.' /usr/lib/version)" = '1' ]; then
    OS_VERSION="$(sed -e 's/UNVRAI.*.v\(.\)\..*/\1/' /usr/lib/version)"
  elif [ "$(grep -c '^UNVRINS.*\.v[0-9]\.' /usr/lib/version)" = '1' ]; then
    OS_VERSION="$(sed -e 's/UNVRINS.*.v\(.\)\..*/\1/' /usr/lib/version)"
  else
    echo "Could not detect OS Version.  /usr/lib/version contains:"
    cat /usr/lib/version
    exit 1
  fi
else
  echo "Could not detect OS Version.  No ubnt-device-info, no version file."
  exit 1
fi

if [ -n "${PACKAGE_ROOT:-}" ]; then
  # Allow the install location to be overridden (used by the test suite).
  export PACKAGE_ROOT
elif [ "$OS_VERSION" = '1' ]; then
  export PACKAGE_ROOT="/mnt/data/tailscale"
else
  export PACKAGE_ROOT="/data/tailscale"
fi
ENV_FILE="${PACKAGE_ROOT}/tailscale-env"

# The package ships a default tailscale-env, so extracting it over an existing
# install would wipe the user's settings (TS_* variables, flags, channel).  Keep
# a copy of the existing file so it can be restored after extraction.
if [ -f "$ENV_FILE" ]; then
  cp "$ENV_FILE" "${WORKDIR}/tailscale-env.existing"
fi

# Extract the package
tar xzf "${WORKDIR}/tailscale.tgz" -C "$(dirname -- "${PACKAGE_ROOT}")"

if [ -f "${WORKDIR}/tailscale-env.existing" ]; then
  echo "Keeping your existing ${ENV_FILE}"
  cp "$ENV_FILE" "${WORKDIR}/tailscale-env.default"
  cp "${WORKDIR}/tailscale-env.existing" "$ENV_FILE"

  # Add any settings introduced by this release that the existing file lacks,
  # using the packaged default values.
  while IFS= read -r line || [ -n "$line" ]; do
    key="${line%%=*}"
    case "$key" in
      ''|\#*|*[!A-Za-z0-9_]*) continue ;;
    esac
    if ! grep -q "^${key}=" "$ENV_FILE"; then
      printf '%s\n' "$line" >> "$ENV_FILE"
    fi
  done < "${WORKDIR}/tailscale-env.default"
fi

# set_tailscaled_flags <flags>
#
# Replace the TAILSCALED_FLAGS line in tailscale-env, rather than appending
# another one on every run.
set_tailscaled_flags() {
  grep -v '^TAILSCALED_FLAGS=' "$ENV_FILE" > "${WORKDIR}/tailscale-env.new" || true
  printf 'TAILSCALED_FLAGS="%s"\n' "$1" >> "${WORKDIR}/tailscale-env.new"
  cat "${WORKDIR}/tailscale-env.new" > "$ENV_FILE"
}

# Update tailscale-env with modified values
if [ -n "${TAILSCALED_FLAGS:-}" ]; then
  set_tailscaled_flags "${TAILSCALED_FLAGS}"
elif [ ! -e /dev/net/tun ]; then
  current_flags="$(sed -n 's/^TAILSCALED_FLAGS="\{0,1\}\([^"]*\)"\{0,1\}[[:space:]]*$/\1/p' "$ENV_FILE" | tail -n 1)"
  case "$current_flags" in
    *userspace-networking*) ;;
    *)
      echo "TUN device (/dev/net/tun) not found, defaulting to userspace networking."
      set_tailscaled_flags "--tun userspace-networking${current_flags:+ ${current_flags}}"
      ;;
  esac
fi

# Run the setup script to ensure that Tailscale is installed
# shellcheck source=package/manage.sh
"$PACKAGE_ROOT/manage.sh" install "${TAILSCALE_VERSION}"

# Start the tailscaled daemon
# shellcheck source=package/manage.sh
"$PACKAGE_ROOT/manage.sh" start