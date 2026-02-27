import Foundation
import AVFoundation
import CoreImage

/// Applies zoom keyframes, trim, and speed effects to a recorded video.
enum VideoExporter {

    struct Options {
        var keyframes: [ZoomKeyframe]
        var trimStartSeconds: Double
        var trimEndSeconds: Double?
        var playbackRate: Double
    }

    // MARK: - Live Preview

    /// Returns an AVPlayerItem with zoom effects applied — use this to update the editor preview.
    static func makePreviewItem(videoURL: URL, options: Options) -> AVPlayerItem {
        let asset = AVURLAsset(url: videoURL)
        let item = AVPlayerItem(asset: asset)
        item.videoComposition = zoomComposition(for: asset, options: options, timingAdjusted: false)
        if let trimEnd = options.trimEndSeconds {
            item.forwardPlaybackEndTime = CMTime(seconds: trimEnd, preferredTimescale: 600)
        }
        return item
    }

    // MARK: - Export

    /// Exports the video with all effects baked in. Calls `onProgress` with 0…1 on the main actor.
    static func export(
        videoURL: URL,
        options: Options,
        outputURL: URL,
        onProgress: @escaping (Float) -> Void
    ) async throws {
        let asset = AVURLAsset(url: videoURL)
        let totalDuration = try await asset.load(.duration)
        let totalSeconds = CMTimeGetSeconds(totalDuration)

        let trimStart = CMTime(seconds: options.trimStartSeconds, preferredTimescale: 600)
        let trimEndSec = options.trimEndSeconds ?? totalSeconds
        let trimEnd = CMTime(seconds: trimEndSec, preferredTimescale: 600)
        let trimDuration = CMTimeSubtract(trimEnd, trimStart)

        // Build a mutable composition for trim + rate scaling
        let comp = AVMutableComposition()

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let srcVideo = videoTracks.first,
              let compVideo = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ExportError.noVideoTrack
        }
        let trimRange = CMTimeRange(start: trimStart, duration: trimDuration)
        try compVideo.insertTimeRange(trimRange, of: srcVideo, at: .zero)

        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        for srcAudio in audioTracks {
            if let compAudio = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try? compAudio.insertTimeRange(trimRange, of: srcAudio, at: .zero)
            }
        }

        // Time-scale all tracks for playback rate
        if abs(options.playbackRate - 1.0) > 0.001 {
            let originalRange = CMTimeRange(start: .zero, duration: trimDuration)
            let scaledDuration = CMTime(
                seconds: CMTimeGetSeconds(trimDuration) / options.playbackRate,
                preferredTimescale: 600
            )
            for track in comp.tracks {
                track.scaleTimeRange(originalRange, toDuration: scaledDuration)
            }
        }

        // Adjust keyframe times for trim + rate
        let adjustedKeyframes = options.keyframes.compactMap { kf -> ZoomKeyframe? in
            let start = (kf.startSeconds - options.trimStartSeconds) / options.playbackRate
            let duration = kf.durationSeconds / options.playbackRate
            guard start + duration > 0 else { return nil }
            var out = kf
            out.startSeconds = max(0, start)
            out.durationSeconds = duration
            return out
        }

        let adjustedOptions = Options(
            keyframes: adjustedKeyframes,
            trimStartSeconds: 0,
            trimEndSeconds: nil,
            playbackRate: 1.0
        )
        let videoComposition = zoomComposition(for: comp, options: adjustedOptions, timingAdjusted: true)

        guard let session = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else {
            throw ExportError.exportSessionFailed
        }
        session.videoComposition = videoComposition
        session.outputURL = outputURL
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true

        // Poll progress
        let pollingTask = Task {
            while !Task.isCancelled {
                let p = session.progress
                await MainActor.run { onProgress(p) }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        defer { pollingTask.cancel() }

        await session.export()

        if let error = session.error {
            throw error
        }
        await MainActor.run { onProgress(1.0) }
    }

    // MARK: - Video Composition

    private static func zoomComposition(for asset: AVAsset, options: Options, timingAdjusted: Bool) -> AVVideoComposition {
        let keyframes = options.keyframes
        let trimStart = timingAdjusted ? 0.0 : options.trimStartSeconds
        let rate = timingAdjusted ? 1.0 : options.playbackRate

        return AVVideoComposition(asset: asset, applyingCIFiltersWithHandler: { request in
            // Map composition time back to original keyframe time space
            let t = CMTimeGetSeconds(request.compositionTime)
            let originalT = t * rate + trimStart

            let source = request.sourceImage
            let result = Self.applyZoom(to: source, at: originalT, extent: source.extent, keyframes: keyframes)
            request.finish(with: result.cropped(to: source.extent), context: nil)
        })
    }

    // MARK: - Zoom Math

    private static func applyZoom(
        to image: CIImage,
        at t: Double,
        extent: CGRect,
        keyframes: [ZoomKeyframe]
    ) -> CIImage {
        var bestScale = 1.0
        var bestCX = 0.5
        var bestCY = 0.5

        for kf in keyframes {
            let end = kf.startSeconds + kf.durationSeconds
            guard t >= kf.startSeconds && t <= end else { continue }
            let progress = (t - kf.startSeconds) / kf.durationSeconds
            let scale = interpolatedScale(progress: progress, target: kf.zoomScale)
            if scale > bestScale {
                bestScale = scale
                bestCX = kf.centerX
                bestCY = kf.centerY
            }
        }

        guard bestScale > 1.001 else { return image }

        // Events use bottom-left origin; CoreImage also uses bottom-left — coordinates map directly.
        let cx = bestCX * extent.width
        let cy = bestCY * extent.height

        let roiW = extent.width / bestScale
        let roiH = extent.height / bestScale
        let roiX = max(0, min(cx - roiW / 2, extent.width - roiW))
        let roiY = max(0, min(cy - roiH / 2, extent.height - roiH))

        let transform = CGAffineTransform(translationX: -roiX, y: -roiY)
            .concatenating(CGAffineTransform(scaleX: CGFloat(bestScale), y: CGFloat(bestScale)))

        return image.transformed(by: transform)
    }

    /// Smooth zoom-in → hold → smooth zoom-out envelope.
    private static func interpolatedScale(progress: Double, target: Double) -> Double {
        let inEnd = 0.25
        let outStart = 0.75
        if progress <= inEnd {
            return 1.0 + (target - 1.0) * easeOut(progress / inEnd)
        } else if progress >= outStart {
            return 1.0 + (target - 1.0) * easeOut(1.0 - (progress - outStart) / (1.0 - outStart))
        } else {
            return target
        }
    }

    private static func easeOut(_ t: Double) -> Double {
        1.0 - (1.0 - t) * (1.0 - t)
    }
}

enum ExportError: LocalizedError {
    case noVideoTrack
    case exportSessionFailed

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "No video track found in the recording."
        case .exportSessionFailed: return "Failed to create export session."
        }
    }
}
