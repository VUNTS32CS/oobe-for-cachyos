#!/usr/bin/env bash
set -uo pipefail
export LC_NUMERIC=C

# Ensure gum is installed for modern TUI look
command -v gum >/dev/null 2>&1 || { echo "Error: 'gum' is required for the TUI interface. Install it with: sudo pacman -S gum" >&2; exit 1; }

# Ensure this is an Arch-based / pacman system only
command -v pacman >/dev/null 2>&1 || { gum style --foreground 196 --bold "Error: Only pacman-based distributions are supported."; exit 1; }

# Enter alternate screen buffer (overlay mode without clearing previous terminal text)
OVERLAY_ACTIVE=1
SCREEN_LOG="$(mktemp /tmp/oobe_screen.XXXXXX)"
printf "\033[?1049h\033[H"

# Record persistent output so it can be pasted onto the original terminal screen on exit
gstyle() { CLICOLOR_FORCE=1 gum style "$@"; }
out() { printf "%s\n" "$*" | tee -a "$SCREEN_LOG"; }
out_color() { local c="$1"; shift; out "$(gstyle --foreground "$c" "$@")"; }
out_step() { out "$(gstyle --foreground 214 --bold "[Step $1/$2]") $(gstyle --foreground 15 "$3")"; }
out_spacer() { [[ -s "${SCREEN_LOG:-}" && -n "$(tail -n 1 "$SCREEN_LOG" 2>/dev/null)" ]] && out "" || true; }

collapse_if_prev_skipped() {
    if [[ -s "${SCREEN_LOG:-}" && -z "$(tail -n 1 "$SCREEN_LOG" 2>/dev/null)" && "$(tail -n 2 "$SCREEN_LOG" 2>/dev/null | head -n 1)" == *"Skipped "* ]]; then
        printf "\033[1A\r\033[J"
        sed -i '$d' "$SCREEN_LOG"
    fi
}
out_skipped() { collapse_if_prev_skipped; out_color 243 "$1"; }

restore_screen() {
    printf "\033[?7h\033[?25h"
    if [[ "${OVERLAY_ACTIVE:-0}" -eq 1 ]]; then
        printf "\033[?1049l"
        OVERLAY_ACTIVE=0
        [[ -f "${SCREEN_LOG:-}" ]] && { cat "$SCREEN_LOG"; rm -f "$SCREEN_LOG"; }
    fi
}

handle_sigint() { restore_screen; gstyle --foreground 196 "Exited."; exit 130; }
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
    [[ -r /sys/class/dmi/id/chassis_type ]] && chassis_type=$(< /sys/class/dmi/id/chassis_type)
    # SMBIOS chassis types for laptops/portables:
    # 8: Portable, 9: Laptop, 10: Notebook, 11: Hand Held, 14: Sub Notebook,
    # 30: Tablet, 31: Convertible, 32: Detachable
    case "$chassis_type" in
        8|9|10|11|14|30|31|32) echo "Laptop"; return ;;
        3|4|5|6|7|13|15|16|24|34|35|36) echo "Desktop"; return ;;
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
    local wait_us=$(( $2 - ($3 - 1) * 1000000 ))
    (( wait_us < 1000 )) && wait_us=1000
    printf -v _out_timeout "%d.%06d" $(( wait_us / 1000000 )) $(( wait_us % 1000000 ))
}

