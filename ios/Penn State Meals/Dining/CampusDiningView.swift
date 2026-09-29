import SwiftUI
import UIKit

struct CampusDiningLegacyRequest {
    let id = UUID()
    let hall: String
}

/// A secondary school owns its entire lifetime; selecting PSU creates no secondary services.
struct CampusDiningView: UIViewControllerRepresentable {
    let school: CampusDiningSchool
    var legacyRequest: CampusDiningLegacyRequest?

    func makeUIViewController(context: Context) -> CampusDiningNavigationController {
        let environment = CampusDiningEnvironment(school: school)
        let list = CampusDiningListController(school: school, environment: environment)
        let controller = CampusDiningNavigationController(rootViewController: list)
        controller.environment = environment
        controller.navigationBar.prefersLargeTitles = true
        controller.view.tintColor = school == .uga ? .systemRed : .systemBlue
        return controller
    }

    func updateUIViewController(_ uiViewController: CampusDiningNavigationController, context: Context) {
        guard let legacyRequest, uiViewController.lastLegacyRequest != legacyRequest.id,
              let environment = uiViewController.environment, let root = uiViewController.viewControllers.first,
              let location = CampusDiningLocation.initialLocations(for: school).first(where: { $0.id.rawValue == legacyRequest.hall }) else { return }
        uiViewController.lastLegacyRequest = legacyRequest.id
        let menu = CampusDiningMenuController(location: location, environment: environment, date: location.calendarContext.localDate(containing: .now))
        uiViewController.setViewControllers([root, menu], animated: false)
    }

    static func dismantleUIViewController(_ uiViewController: CampusDiningNavigationController, coordinator: ()) {
        uiViewController.stopLoading()
    }
}

@MainActor final class CampusDiningNavigationController: UINavigationController {
    var environment: CampusDiningEnvironment?
    var lastLegacyRequest: UUID?
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stopLoading()
    }
    func stopLoading() {
        for controller in viewControllers {
            (controller as? CampusDiningListController)?.cancelWork()
            (controller as? CampusDiningMenuController)?.cancelWork()
        }
        if let environment { Task { await environment.cancel() } }
    }
}

