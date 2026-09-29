import SwiftUI
import UIKit
import EventKit
import EventKitUI
import MapKit
import Observation

private enum DiscoverDestination {
    case home, events, eventFilters, clubs, saved, club(String), event(String)
    var title: String {
        switch self {
        case .home: String(localized: "Discover")
        case .events, .eventFilters: String(localized: "Events")
        case .clubs: String(localized: "Clubs")
        case .saved: String(localized: "Saved")
        case .club: String(localized: "Club")
        case .event: String(localized: "Event")
        }
    }
}

@Observable @MainActor
private final class DiscoverPresentation {
    var calendarEvent: CampusEvent?
}

/// UIKit owns the navigation bar; SwiftUI owns the content and animated save control.
@MainActor
final class DiscoverCoordinator {
    private let model: DiscoverViewModel
    private weak var root: UIViewController?
    init(environment: DiscoverEnvironment = .shared) { model = environment.model }
    func makeRoot() -> UIViewController {
        let controller = makeController(.home)
        root = controller
        return controller
    }
    private func makeController(_ destination: DiscoverDestination) -> UIViewController {
        let presentation = DiscoverPresentation()
        let controller = UIHostingController(rootView: DiscoverScreen(model: model, presentation: presentation, destination: destination, open: { [self] in open($0) }))
        controller.title = destination.title
        controller.navigationItem.backButtonDisplayMode = .minimal
        switch destination {
        case .event(let id):
            controller.title = nil
            controller.navigationItem.largeTitleDisplayMode = .never
            if let event = model.event(id) {
                var actions: [UIMenuElement] = []
                if !event.isCancelled {
                    actions.append(UIAction(title: String(localized: "Add to Calendar"), image: UIImage(systemName: "calendar.badge.plus")) { [model] _ in
                        presentation.calendarEvent = model.event(id)
                    })
                }
                if let url = event.officialURL {
                    actions.append(UIAction(title: String(localized: "Open in Discover"), image: UIImage(systemName: "safari")) { _ in UIApplication.shared.open(url) })
                }
                installActions(on: controller, savedID: id, isClub: false, shareURL: event.officialURL, actions: actions)
            }
        case .club(let id):
            controller.title = nil
            controller.navigationItem.largeTitleDisplayMode = .never
            if let club = model.club(id) {
                installActions(on: controller, savedID: id, isClub: true, shareURL: club.officialURL, actions: [])
            }
        default:
            controller.navigationItem.largeTitleDisplayMode = .automatic
        }
        return controller
    }
    private func installActions(on controller: UIViewController, savedID: String, isClub: Bool, shareURL: URL?, actions: [UIMenuElement]) {
        let saveView = UIHostingConfiguration {
            DiscoverSaveButton(model: model, id: savedID, isClub: isClub)
        }.margins(.all, 0).makeContentView()
        saveView.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        let saveItem = UIBarButtonItem(customView: saveView)
        var items: [UIBarButtonItem] = []
        if !actions.isEmpty {
            let menu = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: UIMenu(children: actions))
            menu.accessibilityLabel = String(localized: "More actions")
            items.append(menu)
        }
        if let shareURL {
            let shareItem = UIBarButtonItem(systemItem: .action)
            shareItem.primaryAction = UIAction { [weak controller, weak shareItem] _ in
                guard let controller else { return }
                let activity = UIActivityViewController(activityItems: [shareURL], applicationActivities: nil)
                activity.popoverPresentationController?.barButtonItem = shareItem
                controller.present(activity, animated: true)
            }
            items.append(shareItem)
        }
        items.append(saveItem)
        controller.navigationItem.rightBarButtonItems = items
    }
    private func open(_ destination: DiscoverDestination) {
        root?.navigationController?.pushViewController(makeController(destination), animated: true)
    }
}

@MainActor
private struct DiscoverSaveButton: View {
    let model: DiscoverViewModel
    let id: String
    let isClub: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var saved: Bool { isClub ? model.saved.organizations[id] != nil : model.saved.events[id] != nil }
    var body: some View {
        Button {
            Task {
                if isClub, let club = model.club(id) { await model.toggle(club) }
                else if let event = model.event(id) { await model.toggle(event) }
            }
        } label: {
            Image(systemName: saved ? "bookmark.fill" : "bookmark")
                .font(.body.weight(.semibold))
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                .symbolEffect(.bounce, value: reduceMotion ? false : saved)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(saved ? Color.blue : Color.primary)
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: saved)
        .sensoryFeedback(.selection, trigger: saved)
        .accessibilityLabel(saved ? "Remove from saved" : "Save")
        .accessibilityValue(saved ? "Saved" : "Not saved")
    }
}

