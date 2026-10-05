#!/bin/sh
set -e

PACKAGE_ROOT="${PACKAGE_ROOT:-"$(dirname -- "$(readlink -f -- "$0";)")"}"
export TAILSCALE_ROOT="${TAILSCALE_ROOT:-/data/tailscale}"
SYSTEMD_UNIT_DIR="${SYSTEMD_UNIT_DIR:-/etc/systemd/system}"
TAILSCALED_DEFAULTS_FILE="${TAILSCALED_DEFAULTS_FILE:-/etc/default/tailscaled}"
TAILSCALED_ENVIRONMENT_MARKER="# tailscale-unifi managed environment"
UNIFI_CONFIG_DIR="${UNIFI_CONFIG_DIR:-/data/unifi-core/config}"
README_URL="https://github.com/SierraSoftworks/tailscale-unifi"

# Best-effort identification of the UniFi hardware we are running on, used to
# surface device-specific guidance from the README.  Returns the full model name
# (e.g. "UniFi Cloud Gateway Max") on UniFi OS 2+, falls back to the product
# prefix in /usr/lib/version (e.g. "UNVRPRO") on older firmware, and is empty
# when neither source is available.  TAILSCALE_DEVICE_MODEL overrides detection.
detect_device_model() {
  if [ -n "${TAILSCALE_DEVICE_MODEL:-}" ]; then
    echo "$TAILSCALE_DEVICE_MODEL"
  elif command -v ubnt-device-info >/dev/null 2>&1; then
    ubnt-device-info model 2>/dev/null || true
  elif [ -f /usr/lib/version ]; then
    cut -d. -f1 /usr/lib/version
  fi
}

device_advisory() {
  _advisory_title="$1"
  _advisory_body="$2"
  _advisory_anchor="$3"

  {
    echo ""
    echo "NOTICE: ${_advisory_title}"
    echo "  ${_advisory_body}"
    echo "  See: ${README_URL}#${_advisory_anchor}"
  } >&2
}

# Read a single KEY="VALUE" (or KEY=VALUE) setting from tailscale-env without
# executing the file, so advisories never widen what `status` runs as shell.
read_env_setting() {
  _env_file="${TAILSCALE_ROOT}/tailscale-env"
  [ -f "$_env_file" ] || return 0
  sed -n "s/^$1=\"\{0,1\}\([^\"]*\)\"\{0,1\}[[:space:]]*\$/\1/p" "$_env_file" | tail -n 1
}

# Print README pointers for known device-specific issues.  Each case below maps a
# model (as returned by detect_device_model) to a README "Troubleshooting" entry;
# entries are skipped when the documented mitigation is already configured.
# Advisories are informational only and never change configuration.  Set
# TAILSCALE_ADVISORIES="false" in tailscale-env to silence them.
print_device_advisories() {
  _advisories="$(read_env_setting TAILSCALE_ADVISORIES)"
  [ "${_advisories:-true}" = "true" ] || return 0

  _model="$(detect_device_model)"
  [ -n "$_model" ] || return 0

  _tun_tcp_gro="$(read_env_setting TS_TUN_DISABLE_TCP_GRO)"
  _tailscaled_flags="$(read_env_setting TAILSCALED_FLAGS)"

  case "$_model" in
    *"Cloud Gateway"*|UCG*)
      case "$_tailscaled_flags" in
        *userspace-networking*) ;;
        *)
          if [ "${_tun_tcp_gro:-0}" != "1" ]; then
            device_advisory "Slow TCP throughput reported on Cloud Gateway devices (${_model})" \
              "TCP traffic forwarded to LAN hosts over Tailscale can collapse to a few hundred kbps on some Cloud Gateway models. Setting TS_TUN_DISABLE_TCP_GRO=1 in ${TAILSCALE_ROOT}/tailscale-env resolves this." \
              "slow-tcp-throughput-on-cloud-gateway-devices"
          fi
          ;;
      esac
      ;;
    *"Network Video Recorder"*|*"UNVR"*|*"UNAS"*|*"Storage"*)
      device_advisory "Userspace networking only (${_model})" \
        "This device's kernel lacks TUN support, so Tailscale runs in userspace networking mode: inbound subnet routing and exit node use work, but traffic is NAT-ed and local machines cannot reach the tailnet." \
        "userspace-networking-on-nvr-and-nas-devices"
      ;;
  esac
}

