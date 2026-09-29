//
//  ScheduleView.swift
//  Penn State Meals
//
//  Created by Ryan Nair on 6/5/25.
//

import SwiftUI
import SwiftSoup
import FirebaseAnalytics

// MARK: – Models

private struct ActivitySchedule: Identifiable, Sendable {
    let id = UUID()
    let activity: String
    let tables: [ScheduleTable]
}

private struct ScheduleTable: Identifiable, Sendable {
    let id = UUID()
    let headers: [String]
    let rows: [ScheduleRow]
}

private struct ScheduleRow: Identifiable, Sendable {
    let id = UUID()
    let cells: [String]
}

private struct ParsedSchedules: Sendable {
    let schedules: [ActivitySchedule]
    let calendarDays: [CalendarDay]
    let scheduleError: String?
    let calendarError: String?
    let activeRegions: Set<IMFacilityRegion>
    let regionSchedules: [IMFacilityRegion: [RegionSchedule]]

    init(schedules: [ActivitySchedule], calendarDays: [CalendarDay], scheduleError: String?, calendarError: String?) {
        self.schedules = schedules
        self.calendarDays = calendarDays
        self.scheduleError = scheduleError
        self.calendarError = calendarError
        var grouped: [IMFacilityRegion: [RegionSchedule]] = [:]
        for schedule in schedules {
            var rowsByRegion: [IMFacilityRegion: [RegionScheduleRow]] = [:]
            for (tableIndex, table) in schedule.tables.enumerated() {
                for row in table.rows {
                    guard let location = row.cells.first else { continue }
                    let slots = zip(table.headers.dropFirst(), row.cells.dropFirst()).compactMap { day, time -> RegionTimeSlot? in
                        let cleaned = time.trimmingCharacters(in: .whitespacesAndNewlines)
                            .replacingOccurrences(of: "\u{00A0}", with: "")
                        return cleaned.isEmpty ? nil : RegionTimeSlot(day: day, time: cleaned)
                    }
                    let displayRow = RegionScheduleRow(id: "\(tableIndex):\(location)", location: location, slots: slots)
                    for region in IMFacilityRegion.regions(for: location) {
                        rowsByRegion[region, default: []].append(displayRow)
                    }
                }
            }
            for (region, rows) in rowsByRegion {
                grouped[region, default: []].append(RegionSchedule(activity: schedule.activity, rows: rows))
            }
        }
        regionSchedules = grouped
        activeRegions = Set(grouped.keys)
    }
}

private struct RegionSchedule: Identifiable, Sendable {
    var id: String { activity }
    let activity: String
    let rows: [RegionScheduleRow]
}

private struct RegionScheduleRow: Identifiable, Sendable {
    let id: String
    let location: String
    let slots: [RegionTimeSlot]
}

private struct RegionTimeSlot: Identifiable, Sendable {
    var id: String { day }
    let day: String
    let time: String
}

private struct CalendarEventModel: Identifiable, Sendable, Equatable {
    let id = UUID()
    let time: String
    let subject: String
    let link: URL
}

private struct CalendarDay: Identifiable, Sendable, Equatable {
    var id: String { dateLabel }
    let dateLabel: String
    let events: [CalendarEventModel]
    
    static func == (lhs: CalendarDay, rhs: CalendarDay) -> Bool {
        lhs.dateLabel == rhs.dateLabel && lhs.events == rhs.events
    }
}

// MARK: – Parsing Logic (Background & Cached)

private enum CampusRecRequestError: Error, Sendable, LocalizedError {
    case invalidResponse
    case httpStatus(Int)
    case emptyResponse
    case unexpectedContentType(String?)
    case unexpectedResponse
    case network(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Penn State returned an invalid response."
        case .httpStatus(let status):
            "Penn State returned HTTP \(status)."
        case .emptyResponse:
            "Penn State returned an empty response."
        case .unexpectedContentType(let contentType):
            "Penn State returned an unexpected content type: \(contentType ?? "unknown")."
        case .unexpectedResponse:
            "Penn State returned data in an unexpected format."
        case .network(let message):
            message
        }
    }
}

