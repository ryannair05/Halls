//
//  MealParser.swift
//  Penn State Meals
//
//  Created by Ryan Nair on 2/1/23.
//

import Foundation
@preconcurrency import SwiftSoup

enum DiningSourceError: Error, Sendable, Equatable {
    case invalidURL
    case invalidFormEncoding
    case transport(URLError)
    case nonHTTPResponse
    case unacceptableStatus(Int)
    case emptyBody
    case responseTooLarge(limit: Int)
    case unsupportedMarkup
    case missingMealSelector
    case missingRequiredField(String)
    case noPublishedMenu
}

enum MealParser {
    struct MealSourceOption: Sendable, Equatable {
        let formValue: String
        let displayName: String
        let sourceOrder: Int
    }

    struct ParsedMealOptions: Sendable, Equatable {
        let options: [MealSourceOption]
        let selectedOption: MealSourceOption?
    }

    struct ParsedDiscovery: Sendable, Equatable {
        let options: ParsedMealOptions
        let selectedPeriod: MenuMealPeriod?
        let selectedPeriodFailure: DiningSourceError?
    }

    private struct MenuItemOccurrenceKey: Hashable {
        let id: String
        let displayName: String
        let detailURL: URL?
        let sourceLabels: [String]
    }

    static func formBody(_ fields: [(String, String)]) throws(DiningSourceError) -> Data {
        var components = URLComponents()
        components.queryItems = fields.map { URLQueryItem(name: $0.0, value: $0.1) }
        guard let query = components.percentEncodedQuery,
              let data = query.data(using: .utf8) else {
            throw DiningSourceError.invalidFormEncoding
        }
        return data
    }

    static func parsedDiscovery(
        from data: Data,
        sourceURL: URL
    ) throws -> ParsedDiscovery {
        let document = try parseDocument(data, sourceURL: sourceURL)
        let options = try parsedMealOptions(in: document)

        guard let selectedOption = options.selectedOption else {
            return ParsedDiscovery(
                options: options,
                selectedPeriod: nil,
                selectedPeriodFailure: nil
            )
        }

        do {
            return ParsedDiscovery(
                options: options,
                selectedPeriod: try mealPeriod(
                    named: selectedOption.displayName,
                    sourceOrder: selectedOption.sourceOrder,
                    sourceIdentifier: selectedOption.formValue,
                    in: document
                ),
                selectedPeriodFailure: nil
            )
        } catch let error as DiningSourceError {
            return ParsedDiscovery(
                options: options,
                selectedPeriod: nil,
                selectedPeriodFailure: error
            )
        } catch {
            return ParsedDiscovery(
                options: options,
                selectedPeriod: nil,
                selectedPeriodFailure: .unsupportedMarkup
            )
        }
    }

    private static func parsedMealOptions(in document: Document) throws -> ParsedMealOptions {
        let selector: Element?
        do {
            selector = try document.getElementById("selMeal")
        } catch {
            throw DiningSourceError.unsupportedMarkup
        }
        guard let selector else {
            throw DiningSourceError.missingMealSelector
        }

        let options: Elements
        do {
            options = try selector.getElementsByTag("option")
        } catch {
            throw DiningSourceError.unsupportedMarkup
        }
        if options.isEmpty() {
            if try pageText(document, containsAny: ["no menu", "menu is not available"]) {
                return ParsedMealOptions(
                    options: [],
                    selectedOption: nil
                )
            }
            throw DiningSourceError.missingRequiredField("selMeal option")
        }

        var result: [MealSourceOption] = []
        var selectedSourceOrder: Int?
        result.reserveCapacity(options.size())
        for option in options {
            let name: String
            let formValue: String
            do {
                name = try option.text(trimAndNormaliseWhitespace: false)
                formValue = try option.attr("value")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                throw DiningSourceError.unsupportedMarkup
            }
            guard !name.isEmpty else {
                continue
            }
            guard name.caseInsensitiveCompare("Select Meal") != .orderedSame else {
                continue
            }
            guard !formValue.isEmpty else {
                throw DiningSourceError.missingRequiredField("selMeal option[value]")
            }
            let parsedOption = MealSourceOption(
                formValue: formValue,
                displayName: name,
                sourceOrder: result.count
            )
            if option.hasAttr("selected") {
                selectedSourceOrder = parsedOption.sourceOrder
            }
            result.append(parsedOption)
        }
        if result.isEmpty {
            if try pageText(document, containsAny: ["no menu", "menu is not available"]) {
                return ParsedMealOptions(
                    options: [],
                    selectedOption: nil
                )
            }
            throw DiningSourceError.missingRequiredField("usable selMeal option")
        }
        let selectedOption = selectedSourceOrder.flatMap { sourceOrder in
            result.first { $0.sourceOrder == sourceOrder }
        } ?? result.first
        return ParsedMealOptions(
            options: result,
            selectedOption: selectedOption
        )
    }

