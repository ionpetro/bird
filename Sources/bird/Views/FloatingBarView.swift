import SwiftUI
import AppKit

// MARK: – Hover

private struct HoverModifier: ViewModifier {
    @State private var isHovered = false
    func body(content: Content) -> some View {
        content
            .brightness(isHovered ? 0.06 : 0)
            .scaleEffect(isHovered ? 1.03 : 1.0)
            .animation(.easeOut(duration: 0.1), value: isHovered)
            .onHover { h in
                isHovered = h
                h ? NSCursor.pointingHand.push() : NSCursor.pop()
            }
    }
}

private extension View {
    func hoverEffect() -> some View { modifier(HoverModifier()) }
    func pointerCursor() -> some View {
        onHover { h in h ? NSCursor.pointingHand.push() : NSCursor.pop() }
    }
}

// MARK: – Floating bar

struct FloatingBarView: View {
    @ObservedObject var recorder: ScreenRecorder
    @State private var selectedSourceKind: CaptureSourceKind = .display
    @State private var countdown: Int? = nil

    var body: some View {
        ZStack {
            if recorder.isRecording { miniPill } else { fullBar }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: recorder.isRecording)
        .environment(\.colorScheme, .dark)
    }

    // MARK: – Full toolbar

    private var fullBar: some View {
        VStack(spacing: 0) {
            mainRow
            if let artifacts = recorder.lastRecordingArtifacts {
                Divider().opacity(0.15).padding(.horizontal, 16)
                recentRow(artifacts).padding(.horizontal, 16).padding(.vertical, 9)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(glassPanel)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .onAppear { Task { await recorder.reloadSources() } }
    }

    private var glassPanel: some View {
        RoundedRectangle(cornerRadius: 20)
            .fill(.ultraThinMaterial)
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.primary.opacity(0.09), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.35), radius: 20, x: 0, y: 6)
    }

    // MARK: – Main row

    private var mainRow: some View {
        HStack(spacing: 10) {
            quitButton
            sep
            sourceSegment
            sourceMenu.pointerCursor()
            sep
            cameraMenu.pointerCursor()
            micMenu.pointerCursor()
            audioToggle.pointerCursor()
            sep
            presetMenu.pointerCursor()
            Spacer()
            recordButton
        }
    }