# Countdown before executing or skipping a process.
# Returns 0 if the countdown finishes (or Enter is pressed),
# Returns 1 if the user presses Q/q to cancel and change their opinion.
countdown_action() {
    local action_prefix="$1" end_us=$(( ${EPOCHREALTIME/./} + 5 * 1000000 )) last_sec=-1 key="" rest="" timeout_str="" main_text=""
    local indicator="$(gstyle --foreground 214 --bold "[!]")"
    local paren_text="$(gstyle --foreground 243 "(Q to change opinion, Ctrl + C to exit or Enter to skip countdown)")"
    # Disable terminal line auto-wrap (DECAWM) and save cursor position so
    # shrinking the terminal or wrapping lines never causes new lines on refresh.
    printf "\033[?7l\033[s"
    while true; do
        local rem_us=$(( end_us - ${EPOCHREALTIME/./} ))
        (( rem_us <= 0 )) && break
        local seconds=$(( (rem_us + 999999) / 1000000 ))
        if (( seconds != last_sec )); then
            main_text="$(gstyle --foreground 15 "${action_prefix} in [${seconds}] seconds")"
            printf "\033[u\r\033[J%s %s %s" "$indicator" "$main_text" "$paren_text"
            last_sec=$seconds
        fi
        set_next_tick_timeout timeout_str "$rem_us" "$seconds"
        if IFS= read -r -s -n 1 -t "$timeout_str" key; then
            if [[ -z "$key" ]]; then
                # User pressed Enter: skip remaining countdown
                printf "\033[?7h\n"; printf "%s %s %s\n" "$indicator" "$main_text" "$paren_text" >> "$SCREEN_LOG"; return 0
            elif [[ "$key" == [qQ] ]]; then
                # User pressed Q: cancel and re-ask question
                printf "\033[?7h\n"; printf "%s %s %s\n" "$indicator" "$main_text" "$paren_text" >> "$SCREEN_LOG"
                out_color 214 "Action cancelled. Returning to question..."; return 1
            elif [[ "$key" == $'\x1b' ]]; then
                IFS= read -r -s -n 2 -t 0.01 rest || true
            fi
        fi
    done
    printf "\033[?7h\n"; printf "%s %s %s\n" "$indicator" "$main_text" "$paren_text" >> "$SCREEN_LOG"; return 0
}

OS_NAME="$(detect_os)"
PLATFORM="$(detect_platform)"

# Echo detected OS and Platform in the purple box before the first question
gstyle --border rounded --padding "0 2" --margin "1 0" --border-foreground 99 \
    "Detected OS: ${OS_NAME}" "Detected Platform: ${PLATFORM}" | tee -a "$SCREEN_LOG"

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

FLATPAK_NAMES=("Sober" "Easy Effects" "OBS Studio" "Wayland Hotkeys" "Vinegar")
FLATPAK_REFS=(
    "app/org.vinegarhq.Sober/x86_64/stable"
    "com.github.wwmm.easyeffects"
    "com.obsproject.Studio"
    "com.obsproject.Studio.Plugin.WaylandHotkeys"
    "org.vinegarhq.Vinegar"
)
TOTAL_FLATPAKS=${#FLATPAK_NAMES[@]}
FLATPAK_STATUS=(0 0 0 0 0) # 0 = Unanswered, 1 = Installed, 2 = Skipped
OBS_EXPANDED=0

update_flatpak_question_status() {
    local any_installed=0 all_answered=1 i
    for (( i = 0; i < TOTAL_FLATPAKS; i++ )); do
        (( FLATPAK_STATUS[i] == 1 )) && any_installed=1
        (( FLATPAK_STATUS[i] == 0 )) && all_answered=0
    done
    if (( any_installed == 1 )); then COMPLETED[4]=1
    elif (( all_answered == 1 )); then COMPLETED[4]=2; fi
}

# Helper to format a question prompt with the orange [n/total] prefix
format_question_prompt() { printf "%s %s" "$(gstyle --foreground 214 "[$1/${TOTAL_QUESTIONS}]")" "$2"; }

# Interactive Gum-styled confirmation widget with TAB support and custom gray key guide:
# Return codes:
#   0 = Yes
#   1 = No
#   2 = TAB pressed (open question switcher)
# 130 = Ctrl + C (interrupted by user)
gum_confirm_with_tab() {
    local prompt_text="$1" allow_tab="${2:-1}" key="" rest="" prompt_styled help_line
    local selected=0 # 0 = Yes (default), 1 = No
    local btn_yes_sel="$(gstyle --background 214 --foreground 15 "   Yes   ")"
    local btn_yes_unsel="$(gstyle --background 235 --foreground 243 "   Yes   ")"
    local btn_no_sel="$(gstyle --background 214 --foreground 15 "   No   ")"
    local btn_no_unsel="$(gstyle --background 235 --foreground 243 "   No   ")"
    if (( allow_tab == 1 )); then
        prompt_styled="$(gstyle --foreground 99 --bold "$prompt_text")"
        help_line=$'\033[38;5;15m←→\033[m \033[38;5;243mtoggle • \033[38;5;15menter\033[m \033[38;5;243msubmit • \033[38;5;15my\033[m \033[38;5;243mYes • \033[38;5;15mn\033[m \033[38;5;243mNo • \033[38;5;15mtab\033[m \033[38;5;243mswitch between questions\033[m'
    else
        prompt_styled="$(gstyle --foreground 15 "$prompt_text")"
        help_line=$'\033[38;5;15m←→\033[m \033[38;5;243mtoggle • \033[38;5;15menter\033[m \033[38;5;243msubmit • \033[38;5;15my\033[m \033[38;5;243mYes • \033[38;5;15mn\033[m \033[38;5;243mNo\033[m'
    fi
    # Reserve 5 lines and save cursor position at the top of the widget
    printf "\n\n\n\n\n\033[5A\033[s\033[?25l"
    while true; do
        local buttons_line=" ${btn_yes_unsel}  ${btn_no_sel}"
        (( selected == 0 )) && buttons_line=" ${btn_yes_sel}  ${btn_no_unsel}"
        printf "\033[u\r\033[J %s\n\n%s\n\n%s" "$prompt_styled" "$buttons_line" "$help_line"
        IFS= read -r -s -n 1 key || { printf "\033[u\r\033[J\033[?25h"; return 130; }
        case "$key" in
            "")
                # Enter pressed
                printf "\033[u\r\033[J\033[?25h"; return "$selected" ;;
            $'\t')
                # Tab pressed
                (( allow_tab == 1 )) && { printf "\033[u\r\033[J\033[?25h"; return 2; }
                selected=$(( 1 - selected )) ;;
            [yY]) printf "\033[u\r\033[J\033[?25h"; return 0 ;;
            [nN]) printf "\033[u\r\033[J\033[?25h"; return 1 ;;
            $'\x03')
                # Ctrl+C
                printf "\033[u\r\033[J\033[?25h"; return 130 ;;
            [hHlL]) selected=$(( 1 - selected )) ;;
            $'\x1b')
                IFS= read -r -s -n 2 -t 0.05 rest || true
                case "$rest" in
                    "[C"|"[D") selected=$(( 1 - selected )) ;;
                    "[Z")
                        # Shift+Tab
                        (( allow_tab == 1 )) && { printf "\033[u\r\033[J\033[?25h"; return 2; }
                        selected=$(( 1 - selected )) ;;
                esac ;;
        esac
    done
}

