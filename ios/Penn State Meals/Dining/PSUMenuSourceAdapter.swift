import Foundation

struct PSUMenuSourceRequest: Sendable {
    let location: PSUDiningHall
    let localDate: DateOnly

    var key: MenuDayKey {
        MenuDayKey(locationID: location.locationID, localDate: localDate)
    }
}

enum PSUMenuWorkPriority: Int, Sendable, Comparable {
    case visibleToday = 0
    case lastViewedToday = 1
    case visibleTomorrow = 2
    case otherToday = 3
    case tomorrow = 4
    case later = 5
    case yesterday = 6

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

enum PSUMenuWorkContext {
    @TaskLocal static var priority: PSUMenuWorkPriority = .otherToday

    @concurrent
    static func perform<Value: Sendable, Failure: Error>(
        priority: PSUMenuWorkPriority,
        operation: @escaping @concurrent @Sendable () async throws(Failure) -> Value
    ) async throws(Failure) -> Value {
        let run: nonisolated(nonsending) () async -> Result<Value, Failure> = {
            do throws(Failure) {
                return .success(try await operation())
            } catch {
                return .failure(error)
            }
        }
        return try await $priority.withValue(priority, operation: run).get()
    }
}

enum PSUMenuSourceStage: Sendable, Equatable {
    case discoveryRequest
    case pageParsing
    case periodRequest(String)
    case periodParsing(String)
}

struct PSUMenuSourceAdapterError: Error, Sendable, Equatable {
    let stage: PSUMenuSourceStage
    let sourceError: DiningSourceError
}

actor PSUHTTPRequestBudget {
    private struct Waiter {
        let id: UUID
        let priority: PSUMenuWorkPriority
        let order: UInt64
        let continuation: CheckedContinuation<Result<Void, DiningSourceError>, Never>
    }

    static let shared = PSUHTTPRequestBudget(limit: 3)

    private let limit: Int
    private var active = 0
    private var waiters: [Waiter] = []
    private var nextOrder: UInt64 = 0

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func withPermit<Value: Sendable>(
        _ operation: @escaping @concurrent @Sendable () async throws(DiningSourceError) -> Value
    ) async throws(DiningSourceError) -> Value {
        try await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async throws(DiningSourceError) {
        let id = UUID()
        let priority = PSUMenuWorkContext.priority
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation {
                (continuation: CheckedContinuation<Result<Void, DiningSourceError>, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: .failure(Self.cancellationError))
                } else if active < limit {
                    active += 1
                    continuation.resume(returning: .success(()))
                } else {
                    nextOrder &+= 1
                    waiters.append(Waiter(
                        id: id,
                        priority: priority,
                        order: nextOrder,
                        continuation: continuation
                    ))
                }
            }
        } onCancel: {
            Task { @concurrent in await self.cancelWaiter(id) }
        }
        try result.get()
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: .failure(Self.cancellationError))
    }

    private func release() {
        if waiters.isEmpty {
            active = max(0, active - 1)
        } else {
            let index = waiters.indices.min {
                let lhs = waiters[$0]
                let rhs = waiters[$1]
                return lhs.priority != rhs.priority
                    ? lhs.priority < rhs.priority
                    : lhs.order < rhs.order
            } ?? waiters.startIndex
            let waiter = waiters.remove(at: index)
            waiter.continuation.resume(returning: .success(()))
        }
    }

    private nonisolated static var cancellationError: DiningSourceError {
        .transport(URLError(.cancelled))
    }
}

final class PSUMenuSourceAdapterImpl: Sendable {
    typealias PreferredPeriodResolver = @concurrent @Sendable () async -> DiningServicePeriodID?
    typealias SnapshotProgress = @concurrent @Sendable (MenuDaySnapshot) async -> Void

    private struct LoadedMeal: Sendable {
        let sourceOrder: Int
        let period: MenuMealPeriod?
        let sourceDigest: String
    }

    private struct Discovery: Sendable {
        let options: MealParser.ParsedMealOptions
        let selectedMeal: LoadedMeal?
        let selectedMealFailure: PSUMenuSourceAdapterError?
        let sourceDigest: String
    }

