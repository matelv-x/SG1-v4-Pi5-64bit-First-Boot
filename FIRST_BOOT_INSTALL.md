Pi 5 first boot install
=======================

Use this package on a fresh Raspberry Pi 5 with Raspberry Pi OS 64-bit Lite or
Desktop.

Tested target: Raspberry Pi OS 64-bit based on Debian Trixie. Debian Bookworm is
not verified for this first-boot package.

Before running this installer:

1. Flash a fresh Raspberry Pi OS image with Raspberry Pi Imager.
2. Use Raspberry Pi OS 64-bit for Raspberry Pi 5.
3. Use Desktop/Full/with desktop if you want the graphical double-click
   installer, or Lite if you will install over SSH/terminal.
4. Boot the Pi once and complete the normal first-run setup.
5. Enable SSH if installing remotely.
6. Connect Wi-Fi or Ethernet and confirm internet access.
7. Then download or clone this first-boot package.

Desktop users can download the ZIP in the Raspberry Pi browser, unpack it on the
Desktop or in Downloads, open the extracted folder, and double-click:

```text
Install SG1 v4 Desktop.desktop
```

Lite/headless users should SSH into the Pi and place the package under
`/home/pi`, normally as `/home/pi/sg1_v4`.

Install flow:

After renaming the folder to `/home/pi/sg1_v4`:

```bash
sudo chmod u+x /home/pi/sg1_v4/install/*.sh
cd /home/pi/sg1_v4/install
sudo ./install.sh
sudo systemctl start stargate.service
```

The root shortcut also works:

```bash
cd /home/pi/sg1_v4
sudo bash install.sh
sudo systemctl start stargate.service
```

Desktop install:

```bash
cd /home/pi/sg1_v4
sudo bash install_desktop.sh
```

Or double-click `Install SG1 v4 Desktop` from the extracted folder.

Hardware profiles:

The installer asks which hardware is connected:

1. `original` - original 3 x Motor HAT gate.
2. `servo_motorhat` - PCA9685 servo chevrons + 1 x Motor HAT stepper.
3. `servo_tmc2209` - PCA9685 servo chevrons + TMC2209 stepper.

Software update safety:

- profile `original` keeps the original Git software updater enabled and
  visible in the web Configuration page;
- profiles `servo_motorhat` and `servo_tmc2209` automatically set the original
  Git software updater to `False` and hide it in the web Configuration page;
- use tested Pi 5 installer packages for future updates to the modified servo
  profiles.

The choice can also be passed directly:

```bash
sudo bash install.sh --hardware-profile servo_tmc2209
sudo bash install_desktop.sh --hardware-profile servo_tmc2209
```

SSH and Wi-Fi:

SSH is enabled by default. Wi-Fi can be configured during install:

```bash
sudo bash install.sh --configure-wifi
sudo bash install_desktop.sh --configure-wifi
```

Or passed directly:

```bash
sudo bash install.sh --wifi-country US --wifi-ssid "My WiFi" --wifi-password "my-password"
```

What the installer does:

- sets hostname to `stargate`, so web and SSH are reachable as
  `http://stargate.local` and `ssh pi@stargate.local`;
- enables SSH, I2C, and SPI;
- optionally configures Wi-Fi credentials;
- does not disable onboard audio;
- installs `/home/pi/sg1_v4`;
- creates `/home/pi/venv_v4`;
- installs exact package versions recovered from the working Pi 5 backup;
- applies the chosen hardware profile and hides unrelated hardware fields from
  `config.htm`;
- sets `pi` password to `sg1` and enables passwordless sudo for the `pi` user;
- configures Apache for the web interface;
- installs `stargate.service` with Motor HAT all-off hooks.

Audio:

The `soundfx/` folder contains dummy/placeholder folders only. This keeps the
installer working and preserves the expected folder layout, but the original
audio files are not included.

After installation, or before running the installer if preparing a local copy,
copy the original audio files supplied by Kristian with the official/original
sound package into:

```text
/home/pi/sg1_v4/soundfx
```

`audio_enable` remains enabled. The software tolerates empty audio folders, but
audio playback will only work after the original files are copied into the
matching `soundfx` subfolders.

After install/reboot the prompt should be:

```text
pi@stargate:~ $
```

Emergency Motor HAT off:

```bash
sudo systemctl stop stargate.service
sudo /home/pi/venv_v4/bin/python /home/pi/sg1_v4/scripts/motorhat_all_off.py --sleep
```
