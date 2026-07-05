 #!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
#  MOTO_ROOT – v3.5 (FINAL)
#  ============================================================================
#  Purpose : Root Motorola G 2022 from an unrooted android (originally used a Pixel 9a) inside of Termux! 
#  Security : HTTPS enforced, TLS 1.2+, automatic SHA‑256 verification,
#             unlock code masked, pre‑flight guide.
#  Resilience : State tracking, flash retries, boot‑image magic check,
#               safe_read, flash error capture, log rotation, selective extraction.
#  Usage    : ./motoroot.sh [--restore|--reset-state|--debug|--skip-checksum|--help]
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# ---------- Colours ----------
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'
readonly BOLD='\033[1m'

# ---------- Logging with Rotation ----------
LOG_FILE="${HOME}/motoroot_.log"
MAX_LOG_SIZE=$((5 * 1024 * 1024))   # 5 MB
if [[ -f "$LOG_FILE" && $(stat -c%s "$LOG_FILE") -gt $MAX_LOG_SIZE ]]; then
    mv "$LOG_FILE" "${LOG_FILE}.old"
fi
exec > >(tee -a "$LOG_FILE") 2>&1

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()  { echo -e "${BLUE}[STEP]${NC} $*"; }
log_debug() { if [[ "${DEBUG:-0}" -eq 1 ]]; then echo -e "${CYAN}[DEBUG]${NC} $*"; fi; }
log_done()  { echo -e "${GREEN}[✓]${NC} $*"; }

# ---------- Global overrides ----------
SKIP_CHECKSUM=false

# ---------- Safe Read (handles EOF, Ctrl+D, no backslash mangling) ----------
_safe_read() {
    local prompt="$1"
    local var_name="$2"
    local default="${3:-}"
    local -n var_ref="$var_name"
    local input=""
    set +e
    read -r -p "$prompt" input
    local rc=$?
    set -e
    if [[ $rc -ne 0 ]]; then
        log_warn "Input aborted (Ctrl+D). Using default: ${default:-<empty>}"
        if [[ -n "$default" ]]; then
            var_ref="$default"
        else
            var_ref=""
        fi
        return 0
    fi
    if [[ -z "$input" && -n "$default" ]]; then
        var_ref="$default"
    else
        var_ref="$input"
    fi
}

# ---------- Configuration ----------
readonly WORKDIR="${HOME}/moto_root"
readonly STATE_FILE="${WORKDIR}/state.txt"
readonly FIRMWARE_ZIP="${WORKDIR}/firmware.zip"
readonly BOOT_IMG="${WORKDIR}/boot.img"
readonly VBMETA_IMG="${WORKDIR}/vbmeta.img"
readonly PATCHED_IMG="${WORKDIR}/magisk_patched.img"
readonly MAX_RETRIES=3
readonly RETRY_DELAY=3
readonly TIMEOUT=60
readonly CONNECT_TIMEOUT=15
readonly MOTO_VENDOR_ID="0x22b8"

readonly -a MIRRORS=(
    "https://mirrors.lolinet.com/firmware/lenomola"
    "https://firmware.center/firmware/Motorola"
    "https://motostockrom.com/files/firmware"
)

# ---------- State Management ----------
_state_init() {
    mkdir -p "$WORKDIR"
    touch "$STATE_FILE"
}
_is_done() { grep -qx "$1" "$STATE_FILE" 2>/dev/null; }
_mark_done() { echo "$1" >> "$STATE_FILE"; }
_reset_state() { > "$STATE_FILE"; log_info "State reset."; }