    private enum PeriodLoadOutcome: Sendable {
        case loaded(LoadedMeal)
        case failed(PSUMenuSourceAdapterError, sourceOrder: Int)
    }

    static let menuURL = URL(
        string: "https://www.absecom.psu.edu/menus/user-pages/daily-menu.cfm"
    ).unsafelyUnwrapped

    private let httpClient: DiningHTTPClient
    private let requestBudget: PSUHTTPRequestBudget

    init(
        httpClient: DiningHTTPClient,
        requestBudget: PSUHTTPRequestBudget = .shared
    ) {
        self.httpClient = httpClient
        self.requestBudget = requestBudget
    }

    @concurrent
    func load(
        _ request: PSUMenuSourceRequest,
        preferredPeriod: PreferredPeriodResolver? = nil,
        onPartialSnapshot: SnapshotProgress? = nil
    ) async throws(PSUMenuSourceAdapterError) -> MenuDaySnapshot {
        async let resolvedPreferredPeriod = Self.resolvePreferredPeriod(preferredPeriod)
        let discoveryBody: Data
        do {
            discoveryBody = try MealParser.formBody([
                ("selMenuDate", Self.formattedDate(request.localDate)),
                ("selCampus", String(request.location.menuNumber))
            ])
        } catch {
            throw Self.adapterError(error, stage: .discoveryRequest)
        }

        let discoveryResponse: DiningHTTPResponse
        do {
            discoveryResponse = try await post(body: discoveryBody)
        } catch {
            throw Self.adapterError(error, stage: .discoveryRequest)
        }

        let discovery: Discovery
        do {
            let sourceDigest = DiningContentHasher.hash(discoveryResponse.data)
            let parsed = try MealParser.parsedDiscovery(
                from: discoveryResponse.data,
                sourceURL: Self.menuURL
            )
            let selectedMeal = parsed.selectedPeriod.map { period in
                LoadedMeal(
                    sourceOrder: period.sourceOrder,
                    period: period.sections.isEmpty ? nil : period,
                    sourceDigest: sourceDigest
                )
            }
            let selectedMealFailure: PSUMenuSourceAdapterError? = if
                let error = parsed.selectedPeriodFailure,
                let option = parsed.options.selectedOption {
                Self.adapterError(error, stage: .periodParsing(option.displayName))
            } else {
                nil
            }
            discovery = Discovery(
                options: parsed.options,
                selectedMeal: selectedMeal,
                selectedMealFailure: selectedMealFailure,
                sourceDigest: sourceDigest
            )
        } catch {
            throw Self.adapterError(error, stage: .pageParsing)
        }

        let mealOrder = discovery.options.options
        let fetchedAt = Date.now

        if mealOrder.isEmpty {
            return MenuDaySnapshot(
                schemaVersion: MenuDaySnapshot.currentSchemaVersion,
                key: request.key,
                fetchedAt: fetchedAt,
                sourceContentHash: DiningContentHasher.hash(discovery.sourceDigest),
                meals: []
            )
        }

        let preferredPeriodID = await resolvedPreferredPeriod
        let preferredOption = preferredPeriodID.flatMap { periodID in
            mealOrder.first {
                DiningServicePeriodNormalizer.normalize($0.displayName).id == periodID
            }
        }
        let seededMeals = discovery.selectedMeal.map { [$0] } ?? []
        var firstFailure = discovery.selectedMealFailure
        let seededOrders = Set(seededMeals.map(\.sourceOrder))
        let waitsForPreferred = preferredOption.map { !seededOrders.contains($0.sourceOrder) } ?? false
        if !waitsForPreferred, let preview = discovery.selectedMeal, let period = preview.period, let onPartialSnapshot {
            await onPartialSnapshot(MenuDaySnapshot(
                schemaVersion: MenuDaySnapshot.currentSchemaVersion, key: request.key, fetchedAt: fetchedAt,
                sourceContentHash: DiningContentHasher.hash(discovery.sourceDigest, followedBy: [preview.sourceDigest]), meals: [period]
            ))
        }
        // Queue the visible meal first, but fill the other permits immediately. Waiting for
        // that meal before starting its siblings adds an unnecessary network round trip.
        let remainingMeals = mealOrder.filter { !seededOrders.contains($0.sourceOrder) }.sorted { lhs, rhs in
            let leftPreferred = lhs.sourceOrder == preferredOption?.sourceOrder
            let rightPreferred = rhs.sourceOrder == preferredOption?.sourceOrder
            return leftPreferred != rightPreferred ? leftPreferred : lhs.sourceOrder < rhs.sourceOrder
        }

        let childMeals = await withTaskGroup(of: PeriodLoadOutcome.self) { @concurrent group in
            let maximumConcurrentPeriodRequests = 3
            var nextPeriodIndex = 0

            while nextPeriodIndex < min(maximumConcurrentPeriodRequests, remainingMeals.count) {
                let option = remainingMeals[nextPeriodIndex]
                group.addTask { @concurrent [httpClient, requestBudget] in
                    await Self.loadMealOutcome(
                        option: option,
                        request: request,
                        httpClient: httpClient,
                        requestBudget: requestBudget
                    )
                }
                nextPeriodIndex += 1
            }

            var results: [LoadedMeal] = []
            results.reserveCapacity(remainingMeals.count)
            var childFailure: PSUMenuSourceAdapterError?
            while let outcome = await group.next() {
                var preview: LoadedMeal?
                switch outcome {
                case .loaded(let meal):
                    results.append(meal)
                    if waitsForPreferred, meal.sourceOrder == preferredOption?.sourceOrder {
                        preview = meal.period == nil ? discovery.selectedMeal : meal
                    }
                case .failed(let error, let sourceOrder):
                    childFailure = childFailure ?? error
                    if waitsForPreferred, sourceOrder == preferredOption?.sourceOrder { preview = discovery.selectedMeal }
                }
                if let preview, let period = preview.period, let onPartialSnapshot {
                    await onPartialSnapshot(MenuDaySnapshot(
                        schemaVersion: MenuDaySnapshot.currentSchemaVersion, key: request.key, fetchedAt: fetchedAt,
                        sourceContentHash: DiningContentHasher.hash(discovery.sourceDigest, followedBy: [preview.sourceDigest]), meals: [period]
                    ))
                }

                if !Task.isCancelled, nextPeriodIndex < remainingMeals.count {
                    let option = remainingMeals[nextPeriodIndex]
                    group.addTask { @concurrent [httpClient, requestBudget] in
                        await Self.loadMealOutcome(
                            option: option,
                            request: request,
                            httpClient: httpClient,
                            requestBudget: requestBudget
                        )
                    }
                    nextPeriodIndex += 1
                }
            }

            return (results.sorted { $0.sourceOrder < $1.sourceOrder }, childFailure)
        }

        if Task.isCancelled {
            throw Self.adapterError(CancellationError(), stage: .discoveryRequest)
        }
        firstFailure = firstFailure ?? childMeals.1
        var meals: [MenuMealPeriod] = []
        let loadedMeals = (seededMeals + childMeals.0)
            .sorted { $0.sourceOrder < $1.sourceOrder }
        for loadedMeal in loadedMeals {
            if let period = loadedMeal.period {
                meals.append(period)
            }
        }

        let snapshot = MenuDaySnapshot(
            schemaVersion: MenuDaySnapshot.currentSchemaVersion,
            key: request.key,
            fetchedAt: fetchedAt,
            sourceContentHash: DiningContentHasher.hash(
                discovery.sourceDigest,
                followedBy: loadedMeals.lazy.map(\.sourceDigest)
            ),
            meals: meals
        )
        guard loadedMeals.count == mealOrder.count else {
            if snapshot.hasPublishedItems, let onPartialSnapshot {
                await onPartialSnapshot(snapshot)
            }
            throw firstFailure ?? Self.adapterError(
                DiningSourceError.unsupportedMarkup,
                stage: .pageParsing
            )
        }
        return snapshot
    }

