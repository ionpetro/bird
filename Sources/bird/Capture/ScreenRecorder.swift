import SwiftUI
import AppKit
import Combine
import ScreenCaptureKit
import AVFoundation
import CoreImage

final class ScreenRecorder: NSObject, ObservableObject {
    @Published var availableSources: [CaptureSource] = []
    @Published var availableCameras: [InputDevice] = []
    @Published var availableMicrophones: [InputDevice] = []
    @Published var previewImage: NSImage?
    @Published var statusText: String = "Idle"
    @Published var isWriting: Bool = false
    @Published var isRecording: Bool = false

    var selectedSourceKind: CaptureSourceKind = .display
    @Published var selectedSourceID: String = ""

    @Published var captureSystemAudio: Bool = true
    @Published var captureMicrophone: Bool = false
    @Published var captureCamera: Bool = false {
        didSet { updateCameraPreview() }
    }

    @Published var selectedCameraID: String = "" {
        didSet { if captureCamera { updateCameraPreview() } }
    }
    @Published var selectedMicrophoneID: String = ""

    private var displayMap: [String: SCDisplay] = [:]
    private var windowMap: [String: SCWindow] = [:]

    private var stream: SCStream?
    private var streamOutput: ScreenStreamOutputHandler?
    private var outputQueue = DispatchQueue(label: "screen.stream.output.queue")

    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var systemAudioInput: AVAssetWriterInput?
    private var micAudioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var writerStartTime: CMTime?
    private var outputURL: URL?

    let cameraManager = CameraManager()
    private let microphoneManager = MicrophoneManager()

    private let ciContext = CIContext()
    private var lastPreviewUpdate: CFAbsoluteTime = 0

    override init() {
        super.init()
        reloadDevices()
    }

    func setSourceKind(_ kind: CaptureSourceKind) {
        selectedSourceKind = kind
        updateAvailableSources()
    }

