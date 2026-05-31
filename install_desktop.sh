#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$SCRIPT_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
APP_DIR="${APP_DIR:-/home/pi/sg1_v4}"
VENV_DIR="${VENV_DIR:-/home/pi/venv_v4}"
HOSTNAME_VALUE="stargate"
SET_HOSTNAME=1
HOSTNAME_EXPLICIT=0
SET_PI_PASSWORD=0
START_SERVICE=1
HARDWARE_PROFILE="${HARDWARE_PROFILE:-}"
PROFILE_ID=""
PROFILE_NAME=""
PROFILE_DESC=""
REQUIREMENTS_FILE="requirements_pi5_backup_lock.txt"
STEPPER_DRIVER="tmc2209"
STEPPER_USE_MOTOR_HAT="false"
HARDWARE_CONFIG_FIELDS=""
CONFIGURE_WIFI="${CONFIGURE_WIFI:-}"
WIFI_SSID="${WIFI_SSID:-}"
WIFI_PASSWORD="${WIFI_PASSWORD:-}"
WIFI_COUNTRY="${WIFI_COUNTRY:-}"
ENABLE_SSH="${ENABLE_SSH:-1}"

usage() {
  cat <<'EOF'
Usage:
  ./install_desktop.sh [options]

Options:
  --set-hostname [name]   Set gate network name, default: stargate.local
  --keep-hostname         Keep the current Raspberry Pi hostname
  --set-pi-password       Set user pi password to sg1 and enable passwordless sudo
  --hardware-profile NAME Hardware profile: original, servo_motorhat, servo_tmc2209
  --configure-wifi        Prompt for Wi-Fi credentials during install
  --wifi-ssid SSID        Wi-Fi network name; implies --configure-wifi
  --wifi-password PASS    Wi-Fi password/passphrase
  --wifi-country CC       Wi-Fi country code, default: US
  --no-ssh                Do not enable SSH
  --no-start              Install but do not start stargate.service
  -h, --help              Show this help

This installer is for Raspberry Pi OS Desktop 64-bit. It preserves the desktop
session: it does not force console autologin, does not disable the display
manager, and does not change the user's password unless requested.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --set-hostname)
      SET_HOSTNAME=1
      HOSTNAME_EXPLICIT=1
      if [ "${2:-}" != "" ] && [[ "${2:-}" != --* ]]; then
        HOSTNAME_VALUE="$2"
        shift
      fi
      shift
      ;;
    --keep-hostname)
      SET_HOSTNAME=0
      shift
      ;;
    --set-pi-password)
      SET_PI_PASSWORD=1
      shift
      ;;
    --hardware-profile)
      HARDWARE_PROFILE="${2:-}"
      if [ "$HARDWARE_PROFILE" = "" ] || [[ "$HARDWARE_PROFILE" == --* ]]; then
        echo "--hardware-profile requires a profile name" >&2
        exit 2
      fi
      shift 2
      ;;
    --configure-wifi)
      CONFIGURE_WIFI=1
      shift
      ;;
    --wifi-ssid)
      WIFI_SSID="${2:-}"
      CONFIGURE_WIFI=1
      shift 2
      ;;
    --wifi-password)
      WIFI_PASSWORD="${2:-}"
      shift 2
      ;;
    --wifi-country)
      WIFI_COUNTRY="${2:-}"
      shift 2
      ;;
    --no-ssh)
      ENABLE_SSH=0
      shift
      ;;
    --no-start)
      START_SERVICE=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

target_user() {
  if id pi >/dev/null 2>&1; then
    echo pi
  elif [ "${SUDO_USER:-}" != "" ] && [ "${SUDO_USER:-}" != "root" ]; then
    echo "$SUDO_USER"
  else
    id -un
  fi
}

TARGET_USER="$(target_user)"
TARGET_GROUP="$(id -gn "$TARGET_USER")"

