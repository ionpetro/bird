import SwiftUI
import AVFoundation
import AppKit
import Combine

struct RecordingEditorView: View {
    let artifacts: RecordingArtifacts

    @State private var project: DraftTimelineProject?
    @State private var selectedKeyframeID: String?
    @State private var player: AVPlayer = AVPlayer()
    @State private var durationSeconds: Double = 0
    @State private var currentSeconds: Double = 0
    @State private var playbackRate: Double = 1.0
    @State private var trimStartSeconds: Double = 0
    @State private var trimEndSeconds: Double = 0
    @State private var statusMessage: String = ""
    @State private var timeObserverToken: Any?

    @State private var isExporting = false
    @State private var exportProgress: Float = 0
    @State private var exportedURL: URL?
    @State private var showSidebar = true
    @State private var isPlaying = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            HStack(spacing: 0) {
                canvas
                if showSidebar {
                    Divider()
                    sidebar.frame(width: 268)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            controlsBar
            Divider()
            timelineBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, .dark)
        .onAppear {
            setupPlayer()
            installTimeObserver()
            loadProject()
        }
        .onReceive(Just(playbackRate).removeDuplicates()) { rate in
            if isPlaying { player.rate = Float(rate) }
        }
        .onDisappear {
            if let t = timeObserverToken { player.removeTimeObserver(t); timeObserverToken = nil }
        }
    }

    // MARK: – Top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            // Traffic-light offset
            Spacer().frame(width: 68)

