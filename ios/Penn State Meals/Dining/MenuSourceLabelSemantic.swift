import UIKit

/// The provider label after normalization. This value contains no UIKit state so it can be
/// computed with the rest of a menu presentation snapshot away from the main actor.
struct MenuSourceLabelSemantic: Hashable, Sendable {
    enum Kind: String, CaseIterable, Hashable, Sendable {
        case vegan
        case vegetarian
        case halal
        case halalFriendly
        case glutenFriendly
        case glutenFree
        case allergenWarning
        case unknown
    }

    enum KnownAllergen: String, CaseIterable, Hashable, Sendable {
        case milk
        case egg
        case fish
        case shellfish
        case peanut
        case treeNut
        case wheat
        case soy
        case sesame
    }

    let sourceText: String
    let kind: Kind
    let knownAllergens: [KnownAllergen]

    init(
        sourceText: String,
        kind: Kind,
        knownAllergens: [KnownAllergen] = []
    ) {
        self.sourceText = sourceText
        self.kind = kind
        self.knownAllergens = knownAllergens
    }

    static func classify(
        _ sourceLabels: [String],
        itemName: String
    ) -> [MenuSourceLabelSemantic] {
        let normalizedItemName = DiningTextNormalizer.foldedWords(itemName)
        var seen = Set<String>()
        var result: [MenuSourceLabelSemantic] = []
        result.reserveCapacity(sourceLabels.count)

        for sourceLabel in sourceLabels {
            let sourceText = sourceLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedLabel = DiningTextNormalizer.foldedWords(sourceText)
            guard !sourceText.isEmpty,
                  normalizedLabel != normalizedItemName,
                  seen.insert(normalizedLabel).inserted else {
                continue
            }
            guard !isPorkOnlyDisclosure(normalizedLabel) else { continue }

            result.append(semantic(for: sourceText, normalized: normalizedLabel))
        }
        return result
    }

    static func allergenWarning(_ sourceText: String) -> MenuSourceLabelSemantic {
        let trimmed = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedText = DiningTextNormalizer.foldedWords(trimmed)
        let allergens = allergens(in: normalizedText)
        return MenuSourceLabelSemantic(
            sourceText: trimmed,
            kind: allergens.isEmpty && hasWord(normalizedText, "pork")
                ? .unknown
                : .allergenWarning,
            knownAllergens: allergens
        )
    }

    var iconAssetNames: [String] {
        switch kind {
        case .allergenWarning:
            knownAllergens.isEmpty
                ? [kind.rawValue]
                : knownAllergens.map(\.rawValue)
        case .unknown: []
        default: [kind.rawValue]
        }
    }

    /// Stable, UIKit-free symbol metadata. Menu rows consume these precomputed descriptors
    /// instead of reclassifying provider labels or constructing text attachments while scrolling.
    var symbolDescriptors: [MenuTraitSymbolDescriptor] {
        switch kind {
        case .allergenWarning where !knownAllergens.isEmpty:
            knownAllergens.map {
                MenuTraitSymbolDescriptor(
                    stableID: "allergen.\($0.rawValue)",
                    assetName: $0.rawValue,
                    tintRole: .allergen
                )
            }
        default:
            iconAssetNames.map {
                MenuTraitSymbolDescriptor(
                    stableID: "\(kind.rawValue).\($0)",
                    assetName: $0,
                    tintRole: tintRole
                )
            }
        }
    }

    private var tintRole: MenuTraitSymbolDescriptor.TintRole {
        switch kind {
        case .vegan: .vegan
        case .vegetarian: .vegetarian
        case .halal, .halalFriendly: .halal
        case .glutenFriendly: .glutenFriendly
        case .glutenFree: .glutenFree
        case .allergenWarning: .allergen
        case .unknown: .unknown
        }
    }

    @MainActor
    var tintColor: UIColor {
        tintRole.color
    }

    private static func semantic(
        for sourceText: String,
        normalized label: String
    ) -> MenuSourceLabelSemantic {
        if (label.hasPrefix("contains") || label.hasPrefix("may contain")) || hasWord(label, "allergen") || hasWord(label, "allergens") {
            let knownAllergens = allergens(in: label)
            return MenuSourceLabelSemantic(
                sourceText: sourceText,
                kind: knownAllergens.isEmpty && hasWord(label, "pork")
                    ? .unknown
                    : .allergenWarning,
                knownAllergens: knownAllergens
            )
        }

        let kind: Kind = switch label {
        case "vegan", "vegan friendly": .vegan
        case "vegetarian", "vegetarian friendly", "meatless", "meat free": .vegetarian
        case "halal": .halal
        case "halal friendly": .halalFriendly
        case "gluten friendly",
             "gluten friendly made w o gluten containing items": .glutenFriendly
        case "gluten free", "gluten gluten free": .glutenFree
        default: .unknown
        }
        return MenuSourceLabelSemantic(sourceText: sourceText, kind: kind)
    }

    private static func isPorkOnlyDisclosure(_ label: String) -> Bool {
        label == "pork"
            || label == "contains pork"
            || label == "may contain pork"
            || label == "contains pork products"
    }

    private static func hasWord(_ value: String, _ word: String) -> Bool {
        var searchStart = value.startIndex
        while let range = value.range(of: word, range: searchStart..<value.endIndex) {
            let startsWord = range.lowerBound == value.startIndex
                || value[value.index(before: range.lowerBound)] == " "
            let endsWord = range.upperBound == value.endIndex
                || value[range.upperBound] == " "
            if startsWord && endsWord { return true }
            searchStart = range.upperBound
        }
        return false
    }

