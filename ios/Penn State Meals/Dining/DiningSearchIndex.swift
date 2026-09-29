import Foundation

// MARK: - Canonical dish identity

/// User-facing dish identity. Provider record IDs remain on `MenuAppearance`; this key is only
/// used to group records that represent the same displayed dish within one provider.
struct DishCanonicalKey: Hashable, Sendable {
    let provider: DiningProviderID
    let normalizedName: String

    /// Deterministic ordering for normalized dish names within a provider.
    var stableSortKey: String { "\(provider.rawValue)|\(normalizedName)" }
}

// MARK: - Public result models

struct MenuAppearance: Sendable, Equatable {
    let itemID: String
    let displayName: String
    let detailURL: URL?
    let detailMetadata: DiningMenuItemDetailMetadata?
    let locationID: DiningLocationID
    let hallName: String
    let date: DateOnly
    let mealID: String
    let mealName: String
    let sectionID: String
    let sectionName: String
    let sourceLabels: [String]
    let mealSourceOrder: Int
    let sectionSourceOrder: Int
    let itemSourceOrder: Int

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.date == rhs.date
            && lhs.locationID == rhs.locationID
            && lhs.itemID == rhs.itemID
            && lhs.mealID == rhs.mealID
            && lhs.sectionID == rhs.sectionID
    }

}

/// One presentation row per hall while retaining every underlying source occurrence.
struct DiningHallAvailabilitySummary: Sendable, Identifiable {
    var id: DiningLocationID { locationID }

    let locationID: DiningLocationID
    let hallName: String
    let date: DateOnly
    let mealNames: [String]
    let sectionNames: [String]
    let sourceItemIDs: [String]
    let appearances: [MenuAppearance]
}

struct DiningSearchRank: Sendable, Equatable {
    let itemNameMatchQuality: Int
    let otherFieldMatchQuality: Int
    let minimumSectionOrder: Int
    let mealOrder: Int
    let itemOrder: Int
    let hallCount: Int
}

struct DiningSearchAggregate: Sendable, Equatable {
    let canonicalKey: DishCanonicalKey
    /// Deterministic compatibility source ID. New presentation identity uses `canonicalKey` and
    /// exact navigation resolves against every value in `sourceItemIDs`.
    let itemID: String
    let sourceItemIDs: [String]
    let displayName: String
    let appearances: [MenuAppearance]
    let hallAvailability: [DiningHallAvailabilitySummary]
    let ranking: DiningSearchRank

    var representativeAppearance: MenuAppearance? {
        appearances.first(where: { $0.detailURL != nil }) ?? appearances.first
    }

    var representativeItem: DiningMenuItem? {
        guard let appearance = representativeAppearance else { return nil }
        return DiningMenuItem(
            id: appearance.itemID,
            displayName: appearance.displayName,
            detailURL: appearance.detailURL,
            sourceOrder: appearance.itemSourceOrder,
            sourceLabels: appearance.sourceLabels,
            detailMetadata: appearance.detailMetadata
        )
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.ranking == rhs.ranking,
              lhs.appearances.count == rhs.appearances.count,
              lhs.canonicalKey == rhs.canonicalKey,
              lhs.displayName == rhs.displayName else { return false }
        return lhs.appearances == rhs.appearances
    }

    init(
        canonicalKey: DishCanonicalKey,
        displayName: String,
        appearances: [MenuAppearance],
        ranking: DiningSearchRank
    ) {
        let sourceItemIDs = Self.orderedUniqueSourceIDs(in: appearances)
        self.canonicalKey = canonicalKey
        self.itemID = sourceItemIDs.first ?? "name:\(canonicalKey.normalizedName)"
        self.sourceItemIDs = sourceItemIDs
        self.displayName = displayName
        self.appearances = appearances
        self.hallAvailability = Self.hallSummaries(from: appearances)
        self.ranking = ranking
    }

    func applying(dietaryFilter: DiningDietaryFilter) -> DiningSearchAggregate? {
        guard !dietaryFilter.isEmpty else { return self }
        let matchingAppearances = appearances.filter { appearance in
            dietaryFilter.matches(
                sourceLabels: appearance.sourceLabels,
                itemName: appearance.displayName
            )
        }
        guard !matchingAppearances.isEmpty else { return nil }
        return DiningSearchAggregate(
            canonicalKey: canonicalKey,
            displayName: displayName,
            appearances: matchingAppearances,
            ranking: DiningSearchRank(
                itemNameMatchQuality: ranking.itemNameMatchQuality,
                otherFieldMatchQuality: ranking.otherFieldMatchQuality,
                minimumSectionOrder: ranking.minimumSectionOrder,
                mealOrder: ranking.mealOrder,
                itemOrder: ranking.itemOrder,
                hallCount: Set(matchingAppearances.map(\.locationID)).count,
            )
        )
    }