@MainActor private enum CampusDiningUI {
    static func datePicker(context: ProviderCalendarContext) -> UIDatePicker {
        let picker = UIDatePicker()
        HeaderDatePickerView.configure(picker, context: context)
        return picker
    }
    static func label(_ text: String? = nil, size: CGFloat = 14) -> UILabel {
        let label = UILabel()
        label.font = .systemFont(ofSize: size)
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        label.text = text
        return label
    }
    static func header(_ stack: UIStackView, table: UITableView) {
        stack.axis = .vertical
        stack.spacing = 8
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = .init(top: 6, leading: max(20, table.safeAreaInsets.left + 16), bottom: 6, trailing: max(20, table.safeAreaInsets.right + 16))
        let width = table.bounds.width
        let previousSize = stack.frame.size
        let height = stack.systemLayoutSizeFitting(CGSize(width: width, height: UIView.layoutFittingCompressedSize.height), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height
        let size = CGSize(width: width, height: ceil(height))
        if table.tableHeaderView !== stack || previousSize != size {
            stack.frame = CGRect(origin: .zero, size: size)
            table.tableHeaderView = stack
        }
    }
    static func error(_ message: String, on controller: UIViewController) {
        let alert = UIAlertController(title: "Unable to complete request", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        controller.present(alert, animated: true)
    }
}

@MainActor final class CampusDiningListController: UITableViewController, UISearchResultsUpdating {
    private struct Match {
        let location: CampusDiningLocation
        let meal: MenuMealPeriod
        let item: DiningMenuItem
    }
    private let school: CampusDiningSchool
    private let environment: CampusDiningEnvironment
    private var locations: [CampusDiningLocation]
    private var groups: [(String, [CampusDiningLocation])] = []
    private var hours: [DiningLocationID: CampusDiningHours] = [:]
    private let search = UISearchController(searchResultsController: nil)
    private let status = CampusDiningUI.label()
    private let header = UIStackView()
    private let picker: UIDatePicker
    private var loadTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var generation = UUID()
    private var matches: [Match] = []
    private var searchMenus: [(CampusDiningLocation, CampusMenuResult)] = []
    private var searchDate: DateOnly?
    private var catalogMessage: String?
    private var isSearching: Bool { !(search.searchBar.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var calendarContext: ProviderCalendarContext { school == .uga ? ProviderCalendarContexts.uga : ProviderCalendarContexts.barnardColumbia }
    private var date: DateOnly { calendarContext.localDate(containing: picker.date) }

    init(school: CampusDiningSchool, environment: CampusDiningEnvironment) {
        self.school = school
        self.environment = environment
        locations = CampusDiningLocation.initialLocations(for: school)
        picker = CampusDiningUI.datePicker(context: school == .uga ? ProviderCalendarContexts.uga : ProviderCalendarContexts.barnardColumbia)
        super.init(style: .insetGrouped)
        title = school.title
    }
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = "Search food across campus"
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
        picker.addTarget(self, action: #selector(dateChanged), for: .valueChanged)
        let dateRow = UIStackView(arrangedSubviews: [CampusDiningUI.label("Menus for", size: 16), picker])
        dateRow.alignment = .center
        picker.setContentHuggingPriority(.required, for: .horizontal)
        header.addArrangedSubview(dateRow)
        header.addArrangedSubview(status)
        status.isHidden = true
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(refresh), for: .valueChanged)
        regroup()
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        load()
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        CampusDiningUI.header(header, table: tableView)
    }
    func cancelWork() {
        loadTask?.cancel(); loadTask = nil
        searchTask?.cancel(); searchTask = nil
        generation = UUID()
    }
    @objc private func refresh() { searchMenus = []; searchDate = nil; load(reload: true) }
    @objc private func dateChanged() { searchMenus = []; searchDate = nil; hours = [:]; load(); updateSearchResults(for: search) }

    private func regroup() {
        groups = []
        for name in school == .uga ? ["Dining Commons", "More places"] : ["Barnard", "Columbia", "More places"] {
            let members = locations.filter { name == "More places" ? $0.isRetail : !$0.isRetail && $0.group == name }
            if !members.isEmpty { groups.append((name, members)) }
        }
        tableView.reloadData()
    }
    private func load(reload: Bool = false) {
        loadTask?.cancel()
        let requestedDate = date
        loadTask = Task { [weak self] in
            guard let self else { return }
            locations = await environment.savedCatalog()
            guard !Task.isCancelled else { return }
            regroup()
            let catalog = await environment.discover(reload: reload)
            guard !Task.isCancelled, date == requestedDate else { return }
            locations = catalog.locations
            catalogMessage = catalog.message
            if !isSearching { status.text = catalog.message; status.isHidden = catalog.message == nil; view.setNeedsLayout() }
            regroup()
            refreshControl?.endRefreshing()
            if isSearching { updateSearchResults(for: search) }
            let environment = environment
            await withTaskGroup(of: (DiningLocationID, CampusDiningHours?).self) { group in
                for location in locations {
                    group.addTask { @concurrent in (location.id, try? await environment.hours(location, date: requestedDate, reload: reload)) }
                }
                for await (id, value) in group {
                    guard !Task.isCancelled, date == requestedDate else { group.cancelAll(); break }
                    hours[id] = value
                    if !isSearching { tableView.reloadData() }
                }
            }
        }
    }

    func updateSearchResults(for searchController: UISearchController) {
        searchTask?.cancel()
        let token = UUID()
        generation = token
        guard isSearching else {
            matches = []
            status.text = catalogMessage
            status.isHidden = catalogMessage == nil
            view.setNeedsLayout()
            tableView.reloadData()
            return
        }
        status.isHidden = false
        let query = (search.searchBar.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedDate = date
        matches = []
        tableView.reloadData()
        searchTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard let self, generation == token else { return }
            if searchDate != requestedDate || searchMenus.isEmpty || searchMenus.contains(where: { Date.now.timeIntervalSince($0.1.snapshot.fetchedAt) >= 900 }) {
                status.text = "Searching menus…"
                var results: [(CampusDiningLocation, CampusMenuResult)] = []
                let environment = environment
                await withTaskGroup(of: (CampusDiningLocation, CampusMenuResult?).self) { group in
                    for location in locations {
                        group.addTask { @concurrent in (location, try? await environment.menu(location, date: requestedDate, background: true)) }
                    }
                    for await (location, result) in group {
                        guard !Task.isCancelled else { group.cancelAll(); break }
                        if let result { results.append((location, result)) }
                    }
                }
                guard !Task.isCancelled, generation == token else { return }
                searchMenus = results.sorted { a, b in
                    (locations.firstIndex { $0.id == a.0.id } ?? 0) < (locations.firstIndex { $0.id == b.0.id } ?? 0)
                }
                searchDate = requestedDate
            }
            guard !Task.isCancelled, generation == token else { return }
            matches = searchMenus.flatMap { location, result in
                result.snapshot.meals.flatMap { meal in
                    meal.sections.flatMap { section in
                        section.items.compactMap { item in
                            item.displayName.localizedStandardContains(query) || section.displayName.localizedStandardContains(query) ? Match(location: location, meal: meal, item: item) : nil
                        }
                    }
                }
            }
            let published = searchMenus.filter { $0.1.snapshot.hasPublishedItems }.count
            let incomplete = locations.count - searchMenus.count + searchMenus.filter { $0.1.isStale || $0.1.availability == .partial }.count
            status.text = "\(matches.count) matches · \(published) of \(locations.count) locations have published menus." + (incomplete > 0 ? " \(incomplete) unavailable, saved, or incomplete." : "")
            tableView.reloadData()
            view.setNeedsLayout()
        }
    }

    override func numberOfSections(in tableView: UITableView) -> Int { isSearching ? 1 : groups.count + 1 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if isSearching { return matches.count }
        return section == groups.count ? 1 : groups[section].1.count
    }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        isSearching ? "Food results" : section == groups.count ? "Nearby" : groups[section].0
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "location") ?? UITableViewCell(style: .subtitle, reuseIdentifier: "location")
        var content = cell.defaultContentConfiguration()
        if isSearching {
            let match = matches[indexPath.row]
            content.text = match.item.displayName
            content.secondaryText = "\(match.location.displayName) · \(match.meal.displayName)"
        } else if indexPath.section == groups.count {
            content.text = "Nearby Restaurants"
            content.secondaryText = nil
        } else {
            let location = groups[indexPath.section].1[indexPath.row]
            content.text = location.displayName
            let value = hours[location.id]
            let isToday = date == calendarContext.localDate(containing: .now)
            content.secondaryText = isToday ? value?.currentStatus ?? (location.isRetail ? "Hours & location information" : "Menus & hours") : "Menus & hours"
        }
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if isSearching {
            let match = matches[indexPath.row]
            navigationController?.pushViewController(CampusDiningMenuController(location: match.location, environment: environment, date: date, mealID: match.meal.id, query: match.item.displayName), animated: true)
        } else if indexPath.section == groups.count {
            navigationController?.pushViewController(UIHostingController(rootView: MapLocationsView()), animated: true)
        } else {
            navigationController?.pushViewController(CampusDiningMenuController(location: groups[indexPath.section].1[indexPath.row], environment: environment, date: date), animated: true)
        }
    }
}

@MainActor final class CampusDiningMenuController: UITableViewController, UISearchResultsUpdating, UIGestureRecognizerDelegate {
    private let location: CampusDiningLocation
    private let environment: CampusDiningEnvironment
    private let hoursHeader: HeaderDatePickerView
    private var picker: UIDatePicker { hoursHeader.datePicker }
    private let mealControl = DiningMealControl()
    private var mealPan: UIPanGestureRecognizer!
    private let selectionFeedback = UISelectionFeedbackGenerator()
    private let filterButton = UIBarButtonItem(image: UIImage(systemName: "line.3.horizontal.decrease"), menu: UIMenu())
    private let status = CampusDiningUI.label()
    private var hoursDetails: String?
    private var dayHours: CampusDiningHours?
    private var locationInformation: String?
    private let header = UIStackView()
    private let search = UISearchController(searchResultsController: nil)
    private var result: CampusMenuResult?
    private var selectedMealID: String?
    private var selectedLabel: String?
    private var presentation: MenuPresentationSnapshot?
    private var dataSource: MenuPresentationTableDataSource!
    private let images = MenuTraitImageCache()
    private var loadTask: Task<Void, Never>?
    private var presentationTask: Task<Void, Never>?
    private var generation = UUID()
    private var renderGeneration = UUID()
    private var date: DateOnly { location.calendarContext.localDate(containing: picker.date) }
    private var period: MenuMealPeriod? { result?.snapshot.meals.first { $0.id == selectedMealID } }

