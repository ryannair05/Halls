import Foundation
import SwiftSoup

struct CampusDiningCatalog: Sendable {
    let locations: [CampusDiningLocation]
    let message: String?
}

/// Created by CampusDiningView only. PSU never constructs this environment or opens these files.
actor CampusDiningEnvironment {
    let school: CampusDiningSchool
    private let root: URL
    private let transport: CampusDiningTransport
    private var columbia: CampusColumbiaPage?
    private var columbiaFlight: (id: UUID, task: Task<CampusColumbiaPage, any Error>)?
    private var menus: [MenuDayKey: CampusMenuResult] = [:]
    private var catalog: [CampusDiningLocation]

    init(school: CampusDiningSchool) {
        self.school = school
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let root = base.appending(path: "CampusDining-v1/\(school.rawValue)", directoryHint: .isDirectory)
        self.root = root
        transport = CampusDiningTransport(root: root)
        catalog = CampusDiningLocation.initialLocations(for: school)
    }

    func cancel() async {
        columbiaFlight?.task.cancel()
        columbiaFlight = nil
        await transport.cancelAll()
    }

    func savedCatalog() -> [CampusDiningLocation] {
        if let data = try? Data(contentsOf: root.appending(path: "catalog.json")),
           let saved = try? JSONDecoder().decode([CampusDiningLocation].self, from: data), !saved.isEmpty { catalog = saved }
        return catalog
    }

    func discover(reload: Bool = false) async -> CampusDiningCatalog {
        var messages: [String] = []
        if school == .uga {
            do {
                let response = try await transport.response(CampusMenuAdapters.url("\(CampusMenuAdapters.ugaAPI)/schools/"), lifetime: 86_400, reload: reload)
                let values = try response.json()
                guard values.isArray else { throw CampusDiningError.schema("UGA catalog") }
                let discovered: [CampusDiningLocation] = values.array.compactMap { entry in
                    guard let slug = entry["slug"].nonempty, let name = entry["name"].nonempty,
                          entry["active_menu_types"].isArray,
                          let sourceURL = URL(string: "https://uga.nutrislice.com/menu/\(slug)") else { return nil }
                    let known = catalog.first { $0.sourceID == slug }
                    return .init(id: known?.id ?? .init(provider: .uga, rawValue: slug), name: name, sourceID: slug,
                                 sourceURL: sourceURL, group: "Dining Commons", isRetail: false,
                                 mealTypes: entry["active_menu_types"].array.compactMap { $0["slug"].nonempty })
                }
                guard !discovered.isEmpty else { throw CampusDiningError.schema("UGA locations") }
                catalog = discovered
                if response.isStale { messages.append("Showing saved locations.") }
            } catch { messages.append("Location updates unavailable.") }
        } else {
            do {
                let response = try await transport.response(CampusMenuAdapters.url("\(CampusMenuAdapters.barnardAPI)/sites/\(CampusMenuAdapters.barnardSite)/locations-public?for_menus=true&locale=en"), lifetime: 86_400, reload: reload)
                let root = try response.json()
                guard root["buildings"].isArray || root["standaloneLocations"].isArray else { throw CampusDiningError.schema("Barnard catalog") }
                let entries = root["buildings"].array.flatMap { $0["locations"].array } + root["standaloneLocations"].array
                let discovered: [CampusDiningLocation] = entries.compactMap { entry in
                    guard let id = entry["id"].nonempty, let name = entry["name"].nonempty, let slug = entry["slug"].nonempty,
                          let sourceURL = URL(string: "https://dineoncampus.com/barnard/whats-on-the-menu/\(slug)") else { return nil }
                    let known = catalog.first { $0.id.provider == .barnard && $0.sourceID == id }
                    return .init(id: known?.id ?? .init(provider: .barnard, rawValue: id), name: entry["useDisplayName"].bool ? entry["displayName"].nonempty ?? name : name,
                                 sourceID: id, sourceURL: sourceURL, group: "Barnard", isRetail: known?.isRetail ?? true)
                }
                if !discovered.isEmpty { catalog = discovered + catalog.filter { $0.id.provider != .barnard } }
                if response.isStale { messages.append("Showing saved Barnard locations.") }
            } catch { messages.append("Barnard location updates unavailable.") }
            do {
                let page = try await columbiaPage(reload: reload)
                catalog = catalog.filter { $0.id.provider != .columbia } + page.locations()
                if page.isStale { messages.append("Showing saved Columbia locations.") }
            } catch { messages.append("Columbia location updates unavailable.") }
        }
        if !Task.isCancelled {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(catalog) { try? data.write(to: root.appending(path: "catalog.json"), options: .atomic) }
        }
        return .init(locations: catalog, message: messages.isEmpty ? nil : messages.joined(separator: " "))
    }

    private func columbiaPage(reload: Bool = false) async throws -> CampusColumbiaPage {
        if !reload, let columbia, Date.now.timeIntervalSince(columbia.fetchedAt) < 900 { return columbia }
        if let columbiaFlight { return try await columbiaFlight.task.value }
        let transport = transport
        let flight = Task { @concurrent in
            let response = try await transport.response(CampusMenuAdapters.url("https://dining.columbia.edu/"), reload: reload)
            return try await CampusColumbiaPage.parse(response)
        }
        let id = UUID()
        columbiaFlight = (id, flight)
        defer { if columbiaFlight?.id == id { columbiaFlight = nil } }
        let value = try await flight.value
        try Task.checkCancellation()
        columbia = value
        return value
    }

    private func menuFile(_ key: MenuDayKey) -> URL {
        root.appending(path: "Menus/\(DiningContentHasher.hash(key.locationID.provider.rawValue + "/" + key.locationID.rawValue + "/" + key.localDate.description + "/" + key.sourceVariant)).json")
    }

    func savedMenu(_ location: CampusDiningLocation, date: DateOnly) -> CampusMenuResult? {
        let key = MenuDayKey(locationID: location.id, localDate: date)
        var saved = menus[key]
        if saved == nil, let data = try? Data(contentsOf: menuFile(key)) { saved = try? JSONDecoder().decode(CampusMenuResult.self, from: data) }
        guard var saved, saved.snapshot.schemaVersion == MenuDaySnapshot.currentSchemaVersion,
              saved.snapshot.key == key, Date.now.timeIntervalSince(saved.snapshot.fetchedAt) < 7 * 86_400 else { return nil }
        saved.isStale = saved.isStale || Date.now.timeIntervalSince(saved.snapshot.fetchedAt) >= 900
        menus[key] = saved
        return saved
    }

    func menu(_ location: CampusDiningLocation, date: DateOnly, reload: Bool = false, background: Bool = false) async throws -> CampusMenuResult {
        guard location.calendarContext.contains(date, relativeTo: .now) else { throw CampusDiningError.noMenu }
        let saved = savedMenu(location, date: date)
        if !reload, let saved, !saved.isStale, saved.availability != .partial { return saved }
        do {
            let result: CampusMenuResult
            switch location.id.provider {
            case .barnard: result = try await CampusMenuAdapters.barnard(location, date: date, transport: transport, reload: reload, background: background)
            case .uga: result = try await CampusMenuAdapters.uga(location, date: date, transport: transport, reload: reload, background: background)
            case .columbia: result = try await columbiaPage(reload: reload).menu(location, date: date)
            default: throw CampusDiningError.invalidResponse
            }
            try Task.checkCancellation()
            // Keep the last complete snapshot if a refresh loses meal periods.
            if result.availability == .partial, var saved, saved.availability != .partial {
                saved.isStale = true
                saved.message = "Refresh was incomplete. Showing the last saved menu."
                return saved
            }
            menus[result.snapshot.key] = result
            if menus.count > 40, let oldest = menus.min(by: { $0.value.snapshot.fetchedAt < $1.value.snapshot.fetchedAt })?.key { menus[oldest] = nil }
            let file = menuFile(result.snapshot.key)
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(result) { try? data.write(to: file, options: .atomic) }
            pruneMenus()
            return result
        } catch {
            try Task.checkCancellation()
            if var saved { saved.isStale = true; saved.message = "Couldn’t refresh. Showing the last saved menu."; return saved }
            throw error
        }
    }

    private func pruneMenus() {
        let directory = root.appending(path: "Menus")
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let sorted = files.sorted { a, b in
            let ad = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let bd = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return ad > bd
        }
        for file in sorted.dropFirst(180) { try? FileManager.default.removeItem(at: file) }
    }

    func information(_ location: CampusDiningLocation) async throws -> String? {
        if let information = location.information, !information.isEmpty { return information }
        guard location.id.provider == .barnard else { return nil }
        let response = try await transport.response(CampusMenuAdapters.url("\(CampusMenuAdapters.barnardAPI)/locations/\(location.sourceID)/details"), lifetime: 86_400)
        let root = try response.json()
        let text = CampusColumbiaPage.text(root["description"].nonempty ?? root["shortDescription"].string)
        return text.isEmpty ? nil : text
    }

    func hours(_ location: CampusDiningLocation, date: DateOnly, reload: Bool = false) async throws -> CampusDiningHours? {
        switch location.id.provider {
        case .barnard:
            let response = try await transport.response(CampusMenuAdapters.url("\(CampusMenuAdapters.barnardAPI)/locations/weekly_schedule?site_id=\(CampusMenuAdapters.barnardSite)&date=\(date)&locale=en"), lifetime: 3_600, reload: reload)
            let root = try response.json()
            let locations = root["theLocations"].isArray ? root["theLocations"].array : root["the_locations"].array
            guard let node = locations.first(where: { $0["id"].string == location.sourceID }),
                  let day = node["week"].array.first(where: { $0["date"].string.hasPrefix(date.description) }) else { return nil }
            let intervals: [CampusDiningHours.Interval] = day["hours"].array.compactMap { hours in
                let start = hours["start_hour"].int * 60 + hours["start_minutes"].int
                var end = hours["end_hour"].int * 60 + hours["end_minutes"].int
                if end <= start { end += 1_440 }
                guard let a = CampusDiningSource.date(date, minutes: start), let b = CampusDiningSource.date(date, minutes: end) else { return nil }
                return .init(start: a, end: b)
            }
            return .init(intervals: intervals, isClosed: day["closed"].bool, sourceText: nil, fetchedAt: response.fetchedAt)
        case .columbia: return try await columbiaPage(reload: reload).hours(location, date: date)
        case .uga:
            let response = try await transport.response(CampusMenuAdapters.url("https://dining.uga.edu/locations/dining-commons/"), lifetime: 3_600, reload: reload)
            return try await Self.ugaHours(response, location: location)
        default: return nil
        }
    }

    @concurrent private static func ugaHours(_ response: CampusDiningResponse, location: CampusDiningLocation) async throws -> CampusDiningHours? {
        let document = try SwiftSoup.Parser.htmlParser().settings(ParseSettings(false, false, false, true)).parseInput([UInt8](response.data), "https://dining.uga.edu/")
        let locations = try document.select(".portal_item.location")
        guard !locations.isEmpty() else { throw CampusDiningError.schema("UGA hours") }
        for node in locations.array() {
            let name = try node.select(".post_title").text().lowercased()
            let key = location.id.rawValue == "village" ? "village" : location.id.rawValue
            guard name.contains(key) else { continue }
            // UGA publishes seasonal schedules and free-text exceptions, sometimes with
            // residency restrictions. Preserve that source text instead of inventing dated hours.
            let text = try node.select(".hours_closures_special_hours").text()
            return .init(intervals: [], isClosed: false, sourceText: text.isEmpty ? nil : text, fetchedAt: response.fetchedAt)
        }
        return nil
    }
}
