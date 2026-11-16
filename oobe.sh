#!/usr/bin/env bash
set -uo pipefail
export LC_NUMERIC=C

# Ensure gum is installed for modern TUI look
if ! command -v gum >/dev/null 2>&1; then
    echo "Error: 'gum' is required for the TUI interface. Install it with: sudo pacman -S gum" >&2
    exit 1
fi

# Ensure this is an Arch-based / pacman system only
if ! command -v pacman >/dev/null 2>&1; then
    gum style --foreground 196 --bold "Error: Only pacman-based distributions are supported."
    exit 1
fi

# Enter alternate screen buffer (overlay mode without clearing previous terminal text)
OVERLAY_ACTIVE=1
SCREEN_LOG="$(mktemp /tmp/oobe_screen.XXXXXX)"
printf "\033[?1049h\033[H"

# Record persistent output so it can be pasted onto the original terminal screen on exit
out() {
    printf "%s\n" "$*" | tee -a "$SCREEN_LOG"
}

out_spacer() {
    if [[ -s "${SCREEN_LOG:-}" && -n "$(tail -n 1 "$SCREEN_LOG" 2>/dev/null)" ]]; then
        out ""
    fi
}

collapse_if_prev_skipped() {
    if [[ -s "${SCREEN_LOG:-}" && -z "$(tail -n 1 "$SCREEN_LOG" 2>/dev/null)" ]]; then
        local prev_line
        prev_line="$(tail -n 2 "$SCREEN_LOG" 2>/dev/null | head -n 1)"
        if [[ "$prev_line" == *"Skipped "* ]]; then
            printf "\033[1A\r\033[J"
            sed -i '$d' "$SCREEN_LOG"
        fi
    fi
}

restore_screen() {
    printf "\033[?7h\033[?25h"
    if [[ "${OVERLAY_ACTIVE:-0}" -eq 1 ]]; then
        printf "\033[?1049l"
        OVERLAY_ACTIVE=0
        if [[ -f "${SCREEN_LOG:-}" ]]; then
            cat "$SCREEN_LOG"
            rm -f "$SCREEN_LOG"
        fi
    fi
}

handle_sigint() {
    restore_screen
    CLICOLOR_FORCE=1 gum style --foreground 196 "Exited."
    exit 130
}

trap 'restore_screen' EXIT
trap 'handle_sigint' INT TERM

detect_os() {
    local os_name="Unknown Linux"
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        os_name="${PRETTY_NAME:-${NAME:-Linux}}"
    fi
    echo "$os_name"
}

detect_platform() {
    local chassis_type=""
    if [[ -r /sys/class/dmi/id/chassis_type ]]; then
        chassis_type=$(< /sys/class/dmi/id/chassis_type)
    fi

    # SMBIOS chassis types for laptops/portables:
    # 8: Portable, 9: Laptop, 10: Notebook, 11: Hand Held, 14: Sub Notebook,
    # 30: Tablet, 31: Convertible, 32: Detachable
    case "$chassis_type" in
        8|9|10|11|14|30|31|32)
            echo "Laptop"
            return
            ;;
        3|4|5|6|7|13|15|16|24|34|35|36)
            echo "Desktop"
            return
            ;;
    esac

    # Fallback check for battery presence
    if compgen -G "/sys/class/power_supply/BAT*" >/dev/null || compgen -G "/sys/class/power_supply/battery*" >/dev/null; then
        echo "Laptop"
    else
        echo "Desktop"
    fi
}

# Compute a `read -t` timeout string (stored in the variable named by $1)
# representing the wait until the next 1-second boundary of rem_us.
set_next_tick_timeout() {
    local -n _out_timeout="$1"
    local rem_us="$2"
    local sec="$3"
    local wait_us=$(( rem_us - (sec - 1) * 1000000 ))
    if (( wait_us < 1000 )); then
        wait_us=1000
    fi
    printf -v _out_timeout "%d.%06d" $(( wait_us / 1000000 )) $(( wait_us % 1000000 ))
}

# Countdown before executing or skipping a process.
# Returns 0 if the countdown finishes (or Enter is pressed),
# Returns 1 if the user presses Q/q to cancel and change their opinion.
countdown_action() {
    local action_prefix="$1"
    local end_us=$(( ${EPOCHREALTIME/./} + 5 * 1000000 ))
    local last_sec=-1
    local key=""
    local rest=""
    local timeout_str=""

    local indicator paren_text main_text=""
    indicator="$(CLICOLOR_FORCE=1 gum style --foreground 214 --bold "[!]")"
    paren_text="$(CLICOLOR_FORCE=1 gum style --foreground 243 "(Q to change opinion, Ctrl + C to exit or Enter to skip countdown)")"

    # Disable terminal line auto-wrap (DECAWM) and save cursor position so
    # shrinking the terminal or wrapping lines never causes new lines on refresh.
    printf "\033[?7l\033[s"

    while true; do
        local now_us=${EPOCHREALTIME/./}
        local rem_us=$(( end_us - now_us ))
        if (( rem_us <= 0 )); then
            break
        fi

        local seconds=$(( (rem_us + 999999) / 1000000 ))
        if (( seconds != last_sec )); then
            main_text="$(CLICOLOR_FORCE=1 gum style --foreground 15 "${action_prefix} in [${seconds}] seconds")"
            printf "\033[u\r\033[J%s %s %s" "$indicator" "$main_text" "$paren_text"
            last_sec=$seconds
        fi

        set_next_tick_timeout timeout_str "$rem_us" "$seconds"

        if IFS= read -r -s -n 1 -t "$timeout_str" key; then
            if [[ -z "$key" ]]; then
                # User pressed Enter: skip remaining countdown
                printf "\033[?7h\n"
                printf "%s %s %s\n" "$indicator" "$main_text" "$paren_text" >> "$SCREEN_LOG"
                return 0
            elif [[ "$key" == "q" || "$key" == "Q" ]]; then
                # User pressed Q: cancel and re-ask question
                printf "\033[?7h\n"
                printf "%s %s %s\n" "$indicator" "$main_text" "$paren_text" >> "$SCREEN_LOG"
                out "$(CLICOLOR_FORCE=1 gum style --foreground 214 "Action cancelled. Returning to question...")"
                return 1
            elif [[ "$key" == $'\x1b' ]]; then
                IFS= read -r -s -n 2 -t 0.01 rest || true
            fi
        fi
    done
    printf "\033[?7h\n"
    printf "%s %s %s\n" "$indicator" "$main_text" "$paren_text" >> "$SCREEN_LOG"
    return 0
}