    private static func orderedUniqueSourceIDs(
        in appearances: [MenuAppearance]
    ) -> [String] {
        Array(Set(appearances.map(\.itemID))).sorted()
    }

    private static func hallSummaries(
        from appearances: [MenuAppearance]
    ) -> [DiningHallAvailabilitySummary] {
        var positions: [DiningLocationID: Int] = [:]
        var grouped: [DiningLocationID: [MenuAppearance]] = [:]
        for appearance in appearances {
            if positions[appearance.locationID] == nil {
                positions[appearance.locationID] = positions.count
            }
            grouped[appearance.locationID, default: []].append(appearance)
        }
        return grouped.map { locationID, values in
            guard let first = values.first else {
                preconditionFailure("Grouped menu appearances must not be empty")
            }
            return DiningHallAvailabilitySummary(
                locationID: locationID,
                hallName: first.hallName,
                date: first.date,
                mealNames: orderedUnique(values.map(\.mealName)),
                sectionNames: orderedUnique(values.map(\.sectionName)),
                sourceItemIDs: orderedUniqueSourceIDs(in: values),
                appearances: values
            )
        }.sorted {
            (positions[$0.locationID] ?? .max) < (positions[$1.locationID] ?? .max)
        }
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }
}

enum DiningSearchCompleteness: String, Sendable, Hashable {
    case loading
    case partial
    case complete
}

enum DiningSearchFailureReason: String, Sendable, Hashable {
    case cacheMiss
    case transport
    case sourceRejected
    case cancelled
    case unavailable
    case unknown
}

struct DiningSearchLocationFailure: Sendable, Hashable {
    let locationID: DiningLocationID
    let reason: DiningSearchFailureReason
}

struct DiningSearchCoverage: Sendable, Equatable {
    let completeness: DiningSearchCompleteness
    let expectedLocationIDs: [DiningLocationID]
    let indexedLocationIDs: [DiningLocationID]
    let failures: [DiningSearchLocationFailure]
    let wasTruncated: Bool

    var indexedLocationCount: Int { indexedLocationIDs.count }
    var expectedLocationCount: Int { expectedLocationIDs.count }
}

struct DiningSearchDateGroup: Sendable {
    let date: DateOnly
    let aggregates: [DiningSearchAggregate]
    let coverage: DiningSearchCoverage
}

struct DiningSearchResults: Sendable {
    let dateGroups: [DiningSearchDateGroup]
    let coverage: DiningSearchCoverage
    let coverageByDate: [DateOnly: DiningSearchCoverage]

    var aggregates: [DiningSearchAggregate] { dateGroups.flatMap(\.aggregates) }
}

// MARK: - Scope, batch, and query generation

struct DiningSearchScope: Hashable, Sendable {
    let provider: DiningProviderID
    let date: DateOnly

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.date == rhs.date && lhs.provider == rhs.provider
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(date)
        hasher.combine(provider)
    }
}

struct DiningSearchBatch: Sendable {
    let scope: DiningSearchScope
    let expectedLocationIDs: [DiningLocationID]
    let snapshots: [MenuDaySnapshot]
    let failures: [DiningSearchLocationFailure]
}

struct DiningSearchRequest: Sendable {
    let generation: UInt64
    let query: String
    let scope: DiningSearchScope
    let fixedLocationOrder: [DiningLocationID]
    let dietaryFilter: DiningDietaryFilter

    init(
        generation: UInt64,
        query: String,
        scope: DiningSearchScope,
        fixedLocationOrder: [DiningLocationID],
        dietaryFilter: DiningDietaryFilter = .none
    ) {
        self.generation = generation
        self.query = query
        self.scope = scope
        self.fixedLocationOrder = fixedLocationOrder
        self.dietaryFilter = dietaryFilter
    }
}

struct DiningSearchResponse: Sendable {
    let generation: UInt64
    let results: DiningSearchResults
}

/// Main-actor delivery makes the generation check and UI mutation one non-suspending operation.
/// This prevents an old `a` result from winning an `a -> ab -> a` (ABA) query sequence.
@MainActor
final class DiningSearchQueryCoordinator {
    typealias SearchOperation = @concurrent @Sendable (
        DiningSearchRequest
    ) async -> DiningSearchResponse
    typealias Delivery = @MainActor @Sendable (DiningSearchResponse) -> Void

    private let operation: SearchOperation
    private var generation: UInt64 = 0
    private var task: Task<Void, Never>?

    init(index: DiningSearchIndex) {
        self.operation = { @concurrent request in
            await index.search(request)
        }
    }

