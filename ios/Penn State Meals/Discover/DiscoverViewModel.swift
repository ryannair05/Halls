import Foundation
import Observation

@MainActor
final class DiscoverEnvironment {
    static let shared = DiscoverEnvironment()
    let model: DiscoverViewModel
    init(repository: DiscoverRepository? = nil) {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Discover", isDirectory: true)
        model = DiscoverViewModel(repository: repository ?? DiscoverRepository(directory: root))
    }
}

enum DiscoverDateFilter: String, CaseIterable, Identifiable {
    case today, tomorrow, week, upcoming
    var id: String { rawValue }
    var title: LocalizedStringResource {
        switch self { case .today: "Today"; case .tomorrow: "Tomorrow"; case .week: "This Week"; case .upcoming: "All Upcoming" }
    }
    func includes(_ event: CampusEvent, now: Date) -> Bool {
        let calendar = PSUDiscover.calendar
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        let start: Date
        let end: Date?
        switch self {
        case .today: start = today; end = tomorrow
        case .tomorrow: start = tomorrow; end = calendar.date(byAdding: .day, value: 2, to: today)
        case .week: start = today; end = calendar.dateInterval(of: .weekOfYear, for: now)?.end
        case .upcoming: start = now; end = nil
        }
        return event.isUpcoming(at: max(start, now)) && (end.map { event.start < $0 } ?? true)
    }
}

struct DiscoverHost: Identifiable {
    let id: String
    let name: String
    let imageURL: URL?
    let organizationID: String?
}

@Observable @MainActor
final class DiscoverViewModel {
    private(set) var snapshot = DiscoverSnapshot()
    private(set) var saved = DiscoverSavedItems()
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var issues: [String] = []
    private(set) var saveError: String?
    private(set) var visibleEvents: [CampusEvent] = []
    private(set) var homeEvents: [CampusEvent] = []
    private(set) var homeOngoingEvents: [CampusEvent] = []
    private(set) var ongoingEvents: [CampusEvent] = []
    private(set) var visibleClubs: [CampusOrganization] = []
    private(set) var clubCategories: [String] = []
    private(set) var eventCategories: [String] = []
    private(set) var savedClubs: [CampusOrganization] = []
    private(set) var savedUpcoming: [CampusEvent] = []
    private(set) var savedPast: [CampusEvent] = []
    var clubSearch = "" { didSet { deriveClubs() } }
    var eventSearch = "" { didSet { deriveEvents() } }
    var clubCategory = "" { didSet { deriveClubs() } }
    var eventCategory = "" { didSet { deriveEvents() } }
    var homeDateFilter: DiscoverDateFilter = .today { didSet { deriveEvents() } }
    var dateFilter: DiscoverDateFilter = .week { didSet { deriveEvents() } }
    var freeFood = false { didSet { deriveEvents() } }
    var onlineOnly = false { didSet { deriveEvents() } }
    var savedClubsOnly = false { didSet { deriveEvents() } }
    @ObservationIgnored private let repository: DiscoverRepository
    @ObservationIgnored private var clubSearchText: [String: String] = [:]
    @ObservationIgnored private var eventSearchText: [String: String] = [:]
    @ObservationIgnored private var didLoad = false
    @ObservationIgnored private var canSave = true