            Text(artifacts.videoURL.deletingPathExtension().lastPathComponent)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)

            Spacer()

            if !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .transition(.opacity)
                    .animation(.easeInOut, value: statusMessage)
            }

            Button {
                withAnimation(.easeInOut(duration: 0.16)) { showSidebar.toggle() }
            } label: {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 14))
                    .foregroundColor(showSidebar ? .primary : .secondary)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(showSidebar ? 0.10 : 0)))
            }
            .buttonStyle(.plain)
            .help("Toggle Panels")

            exportButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var exportButton: some View {
        Button { Task { await exportVideo() } } label: {
            HStack(spacing: 5) {
                if isExporting {
                    ProgressView().scaleEffect(0.65).frame(width: 12, height: 12)
                    Text("\(Int(exportProgress * 100))%")
                } else {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 11, weight: .semibold))
                    Text("Export")
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(isExporting ? Color.secondary : Color.red))
        }
        .buttonStyle(.plain)
        .disabled(isExporting)
        .keyboardShortcut("e", modifiers: [.command])
    }

    // MARK: – Canvas

    private var canvas: some View {
        ZStack {
            Color.black
            PlayerPreviewContainer(player: player)
                .aspectRatio(16 / 9, contentMode: .fit)
                .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: – Controls bar

    private var controlsBar: some View {
        HStack(spacing: 12) {
            // Playback
            Button { togglePlayback() } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])

            HStack(spacing: 3) {
                Text(fmt(currentSeconds)).font(.system(size: 12, weight: .semibold, design: .monospaced))
                Text("/").foregroundColor(.secondary).font(.system(size: 11))
                Text(fmt(durationSeconds)).font(.system(size: 12, design: .monospaced)).foregroundColor(.secondary)
            }

            pill

            Picker("", selection: $playbackRate) {
                Text("0.5×").tag(0.5)
                Text("1×").tag(1.0)
                Text("1.5×").tag(1.5)
                Text("2×").tag(2.0)
            }
            .pickerStyle(.menu).frame(width: 68).font(.system(size: 12))

            pill

            // Trim summary
            HStack(spacing: 4) {
                Image(systemName: "crop").font(.system(size: 10)).foregroundColor(.secondary)
                Text("\(fmt(trimStartSeconds)) – \(fmt(trimEndSeconds))")
                    .font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
            }

            Spacer()

            if let kfs = project?.zoomKeyframes, !kfs.isEmpty {
                Label("\(kfs.count) zoom\(kfs.count == 1 ? "" : "s")", systemImage: "plus.magnifyingglass")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }

            pill

            Button("Preview") { rebuildPreview() }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundColor(.secondary)
                .help("Rebuild player with zoom effects")

            Button("Save") { saveProject() }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundColor(.secondary)
                .keyboardShortcut("s", modifiers: [.command])

            if let url = exportedURL {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                        Text("Reveal").font(.system(size: 11))
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var pill: some View {
        Rectangle().fill(Color.primary.opacity(0.10)).frame(width: 0.5, height: 16)
    }

    // MARK: – Timeline bar

    private var timelineBar: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                let w   = geo.size.width
                let dur = max(durationSeconds, 0.1)

                ZStack(alignment: .leading) {
                    // Track
                    Color.accentColor.opacity(0.75)
                        .clipShape(RoundedRectangle(cornerRadius: 5))

                    // Out-of-trim darkening
                    let inX  = w * CGFloat(trimStartSeconds / dur)
                    let outX = w * CGFloat(trimEndSeconds / dur)
                    if inX > 0 {
                        Rectangle().fill(Color.black.opacity(0.5)).frame(width: inX)
                            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 5, bottomLeadingRadius: 5,
                                                              bottomTrailingRadius: 0, topTrailingRadius: 0))
                    }
                    if outX < w {
                        Rectangle().fill(Color.black.opacity(0.5)).frame(width: w - outX)
                            .offset(x: outX)
                            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0,
                                                              bottomTrailingRadius: 5, topTrailingRadius: 5))
                    }

                    // Keyframe markers
                    if let kfs = project?.zoomKeyframes {
                        ForEach(kfs) { kf in
                            let kx = w * CGFloat(kf.startSeconds / dur)
                            let kw = max(4, w * CGFloat(kf.durationSeconds / dur))
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.white.opacity(selectedKeyframeID == kf.id ? 0.35 : 0.18))
                                .frame(width: kw).padding(.vertical, 5)
                                .offset(x: kx)
                                .onTapGesture { selectedKeyframeID = kf.id; seek(to: kf.startSeconds) }
                        }
                    }

                    // Playhead
                    let px = max(0, min(w * CGFloat(currentSeconds / dur), w - 2))
                    Group {
                        Rectangle().fill(.white).frame(width: 2).offset(x: px)
                        Circle().fill(.white).frame(width: 12).offset(x: px - 5, y: -13)
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    let t = Double(v.location.x / w) * dur
                    currentSeconds = max(0, min(t, dur))
                    seek(to: currentSeconds)
                })
            }
            .frame(height: 36)
            .padding(.horizontal, 16).padding(.top, 10)

            // Trim handles
            HStack(spacing: 8) {
                Text("In").font(.system(size: 10)).foregroundColor(.secondary)
                Slider(value: $trimStartSeconds, in: 0...max(trimEndSeconds - 0.1, 0.1)).frame(maxWidth: 180)
                Text(fmt(trimStartSeconds)).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                Spacer()
                Text(fmt(trimEndSeconds)).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                Slider(value: $trimEndSeconds,
                       in: min(trimStartSeconds + 0.1, durationSeconds)...max(durationSeconds, trimStartSeconds + 0.1))
                    .frame(maxWidth: 180)
                Text("Out").font(.system(size: 10)).foregroundColor(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
    }

    // MARK: – Sidebar

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                sidebarSection("Zoom Keyframes") {
                    if let kfs = project?.zoomKeyframes, !kfs.isEmpty {
                        VStack(spacing: 2) { ForEach(kfs) { keyframeRow($0) } }
                    } else {
                        Text("No keyframes").font(.system(size: 11)).foregroundColor(.secondary)
                    }
                }

                if selectedKeyframeIndex != nil {
                    Divider()
                    sidebarSection("Edit Keyframe") { keyframeEditor }
                }

                Divider()

                sidebarSection("Export") {
                    VStack(spacing: 8) {
                        if isExporting {
                            VStack(spacing: 4) {
                                ProgressView(value: Double(exportProgress)).tint(.red)
                                Text("Exporting \(Int(exportProgress * 100))%")
                                    .font(.system(size: 11)).foregroundColor(.secondary)
                            }
                        }
                        Button { Task { await exportVideo() } } label: {
                            HStack {
                                Spacer()
                                Text(isExporting ? "Exporting…" : "Export MP4")
                                    .font(.system(size: 13, weight: .semibold))
                                Spacer()
                            }
                            .foregroundColor(.white)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 9).fill(isExporting ? Color.secondary : Color.red))
                        }
                        .buttonStyle(.plain).disabled(isExporting)

                        if let url = exportedURL {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                                Text(url.lastPathComponent).font(.system(size: 11)).lineLimit(1)
                                Spacer()
                                Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                    .buttonStyle(.plain).font(.system(size: 11)).foregroundColor(.secondary)
                            }
                        }
                    }
                }

                Spacer(minLength: 16)
            }
            .padding(14)
        }
    }

    private func sidebarSection<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary).tracking(0.6)
            content()
        }
    }

    private func keyframeRow(_ kf: ZoomKeyframe) -> some View {
        HStack(spacing: 8) {
            Rectangle().fill(Color.accentColor).frame(width: 3, height: 28).clipShape(Capsule())
            VStack(alignment: .leading, spacing: 2) {
                Text(kf.sourceEventKind == .leftClick ? "Left click" :
                     kf.sourceEventKind == .rightClick ? "Right click" : "Move")
                    .font(.system(size: 12, weight: .medium))
                Text("\(fmt(kf.startSeconds))  ·  ×\(String(format: "%.1f", kf.zoomScale))  ·  \(String(format: "%.1fs", kf.durationSeconds))")
                    .font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(
            selectedKeyframeID == kf.id ? Color.accentColor.opacity(0.12) : Color.clear
        ))
        .contentShape(Rectangle())
        .onTapGesture { selectedKeyframeID = kf.id; seek(to: kf.startSeconds) }
    }

    @ViewBuilder
    private var keyframeEditor: some View {
        if let i = selectedKeyframeIndex {
            VStack(spacing: 8) {
                kfRow("Start",
                      Binding(get: { project?.zoomKeyframes[i].startSeconds ?? 0 },
                              set: { project?.zoomKeyframes[i].startSeconds = max(0, min($0, durationSeconds)) }),
                      0...max(durationSeconds, 0.1), fmt(project?.zoomKeyframes[i].startSeconds ?? 0))

                kfRow("Duration",
                      Binding(get: { project?.zoomKeyframes[i].durationSeconds ?? 1 },
                              set: { project?.zoomKeyframes[i].durationSeconds = max(0.1, min($0, 6)) }),
                      0.1...6, String(format: "%.1fs", project?.zoomKeyframes[i].durationSeconds ?? 1))

                kfRow("Scale",
                      Binding(get: { project?.zoomKeyframes[i].zoomScale ?? 1 },
                              set: { project?.zoomKeyframes[i].zoomScale = max(1, min($0, 3)) }),
                      1...3, String(format: "%.2f×", project?.zoomKeyframes[i].zoomScale ?? 1))
            }
        }
    }

    private func kfRow(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, _ display: String) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 11)).foregroundColor(.secondary).frame(width: 52, alignment: .leading)
            Slider(value: value, in: range)
            Text(display).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary).frame(width: 40, alignment: .trailing)
        }
    }

    // MARK: – Helpers

    private var selectedKeyframeIndex: Int? {
        guard let id = selectedKeyframeID else { return nil }
        return project?.zoomKeyframes.firstIndex(where: { $0.id == id })
    }

    private func fmt(_ s: Double) -> String {
        guard s.isFinite else { return "0:00" }
        let t = Int(s.rounded(.down))
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    // MARK: – Player

    private func setupPlayer() {
        let item = AVPlayerItem(url: artifacts.videoURL)
        player.replaceCurrentItem(with: item)
        Task {
            guard let d = try? await item.asset.load(.duration), d.isNumeric else { return }
            await MainActor.run {
                durationSeconds = CMTimeGetSeconds(d)
                trimEndSeconds  = durationSeconds
                applyEditing()
            }
        }
    }

    private func installTimeObserver() {
        let interval = CMTime(seconds: 1 / 30.0, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            let s = CMTimeGetSeconds(time)
            if s.isFinite { currentSeconds = s }
            isPlaying = player.timeControlStatus == .playing
            if durationSeconds > 0 && trimEndSeconds > 0 && currentSeconds > trimEndSeconds {
                seek(to: trimStartSeconds); player.pause(); isPlaying = false
            }
        }
    }

    private func seek(to s: Double) {
        player.seek(to: CMTime(seconds: max(0, s), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func togglePlayback() {
        if player.timeControlStatus == .playing { player.pause(); isPlaying = false }
        else { player.rate = Float(playbackRate); player.play(); isPlaying = true }
    }

    private func rebuildPreview() {
        guard let project else { return }
        let t = currentSeconds
        let item = VideoExporter.makePreviewItem(
            videoURL: artifacts.videoURL,
            options: .init(keyframes: project.zoomKeyframes,
                           trimStartSeconds: trimStartSeconds,
                           trimEndSeconds: trimEndSeconds,
                           playbackRate: playbackRate)
        )
        player.replaceCurrentItem(with: item)
        seek(to: t)
        statusMessage = "Preview updated"
    }

    // MARK: – Export

    private func exportVideo() async {
        isExporting = true; exportProgress = 0; exportedURL = nil
        let out = artifacts.videoURL.deletingPathExtension().appendingPathExtension("processed.mp4")
        try? FileManager.default.removeItem(at: out)
        do {
            try await VideoExporter.export(
                videoURL: artifacts.videoURL,
                options: .init(keyframes: project?.zoomKeyframes ?? [],
                               trimStartSeconds: trimStartSeconds,
                               trimEndSeconds: trimEndSeconds,
                               playbackRate: playbackRate),
                outputURL: out,
                onProgress: { p in exportProgress = p }
            )
            exportedURL = out; statusMessage = "Export complete"
        } catch {
            statusMessage = "Export failed: \(error.localizedDescription)"
        }
        isExporting = false
    }

    // MARK: – Timeline

    private func loadProject() {
        guard let url = artifacts.timelineURL else { statusMessage = "No timeline file."; return }
        Task.detached(priority: .userInitiated) {
            guard let data   = try? Data(contentsOf: url),
                  let decoded = try? JSONDecoder().decode(DraftTimelineProject.self, from: data) else {
                await MainActor.run { statusMessage = "Failed to load timeline." }
                return
            }
            await MainActor.run {
                project = decoded
                selectedKeyframeID = decoded.zoomKeyframes.first?.id
                applyEditing()
                statusMessage = "\(decoded.zoomKeyframes.count) keyframe(s) — click Preview to apply zoom"
            }
        }
    }

    private func applyEditing() {
        guard let e = project?.editing else { return }
        trimStartSeconds = max(0, e.trimStartSeconds)
        if let end = e.trimEndSeconds { trimEndSeconds = max(trimStartSeconds + 0.1, min(end, durationSeconds)) }
        playbackRate = e.playbackRate
    }

    private func saveProject() {
        guard let url = artifacts.timelineURL, var proj = project else { return }
        proj.editing = DraftEditingSettings(trimStartSeconds: trimStartSeconds, trimEndSeconds: trimEndSeconds,
                                            playbackRate: playbackRate, aspectRatio: proj.editing?.aspectRatio ?? "auto")
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(proj) else { return }
        try? data.write(to: url, options: .atomic)
        project = proj; statusMessage = "Saved"
    }
}

// MARK: – Player view bridge

private struct PlayerPreviewContainer: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> PlayerLayerHostView {
        let v = PlayerLayerHostView(); v.playerLayer.player = player; return v
    }
    func updateNSView(_ v: PlayerLayerHostView, context: Context) { v.playerLayer.player = player }
}

private final class PlayerLayerHostView: NSView {
    let playerLayer = AVPlayerLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.addSublayer(playerLayer); playerLayer.videoGravity = .resizeAspect
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); playerLayer.frame = bounds }
}
