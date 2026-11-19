#!/usr/bin/env bash
# Tests for `manage.sh ui ...` and the cases where ui-patch.sh refuses to act.
# Everything is mocked. tests/e2e covers ui-patch.sh against a real nginx.
set -e

ROOT="$(dirname "$(dirname "$0")")"
WORKDIR="$(mktemp -d || exit 1)"
trap 'rm -rf ${WORKDIR}' EXIT

# shellcheck source=tests/helpers.sh
. "${ROOT}/tests/helpers.sh"

# A private copy of the package, so a fake UI binary can be added to it.
cp -R "${ROOT}/package" "${WORKDIR}/pkg"
export PACKAGE_ROOT="${WORKDIR}/pkg"
export TAILSCALE_ROOT="${WORKDIR}/pkg"
export SYSTEMD_UNIT_DIR="${WORKDIR}/systemd"
export TAILSCALED_DEFAULTS_FILE="${WORKDIR}/tailscaled.defaults"
export UNIFI_HTTP_DIR="${WORKDIR}/http"
export UNIFI_SHARE_HTTP_DIR="${WORKDIR}/share"
export NGINX_CONF="${WORKDIR}/nginx.conf"
export TSUI_SOCKET="${WORKDIR}/ui.sock"
export TSUI_RUN_DIR="${WORKDIR}/run"
export PATH="${WORKDIR}/bin:${PATH}"
mkdir -p "${SYSTEMD_UNIT_DIR}" "${WORKDIR}/bin" "${UNIFI_HTTP_DIR}" "${UNIFI_SHARE_HTTP_DIR}"

mock "${WORKDIR}/bin/systemctl" ""
mock "${WORKDIR}/bin/nginx" ""
mock "${WORKDIR}/bin/logger" ""
MANAGE="${PACKAGE_ROOT}/manage.sh"
PATCH="${PACKAGE_ROOT}/ui-patch.sh"

echo "manage.sh ui:"

mv "${PACKAGE_ROOT}/ui" "${WORKDIR}/ui"
out="$("$MANAGE" ui enable 2>&1 || true)"
assert_contains "$out" "web UI is not installed" "enable refuses when the UI files are not installed"
assert_eq "$(grep -c '^TAILSCALE_UI="true"' "${TAILSCALE_ROOT}/tailscale-env" || true)" "0" "a refused enable does not change tailscale-env"

mv "${WORKDIR}/ui" "${PACKAGE_ROOT}/ui"
cp "${PACKAGE_ROOT}/tailscale-env" "${WORKDIR}/env.before"
touch "${TAILSCALE_ROOT}/ui.disabled"
reset_mock "${WORKDIR}/bin/systemctl"
"$MANAGE" ui enable >/dev/null 2>&1 || true
assert_contains "$(cat "${TAILSCALE_ROOT}/tailscale-env")" '^TAILSCALE_UI="true"$' "enable sets TAILSCALE_UI=true"
assert_eq "$(grep -c '^TAILSCALE_UI=' "${TAILSCALE_ROOT}/tailscale-env")" "1" "TAILSCALE_UI appears exactly once"
assert_eq "$(grep -v '^TAILSCALE_UI=' "${TAILSCALE_ROOT}/tailscale-env")" "$(grep -v '^TAILSCALE_UI=' "${WORKDIR}/env.before")" "enable leaves every other setting untouched"
[ ! -e "${TAILSCALE_ROOT}/ui.disabled" ]; assert "enable clears the kill switch"
for unit in tailscale-unifi-ui.service tailscale-unifi-ui-patch.service tailscale-unifi-ui-patch.path tailscale-unifi-ui-patch.timer; do
    assert_file_exists "${SYSTEMD_UNIT_DIR}/${unit}" "enable installs ${unit}"
done
assert_contains "$(cat "${WORKDIR}/bin/systemctl.args")" "enable tailscale-unifi-ui.service" "enable enables the units"
assert_contains "$(cat "${WORKDIR}/bin/systemctl.args")" "start tailscale-unifi-ui-patch.service" "enable runs the patcher"