@MainActor
private struct DiscoverScreen: View {
    @Bindable var model: DiscoverViewModel
    @Bindable var presentation: DiscoverPresentation
    let destination: DiscoverDestination
    let open: (DiscoverDestination) -> Void
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        content
            .tint(.blue)
            .environment(\.timeZone, PSUDiscover.timeZone)
            .task { await model.load() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await model.load() } }
            }
            .onAppear { model.derive() }
            .sheet(item: $presentation.calendarEvent) { DiscoverCalendarEditor(event: $0) }
    }
    @ViewBuilder private var content: some View {
        switch destination {
        case .home: DiscoverHome(model: model, open: open)
        case .events: DiscoverEventList(model: model, open: open)
        case .eventFilters: DiscoverEventList(model: model, open: open, showFilters: true)
        case .clubs: DiscoverClubList(model: model, open: open)
        case .saved: DiscoverSavedView(model: model, open: open)
        case .club(let id):
            if let club = model.club(id) { DiscoverClubDetail(model: model, club: club, open: open) }
        case .event(let id):
            if let event = model.event(id) { DiscoverEventDetail(model: model, event: event, open: open) }
        }
    }
}

@MainActor
private struct DiscoverStatus: View {
    let model: DiscoverViewModel
    var body: some View {
        Section {
            if model.isLoading { ProgressView("Updating Discover…") }
            ForEach(model.issues, id: \.self) { issue in
                Label(issue, systemImage: "wifi.exclamationmark").font(.footnote).foregroundStyle(.secondary)
            }
            if let error = model.saveError { Label(error, systemImage: "exclamationmark.triangle").font(.footnote) }
            if !model.snapshot.directoryComplete, model.snapshot.organizationsUpdated != nil {
                Text("Limited club directory. Some clubs and their events may be missing.").font(.footnote).foregroundStyle(.secondary)
            }
            if !model.issues.isEmpty {
                Button("Try Again") { Task { await model.load(force: true) } }.disabled(model.isLoading)
                if let date = model.snapshot.eventsUpdated {
                    Text("Events last updated \(date, format: .dateTime.month().day().hour().minute())").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

@MainActor
private struct DiscoverHome: View {
    let model: DiscoverViewModel
    let open: (DiscoverDestination) -> Void
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                DiscoverHomeHeader(open: open)
                DiscoverHomeStatus(model: model)
                DiscoverHomeEvents(model: model, open: open)
                DiscoverHomeOngoingEvents(model: model, open: open)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .refreshable { await model.load(force: true) }
    }
}

@MainActor
private struct DiscoverHomeEvents: View {
    let model: DiscoverViewModel
    let open: (DiscoverDestination) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DiscoverSectionHeading(title: "On campus", actionTitle: "All events", isUpdating: model.isLoading && model.snapshot.eventsUpdated != nil) {
                model.prepareEventBrowse(); open(.events)
            }
            DiscoverFilterChips(model: model, open: open)
            if model.snapshot.eventsUpdated == nil, !model.hasLoaded || model.isLoading {
                DiscoverEventsLoading()
            } else if model.homeEvents.isEmpty {
                DiscoverEventsEmpty(model: model, isHome: true)
            }
            ForEach(model.homeEvents.prefix(5)) { event in
                Button { open(.event(event.id)) } label: {
                    DiscoverEventRow(event: event, saved: model.saved.events[event.id] != nil)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.background, in: RoundedRectangle(cornerRadius: 20))
                }.buttonStyle(DiscoverPressStyle())
            }
            if !model.homeEvents.isEmpty {
                Button("See all events") { model.prepareEventBrowse(); open(.events) }
                    .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44).padding(.top, 2)
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: model.homeDateFilter)
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: model.freeFood)
    }
}

@MainActor
private struct DiscoverHomeOngoingEvents: View {
    let model: DiscoverViewModel
    let open: (DiscoverDestination) -> Void