    init(operation: @escaping SearchOperation) {
        self.operation = operation
    }

    deinit {
        task?.cancel()
    }

    @discardableResult
    func submit(
        query: String,
        scope: DiningSearchScope,
        fixedLocationOrder: [DiningLocationID],
        dietaryFilter: DiningDietaryFilter = .none,
        debounce: Duration = .milliseconds(150),
        deliver: @escaping Delivery
    ) -> UInt64 {
        generation &+= 1
        let request = DiningSearchRequest(
            generation: generation,
            query: query,
            scope: scope,
            fixedLocationOrder: fixedLocationOrder,
            dietaryFilter: dietaryFilter
        )
        task?.cancel()
        let operation = operation
        task = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: debounce)
            } catch {
                return
            }
            let response = await operation(request)
            guard let self,
                  !Task.isCancelled,
                  response.generation == generation,
                  request.generation == generation else {
                return
            }
            task = nil
            deliver(response)
        }
        return generation
    }

    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
    }
}

// MARK: - Compact bounded index

actor DiningSearchIndex {
    struct Configuration: Sendable {
        let maxRetainedDatesPerProvider: Int
        let maxTotalCanonicalRecords: Int
        let maxCanonicalRecordsPerScope: Int
        let maxVisibleResults: Int

        init(
            maxRetainedDatesPerProvider: Int = 9,
            maxTotalCanonicalRecords: Int = 12_000,
            maxCanonicalRecordsPerScope: Int = 6_000,
            maxVisibleResults: Int = 100
        ) {
            self.maxRetainedDatesPerProvider = max(1, maxRetainedDatesPerProvider)
            self.maxTotalCanonicalRecords = max(1, maxTotalCanonicalRecords)
            self.maxCanonicalRecordsPerScope = min(
                max(1, maxCanonicalRecordsPerScope),
                max(1, maxTotalCanonicalRecords)
            )
            self.maxVisibleResults = max(1, maxVisibleResults)
        }
    }

    private struct CompactLocation: Sendable {
        let locationID: DiningLocationID
        let semanticRevision: String
        let appearances: [IndexedAppearance]
    }

    private struct IndexedAppearance: Sendable {
        let key: DishCanonicalKey
        let appearance: MenuAppearance
        let normalizedLabels: [String]
        let normalizedSection: String
        let normalizedHall: String
    }

    private struct MutableRecord {
        var displayNames: Set<String> = []
        var occurrences: Set<OccurrenceReference> = []
        var normalizedLabels: Set<String> = []
        var normalizedSections: Set<String> = []
        var normalizedHalls: Set<String> = []
    }

    private struct OccurrenceReference: Sendable, Hashable {
        let locationID: DiningLocationID
        let index: Int
    }

    private struct CompactDishRecord: Sendable {
        let key: DishCanonicalKey
        let displayName: String
        let occurrences: [OccurrenceReference]
        let normalizedLabels: Set<String>
        let normalizedSections: Set<String>
        let normalizedHalls: Set<String>

    }

    private struct CompactScopeIndex: Sendable {
        let records: [CompactDishRecord]
        let sourceAliases: [String: Int]
        let occurrenceCount: Int
        let wasTruncated: Bool
    }

    private struct ScopeState: Sendable {
        var locations: [DiningLocationID: CompactLocation]
        var expectedLocationIDs: [DiningLocationID]
        var failures: [DiningSearchLocationFailure]
        var completeness: DiningSearchCompleteness
        var index: CompactScopeIndex
        var lastAccess: UInt64
    }

    private let configuration: Configuration
    private var scopes: [DiningSearchScope: ScopeState] = [:]
    private var activeScope: DiningSearchScope?
    private var accessClock: UInt64 = 0

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    func activate(provider: DiningProviderID, date: DateOnly) {
        let scope = DiningSearchScope(provider: provider, date: date)
        activeScope = scope
        touch(scope)
        evictIfNeeded()
    }

    /// Marks a bounded daily load in progress while retaining any cache-derived partial results.
    func beginLoading(
        provider: DiningProviderID,
        date: DateOnly,
        expectedLocationIDs: [DiningLocationID]
    ) {
        let scope = DiningSearchScope(provider: provider, date: date)
        let expected = expectedLocationIDs
        accessClock &+= 1
        if var state = scopes[scope] {
            state.expectedLocationIDs = expected
            state.failures = []
            state.completeness = .loading
            state.lastAccess = accessClock
            scopes[scope] = state
        } else {
            scopes[scope] = ScopeState(
                locations: [:],
                expectedLocationIDs: expected,
                failures: [],
                completeness: .loading,
                index: emptyScopeIndex,
                lastAccess: accessClock
            )
        }
        evictIfNeeded()
    }

    @discardableResult
    func replace(_ snapshot: MenuDaySnapshot) -> Bool {
        let scope = DiningSearchScope(
            provider: snapshot.key.locationID.provider,
            date: snapshot.key.localDate
        )
        let semanticRevision = DiningContentHasher.semanticFingerprint(for: snapshot)
        accessClock &+= 1
        var state = scopes[scope] ?? ScopeState(
            locations: [:],
            expectedLocationIDs: Self.enabledLocations(for: scope.provider),
            failures: [],
            completeness: .partial,
            index: emptyScopeIndex,
            lastAccess: accessClock
        )
        if state.locations[snapshot.key.locationID]?.semanticRevision == semanticRevision {
            state.lastAccess = accessClock
            scopes[scope] = state
            return false
        }
        let location = makeCompactLocation(from: snapshot, semanticRevision: semanticRevision)
        state.locations[location.locationID] = location
        state.index = makeScopeIndex(from: state.locations)
        state.lastAccess = accessClock
        if state.completeness != .loading {
            state.completeness = resolvedCompleteness(
                expected: state.expectedLocationIDs,
                indexed: Set(state.locations.keys),
                failures: state.failures,
                wasTruncated: state.index.wasTruncated
            )
        }
        scopes[scope] = state
        evictIfNeeded()
        return true
    }

    func invalidate(_ key: MenuDayKey) {
        let scope = DiningSearchScope(
            provider: key.locationID.provider,
            date: key.localDate
        )
        guard var state = scopes[scope], state.locations.removeValue(forKey: key.locationID) != nil else {
            return
        }
        state.index = makeScopeIndex(from: state.locations)
        state.failures.removeAll { $0.locationID == key.locationID }
        state.completeness = resolvedCompleteness(
            expected: state.expectedLocationIDs,
            indexed: Set(state.locations.keys),
            failures: state.failures,
            wasTruncated: state.index.wasTruncated
        )
        accessClock &+= 1
        state.lastAccess = accessClock
        scopes[scope] = state
    }

    func replaceBatch(_ batch: DiningSearchBatch) {
        let expected = batch.expectedLocationIDs
        let expectedSet = Set(expected)
        var locations = scopes[batch.scope]?.locations.filter {
            expectedSet.contains($0.key)
        } ?? [:]
        for snapshot in batch.snapshots {
            let compact = makeCompactLocation(from: snapshot)
            locations[compact.locationID] = compact
        }
        let compactIndex = makeScopeIndex(from: locations)
        let failures = orderedFailures(batch.failures, expected: expected)
        let completeness = resolvedCompleteness(
            expected: expected,
            indexed: Set(locations.keys),
            failures: failures,
            wasTruncated: compactIndex.wasTruncated
        )
        accessClock &+= 1
        let newState = ScopeState(
            locations: locations,
            expectedLocationIDs: expected,
            failures: failures,
            completeness: completeness,
            index: compactIndex,
            lastAccess: accessClock
        )
        scopes[batch.scope] = newState
        evictIfNeeded()
    }

    func recordFailure(
        _ failure: DiningSearchLocationFailure,
        provider: DiningProviderID,
        date: DateOnly
    ) {
        let scope = DiningSearchScope(provider: provider, date: date)
        guard var state = scopes[scope] else { return }
        state.failures.removeAll { $0.locationID == failure.locationID }
        state.failures.append(failure)
        accessClock &+= 1
        state.lastAccess = accessClock
        scopes[scope] = state
    }

    func finishLoading(provider: DiningProviderID, date: DateOnly) {
        let scope = DiningSearchScope(provider: provider, date: date)
        guard var state = scopes[scope] else { return }
        state.completeness = resolvedCompleteness(
            expected: state.expectedLocationIDs,
            indexed: Set(state.locations.keys),
            failures: state.failures,
            wasTruncated: state.index.wasTruncated
        )
        accessClock &+= 1
        state.lastAccess = accessClock
        scopes[scope] = state
    }

    func search(_ request: DiningSearchRequest) -> DiningSearchResponse {
        let primary = search(
            request.query,
            date: request.scope.date,
            fixedHallOrder: request.fixedLocationOrder,
            provider: request.scope.provider,
            dietaryFilter: request.dietaryFilter
        )
        var groups = primary.dateGroups
        var coverageByDate = primary.coverageByDate
        let otherDates = scopes.keys.compactMap { scope -> DateOnly? in
            guard scope.provider == request.scope.provider,
                  scope.date != request.scope.date else { return nil }
            return scope.date
        }
        for date in otherDates {
            let result = search(
                request.query,
                date: date,
                fixedHallOrder: request.fixedLocationOrder,
                provider: request.scope.provider,
                dietaryFilter: request.dietaryFilter
            )
            groups.append(contentsOf: result.dateGroups)
            coverageByDate[date] = result.coverage
        }
        groups.sort {
            Self.dateRanksBefore($0.date, $1.date, today: request.scope.date)
        }
        var remaining = configuration.maxVisibleResults
        groups = groups.compactMap { group in
            guard remaining > 0 else { return nil }
            let retained = Array(group.aggregates.prefix(remaining))
            remaining -= retained.count
            return retained.isEmpty
                ? nil
                : DiningSearchDateGroup(
                    date: group.date,
                    aggregates: retained,
                    coverage: group.coverage
                )
        }
        return DiningSearchResponse(
            generation: request.generation,
            results: DiningSearchResults(
                dateGroups: groups,
                coverage: primary.coverage,
                coverageByDate: coverageByDate
            )
        )
    }

    func search(
        _ query: String,
        date: DateOnly,
        fixedHallOrder: [DiningLocationID],
        provider: DiningProviderID = .pennState,
        dietaryFilter: DiningDietaryFilter = .none
    ) -> DiningSearchResults {
        let scope = DiningSearchScope(provider: provider, date: date)
        let normalizedQuery = DiningTextNormalizer.foldedWords(query)
        let queryTokens = normalizedQuery.split(separator: " ")
        guard var state = scopes[scope] else {
            return DiningSearchResults(
                dateGroups: [],
                coverage: emptyCoverage(fallbackOrder: fixedHallOrder),
                coverageByDate: [:]
            )
        }
        accessClock &+= 1
        state.lastAccess = accessClock
        scopes[scope] = state
        let searchCoverage = coverage(for: scope, state: state, fallbackOrder: fixedHallOrder)
        guard !normalizedQuery.isEmpty else {
            return DiningSearchResults(
                dateGroups: [],
                coverage: searchCoverage,
                coverageByDate: [date: searchCoverage]
            )
        }

        let hallPositions = Dictionary(
            uniqueKeysWithValues: fixedHallOrder.enumerated().map { ($1, $0) }
        )
        var aggregates: [DiningSearchAggregate] = []
        aggregates.reserveCapacity(min(state.index.records.count, configuration.maxVisibleResults))
        for record in state.index.records {
            let quality = matchQuality(
                record: record,
                query: normalizedQuery,
                queryTokens: queryTokens
            )
            guard quality.itemName > 0 || quality.otherField > 0 else { continue }
            guard let aggregate = makeAggregate(
                record: record,
                locations: state.locations,
                quality: quality,
                hallPositions: hallPositions
            ).applying(dietaryFilter: dietaryFilter) else { continue }
            aggregates.append(aggregate)
        }
        aggregates.sort(by: Self.ranksBefore)
        aggregates = Array(aggregates.prefix(configuration.maxVisibleResults))

        let groups = aggregates.isEmpty
            ? []
            : [DiningSearchDateGroup(
                date: date,
                aggregates: aggregates,
                coverage: searchCoverage
            )]
        return DiningSearchResults(
            dateGroups: groups,
            coverage: searchCoverage,
            coverageByDate: [date: searchCoverage]
        )
    }

    /// Resolves legacy/share/Spotlight source IDs without making them presentation identity.
    /// Every source ID retained by a canonical group points to the same aggregate.
    func aggregate(
        containing sourceItemID: String,
        date: DateOnly,
        provider: DiningProviderID,
        fixedHallOrder: [DiningLocationID]
    ) -> DiningSearchAggregate? {
        let scope = DiningSearchScope(provider: provider, date: date)
        guard var state = scopes[scope],
              let recordID = state.index.sourceAliases[sourceItemID],
              state.index.records.indices.contains(recordID) else {
            return nil
        }
        accessClock &+= 1
        state.lastAccess = accessClock
        scopes[scope] = state
        let hallPositions = Dictionary(
            uniqueKeysWithValues: fixedHallOrder.enumerated().map { ($1, $0) }
        )
        return makeAggregate(
            record: state.index.records[recordID],
            locations: state.locations,
            quality: (itemName: 4, otherField: 0),
            hallPositions: hallPositions
        )
    }

    /// Drops every non-active date. If no scope was activated, the most recently used scope is
    /// retained so an in-flight visible search does not turn blank under memory pressure.
    func handleMemoryWarning(keeping requestedScope: DiningSearchScope? = nil) {
        if let requestedScope { activeScope = requestedScope }
        let retained = activeScope.flatMap { scopes[$0] == nil ? nil : $0 }
            ?? scopes.max { $0.value.lastAccess < $1.value.lastAccess }?.key
        if let retained {
            scopes = scopes.filter { $0.key == retained }
            activeScope = retained
        } else {
            scopes.removeAll(keepingCapacity: false)
            activeScope = nil
        }
    }

    // MARK: Index construction

    private var emptyScopeIndex: CompactScopeIndex {
        CompactScopeIndex(
            records: [],
            sourceAliases: [:],
            occurrenceCount: 0,
            wasTruncated: false
        )
    }

    private func makeCompactLocation(from snapshot: MenuDaySnapshot, semanticRevision: String? = nil) -> CompactLocation {
        let locationID = snapshot.key.locationID
        let hallName = Self.displayName(for: locationID)
        let normalizedHall = DiningTextNormalizer.foldedWords(hallName)
        var result: [IndexedAppearance] = []
        for meal in snapshot.meals {
            for section in meal.sections {
                let normalizedSection = DiningTextNormalizer.foldedWords(section.displayName)
                for item in section.items {
                    let key = DishCanonicalKey(
                        provider: locationID.provider,
                        normalizedName: DiningTextNormalizer.foldedWords(item.displayName)
                    )
                    let appearance = MenuAppearance(
                        itemID: item.id,
                        displayName: item.displayName.trimmingCharacters(in: .whitespacesAndNewlines),
                        detailURL: item.detailURL,
                        detailMetadata: item.detailMetadata,
                        locationID: locationID,
                        hallName: hallName,
                        date: snapshot.key.localDate,
                        mealID: meal.id,
                        mealName: meal.displayName,
                        sectionID: section.id,
                        sectionName: section.displayName,
                        sourceLabels: item.sourceLabels,
                        mealSourceOrder: meal.sourceOrder,
                        sectionSourceOrder: section.sourceOrder,
                        itemSourceOrder: item.sourceOrder
                    )
                    result.append(IndexedAppearance(
                        key: key,
                        appearance: appearance,
                        normalizedLabels: item.sourceLabels.map { DiningTextNormalizer.foldedWords($0) },
                        normalizedSection: normalizedSection,
                        normalizedHall: normalizedHall
                    ))
                }
            }
        }
        return CompactLocation(
            locationID: locationID,
            semanticRevision: semanticRevision ?? DiningContentHasher.semanticFingerprint(for: snapshot),
            appearances: result
        )
    }

    private func makeScopeIndex(
        from locations: [DiningLocationID: CompactLocation]
    ) -> CompactScopeIndex {
        var grouped: [DishCanonicalKey: MutableRecord] = [:]
        var occurrenceCount = 0
        for location in locations.values {
            for (appearanceIndex, indexed) in location.appearances.enumerated() {
                occurrenceCount += 1
                var record = grouped[indexed.key] ?? MutableRecord()
                record.displayNames.insert(indexed.appearance.displayName)
                record.occurrences.insert(OccurrenceReference(
                    locationID: location.locationID,
                    index: appearanceIndex
                ))
                record.normalizedLabels.formUnion(indexed.normalizedLabels)
                record.normalizedSections.insert(indexed.normalizedSection)
                record.normalizedHalls.insert(indexed.normalizedHall)
                grouped[indexed.key] = record
            }
        }

        let sortedKeys = grouped.keys.sorted { $0.stableSortKey < $1.stableSortKey }
        let wasTruncated = sortedKeys.count > configuration.maxCanonicalRecordsPerScope
        let retainedKeys = sortedKeys.prefix(configuration.maxCanonicalRecordsPerScope)
        let records = retainedKeys.compactMap { key -> CompactDishRecord? in
            guard let groupedRecord = grouped[key] else { return nil }
            let displayName = groupedRecord.displayNames.sorted {
                let comparison = $0.localizedStandardCompare($1)
                return comparison == .orderedSame ? $0 < $1 : comparison == .orderedAscending
            }.first ?? key.normalizedName
            return CompactDishRecord(
                key: key,
                displayName: displayName,
                occurrences: Array(groupedRecord.occurrences),
                normalizedLabels: groupedRecord.normalizedLabels,
                normalizedSections: groupedRecord.normalizedSections,
                normalizedHalls: groupedRecord.normalizedHalls
            )
        }

        var sourceAliases: [String: Int] = [:]
        for (recordID, record) in records.enumerated() {
            let appearances = appearances(for: record, locations: locations)
            for sourceItemID in appearances.map(\.itemID) {
                // If a provider reuses one source ID across documented discriminator groups, the
                // lexicographically first canonical record is the only deterministic legacy target.
                sourceAliases[sourceItemID] = sourceAliases[sourceItemID] ?? recordID
            }
        }
        return CompactScopeIndex(
            records: records,
            sourceAliases: sourceAliases,
            occurrenceCount: occurrenceCount,
            wasTruncated: wasTruncated
        )
    }

    // MARK: Query and presentation

    private func matchQuality(
        record: CompactDishRecord,
        query: String,
        queryTokens: [Substring]
    ) -> (itemName: Int, otherField: Int) {
        let itemName = record.key.normalizedName
        if itemName == query { return (4, 0) }
        if itemName.hasPrefix(query) { return (3, 0) }
        if itemName.contains(query) { return (2, 0) }
        if queryTokens.allSatisfy(itemName.contains) { return (1, 0) }
        if record.normalizedLabels.contains(where: { $0.contains(query) }) { return (0, 3) }
        if record.normalizedSections.contains(where: { $0.contains(query) }) { return (0, 2) }
        if record.normalizedHalls.contains(where: { $0.contains(query) }) { return (0, 1) }
        return (0, 0)
    }

    private func makeAggregate(
        record: CompactDishRecord,
        locations: [DiningLocationID: CompactLocation],
        quality: (itemName: Int, otherField: Int),
        hallPositions: [DiningLocationID: Int]
    ) -> DiningSearchAggregate {
        let appearances = appearances(for: record, locations: locations).sorted {
            let lhsHall = hallPositions[$0.locationID] ?? Int.max
            let rhsHall = hallPositions[$1.locationID] ?? Int.max
            if lhsHall != rhsHall { return lhsHall < rhsHall }
            if $0.mealSourceOrder != $1.mealSourceOrder {
                return $0.mealSourceOrder < $1.mealSourceOrder
            }
            if $0.sectionSourceOrder != $1.sectionSourceOrder {
                return $0.sectionSourceOrder < $1.sectionSourceOrder
            }
            if $0.itemSourceOrder != $1.itemSourceOrder {
                return $0.itemSourceOrder < $1.itemSourceOrder
            }
            return $0.itemID < $1.itemID
        }
        var minimumSectionOrder = Int.max
        var minimumMealOrder = Int.max
        var minimumItemOrder = Int.max
        var locationIDs = Set<DiningLocationID>()
        locationIDs.reserveCapacity(appearances.count)
        for appearance in appearances {
            minimumSectionOrder = min(minimumSectionOrder, appearance.sectionSourceOrder)
            minimumMealOrder = min(minimumMealOrder, appearance.mealSourceOrder)
            minimumItemOrder = min(minimumItemOrder, appearance.itemSourceOrder)
            locationIDs.insert(appearance.locationID)
        }
        return DiningSearchAggregate(
            canonicalKey: record.key,
            displayName: record.displayName,
            appearances: appearances,
            ranking: DiningSearchRank(
                itemNameMatchQuality: quality.itemName,
                otherFieldMatchQuality: quality.otherField,
                minimumSectionOrder: minimumSectionOrder,
                mealOrder: minimumMealOrder,
                itemOrder: minimumItemOrder,
                hallCount: locationIDs.count
            )
        )
    }

    private func appearances(
        for record: CompactDishRecord,
        locations: [DiningLocationID: CompactLocation]
    ) -> [MenuAppearance] {
        record.occurrences.compactMap { reference in
            guard let location = locations[reference.locationID],
                  location.appearances.indices.contains(reference.index) else { return nil }
            return location.appearances[reference.index].appearance
        }
    }

    private static func ranksBefore(
        _ lhs: DiningSearchAggregate,
        _ rhs: DiningSearchAggregate
    ) -> Bool {
        let left = lhs.ranking
        let right = rhs.ranking
        if left.itemNameMatchQuality != right.itemNameMatchQuality {
            return left.itemNameMatchQuality > right.itemNameMatchQuality
        }
        if left.otherFieldMatchQuality != right.otherFieldMatchQuality {
            return left.otherFieldMatchQuality > right.otherFieldMatchQuality
        }
        if left.minimumSectionOrder != right.minimumSectionOrder {
            return left.minimumSectionOrder < right.minimumSectionOrder
        }
        if left.mealOrder != right.mealOrder { return left.mealOrder < right.mealOrder }
        if left.itemOrder != right.itemOrder { return left.itemOrder < right.itemOrder }
        if left.hallCount != right.hallCount { return left.hallCount > right.hallCount }
        if lhs.canonicalKey.normalizedName != rhs.canonicalKey.normalizedName {
            return lhs.canonicalKey.normalizedName < rhs.canonicalKey.normalizedName
        }
        return lhs.canonicalKey.stableSortKey < rhs.canonicalKey.stableSortKey
    }

    private static func dateRanksBefore(
        _ lhs: DateOnly,
        _ rhs: DateOnly,
        today: DateOnly
    ) -> Bool {
        if (lhs == today) != (rhs == today) { return lhs == today }
        let lhsFuture = lhs > today
        let rhsFuture = rhs > today
        if lhsFuture != rhsFuture { return lhsFuture }
        return lhsFuture ? lhs < rhs : lhs > rhs
    }

    // MARK: Coverage and bounds

    private func resolvedCompleteness(
        expected: [DiningLocationID],
        indexed: Set<DiningLocationID>,
        failures: [DiningSearchLocationFailure],
        wasTruncated: Bool
    ) -> DiningSearchCompleteness {
        guard !wasTruncated,
              failures.isEmpty,
              Set(expected).isSubset(of: indexed) else {
            return .partial
        }
        return .complete
    }

    private func coverage(
        for scope: DiningSearchScope,
        state: ScopeState,
        fallbackOrder: [DiningLocationID]
    ) -> DiningSearchCoverage {
        let expected = state.expectedLocationIDs.isEmpty
            ? (fallbackOrder.isEmpty ? Self.enabledLocations(for: scope.provider) : fallbackOrder)
            : state.expectedLocationIDs
        let expectedSet = Set(expected)
        let positions = Dictionary(uniqueKeysWithValues: expected.enumerated().map { ($1, $0) })
        let indexed = state.locations.keys.filter {
            expectedSet.isEmpty || expectedSet.contains($0)
        }.sorted {
            let lhs = positions[$0] ?? Int.max
            let rhs = positions[$1] ?? Int.max
            return lhs == rhs ? $0.rawValue < $1.rawValue : lhs < rhs
        }
        let completeness: DiningSearchCompleteness
        if state.completeness == .loading {
            completeness = .loading
        } else {
            completeness = resolvedCompleteness(
                expected: expected,
                indexed: Set(indexed),
                failures: state.failures,
                wasTruncated: state.index.wasTruncated
            )
        }
        return DiningSearchCoverage(
            completeness: completeness,
            expectedLocationIDs: expected,
            indexedLocationIDs: indexed,
            failures: orderedFailures(state.failures, expected: expected),
            wasTruncated: state.index.wasTruncated
        )
    }

    private func emptyCoverage(fallbackOrder: [DiningLocationID]) -> DiningSearchCoverage {
        DiningSearchCoverage(
            completeness: .partial,
            expectedLocationIDs: fallbackOrder,
            indexedLocationIDs: [],
            failures: [],
            wasTruncated: false
        )
    }

    private func orderedFailures(
        _ failures: [DiningSearchLocationFailure],
        expected: [DiningLocationID]
    ) -> [DiningSearchLocationFailure] {
        let positions = Dictionary(uniqueKeysWithValues: expected.enumerated().map { ($1, $0) })
        return Array(Set(failures)).sorted {
            let lhs = positions[$0.locationID] ?? Int.max
            let rhs = positions[$1.locationID] ?? Int.max
            if lhs != rhs { return lhs < rhs }
            if $0.locationID.rawValue != $1.locationID.rawValue {
                return $0.locationID.rawValue < $1.locationID.rawValue
            }
            return $0.reason.rawValue < $1.reason.rawValue
        }
    }

    private func touch(_ scope: DiningSearchScope) {
        guard var state = scopes[scope] else { return }
        accessClock &+= 1
        state.lastAccess = accessClock
        scopes[scope] = state
    }

    private func evictIfNeeded() {
        let providers = Set(scopes.keys.map(\.provider))
        for provider in providers {
            let providerScopes = scopes.filter { $0.key.provider == provider }.sorted {
                if $0.key == activeScope { return true }
                if $1.key == activeScope { return false }
                if $0.value.lastAccess != $1.value.lastAccess {
                    return $0.value.lastAccess > $1.value.lastAccess
                }
                return $0.key.date > $1.key.date
            }
            for entry in providerScopes.dropFirst(configuration.maxRetainedDatesPerProvider) {
                scopes[entry.key] = nil
            }
        }

        while scopes.values.reduce(0, { $0 + $1.index.records.count })
                > configuration.maxTotalCanonicalRecords {
            guard let victim = scopes.filter({ $0.key != activeScope }).min(by: {
                $0.value.lastAccess < $1.value.lastAccess
            })?.key else {
                break
            }
            scopes[victim] = nil
        }
    }

    private static func enabledLocations(for provider: DiningProviderID) -> [DiningLocationID] {
        provider == .pennState ? PSUDiningHall.allCases.map(\.locationID) : []
    }

    private static func displayName(for locationID: DiningLocationID) -> String {
        guard locationID.provider == .pennState,
              let hall = PSUDiningHall(rawValue: locationID.rawValue) else {
            return "Dining location"
        }
        return hall.rawValue.capitalized
    }
}