OS_NAME="$(detect_os)"
PLATFORM="$(detect_platform)"

# Echo detected OS and Platform in the purple box before the first question
CLICOLOR_FORCE=1 gum style \
    --border rounded \
    --padding "0 2" \
    --margin "1 0" \
    --border-foreground 99 \
    "Detected OS: ${OS_NAME}" \
    "Detected Platform: ${PLATFORM}" | tee -a "$SCREEN_LOG"

QUESTIONS=(
    "Make package changes?"
    "Stop Bluetooth from starting at startup?"
    "Modify ZRAM?"
    "Hard-blacklist unnecessary kernel modules?"
    "Select Flatpak packages to install:"
    "Import configurations?"
)
TOTAL_QUESTIONS=${#QUESTIONS[@]}
COMPLETED=(0 0 0 0 0 0)

FLATPAK_NAMES=("Sober")
FLATPAK_REFS=("app/org.vinegarhq.Sober/x86_64/stable")
TOTAL_FLATPAKS=${#FLATPAK_NAMES[@]}
FLATPAK_STATUS=(0) # 0 = Unanswered, 1 = Installed, 2 = Skipped

update_flatpak_question_status() {
    local any_installed=0
    local all_answered=1
    local i
    for (( i = 0; i < TOTAL_FLATPAKS; i++ )); do
        if (( FLATPAK_STATUS[i] == 1 )); then
            any_installed=1
        elif (( FLATPAK_STATUS[i] == 0 )); then
            all_answered=0
        fi
    done
    if (( any_installed == 1 )); then
        COMPLETED[4]=1
    elif (( all_answered == 1 )); then
        COMPLETED[4]=2
    fi
}

# Helper to format a question prompt with the orange [n/total] prefix
format_question_prompt() {
    local q_num="$1"
    local q_text="$2"
    local prefix
    prefix="$(CLICOLOR_FORCE=1 gum style --foreground 214 "[${q_num}/${TOTAL_QUESTIONS}]")"
    printf "%s %s" "$prefix" "$q_text"
}

# Interactive Gum-styled confirmation widget with TAB support and custom gray key guide:
# Return codes:
#   0 = Yes
#   1 = No
#   2 = TAB pressed (open question switcher)
# 130 = Ctrl + C (interrupted by user)
gum_confirm_with_tab() {
    local prompt_text="$1"
    local selected=0 # 0 = Yes (default), 1 = No
    local key=""
    local rest=""

    local prompt_styled
    prompt_styled="$(CLICOLOR_FORCE=1 gum style --foreground 99 --bold "$prompt_text")"

    local btn_yes_sel btn_yes_unsel btn_no_sel btn_no_unsel
    btn_yes_sel="$(CLICOLOR_FORCE=1 gum style --background 214 --foreground 15 "   Yes   ")"
    btn_yes_unsel="$(CLICOLOR_FORCE=1 gum style --background 235 --foreground 243 "   Yes   ")"
    btn_no_sel="$(CLICOLOR_FORCE=1 gum style --background 214 --foreground 15 "   No   ")"
    btn_no_unsel="$(CLICOLOR_FORCE=1 gum style --background 235 --foreground 243 "   No   ")"

    local help_line
    help_line=$'\033[38;5;15m←→\033[m \033[38;5;243mtoggle • \033[38;5;15menter\033[m \033[38;5;243msubmit • \033[38;5;15my\033[m \033[38;5;243mYes • \033[38;5;15mn\033[m \033[38;5;243mNo • \033[38;5;15mtab\033[m \033[38;5;243mswitch between questions\033[m'

    # Reserve 5 lines and save cursor position at the top of the widget
    printf "\n\n\n\n\n\033[5A\033[s\033[?25l"

    while true; do
        local buttons_line
        if (( selected == 0 )); then
            buttons_line=" ${btn_yes_sel}  ${btn_no_unsel}"
        else
            buttons_line=" ${btn_yes_unsel}  ${btn_no_sel}"
        fi

        printf "\033[u\r\033[J %s\n\n%s\n\n%s" "$prompt_styled" "$buttons_line" "$help_line"

        IFS= read -r -s -n 1 key || {
            printf "\033[u\r\033[J\033[?25h"
            return 130
        }

        if [[ -z "$key" ]]; then
            # Enter pressed
            printf "\033[u\r\033[J\033[?25h"
            return "$selected"
        elif [[ "$key" == $'\t' ]]; then
            # Tab pressed
            printf "\033[u\r\033[J\033[?25h"
            return 2
        elif [[ "$key" == "y" || "$key" == "Y" ]]; then
            printf "\033[u\r\033[J\033[?25h"
            return 0
        elif [[ "$key" == "n" || "$key" == "N" ]]; then
            printf "\033[u\r\033[J\033[?25h"
            return 1
        elif [[ "$key" == $'\x03' ]]; then
            # Ctrl+C
            printf "\033[u\r\033[J\033[?25h"
            return 130
        elif [[ "$key" == "h" || "$key" == "H" || "$key" == "l" || "$key" == "L" ]]; then
            selected=$(( 1 - selected ))
        elif [[ "$key" == $'\x1b' ]]; then
            IFS= read -r -s -n 2 -t 0.05 rest || true
            case "$rest" in
                "[C"|"[D")
                    selected=$(( 1 - selected ))
                    ;;
                "[Z")
                    # Shift+Tab
                    printf "\033[u\r\033[J\033[?25h"
                    return 2
                    ;;
            esac
        fi
    done
}