    private var sourceMenu: some View {
        Menu {
            if recorder.availableSources.isEmpty {
                Button("No Sources Found") {}
                    .disabled(true)
            } else {
                Picker("Source", selection: $recorder.selectedSourceID) {
                    ForEach(recorder.availableSources) { source in
                        Text(source.label).tag(source.id)
                    }
                }
            }
            Divider()
            Button("Refresh Sources") { Task { await recorder.reloadSources() } }
        } label: {
            controlChip(icon: "display", label: truncated(selectedSourceLabel, max: 28), active: true)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: – Quit

    private var quitButton: some View {
        Button { NSApp.terminate(nil) } label: {
            Circle()
                .fill(Color(red: 1.0, green: 0.23, blue: 0.19))
                .frame(width: 12, height: 12)
        }
        .buttonStyle(.plain)
        .hoverEffect()
    }

    private var sep: some View {
        Rectangle().fill(Color.primary.opacity(0.10)).frame(width: 0.5, height: 20)
    }

    // MARK: – Source segment

    private var sourceSegment: some View {
        HStack(spacing: 1) {
            sourceTab(.display, icon: "rectangle.on.rectangle", label: "Display")
            sourceTab(.window,  icon: "macwindow",              label: "Window")
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
    }

    private func sourceTab(_ kind: CaptureSourceKind, icon: String, label: String) -> some View {
        Button {
            selectedSourceKind = kind
            recorder.setSourceKind(kind)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11))
                Text(label).font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(selectedSourceKind == kind ? .primary : .secondary)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(selectedSourceKind == kind ? Color.primary.opacity(0.13) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: – Controls

    private var cameraMenu: some View {
        Menu {
            Toggle("Enable Camera", isOn: $recorder.captureCamera)
            if !recorder.availableCameras.isEmpty {
                Divider()
                Picker("Camera", selection: $recorder.selectedCameraID) {
                    ForEach(recorder.availableCameras) { c in Text(c.name).tag(c.id) }
                }.disabled(!recorder.captureCamera)
            }
        } label: {
            controlChip(icon: "camera", label: truncated(cameraName), active: recorder.captureCamera)
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    private var micMenu: some View {
        Menu {
            Toggle("Enable Mic", isOn: $recorder.captureMicrophone)
            if !recorder.availableMicrophones.isEmpty {
                Divider()
                Picker("Microphone", selection: $recorder.selectedMicrophoneID) {
                    ForEach(recorder.availableMicrophones) { m in Text(m.name).tag(m.id) }
                }.disabled(!recorder.captureMicrophone)
            }
        } label: {
            controlChip(icon: "mic", label: truncated(micName), active: recorder.captureMicrophone)
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    private var audioToggle: some View {
        Toggle(isOn: $recorder.captureSystemAudio) {
            controlChip(icon: "speaker.wave.2", label: "Audio", active: recorder.captureSystemAudio)
        }
        .toggleStyle(.button).buttonStyle(.plain)
    }

    private var presetMenu: some View {
        Menu {
            Picker("Preset", selection: $recorder.selectedExportPresetID) {
                ForEach(recorder.availableExportPresets) { p in Text(p.name).tag(p.id) }
            }
        } label: {
            controlChip(icon: "slider.horizontal.3", label: presetName, active: true)
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    private var selectedSourceLabel: String {
        recorder.availableSources.first(where: { $0.id == recorder.selectedSourceID })?.label ?? "Select Source"
    }

    private func controlChip(icon: String, label: String, active: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 11))
            Text(label).font(.system(size: 12, weight: .medium)).lineLimit(1)
        }
        .foregroundColor(active ? .primary : .secondary)
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(active ? 0.12 : 0.05))
        )
    }

    // MARK: – Record button (brand accent — only CTA)

    private var recordButton: some View {
        Button {
            guard countdown == nil else { return }
            Task { await startRecording() }
        } label: {
            ZStack {
                if let n = countdown {
                    Text("\(n)")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .id(n)
                        .transition(.asymmetric(
                            insertion: .scale(scale: 1.5).combined(with: .opacity),
                            removal:   .scale(scale: 0.5).combined(with: .opacity)
                        ))
                } else {
                    HStack(spacing: 6) {
                        Circle().fill(.white).frame(width: 7, height: 7)
                        Text("Record").font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.16), value: countdown)
            .padding(.horizontal, 15).padding(.vertical, 8)
            .background(Capsule().fill(Color.red))
        }
        .buttonStyle(.plain)
        .hoverEffect()
    }

    // MARK: – Mini stop pill

    private var miniPill: some View {
        Button { Task { await stopRecording() } } label: {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 2).fill(.white).frame(width: 10, height: 10)
                Text("Stop").font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(
                Capsule(style: .continuous)
                    .fill(Color(red: 0.19, green: 0.57, blue: 0.52).opacity(0.95))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.white.opacity(0.30), lineWidth: 1)
            )
            .clipShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 4)
    }

    // MARK: – Recent recording strip

    private func recentRow(_ a: RecordingArtifacts) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundColor(.green).font(.system(size: 12))
            Text(a.videoURL.lastPathComponent)
                .font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
            Spacer()
            rowAction("Open")    { NSWorkspace.shared.open(a.videoURL) }
            rowAction("Reveal")  { NSWorkspace.shared.activateFileViewerSelecting([a.videoURL]) }
            rowAction("Dismiss") { recorder.clearLastRecordingArtifacts() }
        }
    }

    private func rowAction(_ label: String, action: @escaping () -> Void) -> some View {
        Button(label, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.secondary)
            .hoverEffect()
    }

    // MARK: – Computed helpers

    private var cameraName: String {
        recorder.availableCameras.first(where: { $0.id == recorder.selectedCameraID })?.name ?? "Camera"
    }
    private var micName: String {
        recorder.availableMicrophones.first(where: { $0.id == recorder.selectedMicrophoneID })?.name ?? "Mic"
    }
    private var presetName: String {
        recorder.availableExportPresets.first(where: { $0.id == recorder.selectedExportPresetID })?.name ?? "Preset"
    }

    private func truncated(_ s: String, max: Int = 14) -> String {
        s.count > max ? String(s.prefix(max - 1)) + "…" : s
    }

    private func showError(_ message: String) {
        let a = NSAlert()
        a.messageText = "Recording Error"
        a.informativeText = message
        a.alertStyle = .warning
        a.addButton(withTitle: "OK")
        a.runModal()
    }

    private func startRecording() async {
        if recorder.availableSources.isEmpty { await recorder.reloadSources() }
        for i in stride(from: 3, through: 1, by: -1) {
            countdown = i
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        countdown = nil
        do { try await recorder.startRecording() } catch { showError(error.localizedDescription) }
    }

    private func stopRecording() async {
        do { try await recorder.stopRecordingAndExport() } catch { showError(error.localizedDescription) }
    }
}