tailscale_status() {
  if ! command -v tailscale >/dev/null 2>&1; then
    echo "Tailscale is not installed"
    exit 1
  elif systemctl is-active --quiet tailscaled; then
    echo "Tailscaled is running"
    tailscale --version
  else
    echo "Tailscaled is not running"
  fi

  print_device_advisories
}

tailscale_start() {
  systemctl start tailscaled

  # Wait a few seconds for the daemon to start
    sleep 5

    if systemctl is-active --quiet tailscaled; then
      echo "Tailscaled started successfully"
    else
      echo "Tailscaled failed to start"
      exit 1
    fi

    echo "Run tailscale up to configure the interface."
}

tailscale_stop() {
  echo "Stopping Tailscale..."
  systemctl stop tailscaled
}

# install_systemd_unit <unit-file-name>
#
# Copy ${PACKAGE_ROOT}/<unit> to ${SYSTEMD_UNIT_DIR}/<unit>, but only when the
# destination is missing, is a symlink, or differs from the packaged copy.
#
# A plain `cp -f` does NOT pre-unlink its destination; it only retries the open
# on failure.  On UDM-SE /data -> /ssd1/.data, so a pre-v3.3.0 symlink at
# ${SYSTEMD_UNIT_DIR}/<unit> pointing back into /data/tailscale/ makes the source
# and destination canonicalise to the same inode and `cp` aborts with "are the
# same file".  Removing the destination first handles symlinks, hard-links and
# regular files uniformly.  /etc lives on the overlay root (always mounted), so
# the copied regular files are readable by systemd on every boot even before
# /ssd1 is mounted -- which is what lets RequiresMountsFor= in the unit be
# honoured at all.
install_systemd_unit() {
  _unit="$1"
  _src="${PACKAGE_ROOT}/${_unit}"
  _dst="${SYSTEMD_UNIT_DIR}/${_unit}"

  # Nothing to do if the package does not ship this unit.
  [ -f "$_src" ] || return 0

  if [ -L "$_dst" ] || [ ! -f "$_dst" ] || ! cmp -s "$_src" "$_dst"; then
    rm -f "$_dst"
    cp "$_src" "$_dst"
  fi
}

# ensure_systemd_units
#
# Install (or repair) the units that reinstall Tailscale after a firmware update,
# and make sure they are enabled.
# Running it unconditionally (not only when Tailscale is missing) is what lets old
# symlink-based installs heal themselves -- the stale symlinks are rewritten as
# plain files while the system is healthy, before the next firmware update makes
# them unreadable to systemd.
ensure_systemd_units() {
  echo "Installing systemd units to keep Tailscale installed across firmware updates."
  install_systemd_unit tailscale-install.service
  install_systemd_unit tailscale-install.timer
  
  systemctl daemon-reload
  systemctl enable tailscale-install.service
  systemctl enable --now tailscale-install.timer
}

ensure_cert_renewal_units() {
  [ -f "${PACKAGE_ROOT}/tailscale-cert-renewal.service" ] || return 0
  [ -f "${PACKAGE_ROOT}/tailscale-cert-renewal.timer" ] || return 0

  echo "Installing certificate auto-renewal timer..."
  install_systemd_unit tailscale-cert-renewal.service
  install_systemd_unit tailscale-cert-renewal.timer
  systemctl daemon-reload
  systemctl enable tailscale-cert-renewal.timer
  systemctl start tailscale-cert-renewal.timer
  echo "Certificate will be automatically renewed weekly"
}