    var body: some View {
        if !model.homeOngoingEvents.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Ongoing on campus").font(.title2.bold())
                Text("Exhibitions, opportunities, and longer-running events.")
                    .font(.subheadline).foregroundStyle(.secondary)
                ForEach(model.homeOngoingEvents.prefix(2)) { event in
                    Button { open(.event(event.id)) } label: {
                        DiscoverEventRow(event: event, saved: model.saved.events[event.id] != nil)
                            .padding(16).background(.background, in: RoundedRectangle(cornerRadius: 20))
                    }.buttonStyle(DiscoverPressStyle())
                }
                Button("See all ongoing events") { model.prepareEventBrowse(); open(.events) }
                    .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
            }
        }
    }
}

private struct DiscoverSectionHeading: View {
    let title: LocalizedStringResource
    let actionTitle: LocalizedStringResource
    let isUpdating: Bool
    let action: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        let layout = if dynamicTypeSize.isAccessibilitySize {
            AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
        } else {
            AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
        }
        layout {
            HStack(spacing: 8) {
                Text(title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                ProgressView().controlSize(.small)
                    .opacity(isUpdating ? 1 : 0)
                    .accessibilityLabel("Updating campus events")
                    .accessibilityHidden(!isUpdating)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button(action: action) {
                HStack(spacing: 6) { Text(actionTitle); Image(systemName: "arrow.right") }
                    .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
            }.buttonStyle(DiscoverPressStyle())
        }
    }
}

private struct DiscoverEventsLoading: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                ProgressView()
                Text("Loading campus events…").font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            ForEach(0..<3) { _ in
                HStack(alignment: .top, spacing: 14) {
                    if !dynamicTypeSize.isAccessibilitySize {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.quaternary)
                            .frame(width: 72, height: 72)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Upcoming campus event").font(.headline)
                        Text("Today, 5:00–7:00 PM").font(.subheadline)
                        Label("University Park", systemImage: "mappin").font(.caption)
                        Text("Student organization").font(.caption)
                    }
                    .redacted(reason: .placeholder)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
                .background(.background, in: RoundedRectangle(cornerRadius: 20))
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading campus events")
    }
}

@MainActor
private struct DiscoverHomeHeader: View {
    let open: (DiscoverDestination) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    DiscoverShortcut(title: "Explore clubs", subtitle: "Find your community", symbol: "person.3.fill") { open(.clubs) }
                    DiscoverShortcut(title: "Saved", subtitle: "Plans worth keeping", symbol: "bookmark.fill", tint: .orange) { open(.saved) }
                }
                VStack(spacing: 12) {
                    DiscoverShortcut(title: "Explore clubs", subtitle: "Find your community", symbol: "person.3.fill") { open(.clubs) }
                    DiscoverShortcut(title: "Saved", subtitle: "Plans worth keeping", symbol: "bookmark.fill", tint: .orange) { open(.saved) }
                }
            }
        }
    }
}

private struct DiscoverShortcut: View {
    let title: LocalizedStringResource
    let subtitle: LocalizedStringResource
    let symbol: String
    var tint: Color = .blue
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: symbol).font(.title3).foregroundStyle(tint)
                        .frame(width: 36, height: 36).background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
                    Spacer(minLength: 10)
                    Image(systemName: "arrow.up.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(.background, in: RoundedRectangle(cornerRadius: 20))
        }.buttonStyle(DiscoverPressStyle())
    }
}

