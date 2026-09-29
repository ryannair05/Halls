import Foundation
import SwiftSoup

struct CampusColumbiaPage: Sendable {
    let nodes: CampusJSON
    let terms: CampusJSON
    let menus: [String: CampusJSON]
    let fetchedAt: Date
    let isStale: Bool

    /// The university embeds JSON in JavaScript template strings. Decode literals only;
    /// never evaluate scripts, interpolate expressions, or strip backslashes wholesale.
    static func literal(_ raw: String) throws -> CampusJSON {
        var jsonString = "\""
        var index = raw.startIndex
        while index < raw.endIndex {
            let c = raw[index]
            index = raw.index(after: index)
            if c == "\\" {
                guard index < raw.endIndex else { throw CampusDiningError.schema("Truncated template") }
                let next = raw[index]
                index = raw.index(after: index)
                switch next {
                case "'", "`": jsonString.append(next)
                case "\n": break
                default: jsonString.append("\\"); jsonString.append(next)
                }
            } else {
                switch c {
                case "\"": jsonString += "\\\""
                case "\n": jsonString += "\\n"
                case "\r": jsonString += "\\r"
                case "\t": jsonString += "\\t"
                default: jsonString.append(c)
                }
            }
        }
        jsonString += "\""
        let decoded = try JSONDecoder().decode(String.self, from: Data(jsonString.utf8))
        return try JSONDecoder().decode(CampusJSON.self, from: Data(decoded.utf8))
    }