run_list_menu() {
    local header_line="$1" help_line="$2" allow_q="$4" key="" rest="" i
    local -n _cursor="$3"
    shift 4
    local labels=("$@") count=${#labels[@]} menu_height=$(( ${#labels[@]} + 4 ))
    for (( i = 0; i < menu_height; i++ )); do printf "\n"; done
    printf "\033[%dA\033[s\033[?25l" "$menu_height"
    while true; do
        printf "\033[u\r\033[J%s\n" "$header_line"
        for (( i = 0; i < count; i++ )); do
            if (( i == _cursor )); then printf "%s\n" "$(gstyle --foreground 214 "> ${labels[i]}")"
            else printf "  %s\n" "${labels[i]}"; fi
        done
        printf "\n%s" "$help_line"
        IFS= read -r -s -n 1 key || { printf "\033[u\r\033[J\033[?25h"; return 130; }
        case "$key" in
            "") printf "\033[u\r\033[J\033[?25h"; return 0 ;;
            " ") (( allow_q == 1 && _cursor == 2 )) && { printf "\033[u\r\033[J\033[?25h"; return 4; } ;;
            $'\t') printf "\033[u\r\033[J\033[?25h"; return 2 ;;
            [qQ]) (( allow_q == 1 )) && { printf "\033[u\r\033[J\033[?25h"; return 3; } ;;
            $'\x03') printf "\033[u\r\033[J\033[?25h"; return 130 ;;
            [kK]) _cursor=$(( (_cursor - 1 + count) % count )) ;;
            [jJ]) _cursor=$(( (_cursor + 1) % count )) ;;
            $'\x1b')
                IFS= read -r -s -n 2 -t 0.05 rest || true
                case "$rest" in
                    "[A") _cursor=$(( (_cursor - 1 + count) % count )) ;;
                    "[B") _cursor=$(( (_cursor + 1) % count )) ;;
                    "[Z") printf "\033[u\r\033[J\033[?25h"; return 2 ;;
                    "") printf "\033[u\r\033[J\033[?25h"; (( allow_q == 1 )) && return 3 || return 2 ;;
                esac ;;
        esac
    done
}