    init(location: CampusDiningLocation, environment: CampusDiningEnvironment, date: DateOnly, mealID: String? = nil, query: String = "") {
        self.location = location
        self.environment = environment
        hoursHeader = HeaderDatePickerView(context: location.calendarContext, horizontalInset: 0)
        selectedMealID = mealID
        super.init(style: .insetGrouped)
        title = location.displayName
        picker.date = location.calendarContext.date(on: date, minutesAfterMidnight: 720) ?? .now
        search.searchBar.text = query
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        tableView.register(MenuMealItemCell.self, forCellReuseIdentifier: MenuMealItemCell.reuseID)
        dataSource = MenuPresentationTableDataSource(tableView: tableView) { [weak self] table, indexPath, id in
            guard let self, let row = presentation?.rowsByID[id], let cell = table.dequeueReusableCell(withIdentifier: MenuMealItemCell.reuseID, for: indexPath) as? MenuMealItemCell else { return UITableViewCell() }
            // Keep every disclosure on the item/detail screen; the list shows concise symbols.
            var semantics = row.semantics.filter { $0.kind != .unknown && $0.kind != .allergenWarning }
            if semantics.contains(where: { $0.kind == .vegan }) { semantics.removeAll { $0.kind == .vegetarian } }
            if row.item.detailMetadata?.allergenStatement != nil {
                semantics.append(.init(sourceText: "Allergen information", kind: .allergenWarning))
            }
            let descriptors = semantics.flatMap(\.symbolDescriptors)
            let compact = MenuPresentationRow(id: row.id, item: row.item, semantics: semantics, symbolDescriptors: descriptors)
            cell.configure(row: compact, images: descriptors.compactMap { images.image(for: $0) })
            cell.accessoryType = .disclosureIndicator
            return cell
        }
        dataSource.titleProvider = { [weak self] section in self?.presentation?.section(at: section)?.displayName }
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = "Search this menu"
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = true
        definesPresentationContext = true
        picker.addTarget(self, action: #selector(dateChanged), for: .valueChanged)
        mealControl.onSelect = { [weak self] meal in self?.selectMeal(named: meal) }
        mealControl.onShare = { [weak self] meal in self?.selectMeal(named: meal); self?.share() }
        header.addArrangedSubview(mealControl)
        mealPan = UIPanGestureRecognizer(target: self, action: #selector(handleMealPan(_:)))
        mealPan.allowedScrollTypesMask = .continuous
        mealPan.delegate = self
        tableView.panGestureRecognizer.require(toFail: mealPan)
        tableView.addGestureRecognizer(mealPan)
        header.addArrangedSubview(hoursHeader)
        hoursHeader.show(title: nil, status: "Loading hours…")
        header.addArrangedSubview(status)
        status.isHidden = true
        images.prepare(Set(MenuSourceLabelSemantic(sourceText: "Allergen information", kind: .allergenWarning).symbolDescriptors))
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(refresh), for: .valueChanged)
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(image: UIImage(systemName: "square.and.arrow.up"), style: .plain, target: self, action: #selector(share)),
            filterButton,
            UIBarButtonItem(image: UIImage(systemName: "info.circle"), style: .plain, target: self, action: #selector(showInformation))
        ]
        updateControls()
        navigationItem.rightBarButtonItems?.first?.isEnabled = false
        load()
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if isViewLoaded, loadTask == nil { load() }
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent { cancelWork() }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        CampusDiningUI.header(header, table: tableView)
    }
    func cancelWork() {
        loadTask?.cancel(); loadTask = nil
        presentationTask?.cancel()
        generation = UUID(); renderGeneration = UUID()
    }
    @objc private func dateChanged() {
        result = nil; presentation = nil
        presentationTask?.cancel(); renderGeneration = UUID()
        dataSource.applyEmpty(animatingDifferences: false)
        tableView.backgroundView = nil
        updateControls()
        navigationItem.rightBarButtonItems?.first?.isEnabled = false
        hoursDetails = nil
        dayHours = nil
        hoursHeader.show(title: nil, status: "Loading hours…")
        load()
    }
    @objc private func refresh() { load(reload: true) }
    @objc private func openSource() { UIApplication.shared.open(location.sourceURL) }
    @objc private func showInformation() {
        let controller = UIViewController()
        controller.title = location.displayName
        controller.navigationItem.largeTitleDisplayMode = .never
        let text = UITextView()
        var sections = [location.name, hoursDetails ?? "Hours unavailable"]
        if let locationInformation { sections.append(locationInformation) }
        if let result {
            sections.append("Menu updated " + result.snapshot.fetchedAt.formatted(date: .abbreviated, time: .shortened))
        }
        text.text = sections.joined(separator: "\n\n")
        controller.navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "safari"), primaryAction: UIAction { [weak self] _ in self?.openSource() })
        text.font = .systemFont(ofSize: 17)
        text.isEditable = false
        text.textContainerInset = .init(top: 20, left: 16, bottom: 20, right: 16)
        controller.view = text
        navigationController?.pushViewController(controller, animated: true)
    }