# Interactive question selector shown when TAB is pressed or when the last question is answered.
# Navigatable with Up/Down arrow keys; pressing Enter selects the question to jump to.
select_question_menu() {
    local current_idx="$1"
    local custom_header="${2:-Select a question:}"
    local cursor="$current_idx"
    local key=""
    local rest=""

    local menu_height=$(( TOTAL_QUESTIONS + 4 ))
    for (( i = 0; i < menu_height; i++ )); do
        printf "\n"
    done
    printf "\033[%dA\033[s\033[?25l" "$menu_height"

    local header_line
    header_line="$(CLICOLOR_FORCE=1 gum style --foreground 99 --bold "$custom_header")"
    local help_line
    help_line=$'\033[38;5;15m↓↑\033[m \033[38;5;243mnavigate • \033[38;5;15menter\033[m \033[38;5;243msubmit • \033[38;5;15mtab/esc\033[m \033[38;5;243mcancel\033[m'

    while true; do
        printf "\033[u\r\033[J%s\n" "$header_line"
        for (( i = 0; i < TOTAL_QUESTIONS; i++ )); do
            local q_num=$(( i + 1 ))
            local status_suffix=""
            if (( COMPLETED[i] == 1 )); then
                status_suffix=" (Applied)"
            elif (( COMPLETED[i] == 2 )); then
                status_suffix=" (Skipped)"
            fi
            local item_label="[${q_num}/${TOTAL_QUESTIONS}] ${QUESTIONS[i]}${status_suffix}"
            if (( i == cursor )); then
                printf "%s\n" "$(CLICOLOR_FORCE=1 gum style --foreground 214 "> ${item_label}")"
            else
                printf "  %s\n" "$item_label"
            fi
        done
        printf "\n%s" "$help_line"

        IFS= read -r -s -n 1 key || {
            printf "\033[u\r\033[J\033[?25h"
            return 130
        }

        if [[ -z "$key" ]]; then
            # Enter pressed: jump to selected question
            printf "\033[u\r\033[J\033[?25h"
            SELECTED_QUESTION_IDX="$cursor"
            return 0
        elif [[ "$key" == $'\t' ]]; then
            printf "\033[u\r\033[J\033[?25h"
            SELECTED_QUESTION_IDX="$current_idx"
            return 2
        elif [[ "$key" == $'\x03' ]]; then
            printf "\033[u\r\033[J\033[?25h"
            return 130
        elif [[ "$key" == "k" || "$key" == "K" ]]; then
            cursor=$(( (cursor - 1 + TOTAL_QUESTIONS) % TOTAL_QUESTIONS ))
        elif [[ "$key" == "j" || "$key" == "J" ]]; then
            cursor=$(( (cursor + 1) % TOTAL_QUESTIONS ))
        elif [[ "$key" == $'\x1b' ]]; then
            IFS= read -r -s -n 2 -t 0.05 rest || true
            case "$rest" in
                "[A")
                    cursor=$(( (cursor - 1 + TOTAL_QUESTIONS) % TOTAL_QUESTIONS ))
                    ;;
                "[B")
                    cursor=$(( (cursor + 1) % TOTAL_QUESTIONS ))
                    ;;
                "[Z"|"")
                    printf "\033[u\r\033[J\033[?25h"
                    SELECTED_QUESTION_IDX="$current_idx"
                    return 2
                    ;;
            esac
        fi
    done
}

