#!/usr/bin/env python3
"""Disable the TMC2209 stepper driver when that driver is selected in config."""

import json
from pathlib import Path


CONFIG_PATH = Path("/home/pi/sg1_v4/config/milkyway-config.json")


def get_config_value(config, key, default=None):
    try:
        return config[key]["value"]
    except KeyError:
        return default


def main():
    try:
        config = json.loads(CONFIG_PATH.read_text())
    except FileNotFoundError:
        return 0

    if get_config_value(config, "stepper_driver", "motorkit") != "tmc2209":
        return 0

    enable_pin = get_config_value(config, "tmc2209_enable_pin", 22)
    active_low = get_config_value(config, "tmc2209_enable_active_low", True)

    try:
        from gpiozero import DigitalOutputDevice
        from gpiozero.pins.lgpio import LGPIOFactory
    except ModuleNotFoundError:
        return 0

    pin_factory = LGPIOFactory()
    disable_value = 1 if active_low else 0
    try:
        enable = DigitalOutputDevice(enable_pin, initial_value=disable_value, pin_factory=pin_factory)
        enable.value = disable_value
        enable.close()
    except Exception as ex:  # pylint: disable=broad-except
        print(f"TMC2209 enable GPIO{enable_pin} not available; skipping disable: {ex}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
