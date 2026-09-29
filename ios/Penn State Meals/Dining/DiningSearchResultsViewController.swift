import UIKit

@MainActor
final class DiningSearchResultsViewController: UITableViewController, UISearchResultsUpdating {
    private struct ResultID: Hashable {
        let canonicalKey: DishCanonicalKey
        let date: DateOnly
    }

    private let openItem: @MainActor (DiningSearchAggregate) -> Void
    private let environment: DiningMenuEnvironment
    private var dataSource: UITableViewDiffableDataSource<DateOnly, ResultID>!
    private var aggregates: [ResultID: DiningSearchAggregate] = [:]
    private lazy var queryCoordinator = DiningSearchQueryCoordinator(index: environment.searchIndex)
    private var lastQuery = ""
    private var scope: DiningSearchScope
    private var fixedLocationOrder: [DiningLocationID]
    private var dietaryFilter: DiningDietaryFilter
    private var warmTask: Task<Void, Never>?
    private var warmedScope: DiningSearchScope?
    private var warmControl: DiningProgressiveSearchControl?
    private var coverageByDate: [DateOnly: DiningSearchCoverage] = [:]
    private let coverageLabel = UILabel()

    init(
        environment: DiningMenuEnvironment,
        openItem: @escaping @MainActor (DiningSearchAggregate) -> Void
    ) {
        self.environment = environment
        self.openItem = openItem
        self.scope = DiningSearchScope(
            provider: .pennState,
            date: ProviderCalendarContexts.pennState.serviceDate(containing: .now)
        )
        self.fixedLocationOrder = PSUDiningHall.allCases.map(\.locationID)
        self.dietaryFilter = DiningDietaryFilterStore.shared.filter(for: .pennState)
        super.init(style: .plain)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.delegate = self
        tableView.backgroundColor = .systemBackground
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 58
        tableView.sectionHeaderTopPadding = 8
        dataSource = UITableViewDiffableDataSource(tableView: tableView) {
            [weak self] tableView, indexPath, identifier in
            guard let self, let aggregate = aggregates[identifier] else { return nil }
            let cell = tableView.dequeueReusableCell(withIdentifier: "SearchResult")
                ?? UITableViewCell(style: .subtitle, reuseIdentifier: "SearchResult")
            var content = cell.defaultContentConfiguration()
            content.text = aggregate.displayName
            let halls = aggregate.hallAvailability.map(\.hallName)
            let meals = Self.orderedUnique(
                aggregate.hallAvailability.flatMap(\.mealNames)
            )
            content.secondaryText = [
                meals.joined(separator: ", "),
                halls.joined(separator: ", ")
            ]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
            content.textProperties.font = .preferredFont(forTextStyle: .body)
            content.secondaryTextProperties.font = .preferredFont(forTextStyle: .subheadline)
            content.secondaryTextProperties.color = .secondaryLabel
            content.secondaryTextProperties.numberOfLines = 2
            content.directionalLayoutMargins = NSDirectionalEdgeInsets(
                top: 8,
                leading: 16,
                bottom: 8,
                trailing: 8
            )
            cell.contentConfiguration = content
            cell.accessoryType = .disclosureIndicator
            cell.backgroundColor = .systemBackground
            cell.accessibilityValue = content.secondaryText
            return cell
        }
        dataSource.defaultRowAnimation = .none

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(dietaryFilterDidChange(_:)),
            name: .diningDietaryFilterChanged,
            object: nil
        )

