"""Custom Pi 5 hardware backend for matelv-x's Stargate build.

Hardware map confirmed on the working test image:
- PCA9685 servo board: I2C 0x40, servo channels 0-6 for chevrons 1-7
- Adafruit MotorKit HAT: I2C 0x60, symbol-ring stepper on stepper1
- Wormhole NeoPixel data: BCM12 / physical pin 32 / board.D12
- Chevron LEDs: BCM pins listed in CHEVRON_LED_PINS

This backend keeps the original SG1_v4 API intact. The existing Chevron class
still writes ``motor.throttle`` like it did for DC motors; ServoChevronAdapter
translates those throttle writes into servo angles.
"""

import os
from time import sleep

# Force GPIO Zero onto the Pi-5-safe lgpio backend before importing LED.
os.environ.setdefault("GPIOZERO_PIN_FACTORY", "lgpio")

from adafruit_motorkit import MotorKit  # pylint: disable=import-error
from adafruit_motor import stepper as stp  # pylint: disable=import-error
from adafruit_servokit import ServoKit  # pylint: disable=import-error
import board  # pylint: disable=import-error
import neopixel  # pylint: disable=import-error
from gpiozero import LED  # pylint: disable=import-error

try:
    from gpiozero.pins.lgpio import LGPIOFactory  # pylint: disable=import-error
except Exception:  # pylint: disable=broad-except
    LGPIOFactory = None

from hardware_simulation import DCMotorSim, StepperSim, LEDSim
from stargate_config import StargateConfig

MOTORHAT_ALL_LED_ON_L = 0xFA
MOTORHAT_ALL_LED_ON_H = 0xFB
MOTORHAT_ALL_LED_OFF_L = 0xFC
MOTORHAT_ALL_LED_OFF_H = 0xFD
MOTORHAT_MODE1 = 0x00
MOTORHAT_FULL_OFF = 0x10


class ServoChevronAdapter:
    """Adapter that accepts DC-motor-style throttle writes and moves a servo."""

    def __init__(self, servo, open_angle=0, closed_angle=90, pulse_min=500, pulse_max=2500):
        self.is_servo_adapter = True
        self.servo = servo
        self.open_angle = open_angle
        self.closed_angle = closed_angle
        self._throttle = None
        try:
            self.servo.set_pulse_width_range(pulse_min, pulse_max)
        except Exception:  # pylint: disable=broad-except
            pass
        self.angle(self.closed_angle)

    def angle(self, value):
        try:
            self.servo.angle = value
        except Exception:  # pylint: disable=broad-except
            pass

    @property
    def throttle(self):
        return self._throttle

    @throttle.setter
    def throttle(self, value):
        self._throttle = value
        if value is None:
            return
        if value < 0:
            self.angle(self.open_angle)
        elif value > 0:
            self.angle(self.closed_angle)