execute_question() {
    local q_idx="$1"
    local user_choice="$2"

    case "$q_idx" in
        0)
            # Question 1: Make package changes?
            if [[ "$user_choice" == "Y" ]]; then
                local total_steps=2
                if [[ "$PLATFORM" == "Laptop" ]]; then
                    total_steps=4
                fi

                local step1_prefix step1_title
                step1_prefix="$(CLICOLOR_FORCE=1 gum style --foreground 214 --bold "[Step 1/${total_steps}]")"
                step1_title="$(CLICOLOR_FORCE=1 gum style --foreground 15 "Removing unneeded linux-firmware packages...")"
                out "${step1_prefix} ${step1_title}"

                out "$(CLICOLOR_FORCE=1 gum style --foreground 99 "Searching for installed linux-firmware packages...")"
                mapfile -t installed_fw < <(pacman -Qq | grep -E '^linux-firmware' || true)

                pkgs_to_remove=()
                for pkg in "${installed_fw[@]}"; do
                    if [[ "$PLATFORM" == "Desktop" ]]; then
                        case "$pkg" in
                            linux-firmware-amd|linux-firmware-other|linux-firmware-realtek|linux-firmware-nvidia|linux-firmware-whence)
                                continue
                                ;;
                        esac
                    elif [[ "$PLATFORM" == "Laptop" ]]; then
                        case "$pkg" in
                            linux-firmware-other|linux-firmware-realtek|linux-firmware-intel)
                                continue
                                ;;
                        esac
                    fi
                    pkgs_to_remove+=("$pkg")
                done

                if (( ${#pkgs_to_remove[@]} > 0 )); then
                    out "$(CLICOLOR_FORCE=1 gum style --foreground 99 "Removing packages: ${pkgs_to_remove[*]}")"
                    sudo pacman -Rndd --noconfirm "${pkgs_to_remove[@]}" 2>&1 | tee -a "$SCREEN_LOG"
                else
                    out "$(CLICOLOR_FORCE=1 gum style --foreground 243 "No unneeded linux-firmware packages found to remove.")"
                fi

                local step2_prefix step2_title
                step2_prefix="$(CLICOLOR_FORCE=1 gum style --foreground 214 --bold "[Step 2/${total_steps}]")"
                step2_title="$(CLICOLOR_FORCE=1 gum style --foreground 15 "Uninstalling plasma-thunderbolt...")"
                out "${step2_prefix} ${step2_title}"

                if pacman -Qq plasma-thunderbolt >/dev/null 2>&1; then
                    out "$(CLICOLOR_FORCE=1 gum style --foreground 99 "Removing package: plasma-thunderbolt")"
                    sudo pacman -Rndd --noconfirm plasma-thunderbolt 2>&1 | tee -a "$SCREEN_LOG"
                else
                    out "$(CLICOLOR_FORCE=1 gum style --foreground 243 "plasma-thunderbolt is not installed. Skipping removal.")"
                fi

                if [[ "$PLATFORM" == "Laptop" ]]; then
                    local step3_prefix step3_title
                    step3_prefix="$(CLICOLOR_FORCE=1 gum style --foreground 214 --bold "[Step 3/${total_steps}]")"
                    step3_title="$(CLICOLOR_FORCE=1 gum style --foreground 15 "Uninstalling kitty and installing foot...")"
                    out "${step3_prefix} ${step3_title}"

                    if pacman -Qq kitty >/dev/null 2>&1; then
                        out "$(CLICOLOR_FORCE=1 gum style --foreground 99 "Removing package: kitty")"
                        sudo pacman -Rndd --noconfirm kitty 2>&1 | tee -a "$SCREEN_LOG"
                    else
                        out "$(CLICOLOR_FORCE=1 gum style --foreground 243 "kitty is not installed. Skipping removal.")"
                    fi

                    out "$(CLICOLOR_FORCE=1 gum style --foreground 99 "Installing package: foot")"
                    sudo pacman -S --needed --noconfirm foot 2>&1 | tee -a "$SCREEN_LOG"

                    local step4_prefix step4_title
                    step4_prefix="$(CLICOLOR_FORCE=1 gum style --foreground 214 --bold "[Step 4/${total_steps}]")"
                    step4_title="$(CLICOLOR_FORCE=1 gum style --foreground 15 "Installing and enabling TLP...")"
                    out "${step4_prefix} ${step4_title}"

                    out "$(CLICOLOR_FORCE=1 gum style --foreground 99 "Installing packages: tlp tlp-rdw tlp-pd")"
                    sudo pacman -S --needed --noconfirm tlp tlp-rdw tlp-pd 2>&1 | tee -a "$SCREEN_LOG"

                    out "$(CLICOLOR_FORCE=1 gum style --foreground 99 "Enabling TLP and TLP-PD services...")"
                    sudo systemctl enable --now tlp tlp-pd 2>&1 | tee -a "$SCREEN_LOG"
                fi
            else
                collapse_if_prev_skipped
                out "$(CLICOLOR_FORCE=1 gum style --foreground 243 "Skipped package changes.")"
            fi
            ;;
        1)
            # Question 2: Stop Bluetooth from starting at startup?
            if [[ "$user_choice" == "Y" ]]; then
                bt_conf="/etc/bluetooth/main.conf"
                if [[ -f "$bt_conf" ]]; then
                    if grep -Eq '^[[:space:]]*#?[[:space:]]*AutoEnable[[:space:]]*=' "$bt_conf"; then
                        sudo sed -i -E 's/^[[:space:]]*#?[[:space:]]*AutoEnable[[:space:]]*=.*/AutoEnable = false/' "$bt_conf"
                    else
                        if grep -Eq '^[[:space:]]*\[Policy\]' "$bt_conf"; then
                            sudo sed -i -E '/^[[:space:]]*\[Policy\]/a AutoEnable = false' "$bt_conf"
                        else
                            printf "\n[Policy]\nAutoEnable = false\n" | sudo tee -a "$bt_conf" >/dev/null
                        fi
                    fi
                    out "$(CLICOLOR_FORCE=1 gum style --foreground 99 "Set AutoEnable = false in ${bt_conf}.")"
                else
                    out "$(CLICOLOR_FORCE=1 gum style --foreground 214 "${bt_conf} not found. Skipping.")"
                fi
            else
                collapse_if_prev_skipped
                out "$(CLICOLOR_FORCE=1 gum style --foreground 243 "Skipped disabling Bluetooth AutoEnable.")"
            fi
            ;;
        2)
            # Question 3: Modify ZRAM?
            if [[ "$user_choice" == "Y" ]]; then
                zram_conf="/etc/systemd/zram-generator.conf"
                zram_algo="lz4"
                if [[ "$PLATFORM" == "Desktop" ]]; then
                    zram_algo="zstd"
                fi
                sudo mkdir -p /etc/systemd
                sudo tee "$zram_conf" >/dev/null <<EOF
[zram0]
zram-size = ram/4
compression-algorithm = ${zram_algo}
fs-type = swap
swap-priority = 100
EOF
                out "$(CLICOLOR_FORCE=1 gum style --foreground 99 "Updated ${zram_conf}.")"
            else
                collapse_if_prev_skipped
                out "$(CLICOLOR_FORCE=1 gum style --foreground 243 "Skipped ZRAM modification.")"
            fi
            ;;
        3)
            # Question 4: Hard-blacklist unnecessary kernel modules from starting?
            if [[ "$user_choice" == "Y" ]]; then
                blacklist_conf="/etc/modprobe.d/blacklists.conf"
                sudo mkdir -p /etc/modprobe.d
                if [[ "$PLATFORM" == "Desktop" ]]; then
                    sudo tee "$blacklist_conf" >/dev/null <<'EOF'
blacklist pcspkr
blacklist sp5100_tco

blacklist eeepc_wmi
blacklist asus_wmi
blacklist sparse_keymap
blacklist rfkill

blacklist mac_hid
blacklist mousedev
blacklist joydev

