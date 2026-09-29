import Foundation

enum DiningMenuEnvironmentError: Error, Sendable, Equatable {
    case unsupportedLocation(DiningLocationID)
    case queryLocationMismatch(DiningLocationID)
}

enum DiningSearchWarmPolicy: Sendable, Equatable {
    case cacheOnly
    case revalidateIfStale

    fileprivate var fetchPolicy: DiningFetchPolicy {
        switch self {
        case .cacheOnly: .cacheOnly
        case .revalidateIfStale: .revalidateIfStale
        }
    }

    fileprivate var strength: Int {
        switch self {
        case .cacheOnly: 0
        case .revalidateIfStale: 1
        }
    }
}

actor DiningSearchWarmCoordinator {
    private struct InFlight {
        let operationID: UUID
        let policy: DiningSearchWarmPolicy
        let task: Task<Void, Never>
    }

    private var inFlight: [DiningSearchScope: InFlight] = [:]

    func value(
        for scope: DiningSearchScope,
        policy: DiningSearchWarmPolicy,
        operation: @escaping @concurrent @Sendable () async -> Void
    ) async {
        let entry: InFlight
        if let existing = inFlight[scope] {
            if policy.strength > existing.policy.strength {
                _ = await existing.task.value
                if inFlight[scope]?.operationID == existing.operationID {
                    inFlight[scope] = nil
                }
                await value(for: scope, policy: policy, operation: operation)
                return
            }
            entry = existing
        } else {
            let task = Task { @concurrent in await operation() }
            entry = InFlight(operationID: UUID(), policy: policy, task: task)
            inFlight[scope] = entry
        }
        await entry.task.value
        if inFlight[scope]?.operationID == entry.operationID {
            inFlight[scope] = nil
        }
    }
}

private actor DiningBoundedMenuBatchLoader {
    struct WorkItem: Sendable {
        let locationID: DiningLocationID
        let load: @concurrent @Sendable () async throws -> MenuDaySnapshot
    }

    struct Outcome: Sendable {
        let locationID: DiningLocationID
        let result: Result<MenuDaySnapshot, any Error>
    }

    private let workItems: [WorkItem]
    private var nextIndex = 0

    init(workItems: [WorkItem]) {
        self.workItems = workItems
    }

    func next() -> WorkItem? {
        guard workItems.indices.contains(nextIndex) else { return nil }
        defer { nextIndex += 1 }
        return workItems[nextIndex]
    }

    @concurrent
    static func load(
        _ workItems: [WorkItem],
        maximumConcurrentLoads: Int
    ) async -> [Outcome] {
        let loader = DiningBoundedMenuBatchLoader(workItems: workItems)
        let workerCount = min(max(1, maximumConcurrentLoads), workItems.count)
        return await withTaskGroup(
            of: [Outcome].self,
            returning: [Outcome].self
        ) { @concurrent group in
            for _ in 0..<workerCount {
                group.addTask { @concurrent in
                    var outcomes: [Outcome] = []
                    while !Task.isCancelled, let workItem = await loader.next() {
                        do {
                            outcomes.append(Outcome(
                                locationID: workItem.locationID,
                                result: .success(try await workItem.load())
                            ))
                        } catch {
                            outcomes.append(Outcome(
                                locationID: workItem.locationID,
                                result: .failure(error)
                            ))
                        }
                    }
                    return outcomes
                }
            }
            var outcomes: [Outcome] = []
            for await workerOutcomes in group {
                outcomes.append(contentsOf: workerOutcomes)
            }
            return outcomes
        }
    }
}

actor DiningProgressiveSearchControl {
    private var acceptsMoreWork = true

    func stopAfterActiveLoads() {
        acceptsMoreWork = false
    }

    func canScheduleMoreWork() -> Bool {
        acceptsMoreWork
    }
}

