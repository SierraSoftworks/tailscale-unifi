#!/usr/bin/env bash
# Tests for update channel selection, update failure recovery and uninstall.
set -e

ROOT="$(dirname "$(dirname "$0")")"
WORKDIR="$(mktemp -d || exit 1)"
trap 'rm -rf ${WORKDIR}' EXIT

# shellcheck source=tests/helpers.sh
. "${ROOT}/tests/helpers.sh"

PACKAGE_ROOT="$(cd "${ROOT}/package" && pwd)"
export PACKAGE_ROOT
export TAILSCALE_ROOT="${WORKDIR}"
export TAILSCALED_DEFAULTS_FILE="${WORKDIR}/tailscaled.defaults"
export SYSTEMD_UNIT_DIR="${WORKDIR}/systemd"
export OS_RELEASE_FILE="${ROOT}/tests/os-release"
export PATH="${WORKDIR}:${PATH}"

mkdir -p "${SYSTEMD_UNIT_DIR}"

# Every external command manage.sh touches is mocked so the suite stays offline.
mock "${WORKDIR}/curl" ""
mock "${WORKDIR}/jq" "1.2.0"
mock "${WORKDIR}/tee" ""
mock "${WORKDIR}/apt-key" ""
mock "${WORKDIR}/sleep" ""
mock "${WORKDIR}/tailscale" "1.1.0"

# systemctl mock: records every call; `is-active` reports tailscaled as running
# unless ${WORKDIR}/tailscaled.down exists, and `stop` fails when
# ${WORKDIR}/systemctl.stop-fails exists.
cat > "${WORKDIR}/systemctl" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "${WORKDIR}/systemctl.args"
case "\$1" in
    "is-active") [ ! -e "${WORKDIR}/tailscaled.down" ] ;;
    "stop")      [ ! -e "${WORKDIR}/systemctl.stop-fails" ] ;;
    *)           exit 0 ;;
esac
EOF
chmod +x "${WORKDIR}/systemctl"

# apt mock: `apt update` succeeds, `apt install` fails when
# ${WORKDIR}/apt.install-fails exists.
cat > "${WORKDIR}/apt" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "${WORKDIR}/apt.args"
if [ "\$1" = "install" ] && [ -e "${WORKDIR}/apt.install-fails" ]; then
    echo "E: mocked install failure"
    exit 100
fi
exit 0
EOF
chmod +x "${WORKDIR}/apt"

reset() {
    rm -f "${WORKDIR}"/*.args "${WORKDIR}/tailscaled.down" \
          "${WORKDIR}/systemctl.stop-fails" "${WORKDIR}/apt.install-fails"
    cp "${PACKAGE_ROOT}/tailscale-env" "${WORKDIR}/tailscale-env"
    printf 'PORT="41641"\nFLAGS=""\n' > "${TAILSCALED_DEFAULTS_FILE}"
}

# ── update checks the configured channel ──────────────────────────────────────
reset
sed -i 's/^TAILSCALE_CHANNEL=.*/TAILSCALE_CHANNEL="unstable"/' "${WORKDIR}/tailscale-env"
mock "${WORKDIR}/jq" "1.1.0"

output=$("${ROOT}/package/manage.sh" update 2>&1); assert "update succeeds when already on the latest unstable version"
assert_contains "$(cat "${WORKDIR}/curl.args")" "pkgs.tailscale.com/unstable/" "update checks the channel set in tailscale-env"
assert_not_contains "$(cat "${WORKDIR}/curl.args")" "pkgs.tailscale.com/stable/" "update does not check the stable channel when unstable is configured"
assert_contains "$output" "already up to date" "update reports no update when the channel's version is installed"

reset
mock "${WORKDIR}/jq" "1.1.0"
"${ROOT}/package/manage.sh" update >/dev/null 2>&1; assert "update succeeds on the default channel"
assert_contains "$(cat "${WORKDIR}/curl.args")" "pkgs.tailscale.com/stable/" "update checks the stable channel by default"

# ── a failed update leaves tailscaled running ─────────────────────────────────
reset
mock "${WORKDIR}/jq" "1.2.0"
touch "${WORKDIR}/apt.install-fails"

set +e
output=$("${ROOT}/package/manage.sh" update! 2>&1)
status=$?
set -e

[[ $status -ne 0 ]]; assert "update! exits non-zero when the package install fails"
assert_contains "$output" "Failed to install Tailscale" "update! reports the failed package install"
assert_not_contains "$output" "Configuring Tailscale port" "update! stops installing after the package install fails"
assert_contains "$output" "Update failed, ensuring Tailscale is running" "update! runs its recovery path when the install fails"
assert_contains "$(cat "${WORKDIR}/systemctl.args")" "^start tailscaled" "update! starts tailscaled after a failed install"

reset
mock "${WORKDIR}/jq" "1.2.0"
touch "${WORKDIR}/apt.install-fails"

output=$("${ROOT}/package/manage.sh" on-boot 2>&1); assert "on-boot succeeds when the automatic update fails"
assert_contains "$output" "Update failed, continuing with the installed version" "on-boot reports the failed automatic update"
assert_contains "$output" "Tailscaled started successfully" "on-boot still starts tailscaled after a failed update"

# ── a successful update restarts tailscaled once ──────────────────────────────
reset
mock "${WORKDIR}/jq" "1.2.0"
"${ROOT}/package/manage.sh" update! >/dev/null 2>&1; assert "update! succeeds when the install succeeds"
[[ "$(grep -c '^restart tailscaled' "${WORKDIR}/systemctl.args")" -eq 1 ]]; assert "update! restarts tailscaled exactly once"

# ── uninstall stops the reinstall timer ───────────────────────────────────────
reset
for unit in tailscale-install.service tailscale-install.timer \
            tailscale-cert-renewal.service tailscale-cert-renewal.timer; do
    cp "${PACKAGE_ROOT}/${unit}" "${SYSTEMD_UNIT_DIR}/${unit}"
done
touch "${WORKDIR}/systemctl.stop-fails"

"${ROOT}/package/manage.sh" uninstall >/dev/null 2>&1; assert "uninstall succeeds even when tailscaled cannot be stopped"

systemctl_args="$(cat "${WORKDIR}/systemctl.args")"
assert_contains "$systemctl_args" "disable --now tailscale-install.timer" "uninstall stops and disables the reinstall timer"
assert_contains "$systemctl_args" "disable --now tailscale-cert-renewal.timer" "uninstall stops and disables the certificate renewal timer"
assert_contains "$systemctl_args" "daemon-reload" "uninstall reloads systemd after removing the units"
for unit in tailscale-install.service tailscale-install.timer \
            tailscale-cert-renewal.service tailscale-cert-renewal.timer; do
    [[ ! -e "${SYSTEMD_UNIT_DIR}/${unit}" ]]; assert "uninstall removes ${unit}"
done