@MainActor
private struct DiscoverHomeStatus: View {
    let model: DiscoverViewModel
    var body: some View {
        if !model.issues.isEmpty || model.saveError != nil {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.issues, id: \.self) { Text($0).font(.footnote).foregroundStyle(.secondary) }
                if let error = model.saveError { Text(error).font(.footnote).foregroundStyle(.secondary) }
                Button("Try again") { Task { await model.load(force: true) } }.font(.subheadline.weight(.semibold))
                if let date = model.snapshot.eventsUpdated {
                    Text("Updated \(date, format: .relative(presentation: .named))").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(.background, in: RoundedRectangle(cornerRadius: 16))
        }
        if !model.snapshot.directoryComplete, model.snapshot.organizationsUpdated != nil {
            Text("Limited directory. Some clubs and events may be missing.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

@MainActor
private struct DiscoverFilterChips: View {
    @Bindable var model: DiscoverViewModel
    let open: (DiscoverDestination) -> Void
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Menu {
                    Picker("When", selection: $model.homeDateFilter) {
                        ForEach(DiscoverDateFilter.allCases) { Text($0.title).tag($0) }
                    }
                } label: {
                    HStack(spacing: 6) { Text(model.homeDateFilter.title); Image(systemName: "chevron.down").font(.caption2.bold()) }
                        .font(.subheadline.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 10).frame(minHeight: 44)
                        .foregroundStyle(.white).background(.blue, in: Capsule())
                }
                if model.supportsPerks {
                    Button { model.freeFood.toggle() } label: {
                        Label("Free food", systemImage: "fork.knife")
                            .font(.subheadline.weight(.medium)).padding(.horizontal, 14).padding(.vertical, 10).frame(minHeight: 44)
                            .foregroundStyle(model.freeFood ? Color.white : Color.primary)
                            .background(model.freeFood ? Color.blue : Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
                    }.buttonStyle(DiscoverPressStyle()).sensoryFeedback(.selection, trigger: model.freeFood)
                        .accessibilityAddTraits(model.freeFood ? .isSelected : [])
                }
                Button { model.prepareEventBrowse(); open(.eventFilters) } label: {
                    Image(systemName: "slider.horizontal.3").font(.subheadline.weight(.medium))
                        .padding(12).background(.background, in: Circle())
                }.foregroundStyle(.primary).accessibilityLabel("All event filters")
            }
        }

    }
}

@MainActor
private struct DiscoverEventFilters: View {
    @Bindable var model: DiscoverViewModel
    var body: some View {
        Picker("When", selection: $model.dateFilter) {
            ForEach([DiscoverDateFilter.week, .upcoming]) { filter in Text(filter.title).tag(filter) }
        }.pickerStyle(.menu)
        if model.supportsPerks { Toggle("Free Food", isOn: $model.freeFood) }
        Toggle("Online", isOn: $model.onlineOnly)
        Toggle("Saved Clubs", isOn: $model.savedClubsOnly)
        Picker("Category", selection: $model.eventCategory) {
            Text("All Categories").tag("")
            ForEach(model.eventCategories, id: \.self) { Text($0).tag($0) }
        }
    }
}

@MainActor
private struct DiscoverEventsEmpty: View {
    @Bindable var model: DiscoverViewModel
    var isHome = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("No matching events", systemImage: "calendar").font(.headline)
            Text("Try another day or remove a filter.").font(.subheadline).foregroundStyle(.secondary)
            Button("Show all upcoming events") {
                if isHome { model.homeDateFilter = .upcoming }
                model.eventSearch = ""; model.dateFilter = .upcoming; model.freeFood = false
                model.onlineOnly = false; model.savedClubsOnly = false; model.eventCategory = ""
            }
        }.padding(.vertical, 8)
    }
}