blacklist ccp
blacklist gpio_amdpt
blacklist gpio_generic
blacklist ee1004
blacklist snd_hda_codec_atihdmi

blacklist nouveau
blacklist nova_core
blacklist nova_drm

install pcspkr /bin/false
install sp5100_tco /bin/false

install eeepc_wmi /bin/false
install asus_wmi /bin/false
install sparse_keymap /bin/false
install rfkill /bin/false

install mac_hid /bin/false
install mousedev /bin/false
install joydev /bin/false

install ccp /bin/false
install gpio_amdpt /bin/false
install gpio_generic /bin/false
install ee1004 /bin/false
install snd_hda_codec_atihdmi /bin/false
EOF
                else
                    sudo tee "$blacklist_conf" >/dev/null <<'EOF'
blacklist mei
blacklist mei_me
blacklist mei_hdcp
blacklist mei_pxp

blacklist intel_vsec
blacklist pmt_telemetry
blacklist pmt_discovery
blacklist pmt_class
blacklist intel_pmc_core
blacklist intel_pmc_ssram_telemetry
blacklist intel_pmc_pwrm_telemetry

blacklist intel_oc_wdt

install mei /bin/false
install mei_me /bin/false
install mei_hdcp /bin/false
install mei_pxp /bin/false

install intel_vsec /bin/false
install pmt_telemetry /bin/false
install pmt_discovery /bin/false
install pmt_class /bin/false
install intel_pmc_core /bin/false
install intel_pmc_ssram_telemetry /bin/false
install intel_pmc_pwrm_telemetry /bin/false

install intel_oc_wdt /bin/false
EOF
                fi
                out "$(CLICOLOR_FORCE=1 gum style --foreground 99 "Updated ${blacklist_conf}.")"
            else
                collapse_if_prev_skipped
                out "$(CLICOLOR_FORCE=1 gum style --foreground 243 "Skipped kernel module blacklisting.")"
            fi
            ;;
        5)
            # Question 6: Import configurations?
            if [[ "$user_choice" == "Y" ]]; then
                local has_hyprland=0
                if pacman -Qq hyprland >/dev/null 2>&1 || command -v Hyprland >/dev/null 2>&1 || command -v hyprctl >/dev/null 2>&1; then
                    has_hyprland=1
                fi

                if (( has_hyprland == 1 )); then
                    platform_dir="laptop"
                    if [[ "$PLATFORM" == "Desktop" ]]; then
                        platform_dir="desktop"
                    fi
                    out "$(CLICOLOR_FORCE=1 gum style --foreground 99 "Pulling configurations (${platform_dir}) from GitHub...")"

                    tmp_dotfiles="$(mktemp -d /tmp/oobe_dotfiles.XXXXXX)"
                    pull_ok=0
                    if command -v git >/dev/null 2>&1; then
                        if git clone --depth 1 https://github.com/vunts32cs/oobe-for-cachyos.git "$tmp_dotfiles/repo" 2>&1 | tee -a "$SCREEN_LOG"; then
                            pull_ok=1
                        fi
                    elif command -v curl >/dev/null 2>&1; then
                        mkdir -p "$tmp_dotfiles/repo"
                        if curl -fsSL https://github.com/vunts32cs/oobe-for-cachyos/archive/refs/heads/main.tar.gz | tar -xz -C "$tmp_dotfiles/repo" --strip-components=1 2>&1 | tee -a "$SCREEN_LOG"; then
                            pull_ok=1
                        fi
                    else
                        out "$(CLICOLOR_FORCE=1 gum style --foreground 196 "Error: Neither git nor curl is available to pull dotfiles from GitHub.")"
                    fi

                    if (( pull_ok == 1 )); then
                        src_assets="$tmp_dotfiles/repo/assets/$platform_dir"
                        if [[ -d "$src_assets/hypr" ]]; then
                            mkdir -p "$HOME/.config"
                            rm -rf "$HOME/.config/hypr"
                            cp -r "$src_assets/hypr" "$HOME/.config/hypr"
                            out "$(CLICOLOR_FORCE=1 gum style --foreground 99 "Imported hypr folder to $HOME/.config/hypr.")"
                        else
                            out "$(CLICOLOR_FORCE=1 gum style --foreground 214 "assets/${platform_dir}/hypr not found in repository. Skipping hypr import.")"
                        fi

                        if [[ -f "$src_assets/noctalia-config.toml" ]]; then
                            mkdir -p "$HOME/.config/noctalia"
                            cp -f "$src_assets/noctalia-config.toml" "$HOME/.config/noctalia/noctalia-config.toml"
                            out "$(CLICOLOR_FORCE=1 gum style --foreground 99 "Imported noctalia-config.toml to $HOME/.config/noctalia/noctalia-config.toml.")"
                        else
                            out "$(CLICOLOR_FORCE=1 gum style --foreground 214 "assets/${platform_dir}/noctalia-config.toml not found in repository. Skipping noctalia import.")"
                        fi

                        if [[ -f "$src_assets/foot.ini" ]]; then
                            mkdir -p "$HOME/.config/foot"
                            cp -f "$src_assets/foot.ini" "$HOME/.config/foot/foot.ini"
                            out "$(CLICOLOR_FORCE=1 gum style --foreground 99 "Imported foot.ini to $HOME/.config/foot/foot.ini.")"
                        elif [[ "$PLATFORM" == "Laptop" ]]; then
                            out "$(CLICOLOR_FORCE=1 gum style --foreground 214 "assets/${platform_dir}/foot.ini not found in repository. Skipping foot import.")"
                        fi
                    elif command -v git >/dev/null 2>&1 || command -v curl >/dev/null 2>&1; then
                        out "$(CLICOLOR_FORCE=1 gum style --foreground 196 "Failed to pull dotfiles from GitHub.")"
                    fi
                    rm -rf "$tmp_dotfiles"
                else
                    out "$(CLICOLOR_FORCE=1 gum style --foreground 243 "Hyprland is not installed. Skipping Hyprland configuration import.")"
                fi

                mkdir -p "$HOME/.config/autostart"
                cat <<'EOF' > "$HOME/.config/autostart/arch-update-tray.desktop"