repair_cert_renewal_units_if_configured() {
  for _cert_file in "${TAILSCALE_ROOT}"/certs/*.crt; do
    [ -f "$_cert_file" ] || continue
    [ -f "${_cert_file%.crt}.key" ] || continue
    ensure_cert_renewal_units
    return 0
  done
}

sync_tailscaled_environment() {
  _environment_file="${TAILSCALE_ROOT}/tailscale-env"

  sed -i "/^${TAILSCALED_ENVIRONMENT_MARKER}$/,\$d" "$TAILSCALED_DEFAULTS_FILE"
  sed -i '/^TS_[A-Za-z0-9_]*=/d' "$TAILSCALED_DEFAULTS_FILE"

  printf '%s\n' "$TAILSCALED_ENVIRONMENT_MARKER" >> "$TAILSCALED_DEFAULTS_FILE"
  if [ -f "$_environment_file" ]; then
    grep '^TS_[A-Za-z0-9_]*=' "$_environment_file" >> "$TAILSCALED_DEFAULTS_FILE" || true
  fi
}

tailscale_install() {
  # shellcheck source=tests/os-release
  . "${OS_RELEASE_FILE:-/etc/os-release}"

  # Load the tailscale-env file to discover the flags which are required to be set
  # shellcheck source=package/tailscale-env
  . "${TAILSCALE_ROOT}/tailscale-env"

  tailscale_version="${1:-$(curl -sSLq --ipv4 "https://pkgs.tailscale.com/${TAILSCALE_CHANNEL}/?mode=json" | jq -r '.Tarballs.arm64 | capture("tailscale_(?<version>[^_]+)_").version')}"

  echo "Installing latest Tailscale package repository..."
  if [ "${VERSION_CODENAME}" = "stretch" ]; then
      curl -fsSL --ipv4 "https://pkgs.tailscale.com/${TAILSCALE_CHANNEL}/${ID}/${VERSION_CODENAME}.gpg" | apt-key add -
      curl -fsSL --ipv4 "https://pkgs.tailscale.com/${TAILSCALE_CHANNEL}/${ID}/${VERSION_CODENAME}.list" | tee /etc/apt/sources.list.d/tailscale.list
  else
      curl -fsSL --ipv4 "https://pkgs.tailscale.com/${TAILSCALE_CHANNEL}/${ID}/${VERSION_CODENAME}.noarmor.gpg" | tee /usr/share/keyrings/tailscale-archive-keyring.gpg > /dev/null
      curl -fsSL --ipv4 "https://pkgs.tailscale.com/${TAILSCALE_CHANNEL}/${ID}/${VERSION_CODENAME}.tailscale-keyring.list" | tee /etc/apt/sources.list.d/tailscale.list > /dev/null
  fi

  echo "Updating package lists..."
  apt update

  # Install Tailscale with version pinning if available, otherwise install latest from repo
  if [ -n "$tailscale_version" ] && [ "$tailscale_version" != "null" ]; then
    echo "Installing Tailscale ${tailscale_version}..."
    apt install -y tailscale="${tailscale_version}"
  else
    echo "Installing latest Tailscale from repository (version unavailable)..."
    apt install -y tailscale
  fi

  echo "Configuring Tailscale port..."
  sed -i "s/PORT=\"[^\"]*\"/PORT=\"${PORT:-41641}\"/" "$TAILSCALED_DEFAULTS_FILE" || {
      echo "Failed to configure Tailscale port"
      echo "Check that the file $TAILSCALED_DEFAULTS_FILE exists and contains the line PORT=\"${PORT:-41641}\"."
      exit 1
  }

  echo "Configuring Tailscaled startup flags..."
  sed -i "s@FLAGS=\"[^\"]*\"@FLAGS=\"--state /data/tailscale/tailscaled.state ${TAILSCALED_FLAGS}\"@" "$TAILSCALED_DEFAULTS_FILE" || {
      echo "Failed to configure Tailscaled startup flags"
      echo "Check that the file $TAILSCALED_DEFAULTS_FILE exists and contains the line FLAGS=\"--state /data/tailscale/tailscaled.state ${TAILSCALED_FLAGS}\"."
      exit 1
  }

  echo "Configuring Tailscaled environment..."
  sync_tailscaled_environment

  echo "Restarting Tailscale daemon to detect new configuration..."
  systemctl restart tailscaled.service || {
      echo "Failed to restart Tailscale daemon"
      echo "The daemon might not be running with userspace networking enabled, you can restart it manually using 'systemctl restart tailscaled'."
      exit 1
  }

  echo "Enabling Tailscale to start on boot..."
  systemctl enable tailscaled.service || {
      echo "Failed to enable Tailscale to start on boot"
      echo "You can enable it manually using 'systemctl enable tailscaled'."
      exit 1
  }

  # Install (or repair) the systemd units that reinstall Tailscale after a
  # firmware update.  See ensure_systemd_units / install_systemd_unit above.
  ensure_systemd_units

  print_device_advisories

  echo "Installation complete, run '$0 start' to start Tailscale"
}

tailscale_uninstall() {
  echo "Removing Tailscale"
  apt remove -y tailscale
  rm -f /etc/apt/sources.list.d/tailscale.list || true

  systemctl disable tailscale-install.service || true
  rm -f "${SYSTEMD_UNIT_DIR}/tailscale-install.service" || true

  systemctl disable tailscale-install.timer || true
  rm -f "${SYSTEMD_UNIT_DIR}/tailscale-install.timer" || true

  systemctl disable tailscale-cert-renewal.timer || true
  systemctl stop tailscale-cert-renewal.timer || true
  rm -f "${SYSTEMD_UNIT_DIR}/tailscale-cert-renewal.service" || true
  rm -f "${SYSTEMD_UNIT_DIR}/tailscale-cert-renewal.timer" || true
}

tailscale_has_update() {
  # If Tailscale isn't installed there is nothing to compare against; report
  # "needs install" without the noisy "tailscale: not found" on stderr (this is
  # what `manage.sh update` hits on a device whose binaries were just wiped).
  if ! command -v tailscale >/dev/null 2>&1; then
    return 0
  fi

  CURRENT_VERSION="$(tailscale --version | head -n 1)"
  TARGET_VERSION="${1:-$(curl --ipv4 -sSLq 'https://pkgs.tailscale.com/stable/?mode=json' | jq -r '.Tarballs.arm64 | capture("tailscale_(?<version>[^_]+)_").version')}"

  # Validate TARGET_VERSION is not empty or null
  if [ -z "$TARGET_VERSION" ] || [ "$TARGET_VERSION" = "null" ]; then
    echo "Unable to determine target version (network may be unavailable)"
    return 1
  fi

  if [ "${CURRENT_VERSION}" != "${TARGET_VERSION}" ]; then
    return 0
  else
    return 1
  fi
}

tailscale_update() {
  # Don't stop Tailscale before update - apt can handle the upgrade while running
  # This prevents service disruption if the install fails

  tailscale_install "$1" || {
    echo "Update failed, ensuring Tailscale is running..."
    # If install failed, make sure Tailscale is at least started
    tailscale_start || true
    return 1
  }

  # Restart to pick up the new version
  systemctl restart tailscaled
}

tailscale_cert_generate() {
  cert_dir="${TAILSCALE_ROOT}/certs"

  mkdir -p "$cert_dir"
  echo "Generating certificate for $TAILSCALE_HOSTNAME..."

  if tailscale cert --cert-file "$cert_dir/$TAILSCALE_HOSTNAME.crt" --key-file "$cert_dir/$TAILSCALE_HOSTNAME.key" "$TAILSCALE_HOSTNAME"; then
      chmod 644 "$cert_dir/$TAILSCALE_HOSTNAME.crt"
      chmod 600 "$cert_dir/$TAILSCALE_HOSTNAME.key"
      echo "Certificate generated successfully:"
      echo "  Certificate: $cert_dir/$TAILSCALE_HOSTNAME.crt"
      echo "  Private key: $cert_dir/$TAILSCALE_HOSTNAME.key"
      echo ""
      echo "Certificate expires in 90 days. Use '$0 cert renew $TAILSCALE_HOSTNAME' to renew."

      # Install (or repair) the cert-renewal units.  install_systemd_unit removes
      # any pre-existing symlink before copying (see its comment for why).
      ensure_cert_renewal_units
  else
      echo "Failed to generate certificate. Ensure:"
      echo "  - Your Tailscale session is valid and you are logged in"
      echo "  - MagicDNS is enabled in your Tailscale admin console"
      echo "  - HTTPS is enabled in your Tailscale admin console"
      exit 1
  fi
}

# Print the UUID of the active UniFi OS certificate when its files exist.
tailscale_cert_active_unifi_uuid() {
  _settings_file="${UNIFI_CONFIG_DIR}/settings.yaml"

  [ -f "$_settings_file" ] || return 1

  _cert_uuid=$(sed -n 's/^[[:space:]]*activeCertId:[[:space:]]*\([0-9A-Fa-f-]*\).*$/\1/p' "$_settings_file" | head -n 1)
  if ! printf '%s\n' "$_cert_uuid" | grep -Eq '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$'; then
    return 1
  fi

  [ -f "${UNIFI_CONFIG_DIR}/${_cert_uuid}.crt" ] || return 1
  [ -f "${UNIFI_CONFIG_DIR}/${_cert_uuid}.key" ] || return 1

  printf '%s\n' "$_cert_uuid"
}

# Succeed when the given UniFi certificate came from Tailscale: it is
# byte-identical to the given Tailscale certificate and key, or it is a
# certificate for this node's Tailscale hostname.  The hostname check matters
# because tailscaled renews certificates asynchronously: `tailscale cert`
# returns the cached certificate and writes the renewed one to the same files
# shortly afterwards, so by the next run no byte-identical copy remains.
tailscale_cert_unifi_is_tailscale() {
  _installed_cert="${UNIFI_CONFIG_DIR}/$1.crt"
  _installed_key="${UNIFI_CONFIG_DIR}/$1.key"

  if cmp -s "$2" "$_installed_cert" && cmp -s "$3" "$_installed_key"; then
    return 0
  fi

  command -v openssl >/dev/null 2>&1 || return 1
  openssl x509 -in "$_installed_cert" -noout -checkhost "$TAILSCALE_HOSTNAME" 2>/dev/null | \
    grep -q "does match certificate"
}

tailscale_cert_write_unifi() {
  _cert_uuid="$1"
  _source_cert="$2"
  _source_key="$3"
  _target_cert="${UNIFI_CONFIG_DIR}/${_cert_uuid}.crt"
  _target_key="${UNIFI_CONFIG_DIR}/${_cert_uuid}.key"
  _db_helper="${TAILSCALE_ROOT}/helpers/cert-db-register.sh"

  if [ ! -f "$_db_helper" ]; then
    echo "Cannot install UniFi certificate: database registration script not found"
    return 1
  fi

  if ! cp "$_source_cert" "$_target_cert" || \
     ! cp "$_source_key" "$_target_key" || \
     ! chmod 644 "$_target_cert" || \
     ! chmod 600 "$_target_key"; then
    echo "Failed to copy certificate into UniFi configuration"
    return 1
  fi

  echo "Registering certificate in database..."
  if ! sh "$_db_helper" "$_cert_uuid" "$_target_cert" "$_target_key" "$TAILSCALE_HOSTNAME"; then
    echo "Failed to register certificate in UniFi database"
    return 1
  fi
}

tailscale_cert_renew() {
  cert_dir="${TAILSCALE_ROOT}/certs"
  cert_file="$cert_dir/$TAILSCALE_HOSTNAME.crt"
  key_file="$cert_dir/$TAILSCALE_HOSTNAME.key"

  if [ ! -f "$cert_file" ] || [ ! -f "$key_file" ]; then
      echo "Certificate not found for $TAILSCALE_HOSTNAME"
      echo "Use '$0 cert generate' to create a new certificate"
      exit 1
  fi

  echo "Renewing certificate for $TAILSCALE_HOSTNAME..."

  # Backup existing certificates
  cp "$cert_file" "$cert_file.bak"
  cp "$key_file" "$key_file.bak"

  unifi_uuid=""
  if unifi_uuid=$(tailscale_cert_active_unifi_uuid) && \
     tailscale_cert_unifi_is_tailscale "$unifi_uuid" "$cert_file.bak" "$key_file.bak"; then
    echo "Found matching installed UniFi certificate with ID: $unifi_uuid"
  else
    unifi_uuid=""
  fi

  if tailscale cert --cert-file "$cert_file" --key-file "$key_file" "$TAILSCALE_HOSTNAME"; then
      chmod 644 "$cert_file"
      chmod 600 "$key_file"

      # Compare with the installed copy, not the pre-renewal file: an earlier
      # asynchronous renewal may already have replaced the Tailscale certificate.
      if [ -n "$unifi_uuid" ] && \
         { ! cmp -s "$cert_file" "${UNIFI_CONFIG_DIR}/${unifi_uuid}.crt" || \
           ! cmp -s "$key_file" "${UNIFI_CONFIG_DIR}/${unifi_uuid}.key"; }; then
          cp "${UNIFI_CONFIG_DIR}/${unifi_uuid}.crt" "$cert_file.unifi"
          cp "${UNIFI_CONFIG_DIR}/${unifi_uuid}.key" "$key_file.unifi"

          if ! tailscale_cert_write_unifi "$unifi_uuid" "$cert_file" "$key_file"; then
              tailscale_cert_write_unifi "$unifi_uuid" "$cert_file.unifi" "$key_file.unifi" || \
                echo "Warning: failed to restore the previous UniFi certificate"
              rm -f "$cert_file.unifi" "$key_file.unifi"
              mv "$cert_file.bak" "$cert_file"
              mv "$key_file.bak" "$key_file"
              echo "Failed to update the installed UniFi certificate; restored the previous Tailscale certificate"
              exit 1
          fi

          rm -f "$cert_file.bak" "$key_file.bak" "$cert_file.unifi" "$key_file.unifi"
          echo "UniFi OS certificate updated with ID: $unifi_uuid"
          if ! systemctl restart unifi-core; then
              echo "UniFi certificate was updated, but UniFi Core failed to restart"
              exit 1
          fi
      fi

      rm -f "$cert_file.bak" "$key_file.bak"
      echo "Certificate renewed successfully"
  else
      # Restore backups on failure
      mv "$cert_file.bak" "$cert_file"
      mv "$key_file.bak" "$key_file"
      echo "Failed to renew certificate"
      exit 1
  fi
}

tailscale_cert_info() {
  cert_dir="${TAILSCALE_ROOT}/certs"

  if [ -d "$cert_dir" ]; then
    if [ -f "$cert_dir/$TAILSCALE_HOSTNAME.crt" ]; then
        echo "Certificate information for $TAILSCALE_HOSTNAME:"
        echo "  Certificate: $cert_dir/$TAILSCALE_HOSTNAME.crt"
        echo "  Private key: $cert_dir/$TAILSCALE_HOSTNAME.key"
        if command -v openssl >/dev/null 2>&1; then
            expiry=$(openssl x509 -enddate -noout -in "$cert_dir/$TAILSCALE_HOSTNAME.crt" | cut -d= -f2)
            echo "  Expires: $expiry"
        fi
    else
        echo "No certificate found for $TAILSCALE_HOSTNAME"
        exit 1
    fi
  else
      echo "No certificates directory found, run '$0 cert generate' first"
      exit 1
  fi
}

tailscale_cert_install_unifi() {
  cert_dir="${TAILSCALE_ROOT}/certs"

  if [ ! -f "$cert_dir/$TAILSCALE_HOSTNAME.crt" ] || [ ! -f "$cert_dir/$TAILSCALE_HOSTNAME.key" ]; then
      echo "Certificate not found for $TAILSCALE_HOSTNAME"
      echo "Use '$0 cert generate' to create a certificate first"
      exit 1
  fi

  echo "Installing certificate for UniFi controller..."

  # Install for UniFi OS (nginx)
  if [ -d "$UNIFI_CONFIG_DIR" ]; then
      echo "Installing certificate for UniFi OS web interface..."

      # Generate a UUID for the certificate
      cert_uuid=$(cat /proc/sys/kernel/random/uuid)

      if ! tailscale_cert_write_unifi "$cert_uuid" "$cert_dir/$TAILSCALE_HOSTNAME.crt" "$cert_dir/$TAILSCALE_HOSTNAME.key"; then
          exit 1
      fi

      # Update nginx configuration
      cat > "$UNIFI_CONFIG_DIR/http/local-certs.conf" <<EOF
ssl_certificate     $UNIFI_CONFIG_DIR/$cert_uuid.crt;
ssl_certificate_key $UNIFI_CONFIG_DIR/$cert_uuid.key;
EOF

      # Update settings.yaml to activate the certificate
      if grep -q "activeCertId:" "$UNIFI_CONFIG_DIR/settings.yaml" 2>/dev/null; then
          # Update existing activeCertId
          sed -i "s/activeCertId: .*/activeCertId: $cert_uuid/" "$UNIFI_CONFIG_DIR/settings.yaml"
      else
          # Add activeCertId if it doesn't exist
          echo "activeCertId: $cert_uuid" >> "$UNIFI_CONFIG_DIR/settings.yaml"
      fi

      echo "UniFi OS certificate installed with ID: $cert_uuid"
      echo "Note: Restart unifi-core for the certificate to take effect:"
      echo "  systemctl restart unifi-core"
  fi
}

