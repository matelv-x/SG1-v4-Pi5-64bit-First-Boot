#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

profile_from_choice() {
  case "$1" in
    1|original) echo "original" ;;
    2|servo_motorhat|servo-motorhat) echo "servo_motorhat" ;;
    3|servo_tmc2209|servo-tmc2209|tmc2209) echo "servo_tmc2209" ;;
    *) return 1 ;;
  esac
}

load_profile() {
  local profile="$1"
  local path="$SCRIPT_DIR/profiles/${profile}.conf"
  if [ ! -f "$path" ]; then
    echo "Unknown hardware profile: $profile" >&2
    return 1
  fi
  # shellcheck disable=SC1090
  source "$path"
}

if [ "${1:-}" != "" ]; then
  PROFILE="$(profile_from_choice "$1")"
  load_profile "$PROFILE"
  printf '%s\n' "$PROFILE_ID"
  exit 0
fi

if [ ! -t 0 ]; then
  load_profile "servo_tmc2209"
  printf '%s\n' "$PROFILE_ID"
  exit 0
fi

cat >&2 <<'EOF'

Select SG1 v4 hardware profile:
  1) Original 3 x Motor HAT
     Choose this for the original Jordan/Kristian hardware.
     - 3 stacked Adafruit Motor HAT boards
     - chevrons moved by DC motors
     - glyph ring stepper connected to a Motor HAT

  2) Servo chevrons + 1 x Motor HAT stepper
     Choose this for a Pi 5 conversion with servo chevrons,
     but the glyph ring still driven by one Motor HAT.
     - PCA9685 servo board for chevrons
     - 1 Adafruit Motor HAT for the glyph ring stepper

  3) Servo chevrons + TMC2209 stepper
     Choose this for matelv-x's Pi 5 servo/TMC2209 build.
     - PCA9685 servo board for chevrons
     - TMC2209 STEP/DIR driver for the glyph ring stepper

EOF

while true; do
  read -r -p "Hardware profile [1-3, default 3]: " choice
  choice="${choice:-3}"
  if PROFILE="$(profile_from_choice "$choice")"; then
    load_profile "$PROFILE"
    echo "Selected: $PROFILE_NAME" >&2
    echo "$PROFILE_ID"
    exit 0
  fi
  echo "Please choose 1, 2, or 3." >&2
done