private enum CampusRecLoadResult<Value: Sendable>: Sendable {
    case success(Value)
    case failure(String)
}

private struct FacilitySource: Sendable {
    let id: String
    let location: String
}

private struct FacilityPayload: Sendable {
    let source: FacilitySource
    let appointments: [FacilityAppointmentDTO]
}

private struct FacilityAppointmentDTO: Decodable, Sendable {
    let text: String
    let startDate: String
    let endDate: String
    let allDay: Bool
    let recurrenceRule: String?
    let recurrenceException: String?

    enum CodingKeys: String, CodingKey {
        case text = "Text"
        case startDate = "StartDate"
        case endDate = "EndDate"
        case allDay = "AllDay"
        case recurrenceRule = "RecurrenceRule"
        case recurrenceException = "RecurrenceException"
    }
}

private struct ScheduleOccurrence: Sendable {
    let activity: String
    let location: String
    let dayIndex: Int
    let time: String
}

private let scheduleEndpoint = URL(string: "https://pennstatecampusrec.org/Facility/GetScheduleCustomAppointmentsForDevExtremeScheduler").unsafelyUnwrapped
private let calendarEndpoint = URL(string: "https://pennstatecampusrec.org/Calendar/GetCalendarWidgetItems").unsafelyUnwrapped
private let campusTimeZone = TimeZone(identifier: "America/New_York").unsafelyUnwrapped

// These are the selectable parent facilities used by Penn State's live schedule page.
private let imFacilitySources = [
    FacilitySource(id: "71108e9a-c220-474b-9fb0-0376e847f6b9", location: "Gym 1"),
    FacilitySource(id: "6556d93f-ed79-4398-9fad-d7c2b58af2d7", location: "Gym 2"),
    FacilitySource(id: "38aec95d-e2f6-46ed-a2b1-36cb194bce6d", location: "Gym 3"),
    FacilitySource(id: "cc2490cc-b871-4209-a2db-47a2969edf0e", location: "Gym 4"),
    FacilitySource(id: "beeb7f84-8171-4ce0-ab09-665db211f201", location: "Turf East"),
    FacilitySource(id: "c8424f80-8962-4fd2-b6a4-5e6f9d0e843d", location: "Turf West")
]

@concurrent private func loadFacilitySchedules() async -> CampusRecLoadResult<[ActivitySchedule]> {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = campusTimeZone
    let start = calendar.startOfDay(for: .now)
    let end = calendar.date(byAdding: DateComponents(day: 6, hour: 23, minute: 59), to: start).unsafelyUnwrapped

    let payloads = await withTaskGroup(of: CampusRecLoadResult<FacilityPayload>.self) { @concurrent group in
        for source in imFacilitySources {
            group.addTask { @concurrent in
                do {
                    let data = try await fetchFacilityData(source: source, start: start, end: end)
                    let appointments: [FacilityAppointmentDTO]
                    do {
                        appointments = try JSONDecoder().decode([FacilityAppointmentDTO].self, from: data)
                    } catch {
                        return .failure(CampusRecRequestError.unexpectedResponse.localizedDescription)
                    }
                    return .success(FacilityPayload(source: source, appointments: appointments))
                } catch {
                    return .failure(error.localizedDescription)
                }
            }
        }

        var successes: [FacilityPayload] = []
        var failures: [String] = []
        for await result in group {
            switch result {
            case .success(let payload): successes.append(payload)
            case .failure(let message): failures.append(message)
            }
        }
        return (successes, failures)
    }

    guard !payloads.0.isEmpty else {
        return .failure(payloads.1.first ?? CampusRecRequestError.invalidResponse.localizedDescription)
    }

    if !payloads.1.isEmpty {
        print("Some Campus Recreation facilities failed to load: \(payloads.1.joined(separator: "; "))")
    }

    return .success(makeSchedules(from: payloads.0, start: start, end: end, calendar: calendar))
}