class ElectronicsPCA9685Servo:
    """Pi 5 backend: PCA9685 servos + MotorKit stepper + real GPIO LEDs/NeoPixel."""

    CHEVRON_LED_PINS = {
        1: 21,  # physical pin 40
        2: 16,  # physical pin 36
        3: 20,  # physical pin 38
        4: 26,  # physical pin 37
        5: 6,   # physical pin 31
        6: 13,  # physical pin 33
        7: 19,  # physical pin 35
        8: 23,  # physical pin 16
        9: 25,  # physical pin 22
    }

    def __init__(self, app):
        self.cfg = app.cfg
        self.log = app.log
        self.name = "Pi5 PCA9685 Servo Chevrons + MotorKit Stepper1 + GPIO Chevron LEDs + NeoPixel D12"

        self.board_cfg = StargateConfig(app.base_path, "board_original", app.galaxy_path)
        self.board_cfg.set_log(app.log)
        self.board_cfg.load()

        self.stepper_motor_enable = self.cfg.get("stepper_motor_enable")
        self.chevron_motors_enable = self.cfg.get("chevron_motors_enable")

        self.servo_address = 0x40
        self.motorkit_address = 0x60
        self.neopixel_pin = board.D12
        self.neopixel_led_count = 122

        self.drive_modes = {
            "double": stp.DOUBLE,
            "single": stp.SINGLE,
            "interleave": stp.INTERLEAVE,
            "microstep": stp.MICROSTEP,
        }

        self.pin_factory = None
        self.servo_kit = None
        self.motor_kit = None
        self.motor_channels = None
        self.led_channels = None
        self.stepper = None
        self.neopixels = None

        self.init_servo_and_stepper()
        self.init_led_gpio()
        self.init_neopixels()

        self.log.log(f"Hardware Detected: {self.name}")

    def init_servo_and_stepper(self):
        try:
            self.servo_kit = ServoKit(channels=16, address=self.servo_address)
        except Exception as exc:  # pylint: disable=broad-except
            self.log.log(f"PCA9685 ServoKit unavailable; using motor simulation. Error: {exc}")
            self.servo_kit = None

        try:
            self.motor_kit = MotorKit(address=self.motorkit_address)
        except Exception as exc:  # pylint: disable=broad-except
            self.log.log(f"MotorKit 0x60 unavailable; using stepper simulation. Error: {exc}")
            self.motor_kit = None

        if self.chevron_motors_enable and self.servo_kit:
            self.motor_channels = {
                1: ServoChevronAdapter(self.servo_kit.servo[0]),
                2: ServoChevronAdapter(self.servo_kit.servo[1]),
                3: ServoChevronAdapter(self.servo_kit.servo[2]),
                4: ServoChevronAdapter(self.servo_kit.servo[3]),
                5: ServoChevronAdapter(self.servo_kit.servo[4]),
                6: ServoChevronAdapter(self.servo_kit.servo[5]),
                7: ServoChevronAdapter(self.servo_kit.servo[6]),
                8: DCMotorSim(),
                9: DCMotorSim(),
            }
        else:
            self.motor_channels = {idx: DCMotorSim() for idx in range(1, 10)}

        if self.stepper_motor_enable and self.motor_kit:
            self.stepper = self.motor_kit.stepper1
            self.release_stepper()
        else:
            self.stepper = StepperSim()

    def init_led_gpio(self):
        if LGPIOFactory:
            try:
                self.pin_factory = LGPIOFactory()
            except Exception as exc:  # pylint: disable=broad-except
                self.log.log(f"LGPIOFactory unavailable; LED fallback may be simulated. Error: {exc}")
                self.pin_factory = None

        self.led_channels = {}
        for channel, pin in self.CHEVRON_LED_PINS.items():
            try:
                if self.pin_factory:
                    self.led_channels[channel] = LED(pin, pin_factory=self.pin_factory)
                else:
                    self.led_channels[channel] = LED(pin)
            except Exception as exc:  # pylint: disable=broad-except
                self.log.log(f"Chevron LED {channel} on BCM{pin} unavailable; using LED simulator. Error: {exc}")
                self.led_channels[channel] = LEDSim()

    def init_neopixels(self):
        try:
            self.neopixels = neopixel.NeoPixel(
                self.neopixel_pin,
                self.neopixel_led_count,
                auto_write=False,
                brightness=0.61,
            )
            self.log.log("NeoPixel wormhole initialized on BCM12 / board.D12")
        except Exception as exc:  # pylint: disable=broad-except
            from hardware_simulation import NeopixelSim
            self.log.log(f"NeoPixel wormhole unavailable; using simulator. Error: {exc}")
            self.neopixels = NeopixelSim(self.neopixel_led_count)

    def get_chevron_led(self, chevron_number):
        channel = self.board_cfg.get(f"chevron_{chevron_number}_led_channel")
        return self.led_channels[channel]

    def get_chevron_motor(self, chevron_number):
        channel = self.board_cfg.get(f"chevron_{chevron_number}_motor_channel")
        return self.motor_channels[channel]

    def get_stepper(self):
        return self.stepper

    def force_motorhat_outputs_off(self, sleep_driver=False):
        """Turn off all PCA9685 outputs on the Motor HAT at 0x60."""
        try:
            import smbus2 as smbus  # pylint: disable=import-outside-toplevel
            with smbus.SMBus(1) as bus:
                bus.write_byte_data(self.motorkit_address, MOTORHAT_ALL_LED_ON_L, 0x00)
                bus.write_byte_data(self.motorkit_address, MOTORHAT_ALL_LED_ON_H, 0x00)
                bus.write_byte_data(self.motorkit_address, MOTORHAT_ALL_LED_OFF_L, 0x00)
                bus.write_byte_data(self.motorkit_address, MOTORHAT_ALL_LED_OFF_H, MOTORHAT_FULL_OFF)
                if sleep_driver:
                    bus.write_byte_data(self.motorkit_address, MOTORHAT_MODE1, MOTORHAT_FULL_OFF)
        except Exception as exc:  # pylint: disable=broad-except
            self.log.log(f"Motor HAT all-off failed: {exc}")

    def release_stepper(self, sleep_driver=False):
        """Release stepper coils without globally disabling Motor HAT during runtime."""
        try:
            if self.stepper:
                self.stepper.release()
        except Exception as exc:  # pylint: disable=broad-except
            self.log.log(f"Stepper release failed: {exc}")
        if sleep_driver:
            self.force_motorhat_outputs_off(sleep_driver=True)

    @staticmethod
    def get_stepper_forward():
        return stp.FORWARD

    @staticmethod
    def get_stepper_backward():
        return stp.BACKWARD

    def get_stepper_drive_mode(self, drive_mode):
        try:
            return self.drive_modes[drive_mode]
        except KeyError:
            return self.drive_modes["double"]

    def get_wormhole_pixels(self):
        return self.neopixels

    def get_wormhole_pixel_count(self):
        return self.neopixel_led_count

    def homing_supported(self):
        return False

    def get_homing_sensor_voltage(self):
        return 0
