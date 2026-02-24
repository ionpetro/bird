import SwiftUI
import AppKit
import Combine

@main
struct BirdApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene { Settings { EmptyView() } }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let recorder = ScreenRecorder()
    var toolbarPanel: FloatingPanel?
    var cameraPanel: NSPanel?
    var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupToolbarPanel()
        setupCameraPanel()
        observeRecorderState()
        Task { await recorder.requestPermissions() }
    }

    // MARK: – Panel setup

    private func setupToolbarPanel() {
        let view = FloatingBarView(recorder: recorder)
        let panel = FloatingPanel(contentView: view)
        panel.centerAtBottom()
        panel.orderFront(nil)
        toolbarPanel = panel
    }

    private func setupCameraPanel() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = CGSize(width: 200, height: 200)
        let x = visible.maxX - size.width - 20
        let y = visible.minY + 20
        let panelFrame = NSRect(origin: NSPoint(x: x, y: y), size: size)

        let panel = NSPanel(
            contentRect: panelFrame,
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        let cameraView = CameraPreviewView(cameraManager: recorder.cameraManager)
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .overlay(
                RoundedRectangle(cornerRadius: 24)
                    .stroke(Color.black.opacity(0.6), lineWidth: 2)
            )
        panel.contentView = NSHostingView(rootView: cameraView)
        cameraPanel = panel
    }

    // MARK: – Observations

    private func observeRecorderState() {
        recorder.$isRecording
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording in
                self?.updateToolbarFrame(isRecording: isRecording)
            }
            .store(in: &cancellables)

        recorder.$captureCamera
            .receive(on: DispatchQueue.main)
            .sink { [weak self] captureCamera in
                guard let self else { return }
                if captureCamera {
                    self.cameraPanel?.orderFront(nil)
                } else {
                    self.cameraPanel?.orderOut(nil)
                }
            }
            .store(in: &cancellables)
    }

    private func updateToolbarFrame(isRecording: Bool) {
        guard let panel = toolbarPanel, let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let newFrame: NSRect
        if isRecording {
            let width: CGFloat = 156
            let height: CGFloat = 58
            let x = visible.midX - width / 2
            let y = visible.minY + 24
            newFrame = NSRect(x: x, y: y, width: width, height: height)
        } else {
            let width: CGFloat = 836
            let height: CGFloat = 70
            let x = visible.midX - width / 2
            let y = visible.minY + 24
            newFrame = NSRect(x: x, y: y, width: width, height: height)
        }
        panel.setFrameAnimated(newFrame)
    }
}
