extension CompiledAnimationGraph {
    /// Marker crossings run on the playback clock, even when visual pose sampling is skipped.
    /// Work and queue growth are bounded for long stalls; the player reports dropped occurrences.
    mutating func events(from start: Double, to end: Double, clips: [SkeletalAnimationClip], capacity: Int) -> (events: [AnimationGraphEvent], dropped: Int) {
        guard start != end else {
            return ([], 0)
        }
        for index in contributions.indices { contributions[index] = 0 }
        contributions[root] = 1
        for index in order.reversed() {
            let node = graph.nodes[index]
            let total = node.inputs.reduce(Float.zero) { $0 + $1.weight }
            for edge in node.inputs.indices {
                guard masks[index][edge].contains(where: { $0 > 0 }) else { continue }
                let weight = node.inputs[edge].weight
                let factor = node.kind == .blend ? weight / max(1, total) : min(1, weight)
                contributions[inputs[index][edge]] = min(1, contributions[inputs[index][edge]] + contributions[index] * factor)
            }
        }
        var result: [AnimationGraphEvent] = []
        var dropped = 0
        for index in order {
            guard let clipIndex = clipIndices[index], contributions[index] > 0 else { continue }
            let node = graph.nodes[index]
            let clip = clips[clipIndex]
            let a = Self.clipTime(start, node: node, duration: clip.duration)
            let b = Self.clipTime(end, node: node, duration: clip.duration)
            guard a != b, node.speed != 0 else { continue }
            for marker in node.events {
                var first: Double = 0
                var last: Double = 0
                if node.repeats && clip.duration > 0 {
                    // (start, end] forward and [end, start) reverse, including wrapped zero markers.
                    if b > a {
                        first = ((a - marker.time) / clip.duration).rounded(.down) + 1
                        last = ((b - marker.time) / clip.duration).rounded(.down)
                    } else {
                        first = ((b - marker.time) / clip.duration).rounded(.up)
                        last = ((a - marker.time) / clip.duration).rounded(.up) - 1
                    }
                } else {
                    let crossed = b > a ? marker.time > a && marker.time <= b : marker.time >= b && marker.time < a
                    if !crossed { continue }
                }
                guard first.isFinite, last.isFinite, last >= first else { continue }
                let count = last - first + 1
                let available = max(0, capacity - result.count)
                let emitted = Int(min(Double(available), count))
                dropped += Int(min(Double(Int.max / 65_536), max(0, count - Double(emitted))))
                for offset in 0..<emitted {
                    let cycle = b > a ? first + Double(offset) : last - Double(offset)
                    let occurrence = marker.time + (node.repeats ? cycle * clip.duration : 0)
                    let time = (occurrence - (node.speed < 0 ? clip.duration : 0)) / node.speed
                    result.append(AnimationGraphEvent(node: node.id, clip: clip.name, marker: marker, weight: contributions[index], graphTime: time))
                }
            }
        }
        result.sort {
            if $0.graphTime != $1.graphTime {
                return end > start ? $0.graphTime < $1.graphTime : $0.graphTime > $1.graphTime
            }
            if $0.node != $1.node {
                return $0.node < $1.node
            }
            return $0.marker.name < $1.marker.name
        }
        return (result, dropped)
    }
}