[Desktop Entry]
Hidden=true
EOF
                out "$(CLICOLOR_FORCE=1 gum style --foreground 99 "Updated $HOME/.config/autostart/arch-update-tray.desktop.")"

                if (( has_hyprland == 1 )) && command -v hyprctl >/dev/null 2>&1; then
                    out "$(CLICOLOR_FORCE=1 gum style --foreground 99 "Reloading Hyprland configuration...")"
                    hyprctl reload 2>&1 | tee -a "$SCREEN_LOG"
                fi
            else
                collapse_if_prev_skipped
                out "$(CLICOLOR_FORCE=1 gum style --foreground 243 "Skipped importing configurations.")"
            fi
            ;;
    esac
}

get_countdown_prefix() {
    local q_idx="$1"
    local choice="$2"
    case "$q_idx:$choice" in
        0:Y) echo "Will make package changes" ;;
        0:N) echo "Will skip package changes" ;;
        1:Y) echo "Will disable Bluetooth AutoEnable" ;;
        1:N) echo "Will skip disabling Bluetooth AutoEnable" ;;
        2:Y) echo "Will modify ZRAM configuration" ;;
        2:N) echo "Will skip ZRAM modification" ;;
        3:Y) echo "Will hard-blacklist unnecessary kernel modules" ;;
        3:N) echo "Will skip kernel module blacklisting" ;;
        5:Y) echo "Will import configurations" ;;
        5:N) echo "Will skip importing configurations" ;;
    esac
}

all_questions_completed() {
    local i
    for (( i = 0; i < TOTAL_QUESTIONS; i++ )); do
        if (( COMPLETED[i] == 0 )); then
            return 1
        fi
    done
    return 0
}

any_question_applied() {
    local i
    for (( i = 0; i < TOTAL_QUESTIONS; i++ )); do
        if (( COMPLETED[i] == 1 )); then
            return 0
        fi
    done
    return 1
}

first_uncompleted_question() {
    local i
    for (( i = 0; i < TOTAL_QUESTIONS; i++ )); do
        if (( COMPLETED[i] == 0 )); then
            echo "$i"
            return 0
        fi
    done
    echo 0
}

# Completion prompt shown when all questions are completed:
# "Script complete. Automatically exiting in 10s." with options:
#   0 = "Okay"
#   1 = "Go back to the questions list"
# 130 = Ctrl + C
completion_prompt() {
    local selected=0
    local end_us=$(( ${EPOCHREALTIME/./} + 10 * 1000000 ))
    local last_sec=-1
    local last_selected=-1
    local key=""
    local rest=""
    local timeout_str=""

    local btn_ok_sel btn_ok_unsel btn_back_sel btn_back_unsel
    btn_ok_sel="$(CLICOLOR_FORCE=1 gum style --background 214 --foreground 15 "   Okay   ")"
    btn_ok_unsel="$(CLICOLOR_FORCE=1 gum style --background 235 --foreground 243 "   Okay   ")"
    btn_back_sel="$(CLICOLOR_FORCE=1 gum style --background 214 --foreground 15 "   Go back to the questions list   ")"
    btn_back_unsel="$(CLICOLOR_FORCE=1 gum style --background 235 --foreground 243 "   Go back to the questions list   ")"

    local help_line
    help_line=$'\033[38;5;15m←→\033[m \033[38;5;243mtoggle • \033[38;5;15menter\033[m \033[38;5;243msubmit\033[m'

    local reboot_suffix=""
    if any_question_applied; then
        reboot_suffix=" $(CLICOLOR_FORCE=1 gum style --foreground 196 "Reboot required.")"
    fi

    printf "\n\n\n\n\n\033[5A\033[s\033[?7l\033[?25l"

    while true; do
        local now_us=${EPOCHREALTIME/./}
        local rem_us=$(( end_us - now_us ))
        if (( rem_us <= 0 )); then
            break
        fi

        local seconds=$(( (rem_us + 999999) / 1000000 ))
        if (( seconds != last_sec || selected != last_selected )); then
            local prompt_styled
            prompt_styled="$(CLICOLOR_FORCE=1 gum style --foreground 99 --bold "Script complete. Automatically exiting in ${seconds}s.")${reboot_suffix}"

            local buttons_line
            if (( selected == 0 )); then
                buttons_line=" ${btn_ok_sel}  ${btn_back_unsel}"
            else
                buttons_line=" ${btn_ok_unsel}  ${btn_back_sel}"
            fi

            printf "\033[u\r\033[J %s\n\n%s\n\n%s" "$prompt_styled" "$buttons_line" "$help_line"
            last_sec=$seconds
            last_selected=$selected
        fi

        set_next_tick_timeout timeout_str "$rem_us" "$seconds"

        if IFS= read -r -s -n 1 -t "$timeout_str" key; then
            if [[ -z "$key" ]]; then
                printf "\033[u\r\033[J\033[?7h\033[?25h"
                return "$selected"
            elif [[ "$key" == $'\x03' ]]; then
                printf "\033[u\r\033[J\033[?7h\033[?25h"
                return 130
            elif [[ "$key" == $'\t' || "$key" == "h" || "$key" == "H" || "$key" == "l" || "$key" == "L" ]]; then
                selected=$(( 1 - selected ))
            elif [[ "$key" == $'\x1b' ]]; then
                IFS= read -r -s -n 2 -t 0.01 rest || true
                case "$rest" in
                    "[C"|"[D"|"[Z")
                        selected=$(( 1 - selected ))
                        ;;
                esac
            fi
        fi
    done

    printf "\033[u\r\033[J\033[?7h\033[?25h"
    return 0
}

