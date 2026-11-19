#!/usr/bin/env bash
# Runs inside the e2e container (see run.sh): nginx with the captured UniFi
# config, plus fake UniFi services.
#
# Checks are written as single-quoted expressions that check() evaluates later,
# so variables referenced only inside them look unused to shellcheck.
# shellcheck disable=SC2016,SC2034
set -uo pipefail

PASS=0
pass() { PASS=$((PASS + 1)); echo "  ✅  $1"; }
fail() { echo "  ❌  $1"; [ -n "${2:-}" ] && echo "      $2"; echo; echo "--- nginx error log ---"; tail -n 20 /data/unifi-core/logs/nginx-error.log 2>/dev/null; exit 1; }
check() { if eval "$2"; then pass "$1"; else fail "$1" "${3:-}"; fi; }

HTTP=/data/unifi-core/config/http
CONF=$HTTP/shared-runnable-tailscale-unifi.conf
patch() { sh /data/tailscale/ui-patch.sh "$@"; _rc=$?; sleep 1; return $_rc; }  # nginx reloads are async
export TSUI_VERIFY_DELAY=1

echo "== Setting up simulated console"
cp -a /fixture/etc/nginx/. /etc/nginx/
cp -a /fixture/usr/. /usr/
mkdir -p /data /data/unifi-core/logs /var/cache/nginx /run/tailscale-unifi
cp -a /fixture/data/. /data/
cp -a "$HTTP" /tmp/http-stock
PORTAL="$(sed -n 's/^portal_root=//p' /fixture/tmp/tsui-fixture-meta)"
for name in unifi-core unifi-core-direct; do
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 -subj /CN=unifi.local \
    -keyout "/data/unifi-core/config/${name}.key" -out "/data/unifi-core/config/${name}.crt" 2>/dev/null
done

# systemctl stand-in: units are "active" unless /tmp/inactive-<unit> exists.
cat > /usr/local/bin/systemctl <<'EOF'
#!/bin/sh
for a in "$@"; do case "$a" in -*|is-active) ;; *) u="${a%.service}" ;; esac; done
[ -e "/tmp/inactive-$u" ] && exit 3
exit 0
EOF
chmod +x /usr/local/bin/systemctl

cp -a /src/package /data/tailscale
sed -i 's/\r$//' /data/tailscale/*.sh /data/tailscale/ui/start.sh /data/tailscale/tailscale-env
sed -i 's/^TAILSCALE_UI=.*/TAILSCALE_UI="true"/' /data/tailscale/tailscale-env

# The image links nginx's main error log to stderr; keep it in a file instead.
rm -f /var/log/nginx/error.log /var/log/nginx/access.log
node /src/tests/e2e/fakeuos.js "$HTTP" >/tmp/fakeuos.log 2>&1 &
sleep 0.5
nginx -t -q 2>/dev/null || { nginx -t; fail "stock UniFi config validates in this nginx"; }
STOCK_WARNINGS="$(nginx -t 2>&1 | grep -c warn)"
nginx
sleep 0.5

start_backend() {
  sh /data/tailscale/ui/start.sh --mock --socket /run/tailscale-unifi/ui.sock --socket-group nginx \
    >>/tmp/backend.log 2>&1 &
  BACKEND_PID=$!
  for _ in $(seq 1 50); do [ -S /run/tailscale-unifi/ui.sock ] && break; sleep 0.1; done
}
stop_backend() { kill "$BACKEND_PID" 2>/dev/null; wait "$BACKEND_PID" 2>/dev/null; }

get() { curl -sk -m 8 "$@"; }
code() { curl -sk -m 8 -o /dev/null -w '%{http_code}' "$@"; }
# Header names, minus those that legitimately change when the body changes.
headers() { curl -sk -m 8 -D - -o /dev/null "$1" | tr -d '\r' | grep -viE '^(date|content-length|last-modified|etag|accept-ranges|http/)' | sed 's/:.*//' | sort; }
hash_conf() { [ -f "$CONF" ] && stat -c '%i %Y' "$CONF"; }

