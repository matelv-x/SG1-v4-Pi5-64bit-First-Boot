#!/bin/bash
set -euo pipefail

ENABLE_SSH="${ENABLE_SSH:-1}"
CONFIGURE_WIFI="${CONFIGURE_WIFI:-}"
WIFI_SSID="${WIFI_SSID:-}"
WIFI_PASSWORD="${WIFI_PASSWORD:-}"
WIFI_COUNTRY="${WIFI_COUNTRY:-}"

as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

enable_ssh() {
  [ "$ENABLE_SSH" = "1" ] || return 0

  echo "Enabling SSH"
  if command -v raspi-config >/dev/null 2>&1; then
    as_root raspi-config nonint do_ssh 0 || true
  fi

  as_root systemctl enable ssh >/dev/null 2>&1 || true
  as_root systemctl start ssh >/dev/null 2>&1 || true
}

ask_wifi_credentials() {
  if [ "$WIFI_SSID" != "" ]; then
    CONFIGURE_WIFI=1
    return 0
  fi

  if [ "$CONFIGURE_WIFI" = "0" ]; then
    return 0
  fi

  if [ ! -t 0 ]; then
    CONFIGURE_WIFI=0
    return 0
  fi

  if [ "$CONFIGURE_WIFI" != "1" ]; then
    echo
    read -r -p "Configure Wi-Fi now? [y/N]: " answer
    answer="${answer:-N}"
    case "$answer" in
      y|Y|yes|YES) CONFIGURE_WIFI=1 ;;
      *) CONFIGURE_WIFI=0; return 0 ;;
    esac
  fi

  read -r -p "Wi-Fi SSID: " WIFI_SSID
  if [ "$WIFI_SSID" = "" ]; then
    echo "No SSID entered; skipping Wi-Fi setup."
    CONFIGURE_WIFI=0
    return 0
  fi

  read -r -s -p "Wi-Fi password/passphrase (leave blank for open network): " WIFI_PASSWORD
  echo

  read -r -p "Wi-Fi country code [US]: " WIFI_COUNTRY
  WIFI_COUNTRY="${WIFI_COUNTRY:-US}"
}

set_wifi_country() {
  [ "${WIFI_COUNTRY:-}" != "" ] || return 0

  echo "Setting Wi-Fi country to $WIFI_COUNTRY"
  if command -v raspi-config >/dev/null 2>&1; then
    as_root raspi-config nonint do_wifi_country "$WIFI_COUNTRY" || true
  fi
}

configure_wifi_nmcli() {
  if ! command -v nmcli >/dev/null 2>&1; then
    return 1
  fi

  echo "Configuring Wi-Fi with NetworkManager"
  as_root rfkill unblock wifi >/dev/null 2>&1 || true
  as_root nmcli radio wifi on >/dev/null 2>&1 || true
  as_root nmcli device set wlan0 managed yes >/dev/null 2>&1 || true
  as_root nmcli device wifi rescan ifname wlan0 >/dev/null 2>&1 || true
  sleep 3

  for _ in 1 2 3; do
    if [ "$WIFI_PASSWORD" = "" ]; then
      as_root nmcli device wifi connect "$WIFI_SSID" ifname wlan0 && return 0
    else
      as_root nmcli device wifi connect "$WIFI_SSID" password "$WIFI_PASSWORD" ifname wlan0 && return 0
    fi
    as_root nmcli device wifi rescan ifname wlan0 >/dev/null 2>&1 || true
    sleep 3
  done

  # Some mixed WPA2/WPA3 networks are visible in scans but fail direct connect.
  # Build an explicit WPA-PSK connection as a more stable fallback.
  as_root nmcli connection delete "$WIFI_SSID" >/dev/null 2>&1 || true
  as_root nmcli connection add type wifi ifname wlan0 con-name "$WIFI_SSID" ssid "$WIFI_SSID" >/dev/null
  if [ "$WIFI_PASSWORD" = "" ]; then
    as_root nmcli connection modify "$WIFI_SSID" 802-11-wireless.mode infrastructure ipv4.method auto ipv6.method disabled
  else
    as_root nmcli connection modify "$WIFI_SSID" 802-11-wireless.mode infrastructure 802-11-wireless-security.key-mgmt wpa-psk 802-11-wireless-security.psk "$WIFI_PASSWORD" ipv4.method auto ipv6.method disabled
  fi
  as_root nmcli connection up "$WIFI_SSID"
}

configure_wifi_wpa_supplicant() {
  local conf
  conf="/etc/wpa_supplicant/wpa_supplicant.conf"

  if ! command -v wpa_passphrase >/dev/null 2>&1; then
    return 1
  fi

  echo "Configuring Wi-Fi with wpa_supplicant"
  as_root mkdir -p /etc/wpa_supplicant
  {
    echo "country=${WIFI_COUNTRY:-US}"
    echo "ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev"
    echo "update_config=1"
    if [ "$WIFI_PASSWORD" = "" ]; then
      cat <<EOF
network={
    ssid="$WIFI_SSID"
    key_mgmt=NONE
}
EOF
    else
      wpa_passphrase "$WIFI_SSID" "$WIFI_PASSWORD"
    fi
  } | as_root tee "$conf" >/dev/null

  as_root chmod 600 "$conf"
  as_root rfkill unblock wifi >/dev/null 2>&1 || true
  as_root systemctl restart wpa_supplicant >/dev/null 2>&1 || true
  as_root systemctl restart dhcpcd >/dev/null 2>&1 || true
}

configure_wifi() {
  ask_wifi_credentials
  [ "$CONFIGURE_WIFI" = "1" ] || return 0

  set_wifi_country

  if configure_wifi_nmcli; then
    echo "Wi-Fi configured for SSID: $WIFI_SSID"
    return 0
  fi

  if configure_wifi_wpa_supplicant; then
    echo "Wi-Fi configured for SSID: $WIFI_SSID"
    return 0
  fi

  echo "WARNING: Could not configure Wi-Fi automatically. No supported Wi-Fi manager found."
  return 0
}

enable_ssh
configure_wifi