        let footer = UIView(frame: CGRect(x: 0, y: 0, width: view.bounds.width, height: 0))
        coverageLabel.font = .preferredFont(forTextStyle: .footnote)
        coverageLabel.adjustsFontForContentSizeCategory = true
        coverageLabel.textColor = .secondaryLabel
        coverageLabel.textAlignment = .center
        coverageLabel.numberOfLines = 0
        coverageLabel.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(coverageLabel)
        NSLayoutConstraint.activate([
            coverageLabel.topAnchor.constraint(equalTo: footer.topAnchor, constant: 12),
            coverageLabel.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 20),
            coverageLabel.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -20),
            coverageLabel.bottomAnchor.constraint(equalTo: footer.bottomAnchor, constant: -12)
        ])
        tableView.tableFooterView = footer
        footer.isHidden = true
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (controller: DiningSearchResultsViewController, _) in
            controller.resizeCoverageFooterIfNeeded()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        resizeCoverageFooterIfNeeded()
    }

    deinit {
        Self.stop(warmControl)
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        guard viewIfLoaded?.window == nil else { return }
        aggregates.removeAll(keepingCapacity: false)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isBeingDismissed || navigationController?.isBeingDismissed == true else { return }
        stopWarmSession()
        queryCoordinator.cancel()
        aggregates.removeAll(keepingCapacity: false)
    }

    @objc private func dietaryFilterDidChange(_ notification: Notification) {
        guard let provider = notification.object as? DiningProviderID,
              provider == scope.provider else { return }
        dietaryFilter = DiningDietaryFilterStore.shared.filter(for: provider)
        refreshCurrentQuery()
    }

    func dietaryFilterMenu(
        onChange: @escaping @MainActor (DiningDietaryFilter) -> Void
    ) -> UIMenu {
        DiningDietaryFilterMenu.make(
            filter: dietaryFilter,
            onChange: onChange
        )
    }

    func updateScope(
        _ scope: DiningSearchScope,
        fixedLocationOrder: [DiningLocationID]
    ) {
        guard self.scope != scope || self.fixedLocationOrder != fixedLocationOrder else { return }
        queryCoordinator.cancel()
        stopWarmSession()
        self.scope = scope
        self.fixedLocationOrder = fixedLocationOrder
        refreshCurrentQuery()
    }

    func refreshCurrentQuery() {
        submitCurrentQuery(debounce: .zero)
    }

    func updateSearchResults(for searchController: UISearchController) {
        lastQuery = (searchController.searchBar.text ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        submitCurrentQuery()
    }

    private func submitCurrentQuery(debounce: Duration = .milliseconds(150)) {
        guard isViewLoaded, dataSource != nil else { return }
        guard lastQuery.count >= 3 else {
            queryCoordinator.cancel()
            stopWarmSession()
            clearSearch()
            return
        }
        warmForExplicitSearchIfNeeded()
        if dataSource.snapshot().itemIdentifiers.isEmpty {
            var configuration = UIContentUnavailableConfiguration.loading()
            configuration.text = "Searching menus"
            contentUnavailableConfiguration = configuration
        }
        queryCoordinator.submit(
            query: lastQuery,
            scope: scope,
            fixedLocationOrder: fixedLocationOrder,
            dietaryFilter: dietaryFilter,
            debounce: debounce
        ) { [weak self] response in
            self?.apply(response.results)
        }
    }

    private func warmForExplicitSearchIfNeeded() {
        guard warmedScope != scope else { return }
        warmedScope = scope
        let requestedScope = scope
        let control = DiningProgressiveSearchControl()
        warmControl = control
        warmTask = Task { @MainActor [weak self, environment] in
            await environment.progressivelyWarmPSUSearch(
                control: control
            ) { [weak self] _ in
                guard let self,
                      self.scope == requestedScope,
                      self.warmControl === control else { return }
                self.refreshCurrentQuery()
            }
            guard let self,
                  self.scope == requestedScope,
                  self.warmControl === control else { return }
            self.warmTask = nil
            self.refreshCurrentQuery()
        }
    }

    func stopWarmSession() {
        Self.stop(warmControl)
        warmControl = nil
        warmTask = nil
        warmedScope = nil
    }

    nonisolated private static func stop(_ control: DiningProgressiveSearchControl?) {
        guard let control else { return }
        Task { @concurrent in
            await control.stopAfterActiveLoads()
        }
    }

    private func clearSearch() {
        aggregates.removeAll(keepingCapacity: false)
        if !dataSource.snapshot().itemIdentifiers.isEmpty {
            dataSource.apply(NSDiffableDataSourceSnapshot(), animatingDifferences: false)
        }
        var configuration = UIContentUnavailableConfiguration.search()
        configuration.text = "Search dining menus"
        configuration.secondaryText = "Find a dish across Penn State dining halls."
        contentUnavailableConfiguration = configuration
        coverageByDate.removeAll(keepingCapacity: true)
        updateCoverageFooter(text: nil)
    }

    private func apply(_ results: DiningSearchResults) {
        coverageByDate = results.coverageByDate
        var nextAggregates: [ResultID: DiningSearchAggregate] = [:]
        var snapshot = NSDiffableDataSourceSnapshot<DateOnly, ResultID>()
        var remainingResultCount = 100
        for group in results.dateGroups where !group.aggregates.isEmpty {
            guard remainingResultCount > 0 else { break }
            let visible = group.aggregates.prefix(remainingResultCount)
            guard !visible.isEmpty else { continue }
            snapshot.appendSections([group.date])
            let identifiers = visible.map { aggregate in
                let identifier = ResultID(
                    canonicalKey: aggregate.canonicalKey,
                    date: group.date
                )
                nextAggregates[identifier] = aggregate
                return identifier
            }
            snapshot.appendItems(identifiers, toSection: group.date)
            remainingResultCount -= identifiers.count
        }
        let previous = dataSource.snapshot()
        let previousIDs = Set(previous.itemIdentifiers)
        let changedRetainedIDs = snapshot.itemIdentifiers.filter { identifier in
            previousIDs.contains(identifier)
                && aggregates[identifier] != nextAggregates[identifier]
        }
        if !changedRetainedIDs.isEmpty {
            snapshot.reconfigureItems(changedRetainedIDs)
        }
        let contentChanged = aggregates != nextAggregates
            || previous.sectionIdentifiers != snapshot.sectionIdentifiers
            || previous.itemIdentifiers != snapshot.itemIdentifiers
        if contentChanged {
            aggregates = nextAggregates
            dataSource.apply(snapshot, animatingDifferences: false)
        }

        if snapshot.itemIdentifiers.isEmpty {
            var configuration: UIContentUnavailableConfiguration
            if results.coverageByDate.values.contains(where: { $0.completeness == .loading }) {
                configuration = .loading()
                configuration.text = "Checking dining halls"
            } else {
                configuration = .search()
                configuration.text = "No menu matches"
            }
            configuration.secondaryText = coverageText(for: results)
            contentUnavailableConfiguration = configuration
        } else {
            contentUnavailableConfiguration = nil
        }
        let footerText = results.coverageByDate.values.allSatisfy {
            $0.completeness == .complete
        }
            ? nil
            : coverageText(for: results)
        updateCoverageFooter(
            text: snapshot.itemIdentifiers.isEmpty ? nil : footerText
        )
    }

    private func updateCoverageFooter(text: String?) {
        guard let footer = tableView.tableFooterView else { return }
        coverageLabel.text = text
        footer.isHidden = text == nil
        resizeCoverageFooterIfNeeded()
    }

    private func resizeCoverageFooterIfNeeded() {
        guard let footer = tableView.tableFooterView else { return }
        let width = tableView.bounds.width
        guard width > 0 else { return }
        let targetSize = CGSize(
            width: width,
            height: coverageLabel.text == nil ? 0 : footer.systemLayoutSizeFitting(
                CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            ).height
        )
        guard abs(footer.frame.width - targetSize.width) > 0.5
                || abs(footer.frame.height - targetSize.height) > 0.5 else { return }
        footer.frame.size = targetSize
        tableView.tableFooterView = footer
    }

    private func coverageText(for results: DiningSearchResults) -> String? {
        let coverages = Array(results.coverageByDate.values)
        let indexed = coverages.reduce(0) { $0 + $1.indexedLocationCount }
        let expected = coverages.reduce(0) { $0 + $1.expectedLocationCount }
        let failures = coverages.reduce(0) { $0 + $1.failures.count }
        if coverages.contains(where: { $0.completeness == .loading }) {
            return "Checking \(indexed) of \(expected) hall menus…"
        }
        if failures > 0 {
            return "Partial results · \(failures) hall menus unavailable"
        }
        return coverages.contains { $0.completeness != .complete }
            ? "Partial results"
            : nil
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }

    override func tableView(
        _ tableView: UITableView,
        viewForHeaderInSection section: Int
    ) -> UIView? {
        let sections = dataSource.snapshot().sectionIdentifiers
        guard sections.indices.contains(section) else { return nil }
        let header = UITableViewHeaderFooterView(reuseIdentifier: nil)
        var content = UIListContentConfiguration.groupedHeader()
        content.text = Self.sectionTitle(
            for: sections[section],
            provider: scope.provider
        )
        if let coverage = coverageByDate[sections[section]],
           coverage.completeness == .loading {
            content.secondaryText =
                "Checking \(coverage.indexedLocationCount) of \(coverage.expectedLocationCount)…"
            content.secondaryTextProperties.color = .tertiaryLabel
        } else if let coverage = coverageByDate[sections[section]],
                  !coverage.failures.isEmpty {
            content.secondaryText = "\(coverage.failures.count) hall menus unavailable"
            content.secondaryTextProperties.color = .tertiaryLabel
        }
        content.textProperties.font = .preferredFont(forTextStyle: .subheadline)
        content.textProperties.color = .secondaryLabel
        header.contentConfiguration = content
        return header
    }

    private static func sectionTitle(
        for date: DateOnly,
        provider: DiningProviderID
    ) -> String {
        let context = try? ProviderCalendarContexts.context(for: provider)
        let today = context?.serviceDate(containing: .now)
        if date == today { return "Today" }
        guard let timeZone = context?.timeZone,
              let represented = date.date(in: timeZone) else {
            return date.description
        }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = .autoupdatingCurrent
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEEE MMM d")
        return formatter.string(from: represented)
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let identifier = dataSource.itemIdentifier(for: indexPath),
              let aggregate = aggregates[identifier] else { return }
        openItem(aggregate)
    }

}