# Interactive Gum-styled Yes/No prompt (no Tab switcher) for sub-prompts:
# Return codes:
#   0 = Yes
#   1 = No
# 130 = Ctrl + C (interrupted by user)
gum_confirm_simple() {
    local prompt_text="$1"
    local selected=0 # 0 = Yes (default), 1 = No
    local key=""
    local rest=""

    local prompt_styled
    prompt_styled="$(CLICOLOR_FORCE=1 gum style --foreground 15 "$prompt_text")"

    local btn_yes_sel btn_yes_unsel btn_no_sel btn_no_unsel
    btn_yes_sel="$(CLICOLOR_FORCE=1 gum style --background 214 --foreground 15 "   Yes   ")"
    btn_yes_unsel="$(CLICOLOR_FORCE=1 gum style --background 235 --foreground 243 "   Yes   ")"
    btn_no_sel="$(CLICOLOR_FORCE=1 gum style --background 214 --foreground 15 "   No   ")"
    btn_no_unsel="$(CLICOLOR_FORCE=1 gum style --background 235 --foreground 243 "   No   ")"

    local help_line
    help_line=$'\033[38;5;15m←→\033[m \033[38;5;243mtoggle • \033[38;5;15menter\033[m \033[38;5;243msubmit • \033[38;5;15my\033[m \033[38;5;243mYes • \033[38;5;15mn\033[m \033[38;5;243mNo\033[m'

    printf "\n\n\n\n\n\033[5A\033[s\033[?25l"

    while true; do
        local buttons_line
        if (( selected == 0 )); then
            buttons_line=" ${btn_yes_sel}  ${btn_no_unsel}"
        else
            buttons_line=" ${btn_yes_unsel}  ${btn_no_sel}"
        fi

        printf "\033[u\r\033[J %s\n\n%s\n\n%s" "$prompt_styled" "$buttons_line" "$help_line"

        IFS= read -r -s -n 1 key || {
            printf "\033[u\r\033[J\033[?25h"
            return 130
        }

        if [[ -z "$key" ]]; then
            printf "\033[u\r\033[J\033[?25h"
            return "$selected"
        elif [[ "$key" == "y" || "$key" == "Y" ]]; then
            printf "\033[u\r\033[J\033[?25h"
            return 0
        elif [[ "$key" == "n" || "$key" == "N" ]]; then
            printf "\033[u\r\033[J\033[?25h"
            return 1
        elif [[ "$key" == $'\x03' ]]; then
            printf "\033[u\r\033[J\033[?25h"
            return 130
        elif [[ "$key" == $'\t' || "$key" == "h" || "$key" == "H" || "$key" == "l" || "$key" == "L" ]]; then
            selected=$(( 1 - selected ))
        elif [[ "$key" == $'\x1b' ]]; then
            IFS= read -r -s -n 2 -t 0.05 rest || true
            case "$rest" in
                "[C"|"[D"|"[Z")
                    selected=$(( 1 - selected ))
                    ;;
            esac
        fi
    done
}

# Interactive Flatpak packages selector for Question 5:
# Return codes:
#   0 = Finished Flatpak packages menu (q/Esc)
#   2 = TAB pressed (open question switcher)
# 130 = Ctrl + C (interrupted by user)
flatpak_packages_menu() {
    local cursor=0
    local key=""
    local rest=""
    local menu_height=$(( TOTAL_FLATPAKS + 4 ))

    local header_line
    header_line="$(CLICOLOR_FORCE=1 gum style --foreground 99 --bold "$(format_question_prompt 5 "${QUESTIONS[4]}")")"
    local help_line
    help_line=$'\033[38;5;15m↓↑\033[m \033[38;5;243mnavigate • \033[38;5;15menter\033[m \033[38;5;243mselect • \033[38;5;15mq/esc\033[m \033[38;5;243mfinish • \033[38;5;15mtab\033[m \033[38;5;243mswitch between questions\033[m'

    while true; do
        for (( i = 0; i < menu_height; i++ )); do
            printf "\n"
        done
        printf "\033[%dA\033[s\033[?25l" "$menu_height"

        local chosen_action=""
        while true; do
            printf "\033[u\r\033[J%s\n" "$header_line"
            for (( i = 0; i < TOTAL_FLATPAKS; i++ )); do
                local status_suffix=""
                if (( FLATPAK_STATUS[i] == 1 )); then
                    status_suffix=" (Installed)"
                elif (( FLATPAK_STATUS[i] == 2 )); then
                    status_suffix=" (Skipped)"
                fi
                local item_label="${FLATPAK_NAMES[i]} (${FLATPAK_REFS[i]})${status_suffix}"
                if (( i == cursor )); then
                    printf "%s\n" "$(CLICOLOR_FORCE=1 gum style --foreground 214 "> ${item_label}")"
                else
                    printf "  %s\n" "$item_label"
                fi
            done
            printf "\n%s" "$help_line"

            IFS= read -r -s -n 1 key || {
                printf "\033[u\r\033[J\033[?25h"
                return 130
            }

            if [[ -z "$key" ]]; then
                printf "\033[u\r\033[J\033[?25h"
                chosen_action="select"
                break
            elif [[ "$key" == $'\t' ]]; then
                printf "\033[u\r\033[J\033[?25h"
                return 2
            elif [[ "$key" == "q" || "$key" == "Q" ]]; then
                printf "\033[u\r\033[J\033[?25h"
                return 0
            elif [[ "$key" == $'\x03' ]]; then
                printf "\033[u\r\033[J\033[?25h"
                return 130
            elif [[ "$key" == "k" || "$key" == "K" ]]; then
                cursor=$(( (cursor - 1 + TOTAL_FLATPAKS) % TOTAL_FLATPAKS ))
            elif [[ "$key" == "j" || "$key" == "J" ]]; then
                cursor=$(( (cursor + 1) % TOTAL_FLATPAKS ))
            elif [[ "$key" == $'\x1b' ]]; then
                IFS= read -r -s -n 2 -t 0.05 rest || true
                case "$rest" in
                    "[A")
                        cursor=$(( (cursor - 1 + TOTAL_FLATPAKS) % TOTAL_FLATPAKS ))
                        ;;
                    "[B")
                        cursor=$(( (cursor + 1) % TOTAL_FLATPAKS ))
                        ;;
                    "[Z")
                        printf "\033[u\r\033[J\033[?25h"
                        return 2
                        ;;
                    "")
                        printf "\033[u\r\033[J\033[?25h"
                        return 0
                        ;;
                esac
            fi
        done

        if [[ "$chosen_action" == "select" ]]; then
            local prog_name="${FLATPAK_NAMES[cursor]}"
            local prog_ref="${FLATPAK_REFS[cursor]}"
            while true; do
                gum_confirm_simple "Install ${prog_name}?"
                local fp_rc=$?
                if (( fp_rc == 130 )); then
                    return 130
                elif (( fp_rc == 1 )); then
                    FLATPAK_STATUS[cursor]=2
                    update_flatpak_question_status
                    break
                else
                    if ! countdown_action "Will install ${prog_name}"; then
                        continue
                    fi
                    out "$(CLICOLOR_FORCE=1 gum style --foreground 99 "Installing ${prog_name} (${prog_ref})...")"
                    flatpak install -y flathub "$prog_ref" 2>&1 | tee -a "$SCREEN_LOG"
                    FLATPAK_STATUS[cursor]=1
                    update_flatpak_question_status
                    break
                fi
            done
        fi
    done
}

