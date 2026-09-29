import Foundation

enum DiningTextNormalizer {
    private static let foldingOptions: String.CompareOptions = [
        .caseInsensitive, .diacriticInsensitive, .widthInsensitive
    ]

    static func collapsedWhitespace(_ value: String) -> String {
        var result = String()
        result.reserveCapacity(value.utf8.count)
        var hasOutput = false
        var needsSpace = false

        for scalar in value.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                needsSpace = hasOutput
            } else {
                if needsSpace {
                    result.append(" ")
                    needsSpace = false
                }
                result.unicodeScalars.append(scalar)
                hasOutput = true
            }
        }
        return result
    }

    static func foldedWords(
        _ value: String,
        separator: Character = " "
    ) -> String {
        let folded = value.folding(options: foldingOptions, locale: nil)
        var result = String()
        result.reserveCapacity(folded.utf8.count)
        var hasOutput = false
        var needsSeparator = false

        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if needsSeparator {
                    result.append(separator)
                    needsSeparator = false
                }
                result.unicodeScalars.append(scalar)
                hasOutput = true
            } else {
                needsSeparator = hasOutput
            }
        }
        return result
    }
}

struct DiningServicePeriodID: RawRepresentable, Hashable, Codable, Sendable,
    CustomStringConvertible {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    var description: String { rawValue }
}

extension DiningServicePeriodID {
    static let breakfast = Self(rawValue: "breakfast")
    static let brunch = Self(rawValue: "brunch")
    static let lunch = Self(rawValue: "lunch")
    static let dinner = Self(rawValue: "dinner")
    static let lateNight = Self(rawValue: "late-night")
    static let allDay = Self(rawValue: "all-day")
    static let unknown = Self(rawValue: "unknown")
}

struct DiningServicePeriod: Hashable, Codable, Sendable, Identifiable {
    let id: DiningServicePeriodID
    let displayName: String

    /// Provider-independent presentation order for the service periods whose semantics are
    /// known. Unknown provider labels retain source order after the known periods.
    var sortOrder: Int {
        switch id {
        case .breakfast: 100
        case .brunch: 200
        case .lunch: 300
        case .dinner: 400
        case .lateNight: 500
        case .allDay: 600
        default: 1_000
        }
    }
}

enum DiningServicePeriodNormalizer {
    static func normalize(_ sourceLabel: String) -> DiningServicePeriod {
        let displayName = DiningTextNormalizer.collapsedWhitespace(sourceLabel)
        let token = DiningTextNormalizer.foldedWords(displayName, separator: "-")
        let id: DiningServicePeriodID = switch token {
        case "breakfast", "breakfast-service", "continental-breakfast", "morning":
            .breakfast
        case "brunch", "brunch-service":
            .brunch
        case "lunch", "lunch-service", "midday", "midday-service":
            .lunch
        case "dinner", "dinner-service", "supper", "evening-service":
            .dinner
        case "late-night", "late-night-service", "late-nite", "latenight":
            .lateNight
        case "all-day", "all-day-service", "continuous", "daily":
            .allDay
        default:
            token.isEmpty ? .unknown : DiningServicePeriodID(rawValue: token)
        }

        return DiningServicePeriod(
            id: id,
            displayName: displayName.isEmpty ? fallbackDisplayName(for: id) : displayName
        )
    }

    static func menuLabel(_ menuLabel: String, matchesHoursLabel hoursLabel: String) -> Bool {
        let menuID = normalize(menuLabel).id
        let hoursID = normalize(hoursLabel).id
        if menuID == hoursID { return true }
        return (menuID == .lunch && hoursID == .brunch)
            || (menuID == .brunch && hoursID == .lunch)
    }

    private static func fallbackDisplayName(for id: DiningServicePeriodID) -> String {
        id.rawValue.split(separator: "-").map { $0.capitalized }.joined(separator: " ")
    }
}

extension MenuMealPeriod {
    var servicePeriod: DiningServicePeriod {
        DiningServicePeriodNormalizer.normalize(displayName)
    }
}

extension DiningHoursInterval {
    var servicePeriod: DiningServicePeriod? {
        label.map(DiningServicePeriodNormalizer.normalize)
    }
}
