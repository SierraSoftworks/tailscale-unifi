#!/usr/bin/env bash
# Copy a console's UniFi OS nginx configuration for tests/e2e. Read-only on
# the console.
#
# Only nginx config files and the portal's index.html are copied, no
# certificates or keys (the test generates its own at the same paths).
#
# Usage: tests/e2e/capture-fixture.sh <ssh-host> [outdir]
set -euo pipefail
HOST="${1?usage: capture-fixture.sh <ssh-host> [outdir]}"
OUT="${2:-$(dirname "$0")/fixture}"
mkdir -p "$OUT"

# shellcheck disable=SC2016
ssh "$HOST" 'set -e
  root=$(awk "/location[[:space:]]+\/[[:space:]]*\{/{f=1} f&&\$1==\"root\"{gsub(/;/,\"\",\$2);print \$2;exit}" /usr/share/unifi-core/http/shared-post-setup-server.conf)
  {
    echo "portal_root=$root"
    echo "unifi_core=$(dpkg-query -W -f="\${Version}" unifi-core 2>/dev/null)"
    echo "nginx=$(dpkg-query -W -f="\${Version}" nginx 2>/dev/null)"
    echo "firmware=$(ubnt-device-info firmware 2>/dev/null)"
  } > /tmp/tsui-fixture-meta
  tar czf - \
    /tmp/tsui-fixture-meta \
    /etc/nginx/nginx.conf /etc/nginx/nginx.conf.disabled /etc/nginx/mime.types \
    /usr/share/unifi-core/http/*.conf \
    $(find /data/unifi-core/config/http -maxdepth 1 -type f -name "*.conf") \
    "$root/index.html" 2>/dev/null
  rm -f /tmp/tsui-fixture-meta' | tar xzf - -C "$OUT"
echo "Captured into $OUT:"
cat "$OUT/tmp/tsui-fixture-meta"
