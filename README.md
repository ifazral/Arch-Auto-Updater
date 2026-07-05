# Arch Linux Automated GUI Updater

An automated, user-space system update scheduler tailored for Arch Linux. This project utilizes Systemd User Timers, `topgrade` for overall package updates, and desktop notifications/dialogs (`notify-send`, `yad`) to provide a seamless background update experience without breaking your user environment or GUI permissions.

## Features

* **Dual-Schedule Automation:** Runs daily at 10:00 AM and 07:00 PM by default.
* **Persistent Timers:** Missed schedules (e.g., if the computer was turned off) trigger instantly upon boot.
* **Network & Metered Awareness:** Automatically checks internet connectivity and prompts the user before upgrading over data-metered/limited connections.
* **Smart Safety Blocks:** Prevents catastrophic updates by enforcing system rules when the machine hasn't been upgraded for an extended period (e.g., >3 months).
* **Official News Parser:** Fetches and reviews the latest official Arch Linux RSS feed; pauses upgrades if manual intervention guidelines are active. (If you read news by clicking button, script will work after 2 hours.)
* **Advanced Reboot Detection:** Scans post-upgrade system state and logs to determine if core updates (Kernel, Firmware, Systemd, Wayland/X11 components) require a system reboot.

---

## Security Architecture

Unlike generic scripts that run entire user tasks as root or grant global passwordless `sudo` privileges to users, this project prioritizes system isolation:

1. **User-Space Runtime:** The main script runs within your local user session. This ensures desktop notifications, native environment variables (`DISPLAY`, `WAYLAND_DISPLAY`), and AUR helper wrappers (`yay`/`paru`) function correctly without permission degradation.
2. **Granular Privileges:** The installer adds a strict ruleset under `/etc/sudoers.d/`. Passwordless execution is restricted **only** to `/usr/bin/topgrade`. Even if a malicious script compromises your home directory, it cannot gain arbitrary root execution.

---

## Prerequisites

Ensure the following dependencies are installed on your Arch Linux machine prior to setup:

```bash
sudo pacman -S yad libnotify pacman-contrib networkmanager
yay -S topgrade needrestart

```

*(Note: Ensure you have an AUR helper like `yay` or `paru` installed if you want AUR updates processed by Topgrade).*

---

## Installation

### 1. Clone the repository

```bash
git clone https://github.com/ifazral/Arch-Auto-Updater.git
cd Arch-Auto-Updater

```

### 2. Make the scripts executable

```bash
chmod +x arch-updater.sh arch-updater-installer.sh

```

### 3. Run the installer script

> ⚠️ **Important:** Do NOT run this installer using `sudo`. Run it as a standard user. It will ask for temporary administrative elevation when generating system files.

```bash
./arch-updater-installer.sh

```

---

## Verification & Management

### Check Scheduler Status

To make sure your user-space timer is armed and waiting for the next runtime window:

```bash
systemctl --user status arch-updater.timer

```

### View Next Scheduled Runs

```bash
systemctl --user list-timers --user

```

### Manual Trigger

If you want to debug or force-run the updater service instantly via systemd:

```bash
systemctl --user start arch-updater.service

```

### Unblocking the Script

If the safety mechanism blocks your automated routine because the system was left un-upgraded for more than 3 months, update your system manually first (`sudo pacman -Sy archlinux-keyring and sudo pacman -Syu`), then clear the automated deadlock using:

```bash
~/.local/bin/arch-updater.sh continue

```

---

## Files and Paths Created

* **Script Destination:** `~/.local/bin/arch-updater.sh`
* **Systemd Configurations:** * `~/.config/systemd/user/arch-updater.service`
* `~/.config/systemd/user/arch-updater.timer`


* **Sudo Permissions Drop-In:** `/etc/sudoers.d/99-custom-nopasswd`
* **Log & Cache Profiles:** `~/.cache/arch_updater_*` & `~/.config/arch-updater/`
