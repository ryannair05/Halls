import Foundation
import SwiftSoup

struct PSUMenuItemDetail: Codable, Sendable, Equatable {
    let itemID: String
    let fetchedAt: Date
    let sourceURL: URL
    let ingredients: String?
    let allergenStatement: String?
    let nutrition: [DiningNutritionFact]?

    init(
        itemID: String,
        fetchedAt: Date,
        sourceURL: URL,
        ingredients: String?,
        allergenStatement: String?,
        nutrition: [DiningNutritionFact]?
    ) {
        self.itemID = itemID
        self.fetchedAt = fetchedAt
        self.sourceURL = sourceURL
        self.ingredients = ingredients
        self.allergenStatement = allergenStatement
        self.nutrition = nutrition
    }

    init(itemID: String, metadata: DiningMenuItemDetailMetadata) {
        self.init(
            itemID: itemID,
            fetchedAt: metadata.fetchedAt,
            sourceURL: metadata.sourceURL,
            ingredients: metadata.ingredients,
            allergenStatement: metadata.allergenStatement,
            nutrition: metadata.nutrition.isEmpty ? nil : metadata.nutrition
        )
    }

}

enum PSUMenuItemDetailState: Sendable, Equatable {
    case available(PSUMenuItemDetail)
    case unavailable(sourceURL: URL)
    case parseFailed(sourceURL: URL)
}

enum PSUMenuItemDetailError: Error, Sendable, Equatable {
    case unsupportedItemID
    case invalidSourceURL
    case explicitlyUnavailable
    case emptyBody
    case unsupportedMarkup
}

enum PSUMenuItemDetailFetchPolicy: Sendable, Equatable {
    case useCache
    case reloadIgnoringCache
}

enum PSUMenuItemDetailParser {
    static func parse(
        _ data: Data,
        itemID: String,
        sourceURL: URL,
        fetchedAt: Date
    ) throws(PSUMenuItemDetailError) -> PSUMenuItemDetail {
        guard !data.isEmpty else { throw .emptyBody }

        let document: Document
        do {
            let parser = SwiftSoup.Parser.htmlParser().settings(
                ParseSettings(false, false, false, true)
            )
            document = try parser.parseInput([UInt8](data), sourceURL.absoluteString)
        } catch {
            throw .unsupportedMarkup
        }

        let ingredients: String?
        let allergens: String?
        let nutritionFacts: [DiningNutritionFact]
        do {
            if try document
                .text(trimAndNormaliseWhitespace: false)
                .localizedCaseInsensitiveContains(
                "information is not available"
            ) {
                throw PSUMenuItemDetailError.explicitlyUnavailable
            }

            ingredients = try document
                .getElementsByClass("content-card--ingredients")
                .first()?
                .getElementsByTag("p")
                .first()?
                .text()
            allergens = try document
                .select(".content-card[aria-labelledby=allergensHeading]")
                .first()?
                .getElementsByTag("p")
                .first()?
                .text()
            nutritionFacts = try nutrition(in: document)
        } catch let error as PSUMenuItemDetailError {
            throw error
        } catch {
            throw .unsupportedMarkup
        }

        guard ingredients != nil
                || allergens != nil
                || !nutritionFacts.isEmpty else {
            throw .unsupportedMarkup
        }

        return PSUMenuItemDetail(
            itemID: itemID,
            fetchedAt: fetchedAt,
            sourceURL: sourceURL,
            ingredients: ingredients,
            allergenStatement: allergens,
            nutrition: nutritionFacts.isEmpty ? nil : nutritionFacts
        )
    }

