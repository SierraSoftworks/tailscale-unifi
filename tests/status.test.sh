#!/bin/bash
set -e

ROOT="$(dirname "$(dirname "$0")")"
WORKDIR="$(mktemp -d || exit 1)"
trap 'rm -rf ${WORKDIR}' EXIT

# shellcheck source=tests/helpers.sh
. "${ROOT}/tests/helpers.sh"

export PACKAGE_ROOT="${ROOT}/package"
export TAILSCALE_ROOT="${WORKDIR}"
export TAILSCALED_SOCK="${WORKDIR}/tailscaled.sock"

SYSTEMCTL_INACTIVE_EXIT=1
SYSTEMCTL_ACTIVE_EXIT=0


export PATH="${WORKDIR}:/usr/bin:/bin:/usr/sbin:/sbin"
mock "${WORKDIR}/ubnt-device-info" "2.0.0"
mock "${WORKDIR}/systemctl" "" "${SYSTEMCTL_INACTIVE_EXIT}"

assert_eq "$("${ROOT}/package/manage.sh" status)" "Tailscale is not installed" "Tailscaled should be reported as not installed"

mock "${WORKDIR}/tailscale" "0.0.0"

mock "${WORKDIR}/systemctl" "" "${SYSTEMCTL_INACTIVE_EXIT}"
assert_eq "$("${ROOT}/package/manage.sh" status)" "Tailscaled is not running" "Tailscaled should be reported as not running"

mock "${WORKDIR}/systemctl" "" "${SYSTEMCTL_ACTIVE_EXIT}"
assert_eq "$("${ROOT}/package/manage.sh" status)" "Tailscaled is running
0.0.0" "Tailscaled should be reported as running with the version number"