    static func mealPeriod(
        named mealName: String,
        sourceOrder: Int,
        sourceIdentifier: String? = nil,
        from data: Data,
        sourceURL: URL
    ) throws -> MenuMealPeriod {
        let document = try parseDocument(data, sourceURL: sourceURL)
        return try mealPeriod(
            named: mealName,
            sourceOrder: sourceOrder,
            sourceIdentifier: sourceIdentifier,
            in: document
        )
    }

    private static func mealPeriod(
        named mealName: String,
        sourceOrder: Int,
        sourceIdentifier: String?,
        in document: Document
    ) throws -> MenuMealPeriod {
        let periodID = stablePeriodID(
            displayName: mealName,
            sourceIdentifier: sourceIdentifier
        )
        let sourceSections: Elements
        do {
            sourceSections = try document.getElementsByClass("menu-category-section")
        } catch {
            throw DiningSourceError.unsupportedMarkup
        }
        guard !sourceSections.isEmpty() else {
            if try pageText(
                document,
                containsAny: ["no items found", "no menu items", "menu is not available"]
            ) {
                return MenuMealPeriod(
                    id: periodID,
                    displayName: mealName,
                    sourceOrder: sourceOrder,
                    sections: []
                )
            }
            throw DiningSourceError.unsupportedMarkup
        }

        var sections: [MenuSection] = []
        sections.reserveCapacity(sourceSections.size())

        for (sectionOrder, sourceSection) in sourceSections.enumerated() {
            let titleElements: Elements
            do {
                titleElements = try sourceSection.getElementsByClass("nutrition-category-title")
            } catch {
                throw DiningSourceError.unsupportedMarkup
            }
            guard let titleElement = titleElements.first() else {
                continue
            }
            let categoryName: String
            do {
                categoryName = try titleElement.text(trimAndNormaliseWhitespace: false)
            } catch {
                throw DiningSourceError.unsupportedMarkup
            }
            guard !categoryName.isEmpty else { continue }

            var items: [DiningMenuItem] = []
            var occurrenceKeys: Set<MenuItemOccurrenceKey> = []
            let sourceItems: Elements
            do {
                sourceItems = try sourceSection.getElementsByClass("daily-menu-item")
            } catch {
                throw DiningSourceError.unsupportedMarkup
            }
            items.reserveCapacity(sourceItems.size())
            occurrenceKeys.reserveCapacity(sourceItems.size())
            for sourceItem in sourceItems {
                let links: Elements
                do {
                    links = try sourceItem.select(Self.itemLinkEvaluator)
                } catch {
                    throw DiningSourceError.unsupportedMarkup
                }
                guard let link = links.first() else {
                    continue
                }
                let publishedName: String
                let detailURL: URL?
                let sourceLabels: [String]
                do {
                    publishedName = try link.text(trimAndNormaliseWhitespace: false)
                    detailURL = try resolvedDetailURL(for: link)
                    sourceLabels = try labels(from: sourceItem)
                } catch {
                    throw DiningSourceError.unsupportedMarkup
                }
                guard !publishedName.isEmpty else {
                    continue
                }
                let itemID = sourceItemID(
                    for: publishedName,
                    detailURL: detailURL
                )
                let occurrenceKey = MenuItemOccurrenceKey(
                    id: itemID,
                    displayName: publishedName,
                    detailURL: detailURL,
                    sourceLabels: sourceLabels
                )
                guard occurrenceKeys.insert(occurrenceKey).inserted else {
                    continue
                }
                items.append(DiningMenuItem(
                    id: itemID,
                    displayName: publishedName,
                    detailURL: detailURL,
                    sourceOrder: items.count,
                    sourceLabels: sourceLabels
                ))
            }

            guard !items.isEmpty else {
                continue
            }

            sections.append(MenuSection(
                id: "\(periodID)-section-\(DiningTextNormalizer.foldedWords(categoryName, separator: "-"))",
                displayName: categoryName,
                sourceOrder: sectionOrder,
                items: items
            ))
        }

        sections = stableDuplicateSectionIDs(sections)
        return MenuMealPeriod(
            id: periodID,
            displayName: mealName,
            sourceOrder: sourceOrder,
            sections: sections
        )
    }

