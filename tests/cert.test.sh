#!/bin/bash

ROOT="$(dirname "$(dirname "$0")")"
WORKDIR="$(mktemp -d || exit 1)"
trap 'rm -rf ${WORKDIR}' EXIT

# shellcheck source=tests/helpers.sh
. "${ROOT}/tests/helpers.sh"

export PATH="${WORKDIR}:${PATH}"
export TAILSCALE_ROOT="${WORKDIR}"
export TAILSCALED_SOCK="${WORKDIR}/tailscaled.sock"
export SYSTEMD_UNIT_DIR="${WORKDIR}/systemd"

MANAGE_SH="${ROOT}/package/manage.sh"

mkdir -p "${SYSTEMD_UNIT_DIR}"

mock "${WORKDIR}/ubnt-device-info" "2.0.0"
touch "${TAILSCALED_SOCK}"  # Create the tailscaled socket for testing

# systemctl mock, used to ensure the installer doesn't block thinking that tailscale is running
cat > "${WORKDIR}/systemctl" <<EOF
#!/usr/bin/env bash

case "\$1" in
    "is-active")
        if [ ! -f "${WORKDIR}/tailscaled.sock" ]; then
            exit 1
        fi
        ;;
    "enable")
        echo "--## systemctl enable \$2 ##--"
        touch "${WORKDIR}/\$2.enabled"
        ;;
    "daemon-reload")
        echo "--## systemctl daemon-reload ##--"
        touch "${WORKDIR}/systemctl.daemon-reload"
        ;;
    "start")
        echo "--## systemctl start \$2 ##--"
        touch "${WORKDIR}/\$2.started"
        ;;
    "restart")
        echo "--## systemctl restart \$2 ##--"
        if [ -f "${WORKDIR}/fail-\$2-restart" ]; then
            exit 1
        fi
        touch "${WORKDIR}/\$2.restarted"
        ;;
    *)
        echo "Unexpected command: \${1}"
        exit 1
        ;;
esac
EOF
chmod +x "${WORKDIR}/systemctl"

cat > "${WORKDIR}/tailscale" <<EOF
#!/usr/bin/env bash

# Mock the tailscale cert command
mock_tailscale_cert() {
    while [ \$# -gt 0 ]; do
        case "\$1" in
            --cert-file)
                cert_file="\$2"
                shift 2
                ;;
            --key-file)
                key_file="\$2"
                shift 2
                ;;
            *)
                #hostname="\$1"
                shift
                ;;
        esac
    done

    if [ -n "\$cert_file" ] && [ -n "\$key_file" ]; then
        # Asynchronous renewal: tailscaled hands back the cached certificate
        # unchanged and writes the renewed one later.
        if [ -f "${WORKDIR}/tailscale-cert-cached" ]; then
            return 0
        fi
        echo "CERTIFICATE" > "\$cert_file"
        echo "PRIVATE KEY" > "\$key_file"
        return 0
    fi
    return 1
}

case "\$1" in
    cert)
        shift
        mock_tailscale_cert "\$@"
        ;;
    status)
        if [ "\$2" = "--json" ]; then
            if [ -f "${WORKDIR}/tailscaled.sock" ]; then
                echo '{"BackendState": "Running", "Self": {"DNSName": "test-host.example.ts.net."}}'
            else
                echo '{"BackendState": "Stopped", "Self": {"DNSName": "test-host.example.ts.net."}}'
            fi
        fi
        ;;
    *)
        return 0
        ;;
esac
EOF
chmod +x "${WORKDIR}/tailscale"


# Test certificate generation
test_cert_generate() {
    touch "$TAILSCALED_SOCK"  # Mock running state

    output=$("$MANAGE_SH" cert generate 2>&1)
    assert_contains "$output" "Certificate generated successfully" "Output contains success message"
    assert_file_exists "$TAILSCALE_ROOT/certs/test-host.example.ts.net.crt" "Certificate file exists"
    assert_file_exists "$TAILSCALE_ROOT/certs/test-host.example.ts.net.key" "Key file exists"

    # Check file permissions
    cert_perms=$(stat -c %a "$TAILSCALE_ROOT/certs/test-host.example.ts.net.crt" 2>/dev/null || stat -f %p "$TAILSCALE_ROOT/certs/test-host.example.ts.net.crt" | cut -c4-6)
    key_perms=$(stat -c %a "$TAILSCALE_ROOT/certs/test-host.example.ts.net.key" 2>/dev/null || stat -f %p "$TAILSCALE_ROOT/certs/test-host.example.ts.net.key" | cut -c4-6)
    assert_eq "644" "$cert_perms" "Certificate permissions are correct"
    assert_eq "600" "$key_perms" "Key permissions are correct"

    rm -rf "$TAILSCALE_ROOT/certs"
}