choose_hardware_profile() {
  local profile profile_path
  if [ "$HARDWARE_PROFILE" = "" ]; then
    profile="$(bash "$SCRIPT_DIR/install/choose_hardware_profile.sh")"
  else
    profile="$(bash "$SCRIPT_DIR/install/choose_hardware_profile.sh" "$HARDWARE_PROFILE")"
  fi

  profile_path="$SCRIPT_DIR/install/profiles/${profile}.conf"
  # shellcheck disable=SC1090
  source "$profile_path"

  echo
  echo "Selected hardware profile: $PROFILE_NAME"
  echo "$PROFILE_DESC"
}

check_hardware_profile() {
  bash "$SCRIPT_DIR/install/check_hardware_profile.sh" "$PROFILE_ID"
}

as_user() {
  if [ "$(id -u)" -eq 0 ]; then
    sudo -u "$TARGET_USER" "$@"
  else
    "$@"
  fi
}

trust_desktop_launcher() {
  local launcher uid bus
  launcher="$1"

  as_root chmod +x "$launcher"

  if ! command -v gio >/dev/null 2>&1; then
    return 0
  fi

  uid="$(id -u "$TARGET_USER")"
  bus="/run/user/$uid/bus"

  if [ -S "$bus" ]; then
    as_user env \
      XDG_RUNTIME_DIR="/run/user/$uid" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=$bus" \
      gio set "$launcher" metadata::trusted true >/dev/null 2>&1 || true
  else
    as_user gio set "$launcher" metadata::trusted true >/dev/null 2>&1 || true
  fi
}

motorhat_all_off() {
  if command -v i2cset >/dev/null 2>&1; then
    as_root i2cset -y 1 0x60 0xFA 0x00 >/dev/null 2>&1 || true
    as_root i2cset -y 1 0x60 0xFB 0x00 >/dev/null 2>&1 || true
    as_root i2cset -y 1 0x60 0xFC 0x00 >/dev/null 2>&1 || true
    as_root i2cset -y 1 0x60 0xFD 0x10 >/dev/null 2>&1 || true
    as_root i2cset -y 1 0x60 0x00 0x10 >/dev/null 2>&1 || true
  fi
}

configure_hostname() {
  [ "$SET_HOSTNAME" = "1" ] || return 0

  HOSTNAME_VALUE="$(normalize_hostname "$HOSTNAME_VALUE")"
  echo "Configuring hostname as ${HOSTNAME_VALUE}.local"
  if command -v raspi-config >/dev/null 2>&1; then
    as_root raspi-config nonint do_hostname "$HOSTNAME_VALUE" >/dev/null || true
  fi
  as_root hostnamectl set-hostname "$HOSTNAME_VALUE" || true

  if grep -Eq '^127\.0\.1\.1[[:space:]]+' /etc/hosts; then
    as_root sed -i "s/^127\\.0\\.1\\.1.*/127.0.1.1    ${HOSTNAME_VALUE}/" /etc/hosts
  else
    echo "127.0.1.1    ${HOSTNAME_VALUE}" | as_root tee -a /etc/hosts >/dev/null
  fi

  as_root systemctl restart avahi-daemon >/dev/null 2>&1 || true
}

normalize_hostname() {
  local name
  name="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  name="${name%.local}"
  name="$(printf '%s' "$name" | sed -E 's/[^a-z0-9-]+/-/g; s/^-+//; s/-+$//')"
  if [ "$name" = "" ]; then
    name="stargate"
  fi
  printf '%s\n' "$name"
}

choose_hostname() {
  [ "$SET_HOSTNAME" = "1" ] || return 0

  if [ "$HOSTNAME_EXPLICIT" != "1" ] && [ -t 0 ]; then
    echo
    read -r -p "Gate network name [${HOSTNAME_VALUE}.local]: " answer
    if [ "$answer" != "" ]; then
      HOSTNAME_VALUE="$answer"
    fi
  fi

  HOSTNAME_VALUE="$(normalize_hostname "$HOSTNAME_VALUE")"
  echo "Gate will be reachable as: ${HOSTNAME_VALUE}.local"
}

configure_pi_interfaces() {
  if command -v raspi-config >/dev/null 2>&1; then
    echo "Enabling I2C and SPI"
    as_root raspi-config nonint do_i2c 0 || true
    as_root raspi-config nonint do_spi 0 || true
  fi
}