    private func load(reload: Bool = false) {
        loadTask?.cancel()
        let token = UUID(); generation = token
        let requestedDate = date
        status.text = nil
        status.isHidden = true
        if result == nil {
            var loading = UIContentUnavailableConfiguration.loading()
            loading.text = "Loading menu…"
            tableView.backgroundView = UIContentUnavailableView(configuration: loading)
        }
        loadTask = Task { [weak self] in
            guard let self else { return }
            if let saved = await environment.savedMenu(location, date: requestedDate), generation == token, !Task.isCancelled { show(saved) }
            async let hoursResult = try? environment.hours(location, date: requestedDate, reload: reload)
            async let informationResult = try? environment.information(location)
            do {
                let loaded = try await environment.menu(location, date: requestedDate, reload: reload)
                guard !Task.isCancelled, generation == token else { return }
                show(loaded)
            } catch {
                guard !Task.isCancelled, generation == token else { return }
                if result == nil {
                    dataSource.applyEmpty(animatingDifferences: false)
                    showEmpty(title: "Couldn’t load menu", message: error.localizedDescription, retry: true)
                } else {
                    status.text = "Couldn’t refresh. Showing the saved menu."
                    status.isHidden = false
                }
                updateControls()
            }
            let hours = await hoursResult
            let information = await informationResult
            guard !Task.isCancelled, generation == token else { return }
            locationInformation = information
            let hoursAreStale = hours.map { Date.now.timeIntervalSince($0.fetchedAt) >= 3_600 } ?? false
            dayHours = hours
            updateHoursHeader()
            hoursDetails = (hoursAreStale ? "Saved hours · " : "") + (hours?.summary ?? "Hours unavailable")
            refreshControl?.endRefreshing()
            view.setNeedsLayout()
        }
    }
    private func updateHoursHeader() {
        guard let hours = dayHours else {
            hoursHeader.show(title: nil, status: "Hours unavailable")
            return
        }
        let stale = Date.now.timeIntervalSince(hours.fetchedAt) >= 3_600
        let title = hours.isClosed || hours.intervals.isEmpty ? nil : hours.summary
        let detail: String
        if stale {
            detail = "Saved hours · See info"
        } else if date != location.calendarContext.localDate(containing: .now) {
            detail = hours.isClosed ? "Closed on this date" : "Location hours"
        } else if let active = (hours.carryoverIntervals + hours.intervals).first(where: { $0.start <= .now && .now < $0.end }) {
            detail = "Open · Closes " + HeaderDatePickerView.relative(active.end, to: .now)
        } else if hours.isClosed {
            detail = "Closed"
        } else if let next = hours.intervals.filter({ $0.start > .now }).min(by: { $0.start < $1.start }) {
            detail = "Opens " + HeaderDatePickerView.relative(next.start, to: .now)
        } else if !hours.intervals.isEmpty {
            detail = "Closed"
        } else {
            detail = hours.sourceText == nil ? "Hours unavailable" : "Schedule & exceptions in info"
        }
        hoursHeader.show(title: title, status: detail)
    }