@concurrent private func loadCalendarDays() async -> CampusRecLoadResult<[CalendarDay]> {
    do {
        let data = try await validatedData(from: calendarEndpoint, expectedMIMEType: "text/html", allowsEmptyBody: true)
        guard !data.isEmpty else { return .success([]) }
        return .success(try parseCalendarHTML(data, sourceURL: calendarEndpoint))
    } catch {
        return .failure(error.localizedDescription)
    }
}

@concurrent private func fetchFacilityData(source: FacilitySource, start: Date, end: Date) async throws(CampusRecRequestError) -> Data {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = campusTimeZone
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"

    var components = URLComponents(url: scheduleEndpoint, resolvingAgainstBaseURL: false)
    components?.queryItems = [
        URLQueryItem(name: "selectedFacilityId", value: source.id),
        URLQueryItem(name: "start", value: formatter.string(from: start)),
        URLQueryItem(name: "end", value: formatter.string(from: end))
    ]
    guard let url = components?.url else { throw .invalidResponse }
    return try await validatedData(from: url, expectedMIMEType: "application/json")
}

@concurrent private func validatedData(from url: URL, expectedMIMEType: String, allowsEmptyBody: Bool = false) async throws(CampusRecRequestError) -> Data {
    let data: Data
    let response: URLResponse
    do {
        (data, response) = try await URLSession.shared.data(from: url)
    } catch {
        throw .network(error.localizedDescription)
    }

    guard let httpResponse = response as? HTTPURLResponse else { throw .invalidResponse }
    guard (200..<300).contains(httpResponse.statusCode) else { throw .httpStatus(httpResponse.statusCode) }
    guard httpResponse.mimeType?.caseInsensitiveCompare(expectedMIMEType) == .orderedSame else {
        throw .unexpectedContentType(httpResponse.mimeType)
    }
    guard allowsEmptyBody || !data.isEmpty else { throw .emptyResponse }
    return data
}

private func parseCalendarHTML(
    _ data: Data,
    sourceURL: URL
) throws(CampusRecRequestError) -> [CalendarDay] {
    do {
        let parser = SwiftSoup.Parser.htmlParser().settings(
            ParseSettings(false, false, false, true)
        )
        let document = try parser.parseInput([UInt8](data), sourceURL.absoluteString)
        let items = try document.getElementsByClass("CalendarItem")

        if items.isEmpty(),
           String(decoding: data, as: UTF8.self).localizedCaseInsensitiveContains("<html") {
            throw CampusRecRequestError.unexpectedResponse
        }

        var days: [CalendarDay] = []
        days.reserveCapacity(items.size())

        for item in items {
            let dateLabel = try item
                .getElementsByClass("NewsTitle")
                .text(trimAndNormaliseWhitespace: false)
            let eventElements = try item.getElementsByClass("CalendarEvent")
            var events: [CalendarEventModel] = []
            events.reserveCapacity(eventElements.size())

            for eventEl in eventElements {
                guard let linkElement = try eventEl.getElementsByTag("a").first() else { continue }
                let href = try linkElement.absUrl("href")
                guard !href.isEmpty, let fullLink = URL(string: href) else { continue }

                events.append(CalendarEventModel(
                    time: try eventEl
                        .getElementsByClass("EventTime")
                        .text(trimAndNormaliseWhitespace: false),
                    subject: try eventEl.getElementsByClass("EventSubject").text(),
                    link: fullLink
                ))
            }
            days.append(CalendarDay(dateLabel: dateLabel, events: events))
        }
        return days
    } catch let error as CampusRecRequestError {
        throw error
    } catch {
        throw .unexpectedResponse
    }
}

