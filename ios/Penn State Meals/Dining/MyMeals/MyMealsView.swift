import Observation
import Charts
import HealthKit
import SwiftUI
import UniformTypeIdentifiers

@Observable @MainActor
final class MealExportPresentation {
    var showsSavedPlans = false
    var confirmsHealthExport = false
    var exporting = false
    var exportingHealth = false
    @ObservationIgnored var csvDocument: MealCSVDocument?
}

struct MyMealsView: View {
    let feature: MealFeatureCoordinator
    let initialRecordID: UUID?
    private let journal: MealJournal
    private let purchaseManager: PurchaseManager
    @Bindable private var exportPresentation: MealExportPresentation
    @State private var repeatCandidate: MealRecord?
    @State private var legacyEditor: PlateDraft?
    @State private var editor: PlateDraft?
    @State private var choosesMenu = false
    @State private var selectedContext: PlateContext?
    @State private var showsPurchase = false
    @State private var startsAfterPurchase = false
    @State private var message: String?
    @State private var handledInitialRecord = false

    init(feature: MealFeatureCoordinator, initialRecordID: UUID? = nil, exportPresentation: MealExportPresentation) {
        self.feature = feature
        self.exportPresentation = exportPresentation
        self.initialRecordID = initialRecordID
        journal = feature.journal
        purchaseManager = feature.purchaseManager
    }

    var body: some View {
        Group {
            if let error = journal.storageError {
                ContentUnavailableView {
                    Label("Saved Meals Unavailable", systemImage: "externaldrive.badge.exclamationmark")
                } description: { Text(error) } actions: {
                    Button("Try Again") { journal.retryStorage() }
                }
            } else if !purchaseManager.hasUnlockedPro && !journal.hasSavedData {
                ProContent(purchaseManager: purchaseManager, mealIntroduction: true)
            } else {
                meals
            }
        }
        .navigationTitle("My Meals")
        .confirmationDialog("Replace your unfinished plate?", isPresented: Binding(
            get: { repeatCandidate != nil }, set: { if !$0 { repeatCandidate = nil } }
        ), titleVisibility: .visible) {
            Button("Replace Plate", role: .destructive) {
                if let record = repeatCandidate { repeatMeal(record) }
                repeatCandidate = nil
            }
        }
        .sheet(isPresented: $exportPresentation.showsSavedPlans) {
            NavigationStack {
                ScrollView { MealSavedPlans(records: journal.records(status: .planned), open: openLegacy).padding(20) }
                    .background(Color(uiColor: .systemGroupedBackground))
                    .navigationTitle("Previously Saved Plans")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            MealIconButton("Close", symbol: "xmark") { exportPresentation.showsSavedPlans = false }
                        }
                    }
                    .sheet(item: $legacyEditor) { draft in
                        NavigationStack { MealEditorView(feature: feature, draft: draft) }.mealSheetStyle()
                    }
            }.mealSheetStyle()
        }
        .sheet(item: $editor) { draft in
            NavigationStack { MealEditorView(feature: feature, draft: draft) }
                .mealSheetStyle()
        }
        .sheet(isPresented: $choosesMenu, onDismiss: {
            if let context = selectedContext {
                selectedContext = nil
                feature.openMenu(context)
            }
        }) {
            NavigationStack {
                MealMenuStartView(environment: feature.environment) { context in
                    selectedContext = context
                    choosesMenu = false
                }
            }
            .mealSheetStyle(compact: true)
        }
        .sheet(isPresented: $showsPurchase, onDismiss: {
            if purchaseManager.hasUnlockedPro && startsAfterPurchase { choosesMenu = true }
            startsAfterPurchase = false
        }) {
            MealProIntroduction(purchaseManager: purchaseManager) { showsPurchase = false }
        }
        .confirmationDialog("Export logged nutrition to Apple Health?", isPresented: $exportPresentation.confirmsHealthExport, titleVisibility: .visible) {
            Button("Export to Apple Health") {
                exportPresentation.exportingHealth = true
                Task {
                    do { message = try await MealHealthExport.export(journal.records(status: .eaten)) }
                    catch { message = error.localizedDescription }
                    exportPresentation.exportingHealth = false
                }
            }
        } message: {
            Text("Exports calories, protein, carbs, and fat where complete values are available. Apps that read these values from Health can access them with your permission. Re-exporting updates this app’s entries. Deleting a meal here does not delete an earlier Health export.")
        }
        .fileExporter(isPresented: $exportPresentation.exporting, document: exportPresentation.csvDocument,
                      contentType: .commaSeparatedText, defaultFilename: "Meet-and-Eat-Meals") { result in
            exportPresentation.csvDocument = nil
            if case .failure(let error) = result { message = error.localizedDescription }
        }
        .alert("My Meals", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: { Text(message ?? "") }
        .task {
            await purchaseManager.updatePurchasedProducts()
            if !handledInitialRecord, let initialRecordID, journal.storageError == nil {
                handledInitialRecord = true
                if let record = journal.record(id: initialRecordID) { open(record) }
                else { message = "This meal is no longer saved." }
            }
            await journal.reconcileReminders()
        }
    }

    private var newPlateButton: some View {
        Button {
            if purchaseManager.hasUnlockedPro { choosesMenu = true }
            else { startsAfterPurchase = true; showsPurchase = true }
        } label: {
            Label("New Plate", systemImage: "plus")
                .font(.title3.bold())
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.roundedRectangle(radius: 16))
    }

    private var meals: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                newPlateButton
                if !purchaseManager.hasUnlockedPro {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Saved meals stay yours.").font(.headline)
                        Text("Read, export, or delete anytime. Restore Pro to build and edit.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Button("Restore Pro") { showsPurchase = true }
                    }.mealCard()
                }
                if let draft = feature.draft, purchaseManager.hasUnlockedPro {
                    Button { editor = draft } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "fork.knife").foregroundStyle(.tint)
                                .frame(width: 40, height: 40)
                                .background(.tint.opacity(0.1), in: .circle)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Continue Plate").font(.headline)
                                Text("\(draft.context.title) · \(draft.items.count) items")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }.mealCard(tint: .accentColor)
                    }.buttonStyle(.plain)
                }
                if let error = journal.reminderError {
                    HStack(spacing: 12) {
                        Image(systemName: "bell.badge").foregroundStyle(.secondary)
                        Text(error).font(.footnote).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        MealIconButton("Retry Reminders", symbol: "arrow.clockwise") {
                            Task { await journal.reconcileReminders(requestPermission: true) }
                        }
                    }.mealCard()
                }
                if journal.records(status: .eaten).isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        MealEmptyState(title: "Your meals, remembered", subtitle: "Build a plate and log what you ate.", symbol: "clock.arrow.circlepath")
                        if purchaseManager.hasUnlockedPro {
                            Button("Choose a Menu", systemImage: "plus") { choosesMenu = true }
                                .buttonStyle(.borderedProminent)
                        }
                    }.mealCard()
                } else {
                    MealHistoryContent(records: journal.records(status: .eaten), open: open,
                        repeatMeal: purchaseManager.hasUnlockedPro ? { record in
                            if let draft = feature.draft, !draft.items.isEmpty { repeatCandidate = record }
                            else { repeatMeal(record) }
                        } : nil)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(MealCanvas())
    }

    private func repeatMeal(_ record: MealRecord) {
        guard let draft = feature.repeatMeal(record) else { return }
        editor = draft
    }

    private func openLegacy(_ record: MealRecord) {
        guard let hall = record.hall, let date = record.menuDate else { return }
        legacyEditor = PlateDraft(context: PlateContext(hall: hall, date: date, mealName: record.servicePeriodName), record: record)
    }

    private func open(_ record: MealRecord) {
        guard let hall = record.hall, let date = record.menuDate else {
            message = "This meal’s menu location or date could not be read. You can still export your meals."
            return
        }
        editor = PlateDraft(context: PlateContext(hall: hall, date: date, mealName: record.servicePeriodName), record: record)
    }
}

