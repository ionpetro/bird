import SwiftUI
import AppKit

// MARK: – Hover effect modifier

private struct HoverModifier: ViewModifier {
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .brightness(isHovered ? 0.08 : 0)
            .scaleEffect(isHovered ? 1.04 : 1.0)
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
                hovering ? NSCursor.pointingHand.push() : NSCursor.pop()
            }
    }
}

private extension View {
    func hoverEffect() -> some View { modifier(HoverModifier()) }

    /// Cursor only — for controls (menus/toggles) that have their own hover visuals.
    func pointerCursor() -> some View {
        onHover { hovering in
            hovering ? NSCursor.pointingHand.push() : NSCursor.pop()
        }
    }
}

// MARK: – Floating bar

struct FloatingBarView: View {
    @ObservedObject var recorder: ScreenRecorder
    @State private var selectedSourceKind: CaptureSourceKind = .display
    @State private var countdown: Int? = nil

    var body: some View {
        ZStack {
            if recorder.isRecording {
                miniPill
            } else {
                fullBar
            }
        }
        .animation(.spring(duration: 0.25), value: recorder.isRecording)
    }

    // MARK: – Full toolbar

    private var fullBar: some View {
        HStack(spacing: 16) {
            // Quit button
            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .hoverEffect()

            divider

            // Source tabs
            HStack(spacing: 2) {
                sourceTabButton(kind: .display, icon: "rectangle.fill", label: "Display")
                sourceTabButton(kind: .window, icon: "macwindow", label: "Window")
            }

            divider

            cameraMenu.pointerCursor()
            micMenu.pointerCursor()
            systemAudioButton.pointerCursor()

            Spacer()

            recordButton
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        )
        .onAppear {
            Task { await recorder.reloadSources() }
        }
    }

    // MARK: – Mini stop pill

    private var miniPill: some View {
        Button {
            Task { await stopRecording() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 12, weight: .semibold))
                Text("Stop")
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(Capsule().fill(Color.red))
        }
        .buttonStyle(.plain)
        .hoverEffect()
    }

    // MARK: – Sub-views

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.15))
            .frame(width: 1, height: 28)
    }

    @ViewBuilder
    private func sourceTabButton(kind: CaptureSourceKind, icon: String, label: String) -> some View {
        Button {
            selectedSourceKind = kind
            recorder.setSourceKind(kind)
        } label: {
            Label(label, systemImage: icon)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(selectedSourceKind == kind ? Color.primary.opacity(0.12) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .hoverEffect()
    }

    private var cameraMenu: some View {
        Menu {
            Toggle("Enable Camera", isOn: $recorder.captureCamera)
            if !recorder.availableCameras.isEmpty {
                Divider()
                Picker("Camera", selection: $recorder.selectedCameraID) {
                    ForEach(recorder.availableCameras) { cam in
                        Text(cam.name).tag(cam.id)
                    }
                }
                .disabled(!recorder.captureCamera)
            }
        } label: {
            Label(
                truncated(recorder.availableCameras.first(where: { $0.id == recorder.selectedCameraID })?.name ?? "Camera"),
                systemImage: "camera"
            )
            .font(.system(size: 12))
            .foregroundColor(recorder.captureCamera ? .primary : .secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var micMenu: some View {
        Menu {
            Toggle("Enable Mic", isOn: $recorder.captureMicrophone)
            if !recorder.availableMicrophones.isEmpty {
                Divider()
                Picker("Microphone", selection: $recorder.selectedMicrophoneID) {
                    ForEach(recorder.availableMicrophones) { mic in
                        Text(mic.name).tag(mic.id)
                    }
                }
                .disabled(!recorder.captureMicrophone)
            }
        } label: {
            Label(
                truncated(recorder.availableMicrophones.first(where: { $0.id == recorder.selectedMicrophoneID })?.name ?? "Mic"),
                systemImage: "mic"
            )
            .font(.system(size: 12))
            .foregroundColor(recorder.captureMicrophone ? .primary : .secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var systemAudioButton: some View {
        Toggle(isOn: $recorder.captureSystemAudio) {
            Label("System Audio", systemImage: "speaker.wave.2")
                .font(.system(size: 12))
        }
        .toggleStyle(.button)
        .buttonStyle(.plain)
        .foregroundColor(recorder.captureSystemAudio ? .primary : .secondary)
    }

    private var recordButton: some View {
        Button {
            guard countdown == nil else { return }
            Task { await startRecording() }
        } label: {
            ZStack {
                if let n = countdown {
                    Text("\(n)")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .id(n) // triggers transition on change
                        .transition(.asymmetric(
                            insertion: .scale(scale: 1.4).combined(with: .opacity),
                            removal: .scale(scale: 0.6).combined(with: .opacity)
                        ))
                } else {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 8, height: 8)
                        Text("Record")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: countdown)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.red))
        }
        .buttonStyle(.plain)
        .hoverEffect()
    }

    // MARK: – Helpers

    private func truncated(_ name: String, maxLength: Int = 16) -> String {
        name.count > maxLength ? String(name.prefix(maxLength - 1)) + "…" : name
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Recording Error"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func startRecording() async {
        if recorder.availableSources.isEmpty {
            await recorder.reloadSources()
        }
        // 3-second countdown
        for i in stride(from: 3, through: 1, by: -1) {
            countdown = i
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        countdown = nil
        do {
            try await recorder.startRecording()
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func stopRecording() async {
        do {
            try await recorder.stopRecordingAndExport()
        } catch {
            showError(error.localizedDescription)
        }
    }
}
