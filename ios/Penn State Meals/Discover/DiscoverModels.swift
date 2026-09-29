import Foundation
import SwiftSoup

/// Public Discover URLs are built here; no institutional credentials are used.
enum PSUDiscover {
    static let timeZone = TimeZone(identifier: "America/New_York")!
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
    static func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "discover.psu.edu"
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { preconditionFailure("Invalid Discover URL") }
        return url
    }
    static func httpsURL(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value), url.scheme == "https", url.host != nil else { return nil }
        return url
    }
    /// Verified public Engage CDN. Presets provide appropriately sized, cacheable images.
    static func imageURL(_ value: String?, portrait: Bool = false) -> URL? {
        if let absolute = httpsURL(value) { return absolute }
        guard let value, !value.isEmpty,
              value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "." || $0 == "_") }),
              ["jpg", "jpeg", "png", "webp", "gif"].contains(URL(fileURLWithPath: value).pathExtension.lowercased()) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "se-images.campuslabs.com"
        components.path = "/clink/images/\(value)"
        components.queryItems = portrait ? [
            URLQueryItem(name: "width", value: "1000"), URLQueryItem(name: "height", value: "1000"),
            URLQueryItem(name: "mode", value: "max"), URLQueryItem(name: "format", value: "jpg"),
            URLQueryItem(name: "quality", value: "85")
        ] : [URLQueryItem(name: "preset", value: "med-sq")]
        return components.url
    }
    static func onlineURL(in html: String?) -> URL? {
        guard let html, let document = try? SwiftSoup.parseBodyFragment(html, "https://discover.psu.edu"),
              let anchors = try? document.select("a[href]") else { return nil }
        for anchor in anchors {
            guard let href = try? anchor.absUrl("href"), let url = httpsURL(href), let host = url.host else { continue }
            let meetingHosts = ["zoom.us", "teams.microsoft.com", "teams.live.com", "meet.google.com", "webex.com"]
            if meetingHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return url }
            if let label = try? anchor.text(), ["join online", "join meeting", "online event"].contains(normalized(label)) { return url }
        }
        return nil
    }
    static func eventID(url: URL?, fallback: String) -> String {
        guard let url, url.host == "discover.psu.edu",
              url.pathComponents.count == 3, url.pathComponents[1] == "event" else { return "ical:\(fallback)" }
        return url.lastPathComponent
    }
    static func plainText(_ html: String?) -> String {
        guard let html, !html.isEmpty else { return "" }
        // DOM stays within this parsing operation; only value types leave it.
        guard let document = try? SwiftSoup.parseBodyFragment(html) else { return "" }
        _ = try? document.select("script, style").remove()
        return (try? document.text()) ?? ""
    }
    static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

struct CampusOrganization: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let summary: String
    let description: String
    let categories: [String]
    let officialURL: URL?
    let imageURL: URL?
}

struct CampusEvent: Codable, Identifiable, Sendable, Equatable {
    enum Source: String, Codable, Sendable { case json, iCalendar }
    let id: String
    let title: String
    let description: String
    let start: Date
    let end: Date?
    let isAllDay: Bool
    let location: String
    let hostNames: [String]
    var organizationIDs: [String]
    let categories: [String]
    let benefits: [String]
    let officialURL: URL?
    let imageURL: URL?
    let latitude: Double?
    let longitude: Double?
    let source: Source
    let isCancelled: Bool
    var onlineURL: URL? = nil
    var organizationImageURL: URL? = nil

    var isOnline: Bool {
        onlineURL != nil || PSUDiscover.normalized(location).contains("online") || categories.contains { PSUDiscover.normalized($0).contains("virtual") }
    }
    var spansMultipleDays: Bool {
        guard let end else { return false }
        let lastDay = isAllDay ? end.addingTimeInterval(-1) : end
        return !PSUDiscover.calendar.isDate(start, inSameDayAs: lastDay)
    }
    func isOngoingListing(at date: Date) -> Bool {
        spansMultipleDays && start < PSUDiscover.calendar.startOfDay(for: date) && isUpcoming(at: date)
    }
    var effectiveEnd: Date { end ?? (isAllDay ? PSUDiscover.calendar.date(byAdding: .day, value: 1, to: start)! : start) }
    func isUpcoming(at date: Date) -> Bool {
        if end != nil || isAllDay { return effectiveEnd > date }
        return start >= date
    }
}

struct DiscoverSnapshot: Codable, Sendable {
    var organizations: [CampusOrganization] = []
    var events: [CampusEvent] = []
    var organizationsUpdated: Date?
    var eventsUpdated: Date?
    var directoryComplete = false
    var eventSource: CampusEvent.Source?
}