    @concurrent
    private static func resolvePreferredPeriod(
        _ resolver: PreferredPeriodResolver?
    ) async -> DiningServicePeriodID? {
        await resolver?()
    }

    @concurrent
    private func post(body: Data) async throws(DiningSourceError) -> DiningHTTPResponse {
        var request = URLRequest(url: Self.menuURL)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(
            "application/x-www-form-urlencoded; charset=utf-8",
            forHTTPHeaderField: "Content-Type"
        )
#if DEBUG
        request.attribution = .user
#endif
        let preparedRequest = request
        return try await requestBudget.withPermit {
            @concurrent [httpClient, preparedRequest]
            () async throws(DiningSourceError) -> DiningHTTPResponse in
            try await httpClient.data(for: preparedRequest)
        }
    }

    @concurrent
    private static func loadMealOutcome(
        option: MealParser.MealSourceOption,
        request: PSUMenuSourceRequest,
        httpClient: DiningHTTPClient,
        requestBudget: PSUHTTPRequestBudget
    ) async -> PeriodLoadOutcome {
        do {
            return .loaded(try await loadMeal(
                option: option,
                request: request,
                httpClient: httpClient,
                requestBudget: requestBudget
            ))
        } catch {
            return .failed(adapterError(error, stage: .periodRequest(option.displayName)), sourceOrder: option.sourceOrder)
        }
    }