tailscale_cert() {
    action="${1:-help}"
    cert_dir="${TAILSCALE_ROOT}/certs"

    # Derive hostname from tailscale status (except for help and list commands)
    if [ "$action" != "help" ] && [ "$action" != "list" ]; then
        _ts_running=0
        _ts_attempts=0
        while [ "$_ts_attempts" -lt 10 ]; do
            if [ "$(tailscale status --json | jq -r .BackendState)" = "Running" ]; then
                _ts_running=1
                break
            fi
            _ts_attempts=$((_ts_attempts + 1))
            if [ "$_ts_attempts" -lt 10 ]; then
                sleep 2
            fi
        done
        if [ "$_ts_running" -eq 0 ]; then
            echo "Tailscale is not running. Please start Tailscale first."
            exit 1
        fi

        TAILSCALE_HOSTNAME="$(tailscale status --json | jq -r '.Self.DNSName[:-1]')"
        if [ -z "$TAILSCALE_HOSTNAME" ]; then
            echo "Failed to determine Tailscale hostname"
            exit 1
        fi

        export TAILSCALE_HOSTNAME
    fi

    case "$action" in
        generate)
            tailscale_cert_generate
            ;;

        renew)
            tailscale_cert_renew
            ;;

        info)
            tailscale_cert_info
            ;;

        install-unifi)
            tailscale_cert_install_unifi
            ;;

        help|*)
            echo "Usage: $0 cert {generate|renew|info|install-unifi}"
            echo ""
            echo "Commands:"
            echo "  generate        - Generate new certificate for this device"
            echo "  renew           - Renew existing certificate"
            echo "  info            - Show information about the stored certificate"
            echo "  install-unifi   - Install certificate into UniFi controller"
            echo ""
            echo "Examples:"
            echo "  $0 cert generate"
            echo "  $0 cert renew"
            echo "  $0 cert install-unifi"
            echo ""
            echo "Note: Certificates expire after 90 days."
            echo "      MagicDNS and HTTPS must be enabled in your Tailscale admin console."
            echo "      Hostname is automatically determined from Tailscale status."
            ;;
    esac
}