configure_ssh_wifi() {
  ENABLE_SSH="$ENABLE_SSH" \
  CONFIGURE_WIFI="$CONFIGURE_WIFI" \
  WIFI_SSID="$WIFI_SSID" \
  WIFI_PASSWORD="$WIFI_PASSWORD" \
  WIFI_COUNTRY="$WIFI_COUNTRY" \
    bash "$SCRIPT_DIR/install/configure_ssh_wifi.sh"
}

configure_pi_login_if_requested() {
  [ "$SET_PI_PASSWORD" = "1" ] || return 0
  if ! id pi >/dev/null 2>&1; then
    echo "User pi does not exist; skipping pi password setup"
    return 0
  fi

  echo "Setting pi password and passwordless sudo"
  echo "pi:sg1" | as_root chpasswd
  echo "pi ALL=(ALL) NOPASSWD:ALL" | as_root tee /etc/sudoers.d/010_pi-nopasswd >/dev/null
  as_root chmod 0440 /etc/sudoers.d/010_pi-nopasswd
}

install_system_packages() {
  echo "Installing system packages needed by SG1 v4 on Raspberry Pi OS Desktop"
  as_root apt-get update
  as_root apt-get install -y \
    python3-dev python3-venv python3-pip python3-lgpio liblgpio-dev \
    libasound2-dev i2c-tools python3-smbus apache2 avahi-daemon \
    swig git wireguard wireguard-tools xdg-utils curl xbindkeys xdotool

  if ! command -v chromium-browser >/dev/null 2>&1 && ! command -v chromium >/dev/null 2>&1; then
    echo "Installing Chromium for SG1 desktop webview"
    as_root apt-get install -y chromium-browser || as_root apt-get install -y chromium
  fi
}