@MainActor
private struct DiscoverEventList: View {
    @Bindable var model: DiscoverViewModel
    let open: (DiscoverDestination) -> Void
    @State private var filtersExpanded: Bool
    init(model: DiscoverViewModel, open: @escaping (DiscoverDestination) -> Void, showFilters: Bool = false) {
        self.model = model
        self.open = open
        _filtersExpanded = State(initialValue: showFilters)
    }
    var body: some View {

        List {
            DiscoverStatus(model: model)
            Section {
                DiscoverSearchField(text: $model.eventSearch, prompt: "Search events")
                DisclosureGroup(isExpanded: $filtersExpanded) {
                    DiscoverEventFilters(model: model)
                    if model.hasEventFilters {
                        Button("Reset filters") { model.resetEventFilters() }
                    }
                } label: {
                    HStack {
                        Label("Filters", systemImage: "slider.horizontal.3")
                        Spacer()
                        Text(model.dateFilter.title).font(.caption).foregroundStyle(.secondary)
                        if model.hasEventFilters { Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(.blue).accessibilityLabel("Additional filters active") }
                    }
                }

            }
            Section("Events") {
                if model.snapshot.eventsUpdated == nil, !model.hasLoaded || model.isLoading {
                    DiscoverEventsLoading()
                } else if model.visibleEvents.isEmpty, !model.isLoading {
                    DiscoverEventsEmpty(model: model)
                }
                ForEach(model.visibleEvents) { event in
                    Button { open(.event(event.id)) } label: { DiscoverEventRow(event: event, saved: model.saved.events[event.id] != nil) }.buttonStyle(DiscoverPressStyle())
                }
            }
            if !model.ongoingEvents.isEmpty {
                Section("Ongoing on campus") {
                    ForEach(model.ongoingEvents) { event in
                        Button { open(.event(event.id)) } label: {
                            DiscoverEventRow(event: event, saved: model.saved.events[event.id] != nil)
                        }.buttonStyle(DiscoverPressStyle())
                    }
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .refreshable { await model.load(force: true) }
    }
}

@MainActor
private struct DiscoverClubList: View {
    @Bindable var model: DiscoverViewModel
    let open: (DiscoverDestination) -> Void
    var body: some View {
        List {
            DiscoverStatus(model: model)
            DiscoverSearchField(text: $model.clubSearch, prompt: "Search clubs and interests")
            Picker("Category", selection: $model.clubCategory) {
                Text("All Categories").tag("")
                ForEach(model.clubCategories, id: \.self) { Text($0).tag($0) }
            }
            Section("University Park clubs") {
                if model.visibleClubs.isEmpty, !model.isLoading {
                    ContentUnavailableView {
                        Label("No matching clubs", systemImage: "person.3")
                    } description: {
                        Text("Try another interest or browse all University Park clubs.")
                    } actions: {
                        Button("Show all clubs") { model.clubSearch = ""; model.clubCategory = "" }
                    }

                }
                ForEach(model.visibleClubs) { club in
                    Button { open(.club(club.id)) } label: { DiscoverClubRow(club: club, saved: model.saved.organizations[club.id] != nil) }.buttonStyle(DiscoverPressStyle())
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .refreshable { await model.load(force: true) }
    }
}

@MainActor
private struct DiscoverSavedView: View {
    let model: DiscoverViewModel
    let open: (DiscoverDestination) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var count: Int { model.savedClubs.count + model.savedUpcoming.count + model.savedPast.count }
    var body: some View {
        List {
            DiscoverStatus(model: model)
            if count == 0 {
                ContentUnavailableView {
                    Label("A place for your plans", systemImage: "bookmark")
                } description: {
                    Text("Keep a club you’re curious about or an event you’d love to try. Your saves stay here, even offline.")
                } actions: {
                    Button { model.prepareEventBrowse(); open(.events) } label: {
                        Text("Explore events").frame(minHeight: 44)
                    }.buttonStyle(.borderedProminent)
                    Button { open(.clubs) } label: {
                        Text("Find a club").frame(minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(.bordered)
                }
            }
            if !model.savedClubs.isEmpty {
                Section("Clubs") {
                    ForEach(model.savedClubs) { club in
                        Button { open(.club(club.id)) } label: { DiscoverClubRow(club: club, saved: true) }
                            .buttonStyle(DiscoverPressStyle())
                            .swipeActions {
                                Button("Unsave", systemImage: "bookmark.slash") { Task { await model.toggle(club) } }.tint(.orange)
                            }
                            .accessibilityAction(named: "Remove from Saved") { Task { await model.toggle(club) } }
                    }
                }
            }
            if !model.savedUpcoming.isEmpty {
                Section("Upcoming events") {
                    ForEach(model.savedUpcoming) { event in
                        DiscoverSavedEventRow(model: model, event: event, open: open)
                    }
                }
            }
            if !model.savedPast.isEmpty {
                Section("Past events") {
                    ForEach(model.savedPast) { event in
                        DiscoverSavedEventRow(model: model, event: event, open: open)
                    }
                }
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: count)
        .sensoryFeedback(.selection, trigger: count)
        .refreshable { await model.load(force: true) }
    }
}

@MainActor
private struct DiscoverSavedEventRow: View {
    let model: DiscoverViewModel
    let event: CampusEvent
    let open: (DiscoverDestination) -> Void
    var body: some View {
        Button { open(.event(event.id)) } label: { DiscoverEventRow(event: event, saved: true) }
            .buttonStyle(DiscoverPressStyle())
            .swipeActions {
                Button("Unsave", systemImage: "bookmark.slash") { Task { await model.toggle(event) } }.tint(.orange)
            }
            .accessibilityAction(named: "Remove from Saved") { Task { await model.toggle(event) } }
    }
}

private struct DiscoverClubRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let club: CampusOrganization
    let saved: Bool
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if !dynamicTypeSize.isAccessibilitySize { DiscoverThumbnail(url: club.imageURL, symbol: "person.3", size: 52) }
            VStack(alignment: .leading, spacing: 5) {
                Text(club.name).font(.headline)
                Text(club.summary.isEmpty ? club.description : club.summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
            }
            Spacer(minLength: 0)
            if saved { Image(systemName: "bookmark.fill").foregroundStyle(.blue).accessibilityLabel("Saved") }
        }.padding(.vertical, 5).contentShape(Rectangle())
    }
}

private struct DiscoverEventRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let event: CampusEvent
    let saved: Bool
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if !dynamicTypeSize.isAccessibilitySize {
                if let url = event.imageURL ?? event.organizationImageURL {
                    DiscoverThumbnail(url: url, symbol: "calendar", size: 72)
                } else {
                    DiscoverDateBadge(start: event.start, isOngoing: event.isOngoingListing(at: .now))
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(event.title).font(.headline).foregroundStyle(.primary).lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 3)
                    Spacer(minLength: 0)
                    if saved { Image(systemName: "bookmark.fill").font(.caption).foregroundStyle(.blue).accessibilityLabel("Saved") }
                }
                DiscoverEventTime(event: event, compact: !dynamicTypeSize.isAccessibilitySize && event.imageURL == nil && event.organizationImageURL == nil)
                if !event.location.isEmpty {
                    Label(event.location, systemImage: event.isOnline ? "video" : "mappin")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if !event.hostNames.isEmpty {
                    Text(event.hostNames.formatted(.list(type: .and)))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if event.benefits.contains("Free Food") {
                    Label("Free food", systemImage: "fork.knife").font(.caption.weight(.semibold))
                        .foregroundStyle(.orange).padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.orange.opacity(0.09), in: Capsule())
                }
                if event.isCancelled { Text("Cancelled").foregroundStyle(.red).font(.caption.bold()) }
            }
        }.padding(.vertical, 3).contentShape(Rectangle())
    }
}

private struct DiscoverDateBadge: View {
    let start: Date
    let isOngoing: Bool
    var body: some View {
        VStack(spacing: 3) {
            if isOngoing {
                Image(systemName: "calendar.badge.clock").font(.title2)
            } else {
                Text(start, format: .dateTime.month(.abbreviated)).font(.caption.weight(.semibold))
                Text(start, format: .dateTime.day()).font(.title2.weight(.bold).monospacedDigit())
            }
        }
        .foregroundStyle(.blue)
        .frame(width: 48, height: 56)
        .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityHidden(true)
    }
}

private struct DiscoverEventTime: View {
    let event: CampusEvent
    var compact = false
    private var intervalStyle: Date.IntervalFormatStyle {
        Date.IntervalFormatStyle(date: .abbreviated, time: .omitted, calendar: PSUDiscover.calendar, timeZone: PSUDiscover.timeZone)
    }
    private var timeStyle: Date.IntervalFormatStyle {
        Date.IntervalFormatStyle(date: .omitted, time: .shortened, calendar: PSUDiscover.calendar, timeZone: PSUDiscover.timeZone)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if event.spansMultipleDays, let end = event.end {
                let lastDate = event.isAllDay ? end.addingTimeInterval(-1) : end
                if compact, event.isOngoingListing(at: .now) {
                    Text("Through \(lastDate, format: .dateTime.month(.abbreviated).day().year())")
                } else {
                    Text((event.start..<lastDate).formatted(intervalStyle))
                }
            } else {
                if !compact { Text(event.start, format: .dateTime.weekday(.wide).month(.abbreviated).day()) }
                if event.isAllDay { Text("All day") }
                else if let end = event.end, end > event.start {
                    Text((event.start..<end).formatted(timeStyle))
                } else { Text(event.start, format: .dateTime.hour().minute()) }
            }
            if !compact, !event.isAllDay {
                if event.spansMultipleDays {
                    Text("Starts \(event.start, format: .dateTime.hour().minute())")
                    if let end = event.end { Text("Ends \(end, format: .dateTime.hour().minute())") }
                }
            }
        }.font(.subheadline.weight(.medium)).foregroundStyle(.primary)
    }
}

private struct DiscoverSearchField: View {
    @Binding var text: String
    let prompt: LocalizedStringResource
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(String(localized: prompt), text: $text)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .focused($focused).submitLabel(.search).onSubmit { focused = false }
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).frame(width: 44, height: 44) }
                    .buttonStyle(.borderless).accessibilityLabel("Clear search")
            }
        }.padding(.vertical, 4)
    }
}

