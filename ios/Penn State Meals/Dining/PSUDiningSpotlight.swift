import Foundation
import AppIntents
import CoreSpotlight
import OSLog

/// Local URLs preserve the exact meal occurrence; never depend on a web redirect.
enum PSUDiningLinks {
    static func hall(_ hall: String, date: DateOnly?, meal: String?) -> URL {
        var components = URLComponents()
        components.scheme = "meetandeat"; components.host = "psu-menu"
        components.queryItems = [URLQueryItem(name: "provider", value: "psu"), URLQueryItem(name: "hall", value: hall)]
        if let date { components.queryItems?.append(URLQueryItem(name: "date", value: date.description)) }
        if let meal { components.queryItems?.append(URLQueryItem(name: "meal", value: meal)) }
        return components.url ?? URL(string: "meetandeat://").unsafelyUnwrapped
    }
    static func food(_ reference: PSUFoodReference) -> URL {
        var components = URLComponents()
        components.scheme = "meetandeat"; components.host = "psu-food"
        components.queryItems = [URLQueryItem(name: "id", value: reference.id)]
        return components.url ?? hall(reference.hall, date: reference.date, meal: nil)
    }
    static func spotlightURL(identifier: String) -> URL? {
        if identifier.hasPrefix("psu:"), PSUDiningHall(rawValue: String(identifier.dropFirst(4))) != nil {
            return hall(String(identifier.dropFirst(4)), date: nil, meal: nil)
        }
        return nil
    }
}

/// Only durable hall destinations belong in Spotlight; menus remain in app/intent search.
actor PSUDiningSpotlight {
    static let shared = PSUDiningSpotlight()
    static let indexName = "com.ryannair05.pennstatemeals.psu-dining-v1"
    private static let hallDomain = "psu-dining-v1-halls"
    private let logger = Logger(subsystem: "com.ryannair05.pennstatemeals", category: "DiningSpotlight")
    private let delegate = PSUDiningSpotlightDelegate()
    private lazy var index: CSSearchableIndex = {
        let index = CSSearchableIndex(name: Self.indexName)
        index.indexDelegate = delegate
        return index
    }()
    private var indexedHalls: Set<PSUDiningHall> = []
    private var isCleared = false
    // Serialize complete operations, including suspension points and campus changes.
    private var pending: Task<Void, Never>?

    func synchronize() async {
        do {
            try await reindex(halls: PSUDiningHall.allCases, force: false)
        } catch { logger.error("Spotlight reconciliation failed: \(error.localizedDescription, privacy: .public)") }
    }

    func reindex(halls: [PSUDiningHall], force: Bool = true) async throws {
        try Task.checkCancellation()
        guard !Bundle.main.bundlePath.hasSuffix(".appex") else { return }
        let preceding = pending
        let task = Task { [self] in
            await preceding?.value
            guard PSUDiningAccess.isEnabled else {
                try await clearIndex()
                return
            }
            let changed = halls.filter { force || !indexedHalls.contains($0) }
            guard !changed.isEmpty else { return }
            let items = changed.map { hall -> CSSearchableItem in
                let entity = PSUDiningHallEntity(hall)
                let attributes = CSSearchableItemAttributeSet(contentType: .text)
                attributes.title = "\(entity.name) Dining Hall"
                attributes.contentDescription = PSUDiningHoursLocation(rawValue: hall.rawValue)?.sourceTitle
                attributes.contentURL = PSUDiningLinks.hall(hall.rawValue, date: nil, meal: nil)
                attributes.keywords = ["Penn State", "University Park", "PSU", "menu", "dining", "hours", entity.name]
                let item = CSSearchableItem(uniqueIdentifier: entity.id, domainIdentifier: Self.hallDomain, attributeSet: attributes)
                if #available(iOS 18.0, *) { item.associateAppEntity(entity) }
                item.expirationDate = .distantFuture
                return item
            }
            isCleared = false
            do {
                try await index.indexSearchableItems(items)
                indexedHalls.formUnion(changed)
            } catch {
                if !PSUDiningAccess.isEnabled { try await clearIndex() }
                throw error
            }
            if !PSUDiningAccess.isEnabled { try await clearIndex() }
        }
        pending = Task { @concurrent in _ = try? await task.value }
        try await task.value
        try Task.checkCancellation()
    }

    private func clearIndex() async throws {
        guard !isCleared else { return }
        indexedHalls.removeAll()
        try await index.deleteAllSearchableItems()
        isCleared = true
    }
}

/// Manual indexing still needs a repair delegate, even with IndexedEntityQuery.
private final class PSUDiningSpotlightDelegate: NSObject, CSSearchableIndexDelegate, @unchecked Sendable {
    private struct Acknowledgement: @unchecked Sendable {
        // The Objective-C callback is transferred to exactly one task and called once.
        let call: () -> Void
    }
    func searchableIndex(_ searchableIndex: CSSearchableIndex,
                         reindexAllSearchableItemsWithAcknowledgementHandler acknowledgementHandler: @escaping () -> Void) {
        rebuild(PSUDiningHall.allCases, acknowledgementHandler)
    }
    func searchableIndex(_ searchableIndex: CSSearchableIndex,
                         reindexSearchableItemsWithIdentifiers identifiers: [String],
                         acknowledgementHandler: @escaping () -> Void) {
        let identifiers = Set(identifiers)
        rebuild(PSUDiningHall.allCases.filter { identifiers.contains(PSUDiningHallEntity($0).id) },
                acknowledgementHandler)
    }
    private func rebuild(_ halls: [PSUDiningHall], _ callback: @escaping () -> Void) {
        let acknowledgement = Acknowledgement(call: callback)
        Task { @concurrent in
            do {
                try await PSUDiningSpotlight.shared.reindex(halls: halls)
                acknowledgement.call()
            } catch {
                Logger(subsystem: "com.ryannair05.pennstatemeals", category: "DiningSpotlight")
                    .error("Spotlight repair failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