echo "== Stock behaviour"
STOCK_PAGE="$(get https://127.0.0.1/)"
STOCK_HEADERS="$(headers https://127.0.0.1/network/default/dashboard)"
check "stock portal page served" 'echo "$STOCK_PAGE" | grep -q portal-root'
check "stock page has no panel script" '! echo "$STOCK_PAGE" | grep -q tailscale-unifi'
STOCK_CODES="$(for p in / /api/ping /proxy/network/ /network/default/dashboard /network/default/settings/vpn/site-to-site /proxy/tailscale-unifi/; do echo "$p=$(code "https://127.0.0.1$p")"; done)"

echo "== Preflight refusals (nothing may be installed)"
out="$(patch apply 2>&1)"
check "refuses when the backend is not running" '[ ! -e "$CONF" ] && echo "$out" | grep -q "backend not responding"' "$out"
start_backend
sed -i 's/^TAILSCALE_UI=.*/TAILSCALE_UI="false"/' /data/tailscale/tailscale-env
out="$(patch apply 2>&1)"
check "refuses when TAILSCALE_UI is not enabled" '[ ! -e "$CONF" ] && echo "$out" | grep -q TAILSCALE_UI' "$out"
sed -i 's/^TAILSCALE_UI=.*/TAILSCALE_UI="true"/' /data/tailscale/tailscale-env
touch /tmp/inactive-unifi-core
out="$(patch apply 2>&1)"
check "refuses while unifi-core is stopped" '[ ! -e "$CONF" ] && echo "$out" | grep -q "unifi-core is not running"' "$out"
rm -f /tmp/inactive-unifi-core
touch "$HTTP/site-setup.conf"
out="$(patch apply 2>&1)"
check "refuses while the console is in setup mode" '[ ! -e "$CONF" ] && echo "$out" | grep -q "setup mode"' "$out"
rm -f "$HTTP/site-setup.conf"

echo "== Install"
out="$(patch apply 2>&1)"
check "apply installs the snippet" '[ -f "$CONF" ] && echo "$out" | grep -q "panel installed"' "$out"
check "live nginx config validates" 'nginx -t -q 2>/dev/null'
check "snippet adds no nginx warnings" '[ "$(nginx -t 2>&1 | grep -c warn)" = "$STOCK_WARNINGS" ]' "$(nginx -t 2>&1 | grep warn | sort -u)"
PAGE="$(get https://127.0.0.1/)"
check "portal page now loads the panel script" 'echo "$PAGE" | grep -qF "<script defer src=\"/proxy/tailscale-unifi/inject.js\"></script></head>"'
check "portal page is otherwise byte-identical" '[ "$(echo "$PAGE" | sed "s#<script defer src=\"/proxy/tailscale-unifi/inject.js\"></script>##")" = "$STOCK_PAGE" ]'
check "SPA deep links also get the script" 'get https://127.0.0.1/network/default/settings/vpn/site-to-site | grep -q tailscale-unifi/inject.js'
check "portal response headers unchanged" '[ "$(headers https://127.0.0.1/network/default/dashboard)" = "$STOCK_HEADERS" ]' "stock: $(echo "$STOCK_HEADERS" | tr '
' ' ') | now: $(headers https://127.0.0.1/network/default/dashboard | tr '
' ' ')"
for p in / /api/ping /proxy/network/ /network/default/dashboard; do
  want="$(echo "$STOCK_CODES" | sed -n "s#^$p=##p")"
  check "UniFi endpoint $p unchanged ($want)" '[ "$(code "https://127.0.0.1$p")" = "$want" ]'
done
check "UniFi assets unaffected" '[ "$(code https://127.0.0.1/assets/manifest.json)" != "500" ]'
check "inject.js served" 'get https://127.0.0.1/proxy/tailscale-unifi/inject.js | grep -q __tailscaleUnifiUI'
check "panel page served" '[ "$(code https://127.0.0.1/proxy/tailscale-unifi/)" = 200 ]'