private actor DiningProgressiveMenuLoader {
    struct WorkItem: Sendable {
        let date: DateOnly
        let locationID: DiningLocationID
        let load: @concurrent @Sendable () async throws -> MenuDaySnapshot
    }

    private let workItems: [WorkItem]
    private let control: DiningProgressiveSearchControl
    private var nextIndex = 0

    init(workItems: [WorkItem], control: DiningProgressiveSearchControl) {
        self.workItems = workItems
        self.control = control
    }

    func next() async -> WorkItem? {
        guard await control.canScheduleMoreWork(),
              workItems.indices.contains(nextIndex) else { return nil }
        defer { nextIndex += 1 }
        return workItems[nextIndex]
    }
}

actor LastViewedDiningLocationStore {
    static let defaultsKey = "lastViewedHallID"

    private let suiteName: String?

    init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    func locationID() -> DiningLocationID? {
        guard let stored = defaults.string(forKey: Self.defaultsKey),
              let separator = stored.firstIndex(of: ":") else {
            return nil
        }
        let provider = String(stored[..<separator])
        let rawValue = String(stored[stored.index(after: separator)...])
        guard !provider.isEmpty, !rawValue.isEmpty else { return nil }
        return DiningLocationID(
            provider: DiningProviderID(rawValue: provider),
            rawValue: rawValue
        )
    }

    func recordSuccessfullyDisplayed(_ locationID: DiningLocationID) {
        defaults.set(
            "\(locationID.provider.rawValue):\(locationID.rawValue)",
            forKey: Self.defaultsKey
        )
    }

    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }
}

final class DiningMenuEnvironment: Sendable {
    static let shared = DiningMenuEnvironment()

    let repository: DefaultDiningMenuRepository
    let searchIndex: DiningSearchIndex
    let psuHours: PSUDiningHours
    let lastViewedLocationStore: LastViewedDiningLocationStore

    private let fileStore: MenuSnapshotFileStore
    private let itemDetailRepositoryProvider: MenuItemDetailRepositoryProvider
    private let searchWarmCoordinator = DiningSearchWarmCoordinator()

    init(
        cacheRoot: URL? = nil,
        defaultsSuiteName: String? = nil
    ) {
        let services = if let cacheRoot { PSUDiningServices(root: cacheRoot) } else { PSUDiningServices.shared }
        fileStore = services.fileStore
        repository = services.repository
        psuHours = services.hours
        searchIndex = DiningSearchIndex()
        itemDetailRepositoryProvider = MenuItemDetailRepositoryProvider(
            rootDirectory: (cacheRoot ?? PSUDiningAccess.root).appending(path: "MenuItemDetails")
        )
        lastViewedLocationStore = LastViewedDiningLocationStore(suiteName: defaultsSuiteName)
    }

    @concurrent
    func menu(
        for hall: PSUDiningHall,
        query: DiningQuery,
        policy: DiningFetchPolicy,
        preferredPeriod: DefaultDiningMenuRepository.PreferredPeriodResolver? = nil,
        onPartialSnapshot: DefaultDiningMenuRepository.SnapshotProgress? = nil
    ) async throws -> MenuDaySnapshot {
        guard query.locationID == hall.locationID,
              query.calendarContext == hall.calendarContext else {
            throw DiningMenuEnvironmentError.queryLocationMismatch(query.locationID)
        }
        if policy == .reloadDiscardingCache {
            await searchIndex.invalidate(query.menuDayKey)
        }
        let priority = Self.psuPriority(
            date: query.localDate,
            locationID: query.locationID,
            lastViewed: nil,
            visible: true
        )
        let snapshot = try await PSUMenuWorkContext.perform(priority: priority) {
            @concurrent [repository] in
            try await repository.menu(
                for: query.menuDayKey,
                policy: policy,
                preferredPeriod: preferredPeriod,
                onPartialSnapshot: onPartialSnapshot
            )
        }
        await searchIndex.replace(snapshot)
        await publishDiningIntegration(snapshot)
        return snapshot
    }

