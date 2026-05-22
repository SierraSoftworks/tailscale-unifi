#!/usr/bin/env bash
set -e

ROOT="$(dirname "$(dirname "$0")")"
WORKDIR="$(mktemp -d || exit 1)"
trap 'rm -rf ${WORKDIR}' EXIT

# shellcheck source=tests/helpers.sh
. "${ROOT}/tests/helpers.sh"

export PACKAGE_ROOT="${ROOT}/package"
export TAILSCALE_ROOT="${WORKDIR}"
export TAILSCALED_SOCK="${WORKDIR}/tailscaled.sock"
export SYSTEMD_UNIT_DIR="${WORKDIR}/systemd"
export OS_VERSION="v2"

mkdir -p "${SYSTEMD_UNIT_DIR}"

export PATH="${WORKDIR}:${PATH}"
mock "${WORKDIR}/apt-key" "--## apt-key mock: \$* ##--"
mock "${WORKDIR}/tee" "--## tee mock: \$* ##--"
mock "${WORKDIR}/apt" "--## apt mock: \$* ##--"
mock "${WORKDIR}/sed" "--## sed mock: \$* ##--"
mock "${WORKDIR}/ln" "--## ln mock: \$* ##--"
mock "${WORKDIR}/ubnt-device-info" "2.0.0"

# systemctl mock, used to ensure the installer doesn't block thinking that tailscale is running
cat > "${WORKDIR}/systemctl" <<EOF
#!/usr/bin/env bash

case "\$1" in
    "is-active")
        echo "--## systemctl is-active ##--"
        exit 1
        ;;
    "is-enabled")
        echo "--## systemctl is-enabled ##--"
        exit 1
        ;;
    "enable")
        echo "--## systemctl enable \$2 ##--"
        touch "${WORKDIR}/\$2.enabled"
        ;;
    "daemon-reload")
        echo "--## systemctl daemon-reload ##--"
        touch "${WORKDIR}/systemctl.daemon-reload"
        ;;
    "restart")
        echo "--## systemctl restart ##--"
        touch "${WORKDIR}/tailscaled.restarted"
        ;;
    *)
        echo "Unexpected command: \${1}"
        exit 1
        ;;
esac
EOF
chmod +x "${WORKDIR}/systemctl"

cp "${ROOT}/tests/os-release" "${WORKDIR}/os-release"
export OS_RELEASE_FILE="${WORKDIR}/os-release"

cp "${PACKAGE_ROOT}/tailscale-env" "${WORKDIR}/tailscale-env"

# ── fresh install (clean SYSTEMD_UNIT_DIR) ────────────────────────────────────
"${ROOT}/package/manage.sh" install; assert "Tailscale installer should run successfully"

apt_first=$(head -n 1 "${WORKDIR}/apt.args")
apt_second=$(head -n 2 "${WORKDIR}/apt.args" | tail -n 1)
sed_args=$(cat "${WORKDIR}/sed.args")

assert_contains "$apt_first" "update" "The apt command should be called to update the package list"
assert_contains "$apt_second" "install -y tailscale" "The apt command should be called with the command to install tailscale file"
assert_contains "$sed_args" "--state /data/tailscale" "The defaults should be updated with state directory"
[[ -f "${WORKDIR}/tailscaled.restarted" ]]; assert "tailscaled should have been restarted"
[[ -f "${WORKDIR}/tailscaled.service.enabled" ]]; assert "tailscaled unit should be enabled"
[[ -f "${WORKDIR}/systemctl.daemon-reload" ]]; assert "systemctl should have been reloaded"
[[ -f "${WORKDIR}/tailscale-install.service.enabled" ]]; assert "tailscale-install unit should be enabled"
[[ -f "${SYSTEMD_UNIT_DIR}/tailscale-install.service" ]]; assert "tailscale-install.service unit file should be copied to systemd directory"
[[ -f "${SYSTEMD_UNIT_DIR}/tailscale-install.timer" ]]; assert "tailscale-install.timer unit file should be copied to systemd directory"

# ── upgrade-from-symlink path ─────────────────────────────────────────────────
# Simulate a v3.2.0 install where the unit files in SYSTEMD_UNIT_DIR are
# symlinks pointing back into PACKAGE_ROOT (= /data/tailscale on a real
# device).  On UDM-SE /data -> /ssd1/.data, so both paths canonicalise to
# the same inode; a plain `cp -f` aborts with "are the same file" and the
# symlinks are left in place, silently breaking the boot-time fix.
# The rm-before-cp change must handle this without error.
ln -sf "${PACKAGE_ROOT}/tailscale-install.service" \
       "${SYSTEMD_UNIT_DIR}/tailscale-install.service"
ln -sf "${PACKAGE_ROOT}/tailscale-install.timer" \
       "${SYSTEMD_UNIT_DIR}/tailscale-install.timer"

"${ROOT}/package/manage.sh" install; assert "Upgrade from symlink state should succeed without 'same file' error"

# After the fix the destination must be a regular file, not a symlink.
# If rm -f silently failed and cp wrote through the symlink instead, the
# destination would still appear as a file — only -L distinguishes the two.
[[ ! -L "${SYSTEMD_UNIT_DIR}/tailscale-install.service" ]]; assert "tailscale-install.service should be a regular file after upgrade, not a symlink"
[[ ! -L "${SYSTEMD_UNIT_DIR}/tailscale-install.timer" ]]; assert "tailscale-install.timer should be a regular file after upgrade, not a symlink"