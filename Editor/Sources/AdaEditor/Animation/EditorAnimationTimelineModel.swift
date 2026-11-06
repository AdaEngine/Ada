@_spi(AdaEngine) import AdaEngine
import Foundation
import Observation

/// Selection and gesture drafts belong to the open asset; every committed edit uses its shared service.
@Observable @MainActor
final class EditorAnimationTimelineModel {
    struct Key: Hashable { var track: String; var key: String }
    struct Row: Identifiable {
        var id: String
        var nodeID: String
        var label: String
        var depth: Int
        var channel: AnimationLibraryTrack.Channel?
        var track: AnimationLibraryTrack?
    }
    @ObservationIgnored weak var workspace: EditorAnimationAssetWorkspace?
    var selectedNodes: Set<String> = [] { didSet { synchronizeBoneSelection() } }
    var selectedKeys: Set<Key> = []
    var selectedTrackID: String?
    var selectedChannel: AnimationLibraryTrack.Channel?
    var expandedChannels: Set<String> = []
    var collapsedNodes: Set<String> = []
    var search = ""
    var selectedOnly = false
    var animatedOnly = false
    var channelFilter = "all"
    var showsModelPanel = true
    var modelPanelWidth: Float = 220
    var inspectorMode = "selection"
    private var requestedVerticalOffset: Float = 0
    var verticalOffset: Float {
        get { min(requestedVerticalOffset, max(0, Float(rows.count) * EditorAnimationTimeline.rowHeight - viewportSize.height + EditorAnimationTimeline.rulerHeight)) }
        set { requestedVerticalOffset = newValue.isFinite ? max(0, newValue) : 0 }
    }
    var timeOffset: Double = 0
    var pixelsPerSecond: Float = 160
    var viewportSize = Size.zero
    var snap: Double = 1 / 30
    var autoKey = false
    var speed: Double = 1
    var timeText = "0"
    var durationText = "1"
    var error = ""
    var dragDelta: Double = 0
    var marquee: Rect?
    var pointerEpoch: UInt64 = 0
    @ObservationIgnored var onCancelPointer: (() -> Void)?
    var poseValues: [String: [Float]] = [:]
    var poseRevision: String?
    struct PoseIdentity { let library: String; let clip: String; let time: Double; let revision: String }
    var poseIdentity: PoseIdentity?
    var queuedTime: Double?
    var queuedClip: String?
    var queuedMode: EditorAnimationAssetWorkspace.Mode?
    @ObservationIgnored private var selectionAnchor: String?
    @ObservationIgnored private var keyAnchor: Key?
    @ObservationIgnored private var dragRevision: String?
    @ObservationIgnored private var dragClip: AnimationLibraryClip?
    @ObservationIgnored private var dragLibraryID: String?
    @ObservationIgnored private var dragMode: EditorAnimationAssetWorkspace.Mode?
    @ObservationIgnored private var dragKeys: [(Key, AnimationLibraryKey)] = []

    var isEditable: Bool { workspace?.library?.isDiscarded == false && workspace?.mode != .clips }
    var library: AnimationLibrary? { isEditable ? workspace?.library?.library : workspace?.sourceLibrary }
    var clip: AnimationLibraryClip? {
        if isEditable { return library?.clips.first { $0.id == workspace?.library?.selectedClipID } ?? library?.clips.first }
        return library?.clips.first { $0.name == workspace?.sourceClip } ?? library?.clips.first
    }
    var duration: Double { clip?.duration ?? 0 }
    var time: Double {
        let clock = workspace?.preview.playbackTime ?? 0
        guard duration > 0, clock > duration else { return max(0, clock) }
        return clip?.repeats == true ? clock.truncatingRemainder(dividingBy: duration) : duration
    }
    var nodes: [AnimationRigBinding.Node] { library?.binding.nodes ?? workspace?.sourceLibrary?.binding.nodes ?? [] }
    var selectedNode: AnimationRigBinding.Node? { nodes.first { selectedNodes.contains($0.id) } }
    var selectedTrack: AnimationLibraryTrack? {
        let tracks = clip?.tracks ?? []
        if let track = tracks.first(where: { $0.id == selectedTrackID }), selectedNodes.isEmpty || selectedNodes.contains(track.nodeID) { return track }
        if !selectedNodes.isEmpty {
            return tracks.first { selectedNodes.contains($0.nodeID) && $0.channel == (selectedChannel ?? .rotation) }
                ?? (selectedChannel == nil ? tracks.first { selectedNodes.contains($0.nodeID) } : nil)
        }
        return tracks.first
    }
    var hasUnkeyedPose: Bool { !poseValues.isEmpty }