# ---------- Secure Download (with cipher fallback) ----------
_curl_secure() {
    local url="$1" output="$2"
    if [[ ! "$url" =~ ^https:// ]]; then
        log_error "Insecure URL (not HTTPS): $url"
        return 1
    fi
    log_debug "Downloading securely from $url"
    if curl --proto =https --tlsv1.2 --fail --location \
           --connect-timeout "$CONNECT_TIMEOUT" --max-time "$TIMEOUT" \
           --ciphers "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384" \
           --output "$output" "$url" 2>/dev/null; then
        return 0
    fi
    log_warn "Strong cipher download failed – retrying with default ciphers (still HTTPS/TLS)."
    if curl --proto =https --tlsv1.2 --fail --location \
           --connect-timeout "$CONNECT_TIMEOUT" --max-time "$TIMEOUT" \
           --output "$output" "$url"; then
        return 0
    fi
    log_error "Download failed or timed out after ${TIMEOUT}s."
    return 1
}

# ---------- Boot Image Magic Check (no xxd) ----------
_check_boot_magic() {
    local img="$1"
    if [[ ! -f "$img" ]]; then
        log_error "Image file not found: $img"
        return 1
    fi
    local header
    header=$(head -c 8 "$img" 2>/dev/null)
    if [[ "$header" != "ANDROID!" ]]; then
        log_error "Invalid boot image magic (expected 'ANDROID!'). File may be corrupted."
        return 1
    fi
    log_debug "Boot image magic verified."
    return 0
}

# ---------- Strict Automatic Checksum Verification ----------
_verify_checksum() {
    local file="$1" base_url="$2"
    local hash_url="${base_url}.sha256"
    local attempts=0
    local max_attempts=3

    log_step "Verifying checksum automatically..."
    log_warn "Note: checksum is fetched from the same mirror as the firmware — this catches"
    log_warn "corruption/transfer errors, NOT a compromised mirror serving a matching evil hash."

    if ${SKIP_CHECKSUM:-false}; then
        log_warn "FUCK, A FUCKING ERROR SHIT OR A SILLY SKIPPED CHECKSUM!!!!!  --skip-checksum used: skipping integrity verification."
        return 0
    fi

    while [[ $attempts -lt $max_attempts ]]; do
        attempts=$((attempts + 1))
        log_debug "Attempt $attempts/$max_attempts to fetch $hash_url"

        # Try with strong ciphers first, then fallback
        if curl --proto =https --tlsv1.2 --fail --silent --location \
               --connect-timeout "$CONNECT_TIMEOUT" --max-time "$TIMEOUT" \
               --ciphers "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384" \
               --output "${file}.sha256" "$hash_url" 2>/dev/null; then
            :
        elif curl --proto =https --tlsv1.2 --fail --silent --location \
                 --connect-timeout "$CONNECT_TIMEOUT" --max-time "$TIMEOUT" \
                 --output "${file}.sha256" "$hash_url" 2>/dev/null; then
            :
        else
            log_warn "Failed to fetch checksum file (attempt $attempts)."
            sleep 2
            continue
        fi

        local expected
        expected=$(awk '{print $1}' "${file}.sha256" 2>/dev/null)
        if [[ -z "$expected" ]]; then
            log_error "Checksum file is empty or corrupt."
            rm -f "${file}.sha256"
            return 1
        fi

        local actual
        actual=$(sha256sum "$file" | awk '{print $1}')
        if [[ "$actual" == "$expected" ]]; then
            log_done "Checksum verified successfully."
            rm -f "${file}.sha256"
            return 0
        else
            log_error "Checksum MISMATCH! Expected: $expected, Got: $actual"
            rm -f "${file}.sha256"
            return 1
        fi
    done

    log_error "Could not verify integrity after $max_attempts attempts."
    log_error "To bypass (NOT RECOMMENDED), re-run with --skip-checksum"
    return 1
}

# ---------- Dependencies ----------
_install_pkg() {
    log_step "Installing $1"
    pkg install -y "$1" >/dev/null 2>&1 || { log_error "Failed to install $1"; return 1; }
}
_install_termux_adb_fastboot() {
    if command -v termux-adb >/dev/null && command -v termux-fastboot >/dev/null; then
        log_info "termux-adb/fastboot already installed."
        return 0
    fi
    log_warn "Installing termux-adb/fastboot..."
    curl --proto =https --tlsv1.2 --fail -sS https://raw.githubusercontent.com/nohajc/termux-adb/master/install.sh | bash
    if ! command -v termux-adb >/dev/null || ! command -v termux-fastboot >/dev/null; then
        log_error "Installation failed. Please run manually: curl -sS --proto =https --tlsv1.2 https://raw.githubusercontent.com/nohajc/termux-adb/master/install.sh | bash"
        return 1
    fi
    log_info "Installation successful."
}
_check_dependencies() {
    log_step "Checking dependencies..."
    local pkgs=(wget unzip curl)
    for pkg in "${pkgs[@]}"; do
        if ! command -v "$pkg" >/dev/null; then
            _install_pkg "$pkg" || return 1
        fi
    done
    _install_termux_adb_fastboot || return 1
    command -v termux-setup-storage >/dev/null && termux-setup-storage 2>/dev/null || log_warn "Storage setup may have failed."
    if ! command -v termux-adb >/dev/null || ! command -v termux-fastboot >/dev/null; then
        log_error "termux-adb or termux-fastboot not found."
        return 1
    fi
    return 0
}

# ---------- ADB/Fastboot Wrappers ----------
_adb() { log_debug "ADB: $*"; termux-adb "$@"; }
_fastboot() { log_debug "FASTBOOT: $*"; termux-fastboot -i "$MOTO_VENDOR_ID" "$@"; }

_wait_for_adb() {
    log_step "Waiting for ADB..."
    for i in {1..5}; do
        for j in {1..10}; do
            if _adb devices | awk 'NR>1 && $2=="device" {found=1} END{exit !found}'; then
                log_info "ADB connected."
                return 0
            fi
            sleep 3
        done
        log_warn "Restarting ADB server..."
        _adb kill-server 2>/dev/null
        sleep 2
        _adb start-server 2>/dev/null
    done
    log_error "ADB device not found."
    return 1
}

_wait_for_fastboot() {
    log_step "Waiting for fastboot..."
    for i in {1..5}; do
        for j in {1..10}; do
            if _fastboot devices | grep -q .; then
                log_info "Fastboot connected."
                return 0
            fi
            sleep 2
        done
    done
    log_error "Fastboot device not found."
    return 1
}

# ---------- Pre‑flight Checklist ----------
_preflight_setup() {
    echo ""
    log_step "===== PRE‑FLIGHT SETUP ====="
    echo "Please prepare both phones before we continue."
    echo ""
    echo "On your MOTOROLA G 2022 (the phone to root):"
    echo "  1. Go to Settings → About Phone → tap 'Build Number' 7 times"
    echo "     to enable Developer Options."
    echo "  2. Go to Settings → System → Developer Options."
    echo "  3. Enable 'OEM Unlocking' (if available). This is required."
    echo "  4. Enable 'USB Debugging'."
    echo ""
    echo "On your PIXEL 9a (this device):"
    echo "  5. Connect the Motorola with a USB data cable."
    echo "  6. If you see a USB permission pop-up, tap 'Allow'."
    echo ""
    echo "On the Motorola, when the RSA fingerprint prompt appears,"
    echo "check 'Always allow from this computer' and tap 'OK'."
    echo ""
    local dummy
    _safe_read "Press ENTER when ready" dummy

    if ! _adb devices >/dev/null 2>&1; then
        log_error "No ADB output. Ensure USB cable supports data and is connected."
        return 1
    fi

    if _adb devices | grep -q "unauthorized"; then
        echo ""
        log_warn "Motorola is connected but not authorized."
        echo "Please check the Motorola screen for the RSA fingerprint dialog."
        echo "Accept it and check 'Always allow'."
        _safe_read "Press ENTER after accepting" dummy
    fi

    if ! _wait_for_adb; then
        log_error "Still cannot connect to Motorola. Re‑check all steps and cable."
        return 1
    fi

    log_step "Checking OEM unlock support..."
    if _adb shell "getprop ro.oem_unlock_supported" 2>/dev/null | grep -q "1"; then
        log_info "OEM unlocking is supported."
    else
        log_warn "Could not verify OEM unlock support. Proceed with caution."
    fi

    log_done "Pre‑flight checks complete."
    return 0
}

# ---------- Firmware Discovery ----------
_discover_firmware_url() {
    local model="$1" mirror="$2"
    local variant_url
    variant_url=$(curl --proto =https --tlsv1.2 -s --connect-timeout "$CONNECT_TIMEOUT" --max-time "$TIMEOUT" "$mirror/$model/" | grep -o 'href="[^"]*/"' | grep -v '../' | head -1 | sed 's/href="//;s/"//')
    [[ -z "$variant_url" ]] && return 1
    local zip_file
    zip_file=$(curl --proto =https --tlsv1.2 -s --connect-timeout "$CONNECT_TIMEOUT" --max-time "$TIMEOUT" "$mirror/$model/$variant_url" | grep -o 'href="[^"]*\.zip"' | head -1 | sed 's/href="//;s/"//')
    [[ -z "$zip_file" ]] && return 1
    echo "$mirror/$model/$variant_url$zip_file"
}

_get_firmware() {
    if _is_done "firmware_download"; then
        log_info "Firmware already downloaded."
        return 0
    fi
    log_step "Firmware acquisition"
    local url=""
    local auto
    _safe_read "Auto‑discover from mirrors? (y/n): " auto "n"
    if [[ "$auto" == "y" ]]; then
        local model
        _safe_read "Enter model (e.g., moto_g_power_2022): " model
        [[ -z "$model" ]] && { log_error "Model required."; return 1; }
        for mirror in "${MIRRORS[@]}"; do
            if discovered_url=$(_discover_firmware_url "$model" "$mirror"); then
                log_info "Discovered: $discovered_url"
                local use
                _safe_read "Use this URL? (y/n): " use "n"
                if [[ "$use" == "y" ]]; then
                    url="$discovered_url"
                    break
                fi
            fi
        done
        [[ -z "$url" ]] && log_warn "Auto-discovery failed."
    fi
    if [[ -z "$url" ]]; then
        _safe_read "Paste full HTTPS firmware URL: " url
        [[ -z "$url" ]] && { log_error "No URL."; return 1; }
        [[ ! "$url" =~ ^https:// ]] && { log_error "Must be HTTPS."; return 1; }
    fi
    _curl_secure "$url" "$FIRMWARE_ZIP" || return 1
    unzip -t "$FIRMWARE_ZIP" >/dev/null 2>&1 || { log_error "Invalid ZIP."; rm -f "$FIRMWARE_ZIP"; return 1; }

    log_step "Verifying firmware integrity automatically..."
    if ! _verify_checksum "$FIRMWARE_ZIP" "$url"; then
        log_error "Integrity check failed. Firmware may be corrupted or tampered."
        rm -f "$FIRMWARE_ZIP"
        return 1
    fi

    log_step "Extracting boot.img and vbmeta.img..."
    if ! unzip -j "$FIRMWARE_ZIP" "*/boot.img" "*/vbmeta.img" -d "$WORKDIR" 2>/dev/null; then
        unzip -j "$FIRMWARE_ZIP" "boot.img" "vbmeta.img" -d "$WORKDIR" || {
            log_error "Extraction failed. Could not find boot.img/vbmeta.img in ZIP."
            return 1
        }
    fi

    [[ -f "$BOOT_IMG" ]] || { log_error "boot.img not extracted."; return 1; }
    [[ -f "$VBMETA_IMG" ]] || { log_error "vbmeta.img not extracted."; return 1; }

    rm -f "$FIRMWARE_ZIP"   # free space
    _mark_done "firmware_download"
    log_info "Firmware ready."
}

# ---------- SD Card Detection ----------
_get_sd_mount() {
    if [[ -z "${SD_MOUNT:-}" ]]; then
        local sd
        sd=$(_adb shell "ls /storage/" | grep -E '^[A-Z0-9]{4}-[A-Z0-9]{4}$' | head -1 | tr -d '\r')
        if [[ -n "$sd" ]]; then
            SD_MOUNT="/storage/$sd"
        else
            log_warn "No external SD – using internal /sdcard."
            SD_MOUNT="/sdcard"
        fi
    fi
    echo "$SD_MOUNT"
}

# ---------- Push boot.img ----------
_push_boot() {
    if _is_done "push_boot"; then
        log_info "boot.img already pushed."
        return 0
    fi
    local sd
    sd=$(_get_sd_mount)
    log_step "Pushing boot.img to $sd/boot.img"
    _adb push "$BOOT_IMG" "$sd/boot.img" || { log_error "Push failed."; return 1; }
    _mark_done "push_boot"
    return 0
}

# ---------- Magisk Patching ----------
_wait_for_patched() {
    if _is_done "magisk_patched"; then
        log_info "Patched image already pulled."
        return 0
    fi
    local magisk_installed
    magisk_installed=$(_adb shell "pm list packages | grep -q com.topjohnwu.magisk && echo yes || echo no" 2>/dev/null | tr -d '\r')
    if [[ "$magisk_installed" != "yes" ]]; then
        log_warn "Magisk does not appear to be installed on the Motorola."
        local cont
        _safe_read "Continue anyway? (y/n): " cont "n"
        [[ "$cont" != "y" ]] && return 1
    fi
    echo ""
    log_warn "=== MAGISK PATCHING ==="
    echo "1. On Motorola, open Magisk."
    echo "2. Tap 'Install' → 'Select and Patch a File'."
    echo "3. Choose $(_get_sd_mount)/boot.img"
    echo "4. After patching, the file is saved as magisk_patched_*.img"
    _safe_read "Press ENTER when patching is complete..." dummy

    local remote=""
    local search_paths=("/sdcard/Download" "/sdcard" "/storage/emulated/0/Download" "/storage/emulated/0")
    for path in "${search_paths[@]}"; do
        remote=$(_adb shell "find $path -maxdepth 2 -name 'magisk_patched_*.img' 2>/dev/null | head -n1" | tr -d '\r')
        [[ -n "$remote" ]] && break
    done
    if [[ -z "$remote" ]]; then
        log_error "Could not locate patched file."
        return 1
    fi
    log_step "Pulling patched image..."
    _adb pull "$remote" "$PATCHED_IMG" || { log_error "Pull failed."; return 1; }
    if ! _check_boot_magic "$PATCHED_IMG"; then
        log_error "Patched image is not a valid boot image. Aborting."
        return 1
    fi
    _mark_done "magisk_patched"
    log_info "Patched image saved to $PATCHED_IMG"
    return 0
}

# ---------- Bootloader Unlock ----------
_unlock_bootloader() {
    if _is_done "bootloader_unlock"; then
        log_info "Bootloader already marked unlocked."
        return 0
    fi
    echo ""
    log_warn "BOOTLOADER UNLOCK – This will FACTORY RESET your Motorola!"
    local confirm
    _safe_read "Type 'YES' to confirm: " confirm
    if [[ "$confirm" != "YES" ]]; then
        log_error "Unlock not confirmed. Aborting — cannot flash a patched boot image to a locked bootloader."
        return 1
    fi
    local code
    set +e
    read -r -s -p "Enter unlock code (20 hex chars): " code
    local rc=$?
    set -e
    if [[ $rc -ne 0 ]]; then
        log_error "Input aborted. Unlock not performed — cannot continue to flashing."
        return 1
    fi
    echo
    [[ -z "$code" ]] && { log_error "No unlock code provided — cannot continue to flashing."; return 1; }
    if ! [[ "$code" =~ ^[A-Fa-f0-9]{20}$ ]]; then
        log_warn "Code format looks invalid. Continuing anyway."
    fi
    log_step "Rebooting to bootloader..."
    _adb reboot bootloader || { log_error "Failed to reboot."; return 1; }
    sleep 5
    _wait_for_fastboot || return 1
    if _fastboot getvar unlocked 2>&1 | grep -qi "yes"; then
        log_info "Already unlocked."
        _mark_done "bootloader_unlock"
        return 0
    fi
    log_step "Unlocking..."
    if ! _fastboot oem unlock "$code" >/dev/null 2>&1; then
        log_error "Unlock failed."
        return 1
    fi
    log_info "Unlock command sent. Device will reset."
    _safe_read "Wait for device to reboot to system, re‑enable USB Debugging, then press ENTER..." dummy
    _wait_for_adb || { log_error "ADB not available after unlock."; return 1; }
    _mark_done "bootloader_unlock"
    return 0
}

# ---------- Flash with Retries ----------
_flash_with_retry() {
    local cmd=("$@")
    local attempt=0
    local output=""
    while [[ $attempt -lt $MAX_RETRIES ]]; do
        attempt=$((attempt + 1))
        log_step "Flash attempt $attempt/$MAX_RETRIES: ${cmd[*]}"
        set +e
        output=$("${cmd[@]}" 2>&1)
        local rc=$?
        set -e
        if [[ $rc -eq 0 ]]; then
            return 0
        fi
        log_warn "Flash attempt $attempt failed (rc=$rc)."
        log_debug "Flash output: $output"
        sleep $((RETRY_DELAY * attempt))
    done
    log_error "Flash failed after $MAX_RETRIES attempts. Last output: $output"
    return 1
}

_flash_patched() {
    log_step "Rebooting to bootloader..."
    _adb reboot bootloader || return 1
    sleep 5
    _wait_for_fastboot || return 1

    local slot="a"
    local slot_var
    slot_var=$(_fastboot getvar current-slot 2>&1 | sed -n 's/.*current-slot:[[:space:]]*\([ab]\).*/\1/p' | head -1)
    if [[ -n "$slot_var" && "$slot_var" =~ ^[ab]$ ]]; then
        slot="$slot_var"
    else
        log_warn "Could not determine active slot, defaulting to 'a'."
    fi
    log_info "Active slot: $slot"

    if ! _flash_with_retry _fastboot flash "boot_$slot" "$PATCHED_IMG"; then
        log_error "Boot flash failed."
        return 1
    fi

    [[ -f "$VBMETA_IMG" ]] || { log_error "vbmeta.img missing."; return 1; }
    if ! _flash_with_retry _fastboot --disable-verity --disable-verification flash "vbmeta_$slot" "$VBMETA_IMG"; then
        log_error "vbmeta flash failed."
        return 1
    fi

    log_step "Rebooting..."
    _fastboot reboot || { log_error "Reboot failed."; return 1; }
    log_info "Device rebooting. First boot may take a few minutes."
    log_info "After boot, open Magisk and perform a 'Direct Install'."
    _mark_done "flash_done"
    return 0
}

# ---------- Restore Stock ----------
_restore_stock() {
    [[ -f "$BOOT_IMG" ]] || { log_error "Stock boot.img not found."; return 1; }
    log_step "Restoring stock boot..."
    _adb reboot bootloader || return 1
    sleep 5
    _wait_for_fastboot || return 1
    local slot="a"
    local slot_var
    slot_var=$(_fastboot getvar current-slot 2>&1 | sed -n 's/.*current-slot:[[:space:]]*\([ab]\).*/\1/p' | head -1)
    [[ -n "$slot_var" && "$slot_var" =~ ^[ab]$ ]] && slot="$slot_var"
    _fastboot flash "boot_$slot" "$BOOT_IMG" || { log_error "Restore failed."; return 1; }
    _fastboot reboot || return 1
    log_info "Stock boot restored."
    return 0
}

# ---------- Help ----------
_show_help() {
    cat <<EOF
${BOLD}MOTO_ROOT– v3.5 ${NC}

Usage: $0 [OPTIONS]

  --restore          Restore stock boot image and exit.
  --reset-state      Reset the state file (start fresh).
  --debug            Enable debug logging.
  --skip-checksum    Skip automatic SHA‑256 verification (NOT RECOMMENDED).
  --help             Show this help.

EOF
}

# ---------- Main ----------
_main() {
    local restore=false reset=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --restore) restore=true; shift ;;
            --reset-state) reset=true; shift ;;
            --debug) DEBUG=1; shift ;;
            --skip-checksum) SKIP_CHECKSUM=true; shift ;;
            --help) _show_help; exit 0 ;;
            *) log_error "Unknown option: $1"; _show_help; exit 1 ;;
        esac
    done
    if $reset; then _reset_state; exit 0; fi
    log_info "=== MOTO_ROOT v3.5 ==="
    log_info "Log file: $LOG_FILE"
    _state_init
    _check_dependencies || { log_error "Dependency check failed."; exit 1; }
    _preflight_setup || exit 1
    if $restore; then
        _restore_stock || exit 1
        log_info "Restore completed."
        exit 0
    fi
    _get_firmware || exit 1
    _push_boot || exit 1
    _wait_for_patched || exit 1
    _unlock_bootloader || exit 1
    _flash_patched || {
        log_error "Flashing failed."
        local ans
        _safe_read "Restore stock boot? (y/n): " ans "n"
        [[ "$ans" == "y" ]] && _restore_stock
        exit 1
    }
    log_done "All done! Your Motorola should be rooted."
    log_info "Verify with a root checker app and complete Magisk setup."
    log_info "To restore stock later: $0 --restore"
}

if ! command -v pkg >/dev/null; then
    echo "This script is designed for Termux. Please run it in Termux."
    exit 1
fi
trap 'log_warn "Interrupted by user."; exit 1' INT TERM
_main "$@"
