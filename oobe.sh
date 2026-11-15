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
    CLICOLOR_FORCE=1 gum style --foreground 214 "Exited."
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
    local end_us=$(( ${EPOCHREALTIME/./} + 6 * 1000000 ))
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
    "Remove unneeded linux-firmware packages?"
    "Stop Bluetooth from starting at startup?"
    "Modify ZRAM?"
    "Hard-blacklist unnecessary kernel modules from starting?"
    "Select Flatpak packages to install:"
)
TOTAL_QUESTIONS=${#QUESTIONS[@]}
COMPLETED=(0 0 0 0 0)

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
    btn_yes_sel="$(CLICOLOR_FORCE=1 gum style --background 214 --foreground 230 "   Yes   ")"
    btn_yes_unsel="$(CLICOLOR_FORCE=1 gum style --background 235 --foreground 254 "   Yes   ")"
    btn_no_sel="$(CLICOLOR_FORCE=1 gum style --background 214 --foreground 230 "   No   ")"
    btn_no_unsel="$(CLICOLOR_FORCE=1 gum style --background 235 --foreground 254 "   No   ")"

    local help_line
    help_line=$'\033[38;5;241m←→\033[m \033[38;5;239mtoggle\033[38;5;237m • \033[38;5;241menter\033[m \033[38;5;239msubmit\033[38;5;237m • \033[38;5;241my\033[m \033[38;5;239mYes\033[38;5;237m • \033[38;5;241mn\033[m \033[38;5;239mNo\033[38;5;237m • \033[38;5;241mtab\033[m \033[38;5;239mswitch between questions\033[m'

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
    help_line=$'\033[38;5;241m↓↑\033[m \033[38;5;239mnavigate\033[38;5;237m • \033[38;5;241menter\033[m \033[38;5;239msubmit\033[38;5;237m • \033[38;5;241mtab/esc\033[m \033[38;5;239mcancel\033[m'

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
                printf "%s\n" "$(CLICOLOR_FORCE=1 gum style --foreground 212 "> ${item_label}")"
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
            # Question 1: Remove unneeded linux-firmware packages?
            if [[ "$user_choice" == "Y" ]]; then
                out "$(CLICOLOR_FORCE=1 gum style --foreground 86 "Searching for installed linux-firmware packages...")"
                mapfile -t installed_fw < <(pacman -Qq | grep -E '^linux-firmware' || true)

                pkgs_to_remove=()
                for pkg in "${installed_fw[@]}"; do
                    if [[ "$PLATFORM" == "Desktop" ]]; then
                        case "$pkg" in
                            linux-firmware-amd|linux-firmware-other|linux-firmware-realtek|linux-firmware-nvidia)
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
                    out "$(CLICOLOR_FORCE=1 gum style --foreground 214 "Removing packages: ${pkgs_to_remove[*]}")"
                    sudo pacman -Rnsdd --noconfirm "${pkgs_to_remove[@]}" 2>&1 | tee -a "$SCREEN_LOG"
                else
                    out "$(CLICOLOR_FORCE=1 gum style --foreground 86 "No unneeded linux-firmware packages found to remove.")"
                fi
            else
                out "$(CLICOLOR_FORCE=1 gum style --foreground 245 "Skipped linux-firmware cleanup.")"
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
                    out "$(CLICOLOR_FORCE=1 gum style --foreground 86 "Set AutoEnable = false in ${bt_conf}.")"
                else
                    out "$(CLICOLOR_FORCE=1 gum style --foreground 214 "${bt_conf} not found. Skipping.")"
                fi
            else
                out "$(CLICOLOR_FORCE=1 gum style --foreground 245 "Skipped disabling Bluetooth AutoEnable.")"
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
                out "$(CLICOLOR_FORCE=1 gum style --foreground 86 "Updated ${zram_conf}.")"
            else
                out "$(CLICOLOR_FORCE=1 gum style --foreground 245 "Skipped ZRAM modification.")"
            fi
            ;;
        3)
            # Question 4: Hard-blacklist unnecessary kernel modules from starting?
            if [[ "$user_choice" == "Y" ]]; then
                blacklist_conf="/etc/modprobe.d/blacklists.conf"
                sudo mkdir -p /etc/modprobe.d
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
                out "$(CLICOLOR_FORCE=1 gum style --foreground 86 "Updated ${blacklist_conf}.")"
            else
                out "$(CLICOLOR_FORCE=1 gum style --foreground 245 "Skipped kernel module blacklisting.")"
            fi
            ;;
    esac
}

