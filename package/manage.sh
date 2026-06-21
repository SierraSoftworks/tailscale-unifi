#!/bin/sh
set -e

PACKAGE_ROOT="${PACKAGE_ROOT:-"$(dirname -- "$(readlink -f -- "$0";)")"}"
export TAILSCALE_ROOT="${TAILSCALE_ROOT:-/data/tailscale}"
SYSTEMD_UNIT_DIR="${SYSTEMD_UNIT_DIR:-/etc/systemd/system}"

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
# and make sure they are enabled.  Safe to run on every boot: it only reloads and
# enables when a unit actually changed, so a healthy device incurs no churn.
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
  sed -i "s/PORT=\"[^\"]*\"/PORT=\"${PORT:-41641}\"/" /etc/default/tailscaled || {
      echo "Failed to configure Tailscale port"
      echo "Check that the file /etc/default/tailscaled exists and contains the line PORT=\"${PORT:-41641}\"."
      exit 1
  }

  echo "Configuring Tailscaled startup flags..."
  sed -i "s@FLAGS=\"[^\"]*\"@FLAGS=\"--state /data/tailscale/tailscaled.state ${TAILSCALED_FLAGS}\"@" /etc/default/tailscaled || {
      echo "Failed to configure Tailscaled startup flags"
      echo "Check that the file /etc/default/tailscaled exists and contains the line FLAGS=\"--state /data/tailscale/tailscale.state ${TAILSCALED_FLAGS}\"."
      exit 1
  }

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
      if [ -f "${PACKAGE_ROOT}/tailscale-cert-renewal.service" ] && [ -f "${PACKAGE_ROOT}/tailscale-cert-renewal.timer" ]; then
          echo "Installing certificate auto-renewal timer..."
          install_systemd_unit tailscale-cert-renewal.service
          install_systemd_unit tailscale-cert-renewal.timer
          systemctl daemon-reload
          systemctl enable tailscale-cert-renewal.timer
          systemctl start tailscale-cert-renewal.timer
          echo "Certificate will be automatically renewed weekly"
      fi
  else
      echo "Failed to generate certificate. Ensure:"
      echo "  - Your Tailscale session is valid and you are logged in"
      echo "  - MagicDNS is enabled in your Tailscale admin console"
      echo "  - HTTPS is enabled in your Tailscale admin console"
      exit 1
  fi
}

tailscale_cert_renew() {
  cert_dir="${TAILSCALE_ROOT}/certs"

  if [ ! -f "$cert_dir/$TAILSCALE_HOSTNAME.crt" ] || [ ! -f "$cert_dir/$TAILSCALE_HOSTNAME.key" ]; then
      echo "Certificate not found for $TAILSCALE_HOSTNAME"
      echo "Use '$0 cert generate' to create a new certificate"
      exit 1
  fi

  echo "Renewing certificate for $TAILSCALE_HOSTNAME..."

  # Backup existing certificates
  cp "$cert_dir/$TAILSCALE_HOSTNAME.crt" "$cert_dir/$TAILSCALE_HOSTNAME.crt.bak"
  cp "$cert_dir/$TAILSCALE_HOSTNAME.key" "$cert_dir/$TAILSCALE_HOSTNAME.key.bak"

  if tailscale cert --cert-file "$cert_dir/$TAILSCALE_HOSTNAME.crt" --key-file "$cert_dir/$TAILSCALE_HOSTNAME.key" "$TAILSCALE_HOSTNAME"; then
      chmod 644 "$cert_dir/$TAILSCALE_HOSTNAME.crt"
      chmod 600 "$cert_dir/$TAILSCALE_HOSTNAME.key"
      rm -f "$cert_dir/$TAILSCALE_HOSTNAME.crt.bak" "$cert_dir/$TAILSCALE_HOSTNAME.key.bak"
      echo "Certificate renewed successfully"
  else
      # Restore backups on failure
      mv "$cert_dir/$TAILSCALE_HOSTNAME.crt.bak" "$cert_dir/$TAILSCALE_HOSTNAME.crt"
      mv "$cert_dir/$TAILSCALE_HOSTNAME.key.bak" "$cert_dir/$TAILSCALE_HOSTNAME.key"
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
  if [ -d "/data/unifi-core/config" ]; then
      echo "Installing certificate for UniFi OS web interface..."

      # Generate a UUID for the certificate
      cert_uuid=$(cat /proc/sys/kernel/random/uuid)

      # Copy certificates with UUID names
      cp "$cert_dir/$TAILSCALE_HOSTNAME.crt" "/data/unifi-core/config/$cert_uuid.crt"
      cp "$cert_dir/$TAILSCALE_HOSTNAME.key" "/data/unifi-core/config/$cert_uuid.key"

      # Set proper permissions
      chmod 644 "/data/unifi-core/config/$cert_uuid.crt"
      chmod 600 "/data/unifi-core/config/$cert_uuid.key"

      # Register certificate in PostgreSQL database for persistence
      if [ -f "${TAILSCALE_ROOT}/helpers/cert-db-register.sh" ]; then
          echo "Registering certificate in database..."
          if ! sh "${TAILSCALE_ROOT}/helpers/cert-db-register.sh" "$cert_uuid" "/data/unifi-core/config/$cert_uuid.crt" "/data/unifi-core/config/$cert_uuid.key" "$TAILSCALE_HOSTNAME"; then
              echo "Failed to register certificate in UniFi database"
              exit 1
          fi
      else
          echo "Warning: Database registration script not found. Certificate may not persist across restarts."
      fi

      # Update nginx configuration
      cat > /data/unifi-core/config/http/local-certs.conf <<EOF
ssl_certificate     /data/unifi-core/config/$cert_uuid.crt;
ssl_certificate_key /data/unifi-core/config/$cert_uuid.key;
EOF

      # Update settings.yaml to activate the certificate
      if grep -q "activeCertId:" /data/unifi-core/config/settings.yaml 2>/dev/null; then
          # Update existing activeCertId
          sed -i "s/activeCertId: .*/activeCertId: $cert_uuid/" /data/unifi-core/config/settings.yaml
      else
          # Add activeCertId if it doesn't exist
          echo "activeCertId: $cert_uuid" >> /data/unifi-core/config/settings.yaml
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
      echo "If you wish to force a reinstall, run '$0 install!'"
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