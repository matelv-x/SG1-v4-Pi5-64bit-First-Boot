#!/usr/bin/env python3
import json
import sys
from pathlib import Path


PROFILE_NAMES = {
    "original": "Original 3 x Motor HAT",
    "servo_motorhat": "Servo chevrons + 1 x Motor HAT stepper",
    "servo_tmc2209": "Servo chevrons + TMC2209 stepper",
}


def parse_bool(value):
    return str(value).strip().lower() in ("1", "true", "yes", "y")


def set_record(config, key, value, record_type=None, desc=None, protected=None, hidden=None):
    record = config.setdefault(key, {})
    record["value"] = value
    if record_type is not None:
        record["type"] = record_type
    if desc is not None:
        record["desc"] = desc
    if protected is not None:
        record["protected"] = protected
    if hidden is not None:
        record["hidden"] = hidden
    return record


def apply_chevron_labels(config, profile_id):
    chevron_keys = [
        "chevron_down_throttle",
        "chevron_down_time",
        "chevron_down_wait_time",
        "chevron_motors_enable",
        "chevron_up_throttle",
        "chevron_up_time",
    ]

    is_servo = profile_id in ("servo_motorhat", "servo_tmc2209")
    group = "Chevron Servo" if is_servo else "Chevron Motor"

    for key in chevron_keys:
        if key in config:
            config[key]["config_group"] = group

    if "chevron_motors_enable" in config:
        record = config["chevron_motors_enable"]
        if is_servo:
            record["display_name"] = "Chevron Servo Enable"
            record["desc"] = "True to enable Chevron Servo Motors"
        else:
            record["display_name"] = "Chevron Motor Enable"
            record["desc"] = "True to enable Chevron DC Motors"


def main():
    if len(sys.argv) != 6:
        print(
            "Usage: apply_hardware_profile.py APP_DIR PROFILE_ID STEPPER_DRIVER "
            "STEPPER_USE_MOTOR_HAT HARDWARE_CONFIG_FIELDS",
            file=sys.stderr,
        )
        return 2

    app_dir = Path(sys.argv[1])
    profile_id = sys.argv[2]
    stepper_driver = sys.argv[3]
    stepper_use_motor_hat = parse_bool(sys.argv[4])
    hardware_config_fields = sys.argv[5].split()

    if profile_id not in PROFILE_NAMES:
        print(f"Unknown hardware profile: {profile_id}", file=sys.stderr)
        return 2

    config_path = app_dir / "config" / "milkyway-config.json"
    default_config_path = app_dir / "config" / "defaults-milkyway" / "config.json.dist"

    for path in (config_path, default_config_path):
        with path.open("r", encoding="utf-8") as handle:
            config = json.load(handle)

        set_record(
            config,
            "hardware_profile",
            profile_id,
            "string-enum",
            "Hardware profile selected during installation",
            protected=True,
            hidden=True,
        )["enum_values"] = list(PROFILE_NAMES)

        set_record(
            config,
            "hardware_profile_name",
            PROFILE_NAMES[profile_id],
            "str",
            "Hardware profile name selected during installation",
            protected=True,
            hidden=True,
        )

        set_record(
            config,
            "hardware_config_fields",
            hardware_config_fields,
            "list",
            "Config keys visible for the selected hardware profile",
            protected=True,
            hidden=True,
        )

        set_record(config, "stepper_driver", stepper_driver)
        set_record(config, "stepper_use_motor_hat", stepper_use_motor_hat, hidden=True)
        apply_chevron_labels(config, profile_id)

        tmc_keys = [
            "tmc2209_direction_setup_seconds",
            "tmc2209_dir_pin",
            "tmc2209_enable_active_low",
            "tmc2209_enable_pin",
            "tmc2209_step_pin",
            "tmc2209_step_pulse_seconds",
        ]

        for key in tmc_keys:
            if key in config:
                config[key]["hidden"] = stepper_driver != "tmc2209"

        with path.open("w", encoding="utf-8") as handle:
            json.dump(config, handle, indent=2)
            handle.write("\n")

    print(f"Applied hardware profile: {PROFILE_NAMES[profile_id]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
