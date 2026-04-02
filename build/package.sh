#!/usr/bin/env bash
set -e

SOURCE="${1?You must provide the repo root as the first argument}"
DEST="${2?You must provide the destination directory as the second argument}"
WORKDIR="$(mktemp -d || exit 1)"
trap 'rm -rf ${WORKDIR}' EXIT

echo "Preparing temporary build directory"
cp -R "${SOURCE}/package/" "${WORKDIR}/tailscale"
cp "${SOURCE}/LICENSE" "${WORKDIR}/tailscale/LICENSE"

mkdir -p "${WORKDIR}/on_boot.d"
mv "${WORKDIR}/tailscale/on-boot.sh" "${WORKDIR}/on_boot.d/10-tailscaled.sh"

echo ""
echo "Package Contents:"
ls -l "$WORKDIR"/*
echo ""

echo "Building tailscale-unifi package"
mkdir -p "${DEST}"
# Assuming GNU tar with the --owner and --group args
tar czf "${DEST}/tailscale-unifi.tgz" -C "${WORKDIR}" tailscale on_boot.d --owner=0 --group=0
