# SG1 v4 Pi 5 64-bit First Boot

First-boot SG1 v4 installer/fork for **Raspberry Pi 5 only** running **64-bit Raspberry Pi OS**.

Tested target: **Raspberry Pi OS 64-bit based on Debian Trixie**. Debian Bookworm is the previous Raspberry Pi OS generation and is **not verified** for this first-boot package.

This repository is public so Raspberry Pi 5 users can install the first-boot package directly.

## What this is

This is a complete first-boot SG1 v4 package prepared for Pi 5 hardware profiles, including xinux87's PCA9685 servo chevrons matelv-x's/codex TMC2209 STEP/DIR glyph-ring stepper profile.

## Before installing this first-boot package

Do this first. The installer assumes Raspberry Pi OS is already installed, booted once, and connected to the network.

1. Flash a fresh Raspberry Pi OS image with **Raspberry Pi Imager**.
2. Use a **Raspberry Pi 5** and a **64-bit** Raspberry Pi OS image.
3. Recommended/tested image: **Raspberry Pi OS 64-bit / Debian Trixie**.
4. Choose the edition that matches how you will install:
   - **Desktop / Full / with desktop** - use this if you want the graphical desktop and double-click installer.
   - **Lite** - use this if you will install over SSH/terminal only.
5. Boot the Pi and complete the normal first-run setup before running this installer:
   - create/confirm the user,
   - set country/locale/timezone/keyboard,
   - enable SSH if you will install remotely,
   - connect Wi-Fi or Ethernet,
   - confirm the Pi can reach the internet.
6. Only after that, download or clone this first-boot package.

For Desktop installs, you can download the ZIP with the Raspberry Pi browser, unpack it on the Desktop or in Downloads, open the extracted folder, and double click:

```text
Install SG1 v4 Desktop.desktop
```

For Lite/headless installs, SSH into the Pi and clone into `/home/pi` using the command block below.

Bookworm note: this package may work on Bookworm, but it has not been tested there. Use Trixie unless you are deliberately testing a Bookworm build and are ready to fix Python/package differences.

## First boot install, non-desktop / SSH

```bash
cd /home/pi
sudo systemctl stop stargate.service 2>/dev/null || true
sudo rm -rf /home/pi/sg1_v4 /home/pi/venv_v4
git clone https://github.com/matelv-x/SG1-v4-Pi5-64bit-First-Boot.git sg1_v4
cd /home/pi/sg1_v4/install
sudo chmod +x install.sh
sudo ./install.sh
sudo systemctl start stargate.service
systemctl status stargate.service --no-pager -l
```

## First boot install, desktop terminal

```bash
cd /home/pi
sudo systemctl stop stargate.service 2>/dev/null || true
sudo rm -rf /home/pi/sg1_v4 /home/pi/venv_v4
git clone https://github.com/matelv-x/SG1-v4-Pi5-64bit-First-Boot.git sg1_v4
cd /home/pi/sg1_v4
chmod +x install_desktop.sh
sudo ./install_desktop.sh
sudo systemctl start stargate.service
systemctl status stargate.service --no-pager -l
```

## First boot install, desktop double click

You can also download/unpack the ZIP, open the extracted folder in the Raspberry Pi Desktop file manager, and double click:

```text
Install SG1 v4 Desktop.desktop
```

If the desktop asks how to open it, choose to execute/run it.

## Audio files / soundfx

The `soundfx/` folder in this repository contains only dummy/placeholder folders. This keeps the installer working and preserves the expected directory layout, but the original audio files are **not included**.

After installation, or before running the installer if you are preparing a local copy, copy the original audio files supplied by Kristian when the official/original sound package was purchased into:

```text
/home/pi/sg1_v4/soundfx
```

The software can install and run with empty audio folders, but audio playback will only work after those original files are copied into the matching `soundfx` folder and subfolders.

## Physical calibration required