    @concurrent
    private static func loadMeal(
        option: MealParser.MealSourceOption,
        request: PSUMenuSourceRequest,
        httpClient: DiningHTTPClient,
        requestBudget: PSUHTTPRequestBudget
    ) async throws(PSUMenuSourceAdapterError) -> LoadedMeal {
        let body: Data
        do {
            body = try MealParser.formBody([
                ("selMenuDate", formattedDate(request.localDate)),
                ("selMeal", option.formValue),
                ("selCampus", String(request.location.menuNumber))
            ])
        } catch {
            throw adapterError(error, stage: .periodRequest(option.displayName))
        }

        var urlRequest = URLRequest(url: menuURL)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = body
        urlRequest.setValue(
            "application/x-www-form-urlencoded; charset=utf-8",
            forHTTPHeaderField: "Content-Type"
        )
#if DEBUG
        urlRequest.attribution = .user
#endif
        let preparedRequest = urlRequest

        let response: DiningHTTPResponse
        do {
            response = try await requestBudget.withPermit {
                @concurrent [httpClient, preparedRequest]
                () async throws(DiningSourceError) -> DiningHTTPResponse in
                try await httpClient.data(for: preparedRequest)
            }
        } catch {
            throw adapterError(error, stage: .periodRequest(option.displayName))
        }

        let period: MenuMealPeriod
        do {
            period = try MealParser.mealPeriod(
                named: option.displayName,
                sourceOrder: option.sourceOrder,
                sourceIdentifier: option.formValue,
                from: response.data,
                sourceURL: menuURL
            )
        } catch {
            throw adapterError(error, stage: .periodParsing(option.displayName))
        }

        return LoadedMeal(
            sourceOrder: option.sourceOrder,
            period: period.sections.isEmpty ? nil : period,
            sourceDigest: DiningContentHasher.hash(response.data)
        )
    }

    private static func formattedDate(_ date: DateOnly) -> String {
        String(format: "%d/%d/%02d", date.month, date.day, date.year % 100)
    }

    private static func adapterError(
        _ error: any Error,
        stage: PSUMenuSourceStage
    ) -> PSUMenuSourceAdapterError {
        if let adapterError = error as? PSUMenuSourceAdapterError {
            return adapterError
        }
        if let sourceError = error as? DiningSourceError {
            return PSUMenuSourceAdapterError(stage: stage, sourceError: sourceError)
        }
        if error is CancellationError {
            return PSUMenuSourceAdapterError(
                stage: stage,
                sourceError: .transport(URLError(.cancelled))
            )
        }
        return PSUMenuSourceAdapterError(stage: stage, sourceError: .unsupportedMarkup)
    }
}