private func makeSchedules(from payloads: [FacilityPayload], start: Date, end: Date, calendar: Calendar) -> [ActivitySchedule] {
    let generatedOccurrences: [ScheduleOccurrence] = payloads.flatMap { payload in
        payload.appointments.flatMap {
            occurrences(for: $0, location: payload.source.location, start: start, end: end, calendar: calendar)
        }
    }

    let dayFormatter = DateFormatter()
    dayFormatter.calendar = calendar
    dayFormatter.locale = Locale(identifier: "en_US_POSIX")
    dayFormatter.timeZone = calendar.timeZone
    dayFormatter.dateFormat = "EEE M/d"
    let headers = ["Facility"] + (0..<7).compactMap {
        calendar.date(byAdding: .day, value: $0, to: start).map(dayFormatter.string)
    }

    let byActivity = Dictionary(grouping: generatedOccurrences, by: \ScheduleOccurrence.activity)
    return byActivity.keys.sorted().compactMap { activity in
        guard let activityOccurrences = byActivity[activity] else { return nil }
        let byLocation = Dictionary(grouping: activityOccurrences, by: \ScheduleOccurrence.location)
        let rows = byLocation.keys.sorted().map { location in
            let locationOccurrences = byLocation[location, default: []]
            let cells = (0..<7).map { dayIndex in
                Array(Set(locationOccurrences.filter { $0.dayIndex == dayIndex }.map(\.time)))
                    .sorted()
                    .joined(separator: "\n")
            }
            return ScheduleRow(cells: [location] + cells)
        }
        return ActivitySchedule(activity: activity, tables: [ScheduleTable(headers: headers, rows: rows)])
    }
}

private func occurrences(for appointment: FacilityAppointmentDTO, location: String, start: Date, end: Date, calendar: Calendar) -> [ScheduleOccurrence] {
    let dateFormatter = DateFormatter()
    dateFormatter.calendar = calendar
    dateFormatter.locale = Locale(identifier: "en_US_POSIX")
    dateFormatter.timeZone = calendar.timeZone
    dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
    guard let appointmentStart = dateFormatter.date(from: appointment.startDate),
          let appointmentEnd = dateFormatter.date(from: appointment.endDate),
          appointmentStart <= appointmentEnd
    else { return [] }

    let timeStyle = Date.IntervalFormatStyle(
        date: .omitted,
        time: .shortened,
        locale: .current,
        calendar: calendar,
        timeZone: calendar.timeZone
    )
    let time = if appointment.allDay {
        "All Day"
    } else {
        (appointmentStart..<appointmentEnd).formatted(timeStyle)
    }

    guard let recurrenceRule = appointment.recurrenceRule, !recurrenceRule.isEmpty else {
        guard appointmentStart >= start, appointmentStart <= end,
              let dayIndex = calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: appointmentStart)).day,
              (0..<7).contains(dayIndex)
        else { return [] }
        return [ScheduleOccurrence(activity: appointment.text.trimmingCharacters(in: .whitespacesAndNewlines), location: location, dayIndex: dayIndex, time: time)]
    }

    let ruleParts = Dictionary(uniqueKeysWithValues: recurrenceRule.split(separator: ";").compactMap { part -> (String, String)? in
        let values = part.split(separator: "=", maxSplits: 1).map(String.init)
        return values.count == 2 ? (values[0], values[1]) : nil
    })
    guard ruleParts["FREQ"] == "WEEKLY", let byDay = ruleParts["BYDAY"] else { return [] }

    let weekdayNumbers = Set(byDay.split(separator: ",").compactMap { weekdayNumber(for: String($0)) })
    let untilDate = ruleParts["UNTIL"].flatMap(parseRecurrenceUntil)
    let exceptionFormatter = DateFormatter()
    exceptionFormatter.calendar = calendar
    exceptionFormatter.locale = Locale(identifier: "en_US_POSIX")
    exceptionFormatter.timeZone = calendar.timeZone
    exceptionFormatter.dateFormat = "yyyyMMdd'T'HHmmss"
    let exceptions = Set((appointment.recurrenceException ?? "").split(separator: ",").compactMap {
        exceptionFormatter.date(from: String($0))
    })
    let startTime = calendar.dateComponents([.hour, .minute, .second], from: appointmentStart)

    return (0..<7).compactMap { dayIndex in
        guard let day = calendar.date(byAdding: .day, value: dayIndex, to: start),
              weekdayNumbers.contains(calendar.component(.weekday, from: day)),
              let occurrence = calendar.date(bySettingHour: startTime.hour ?? 0, minute: startTime.minute ?? 0, second: startTime.second ?? 0, of: day),
              occurrence >= appointmentStart,
              occurrence <= end,
              untilDate.map({ occurrence <= $0 }) ?? true,
              !exceptions.contains(occurrence)
        else { return nil }
        return ScheduleOccurrence(activity: appointment.text.trimmingCharacters(in: .whitespacesAndNewlines), location: location, dayIndex: dayIndex, time: time)
    }
}

