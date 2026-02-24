# ScreenStudio Lite (macOS SwiftUI)

This is a native macOS screen recorder using ScreenCaptureKit + AVFoundation.

## What you get
- Record an entire display or a single window.
- Optional camera overlay bottom-right.
- Optional system audio and microphone.
- Export as MP4.

## How to run in Xcode
1. Open Xcode.
2. Create a new **macOS App** project named `bird`.
3. Replace the generated sources with the files in `bird/Sources/bird/`.
4. Set the app’s **Info.plist** to `bird/Info.plist`.
5. Set the app’s **Entitlements** to `bird/bird.entitlements`.
6. In the target **Signing & Capabilities**:
   - Enable **App Sandbox**.
   - Check **Camera**, **Microphone**, and **Screen Recording**.
   - Check **User Selected Files** (Read/Write).
7. Build and run.

## Permissions
The first time you start recording, macOS will prompt for Screen Recording, Camera, and Microphone permissions. If you deny them, enable later in System Settings > Privacy & Security.
