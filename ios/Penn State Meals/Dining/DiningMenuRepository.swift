import Foundation

enum DiningFetchPolicy: Sendable, Equatable {
    case cacheOnly
    case cacheElseLoad
    case revalidateIfStale
    case reloadDiscardingCache
}

enum DiningRepositoryError: Error, Sendable, Equatable {
    case cacheMiss(MenuDayKey)
    case obsoleteRequest
    case invalidSnapshot
}

actor DefaultDiningMenuRepository {
    private static let memoryCacheLimit = 10

    typealias PreferredPeriodResolver = PSUMenuSourceAdapterImpl.PreferredPeriodResolver
    typealias SnapshotProgress = @concurrent @Sendable (MenuDaySnapshot) async -> Void
    typealias SnapshotLoader = @concurrent @Sendable (
        MenuDayKey,
        PreferredPeriodResolver?,
        SnapshotProgress?
    ) async throws -> MenuDaySnapshot
    typealias StalenessCheck = @concurrent @Sendable (MenuDaySnapshot, Date) async -> Bool

    private struct InFlight: Sendable {
        let generation: UInt64
        let task: Task<MenuDaySnapshot, any Error>
        var progressHandlers: [UUID: SnapshotProgress]
        var waiterCount: Int
    }

    private let readsSharedStore: Bool
    private let fileStore: MenuSnapshotFileStore
    private let loadSnapshot: SnapshotLoader
    private let isStale: StalenessCheck
    private var memoryCache: [MenuDayKey: MenuDaySnapshot] = [:]
    private var memoryAccessOrder: [MenuDayKey] = []
    private var inFlight: [MenuDayKey: InFlight] = [:]
    private var generations: [MenuDayKey: UInt64] = [:]

    init(
        fileStore: MenuSnapshotFileStore,
        readsSharedStore: Bool = false,
        loadSnapshot: @escaping SnapshotLoader,
        isStale: @escaping StalenessCheck = { @concurrent _, _ in true }
    ) {
        self.fileStore = fileStore
        self.readsSharedStore = readsSharedStore
        self.loadSnapshot = loadSnapshot
        self.isStale = isStale
    }

    func menu(
        for key: MenuDayKey,
        policy: DiningFetchPolicy,
        preferredPeriod: PreferredPeriodResolver? = nil,
        onPartialSnapshot: SnapshotProgress? = nil
    ) async throws -> MenuDaySnapshot {
        let cached = await cachedSnapshot(for: key)

        switch policy {
        case .cacheOnly:
            guard let cached else { throw DiningRepositoryError.cacheMiss(key) }
            return cached

        case .cacheElseLoad:
            if let cached {
                return cached
            }
            return try await networkResult(
                for: key,
                staleFallback: nil,
                preferredPeriod: preferredPeriod,
                onPartialSnapshot: onPartialSnapshot
            )

        case .revalidateIfStale:
            if let cached, !(await isStale(cached, .now)) {
                return cached
            }
            return try await networkResult(
                for: key,
                staleFallback: cached,
                preferredPeriod: preferredPeriod,
                onPartialSnapshot: onPartialSnapshot
            )

        case .reloadDiscardingCache:
            try await invalidate(key)
            return try await networkResult(
                for: key,
                staleFallback: cached,
                preferredPeriod: preferredPeriod,
                onPartialSnapshot: onPartialSnapshot
            )
        }
    }

    private func cachedSnapshot(for key: MenuDayKey) async -> MenuDaySnapshot? {
        if readsSharedStore { return await fileStore.snapshot(for: key) }
        if let snapshot = memoryCache[key] {
            Self.touch(key, in: &memoryAccessOrder)
            return snapshot
        }
        guard let snapshot = await fileStore.snapshot(for: key) else { return nil }
        cacheInMemory(snapshot)
        return snapshot
    }

    private func networkResult(
        for key: MenuDayKey,
        staleFallback: MenuDaySnapshot?,
        preferredPeriod: PreferredPeriodResolver?,
        onPartialSnapshot: SnapshotProgress?
    ) async throws -> MenuDaySnapshot {
        do {
            try Task.checkCancellation()
        } catch {
            throw error
        }
        let generation = generations[key, default: 0]
        let operation: InFlight
        let progressObserverID = onPartialSnapshot.map { _ in UUID() }
        if var existing = inFlight[key], existing.generation == generation {
            existing.waiterCount += 1
            if let progressObserverID, let onPartialSnapshot {
                existing.progressHandlers[progressObserverID] = onPartialSnapshot
            }
            inFlight[key] = existing
            operation = existing
        } else {
            let progress: SnapshotProgress = { @concurrent snapshot in
                await self.publish(snapshot, for: key, generation: generation)
            }
            let task = Task {
                try await loadSnapshot(key, preferredPeriod, progress)
            }
            var progressHandlers: [UUID: SnapshotProgress] = [:]
            if let progressObserverID, let onPartialSnapshot {
                progressHandlers[progressObserverID] = onPartialSnapshot
            }
            operation = InFlight(
                generation: generation,
                task: task,
                progressHandlers: progressHandlers,
                waiterCount: 1
            )
            inFlight[key] = operation
        }

        do {
            var snapshot = try await withTaskCancellationHandler(operation: { @concurrent in
                try await operation.task.value
            }, onCancel: {
                Task { @concurrent in
                    await self.cancelWaiter(for: key, generation: operation.generation)
                }
            })
            removeProgressHandler(progressObserverID, for: key, generation: operation.generation)
            try Task.checkCancellation()
            guard generations[key, default: 0] == operation.generation else {
                throw DiningRepositoryError.obsoleteRequest
            }
            guard snapshot.key == key,
                  snapshot.schemaVersion == MenuDaySnapshot.currentSchemaVersion else {
                throw DiningRepositoryError.invalidSnapshot
            }

            if !snapshot.hasPublishedItems {
                if let staleFallback, staleFallback.hasPublishedItems {
                    snapshot = staleFallback
                } else if let retained = await fileStore.lastKnownGoodSnapshot(for: key) {
                    snapshot = retained
                }
                // Preserve the original timestamp so retained data is not marked freshly fetched.
                try Task.checkCancellation()
                guard generations[key, default: 0] == operation.generation else {
                    throw DiningRepositoryError.obsoleteRequest
                }
            }

            if inFlight[key]?.generation == operation.generation {
                inFlight[key] = nil
                _ = try await fileStore.store(snapshot)
                cacheInMemory(snapshot)
                guard generations[key, default: 0] == operation.generation else {
                    throw DiningRepositoryError.obsoleteRequest
                }
            }
            return snapshot
        } catch {
            removeProgressHandler(progressObserverID, for: key, generation: operation.generation)
            if Task.isCancelled {
                throw CancellationError()
            }
            if inFlight[key]?.generation == operation.generation {
                inFlight[key] = nil
            }
            guard generations[key, default: 0] == operation.generation else {
                throw DiningRepositoryError.obsoleteRequest
            }
            let retainedLastGood: MenuDaySnapshot?
            if let staleFallback, staleFallback.hasPublishedItems {
                retainedLastGood = staleFallback
            } else {
                retainedLastGood = await fileStore.lastKnownGoodSnapshot(for: key)
            }
            if let retainedLastGood {
                // A discard-and-reload failure offers this separately retained value only as stale.
                // It must not re-enter the ordinary cache and later masquerade as a cache hit.
                return retainedLastGood
            } else if let staleFallback {
                return staleFallback
            }
            throw error
        }
    }

    private func publish(
        _ snapshot: MenuDaySnapshot,
        for key: MenuDayKey,
        generation: UInt64
    ) async {
        guard let operation = inFlight[key], operation.generation == generation else { return }
        for handler in operation.progressHandlers.values {
            await handler(snapshot)
        }
    }

    private func removeProgressHandler(
        _ id: UUID?,
        for key: MenuDayKey,
        generation: UInt64
    ) {
        guard let id,
              var operation = inFlight[key],
              operation.generation == generation else { return }
        operation.progressHandlers[id] = nil
        inFlight[key] = operation
    }

    private func cancelWaiter(for key: MenuDayKey, generation: UInt64) {
        guard var operation = inFlight[key], operation.generation == generation else { return }
        operation.waiterCount -= 1
        if operation.waiterCount <= 0 {
            operation.task.cancel()
            inFlight[key] = nil
        } else {
            inFlight[key] = operation
        }
    }

    private func invalidate(_ key: MenuDayKey) async throws {
        generations[key, default: 0] &+= 1
        inFlight.removeValue(forKey: key)?.task.cancel()
        removeFromMemoryCache(key)
        try await fileStore.invalidate(key)
    }

    func handleMemoryWarning() async {
        await fileStore.clearMemoryCache()
        memoryCache.removeAll(keepingCapacity: false)
        memoryAccessOrder.removeAll(keepingCapacity: false)
    }

    private func cacheInMemory(_ snapshot: MenuDaySnapshot) {
        guard !readsSharedStore else { return }
        let key = snapshot.key
        memoryCache[key] = snapshot
        Self.touch(key, in: &memoryAccessOrder)
        Self.trim(&memoryCache, order: &memoryAccessOrder, limit: Self.memoryCacheLimit)
    }

    private func removeFromMemoryCache(_ key: MenuDayKey) {
        memoryCache[key] = nil
        memoryAccessOrder.removeAll { $0 == key }
    }

    private static func touch(_ key: MenuDayKey, in order: inout [MenuDayKey]) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private static func trim(
        _ cache: inout [MenuDayKey: MenuDaySnapshot],
        order: inout [MenuDayKey],
        limit: Int
    ) {
        while order.count > limit {
            cache[order.removeFirst()] = nil
        }
    }

}