echo "== Authentication & authorization (through real nginx + UniFi auth flow)"
check "API without session is 401" '[ "$(code https://127.0.0.1/proxy/tailscale-unifi/api/state)" = 401 ]'
check "API with invalid session is 401" '[ "$(code -b TOKEN=nope https://127.0.0.1/proxy/tailscale-unifi/api/state)" = 401 ]'
STATE="$(get -b TOKEN=good https://127.0.0.1/proxy/tailscale-unifi/api/state)"
check "admin session reads state" 'echo "$STATE" | grep -q "\"backendState\":\"Running\"" && echo "$STATE" | grep -q "\"admin\":true"' "$STATE"
H=(-H 'Content-Type: application/json' -H 'X-TSUI-Request: 1')
check "admin can change settings" '[ "$(code -b TOKEN=good "${H[@]}" -d "{\"acceptRoutes\":true}" https://127.0.0.1/proxy/tailscale-unifi/api/prefs)" = 200 ]'
check "viewer can read" 'get -b TOKEN=viewer https://127.0.0.1/proxy/tailscale-unifi/api/state | grep -q "\"admin\":false"'
check "viewer cannot change settings" '[ "$(code -b TOKEN=viewer "${H[@]}" -d "{\"ssh\":true}" https://127.0.0.1/proxy/tailscale-unifi/api/prefs)" = 403 ]'
check "cross-site POST rejected" '[ "$(code -b TOKEN=good -H "Content-Type: application/json" -H "Origin: https://evil.example" -d "{\"ssh\":true}" https://127.0.0.1/proxy/tailscale-unifi/api/prefs)" = 403 ]'

echo "== Idempotency"
before="$(hash_conf)"
out="$(patch apply 2>&1)"
check "second apply changes nothing" '[ "$(hash_conf)" = "$before" ] && [ -z "$out" ]' "$out"
# nginx -t appends warnings to nginx's main error log, so count its lines.
errlog_lines() { { wc -l < /var/log/nginx/error.log; } 2>/dev/null || echo 0; }
lines="$(errlog_lines)"
patch apply >/dev/null 2>&1
check "unchanged config: no nginx -t, nothing written to the error log" '[ "$(errlog_lines)" = "$lines" ]' "$lines -> $(errlog_lines)"
echo "# comment added by a UniFi update" >> "$HTTP/shared-runnable-users.conf"
fp="$(cat /run/tailscale-unifi/validated)"
patch apply >/dev/null 2>&1
check "changed UniFi config is validated again" '[ "$(cat /run/tailscale-unifi/validated)" != "$fp" ] && [ -f "$CONF" ]'
sed -i '$d' "$HTTP/shared-runnable-users.conf"

