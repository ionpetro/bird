import AppKit
import SwiftUI

final class FloatingPanel: NSPanel {
    init<V: View>(contentView: V) {
        let hosting = NSHostingView(rootView: contentView)
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 836, height: 70),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.contentView = hosting
        isFloatingPanel = true
        level = .floating
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        backgroundColor = .clear
        hasShadow = true
        isOpaque = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
    }

    func centerAtBottom() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let x = visible.midX - frame.width / 2
        let y = visible.minY + 24
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    func setFrameAnimated(_ newFrame: NSRect) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().setFrame(newFrame, display: true)
        }
    }
}
