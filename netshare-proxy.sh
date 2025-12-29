#!/usr/bin/env bash
set -euo pipefail

# ===== NetShare proxy =====
PROXY_HOST="192.168.49.1"
PROXY_PORT="8282"
PROXY_URL="http://${PROXY_HOST}:${PROXY_PORT}/"

# Target network (NetworkManager connection name)
TARGET_NM_CONN="DIRECT-NS-smcwifi"

# ----- APT proxy files -----
APT_PROXY_FILE="/etc/apt/apt.conf.d/99proxy"
APT_PROXY_BAK="/etc/apt/apt.conf.d/99proxy.disabled"

# ----- Global env proxy files (pip/curl/git) -----
ENV_PROXY_FILE="/etc/profile.d/99proxy.sh"
ENV_PROXY_BAK="/etc/profile.d/99proxy.sh.disabled"

# ----- NetShare detection (interface-based; reliable for dispatcher) -----
is_netshare() {
  local iface="${1:-}"

  if command -v nmcli >/dev/null 2>&1 && [[ -n "$iface" ]]; then
    local conn
    conn="$(nmcli -g GENERAL.CONNECTION dev show "$iface" 2>/dev/null | head -n 1 || true)"
    [[ -n "$conn" && "$conn" != "--" && "$conn" == "$TARGET_NM_CONN" ]] && return 0
    return 1
  fi

  # Fallback for manual runs without iface
  if command -v nmcli >/dev/null 2>&1; then
    local conn2
    conn2="$(nmcli -t -f DEVICE,STATE,CONNECTION dev status 2>/dev/null | awk -F: '$2=="connected"{print $3; exit}' || true)"
    [[ -n "$conn2" && "$conn2" == "$TARGET_NM_CONN" ]] && return 0
  fi
  return 1
}

# ----- APT proxy -----
enable_apt_proxy() {
  cat > "$APT_PROXY_FILE" <<EOT
Acquire::http::Proxy  "${PROXY_URL}";
Acquire::https::Proxy "${PROXY_URL}";
EOT
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

# ----- ENV proxy (pip/curl/git) -----
enable_env_proxy() {
  cat > "$ENV_PROXY_FILE" <<EOT
# Auto-managed by netshare-proxy.sh
export http_proxy="${PROXY_URL}"
export https_proxy="${PROXY_URL}"
export HTTP_PROXY="${PROXY_URL}"
export HTTPS_PROXY="${PROXY_URL}"
export no_proxy="localhost,127.0.0.1,::1"
export NO_PROXY="\$no_proxy"
EOT
  chmod 0644 "$ENV_PROXY_FILE"
  echo "[OK] Enabled ENV proxy: $PROXY_URL (new shells only)"
}

disable_env_proxy() {
  if [[ -f "$ENV_PROXY_FILE" ]]; then
    mv -f "$ENV_PROXY_FILE" "$ENV_PROXY_BAK"
    echo "[OK] Disabled ENV proxy (moved to $ENV_PROXY_BAK)"
  else
    echo "[OK] ENV proxy already disabled."
  fi
}

# ----- GNOME proxy -----
get_login_user() {
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER:-}" != "root" ]]; then
    echo "$SUDO_USER"
    return 0
  fi
  loginctl list-users 2>/dev/null | awk 'NR>1{print $2; exit}' || true
}

run_gsettings_as_user() {
  local u="$1"; shift
  [[ -n "$u" ]] || return 0
  local uid; uid="$(id -u "$u")"
  runuser -u "$u" -- env DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" "$@"
}

enable_gnome_proxy() {
  local u; u="$(get_login_user)"
  [[ -n "$u" ]] || { echo "[WARN] No login user; skip GNOME proxy."; return 0; }

  run_gsettings_as_user "$u" gsettings set org.gnome.system.proxy mode 'manual'
  run_gsettings_as_user "$u" gsettings set org.gnome.system.proxy.http host "$PROXY_HOST"
  run_gsettings_as_user "$u" gsettings set org.gnome.system.proxy.http port "$PROXY_PORT"
  run_gsettings_as_user "$u" gsettings set org.gnome.system.proxy.https host "$PROXY_HOST"
  run_gsettings_as_user "$u" gsettings set org.gnome.system.proxy.https port "$PROXY_PORT"
  run_gsettings_as_user "$u" gsettings set org.gnome.system.proxy ignore-hosts "['localhost','127.0.0.1','::1']"
  echo "[OK] Enabled GNOME proxy for user '$u'"
}

disable_gnome_proxy() {
  local u; u="$(get_login_user)"
  [[ -n "$u" ]] || { echo "[WARN] No login user; skip GNOME proxy."; return 0; }
  run_gsettings_as_user "$u" gsettings set org.gnome.system.proxy mode 'none'
  echo "[OK] Disabled GNOME proxy for user '$u'"
}

status() {
  echo "=== Network ==="
  echo "dev status:"
  nmcli -t -f DEVICE,TYPE,STATE,CONNECTION dev status 2>/dev/null || true
  echo "Default GW: $(ip route | awk '/^default/ {print $3; exit}' || true)"

  echo
  echo "=== APT proxy ==="
  ls -al "$APT_PROXY_FILE" "$APT_PROXY_BAK" 2>/dev/null || true
  [[ -f "$APT_PROXY_FILE" ]] && cat "$APT_PROXY_FILE" || true

  echo
  echo "=== ENV proxy ==="
  ls -al "$ENV_PROXY_FILE" "$ENV_PROXY_BAK" 2>/dev/null || true
  [[ -f "$ENV_PROXY_FILE" ]] && cat "$ENV_PROXY_FILE" || true

  echo
  echo "=== GNOME proxy ==="
  local u; u="$(get_login_user || true)"
  echo "user: ${u:-unknown}"
  [[ -n "$u" ]] && run_gsettings_as_user "$u" gsettings get org.gnome.system.proxy mode 2>/dev/null || true
}

apply_on() {
  enable_apt_proxy
  enable_env_proxy
  enable_gnome_proxy
}

apply_off() {
  disable_apt_proxy
  disable_env_proxy
  disable_gnome_proxy
}

main() {
  case "${1:-auto}" in
    auto)
      if is_netshare "${2:-}"; then
        apply_on
      else
        apply_off
      fi
      ;;
    on)     apply_on ;;
    off)    apply_off ;;
    status) status ;;
    *)
      echo "Usage: $0 [auto|on|off|status] [iface]"
      exit 2
      ;;
  esac
}

[[ "$(id -u)" -ne 0 ]] && exec sudo -E "$0" "$@"
main "$@"