    private func show(_ result: CampusMenuResult) {
        self.result = result
        if !result.snapshot.meals.contains(where: { $0.id == selectedMealID }) {
            selectedMealID = result.snapshot.meals.first(where: { !$0.sections.allSatisfy { $0.items.isEmpty } })?.id ?? result.snapshot.meals.first?.id
        }
        let updated = result.snapshot.fetchedAt.formatted(date: .abbreviated, time: .shortened)
        status.text = switch result.availability {
        case .closed: "Closed on this date."
        case .unpublished: result.message ?? "No menu has been published for this date."
        case .partial: result.message ?? "Some meal periods are unavailable."
        case .published: result.message ?? (result.isStale ? "Saved menu · Updated \(updated)" : nil)
        }
        if result.isStale, result.availability != .published { status.text = (status.text ?? "") + " Showing saved information." }
        status.isHidden = status.text == nil || !result.snapshot.hasPublishedItems
        updateControls()
        render()
        view.setNeedsLayout()
    }
    private func updateControls() {
        let meals = result?.snapshot.meals ?? []
        mealControl.configure(meals: meals.map(\.displayName), selected: period?.displayName ?? "")
        updateFilterControls()
    }

    private func updateFilterControls() {
        // Exact source labels only: no absence-based allergen or inferred dietary claims.
        let supported = Set(["vegan", "vegetarian", "meatless", "halal", "kosher", "gluten free", "gluten-free", "avoiding gluten"])
        let labels = Set((period?.sections.flatMap(\.items).flatMap(\.sourceLabels) ?? []).filter { supported.contains($0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)) }).sorted()
        if let selectedLabel, !labels.contains(selectedLabel) { self.selectedLabel = nil }
        filterButton.isEnabled = !labels.isEmpty
        filterButton.image = UIImage(systemName: selectedLabel == nil ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
        filterButton.menu = UIMenu(children: [UIAction(title: "All foods", state: selectedLabel == nil ? .on : .off) { [weak self] _ in self?.selectedLabel = nil; self?.updateFilterControls(); self?.render() }] + labels.map { label in
            UIAction(title: label, state: selectedLabel == label ? .on : .off) { [weak self] _ in self?.selectedLabel = label; self?.updateFilterControls(); self?.render() }
        })
    }
    private func selectMeal(named name: String) {
        guard let meal = result?.snapshot.meals.first(where: { $0.displayName == name }), meal.id != selectedMealID else { return }
        selectionFeedback.prepare()
        selectedMealID = meal.id
        mealControl.select(name, animated: true)
        mealControl.scrollSelectedMealIntoView(animated: true)
        // Update filters without rebuilding the selector or interrupting its animation.
        updateFilterControls()
        render()
        selectionFeedback.selectionChanged()
    }

