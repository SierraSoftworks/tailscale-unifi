#!/bin/sh
# Installs or removes the nginx snippet that adds the Tailscale panel to the
# UniFi OS web UI:
#
#   /data/unifi-core/config/http/shared-runnable-tailscale-unifi.conf
#
# That directory holds UniFi's generated nginx snippets. UniFi empties it
# whenever unifi-core or nginx starts, so the snippet has to be re-applied
# after each restart (see the tailscale-unifi-ui-patch units). No other file
# is changed.
#
# "apply" installs the snippet only if all of these pass:
#   1. The nginx layout matches what the snippet expects (include globs,
#      portal root, no conflicting locations), the console is set up, and the
#      panel backend is answering.
#   2. The current nginx config passes "nginx -t", and a few UniFi URLs return
#      the same status twice in a row.
#   3. "nginx -t" passes on a copy of the config tree with the snippet added.
#   4. After the snippet is moved into place, "nginx -t" passes on the live
#      config.
#   5. After "nginx -s reload", the UniFi URLs from step 2 return the same
#      status as before and the panel is reachable.
# If step 4 or 5 fails the snippet is removed again and nginx reloaded, and
# apply waits an hour before trying again (apply --force skips the wait).
#
# Usage: ui-patch.sh {apply [--force]|remove|check|status|render}
set -u

TAILSCALE_ROOT="${TAILSCALE_ROOT:-/data/tailscale}"
HTTP_DIR="${UNIFI_HTTP_DIR:-/data/unifi-core/config/http}"
SHARE_DIR="${UNIFI_SHARE_HTTP_DIR:-/usr/share/unifi-core/http}"
NGINX_CONF="${NGINX_CONF:-/etc/nginx/nginx.conf}"
NGINX="${NGINX_BIN:-nginx}"
UI_SOCKET="${TSUI_SOCKET:-/run/tailscale-unifi/ui.sock}"
RUN_DIR="${TSUI_RUN_DIR:-/run/tailscale-unifi}"
HEALTH_BASE="${TSUI_HEALTH_BASE:-https://127.0.0.1}"
VERIFY_DELAY="${TSUI_VERIFY_DELAY:-2}"
KILL_FILE="${TAILSCALE_ROOT}/ui.disabled"
COOLDOWN="${TSUI_COOLDOWN:-3600}"   # seconds to wait after a failed apply
FORCE=0

CONF_NAME="shared-runnable-tailscale-unifi.conf"
CONF="${HTTP_DIR}/${CONF_NAME}"
TMP_CONF="${HTTP_DIR}/.tailscale-unifi.conf.tmp"  # does not match *.conf globs
MARKER="# tailscale-unifi-ui: managed file"
URL_PREFIX="/proxy/tailscale-unifi/"

log() {
  echo "ui-patch: $*" >&2
  if command -v logger >/dev/null 2>&1; then
    logger -t tailscale-unifi-ui -- "$*" 2>/dev/null || true
  fi
}

# Read KEY="VALUE" from tailscale-env without executing it.
env_setting() {
  _f="${TAILSCALE_ROOT}/tailscale-env"
  [ -f "$_f" ] || return 0
  sed -n "s/^$1=\"\{0,1\}\([^\"]*\)\"\{0,1\}[[:space:]]*\$/\1/p" "$_f" | tail -n 1
}

is_ours() {
  [ -f "$1" ] && head -n 1 "$1" | grep -qF "$MARKER"
}

