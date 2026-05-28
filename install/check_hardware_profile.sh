#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE="${1:-}"
ASSUME_YES="${ASSUME_YES:-0}"

if [ "$PROFILE" = "" ]; then
  echo "Usage: check_hardware_profile.sh PROFILE" >&2
  exit 2
fi

PROFILE_PATH="$SCRIPT_DIR/profiles/${PROFILE}.conf"
if [ ! -f "$PROFILE_PATH" ]; then
  echo "Unknown hardware profile: $PROFILE" >&2
  exit 2
fi

# shellcheck disable=SC1090
source "$PROFILE_PATH"

normalize_i2c_address() {
  local value
  value="$1"
  value="${value#0x}"
  value="${value#0X}"
  printf '0x%02x' "$((16#$value))"
}

scan_i2c_addresses() {
  if ! command -v i2cdetect >/dev/null 2>&1; then
    return 1
  fi

  i2cdetect -y 1 2>/dev/null | awk '
    NR > 1 {
      row = $1
      gsub(":", "", row)
      for (i = 2; i <= NF; i++) {
        if ($i != "--") {
          col = i - 2
          printf "0x%s%x\n", substr(row, 1, 1), col
        }
      }
    }
  '
}

contains_address() {
  local needle="$1"
  local haystack="$2"
  grep -qx "$needle" <<<"$haystack"
}

echo
echo "Hardware preflight check for: $PROFILE_NAME"

if [ "${PROFILE_ID:-}" = "servo_tmc2209" ]; then
  echo "Note: TMC2209 is connected by GPIO STEP/DIR and cannot be detected on I2C."
  echo "      This check verifies the PCA9685 servo board only."
fi

if ! detected="$(scan_i2c_addresses)"; then
  echo "WARNING: i2cdetect is not available or I2C bus 1 cannot be scanned."
  echo "Installation can continue, but hardware cannot be verified now."
  if [ "$ASSUME_YES" = "1" ] || [ ! -t 0 ]; then
    exit 0
  fi
  read -r -p "Continue anyway? [Y/n]: " answer
  answer="${answer:-Y}"
  case "$answer" in
    y|Y|yes|YES) exit 0 ;;
    *) echo "Install cancelled."; exit 1 ;;
  esac
fi

echo "Detected I2C devices:"
if [ "$detected" = "" ]; then
  echo "  none"
else
  sed 's/^/  /' <<<"$detected"
fi

missing=""
for expected in $EXPECTED_I2C_ADDRESSES; do
  expected="$(normalize_i2c_address "$expected")"
  if contains_address "$expected" "$detected"; then
    echo "OK: found required $expected"
  else
    echo "MISSING: required $expected"
    missing="$missing $expected"
  fi
done

for optional in ${OPTIONAL_I2C_ADDRESSES:-}; do
  optional="$(normalize_i2c_address "$optional")"
  if contains_address "$optional" "$detected"; then
    echo "OK: found optional $optional"
  fi
done

if [ "$missing" = "" ]; then
  echo "Hardware check passed."
  exit 0
fi

echo
echo "WARNING: selected profile does not match the currently detected I2C hardware."
echo "Missing required device(s):$missing"
echo "Installation can continue; SG1 may run in simulation/no-hardware mode until hardware is connected."

if [ "$ASSUME_YES" = "1" ] || [ ! -t 0 ]; then
  echo "Continuing because installer is non-interactive."
  exit 0
fi

read -r -p "Continue anyway? [Y/n]: " answer
answer="${answer:-Y}"
case "$answer" in
  y|Y|yes|YES) exit 0 ;;
  *) echo "Install cancelled."; exit 1 ;;
esac