private struct DiscoverThumbnail: View {
    let url: URL?
    let symbol: String
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: reduceMotion ? nil : .easeOut(duration: 0.2))) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill().transition(.opacity)
            } else {
                ZStack {
                    Color.blue.opacity(0.07)
                    Image(systemName: symbol).font(.title2).foregroundStyle(.blue.opacity(0.6))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
        .accessibilityHidden(true)
    }
}

private struct DiscoverArtwork: View {
    let url: URL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: reduceMotion ? nil : .easeOut(duration: 0.25))) { phase in
            if let image = phase.image {
                image.resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 340)
                    .transition(.opacity)
            } else if phase.error == nil {
                RoundedRectangle(cornerRadius: 20).fill(.quaternary)
                    .frame(height: 200).overlay { ProgressView() }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .accessibilityLabel("Event artwork")
    }
}

private struct DiscoverDetailSection<Content: View>: View {
    let title: LocalizedStringResource
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.bold()).accessibilityAddTraits(.isHeader)
            content
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
private struct DiscoverClubDetail: View {
    let model: DiscoverViewModel
    let club: CampusOrganization
    let open: (DiscoverDestination) -> Void
    @State private var events: [CampusEvent] = []
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 18) {
                    DiscoverThumbnail(url: club.imageURL, symbol: "person.3", size: 88)
                    Text(club.name).font(.largeTitle.bold()).fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                }
                if let url = club.officialURL {
                    Link(destination: url) {
                        Label("Visit official club page", systemImage: "arrow.up.right")
                            .font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                    }.buttonStyle(.borderedProminent)
                }
                if !club.description.isEmpty {
                    DiscoverDetailSection(title: "About") {
                        Text(club.description).font(.body).lineSpacing(4).textSelection(.enabled)
                    }
                } else if !club.summary.isEmpty {
                    Text(club.summary).font(.body).lineSpacing(4).textSelection(.enabled)
                }
                DiscoverDetailSection(title: "Upcoming events") {
                    if events.isEmpty {
                        Text("No upcoming events listed.").foregroundStyle(.secondary)
                    }
                    ForEach(events) { event in
                        Button { open(.event(event.id)) } label: {
                            DiscoverEventRow(event: event, saved: model.saved.events[event.id] != nil)
                                .padding(16).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
                        }.buttonStyle(DiscoverPressStyle())
                    }
                }
                DiscoverHomeStatus(model: model)
            }
            .padding(20).padding(.bottom, 16)
            .frame(maxWidth: 720, alignment: .leading).frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .onAppear { events = model.events(for: club) }
        .onChange(of: model.snapshot.eventsUpdated) { _, _ in events = model.events(for: club) }
    }
}

