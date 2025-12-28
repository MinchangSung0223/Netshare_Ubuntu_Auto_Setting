# NetShare Proxy Auto Switch (Ubuntu + GNOME + APT)

특정 네트워크(NetShare / 핫스팟 등)에 **연결되었을 때만 프록시를 자동 활성화**하고,
그 외 네트워크에서는 **자동으로 프록시를 비활성화**하는 스크립트이다.

지원 범위:

* APT (`/etc/apt/apt.conf.d`)
* GNOME System Proxy (gsettings)
* NetworkManager 기반 자동 트리거

---

## 1. 개요

동작 방식 요약:

* NetworkManager 네트워크 변경 이벤트 감지
* **지정한 네트워크(SSID 또는 connection name)** 일 때만:

  * APT proxy 활성화
  * GNOME proxy 활성화
* 다른 네트워크로 변경되면:

  * APT proxy 비활성화
  * GNOME proxy 비활성화

---

## 2. 설치 위치

스크립트는 root 권한이 필요하므로 `/usr/local/sbin`에 설치하는 것을 권장한다.

```bash
sudo install -m 0755 netshare-proxy.sh /usr/local/sbin/netshare-proxy.sh
```

---

## 3. NetShare 대상 네트워크 설정

스크립트 상단에서 **아래 중 하나만 설정하면 됨**.

### (권장) NetworkManager connection name 기준

```bash
TARGET_NM_CONN="MyNetShareWifi"
```

확인 방법:

```bash
nmcli connection show
```

### (대안) Wi-Fi SSID 기준

```bash
TARGET_SSID="MyPhoneHotspot"
```

확인 방법:

```bash
nmcli dev wifi list
```

---

## 4. 프록시 스크립트 본문

> 📌 `/usr/local/sbin/netshare-proxy.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

# ===== NetShare proxy config =====
PROXY_HOST="192.168.49.1"
PROXY_PORT="8282"
PROXY_URL="http://${PROXY_HOST}:${PROXY_PORT}/"

TARGET_NM_CONN="DIRECT-NS-smcwifi"   # nmcli connection name (권장)

APT_PROXY_FILE="/etc/apt/apt.conf.d/99proxy"
APT_PROXY_BAK="/etc/apt/apt.conf.d/99proxy.disabled"

# ----- NetShare detection -----
is_netshare() {
  if command -v nmcli >/dev/null 2>&1; then
    local active
    active="$(nmcli -t -f NAME,TYPE connection show --active | \
      awk -F: '$2=="wifi" || $2=="ethernet"{print $1; exit}' || true)"

    [[ -n "${TARGET_NM_CONN:-}" && "$active" == "$TARGET_NM_CONN" ]] && return 0

    if [[ -n "${TARGET_SSID:-}" ]]; then
      local ssid
      ssid="$(nmcli -t -f active,ssid dev wifi | awk -F: '$1=="yes"{print $2; exit}' || true)"
      [[ "$ssid" == "$TARGET_SSID" ]] && return 0
    fi
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

# ----- GNOME proxy -----
get_login_user() {
  [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]] && echo "$SUDO_USER" && return
  loginctl list-users | awk 'NR>1{print $2; exit}'
}

run_gsettings_as_user() {
  local u="$1"; shift
  local uid
  uid="$(id -u "$u")"
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

main() {
  case "${1:-auto}" in
    auto)
      if is_netshare; then
        enable_apt_proxy
        enable_gnome_proxy
      else
        disable_apt_proxy
        disable_gnome_proxy
      fi
      ;;
    on)  enable_apt_proxy; enable_gnome_proxy ;;
    off) disable_apt_proxy; disable_gnome_proxy ;;
    *) echo "Usage: $0 [auto|on|off]" ;;
  esac
}

[[ "$(id -u)" -ne 0 ]] && exec sudo -E "$0" "$@"
main "$@"
```

---

## 5. NetworkManager 자동 트리거 설정

네트워크 상태가 변경될 때마다 자동 실행되도록 dispatcher를 등록한다.

```bash
sudo tee /etc/NetworkManager/dispatcher.d/90-netshare-proxy >/dev/null <<'EOF'
#!/usr/bin/env bash
SCRIPT="/usr/local/sbin/netshare-proxy.sh"

case "$2" in
  up|down|dhcp4-change|connectivity-change|vpn-up|vpn-down)
    "$SCRIPT" auto || true
    ;;
esac
EOF
```

권한 부여:

```bash
sudo chmod 0755 /etc/NetworkManager/dispatcher.d/90-netshare-proxy
```

NetworkManager 재시작:

```bash
sudo systemctl restart NetworkManager
```

---

## 6. 상태 확인

```bash
sudo /usr/local/sbin/netshare-proxy.sh auto
sudo /usr/local/sbin/netshare-proxy.sh off
sudo /usr/local/sbin/netshare-proxy.sh on
```

APT 설정 확인:

```bash
cat /etc/apt/apt.conf.d/99proxy*
```

GNOME proxy 확인:

```bash
gsettings get org.gnome.system.proxy mode
```

---

## 7. 주의 사항

* GNOME proxy 설정은 **로그인된 사용자 세션(DBus)** 이 있어야 적용됨
* 로그인 이전에는 APT proxy만 적용될 수 있음 (정상 동작)
* 단일 사용자 데스크톱 환경 기준으로 설계됨

---

## 8. 라이선스 / 사용

* 개인 개발용 / 연구용 환경에서 자유 사용
* NetShare, 핫스팟, 사내 프록시 환경 전환 자동화 목적
