#!/bin/bash

# Variables for coloring
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}[*] Arch Updater Installation Starting...${NC}"

# Security Check: Script should not be run with sudo!
if [ "$EUID" -eq 0 ]; then
    echo -e "${RED}[Error] Please DO NOT run this script with 'sudo'.${NC}"
    echo "Run the script with your normal user account; a password will be requested where necessary."
    exit 1
fi

# Variables and Directories
CURRENT_USER=$(whoami)
USER_HOME=$HOME
BIN_DIR="$USER_HOME/.local/bin"
SYSTEMD_USER_DIR="$USER_HOME/.config/systemd/user"
MAIN_SCRIPT="arch-updater.sh"

# 1. Main Script Check and Moving
if [ ! -f "$MAIN_SCRIPT" ]; then
    echo -e "${RED}[Error] '$MAIN_SCRIPT' file not found in the current directory!${NC}"
    echo "Please place your update script in the same folder as this install.sh."
    exit 1
fi

echo -e "${GREEN}[1/5] Creating directories and moving the script...${NC}"
mkdir -p "$BIN_DIR"
mkdir -p "$SYSTEMD_USER_DIR"

cp "$MAIN_SCRIPT" "$BIN_DIR/arch-updater.sh"
chmod +x "$BIN_DIR/arch-updater.sh"

# 2. Configuring the Sudoers File
echo -e "${GREEN}[2/5] Configuring sudoers passwordless topgrade permission... (Your sudo password may be requested)${NC}"
SUDOERS_FILE="/etc/sudoers.d/99-custom-nopasswd"
# Clear/create the current file and allow only for topgrade
echo "$CURRENT_USER ALL=(ALL) NOPASSWD: /usr/bin/topgrade" | sudo tee "$SUDOERS_FILE" > /dev/null
sudo chmod 440 "$SUDOERS_FILE"

# 3. Creating the Systemd Service File
echo -e "${GREEN}[3/5] Creating Systemd User Service...${NC}"
cat <<EOF > "$SYSTEMD_USER_DIR/arch-updater.service"
[Unit]
Description=Arch Linux Update Service (User)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash $BIN_DIR/arch-updater.sh
EOF

# 4. Creating the Systemd Timer File
echo -e "${GREEN}[4/5] Creating Systemd User Timer...${NC}"
cat <<EOF > "$SYSTEMD_USER_DIR/arch-updater.timer"
[Unit]
Description=Arch Linux Update Timer (Fixed Schedule)

[Timer]
# Run every day at 10:00 AM
OnCalendar=*-*-* 10:00:00
# Run every day at 7:00 PM
OnCalendar=*-*-* 19:00:00
# Trigger immediately if timer was missed (e.g., PC was off)
Persistent=true

[Install]
WantedBy=timers.target
EOF

# 5. Enabling Systemd Services
echo -e "${GREEN}[5/5] Enabling the timer...${NC}"
systemctl --user daemon-reload
systemctl --user enable --now arch-updater.timer

echo -e "${GREEN}[✓] Installation completed successfully!${NC}"
echo "-------------------------------------------------------"
echo -e "To check the timer status: ${GREEN}systemctl --user status arch-updater.timer${NC}"
echo -e "To see the next scheduled run times: ${GREEN}systemctl --user list-timers${NC}"
echo "-------------------------------------------------------"
