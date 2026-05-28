"""Pi 5 backend for PCA9685 chevron servos with a TMC2209 stepper driver.

Hardware map:
- PCA9685 servo board: I2C 0x40, servo channels 0-6 for chevrons 1-7
- TMC2209: STEP/DIR/EN GPIO pins from config
- Wormhole NeoPixel data: BCM12 / physical pin 32 / board.D12
- Chevron LEDs: BCM pins listed in CHEVRON_LED_PINS

The TMC2209 is driven in plain STEP/DIR mode. Microstepping/current are expected
to be configured on the driver hardware, not over UART.
"""

import os
from time import sleep

os.environ.setdefault("GPIOZERO_PIN_FACTORY", "lgpio")

from adafruit_motor import stepper as stp  # pylint: disable=import-error
from adafruit_servokit import ServoKit  # pylint: disable=import-error
import board  # pylint: disable=import-error
import neopixel  # pylint: disable=import-error
from gpiozero import DigitalOutputDevice, LED  # pylint: disable=import-error

try:
    from gpiozero.pins.lgpio import LGPIOFactory  # pylint: disable=import-error
except Exception:  # pylint: disable=broad-except
    LGPIOFactory = None

from hardware_simulation import DCMotorSim, StepperSim, LEDSim
from stargate_config import StargateConfig


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


class TMC2209StepDirAdapter:
    """Small StepperMotor-compatible adapter for STEP/DIR stepper drivers."""

    def __init__(
        self,
        step_pin,
        dir_pin,
        enable_pin,
        enable_active_low=True,
        step_pulse_seconds=0.00001,
        direction_setup_seconds=0.000005,
        pin_factory=None,
        log=None,
    ):
        self.log = log
        self.enable_active_low = enable_active_low
        self.step_pulse_seconds = step_pulse_seconds
        self.direction_setup_seconds = direction_setup_seconds
        self._enabled = False

        kwargs = {"pin_factory": pin_factory} if pin_factory else {}
        self.step = DigitalOutputDevice(step_pin, initial_value=False, **kwargs)
        self.direction = DigitalOutputDevice(dir_pin, initial_value=False, **kwargs)
        self.enable = DigitalOutputDevice(enable_pin, initial_value=not enable_active_low, **kwargs)
        self.release()

    def _set_enabled(self, enabled):
        if enabled:
            self.enable.value = 0 if self.enable_active_low else 1
            self._enabled = True
        else:
            self.enable.value = 1 if self.enable_active_low else 0
            self._enabled = False

    def onestep(self, direction=stp.FORWARD, style=stp.DOUBLE):  # pylint: disable=unused-argument
        if not self._enabled:
            self._set_enabled(True)

        self.direction.value = 1 if direction == stp.FORWARD else 0
        if self.direction_setup_seconds > 0:
            sleep(self.direction_setup_seconds)

        self.step.on()
        sleep(self.step_pulse_seconds)
        self.step.off()
        sleep(self.step_pulse_seconds)
        return None

    def release(self):
        self._set_enabled(False)


class ElectronicsPCA9685ServoTMC2209:
    """Pi 5 backend: PCA9685 servos + TMC2209 STEP/DIR + GPIO LEDs/NeoPixel."""

    CHEVRON_LED_PINS = {
        1: 21,
        2: 16,
        3: 20,
        4: 26,
        5: 6,
        6: 13,
        7: 19,
        8: 23,
        9: 25,
    }

    def __init__(self, app):
        self.cfg = app.cfg
        self.log = app.log
        self.name = "Pi5 PCA9685 Servo Chevrons + TMC2209 Step/Dir + GPIO Chevron LEDs + NeoPixel D12"

        self.board_cfg = StargateConfig(app.base_path, "board_original", app.galaxy_path)
        self.board_cfg.set_log(app.log)
        self.board_cfg.load()

        self.stepper_motor_enable = self.cfg.get("stepper_motor_enable")
        self.chevron_motors_enable = self.cfg.get("chevron_motors_enable")

        self.servo_address = 0x40
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
        self.motor_channels = None
        self.led_channels = None
        self.stepper = None
        self.neopixels = None

        self.init_pin_factory()
        self.init_servos()
        self.init_stepper()
        self.init_led_gpio()
        self.init_neopixels()

        self.log.log(f"Hardware Detected: {self.name}")

    def init_pin_factory(self):
        if LGPIOFactory:
            try:
                self.pin_factory = LGPIOFactory()
            except Exception as exc:  # pylint: disable=broad-except
                self.log.log(f"LGPIOFactory unavailable; GPIO fallback may be simulated. Error: {exc}")
                self.pin_factory = None

    def init_servos(self):
        try:
            self.servo_kit = ServoKit(channels=16, address=self.servo_address)
        except Exception as exc:  # pylint: disable=broad-except
            self.log.log(f"PCA9685 ServoKit unavailable; using motor simulation. Error: {exc}")
            self.servo_kit = None

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

    def init_stepper(self):
        if not self.stepper_motor_enable:
            self.stepper = StepperSim()
            return

        try:
            self.stepper = TMC2209StepDirAdapter(
                step_pin=self.cfg.get("tmc2209_step_pin"),
                dir_pin=self.cfg.get("tmc2209_dir_pin"),
                enable_pin=self.cfg.get("tmc2209_enable_pin"),
                enable_active_low=self.cfg.get("tmc2209_enable_active_low"),
                step_pulse_seconds=self.cfg.get("tmc2209_step_pulse_seconds"),
                direction_setup_seconds=self.cfg.get("tmc2209_direction_setup_seconds"),
                pin_factory=self.pin_factory,
                log=self.log,
            )
            self.release_stepper()
        except Exception as exc:  # pylint: disable=broad-except
            self.log.log(f"TMC2209 GPIO stepper unavailable; using stepper simulation. Error: {exc}")
            self.stepper = StepperSim()

    def init_led_gpio(self):
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

    def release_stepper(self, sleep_driver=False):  # pylint: disable=unused-argument
        try:
            if self.stepper:
                self.stepper.release()
        except Exception as exc:  # pylint: disable=broad-except
            self.log.log(f"TMC2209 stepper release failed: {exc}")

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