# Test certificate renewal
test_cert_renew() {
    mkdir -p "$TAILSCALE_ROOT/certs"
    touch "$TAILSCALED_SOCK"  # Mock running state

    # Create existing certificates
    echo "OLD CERT" > "$TAILSCALE_ROOT/certs/test-host.example.ts.net.crt"
    echo "OLD KEY" > "$TAILSCALE_ROOT/certs/test-host.example.ts.net.key"

    output=$("$MANAGE_SH" cert renew 2>&1)
    assert_contains "$output" "Certificate renewed successfully" "Output contains success message"

    cert_content=$(cat "$TAILSCALE_ROOT/certs/test-host.example.ts.net.crt")
    assert_eq "CERTIFICATE" "$cert_content" "Certificate content is correct"

    rm -rf "$TAILSCALE_ROOT/certs"
}

test_cert_renew_updates_installed_unifi_cert() {
    cert_uuid="12345678-1234-1234-1234-123456789012"
    unifi_config_dir="${WORKDIR}/unifi-core/config"

    mkdir -p "$TAILSCALE_ROOT/certs" "$TAILSCALE_ROOT/helpers" "$unifi_config_dir"
    touch "$TAILSCALED_SOCK"
    echo "OLD CERT" > "$TAILSCALE_ROOT/certs/test-host.example.ts.net.crt"
    echo "OLD KEY" > "$TAILSCALE_ROOT/certs/test-host.example.ts.net.key"
    echo "OLD CERT" > "$unifi_config_dir/$cert_uuid.crt"
    echo "OLD KEY" > "$unifi_config_dir/$cert_uuid.key"
    echo "activeCertId: $cert_uuid" > "$unifi_config_dir/settings.yaml"
    mock "$TAILSCALE_ROOT/helpers/cert-db-register.sh"

    output=$(UNIFI_CONFIG_DIR="$unifi_config_dir" "$MANAGE_SH" cert renew 2>&1)

    assert_contains "$output" "UniFi OS certificate updated" \
        "Renewal updates the installed UniFi certificate"
    assert_eq "CERTIFICATE" "$(cat "$unifi_config_dir/$cert_uuid.crt")" \
        "Installed UniFi certificate contains the renewed certificate"
    assert_eq "PRIVATE KEY" "$(cat "$unifi_config_dir/$cert_uuid.key")" \
        "Installed UniFi key contains the renewed private key"
    assert_contains "$(cat "$TAILSCALE_ROOT/helpers/cert-db-register.sh.args")" "$cert_uuid" \
        "Renewal updates the existing UniFi database record"
    assert_file_exists "$WORKDIR/unifi-core.restarted" \
        "Renewal restarts UniFi Core after installing a changed certificate"

    rm -rf "$TAILSCALE_ROOT/certs" "$TAILSCALE_ROOT/helpers" "$unifi_config_dir"
    rm -f "$WORKDIR/unifi-core.restarted"
}

test_cert_renew_does_not_replace_unrelated_unifi_cert() {
    cert_uuid="12345678-1234-1234-1234-123456789012"
    unifi_config_dir="${WORKDIR}/unifi-core/config"

    mkdir -p "$TAILSCALE_ROOT/certs" "$unifi_config_dir"
    touch "$TAILSCALED_SOCK"
    echo "OLD CERT" > "$TAILSCALE_ROOT/certs/test-host.example.ts.net.crt"
    echo "OLD KEY" > "$TAILSCALE_ROOT/certs/test-host.example.ts.net.key"
    echo "UNRELATED CERT" > "$unifi_config_dir/$cert_uuid.crt"
    echo "UNRELATED KEY" > "$unifi_config_dir/$cert_uuid.key"
    echo "activeCertId: $cert_uuid" > "$unifi_config_dir/settings.yaml"

    output=$(UNIFI_CONFIG_DIR="$unifi_config_dir" "$MANAGE_SH" cert renew 2>&1)

    assert_not_contains "$output" "UniFi OS certificate updated" \
        "Renewal does not replace an unrelated active UniFi certificate"
    assert_eq "UNRELATED CERT" "$(cat "$unifi_config_dir/$cert_uuid.crt")" \
        "Unrelated active UniFi certificate remains unchanged"
    [[ ! -f "$WORKDIR/unifi-core.restarted" ]]
    assert "Renewal does not restart UniFi Core when its certificate is unrelated"

    rm -rf "$TAILSCALE_ROOT/certs" "$unifi_config_dir"
}