extension PlateDraft: nonisolated Identifiable {
    nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }
}

private struct MealRecordRow: View {
    let record: MealRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                MealEmblem(symbol: MealPalette.symbol(for: record.servicePeriodName), color: MealPalette.color(for: record.servicePeriodName))
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.servicePeriodName).font(.title3.weight(.semibold))
                    Text(record.hallRawValue.capitalized).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if let date = record.status == .eaten ? record.eatenAt : record.scheduledAt {
                    Text(date, format: Date.FormatStyle(date: .omitted, time: .shortened, timeZone: ProviderCalendarContexts.pennState.timeZone))
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            Text(record.items.map(\.displayName).joined(separator: ", "))
                .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            HStack(spacing: 16) {
                Label(record.nutritionTotals.text(.calories), systemImage: "flame")
                Text(record.nutritionTotals.text(.protein) + " protein")
            }.font(.caption).foregroundStyle(.secondary)
        }
        .mealCard(tint: MealPalette.color(for: record.servicePeriodName))
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

/// Capture revisions as values: SwiftData records themselves keep reference identity
/// when their fields change, so comparing arrays of those references misses edits.
private struct MealRecordRevision: Equatable {
    let id: UUID
    let updatedAt: Date
    init(_ record: MealRecord) {
        id = record.id
        updatedAt = record.updatedAt
    }
}