    var hierarchyRows: [Row] {
        let values = nodes
        let children = Dictionary(grouping: values, by: { $0.parentID ?? "" })
        var allowed: Set<String> = []
        if !search.isEmpty {
            let parents = values.reduce(into: [String: String]()) { $0[$1.id] = $1.parentID }
            for node in values where (node.name ?? node.id).localizedCaseInsensitiveContains(search) {
                var current: String? = node.id
                while let id = current, allowed.insert(id).inserted { current = parents[id] }
            }
        }
        var stack = (children[""] ?? []).reversed().map { ($0, 0) }
        var result: [Row] = []
        var visited: Set<String> = []
        while let (node, depth) = stack.popLast() {
            guard visited.insert(node.id).inserted else { continue }
            if search.isEmpty || allowed.contains(node.id) {
                result.append(.init(id: node.id, nodeID: node.id, label: node.name ?? node.id, depth: depth))
                if !collapsedNodes.contains(node.id) || !search.isEmpty {
                    for child in (children[node.id] ?? []).reversed() { stack.append((child, depth + 1)) }
                }
            }
        }
        return result
    }

    var rows: [Row] {
        let tracks = Dictionary(grouping: clip?.tracks ?? [], by: \.nodeID)
        return hierarchyRows.flatMap { row -> [Row] in
            if selectedOnly && !selectedNodes.contains(row.nodeID) { return [] }
            if animatedOnly && tracks[row.nodeID, default: []].isEmpty { return [] }
            guard expandedChannels.contains(row.nodeID) || channelFilter != "all" else { return [row] }
            let channels: [AnimationLibraryTrack.Channel] = [.translation, .rotation, .scale]
                + (tracks[row.nodeID, default: []].contains { $0.channel == .weights } ? [.weights] : [])
            return [row] + channels.filter { channelFilter == "all" || $0.rawValue == channelFilter }.map { channel in
                .init(id: row.nodeID + ":" + channel.rawValue, nodeID: row.nodeID,
                      label: L10n.tr(channel.rawValue), depth: row.depth + 1, channel: channel,
                      track: tracks[row.nodeID]?.first { $0.channel == channel })
            }
        }
    }

    func selectNode(_ id: String, additive: Bool = false, range: Bool = false) {
        let order = hierarchyRows.map(\.nodeID)
        if range, let anchor = selectionAnchor, let first = order.firstIndex(of: anchor), let last = order.firstIndex(of: id) {
            selectedNodes.formUnion(order[min(first, last)...max(first, last)])
        } else if additive {
            if !selectedNodes.insert(id).inserted { selectedNodes.remove(id) }
        } else { selectedNodes = [id] }
        selectionAnchor = id
        selectedTrackID = nil
        selectedChannel = nil
        keyAnchor = nil
        selectedKeys = []
        inspectorMode = "selection"
        workspace?.preview.showsBones = true
    }

    func selectSubtree(_ id: String) {
        selectNode(id)
        var changed = true
        while changed {
            changed = false
            for node in nodes where node.parentID.map(selectedNodes.contains) == true {
                if selectedNodes.insert(node.id).inserted { changed = true }
            }
        }
    }

    func seek(_ value: Double, discardPose: Bool = false) {
        guard value.isFinite else { return }
        if hasUnkeyedPose && !discardPose { queuedTime = value; return }
        poseValues = [:]
        poseRevision = nil
        poseIdentity = nil
        let clamped = max(0, min(duration, value))
        workspace?.preview.playsAnimation = false
        workspace?.applyModePreview()
        workspace?.preview.seekGraph(to: clamped)
        timeText = String(format: "%.4f", clamped)
    }

    func step(_ direction: Double, byKey: Bool) {
        let times = clip?.tracks.flatMap { $0.keys.map(\.time) }.sorted() ?? []
        let next = direction > 0 ? times.first { $0 > time + 0.000001 } : times.last { $0 < time - 0.000001 }
        seek(byKey ? next ?? (direction > 0 ? duration : 0) : time + direction * (snap > 0 ? snap : 1 / 30))
    }

    func selectClip(_ id: String) {
        if hasUnkeyedPose { queuedClip = id; return }
        let clock = time
        if let clip = workspace?.library?.library.clips.first(where: { $0.id == id }) {
            workspace?.mode = .keys
            workspace?.library?.selectedClipID = clip.id
        } else if let clip = workspace?.sourceLibrary?.clips.first(where: { $0.id == id }) {
            workspace?.mode = .clips
            workspace?.sourceClip = clip.name
        }
        selectedKeys = []
        selectedTrackID = nil
        selectedChannel = nil
        keyAnchor = nil
        seek(min(clock, duration))
        durationText = String(format: "%.5g", duration)
    }