    private func updateCameraPreview() {
        let shouldCapture = captureCamera && !selectedCameraID.isEmpty
        let deviceID = selectedCameraID
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            if shouldCapture {
                try? self.cameraManager.start(deviceID: deviceID)
            } else {
                self.cameraManager.stop()
            }
        }
    }

    func requestPermissions() async {
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                AVCaptureDevice.requestAccess(for: .video) { continuation.resume(returning: $0) }
            }
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
            }
        }
        await MainActor.run { self.reloadDevices() }
        await reloadSources()
    }

    func reloadSources() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let newDisplays = Dictionary(uniqueKeysWithValues: content.displays.map { (String($0.displayID), $0) })
            let onScreenWindows = content.windows.filter { $0.isOnScreen }
            let newWindows = Dictionary(uniqueKeysWithValues: onScreenWindows.map { (String($0.windowID), $0) })

            await MainActor.run {
                self.displayMap = newDisplays
                self.windowMap = newWindows
                self.updateAvailableSources()
                self.statusText = "Sources loaded"
            }
        } catch {
            await MainActor.run {
                self.statusText = "Screen recording permission required — grant access in System Settings > Privacy & Security > Screen Recording, then click Refresh Sources."
            }
        }
    }

    func startRecording() async throws {
        guard stream == nil else { return }

        guard let contentFilter = try makeContentFilter() else {
            throw CaptureError.invalidSelection
        }

        let configuration = SCStreamConfiguration()
        configuration.queueDepth = 6
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.capturesAudio = captureSystemAudio
        configuration.excludesCurrentProcessAudio = true
        configuration.showsCursor = true

        if let targetSize = captureTargetSize() {
            configuration.width = Int(targetSize.width)
            configuration.height = Int(targetSize.height)
        }

        try prepareWriter(configuration: configuration)
        try await startAuxiliaryCapture()

        let handler = ScreenStreamOutputHandler { [weak self] sampleBuffer, type in
            self?.handleStreamSampleBuffer(sampleBuffer, type: type)
        }
        streamOutput = handler

        let stream = SCStream(filter: contentFilter, configuration: configuration, delegate: nil)
        self.stream = stream

        try await stream.addStreamOutput(handler, type: .screen, sampleHandlerQueue: outputQueue)
        if captureSystemAudio {
            try await stream.addStreamOutput(handler, type: .audio, sampleHandlerQueue: outputQueue)
        }
        try await stream.startCapture()

        statusText = "Recording"
        isRecording = true
    }

    func stopRecordingAndExport() async throws {
        guard let stream else { return }
        isRecording = false
        statusText = "Finishing"

        try await stream.stopCapture()
        self.stream = nil
        streamOutput = nil

        if !captureCamera {
            cameraManager.stop()
        }
        microphoneManager.stop()

        await finishWriting()

        statusText = "Exporting"
        if let outputURL {
            if let saveURL = try await promptSaveURL(defaultName: "ScreenRecording.mp4") {
                if FileManager.default.fileExists(atPath: saveURL.path) {
                    try FileManager.default.removeItem(at: saveURL)
                }
                try FileManager.default.copyItem(at: outputURL, to: saveURL)
                statusText = "Saved to \(saveURL.lastPathComponent)"
            } else {
                statusText = "Export cancelled"
            }
            try? FileManager.default.removeItem(at: outputURL)
        }
    }

    private func updateAvailableSources() {
        switch selectedSourceKind {
        case .display:
            availableSources = displayMap.values
                .sorted { $0.displayID < $1.displayID }
                .map { CaptureSource(id: String($0.displayID), label: "Display \($0.displayID)") }
        case .window:
            availableSources = windowMap.values
                .sorted { $0.windowID < $1.windowID }
                .map { CaptureSource(id: String($0.windowID), label: $0.title ?? "Window \($0.windowID)") }
        }

        if let first = availableSources.first {
            selectedSourceID = first.id
        }
    }

    private func reloadDevices() {
        if AVCaptureDevice.authorizationStatus(for: .video) == .authorized {
            let cameraDevices = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .externalUnknown], mediaType: .video, position: .unspecified).devices
            availableCameras = cameraDevices.map { InputDevice(id: $0.uniqueID, name: $0.localizedName) }
            if selectedCameraID.isEmpty { selectedCameraID = availableCameras.first?.id ?? "" }
        }

        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
            let micDevices = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInMicrophone, .externalUnknown], mediaType: .audio, position: .unspecified).devices
            availableMicrophones = micDevices.map { InputDevice(id: $0.uniqueID, name: $0.localizedName) }
            if selectedMicrophoneID.isEmpty { selectedMicrophoneID = availableMicrophones.first?.id ?? "" }
        }
    }

    private func makeContentFilter() throws -> SCContentFilter? {
        switch selectedSourceKind {
        case .display:
            guard let display = displayMap[selectedSourceID] else { return nil }
            return SCContentFilter(display: display, excludingWindows: [])
        case .window:
            guard let window = windowMap[selectedSourceID] else { return nil }
            return SCContentFilter(desktopIndependentWindow: window)
        }
    }

    private func captureTargetSize() -> CGSize? {
        switch selectedSourceKind {
        case .display:
            guard let display = displayMap[selectedSourceID] else { return nil }
            return CGSize(width: display.width, height: display.height)
        case .window:
            guard let window = windowMap[selectedSourceID] else { return nil }
            return window.frame.size
        }
    }

    private func prepareWriter(configuration: SCStreamConfiguration) throws {
        let width = configuration.width > 0 ? configuration.width : 1920
        let height = configuration.height > 0 ? configuration.height : 1080

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bird-\(UUID().uuidString).mp4")
        self.outputURL = outputURL

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: width * height * 6,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: attributes)

        writer.add(videoInput)

        if captureSystemAudio {
            let systemAudioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings())
            systemAudioInput.expectsMediaDataInRealTime = true
            writer.add(systemAudioInput)
            self.systemAudioInput = systemAudioInput
        }

        if captureMicrophone {
            let micAudioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings())
            micAudioInput.expectsMediaDataInRealTime = true
            writer.add(micAudioInput)
            self.micAudioInput = micAudioInput
        }

        self.assetWriter = writer
        self.videoInput = videoInput
        self.adaptor = adaptor
        writerStartTime = nil
        isWriting = true
    }

    private func audioSettings() -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192000
        ]
    }

    private func startAuxiliaryCapture() throws {
        if captureCamera, !selectedCameraID.isEmpty, !cameraManager.isRunning {
            try cameraManager.start(deviceID: selectedCameraID)
        }

        if captureMicrophone, !selectedMicrophoneID.isEmpty {
            microphoneManager.onSampleBuffer = { [weak self] sampleBuffer in
                self?.handleMicrophoneSample(sampleBuffer)
            }
            try microphoneManager.start(deviceID: selectedMicrophoneID)
        }
    }

    private func handleStreamSampleBuffer(_ sampleBuffer: CMSampleBuffer, type: SCStreamOutputType) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let writer = assetWriter else { return }

        if writer.status == .unknown {
            writer.startWriting()
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            writer.startSession(atSourceTime: timestamp)
            writerStartTime = timestamp
        }

        switch type {
        case .screen:
            handleScreenSample(sampleBuffer)
        case .audio:
            handleSystemAudioSample(sampleBuffer)
        @unknown default:
            return
        }
    }

    private func handleScreenSample(_ sampleBuffer: CMSampleBuffer) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        guard let adaptor, let videoInput else { return }
        guard videoInput.isReadyForMoreMediaData else { return }

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        let cameraBuffer = captureCamera ? cameraManager.latestFrame()?.0 : nil
        guard let pixelBuffer = makeCompositedBuffer(screenBuffer: imageBuffer, cameraBuffer: cameraBuffer) else { return }
        adaptor.append(pixelBuffer, withPresentationTime: timestamp)

        updatePreviewIfNeeded(from: imageBuffer)
    }

    private func handleSystemAudioSample(_ sampleBuffer: CMSampleBuffer) {
        guard let systemAudioInput, systemAudioInput.isReadyForMoreMediaData else { return }
        systemAudioInput.append(sampleBuffer)
    }

    private func handleMicrophoneSample(_ sampleBuffer: CMSampleBuffer) {
        guard let micAudioInput, micAudioInput.isReadyForMoreMediaData else { return }
        micAudioInput.append(sampleBuffer)
    }

    private func makeCompositedBuffer(screenBuffer: CVPixelBuffer, cameraBuffer: CVPixelBuffer?) -> CVPixelBuffer? {
        guard let adaptor, let pool = adaptor.pixelBufferPool else { return nil }

        var outputBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outputBuffer)
        guard let outputBuffer else { return nil }

        let screenImage = CIImage(cvPixelBuffer: screenBuffer)
        var composed = screenImage

        if let cameraBuffer {
            let cameraImage = CIImage(cvPixelBuffer: cameraBuffer)

            let screenExtent = screenImage.extent
            let overlayWidth = screenExtent.width * 0.22
            let scale = overlayWidth / cameraImage.extent.width
            let scaledCamera = cameraImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let margin: CGFloat = 24
            let x = screenExtent.maxX - scaledCamera.extent.width - margin
            let y = screenExtent.minY + margin
            let positionedCamera = scaledCamera.transformed(by: CGAffineTransform(translationX: x, y: y))

            composed = positionedCamera.composited(over: screenImage)
        }

        ciContext.render(composed, to: outputBuffer)
        return outputBuffer
    }

    private func updatePreviewIfNeeded(from imageBuffer: CVPixelBuffer) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastPreviewUpdate > 0.25 else { return }
        lastPreviewUpdate = now

        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
        let nsImage = NSImage(cgImage: cgImage, size: .zero)
        DispatchQueue.main.async {
            self.previewImage = nsImage
        }
    }

    private func finishWriting() async {
        guard let writer = assetWriter else { return }
        isWriting = false

        if writer.status == .writing {
            videoInput?.markAsFinished()
            systemAudioInput?.markAsFinished()
            micAudioInput?.markAsFinished()

            await withCheckedContinuation { continuation in
                writer.finishWriting {
                    continuation.resume()
                }
            }
        } else {
            writer.cancelWriting()
        }

        assetWriter = nil
        videoInput = nil
        systemAudioInput = nil
        micAudioInput = nil
        adaptor = nil
    }

    private func promptSaveURL(defaultName: String) async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async {
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.mpeg4Movie]
                panel.nameFieldStringValue = defaultName
                panel.canCreateDirectories = true

                panel.begin { response in
                    if response == .OK {
                        continuation.resume(returning: panel.url)
                    } else {
                        continuation.resume(returning: nil)
                    }
                }
            }
        }
    }
}

final class ScreenStreamOutputHandler: NSObject, SCStreamOutput {
    private let onSampleBuffer: (CMSampleBuffer, SCStreamOutputType) -> Void

    init(onSampleBuffer: @escaping (CMSampleBuffer, SCStreamOutputType) -> Void) {
        self.onSampleBuffer = onSampleBuffer
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        onSampleBuffer(sampleBuffer, type)
    }
}

enum CaptureError: LocalizedError {
    case invalidSelection
    case deviceNotFound(String)

    var errorDescription: String? {
        switch self {
        case .invalidSelection:
            return "Please select a valid display or window to record."
        case .deviceNotFound(let name):
            return "\(name) not found. Check device permissions."
        }
    }
}
