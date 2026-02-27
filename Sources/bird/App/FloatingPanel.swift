import AppKit
import SwiftUI

final class FloatingPanel: NSPanel {
    init<V: View>(contentView: V) {
        let hosting = NSHostingView(rootView: contentView)
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 58),
            styleMask: [.nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 940, height: 58))
        container.wantsLayer = true
        container.layer?.backgroundColor = CGColor.clear

        hosting.translatesAutoresizingMaskIntoConstraints = false
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = CGColor.clear
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        self.contentView = container
        isFloatingPanel = true
        level = .floating
        isMovableByWindowBackground = true
        backgroundColor = .clear
        hasShadow = true
        isOpaque = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

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