test_cert_renew_rolls_back_when_unifi_update_fails() {
    cert_uuid="12345678-1234-1234-1234-123456789012"
    unifi_config_dir="${WORKDIR}/unifi-core/config"

    mkdir -p "$TAILSCALE_ROOT/certs" "$TAILSCALE_ROOT/helpers" "$unifi_config_dir"
    touch "$TAILSCALED_SOCK"
    echo "OLD CERT" > "$TAILSCALE_ROOT/certs/test-host.example.ts.net.crt"
    echo "OLD KEY" > "$TAILSCALE_ROOT/certs/test-host.example.ts.net.key"
    echo "OLD CERT" > "$unifi_config_dir/$cert_uuid.crt"
    echo "OLD KEY" > "$unifi_config_dir/$cert_uuid.key"
    echo "activeCertId: $cert_uuid" > "$unifi_config_dir/settings.yaml"
    mock "$TAILSCALE_ROOT/helpers/cert-db-register.sh" "database unavailable" 1

    output=$(UNIFI_CONFIG_DIR="$unifi_config_dir" "$MANAGE_SH" cert renew 2>&1) || true

    assert_contains "$output" "restored the previous Tailscale certificate" \
        "Renewal reports rollback when the UniFi database update fails"
    assert_eq "OLD CERT" "$(cat "$TAILSCALE_ROOT/certs/test-host.example.ts.net.crt")" \
        "Tailscale certificate is rolled back after a UniFi update failure"
    assert_eq "OLD CERT" "$(cat "$unifi_config_dir/$cert_uuid.crt")" \
        "Installed UniFi certificate is rolled back after a database failure"
    [[ ! -f "$WORKDIR/unifi-core.restarted" ]]
    assert "UniFi Core is not restarted after a database update failure"

    rm -rf "$TAILSCALE_ROOT/certs" "$TAILSCALE_ROOT/helpers" "$unifi_config_dir"
}

test_cert_renew_keeps_updated_state_when_unifi_restart_fails() {
    cert_uuid="12345678-1234-1234-1234-123456789012"
    unifi_config_dir="${WORKDIR}/unifi-core/config"

    mkdir -p "$TAILSCALE_ROOT/certs" "$TAILSCALE_ROOT/helpers" "$unifi_config_dir"
    touch "$TAILSCALED_SOCK" "$WORKDIR/fail-unifi-core-restart"
    echo "OLD CERT" > "$TAILSCALE_ROOT/certs/test-host.example.ts.net.crt"
    echo "OLD KEY" > "$TAILSCALE_ROOT/certs/test-host.example.ts.net.key"
    echo "OLD CERT" > "$unifi_config_dir/$cert_uuid.crt"
    echo "OLD KEY" > "$unifi_config_dir/$cert_uuid.key"
    echo "activeCertId: $cert_uuid" > "$unifi_config_dir/settings.yaml"
    mock "$TAILSCALE_ROOT/helpers/cert-db-register.sh"

    output=$(UNIFI_CONFIG_DIR="$unifi_config_dir" "$MANAGE_SH" cert renew 2>&1) || true

    assert_contains "$output" "UniFi certificate was updated, but UniFi Core failed to restart" \
        "Renewal reports when the updated certificate could not be activated"
    assert_eq "CERTIFICATE" "$(cat "$TAILSCALE_ROOT/certs/test-host.example.ts.net.crt")" \
        "Renewed Tailscale certificate remains after a UniFi restart failure"
    assert_eq "CERTIFICATE" "$(cat "$unifi_config_dir/$cert_uuid.crt")" \
        "Updated UniFi certificate remains after a restart failure"

    rm -rf "$TAILSCALE_ROOT/certs" "$TAILSCALE_ROOT/helpers" "$unifi_config_dir"
    rm -f "$WORKDIR/fail-unifi-core-restart"
}