@MainActor
private struct DiscoverEventDetail: View {
    let model: DiscoverViewModel
    let event: CampusEvent
    let open: (DiscoverDestination) -> Void
    @State private var hosts: [DiscoverHost] = []
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if let imageURL = event.imageURL { DiscoverArtwork(url: imageURL) }
                VStack(alignment: .leading, spacing: 14) {
                    if event.isCancelled {
                        Label("Cancelled", systemImage: "xmark.circle.fill").font(.subheadline.weight(.semibold)).foregroundStyle(.red)
                    }
                    Text(event.title).font(.largeTitle.bold()).fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    if !event.benefits.isEmpty {
                        Text(event.benefits.formatted(.list(type: .and)))
                            .font(.subheadline.weight(.medium)).foregroundStyle(.blue)
                    }
                }
                DiscoverEventLocation(event: event)
                if !hosts.isEmpty {
                    DiscoverDetailSection(title: "Hosted by") {
                        ForEach(hosts) { host in
                            DiscoverHostRow(host: host, open: open)
                        }
                    }
                }
                if !event.description.isEmpty {
                    DiscoverDetailSection(title: "About") {
                        Text(event.description).font(.body).lineSpacing(4).textSelection(.enabled)
                    }
                }
                DiscoverHomeStatus(model: model)
            }
            .padding(20).padding(.bottom, 16)
            .frame(maxWidth: 720, alignment: .leading).frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .onAppear { hosts = model.hosts(for: event) }
        .onChange(of: model.snapshot.organizationsUpdated) { _, _ in hosts = model.hosts(for: event) }
    }
}

