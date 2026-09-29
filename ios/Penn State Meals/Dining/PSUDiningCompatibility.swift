import Foundation

/// Shared meal selection used by menus, Handoff, widgets, and public links.
struct DiningDeepLinkMeal: RawRepresentable, Hashable, Sendable {
    let rawValue: String

    init?(rawValue: String) {
        guard (1...32).contains(rawValue.utf8.count),
              rawValue.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }) else { return nil }
        self.rawValue = rawValue
    }

    init?(displayName: String) {
        // Normalize provider-facing labels once, when creating a link selection.
        self.init(rawValue: displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().replacingOccurrences(of: " ", with: "-"))
    }

    var displayName: String {
        rawValue.replacingOccurrences(of: "-", with: " ").capitalized
    }
}

extension DateOnly {
    init?(deepLinkValue: String) {
        guard deepLinkValue.utf8.count == 10,
              deepLinkValue.utf8.enumerated().allSatisfy({ index, byte in
                  index == 4 || index == 7 ? byte == 45 : (48...57).contains(byte)
              }),
              let year = Int(deepLinkValue.prefix(4)),
              let month = Int(deepLinkValue.dropFirst(5).prefix(2)),
              let day = Int(deepLinkValue.suffix(2)) else { return nil }
        self.init(year: year, month: month, day: day)
    }
}

enum DiningDeepLinkUserInfoKey {
    static let provider = "provider"
    static let hall = "hall"
    static let date = "date"
    static let meal = "meal"
}

enum SpotlightStableIdentifier {
    static func diningLocation(_ locationID: DiningLocationID) -> String {
        "dining-location:\(locationID.provider.rawValue):\(locationID.rawValue)"
    }
}

enum MeetAndEatURLFactory {
    private static let fallbackURL = URL(string: "https://swiftbyte.app/meetandeat/open/").unsafelyUnwrapped

    static func staticFallback(
        kind: String,
        id: String,
        date: String?,
        meal: String? = nil
    ) -> URL? {
        // Handoff requires a web URL; the website dispatches it to the app.
        var queryItems = [
            URLQueryItem(name: "kind", value: kind),
            URLQueryItem(name: "id", value: id)
        ]
        if let date { queryItems.append(URLQueryItem(name: "date", value: date)) }
        if let meal { queryItems.append(URLQueryItem(name: "meal", value: meal)) }
        return fallbackURL.appending(queryItems: queryItems)
    }
}

extension Notification.Name {
    static let meetAndEatOpenDiningHall = Notification.Name("MeetAndEatOpenDiningHall")
    static let meetAndEatOpenMealRecord = Notification.Name("MeetAndEatOpenMealRecord")
}

@MainActor
enum MealReminderNavigation {
    private static var pendingRecordID: UUID?

    static var hasPendingRecord: Bool { pendingRecordID != nil }

    static func queue(_ recordID: UUID) {
        pendingRecordID = recordID
    }

    static func take() -> UUID? {
        defer { pendingRecordID = nil }
        return pendingRecordID
    }

    static func consume(_ recordID: UUID) {
        if pendingRecordID == recordID {
            pendingRecordID = nil
        }
    }
}

/// Public routes are parsed before changing tabs or creating view controllers.
/// Keep this grammar aligned with the website's dispatcher and association file.
enum MeetAndEatDeepLink: Equatable, Sendable {
    case diningHome
    case foodSearch(String)
    case hall(String, date: DateOnly?, meal: DiningDeepLinkMeal?)
    case dish(String, date: DateOnly?)
    case food(PSUFoodReference)
    case cata(routeID: Int?, stopID: Int?)

    var tab: Int {
        if case .cata = self { return 2 }
        return 0
    }

    private static let halls = ["north", "east", "south", "west", "pollock"]
    private static let queryKeys: Set<String> = ["kind", "id", "provider", "hall", "date", "meal"]

