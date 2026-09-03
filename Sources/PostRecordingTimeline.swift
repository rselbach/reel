import Foundation

struct TimelineSpan: Equatable, Sendable {
    let start: Double
    let end: Double

    var duration: Double { end - start }
}

struct TimelineClip: Identifiable, Equatable, Sendable {
    let id: UUID
    let span: TimelineSpan
    var isDeleted: Bool
}

struct UnitPoint2D: Equatable, Hashable, Sendable {
    static let center = UnitPoint2D(uncheckedX: 0.5, y: 0.5)

    let x: Double
    let y: Double

    init?(x: Double, y: Double) {
        guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else {
            return nil
        }
        self.init(uncheckedX: x, y: y)
    }

    private init(uncheckedX x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

struct ZoomSceneSettings: Equatable, Sendable {
    struct Level: Equatable, Hashable, Sendable {
        static let minimumScale = 1.25
        static let maximumScale = 3.0
        static let sliderStep = 0.05

        let scale: Double

        init(scale: Double) {
            guard scale.isFinite else {
                self.scale = 1.5
                return
            }
            self.scale = min(max(scale, Self.minimumScale), Self.maximumScale)
        }

        private var percentage: Int { Int((scale * 100).rounded()) }

        var label: String {
            "\(percentage)%"
        }

        var accessibilityLabel: String {
            "\(percentage) percent"
        }
    }

    enum TransitionSpeed: Double, CaseIterable, Hashable, Sendable {
        case fast = 0.15
        case normal = 0.25
        case slow = 0.4

        var duration: Double { rawValue }

        var label: String {
            switch self {
            case .fast:
                return "Fast"
            case .normal:
                return "Normal"
            case .slow:
                return "Slow"
            }
        }
    }

    static let standard = ZoomSceneSettings(level: Level(scale: 1.5), transitionSpeed: .normal)

    var level: Level
    var transitionSpeed: TransitionSpeed
}

struct ZoomScene: Identifiable, Equatable, Sendable {
    let id: UUID
    let span: TimelineSpan
    var focalPoint: UnitPoint2D
    fileprivate(set) var settings: ZoomSceneSettings
}

enum ZoomSceneEditError: LocalizedError, Equatable {
    case duplicateID
    case invalidSpan
    case overlapsExistingScene
    case sceneNotFound

    var errorDescription: String? {
        switch self {
        case .duplicateID:
            return "A zoom scene with this identity already exists."
        case .invalidSpan:
            return "Zoom scenes must be at least 0.25 seconds and stay within the recording."
        case .overlapsExistingScene:
            return "Zoom scenes cannot overlap."
        case .sceneNotFound:
            return "The selected zoom scene no longer exists."
        }
    }
}

struct TimelineEdit: Equatable, Sendable {
    static let minimumDuration: Double = 0.5
    static let minimumClipDuration: Double = 0.05
    static let minimumZoomSceneDuration: Double = 0.25

    let sourceDuration: Double
    private(set) var clips: [TimelineClip]
    private(set) var zoomScenes: [ZoomScene]

    init?(sourceDuration: Double, initialClipID: UUID = UUID()) {
        guard sourceDuration.isFinite, sourceDuration > 0 else { return nil }
        self.sourceDuration = sourceDuration
        clips = [
            TimelineClip(
                id: initialClipID,
                span: TimelineSpan(start: 0, end: sourceDuration),
                isDeleted: false
            )
        ]
        zoomScenes = []
    }

    var keptRanges: [TimelineSpan] {
        var ranges: [TimelineSpan] = []
        for clip in clips where !clip.isDeleted {
            guard let previous = ranges.last, previous.end == clip.span.start else {
                ranges.append(clip.span)
                continue
            }
            ranges.removeLast()
            ranges.append(TimelineSpan(start: previous.start, end: clip.span.end))
        }
        return ranges
    }

    var deletedClips: [TimelineClip] {
        clips.filter(\.isDeleted)
    }

    var editedDuration: Double {
        keptRanges.reduce(0) { $0 + $1.duration }
    }

    var firstKeptTime: Double? {
        keptRanges.first?.start
    }

    var lastKeptTime: Double? {
        keptRanges.last?.end
    }

    var hasMeaningfulChanges: Bool {
        !deletedClips.isEmpty || !zoomScenes.isEmpty
    }

    func clip(id: TimelineClip.ID) -> TimelineClip? {
        clips.first { $0.id == id }
    }

    func clipID(at time: Double) -> TimelineClip.ID? {
        guard time.isFinite, time >= 0, time <= sourceDuration else { return nil }
        for (index, clip) in clips.enumerated() {
            let includesFinalBoundary = index == clips.count - 1 && time == clip.span.end
            if time >= clip.span.start && (time < clip.span.end || includesFinalBoundary) {
                return clip.id
            }
        }
        return nil
    }

    func zoomScene(id: ZoomScene.ID) -> ZoomScene? {
        zoomScenes.first { $0.id == id }
    }

    func zoomScene(atSourceTime time: Double) -> ZoomScene? {
        guard time.isFinite else { return nil }
        return zoomScenes.first { time >= $0.span.start && time < $0.span.end }
    }

    func availableZoomSpan(containing time: Double) -> TimelineSpan? {
        guard time.isFinite, time >= 0, time <= sourceDuration else { return nil }
        guard zoomScene(atSourceTime: time) == nil else { return nil }

        let start = zoomScenes.last { $0.span.end <= time }?.span.end ?? 0
        let end = zoomScenes.first { $0.span.start >= time }?.span.start ?? sourceDuration
        guard end - start >= Self.minimumZoomSceneDuration else { return nil }
        return TimelineSpan(start: start, end: end)
    }

    @discardableResult
    mutating func addZoomScene(
        span: TimelineSpan,
        focalPoint: UnitPoint2D = .center,
        settings: ZoomSceneSettings = .standard,
        id: UUID = UUID()
    ) throws -> ZoomScene.ID {
        guard zoomScene(id: id) == nil else {
            throw ZoomSceneEditError.duplicateID
        }
        try validateZoomSceneSpan(span)

        let scene = ZoomScene(
            id: id,
            span: span,
            focalPoint: focalPoint,
            settings: settings
        )
        let index = zoomScenes.firstIndex { $0.span.start > span.start } ?? zoomScenes.endIndex
        zoomScenes.insert(scene, at: index)
        return id
    }

    mutating func setZoomFocalPoint(_ point: UnitPoint2D, for id: ZoomScene.ID) throws {
        guard let index = zoomScenes.firstIndex(where: { $0.id == id }) else {
            throw ZoomSceneEditError.sceneNotFound
        }
        zoomScenes[index].focalPoint = point
    }

    mutating func setZoomSettings(
        _ settings: ZoomSceneSettings,
        for id: ZoomScene.ID
    ) throws {
        guard let index = zoomScenes.firstIndex(where: { $0.id == id }) else {
            throw ZoomSceneEditError.sceneNotFound
        }
        zoomScenes[index].settings = settings
    }

    func zoomSceneResizeBounds(id: ZoomScene.ID) -> TimelineSpan? {
        guard let index = zoomScenes.firstIndex(where: { $0.id == id }) else { return nil }
        let start = index == zoomScenes.startIndex ? 0 : zoomScenes[index - 1].span.end
        let end =
            index == zoomScenes.index(before: zoomScenes.endIndex)
            ? sourceDuration
            : zoomScenes[index + 1].span.start
        return TimelineSpan(start: start, end: end)
    }

    mutating func resizeZoomScene(id: ZoomScene.ID, to span: TimelineSpan) throws {
        guard let index = zoomScenes.firstIndex(where: { $0.id == id }) else {
            throw ZoomSceneEditError.sceneNotFound
        }
        try validateZoomSceneSpan(span, excluding: id)
        let scene = zoomScenes[index]
        zoomScenes[index] = ZoomScene(
            id: scene.id,
            span: span,
            focalPoint: scene.focalPoint,
            settings: scene.settings
        )
        zoomScenes.sort { $0.span.start < $1.span.start }
    }

    mutating func removeZoomScene(id: ZoomScene.ID) {
        zoomScenes.removeAll { $0.id == id }
    }

    private func validateZoomSceneSpan(
        _ span: TimelineSpan,
        excluding excludedID: ZoomScene.ID? = nil
    ) throws {
        guard
            span.start.isFinite,
            span.end.isFinite,
            span.start >= 0,
            span.end <= sourceDuration,
            span.duration >= Self.minimumZoomSceneDuration
        else {
            throw ZoomSceneEditError.invalidSpan
        }
        guard
            !zoomScenes.contains(where: { scene in
                scene.id != excludedID
                    && span.start < scene.span.end
                    && scene.span.start < span.end
            })
        else {
            throw ZoomSceneEditError.overlapsExistingScene
        }
    }

    func canSplit(at time: Double) -> Bool {
        guard let id = clipID(at: time), let clip = clip(id: id), !clip.isDeleted else {
            return false
        }
        return time - clip.span.start >= Self.minimumClipDuration
            && clip.span.end - time >= Self.minimumClipDuration
    }

    @discardableResult
    mutating func splitClip(at time: Double, rightClipID: UUID = UUID()) -> TimelineClip.ID? {
        guard canSplit(at: time), let id = clipID(at: time) else { return nil }
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return nil }
        let clip = clips[index]
        clips.replaceSubrange(
            index...index,
            with: [
                TimelineClip(
                    id: clip.id,
                    span: TimelineSpan(start: clip.span.start, end: time),
                    isDeleted: false
                ),
                TimelineClip(
                    id: rightClipID,
                    span: TimelineSpan(start: time, end: clip.span.end),
                    isDeleted: false
                ),
            ]
        )
        return rightClipID
    }

    func canDeleteClip(id: TimelineClip.ID) -> Bool {
        guard let clip = clip(id: id), !clip.isDeleted else { return false }
        let minimum = min(Self.minimumDuration, sourceDuration)
        return editedDuration - clip.span.duration >= minimum
    }

    @discardableResult
    mutating func deleteClip(id: TimelineClip.ID) -> Bool {
        guard canDeleteClip(id: id), let index = clips.firstIndex(where: { $0.id == id }) else {
            return false
        }
        clips[index].isDeleted = true
        return true
    }

    mutating func restoreClip(id: TimelineClip.ID) {
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return }
        clips[index].isDeleted = false
    }

