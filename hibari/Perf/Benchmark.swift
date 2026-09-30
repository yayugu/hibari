#if PERF
import UIKit

@MainActor
final class Benchmark {
    enum Mode: String {
        case scroll
        case layout
        case gapfill
    }

    private let mode: Mode
    private weak var root: RootViewController?
    private var started = false
    private let monitor = FrameMonitor()

    init?(mode: String, root: RootViewController) {
        guard let mode = Mode(rawValue: mode) else { return nil }
        self.mode = mode
        self.root = root
    }

    func startIfNeeded() {
        guard !started, let root else { return }
        started = true
        switch mode {
        case .scroll: runScroll(root)
        case .layout: runLayout(root)
        case .gapfill: runGapFill(root)
        }
    }

    private var benchmarkTimelineIndex: Int {
        guard let root, let id = AppSettings.benchmarkTimeline else { return 0 }
        return root.timelines.firstIndex { $0.timelineID == id } ?? 0
    }

    private func runScroll(_ root: RootViewController) {
        let index = benchmarkTimelineIndex
        root.select(index, animated: false)
        guard let timeline = root.currentTimeline else { return }
        waitUntilLoaded(timeline) { [weak self] in
            timeline.loadAllPages {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self?.scroll(timeline, root: root)
                }
            }
        }
    }

    private func waitUntilLoaded(_ timeline: TimelineViewController, then body: @escaping () -> Void) {
        if timeline.isLoaded {
            body()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.waitUntilLoaded(timeline, then: body)
            }
        }
    }

    private func scroll(_ timeline: TimelineViewController, root: RootViewController) {
        let collectionView = timeline.collectionView
        let speed = AppSettings.benchmarkSpeed
        let startOffset = -collectionView.adjustedContentInset.top
        collectionView.setContentOffset(CGPoint(x: 0, y: startOffset), animated: false)

        let displayBefore = timeline.displayStats
        let imagesBefore = ImagePipeline.shared.stats.withLock { $0 }
        let rendersBefore = NoteRenderer.shared.stats.withLock { $0 }
        var offset = startOffset
        var last: CFTimeInterval?

        monitor.onFrame = { [weak self] link in
            let dt = last.map { link.timestamp - $0 } ?? 0
            last = link.timestamp
            offset += speed * dt
            let end = collectionView.contentSize.height - collectionView.bounds.height
                + collectionView.adjustedContentInset.bottom
            if offset >= end {
                collectionView.contentOffset.y = end
                self?.finishScroll(timeline, root: root, distance: end - startOffset, displayBefore: displayBefore,
                                   imagesBefore: imagesBefore, rendersBefore: rendersBefore)
            } else {
                collectionView.contentOffset.y = offset
            }
        }
        monitor.start()
    }

    private func finishScroll(
        _ timeline: TimelineViewController,
        root: RootViewController,
        distance: CGFloat,
        displayBefore: TimelineDisplayStats,
        imagesBefore: ImagePipeline.Stats,
        rendersBefore: NoteRenderer.Stats
    ) {
        monitor.stop()
        monitor.onFrame = nil
        let maxFPS = root.view.window?.windowScene?.screen.maximumFramesPerSecond ?? 60
        let frames = monitor.report(maximumFramesPerSecond: maxFPS)
        let display = timeline.displayStats
        let images = ImagePipeline.shared.stats.withLock { $0 }
        let renders = NoteRenderer.shared.stats.withLock { $0 }
        let blockRenders = renders.renders - rendersBefore.renders
        let imageDecodes = images.sourceDecodes - imagesBefore.sourceDecodes

        var result = Self.environment()
        result["mode"] = "scroll"
        result["timeline"] = timeline.timelineID
        result["notes"] = timeline.noteCount
        result["speedPointsPerSecond"] = AppSettings.benchmarkSpeed
        result["distancePoints"] = Double(distance)
        result["frames"] = Self.dictionary(frames)
        result["cellsDisplayed"] = display.cellsDisplayed - displayBefore.cellsDisplayed
        result["renderLate"] = display.renderLate - displayBefore.renderLate
        result["imagesLate"] = display.imagesLate - displayBefore.imagesLate
        result["blockRenders"] = blockRenders
        result["blockRenderMsAverage"] = blockRenders > 0
            ? (renders.renderSeconds - rendersBefore.renderSeconds) * 1000 / Double(blockRenders) : 0
        result["imageDecodes"] = imageDecodes
        result["imageDiskHits"] = images.diskHits - imagesBefore.diskHits
        result["imageProcessMsAverage"] = imageDecodes > 0
            ? (images.processingSeconds - imagesBefore.processingSeconds) * 1000 / Double(imageDecodes) : 0
        publish(result, in: root)
    }

    private func runGapFill(_ root: RootViewController) {
        let index = benchmarkTimelineIndex
        root.select(index, animated: false)
        guard let timeline = root.currentTimeline,
              let source = root.session.timelines[index].source as? FixtureTimelineSource
        else { return }
        let sensitiveMedia = AppSettings.sensitiveMedia(for: root.session.account)
        waitUntil({ timeline.isLoaded }) {
            timeline.loadAllPages {
                Task { @MainActor [weak self] in
                    let notes = (try? await source.allNotes()) ?? []
                    let expected = Set(notes.filter { !$0.isUnavailableRenote && sensitiveMedia.shows($0) }
                        .map(\.displayedNote.id)).count
                    await source.revealAll()
                    timeline.refresh(keepingPosition: true) {
                        self?.waitUntil({ !timeline.isFillingGap }) {
                            timeline.scrollBelowFirstGap(by: 40)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                self?.measureGapFill(timeline, root: root, expectedNotes: expected)
                            }
                        }
                    }
                }
            }
        }
    }

    private func measureGapFill(_ timeline: TimelineViewController, root: RootViewController, expectedNotes: Int) {
        let collectionView = timeline.collectionView
        let statsBefore = timeline.positionStats
        let finish: () -> Void = { [weak self] in
            self?.finishGapFill(timeline, root: root, expectedNotes: expectedNotes, statsBefore: statsBefore)
        }
        guard !AppSettings.benchmarkFlings else {
            let ready = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
            ready.isAccessibilityElement = true
            ready.accessibilityIdentifier = "benchmark.ready"
            root.view.addSubview(ready)
            monitor.onFrame = nil
            monitor.start()
            let deadline = Date(timeIntervalSinceNow: 180)
            waitUntil({
                Date() > deadline || (timeline.gapCount == 0 && timeline.isAtTop && !collectionView.isDragging
                    && !collectionView.isDecelerating)
            }, then: finish)
            return
        }
        let speed = AppSettings.benchmarkSpeed
        var last: CFTimeInterval?
        monitor.onFrame = { link in
            let dt = last.map { link.timestamp - $0 } ?? 0
            last = link.timestamp
            let top = -collectionView.adjustedContentInset.top
            let next = collectionView.contentOffset.y - speed * dt
            if next <= top {
                collectionView.contentOffset.y = top
                finish()
            } else {
                collectionView.contentOffset.y = next
            }
        }
        monitor.start()
    }

    private func finishGapFill(_ timeline: TimelineViewController, root: RootViewController, expectedNotes: Int,
                               statsBefore: TimelineViewController.PositionStats) {
        monitor.stop()
        monitor.onFrame = nil
        let maxFPS = root.view.window?.windowScene?.screen.maximumFramesPerSecond ?? 60
        let frames = monitor.report(maximumFramesPerSecond: maxFPS)
        let stats = timeline.positionStats
        let reloads = stats.reloads - statsBefore.reloads

        var result = Self.environment()
        result["mode"] = "gapfill"
        result["flings"] = AppSettings.benchmarkFlings
        result["timeline"] = timeline.timelineID
        result["notes"] = timeline.noteCount
        result["expectedNotes"] = expectedNotes
        result["gapsRemaining"] = timeline.gapCount
        result["frames"] = Self.dictionary(frames)
        result["reloads"] = reloads
        result["reloadMsAverage"] = reloads > 0 ? (stats.totalReloadMs - statsBefore.totalReloadMs) / Double(reloads) : 0
        result["reloadMsMax"] = stats.maxReloadMs
        result["maxJumpPoints"] = stats.maxJumpPoints
        result["reloadsWhileDecelerating"] = stats.reloadsWhileDecelerating - statsBefore.reloadsWhileDecelerating
        result["interruptedDecelerations"] = stats.interruptedDecelerations - statsBefore.interruptedDecelerations
        publish(result, in: root)
    }

    private func waitUntil(_ condition: @escaping () -> Bool, then body: @escaping () -> Void) {
        if condition() {
            body()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.waitUntil(condition, then: body)
            }
        }
    }

    private func runLayout(_ root: RootViewController) {
        guard let store = FixtureStore.shared else { return }
        let context = LayoutContext(width: root.view.bounds.width, safeAreaInsets: root.view.safeAreaInsets,
                                    traits: root.traitCollection, revealsSensitiveMedia: true)
        Task.detached(priority: .userInitiated) {
            let result = UncheckedSendable(Self.measureLayout(store: store, context: context, time: store.manifest.fetchedAt))
            await self.publish(result.value, in: root)
        }
    }

    nonisolated private static func measureLayout(store: FixtureStore, context: LayoutContext, time: Date) -> [String: Any] {
        func now() -> Double { CFAbsoluteTimeGetCurrent() }
        let temp = FileManager.default.temporaryDirectory.appending(path: "benchmark-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        let source = FixtureMediaSource(store: store)
        let pipeline = ImagePipeline(source: source, diskDirectory: temp)
        let resolver = EmojiResolver(localEmojis: store.localEmojis, mediaProxy: store.manifest.mediaProxy)

        var decodeMs: [Double] = []
        var notes: [Note] = []
        for timeline in store.timelines {
            for page in timeline.pages {
                let t = now()
                notes += (try? store.loadPage(page)) ?? []
                decodeMs.append((now() - t) * 1000)
            }
        }
        let items = notes.map { TimelineItem(note: $0) }

        var mfmMs: [Double] = []
        for text in notes.compactMap(\.displayedNote.text) {
            let t = now()
            _ = MFMParser.parse(text)
            mfmMs.append((now() - t) * 1000)
        }

        let engine = NoteLayoutEngine(emojiResolver: resolver, sizes: source)
        var layoutMs: [Double] = []
        var layouts: [NoteLayout] = []
        for item in items {
            let t = now()
            layouts.append(engine.layout(for: item, context: context, now: time))
            layoutMs.append((now() - t) * 1000)
        }

        let batchEngine = NoteLayoutEngine(emojiResolver: resolver, sizes: source)
        let batchStart = now()
        _ = batchEngine.layouts(for: items, context: context, now: time)
        let batchMs = (now() - batchStart) * 1000

        var renderColdMs: [Double] = []
        let coldRenderer = NoteRenderer(imagePipeline: pipeline)
        for layout in layouts {
            let t = now()
            coldRenderer.renderSynchronously(layout)
            renderColdMs.append((now() - t) * 1000)
        }
        var renderWarmMs: [Double] = []
        let warmRenderer = NoteRenderer(imagePipeline: pipeline)
        for layout in layouts {
            let t = now()
            warmRenderer.renderSynchronously(layout)
            renderWarmMs.append((now() - t) * 1000)
        }

        var seen = Set<String>()
        var imageMs: [Double] = []
        var imagePixels = 0
        for request in layouts.flatMap(\.imageRequests) where seen.insert(request.cacheKey).inserted {
            let t = now()
            if pipeline.imageSynchronously(for: request) != nil {
                imageMs.append((now() - t) * 1000)
                imagePixels += request.pixelWidth * request.pixelHeight
            }
        }
        let diskPipeline = ImagePipeline(source: source, diskDirectory: temp)
        var diskMs: [Double] = []
        for key in seen.prefix(200) {
            guard let request = layouts.lazy.flatMap(\.imageRequests).first(where: { $0.cacheKey == key }) else { continue }
            let t = now()
            _ = diskPipeline.imageSynchronously(for: request)
            diskMs.append((now() - t) * 1000)
        }

        var result = environment()
        result["mode"] = "layout"
        result["notes"] = items.count
        result["canvasWidth"] = Double(context.canvasWidth)
        result["jsonDecodeMsPerPage"] = summary(decodeMs)
        result["layoutMsPerNote"] = summary(layoutMs)
        result["layoutBatchMsTotal"] = batchMs
        result["renderColdMsPerNote"] = summary(renderColdMs)
        result["renderWarmMsPerNote"] = summary(renderWarmMs)
        result["imageProcessMsPerImage"] = summary(imageMs)
        result["imageDiskCacheMsPerImage"] = summary(diskMs)
        result["imagesProcessed"] = imageMs.count
        result["imageMegapixels"] = Double(imagePixels) / 1_000_000
        result["mfmParseMsPerNote"] = summary(mfmMs)
        let requested = Set(layouts.flatMap { $0.imageRequests.map(\.url) + $0.emojiRequests.map(\.url) })
        result["mediaRequested"] = requested.count
        result["mediaMissing"] = requested.filter { store.fileURL(forMedia: $0) == nil }.count
        return result
    }

    nonisolated private static func summary(_ values: [Double]) -> [String: Double] {
        guard !values.isEmpty else { return [:] }
        let sorted = values.sorted()
        func p(_ q: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * q))] }
        return [
            "count": Double(values.count),
            "average": values.reduce(0, +) / Double(values.count),
            "p50": p(0.5),
            "p95": p(0.95),
            "max": sorted.last ?? 0,
        ]
    }

    nonisolated private static func environment() -> [String: Any] {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
        #if targetEnvironment(simulator)
        let simulator = true
        #else
        let simulator = false
        #endif
        #if DEBUG
        let configuration = "Debug"
        #else
        let configuration = "Release"
        #endif
        return [
            "machine": ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? machine,
            "simulator": simulator,
            "configuration": configuration,
            "system": ProcessInfo.processInfo.operatingSystemVersionString,
        ]
    }

    private static func dictionary(_ report: FrameMonitor.Report) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(report),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    private func publish(_ result: [String: Any], in root: RootViewController) {
        let data = (try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])) ?? Data()
        let json = String(decoding: data, as: UTF8.self)
        let url = URL.documentsDirectory.appending(path: "benchmark-\(mode.rawValue).json")
        try? data.write(to: url)
        print("HIBARI_BENCHMARK_RESULT \(json)")

        let panel = UILabel()
        panel.numberOfLines = 0
        panel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        panel.textColor = .white
        panel.backgroundColor = UIColor.black.withAlphaComponent(0.85)
        panel.text = json
        panel.accessibilityIdentifier = "benchmark.result"
        panel.accessibilityValue = json
        let safe = root.view.safeAreaInsets
        panel.frame = root.view.bounds.inset(by: UIEdgeInsets(top: safe.top + 72, left: 12, bottom: safe.bottom + 72, right: 12))
        panel.layer.cornerRadius = 8
        panel.layer.masksToBounds = true
        root.view.addSubview(panel)
    }
}
#endif