struct DiscoverSavedItems: Codable, Sendable {
    var organizations: [String: CampusOrganization] = [:]
    var events: [String: CampusEvent] = [:]
    mutating func merge(_ snapshot: DiscoverSnapshot) {
        for organization in snapshot.organizations where organizations[organization.id] != nil { organizations[organization.id] = organization }
        for event in snapshot.events where events[event.id] != nil { events[event.id] = event }
    }
}

/// Engage mixes numeric and string identifiers between its endpoints.
struct DiscoverID: Decodable, Sendable {
    let value: String
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) { self.value = value }
        else { value = String(try container.decode(Int.self)) }
    }
}

struct DiscoverPage<Record: Decodable & Sendable>: Decodable, Sendable {
    let count: Int
    let value: [Record]
    enum CodingKeys: String, CodingKey { case count = "@odata.count", value }
}

struct OrganizationDTO: Decodable, Sendable {
    let Id: DiscoverID
    let Name: String
    let WebsiteKey: String?
    let Summary: String?
    let Description: String?
    let CategoryNames: [String]?
    let Status: String?
    let Visibility: String?
    let ProfilePicture: String?
    var isUniversityPark: Bool {
        Status == "Active" && Visibility == "Public" && (CategoryNames ?? []).contains("University Park Orgs")
    }
    func normalized() -> CampusOrganization {
        CampusOrganization(id: Id.value, name: Name, summary: PSUDiscover.plainText(Summary),
            description: PSUDiscover.plainText(Description),
            categories: (CategoryNames ?? []).filter { $0 != "University Park Orgs" }.sorted(),
            officialURL: WebsiteKey.flatMap { $0.isEmpty ? nil : PSUDiscover.url("/organization/\($0)") },
            imageURL: PSUDiscover.imageURL(ProfilePicture))
    }
}

struct EventDTO: Decodable, Sendable {
    let id: DiscoverID
    let name: String
    let description: String?
    let startsOn: String
    let endsOn: String?
    let location: String?
    let organizationId: DiscoverID?
    let organizationIds: [DiscoverID]?
    let organizationName: String?
    let organizationNames: [String]?
    let categoryNames: [String]?
    let benefitNames: [String]?
    let imagePath: String?
    let organizationProfilePicture: String?
    let visibility: String?
    let status: String?
    let latitude: Coordinate?
    let longitude: Coordinate?

    struct Coordinate: Decodable, Sendable {
        let value: Double?
        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            value = (try? container.decode(Double.self)) ?? (try? container.decode(String.self)).flatMap(Double.init)
        }
    }
    func normalized() -> CampusEvent? {
        guard visibility == "Public", status == "Approved" || status == "Cancelled",
              let start = Self.date(startsOn) else { return nil }
        let end = endsOn.flatMap(Self.date)
        guard end.map({ $0 >= start }) ?? true else { return nil }
        var hosts = organizationNames ?? []
        if let organizationName, !hosts.contains(organizationName) { hosts.append(organizationName) }
        var hostIDs = (organizationIds ?? []).map(\.value)
        if let primaryID = organizationId?.value, !hostIDs.contains(primaryID) { hostIDs.append(primaryID) }
        return CampusEvent(id: id.value, title: name, description: PSUDiscover.plainText(description), start: start,
            end: end, isAllDay: false, location: location ?? "",
            hostNames: hosts,
            organizationIDs: hostIDs,
            categories: categoryNames ?? [], benefits: benefitNames ?? [], officialURL: PSUDiscover.url("/event/\(id.value)"),
            imageURL: PSUDiscover.imageURL(imagePath, portrait: true), latitude: latitude?.value, longitude: longitude?.value,
            source: .json, isCancelled: status == "Cancelled", onlineURL: PSUDiscover.onlineURL(in: description),
            organizationImageURL: PSUDiscover.imageURL(organizationProfilePicture))
    }
    static func date(_ text: String) -> Date? {
        (try? Date.ISO8601FormatStyle().parse(text))
            ?? (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text))
    }
}

struct UniversityParkClassifier: Sendable {
    let organizations: [CampusOrganization]
    func classify(_ events: [CampusEvent]) -> [CampusEvent] {
        let ids = Set(organizations.map(\.id))
        let names = Dictionary(grouping: organizations, by: { PSUDiscover.normalized($0.name) })
        return events.compactMap { event in
            var event = event
            if event.source == .json {
                return event.organizationIDs.contains(where: ids.contains) ? event : nil
            }
            let matching = event.hostNames.flatMap { names[PSUDiscover.normalized($0)] ?? [] }
            if !matching.isEmpty {
                event.organizationIDs = matching.map(\.id)
                return event
            }
            // Campus evidence must be in location/category, not a casual mention in prose.
            let location = PSUDiscover.normalized(event.location)
            let explicitCampus = location.contains("university park") || location.contains("state college")
                || event.categories.contains { PSUDiscover.normalized($0).contains("university park") }
            return explicitCampus ? event : nil
        }
    }
}