# Create a real self-signed certificate for the given hostname.
make_test_cert() {
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 90 \
        -subj "/CN=$1" -addext "subjectAltName=DNS:$1" \
        -keyout "$3" -out "$2" >/dev/null 2>&1
}

# tailscaled renewed the certificate in the background after an earlier run
# compared the files, so the active UniFi copy is an older certificate for the
# same hostname and `tailscale cert` now returns the renewed one unchanged.
test_cert_renew_updates_unifi_cert_after_async_renewal() {
    cert_uuid="12345678-1234-1234-1234-123456789012"
    unifi_config_dir="${WORKDIR}/unifi-core/config"

    mkdir -p "$TAILSCALE_ROOT/certs" "$TAILSCALE_ROOT/helpers" "$unifi_config_dir"
    touch "$TAILSCALED_SOCK" "$WORKDIR/tailscale-cert-cached"
    make_test_cert test-host.example.ts.net \
        "$TAILSCALE_ROOT/certs/test-host.example.ts.net.crt" "$TAILSCALE_ROOT/certs/test-host.example.ts.net.key"
    make_test_cert test-host.example.ts.net "$unifi_config_dir/$cert_uuid.crt" "$unifi_config_dir/$cert_uuid.key"
    echo "activeCertId: $cert_uuid" > "$unifi_config_dir/settings.yaml"
    mock "$TAILSCALE_ROOT/helpers/cert-db-register.sh"

    output=$(UNIFI_CONFIG_DIR="$unifi_config_dir" "$MANAGE_SH" cert renew 2>&1)

    assert_contains "$output" "UniFi OS certificate updated" \
        "Renewal updates a UniFi certificate left behind by an asynchronous renewal"
    cmp -s "$TAILSCALE_ROOT/certs/test-host.example.ts.net.crt" "$unifi_config_dir/$cert_uuid.crt"
    assert "Installed UniFi certificate matches the current Tailscale certificate"
    cmp -s "$TAILSCALE_ROOT/certs/test-host.example.ts.net.key" "$unifi_config_dir/$cert_uuid.key"
    assert "Installed UniFi key matches the current Tailscale key"
    assert_contains "$(cat "$TAILSCALE_ROOT/helpers/cert-db-register.sh.args")" "$cert_uuid" \
        "Asynchronous catch-up updates the existing UniFi database record"
    assert_file_exists "$WORKDIR/unifi-core.restarted" \
        "Asynchronous catch-up restarts UniFi Core"
    [[ ! -e "$TAILSCALE_ROOT/certs/test-host.example.ts.net.crt.unifi" ]]
    assert "Temporary copy of the previous UniFi certificate is removed"

    rm -rf "$TAILSCALE_ROOT/certs" "$TAILSCALE_ROOT/helpers" "$unifi_config_dir"
    rm -f "$WORKDIR/unifi-core.restarted" "$WORKDIR/tailscale-cert-cached"
}

test_cert_renew_leaves_current_unifi_cert_alone() {
    cert_uuid="12345678-1234-1234-1234-123456789012"
    unifi_config_dir="${WORKDIR}/unifi-core/config"

    mkdir -p "$TAILSCALE_ROOT/certs" "$TAILSCALE_ROOT/helpers" "$unifi_config_dir"
    touch "$TAILSCALED_SOCK" "$WORKDIR/tailscale-cert-cached"
    make_test_cert test-host.example.ts.net \
        "$TAILSCALE_ROOT/certs/test-host.example.ts.net.crt" "$TAILSCALE_ROOT/certs/test-host.example.ts.net.key"
    cp "$TAILSCALE_ROOT/certs/test-host.example.ts.net.crt" "$unifi_config_dir/$cert_uuid.crt"
    cp "$TAILSCALE_ROOT/certs/test-host.example.ts.net.key" "$unifi_config_dir/$cert_uuid.key"
    echo "activeCertId: $cert_uuid" > "$unifi_config_dir/settings.yaml"
    mock "$TAILSCALE_ROOT/helpers/cert-db-register.sh"

    output=$(UNIFI_CONFIG_DIR="$unifi_config_dir" "$MANAGE_SH" cert renew 2>&1)

    assert_not_contains "$output" "UniFi OS certificate updated" \
        "Renewal does not rewrite a UniFi certificate that is already current"
    [[ ! -f "$TAILSCALE_ROOT/helpers/cert-db-register.sh.args" ]]
    assert "Renewal does not touch the UniFi database when nothing changed"
    [[ ! -f "$WORKDIR/unifi-core.restarted" ]]
    assert "Renewal does not restart UniFi Core when nothing changed"

    rm -rf "$TAILSCALE_ROOT/certs" "$TAILSCALE_ROOT/helpers" "$unifi_config_dir"
    rm -f "$WORKDIR/tailscale-cert-cached"
}