# Interactive question selector shown when TAB is pressed or when the last question is answered.
# Navigatable with Up/Down arrow keys; pressing Enter selects the question to jump to.
select_question_menu() {
    local current_idx="$1" cursor="$1" i labels=() status_suffix rc
    local header_line="$(gstyle --foreground 99 --bold "${2:-Select a question:}")"
    local help_line=$'\033[38;5;15m↓↑\033[m \033[38;5;243mnavigate • \033[38;5;15menter\033[m \033[38;5;243msubmit • \033[38;5;15mtab/esc\033[m \033[38;5;243mcancel\033[m'
    for (( i = 0; i < TOTAL_QUESTIONS; i++ )); do
        status_suffix=""
        (( COMPLETED[i] == 1 )) && status_suffix=" (Applied)"
        (( COMPLETED[i] == 2 )) && status_suffix=" (Skipped)"
        labels+=("[$(( i + 1 ))/${TOTAL_QUESTIONS}] ${QUESTIONS[i]}${status_suffix}")
    done
    run_list_menu "$header_line" "$help_line" cursor 0 "${labels[@]}"; rc=$?
    if (( rc == 0 )); then
        # Enter pressed: jump to selected question
        SELECTED_QUESTION_IDX="$cursor"; return 0
    elif (( rc == 2 )); then
        SELECTED_QUESTION_IDX="$current_idx"; return 2
    fi
    return "$rc"
}

remove_pkg_if_installed() {
    if pacman -Qq "$1" >/dev/null 2>&1; then
        out_color 99 "Removing package: $1"
        sudo pacman -Rnsdd --noconfirm "$1" 2>&1 | tee -a "$SCREEN_LOG"
    else
        out_color 243 "$1 is not installed. Skipping removal."
    fi
}

import_cfg_file() {
    local src="$1" dst_dir="$2" name="$3" warn="${4:-1}"
    if [[ -f "$src" ]]; then
        mkdir -p "$dst_dir"; cp -f "$src" "$dst_dir/$name"
        out_color 99 "Imported ${name} to ${dst_dir}/${name}."
    elif (( warn == 1 )); then
        out_color 214 "assets/${platform_dir}/${name} not found in repository. Skipping ${name%%[-.]*} import."
    fi
}