    @concurrent
    func menu(
        for hall: PSUDiningHall,
        on date: DateOnly,
        policy: DiningFetchPolicy
    ) async throws -> MenuDaySnapshot {
        let query = try DiningQuery(
            locationID: hall.locationID,
            localDate: date,
            calendarContext: hall.calendarContext
        )
        return try await menu(for: hall, query: query, policy: policy)
    }

    @concurrent
    func itemDetail(for item: DiningMenuItem, context: PlateContext) async throws -> PSUMenuItemDetailState {
        if let metadata = item.detailMetadata,
           (0..<PSUMenuItemDetailRepository.cacheInterval).contains(Date.now.timeIntervalSince(metadata.fetchedAt)) {
            return .available(PSUMenuItemDetail(itemID: item.id, metadata: metadata))
        }
        guard let sourceURL = item.detailURL else {
            if let metadata = item.detailMetadata {
                return .available(PSUMenuItemDetail(itemID: item.id, metadata: metadata))
            }
            throw PSUMenuItemDetailError.invalidSourceURL
        }
        let repository = try await itemDetailRepositoryProvider.repository()
        let state = try await repository.detail(for: item.id, displayName: item.displayName, sourceURL: sourceURL)
        try Task.checkCancellation()
        if case .unavailable = state,
           let refreshed = await refreshDetailSource(matching: item, locationID: context.hall.locationID, on: context.date),
           let refreshedURL = refreshed.detailURL {
            return try await repository.detail(
                for: refreshed.id, displayName: refreshed.displayName, sourceURL: refreshedURL, policy: .reloadIgnoringCache
            )
        }
        return state
    }

    @concurrent
    func recordSuccessfullyDisplayed(_ snapshot: MenuDaySnapshot) async {
        if snapshot.hasPublishedItems {
            await lastViewedLocationStore.recordSuccessfullyDisplayed(snapshot.key.locationID)
        }
    }

    @concurrent
    func warmSearchIndex(
        provider: DiningProviderID,
        on date: DateOnly,
        policy: DiningSearchWarmPolicy = .revalidateIfStale,
        maximumConcurrentLoads: Int = 3
    ) async {
        let scope = DiningSearchScope(provider: provider, date: date)
        return await searchWarmCoordinator.value(
            for: scope,
            policy: policy
        ) { @concurrent [self] in
            guard provider == .pennState else { return }
            let expected = PSUDiningHall.allCases.map(\.locationID)
            let lastViewed = await lastViewedLocationStore.locationID()
            await searchIndex.activate(provider: provider, date: date)
            await searchIndex.beginLoading(
                provider: provider,
                date: date,
                expectedLocationIDs: expected
            )
            let workItems = providerWorkItems(
                provider: provider,
                date: date,
                policy: policy.fetchPolicy,
                expectedLocationIDs: expected,
                lastViewed: lastViewed
            )
            let outcomes = await DiningBoundedMenuBatchLoader.load(
                workItems,
                maximumConcurrentLoads: maximumConcurrentLoads
            )
            let outcomeByLocation = Dictionary(
                uniqueKeysWithValues: outcomes.map { ($0.locationID, $0.result) }
            )
            var snapshots: [MenuDaySnapshot] = []
            var failures: [DiningSearchLocationFailure] = []
            for locationID in expected {
                guard let outcome = outcomeByLocation[locationID] else {
                    failures.append(DiningSearchLocationFailure(
                        locationID: locationID,
                        reason: .unavailable
                    ))
                    continue
                }
                switch outcome {
                case .success(let snapshot):
                    snapshots.append(snapshot)
                case .failure(let error):
                    failures.append(DiningSearchLocationFailure(
                        locationID: locationID,
                        reason: Self.searchFailureReason(for: error)
                    ))
                }
            }
            await searchIndex.replaceBatch(DiningSearchBatch(
                scope: scope,
                expectedLocationIDs: expected,
                snapshots: snapshots,
                failures: failures
            ))
        }
    }

