import Foundation

/// Parser for Engage's occurrence-based public feed. It does not invent recurring occurrences.
enum DiscoverICalendar {
    struct Property {
        let name: String
        let parameters: [String: String]
        let value: String
    }
    static func parse(_ data: Data) throws -> [CampusEvent] {
        guard let text = String(data: data, encoding: .utf8), text.contains("BEGIN:VCALENDAR"), text.contains("END:VCALENDAR") else {
            throw DiscoverError.invalidResponse
        }
        var lines: [String] = []
        for line in text.replacing("\r\n", with: "\n").components(separatedBy: "\n") {
            if (line.hasPrefix(" ") || line.hasPrefix("\t")), !lines.isEmpty {
                lines[lines.count - 1] += line.dropFirst()
            } else { lines.append(line) }
        }
        var properties: [Property]? = nil
        var events: [String: CampusEvent] = [:]
        var sawEvent = false
        for line in lines {
            if line == "BEGIN:VEVENT" { sawEvent = true; properties = []; continue }
            if line == "END:VEVENT" {
                if let properties, let event = event(properties) { events[event.id] = event }
                properties = nil
                continue
            }
            if properties != nil, let separator = line.firstIndex(of: ":") {
                let key = line[..<separator].components(separatedBy: ";")
                var parameters: [String: String] = [:]
                for part in key.dropFirst() {
                    let pair = part.split(separator: "=", maxSplits: 1)
                    if pair.count == 2 { parameters[String(pair[0]).uppercased()] = String(pair[1]).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
                }
                properties?.append(Property(name: key[0].uppercased(), parameters: parameters, value: String(line[line.index(after: separator)...])))
            }
        }
        guard properties == nil, !sawEvent || !events.isEmpty else { throw DiscoverError.invalidResponse }
        return Array(events.values)
    }
    static func unescape(_ value: String) -> String {
        var result = ""
        var escaped = false
        for character in value {
            if escaped {
                result.append(character == "n" || character == "N" ? "\n" : character)
                escaped = false
            } else if character == "\\" { escaped = true }
            else { result.append(character) }
        }
        if escaped { result.append("\\") }
        return result
    }
    static func list(_ value: String) -> [String] {
        var values: [String] = []
        var current = ""
        var escaped = false
        for character in value {
            if character == ",", !escaped { values.append(unescape(current)); current = "" }
            else { current.append(character) }
            if character == "\\", !escaped { escaped = true } else { escaped = false }
        }
        values.append(unescape(current))
        return values.filter { !$0.isEmpty }
    }
    static func date(_ property: Property) -> Date? {
        let allDay = property.parameters["VALUE"] == "DATE" || property.value.count == 8
        let utc = property.value.hasSuffix("Z")
        let timeZone = if utc { TimeZone(secondsFromGMT: 0)! }
            else { property.parameters["TZID"].flatMap(TimeZone.init(identifier:)) ?? PSUDiscover.timeZone }
        let format: Date.FormatString = if allDay {
            "\(year: .padded(4))\(month: .twoDigits)\(day: .twoDigits)"
        } else {
            "\(year: .padded(4))\(month: .twoDigits)\(day: .twoDigits)T\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)\(second: .twoDigits)"
        }
        let value = utc ? String(property.value.dropLast()) : property.value
        return try? Date.ParseStrategy(format: format, locale: Locale(identifier: "en_US_POSIX"),
            timeZone: timeZone, calendar: Calendar(identifier: .gregorian), isLenient: false).parse(value)
    }
    private static func event(_ properties: [Property]) -> CampusEvent? {
        func first(_ name: String) -> Property? { properties.first { $0.name == name } }
        func text(_ name: String) -> String { first(name).map { unescape($0.value) } ?? "" }
        guard let startProperty = first("DTSTART"), let start = date(startProperty),
              !text("UID").isEmpty, !text("SUMMARY").isEmpty else { return nil }
        let uid = text("UID")
        let end = first("DTEND").flatMap(date)
        guard end.map({ $0 >= start }) ?? true else { return nil }
        let url = PSUDiscover.httpsURL(text("URL")) ?? PSUDiscover.httpsURL(uid)
        var hosts = properties.filter { $0.name == "X-HOSTS" }.flatMap { list($0.value) }
        if hosts.isEmpty, let organizer = first("ORGANIZER") {
            let host = organizer.parameters["CN"] ?? organizer.value
            if !host.hasPrefix("mailto:") { hosts = [unescape(host)] }
        }
        let description = text("DESCRIPTION")
        let descriptionLines = description.components(separatedBy: "\n")
        let onlineURL = descriptionLines.first { $0.hasPrefix("Online Location: ") }
            .flatMap { PSUDiscover.httpsURL(String($0.dropFirst("Online Location: ".count)).trimmingCharacters(in: .whitespaces)) }
        if hosts.isEmpty, let hosted = description.components(separatedBy: "\n").first(where: { $0.hasPrefix("Hosted by: ") }) {
            hosts = [String(hosted.dropFirst("Hosted by: ".count))]
        }
        let geo = text("GEO").split(separator: ";").compactMap { Double($0) }
        // The feed appends structured host/link metadata to the description. Present it once in the UI.
        let prose = descriptionLines.filter {
            !$0.hasPrefix("Hosted by: ") && !$0.hasPrefix("Online Location: ") && !$0.hasPrefix("Additional Information can be found at: ")
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return CampusEvent(id: PSUDiscover.eventID(url: url, fallback: uid), title: text("SUMMARY"),
            description: prose, start: start, end: end,
            isAllDay: startProperty.parameters["VALUE"] == "DATE" || startProperty.value.count == 8,
            location: text("LOCATION"), hostNames: hosts, organizationIDs: [],
            categories: properties.filter { $0.name == "CATEGORIES" }.flatMap { list($0.value) }, benefits: [],
            officialURL: url, imageURL: nil, latitude: geo.count == 2 ? geo[0] : nil,
            longitude: geo.count == 2 ? geo[1] : nil, source: .iCalendar, isCancelled: text("STATUS") == "CANCELLED", onlineURL: onlineURL)
    }
}