    init(repository: DiscoverRepository) { self.repository = repository }
    var supportsPerks: Bool { snapshot.eventSource == .json }
    func load(force: Bool = false) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false; hasLoaded = true }
        if !didLoad || !canSave {
            snapshot = await repository.cached()
            indexContent()
            do { saved = try await repository.savedItems(); canSave = true; saveError = nil }
            catch { saveError = "Saved items could not be opened. Try reopening Discover."; canSave = false }
            didLoad = true
            derive()
        }
        let refresh = await repository.refresh(force: force)
        snapshot = refresh.snapshot
        indexContent()
        issues = refresh.issues
        if !supportsPerks { freeFood = false }
        saved.merge(snapshot)
        derive()
        if canSave { await persist() }
    }
    func toggle(_ organization: CampusOrganization) async {
        guard canSave else { return }
        if saved.organizations.removeValue(forKey: organization.id) == nil { saved.organizations[organization.id] = organization }
        derive()
        await persist()
    }
    func toggle(_ event: CampusEvent) async {
        guard canSave else { return }
        if saved.events.removeValue(forKey: event.id) == nil { saved.events[event.id] = event }
        derive()
        await persist()
    }
    private func persist() async {
        do { try await repository.save(saved); saveError = nil }
        catch { saveError = "Your changes could not be saved on this device. Please try again." }
    }
    func club(_ id: String) -> CampusOrganization? { snapshot.organizations.first { $0.id == id } ?? saved.organizations[id] }
    func event(_ id: String) -> CampusEvent? { snapshot.events.first { $0.id == id } ?? saved.events[id] }
    func events(for club: CampusOrganization) -> [CampusEvent] {
        snapshot.events.filter { !$0.isCancelled && $0.isUpcoming(at: .now) && $0.organizationIDs.contains(club.id) }
    }
    func hosts(for event: CampusEvent) -> [DiscoverHost] {
        var hosts: [DiscoverHost] = []
        var names: Set<String> = []
        for id in event.organizationIDs {
            guard let organization = club(id), names.insert(PSUDiscover.normalized(organization.name)).inserted else { continue }
            hosts.append(DiscoverHost(id: id, name: organization.name, imageURL: organization.imageURL, organizationID: id))
        }
        for name in event.hostNames where names.insert(PSUDiscover.normalized(name)).inserted {
            hosts.append(DiscoverHost(id: "name:\(name)", name: name, imageURL: event.organizationImageURL, organizationID: nil))
        }
        return hosts
    }
    var hasEventFilters: Bool { !eventCategory.isEmpty || onlineOnly || savedClubsOnly || freeFood || dateFilter != .week }
    func resetEventFilters() {
        dateFilter = .week
        eventCategory = ""
        onlineOnly = false
        savedClubsOnly = false
        freeFood = false
    }
    func prepareEventBrowse() {
        dateFilter = .week
        eventSearch = ""
        eventCategory = ""
        onlineOnly = false
        savedClubsOnly = false
    }
    /// Normalize source text once per snapshot, not once per keystroke.
    private func indexContent() {
        clubSearchText = Dictionary(uniqueKeysWithValues: snapshot.organizations.map {
            ($0.id, PSUDiscover.normalized($0.name + " " + $0.summary + " " + $0.categories.joined(separator: " ")))
        })
        eventSearchText = Dictionary(uniqueKeysWithValues: snapshot.events.map {
            ($0.id, PSUDiscover.normalized($0.title + " " + $0.hostNames.joined(separator: " ") + " " + $0.description))
        })
        clubCategories = Set(snapshot.organizations.flatMap(\.categories)).sorted()
        eventCategories = Set(snapshot.events.flatMap(\.categories)).sorted()
    }
    func derive(now: Date = .now) {
        deriveClubs()
        deriveEvents(now: now)
        savedClubs = saved.organizations.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        savedUpcoming = saved.events.values.filter { $0.isUpcoming(at: now) }.sorted { $0.start < $1.start }
        savedPast = saved.events.values.filter { !$0.isUpcoming(at: now) }.sorted { $0.start > $1.start }
    }
    private func deriveClubs() {
        let query = PSUDiscover.normalized(clubSearch)
        visibleClubs = snapshot.organizations.filter {
            (clubCategory.isEmpty || $0.categories.contains(clubCategory)) &&
            (query.isEmpty || clubSearchText[$0.id]?.contains(query) == true)
        }
    }
    private func deriveEvents(now: Date = .now) {
        let query = PSUDiscover.normalized(eventSearch)
        let campusEvents = snapshot.events.filter {
            !$0.isCancelled && (!freeFood || $0.benefits.contains("Free Food"))
        }
        // The landing page is a campus overview; searches and advanced filters belong to All Events.
        let homeMatches = campusEvents.filter { homeDateFilter.includes($0, now: now) }
        homeEvents = homeMatches.filter { !$0.isOngoingListing(at: now) }
        homeOngoingEvents = homeMatches.filter { $0.isOngoingListing(at: now) }
        let matches = campusEvents.filter {
            dateFilter.includes($0, now: now) && (eventCategory.isEmpty || $0.categories.contains(eventCategory)) &&
            (!onlineOnly || $0.isOnline) &&
            (!savedClubsOnly || $0.organizationIDs.contains { saved.organizations[$0] != nil }) &&
            (query.isEmpty || eventSearchText[$0.id]?.contains(query) == true)
        }
        visibleEvents = matches.filter { !$0.isOngoingListing(at: now) }
        ongoingEvents = matches.filter { $0.isOngoingListing(at: now) }
    }
}