# The directory UniFi serves the portal page from, read from UniFi's config so
# the snippet serves the same file.
portal_root() {
  awk '
    /location[[:space:]]+\/[[:space:]]*\{/ { inblock = 1; depth = 0 }
    inblock {
      n = gsub(/\{/, "{"); depth += n
      if ($1 == "root") { gsub(/;/, "", $2); print $2; exit }
      m = gsub(/\}/, "}"); depth -= m
      if (depth <= 0 && m > 0) inblock = 0
    }
  ' "${SHARE_DIR}/shared-post-setup-server.conf" 2>/dev/null
}

render() {
  _root="$1"
  cat <<EOF
${MARKER}
# Tailscale panel, see https://github.com/SierraSoftworks/tailscale-unifi
# Can be deleted at any time. To keep it from coming back: touch ${KILL_FILE}

# Panel page and API, served by tailscale-unifi-ui. The backend checks the
# caller's UniFi OS session on every API request.
location ^~ ${URL_PREFIX} {
    include ${SHARE_DIR}/security.conf;

    proxy_pass http://unix:${UI_SOCKET}:/;
    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-For \$remote_addr;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Forwarded-Host \$host;
    proxy_connect_timeout 5s;
    proxy_read_timeout 60s;
    client_max_body_size 64k;
}

# The UniFi OS portal page with the same file and headers as UniFi's own
# location, plus a <script> tag for the panel.
location = /index.html {
    include ${SHARE_DIR}/cors.conf;
    include ${SHARE_DIR}/security.conf;

    root ${_root};
    expires -1;
    # UniFi's location does not compress this page either.
    gzip off;

    sub_filter_once on;
    sub_filter '</head>' '<script defer src="${URL_PREFIX}inject.js"></script></head>';
}
EOF
}

# Checks

# Prints the reason and returns 1 if the snippet should not be installed.
preflight() {
  if [ -e "$KILL_FILE" ]; then echo "disabled by ${KILL_FILE}"; return 1; fi
  if [ "$(env_setting TAILSCALE_UI)" != "true" ]; then echo "TAILSCALE_UI is not \"true\" in tailscale-env"; return 1; fi
  if ! command -v "$NGINX" >/dev/null 2>&1; then echo "nginx not found"; return 1; fi
  if command -v systemctl >/dev/null 2>&1; then
    for _u in nginx unifi-core; do
      if ! systemctl is-active --quiet "$_u"; then echo "${_u} is not running"; return 1; fi
    done
  fi
  if [ ! -d "$HTTP_DIR" ]; then echo "${HTTP_DIR} missing"; return 1; fi
  if ! grep -qF "include ${HTTP_DIR}/site-*.conf;" "$NGINX_CONF" 2>/dev/null; then
    echo "nginx.conf layout not recognised (site include)"; return 1
  fi
  if ! grep -qF "include ${HTTP_DIR}/shared-runnable-*.conf;" "${SHARE_DIR}/shared-server-defaults.conf" 2>/dev/null; then
    echo "shared-server-defaults.conf layout not recognised (runnable include)"; return 1
  fi
  if [ ! -f "${HTTP_DIR}/site-local-ip.conf" ]; then echo "console not set up (site-local-ip.conf missing)"; return 1; fi
  for _f in "$HTTP_DIR"/site-setup*.conf; do
    if [ -e "$_f" ]; then echo "console is in setup mode"; return 1; fi
  done
  for _f in cors.conf security.conf shared-post-setup-server.conf; do
    if [ ! -f "${SHARE_DIR}/${_f}" ]; then echo "${SHARE_DIR}/${_f} missing"; return 1; fi
  done
  if ! grep -qE "location[[:space:]]+/index\.html" "${SHARE_DIR}/shared-post-setup-server.conf"; then
    echo "portal index location not recognised"; return 1
  fi
  _root="$(portal_root)"
  if [ -z "$_root" ] || [ ! -f "${_root}/index.html" ]; then echo "portal root not found"; return 1; fi
  if ! grep -qF "</head>" "${_root}/index.html" || ! grep -qF 'id="portal-root"' "${_root}/index.html"; then
    echo "portal index.html not recognised"; return 1
  fi
  # The locations the snippet adds must not exist anywhere else.
  for _f in "$SHARE_DIR"/*.conf "$HTTP_DIR"/*.conf; do
    [ -f "$_f" ] || continue
    [ "$_f" = "$CONF" ] && continue
    if grep -qE "location[[:space:]]+=[[:space:]]*/index\.html|${URL_PREFIX}" "$_f"; then
      echo "conflicting location in ${_f}"; return 1
    fi
  done
  if ! backend_ok; then echo "tailscale-unifi-ui backend not responding on ${UI_SOCKET}"; return 1; fi
  return 0
}

backend_ok() {
  [ -S "$UI_SOCKET" ] || return 1
  curl -sf -m 5 --unix-socket "$UI_SOCKET" http://localhost/healthz 2>/dev/null | grep -q '^ok'
}

nginx_test_live() {
  "$NGINX" -t -q -c "$NGINX_CONF" >/dev/null 2>&1
}

# Run nginx -t on a copy of the config tree that includes the snippet.
sandbox_test() {
  _content="$1"
  _sb="$(mktemp -d "${TMPDIR:-/tmp}/tsui-sandbox.XXXXXX")" || return 1
  mkdir -p "${_sb}/http" "${_sb}/share"
  cp "$HTTP_DIR"/*.conf "${_sb}/http/" 2>/dev/null
  cp "$SHARE_DIR"/*.conf "${_sb}/share/" 2>/dev/null
  rm -f "${_sb}/http/${CONF_NAME}"
  printf '%s\n' "$_content" > "${_sb}/http/${CONF_NAME}"
  cp "$NGINX_CONF" "${_sb}/nginx.conf"
  for _f in "${_sb}/nginx.conf" "${_sb}"/http/*.conf "${_sb}"/share/*.conf; do
    [ -f "$_f" ] || continue
    sed -i -e "s#${HTTP_DIR}/#${_sb}/http/#g" -e "s#${SHARE_DIR}/#${_sb}/share/#g" "$_f"
  done
  _out="$("$NGINX" -t -c "${_sb}/nginx.conf" 2>&1)"
  _rc=$?
  rm -rf "$_sb"
  if [ $_rc -ne 0 ]; then
    log "sandbox nginx -t failed: $(echo "$_out" | grep -E 'emerg|error' | head -n 3)"
  fi
  return $_rc
}

# Status code of a URL on the local console ("000" when unreachable).
probe() {
  curl -sk -m 8 -o /dev/null -w '%{http_code}' "${HEALTH_BASE}$1" 2>/dev/null || true
}

# UniFi URLs that must return the same status before and after a change.
probe_set() {
  printf '/=%s /api/ping=%s /proxy/network/=%s /network/default/dashboard=%s' \
    "$(probe /)" "$(probe /api/ping)" "$(probe /proxy/network/)" "$(probe /network/default/dashboard)"
}

verify_once() {
  _now="$(probe_set)"
  if [ "$_now" != "$1" ]; then
    _why="endpoints changed (before: $1; after: ${_now})"
    return 1
  fi
  _page="$(curl -sk -m 8 "${HEALTH_BASE}/" 2>/dev/null)"
  if ! echo "$_page" | grep -qF "${URL_PREFIX}inject.js" || ! echo "$_page" | grep -qF 'id="portal-root"'; then
    _why="portal page not served as expected"
    return 1
  fi
  if [ "$(probe "${URL_PREFIX}healthz")" != "200" ]; then
    _why="panel not reachable through nginx"
    return 1
  fi
  return 0
}

# nginx reloads are asynchronous, and UniFi may reload it at the same moment,
# so verification gets a few attempts.
verify_live() {
  _why=""
  for _attempt in 1 2 3; do
    sleep "$VERIFY_DELAY"
    if verify_once "$1"; then
      return 0
    fi
  done
  log "verification failed: ${_why}"
  return 1
}

# Probe the UniFi endpoints until two consecutive probes agree, so the baseline
# is not taken while an nginx reload (ours or UniFi's) is still in flight.
stable_baseline() {
  _prev="$(probe_set)"
  for _attempt in 1 2 3 4 5; do
    sleep "$VERIFY_DELAY"
    _cur="$(probe_set)"
    if [ "$_cur" = "$_prev" ]; then
      echo "$_cur"
      return 0
    fi
    _prev="$_cur"
  done
  return 1
}

reload_nginx() {
  if nginx_test_live; then
    "$NGINX" -s reload >/dev/null 2>&1
  else
    log "not reloading nginx: live configuration does not validate"
    return 1
  fi
}

# Commands

do_remove() {
  if [ -e "$TMP_CONF" ]; then rm -f "$TMP_CONF"; fi
  if [ -e "$CONF" ]; then
    if ! is_ours "$CONF"; then
      log "refusing to delete ${CONF}: not created by tailscale-unifi"
      return 1
    fi
    rm -f "$CONF"
    log "removed ${CONF}"
    reload_nginx || true
  fi
  return 0
}

do_apply() {
  if ! _why="$(preflight)"; then
    log "not installing panel: ${_why}"
    do_remove
    return 0
  fi

  _desired="$(render "$(portal_root)")"

  if ! is_ours "$CONF" && cooling_down; then
    log "not installing panel: rolled back recently; waiting for the cool-down (use 'apply --force' to retry now)"
    return 0
  fi

  if is_ours "$CONF" && [ "$(cat "$CONF")" = "$_desired" ]; then
    # Already installed: check that the live config is still valid. Skip the
    # check if no config file changed since the last one passed, because
    # nginx -t writes its warnings to the error log on flash every time.
    if [ "$(config_fingerprint)" = "$(cat "${RUN_DIR}/validated" 2>/dev/null)" ]; then
      return 0
    fi
    if nginx_test_live; then
      remember_valid
      return 0
    fi
    log "live nginx config no longer validates with the panel installed; removing it"
    rm -f "$CONF"
    if nginx_test_live; then "$NGINX" -s reload >/dev/null 2>&1; fi
    return 1
  fi

  if [ -e "$CONF" ] && ! is_ours "$CONF"; then
    log "refusing to overwrite ${CONF}: not created by tailscale-unifi"
    return 1
  fi
  if [ -e "$CONF" ]; then
    # An older version of the snippet: remove it first so the baseline is stock.
    rm -f "$CONF"
    reload_nginx || true
  fi

  if ! nginx_test_live; then
    log "not installing panel: UniFi's own nginx config does not validate right now"
    return 0
  fi
  if ! _baseline="$(stable_baseline)"; then
    log "not installing panel: UniFi web UI responses are not stable right now"
    return 0
  fi
  case "$_baseline" in
    *=000*|*=5*) log "not installing panel: UniFi web UI is not healthy right now (${_baseline})"; return 0 ;;
  esac

  if ! sandbox_test "$_desired"; then
    mark_rollback
    log "not installing panel: configuration rejected in sandbox"
    return 1
  fi

  if ! printf '%s\n' "$_desired" > "$TMP_CONF" || ! mv -f "$TMP_CONF" "$CONF"; then
    rm -f "$TMP_CONF"
    log "could not write ${CONF}"
    return 1
  fi

  if ! nginx_test_live; then
    rm -f "$CONF"
    mark_rollback
    log "live nginx -t failed with the panel; removed it (nginx was not reloaded)"
    return 1
  fi
  if ! "$NGINX" -s reload >/dev/null 2>&1; then
    rm -f "$CONF"
    mark_rollback
    log "nginx reload failed; removed the panel"
    reload_nginx || true
    return 1
  fi
  if ! verify_live "$_baseline"; then
    rm -f "$CONF"
    reload_nginx || true
    mark_rollback
    log "rolled back: panel removed and nginx reloaded; not retrying for ${COOLDOWN}s (use 'apply --force' to retry now)"
    return 1
  fi
  rm -f "${RUN_DIR}/rollback-at"
  remember_valid
  log "panel installed"
  return 0
}

# Checksum of the files nginx -t reads (apart from certificates), used to skip
# repeated checks of an unchanged config.
config_fingerprint() {
  cat "$NGINX_CONF" "$SHARE_DIR"/*.conf "$HTTP_DIR"/*.conf 2>/dev/null | cksum
}

# Kept in RUN_DIR (tmpfs), so every boot starts with a full check.
remember_valid() {
  if mkdir -p "$RUN_DIR" 2>/dev/null; then
    config_fingerprint > "${RUN_DIR}/validated" 2>/dev/null || true
  fi
}

mark_rollback() {
  if mkdir -p "$RUN_DIR" 2>/dev/null; then
    date +%s > "${RUN_DIR}/rollback-at" 2>/dev/null || true
  fi
}

# True within COOLDOWN seconds of a failed apply.
cooling_down() {
  [ "$FORCE" = "1" ] && return 1
  [ -f "${RUN_DIR}/rollback-at" ] || return 1
  _at="$(cat "${RUN_DIR}/rollback-at" 2>/dev/null)"
  case "$_at" in ''|*[!0-9]*) return 1 ;; esac
  [ $(( $(date +%s) - _at )) -lt "$COOLDOWN" ]
}

do_status() {
  if is_ours "$CONF"; then echo "installed: yes (${CONF})"; else echo "installed: no"; fi
  if _why="$(preflight)"; then echo "preflight: ok"; else echo "preflight: ${_why}"; fi
  if backend_ok; then echo "backend: running"; else echo "backend: not responding"; fi
  if [ -e "$KILL_FILE" ]; then echo "kill switch: ${KILL_FILE} present"; fi
}

with_lock() {
  mkdir -p "$RUN_DIR" 2>/dev/null || true
  if command -v flock >/dev/null 2>&1; then
    exec 9>"${RUN_DIR}/patch.lock"
    if ! flock -w 60 9; then
      log "another ui-patch run is still in progress"
      return 1
    fi
  fi
  "$@"
}

case "${1:-}" in
  apply)  [ "${2:-}" = "--force" ] && FORCE=1; with_lock do_apply ;;
  remove) with_lock do_remove ;;
  check)  if _why="$(preflight)"; then echo "ok"; else echo "$_why"; exit 1; fi ;;
  status) do_status ;;
  render) render "${2:-$(portal_root)}" ;;
  *)
    echo "Usage: $0 {apply|remove|check|status|render}" >&2
    exit 2
    ;;
esac