    private static func parseDocument(_ data: Data, sourceURL: URL) throws -> Document {
        guard !data.isEmpty else { throw DiningSourceError.emptyBody }
        do {
            let parser = SwiftSoup.Parser.htmlParser().settings(
                ParseSettings(false, false, false, true)
            )
            return try parser.parseInput([UInt8](data), sourceURL.absoluteString)
        } catch {
            throw DiningSourceError.unsupportedMarkup
        }
    }

    private static func stablePeriodID(
        displayName: String,
        sourceIdentifier: String?
    ) -> String {
        let semantic = DiningTextNormalizer.foldedWords(displayName, separator: "-")
        guard let sourceIdentifier else { return "period-\(semantic)" }
        let source = DiningTextNormalizer.foldedWords(sourceIdentifier, separator: "-")
        return source.isEmpty || source == semantic
            ? "period-\(semantic)"
            : "period-\(source)-\(semantic)"
    }

    private static func stableDuplicateSectionIDs(_ sections: [MenuSection]) -> [MenuSection] {
        var counts: [String: Int] = [:]
        counts.reserveCapacity(sections.count)
        for section in sections {
            counts[section.id, default: 0] += 1
        }
        var occurrenceCounts: [String: Int] = [:]
        occurrenceCounts.reserveCapacity(counts.count)
        return sections.map { section in
            guard counts[section.id, default: 0] > 1 else { return section }
            let occurrence = occurrenceCounts[section.id, default: 0] + 1
            occurrenceCounts[section.id] = occurrence
            return MenuSection(
                id: "\(section.id)-occurrence-\(occurrence)",
                displayName: section.displayName,
                sourceOrder: section.sourceOrder,
                items: section.items
            )
        }
    }

    private static func resolvedDetailURL(for element: Element) throws -> URL? {
        let href = try element.absUrl("href")
        guard !href.isEmpty else { return nil }
        return URL(string: href)
    }

    // These immutable evaluators run once per food item across distinct DOM roots.
    // Saved-menu release measurements justify bypassing string-selector lookup here.
    private static let itemLinkEvaluator = try! QueryParser.parse("a.daily-menu-item__link")
    private static let itemLabelEvaluator = try! QueryParser.parse(".daily-menu-item__icons img[alt]")

    private static func sourceItemID(
        for publishedName: String,
        detailURL: URL?
    ) -> String {
        if let detailURL,
           let components = URLComponents(url: detailURL, resolvingAgainstBaseURL: true),
           let mid = components.queryItems?.first(where: { $0.name == "mid" })?.value,
           !mid.isEmpty {
            return "mid:\(mid)"
        }
        return "name:\(DiningTextNormalizer.foldedWords(publishedName))"
    }

    private static func labels(from element: Element) throws -> [String] {
        let labelledElements = try element.select(Self.itemLabelEvaluator)
        var labels: [String] = []
        var seenLabels: Set<String> = []
        labels.reserveCapacity(labelledElements.size())
        seenLabels.reserveCapacity(labelledElements.size())
        for labelledElement in labelledElements {
            let rawLabel = try labelledElement.attr("alt")
            guard !rawLabel.isEmpty, seenLabels.insert(rawLabel).inserted else { continue }
            labels.append(rawLabel)
        }
        return labels
    }

    private static func pageText(
        _ document: Document,
        containsAny phrases: [String]
    ) throws -> Bool {
        let text: String
        do {
            text = try document
                .text(trimAndNormaliseWhitespace: false)
        } catch {
            throw DiningSourceError.unsupportedMarkup
        }
        return phrases.contains { text.range(of: $0, options: .caseInsensitive) != nil }
    }

}
