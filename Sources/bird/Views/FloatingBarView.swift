import SwiftUI

struct FloatingBarView: View {
    @ObservedObject var recorder: ScreenRecorder
    @State private var selectedSourceKind: CaptureSourceKind = .display
    @State private var errorText: String?

    var body: some View {
        ZStack {
            if recorder.isRecording {
                miniPill
            } else {
                fullBar
            }
        }
        .animation(.spring(duration: 0.25), value: recorder.isRecording)
        .alert("Error", isPresented: Binding(
            get: { errorText != nil },
            set: { if !$0 { errorText = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
    }

    // MARK: – Full toolbar

    private var fullBar: some View {
        HStack(spacing: 12) {
            // Quit button
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)

            divider

            // Source tabs
            HStack(spacing: 2) {
                sourceTabButton(kind: .display, icon: "rectangle.fill", label: "Display")
                sourceTabButton(kind: .window, icon: "macwindow", label: "Window")
            }

            divider

            // Camera picker
            cameraMenu

            // Mic picker
            micMenu

            // System audio
            systemAudioButton

            Spacer()

            // Record button
            recordButton
        }
        .padding(.horizontal, 14)
        .frame(height: 54)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
                .shadow(radius: 16, y: 4)
        )
        .padding(8)
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
            Label(truncated(recorder.availableCameras.first(where: { $0.id == recorder.selectedCameraID })?.name ?? "Camera"), systemImage: "camera")
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
            Label(truncated(recorder.availableMicrophones.first(where: { $0.id == recorder.selectedMicrophoneID })?.name ?? "Mic"), systemImage: "mic")
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
            Task { await startRecording() }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.white)
                    .frame(width: 8, height: 8)
                Text("Record")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.red))
        }
        .buttonStyle(.plain)
    }

    // MARK: – Helpers

    private func truncated(_ name: String, maxLength: Int = 16) -> String {
        name.count > maxLength ? String(name.prefix(maxLength - 1)) + "…" : name
    }

    private func startRecording() async {
        do {
            try await recorder.startRecording()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func stopRecording() async {
        do {
            try await recorder.stopRecordingAndExport()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