execute_question() {
    local q_idx="$1" user_choice="$2"
    case "$q_idx" in
        0)
            # Question 1: Make package changes?
            if [[ "$user_choice" == "Y" ]]; then
                local total_steps=2 keep_pat='linux-firmware-(other|realtek|intel)'
                if [[ "$PLATFORM" == "Desktop" ]]; then keep_pat='linux-firmware-(amd|other|realtek|nvidia|whence)'; else total_steps=4; fi
                out_step 1 "$total_steps" "Removing unneeded linux-firmware packages..."
                out_color 99 "Searching for installed linux-firmware packages..."
                mapfile -t installed_fw < <(pacman -Qq | grep -E '^linux-firmware' || true)
                pkgs_to_remove=()
                for pkg in "${installed_fw[@]}"; do [[ "$pkg" =~ ^${keep_pat}$ ]] || pkgs_to_remove+=("$pkg"); done
                if (( ${#pkgs_to_remove[@]} > 0 )); then
                    out_color 99 "Removing packages: ${pkgs_to_remove[*]}"
                    sudo pacman -Rndd --noconfirm "${pkgs_to_remove[@]}" 2>&1 | tee -a "$SCREEN_LOG"
                else
                    out_color 243 "No unneeded linux-firmware packages found to remove."
                fi
                out_step 2 "$total_steps" "Uninstalling plasma-thunderbolt and kdeconnect..."
                remove_pkg_if_installed plasma-thunderbolt
                remove_pkg_if_installed kdeconnect
                if [[ "$PLATFORM" == "Laptop" ]]; then
                    out_step 3 "$total_steps" "Uninstalling kitty and installing foot..."
                    remove_pkg_if_installed kitty
                    out_color 99 "Installing package: foot"
                    sudo pacman -S --needed --noconfirm foot 2>&1 | tee -a "$SCREEN_LOG"
                    out_step 4 "$total_steps" "Installing and enabling TLP..."
                    out_color 99 "Installing packages: tlp tlp-rdw tlp-pd"
                    sudo pacman -S --needed --noconfirm tlp tlp-rdw tlp-pd 2>&1 | tee -a "$SCREEN_LOG"
                    out_color 99 "Enabling TLP and TLP-PD services..."
                    sudo systemctl enable --now tlp tlp-pd 2>&1 | tee -a "$SCREEN_LOG"
                fi
            else
                out_skipped "Skipped package changes."
            fi ;;
        1)
            # Question 2: Stop Bluetooth from starting at startup?
            if [[ "$user_choice" == "Y" ]]; then
                local bt_conf="/etc/bluetooth/main.conf"
                if [[ -f "$bt_conf" ]]; then
                    if grep -Eq '^[[:space:]]*#?[[:space:]]*AutoEnable[[:space:]]*=' "$bt_conf"; then
                        sudo sed -i -E 's/^[[:space:]]*#?[[:space:]]*AutoEnable[[:space:]]*=.*/AutoEnable = false/' "$bt_conf"
                    elif grep -Eq '^[[:space:]]*\[Policy\]' "$bt_conf"; then
                        sudo sed -i -E '/^[[:space:]]*\[Policy\]/a AutoEnable = false' "$bt_conf"
                    else
                        printf "\n[Policy]\nAutoEnable = false\n" | sudo tee -a "$bt_conf" >/dev/null
                    fi
                    out_color 99 "Set AutoEnable = false in ${bt_conf}."
                else
                    out_color 214 "${bt_conf} not found. Skipping."
                fi
            else
                out_skipped "Skipped disabling Bluetooth AutoEnable."
            fi ;;
        2)
            # Question 3: Modify ZRAM?
            if [[ "$user_choice" == "Y" ]]; then
                local zram_conf="/etc/systemd/zram-generator.conf" zram_algo="lz4"
                [[ "$PLATFORM" == "Desktop" ]] && zram_algo="zstd"
                sudo mkdir -p /etc/systemd
                printf "[zram0]\nzram-size = ram/4\ncompression-algorithm = %s\nfs-type = swap\nswap-priority = 100\n" "$zram_algo" | sudo tee "$zram_conf" >/dev/null
                out_color 99 "Updated ${zram_conf}."
            else
                out_skipped "Skipped ZRAM modification."
            fi ;;
        3)
            # Question 4: Hard-blacklist unnecessary kernel modules from starting?
            if [[ "$user_choice" == "Y" ]]; then
                local blacklist_conf="/etc/modprobe.d/blacklists.conf" hard_mods soft_mods=()
                if [[ "$PLATFORM" == "Desktop" ]]; then
                    hard_mods=(pcspkr sp5100_tco eeepc_wmi asus_wmi sparse_keymap rfkill mac_hid mousedev joydev ccp gpio_amdpt gpio_generic ee1004 snd_hda_codec_atihdmi)
                    soft_mods=(nouveau nova_core nova_drm)
                else
                    hard_mods=(mei mei_me mei_hdcp mei_pxp intel_vsec pmt_telemetry pmt_discovery pmt_class intel_pmc_core intel_pmc_ssram_telemetry intel_pmc_pwrm_telemetry intel_oc_wdt)
                fi
                sudo mkdir -p /etc/modprobe.d
                {
                    printf "blacklist %s\n" "${hard_mods[@]}"
                    (( ${#soft_mods[@]} > 0 )) && printf "blacklist %s\n" "${soft_mods[@]}"
                    printf "install %s /bin/false\n" "${hard_mods[@]}"
                } | sudo tee "$blacklist_conf" >/dev/null
                out_color 99 "Updated ${blacklist_conf}."
            else
                out_skipped "Skipped kernel module blacklisting."
            fi ;;
        5)
            # Question 6: Import configurations?
            if [[ "$user_choice" == "Y" ]]; then
                local has_hyprland=0
                if pacman -Qq hyprland >/dev/null 2>&1 || command -v Hyprland >/dev/null 2>&1 || command -v hyprctl >/dev/null 2>&1; then
                    has_hyprland=1
                fi
                if (( has_hyprland == 1 )); then
                    local platform_dir="laptop" tmp_dotfiles pull_ok=0 src_assets foot_warn=1
                    [[ "$PLATFORM" == "Desktop" ]] && { platform_dir="desktop"; foot_warn=0; }
                    out_color 99 "Pulling configurations (${platform_dir}) from GitHub..."
                    tmp_dotfiles="$(mktemp -d /tmp/oobe_dotfiles.XXXXXX)"
                    if command -v git >/dev/null 2>&1; then
                        git clone --depth 1 https://github.com/vunts32cs/oobe-for-cachyos.git "$tmp_dotfiles/repo" 2>&1 | tee -a "$SCREEN_LOG" && pull_ok=1
                    elif command -v curl >/dev/null 2>&1; then
                        mkdir -p "$tmp_dotfiles/repo"
                        curl -fsSL https://github.com/vunts32cs/oobe-for-cachyos/archive/refs/heads/main.tar.gz | tar -xz -C "$tmp_dotfiles/repo" --strip-components=1 2>&1 | tee -a "$SCREEN_LOG" && pull_ok=1
                    else
                        out_color 196 "Error: Neither git nor curl is available to pull dotfiles from GitHub."
                    fi
                    if (( pull_ok == 1 )); then
                        src_assets="$tmp_dotfiles/repo/assets/$platform_dir"
                        if [[ -d "$src_assets/hypr" ]]; then
                            mkdir -p "$HOME/.config"; rm -rf "$HOME/.config/hypr"; cp -r "$src_assets/hypr" "$HOME/.config/hypr"
                            out_color 99 "Imported hypr folder to $HOME/.config/hypr."
                        else
                            out_color 214 "assets/${platform_dir}/hypr not found in repository. Skipping hypr import."
                        fi
                        import_cfg_file "$src_assets/noctalia-config.toml" "$HOME/.config/noctalia" "noctalia-config.toml" 1
                        import_cfg_file "$src_assets/foot.ini" "$HOME/.config/foot" "foot.ini" "$foot_warn"
                    elif command -v git >/dev/null 2>&1 || command -v curl >/dev/null 2>&1; then
                        out_color 196 "Failed to pull dotfiles from GitHub."
                    fi
                    rm -rf "$tmp_dotfiles"
                else
                    out_color 243 "Hyprland is not installed. Skipping Hyprland configuration import."
                fi
                mkdir -p "$HOME/.config/autostart"
                printf "[Desktop Entry]\nHidden=true\n" > "$HOME/.config/autostart/arch-update-tray.desktop"
                out_color 99 "Updated $HOME/.config/autostart/arch-update-tray.desktop."
                if (( has_hyprland == 1 )) && command -v hyprctl >/dev/null 2>&1; then
                    out_color 99 "Reloading Hyprland configuration..."
                    hyprctl reload 2>&1 | tee -a "$SCREEN_LOG"
                fi
            else
                out_skipped "Skipped importing configurations."
            fi ;;
    esac
}

get_countdown_prefix() {
    case "$1:$2" in
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

all_questions_completed() { local i; for (( i = 0; i < TOTAL_QUESTIONS; i++ )); do (( COMPLETED[i] == 0 )) && return 1; done; return 0; }
any_question_applied() { local i; for (( i = 0; i < TOTAL_QUESTIONS; i++ )); do (( COMPLETED[i] == 1 )) && return 0; done; return 1; }
first_uncompleted_question() { local i; for (( i = 0; i < TOTAL_QUESTIONS; i++ )); do (( COMPLETED[i] == 0 )) && { echo "$i"; return 0; }; done; echo 0; }

# Completion prompt shown when all questions are completed:
# "Script complete. Automatically exiting in 10s." with options:
#   0 = "Okay"
#   1 = "Go back to the questions list"
# 130 = Ctrl + C
completion_prompt() {
    local selected=0 end_us=$(( ${EPOCHREALTIME/./} + 10 * 1000000 )) last_sec=-1 last_selected=-1 key="" rest="" timeout_str="" reboot_suffix=""
    local btn_ok_sel="$(gstyle --background 214 --foreground 15 "   Okay   ")"
    local btn_ok_unsel="$(gstyle --background 235 --foreground 243 "   Okay   ")"
    local btn_back_sel="$(gstyle --background 214 --foreground 15 "   Go back to the questions list   ")"
    local btn_back_unsel="$(gstyle --background 235 --foreground 243 "   Go back to the questions list   ")"
    local help_line=$'\033[38;5;15m←→\033[m \033[38;5;243mtoggle • \033[38;5;15menter\033[m \033[38;5;243msubmit\033[m'
    any_question_applied && reboot_suffix=" $(gstyle --foreground 196 "Reboot required.")"
    printf "\n\n\n\n\n\033[5A\033[s\033[?7l\033[?25l"
    while true; do
        local rem_us=$(( end_us - ${EPOCHREALTIME/./} ))
        (( rem_us <= 0 )) && break
        local seconds=$(( (rem_us + 999999) / 1000000 ))
        if (( seconds != last_sec || selected != last_selected )); then
            local prompt_styled="$(gstyle --foreground 99 --bold "Script complete. Automatically exiting in ${seconds}s.")${reboot_suffix}"
            local buttons_line=" ${btn_ok_unsel}  ${btn_back_sel}"
            (( selected == 0 )) && buttons_line=" ${btn_ok_sel}  ${btn_back_unsel}"
            printf "\033[u\r\033[J %s\n\n%s\n\n%s" "$prompt_styled" "$buttons_line" "$help_line"
            last_sec=$seconds; last_selected=$selected
        fi
        set_next_tick_timeout timeout_str "$rem_us" "$seconds"
        if IFS= read -r -s -n 1 -t "$timeout_str" key; then
            case "$key" in
                "") printf "\033[u\r\033[J\033[?7h\033[?25h"; return "$selected" ;;
                $'\x03') printf "\033[u\r\033[J\033[?7h\033[?25h"; return 130 ;;
                $'\t'|[hHlL]) selected=$(( 1 - selected )) ;;
                $'\x1b')
                    IFS= read -r -s -n 2 -t 0.01 rest || true
                    [[ "$rest" == "[C" || "$rest" == "[D" || "$rest" == "[Z" ]] && selected=$(( 1 - selected )) ;;
            esac
        fi
    done
    printf "\033[u\r\033[J\033[?7h\033[?25h"; return 0
}

