#!/usr/bin/env python3
from pathlib import Path
import sys
from time import sleep

from serial.serialutil import SerialException

APP_ROOT = Path(__file__).resolve().parents[1]
if str(APP_ROOT) not in sys.path:
    sys.path.insert(0, str(APP_ROOT))

from classes.StargateMilkyWay.dialers import DHDv2  # pylint: disable=wrong-import-position


class ConsoleLog:
    @staticmethod
    def log(message):
        print(message)


def key_press():
    import termios
    import tty

    fd = sys.stdin.fileno()
    old_settings = termios.tcgetattr(fd)
    try:
        tty.setraw(fd)
        return sys.stdin.read(1)
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old_settings)


def main():
    dhd_port = DHDv2.get_dhd_port()
    if not dhd_port:
        print("No DHDv2 serial port found.")
        return 1

    try:
        dhd = DHDv2(dhd_port, 115200, ConsoleLog())
    except SerialException as exc:
        print(f"Could not connect to DHDv2 on {dhd_port}: {exc}")
        return 1

    dhd.set_brightness_center(100)
    dhd.set_brightness_symbols(3)
    dhd.set_all_pixels_to_color(0, 0, 0)
    dhd.latch()

    for led in reversed(range(1, 39)):
        dhd.set_pixel_use_led_id(led, 250, 117, 0)
        dhd.latch()
        sleep(0.15)
        dhd.set_pixel_use_led_id(led, 0, 0, 0)
        dhd.latch()

    dhd.set_pixel_use_led_id(0, 255, 0, 0)
    dhd.latch()
    sleep(2)
    dhd.clear_all_pixels()
    dhd.latch()

    key_symbol_map = {
        "8": 1, "C": 2, "V": 3, "U": 4, "a": 5, "3": 6, "5": 7, "S": 8, "b": 9,
        "K": 10, "X": 11, "Z": 12, "E": 14, "P": 15, "M": 16, "D": 17, "F": 18,
        "7": 19, "c": 20, "W": 21, "6": 22, "G": 23, "4": 24, "B": 25, "H": 26,
        "R": 27, "L": 28, "2": 29, "N": 30, "Q": 31, "9": 32, "J": 33, "0": 34,
        "O": 35, "T": 36, "Y": 37, "1": 38, "I": 39, "A": 0,
    }

    print("DHD LED test is active. Press DHD buttons to toggle LEDs. Press '-' or Ctrl+C to exit.")
    active = []

    try:
        while True:
            key = key_press()
            if key == "-":
                break

            try:
                symbol_number = key_symbol_map[key]
            except KeyError:
                print(f"Ignored key: {key!r}")
                continue

            if symbol_number not in active:
                active.append(symbol_number)
                color = (255, 0, 0) if symbol_number == 0 else (250, 117, 0)
                dhd.set_pixel(symbol_number, *color)
            else:
                active.remove(symbol_number)
                dhd.clear_pixel(symbol_number)
            dhd.latch()
    except KeyboardInterrupt:
        pass
    finally:
        dhd.clear_all_pixels()
        dhd.latch()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
