#!/bin/bash
# GMKtec EVO-X2 / Sixunited AXB35-02 power mode notification handler
# Triggered by acpid on WMI event 0xBC from PNP0C14:00
# Requires: ec_su_axb35 kernel module, acpid, gdbus
#
# Shows a desktop notification when the P-Mode hardware button is pressed,
# displaying the new power mode, CPU temperature, and fan RPM.

STATE_FILE="/run/gmktec-mode-state"
SYSFS="/sys/class/ec_su_axb35"
LOGGER_TAG="GMKtec"

read_required_value() {
    local path="$1" label="$2" value=""
    if [[ -r "$path" ]]; then
        value=$(<"$path")
    fi
    if [[ -z "$value" ]]; then
        logger "$LOGGER_TAG: ERROR - Failed to read $label from $path"
        exit 1
    fi
    printf '%s\n' "$value"
}

read_optional_value() {
    local path="$1" fallback="$2" value=""
    if [[ -r "$path" ]]; then
        value=$(<"$path")
    fi
    if [[ -z "$value" ]]; then
        printf '%s\n' "$fallback"
        return
    fi
    printf '%s\n' "$value"
}

load_previous_state() {
    local key value

    [[ -r "$STATE_FILE" ]] || return
    [[ -L "$STATE_FILE" ]] && return

    while IFS='=' read -r key value; do
        case "$key" in
            prev_power)
                if [[ "$value" =~ ^\"[a-zA-Z0-9_-]*\"$ ]]; then
                    prev_power="${value#\"}"
                    prev_power="${prev_power%\"}"
                fi
                ;;
            prev_fan)
                if [[ "$value" =~ ^\"[a-zA-Z0-9_-]*\"$ ]]; then
                    prev_fan="${value#\"}"
                    prev_fan="${prev_fan%\"}"
                fi
                ;;
        esac
    done < "$STATE_FILE"
}

save_current_state() {
    local state_dir temp_file old_umask
    state_dir="$(dirname "$STATE_FILE")"
    mkdir -p "$state_dir" || return 1
    temp_file=$(mktemp "$state_dir/.gmktec-mode-state.XXXXXX") || return 1

    old_umask="$(umask)"
    umask 077
    {
        printf 'prev_power="%s"\n' "$power_mode"
        printf 'prev_fan="%s"\n' "$fan_mode"
    } > "$temp_file" || {
        umask "$old_umask"
        rm -f "$temp_file"
        return 1
    }
    umask "$old_umask"

    chmod 600 "$temp_file" || {
        rm -f "$temp_file"
        return 1
    }
    mv -f "$temp_file" "$STATE_FILE"
}

if [[ ! -d "$SYSFS" ]]; then
    logger "$LOGGER_TAG: ERROR - ec_su_axb35 sysfs not found at $SYSFS"
    exit 1
fi

# Read current state from ec_su_axb35 sysfs
power_mode=$(read_required_value "$SYSFS/apu/power_mode" "power mode")
fan_mode=$(read_required_value "$SYSFS/fan1/mode" "fan mode")
fan_rpm=$(read_optional_value "$SYSFS/fan1/rpm" "N/A")
cpu_temp=$(read_optional_value "$SYSFS/temp1/temp" "N/A")

# Friendly labels for notifications
case "$power_mode" in
    quiet)       power_label="Quiet (55W)"         ; power_icon="battery-low-symbolic" ;;
    balanced)    power_label="Balanced (85W)"       ; power_icon="battery-good-symbolic" ;;
    performance) power_label="Performance (120W)"   ; power_icon="battery-full-charged-symbolic" ;;
    *)           power_label="$power_mode"          ; power_icon="battery-symbolic" ;;
esac