    func playableSourceTime(atOrAfter time: Double) -> Double? {
        guard time.isFinite else { return nil }
        let clamped = min(max(0, time), sourceDuration)

        if let deleted = deletedClips.first(where: {
            clamped >= $0.span.start && clamped < $0.span.end
        }) {
            return keptRanges.first { $0.start >= deleted.span.end }?.start
        }

        for range in keptRanges {
            if clamped < range.start {
                return range.start
            }
            if clamped <= range.end {
                return clamped
            }
        }
        return nil
    }

    func sourceTime(forEditedTime time: Double) -> Double? {
        guard time.isFinite, time >= 0, time <= editedDuration else { return nil }
        var cursor = 0.0
        for (index, range) in keptRanges.enumerated() {
            let next = cursor + range.duration
            if time < next || index == keptRanges.count - 1 {
                return min(range.end, range.start + time - cursor)
            }
            cursor = next
        }
        return nil
    }

    func editedTime(forSourceTime time: Double) -> Double? {
        guard time.isFinite else { return nil }
        var cursor = 0.0
        for (index, range) in keptRanges.enumerated() {
            let includesFinalBoundary = index == keptRanges.count - 1 && time == range.end
            if time >= range.start && (time < range.end || includesFinalBoundary) {
                return cursor + time - range.start
            }
            cursor += range.duration
        }
        return nil
    }
}