private func weekdayNumber(for abbreviation: String) -> Int? {
    switch abbreviation {
    case "SU": 1
    case "MO": 2
    case "TU": 3
    case "WE": 4
    case "TH": 5
    case "FR": 6
    case "SA": 7
    default: nil
    }
}

private func parseRecurrenceUntil(_ value: String) -> Date? {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    return formatter.date(from: value)
}

// MARK: – Main View

struct ScheduleView: View {
    @State private var parsed: ParsedSchedules?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var fetchedAt: Date?
    @State private var loadedDay: Date?
    @Environment(\.scenePhase) private var scenePhase
    
    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground)
                .ignoresSafeArea()
            
            ScrollView {
                if let parsed {
                    contentView(parsed)
                } else if isLoading {
                    ProgressView("Loading Schedules…")
                        .frame(maxWidth: .infinity, minHeight: 300)
                } else if errorMessage != nil {
                    ContentUnavailableView {
                        Label("Unable to Load", systemImage: "wifi.slash")
                    } description: {
                        Text("Campus Recreation couldn't be reached.")
                    } actions: {
                        Button("Try Again") { Task { await loadSchedules(force: true) } }
                    }
                }
            }
            .refreshable { await loadSchedules(force: true) }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await loadSchedules()
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
        .analyticsScreen(name: "ScheduleView")
        .navigationTitle("Rec Schedule")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    // MARK: - Subviews
    
    @ViewBuilder
    private func contentView(_ data: ParsedSchedules) -> some View {
        VStack(spacing: 24) {
            if isLoading { ProgressView("Updating schedules…") }
            if data.scheduleError != nil {
                if !data.schedules.isEmpty {
                    Label("Showing saved facility schedules. Pull to refresh to try again.", systemImage: "wifi.slash")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    sourceUnavailableSection(title: "Facility Schedule Unavailable", systemImage: "building.2.crop.circle")
                }
            }
            if data.scheduleError == nil || !data.schedules.isEmpty {
                ScheduleMapSection(activeRegions: data.activeRegions, regionSchedules: data.regionSchedules)
            }
            if data.calendarError != nil {
                if !data.calendarDays.isEmpty {
                    Label("Showing saved calendar events. Pull to refresh to try again.", systemImage: "wifi.slash")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    sourceUnavailableSection(title: "Calendar Unavailable", systemImage: "calendar.badge.exclamationmark")
                }
            }
            if !data.calendarDays.isEmpty { CalendarWidget(days: data.calendarDays) }
        }
        .padding(16)
    }

    private func sourceUnavailableSection(title: String, systemImage: String) -> some View {
        ContentUnavailableView(title, systemImage: systemImage, description: Text("Pull to refresh and try again."))
            .frame(maxWidth: .infinity, minHeight: 180)
            .background(Color.secondarySystemGroupedBackground)
            .clipShape(RoundedRectangle(cornerRadius: 16))
    }
    
    // MARK: - Actions
    
    private func loadSchedules(force: Bool = false) async {
        guard !isLoading else { return }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = campusTimeZone
        let day = calendar.startOfDay(for: .now)
        if !force, loadedDay == day, let fetchedAt, Date.now.timeIntervalSince(fetchedAt) < 900 { return }
        if loadedDay != day { parsed = nil }
        let saved = parsed
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        async let scheduleResult = loadFacilitySchedules()
        async let calendarResult = loadCalendarDays()
        let (loadedSchedule, loadedCalendar) = await (scheduleResult, calendarResult)
        guard !Task.isCancelled, calendar.startOfDay(for: .now) == day else { return }
        let schedules: [ActivitySchedule]
        let scheduleError: String?
        switch loadedSchedule {
        case .success(let value): schedules = value; scheduleError = nil
        case .failure(let message): schedules = saved?.schedules ?? []; scheduleError = message
        }
        let calendarDays: [CalendarDay]
        let calendarError: String?
        switch loadedCalendar {
        case .success(let value): calendarDays = value; calendarError = nil
        case .failure(let message): calendarDays = saved?.calendarDays ?? []; calendarError = message
        }
        if scheduleError != nil, calendarError != nil, saved == nil {
            errorMessage = "Both Campus Recreation sources failed to load."
        } else {
            parsed = ParsedSchedules(schedules: schedules, calendarDays: calendarDays,
                                     scheduleError: scheduleError, calendarError: calendarError)
        }
        loadedDay = day
        // Failed sources can retry on the next visible check; successful loads keep a 15-minute TTL.
        fetchedAt = scheduleError == nil && calendarError == nil ? .now : nil
    }
}

