#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
#  MOTO_ROOT – v3.5 (FINAL)
#  ============================================================================
#  Purpose : Root Motorola G 2022 from an unrooted Pixel 9a (Termux)
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
readonly FIRMWARE_META="${WORKDIR}/firmware_meta.txt"
readonly BOOT_IMG="${WORKDIR}/boot.img"
readonly VBMETA_IMG="${WORKDIR}/vbmeta.img"
readonly PATCHED_IMG="${WORKDIR}/magisk_patched.img"
readonly MAX_RETRIES=3
readonly RETRY_DELAY=3
readonly TIMEOUT=60
readonly CONNECT_TIMEOUT=15
readonly MOTO_VENDOR_ID="0x22b8"
readonly LOLINET_BASE="https://mirrors.lolinet.com/firmware/lenomola"

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

# ---------- h5ai Directory Listing ----------
# mirrors.lolinet.com runs h5ai, which ships a real no-JS fallback <table id="fallback">
# with genuine <a href> entries (for browsers/scripts without JS). Scoping to that table
# instead of grepping the whole page avoids matching nav/footer/breadcrumb links (e.g. the
# h5ai project link) that also end in "/" and would otherwise get picked up as if they were
# real firmware folders.
_h5ai_list() {
    local url="$1"
    local html
    html=$(curl --proto =https --tlsv1.2 -s --connect-timeout "$CONNECT_TIMEOUT" --max-time "$TIMEOUT" "$url") || return 1
    echo "$html" \
        | sed -n '/id="fallback"/,/<\/table>/p' \
        | grep -oE 'href="[^"]*"' \
        | sed -E 's/^href="//; s/"$//' \
        | grep -vE '^(\.\./|\.\.$)' \
        | sort -u
}

