#if SAGA_RENDER && canImport(SAGACompiler)
    import SAGACore
    import SAGATypes

    /// Optional profiling work. The timestamps bracket the first and last eligible passes and include GPU work between them.
    struct SAGAVulkanTiming: Sendable {
        private static let byteCount: UInt64 = 16
        private let query: ResourceID
        private let resolve: ResourceID
        private let readback: ResourceID
        let commands: [BufferCommand]

        static func prepare(_ commands: [BufferCommand], on device: Device) async -> Self? {
            guard device.capabilities.features.contains(.timestampQuery),
                let first = commands.indices.first(where: { Self.supportsTimestamp(commands[$0]) }),
                let last = commands.indices.last(where: { Self.supportsTimestamp(commands[$0]) }),
                let query = try? await device.createQuerySet(.init(type: .timestamp, count: 2))
            else {
                return nil
            }
            guard let resolve = try? await device.createBuffer(.init(size: byteCount, usage: [.queryResolve, .copySource])) else {
                try? await device.destroyQuerySet(query)
                return nil
            }
            guard let readback = try? await device.createBuffer(.init(size: byteCount, usage: [.copyDestination, .mapRead])) else {
                try? await device.destroyBuffer(resolve)
                try? await device.destroyQuerySet(query)
                return nil
            }
            var measured = commands
            measured[first] = .timestamped(
                pass: commands[first],
                writes: .init(querySet: query, beginningOfPassWriteIndex: 0, endOfPassWriteIndex: first == last ? 1 : nil)
            )
            if first != last {
                measured[last] = .timestamped(pass: commands[last], writes: .init(querySet: query, endOfPassWriteIndex: 1))
            }
            measured.append(.resolveQuerySet(querySet: query, firstQuery: 0, queryCount: 2, destination: resolve))
            measured.append(.copy(source: resolve, destination: readback, byteCount: byteCount))
            measured.append(.read(buffer: readback, byteCount: byteCount))
            return Self(query: query, resolve: resolve, readback: readback, commands: measured)
        }

        func complete(_ ticket: CommandTicket, on device: Device) async throws -> Double? {
            let results: [[UInt32]]
            do {
                results = try await ticket.wait()
            } catch {
                await release(on: device)
                throw error
            }
            await release(on: device)
            guard let words = results.last, words.count == 4 else {
                return nil
            }
            let start = UInt64(words[0]) | UInt64(words[1]) << 32
            let end = UInt64(words[2]) | UInt64(words[3]) << 32
            guard end > start else {
                return nil
            }
            return Double(end - start) * device.capabilities.timestampPeriodNanoseconds / 1_000_000_000
        }

        func release(on device: Device) async {
            try? await device.destroyBuffer(readback)
            try? await device.destroyBuffer(resolve)
            try? await device.destroyQuerySet(query)
        }

        private static func supportsTimestamp(_ command: BufferCommand) -> Bool {
            switch command {
            case .dispatchCompute, .dispatchComputeRanges, .dispatchComputeIndirect, .render, .renderIndexed, .renderIndirect, .drawMesh:
                true
            default:
                false
            }
        }
    }
#endif
