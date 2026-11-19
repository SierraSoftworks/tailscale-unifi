#!/bin/sh
# Starts the Tailscale panel backend with the Node.js runtime that ships with
# UniFi OS. UniFi installs it under a versioned name (e.g. /usr/bin/node24),
# so pick the newest one. TSUI_NODE overrides the choice.
set -eu

node="${TSUI_NODE:-}"
if [ -z "$node" ]; then
  node="$(printf '%s\n' /usr/bin/node /usr/bin/node[0-9]* /usr/local/bin/node |
    while read -r f; do [ -x "$f" ] && echo "$f"; done | sort -V | tail -n 1)"
fi
if [ -z "$node" ] || [ ! -x "$node" ]; then
  echo "tailscale-unifi-ui: no Node.js runtime found" >&2
  exit 1
fi

exec "$node" --max-old-space-size=48 "$(dirname "$0")/server/main.js" "$@"