    /// Completes today plus every retained PSU date without manufacturing new date scopes. Results
    /// are published after each hall and no more than two hall/day loads run concurrently.
    @concurrent
    func progressivelyWarmPSUSearch(
        control: DiningProgressiveSearchControl,
        maximumConcurrentLoads: Int = 2,
        onUpdate: @escaping @MainActor @Sendable (DateOnly) -> Void
    ) async {
        let context = ProviderCalendarContexts.pennState
        let today = context.serviceDate(containing: .now)
        let permittedRange = context.permittedRange(relativeTo: .now)
        let storedKeys = await fileStore.storedKeys(provider: .pennState).filter {
            permittedRange?.contains($0.localDate) ?? false
        }
        var retainedDates = Set(storedKeys.map(\.localDate))
        retainedDates.insert(today)
        let dates = retainedDates.sorted {
            if ($0 == today) != ($1 == today) { return $0 == today }
            let lhsFuture = $0 > today
            let rhsFuture = $1 > today
            if lhsFuture != rhsFuture { return lhsFuture }
            return lhsFuture ? $0 < $1 : $0 > $1
        }
        let expected = PSUDiningHall.allCases.map(\.locationID)
        let lastViewed = await lastViewedLocationStore.locationID()
        let hallOrder = PSUDiningHall.allCases.sorted {
            let lhsLast = $0.locationID == lastViewed
            let rhsLast = $1.locationID == lastViewed
            if lhsLast != rhsLast { return lhsLast }
            return expected.firstIndex(of: $0.locationID).unsafelyUnwrapped
                < expected.firstIndex(of: $1.locationID).unsafelyUnwrapped
        }

        for date in dates {
            await searchIndex.activate(provider: .pennState, date: date)
            await searchIndex.beginLoading(
                provider: .pennState,
                date: date,
                expectedLocationIDs: expected
            )
            for key in storedKeys where key.localDate == date {
                guard let hall = PSUDiningHall(rawValue: key.locationID.rawValue),
                      let snapshot = try? await menu(
                          for: hall,
                          on: date,
                          policy: .cacheOnly
                      ) else { continue }
                await searchIndex.replace(snapshot)
            }
            await onUpdate(date)
        }

        let workItems = dates.flatMap { date in
            hallOrder.map { hall in
                DiningProgressiveMenuLoader.WorkItem(
                    date: date,
                    locationID: hall.locationID,
                    load: { @concurrent [self] in
                        try await loadForSearchWarm(
                            for: hall,
                            date: date,
                            policy: .revalidateIfStale,
                            priority: Self.psuPriority(
                                date: date,
                                locationID: hall.locationID,
                                lastViewed: lastViewed,
                                visible: false
                            )
                        )
                    }
                )
            }
        }
        let loader = DiningProgressiveMenuLoader(workItems: workItems, control: control)
        let workerCount = min(max(1, maximumConcurrentLoads), workItems.count)
        await withTaskGroup(of: Void.self) { @concurrent group in
            for _ in 0..<workerCount {
                group.addTask { @concurrent [self] in
                    while let workItem = await loader.next() {
                        do {
                            let snapshot = try await workItem.load()
                            await searchIndex.replace(snapshot)
                        } catch {
                            await searchIndex.recordFailure(
                                DiningSearchLocationFailure(
                                    locationID: workItem.locationID,
                                    reason: Self.searchFailureReason(for: error)
                                ),
                                provider: .pennState,
                                date: workItem.date
                            )
                        }
                        await onUpdate(workItem.date)
                    }
                }
            }
        }
        for date in dates {
            await searchIndex.finishLoading(provider: .pennState, date: date)
            await onUpdate(date)
        }
    }

    @concurrent
    func handleSearchMemoryWarning() async {
        await repository.handleMemoryWarning()
        await itemDetailRepositoryProvider.handleMemoryWarning()
        await searchIndex.handleMemoryWarning()
    }

    @concurrent
    func itemDetailRepository() async throws -> PSUMenuItemDetailRepository {
        try await itemDetailRepositoryProvider.repository()
    }

