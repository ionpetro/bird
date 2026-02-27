import Foundation
import AVFoundation

enum CaptureSourceKind: String, CaseIterable, Identifiable {
    case display
    case window

    var id: String { rawValue }
    var label: String {
        switch self {
        case .display: return "Entire Display"
        case .window: return "Single Window"
        }
    }
}

struct CaptureSource: Identifiable, Hashable {
    let id: String
    let label: String
}

struct InputDevice: Identifiable, Hashable {
    let id: String
    let name: String
}

enum ExportVideoFormat: String, CaseIterable, Identifiable {
    case mp4
    case mov

    var id: String { rawValue }

    var fileType: AVFileType {
        switch self {
        case .mp4: return .mp4
        case .mov: return .mov
        }
    }
}

struct ExportPreset: Identifiable, Hashable {
    let id: String
    let name: String
    let format: ExportVideoFormat
    let frameRate: Int
    let bitRateMultiplier: Int

    static let defaults: [ExportPreset] = [
        ExportPreset(id: "balanced", name: "Balanced 30 FPS", format: .mp4, frameRate: 30, bitRateMultiplier: 6),
        ExportPreset(id: "smooth", name: "Smooth 60 FPS", format: .mp4, frameRate: 60, bitRateMultiplier: 8),
        ExportPreset(id: "hq", name: "High Quality", format: .mov, frameRate: 60, bitRateMultiplier: 10)
    ]
}

enum CaptureEventKind: String, Codable {
    case leftClick
    case rightClick
    case mouseMove
    case keyDown
}

struct CaptureEvent: Codable {
    let kind: CaptureEventKind
    let timestampSeconds: Double
    let x: Double
    let y: Double
    let keyCode: UInt16?
    let characters: String?
    let modifierFlags: UInt?
}

struct CaptureSessionMetadata: Codable {
    let startedAtISO8601: String
    let target: String
    let coordinateSpace: String
    let targetRect: CaptureTargetRect?
    let timelineOffsetSeconds: Double
    let monitorCapabilities: CaptureMonitorCapabilities
    let events: [CaptureEvent]
}

struct CaptureMonitorCapabilities: Codable {
    let mouseClickMonitor: Bool
    let mouseMoveMonitor: Bool
    let keyboardMonitor: Bool
}

struct ZoomKeyframe: Codable, Identifiable {
    let id: String
    var startSeconds: Double
    var durationSeconds: Double
    var centerX: Double
    var centerY: Double
    var zoomScale: Double
    var sourceEventKind: CaptureEventKind
}

struct DraftTimelineProject: Codable {
    let version: Int
    let createdAtISO8601: String
    let sourceEventsFileName: String
    var zoomKeyframes: [ZoomKeyframe]
    var editing: DraftEditingSettings?
}

struct DraftEditingSettings: Codable {
    var trimStartSeconds: Double
    var trimEndSeconds: Double?
    var playbackRate: Double
    var aspectRatio: String

    static func defaults(for duration: Double) -> DraftEditingSettings {
        DraftEditingSettings(
            trimStartSeconds: 0,
            trimEndSeconds: duration > 0 ? duration : nil,
            playbackRate: 1.0,
            aspectRatio: "auto"
        )
    }
}

struct RecordingArtifacts {
    let videoURL: URL
    let eventsURL: URL?
    let timelineURL: URL?
    let savedAt: Date
}

struct CaptureTargetRect: Codable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}
