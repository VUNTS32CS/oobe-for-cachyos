#!/usr/bin/env bash
set -uo pipefail

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

# Countdown before executing or skipping a process.
# Returns 0 if the countdown finishes (or Enter is pressed),
# Returns 1 if the user presses Q/q to cancel and change their opinion.
countdown_action() {
    local action_prefix="$1"
    local seconds=6
    local key=""

    # Disable terminal line auto-wrap (DECAWM) and save cursor position so
    # shrinking the terminal or wrapping lines never causes new lines on refresh.
    printf "\033[?7l\033[s"

    while (( seconds > 0 )); do
        local indicator
        local main_text
        local paren_text
        indicator="$(CLICOLOR_FORCE=1 gum style --foreground 214 --bold "[!]")"
        main_text="$(CLICOLOR_FORCE=1 gum style --foreground 15 "${action_prefix} in [${seconds}] seconds")"
        paren_text="$(CLICOLOR_FORCE=1 gum style --foreground 243 "(Q to change opinion, Ctrl + C to exit or Enter to skip countdown)")"
        printf "\033[u\r\033[J%s %s %s" "$indicator" "$main_text" "$paren_text"

        if IFS= read -r -s -n 1 -t 1 key; then
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
            fi
        fi
        (( seconds-- ))
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
)
TOTAL_QUESTIONS=${#QUESTIONS[@]}
COMPLETED=(0 0 0 0)

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
                if [[ "$PLATFORM" == "Desktop" ]]; then
                    out "$(CLICOLOR_FORCE=1 gum style --foreground 196 --bold "Desktop platform detected. Stopping and exiting the script.")"
                    exit 0
                elif [[ "$PLATFORM" == "Laptop" ]]; then
                    out "$(CLICOLOR_FORCE=1 gum style --foreground 86 "Searching for installed linux-firmware packages...")"
                    mapfile -t installed_fw < <(pacman -Qq | grep -E '^linux-firmware' || true)

                    pkgs_to_remove=()
                    for pkg in "${installed_fw[@]}"; do
                        case "$pkg" in
                            linux-firmware-other|linux-firmware-realtek|linux-firmware-intel)
                                # Keep these packages
                                ;;
                            *)
                                pkgs_to_remove+=("$pkg")
                                ;;
                        esac
                    done

                    if (( ${#pkgs_to_remove[@]} > 0 )); then
                        out "$(CLICOLOR_FORCE=1 gum style --foreground 214 "Removing packages: ${pkgs_to_remove[*]}")"
                        sudo pacman -Rdd --noconfirm "${pkgs_to_remove[@]}" 2>&1 | tee -a "$SCREEN_LOG"
                    else
                        out "$(CLICOLOR_FORCE=1 gum style --foreground 86 "No unneeded linux-firmware packages found to remove.")"
                    fi
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
                sudo mkdir -p /etc/systemd
                sudo tee "$zram_conf" >/dev/null <<'EOF'
[zram0]
zram-size = ram/4
compression-algorithm = lz4
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
    local seconds=10
    local key=""
    local rest=""

    local btn_ok_sel btn_ok_unsel btn_back_sel btn_back_unsel
    btn_ok_sel="$(CLICOLOR_FORCE=1 gum style --background 214 --foreground 230 "   Okay   ")"
    btn_ok_unsel="$(CLICOLOR_FORCE=1 gum style --background 235 --foreground 254 "   Okay   ")"
    btn_back_sel="$(CLICOLOR_FORCE=1 gum style --background 214 --foreground 230 "   Go back to the questions list   ")"
    btn_back_unsel="$(CLICOLOR_FORCE=1 gum style --background 235 --foreground 254 "   Go back to the questions list   ")"

    local help_line
    help_line=$'\033[38;5;241m←→\033[m \033[38;5;239mtoggle\033[38;5;237m • \033[38;5;241menter\033[m \033[38;5;239msubmit\033[m'

    printf "\n\n\n\n\n\033[5A\033[s\033[?7l\033[?25l"

    while (( seconds > 0 )); do
        local prompt_styled
        prompt_styled="$(CLICOLOR_FORCE=1 gum style --foreground 99 --bold "Script complete. Automatically exiting in ${seconds}s.")"

        local buttons_line
        if (( selected == 0 )); then
            buttons_line=" ${btn_ok_sel}  ${btn_back_unsel}"
        else
            buttons_line=" ${btn_ok_unsel}  ${btn_back_sel}"
        fi

        printf "\033[u\r\033[J %s\n\n%s\n\n%s" "$prompt_styled" "$buttons_line" "$help_line"

        if IFS= read -r -s -n 1 -t 1 key; then
            if [[ -z "$key" ]]; then
                printf "\033[u\r\033[J\033[?7h\033[?25h"
                return "$selected"
            elif [[ "$key" == $'\x03' ]]; then
                printf "\033[u\r\033[J\033[?7h\033[?25h"
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
        else
            (( seconds-- ))
        fi
    done

    printf "\033[u\r\033[J\033[?7h\033[?25h"
    return 0
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
