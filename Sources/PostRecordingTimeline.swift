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

struct TimelineEdit: Equatable, Sendable {
    static let minimumDuration: Double = 0.5
    static let minimumClipDuration: Double = 0.05

    let sourceDuration: Double
    private(set) var clips: [TimelineClip]

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
        !deletedClips.isEmpty
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