    private static func allergens(in label: String) -> [KnownAllergen] {
        var result: [KnownAllergen] = []

        func append(_ allergen: KnownAllergen, when matches: Bool) {
            if matches, !result.contains(allergen) { result.append(allergen) }
        }

        append(.milk, when: hasWord(label, "milk") || hasWord(label, "dairy"))
        append(.egg, when: hasWord(label, "egg") || hasWord(label, "eggs"))
        append(.fish, when: hasWord(label, "fish"))
        append(
            .shellfish,
            when: ["shellfish", "crustacean", "crustaceans", "shrimp", "crab", "lobster"]
                .contains(where: { hasWord(label, $0) })
        )
        append(.peanut, when: hasWord(label, "peanut") || hasWord(label, "peanuts"))
        append(
            .treeNut,
            when: label.contains("tree nut")
                || [
                    "almond", "almonds", "cashew", "cashews", "pecan", "pecans",
                    "pistachio", "pistachios", "walnut", "walnuts", "hazelnut", "hazelnuts"
                ].contains(where: { hasWord(label, $0) })
        )
        append(.wheat, when: hasWord(label, "wheat"))
        append(
            .soy,
            when: ["soy", "soya", "soybean", "soybeans"].contains(where: { hasWord(label, $0) })
        )
        append(.sesame, when: hasWord(label, "sesame"))
        return result
    }
}

/// One conservative filter contract is consumed by both a hall menu snapshot and global search.
/// Missing metadata is never interpreted as a safety claim: it remains visible unless a provider
/// explicitly declares a requested dietary trait or confirmed allergen presence.
struct DiningDietaryFilter: Hashable, Sendable {
    enum Inclusion: String, CaseIterable, Hashable, Sendable {
        case vegan
        case halal
        case glutenFriendly

        var displayName: String {
            switch self {
            case .vegan: "Vegan"
            case .halal: "Halal"
            case .glutenFriendly: "Gluten Friendly"
            }
        }

        fileprivate var acceptedKinds: Set<MenuSourceLabelSemantic.Kind> {
            switch self {
            case .vegan: [.vegan]
            case .halal: [.halal, .halalFriendly]
            case .glutenFriendly: [.glutenFriendly, .glutenFree]
            }
        }

        fileprivate var assetName: String { rawValue }
    }

    var required: Set<Inclusion> = []

    static let none = DiningDietaryFilter()

    var isEmpty: Bool { required.isEmpty }

    func matches(_ semantics: [MenuSourceLabelSemantic]) -> Bool {
        return required.allSatisfy { inclusion in
            semantics.contains { inclusion.acceptedKinds.contains($0.kind) }
        }
    }

    func matches(sourceLabels: [String], itemName: String) -> Bool {
        matches(MenuSourceLabelSemantic.classify(sourceLabels, itemName: itemName))
    }
}

@MainActor
final class DiningDietaryFilterStore {
    static let shared = DiningDietaryFilterStore()

    private var filters: [DiningProviderID: DiningDietaryFilter] = [:]

    func filter(for provider: DiningProviderID) -> DiningDietaryFilter {
        filters[provider] ?? .none
    }

    func set(_ filter: DiningDietaryFilter, for provider: DiningProviderID) {
        guard filters[provider] != filter else { return }
        filters[provider] = filter
        NotificationCenter.default.post(name: .diningDietaryFilterChanged, object: provider)
    }
}

extension Notification.Name {
    static let diningDietaryFilterChanged = Notification.Name("DiningDietaryFilterChanged")
}

@MainActor
enum DiningDietaryFilterMenu {
    static func make(
        filter: DiningDietaryFilter,
        onChange: @escaping @MainActor (DiningDietaryFilter) -> Void
    ) -> UIMenu {
        let inclusions = DiningDietaryFilter.Inclusion.allCases.map { inclusion in
            UIAction(
                title: inclusion.displayName,
                image: UIImage(named: inclusion.assetName),
                state: filter.required.contains(inclusion) ? .on : .off
            ) { _ in
                var changed = filter
                if changed.required.remove(inclusion) == nil {
                    changed.required.insert(inclusion)
                }
                onChange(changed)
            }
        }
        var sections: [UIMenuElement] = inclusions
        if !filter.isEmpty {
            sections.append(UIMenu(options: .displayInline, children: [
                UIAction(title: "Clear Filters", attributes: .destructive) { _ in
                    onChange(.none)
                }
            ]))
        }
        return UIMenu(children: sections)
    }
}

/// A compact presentation recipe rather than a rendered image. It is safe to build off-main,
/// hashable for deduplication, and reusable across every cell displaying the same trait.
struct MenuTraitSymbolDescriptor: Hashable, Sendable {
    enum TintRole: String, Hashable, Sendable {
        case vegan
        case vegetarian
        case halal
        case glutenFriendly
        case glutenFree
        case allergen
        case unknown
    }

    let stableID: String
    let assetName: String
    let tintRole: TintRole
}

@MainActor
extension MenuTraitSymbolDescriptor.TintRole {
    var color: UIColor {
        switch self {
        case .vegan:
            UIColor { traits in
                traits.accessibilityContrast == .high
                    ? UIColor(red: 0.00, green: 0.34, blue: 0.18, alpha: 1)
                    : UIColor(red: 0.02, green: 0.55, blue: 0.31, alpha: 1)
            }
        case .vegetarian:
            UIColor { traits in
                traits.accessibilityContrast == .high
                    ? UIColor(red: 0.15, green: 0.35, blue: 0.22, alpha: 1)
                    : UIColor(red: 0.36, green: 0.55, blue: 0.40, alpha: 1)
            }
        case .halal:
            .systemTeal
        case .glutenFriendly:
            .systemIndigo
        case .glutenFree:
            .systemPurple
        case .allergen:
            .systemOrange
        case .unknown:
            .tertiaryLabel
        }
    }
}
