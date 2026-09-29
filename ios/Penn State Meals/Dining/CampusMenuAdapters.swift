import Foundation
import SwiftSoup

/// All DOMs and dynamic JSON values remain local to the concurrent extraction task.
enum CampusMenuAdapters {
    static let barnardAPI = "https://apiv4.dineoncampus.com"
    static let barnardSite = "5cb77d6e4198d40babbc28b5"
    static let ugaAPI = "https://uga.api.nutrislice.com/menu/api"

    static func url(_ value: String) throws -> URL {
        guard let url = URL(string: value), url.scheme == "https" else { throw CampusDiningError.invalidResponse }
        return url
    }

    @concurrent static func barnard(_ location: CampusDiningLocation, date: DateOnly, transport: CampusDiningTransport, reload: Bool, background: Bool) async throws -> CampusMenuResult {
        let response = try await transport.response(url("\(barnardAPI)/locations/\(location.sourceID)/periods/?date=\(date)"), reload: reload, background: background)
        let root = try response.json()
        guard root["periods"].isArray else { throw CampusDiningError.schema("Barnard periods") }
        let periods = root["periods"].array
        var meals: [MenuMealPeriod] = []
        var descriptions: [String: String] = [:]
        var failures = 0
        var stale = response.isStale
        var fetchedAt = response.fetchedAt
        var explicitlyClosed = root["menu"]["closedOnDate"].bool
        let values = await withTaskGroup(of: (Int, CampusDiningResponse?).self) { @concurrent group in
            for (index, period) in periods.enumerated() {
                group.addTask { @concurrent in
                    if index == 0, root["menu"]["period"]["categories"].isArray,
                       let data = try? JSONEncoder().encode(root["menu"]) {
                        return (index, CampusDiningResponse(data: data, fetchedAt: response.fetchedAt, isStale: response.isStale))
                    }
                    do {
                        let value = try await transport.response(url("\(barnardAPI)/locations/\(location.sourceID)/menu?date=\(date)&period=\(period["id"].string)"), reload: reload, background: background)
                        return (index, value)
                    } catch { return (index, nil) }
                }
            }
            var values: [(Int, CampusDiningResponse?)] = []
            for await value in group { values.append(value) }
            return values.sorted { $0.0 < $1.0 }
        }
        try Task.checkCancellation()
        for (index, value) in values {
            guard let value, let menu = try? value.json() else { failures += 1; continue }
            if menu["closedOnDate"].bool { explicitlyClosed = true }
            guard menu["period"]["categories"].isArray else {
                if !menu["closedOnDate"].bool { failures += 1 }
                continue
            }
            stale = stale || value.isStale
            fetchedAt = min(fetchedAt, value.fetchedAt)
            explicitlyClosed = explicitlyClosed || menu["closedOnDate"].bool
            let period = periods[index]
            let mealID = period["slug"].nonempty ?? period["id"].nonempty ?? "meal-\(index)"
            var sections: [MenuSection] = []
            for (si, section) in CampusDiningSource.ordered(menu["period"]["categories"].array, key: "sortOrder").enumerated() {
                guard section["items"].isArray else { failures += 1; continue }
                let sectionID = section["id"].nonempty ?? "section-\(si)"
                var items: [DiningMenuItem] = []
                for (ii, food) in CampusDiningSource.ordered(section["items"].array, key: "sortOrder").enumerated() {
                    guard let name = food["name"].nonempty else { continue }
                    let id = "\(mealID)/\(sectionID)/\(food["id"].nonempty ?? String(ii))/\(ii)"
                    let filters = food["filters"].array
                    let customDisclosures = food["customAllergens"].array.compactMap { $0.nonempty ?? $0["name"].nonempty }
                    let labels = filters.compactMap { $0["name"].nonempty } + customDisclosures
                    var facts = food["nutrients"].array.compactMap { nutrient -> DiningNutritionFact? in
                        guard let name = nutrient["name"].nonempty, let value = nutrient["value"].nonempty, value != "-" else { return nil }
                        let unit = nutrient["uom"].string
                        let suffix = unit.isEmpty || value.lowercased().contains(unit.lowercased()) ? "" : " \(unit)"
                        let displayName = name.replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression)
                        return DiningNutritionFact(name: displayName == "Total Carbohydrates" ? "Total Carbohydrate" : displayName, value: value + suffix)
                    }
                    if !facts.contains(where: { $0.name.lowercased().contains("calor") }), let calories = food["calories"].nonempty, calories != "-" {
                        facts.insert(.init(name: "Calories", value: calories), at: 0)
                    }
                    if let portion = food["portion"].nonempty { facts.insert(.init(name: "Serving Size", value: portion), at: 0) }
                    let disclosures = filters.filter { !$0["icon"].bool }.compactMap { $0["name"].nonempty } + customDisclosures
                    let metadata = DiningMenuItemDetailMetadata(sourceURL: location.sourceURL, fetchedAt: value.fetchedAt,
                        ingredients: food["ingredients"].nonempty, allergenStatement: disclosures.isEmpty ? nil : disclosures.joined(separator: ", "), nutrition: facts)
                    items.append(.init(id: id, displayName: name, detailURL: location.sourceURL, sourceOrder: ii, sourceLabels: labels, detailMetadata: metadata))
                    descriptions[id] = food["desc"].nonempty
                }
                sections.append(.init(id: sectionID, displayName: section["name"].string, sourceOrder: si, items: items))
            }
            meals.append(.init(id: mealID, displayName: period["name"].string, sourceOrder: index, sections: sections))
        }
        if !periods.isEmpty, failures == periods.count, meals.isEmpty { throw CampusDiningError.invalidResponse }
        let snapshot = CampusDiningSource.snapshot(location: location, date: date, meals: meals, fetchedAt: fetchedAt)
        return .init(snapshot: snapshot, availability: failures > 0 ? .partial : snapshot.hasPublishedItems ? .published : explicitlyClosed ? .closed : .unpublished,
                     isStale: stale, message: failures > 0 ? "Some meal periods could not be loaded." : nil, descriptions: descriptions)
    }

    @concurrent static func uga(_ location: CampusDiningLocation, date: DateOnly, transport: CampusDiningTransport, reload: Bool, background: Bool) async throws -> CampusMenuResult {
        let catalogResponse = try await transport.response(url("\(ugaAPI)/schools/"), lifetime: 86_400, reload: reload, background: background)
        let catalog = try catalogResponse.json()
        guard catalog.isArray, let school = catalog.array.first(where: { $0["slug"].string == location.sourceID }), school["active_menu_types"].isArray else { throw CampusDiningError.schema("UGA catalog") }
        let types = school["active_menu_types"].array
        let context = location.calendarContext
        guard let instant = context.date(on: date, minutesAfterMidnight: 0),
              let week = date.addingDays(-(context.calendar.component(.weekday, from: instant) - 1)) else { throw CampusDiningError.invalidResponse }
        let values = await withTaskGroup(of: (Int, CampusDiningResponse?).self) { @concurrent group in
            for (index, type) in types.enumerated() {
                group.addTask { @concurrent in
                    do {
                        let response = try await transport.response(url("\(ugaAPI)/weeks/school/\(location.sourceID)/menu-type/\(type["slug"].string)/\(week.year)/\(week.month)/\(week.day)/"), reload: reload, background: background)
                        return (index, response)
                    } catch { return (index, nil) }
                }
            }
            var values: [(Int, CampusDiningResponse?)] = []
            for await value in group { values.append(value) }
            return values.sorted { $0.0 < $1.0 }
        }
        try Task.checkCancellation()
        var meals: [MenuMealPeriod] = []
        var descriptions: [String: String] = [:]
        var failures = 0
        var hasUnpublishedMeals = false
        var stale = catalogResponse.isStale
        var fetchedAt = Date.now
        let nutrients: [(String, String, String)] = [("calories", "Calories", ""), ("g_fat", "Total Fat", "g"), ("g_saturated_fat", "Saturated Fat", "g"), ("g_trans_fat", "Trans Fat", "g"), ("mg_cholesterol", "Cholesterol", "mg"), ("mg_sodium", "Sodium", "mg"), ("g_carbs", "Total Carbohydrate", "g"), ("g_fiber", "Dietary Fiber", "g"), ("g_sugar", "Total Sugars", "g"), ("g_added_sugar", "Added Sugars", "g"), ("g_protein", "Protein", "g"), ("mg_calcium", "Calcium", "mg"), ("mg_iron", "Iron", "mg"), ("mg_potassium", "Potassium", "mg")]
        for (index, response) in values {
            guard let response, let root = try? response.json(), root["days"].isArray,
                  let day = root["days"].array.first(where: { $0["date"].string == date.description }), day["menu_items"].isArray else { failures += 1; continue }
            hasUnpublishedMeals = hasUnpublishedMeals || day["has_unpublished_menus"].bool
            stale = stale || response.isStale
            fetchedAt = min(fetchedAt, response.fetchedAt)
            let type = types[index]
            let mealID = type["slug"].string
            var sections: [MenuSection] = []
            var items: [DiningMenuItem] = []
            var sectionName = "Menu"
            var sectionID = "default"
            var currentMenuID: String?
            // menu_id groups can have separate position sequences; honor menu_info first.
            let rows = day["menu_items"].array.enumerated().sorted { a, b in
                let ai = day["menu_info"][a.element["menu_id"].string]["position"].int
                let bi = day["menu_info"][b.element["menu_id"].string]["position"].int
                if ai != bi { return ai < bi }
                let ap = a.element["position"].int, bp = b.element["position"].int
                return ap == bp ? a.offset < b.offset : ap < bp
            }.map(\.element)
            for (ii, row) in rows.enumerated() {
                let menuID = row["menu_id"].string
                if menuID != currentMenuID {
                    if !items.isEmpty { sections.append(.init(id: sectionID, displayName: sectionName, sourceOrder: sections.count, items: items)); items = [] }
                    currentMenuID = menuID
                    sectionID = menuID
                    sectionName = day["menu_info"][menuID]["section_options"]["display_name"].nonempty ?? "Menu"
                }
                if row["is_section_title"].bool {
                    if !items.isEmpty { sections.append(.init(id: sectionID, displayName: sectionName, sourceOrder: sections.count, items: items)); items = [] }
                    sectionName = row["text"].nonempty ?? "Menu"
                    sectionID = row["id"].nonempty ?? "section-\(ii)"
                    continue
                }
                let food = row["food"]
                guard let name = food["name"].nonempty else { continue }
                let id = "\(mealID)/\(row["id"].nonempty ?? String(ii))/\(ii)"
                let icons = food["icons"]["food_icons"].array.filter { $0["enabled"].bool }
                let labels = icons.compactMap { $0["name"].nonempty }
                var facts = nutrients.compactMap { key, name, unit -> DiningNutritionFact? in
                    guard food["has_nutrition_info"].bool, let value = food["rounded_nutrition_info"][key].nonempty else { return nil }
                    return .init(name: name, value: value + (unit.isEmpty ? "" : " \(unit)"))
                }
                let serving = [food["serving_size_info"]["serving_size_amount"].string, food["serving_size_info"]["serving_size_unit"].string].filter { !$0.isEmpty }.joined(separator: " ")
                if !serving.isEmpty { facts.insert(.init(name: "Serving Size", value: serving), at: 0) }
                let allergens = icons.filter { $0["behavior"].int == 1 }.compactMap { $0["name"].nonempty }
                items.append(.init(id: id, displayName: name, detailURL: location.sourceURL, sourceOrder: ii, sourceLabels: labels,
                    detailMetadata: .init(sourceURL: location.sourceURL, fetchedAt: response.fetchedAt, ingredients: food["ingredients"].nonempty,
                        allergenStatement: allergens.isEmpty ? nil : allergens.joined(separator: ", "), nutrition: facts)))
                descriptions[id] = food["description"].nonempty
            }
            if !items.isEmpty { sections.append(.init(id: sectionID, displayName: sectionName, sourceOrder: sections.count, items: items)) }
            meals.append(.init(id: mealID, displayName: type["name"].string, sourceOrder: index, sections: sections))
        }
        if !types.isEmpty, failures == types.count { throw CampusDiningError.invalidResponse }
        let snapshot = CampusDiningSource.snapshot(location: location, date: date, meals: meals, fetchedAt: fetchedAt)
        return .init(snapshot: snapshot, availability: failures > 0 || (hasUnpublishedMeals && snapshot.hasPublishedItems) ? .partial : snapshot.hasPublishedItems ? .published : .unpublished,
                     isStale: stale, message: failures > 0 ? "Some meal periods could not be loaded." : hasUnpublishedMeals ? "Some menus have not been published yet." : nil, descriptions: descriptions)
    }
}