echo "== UniFi restart simulation (unifi-core wipes the directory)"
rm -rf "${HTTP:?}"/*.conf && cp -a /tmp/http-stock/. "$HTTP/" && nginx -s reload 2>/dev/null && sleep 0.5
check "wipe returns the console to stock" '! get https://127.0.0.1/ | grep -q tailscale-unifi'
out="$(patch apply 2>&1)"
check "apply re-installs after the wipe" '[ -f "$CONF" ] && get https://127.0.0.1/ | grep -q tailscale-unifi/inject.js' "$out"

echo "== Conflicts introduced by a future UniFi update"
cp "$HTTP/shared-runnable-users.conf" /tmp/users.bak
printf '\nlocation = /index.html { return 204; }\n' >> "$HTTP/shared-runnable-users.conf"
rm -f "$CONF" && nginx -s reload 2>/dev/null
out="$(patch apply 2>&1)"
check "refuses when UniFi defines the same location" '[ ! -e "$CONF" ] && echo "$out" | grep -q "conflicting location"' "$out"
cp /tmp/users.bak "$HTTP/shared-runnable-users.conf" && nginx -s reload 2>/dev/null
patch apply >/dev/null 2>&1
check "re-installed after conflict resolved" '[ -f "$CONF" ]'
cp "$HTTP/shared-runnable-users.conf" /tmp/users.bak
printf '\nlocation = /index.html { return 204; }\n' >> "$HTTP/shared-runnable-users.conf"
out="$(patch apply 2>&1)"
check "removes itself when UniFi later adds a conflicting location" '[ ! -e "$CONF" ]' "$out"
cp /tmp/users.bak "$HTTP/shared-runnable-users.conf"
nginx -s reload 2>/dev/null

echo "== Automatic rollback"
patch apply >/dev/null 2>&1
rm -f "$CONF" && nginx -s reload 2>/dev/null
chmod 600 /run/tailscale-unifi/ui.sock   # nginx workers can no longer reach the backend
out="$(patch apply 2>&1)"
check "verification failure rolls back" '[ ! -e "$CONF" ] && echo "$out" | grep -q "rolled back"' "$out"
sleep 1  # nginx reloads asynchronously; let old workers drain
check "console is stock after rollback" '[ "$(get https://127.0.0.1/)" = "$STOCK_PAGE" ]' "$(get https://127.0.0.1/ | grep -o 'tailscale-unifi[^"]*' ; ls "$HTTP")"
check "nginx config valid after rollback" 'nginx -t -q 2>/dev/null'
out="$(patch apply 2>&1)"
check "no retry during cool-down" '[ ! -e "$CONF" ] && echo "$out" | grep -q "cool-down"' "$out"
chmod 660 /run/tailscale-unifi/ui.sock
out="$(patch apply --force 2>&1)"
check "apply --force retries and succeeds" '[ -f "$CONF" ]' "$out"

echo "== Sandbox rejects an invalid configuration without touching the live tree"
rm -f "$CONF" && nginx -s reload 2>/dev/null
cp /data/tailscale/ui-patch.sh /tmp/ui-patch-broken.sh
sed -i 's#^    gzip off;#    gzip off;\n    this_is_not_a_directive on;#' /tmp/ui-patch-broken.sh
out="$(TSUI_COOLDOWN=0 sh /tmp/ui-patch-broken.sh apply 2>&1)"
check "invalid snippet rejected in sandbox" '[ ! -e "$CONF" ] && echo "$out" | grep -q "rejected in sandbox"' "$out"
check "live tree untouched by sandbox test" '[ -z "$(ls -A "$HTTP" | grep -v -e "^uos-" | sort | diff - <(ls -A /tmp/http-stock | sort))" ]'
rm -f /run/tailscale-unifi/rollback-at

echo "== Kill switch & removal"
patch apply >/dev/null 2>&1
check "installed again" '[ -f "$CONF" ]'
touch /data/tailscale/ui.disabled
out="$(patch apply 2>&1)"
check "kill switch removes the panel" '[ ! -e "$CONF" ] && ! get https://127.0.0.1/ | grep -q tailscale-unifi' "$out"
rm -f /data/tailscale/ui.disabled
patch apply >/dev/null 2>&1
stop_backend
out="$(patch apply 2>&1)"
check "panel removed when the backend stops" '[ ! -e "$CONF" ]' "$out"
start_backend
patch apply >/dev/null 2>&1
echo "# not ours" > /tmp/foreign && cp /tmp/foreign "$HTTP/shared-runnable-tailscale-unifi.conf.bak"
out="$(patch remove 2>&1)"
check "remove deletes only our file" '[ ! -e "$CONF" ] && [ -e "$HTTP/shared-runnable-tailscale-unifi.conf.bak" ]' "$out"
rm -f "$HTTP/shared-runnable-tailscale-unifi.conf.bak"
echo "# someone else's file" > "$CONF"
out="$(patch remove 2>&1)"
check "refuses to delete a file it did not create" '[ -e "$CONF" ] && echo "$out" | grep -q "not created by tailscale-unifi"' "$out"
rm -f "$CONF"

echo "== Final state"
nginx -s reload 2>/dev/null; sleep 0.5
check "console back to exactly stock" '[ "$(get https://127.0.0.1/)" = "$STOCK_PAGE" ] && nginx -t -q 2>/dev/null'
echo
echo "All ${PASS} end-to-end checks passed."