The Pi 5 first-boot installer only installs the software and selects the hardware backend. It does **not** calibrate the glyph-ring stepper motor or the servo chevrons to your physical gate. Every printed/mechanical gate is a little different, so check the selected hardware profile after install.

Calibration requirements by hardware profile:

- **Profile 1: Original 3 x Motor HAT** - original hardware. No extra Pi 5 servo/TMC calibration is normally required; use the original mechanical setup and original calibration workflow.
- **Profile 2: Servo chevrons + 1 x Motor HAT stepper** - calibrate the servo chevrons. The glyph-ring stepper remains on the original Motor HAT path, so the original ring calibration/settings normally apply.
- **Profile 3: Servo chevrons + TMC2209 stepper** - calibrate both the servo chevrons and the glyph-ring stepper/TMC2209 settings.

Before calibration, make a quick backup:

```bash
sudo systemctl stop stargate.service
cp /home/pi/sg1_v4/config/milkyway-config.json /home/pi/milkyway-config.before-calibration.json
cp /home/pi/sg1_v4/config/milkyway-ring_position.json /home/pi/milkyway-ring_position.before-calibration.json
sudo systemctl start stargate.service
```

### Use the web Config page first

Open the web UI:

```text
http://YOUR_PI_ADDRESS/config.htm or http://stargate.local/config.htm
```

The relevant groups are:

- `Chevron Motor` - chevron movement timing/speed and chevron motor enable.
- `Stepper` - glyph-ring stepper enable, driver selection, one-revolution step count, speed, acceleration and TMC2209 GPIO timing/pins.

After changing values, use the page's submit/save button. The page shows a confirmation dialog before applying changes. Restart `stargate.service` after motor/stepper changes if the page does not do it for you:

```bash
sudo systemctl restart stargate.service
```

### Glyph ring / stepper calibration

For **Profile 1** and normally **Profile 2**, keep the original Motor HAT stepper setup unless your physical ring is landing in the wrong place.

For **Profile 3: Servo chevrons + TMC2209 stepper**, check these `Stepper` fields in `config.htm`:

- `Stepper Use Motor Hat` / `stepper_use_motor_hat` should be **off/false** for TMC2209.
- `stepper_driver` should show `tmc2209` internally.
- `stepper_one_revolution_steps` must match one full mechanical revolution of your ring. Default is `1250`, but your gear ratio and microstepping may differ.
- `stepper_speed_normal` and `stepper_speed_slow` control movement speed. Larger values are slower.
- `stepper_acceleration_steps` controls ramp-up/ramp-down.
- `tmc2209_step_pin`, `tmc2209_dir_pin`, `tmc2209_enable_pin`, `tmc2209_enable_active_low`, `tmc2209_step_pulse_seconds`, and `tmc2209_direction_setup_seconds` must match your wiring/driver.

The ring position itself is stored in:

```text
/home/pi/sg1_v4/config/milkyway-ring_position.json
```

To set the current physical ring position as zero:

1. Move the ring so the Earth/home symbol is exactly at top dead center.
2. Open:

```text
http://YOUR_PI_ADDRESS/debug.htm or http://stargate.local/debug.htm
```

3. Click:

```text
Set Position=0 (Earth at top)
```

You can also send the same command from the Pi:

```bash
curl -X POST -H 'Content-Type: application/json' -d '{}' http://127.0.0.1:8080/do/set_glyph_ring_zero
```

If the ring is consistently offset, set zero again. If the error grows as the ring moves around the circle, adjust `stepper_one_revolution_steps` in `config.htm`, save, restart, then test again.

A safe stepper calibration loop is:

1. Set Earth/home at top dead center.
2. Click `Set Position=0 (Earth at top)`.
3. Dial/test several symbols from the web UI.
4. If all symbols are shifted by the same amount, reset zero.
5. If the shift changes around the ring, tune `stepper_one_revolution_steps`.
6. If the ring stutters or skips, slow it down by increasing `stepper_speed_normal` / `stepper_speed_slow` and reduce acceleration stress by increasing or tuning `stepper_acceleration_steps`.

