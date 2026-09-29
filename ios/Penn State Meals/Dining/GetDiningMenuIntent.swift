import AppIntents
import CoreTransferable
import GeoToolbox
import SwiftUI
import CoreSpotlight

// Fixed hall names are extracted into Siri phrase metadata without a runtime entity fetch.
extension PSUDiningHall: AppEnum {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Dining Hall"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .north: DisplayRepresentation(title: "North", subtitle: "Warnock Commons", synonyms: ["Warnock", "North Dining Hall"]),
        .east: DisplayRepresentation(title: "East", subtitle: "Findlay Commons", synonyms: ["Findlay", "East Dining Hall"]),
        .south: DisplayRepresentation(title: "South", subtitle: "Redifer Commons", synonyms: ["Redifer", "South Dining Hall"]),
        .west: DisplayRepresentation(title: "West", subtitle: "Waring Commons", synonyms: ["Waring", "West Dining Hall"]),
        .pollock: DisplayRepresentation(title: "Pollock", synonyms: ["Pollock Commons", "Pollock Dining Hall"])
    ]
}

struct PSUDiningHallEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Dining Hall"
    static let defaultQuery = PSUDiningHallQuery()
    let id: String
    @Property(title: "Name") var name: String
    init(_ hall: PSUDiningHall) { id = "psu:" + hall.rawValue; name = hall.rawValue.capitalized }
    var hall: PSUDiningHall? {
        guard id.hasPrefix("psu:") else { return nil }
        return PSUDiningHall(rawValue: String(id.dropFirst(4)))
    }
    var displayRepresentation: DisplayRepresentation {
        if let hall, let location = PSUDiningHoursLocation(rawValue: hall.rawValue) {
            DisplayRepresentation(title: "\(name)", subtitle: "\(location.sourceTitle)")
        } else {
            DisplayRepresentation(title: "\(name)")
        }
    }
}

struct PSUDiningHallQuery: EntityStringQuery {
    @concurrent func entities(for identifiers: [String]) async throws -> [PSUDiningHallEntity] {
        try Task.checkCancellation()
        let halls = PSUDiningHall.allCases.map(PSUDiningHallEntity.init)
        return identifiers.compactMap { id in halls.first { $0.id == id } }
    }
    @concurrent func suggestedEntities() async throws -> [PSUDiningHallEntity] {
        try Task.checkCancellation()
        return PSUDiningHall.allCases.map(PSUDiningHallEntity.init)
    }
    @concurrent func entities(matching string: String) async throws -> [PSUDiningHallEntity] {
        if string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return try await suggestedEntities()
        }
        let words = DiningTextNormalizer.foldedWords(string).split(separator: " ")
        guard !words.isEmpty else { return [] }
        return try await suggestedEntities().filter { entity in
            let aliases: String = switch entity.hall {
            case .north: "north warnock"
            case .south: "south redifer"
            case .east: "east findlay"
            case .west: "west waring"
            case .pollock: "pollock"
            case nil: ""
            }
            return words.allSatisfy { aliases.contains($0) || ["dining", "hall", "commons"].contains(String($0)) }
        }
    }
}

struct PSUFoodEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Food"
    static let defaultQuery = PSUFoodQuery()
    let id: String
    @Property(title: "Name") var name: String
    @Property(title: "Dining Hall") var diningHall: PSUDiningHallEntity
    @Property(title: "Meal") var meal: String
    @Property(title: "Date") var date: Date
    @Property(title: "Station") var station: String
    @Property(title: "Dietary Labels") var dietaryLabels: [String]
    init(_ record: PSUFoodRecord) {
        id = record.id; name = record.item.displayName
        diningHall = PSUDiningHallEntity(PSUDiningHall(rawValue: record.reference.hall) ?? .north)
        meal = record.mealName; station = record.sectionName
        date = record.reference.date.date(in: PSUServiceSelection.calendar.timeZone) ?? .now
        dietaryLabels = record.item.sourceLabels
    }
    init?(id: String, name: String, meal: String, station: String, dietaryLabels: [String]) {
        guard let reference = PSUFoodReference(id: id),
              let hall = PSUDiningHall(rawValue: reference.hall),
              let date = reference.date.date(in: hall.calendarContext.timeZone) else { return nil }
        self.id = id; self.name = name; self.meal = meal; self.station = station
        diningHall = PSUDiningHallEntity(hall)
        self.date = date; self.dietaryLabels = dietaryLabels
    }
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(diningHall.name) · \(meal) · \(PSUServiceSelection.calendar.localDate(containing: date).description)")
    }
}

