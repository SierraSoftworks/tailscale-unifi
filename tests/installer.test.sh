#!/usr/bin/env bash
# Tests for install.sh: re-running it must keep the user's tailscale-env.
set -e

ROOT="$(cd "$(dirname "$(dirname "$0")")" && pwd)"
WORKDIR="$(mktemp -d || exit 1)"
trap 'rm -rf ${WORKDIR}' EXIT

# shellcheck source=tests/helpers.sh
. "${ROOT}/tests/helpers.sh"

BIN="${WORKDIR}/bin"
mkdir -p "$BIN"
export PATH="${BIN}:${PATH}"
export PACKAGE_ROOT="${WORKDIR}/data/tailscale"
mkdir -p "$(dirname "$PACKAGE_ROOT")"

# Build a package whose tailscale-env carries a setting from a "newer release"
# and whose manage.sh is a stub, so install.sh can run end to end offline.
PKG="${WORKDIR}/pkg"
mkdir -p "${PKG}/tailscale"
cp "${ROOT}/package/tailscale-env" "${PKG}/tailscale/tailscale-env"
printf '%s\n' 'TAILSCALE_NEW_SETTING="default"' >> "${PKG}/tailscale/tailscale-env"
cat > "${PKG}/tailscale/manage.sh" <<EOF
#!/bin/sh
echo "\$*" >> "${WORKDIR}/manage.args"
EOF
chmod +x "${PKG}/tailscale/manage.sh"
tar czf "${WORKDIR}/tailscale-unifi.tgz" -C "$PKG" tailscale

# curl mock: write the package to the -o destination.
cat > "${BIN}/curl" <<EOF
#!/usr/bin/env bash
while [ \$# -gt 0 ]; do
    if [ "\$1" = "-o" ]; then cp "${WORKDIR}/tailscale-unifi.tgz" "\$2"; fi
    shift
done
EOF
chmod +x "${BIN}/curl"
mock "${BIN}/ubnt-device-info" "4"

env_file="${PACKAGE_ROOT}/tailscale-env"

# ── fresh install ─────────────────────────────────────────────────────────────
sh "${ROOT}/install.sh" >/dev/null 2>&1; assert "install.sh succeeds on a fresh device"
assert_file_exists "$env_file" "install.sh creates tailscale-env on a fresh device"
assert_contains "$(cat "${WORKDIR}/manage.args")" "^install" "install.sh runs manage.sh install"

# ── re-running keeps the user's settings ──────────────────────────────────────
cat > "$env_file" <<'EOF'
PORT="41641"
TAILSCALED_FLAGS="--tun userspace-networking"
TAILSCALE_FLAGS=""
TAILSCALE_AUTOUPDATE="false"
TAILSCALE_CHANNEL="unstable"
TS_TUN_DISABLE_TCP_GRO=1
EOF

sh "${ROOT}/install.sh" >/dev/null 2>&1; assert "install.sh succeeds over an existing install"
env_content="$(cat "$env_file")"
assert_contains "$env_content" "^TS_TUN_DISABLE_TCP_GRO=1$" "re-running install.sh keeps TS_ settings"
assert_contains "$env_content" '^TAILSCALE_CHANNEL="unstable"$' "re-running install.sh keeps the configured channel"
assert_contains "$env_content" '^TAILSCALE_AUTOUPDATE="false"$' "re-running install.sh keeps the auto-update setting"
assert_contains "$env_content" '^TAILSCALED_FLAGS="--tun userspace-networking"$' "re-running install.sh keeps tailscaled flags"
assert_contains "$env_content" '^TAILSCALE_NEW_SETTING="default"$' "re-running install.sh adds settings introduced by the new release"
assert_contains "$env_content" '^TAILSCALE_ADVISORIES="true"$' "re-running install.sh adds packaged settings missing from the existing file"
[[ "$(grep -c '^TAILSCALE_CHANNEL=' "$env_file")" -eq 1 ]]; assert "re-running install.sh does not duplicate existing settings"

# ── TAILSCALED_FLAGS override replaces, rather than appends ───────────────────
TAILSCALED_FLAGS="--verbose 1" sh "${ROOT}/install.sh" >/dev/null 2>&1; assert "install.sh succeeds with a TAILSCALED_FLAGS override"
TAILSCALED_FLAGS="--verbose 1" sh "${ROOT}/install.sh" >/dev/null 2>&1; assert "install.sh succeeds when run again with the same override"
[[ "$(grep -c '^TAILSCALED_FLAGS=' "$env_file")" -eq 1 ]]; assert "TAILSCALED_FLAGS appears once after repeated overrides"
assert_contains "$(cat "$env_file")" '^TAILSCALED_FLAGS="--verbose 1"$' "the TAILSCALED_FLAGS override is applied"
assert_contains "$(cat "$env_file")" "^TS_TUN_DISABLE_TCP_GRO=1$" "a TAILSCALED_FLAGS override keeps other settings"