get_countdown_prefix() {
    local q_idx="$1"
    local choice="$2"
    case "$q_idx:$choice" in
        0:Y) echo "Will run linux-firmware cleanup" ;;
        0:N) echo "Will skip linux-firmware cleanup" ;;
        1:Y) echo "Will disable Bluetooth AutoEnable" ;;
        1:N) echo "Will skip disabling Bluetooth AutoEnable" ;;
        2:Y) echo "Will modify ZRAM configuration" ;;
        2:N) echo "Will skip ZRAM modification" ;;
        3:Y) echo "Will hard-blacklist unnecessary kernel modules" ;;
        3:N) echo "Will skip kernel module blacklisting" ;;
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
    btn_ok_sel="$(CLICOLOR_FORCE=1 gum style --background 214 --foreground 230 "   Okay   ")"
    btn_ok_unsel="$(CLICOLOR_FORCE=1 gum style --background 235 --foreground 254 "   Okay   ")"
    btn_back_sel="$(CLICOLOR_FORCE=1 gum style --background 214 --foreground 230 "   Go back to the questions list   ")"
    btn_back_unsel="$(CLICOLOR_FORCE=1 gum style --background 235 --foreground 254 "   Go back to the questions list   ")"

    local help_line
    help_line=$'\033[38;5;241m←→\033[m \033[38;5;239mtoggle\033[38;5;237m • \033[38;5;241menter\033[m \033[38;5;239msubmit\033[m'

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
            prompt_styled="$(CLICOLOR_FORCE=1 gum style --foreground 99 --bold "Script complete. Automatically exiting in ${seconds}s.")"

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
    prompt_styled="$(CLICOLOR_FORCE=1 gum style --foreground 99 --bold "$prompt_text")"

    local btn_yes_sel btn_yes_unsel btn_no_sel btn_no_unsel
    btn_yes_sel="$(CLICOLOR_FORCE=1 gum style --background 214 --foreground 230 "   Yes   ")"
    btn_yes_unsel="$(CLICOLOR_FORCE=1 gum style --background 235 --foreground 254 "   Yes   ")"
    btn_no_sel="$(CLICOLOR_FORCE=1 gum style --background 214 --foreground 230 "   No   ")"
    btn_no_unsel="$(CLICOLOR_FORCE=1 gum style --background 235 --foreground 254 "   No   ")"

    local help_line
    help_line=$'\033[38;5;241m←→\033[m \033[38;5;239mtoggle\033[38;5;237m • \033[38;5;241menter\033[m \033[38;5;239msubmit\033[38;5;237m • \033[38;5;241my\033[m \033[38;5;239mYes\033[38;5;237m • \033[38;5;241mn\033[m \033[38;5;239mNo\033[m'

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
    help_line=$'\033[38;5;241m↓↑\033[m \033[38;5;239mnavigate\033[38;5;237m • \033[38;5;241menter\033[m \033[38;5;239mselect\033[38;5;237m • \033[38;5;241mq/esc\033[m \033[38;5;239mfinish\033[38;5;237m • \033[38;5;241mtab\033[m \033[38;5;239mswitch between questions\033[m'

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
                    printf "%s\n" "$(CLICOLOR_FORCE=1 gum style --foreground 212 "> ${item_label}")"
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
                    out "$(CLICOLOR_FORCE=1 gum style --foreground 86 "Installing ${prog_name} (${prog_ref})...")"
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
            restore_screen
            CLICOLOR_FORCE=1 gum style --foreground 196 "Script interrupted by user."
            exit 130
        elif (( comp_rc == 1 )); then
            SELECTED_QUESTION_IDX=0
            select_question_menu 0 "Select a question:"
            menu_rc=$?
            if (( menu_rc == 130 )); then
                restore_screen
                CLICOLOR_FORCE=1 gum style --foreground 196 "Script interrupted by user."
                exit 130
            elif (( menu_rc == 2 )); then
                # Cancelled out of questions list while all questions are complete: return to completion prompt
                continue
            fi
            current_q="$SELECTED_QUESTION_IDX"
            force_ask=1
        else
            out "$(CLICOLOR_FORCE=1 gum style --foreground 82 --bold "Script successfully completed.")"
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
            restore_screen
            CLICOLOR_FORCE=1 gum style --foreground 196 "Script interrupted by user."
            exit 130
        fi
        current_q="$SELECTED_QUESTION_IDX"
        continue
    fi

    if (( current_q == 4 )); then
        flatpak_packages_menu
        fp_menu_rc=$?
        if (( fp_menu_rc == 130 )); then
            restore_screen
            CLICOLOR_FORCE=1 gum style --foreground 196 "Script interrupted by user."
            exit 130
        elif (( fp_menu_rc == 2 )); then
            SELECTED_QUESTION_IDX="$current_q"
            select_question_menu "$current_q" "Select a question:"
            menu_rc=$?
            if (( menu_rc == 130 )); then
                restore_screen
                CLICOLOR_FORCE=1 gum style --foreground 196 "Script interrupted by user."
                exit 130
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
            restore_screen
            CLICOLOR_FORCE=1 gum style --foreground 196 "Script interrupted by user."
            exit 130
        elif (( confirm_rc == 2 )); then
            SELECTED_QUESTION_IDX="$current_q"
            select_question_menu "$current_q" "Select a question:"
            menu_rc=$?
            if (( menu_rc == 130 )); then
                restore_screen
                CLICOLOR_FORCE=1 gum style --foreground 196 "Script interrupted by user."
                exit 130
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
        out "$(CLICOLOR_FORCE=1 gum style --foreground 214 "Next question (${next_q_num}/${TOTAL_QUESTIONS}) is answered (${next_state}). To another question...")"
        current_q="$(first_uncompleted_question)"
    fi
done
