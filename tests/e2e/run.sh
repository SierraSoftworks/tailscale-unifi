#!/usr/bin/env bash
# Tests ui-patch.sh against nginx running a console's UniFi OS web config
# (captured with tests/e2e/capture-fixture.sh), inside a temporary container.
#
# Usage: tests/e2e/run.sh [fixture-dir]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIXTURE="${1:-${ROOT}/tests/e2e/fixture}"
NGINX_IMAGE="${E2E_NGINX_IMAGE:-nginx:1.30}"
NODE_IMAGE="${E2E_NODE_IMAGE:-node:24-bookworm-slim}"
IMAGE="tailscale-unifi-e2e"

if [ ! -f "${FIXTURE}/tmp/tsui-fixture-meta" ]; then
  echo "No fixture at ${FIXTURE}. Capture one first: tests/e2e/capture-fixture.sh <console-ssh-host>" >&2
  exit 2
fi

echo "Building ${IMAGE} (${NGINX_IMAGE} with Node.js from ${NODE_IMAGE})"
docker build -q -t "$IMAGE" - >/dev/null <<EOF
FROM ${NODE_IMAGE} AS node
FROM ${NGINX_IMAGE}
COPY --from=node /usr/local/bin/node /usr/local/bin/node
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends openssl libstdc++6 >/dev/null \
 && rm -rf /var/lib/apt/lists/*
EOF

winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else echo "$1"; fi; }

MSYS_NO_PATHCONV=1 docker run --rm \
  -v "$(winpath "$ROOT"):/src:ro" \
  -v "$(winpath "$FIXTURE"):/fixture:ro" \
  "$IMAGE" bash /src/tests/e2e/in-container.sh