test_cert_renew_does_not_replace_unifi_cert_for_other_host() {
    cert_uuid="12345678-1234-1234-1234-123456789012"
    unifi_config_dir="${WORKDIR}/unifi-core/config"

    mkdir -p "$TAILSCALE_ROOT/certs" "$TAILSCALE_ROOT/helpers" "$unifi_config_dir"
    touch "$TAILSCALED_SOCK" "$WORKDIR/tailscale-cert-cached"
    make_test_cert test-host.example.ts.net \
        "$TAILSCALE_ROOT/certs/test-host.example.ts.net.crt" "$TAILSCALE_ROOT/certs/test-host.example.ts.net.key"
    make_test_cert unifi.example.com "$unifi_config_dir/$cert_uuid.crt" "$unifi_config_dir/$cert_uuid.key"
    cp "$unifi_config_dir/$cert_uuid.crt" "$WORKDIR/other-host.crt"
    echo "activeCertId: $cert_uuid" > "$unifi_config_dir/settings.yaml"
    mock "$TAILSCALE_ROOT/helpers/cert-db-register.sh"

    output=$(UNIFI_CONFIG_DIR="$unifi_config_dir" "$MANAGE_SH" cert renew 2>&1)

    assert_not_contains "$output" "UniFi OS certificate updated" \
        "Renewal does not replace a UniFi certificate issued for another hostname"
    cmp -s "$WORKDIR/other-host.crt" "$unifi_config_dir/$cert_uuid.crt"
    assert "UniFi certificate for another hostname remains unchanged"
    [[ ! -f "$WORKDIR/unifi-core.restarted" ]]
    assert "Renewal does not restart UniFi Core for a certificate it does not own"

    rm -rf "$TAILSCALE_ROOT/certs" "$TAILSCALE_ROOT/helpers" "$unifi_config_dir"
    rm -f "$WORKDIR/tailscale-cert-cached" "$WORKDIR/other-host.crt"
}

test_cert_renew_restores_unifi_cert_when_async_update_fails() {
    cert_uuid="12345678-1234-1234-1234-123456789012"
    unifi_config_dir="${WORKDIR}/unifi-core/config"

    mkdir -p "$TAILSCALE_ROOT/certs" "$TAILSCALE_ROOT/helpers" "$unifi_config_dir"
    touch "$TAILSCALED_SOCK" "$WORKDIR/tailscale-cert-cached"
    make_test_cert test-host.example.ts.net \
        "$TAILSCALE_ROOT/certs/test-host.example.ts.net.crt" "$TAILSCALE_ROOT/certs/test-host.example.ts.net.key"
    make_test_cert test-host.example.ts.net "$unifi_config_dir/$cert_uuid.crt" "$unifi_config_dir/$cert_uuid.key"
    cp "$unifi_config_dir/$cert_uuid.crt" "$WORKDIR/previous-unifi.crt"
    cp "$TAILSCALE_ROOT/certs/test-host.example.ts.net.crt" "$WORKDIR/current-tailscale.crt"
    echo "activeCertId: $cert_uuid" > "$unifi_config_dir/settings.yaml"
    mock "$TAILSCALE_ROOT/helpers/cert-db-register.sh" "database unavailable" 1

    output=$(UNIFI_CONFIG_DIR="$unifi_config_dir" "$MANAGE_SH" cert renew 2>&1) || true

    assert_contains "$output" "Failed to update the installed UniFi certificate" \
        "Renewal reports a failed asynchronous catch-up"
    cmp -s "$WORKDIR/previous-unifi.crt" "$unifi_config_dir/$cert_uuid.crt"
    assert "Installed UniFi certificate is restored from its own previous copy"
    cmp -s "$WORKDIR/current-tailscale.crt" "$TAILSCALE_ROOT/certs/test-host.example.ts.net.crt"
    assert "Current Tailscale certificate is kept"
    [[ ! -f "$WORKDIR/unifi-core.restarted" ]]
    assert "UniFi Core is not restarted after a failed asynchronous catch-up"

    rm -rf "$TAILSCALE_ROOT/certs" "$TAILSCALE_ROOT/helpers" "$unifi_config_dir"
    rm -f "$WORKDIR/tailscale-cert-cached" "$WORKDIR/previous-unifi.crt" "$WORKDIR/current-tailscale.crt"
}