    /// Reposts the menu that issued PSU's session-bound nutrition links, then returns the current
    /// occurrence in case PSU also replaced its provider-native `mid`.
    @concurrent
    func refreshDetailSource(
        matching item: DiningMenuItem,
        locationID: DiningLocationID,
        on date: DateOnly
    ) async -> DiningMenuItem? {
        guard locationID.provider == .pennState,
              let hall = PSUDiningHall(rawValue: locationID.rawValue),
              let snapshot = try? await menu(
                  for: hall,
                  on: date,
                  policy: .reloadDiscardingCache
              ) else { return nil }

        let items = snapshot.meals.lazy
            .flatMap(\.sections)
            .flatMap(\.items)
        if let exact = items.first(where: { $0.id == item.id && $0.detailURL != nil }) {
            return exact
        }
        let normalizedName = DiningTextNormalizer.foldedWords(item.displayName)
        return items.first {
            $0.detailURL != nil
                && DiningTextNormalizer.foldedWords($0.displayName) == normalizedName
        }
    }

    /// Performs cache maintenance without expanding the cache across every hall and date. A true
    /// first launch has no last-viewed hall and therefore performs no menu or hours requests.
    @concurrent
    func maintainPSULanding() async {
        let context = ProviderCalendarContexts.pennState
        let today = context.serviceDate(containing: .now)
        let dates = (-context.dateHorizon.pastDayCount...context.dateHorizon.futureDayCount)
            .compactMap { today.addingDays($0) }
        _ = try? await fileStore.prune(provider: .pennState, keeping: Set(dates))

        guard !Task.isCancelled,
              let lastViewed = await lastViewedLocationStore.locationID(),
              lastViewed.provider == .pennState,
              let hall = PSUDiningHall(rawValue: lastViewed.rawValue) else { return }
        _ = try? await menu(for: hall, on: today, policy: .revalidateIfStale)
    }

    /// Warms tomorrow after the visible menu is ready, below visible work in the HTTP budget.
    @concurrent
    func prefetchTomorrow(for hall: PSUDiningHall) async {
        let context = hall.calendarContext
        let today = context.serviceDate(containing: .now)
        guard let tomorrow = today.addingDays(1), !Task.isCancelled else { return }
        if let snapshot = try? await loadForSearchWarm(
            for: hall,
            date: tomorrow,
            policy: .revalidateIfStale,
            priority: .tomorrow
        ) {
            await searchIndex.replace(snapshot)
        }
    }

    /// Rehydrates the full in-process search index strictly from typed disk cache. This is shared
    /// by cold deep links, App Entity discovery, and startup indexing and never starts network IO.
    @concurrent
    func hydrateSearchIndexFromCache(
        provider: DiningProviderID,
        on date: DateOnly,
        locationID: DiningLocationID? = nil
    ) async {
        if locationID == nil {
            _ = await warmSearchIndex(provider: provider, on: date, policy: .cacheOnly)
            return
        }
        if provider == .pennState {
            for hall in PSUDiningHall.allCases
            where locationID == nil || hall.locationID == locationID {
                _ = try? await menu(
                    for: hall,
                    on: date,
                    policy: .cacheOnly
                )
            }
        }
    }

    /// Resolves any retained provider source ID to its canonical presentation group. Cold routes
    /// first use the atomic disk-cache batch, then perform one bounded provider refresh only when
    /// the compatibility alias is still absent.
    @concurrent
    func searchAggregate(
        containing sourceItemID: String,
        provider: DiningProviderID,
        on date: DateOnly,
        fixedLocationOrder: [DiningLocationID],
        revalidateIfMissing: Bool = true
    ) async -> DiningSearchAggregate? {
        await hydrateSearchIndexFromCache(provider: provider, on: date)
        if let aggregate = await searchIndex.aggregate(
            containing: sourceItemID,
            date: date,
            provider: provider,
            fixedHallOrder: fixedLocationOrder
        ) {
            return aggregate
        }
        guard revalidateIfMissing else { return nil }
        _ = await warmSearchIndex(
            provider: provider,
            on: date,
            policy: .revalidateIfStale
        )
        return await searchIndex.aggregate(
            containing: sourceItemID,
            date: date,
            provider: provider,
            fixedHallOrder: fixedLocationOrder
        )
    }

