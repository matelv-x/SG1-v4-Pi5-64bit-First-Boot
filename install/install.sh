#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
APP_DIR="/home/pi/sg1_v4"
VENV_DIR="/home/pi/venv_v4"
HOSTNAME_VALUE="${HOSTNAME_VALUE:-stargate}"
SET_HOSTNAME=1
HOSTNAME_EXPLICIT=0
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
  ./install.sh [options]

Options:
  --set-hostname [name]  Set gate network name, default: stargate.local
  --keep-hostname        Keep the current Raspberry Pi hostname
  --hardware-profile NAME Hardware profile: original, servo_motorhat, servo_tmc2209
  --configure-wifi       Prompt for Wi-Fi credentials during install
  --wifi-ssid SSID       Wi-Fi network name; implies --configure-wifi
  --wifi-password PASS   Wi-Fi password/passphrase
  --wifi-country CC      Wi-Fi country code, default: US
  --no-ssh               Do not enable SSH
  -h, --help              Show this help
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --set-hostname|--hostname)
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

choose_hardware_profile() {
  local profile profile_path
  if [ "$HARDWARE_PROFILE" = "" ]; then
    profile="$(bash "$SCRIPT_DIR/choose_hardware_profile.sh")"
  else
    profile="$(bash "$SCRIPT_DIR/choose_hardware_profile.sh" "$HARDWARE_PROFILE")"
  fi

  profile_path="$SCRIPT_DIR/profiles/${profile}.conf"
  # shellcheck disable=SC1090
  source "$profile_path"

  echo
  echo "Selected hardware profile: $PROFILE_NAME"
  echo "$PROFILE_DESC"
}

check_hardware_profile() {
  bash "$SCRIPT_DIR/check_hardware_profile.sh" "$PROFILE_ID"
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
  as_root modprobe i2c-dev >/dev/null 2>&1 || true
}

configure_ssh_wifi() {
  ENABLE_SSH="$ENABLE_SSH" \
  CONFIGURE_WIFI="$CONFIGURE_WIFI" \
  WIFI_SSID="$WIFI_SSID" \
  WIFI_PASSWORD="$WIFI_PASSWORD" \
  WIFI_COUNTRY="$WIFI_COUNTRY" \
    bash "$SCRIPT_DIR/configure_ssh_wifi.sh"
}

configure_pi_login() {
  echo "Setting pi password and passwordless sudo"
  echo "pi:sg1" | as_root chpasswd
  echo "pi ALL=(ALL) NOPASSWD:ALL" | as_root tee /etc/sudoers.d/010_pi-nopasswd >/dev/null
  as_root chmod 0440 /etc/sudoers.d/010_pi-nopasswd
}

install_hardware_check_packages() {
  echo "Installing hardware check packages"
  as_root apt-get update
  as_root apt-get install --no-install-recommends -y \
    i2c-tools python3-smbus iw rfkill
}

install_system_packages() {
  echo "Installing system packages needed by the selected SG1 build"
  as_root apt-get install --no-install-recommends -y \
    python3-dev python3-venv python3-pip python3-lgpio liblgpio-dev \
    libasound2-dev apache2 avahi-daemon swig git \
    wireguard wireguard-tools
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
  as_root chown -R pi:pi "$APP_DIR"
  as_root chmod u+x "$APP_DIR"/scripts/*.py "$APP_DIR"/util/* "$APP_DIR"/install/*.sh 2>/dev/null || true
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
  as_root chown -R pi:pi "$VENV_DIR"
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
  echo "Installing Stargate systemd service with safe-off hooks"
  as_root tee /etc/systemd/system/stargate.service >/dev/null <<'EOT'
[Unit]
Description=BuildAStargate.com Stargate Daemon (SG1)
Requires=multi-user.target
After=multi-user.target rc-local.service
AllowIsolate=yes

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

echo "Stopping Stargate service if present"
as_root systemctl stop stargate.service 2>/dev/null || true
configure_pi_interfaces
configure_ssh_wifi
install_hardware_check_packages
choose_hardware_profile
check_hardware_profile
motorhat_all_off
install_system_packages
configure_pi_login
install_app_files
apply_hardware_profile
install_python_venv
install_systemd_service
configure_apache
choose_hostname
configure_hostname
motorhat_all_off

echo
echo "Install complete."
echo "Web and SSH address:"
echo "  ${HOSTNAME_VALUE}.local"
echo "Start manually when ready:"
echo "  sudo systemctl start stargate.service"
echo "Check status:"
echo "  systemctl status stargate.service --no-pager -l"
