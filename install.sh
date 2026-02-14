#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HANDLER="/etc/acpi/gmktec-mode-notify.sh"
ACPI_HANDLER="/etc/acpi/handler.sh"
WMI_BLOCK_FILE="$(mktemp)"

cleanup() {
    rm -f "$WMI_BLOCK_FILE"
}
trap cleanup EXIT

echo "GMKtec Mode Notify — Installer"
echo ""

# Check dependencies
if ! command -v gdbus &>/dev/null; then
    echo "ERROR: gdbus not found. Install glib2 (usually pre-installed on GNOME)."
    exit 1
fi

if ! modinfo ec_su_axb35 &>/dev/null 2>&1; then
    echo "WARNING: ec_su_axb35 kernel module not found."
    echo "Install from: https://github.com/loomm/ec-su_axb35-linux"
    echo ""
fi

# Install acpid if needed
if ! command -v acpi_listen &>/dev/null; then
    echo "Installing acpid..."
    if command -v pacman &>/dev/null; then
        sudo pacman -S --noconfirm acpid
    elif command -v apt &>/dev/null; then
        sudo apt install -y acpid
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y acpid
    else
        echo "ERROR: Could not install acpid. Install it manually."
        exit 1
    fi
fi

# Install the notification handler
echo "Installing handler to $HANDLER..."
sudo install -m 755 "$SCRIPT_DIR/gmktec-mode-notify.sh" "$HANDLER"

# Patch acpid handler.sh to route WMI events
cat > "$WMI_BLOCK_FILE" <<'EOF'
    wmi)
        # GMKtec P-Mode button notification
        if [[ "$2" == "PNP0C14:00" && "$3" == "000000bc" ]]; then
            /etc/acpi/gmktec-mode-notify.sh &
        fi
        ;;
EOF

if [[ -f "$ACPI_HANDLER" ]] && ! grep -q "gmktec-mode-notify" "$ACPI_HANDLER"; then
    echo "Patching $ACPI_HANDLER with WMI event handler..."
    TMP_HANDLER="$(mktemp)"
    awk -v block="$(cat "$WMI_BLOCK_FILE")" '
        !inserted && $0 ~ /^    \*\)$/ { print block; inserted=1 }
        { print }
        END { if (!inserted) exit 1 }
    ' "$ACPI_HANDLER" > "$TMP_HANDLER"
    cat "$TMP_HANDLER" | sudo tee "$ACPI_HANDLER" >/dev/null
    rm -f "$TMP_HANDLER"
else
    if ! grep -q "gmktec-mode-notify" "$ACPI_HANDLER" 2>/dev/null; then
        echo "WARNING: Could not patch $ACPI_HANDLER — file not found."
        echo "You may need to manually configure acpid to run $HANDLER on WMI events."
    else
        echo "acpid handler already patched."
    fi
fi

# Enable and start acpid
sudo systemctl enable acpid
sudo systemctl restart acpid

echo ""
echo "Done! Press the P-Mode button to test."
echo "Check logs: journalctl -f | grep GMKtec"
