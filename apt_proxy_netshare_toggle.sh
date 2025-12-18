#!/usr/bin/env bash
set -euo pipefail

# NetShare proxy
PROXY_HOST="192.168.49.1"
PROXY_PORT="8282"
PROXY_URL="http://${PROXY_HOST}:${PROXY_PORT}/"

APT_PROXY_FILE="/etc/apt/apt.conf.d/99proxy"
APT_PROXY_BAK="/etc/apt/apt.conf.d/99proxy.disabled"

# ----- NetShare detection -----
is_netshare() {
  local gw
  gw="$(ip route | awk '/^default/ {print $3; exit}' || true)"
  [[ "$gw" == "$PROXY_HOST" ]] || return 1

  if command -v nc >/dev/null 2>&1; then
    nc -z -w 1 "$PROXY_HOST" "$PROXY_PORT" >/dev/null 2>&1
  else
    (echo >/dev/tcp/"$PROXY_HOST"/"$PROXY_PORT") >/dev/null 2>&1
  fi
}

# ----- APT proxy (root) -----
enable_apt_proxy() {
  cat > "$APT_PROXY_FILE" <<EOF
Acquire::http::Proxy  "${PROXY_URL}";
Acquire::https::Proxy "${PROXY_URL}";
EOF
  chmod 0644 "$APT_PROXY_FILE"
  echo "[OK] Enabled APT proxy: $PROXY_URL"
}

disable_apt_proxy() {
  if [[ -f "$APT_PROXY_FILE" ]]; then
    mv -f "$APT_PROXY_FILE" "$APT_PROXY_BAK"
    echo "[OK] Disabled APT proxy (moved to $APT_PROXY_BAK)"
  else
    echo "[OK] APT proxy already disabled."
  fi
}

# ----- GNOME proxy (must run as the logged-in user) -----
# We call gsettings in the *original* user session even if this script runs as root.
get_login_user() {
  # Prefer SUDO_USER when using sudo
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER:-}" != "root" ]]; then
    echo "$SUDO_USER"
    return 0
  fi
  # Fallback: active console user (works in most desktop cases)
  local u
  u="$(loginctl list-users 2>/dev/null | awk 'NR>1 {print $2}' | head -n 1 || true)"
  [[ -n "$u" ]] && echo "$u" || echo ""
}

get_user_dbus_addr() {
  local u="$1"
  [[ -n "$u" ]] || return 1
  local uid
  uid="$(id -u "$u")"
  # Most GNOME sessions expose this socket path
  echo "unix:path=/run/user/${uid}/bus"
}

run_gsettings_as_user() {
  local u="$1"; shift
  if [[ -z "$u" ]]; then
    echo "[WARN] Cannot determine login user; skipping GNOME proxy."
    return 0
  fi
  local dbus_addr
  dbus_addr="$(get_user_dbus_addr "$u")"

  # Run gsettings in that user's session bus
  runuser -u "$u" -- env DBUS_SESSION_BUS_ADDRESS="$dbus_addr" "$@"
}

enable_gnome_proxy() {
  local u; u="$(get_login_user)"
  if [[ -z "$u" ]]; then
    echo "[WARN] No login user detected; GNOME proxy not changed."
    return 0
  fi

  run_gsettings_as_user "$u" gsettings set org.gnome.system.proxy mode 'manual'
  run_gsettings_as_user "$u" gsettings set org.gnome.system.proxy.http host "$PROXY_HOST"
  run_gsettings_as_user "$u" gsettings set org.gnome.system.proxy.http port "$PROXY_PORT"
  run_gsettings_as_user "$u" gsettings set org.gnome.system.proxy.https host "$PROXY_HOST"
  run_gsettings_as_user "$u" gsettings set org.gnome.system.proxy.https port "$PROXY_PORT"
  run_gsettings_as_user "$u" gsettings set org.gnome.system.proxy ignore-hosts "['localhost','127.0.0.1','::1']"

  echo "[OK] Enabled GNOME proxy (manual): ${PROXY_HOST}:${PROXY_PORT} for user '$u'"
}

disable_gnome_proxy() {
  local u; u="$(get_login_user)"
  if [[ -z "$u" ]]; then
    echo "[WARN] No login user detected; GNOME proxy not changed."
    return 0
  fi
  run_gsettings_as_user "$u" gsettings set org.gnome.system.proxy mode 'none'
  echo "[OK] Disabled GNOME proxy (mode=none) for user '$u'"
}

status() {
  echo "Default GW: $(ip route | awk '/^default/ {print $3; exit}' || true)"
  if [[ -f "$APT_PROXY_FILE" ]]; then
    echo "APT proxy file: $APT_PROXY_FILE (enabled)"
    cat "$APT_PROXY_FILE"
  elif [[ -f "$APT_PROXY_BAK" ]]; then
    echo "APT proxy file: $APT_PROXY_BAK (disabled)"
    cat "$APT_PROXY_BAK"
  else
    echo "APT proxy file: (none)"
  fi

  local u; u="$(get_login_user || true)"
  if [[ -n "$u" ]]; then
    echo "GNOME proxy user: $u"
    # Best-effort read (won't fail script)
    run_gsettings_as_user "$u" gsettings get org.gnome.system.proxy mode 2>/dev/null || true
    run_gsettings_as_user "$u" gsettings get org.gnome.system.proxy.http host 2>/dev/null || true
    run_gsettings_as_user "$u" gsettings get org.gnome.system.proxy.http port 2>/dev/null || true
  else
    echo "GNOME proxy user: (unknown)"
  fi
}

apply_on() {
  enable_apt_proxy
  enable_gnome_proxy
}

apply_off() {
  disable_apt_proxy
  disable_gnome_proxy
}

main() {
  case "${1:-auto}" in
    auto)
      if is_netshare; then
        apply_on
      else
        apply_off
      fi
      ;;
    on)     apply_on ;;
    off)    apply_off ;;
    status) status ;;
    *)
      echo "Usage: $0 [auto|on|off|status]"
      exit 2
      ;;
  esac
}

# Needs root for /etc/apt changes; GNOME changes are applied to the original user session.
if [[ "$(id -u)" -ne 0 ]]; then
  exec sudo -E "$0" "$@"
fi

main "$@"

