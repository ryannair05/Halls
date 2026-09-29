import Foundation

/// Stable section identity scoped to one source meal. The occurrence ordinal keeps malformed
/// provider payloads with repeated section IDs legal for diffable data sources without changing
/// the identity of unaffected sections during filtering.
struct MenuPresentationSectionID: Hashable, Sendable {
    let mealID: String
    let sourceSectionID: String
    let occurrence: Int
}

/// Stable occurrence identity. Provider IDs alone are not unique when the same dish is emitted
/// twice in one station, so the source-order occurrence is part of the presentation identity.
struct MenuPresentationRowID: Hashable, Sendable {
    let sectionID: MenuPresentationSectionID
    let sourceItemID: String
    let occurrence: Int
}

struct MenuPresentationRow: Equatable, Sendable {
    let id: MenuPresentationRowID
    let item: DiningMenuItem
    let semantics: [MenuSourceLabelSemantic]
    let symbolDescriptors: [MenuTraitSymbolDescriptor]

    var unknownSourceLabels: [String] {
        semantics.compactMap { $0.kind == .unknown ? $0.sourceText : nil }
    }
}

struct MenuPresentationSection: Equatable, Sendable {
    let id: MenuPresentationSectionID
    let displayName: String
    let rowIDs: [MenuPresentationRowID]
}

/// Immutable, indexed state consumed by `MealsViewController`. All filtering and provider-label
/// classification occurs during construction; UIKit data-source callbacks only perform array or
/// dictionary lookups.
struct MenuPresentationSnapshot: Equatable, Sendable {
    struct StateKey: Hashable, Sendable {
        let sourceKey: MenuDayKey
        let sourceContentHash: String
        let mealID: String
        let normalizedFilter: String
        let dietaryFilter: DiningDietaryFilter
    }

    let key: StateKey
    let sections: [MenuPresentationSection]
    let rowsByID: [MenuPresentationRowID: MenuPresentationRow]
    let symbolDescriptors: Set<MenuTraitSymbolDescriptor>

    var itemIdentifiers: [MenuPresentationRowID] {
        sections.flatMap(\.rowIDs)
    }

    func section(at index: Int) -> MenuPresentationSection? {
        guard sections.indices.contains(index) else { return nil }
        return sections[index]
    }

    /// Swift 6's `@concurrent` guarantees this CPU-only transformation does not inherit the
    /// caller's main-actor executor.
    @concurrent
    static func build(
        sourceKey: MenuDayKey,
        sourceContentHash: String,
        period: MenuMealPeriod,
        filterQuery: String,
        dietaryFilter: DiningDietaryFilter = .none
    ) async throws -> MenuPresentationSnapshot {

        let key = stateKey(
            sourceKey: sourceKey,
            sourceContentHash: sourceContentHash,
            mealID: period.id,
            filterQuery: filterQuery,
            dietaryFilter: dietaryFilter
        )
        let normalizedFilter = key.normalizedFilter
        var sectionIDOccurrences: [String: Int] = [:]
        var sections: [MenuPresentationSection] = []
        var rowsByID: [MenuPresentationRowID: MenuPresentationRow] = [:]
        var descriptors = Set<MenuTraitSymbolDescriptor>()

        sections.reserveCapacity(period.sections.count)
        rowsByID.reserveCapacity(period.sections.reduce(into: 0) { $0 += $1.items.count })

        for sourceSection in period.sections {
            try Task.checkCancellation()

            let sectionOccurrence = sectionIDOccurrences[sourceSection.id, default: 0]
            sectionIDOccurrences[sourceSection.id] = sectionOccurrence + 1
            let sectionID = MenuPresentationSectionID(
                mealID: period.id,
                sourceSectionID: sourceSection.id,
                occurrence: sectionOccurrence
            )
            let sectionMatches = normalizedFilter.isEmpty
                || DiningTextNormalizer.foldedWords(sourceSection.displayName)
                    .contains(normalizedFilter)
            var itemIDOccurrences: [String: Int] = [:]
            var rowIDs: [MenuPresentationRowID] = []
            rowIDs.reserveCapacity(sourceSection.items.count)

            for item in sourceSection.items {
                let itemOccurrence = itemIDOccurrences[item.id, default: 0]
                itemIDOccurrences[item.id] = itemOccurrence + 1
                let rowID = MenuPresentationRowID(
                    sectionID: sectionID,
                    sourceItemID: item.id,
                    occurrence: itemOccurrence
                )
                guard sectionMatches || matches(
                    item: item,
                    normalizedFilter: normalizedFilter
                ) else {
                    continue
                }

                let semantics = MenuSourceLabelSemantic.classify(
                    item.sourceLabels,
                    itemName: item.displayName
                )
                guard dietaryFilter.matches(semantics) else { continue }
                var seenDescriptors = Set<MenuTraitSymbolDescriptor>()
                let itemDescriptors = semantics
                    .flatMap(\.symbolDescriptors)
                    .filter { seenDescriptors.insert($0).inserted }
                descriptors.formUnion(itemDescriptors)
                rowsByID[rowID] = MenuPresentationRow(
                    id: rowID,
                    item: item,
                    semantics: semantics,
                    symbolDescriptors: itemDescriptors
                )
                rowIDs.append(rowID)
            }

            guard !rowIDs.isEmpty else { continue }
            sections.append(MenuPresentationSection(
                id: sectionID,
                displayName: sourceSection.displayName,
                rowIDs: rowIDs
            ))
        }

        return MenuPresentationSnapshot(
            key: key,
            sections: sections,
            rowsByID: rowsByID,
            symbolDescriptors: descriptors
        )
    }

    static func stateKey(
        sourceKey: MenuDayKey,
        sourceContentHash: String,
        mealID: String,
        filterQuery: String,
        dietaryFilter: DiningDietaryFilter = .none
    ) -> StateKey {
        StateKey(
            sourceKey: sourceKey,
            sourceContentHash: sourceContentHash,
            mealID: mealID,
            normalizedFilter: DiningTextNormalizer.foldedWords(filterQuery),
            dietaryFilter: dietaryFilter
        )
    }

    private static func matches(item: DiningMenuItem, normalizedFilter: String) -> Bool {
        guard !normalizedFilter.isEmpty else { return true }
        if DiningTextNormalizer.foldedWords(item.displayName).contains(normalizedFilter) { return true }
        return item.sourceLabels.contains {
            DiningTextNormalizer.foldedWords($0).contains(normalizedFilter)
        }
    }
}