# Test certificate info
test_cert_info() {
    mkdir -p "$TAILSCALE_ROOT/certs"

    echo "CERT" > "$TAILSCALE_ROOT/certs/test-host.example.ts.net.crt"
    echo "KEY" > "$TAILSCALE_ROOT/certs/test-host.example.ts.net.key"

    output=$("$MANAGE_SH" cert info 2>&1)
    assert_contains "$output" "Certificate:" "Output contains Certificate path"
    assert_contains "$output" "test-host.example.ts.net.crt" "Output contains test-host.example.ts.net.crt"
    assert_contains "$output" "Private key:" "Output contains Private key path"
    assert_contains "$output" "test-host.example.ts.net.key" "Output contains test-host.example.ts.net.key"

    rm -rf "$TAILSCALE_ROOT/certs"
}

# Test when tailscale is not running
test_cert_not_running() {
    mkdir -p "$TAILSCALE_ROOT"

    rm -f "$TAILSCALED_SOCK"

    output=$("$MANAGE_SH" cert generate 2>&1) || true
    assert_contains "$output" "Tailscale is not running" "Output contains not running message"
}

# Test help command
test_cert_help() {
    output=$("$MANAGE_SH" cert help 2>&1)
    assert_contains "$output" "Usage:" "Output contains usage title"
    assert_contains "$output" "generate" "Output contains generate command"
    assert_contains "$output" "renew" "Output contains renew command"
    assert_contains "$output" "info" "Output contains info command"
    assert_contains "$output" "install-unifi" "Output contains install-unifi command"
}

# Test cert-renewal unit upgrade-from-symlink path
# Simulate a v3.2.0 install where tailscale-cert-renewal.{service,timer} in
# SYSTEMD_UNIT_DIR are symlinks pointing back into PACKAGE_ROOT.
# The same-inode cp failure that affects the install path applies here.
test_cert_generate_upgrade_from_symlink() {
    touch "$TAILSCALED_SOCK"  # Mock running state

    # Only run this fixture if the package ships the cert-renewal units;
    # skip silently if they are absent (e.g. in minimal test environments).
    if [ ! -f "${ROOT}/package/tailscale-cert-renewal.service" ] || \
       [ ! -f "${ROOT}/package/tailscale-cert-renewal.timer" ]; then
        return 0
    fi

    ln -sf "${ROOT}/package/tailscale-cert-renewal.service" \
           "${SYSTEMD_UNIT_DIR}/tailscale-cert-renewal.service"
    ln -sf "${ROOT}/package/tailscale-cert-renewal.timer" \
           "${SYSTEMD_UNIT_DIR}/tailscale-cert-renewal.timer"

    output=$("$MANAGE_SH" cert generate 2>&1)
    assert_contains "$output" "Certificate generated successfully" \
        "cert generate succeeds when cert-renewal units are pre-existing symlinks"

    [[ ! -L "${SYSTEMD_UNIT_DIR}/tailscale-cert-renewal.service" ]]
    assert "tailscale-cert-renewal.service should be a regular file after upgrade, not a symlink"

    [[ ! -L "${SYSTEMD_UNIT_DIR}/tailscale-cert-renewal.timer" ]]
    assert "tailscale-cert-renewal.timer should be a regular file after upgrade, not a symlink"

    rm -rf "$TAILSCALE_ROOT/certs"
}

# Run tests
test_cert_generate
test_cert_renew
test_cert_renew_updates_installed_unifi_cert
test_cert_renew_does_not_replace_unrelated_unifi_cert
test_cert_renew_rolls_back_when_unifi_update_fails
test_cert_renew_keeps_updated_state_when_unifi_restart_fails
test_cert_renew_updates_unifi_cert_after_async_renewal
test_cert_renew_leaves_current_unifi_cert_alone
test_cert_renew_does_not_replace_unifi_cert_for_other_host
test_cert_renew_restores_unifi_cert_when_async_update_fails
test_cert_info
test_cert_not_running
test_cert_help
test_cert_generate_upgrade_from_symlink

echo "All certificate tests passed!"