    @objc private func handleMealPan(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .ended, let period else { return }
        let translation = gesture.translation(in: tableView)
        let velocity = gesture.velocity(in: tableView)
        let direction: CGFloat = view.effectiveUserInterfaceLayoutDirection == .rightToLeft ? -1 : 1
        if let name = DiningMealControl.mealAfterSwipe(meals: result?.snapshot.meals.map(\.displayName) ?? [], selectedMeal: period.displayName,
            translationX: translation.x * direction, translationY: translation.y, velocityX: velocity.x * direction) {
            selectMeal(named: name)
        }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === mealPan else { return true }
        let velocity = mealPan.velocity(in: tableView)
        return (result?.snapshot.meals.count ?? 0) > 1 && abs(velocity.x) > abs(velocity.y)
    }

    func updateSearchResults(for searchController: UISearchController) { render() }
    private func render() {
        presentationTask?.cancel()
        let token = UUID(); renderGeneration = token
        guard let result, let period else {
            presentation = nil; dataSource?.applyEmpty(animatingDifferences: false)
            if let result {
                showEmpty(title: result.availability == .closed ? "Closed" : "No menu published", message: result.message ?? "Choose another date to see available meals.")
            }
            navigationItem.rightBarButtonItems?.first?.isEnabled = false
            return
        }
        let label = selectedLabel
        let filtered = MenuMealPeriod(id: period.id, displayName: period.displayName, sourceOrder: period.sourceOrder, sections: period.sections.map { section in
            MenuSection(id: section.id, displayName: section.displayName, sourceOrder: section.sourceOrder, items: section.items.filter { item in label.map { item.sourceLabels.contains($0) } ?? true })
        })
        let query = search.searchBar.text ?? ""
        presentationTask = Task { [weak self] in
            do {
                let next = try await MenuPresentationSnapshot.build(sourceKey: result.snapshot.key, sourceContentHash: result.snapshot.sourceContentHash, period: filtered, filterQuery: query)
                guard let self, !Task.isCancelled, renderGeneration == token else { return }
                let previous = presentation
                presentation = next
                images.prepare(next.symbolDescriptors)
                dataSource.apply(next, replacing: previous, animatingDifferences: false)
                if next.itemIdentifiers.isEmpty {
                    if !query.isEmpty || selectedLabel != nil {
                        showEmpty(title: "No matching foods", message: "Try another search or clear the dietary filter.")
                    } else {
                        showEmpty(title: "No menu published", message: "Choose another meal or date.")
                    }
                } else { tableView.backgroundView = nil }
                navigationItem.rightBarButtonItems?.first?.isEnabled = !next.itemIdentifiers.isEmpty
            } catch { /* A superseding date, meal, or query cancels presentation work. */ }
        }
    }
    private func showEmpty(title: String, message: String, retry: Bool = false) {
        var configuration = UIContentUnavailableConfiguration.empty()
        configuration.text = title
        configuration.secondaryText = message
        configuration.image = UIImage(systemName: retry ? "wifi.exclamationmark" : "fork.knife")
        if retry {
            configuration.button = .tinted()
            configuration.button.title = "Try again"
            configuration.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.load(reload: true) }
        }
        tableView.backgroundView = UIContentUnavailableView(configuration: configuration)
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath), let item = presentation?.rowsByID[id]?.item else { return }
        navigationController?.pushViewController(CampusDiningDetailController(item: item, description: result?.descriptions[item.id], sourceURL: location.sourceURL, provider: location.id.provider), animated: true)
    }
    @objc private func share() {
        guard let presentationTask else { return }
        let token = renderGeneration
        Task { [weak self] in
            // Meal selection and filtering rebuild the visible rows asynchronously.
            await presentationTask.value
            guard let self, !presentationTask.isCancelled, renderGeneration == token else { return }
            presentShareComposer()
        }
    }

    private func presentShareComposer() {
        guard let result, let period, let presentation else { return }
        let visible = Set(presentation.rowsByID.values.map { $0.item.id })
        let filtered = MenuMealPeriod(id: period.id, displayName: period.displayName, sourceOrder: period.sourceOrder,
            sections: period.sections.compactMap { section in
                let items = section.items.filter { visible.contains($0.id) }
                return items.isEmpty ? nil : MenuSection(id: section.id, displayName: section.displayName, sourceOrder: section.sourceOrder, items: items)
            })
        let composer = MenuShareComposerViewController(
            snapshot: result.snapshot, hallName: location.name, period: filtered,
            sourceURL: location.sourceURL
        )
        let navigation = UINavigationController(rootViewController: composer)
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        present(navigation, animated: true)
    }

}