current_q=0
force_ask=0
while true; do
    if (( force_ask == 0 )) && all_questions_completed; then
        completion_prompt
        comp_rc=$?
        if (( comp_rc == 130 )); then
            handle_sigint
        elif (( comp_rc == 1 )); then
            SELECTED_QUESTION_IDX=0
            select_question_menu 0 "Select a question:"
            menu_rc=$?
            if (( menu_rc == 130 )); then
                handle_sigint
            elif (( menu_rc == 2 )); then
                # Cancelled out of questions list while all questions are complete: return to completion prompt
                continue
            fi
            current_q="$SELECTED_QUESTION_IDX"
            force_ask=1
        else
            final_msg="$(CLICOLOR_FORCE=1 gum style --foreground 99 --bold "Script completed.")"
            if any_question_applied; then
                final_msg="${final_msg} $(CLICOLOR_FORCE=1 gum style --foreground 196 "Reboot required.")"
            fi
            out "$final_msg"
            break
        fi
    fi
    force_ask=0

    if (( current_q >= TOTAL_QUESTIONS )); then
        first_uncomp="$(first_uncompleted_question)"
        SELECTED_QUESTION_IDX="$first_uncomp"
        select_question_menu "$first_uncomp" "Last question answered. Select a question:"
        menu_rc=$?
        if (( menu_rc == 130 )); then
            handle_sigint
        fi
        current_q="$SELECTED_QUESTION_IDX"
        continue
    fi

    if (( current_q == 4 )); then
        flatpak_packages_menu
        fp_menu_rc=$?
        if (( fp_menu_rc == 130 )); then
            handle_sigint
        elif (( fp_menu_rc == 2 )); then
            SELECTED_QUESTION_IDX="$current_q"
            select_question_menu "$current_q" "Select a question:"
            menu_rc=$?
            if (( menu_rc == 130 )); then
                handle_sigint
            elif (( menu_rc == 2 )) && all_questions_completed; then
                continue
            fi
            current_q="$SELECTED_QUESTION_IDX"
            if all_questions_completed; then
                force_ask=1
            fi
            continue
        fi
        if (( COMPLETED[4] == 0 )); then
            COMPLETED[4]=2
        fi
    else
        q_num=$(( current_q + 1 ))
        prompt_str="$(format_question_prompt "$q_num" "${QUESTIONS[current_q]}")"

        gum_confirm_with_tab "$prompt_str"
        confirm_rc=$?

        if (( confirm_rc == 130 )); then
            handle_sigint
        elif (( confirm_rc == 2 )); then
            SELECTED_QUESTION_IDX="$current_q"
            select_question_menu "$current_q" "Select a question:"
            menu_rc=$?
            if (( menu_rc == 130 )); then
                handle_sigint
            elif (( menu_rc == 2 )) && all_questions_completed; then
                # Backed out of questions list while all questions are complete: show completion message
                continue
            fi
            current_q="$SELECTED_QUESTION_IDX"
            if all_questions_completed; then
                force_ask=1
            fi
            continue
        elif (( confirm_rc == 0 )); then
            user_choice="Y"
        else
            user_choice="N"
        fi

        if [[ "$user_choice" == "Y" ]]; then
            countdown_prefix="$(get_countdown_prefix "$current_q" "$user_choice")"
            if ! countdown_action "$countdown_prefix"; then
                continue
            fi
            execute_question "$current_q" "$user_choice"
            COMPLETED[current_q]=1
        else
            execute_question "$current_q" "$user_choice"
            COMPLETED[current_q]=2
        fi
    fi

    (( current_q++ ))
    if (( current_q < TOTAL_QUESTIONS && COMPLETED[current_q] != 0 )) && ! all_questions_completed; then
        next_q_num=$(( current_q + 1 ))
        if (( COMPLETED[current_q] == 1 )); then
            next_state="Applied"
        else
            next_state="Skipped"
        fi
        out "$(CLICOLOR_FORCE=1 gum style --foreground 99 --bold "Next question (${next_q_num}/${TOTAL_QUESTIONS}) is answered (${next_state}). To another question...")"
        current_q="$(first_uncompleted_question)"
    fi
    out_spacer
done