private struct MealSavedPlans: View {
    let records: [MealRecord]
    let open: (MealRecord) -> Void
    @State private var groups: [PlanDay] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 10) {
                    Text(mealDayLabel(group.id))
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(group.records) { record in
                        Button { open(record) } label: { MealRecordRow(record: record) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
        .onChange(of: records.map(MealRecordRevision.init), initial: true) {
            let grouped = Dictionary(grouping: records, by: \.menuDateValue)
            groups = grouped.keys.sorted().map { day in
                PlanDay(id: day, records: grouped[day, default: []].sorted {
                    ($0.scheduledAt ?? .distantPast) < ($1.scheduledAt ?? .distantPast)
                })
            }
        }
    }

    private struct PlanDay: Identifiable {
        let id: String
        let records: [MealRecord]
    }
}

private struct MealHistoryContent: View {
    let records: [MealRecord]
    let open: (MealRecord) -> Void
    let repeatMeal: ((MealRecord) -> Void)?
    private let calendar = ProviderCalendarContexts.pennState

    @State private var groups: [HistoryDay] = []
    @State private var dailyTotals: [DateOnly: NutritionDayTotals] = [:]

    private func rebuildHistory() {
        let grouped = Dictionary(grouping: records) { calendar.serviceDate(containing: $0.eatenAt ?? $0.updatedAt) }
        groups = grouped.keys.sorted { $0.description > $1.description }.map { day in
            let meals = grouped[day, default: []].sorted { ($0.eatenAt ?? $0.updatedAt) > ($1.eatenAt ?? $1.updatedAt) }
            return HistoryDay(day: day, records: meals,
                              totals: meals.reduce(into: NutritionTotals()) { $0.merge($1.nutritionTotals) })
        }
        dailyTotals = Dictionary(uniqueKeysWithValues: groups.map {
            ($0.day, NutritionDayTotals(totals: $0.totals, count: $0.records.count))
        })
    }

    private struct HistoryDay: Identifiable {
        var id: DateOnly { day }
        let day: DateOnly
        let records: [MealRecord]
        let totals: NutritionTotals
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 24) {
            if records.isEmpty {
                MealEmptyState(title: "A little history starts here", subtitle: "Log a meal to see your daily nutrition.", symbol: "clock")
                    .padding(.vertical, 20)
            } else {
                NutritionHistoryChart(dailyTotals: dailyTotals)
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(mealDayLabel(group.day.description)).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        PlateNutritionSummary(totals: group.totals)
                        ForEach(group.records) { record in
                            VStack(alignment: .leading, spacing: 8) {
                                Button { open(record) } label: { MealRecordRow(record: record) }.buttonStyle(.plain)
                                if let repeatMeal {
                                    Button("Have Again", systemImage: "arrow.counterclockwise") { repeatMeal(record) }
                                        .font(.subheadline).frame(minHeight: 44).padding(.horizontal, 12)
                                }
                            }
                        }
                    }
                }
            }
        }
        .onChange(of: records.map(MealRecordRevision.init), initial: true) { rebuildHistory() }
    }
}

private struct NutritionDayTotals: Equatable {
    let totals: NutritionTotals
    let count: Int
}

private struct NutritionHistoryChart: View {
    // Aggregated by the parent when saved records change, outside selection updates.
    let dailyTotals: [DateOnly: NutritionDayTotals]
    @State private var days = 7
    @State private var offset = 0
    @State private var metric = PlateNutrient.calories
    @State private var selection: Date?
    @State private var points: [NutritionDay] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    private let calendar = ProviderCalendarContexts.pennState

    private var end: DateOnly {
        let today = calendar.serviceDate(containing: .now)
        return today.addingDays(-offset * days) ?? today
    }
    private var start: DateOnly { end.addingDays(1 - days) ?? end }
    private func rebuildPoints() {
        points = (0..<days).compactMap { index in
            guard let day = start.addingDays(index), let date = day.date(in: calendar.timeZone, hour: 0) else { return nil }
            let summary = dailyTotals[day]
            return NutritionDay(date: date, totals: summary?.totals ?? NutritionTotals(), count: summary?.count ?? 0)
        }
        rebuildMetric()
    }
    private var selected: NutritionDay? {
        guard let selection else { return nil }
        return points.first { calendar.calendar.isDate($0.date, inSameDayAs: selection) }
    }
    @State private var known: [Double] = []
    private func rebuildMetric() {
        known = points.compactMap { $0.count > 0 ? $0.totals.amount(metric) : nil }
    }
    private var average: Double { known.isEmpty ? 0 : known.reduce(0, +) / Double(known.count) }
    private var unit: String { metric == .calories ? "kcal" : "g" }

