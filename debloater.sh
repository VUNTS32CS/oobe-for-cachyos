#!/usr/bin/env bash

# Ensure script is named and invoked properly, exit on unhandled errors
set -u

# 1. Dependency Check: Ensure pacman and gum are present
if ! command -v pacman &>/dev/null; then
    echo "Error: pacman not found. This script only supports Arch-based distributions."
    exit 1
fi

if ! command -v gum &>/dev/null; then
    echo "Error: 'gum' is not installed. Install it first with: sudo pacman -S gum"
    exit 1
fi

# Clean exit trap for Ctrl+C
trap 'echo ""; gum style --foreground 196 "Script terminated by user."; exit 130' SIGINT

# 2. Detect OS and Platform (Laptop vs Desktop only)
detect_environment() {
    # Extract OS name
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        OS_NAME="${PRETTY_NAME:-$NAME}"
    else
        OS_NAME="Unknown Arch-based Linux"
    fi

    # Detect Chassis Type via SMBIOS/DMI Specification
    # Laptop/Mobile codes: 8 (Portable), 9 (Laptop), 10 (Notebook), 11 (Hand Held), 14 (Sub Notebook), 30 (Tablet), 31 (Convertible), 32 (Detachable)
    # Desktop codes: 3 (Desktop), 4 (Low Profile Desktop), 5 (Pizza Box), 6 (Mini Tower), 7 (Tower), 13 (All in One), 15 (Space-saving), 16 (Lunch Box), 35 (Mini PC), 36 (Stick PC)
    local chassis_type=""
    if [[ -r /sys/class/dmi/id/chassis_type ]]; then
        chassis_type=$(cat /sys/class/dmi/id/chassis_type)
    fi

    case "$chassis_type" in
        8|9|10|11|14|30|31|32)
            PLATFORM="Laptop"
            ;;
        3|4|5|6|7|13|15|16|35|36)
            PLATFORM="Desktop"
            ;;
        *)
            # Fallback check: presence of a battery directory in /sys/class/power_supply
            if compgen -G "/sys/class/power_supply/BAT*" > /dev/null; then
                PLATFORM="Laptop"
            else
                PLATFORM="Desktop"
            fi
            ;;
    esac

    gum style \
        --border normal \
        --margin "1 0" \
        --padding "1 2" \
        --border-foreground 212 \
        "System Detection Complete" \
        "OS:       $OS_NAME" \
        "Platform: $PLATFORM"
}

# 3. Interactive Countdown Function
# Returns 0 if countdown completes or Enter is pressed.
# Returns 1 if 'Q'/'q' is pressed to go back and re-answer the question.
countdown_prompt() {
    local action_text="$1"
    local seconds=6

    while [[ $seconds -gt 0 ]]; do
        # \r returns to start of line, \033[K clears to the end of the line
        printf "\r\033[K%s in [%d] seconds (press Q to cancel and change opinion, Ctrl + C to stop the script or Enter to skip the countdown) " "$action_text" "$seconds"

        # Wait 1 second for a single character input
        IFS= read -r -s -n 1 -t 1 key
        local read_status=$?

        if [[ $read_status -eq 0 ]]; then
            # In bash, pressing Enter with read -n 1 yields an empty string
            if [[ -z "$key" ]]; then
                printf "\n"
                return 0
            elif [[ "$key" == "q" \vert{}\vert{} "$key" == "Q" ]]; then
                printf "\n"
                gum style --foreground 214 "Action cancelled. Returning to question..."
                return 1
            fi
        fi

        ((seconds--))
    done

    printf "\n"
    return 0
}

# ==============================================================================
# Question 1: linux-firmware cleanup
# ==============================================================================
question_linux_firmware() {
    while true; do
        # Default is Yes (--default=true)
        if gum confirm --default=true "Do you want to remove unneeded linux-firmware packages?"; then
            USER_CHOICE="Y"
            ACTION_MSG="Will execute linux-firmware cleanup"
        else
            USER_CHOICE="N"