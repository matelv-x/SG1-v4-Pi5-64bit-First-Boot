#!/usr/bin/env python3
"""Switch the Pi5 symbol-ring stepper backend between MotorKit and TMC2209."""

import json
import sys
from pathlib import Path


CONFIG_PATH = Path("/home/pi/sg1_v4/config/milkyway-config.json")
VALID_DRIVERS = {"motorkit", "tmc2209"}


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in VALID_DRIVERS:
        print("Usage: set_stepper_driver.py motorkit|tmc2209", file=sys.stderr)
        return 2

    driver = sys.argv[1]
    data = json.loads(CONFIG_PATH.read_text())
    data.setdefault("stepper_driver", {
        "desc": "Internal stepper driver backend selected from Stepper Use Motor Hat",
        "type": "string-enum",
        "protected": True,
        "enum_values": ["motorkit", "tmc2209"],
    })
    data["stepper_driver"]["value"] = driver
    data.setdefault("stepper_use_motor_hat", {
        "desc": "True selects the Motor HAT stepper driver. False selects the TMC2209 STEP/DIR driver.",
        "type": "bool",
    })
    data["stepper_use_motor_hat"]["value"] = driver == "motorkit"
    CONFIG_PATH.write_text(json.dumps(data, indent=2) + "\n")
    print(f"Stepper driver set to {driver}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