install_app_files() {
  local src_real app_real
  src_real="$(readlink -f "$SRC_DIR")"
  app_real="$(readlink -f "$APP_DIR" 2>/dev/null || true)"

  if [ "$src_real" = "$app_real" ]; then
    echo "Using existing source folder in place: $APP_DIR"
  else
    if [ -d "$APP_DIR" ]; then
      echo "Backing up existing $APP_DIR to ${APP_DIR}.backup-${STAMP}"
      as_root mv "$APP_DIR" "${APP_DIR}.backup-${STAMP}"
    fi

    echo "Copying SG1 v4 code to $APP_DIR"
    as_root mkdir -p "$APP_DIR"
    as_root cp -a "$SRC_DIR/." "$APP_DIR/"
  fi

  as_root rm -rf "$APP_DIR/web/retro" "$APP_DIR/soundfx/alarm"
  as_root chown -R "$TARGET_USER:$TARGET_GROUP" "$APP_DIR"
  as_root chmod u+x "$APP_DIR"/scripts/*.py "$APP_DIR"/util/* "$APP_DIR"/install/*.sh "$APP_DIR"/install_desktop.sh 2>/dev/null || true
}

install_python_venv() {
  if [ -d "$VENV_DIR" ]; then
    echo "Backing up existing $VENV_DIR to ${VENV_DIR}.backup-${STAMP}"
    as_root mv "$VENV_DIR" "${VENV_DIR}.backup-${STAMP}"
  fi

  echo "Creating fresh Python venv at $VENV_DIR"
  as_root python3 -m venv "$VENV_DIR"
  as_root "$VENV_DIR/bin/python" -m pip install --upgrade pip setuptools wheel
  as_root "$VENV_DIR/bin/python" -m pip install -r "$APP_DIR/$REQUIREMENTS_FILE"
  as_root chown -R "$TARGET_USER:$TARGET_GROUP" "$VENV_DIR"
}

apply_hardware_profile() {
  echo "Applying hardware profile: $PROFILE_NAME"
  as_root python3 "$APP_DIR/install/apply_hardware_profile.py" \
    "$APP_DIR" \
    "$PROFILE_ID" \
    "$STEPPER_DRIVER" \
    "$STEPPER_USE_MOTOR_HAT" \
    "$HARDWARE_CONFIG_FIELDS"
}

install_systemd_service() {
  echo "Installing Stargate systemd service"
  as_root tee /etc/systemd/system/stargate.service >/dev/null <<'EOT'
[Unit]
Description=BuildAStargate.com Stargate Daemon (SG1)
Wants=network-online.target
After=network-online.target rc-local.service

[Service]
Type=simple
WorkingDirectory=/home/pi/sg1_v4
ExecStartPre=/home/pi/venv_v4/bin/python /home/pi/sg1_v4/scripts/motorhat_all_off.py --sleep
ExecStartPre=/home/pi/venv_v4/bin/python /home/pi/sg1_v4/scripts/tmc2209_disable.py
ExecStart=/home/pi/venv_v4/bin/python /home/pi/sg1_v4/main.py --daemon
ExecStopPost=/home/pi/venv_v4/bin/python /home/pi/sg1_v4/scripts/motorhat_all_off.py --sleep
ExecStopPost=/home/pi/venv_v4/bin/python /home/pi/sg1_v4/scripts/tmc2209_disable.py

[Install]
WantedBy=multi-user.target
EOT

  as_root systemctl daemon-reload
  as_root systemctl enable stargate.service
}

configure_apache() {
  echo "Configuring Apache web interface"
  as_root tee /etc/apache2/conf-available/stargate_api.conf >/dev/null <<'EOT'
<Directory /home/pi/sg1_v4/web>
    Options Indexes FollowSymLinks
    AllowOverride None
    Require all granted
</Directory>
ProxyPass     /stargate/     http://localhost:8080/ retry=0
EOT
  as_root ln -sf /etc/apache2/conf-available/stargate_api.conf /etc/apache2/conf-enabled/stargate_api.conf
  as_root ln -sf ../mods-available/proxy.conf /etc/apache2/mods-enabled/proxy.conf
  as_root ln -sf ../mods-available/proxy.load /etc/apache2/mods-enabled/proxy.load
  as_root ln -sf ../mods-available/proxy_http.load /etc/apache2/mods-enabled/proxy_http.load
  as_root sed -i 's/export APACHE_RUN_USER=www-data/export APACHE_RUN_USER=pi/' /etc/apache2/envvars
  as_root sed -i 's/export APACHE_RUN_GROUP=www-data/export APACHE_RUN_GROUP=pi/' /etc/apache2/envvars
  as_root sed -i 's|DocumentRoot .*|DocumentRoot /home/pi/sg1_v4/web|' /etc/apache2/sites-available/000-default.conf
  as_root systemctl restart apache2
}

configure_pcmanfm_launching() {
  local user_home libfm_conf
  user_home="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
  libfm_conf="$user_home/.config/libfm/libfm.conf"

  as_root mkdir -p "$(dirname "$libfm_conf")"

  if [ ! -f "$libfm_conf" ]; then
    as_root tee "$libfm_conf" >/dev/null <<'EOT'
[config]
quick_exec=1
EOT
  elif grep -q '^quick_exec=' "$libfm_conf"; then
    as_root sed -i 's/^quick_exec=.*/quick_exec=1/' "$libfm_conf"
  else
    as_root sed -i '/^\[config\]/a quick_exec=1' "$libfm_conf"
  fi

  as_root chown "$TARGET_USER:$TARGET_GROUP" "$libfm_conf"
}

