#!/usr/bin/env bash
set -e

ROOT="$(dirname "$(dirname "$0")")"
WORKDIR="$(mktemp -d || exit 1)"
trap 'rm -rf ${WORKDIR}' EXIT

# shellcheck source=tests/helpers.sh
. "${ROOT}/tests/helpers.sh"

# Absolute so the symlink fixtures below resolve from any working directory.
PACKAGE_ROOT="$(cd "${ROOT}/package" && pwd)"
export PACKAGE_ROOT
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
mock "${WORKDIR}/ubnt-device-info" "2.0.0"
# NB: `ln` is deliberately NOT mocked.  manage.sh no longer creates symlinks
# (it copies unit files), so the only `ln` calls are the symlink fixtures the
# tests below set up — those must use the real `ln` to be meaningful.

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

# ── update with the tailscale binary absent => clean "needs install" ──────────
# A device whose binaries were just wiped by a firmware update has no `tailscale`
# on PATH.  `manage.sh update` must treat that as "needs install" and reinstall,
# without the noisy "tailscale: not found" that the old tailscale_has_update
# emitted.  curl/jq are mocked empty so the version probe stays offline.
mock "${WORKDIR}/curl" ""
mock "${WORKDIR}/jq" ""
reset_mock "${WORKDIR}/apt"

update_out=$("${ROOT}/package/manage.sh" update 2>&1) || true
assert_not_contains "$update_out" "tailscale: not found" "update with tailscale absent does not emit 'tailscale: not found'"
assert_contains "$(cat "${WORKDIR}/apt.args")" "install -y tailscale" "update with tailscale absent triggers an install"

# ── on-boot repairs stale units while Tailscale is healthy ────────────────────
# The core regression fix: installs predating the copy-based layout leave unit
# files that drift from the package — symlinks into /data (unreadable at early
# boot), or stale copies from an older version.  on-boot must repair them on
# EVERY boot, even when Tailscale is already installed and running, so they are
# healthy before the next firmware update.  Re-mock systemctl so Tailscale
# appears installed AND running, and handle the `start` issued by tailscale_start.
cat > "${WORKDIR}/systemctl" <<EOF
#!/usr/bin/env bash
case "\$1" in
    "is-active")     exit 0 ;;
    "is-enabled")    exit 0 ;;
    "enable")        touch "${WORKDIR}/\$2.enabled" ;;
    "daemon-reload") touch "${WORKDIR}/systemctl.daemon-reload" ;;
    "start")         touch "${WORKDIR}/tailscaled.started" ;;
    "restart")       touch "${WORKDIR}/tailscaled.restarted" ;;
    *) echo "Unexpected command: \${1}"; exit 1 ;;
esac
EOF
chmod +x "${WORKDIR}/systemctl"

# tailscale present on PATH (command -v succeeds) and reporting a version; sleep
# instant so tailscale_start doesn't stall the suite.
mock "${WORKDIR}/tailscale" "1.999.0"
mock "${WORKDIR}/sleep" ""

# A stale regular unit file (content differs from the package) plus a symlinked
# unit (the pre-v3.3.0 layout).  The stale-content case drives the change
# detection portably; the symlink case mirrors the real-world bug.
printf '[Unit]\n# stale\n' > "${SYSTEMD_UNIT_DIR}/tailscale-install.service"
ln -sf "${PACKAGE_ROOT}/tailscale-install.timer" \
       "${SYSTEMD_UNIT_DIR}/tailscale-install.timer"
rm -f "${WORKDIR}/systemctl.daemon-reload"

"${ROOT}/package/manage.sh" on-boot; assert "on-boot succeeds when Tailscale is already installed"

cmp -s "${PACKAGE_ROOT}/tailscale-install.service" "${SYSTEMD_UNIT_DIR}/tailscale-install.service"; assert "on-boot rewrites a stale tailscale-install.service to match the package while Tailscale is healthy"
[[ ! -L "${SYSTEMD_UNIT_DIR}/tailscale-install.timer" ]]; assert "on-boot rewrites a symlinked tailscale-install.timer as a regular file while Tailscale is healthy"
[[ -f "${WORKDIR}/systemctl.daemon-reload" ]]; assert "on-boot runs daemon-reload after repairing stale units"

# ── on-boot is safe to run repeatedly ─────────────────────────────────────────
# A second on-boot with the units already correct must still succeed and leave
# them as regular files matching the package (install_systemd_unit only re-copies
# a unit when it actually differs, so repeated runs don't corrupt the files).
"${ROOT}/package/manage.sh" on-boot; assert "second on-boot succeeds and is idempotent"

[[ ! -L "${SYSTEMD_UNIT_DIR}/tailscale-install.service" ]]; assert "tailscale-install.service stays a regular file after a repeated on-boot"
[[ ! -L "${SYSTEMD_UNIT_DIR}/tailscale-install.timer" ]]; assert "tailscale-install.timer stays a regular file after a repeated on-boot"
cmp -s "${PACKAGE_ROOT}/tailscale-install.service" "${SYSTEMD_UNIT_DIR}/tailscale-install.service"; assert "tailscale-install.service still matches the package after a repeated on-boot"