case $1 in
  "status")
    tailscale_status
    ;;
  "start")
    tailscale_start
    ;;
  "stop")
    tailscale_stop
    ;;
  "restart")
    tailscale_stop
    tailscale_start
    ;;
  "install")
    if systemctl is-active --quiet tailscaled; then
      echo "Tailscale is already installed and running, if you wish to update it, run '$0 update'"
      echo "If you have changed ${TAILSCALE_ROOT}/tailscale-env or wish to force a reinstall, run '$0 install!'"
      exit 0
    fi

    tailscale_install "$2"
    ;;
  "install!")
    tailscale_install "$2"
    ;;
  "uninstall")
    tailscale_stop
    tailscale_uninstall
    ;;
  "update")
    if tailscale_has_update "$2"; then
      if systemctl is-active --quiet tailscaled; then
        echo "Tailscaled is running, please stop it before updating"
        exit 1
      fi

      tailscale_install "$2"
    else
      echo "Tailscale is already up to date"
    fi
    ;;
  "update!")
    if tailscale_has_update "$2"; then
      tailscale_update "$2"
    else
      echo "Tailscale is already up to date"
    fi
    ;;
  "on-boot")
    # shellcheck source=package/tailscale-env
    . "${PACKAGE_ROOT}/tailscale-env"

    # Repair the systemd units first, on every boot, even when Tailscale is
    # already installed and healthy.  This rewrites any stale symlinked unit
    # files (from installs predating the copy-based layout) as plain regular
    # files in /etc while the disk is mounted, so the auto-reinstall units stay
    # readable by systemd after the next firmware update wipes /usr.  Doing it
    # first means the units are healthy for the next boot even if the steps
    # below fail.
    ensure_systemd_units
    repair_cert_renewal_units_if_configured

    if ! command -v tailscale >/dev/null 2>&1; then
      tailscale_install
    fi

    if [ "${TAILSCALE_AUTOUPDATE}" = "true" ]; then
      tailscale_has_update && tailscale_update || echo "No update available or unable to check"
    fi

    tailscale_start
    ;;
  "cert")
    shift
    tailscale_cert "$@"
    ;;
  *)
    echo "Usage: $0 {status|start|stop|restart|install|uninstall|update|cert}"
    exit 1
    ;;
esac
