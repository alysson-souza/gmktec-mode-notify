#!/bin/bash
set -e

echo "GMKtec Mode Notify — Uninstaller"
echo ""

HANDLER="/etc/acpi/gmktec-mode-notify.sh"
ACPI_HANDLER="/etc/acpi/handler.sh"

# Remove handler script
if [[ -f "$HANDLER" ]]; then
    echo "Removing $HANDLER..."
    sudo rm -f "$HANDLER"
fi

# Remove WMI case from handler.sh
if grep -q "gmktec-mode-notify" "$ACPI_HANDLER" 2>/dev/null; then
    echo "Removing WMI handler from $ACPI_HANDLER..."
    TMP_HANDLER="$(mktemp)"
    awk '
        /^[[:space:]]*wmi\)[[:space:]]*$/ {
            in_block=1
            block=$0 ORS
            has_gmktec=0
            next
        }
        in_block {
            block=block $0 ORS
            if ($0 ~ /gmktec-mode-notify/) {
                has_gmktec=1
            }
            if ($0 ~ /^[[:space:]]*;;[[:space:]]*$/) {
                in_block=0
                if (!has_gmktec) {
                    printf "%s", block
                }
                block=""
            }
            next
        }
        { print }
    ' "$ACPI_HANDLER" > "$TMP_HANDLER"
    cat "$TMP_HANDLER" | sudo tee "$ACPI_HANDLER" >/dev/null
    rm -f "$TMP_HANDLER"
fi

# Clean up state file (new and legacy paths)
sudo rm -f /run/gmktec-mode-state /tmp/gmktec-mode-state

echo "Restarting acpid..."
sudo systemctl restart acpid

echo "Done."