    private var axisDates: [Date] {
        let step = if days == 7 { typeSize.isAccessibilitySize ? 2 : 1 }
            else { days == 30 ? 7 : 21 }
        // Place each tick at the center of its daily bar, including the last day.
        return stride(from: 0, to: points.count, by: step).compactMap {
            calendar.calendar.date(byAdding: .hour, value: 12, to: points[$0].date)
        }
    }
    private var axisFormat: Date.FormatStyle {
        var format = if days == 7 { Date.FormatStyle().weekday(.abbreviated) }
            else { Date.FormatStyle().month(.abbreviated).day() }
        format.calendar = calendar.calendar
        format.timeZone = calendar.timeZone
        return format
    }
    private var periodLabel: String {
        guard let first = start.date(in: calendar.timeZone), let last = end.date(in: calendar.timeZone) else { return "" }
        return Date.IntervalFormatStyle(date: .abbreviated, time: .omitted,
                                        calendar: calendar.calendar, timeZone: calendar.timeZone)
            .format(first..<last)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Nutrition", systemImage: "chart.bar.xaxis").font(.headline)
                Spacer()
                Menu {
                    Picker("Nutrient", selection: $metric) {
                        ForEach(PlateNutrient.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                } label: { Label(metric.title, systemImage: "chevron.down").font(.subheadline.weight(.semibold)) }
            }
            Picker("Time range", selection: $days) {
                Text("Week").tag(7)
                Text("Month").tag(30)
                Text("3 Months").tag(90)
            }.pickerStyle(.segmented)
            HStack {
                MealIconButton("Previous period", symbol: "chevron.left") { offset += 1; selection = nil }
                Spacer(minLength: 0)
                Text(periodLabel).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                MealIconButton("Next period", symbol: "chevron.right") { offset = max(0, offset - 1); selection = nil }
                    .disabled(offset == 0)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(selected.map { $0.date.formatted(.dateTime.month(.abbreviated).day()) } ?? "Daily average")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text(selected.map { $0.count == 0 ? "No meals logged" : $0.totals.text(metric) }
                     ?? (known.isEmpty ? "No data" : "\(average.formatted(.number.precision(.fractionLength(0...1)))) \(unit)"))
                    .font(.title.weight(.semibold)).monospacedDigit().contentTransition(.numericText())
                Text(selected.map { "\($0.count) meals" } ?? "\(known.count) of \(days) days with published values")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Chart {
                ForEach(points) { point in
                    if point.count > 0, let amount = point.totals.amount(metric) {
                        BarMark(x: .value("Day", point.date, unit: .day), y: .value(metric.title, amount))
                            .foregroundStyle(MealPalette.color(for: metric).gradient)
                            .opacity(point.totals.isPartial(metric) ? 0.45 : 1)
                            .cornerRadius(days == 7 ? 5 : 2)
                            .accessibilityLabel(point.date.formatted(date: .abbreviated, time: .omitted))
                            .accessibilityValue(point.totals.text(metric))
                    }
                }
                if let selected {
                    RuleMark(x: .value("Selected day", selected.date, unit: .day))
                        .foregroundStyle(.secondary).lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                }
            }
            .chartXScale(domain: (start.date(in: calendar.timeZone, hour: 0) ?? .now)...(end.addingDays(1)?.date(in: calendar.timeZone, hour: 0) ?? .now))
            .chartYScale(domain: 0...max(1, (known.max() ?? 1) * 1.15))
            .chartXSelection(value: $selection)
            .chartXAxis {
                AxisMarks(values: axisDates) { value in
                    AxisValueLabel(anchor: .top, collisionResolution: .greedy) {
                        if let date = value.as(Date.self) {
                            Text(date.formatted(axisFormat)).lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                }
            }
            .chartYAxis { AxisMarks(position: .trailing) }
            .frame(height: 200)
            .overlay { if known.isEmpty { ContentUnavailableView("No logged nutrition", systemImage: "chart.bar", description: Text("Log a meal or choose another period.")) } }
            Text("Touch the chart to inspect a day. Gaps are unlogged days; lighter bars contain partial nutrition. Averages use days with published values.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .plateSurface()
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: metric)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: days)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: offset)
        .onChange(of: days) { _, _ in offset = 0; selection = nil }
        .onChange(of: ChartPeriod(start: start, days: days), initial: true) { _, _ in rebuildPoints() }
        .onChange(of: dailyTotals) { _, _ in rebuildPoints() }
        .onChange(of: metric) { rebuildMetric() }
        .environment(\.timeZone, calendar.timeZone)
        .environment(\.calendar, calendar.calendar)
    }

    private struct ChartPeriod: Equatable {
        let start: DateOnly
        let days: Int
    }

    private struct NutritionDay: Identifiable {
        var id: Date { date }
        let date: Date
        let totals: NutritionTotals
        let count: Int
    }
}

struct MealEditorView: View {
    let feature: MealFeatureCoordinator
    @Bindable var draft: PlateDraft
    private let purchaseManager: PurchaseManager
    private let journal: MealJournal
    @Environment(\.dismiss) private var dismiss
    @State private var consumedAt: Date
    @State private var saving = false
    @State private var saved = false
    @State private var error: String?
    @State private var confirmsDelete = false
    @State private var confirmsDiscard = false
    @State private var choosesItems = false
    @State private var detail: DiningMenuItem?
    @State private var retryGeneration = 0

    init(feature: MealFeatureCoordinator, draft: PlateDraft) {
        self.feature = feature
        self.draft = draft
        purchaseManager = feature.purchaseManager
        journal = feature.journal
        let record = draft.recordID.flatMap(feature.journal.record(id:))
        _consumedAt = State(initialValue: record?.eatenAt ?? .now)
    }

    private var canEdit: Bool { purchaseManager.hasUnlockedPro && !saved }
    private var record: MealRecord? { draft.recordID.flatMap(journal.record(id:)) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !purchaseManager.hasUnlockedPro {
                    Text("Restore Pro to edit. Your saved meal is still available to read or delete.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Label("\(draft.context.title) · \(draft.context.dateLabel)",
                      systemImage: "fork.knife")
                    .font(.subheadline).foregroundStyle(.secondary)
                PlateNutritionSummary(totals: draft.totals)
                if !draft.totals.isComplete {
                    Label("Partial totals include published values only.", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(spacing: 0) {
                    HStack {
                        Label("On your plate", systemImage: "fork.knife").font(.headline)
                        Spacer()
                        if canEdit { MealIconButton("Add Foods", symbol: "plus") { choosesItems = true } }
                    }
                    if draft.items.isEmpty {
                        Text("Add foods from the menu to get started.")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 20)
                    }
                    ForEach($draft.items) { $item in
                        Divider()
                        PlateFoodRow(item: $item, canEdit: canEdit,
                            open: { detail = item.source ?? storedDetail(item) },
                            remove: { draft.remove(item.id); feature.changed() },
                            retry: { draft.retryNutrition(); retryGeneration += 1 })
                    }
                }.plateSurface()
                let allergens = draft.allergenStatements
                if !allergens.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Allergens", systemImage: "exclamationmark.shield")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
                        ForEach(allergens, id: \.self) { Text($0).font(.footnote).foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4)
                }
                if canEdit {
                    DatePicker(selection: $consumedAt, in: ...Date.now) {
                        Label("Eaten", systemImage: "calendar")
                    }.font(.subheadline).plateSurface()
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(record == nil ? "Your Plate" : "Meal Details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                MealIconButton("Close", symbol: "xmark") { dismiss() }.disabled(saving)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if let record {
                        if record.reminderIdentifier != nil {
                            Button("Cancel Reminder", systemImage: "bell.slash") {
                                do { try journal.cancelReminder(record) }
                                catch { self.error = error.localizedDescription }
                            }
                        }
                        Button("Delete Meal", systemImage: "trash", role: .destructive) { confirmsDelete = true }
                    } else {
                        Button("Discard Plate", systemImage: "trash", role: .destructive) { confirmsDiscard = true }
                    }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(.circle)
                }.accessibilityLabel("Plate actions")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if canEdit {
                Button(action: save) {
                    HStack(spacing: 10) {
                        if saving { ProgressView().tint(.white) }
                        Text(record?.status == .eaten ? "Save Changes" : "Log Meal").font(.headline)
                    }
                    .frame(maxWidth: .infinity).frame(minHeight: 34)
                }
                .buttonStyle(.borderedProminent).buttonBorderShape(.roundedRectangle(radius: 14))
                .disabled(draft.items.isEmpty || draft.isLoading || saving)
                .padding(.horizontal, 20).padding(.vertical, 12)
                .background(.bar)
            }
        }
        .environment(\.timeZone, ProviderCalendarContexts.pennState.timeZone)
        .disabled(saving)
        .interactiveDismissDisabled(saving)
        .confirmationDialog("Delete this meal?", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                guard let record else { return }
                do { try journal.delete(record); dismiss() } catch { self.error = error.localizedDescription }
            }
        }
        .confirmationDialog("Discard this plate?", isPresented: $confirmsDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { feature.discardDraft(); dismiss() }
        }
        .alert(saved ? "Meal Saved" : "Couldn’t Save Meal", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            if saved {
                Button("Retry Reminder") {
                    Task {
                        await journal.reconcileReminders(requestPermission: true)
                        if let message = journal.reminderError { error = message } else { dismiss() }
                    }
                }
                Button("Done") { dismiss() }
            } else { Button("OK") { error = nil } }
        } message: { Text(error ?? "") }
        .sheet(isPresented: $choosesItems) {
            PlateMenuPicker(feature: feature, draft: draft, onDone: { choosesItems = false })
                .ignoresSafeArea()
        }
        .sheet(item: $detail) { item in
            MealItemDetailSheet(item: item, context: draft.context, environment: feature.environment)
        }
        .task(id: NutritionLoadID(tokens: draft.items.map(\.token), retry: retryGeneration)) {
            // The active plate has one coordinator-owned loader; record edits own their loader here.
            if feature.draft === draft { feature.loadNutrition() }
            else { await draft.loadNutrition(environment: feature.environment) }
        }
    }

    private struct NutritionLoadID: Equatable {
        let tokens: [UUID]
        let retry: Int
    }

    private func storedDetail(_ item: PlateDraftItem) -> DiningMenuItem {
        DiningMenuItem(id: item.id, displayName: item.name, detailURL: nil, sourceOrder: 0, sourceLabels: [],
            detailMetadata: DiningMenuItemDetailMetadata(
                sourceURL: URL(string: "https://menu.hfs.psu.edu").unsafelyUnwrapped, fetchedAt: .now,
                ingredients: nil, allergenStatement: item.allergenStatement, nutrition: item.facts
            ))
    }

    private func save() {
        guard canEdit, !saving, !draft.isLoading else { return }
        saving = true
        do {
            try journal.commit(draft: draft, status: .eaten, consumedAt: consumedAt, scheduledAt: nil, reminderEnabled: false)
            saved = true
            feature.didSave(draft)
            saving = false
            dismiss()
        } catch {
            saving = false
            self.error = error.localizedDescription
        }
    }
}

private struct PlateNutritionSummary: View {
    let totals: NutritionTotals
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Calories", systemImage: "flame.fill")
                    .font(.subheadline).foregroundStyle(.orange)
                Spacer()
                Text(totals.text(.calories)).font(.title2.weight(.semibold)).monospacedDigit()
            }
            Divider()
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
            layout {
                ForEach([PlateNutrient.protein, .carbohydrates, .fat], id: \.self) { nutrient in
                    VStack(alignment: .leading, spacing: 5) {
                        Label(nutrient.title, systemImage: symbol(for: nutrient))
                            .font(.caption).foregroundStyle(MealPalette.color(for: nutrient))
                        Text(totals.text(nutrient)).font(.subheadline.weight(.semibold)).monospacedDigit()
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }.plateSurface()
    }

    private func symbol(for nutrient: PlateNutrient) -> String {
        switch nutrient {
        case .calories: "flame.fill"
        case .protein: "dumbbell.fill"
        case .carbohydrates: "leaf.fill"
        case .fat: "drop.fill"
        }
    }
}

private struct PlateFoodRow: View {
    @Binding var item: PlateDraftItem
    let canEdit: Bool
    let open: () -> Void
    let remove: () -> Void
    let retry: () -> Void