# Interactive Gum-styled Yes/No prompt (no Tab switcher) for sub-prompts:
# Return codes:
#   0 = Yes
#   1 = No
# 130 = Ctrl + C (interrupted by user)
gum_confirm_simple() { gum_confirm_with_tab "$1" 0; } # 0 = Yes (default), 1 = No

# Interactive Flatpak packages selector for Question 5:
# Return codes:
#   0 = Finished Flatpak packages menu (q/Esc)
#   2 = TAB pressed (open question switcher)
# 130 = Ctrl + C (interrupted by user)
flatpak_packages_menu() {
    local cursor=0 i prefix status_suffix rc pkg_idx
    local header_line="$(gstyle --foreground 99 --bold "$(format_question_prompt 5 "${QUESTIONS[4]}")")"
    local help_line=$'\033[38;5;15m↓↑\033[m \033[38;5;243mnavigate • \033[38;5;15menter\033[m \033[38;5;243mselect • \033[38;5;15mspace\033[m \033[38;5;243mexpand/collapse • \033[38;5;15mq/esc\033[m \033[38;5;243mfinish • \033[38;5;15mtab\033[m \033[38;5;243mswitch between questions\033[m'
    while true; do
        local labels=() visible_indices=()
        for (( i = 0; i < TOTAL_FLATPAKS; i++ )); do
            (( i == 3 && OBS_EXPANDED == 0 )) && continue
            prefix=""
            if (( i == 2 )); then
                (( OBS_EXPANDED == 1 )) && prefix="[-] " || prefix="[+] "
            elif (( i == 3 )); then
                prefix="  - "
            fi
            status_suffix=""
            (( FLATPAK_STATUS[i] == 1 )) && status_suffix=" (Installed)"
            (( FLATPAK_STATUS[i] == 2 )) && status_suffix=" (Skipped)"
            visible_indices+=("$i")
            labels+=("${prefix}${FLATPAK_NAMES[i]} (${FLATPAK_REFS[i]})${status_suffix}")
        done
        run_list_menu "$header_line" "$help_line" cursor 1 "${labels[@]}"; rc=$?
        (( rc == 4 )) && { OBS_EXPANDED=$(( 1 - OBS_EXPANDED )); continue; }
        (( rc == 3 )) && return 0
        (( rc != 0 )) && return "$rc"
        pkg_idx="${visible_indices[cursor]}"
        local prog_name="${FLATPAK_NAMES[pkg_idx]}" prog_ref="${FLATPAK_REFS[pkg_idx]}"
        while true; do
            gum_confirm_simple "Install ${prog_name}?"
            local fp_rc=$?
            if (( fp_rc == 130 )); then return 130
            elif (( fp_rc == 1 )); then FLATPAK_STATUS[pkg_idx]=2; update_flatpak_question_status; break
            else
                countdown_action "Will install ${prog_name}" || continue
                out_color 99 "Installing ${prog_name} (${prog_ref})..."
                flatpak install -y flathub "$prog_ref" 2>&1 | tee -a "$SCREEN_LOG"
                FLATPAK_STATUS[pkg_idx]=1; update_flatpak_question_status; break
            fi
        done
    done
}

