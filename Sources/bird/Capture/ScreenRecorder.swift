import SwiftUI
import AppKit
import Combine
import ScreenCaptureKit
import AVFoundation
import CoreImage
import Foundation

final class ScreenRecorder: NSObject, ObservableObject {
    @Published var availableSources: [CaptureSource] = []
    @Published var availableCameras: [InputDevice] = []
    @Published var availableMicrophones: [InputDevice] = []
    @Published var previewImage: NSImage?
    @Published var statusText: String = "Idle"
    @Published var isWriting: Bool = false
    @Published var isRecording: Bool = false
    @Published var lastRecordingArtifacts: RecordingArtifacts?
    @Published var availableExportPresets: [ExportPreset] = ExportPreset.defaults
    @Published var selectedExportPresetID: String = ExportPreset.defaults.first?.id ?? "balanced"

    var selectedSourceKind: CaptureSourceKind = .display
    @Published var selectedSourceID: String = ""

    @Published var captureSystemAudio: Bool = true
    @Published var captureMicrophone: Bool = true
    @Published var captureCamera: Bool = true {
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
    private var captureSessionStartedAt: Date?
    private var captureEvents: [CaptureEvent] = []
    private var captureTimelineOffsetSeconds: Double = 0
    private var captureTargetRect: CGRect?
    private var captureTargetKind: CaptureSourceKind = .display
    private var captureMonitorCapabilities = CaptureMonitorCapabilities(mouseClickMonitor: false, mouseMoveMonitor: false, keyboardMonitor: false)
    private var hasLimitedCaptureTelemetry: Bool = false
    private var lastMouseMoveEventTime: TimeInterval = 0
    private let captureEventsQueue = DispatchQueue(label: "capture.events.queue")
    private var globalLeftClickMonitor: Any?
    private var globalRightClickMonitor: Any?
    private var globalMouseMoveMonitor: Any?
    private var globalKeyDownMonitor: Any?
    private var localKeyDownMonitor: Any?

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
            _ = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                AVCaptureDevice.requestAccess(for: .video) { continuation.resume(returning: $0) }
            }
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
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
        let exportPreset = activeExportPreset()
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(exportPreset.frameRate))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.capturesAudio = captureSystemAudio
        configuration.excludesCurrentProcessAudio = true
        configuration.showsCursor = true

        if let targetSize = captureTargetSize() {
            configuration.width = Int(targetSize.width)
            configuration.height = Int(targetSize.height)
        }

        do {
            try prepareWriter(configuration: configuration, preset: exportPreset)
            try startAuxiliaryCapture()
            beginCaptureEventTracking()

            let handler = ScreenStreamOutputHandler { [weak self] sampleBuffer, type in
                self?.handleStreamSampleBuffer(sampleBuffer, type: type)
            }
            streamOutput = handler

            let stream = SCStream(filter: contentFilter, configuration: configuration, delegate: nil)
            self.stream = stream

            try stream.addStreamOutput(handler, type: .screen, sampleHandlerQueue: outputQueue)
            if captureSystemAudio {
                try stream.addStreamOutput(handler, type: .audio, sampleHandlerQueue: outputQueue)
            }

            // Signal recording start before capture begins so the camera bubble
            // panel has time to hide before the first frame is captured.
            isRecording = true
            try? await Task.sleep(nanoseconds: 150_000_000) // 0.15s

            try await stream.startCapture()
            statusText = hasLimitedCaptureTelemetry ? "Recording (limited telemetry)" : "Recording"
        } catch {
            isRecording = false
            endCaptureEventTracking()
            self.stream = nil
            streamOutput = nil
            microphoneManager.stop()
            await finishWriting()
            throw error
        }
    }

    func stopRecordingAndExport() async throws {
        guard let stream else { return }
        isRecording = false
        statusText = "Finishing"

        defer {
            self.stream = nil
            streamOutput = nil
            endCaptureEventTracking()
            if !captureCamera {
                cameraManager.stop()
            }
            microphoneManager.stop()
        }

        try await stream.stopCapture()

        await finishWriting()

        statusText = "Saving"
        if let tempURL = outputURL {
            let finalURL: URL
            if let saveURL = try? autoSaveURL(for: activeExportPreset()) {
                do {
                    try FileManager.default.moveItem(at: tempURL, to: saveURL)
                    finalURL = saveURL
                } catch {
                    finalURL = tempURL
                }
            } else {
                finalURL = tempURL
            }
            let sidecars = try? writeCaptureMetadataSidecar(for: finalURL)
            lastRecordingArtifacts = RecordingArtifacts(
                videoURL: finalURL,
                eventsURL: sidecars?.eventsURL,
                timelineURL: sidecars?.timelineURL,
                savedAt: Date()
            )
            statusText = "Saved to \(finalURL.lastPathComponent)"
        }
    }

    func clearLastRecordingArtifacts() {
        lastRecordingArtifacts = nil
    }

    func activeExportPreset() -> ExportPreset {
        availableExportPresets.first(where: { $0.id == selectedExportPresetID }) ?? ExportPreset.defaults[0]
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

    private func prepareWriter(configuration: SCStreamConfiguration, preset: ExportPreset) throws {
        let width = configuration.width > 0 ? configuration.width : 1920
        let height = configuration.height > 0 ? configuration.height : 1080

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bird-\(UUID().uuidString)")
            .appendingPathExtension(preset.format.rawValue)
        self.outputURL = outputURL

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: preset.format.fileType)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: width * height * 6,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]

        let computedBitrate = max(width * height * preset.bitRateMultiplier, 2_000_000)
        var compression = (videoSettings[AVVideoCompressionPropertiesKey] as? [String: Any]) ?? [:]
        compression[AVVideoAverageBitRateKey] = computedBitrate
        compression[AVVideoExpectedSourceFrameRateKey] = preset.frameRate

        var finalVideoSettings = videoSettings
        finalVideoSettings[AVVideoCompressionPropertiesKey] = compression

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: finalVideoSettings)
        videoInput.expectsMediaDataInRealTime = true

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: attributes)

        guard writer.canAdd(videoInput) else {
            throw CaptureError.writerConfiguration("Video settings are not supported for \(preset.format.rawValue)")
        }
        writer.add(videoInput)

        if captureSystemAudio {
            let systemAudioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings())
            systemAudioInput.expectsMediaDataInRealTime = true
            guard writer.canAdd(systemAudioInput) else {
                throw CaptureError.writerConfiguration("System audio settings are not supported for \(preset.format.rawValue)")
            }
            writer.add(systemAudioInput)
            self.systemAudioInput = systemAudioInput
        }

        if captureMicrophone {
            let micAudioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings())
            micAudioInput.expectsMediaDataInRealTime = true
            guard writer.canAdd(micAudioInput) else {
                throw CaptureError.writerConfiguration("Microphone settings are not supported for \(preset.format.rawValue)")
            }
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
            captureEventsQueue.sync {
                if let startedAt = captureSessionStartedAt {
                    captureTimelineOffsetSeconds = max(0, Date().timeIntervalSince(startedAt))
                }
            }
        }

        switch type {
        case .screen:
            handleScreenSample(sampleBuffer)
        case .audio:
            handleSystemAudioSample(sampleBuffer)
        case .microphone:
            return
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

            // Circular mask via CIRadialGradient
            let extent = scaledCamera.extent
            let radius = min(extent.width, extent.height) / 2
            let center = CIVector(x: extent.midX, y: extent.midY)
            let circularCamera: CIImage
            if let gradientFilter = CIFilter(name: "CIRadialGradient") {
                gradientFilter.setValue(center, forKey: "inputCenter")
                gradientFilter.setValue(radius - 1, forKey: "inputRadius0")
                gradientFilter.setValue(radius,     forKey: "inputRadius1")
                gradientFilter.setValue(CIColor.white, forKey: "inputColor0")
                gradientFilter.setValue(CIColor.clear, forKey: "inputColor1")
                let mask = gradientFilter.outputImage!.cropped(to: extent)
                circularCamera = scaledCamera.applyingFilter("CIBlendWithMask", parameters: [
                    "inputBackgroundImage": CIImage(color: .clear).cropped(to: extent),
                    "inputMaskImage": mask
                ])
            } else {
                circularCamera = scaledCamera
            }

            let positionedCamera = circularCamera.transformed(by: CGAffineTransform(translationX: x, y: y))
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

    private func autoSaveURL(for preset: ExportPreset) throws -> URL {
        let docs = try FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let name = "Screen Recording \(formatter.string(from: Date())).\(preset.format.rawValue)"
        return docs.appendingPathComponent(name)
    }

    private func beginCaptureEventTracking() {
        captureEventsQueue.sync {
            captureSessionStartedAt = Date()
            captureEvents = []
            captureTimelineOffsetSeconds = 0
            captureTargetKind = selectedSourceKind
            captureTargetRect = currentCaptureTargetRect()
            captureMonitorCapabilities = CaptureMonitorCapabilities(mouseClickMonitor: false, mouseMoveMonitor: false, keyboardMonitor: false)
            lastMouseMoveEventTime = 0
        }

        globalLeftClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            self?.appendCaptureEvent(kind: .leftClick, event: event)
        }
        globalRightClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.rightMouseDown]) { [weak self] event in
            self?.appendCaptureEvent(kind: .rightClick, event: event)
        }
        globalMouseMoveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]) { [weak self] event in
            self?.appendCaptureEvent(kind: .mouseMove, event: event)
        }
        globalKeyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.appendKeyboardEvent(event: event)
        }
        localKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.appendKeyboardEvent(event: event)
            return event
        }

        captureEventsQueue.sync {
            captureMonitorCapabilities = CaptureMonitorCapabilities(
                mouseClickMonitor: globalLeftClickMonitor != nil && globalRightClickMonitor != nil,
                mouseMoveMonitor: globalMouseMoveMonitor != nil,
                keyboardMonitor: globalKeyDownMonitor != nil || localKeyDownMonitor != nil
            )
            hasLimitedCaptureTelemetry = !captureMonitorCapabilities.mouseClickMonitor || !captureMonitorCapabilities.mouseMoveMonitor || !captureMonitorCapabilities.keyboardMonitor
        }
    }

    private func endCaptureEventTracking() {
        if let monitor = globalLeftClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalLeftClickMonitor = nil
        }
        if let monitor = globalRightClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalRightClickMonitor = nil
        }
        if let monitor = globalMouseMoveMonitor {
            NSEvent.removeMonitor(monitor)
            globalMouseMoveMonitor = nil
        }
        if let monitor = globalKeyDownMonitor {
            NSEvent.removeMonitor(monitor)
            globalKeyDownMonitor = nil
        }
        if let monitor = localKeyDownMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyDownMonitor = nil
        }
    }

    private func appendCaptureEvent(kind: CaptureEventKind, event: NSEvent) {
        let globalLocation = NSEvent.mouseLocation
        captureEventsQueue.async { [weak self] in
            guard let self, let startedAt = self.captureSessionStartedAt else { return }
            guard let targetRect = self.captureTargetRect, targetRect.width > 0, targetRect.height > 0 else { return }

            if kind == .mouseMove {
                let now = event.timestamp
                guard now - self.lastMouseMoveEventTime >= (1.0 / 30.0) else { return }
                self.lastMouseMoveEventTime = now
            }

            let normalizedX = min(max((globalLocation.x - targetRect.minX) / targetRect.width, 0), 1)
            let normalizedY = min(max((globalLocation.y - targetRect.minY) / targetRect.height, 0), 1)

            self.captureEvents.append(CaptureEvent(
                kind: kind,
                timestampSeconds: Date().timeIntervalSince(startedAt),
                x: normalizedX,
                y: normalizedY,
                keyCode: nil,
                characters: nil,
                modifierFlags: nil
            ))
        }
    }

    private func appendKeyboardEvent(event: NSEvent) {
        let globalLocation = NSEvent.mouseLocation
        captureEventsQueue.async { [weak self] in
            guard let self, let startedAt = self.captureSessionStartedAt else { return }
            guard let targetRect = self.captureTargetRect, targetRect.width > 0, targetRect.height > 0 else { return }

            let normalizedX = min(max((globalLocation.x - targetRect.minX) / targetRect.width, 0), 1)
            let normalizedY = min(max((globalLocation.y - targetRect.minY) / targetRect.height, 0), 1)

            self.captureEvents.append(CaptureEvent(
                kind: .keyDown,
                timestampSeconds: Date().timeIntervalSince(startedAt),
                x: normalizedX,
                y: normalizedY,
                keyCode: event.keyCode,
                characters: event.charactersIgnoringModifiers,
                modifierFlags: event.modifierFlags.rawValue
            ))
        }
    }

    private func writeCaptureMetadataSidecar(for savedVideoURL: URL) throws -> (eventsURL: URL, timelineURL: URL) {
        let snapshot = captureEventsQueue.sync {
            (
                startedAt: captureSessionStartedAt,
                events: captureEvents,
                targetRect: captureTargetRect,
                targetKind: captureTargetKind,
                timelineOffsetSeconds: captureTimelineOffsetSeconds,
                monitorCapabilities: captureMonitorCapabilities
            )
        }

        guard let startedAt = snapshot.startedAt else {
            throw CaptureError.writerConfiguration("Missing capture session metadata")
        }
        defer {
            captureEventsQueue.sync {
                captureSessionStartedAt = nil
                captureEvents = []
                captureTargetRect = nil
                captureTimelineOffsetSeconds = 0
                hasLimitedCaptureTelemetry = false
            }
        }

        let target = snapshot.targetKind == .display ? "display" : "window"
        let rect = snapshot.targetRect.map {
            CaptureTargetRect(x: $0.origin.x, y: $0.origin.y, width: $0.width, height: $0.height)
        }

        let metadata = CaptureSessionMetadata(
            startedAtISO8601: ISO8601DateFormatter().string(from: startedAt),
            target: target,
            coordinateSpace: "normalized_capture_target_bottom_left_origin",
            targetRect: rect,
            timelineOffsetSeconds: snapshot.timelineOffsetSeconds,
            monitorCapabilities: snapshot.monitorCapabilities,
            events: snapshot.events
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(metadata)
        let metadataURL = savedVideoURL.deletingPathExtension().appendingPathExtension("events.json")
        try data.write(to: metadataURL, options: Data.WritingOptions.atomic)

        let timelineURL = try writeDraftTimelineSidecar(for: savedVideoURL, eventsURL: metadataURL, metadata: metadata)
        return (metadataURL, timelineURL)
    }

    private func writeDraftTimelineSidecar(for savedVideoURL: URL, eventsURL: URL, metadata: CaptureSessionMetadata) throws -> URL {
        let project = ZoomTimelineGenerator.makeDraftProject(
            metadata: metadata,
            sourceEventsFileName: eventsURL.lastPathComponent
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(project)
        let timelineURL = savedVideoURL.deletingPathExtension().appendingPathExtension("timeline.json")
        try data.write(to: timelineURL, options: Data.WritingOptions.atomic)
        return timelineURL
    }

    private func currentCaptureTargetRect() -> CGRect? {
        switch selectedSourceKind {
        case .display:
            guard let display = displayMap[selectedSourceID] else { return nil }
            return displayRect(for: display)
        case .window:
            return windowMap[selectedSourceID]?.frame
        }
    }

    private func displayRect(for display: SCDisplay) -> CGRect? {
        NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return CGDirectDisplayID(number.uint32Value) == display.displayID
        }?.frame
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
    case writerConfiguration(String)

    var errorDescription: String? {
        switch self {
        case .invalidSelection:
            return "Please select a valid display or window to record."
        case .deviceNotFound(let name):
            return "\(name) not found. Check device permissions."
        case .writerConfiguration(let message):
            return message
        }
    }
}