    private var servingLabel: String {
        let count = item.servings.formatted(.number.precision(.fractionLength(0...1)))
        return item.servings == 1 ? "\(count) serving" : "\(count) servings"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: open) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        if let serving = item.servingSize {
                            Label(serving, systemImage: "scalemass")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if item.nutritionState == .loading || item.nutritionState == .pending {
                            ProgressView().controlSize(.mini).accessibilityLabel("Loading nutrition")
                        } else {
                            Label(item.totals.text(.calories), systemImage: "flame")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary).padding(.top, 3)
                }.contentShape(.rect)
            }.buttonStyle(.plain).accessibilityHint("Shows item details")
            if canEdit {
                HStack(spacing: 12) {
                    Stepper(value: $item.servings, in: 0.5...10, step: 0.5) {
                        Text(servingLabel)
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }.accessibilityLabel("Servings of \(item.name)")
                    if item.nutritionState == .failed {
                        MealIconButton("Retry Nutrition", symbol: "arrow.clockwise", action: retry)
                    }
                    MealIconButton("Remove \(item.name)", symbol: "trash", action: remove)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(servingLabel).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 12)
    }
}

struct MealIconButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    init(_ title: String, symbol: String, action: @escaping () -> Void) {
        self.title = title; self.symbol = symbol; self.action = action
    }
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.body.weight(.semibold))
                .frame(minWidth: 44, minHeight: 44).contentShape(.rect)
        }.buttonStyle(.plain).accessibilityLabel(title)
    }
}