@MainActor
private struct DiscoverHostRow: View {
    let host: DiscoverHost
    let open: (DiscoverDestination) -> Void
    var body: some View {
        Button {
            if let id = host.organizationID { open(.club(id)) }
        } label: {
            HStack(spacing: 12) {
                DiscoverThumbnail(url: host.imageURL, symbol: "person.3", size: 48)
                Text(host.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if host.organizationID != nil { Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary) }
            }.padding(14).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
        }.buttonStyle(DiscoverPressStyle()).disabled(host.organizationID == nil)
    }
}

@MainActor
private struct DiscoverEventLocation: View {
    let event: CampusEvent
    @Environment(\.openURL) private var openURL
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "calendar").font(.title3).foregroundStyle(.blue).frame(width: 24)
                DiscoverEventTime(event: event)
            }
            if event.isOnline {
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Label("Online", systemImage: "video").font(.headline)
                    if let url = event.onlineURL, !event.isCancelled {
                        Link(destination: url) {
                            Label("Open online event", systemImage: "arrow.up.right")
                                .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 4)
                        }.buttonStyle(.borderedProminent).controlSize(.large)
                    } else if let url = event.officialURL {
                        Link("View online details in Discover", destination: url)
                            .font(.subheadline.weight(.medium))
                    }
                }
            } else if !event.location.isEmpty {
                Divider()
                Button { if let url = mapsURL { openURL(url) } } label: {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: "mappin.and.ellipse").font(.title3).foregroundStyle(.blue).frame(width: 24)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(event.location).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                            Text("Get directions").font(.caption).foregroundStyle(.blue)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }.multilineTextAlignment(.leading)
                }.buttonStyle(DiscoverPressStyle())
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }
    private var mapsURL: URL? {
        var components = URLComponents(string: "https://maps.apple.com/")!
        if let latitude = event.latitude, let longitude = event.longitude,
           (-90...90).contains(latitude), (-180...180).contains(longitude) {
            components.queryItems = [URLQueryItem(name: "daddr", value: "\(latitude),\(longitude)")]
        } else {
            components.queryItems = [URLQueryItem(name: "daddr", value: "\(event.location), University Park, PA")]
        }
        components.queryItems?.append(URLQueryItem(name: "dirflg", value: "w"))
        return components.url
    }
}

private struct DiscoverPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(reduceMotion ? nil : .smooth(duration: 0.18), value: configuration.isPressed)
    }
}

@MainActor
private struct DiscoverCalendarEditor: UIViewControllerRepresentable {
    let event: CampusEvent
    @Environment(\.dismiss) private var dismiss
    func makeCoordinator() -> Coordinator { Coordinator(dismiss: dismiss) }
    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let controller = EKEventEditViewController()
        let store = EKEventStore()
        controller.eventStore = store
        let calendarEvent = EKEvent(eventStore: store)
        calendarEvent.title = event.title
        calendarEvent.startDate = event.start
        calendarEvent.endDate = event.end ?? PSUDiscover.calendar.date(byAdding: event.isAllDay ? .day : .hour, value: 1, to: event.start)
        calendarEvent.isAllDay = event.isAllDay
        calendarEvent.timeZone = PSUDiscover.timeZone
        calendarEvent.location = event.location
        calendarEvent.notes = event.description
        calendarEvent.url = event.officialURL
        controller.event = calendarEvent
        controller.editViewDelegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: EKEventEditViewController, context: Context) {}
    @MainActor
    final class Coordinator: NSObject, @preconcurrency EKEventEditViewDelegate {
        let dismiss: DismissAction
        init(dismiss: DismissAction) { self.dismiss = dismiss }
        func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) { dismiss() }
    }
}
