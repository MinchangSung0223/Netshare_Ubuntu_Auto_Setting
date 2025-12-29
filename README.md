# NetShare Proxy Auto Switch (Ubuntu + GNOME + APT + pip)

특정 네트워크(NetShare / 핫스팟 등)에 **연결되었을 때만 프록시를 자동 활성화**하고,
그 외 네트워크에서는 **자동으로 프록시를 비활성화**하는 스크립트이다.

이 버전은 다음 사항을 모두 반영한다:

* NetworkManager **dispatcher 기반 자동 실행**
* **인터페이스 기반** NetShare 판별 (auto가 off로 떨어지는 문제 해결)
* APT / GNOME System Proxy / **pip·curl·git용 환경변수**까지 on/off 동기화

---

## 1. 개요

동작 흐름 요약:

1. NetworkManager가 네트워크 변경 이벤트 발생
2. dispatcher가 `netshare-proxy.sh auto <iface>` 호출
3. 스크립트가 **해당 인터페이스의 active connection name**을 기준으로 NetShare 여부 판단
4. NetShare 네트워크일 때만:

   * APT proxy 활성화
   * GNOME proxy 활성화
   * `/etc/profile.d` 기반 ENV proxy 활성화 (pip/curl/git)
5. 그 외 네트워크에서는 위 설정을 모두 비활성화

---

## 2. 설치 위치

스크립트는 root 권한이 필요하므로 `/usr/local/sbin`에 설치한다.

```bash
sudo install -m 0755 netshare-proxy.sh /usr/local/sbin/netshare-proxy.sh
```

---

## 3. NetShare 대상 네트워크 설정 (중요)

### 3.1 NetworkManager connection name 기준 (권장)

`netshare-proxy.sh` 상단에서 아래 값을 **실제 connection name과 정확히 일치**하게 설정해야 한다.

```bash
TARGET_NM_CONN="DIRECT-NS-smcwifi"
```

확인 방법:

```bash
nmcli -t -f DEVICE,TYPE,STATE,CONNECTION dev status
```

출력 예:

```
wlp0s20f3:wifi:connected:DIRECT-NS-smcwifi
```

이때 마지막 필드가 connection name이다.

> ⚠️ 이름이 다르면 `auto` 모드에서 항상 disable됨

---

## 4. 프록시 스크립트 (`netshare-proxy.sh`)