private struct DiningHallPicker: UIViewRepresentable {
    @Binding var selection: PSUDiningHall?

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeUIView(context: Context) -> UISegmentedControl {
        let picker = UISegmentedControl(items: PSUDiningHall.allCases.map { $0.rawValue.capitalized })
        picker.selectedSegmentIndex = UISegmentedControl.noSegment
        picker.accessibilityLabel = "Dining hall"
        picker.addTarget(context.coordinator, action: #selector(Coordinator.selectHall(_:)), for: .valueChanged)
        return picker
    }

    func updateUIView(_ picker: UISegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        picker.selectedSegmentIndex = selection.flatMap { PSUDiningHall.allCases.firstIndex(of: $0) }
            ?? UISegmentedControl.noSegment
    }

    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<PSUDiningHall?>
        init(selection: Binding<PSUDiningHall?>) { self.selection = selection }
        @objc func selectHall(_ sender: UISegmentedControl) {
            guard PSUDiningHall.allCases.indices.contains(sender.selectedSegmentIndex) else { return }
            selection.wrappedValue = PSUDiningHall.allCases[sender.selectedSegmentIndex]
        }
    }
}

private struct MealEmptyState: View {
    let title: String
    let subtitle: String
    let symbol: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MealEmblem(symbol: symbol, color: .accentColor)
            Text(title).font(.title3.weight(.semibold))
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private enum MealPalette {
    static func color(for nutrient: PlateNutrient) -> Color {
        switch nutrient {
        case .calories: .orange
        case .protein: .teal
        case .carbohydrates: .indigo
        case .fat: .pink
        }
    }
    static func color(for meal: String) -> Color {
        switch DiningServicePeriodNormalizer.normalize(meal).id {
        case .breakfast, .brunch: .orange
        case .lunch: .teal
        case .dinner, .lateNight: .indigo
        default: .accentColor
        }
    }
    static func symbol(for meal: String) -> String {
        switch DiningServicePeriodNormalizer.normalize(meal).id {
        case .breakfast, .brunch: "sunrise.fill"
        case .lunch: "sun.max.fill"
        case .dinner, .lateNight: "moon.stars.fill"
        default: "fork.knife"
        }
    }
}

private struct MealEmblem: View {
    let symbol: String
    let color: Color
    var body: some View {
        Image(systemName: symbol).font(.title3.weight(.semibold)).foregroundStyle(color)
            .frame(width: 44, height: 44)
            .background(color.opacity(0.14), in: .rect(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(color.opacity(0.12), lineWidth: 1))
            .accessibilityHidden(true)
    }
}

private struct MealCanvas: View {
    var body: some View {
        Color(uiColor: .systemGroupedBackground)
            .overlay(alignment: .top) {
                LinearGradient(colors: [Color.accentColor.opacity(0.075), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .frame(height: 300)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

extension View {
    fileprivate func plateSurface() -> some View {
        self.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
    }

    fileprivate func mealCard(tint: Color = .clear) -> some View {
        self.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
                    .overlay {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(LinearGradient(colors: [tint.opacity(0.12), tint.opacity(0.025)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(tint.opacity(0.12), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.035), radius: 8, x: 0, y: 3)
                    .allowsHitTesting(false)
            }
    }
    func mealSheetStyle(compact: Bool = false) -> some View {
        self.presentationDetents(compact ? [.height(520), .large] : [.large])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(28)
    }
}

private func mealDayLabel(_ rawValue: String) -> String {
    let calendar = ProviderCalendarContexts.pennState
    guard let day = DateOnly(deepLinkValue: rawValue), let date = day.date(in: calendar.timeZone) else { return rawValue }
    let today = calendar.serviceDate(containing: .now)
    if day == today { return "Today" }
    if day == today.addingDays(1) { return "Tomorrow" }
    return date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: calendar.timeZone))
}

private struct MealMenuStartView: View {
    let environment: DiningMenuEnvironment
    let select: (PlateContext) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var hall: PSUDiningHall?
    @State private var date = Date.now
    @State private var periods: [MenuMealPeriod] = []
    @State private var loading = false
    @State private var error: String?
    @State private var retry = 0
    private let calendar = ProviderCalendarContexts.pennState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Dining hall").font(.subheadline.weight(.semibold))
                    if typeSize.isAccessibilitySize {
                        Picker("Dining hall", selection: $hall) {
                            Text("Choose a hall").tag(Optional<PSUDiningHall>.none)
                            ForEach(PSUDiningHall.allCases) { Text($0.rawValue.capitalized).tag(Optional($0)) }
                        }.pickerStyle(.menu)
                    } else {
                        DiningHallPicker(selection: $hall).frame(height: 44)
                    }
                }
                let today = calendar.serviceDate(containing: .now)
                let start = today.date(in: calendar.timeZone) ?? .now
                let end = today.addingDays(calendar.dateHorizon.futureDayCount)?.date(in: calendar.timeZone) ?? start
                DatePicker(selection: $date, in: start...end, displayedComponents: .date) {
                    Label("Date", systemImage: "calendar").font(.subheadline.weight(.medium))
                }.mealCard()
                VStack(alignment: .leading, spacing: 12) {
                    Text("Available meals").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    if loading {
                        ProgressView("Loading menu…").font(.subheadline)
                            .frame(maxWidth: .infinity, minHeight: 100)
                    } else if let error {
                        HStack {
                            Text(error).font(.subheadline).foregroundStyle(.secondary)
                            Spacer()
                            MealIconButton("Try Again", symbol: "arrow.clockwise") { retry += 1 }
                        }.mealCard()
                    } else if let hall {
                        if periods.isEmpty { Text("No meals are published for this date.").font(.subheadline).foregroundStyle(.secondary) }
                        VStack(spacing: 10) {
                            ForEach(periods) { period in
                                Button {
                                    select(PlateContext(hall: hall, date: DateOnly(date, in: calendar.timeZone), mealName: period.displayName))
                                } label: {
                                    HStack(spacing: 12) {
                                        MealEmblem(symbol: MealPalette.symbol(for: period.displayName), color: MealPalette.color(for: period.displayName))
                                        Text(period.displayName).font(.body.weight(.medium))
                                        Spacer()
                                        Image(systemName: "arrow.up.right").font(.subheadline.weight(.semibold)).foregroundStyle(.tint)
                                    }.frame(minHeight: 44).mealCard().contentShape(.rect)
                                }.buttonStyle(.plain)
                            }
                        }
                    } else {
                        Text("Select a hall to see its menu.").font(.subheadline).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
                    }
                }
            }.padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 24)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Choose a Menu")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                MealIconButton("Close", symbol: "xmark") { dismiss() }
            }
        }
        .environment(\.timeZone, calendar.timeZone)
        .task(id: "\(hall?.rawValue ?? "")-\(DateOnly(date, in: calendar.timeZone))-\(retry)") {
            periods = []
            error = nil
            guard let hall else { loading = false; return }
            loading = true
            do {
                let menu = try await environment.menu(for: hall, on: DateOnly(date, in: calendar.timeZone), policy: .revalidateIfStale)
                guard !Task.isCancelled else { return }
                periods = menu.meals.filter { $0.sections.contains { !$0.items.isEmpty } }
            } catch {
                guard !Task.isCancelled else { return }
                self.error = "This menu couldn’t be loaded. Check your connection and try again."
            }
            loading = false
        }
    }
}

struct MealCSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    let data: Data

