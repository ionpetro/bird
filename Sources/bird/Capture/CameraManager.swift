import AVFoundation

final class CameraManager: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "camera.capture.queue")

    private var latestBuffer: CVPixelBuffer?
    private var latestTime: CMTime = .zero

    var isRunning: Bool { session.isRunning }

    lazy var previewLayer: AVCaptureVideoPreviewLayer = {
        let layer = AVCaptureVideoPreviewLayer(session: self.session)
        layer.videoGravity = .resizeAspectFill
        return layer
    }()

    func start(deviceID: String) throws {
        stop()

        guard let device = AVCaptureDevice(uniqueID: deviceID) else {
            throw CaptureError.deviceNotFound("Camera")
        }

        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        session.sessionPreset = .high
        if session.canAddInput(input) { session.addInput(input) }
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        session.startRunning()
    }

    func stop() {
        if session.isRunning {
            session.stopRunning()
        }
        session.beginConfiguration()
        for input in session.inputs {
            session.removeInput(input)
        }
        session.commitConfiguration()
        latestBuffer = nil
    }

    func latestFrame() -> (CVPixelBuffer, CMTime)? {
        queue.sync {
            guard let buffer = latestBuffer else { return nil }
            return (buffer, latestTime)
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        latestBuffer = imageBuffer
        latestTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    }
}