    @concurrent static func parse(_ response: CampusDiningResponse) async throws -> Self {
        let document = try SwiftSoup.Parser.htmlParser().settings(ParseSettings(false, false, false, true)).parseInput([UInt8](response.data), "https://dining.columbia.edu/")
        let scripts = try document.select("script").array().map { $0.data() }.joined(separator: "\n")
        func extract(_ pattern: String) throws -> [(String, String)] {
            // Match only assignment prefixes. A repeated regex over a megabyte-sized
            // literal can exhaust ICU's backtracking stack and silently miss later halls.
            let expression = try NSRegularExpression(pattern: pattern)
            return try expression.matches(in: scripts, range: NSRange(scripts.startIndex..., in: scripts)).map { match in
                guard let assignment = Range(match.range, in: scripts) else { throw CampusDiningError.schema("Columbia assignment") }
                let start = assignment.upperBound
                var cursor = start
                while cursor < scripts.endIndex {
                    if scripts[cursor] == "`" { break }
                    if scripts[cursor] == "\\" {
                        cursor = scripts.index(after: cursor)
                        guard cursor < scripts.endIndex else { throw CampusDiningError.schema("Columbia escape") }
                    }
                    cursor = scripts.index(after: cursor)
                }
                guard cursor < scripts.endIndex else { throw CampusDiningError.schema("Columbia template") }
                let key = match.numberOfRanges > 1 ? Range(match.range(at: 1), in: scripts).map { String(scripts[$0]) } ?? "" : ""
                return (key, String(scripts[start..<cursor]))
            }
        }
        guard let nodes = try extract(#"var\s+dining_nodes\s*=\s*"# + "`").first,
              let terms = try extract(#"var\s+dining_terms\s*=\s*"# + "`").first else { throw CampusDiningError.schema("Columbia catalog") }
        let parsedNodes = try literal(nodes.1)
        let parsedTerms = try literal(terms.1)
        guard parsedNodes["locations"].isArray, parsedTerms["types"].isObject, parsedTerms["stations"].isObject else { throw CampusDiningError.schema("Columbia terms") }
        var menus: [String: CampusJSON] = [:]
        for (id, value) in try extract(#"hall_menus_data\[(\d+)\]\s*=\s*JSON\.parse\(\s*"# + "`") {
            let menu = try literal(value)
            guard menu.isArray else { throw CampusDiningError.schema("Columbia menus") }
            menus[id] = menu
        }
        guard !menus.isEmpty else { throw CampusDiningError.schema("Columbia menu scripts") }
        return Self(nodes: parsedNodes, terms: parsedTerms, menus: menus, fetchedAt: response.fetchedAt, isStale: response.isStale)
    }

    func locations() -> [CampusDiningLocation] {
        let fallback = CampusDiningLocation.initialLocations(for: .barnardColumbia)
        return nodes["locations"].array.compactMap { node in
            guard let id = node["nid"].nonempty else { return nil }
            let known = fallback.first { $0.id.provider == .columbia && $0.sourceID == id }
            let path = node["path"].nonempty
            guard let sourceURL = path.flatMap({ URL(string: $0, relativeTo: URL(string: "https://dining.columbia.edu"))?.absoluteURL }) ?? known?.sourceURL else { return nil }
            return .init(id: .init(provider: .columbia, rawValue: id), name: Self.text(node["title"].string), sourceID: id,
                         sourceURL: sourceURL, group: "Columbia", isRetail: menus[id] == nil, information: [Self.text(node["address"].string), Self.text(node["description"].string)].filter { !$0.isEmpty }.joined(separator: "\n\n"))
        }
    }

    static func text(_ value: String) -> String {
        // Plain strings avoid DOM construction; entity-bearing/HTML fields use task-local parsing.
        guard value.contains("&") || value.contains("<") else { return value.trimmingCharacters(in: .whitespacesAndNewlines) }
        return (try? SwiftSoup.parseBodyFragment(value).text()) ?? value
    }

    static func sourceDate(_ value: String) -> Date? {
        // Drupal emits timezone-less UTC timestamps, not New York wall times.
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: value.hasSuffix("Z") ? value : value + "Z")
    }

    @concurrent func menu(_ location: CampusDiningLocation, date: DateOnly) async throws -> CampusMenuResult {
        guard let payload = menus[location.sourceID] else {
            return .init(snapshot: CampusDiningSource.snapshot(location: location, date: date, meals: [], fetchedAt: fetchedAt), availability: .unpublished,
                         isStale: isStale, message: "This location has not published a daily menu.")
        }
        var mealOrder: [String] = []
        var sections: [String: [MenuSection]] = [:]
        var descriptions: [String: String] = [:]
        var malformed = false
        for record in payload.array {
            try Task.checkCancellation()
            guard record["date_range_fields"].isArray else { malformed = true; continue }
            for (ri, range) in record["date_range_fields"].array.enumerated() {
                guard let start = Self.sourceDate(range["date_from"].string), let end = Self.sourceDate(range["date_to"].string) else { malformed = true; continue }
                // Select by the source's Eastern service date; an overnight menu belongs to its starting day.
                guard location.calendarContext.localDate(containing: start) <= date,
                      date <= location.calendarContext.localDate(containing: end),
                      location.calendarContext.localDate(containing: start) == date || end.timeIntervalSince(start) > 86_400 else { continue }
                guard range["stations"].isArray, range["menu_type"].isArray else { malformed = true; continue }
                for type in range["menu_type"].array {
                    let mealID = type.string
                    if !mealOrder.contains(mealID) { mealOrder.append(mealID) }
                    for (si, station) in range["stations"].array.enumerated() {
                        let stationID = station["station"].array.first?.string ?? "\(si)"
                        let id = "\(record["nid"].string)/\(ri)/\(si)/\(stationID)"
                        guard station["meals_paragraph"].isArray else { malformed = true; continue }
                        var items: [DiningMenuItem] = []
                        for (ii, food) in station["meals_paragraph"].array.enumerated() {
                            let name = Self.text(food["title"].string)
                            guard !name.isEmpty else { continue }
                            let itemID = "\(mealID)/\(id)/\(ii)"
                            let prefs = food["prefs"].array.map { Self.text($0.string) }.filter { !$0.isEmpty }
                            let allergens = food["allergens"].array.map { Self.text($0.string) }.filter { !$0.isEmpty }
                            items.append(.init(id: itemID, displayName: name, detailURL: location.sourceURL, sourceOrder: ii,
                                sourceLabels: prefs + allergens,
                                detailMetadata: .init(sourceURL: location.sourceURL, fetchedAt: fetchedAt, ingredients: nil,
                                    allergenStatement: allergens.isEmpty ? nil : allergens.joined(separator: ", "), nutrition: [])))
                            let description = Self.text(food["meal_text"].string)
                            if !description.isEmpty { descriptions[itemID] = description }
                        }
                        sections[mealID, default: []].append(.init(id: id, displayName: Self.text(terms["stations"][stationID]["name"].nonempty ?? "Menu"), sourceOrder: sections[mealID, default: []].count, items: items))
                    }
                }
            }
        }
        let meals = mealOrder.enumerated().map { index, id in
            MenuMealPeriod(id: id, displayName: Self.text(terms["types"][id]["name"].nonempty ?? "Menu"), sourceOrder: index, sections: sections[id] ?? [])
        }
        if malformed && meals.isEmpty { throw CampusDiningError.schema("Columbia menu ranges") }
        let snapshot = CampusDiningSource.snapshot(location: location, date: date, meals: meals, fetchedAt: fetchedAt)
        return .init(snapshot: snapshot, availability: malformed ? .partial : snapshot.hasPublishedItems ? .published : .unpublished,
                     isStale: isStale, message: malformed ? "Some source menu entries could not be read." : nil, descriptions: descriptions)
    }

    func hours(_ location: CampusDiningLocation, date: DateOnly, includingCarryover: Bool = true) -> CampusDiningHours? {
        guard let node = nodes["locations"].array.first(where: { $0["nid"].string == location.sourceID }),
              let midnight = location.calendarContext.date(on: date, minutesAfterMidnight: 0) else { return nil }
        let weekday = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"][location.calendarContext.calendar.component(.weekday, from: midnight) - 1]
        var intervals: [CampusDiningHours.Interval] = []
        var matched = false
        var notes: [String] = []
        for range in node["open_hours_fields"].array {
            guard let start = Self.sourceDate(range["date_from"].string), let end = Self.sourceDate(range["date_to"].string),
                  location.calendarContext.localDate(containing: start) <= date, date <= location.calendarContext.localDate(containing: end) else { continue }
            matched = true
            if range["excluded"].array.contains(where: { $0.string == date.description }) { continue }
            notes += range["displayed_hours"].array.compactMap { $0["title"].nonempty }.map(Self.text)
            for days in range["days"].array {
                for hours in days["days_" + weekday].array {
                    guard let from = Int(hours["hours_from"].string), let to = Int(hours["hours_to"].string) else { continue }
                    let startMinutes = from / 100 * 60 + from % 100
                    var endMinutes = to / 100 * 60 + to % 100
                    if endMinutes <= startMinutes { endMinutes += 1_440 }
                    if let a = CampusDiningSource.date(date, minutes: startMinutes), let b = CampusDiningSource.date(date, minutes: endMinutes) { intervals.append(.init(start: a, end: b)) }
                }
            }
        }
        guard matched else { return nil }
        var result = CampusDiningHours(intervals: intervals, isClosed: intervals.isEmpty && notes.isEmpty, sourceText: notes.isEmpty ? nil : notes.joined(separator: "\n"), fetchedAt: fetchedAt)
        if includingCarryover, let previous = date.addingDays(-1), let prior = hours(location, date: previous, includingCarryover: false) {
            result.carryoverIntervals = prior.intervals.filter { $0.end > midnight }
        }
        return result
    }
}