case "$fan_mode" in
    curve)  fan_label="Auto"   ; fan_icon="weather-windy-symbolic" ;;
    auto)   fan_label="Auto"   ; fan_icon="weather-windy-symbolic" ;;
    full)   fan_label="Full"   ; fan_icon="weather-storm-symbolic" ;;
    fixed)  fan_label="Fixed"  ; fan_icon="emblem-system-symbolic" ;;
    *)      fan_label="$fan_mode" ; fan_icon="dialog-question-symbolic" ;;
esac

# Load previous state
prev_power="" ; prev_fan=""
load_previous_state

# Save current state
if ! save_current_state; then
    logger "$LOGGER_TAG: ERROR - Failed to persist state at $STATE_FILE"
fi

# Find active graphical session user
# Supports both single-user desktops and multi-seat setups
find_session_user() {
    local user uid session_id active remote class type state
    # Try loginctl first (systemd)
    if command -v loginctl &>/dev/null; then
        while read -r session_id _; do
            [[ -n "$session_id" ]] || continue

            active=$(loginctl show-session "$session_id" -p Active --value 2>/dev/null)
            remote=$(loginctl show-session "$session_id" -p Remote --value 2>/dev/null)
            class=$(loginctl show-session "$session_id" -p Class --value 2>/dev/null)
            type=$(loginctl show-session "$session_id" -p Type --value 2>/dev/null)
            state=$(loginctl show-session "$session_id" -p State --value 2>/dev/null)

            if [[ "$active" == "yes" && "$remote" == "no" && "$class" == "user" && "$state" == "active" && "$type" != "tty" ]]; then
                user=$(loginctl show-session "$session_id" -p Name --value 2>/dev/null)
                [[ -n "$user" ]] && break
            fi
        done < <(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}')
    fi
    # Fallback: find who owns the graphical session
    if [[ -z "$user" ]]; then
        user=$(who 2>/dev/null | awk 'NR==1 { print $1 }')
    fi
    if [[ -z "$user" ]]; then
        return 1
    fi
    uid=$(id -u "$user" 2>/dev/null) || return 1
    echo "$user $uid"
}

# Send notification via gdbus (works from acpid daemon/root context)
# Note: notify-send silently fails when called from acpid via runuser,
# even with correct DBUS_SESSION_BUS_ADDRESS. gdbus call works reliably.
send_notify() {
    local summary="$1" body="$2" icon="$3"
    local session_info user uid

    session_info=$(find_session_user) || return 1
    read -r user uid <<< "$session_info"

    runuser -u "$user" -- env \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" \
        gdbus call --session \
        --dest=org.freedesktop.Notifications \
        --object-path=/org/freedesktop/Notifications \
        --method=org.freedesktop.Notifications.Notify \
        "GMKtec" 0 "$icon" "$summary" "$body" "[]" "{}" 3000 \
        >/dev/null 2>&1
}

# Determine what changed and notify
power_changed=0 ; fan_changed=0
[[ "$prev_power" != "$power_mode" && -n "$prev_power" ]] && power_changed=1
[[ "$prev_fan" != "$fan_mode" && -n "$prev_fan" ]] && fan_changed=1

if (( power_changed && fan_changed )); then
    send_notify "$power_label | Fan: $fan_label" "${cpu_temp}°C | ${fan_rpm} RPM" "$power_icon"
    logger "GMKtec: Power=$power_mode Fan=$fan_mode"
elif (( power_changed )); then
    send_notify "$power_label" "${cpu_temp}°C | ${fan_rpm} RPM" "$power_icon"
    logger "GMKtec: Power mode changed to $power_mode"
elif (( fan_changed )); then
    send_notify "Fan: $fan_label" "${cpu_temp}°C | ${fan_rpm} RPM" "$fan_icon"
    logger "GMKtec: Fan mode changed to $fan_mode"
elif [[ -z "$prev_power" && -z "$prev_fan" ]]; then
    send_notify "$power_label | Fan: $fan_label" "${cpu_temp}°C | ${fan_rpm} RPM" "preferences-system-symbolic"
    logger "GMKtec: Initial state - Power=$power_mode Fan=$fan_mode"
fi