struct PSUFoodQuery: EntityStringQuery {
    @concurrent func entities(for identifiers: [String]) async throws -> [PSUFoodEntity] {
        try Task.checkCancellation()
        // Catalog entries are search hints, not proof that a food is still being served.
        // The shared repository coalesces each hall/day and applies its freshness policy.
        var byID: [String: PSUFoodRecord] = [:]
        let references = identifiers.compactMap(PSUFoodReference.init(id:))
        let batches = Dictionary(grouping: references) { "\($0.hall):\($0.date)" }
        try await withThrowingTaskGroup(of: [PSUFoodRecord].self) { @concurrent group in
            for references in batches.values {
                group.addTask { @concurrent in
                    guard let reference = references.first,
                          let hall = PSUDiningHall(rawValue: reference.hall),
                          hall.calendarContext.contains(reference.date, relativeTo: .now) else { return [] }
                    do {
                        let loaded = try await PSUDiningServices.intents.menu(hall: hall, date: reference.date)
                        let wanted = Set(references.map(\.id))
                        return PSUFoodRecord.records(in: loaded.snapshot).filter { wanted.contains($0.id) }
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        try Task.checkCancellation()
                        if let actionError = error as? PSUDiningActionError {
                            switch actionError {
                            case .menuNotPublished, .foodUnavailable, .dateUnavailable: return []
                            default: break
                            }
                        }
                        throw error
                    }
                }
            }
            for try await batch in group { for record in batch { byID[record.id] = record } }
        }
        try Task.checkCancellation()
        return identifiers.compactMap { byID[$0].map(PSUFoodEntity.init) }
    }
    @concurrent func suggestedEntities() async throws -> [PSUFoodEntity] {
        let today = PSUServiceSelection.calendar.serviceDate(containing: .now)
        var records: [PSUFoodRecord] = []
        for hall in PSUDiningHall.allCases {
            try Task.checkCancellation()
            // Keep every hall represented instead of letting the first menu fill the picker.
            let key = MenuDayKey(locationID: hall.locationID, localDate: today)
            let hallRecords: [PSUFoodRecord]
            if let snapshot = await PSUDiningServices.shared.fileStore.snapshot(for: key) {
                hallRecords = PSUFoodRecord.records(in: snapshot)
            } else {
                hallRecords = await PSUFoodCatalog.shared.records(hall: hall.rawValue, date: today)
            }
            records += hallRecords.prefix(8)
        }
        try Task.checkCancellation()
        return records.prefix(40).map(PSUFoodEntity.init)
    }
    @concurrent func entities(matching string: String) async throws -> [PSUFoodEntity] {
        guard !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return try await suggestedEntities() }
        guard !DiningTextNormalizer.foldedWords(string).isEmpty else { return [] }
        let result = try await PSUDiningServices.intents.search(text: string,
            date: PSUServiceSelection.calendar.serviceDate(containing: .now), hall: nil, meal: nil)
        return result.records.map(PSUFoodEntity.init)
    }
}

@available(iOS 18.0, *)
extension PSUDiningHallEntity: IndexedEntity {
    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = "\(name) Dining Hall"
        attributes.contentDescription = hall.flatMap { PSUDiningHoursLocation(rawValue: $0.rawValue)?.sourceTitle }
        attributes.keywords = ["Penn State", "University Park", "PSU", "menu", "dining", "hours", name]
        if let hall {
            attributes.contentURL = PSUDiningLinks.hall(hall.rawValue, date: nil, meal: nil)
            attributes.latitude = NSNumber(value: hall.coordinate.latitude)
            attributes.longitude = NSNumber(value: hall.coordinate.longitude)
            attributes.supportsNavigation = true
        }
        return attributes
    }
}

enum PSUMealPreference: String, AppEnum {
    case automatic, breakfast, brunch, lunch, dinner
    case lateNight = "late-night"
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Meal"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .automatic: "Automatic", .breakfast: "Breakfast", .brunch: "Brunch",
        .lunch: "Lunch", .dinner: "Dinner", .lateNight: "Late Night"
    ]
}

struct PSUDiningWidgetConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Dining Menu"
    @Parameter(title: "Dining Hall") var diningHall: PSUDiningHallEntity?
    @Parameter(title: "Meal", default: .automatic) var meal: PSUMealPreference
    static var parameterSummary: some ParameterSummary { Summary("Show \(\.$meal) at \(\.$diningHall)") }
}

@available(iOS 27.0, *)
extension PSUDiningHallQuery: IndexedEntityQuery {
    @concurrent func reindexEntities(for identifiers: [String], indexDescription: CSSearchableIndexDescription) async throws {
        let halls = try await entities(for: identifiers).compactMap(\.hall)
        try await PSUDiningSpotlight.shared.reindex(halls: halls)
    }
    @concurrent func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        try await PSUDiningSpotlight.shared.reindex(halls: PSUDiningHall.allCases)
    }
}

// These five identifiers are deterministic on every device. No sync service is needed.
@available(iOS 27.0, *)
extension PSUDiningHallEntity: SyncableEntity {}

@available(iOS 27.0, *)
extension PSUDiningHallEntity: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        ValueRepresentation(exporting: { @concurrent (entity: PSUDiningHallEntity) async throws -> PlaceDescriptor in
            guard let hall = entity.hall else { throw PSUDiningActionError.invalidSelection }
            return PlaceDescriptor(representations: [.coordinate(hall.coordinate)],
                                   commonName: "\(entity.name) Dining Hall, Penn State University Park")
        })
    }
}
