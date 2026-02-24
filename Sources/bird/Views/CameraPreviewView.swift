import SwiftUI
import AVFoundation

struct CameraPreviewView: NSViewRepresentable {
    let cameraManager: CameraManager

    func makeNSView(context: Context) -> CameraPreviewNSView {
        CameraPreviewNSView(previewLayer: cameraManager.previewLayer)
    }

    func updateNSView(_ nsView: CameraPreviewNSView, context: Context) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        nsView.previewLayer.frame = nsView.bounds
        CATransaction.commit()
    }
}

final class CameraPreviewNSView: NSView {
    let previewLayer: AVCaptureVideoPreviewLayer

    init(previewLayer: AVCaptureVideoPreviewLayer) {
        self.previewLayer = previewLayer
        super.init(frame: .zero)
        wantsLayer = true
        previewLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(previewLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        CATransaction.commit()
    }
}