jump_to_question() {
    local idx="$1" header="${2:-Select a question:}" menu_rc
    SELECTED_QUESTION_IDX="$idx"
    select_question_menu "$idx" "$header"
    menu_rc=$?
    (( menu_rc == 130 )) && handle_sigint
    (( menu_rc == 2 )) && all_questions_completed && return 1
    current_q="$SELECTED_QUESTION_IDX"
    all_questions_completed && force_ask=1
    return 0
}

current_q=0
force_ask=0
while true; do
    if (( force_ask == 0 )) && all_questions_completed; then
        completion_prompt
        comp_rc=$?
        if (( comp_rc == 130 )); then handle_sigint
        elif (( comp_rc == 1 )); then
            # Cancelled out of questions list while all questions are complete: return to completion prompt
            jump_to_question 0 || continue
        else
            final_msg="$(gstyle --foreground 99 --bold "Script completed.")"
            any_question_applied && final_msg="${final_msg} $(gstyle --foreground 196 "Reboot required.")"
            out "$final_msg"
            break
        fi
    fi
    force_ask=0

    if (( current_q >= TOTAL_QUESTIONS )); then
        jump_to_question "$(first_uncompleted_question)" "Last question answered. Select a question:" || true
        continue
    fi

    if (( current_q == 4 )); then
        flatpak_packages_menu
        fp_menu_rc=$?
        (( fp_menu_rc == 130 )) && handle_sigint
        if (( fp_menu_rc == 2 )); then
            jump_to_question "$current_q" || true
            continue
        fi
        (( COMPLETED[4] == 0 )) && COMPLETED[4]=2
    else
        gum_confirm_with_tab "$(format_question_prompt $(( current_q + 1 )) "${QUESTIONS[current_q]}")"
        confirm_rc=$?
        if (( confirm_rc == 130 )); then handle_sigint
        elif (( confirm_rc == 2 )); then
            # Backed out of questions list while all questions are complete: show completion message
            jump_to_question "$current_q" || true
            continue
        fi
        user_choice="N"; (( confirm_rc == 0 )) && user_choice="Y"
        if [[ "$user_choice" == "Y" ]]; then
            countdown_action "$(get_countdown_prefix "$current_q" "$user_choice")" || continue
            execute_question "$current_q" "$user_choice"
            COMPLETED[current_q]=1
        else
            execute_question "$current_q" "$user_choice"
            COMPLETED[current_q]=2
        fi
    fi

    (( current_q++ ))
    if (( current_q < TOTAL_QUESTIONS && COMPLETED[current_q] != 0 )) && ! all_questions_completed; then
        next_state="Skipped"; (( COMPLETED[current_q] == 1 )) && next_state="Applied"
        out "$(gstyle --foreground 99 --bold "Next question ($(( current_q + 1 ))/${TOTAL_QUESTIONS}) is answered (${next_state}). To another question...")"
        current_q="$(first_uncompleted_question)"
    fi
    out_spacer
done