### Servo chevron calibration

Servo calibration applies to **Profile 2** and **Profile 3**.

The PCA9685 profile maps chevrons 1-7 to servo channels 0-6:

```text
Chevron 1 -> PCA9685 channel 0
Chevron 2 -> PCA9685 channel 1
Chevron 3 -> PCA9685 channel 2
Chevron 4 -> PCA9685 channel 3
Chevron 5 -> PCA9685 channel 4
Chevron 6 -> PCA9685 channel 5
Chevron 7 -> PCA9685 channel 6
```

In `config.htm`, start with the `Chevron Motor` group:

- `chevron_down_time` controls how long the chevron moves/unlocks.
- `chevron_up_time` controls how long the chevron moves/locks.
- `chevron_down_wait_time` controls how long it waits while unlocked.
- `chevron_motors_enable` must be enabled for physical servo movement.

Use the Debug page to test individual chevrons:

```text
http://YOUR_PI_ADDRESS/debug.htm or http://stargate.local/debug.htm
```

Click `Chevron 1` through `Chevron 7`. Each chevron should move cleanly down/up without hitting the printed body, stalling, buzzing hard, or pulling the linkage past its stop.

If your current first-boot build exposes servo angle fields in `config.htm`, adjust each chevron's open/closed angles there and save. Use small changes and test one chevron at a time.

If your build does **not** expose servo angle fields yet, the default software angles are in the selected backend file:

- Profile 2: `/home/pi/sg1_v4/classes/StargateMilkyWay/electronics_pca9685_servo.py`
- Profile 3: `/home/pi/sg1_v4/classes/StargateMilkyWay/electronics_pca9685_servo_tmc2209.py`

The defaults are only placeholders:

```text
open_angle = 0
closed_angle = 90
```

To find safe angles manually, stop the service and test one PCA9685 channel at a time:

```bash
sudo systemctl stop stargate.service
cat >/home/pi/servo_angle_test.py <<'PY'
import sys
from adafruit_servokit import ServoKit

channel = int(sys.argv[1])
angle = float(sys.argv[2])

kit = ServoKit(channels=16, address=0x40)
kit.servo[channel].set_pulse_width_range(500, 2500)
kit.servo[channel].angle = angle
print(f"PCA9685 channel {channel} -> {angle} degrees")
PY
```

Examples:

```bash
python3 /home/pi/servo_angle_test.py 0 45
python3 /home/pi/servo_angle_test.py 0 60
python3 /home/pi/servo_angle_test.py 0 90
```

Repeat for channels `0` through `6`. Write down each chevron's safe open and closed angles. Then edit the selected backend file and change the adapter lines, for example:

```python
1: ServoChevronAdapter(self.servo_kit.servo[0], open_angle=35, closed_angle=82),
2: ServoChevronAdapter(self.servo_kit.servo[1], open_angle=40, closed_angle=88),
```

Restart and test again:

```bash
sudo systemctl start stargate.service
```

If a servo moves the wrong way, swap its `open_angle` and `closed_angle` values for that channel. Do not leave a servo buzzing against a mechanical stop; reduce the travel angle immediately.



## Restore / remove

This is a first-boot full application install. To remove it and start again:

```bash
sudo systemctl stop stargate.service 2>/dev/null || true
sudo rm -rf /home/pi/sg1_v4 /home/pi/venv_v4
```

Then reinstall from a known-good backup or re-run the first boot commands above.

## Attribution and originality

Original base project: StargateProject SG1 software from the BuildAStargate/Jordan/Kristian/Jonnerd project lineage.

Reference branch used while preparing this Pi 5 first-boot fork: https://github.com/xinux87/StargateProject-software/tree/sg1_without_internet

How much is copied or changed: this is a large fork-style full application package. It includes substantial original SG1 v4 project code plus Pi 5 / 64-bit install changes, hardware-profile selection, PCA9685 servo support and TMC2209 STEP/DIR support.
