#!/usr/bin/env python3
"""Force the Adafruit Motor HAT at 0x60 off.

This is intentionally tiny and independent from the Stargate app so systemd can
run it before/after the service. It mirrors the known-safe i2cset sequence used
for matelv-x's Pi 5 build.
"""

import sys

MOTORHAT_ADDRESS = 0x60
ALL_LED_ON_L = 0xFA
ALL_LED_ON_H = 0xFB
ALL_LED_OFF_L = 0xFC
ALL_LED_OFF_H = 0xFD
MODE1 = 0x00
FULL_OFF = 0x10


def main():
    try:
        import smbus2 as smbus
    except ModuleNotFoundError:
        print("smbus2 is not installed; skipping Motor HAT all-off", file=sys.stderr)
        return 0

    sleep_driver = "--sleep" in sys.argv

    try:
        with smbus.SMBus(1) as bus:
            bus.write_byte_data(MOTORHAT_ADDRESS, ALL_LED_ON_L, 0x00)
            bus.write_byte_data(MOTORHAT_ADDRESS, ALL_LED_ON_H, 0x00)
            bus.write_byte_data(MOTORHAT_ADDRESS, ALL_LED_OFF_L, 0x00)
            bus.write_byte_data(MOTORHAT_ADDRESS, ALL_LED_OFF_H, FULL_OFF)
            if sleep_driver:
                bus.write_byte_data(MOTORHAT_ADDRESS, MODE1, FULL_OFF)
    except OSError as ex:
        print(f"Motor HAT 0x{MOTORHAT_ADDRESS:02x} not available; skipping all-off: {ex}", file=sys.stderr)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
