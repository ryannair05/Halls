import Foundation

enum DiscoverError: Error, LocalizedError, Sendable {
    case invalidResponse, incompleteDirectory, repeatedPage, http(Int)
    var errorDescription: String? {
        switch self {
        case .invalidResponse: "Discover returned an unreadable response."
        case .incompleteDirectory: "Only part of the club directory is available. Pull to refresh to try again."
        case .repeatedPage: "Discover could not finish loading the directory."
        case .http(let status): "Discover is temporarily unavailable (\(status))."
        }
    }
}

struct DiscoverHTTPResponse: Sendable {
    let data: Data
    let contentType: String
}
protocol DiscoverHTTPClient: Sendable {
    @concurrent func get(_ url: URL) async throws -> DiscoverHTTPResponse
}
struct AnonymousDiscoverHTTPClient: DiscoverHTTPClient {
    private let session: URLSession
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 45
        session = URLSession(configuration: configuration)
    }
    @concurrent func get(_ url: URL) async throws -> DiscoverHTTPResponse {
        let (data, response) = try await session.data(from: url)
        guard let response = response as? HTTPURLResponse else { throw DiscoverError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw DiscoverError.http(response.statusCode) }
        return DiscoverHTTPResponse(data: data, contentType: response.mimeType ?? "")
    }
}

struct DiscoverRefresh: Sendable {
    let snapshot: DiscoverSnapshot
    let issues: [String]
}