    init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil, components.port == nil else { return nil }
        if components.scheme?.lowercased() == "meetandeat", components.host?.lowercased() == "psu-food" {
            guard components.path.isEmpty, let items = components.queryItems, items.count == 1,
                  items[0].name == "id", let id = items[0].value,
                  let reference = PSUFoodReference(id: id) else { return nil }
            self = .food(reference)
            return
        }
        var fields: [String: String] = [:]
        for item in components.queryItems ?? [] where Self.queryKeys.contains(item.name) {
            guard fields[item.name] == nil, let value = item.value,
                  Self.isPublicValue(value) else { return nil }
            fields[item.name] = value
        }
        guard let selection = Selection(date: fields["date"], meal: fields["meal"]) else { return nil }
        let path = components.path.split(separator: "/")
        // URL schemes and hosts are case-insensitive; route paths and query values aren't.
        if components.scheme?.caseInsensitiveCompare("https") == .orderedSame {
            guard components.host?.caseInsensitiveCompare("swiftbyte.app") == .orderedSame,
                  path.first == "meetandeat" else { return nil }
            switch path.count {
            case 1 where fields.isEmpty:
                self = .diningHome
            case 2 where path[1] == "cata" && fields.isEmpty:
                self = .cata(routeID: nil, stopID: nil)
            case 3 where path[1] == "hall":
                guard fields.keys.allSatisfy({ $0 == "date" || $0 == "meal" }),
                      let hall = Self.hallID(String(path[2])) else { return nil }
                self = .hall(hall, date: selection.date, meal: selection.meal)
            case 2 where path[1] == "open":
                guard let kind = fields["kind"], let id = fields["id"],
                      let route = Self.dispatch(kind: kind, id: id, selection: selection) else { return nil }
                self = route
            default: return nil
            }
        } else if components.scheme?.caseInsensitiveCompare("meetandeat") == .orderedSame {
            let host = components.host ?? ""
            if host.isEmpty, path.isEmpty, fields.isEmpty {
                self = .diningHome
            } else if host.caseInsensitiveCompare("view-hall") == .orderedSame || host.caseInsensitiveCompare("psu-menu") == .orderedSame {
                guard path.isEmpty, fields["kind"] == nil, fields["id"] == nil,
                      fields["provider"] == "psu",
                      let rawHall = fields["hall"],
                      let hall = Self.hallID(rawHall) else { return nil }
                self = .hall(hall, date: selection.date, meal: selection.meal)
            } else if host.caseInsensitiveCompare("dish") == .orderedSame {
                guard path.isEmpty, fields["provider"] == "psu", let id = fields["id"],
                      let route = Self.dish(id, selection: selection) else { return nil }
                self = route
            } else if host.caseInsensitiveCompare("cata") == .orderedSame {
                if path.isEmpty, fields.isEmpty { self = .cata(routeID: nil, stopID: nil); return }
                guard path.count == 1, let id = fields["id"],
                      let route = Self.dispatch(kind: "cata-" + path[0], id: id, selection: selection) else { return nil }
                self = route
            } else { return nil }
        } else { return nil }
    }

    /// Handoff already supplies fields; it doesn't need to build and reparse a web URL.
    init?(hallID: String, date: String?, meal: String?) {
        guard let hall = Self.hallID(hallID),
              let selection = Selection(date: date, meal: meal) else { return nil }
        self = .hall(hall, date: selection.date, meal: selection.meal)
    }

    private struct Selection {
        let date: DateOnly?
        let meal: DiningDeepLinkMeal?

        init?(date: String?, meal: String?) {
            self.date = date.flatMap(DateOnly.init(deepLinkValue:))
            self.meal = meal.flatMap(DiningDeepLinkMeal.init(rawValue:))
            guard date == nil || self.date != nil,
                  meal == nil || self.meal != nil else { return nil }
        }
    }

    private static func hallID(_ value: String) -> String? {
        halls.contains(value) ? value : nil
    }

    private static func dispatch(kind: String, id: String, selection: Selection) -> Self? {
        switch kind {
        case "hall":
            guard id.hasPrefix("psu:"), let hall = hallID(String(id.dropFirst(4))) else { return nil }
            return .hall(hall, date: selection.date, meal: selection.meal)
        case "dish":
            guard id.hasPrefix("psu:") else { return nil }
            return dish(String(id.dropFirst(4)), selection: selection)
        case "cata-route", "cata-stop":
            guard selection.date == nil, selection.meal == nil, let number = positiveID(id) else { return nil }
            return .cata(routeID: kind == "cata-route" ? number : nil, stopID: kind == "cata-stop" ? number : nil)
        default: return nil
        }
    }

    private static func dish(_ id: String, selection: Selection) -> Self? {
        guard selection.meal == nil,
              (id.hasPrefix("mid:") && positiveID(String(id.dropFirst(4))) != nil)
                || (id.hasPrefix("name:") && id.count > 5) else { return nil }
        return .dish(id, date: selection.date)
    }

    private static func positiveID(_ value: String) -> Int? {
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
              let id = Int(value), id > 0 else { return nil }
        return id
    }

    private static func isPublicValue(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.prefix(129).count <= 128
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) })
    }

}

@MainActor
enum MeetAndEatLinkNavigation {
    struct Request: Equatable {
        let id = UUID()
        let route: MeetAndEatDeepLink
    }
    private(set) static var pending: Request?

    static func queue(_ route: MeetAndEatDeepLink) {
        pending = Request(route: route)
    }

    static func consume(_ request: Request) {
        if pending?.id == request.id { pending = nil }
    }
}

extension Notification.Name {
    static let meetAndEatOpenLink = Notification.Name("MeetAndEatOpenLink")
}

@MainActor
enum PSUDiningIntentNavigation {
    private static var intentRoute: (route: MeetAndEatDeepLink, until: Date)?
    static func isIntentDriven(hall: String, foodID: String? = nil) -> Bool {
        guard let pending = intentRoute, pending.until > .now else { intentRoute = nil; return false }
        switch pending.route {
        case .hall(let target, _, _): return foodID == nil && hall == target
        case .food(let food): return hall == food.hall && (foodID == nil || foodID == food.id)
        default: return false
        }
    }
    static func open(_ route: MeetAndEatDeepLink) {
        intentRoute = (route, .now.addingTimeInterval(30))
        MeetAndEatLinkNavigation.queue(route)
        NotificationCenter.default.post(name: .meetAndEatIntentNavigation, object: nil)
    }
}

extension Notification.Name {
    static let meetAndEatIntentNavigation = Notification.Name("MeetAndEatIntentNavigation")
}