> 📌 `/usr/local/sbin/netshare-proxy.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

# ===== NetShare proxy config =====
PROXY_HOST="192.168.49.1"
PROXY_PORT="8282"
PROXY_URL="http://${PROXY_HOST}:${PROXY_PORT}/"

APT_PROXY_FILE="/etc/apt/apt.conf.d/99proxy"
APT_PROXY_BAK="/etc/apt/apt.conf.d/99proxy.disabled"

# Global env proxy (pip / curl / git) - new shells only
ENV_PROXY_FILE="/etc/profile.d/99proxy.sh"
ENV_PROXY_BAK="/etc/profile.d/99proxy.sh.disabled"

TARGET_NM_CONN="DIRECT-NS-smcwifi"

# ----- NetShare detection (interface-based, reliable) -----
is_netshare() {
  local iface="${1:-}"

  if command -v nmcli >/dev/null 2>&1 && [[ -n "$iface" ]]; then
    local conn
    conn="$(nmcli -g GENERAL.CONNECTION dev show "$iface" 2>/dev/null | head -n 1 || true)"
    [[ -n "$conn" && "$conn" != "--" && "$conn" == "$TARGET_NM_CONN" ]] && return 0
    return 1
  fi

  # Fallback (manual run without iface)
  if command -v nmcli >/dev/null 2>&1; then
    local active
    active="$(nmcli -t -f NAME connection show --active 2>/dev/null | head -n 1 || true)"
    [[ "$active" == "$TARGET_NM_CONN" ]] && return 0
  fi

  return 1
}

# ----- APT proxy -----
enable_apt_proxy() {
  cat > "$APT_PROXY_FILE" <<EOF
Acquire::http::Proxy  "${PROXY_URL}";
Acquire::https::Proxy "${PROXY_URL}";
EOF
  chmod 0644 "$APT_PROXY_FILE"
}

disable_apt_proxy() {
  [[ -f "$APT_PROXY_FILE" ]] && mv -f "$APT_PROXY_FILE" "$APT_PROXY_BAK"
}

# ----- ENV proxy (pip / curl / git) -----
enable_env_proxy() {
  cat > "$ENV_PROXY_FILE" <<EOF
export http_proxy="${PROXY_URL}"
export https_proxy="${PROXY_URL}"
export HTTP_PROXY="${PROXY_URL}"
export HTTPS_PROXY="${PROXY_URL}"
export no_proxy="localhost,127.0.0.1,::1"
export NO_PROXY="\$no_proxy"
EOF
  chmod 0644 "$ENV_PROXY_FILE"
}

disable_env_proxy() {
  [[ -f "$ENV_PROXY_FILE" ]] && mv -f "$ENV_PROXY_FILE" "$ENV_PROXY_BAK"
}

# ----- GNOME proxy -----
get_login_user() {
  [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]] && echo "$SUDO_USER" && return
  loginctl list-users | awk 'NR>1{print $2; exit}'
}

run_gsettings_as_user() {
  local u="$1"; shift
  local uid; uid="$(id -u "$u")"
  runuser -u "$u" -- env DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" "$@"
}

enable_gnome_proxy() {
  local u; u="$(get_login_user)"
  [[ -z "$u" ]] && return 0
  run_gsettings_as_user "$u" gsettings set org.gnome.system.proxy mode manual
  run_gsettings_as_user "$u" gsettings set org.gnome.system.proxy.http host "$PROXY_HOST"
  run_gsettings_as_user "$u" gsettings set org.gnome.system.proxy.http port "$PROXY_PORT"
  run_gsettings_as_user "$u" gsettings set org.gnome.system.proxy.https host "$PROXY_HOST"
  run_gsettings_as_user "$u" gsettings set org.gnome.system.proxy.https port "$PROXY_PORT"
}

disable_gnome_proxy() {
  local u; u="$(get_login_user)"
  [[ -z "$u" ]] && return 0
  run_gsettings_as_user "$u" gsettings set org.gnome.system.proxy mode none
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
    on)  apply_on ;;
    off) apply_off ;;
    *) echo "Usage: $0 [auto|on|off] [iface]" ;;
  esac
}

[[ "$(id -u)" -ne 0 ]] && exec sudo -E "$0" "$@"
main "$@"
```

---

## 5. NetworkManager dispatcher 설정 (자동 실행 핵심)

```bash
sudo tee /etc/NetworkManager/dispatcher.d/90-netshare-proxy >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

SCRIPT="/usr/local/sbin/netshare-proxy.sh"
IFACE="${1:-}"
ACTION="${2:-}"

case "$ACTION" in
  up|down|dhcp4-change|dhcp6-change|connectivity-change|vpn-up|vpn-down)
    "$SCRIPT" auto "$IFACE" || true
    ;;
esac
EOF

sudo chmod 0755 /etc/NetworkManager/dispatcher.d/90-netshare-proxy
sudo systemctl restart NetworkManager
```

---

## 6. 확인 방법

강제 적용:

```bash
sudo netshare-proxy.sh auto
```

현재 연결 확인:

```bash
nmcli -t -f DEVICE,TYPE,STATE,CONNECTION dev status
```

pip 테스트 (새 터미널에서):

```bash
pip install --user streamlit pandas
```

---

## 7. 주의 사항

* `/etc/profile.d` 기반 ENV proxy는 **새로 열린 쉘부터 적용됨**
* auto 모드에서 항상 off가 되면 **connection name 불일치**를 가장 먼저 의심할 것
* GNOME proxy는 로그인된 사용자 세션이 있어야 적용됨

---

## 8. 사용 목적

* NetShare / 핫스팟 환경에서 APT, pip, curl, git DNS 문제 자동 해결
* 연구·개발용 Ubuntu 데스크톱 환경 네트워크 자동 전환