actor DiscoverRepository {
    private struct Cache: Codable {
        var version = 1
        var snapshot = DiscoverSnapshot()
        var jsonAvailable: Bool?
        var jsonChecked: Date?
        var pagingAvailable: Bool?
        var pagingChecked: Date?
    }
    private let client: any DiscoverHTTPClient
    private let directory: URL
    private var cache = Cache()
    private var loaded = false
    private var refreshTask: Task<DiscoverRefresh, Never>?

    init(client: any DiscoverHTTPClient = AnonymousDiscoverHTTPClient(), directory: URL) {
        self.client = client
        self.directory = directory
    }
    func cached() -> DiscoverSnapshot {
        loadCache()
        return cache.snapshot
    }
    private func loadCache() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: directory.appendingPathComponent("cache-v1.json")),
           let decoded = try? JSONDecoder().decode(Cache.self, from: data), decoded.version == 1 {
            cache = decoded
        }
    }
    func refresh(force: Bool = false, now: Date = .now) async -> DiscoverRefresh {
        if let refreshTask { return await refreshTask.value }
        let task = Task { await self.performRefresh(force: force, now: now) }
        refreshTask = task
        let result = await task.value
        refreshTask = nil
        return result
    }
    private func performRefresh(force: Bool, now: Date) async -> DiscoverRefresh {
        loadCache()
        var issues: [String] = []
        let needsEvents = force || stale(cache.snapshot.eventsUpdated, age: 15 * 60, now: now)
        async let eventResult = refreshEventsIfNeeded(needsEvents, now: now)
        if force || stale(cache.snapshot.organizationsUpdated, age: 12 * 3600, now: now) {
            do {
                let result = try await organizations(now: now)
                if result.complete || !cache.snapshot.directoryComplete {
                    cache.snapshot.organizations = result.items
                    cache.snapshot.directoryComplete = result.complete
                    cache.snapshot.organizationsUpdated = now
                }
                if !result.complete { issues.append(DiscoverError.incompleteDirectory.localizedDescription) }
            } catch { issues.append("Clubs: \(error.localizedDescription)") }
        }
        if let eventResult = await eventResult {
            do {
                let result = try eventResult.get()
                cache.snapshot.events = UniversityParkClassifier(organizations: cache.snapshot.organizations).classify(result.items)
                    .sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
                cache.snapshot.eventsUpdated = now
                cache.snapshot.eventSource = result.source
            } catch { issues.append("Events: \(error.localizedDescription)") }
        }
        do { try write(cache, name: "cache-v1.json") }
        catch { issues.append("Offline cache could not be updated.") }
        return DiscoverRefresh(snapshot: cache.snapshot, issues: issues)
    }
    private func refreshEventsIfNeeded(_ needed: Bool, now: Date) async -> Result<(items: [CampusEvent], source: CampusEvent.Source), any Error>? {
        guard needed else { return nil }
        do { return .success(try await events(now: now)) }
        catch { return .failure(error) }
    }
    private func stale(_ date: Date?, age: TimeInterval, now: Date) -> Bool {
        guard let date else { return true }
        return now.timeIntervalSince(date) >= age || date > now
    }
    private func page<T: Decodable & Sendable>(_ type: T.Type, path: String, query: [URLQueryItem]) async throws -> DiscoverPage<T> {
        let response = try await client.get(PSUDiscover.url(path, query: query))
        guard response.contentType.lowercased().contains("json") else { throw DiscoverError.invalidResponse }
        return try JSONDecoder().decode(DiscoverPage<T>.self, from: response.data)
    }
    private func organizationPage(top: Int?, skip: Int = 0) async throws -> DiscoverPage<OrganizationDTO> {
        let query = top.map { [URLQueryItem(name: "top", value: String($0)), URLQueryItem(name: "skip", value: String(skip)), URLQueryItem(name: "orderBy[0]", value: "UpperName asc")] } ?? []
        return try await page(OrganizationDTO.self, path: "/api/discovery/search/organizations", query: query)
    }
    private func organizations(now: Date) async throws -> (items: [CampusOrganization], complete: Bool) {
        let bare = try await organizationPage(top: nil)
        guard bare.count >= 0 else { throw DiscoverError.invalidResponse }
        if bare.value.count < bare.count, stale(cache.pagingChecked, age: 24 * 3600, now: now) {
            do {
                async let firstRequest = organizationPage(top: 1)
                async let secondRequest = organizationPage(top: 1, skip: 1)
                let (first, second) = try await (firstRequest, secondRequest)
                cache.pagingAvailable = first.value.count == 1 && second.value.count == 1 && first.value.first?.Id.value != second.value.first?.Id.value
            } catch { cache.pagingAvailable = false }
            cache.pagingChecked = now
        }
        var records = bare.value
        var complete = records.count >= bare.count
        if cache.pagingAvailable == true, !complete {
            do {
                let first = try await organizationPage(top: 100)
                guard !first.value.isEmpty else { throw DiscoverError.incompleteDirectory }
                var pages = first.value
                var seen = Set(first.value.map { $0.Id.value })
                guard seen.count == pages.count else { throw DiscoverError.repeatedPage }
                // Honor the server's actual page size and keep at most four requests in flight.
                let pageSize = first.value.count
                let total = first.count
                try await withThrowingTaskGroup(of: DiscoverPage<OrganizationDTO>.self) { group in
                    var offset = pageSize
                    for _ in 0..<4 where offset < total {
                        let skip = offset
                        group.addTask { @concurrent in try await self.organizationPage(top: 100, skip: skip) }
                        offset += pageSize
                    }
                    while let next = try await group.next() {
                        try Task.checkCancellation()
                        guard !next.value.isEmpty else { throw DiscoverError.incompleteDirectory }
                        let newRecords = next.value.filter { seen.insert($0.Id.value).inserted }
                        guard newRecords.count == next.value.count else { throw DiscoverError.repeatedPage }
                        pages += newRecords
                        if offset < total {
                            let skip = offset
                            group.addTask { @concurrent in try await self.organizationPage(top: 100, skip: skip) }
                            offset += pageSize
                        }
                    }
                }
                records = pages
                complete = seen.count >= max(bare.count, first.count)
            } catch {
                // Keep the previous complete directory, or use a clearly marked bare response.
                complete = false
            }
        }
        var seen: Set<String> = []
        let items = records.filter { $0.isUniversityPark && seen.insert($0.Id.value).inserted }.map { $0.normalized() }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return (items, complete)
    }
    private func eventPage(take: Int, skip: Int, now: Date) async throws -> DiscoverPage<EventDTO> {
        try await page(EventDTO.self, path: "/api/discovery/event/search", query: [
            URLQueryItem(name: "take", value: String(take)), URLQueryItem(name: "skip", value: String(skip)),
            URLQueryItem(name: "status", value: "Approved"),
            URLQueryItem(name: "endsAfter", value: now.formatted(.iso8601)),
            URLQueryItem(name: "orderByField", value: "endsOn"), URLQueryItem(name: "orderByDirection", value: "ascending")])
    }
    private func events(now: Date) async throws -> (items: [CampusEvent], source: CampusEvent.Source) {
        // The first useful page also probes JSON support; avoid a separate one-record request.
        if cache.jsonAvailable != false || stale(cache.jsonChecked, age: 24 * 3600, now: now) {
            do {
                let first = try await eventPage(take: 100, skip: 0, now: now)
                guard first.count >= 0, !first.value.isEmpty || first.count == 0 else {
                    throw DiscoverError.invalidResponse
                }
                var records = first.value
                var seen = Set(records.map { $0.id.value })
                guard seen.count == records.count else { throw DiscoverError.repeatedPage }
                // Respect server page-size caps, with at most four remaining pages in flight.
                let pageSize = first.value.count
                try await withThrowingTaskGroup(of: DiscoverPage<EventDTO>.self) { group in
                    var offset = pageSize
                    for _ in 0..<4 where offset < first.count {
                        let skip = offset
                        group.addTask { @concurrent in try await self.eventPage(take: 100, skip: skip, now: now) }
                        offset += pageSize
                    }
                    while let next = try await group.next() {
                        try Task.checkCancellation()
                        guard !next.value.isEmpty else { throw DiscoverError.invalidResponse }
                        let newRecords = next.value.filter { seen.insert($0.id.value).inserted }
                        guard newRecords.count == next.value.count else { throw DiscoverError.repeatedPage }
                        records += newRecords
                        if offset < first.count {
                            let skip = offset
                            group.addTask { @concurrent in try await self.eventPage(take: 100, skip: skip, now: now) }
                            offset += pageSize
                        }
                    }
                }
                guard records.count >= first.count else { throw DiscoverError.invalidResponse }
                cache.jsonAvailable = true
                cache.jsonChecked = now
                var events = records.compactMap { $0.normalized() }
                if events.contains(where: { $0.isOnline && $0.onlineURL == nil }),
                   let response = try? await client.get(PSUDiscover.url("/events.ics")),
                   let calendarEvents = try? DiscoverICalendar.parse(response.data) {
                    let onlineLinks = Dictionary(uniqueKeysWithValues: calendarEvents.compactMap { event in
                        event.onlineURL.map { (event.id, $0) }
                    })
                    for index in events.indices where events[index].onlineURL == nil {
                        events[index].onlineURL = onlineLinks[events[index].id]
                    }
                }
                return (events, .json)
            } catch {
                cache.jsonAvailable = false
                cache.jsonChecked = now
            }
        }
        let response = try await client.get(PSUDiscover.url("/events.ics"))
        return (try DiscoverICalendar.parse(response.data), .iCalendar)
    }
    func savedItems() throws -> DiscoverSavedItems {
        let url = directory.appendingPathComponent("saved-v1.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return DiscoverSavedItems() }
        return try JSONDecoder().decode(DiscoverSavedItems.self, from: Data(contentsOf: url))
    }
    func save(_ items: DiscoverSavedItems) throws { try write(items, name: "saved-v1.json") }
    private func write<T: Encodable>(_ value: T, name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: directory.appendingPathComponent(name), options: .atomic)
    }
}