    func resolveUnkeyedPose(key: Bool, cancel: Bool = false) {
        if cancel { queuedTime = nil; queuedClip = nil; queuedMode = nil; return }
        if key { perform { try insertKeys(channels: [.translation, .rotation, .scale]) }; if !error.isEmpty { return } }
        poseValues = [:]
        poseRevision = nil
        poseIdentity = nil
        workspace?.refreshLibrary()
        let nextTime = queuedTime
        let nextClip = queuedClip
        let nextMode = queuedMode
        queuedTime = nil; queuedClip = nil; queuedMode = nil
        if let nextClip { selectClip(nextClip) }
        if let nextTime { seek(nextTime) }
        if let nextMode { workspace?.mode = nextMode; inspectorMode = nextMode == .graph ? "graph" : "selection" }
    }

    func keys(in row: Row, timeRange: ClosedRange<Double>? = nil) -> [(Key, AnimationLibraryKey)] {
        (row.track.map { [$0] } ?? (clip?.tracks.filter { $0.nodeID == row.nodeID } ?? [])).flatMap { track in
            guard let timeRange else { return track.keys.map { (Key(track: track.id, key: $0.id), $0) } }
            func lowerBound(_ time: Double) -> Int {
                var low = 0, high = track.keys.count
                while low < high {
                    let middle = (low + high) / 2
                    if track.keys[middle].time < time { low = middle + 1 } else { high = middle }
                }
                return low
            }
            func visible(_ range: ClosedRange<Double>) -> [(Key, AnimationLibraryKey)] {
                let start = lowerBound(range.lowerBound)
                var end = lowerBound(range.upperBound)
                if end < track.keys.count, track.keys[end].time == range.upperBound { end += 1 }
                return track.keys[start..<end].map { (Key(track: track.id, key: $0.id), $0) }
            }
            var result = visible(timeRange)
            if dragDelta != 0 {
                let present = Set(result.map(\.0))
                result += visible((timeRange.lowerBound - dragDelta)...(timeRange.upperBound - dragDelta)).filter {
                    selectedKeys.contains($0.0) && !present.contains($0.0)
                }
            }
            return result
        }
    }

    func selectKey(_ reference: Key, additive: Bool = false, range: Bool = false) {
        if range, let anchor = keyAnchor,
           let first = clip?.tracks.first(where: { $0.id == anchor.track })?.keys.first(where: { $0.id == anchor.key }),
           let last = clip?.tracks.first(where: { $0.id == reference.track })?.keys.first(where: { $0.id == reference.key }) {
            let span = min(first.time, last.time)...max(first.time, last.time)
            let tracks = Set([anchor.track, reference.track])
            selectedKeys.formUnion((clip?.tracks ?? []).filter { tracks.contains($0.id) }.flatMap { track in
                track.keys.filter { span.contains($0.time) }.map { Key(track: track.id, key: $0.id) }
            })
        } else if !additive { selectedKeys = [reference] } else if !selectedKeys.insert(reference).inserted { selectedKeys.remove(reference) }
        keyAnchor = reference
        selectedTrackID = selectedKeys.contains(reference) ? reference.track : selectedKeys.sorted { $0.track < $1.track }.first?.track
        let tracks = Set(selectedKeys.map(\.track))
        selectedNodes = Set((clip?.tracks ?? []).filter { tracks.contains($0.id) }.map(\.nodeID))
        if let track = selectedTrack {
            selectedChannel = track.channel
            reveal(track.nodeID)
        }
        inspectorMode = "key"
    }

    func reveal(_ id: String) {
        let parents = nodes.reduce(into: [String: String]()) { $0[$1.id] = $1.parentID }
        var current = parents[id]
        var visited: Set<String> = []
        while let value = current, visited.insert(value).inserted { collapsedNodes.remove(value); current = parents[value] }
    }

    func beginKeyDrag() {
        dragRevision = workspace?.library?.revision
        dragClip = clip
        dragLibraryID = library?.id
        dragMode = workspace?.mode
        dragKeys = (clip?.tracks ?? []).flatMap { track in
            track.keys.compactMap { key in
                let ref = Key(track: track.id, key: key.id)
                return selectedKeys.contains(ref) ? (ref, key) : nil
            }
        }
        dragDelta = 0
    }

    func endKeyDrag(cancel: Bool = false) {
        defer { dragKeys = []; dragDelta = 0; dragRevision = nil; dragClip = nil; dragLibraryID = nil; dragMode = nil }
        guard !cancel, dragDelta != 0, let original = dragClip else { return }
        guard clip?.id == original.id, library?.id == dragLibraryID, workspace?.mode == dragMode else {
            error = L10n.tr("Animation selection changed during the drag.")
            return
        }
        perform {
            let refs = Set(dragKeys.map(\.0))
            let trackIDs = Set(refs.map(\.track))
            var edits: [AnimationEdit] = []
            for track in original.tracks where trackIDs.contains(track.id) {
                var replacement = track
                for index in replacement.keys.indices where refs.contains(.init(track: track.id, key: replacement.keys[index].id)) {
                    replacement.keys[index].time += dragDelta
                }
                replacement.keys.sort { $0.time < $1.time }
                // Every intermediate operation remains valid, including two-key cubic morph tracks.
                edits.append(.init(kind: .removeTrack, clipID: original.id, trackID: track.id))
                edits.append(.init(kind: .createTrack, clipID: original.id, track: replacement))
            }
            try apply(edits, revision: dragRevision)
        }
    }