/// Selection updates only the map; region parsing and row preparation happen on load.
private struct ScheduleMapSection: View {
    let activeRegions: Set<IMFacilityRegion>
    let regionSchedules: [IMFacilityRegion: [RegionSchedule]]
    @State private var selectedRegion: IMFacilityRegion?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Building Map")
                .font(.title2.weight(.semibold))
                .padding(.horizontal)
            IMBuildingMapView(activeRegions: activeRegions, selectedRegion: $selectedRegion) { region in
                RegionPopoverView(schedules: regionSchedules[region] ?? [])
            }
        }
    }
}

// MARK: – New Calendar UX

private struct CalendarWidget: View {
    let days: [CalendarDay]
    
    // State
    @State private var selectedDayID: String?
    @State private var searchText = ""
    @State private var filteredEvents: [CalendarEventModel] = []
    
    private var selectedDay: CalendarDay? {
        days.first { $0.id == selectedDayID }
    }
    
    private func updateFilteredEvents() {
        let events = selectedDay?.events ?? []
        filteredEvents = searchText.isEmpty ? events : events.filter {
            $0.subject.localizedCaseInsensitiveContains(searchText) ||
            $0.time.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Label("All Events", systemImage: "calendar")
                    .font(.headline)
                Spacer()
            }
            .padding()
            .background(Color.secondarySystemGroupedBackground)
            
            Divider()
            
            // 1. Day Picker (Horizontal Scroll)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(days) { day in
                        DayPill(dateLabel: day.dateLabel, isSelected: selectedDayID == day.id)
                            .onTapGesture {
                                withAnimation(.spring(duration: 0.3)) {
                                    selectedDayID = day.id
                                }
                            }
                    }
                }
                .padding()
            }
            .background(Color(uiColor: .tertiarySystemGroupedBackground))
            
            Divider()
            
            // 2. Events List (Vertical)
            // Fixed height container with internal scroll prevents the "infinite length" issue
            VStack(spacing: 0) {
                if let _ = selectedDay {
                    // Search Bar
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Search events...", text: $searchText)
                            .textFieldStyle(.plain)
                    }
                    .padding(10)
                    .background(Color(uiColor: .systemFill))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding()
                    
                    // The List
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            if filteredEvents.isEmpty {
                                ContentUnavailableView("No Events Found", systemImage: "magnifyingglass")
                                    .padding(.top, 40)
                            } else {
                                ForEach(filteredEvents) { event in
                                    VStack(spacing: 0) {
                                        EventRow(event: event)
                                            .padding(.horizontal)
                                            .padding(.vertical, 12)
                                        Divider()
                                            .padding(.leading, 80) // Inset divider
                                    }
                                }
                            }
                        }
                    }
                    .frame(height: 300) // Limits height to reasonable size
                } else {
                    ContentUnavailableView("Select a date", systemImage: "arrow.up.circle")
                        .frame(height: 200)
                }
            }
            .background(Color.secondarySystemGroupedBackground)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 4)
        .onChange(of: days, initial: true) {
            if !days.contains(where: { $0.id == selectedDayID }) { selectedDayID = days.first?.id }
            updateFilteredEvents()
        }
        .onChange(of: selectedDayID) { updateFilteredEvents() }
        .onChange(of: searchText) { updateFilteredEvents() }
    }
}