    private static func nutrition(in document: Document) throws -> [DiningNutritionFact] {
        guard let card = try document
            .getElementsByClass("nutrition-facts-card")
            .first() else { return [] }
        var facts: [DiningNutritionFact] = []

        if let summaryRoot = try card.getElementsByClass("nutrition-summary").first() {
            let summaries = try summaryRoot.getElementsByClass("summary-value")
            facts.reserveCapacity(summaries.size())
            for summary in summaries {
                guard let label = try summary.getElementsByTag("strong").first() else { continue }
                let name = try label.text(trimAndNormaliseWhitespace: false)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ": "))
                facts.append(DiningNutritionFact(name: name, value: summary.ownText()))
            }
        }

        let rows = try card.getElementsByClass("fact-row")
        facts.reserveCapacity(facts.count + rows.size())
        for row in rows {
            guard let nameElement = try row.getElementsByClass("fact-name").first(),
                  let amountElement = try row.getElementsByClass("fact-amount").first() else {
                continue
            }
            let name = try nameElement.text(trimAndNormaliseWhitespace: false)
            let amount = try amountElement.text(trimAndNormaliseWhitespace: false)
            let publishedDailyValue = try row
                .getElementsByClass("fact-dv")
                .first()?
                .text(trimAndNormaliseWhitespace: false)
            let dailyValue: String? = if let publishedDailyValue,
                                         publishedDailyValue != "-",
                                         publishedDailyValue != "—" {
                publishedDailyValue
            } else {
                nil
            }
            let value = dailyValue.map { "\(amount) · \($0)" } ?? amount
            facts.append(DiningNutritionFact(name: name, value: value))
        }
        return facts
    }
}

