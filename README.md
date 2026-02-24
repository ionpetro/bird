# bird

A minimal native macOS screen recorder with a floating toolbar UI — no Electron, no subscriptions.

Built with Swift, ScreenCaptureKit, and AVFoundation.

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue) ![Swift](https://img.shields.io/badge/Swift-5.9-orange)

---

## Features

- **Floating toolbar** at the bottom of your screen (Screen Studio-style) — no app window
- **Display or Window** capture mode
- **Camera overlay** composited directly into the recording as a circular inset (bottom-right)
- **Microphone + system audio** capture
- **3-second countdown** before recording starts
- **Auto-saves** to `~/Documents` with a timestamp filename — no save dialog
- Finder opens and highlights the file when done

---

## Requirements

- macOS 13 Ventura or later
- Xcode Command Line Tools (`xcode-select --install`)
- A valid local code signing identity (comes with Xcode)

---

## Run locally

### 1. Clone the repo

```bash
git clone https://github.com/ionpetro/bird.git
cd bird
```

### 2. Grant permissions up front (recommended)

bird needs three macOS permissions. You can pre-approve them or wait for the prompts at first launch:

- **System Settings → Privacy & Security → Screen Recording** — add `bird` (or Terminal while developing)
- **System Settings → Privacy & Security → Camera** — allow
- **System Settings → Privacy & Security → Microphone** — allow

### 3. Build and launch

```bash
./run.sh
```

This script does three things:
1. `swift build` — compiles the Swift Package
2. `codesign` — signs the binary with a local identity (required for ScreenCaptureKit)
3. Launches the app

The toolbar appears at the **bottom-center** of your screen. There is no Dock icon — to quit, click the **✕** button on the left of the toolbar.

### 4. Record

1. Choose **Display** (full screen) or **Window** (single app)
2. Toggle **Camera**, **Mic**, and **System Audio** as needed
3. Click **Record** — a 3-second countdown runs, then recording starts
4. The toolbar shrinks to a small **Stop** pill in the bottom-left corner
5. Click **Stop** — the file is saved automatically to `~/Documents/Screen Recording YYYY-MM-DD at HH.MM.SS.mp4` and revealed in Finder

---

## Project structure

```
bird/
├── Sources/bird/
│   ├── App/
│   │   ├── BirdApp.swift          # App entry point, AppDelegate, panel management
│   │   └── FloatingPanel.swift    # Custom NSPanel subclass
│   ├── Capture/
│   │   ├── ScreenRecorder.swift   # ScreenCaptureKit pipeline + compositing
│   │   ├── CameraManager.swift    # AVCaptureSession wrapper
│   │   └── MicrophoneManager.swift
│   ├── Views/
│   │   ├── FloatingBarView.swift  # Toolbar UI + countdown
│   │   └── CameraPreviewView.swift # Live camera bubble (NSViewRepresentable)
│   └── Models/
│       └── Models.swift
├── Info.plist
├── bird-dev.entitlements          # Entitlements used by run.sh
└── run.sh                         # Build + sign + launch script
```

---

## Troubleshooting

**Toolbar doesn't appear**
Run `pkill bird` in Terminal to kill any stale instance, then `./run.sh` again.

**"Screen Recording permission required" error when clicking Record**
Go to System Settings → Privacy & Security → Screen Recording and add the `bird` binary (`.build/arm64-apple-macosx/debug/bird`), then relaunch.

**Build fails with signing error**
Make sure Xcode Command Line Tools are installed: `xcode-select --install`. The `run.sh` uses ad-hoc signing (`-`), which requires no Apple Developer account.

**Camera not showing in recording**
Ensure Camera permission is granted in System Settings → Privacy & Security → Camera. The live preview bubble disappears during recording by design — the camera is composited directly into the video.