@MainActor private final class CampusDiningDetailController: UIViewController {
    private let item: DiningMenuItem
    private let itemDescription: String?
    private let sourceURL: URL
    private let provider: DiningProviderID
    init(item: DiningMenuItem, description: String?, sourceURL: URL, provider: DiningProviderID) {
        self.item = item; itemDescription = description; self.sourceURL = sourceURL; self.provider = provider
        super.init(nibName: nil, bundle: nil)
        title = item.displayName
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        navigationItem.largeTitleDisplayMode = .never
        let scroll = UIScrollView()
        let stack = UIStackView()
        stack.axis = .vertical; stack.spacing = 20
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll); scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 20), stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20), stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -20),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -40)
        ])
        let name = CampusDiningUI.label(item.displayName, size: 26); name.textColor = .label
        stack.addArrangedSubview(name)
        if let itemDescription { stack.addArrangedSubview(CampusDiningUI.label(CampusColumbiaPage.text(itemDescription), size: 16)) }
        if !item.sourceLabels.isEmpty { stack.addArrangedSubview(CampusDiningUI.label("Source labels\n" + item.sourceLabels.joined(separator: " · "), size: 16)) }
        if let metadata = item.detailMetadata {
            if !metadata.nutrition.isEmpty { stack.addArrangedSubview(NutritionFactsCardView(facts: metadata.nutrition, expanded: true)) }
            else { stack.addArrangedSubview(CampusDiningUI.label(provider == .columbia ? "Columbia does not publish structured nutrition for this menu." : "Nutrition has not been published for this item.")) }
            stack.addArrangedSubview(CampusDiningUI.label("Ingredients\n" + (metadata.ingredients.map(CampusColumbiaPage.text) ?? "Not published"), size: 16))
            stack.addArrangedSubview(CampusDiningUI.label("Allergen information\n" + (metadata.allergenStatement ?? "Not published"), size: 16))
        }
        let button = UIButton(type: .system)
        button.setTitle("View official source", for: .normal)
        button.addAction(UIAction { [weak self] _ in if let self { UIApplication.shared.open(sourceURL) } }, for: .touchUpInside)
        stack.addArrangedSubview(button)
    }
}