actor PSUMenuItemDetailRepository {
    static let cacheInterval: TimeInterval = 30 * 24 * 60 * 60
    private static let memoryLimit = 24

    private struct InFlight: Sendable {
        let id: UUID
        let task: Task<PSUMenuItemDetail, any Error>
    }

    private let rootDirectory: URL
    private let httpClient: DiningHTTPClient
    private let now: @Sendable () -> Date
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var memory: [String: PSUMenuItemDetail] = [:]
    private var memoryAccessOrder: [String] = []
    private var inFlight: [String: InFlight] = [:]

    init(
        rootDirectory: URL? = nil,
        httpClient: DiningHTTPClient = .shared,
        now: @escaping @Sendable () -> Date = { .now },
        fileManager: FileManager = .default
    ) throws {
        self.httpClient = httpClient
        self.now = now
        self.fileManager = fileManager
        if let rootDirectory {
            self.rootDirectory = rootDirectory
        } else {
            self.rootDirectory = URL.cachesDirectory
                .appending(components: "MeetAndEat", "MenuItemDetails", directoryHint: .isDirectory)
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func detail(
        for itemID: String,
        displayName: String,
        sourceURL: URL,
        policy: PSUMenuItemDetailFetchPolicy = .useCache
    ) async throws -> PSUMenuItemDetailState {
        guard itemID.hasPrefix("mid:") else {
            throw PSUMenuItemDetailError.unsupportedItemID
        }
        let rawValue = String(itemID.dropFirst(4))
        guard !rawValue.isEmpty else { throw PSUMenuItemDetailError.unsupportedItemID }
        guard sourceURL.scheme == "https" else {
            throw PSUMenuItemDetailError.invalidSourceURL
        }
        let sourceMID = URLComponents(
            url: sourceURL,
            resolvingAgainstBaseURL: true
        )?.queryItems?.first(where: { $0.name == "mid" })?.value
        guard sourceMID == rawValue else {
            throw PSUMenuItemDetailError.invalidSourceURL
        }
        let cacheKey = DiningTextNormalizer.foldedWords(displayName)
        guard !cacheKey.isEmpty else {
            throw PSUMenuItemDetailError.unsupportedItemID
        }

        let currentDate = now()
        let cached = loadCachedDetail(for: cacheKey)
        if policy == .useCache, let cached,
           Self.isCacheValid(cached, at: currentDate) {
            return .available(cached)
        }

        let operation: InFlight
        if let existing = inFlight[cacheKey] {
            operation = existing
        } else {
            let task = Task { @concurrent [httpClient, now] in
                let response = try await PSUHTTPRequestBudget.shared.withPermit {
                    @concurrent () async throws(DiningSourceError) -> DiningHTTPResponse in
                    try await httpClient.data(for: URLRequest(url: sourceURL))
                }
                return try PSUMenuItemDetailParser.parse(
                    response.data,
                    itemID: itemID,
                    sourceURL: sourceURL,
                    fetchedAt: now()
                )
            }
            operation = InFlight(
                id: UUID(),
                task: task
            )
            inFlight[cacheKey] = operation
        }

        do {
            let loaded = try await operation.task.value
            if inFlight[cacheKey]?.id == operation.id {
                inFlight[cacheKey] = nil
                try store(loaded, for: cacheKey)
                cacheInMemory(loaded, for: cacheKey)
            }
            return .available(loaded)
        } catch {
            if inFlight[cacheKey]?.id == operation.id {
                inFlight[cacheKey] = nil
            }
            if Task.isCancelled || error is CancellationError ||
                (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            if (error as? PSUMenuItemDetailError) == .explicitlyUnavailable {
                invalidateCachedDetail(for: cacheKey)
                return .unavailable(sourceURL: sourceURL)
            }
            if let detailError = error as? PSUMenuItemDetailError,
               detailError == .emptyBody || detailError == .unsupportedMarkup {
                return .parseFailed(sourceURL: sourceURL)
            }
            throw error
        }
    }

    private func invalidateCachedDetail(for cacheKey: String) {
        memory[cacheKey] = nil
        memoryAccessOrder.removeAll { $0 == cacheKey }
        try? fileManager.removeItem(at: fileURL(for: cacheKey))
    }

    private static func isCacheValid(_ detail: PSUMenuItemDetail, at date: Date) -> Bool {
        let age = date.timeIntervalSince(detail.fetchedAt)
        return age >= 0 && age < cacheInterval
    }

    private func loadCachedDetail(for cacheKey: String) -> PSUMenuItemDetail? {
        if let cached = memory[cacheKey] {
            touch(cacheKey)
            return cached
        }
        let url = fileURL(for: cacheKey)
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let cached = try? decoder.decode(PSUMenuItemDetail.self, from: data) else {
            try? fileManager.removeItem(at: url)
            return nil
        }
        cacheInMemory(cached, for: cacheKey)
        return cached
    }

    func handleMemoryWarning() {
        memory.removeAll(keepingCapacity: false)
        memoryAccessOrder.removeAll(keepingCapacity: false)
    }

    private func cacheInMemory(_ detail: PSUMenuItemDetail, for cacheKey: String) {
        memory[cacheKey] = detail
        touch(cacheKey)
        while memoryAccessOrder.count > Self.memoryLimit {
            memory[memoryAccessOrder.removeFirst()] = nil
        }
    }

    private func touch(_ cacheKey: String) {
        memoryAccessOrder.removeAll { $0 == cacheKey }
        memoryAccessOrder.append(cacheKey)
    }

    private func store(_ detail: PSUMenuItemDetail, for cacheKey: String) throws {
        let destination = fileURL(for: cacheKey)
        let directory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(detail).write(to: destination, options: .atomic)
    }

    private func fileURL(for cacheKey: String) -> URL {
        let digest = DiningContentHasher.hash(cacheKey)
        return rootDirectory.appending(component: "\(digest).json", directoryHint: .notDirectory)
    }
}

actor MenuItemDetailRepositoryProvider {
    let rootDirectory: URL?
    private var cached: PSUMenuItemDetailRepository?

    init(rootDirectory: URL?) {
        self.rootDirectory = rootDirectory
    }

    func repository() throws -> PSUMenuItemDetailRepository {
        if let cached { return cached }
        let repository = try PSUMenuItemDetailRepository(rootDirectory: rootDirectory)
        cached = repository
        return repository
    }

    func handleMemoryWarning() async {
        await cached?.handleMemoryWarning()
    }
}