install_desktop_shortcuts() {
  local desktop_dir user_home launcher webview_launcher icon_path
  user_home="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
  desktop_dir="$user_home/Desktop"
  launcher="$desktop_dir/SG1 Stargate WebView.desktop"
  webview_launcher="$APP_DIR/desktop/stargate-webview.sh"
  icon_path="$APP_DIR/desktop/sg1-webview-icon.png"

  as_root mkdir -p "$APP_DIR/desktop"
  as_root tee "$webview_launcher" >/dev/null <<'EOT'
#!/bin/bash
set -euo pipefail

URL="${1:-http://localhost/}"

find_chromium() {
  if command -v chromium-browser >/dev/null 2>&1; then
    command -v chromium-browser
  elif command -v chromium >/dev/null 2>&1; then
    command -v chromium
  else
    return 1
  fi
}

CHROMIUM="$(find_chromium || true)"
if [ -z "$CHROMIUM" ]; then
  if command -v xdg-open >/dev/null 2>&1; then
    exec xdg-open "$URL"
  fi
  echo "Chromium is not installed and xdg-open is unavailable." >&2
  exit 1
fi

for _ in $(seq 1 30); do
  if curl -fsS "$URL" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if command -v xbindkeys >/dev/null 2>&1 && command -v xdotool >/dev/null 2>&1 && command -v xprop >/dev/null 2>&1; then
  BIND_RC="${XDG_RUNTIME_DIR:-/tmp}/sg1-webview-xbindkeys.rc"
  BIND_ACTION="/home/pi/sg1_v4/desktop/minimize-sg1-webview.sh"
  cat > "$BIND_ACTION" <<'EOS'
#!/bin/bash
active="$(xdotool getactivewindow 2>/dev/null || true)"
[ -n "$active" ] || exit 0
props="$(xprop -id "$active" WM_CLASS WM_NAME 2>/dev/null || true)"
echo "$props" | grep -Eiq 'chromium|SG1 Stargate|Stargate WebView' || exit 0
xdotool windowminimize "$active" 2>/dev/null || true
EOS
  chmod +x "$BIND_ACTION"
  cat > "$BIND_RC" <<EOS
"$BIND_ACTION"
  Escape
EOS
  pkill -u "$(id -u)" -f "xbindkeys.*sg1-webview-xbindkeys.rc" 2>/dev/null || true
  xbindkeys -f "$BIND_RC" >/dev/null 2>&1 || true
fi

exec "$CHROMIUM" \
  --app="$URL" \
  --start-fullscreen \
  --no-first-run \
  --disable-infobars \
  --disable-session-crashed-bubble \
  --disable-features=TranslateUI \
  --overscroll-history-navigation=0
EOT
  as_root chown "$TARGET_USER:$TARGET_GROUP" "$webview_launcher"
  as_root chmod +x "$webview_launcher"

  [ -d "$desktop_dir" ] || return 0

  cat > /tmp/sg1-stargate-web.desktop <<'EOT'
[Desktop Entry]
Type=Application
Name=SG1 Stargate WebView
Comment=Open SG1 Stargate in a borderless webview window
Exec=/home/pi/sg1_v4/desktop/stargate-webview.sh http://localhost/
Icon=/home/pi/sg1_v4/desktop/sg1-webview-icon.png
Terminal=false
Categories=Utility;
EOT
  as_root cp /tmp/sg1-stargate-web.desktop "$launcher"
  as_root chown "$TARGET_USER:$TARGET_GROUP" "$launcher"
  [ -f "$icon_path" ] && as_root chown "$TARGET_USER:$TARGET_GROUP" "$icon_path"
  trust_desktop_launcher "$launcher"
  rm -f /tmp/sg1-stargate-web.desktop
}

echo "Stopping Stargate service if present"
as_root systemctl stop stargate.service 2>/dev/null || true
choose_hardware_profile
check_hardware_profile
motorhat_all_off
configure_pi_interfaces
configure_ssh_wifi
install_system_packages
configure_pi_login_if_requested
install_app_files
apply_hardware_profile
install_python_venv
install_systemd_service
configure_apache
configure_pcmanfm_launching
install_desktop_shortcuts
choose_hostname
configure_hostname
motorhat_all_off

if [ "$START_SERVICE" = "1" ]; then
  echo "Starting Stargate service"
  as_root systemctl restart stargate.service
fi

echo
echo "Desktop install complete."
echo "Open the web UI:"
echo "  http://localhost/"
if [ "$SET_HOSTNAME" = "1" ]; then
  echo "  http://${HOSTNAME_VALUE}.local/"
  echo "SSH:"
  echo "  ssh ${TARGET_USER}@${HOSTNAME_VALUE}.local"
else
  echo "  http://$(hostname).local/"
fi
echo "Check service status:"
echo "  systemctl status stargate.service --no-pager -l"