# Resolve a possibly-relative href against its listing URL into an absolute URL.
_h5ai_resolve() {
    local base="$1" href="$2"
    if [[ "$href" =~ ^https?:// ]]; then
        echo "$href"
    elif [[ "$href" == /* ]]; then
        local scheme_host
        scheme_host=$(echo "$base" | grep -oE '^https?://[^/]+')
        echo "${scheme_host}${href}"
    else
        echo "${base%/}/${href}"
    fi
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
        log_warn "⚠️  --skip-checksum used: skipping integrity verification."
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

# ---------- Device Identification ----------
# Reads the Motorola's real codename/model directly off the device instead of
# trusting a free-typed "model string", which is how the old auto-discovery
# picked wrong-device firmware. "Motorola G 2022" isn't one phone — G22/G32/
# G42/G52/G62/G82 were all sold as "moto g" in 2022 with different codenames
# (hawaiip/devon/hawao/rhode/rhodec/rhodep respectively), so guessing is risky.
_detect_device_codename() {
    local codename
    codename=$(_adb shell getprop ro.product.device 2>/dev/null | tr -d '\r\n')
    [[ -z "$codename" ]] && codename=$(_adb shell getprop ro.build.product 2>/dev/null | tr -d '\r\n')
    echo "$codename"
}

_detect_device_model() {
    _adb shell getprop ro.product.model 2>/dev/null | tr -d '\r\n'
}

# ---------- Firmware Discovery (lolinet, codename-based) ----------
# lolinet organizes firmware as: <base>/<codename>/official/<variant>/<file>.zip
# NOT <base>/<model-string>/ like the old code assumed — that mismatch is why
# auto-discovery never found anything. Carrier/region variant selection is left
# to the person: matching the wrong variant to a device is a known bricking
# risk (see Troubleshooting), and there's no reliable way to auto-resolve that
# without a maintained CID lookup table.
_discover_lolinet_variants() {
    local codename="$1"
    local official_url="${LOLINET_BASE}/${codename}/official/"
    _h5ai_list "$official_url"
}

_discover_lolinet_zips() {
    local variant_url="$1"
    _h5ai_list "$variant_url" | grep -iE '\.zip$'
}

_get_firmware() {
    if _is_done "firmware_download"; then
        log_info "Firmware already downloaded."
        return 0
    fi
    log_step "Firmware acquisition"

    local url=""
    local codename model
    codename=$(_detect_device_codename)
    model=$(_detect_device_model)

    if [[ -n "$codename" ]]; then
        log_info "Detected device codename: $codename (model: ${model:-unknown})"
        local official_url="${LOLINET_BASE}/${codename}/official/"
        log_step "Listing variants at $official_url"

        local variant_hrefs
        variant_hrefs=$(_discover_lolinet_variants "$codename" || true)

        if [[ -z "$variant_hrefs" ]]; then
            log_warn "Could not list variants automatically (codename folder may not exist, or lolinet layout changed)."
            log_warn "You can browse manually: $official_url"
        else
            local -a variants=()
            while IFS= read -r href; do
                [[ -z "$href" ]] && continue
                variants+=("$href")
            done <<< "$variant_hrefs"

            echo ""
            log_info "Available variants for '$codename':"
            local i=1 v
            for v in "${variants[@]}"; do
                echo "  [$i] $v"
                ((i++)) || true
            done
            echo ""
            log_warn "Pick the variant matching YOUR region/carrier (e.g. RETAIL, RETEU, RETBR, RETLA)."
            log_warn "Getting this wrong can flash incompatible firmware. If unsure, run 'fastboot getvar cid'"
            log_warn "later and cross-check against the CID convention lolinet documents, or ask in their Telegram."

            local choice
            _safe_read "Enter the number of your variant (or blank to paste a URL manually): " choice ""

            if [[ -n "$choice" && "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le "${#variants[@]}" ]]; then
                local chosen_variant="${variants[$((choice-1))]}"
                local variant_url
                variant_url=$(_h5ai_resolve "$official_url" "$chosen_variant")

                local zip_hrefs
                zip_hrefs=$(_discover_lolinet_zips "$variant_url" || true)
                if [[ -z "$zip_hrefs" ]]; then
                    log_warn "No .zip files found directly in that folder — it may have date subfolders."
                    log_warn "Browse manually: $variant_url"
                else
                    local -a zips=()
                    while IFS= read -r zh; do
                        [[ -z "$zh" ]] && continue
                        zips+=("$zh")
                    done <<< "$zip_hrefs"
                    # Newest build tends to sort last lexicographically (lolinet filenames
                    # embed dates/version strings); still, ask for confirmation rather than
                    # silently trusting sort order.
                    local suggested="${zips[-1]}"
                    echo ""
                    log_info "Found ${#zips[@]} firmware file(s). Suggested (last alphabetically = usually newest):"
                    echo "  $suggested"
                    local use_suggested
                    _safe_read "Use this file? (y/n): " use_suggested "y"
                    if [[ "$use_suggested" == "y" ]]; then
                        url=$(_h5ai_resolve "$variant_url" "$suggested")
                    else
                        local j=1 z
                        for z in "${zips[@]}"; do
                            echo "  [$j] $z"
                            ((j++)) || true
                        done
                        local zchoice
                        _safe_read "Enter the number of the file to use: " zchoice ""
                        if [[ "$zchoice" =~ ^[0-9]+$ && "$zchoice" -ge 1 && "$zchoice" -le "${#zips[@]}" ]]; then
                            url=$(_h5ai_resolve "$variant_url" "${zips[$((zchoice-1))]}")
                        fi
                    fi
                fi
            fi
        fi
    else
        log_warn "Could not read device codename over ADB. Falling back to manual URL entry."
    fi

    if [[ -z "$url" ]]; then
        _safe_read "Paste full HTTPS firmware URL: " url
        [[ -z "$url" ]] && { log_error "No URL."; return 1; }
        [[ ! "$url" =~ ^https:// ]] && { log_error "Must be HTTPS."; return 1; }
    fi

    log_info "Selected firmware URL: $url"
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

    # Record what we flashed from, for the CID sanity-check later in _flash_patched.
    printf 'url=%s\ncodename=%s\n' "$url" "$codename" > "$FIRMWARE_META"

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

# ---------- Magisk Patching: automatic (CLI) ----------
# Extracts magiskboot + boot_patch.sh straight from the Magisk APK and runs the
# patch on-device via `adb shell`, the same way Magisk's own recovery-flashable
# zip does it — no GUI taps required. This mirrors what the Magisk app itself
# does internally; it is not a hack around Magisk, it's driving its own
# published patch script directly.
#
# Caveat: asset/lib names have been stable across recent Magisk releases, but
# could shift in a future release. If this fails, fall back to the manual
# in-app patching flow (_wait_for_patched_manual) and open an issue with the
# Magisk version you used.
_auto_patch_boot() {
    local apk_path
    _safe_read "Path to a Magisk APK on THIS Pixel (e.g. /sdcard/Download/Magisk-v27.0.apk): " apk_path
    if [[ ! -f "$apk_path" ]]; then
        log_error "File not found: $apk_path"
        return 1
    fi

    local abi
    abi=$(_adb shell getprop ro.product.cpu.abi 2>/dev/null | tr -d '\r\n')
    [[ -z "$abi" ]] && abi="arm64-v8a"
    log_info "Target device ABI: $abi"

    local extract_dir="${WORKDIR}/magisk_extract"
    rm -rf "$extract_dir"
    mkdir -p "$extract_dir"

    if ! unzip -o "$apk_path" "lib/${abi}/*" "assets/*" -d "$extract_dir" >/dev/null 2>&1; then
        log_error "Could not extract lib/${abi} or assets/ from $apk_path"
        log_error "Run: unzip -l '$apk_path' | grep '^lib/' to see which ABIs this APK actually ships."
        return 1
    fi

    local libdir="${extract_dir}/lib/${abi}"
    if [[ ! -d "$libdir" ]] || [[ -z "$(ls -A "$libdir" 2>/dev/null)" ]]; then
        log_error "No native libraries found for ABI $abi in this APK."
        return 1
    fi

    local remote_dir="/data/local/tmp/motoroot_magisk"
    _adb shell "rm -rf $remote_dir && mkdir -p $remote_dir" || { log_error "Could not prep remote dir."; return 1; }

    log_step "Pushing patch tools to device..."
    local lib bin ok=true
    for lib in "$libdir"/lib*.so; do
        [[ -f "$lib" ]] || continue
        bin=$(basename "$lib")
        bin="${bin#lib}"
        bin="${bin%.so}"
        if ! _adb push "$lib" "$remote_dir/$bin" >/dev/null 2>&1; then
            log_error "Failed to push $bin"
            ok=false
        fi
    done
    $ok || return 1

    local f
    for f in "$extract_dir"/assets/*.sh; do
        [[ -f "$f" ]] && _adb push "$f" "$remote_dir/$(basename "$f")" >/dev/null 2>&1
    done

    _adb shell "chmod 755 $remote_dir/*" >/dev/null 2>&1 || true
    _adb push "$BOOT_IMG" "$remote_dir/boot.img" >/dev/null 2>&1 || { log_error "Failed to push boot.img"; return 1; }

    if [[ ! -f "${extract_dir}/assets/boot_patch.sh" ]]; then
        log_error "boot_patch.sh not found in this APK's assets/ — Magisk's internal layout may have changed."
        return 1
    fi

    log_step "Running boot_patch.sh on the Motorola (this can take a minute)..."
    if ! _adb shell "cd $remote_dir && sh boot_patch.sh boot.img" 2>&1 | tee -a "$LOG_FILE"; then
        log_error "boot_patch.sh failed. See output above."
        return 1
    fi

    local remote_out="$remote_dir/new-boot.img"
    if ! _adb shell "[ -f $remote_out ]" 2>/dev/null; then
        log_error "Expected output new-boot.img not found on device."
        return 1
    fi

    _adb pull "$remote_out" "$PATCHED_IMG" >/dev/null 2>&1 || { log_error "Failed to pull patched image."; return 1; }
    if ! _check_boot_magic "$PATCHED_IMG"; then
        log_error "Patched image failed magic check."
        return 1
    fi

    _adb shell "rm -rf $remote_dir" >/dev/null 2>&1 || true
    _mark_done "magisk_patched"
    log_done "Boot image patched automatically. Saved to $PATCHED_IMG"
    return 0
}

# ---------- Magisk Patching: manual (original in-app flow) ----------
_wait_for_patched_manual() {
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

_wait_for_patched() {
    if _is_done "magisk_patched"; then
        log_info "Patched image already pulled."
        return 0
    fi

    echo ""
    log_step "Boot image patching"
    echo "  [1] Automatic — I have a Magisk APK file, patch boot.img via adb (no phone taps)"
    echo "  [2] Manual — I'll patch it myself in the Magisk app"
    local mode
    _safe_read "Choose 1 or 2: " mode "2"

    if [[ "$mode" == "1" ]]; then
        if _auto_patch_boot; then
            return 0
        fi
        log_warn "Automatic patching failed. Falling back to manual flow."
    fi
    _wait_for_patched_manual
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
    log_warn "IMPORTANT: many Motorolas show an on-screen warning that needs a volume-key"
    log_warn "press to actually confirm the unlock. Check the Motorola's screen now."
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

# Best-effort sanity check: warn (don't block) if the CID burned into this
# device doesn't appear anywhere in the firmware filename/URL we downloaded.
# This is a heuristic, not a guarantee — lolinet filenames don't always
# encode CID, and this only runs after ADB→fastboot handoff when it's cheap
# to ask.
_cid_sanity_check() {
    [[ -f "$FIRMWARE_META" ]] || return 0
    local cid
    cid=$(_fastboot getvar cid 2>&1 | grep -oE '[0-9]+' | head -1)
    [[ -z "$cid" ]] && return 0
    local recorded_url
    recorded_url=$(grep '^url=' "$FIRMWARE_META" | cut -d= -f2-)
    if [[ -n "$recorded_url" && "$recorded_url" != *"$cid"* ]]; then
        log_warn "Device CID ($cid) was not found in the firmware filename/URL you downloaded."
        log_warn "This doesn't necessarily mean it's wrong (many filenames omit CID), but if you"
        log_warn "picked the variant manually, double-check it against lolinet's carrier folder"
        log_warn "before continuing. Firmware URL: $recorded_url"
        local cont
        _safe_read "Continue flashing anyway? (y/n): " cont "n"
        [[ "$cont" != "y" ]] && return 1
    fi
    return 0
}

_flash_patched() {
    log_step "Rebooting to bootloader..."
    _adb reboot bootloader || return 1
    sleep 5
    _wait_for_fastboot || return 1

    _cid_sanity_check || { log_error "Aborted after CID check."; return 1; }

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