    init(records: [MealRecord]) {
        var rows = ["id,status,menu_date,consumed_at,scheduled_at,hall,meal,item,servings,calories,protein_g,carbohydrates_g,fat_g,nutrition_complete"]
        for record in records {
            for item in record.items {
                var totals = NutritionTotals()
                totals.add(item.normalizedNutrients, servings: item.servingMultiplier)
                let values = [record.id.uuidString, record.status.rawValue, record.menuDateValue,
                    record.eatenAt?.ISO8601Format() ?? "", record.scheduledAt?.ISO8601Format() ?? "",
                    record.hallRawValue, record.servicePeriodName, item.displayName, String(item.servingMultiplier)]
                    + PlateNutrient.allCases.map { nutrient in totals.amount(nutrient).map(String.init(describing:)) ?? "" }
                    + [String(totals.isComplete)]
                rows.append(values.map(Self.escape).joined(separator: ","))
            }
        }
        data = Data(rows.joined(separator: "\n").utf8)
    }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
    private static func escape(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

@MainActor
private enum MealHealthExport {
    static func export(_ records: [MealRecord]) async throws -> String {
        let store = HKHealthStore()
        let mapping: [(PlateNutrient, HKQuantityTypeIdentifier)] = [
            (.calories, .dietaryEnergyConsumed), (.protein, .dietaryProtein),
            (.carbohydrates, .dietaryCarbohydrates), (.fat, .dietaryFatTotal)
        ]
        let types = Set(mapping.map { HKQuantityType($0.1) })
        try await store.requestAuthorization(toShare: types, read: [])
        var samples: [HKQuantitySample] = []
        var skipped = 0
        var removed = 0
        for record in records {
            let totals = record.nutritionTotals
            let date = record.eatenAt ?? record.updatedAt
            for (nutrient, identifier) in mapping {
                let type = HKQuantityType(identifier)
                guard store.authorizationStatus(for: type) == .sharingAuthorized else {
                    skipped += 1
                    continue
                }
                let syncIdentifier = "com.ryannair05.pennstatemeals.\(record.id.uuidString).\(nutrient.rawValue)"
                guard !totals.isPartial(nutrient), let amount = totals.amount(nutrient) else {
                    // Reconcile old exports even when there are no new values to save.
                    // HealthKit limits deletion to samples saved by this app.
                    let predicate = HKQuery.predicateForObjects(
                        withMetadataKey: HKMetadataKeySyncIdentifier,
                        allowedValues: [syncIdentifier]
                    )
                    removed += try await store.deleteObjects(of: type, predicate: predicate)
                    skipped += 1
                    continue
                }
                let quantity = HKQuantity(unit: nutrient == .calories ? .kilocalorie() : .gram(), doubleValue: amount)
                let metadata: [String: Any] = [
                    HKMetadataKeySyncIdentifier: syncIdentifier,
                    HKMetadataKeySyncVersion: NSNumber(value: Int64(record.updatedAt.timeIntervalSince1970 * 1000)),
                    HKMetadataKeyFoodType: record.items.map(\.displayName).joined(separator: ", ")
                ]
                samples.append(HKQuantitySample(type: type, quantity: quantity, start: date, end: date, metadata: metadata))
            }
        }
        guard !samples.isEmpty || removed > 0 else {
            return "Nothing exported. Allow nutrition writes in Health settings and choose meals with complete published values."
        }
        if !samples.isEmpty {
            try await store.save(samples)
        }
        return "Exported \(samples.count) nutrition values to Apple Health. Removed \(removed) outdated values. \(skipped) unavailable, partial, or unapproved values were skipped."
    }
}
