import WidgetKit
import SwiftUI
import AppIntents

struct DiningMenuEntry: TimelineEntry {
    let date: Date
    let hallID: String?
    let hallName: String
    let serviceDate: DateOnly
    let mealID: String?
    let mealName: String?
    let sections: [WidgetMealSection]
    let message: String?
    let status: String?
    let nextRefresh: Date
    var relevanceDuration: TimeInterval = 0

    var relevance: TimelineEntryRelevance? {
        // An explicit zero keeps unavailable, closed and stale entries out of Smart Rotate.
        TimelineEntryRelevance(score: PSUDiningAccess.isEnabled && relevanceDuration > 0 ? 100 : 0,
                               duration: relevanceDuration)
    }

    var destinationURL: URL? {
        guard let hallID, PSUDiningAccess.isEnabled else { return nil }
        return PSUDiningLinks.hall(hallID, date: serviceDate, meal: mealID)
    }
    static var preview: Self {
        let now = Date.now
        return Self(date: now, hallID: "west", hallName: "West", serviceDate: PSUServiceSelection.calendar.serviceDate(containing: now),
                    mealID: "dinner", mealName: "Dinner",
                    sections: [WidgetMealSection(id: "entrees", name: "Entrees", items: [
                        WidgetMealItem(id: "chicken", name: "Grilled Chicken"), WidgetMealItem(id: "tofu", name: "Vegetable Stir Fry")]),
                        WidgetMealSection(id: "sides", name: "Sides", items: [WidgetMealItem(id: "rice", name: "Brown Rice"), WidgetMealItem(id: "broccoli", name: "Roasted Broccoli")])],
                    message: nil, status: "Open now", nextRefresh: now.addingTimeInterval(3600))
    }
}

struct DiningMenuProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> DiningMenuEntry { .preview }
    @concurrent func snapshot(for configuration: PSUDiningWidgetConfiguration, in context: Context) async -> DiningMenuEntry {
        if context.isPreview { return .preview }
        return await entries(configuration).first ?? .preview
    }
    @concurrent func timeline(for configuration: PSUDiningWidgetConfiguration, in context: Context) async -> Timeline<DiningMenuEntry> {
        let entries = await entries(configuration)
        return Timeline(entries: entries, policy: .after(entries.first?.nextRefresh ?? .now.addingTimeInterval(15 * 60)))
    }
    @concurrent private func entries(_ configuration: PSUDiningWidgetConfiguration) async -> [DiningMenuEntry] {
        let now = Date.now
        let day = PSUServiceSelection.calendar.serviceDate(containing: now)
        let hall = configuration.diningHall?.hall
        func unavailable(_ message: String) -> [DiningMenuEntry] {
            [DiningMenuEntry(date: now, hallID: hall?.rawValue, hallName: hall?.rawValue.capitalized ?? "PSU Dining",
                serviceDate: day, mealID: nil, mealName: nil, sections: [], message: message, status: nil,
                nextRefresh: now.addingTimeInterval(15 * 60))]
        }
        guard PSUDiningAccess.isEnabled else { return unavailable("Select Penn State in Halls to use this widget.") }
        guard let hall else { return unavailable("Edit this widget to select a dining hall.") }
        do {
            let result = try await PSUDiningServices.shared.menu(hall: hall, date: day, preference: configuration.meal.rawValue)
            guard PSUDiningAccess.isEnabled else { return unavailable("Select Penn State in Halls to use this widget.") }
            let dates = [now] + PSUServiceSelection.timelineTransitions(hours: result.hours, now: now)
            return dates.map { instant in
                let entryDay = PSUServiceSelection.calendar.serviceDate(containing: instant)
                guard entryDay == day else {
                    // This entry appears even if the system postpones our network refresh.
                    return DiningMenuEntry(date: instant, hallID: hall.rawValue, hallName: hall.rawValue.capitalized,
                        serviceDate: entryDay, mealID: nil, mealName: nil, sections: [],
                        message: "Today’s menu is updating. Open the hall to refresh.", status: nil,
                        nextRefresh: instant.addingTimeInterval(15 * 60))
                }
                let meal = PSUServiceSelection.meal(in: result.snapshot, preference: configuration.meal.rawValue, hours: result.hours, now: instant)
                let sections = (meal?.sections ?? []).filter { !$0.items.isEmpty }.map { section in
                    WidgetMealSection(id: section.id, name: section.displayName,
                        items: section.items.map { WidgetMealItem(id: section.id + ":" + $0.id, name: $0.displayName) })
                }
                let message: String?
                if sections.isEmpty {
                    message = if result.hours?.isExplicitlyClosed == true { "Closed. No menu is published." }
                    else if configuration.meal != .automatic { "No \(configuration.meal.rawValue.replacingOccurrences(of: "-", with: " ")) menu is published for today." }
                    else { "No menu is published for today." }
                } else { message = nil }
                // Future entries must not promote a menu that has gone stale by then.
                let isStale = PSUMenuFreshnessPolicy.isStale(result.snapshot, at: instant, dayHours: result.hours)
                let status = if isStale { "Saved menu" }
                    else { PSUServiceSelection.status(hours: result.hours, date: day, now: instant) }
                let relevanceEnd = if !isStale && !sections.isEmpty {
                    PSUServiceSelection.relevanceEnd(meal: meal, hours: result.hours, date: day, at: instant)
                } else {
                    nil as Date?
                }
                return DiningMenuEntry(date: instant, hallID: hall.rawValue, hallName: hall.rawValue.capitalized, serviceDate: day,
                    mealID: meal?.servicePeriod.id.rawValue, mealName: meal?.displayName,
                    sections: sections, message: message, status: status,
                    nextRefresh: isStale ? instant.addingTimeInterval(15 * 60) : PSUServiceSelection.nextRefresh(hours: result.hours, now: instant),
                    relevanceDuration: relevanceEnd?.timeIntervalSince(instant) ?? 0)
            }
        } catch PSUDiningActionError.menuNotPublished {
            return unavailable("No menu is published for today.")
        } catch {
            return unavailable("Couldn’t refresh the menu. Connect to the internet and try again.")
        }
    }
}

