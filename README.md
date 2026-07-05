# MOTO_ROOT

**A no‑compromise, end‑to‑end root automation script for the Motorola G 2022,  
run entirely from an unrooted Pixel 9a using Termux.**

[![ShellCheck](https://img.shields.io/badge/ShellCheck-passing-brightgreen)](https://www.shellcheck.net/)
[![Platform](https://img.shields.io/badge/platform-Termux%20%7C%20Android-brightgreen)](https://termux.com/)
[![Security](https://img.shields.io/badge/Security-HTTPS%20%2B%20checksum%20enforced-blueviolet)](#security--integrity)
[![Version](https://img.shields.io/badge/version-3.5-orange)](#)

---

## Table of Contents

- [Features](#features)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Usage](#usage)
- [Step‑by‑Step Overview](#stepbystep-overview)
- [Security & Integrity](#security--integrity)
- [Recovery / Un‑root](#recovery--un-root)
- [Troubleshooting](#troubleshooting)
- [FAQ](#faq)
- [Contributing](#contributing)
- [License](#license)
- [Disclaimer](#disclaimer)
- [Acknowledgements](#acknowledgements)

---

## Features

- **Zero‑touch pre‑flight guide** – walks you through enabling USB Debugging, OEM Unlocking, accepting RSA keys, and verifying the USB data cable.
- **Automatic firmware discovery** – tries three HTTPS mirrors (lolinet, firmware.center, motostockrom); falls back to a user‑supplied URL if needed.
- **Mandatory SHA‑256 checksum verification** – the script downloads the `.sha256` file from the mirror and aborts on mismatch or download failure. An emergency `--skip-checksum` flag exists for unsupported mirrors. Note: this catches corruption and transfer errors, not a compromised mirror serving a matching hash for tampered firmware — see [Security & Integrity](#security--integrity).
- **Strict HTTPS + TLS 1.2+** – all downloads use strong ciphers first, then fall back to secure defaults, with connect and max-time limits so a dead mirror fails fast instead of hanging.
- **Bootloader unlock** – with double‑confirmation, silent unlock code input, and resumable state. The script now aborts cleanly (rather than silently continuing) if you decline the unlock or the input is interrupted.
- **Magisk patching assistant** – guides you through patching and automatically pulls the patched image.
- **Flash with retries** – each flash command is retried up to 3 times with exponential back‑off; error output is captured and logged.
- **Boot image magic validation** – verifies the patched image starts with `ANDROID!` before flashing.
- **vbmeta disable‑verity** – flashes `vbmeta` with `--disable-verity --disable-verification` to prevent bootloops.
- **Active-slot detection** – reads the device's actual A/B slot from `fastboot getvar current-slot` before flashing, so the patched image lands on the slot that's actually booting.
- **State persistence** – every completed step is saved; you can resume after interruptions.
- **Comprehensive logging** – all output is saved to `~/motoroot_.log` with rotation at 5 MB.
- **Safe‑read prompts** – handles `Ctrl+D`/`EOF` gracefully without crashing.
- **Restore option** – `--restore` flashes the stock boot image if you want to un‑root.

---

## Prerequisites

1. **Termux** installed on the Pixel 9a (from F‑Droid or GitHub, not the Play Store).  
2. **Motorola G 2022** with an unlockable bootloader (most retail models).  
3. A **USB data cable** (not charge‑only).  
4. The **Magisk app** installed on the Motorola (APK from the [official GitHub](https://github.com/topjohnwu/Magisk)).  
5. The **unlock code** from Motorola's bootloader unlock portal (only if you plan to unlock the bootloader; the script will ask when needed).

---

## Installation

1. Open Termux on the Pixel 9a and run:
   ```bash
   termux-setup-storage
   ```
   Grant storage permission when prompted.

2. Download the script:
   ```bash
   curl -o motoroot.sh \
        https://raw.githubusercontent.com/YOUR_USERNAME/MOTO_ROOT/main/motoroot.sh
   ```
3. Make it executable:
   ```bash
   chmod +x motoroot.sh
   ```
4. Run it:
   ```bash
   ./motoroot.sh
   ```
   The script will install all necessary dependencies (wget, unzip, curl, termux-adb-fastboot) automatically.

---

## Usage

```
./motoroot.sh [OPTIONS]
```

| Option | Description |
|---|---|
| `--restore` | Flash the original stock boot image and exit (un‑root). |
| `--reset-state` | Clear the saved progress file so you can start fresh. |
| `--debug` | Enable verbose debug logging (very detailed). |
| `--skip-checksum` | Skip mandatory SHA‑256 verification (NOT recommended). |
| `--help` | Display this help. |

Typical root procedure: just run `./motoroot.sh` without any arguments and follow the on‑screen instructions.

---

## Step‑by‑Step Overview

1. **Pre‑flight setup**
   The script prints a checklist for enabling Developer Options, USB Debugging, and OEM Unlocking on the Motorola. It also reminds you about the USB permission pop‑up on the Pixel 9a and the RSA key acceptance. It waits until ADB is fully working.
2. **Firmware acquisition**
   - Auto‑discover from HTTPS mirrors, or paste your own HTTPS URL.
   - Downloads the ZIP, verifies its integrity with the `.sha256` file from the same directory.
   - Extracts `boot.img` and `vbmeta.img`.
   - Deletes the ZIP to save space.
3. **Push boot.img**
   Sends the stock boot image to the Motorola's storage (external SD card preferred, internal fallback).
4. **Magisk patching**
   - Checks whether Magisk is installed on the phone.
   - Instructs you to patch the image using Magisk.
   - Automatically locates and pulls the patched `magisk_patched_*.img` from the device.
   - Validates the boot image magic.
5. **Bootloader unlock**
   - Warns you that data will be wiped.
   - Requires you to type `YES` to confirm — declining stops the script here rather than silently skipping ahead.
   - Reads the unlock code silently (input not echoed).
   - Sends the unlock command and waits for the device to reboot.
   - **On-device confirmation:** most Motorola bootloaders show a warning screen after `fastboot oem unlock` that requires a volume-key press on the phone itself. Watch the Motorola's screen — the script waiting for ADB does not mean it's waiting for you to look away.
6. **Flashing**
   - Reboots to bootloader, detects the actual active slot via `current-slot`.
   - Flashes the patched boot image and vbmeta with verity disabled.
   - Retries each flash up to 3 times.
   - Reboots the device.

After first boot, open Magisk and perform a **Direct Install** to finalise the root.

---

## Security & Integrity

Everything the script downloads is forced over HTTPS with TLS 1.2 or higher. Certificates are validated by curl's default trust store — the script does not pin a specific certificate or CA, so this is standard TLS verification, not certificate pinning.

The firmware checksum is verified automatically and mandatory. If the mirror does not provide a `.sha256` file, or the hash doesn't match, the script aborts. **Important limitation:** the checksum file is fetched from the same mirror as the firmware itself. This protects against corruption or an interrupted download — it does *not* protect against a compromised mirror serving tampered firmware alongside a matching hash. If you need protection against that threat model, verify the hash independently against a source you trust before running the script, or compare it against a value published somewhere other than the mirror.

You can override checksum verification with `--skip-checksum`, but you'll see a warning and are strongly advised to verify manually first.

Downloads use a 15-second connect timeout and a 60-second overall timeout, so a dead or throttled mirror fails and retries instead of hanging indefinitely.

The unlock code is never displayed on screen and is never written to the log file.

The log file (`~/motoroot_.log`) may contain non‑sensitive prompts. If you are concerned, delete it after use.

---

## Recovery / Un‑root

If you ever need to go back to stock (e.g. for an OTA update or warranty), run:

```bash
./motoroot.sh --restore
```

This flashes the original `boot.img` (saved during the firmware step) and reboots.

To completely start over, reset the state:

```bash
./motoroot.sh --reset-state
```

---

## Troubleshooting

| Problem | Solution |
|---|---|
| `termux-adb` or `termux-fastboot` not found | The script installs them automatically; if that fails, run: `curl -sS https://raw.githubusercontent.com/nohajc/termux-adb/master/install.sh \| bash` |
| ADB shows unauthorized | On the Motorola, tap "Always allow" and accept the RSA prompt. |
| ADB devices list is empty | Make sure USB Debugging is ON, the cable supports data, and you gave Termux storage permission. Try re‑connecting the cable. |
| Firmware auto‑discovery fails | Enter a model string like `moto_g_power_2022`, or manually provide an HTTPS URL. |
| Checksum verification fails | The firmware may be corrupt or tampered. Try a different mirror, or use `--skip-checksum` only as a last resort. |
| Flash failed after 3 attempts | Check the debug log (`--debug` flag) and look at the captured fastboot output. Restart the script. |
| Bootloop after flashing | Boot to bootloader manually and run `./motoroot.sh --restore`. |
| Unlock seems to hang after sending the code | Check the Motorola's screen — many devices require a physical volume-key confirmation on-device before the unlock actually proceeds. |

---

## FAQ

**Q: Does this work on other Motorola models?**
A: The script targets the G 2022, but the approach is similar for many Motorola devices with A/B slots. You may need to adjust the vendor ID (currently `0x22b8`). Contributions for other models are welcome!

**Q: Why do I need a Pixel 9a? Can I use another phone as the host?**
A: Any Android phone running Termux can act as the host, as long as it supports USB OTG and can install termux-adb.

**Q: Can I use a computer instead?**
A: Absolutely – just use standard `adb` and `fastboot`. The script is designed for a pure‑mobile setup.

---

## Contributing

Pull requests, bug reports, and feature suggestions are welcome! Please test on your device and try to keep the script as secure and robust as the current version.

---

## License

This project is licensed under the GNU General Public License v3.0. See the LICENSE file for details.

---

## Disclaimer

This script is provided as‑is, without any warranty. Rooting voids your warranty, may brick your device, and can cause data loss. You are solely responsible for your actions. The authors assume no liability.

---

## Acknowledgements

- topjohnwu for Magisk
- nohajc for termux-adb-fastboot
- The Termux community
- The firmware mirror maintainers

---

Made with ❤️ for those who want root from daddy.
