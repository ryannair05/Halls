import Foundation

struct CampusDiningResponse: Codable, Sendable {
    let data: Data
    let fetchedAt: Date
    var isStale = false

    func json() throws -> CampusJSON { try JSONDecoder().decode(CampusJSON.self, from: data) }
}

/// Exclusively owned by a secondary-school environment. No PSU sessions, caches, or permits.
actor CampusDiningTransport {
    private struct Flight {
        let id: UUID
        let task: Task<CampusDiningResponse, any Error>
    }
    private struct Waiter {
        let id: UUID
        let url: URL
        let continuation: CheckedContinuation<Void, any Error>
    }
    private let session: URLSession
    private let root: URL
    private var memory: [URL: CampusDiningResponse] = [:]
    private var flights: [URL: Flight] = [:]
    private var active = 0
    private var waiters: [Waiter] = []

    init(root: URL) {
        self.root = root.appending(path: "Responses")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 35
        configuration.httpMaximumConnectionsPerHost = 3
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    func response(_ url: URL, lifetime: TimeInterval = 900, reload: Bool = false, background: Bool = false) async throws -> CampusDiningResponse {
        try Task.checkCancellation()
        let saved = cached(url)
        if !reload, let saved, Date.now.timeIntervalSince(saved.fetchedAt) < lifetime { return saved }
        if let flight = flights[url] {
            if !background, let index = waiters.firstIndex(where: { $0.url == url }) {
                let waiter = waiters.remove(at: index)
                waiters.insert(waiter, at: 0)
            }
            let value = try await flight.task.value
            try Task.checkCancellation()
            return value
        }
        let id = UUID()
        let task = Task { try await self.load(url, saved: saved, background: background) }
        flights[url] = Flight(id: id, task: task)
        defer { if flights[url]?.id == id { flights[url] = nil } }
        let result = try await task.value
        try Task.checkCancellation()
        return result
    }

    func cancelAll() {
        for flight in flights.values { flight.task.cancel() }
        flights.removeAll()
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.continuation.resume(throwing: CancellationError()) }
    }

    private func acquire(_ url: URL, background: Bool) async throws {
        try Task.checkCancellation()
        if active < 3 { active += 1; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                let waiter = Waiter(id: id, url: url, continuation: continuation)
                if background { waiters.append(waiter) } else { waiters.insert(waiter, at: 0) }
            }
        } onCancel: {
            Task { @concurrent in await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release() {
        if waiters.isEmpty { active -= 1 }
        else { waiters.removeFirst().continuation.resume() }
    }

    /// Nutrislice rejects app-generated CFNetwork user agents with HTTP 400.
    /// Preserve the request contract used by the working legacy UGA adapter.
    nonisolated static func request(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        if url.host == "uga.api.nutrislice.com" {
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.2 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
            request.setValue("https://uga.nutrislice.com/", forHTTPHeaderField: "Referer")
            request.setValue("uga.nutrislice.com", forHTTPHeaderField: "x-nutrislice-origin")
            request.setValue("https://uga.nutrislice.com", forHTTPHeaderField: "Origin")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
        }
        return request
    }

    private func load(_ url: URL, saved: CampusDiningResponse?, background: Bool) async throws -> CampusDiningResponse {
        try await acquire(url, background: background)
        defer { release() }
        do {
            try Task.checkCancellation()
            let (data, response) = try await session.data(for: Self.request(for: url))
            guard let response = response as? HTTPURLResponse else { throw CampusDiningError.invalidResponse }
            guard (200..<300).contains(response.statusCode) else { throw CampusDiningError.http(response.statusCode) }
            guard !data.isEmpty, data.count < 15_000_000 else { throw CampusDiningError.invalidResponse }
            try Task.checkCancellation()
            let result = CampusDiningResponse(data: data, fetchedAt: .now)
            memory[url] = result
            trimMemory()
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if let encoded = try? JSONEncoder().encode(result) { try? encoded.write(to: file(url), options: .atomic) }
            pruneDisk()
            return result
        } catch {
            try Task.checkCancellation()
            if var saved { saved.isStale = true; return saved }
            throw error
        }
    }

    private func cached(_ url: URL) -> CampusDiningResponse? {
        if let value = memory[url] { return value }
        guard let data = try? Data(contentsOf: file(url)),
              let value = try? JSONDecoder().decode(CampusDiningResponse.self, from: data),
              Date.now.timeIntervalSince(value.fetchedAt) < 7 * 86_400 else { return nil }
        memory[url] = value
        trimMemory()
        return value
    }

    private func trimMemory() {
        while memory.count > 12, let oldest = memory.min(by: { $0.value.fetchedAt < $1.value.fetchedAt })?.key {
            memory[oldest] = nil
        }
    }

    private func file(_ url: URL) -> URL { root.appending(path: DiningContentHasher.hash(url.absoluteString) + ".json") }

    private func pruneDisk() {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: keys) else { return }
        let entries = files.compactMap { url -> (URL, Date, Int)? in
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, v.contentModificationDate ?? .distantPast, v.fileSize ?? 0)
        }.sorted { $0.1 > $1.1 }
        var bytes = 0
        for entry in entries {
            bytes += entry.2
            if bytes > 64_000_000 || Date.now.timeIntervalSince(entry.1) > 7 * 86_400 {
                try? FileManager.default.removeItem(at: entry.0)
            }
        }
    }
}
