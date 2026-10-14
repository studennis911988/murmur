# Installing Murmur

A step-by-step guide to build and install **Murmur** from source on your Mac.

---

## System Requirements

| Requirement | Minimum |
|---|---|
| macOS | **14.5 Sonoma** or later |
| Xcode | **16.2** (for macOS 14) or the latest version compatible with your macOS |
| Disk space | ~40 GB free (for Xcode + build artifacts) |
| Architecture | Apple Silicon (arm64) or Intel (x86_64) |

> **Note for macOS 15+ users:** Install the latest Xcode from the App Store directly.

---

## Step 1 — Install Xcode

Murmur requires **full Xcode** (not just Command Line Tools) because it uses Swift Package Manager and links against macOS frameworks (Carbon, Speech, AVFoundation, etc.).

### macOS 15 (Sequoia) and later
Open the **App Store**, search for **Xcode**, and click **Install**.

### macOS 14 (Sonoma) — Xcode 16.2
The App Store may offer a version too new for your macOS. Download the correct version manually:

1. Go to [https://developer.apple.com/download/more/](https://developer.apple.com/download/more/) *(free Apple ID required)*
2. Search for **Xcode 16.2**
3. Download **`Xcode_16.2.xip`** (~7.7 GB)
4. Double-click the `.xip` file in Finder to expand it (takes a few minutes)
5. Drag **`Xcode.app`** to your `/Applications` folder

### Activate Xcode and accept the license

After Xcode is in `/Applications`, run:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
```

Verify it works:

```bash
swift --version
# Should print: Apple Swift version 6.x ...
```

---

## Step 2 — Clone the Repository

```bash
git clone https://github.com/studennis911988/murmur.git
cd murmur
```

---

## Step 3 — Build and Install

```bash
make install
```

This will:
- Compile the Swift sources in release mode
- Bundle `Murmur.app` under `build/`
- Copy it to `/Applications/Murmur.app`
- Launch the app automatically

---

## Other Make Targets

| Command | Description |
|---|---|
| `make app` | Build `build/Murmur.app` only (no install) |
| `make run` | Build and open the app |
| `make check` | Run self-checks (`MurmurChecks`) |
| `make models` | Download/set up Whisper models |
| `make clean` | Remove build artifacts |

---

## Troubleshooting

### ❌ `Invalid manifest` / `Undefined symbols for architecture arm64`
**Cause:** You have only Command Line Tools installed, not full Xcode.  
**Fix:** Follow Step 1 above to install Xcode.

```bash
# Confirm you're using Xcode, not just CLT:
xcode-select -p
# Should print: /Applications/Xcode.app/Contents/Developer
```

### ❌ `xcbuild executable does not exist`
**Cause:** A tool tried to use Xcode internals before Xcode was installed.  
**Fix:** Install Xcode first (Step 1), then retry.

### ❌ App Store says "macOS version X or later is required"
**Cause:** The latest Xcode requires a newer macOS than you have.  
**Fix:** Download the last Xcode compatible with your macOS from [developer.apple.com/download/more/](https://developer.apple.com/download/more/). Refer to the table below:

| Your macOS | Required Xcode |
|---|---|
| macOS 14.5 Sonoma | Xcode 16.2 |
| macOS 15.x Sequoia | Xcode 16.3+ |
| macOS 26.x or later | Latest Xcode from App Store |

### ❌ `git push` fails with `Permission denied (publickey)`
Your remote may be set to SSH. Switch it to HTTPS:

```bash
git remote set-url origin https://github.com/studennis911988/murmur.git
git push -u origin main
```

> GitHub requires a **Personal Access Token (PAT)** as your password.  
> Generate one at [github.com/settings/tokens](https://github.com/settings/tokens) with `repo` scope.

---

## Uninstalling

```bash
rm -rf /Applications/Murmur.app
make clean
```