reset_mock "${WORKDIR}/bin/systemctl"
"$MANAGE" ui disable >/dev/null 2>&1
assert_contains "$(cat "${TAILSCALE_ROOT}/tailscale-env")" '^TAILSCALE_UI="false"$' "disable sets TAILSCALE_UI=false"
[ ! -e "${SYSTEMD_UNIT_DIR}/tailscale-unifi-ui.service" ] && [ ! -e "${SYSTEMD_UNIT_DIR}/tailscale-unifi-ui-patch.path" ]; assert "disable removes the units"
assert_contains "$(cat "${WORKDIR}/bin/systemctl.args")" "disable --now tailscale-unifi-ui-patch.path" "disable stops the watcher first"

# on-boot repairs the UI units only when enabled.
rm -f "${SYSTEMD_UNIT_DIR}"/tailscale-unifi-ui*
mock "${WORKDIR}/bin/tailscale" "1.0.0"
mock "${WORKDIR}/bin/curl" ""
mock "${WORKDIR}/bin/jq" ""
mock "${WORKDIR}/bin/sleep" ""
sed -i 's/^TAILSCALE_AUTOUPDATE=.*/TAILSCALE_AUTOUPDATE="false"/' "${TAILSCALE_ROOT}/tailscale-env"
"$MANAGE" on-boot >/dev/null 2>&1 || true
[ ! -e "${SYSTEMD_UNIT_DIR}/tailscale-unifi-ui.service" ]; assert "on-boot does not install UI units while the UI is disabled"
sed -i 's/^TAILSCALE_UI=.*/TAILSCALE_UI="true"/' "${TAILSCALE_ROOT}/tailscale-env"
"$MANAGE" on-boot >/dev/null 2>&1 || true
assert_file_exists "${SYSTEMD_UNIT_DIR}/tailscale-unifi-ui-patch.path" "on-boot re-installs UI units after a firmware update wiped them"

echo ""
echo "ui-patch.sh:"

rendered="$(sh "$PATCH" render /portal/root)"
assert_contains "$rendered" "^# tailscale-unifi-ui: managed file" "rendered snippet starts with the ownership marker"
assert_contains "$rendered" "proxy_pass http://unix:${TSUI_SOCKET}:/;" "panel is proxied to the Unix socket"
assert_contains "$rendered" "root /portal/root;" "portal root comes from UniFi's config"
assert_contains "$rendered" "include ${UNIFI_SHARE_HTTP_DIR}/security.conf;" "UniFi's own security headers are kept"
assert_not_contains "$rendered" "listen" "snippet never opens a port"

touch "${TAILSCALE_ROOT}/ui.disabled"
assert_contains "$(sh "$PATCH" check 2>&1 || true)" "disabled by" "check honours the kill switch"
rm -f "${TAILSCALE_ROOT}/ui.disabled"
sed -i 's/^TAILSCALE_UI=.*/TAILSCALE_UI="false"/' "${TAILSCALE_ROOT}/tailscale-env"
assert_contains "$(sh "$PATCH" check 2>&1 || true)" "TAILSCALE_UI" "check requires TAILSCALE_UI=true"
sed -i 's/^TAILSCALE_UI=.*/TAILSCALE_UI="true"/' "${TAILSCALE_ROOT}/tailscale-env"
echo "worker_processes 1;" > "$NGINX_CONF"
assert_contains "$(sh "$PATCH" check 2>&1 || true)" "nginx.conf layout not recognised" "check refuses an unknown nginx.conf layout"

# apply with a failing preflight must leave the directory untouched and never reload nginx.
reset_mock "${WORKDIR}/bin/nginx"
sh "$PATCH" apply >/dev/null 2>&1
assert_eq "$(ls -A "$UNIFI_HTTP_DIR")" "" "apply installs nothing when preflight fails"
[ ! -f "${WORKDIR}/bin/nginx.args" ]; assert "apply does not touch nginx when preflight fails"

# remove only ever deletes our own file.
echo "# someone else" > "${UNIFI_HTTP_DIR}/shared-runnable-tailscale-unifi.conf"
sh "$PATCH" remove >/dev/null 2>&1 || true
assert_file_exists "${UNIFI_HTTP_DIR}/shared-runnable-tailscale-unifi.conf" "remove refuses to delete a file it did not create"
printf '%s\n' "$rendered" > "${UNIFI_HTTP_DIR}/shared-runnable-tailscale-unifi.conf"
sh "$PATCH" remove >/dev/null 2>&1
[ ! -e "${UNIFI_HTTP_DIR}/shared-runnable-tailscale-unifi.conf" ]; assert "remove deletes its own file"
