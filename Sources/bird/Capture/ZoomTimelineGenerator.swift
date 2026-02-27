import Foundation

enum ZoomTimelineGenerator {
    static func makeDraftProject(metadata: CaptureSessionMetadata, sourceEventsFileName: String) -> DraftTimelineProject {
        let keyframes = buildZoomKeyframes(from: metadata.events)
        return DraftTimelineProject(
            version: 1,
            createdAtISO8601: ISO8601DateFormatter().string(from: Date()),
            sourceEventsFileName: sourceEventsFileName,
            zoomKeyframes: keyframes,
            editing: nil
        )
    }

    private static func buildZoomKeyframes(from events: [CaptureEvent]) -> [ZoomKeyframe] {
        let sorted = events.sorted { $0.timestampSeconds < $1.timestampSeconds }
        let clickEvents = sorted.filter { $0.kind == .leftClick || $0.kind == .rightClick }

        var keyframes: [ZoomKeyframe] = []
        var lastAcceptedStart: Double = -.infinity

        for event in clickEvents {
            let start = max(0, event.timestampSeconds - 0.12)
            if start - lastAcceptedStart < 0.35 {
                continue
            }

            let keyframe = ZoomKeyframe(
                id: UUID().uuidString,
                startSeconds: start,
                durationSeconds: 1.5,
                centerX: event.x,
                centerY: event.y,
                zoomScale: event.kind == .rightClick ? 1.45 : 1.6,
                sourceEventKind: event.kind
            )
            keyframes.append(keyframe)
            lastAcceptedStart = start
        }

        if !keyframes.isEmpty {
            return keyframes
        }

        let fallbackPoints = sorted
            .filter { $0.kind == .mouseMove }
            .enumerated()
            .filter { offset, _ in offset % 45 == 0 }
            .map { $0.element }

        return fallbackPoints.map {
            ZoomKeyframe(
                id: UUID().uuidString,
                startSeconds: max(0, $0.timestampSeconds - 0.08),
                durationSeconds: 1.25,
                centerX: $0.x,
                centerY: $0.y,
                zoomScale: 1.35,
                sourceEventKind: .mouseMove
            )
        }
    }
}