private struct DayPill: View {
    let dateLabel: String
    let isSelected: Bool
    
    var body: some View {
        Text(dateLabel)
            .font(.subheadline.weight(isSelected ? .semibold : .medium))
            .foregroundStyle(isSelected ? .white : .primary)
            .padding(.vertical, 8)
            .padding(.horizontal, 16)
            .background(isSelected ? Color.blue : Color(uiColor: .systemFill))
            .clipShape(Capsule())
//            .overlay(
//                Capsule()
//                    .strokeBorder(Color.blue.opacity(0.3), lineWidth: isSelected ? 0 : 1)
//            )
            .scaleEffect(isSelected ? 1.05 : 1.0)
    }
}

private struct EventRow: View {
    let event: CalendarEventModel
    @Environment(\.openURL) private var openURL
    
    var body: some View {
        Button {
            openURL(event.link)
        } label: {
            HStack(alignment: .center, spacing: 12) {
                // Time Column
                Text(event.time)
                    .font(.callout.monospacedDigit())
                    .fontWeight(.medium)
                    .foregroundStyle(.blue)
                    .frame(width: 70, alignment: .leading)
                    .minimumScaleFactor(0.8)
                
                // Subject
                Text(event.subject)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                
                Spacer()
                
                // Action Icon
                Image(systemName: "chevron.right")
                    .font(.caption2.bold())
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain) // Ensures the whole row is clickable without gray flash
    }
}

// Removed ActivityCard and RowCardTable as they are replaced by the map and RegionPopoverView

private struct TimeSlotCell: View {
    let day, time: String
    var body: some View {
        VStack(spacing: 4) {
            Text(day).font(.caption2.bold()).foregroundStyle(.secondary).textCase(.uppercase)
            Text(time).font(.caption.weight(.medium)).foregroundStyle(.primary).multilineTextAlignment(.center).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(Material.regular)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Region Popover

private struct RegionPopoverView: View {
    let schedules: [RegionSchedule]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Current Schedules").font(.headline)
                Spacer()
            }
            .padding()
            List {
                ForEach(schedules) { schedule in
                    Section(schedule.activity) {
                        ForEach(schedule.rows) { row in
                            RegionScheduleRowView(row: row)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 300, minHeight: 400)
    }
}

private struct RegionScheduleRowView: View {
    let row: RegionScheduleRow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(row.location)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 85), spacing: 8)], spacing: 8) {
                ForEach(row.slots) { slot in
                    TimeSlotCell(day: slot.day, time: slot.time)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: – Extensions
private extension Color {
    static let secondarySystemGroupedBackground = Color(uiColor: .secondarySystemGroupedBackground)
}

#Preview {
    ScheduleView()
}