    func cancelPointer() {
        pointerEpoch &+= 1
        onCancelPointer?()
        endKeyDrag(cancel: true)
        marquee = nil
    }

    func apply(_ edits: [AnimationEdit], revision: String? = nil) throws {
        guard isEditable, let workspace, let document = workspace.library, let service = workspace.service else {
            throw AnimationAuthoringError(.conflict, itemID: "timeline", message: L10n.tr("Extract an editable copy before changing keys."))
        }
        _ = try service.apply(path: document.relativePath, expectedRevision: revision ?? document.revision, operations: edits)
        workspace.refreshLibrary()
    }

    func configureDuration(_ value: Double) throws {
        guard let clip else { return }
        try apply([.init(kind: .configureClip, clipID: clip.id, duration: value)])
    }

    func deleteKeys() throws {
        guard let clip else { return }
        try apply(selectedKeys.map { .init(kind: .removeKey, clipID: clip.id, trackID: $0.track, keyID: $0.key) })
        selectedKeys = []
    }

    func perform(_ action: () throws -> Void) {
        do { try action(); error = "" } catch { self.error = error.localizedDescription }
    }

    func insertKeys(channels requestedChannels: [AnimationLibraryTrack.Channel]? = nil) throws {
        guard let library, let clip else { return }
        let channels = requestedChannels ?? selectedChannel.map { [$0] } ?? [.translation, .rotation, .scale]
        try requirePoseTarget()
        let sampled = try library.sample(clipID: clip.id, at: time)
        var edits: [AnimationEdit] = []
        for (index, node) in library.binding.nodes.enumerated() where selectedNodes.contains(node.id)
            || channels.contains(where: { poseValues[node.id + ":" + $0.rawValue] != nil }) {
            guard sampled.poses.indices.contains(index) else { continue }
            let pose = sampled.poses[index]
            for channel in channels {
                guard channel == .weights || node.restTranslation != nil else { continue }
                let value: [Float]
                switch channel {
                case .translation: value = [pose.translation.x, pose.translation.y, pose.translation.z]
                case .rotation: value = [pose.rotation.x, pose.rotation.y, pose.rotation.z, pose.rotation.w]
                case .scale: value = [pose.scale.x, pose.scale.y, pose.scale.z]
                case .weights: value = sampled.morphWeights[index]
                }
                let values = poseValues[node.id + ":" + channel.rawValue] ?? value
                guard !values.isEmpty else { continue }
                var track = clip.tracks.first { $0.nodeID == node.id && $0.channel == channel }
                if track == nil {
                    track = .init(nodeID: node.id, channel: channel)
                    edits.append(.init(kind: .createTrack, clipID: clip.id, track: track))
                }
                guard let track else { continue }
                let existing = track.keys.first { abs($0.time - time) < 0.0000001 }
                let zero = Array(repeating: Float(0), count: values.count)
                let key = AnimationLibraryKey(id: existing?.id ?? UUID().uuidString, time: existing?.time ?? time, value: values,
                    incoming: track.interpolation == .cubicSpline ? existing?.incoming ?? zero : nil,
                    outgoing: track.interpolation == .cubicSpline ? existing?.outgoing ?? zero : nil,
                    curve: existing?.curve)
                edits.append(.init(kind: .putKey, clipID: clip.id, trackID: track.id, key: key, replaceExisting: existing != nil))
            }
        }
        guard !edits.isEmpty else { return }
        try apply(edits, revision: poseRevision)
        poseValues = poseValues.filter { entry in !channels.contains { entry.key.hasSuffix(":" + $0.rawValue) } }
        if poseValues.isEmpty {
            poseRevision = nil
            poseIdentity = nil
            workspace?.refreshLibrary()
        } else if let identity = poseIdentity, let revision = workspace?.library?.revision {
            poseRevision = revision
            poseIdentity = .init(library: identity.library, clip: identity.clip, time: identity.time, revision: revision)
        }
    }

    func requestMode(_ mode: EditorAnimationAssetWorkspace.Mode) {
        if hasUnkeyedPose { queuedMode = mode; return }
        workspace?.mode = mode
        inspectorMode = mode == .graph ? "graph" : "selection"
    }

    func synchronizeBoneSelection() {
        workspace?.preview.selectedNodeIndices = Set(nodes.enumerated().filter { selectedNodes.contains($0.element.id) }.map(\.offset))
    }
}