    private func providerWorkItems(
        provider: DiningProviderID,
        date: DateOnly,
        policy: DiningFetchPolicy,
        expectedLocationIDs: [DiningLocationID],
        lastViewed: DiningLocationID?
    ) -> [DiningBoundedMenuBatchLoader.WorkItem] {
        let expected = Set(expectedLocationIDs)
        switch provider {
        case .pennState:
            return PSUDiningHall.allCases.compactMap { hall in
                guard expected.contains(hall.locationID) else { return nil }
                return DiningBoundedMenuBatchLoader.WorkItem(
                    locationID: hall.locationID,
                    load: { @concurrent [self] in
                        try await loadForSearchWarm(
                            for: hall,
                            date: date,
                            policy: policy,
                            priority: Self.psuPriority(
                                date: date,
                                locationID: hall.locationID,
                                lastViewed: lastViewed,
                                visible: false
                            )
                        )
                    }
                )
            }
        case .barnard, .uga:
            return []
        default:
            return []
        }
    }

    @concurrent
    private func loadForSearchWarm(
        for hall: PSUDiningHall,
        date: DateOnly,
        policy: DiningFetchPolicy,
        priority: PSUMenuWorkPriority?
    ) async throws -> MenuDaySnapshot {
        let query = try DiningQuery(
            locationID: hall.locationID,
            localDate: date,
            calendarContext: hall.calendarContext
        )
        let snapshot: MenuDaySnapshot
        if let priority {
            snapshot = try await PSUMenuWorkContext.perform(priority: priority) {
                @concurrent [repository] in
                try await repository.menu(for: query.menuDayKey, policy: policy)
            }
        } else {
            snapshot = try await repository.menu(for: query.menuDayKey, policy: policy)
        }
        await publishDiningIntegration(snapshot)
        return snapshot
    }

    @concurrent
    private func publishDiningIntegration(_ snapshot: MenuDaySnapshot) async {
        guard PSUDiningAccess.isEnabled else { return }
        try? await PSUFoodCatalog.shared.replace(snapshot)
        Task { @concurrent in await PSUDiningWidgetUpdates.shared.menuDidLoad(snapshot) }
    }

    private static func psuPriority(
        date: DateOnly,
        locationID: DiningLocationID,
        lastViewed: DiningLocationID?,
        visible: Bool
    ) -> PSUMenuWorkPriority {
        let context = ProviderCalendarContexts.pennState
        let today = context.serviceDate(containing: .now)
        if date == today {
            if visible { return .visibleToday }
            if locationID == lastViewed { return .lastViewedToday }
            return .otherToday
        }
        if date == today.addingDays(1) {
            return visible ? .visibleTomorrow : .tomorrow
        }
        return date < today ? .yesterday : .later
    }

    private static func searchFailureReason(for error: any Error) -> DiningSearchFailureReason {
        if error is CancellationError { return .cancelled }
        if case DiningRepositoryError.cacheMiss = error { return .cacheMiss }
        let sourceError: DiningSourceError? = if let sourceError = error as? DiningSourceError {
            sourceError
        } else if let adapterError = error as? PSUMenuSourceAdapterError {
            adapterError.sourceError
        } else {
            nil
        }
        switch sourceError {
        case .transport: return .transport
        case .unsupportedMarkup, .missingMealSelector, .missingRequiredField,
             .emptyBody, .responseTooLarge, .nonHTTPResponse, .unacceptableStatus:
            return .sourceRejected
        case .noPublishedMenu: return .unavailable
        case .invalidURL, .invalidFormEncoding, nil: return .unknown
        }
    }
}
