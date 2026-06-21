#!/bin/bash
set -e

# Legacy boot hook for unifi-common / udm-boot setups.  This script is packaged
# as on_boot.d/10-tailscaled.sh and runs at boot on devices that execute the
# /data/on_boot.d scripts.  It is a best-effort fallback only; the primary
# mechanism for keeping Tailscale installed across firmware updates is the
# systemd tailscale-install.service/.timer that manage.sh installs.
#
# All of the boot-time logic (unit repair, reinstall, update, start) lives in
# manage.sh's "on-boot" handler, so this just delegates to it instead of
# duplicating OS detection.  UniFi OS 1.x (which used /mnt/data) is no longer
# supported.
exec /data/tailscale/manage.sh on-boot