struct MealsWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    @ScaledMetric(relativeTo: .caption) private var rowHeight: CGFloat = 18
    let entry: DiningMenuEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.hallName).font(.subheadline.bold()).lineLimit(1)
                Spacer(minLength: 2)
                Text(entry.mealName ?? "Menu").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Divider()
            if let message = entry.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                GeometryReader { geometry in
                    let budget = max(1, Int(geometry.size.height / rowHeight))
                    if family == .systemSmall {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(entry.sections.flatMap(\.items).prefix(budget)) { item in itemRow(item) }
                        }
                    } else {
                        HStack(alignment: .top, spacing: 12) {
                            column(sections: entry.sections.enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element), budget: budget)
                            column(sections: entry.sections.enumerated().filter { !$0.offset.isMultiple(of: 2) }.map(\.element), budget: budget)
                        }
                    }
                }
            }
            if let status = entry.status { Text(status).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(.background, for: .widget)
        .widgetURL(entry.destinationURL)
    }
    private func column(sections: [WidgetMealSection], budget: Int) -> some View {
        let visible = Array(sections.prefix(max(1, budget / 3)))
        let rows = allocatedRows(sections: visible, budget: max(0, budget - visible.count))
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(visible) { section in
                Text(section.name).font(.caption2.bold()).foregroundStyle(.secondary).lineLimit(1)
                    .frame(height: rowHeight, alignment: .leading)
                ForEach(section.items.prefix(rows[section.id, default: 0])) { item in itemRow(item) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func allocatedRows(sections: [WidgetMealSection], budget: Int) -> [String: Int] {
        var limits: [String: Int] = [:]
        var remaining = budget
        while remaining > 0 {
            var added = false
            for section in sections where limits[section.id, default: 0] < section.items.count {
                limits[section.id, default: 0] += 1; remaining -= 1; added = true
                if remaining == 0 { break }
            }
            if !added { break }
        }
        return limits
    }
    private func itemRow(_ item: WidgetMealItem) -> some View {
        Text(item.name).font(.caption).lineLimit(1).frame(height: rowHeight, alignment: .leading)
    }
}

struct MealsWidget: Widget {
    let kind = "PSUDiningMenuWidget-v1"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: PSUDiningWidgetConfiguration.self, provider: DiningMenuProvider()) { entry in
            MealsWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("PSU Dining Menu")
        .description("Today’s Penn State dining menu for your chosen hall and meal.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

#Preview(as: .systemSmall) { MealsWidget() } timeline: { DiningMenuEntry.preview }
#Preview(as: .systemMedium) { MealsWidget() } timeline: { DiningMenuEntry.preview }
#Preview(as: .systemLarge) { MealsWidget() } timeline: { DiningMenuEntry.preview }
