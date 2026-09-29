import SwiftUI
import MapKit
import SafariServices
import UIKit

@MainActor
final class DiningHallListViewController: UITableViewController, UISearchControllerDelegate {
    private enum Section: Hashable {
        case weather
        case halls
        case otherLocations
    }

    private enum Row: Hashable {
        case weather
        case hall(PSUDiningHall)
        case psuEats
        case campusRec
        case nearbyRestaurants
        case discover
        case myMeals

        var restorationIdentifier: String? {
            switch self {
            case .hall(let hall): "hall:\(hall.rawValue)"
            case .myMeals: "myMeals"
            case .campusRec: "campusRec"
            case .nearbyRestaurants: "nearbyRestaurants"
            case .discover: "discover"
            case .weather, .psuEats: nil
            }
        }

        init?(restorationIdentifier: String) {
            switch restorationIdentifier {
            case "myMeals": self = .myMeals
            case "campusRec": self = .campusRec
            case "nearbyRestaurants": self = .nearbyRestaurants
            case "meet", "discover": self = .discover
            default:
                guard restorationIdentifier.hasPrefix("hall:"),
                      let hall = PSUDiningHall(rawValue: String(restorationIdentifier.dropFirst(5))) else { return nil }
                self = .hall(hall)
            }
        }
    }

    private static let lastDestinationKey = "psuDining.lastDestination.v1"

    private let purchaseManager: PurchaseManager
    private let mealJournal: MealJournal
    private let mealFeature: MealFeatureCoordinator
    private let environment: DiningMenuEnvironment
    private var dataSource: UITableViewDiffableDataSource<Section, Row>!
    private var loadTask: Task<Void, Never>?
    private var maintenanceTask: Task<Void, Never>?
    private var hasAppeared = false
    private var deepLinkTask: Task<Void, Never>?
    private var diningSearchResults: DiningSearchResultsViewController!
    private var diningSearchController: UISearchController!
    private var pendingSearchQuery: String?
    private var restoresSearchAfterNavigation = false
    private var selectedDestination: Row?

    private var diningSplit: DiningSplitViewController? {
        splitViewController as? DiningSplitViewController
    }

    private var detailNavigationController: UINavigationController? {
        diningSplit?.detailNavigationController
    }

    func clearDestinationSelection() {
        selectedDestination = nil
        if let selected = tableView.indexPathForSelectedRow {
            tableView.deselectRow(at: selected, animated: false)
        }
    }

    private func selectDestination(_ row: Row?) {
        clearDestinationSelection()
        selectedDestination = row
        if let identifier = row?.restorationIdentifier {
            UserDefaults.standard.set(identifier, forKey: Self.lastDestinationKey)
        }
        restoreDestinationSelection()
    }

    private func restoreDestinationSelection() {
        guard diningSplit?.isCollapsed == false, let selectedDestination,
              let indexPath = dataSource.indexPath(for: selectedDestination) else { return }
        tableView.selectRow(at: indexPath, animated: false, scrollPosition: .none)
    }

    func updateDestinationSelection() {
        if diningSplit?.isCollapsed == false {
            restoreDestinationSelection()
        } else if let selected = tableView.indexPathForSelectedRow {
            tableView.deselectRow(at: selected, animated: false)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateDestinationSelection()
    }

    func restoreLastDestination(fallbackLocation: DiningLocationID?) {
        loadViewIfNeeded()
        if let identifier = UserDefaults.standard.string(forKey: Self.lastDestinationKey),
           let row = Row(restorationIdentifier: identifier) {
            showDestination(row, animated: false)
        } else if let fallbackLocation, fallbackLocation.provider == .pennState,
                  let hall = PSUDiningHall(rawValue: fallbackLocation.rawValue) {
            showDestination(.hall(hall), animated: false)
        }
    }

    private func showDestination(_ row: Row, animated: Bool = true) {
        switch row {
        case .hall(let hall):
            showHall(hall, preferredDate: nil, preferredMeal: nil, animated: animated)
        case .myMeals:
            openMyMeals(animated: animated)
        case .campusRec:
            selectDestination(row)
            diningSplit?.showDestination(UIHostingController(rootView: ScheduleView()), animated: animated)
        case .nearbyRestaurants:
            selectDestination(row)
            diningSplit?.showDestination(UIHostingController(rootView: MapLocationsView()), animated: animated)
        case .discover:
            selectDestination(row)
            diningSplit?.showDestination(DiscoverCoordinator().makeRoot(), animated: animated)
        case .weather, .psuEats:
            break
        }
    }

    private func configureDiningSearch() {
        let results = DiningSearchResultsViewController(
            environment: environment,
            openItem: { [weak self] aggregate in self?.openSearchResult(aggregate) }
        )
        let controller = UISearchController(searchResultsController: results)
        controller.searchResultsUpdater = results
        controller.delegate = self
        controller.searchBar.placeholder = "Search dining menus"
        controller.obscuresBackgroundDuringPresentation = true
        diningSearchResults = results
        diningSearchController = controller
    }

    func willDismissSearchController(_ searchController: UISearchController) {
        diningSearchResults.stopWarmSession()
    }

    init(
        purchaseManager: PurchaseManager,
        mealJournal: MealJournal,
        environment: DiningMenuEnvironment,
        mealFeature: MealFeatureCoordinator
    ) {
        self.purchaseManager = purchaseManager
        self.mealJournal = mealJournal
        self.mealFeature = mealFeature
        self.environment = environment
        super.init(style: .plain)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    deinit {
        loadTask?.cancel()
        maintenanceTask?.cancel()
        deepLinkTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "PSU Dining"
        clearsSelectionOnViewWillAppear = false
        navigationItem.largeTitleDisplayMode = .always
        navigationController?.navigationBar.prefersLargeTitles = true
        configureDiningSearch()
        navigationItem.searchController = diningSearchController
        navigationItem.hidesSearchBarWhenScrolling = true
        updateDiningFilterButton()
        definesPresentationContext = true
        tableView.backgroundColor = .systemBackground
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 80
        tableView.sectionHeaderHeight = UITableView.automaticDimension
        tableView.estimatedSectionHeaderHeight = 32
        tableView.sectionHeaderTopPadding = 12
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(refresh), for: .valueChanged)
        configureDataSource()
        applySnapshot()
        updateWeatherHeader()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openHallNotification(_:)),
            name: .meetAndEatOpenDiningHall,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openMealRecordNotification(_:)),
            name: .meetAndEatOpenMealRecord,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(diningFilterDidChange(_:)),
            name: .diningDietaryFilterChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(openLinkNotification), name: .meetAndEatOpenLink, object: nil
        )
        loadCachedHallStates()
    }

    @objc private func openLinkNotification() {
        routePendingLink()
    }

    func routePendingLink() {
        guard isViewLoaded, let navigationController,
              let request = MeetAndEatLinkNavigation.pending,
              request.route.tab == 0 else { return }
        MeetAndEatLinkNavigation.consume(request)
        deepLinkTask?.cancel()
        let navigate = { [weak self] in
            guard let self else { return }
            self.pendingSearchQuery = nil
            self.diningSearchController.isActive = false
            navigationController.popToViewController(self, animated: false)
            switch request.route {
            case .diningHome: self.diningSplit?.showDiningHome()
            case .foodSearch(let query): self.showFoodSearch(query)
            case let .hall(rawHall, date, meal):
                guard let hall = PSUDiningHall(rawValue: rawHall) else { return }
                self.showHall(hall, preferredDate: date, preferredMeal: meal?.displayName)
            case let .dish(id, date):
                self.openLinkedDish(id, date: date)
            case .food(let reference): self.openLinkedFood(reference)
            case .cata: break
            }
        }
        let presenter: UIViewController = diningSplit ?? navigationController
        if presenter.presentedViewController != nil {
            presenter.dismiss(animated: false, completion: navigate)
        } else { navigate() }
    }

    private func showFoodSearch(_ query: String) {
        restoresSearchAfterNavigation = false
        clearDestinationSelection()
        diningSplit?.showDiningHome()
        diningSearchResults.loadViewIfNeeded()
        diningSearchResults.updateScope(
            DiningSearchScope(provider: .pennState,
                date: ProviderCalendarContexts.pennState.serviceDate(containing: .now)),
            fixedLocationOrder: PSUDiningHall.allCases.map(\.locationID))
        pendingSearchQuery = query
        activatePendingSearch()
    }

    private func activatePendingSearch() {
        guard viewIfLoaded?.window != nil, navigationController?.topViewController === self,
              let query = pendingSearchQuery else { return }
        pendingSearchQuery = nil
        diningSearchController.searchBar.text = query
        diningSearchController.isActive = true
        diningSearchResults.updateSearchResults(for: diningSearchController)
        diningSearchResults.refreshCurrentQuery()
    }

    private func openLinkedFood(_ reference: PSUFoodReference) {
        guard let hall = PSUDiningHall(rawValue: reference.hall), PSUDiningAccess.isEnabled else { return }
        let loading = UIViewController()
        loading.title = "Dining item"
        loading.view.backgroundColor = .systemBackground
        loading.contentUnavailableConfiguration = UIContentUnavailableConfiguration.loading()
        selectDestination(nil)
        diningSplit?.showDestination(loading, animated: false)
        deepLinkTask = Task { @MainActor [weak self, weak loading] in
            guard let self, let loading else { return }
            do {
                guard reference.date >= PSUServiceSelection.calendar.serviceDate(containing: .now) else {
                    throw PSUDiningActionError.foodUnavailable
                }
                let record = try await PSUDiningServices.shared.resolve(reference)
                guard !Task.isCancelled, detailNavigationController?.topViewController === loading else { return }
                let detail = MenuItemDetailViewController(item: record.item, environment: environment,
                    providerID: .pennState, sourceLocationID: hall.locationID, sourceDate: reference.date, intentFoodRecord: record,
                    openHall: { [weak self] location, date, meal in self?.showHall(location, preferredDate: date, preferredMeal: meal) },
                    mealFeature: mealFeature,
                    plateContext: PlateContext(hall: hall, date: reference.date, mealName: record.mealName))
                showHall(hall, preferredDate: reference.date, preferredMeal: record.mealName, animated: false)
                detailNavigationController?.pushViewController(detail, animated: true)
            } catch {
                guard !Task.isCancelled, detailNavigationController?.topViewController === loading else { return }
                var content = UIContentUnavailableConfiguration.empty()
                content.image = UIImage(systemName: "menucard")
                content.text = "Food unavailable"
                showHall(hall, preferredDate: reference.date, preferredMeal: nil, animated: false)
                content.secondaryText = "This food could not be loaded for \(reference.date). Go back to view the \(hall.rawValue.capitalized) menu."
                let unavailable = UIViewController()
                unavailable.title = "Dining item"
                unavailable.view.backgroundColor = .systemBackground
                unavailable.contentUnavailableConfiguration = content
                detailNavigationController?.pushViewController(unavailable, animated: false)
            }
        }
    }

    private func openLinkedDish(_ id: String, date: DateOnly?) {
        let serviceDate = date ?? ProviderCalendarContexts.pennState.serviceDate(containing: .now)
        let loading = UIViewController()
        loading.title = "Shared dining item"
        loading.view.backgroundColor = .systemBackground
        var content = UIContentUnavailableConfiguration.loading()
        content.text = "Finding the shared dish…"
        loading.contentUnavailableConfiguration = content
        selectDestination(nil)
        diningSplit?.showDestination(loading, animated: false)
        deepLinkTask = Task { @MainActor [weak self, weak loading] in
            guard let self, let loading else { return }
            let aggregate = await environment.searchAggregate(
                containing: id, provider: .pennState, on: serviceDate,
                fixedLocationOrder: PSUDiningHall.allCases.map(\.locationID)
            )
            guard !Task.isCancelled, detailNavigationController?.topViewController === loading else { return }
            if let aggregate {
                openSearchResult(aggregate)
            } else {
                var content = UIContentUnavailableConfiguration.empty()
                content.image = UIImage(systemName: "menucard")
                content.text = "Dish unavailable"
                content.secondaryText = "This dish could not be found in the published menus for \(serviceDate.description). Go back to explore another menu."
                loading.contentUnavailableConfiguration = content
            }
        }
    }

    private func updateDiningFilterButton() {
        let filter = DiningDietaryFilterStore.shared.filter(for: .pennState)
        let filterButton = UIBarButtonItem(
            image: UIImage(
                systemName: filter.isEmpty
                    ? "line.3.horizontal.decrease"
                    : "line.3.horizontal.decrease.circle.fill"
            ),
            menu: diningSearchResults.dietaryFilterMenu { changed in
                DiningDietaryFilterStore.shared.set(changed, for: .pennState)
            }
        )
        navigationItem.rightBarButtonItems = [filterButton]
    }

    @objc private func diningFilterDidChange(_ notification: Notification) {
        guard notification.object as? DiningProviderID == .pennState else { return }
        updateDiningFilterButton()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        restoreDestinationSelection()
        if diningSplit?.isCollapsed == true {
            // Returning to the list abandons any unresolved item deep link.
            deepLinkTask?.cancel()
        }
        routePendingMeal()
        routePendingLink()
        activatePendingSearch()
        Task { await mealJournal.reconcileReminders() }
        if restoresSearchAfterNavigation {
            restoresSearchAfterNavigation = false
            diningSearchController.isActive = true
            diningSearchResults.refreshCurrentQuery()
        }
        hasAppeared = true
        maintenanceTask?.cancel()
        maintenanceTask = Task { @concurrent [environment] in
            await Task.yield()
            await environment.maintainPSULanding()
        }
    }

    @objc private func applicationDidBecomeActive() {
        guard hasAppeared,
              viewIfLoaded?.window != nil,
              navigationController?.topViewController === self else { return }
        loadCachedHallStates()
    }

    @objc private func applicationDidEnterBackground() {
        maintenanceTask?.cancel()
        maintenanceTask = Task { @concurrent [environment] in
            await environment.searchIndex.handleMemoryWarning()
        }
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        maintenanceTask?.cancel()
        maintenanceTask = Task { @concurrent [environment] in
            await environment.handleSearchMemoryWarning()
        }
    }

    func updateWeatherHeader() {
        guard dataSource != nil else { return }
        let snapshotHasWeather = dataSource.snapshot().itemIdentifiers.contains(.weather)
        guard snapshotHasWeather != purchaseManager.hasUnlockedPro else { return }
        applySnapshot()
    }

    @objc private func openHallNotification(_ notification: Notification) {
        guard let locationID = notification.object as? DiningLocationID,
              locationID.provider == .pennState else { return }
        openHall(
            locationID,
            preferredDate: notification.userInfo?[DiningDeepLinkUserInfoKey.date] as? DateOnly,
            preferredMeal: notification.userInfo?[DiningDeepLinkUserInfoKey.meal] as? String
        )
    }

    @objc private func openMealRecordNotification(_ notification: Notification) {
        routePendingMeal()
    }

    private func routePendingMeal() {
        guard let navigationController, let recordID = MealReminderNavigation.take() else { return }
        deepLinkTask?.cancel()
        let open = { [weak self] in
            guard let self else { return }
            navigationController.popToViewController(self, animated: false)
            self.openMyMeals(recordID: recordID)
        }
        let presenter: UIViewController = diningSplit ?? navigationController
        if presenter.presentedViewController != nil {
            presenter.dismiss(animated: false, completion: open)
        } else {
            open()
        }
    }

    private func configureDataSource() {
        dataSource = UITableViewDiffableDataSource(tableView: tableView) {
            [weak self] tableView, indexPath, row in
            guard let self else { return nil }
            if case .weather = row {
                let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
                cell.isAccessibilityElement = false
                cell.selectionStyle = .none
                cell.separatorInset = UIEdgeInsets(
                    top: 0,
                    left: .greatestFiniteMagnitude,
                    bottom: 0,
                    right: 0
                )
                cell.contentConfiguration = UIHostingConfiguration {
                    DiningWeatherHeader(purchaseManager: purchaseManager)
                }
                .margins(.horizontal, 16)
                .margins(.vertical, 8)
                return cell
            }

            let cell = tableView.dequeueReusableCell(withIdentifier: "DiningRow")
                ?? UITableViewCell(style: .subtitle, reuseIdentifier: "DiningRow")
            cell.configurationUpdateHandler = nil
            cell.backgroundConfiguration = nil
            cell.selectionStyle = .default
            cell.accessoryType = .none
            let accessory = UIView(frame: CGRect(x: 0, y: 0, width: 36, height: 32))
            let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
            chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            chevron.tintColor = .tertiaryLabel
            chevron.frame = CGRect(x: 0, y: 8, width: 10, height: 16)
            accessory.addSubview(chevron)
            accessory.isAccessibilityElement = false
            cell.accessoryView = accessory
            cell.separatorInset = UIEdgeInsets(top: 0, left: 60, bottom: 0, right: 0)
            cell.isAccessibilityElement = true
            cell.accessibilityLabel = nil
            cell.accessibilityValue = nil
            cell.accessibilityHint = nil
            cell.accessibilityTraits = .button

            var content = cell.defaultContentConfiguration()
            content.imageProperties.maximumSize = CGSize(width: 24, height: 24)
            content.imageProperties.reservedLayoutSize = CGSize(width: 32, height: 32)
            content.textProperties.font = .preferredFont(forTextStyle: .body)
            content.textProperties.numberOfLines = 0
            content.directionalLayoutMargins = NSDirectionalEdgeInsets(
                top: 6,
                leading: 20,
                bottom: 6,
                trailing: 16
            )
            switch row {
            case .weather:
                preconditionFailure("Weather rows use their own non-reusable cell")
            case .hall(let hall):
                let hallName = hall.rawValue.capitalized
                content.text = hallName
                content.image = UIImage(named: hallName)
                content.imageProperties.maximumSize = CGSize(width: 64, height: 64)
                content.imageProperties.reservedLayoutSize = CGSize(width: 64, height: 64)
                content.textProperties.font = .preferredFont(forTextStyle: .headline)
                content.directionalLayoutMargins = NSDirectionalEdgeInsets(
                    top: 8,
                    leading: 24,
                    bottom: 8,
                    trailing: 24
                )
                cell.separatorInset = UIEdgeInsets(
                    top: 0,
                    left: .greatestFiniteMagnitude,
                    bottom: 0,
                    right: 0
                )
                cell.configurationUpdateHandler = { cell, state in
                    var background = UIBackgroundConfiguration.clear()
                    background.backgroundColor = state.isHighlighted || state.isSelected
                        ? .secondarySystemFill
                        : .secondarySystemBackground
                    background.cornerRadius = 14
                    background.backgroundInsets = NSDirectionalEdgeInsets(
                        top: 4,
                        leading: 16,
                        bottom: 4,
                        trailing: 16
                    )
                    cell.backgroundConfiguration = background
                }
                cell.accessibilityLabel = hallName
                cell.accessibilityHint = "Opens today’s menu"
                cell.accessibilityTraits = .button
            case .myMeals:
                content.text = "My Meals"
                content.image = UIImage(systemName: "fork.knife")
                content.imageProperties.tintColor = .systemIndigo
            case .psuEats:
                content.text = "PSU Eats"
                content.image = UIImage(systemName: "takeoutbag.and.cup.and.straw")
                content.imageProperties.tintColor = .systemOrange
            case .campusRec:
                content.text = "Recreation"
                content.image = UIImage(systemName: "figure.run")
                content.imageProperties.tintColor = .systemBlue
            case .nearbyRestaurants:
                content.text = "Nearby Restaurants"
                content.image = UIImage(systemName: "location.fill.viewfinder")
                content.imageProperties.tintColor = .systemGreen
            case .discover:
                content.text = "Discover"
                content.image = UIImage(systemName: "sparkles")
                content.imageProperties.tintColor = .systemTeal
            }
            cell.contentConfiguration = content
            return cell
        }
        dataSource.defaultRowAnimation = .none
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()
        if purchaseManager.hasUnlockedPro {
            snapshot.appendSections([.weather])
            snapshot.appendItems([.weather], toSection: .weather)
        }
        snapshot.appendSections([.halls, .otherLocations])
        snapshot.appendItems(PSUDiningHall.allCases.map(Row.hall), toSection: .halls)
        snapshot.appendItems(
            [.myMeals, .psuEats, .discover, .campusRec, .nearbyRestaurants],
            toSection: .otherLocations
        )
        dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
            self?.restoreDestinationSelection()
        }
    }

    @objc private func refresh() {
        loadCachedHallStates()
    }

    private func loadCachedHallStates() {
        loadTask?.cancel()
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let environment = self.environment
            let date = ProviderCalendarContexts.pennState.serviceDate(containing: .now)
            let hallOrder = PSUDiningHall.allCases.map(\.locationID)
            diningSearchResults.updateScope(
                DiningSearchScope(provider: .pennState, date: date),
                fixedLocationOrder: hallOrder
            )
            if let lastViewed = await environment.lastViewedLocationStore.locationID(),
               lastViewed.provider == .pennState {
                await environment.hydrateSearchIndexFromCache(
                    provider: .pennState,
                    on: date,
                    locationID: lastViewed
                )
            }

            guard !Task.isCancelled else { return }
            diningSearchResults.refreshCurrentQuery()
            refreshControl?.endRefreshing()
        }
    }

    override func tableView(
        _ tableView: UITableView,
        viewForHeaderInSection section: Int
    ) -> UIView? {
        let sections = dataSource.snapshot().sectionIdentifiers
        guard sections.indices.contains(section), sections[section] == .otherLocations else {
            return nil
        }
        let header = UITableViewHeaderFooterView(reuseIdentifier: nil)
        var content = UIListContentConfiguration.groupedHeader()
        content.text = "Other Locations"
        content.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: 6,
            leading: 20,
            bottom: 4,
            trailing: 16
        )
        header.contentConfiguration = content
        return header
    }

    override func tableView(
        _ tableView: UITableView,
        heightForHeaderInSection section: Int
    ) -> CGFloat {
        let sections = dataSource.snapshot().sectionIdentifiers
        return sections.indices.contains(section) && sections[section] == .otherLocations
            ? UITableView.automaticDimension
            : .leastNormalMagnitude
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard let row = dataSource.itemIdentifier(for: indexPath) else { return }
        deepLinkTask?.cancel()
        switch row {
        case .weather:
            tableView.deselectRow(at: indexPath, animated: false)
            restoreDestinationSelection()
        case .hall(let hall):
            openHall(hall.locationID)
        case .myMeals:
            openMyMeals()
        case .psuEats:
            tableView.deselectRow(at: indexPath, animated: true)
            restoreDestinationSelection()
            let url = URL(string: "https://weborder.transactcampus.com/237").unsafelyUnwrapped
            let browser = SFSafariViewController(url: url)
            browser.dismissButtonStyle = .close
            self.present(browser, animated: true)
        case .campusRec, .nearbyRestaurants, .discover:
            showDestination(row)
        }
    }

    private func openMyMeals(recordID: UUID? = nil, animated: Bool = true) {
        selectDestination(.myMeals)
        diningSplit?.showDestination(mealFeature.makeJournalViewController(recordID: recordID), animated: animated)
    }

    override func tableView(
        _ tableView: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard case .hall(let hall) = dataSource.itemIdentifier(for: indexPath) else {
            return nil
        }
        return UIContextMenuConfiguration(
            identifier: hall.rawValue as NSString,
            previewProvider: nil
        ) { [weak self] _ in
            let officialMenu = UIAction(
                title: "Official Menu",
                image: UIImage(systemName: "safari")
            ) { [weak self] _ in
                self?.openOfficialMenu(for: hall)
            }
            let maps = UIAction(
                title: "Open in Maps",
                image: UIImage(systemName: "mappin.and.ellipse")
            ) { _ in
                let mapItem = MKMapItem(
                    placemark: MKPlacemark(coordinate: hall.coordinate)
                )
                mapItem.name = "\(hall.rawValue.capitalized) Dining"
                mapItem.openInMaps()
            }
            return UIMenu(children: [officialMenu, maps])
        }
    }

    private func openOfficialMenu(for hall: PSUDiningHall) {
        let today = DateOnly(.now, in: hall.calendarContext.timeZone)
        var components = URLComponents(
            string: "https://www.absecom.psu.edu/menus/user-pages/daily-menu.cfm"
        )
        components?.queryItems = [
            URLQueryItem(
                name: "selMenuDate",
                value: String(
                    format: "%02d/%02d/%04d",
                    today.month,
                    today.day,
                    today.year
                )
            ),
            URLQueryItem(name: "selCampus", value: String(hall.menuNumber))
        ]
        guard let url = components?.url else {
            let alert = UIAlertController(
                title: "Official Menu Unavailable",
                message: "Halls couldn’t create the official menu link.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return
        }
        let browser = SFSafariViewController(url: url)
        browser.dismissButtonStyle = .close
        present(browser, animated: true)
    }

    private func openSearchResult(_ aggregate: DiningSearchAggregate) {
        guard let appearance = aggregate.representativeAppearance,
              let item = aggregate.representativeItem else { return }
        let controller = MenuItemDetailViewController(
            item: item,
            environment: environment,
            providerID: aggregate.canonicalKey.provider,
            availabilityAggregate: aggregate,
            fixedHallOrder: PSUDiningHall.allCases.map(\.locationID),
            sourceLocationID: appearance.locationID,
            sourceDate: appearance.date,
            openHall: { [weak self] locationID, date, meal in
                self?.showHall(locationID, preferredDate: date, preferredMeal: meal)
            },
            mealFeature: mealFeature
        )
        if diningSearchController.isActive {
            diningSearchController.dismiss(animated: false) { [weak self] in
                guard let self else { return }
                restoresSearchAfterNavigation = diningSplit?.isCollapsed == true
                selectDestination(nil)
                diningSplit?.showDestination(controller)
            }
        } else {
            selectDestination(nil)
            diningSplit?.showDestination(controller)
        }
    }

    private func openHall(
        _ locationID: DiningLocationID,
        preferredDate: DateOnly? = nil,
        preferredMeal: String? = nil
    ) {
        guard locationID.provider == .pennState,
              let hall = PSUDiningHall(rawValue: locationID.rawValue) else { return }
        deepLinkTask?.cancel()
        diningSearchController.isActive = false
        navigationController?.popToViewController(self, animated: false)
        showHall(hall, preferredDate: preferredDate, preferredMeal: preferredMeal)
    }

    private func showHall(
        _ locationID: DiningLocationID,
        preferredDate: DateOnly? = nil,
        preferredMeal: String? = nil
    ) {
        guard locationID.provider == .pennState,
              let hall = PSUDiningHall(rawValue: locationID.rawValue) else { return }
        showHall(hall, preferredDate: preferredDate, preferredMeal: preferredMeal)
    }

    private func showHall(
        _ hall: PSUDiningHall,
        preferredDate: DateOnly?,
        preferredMeal: String?,
        animated: Bool = true
    ) {
        maintenanceTask?.cancel()
        maintenanceTask = nil
        let controller = MealsViewController(
            diningHall: hall,
            preferredDate: preferredDate,
            preferredMeal: preferredMeal.flatMap(DiningDeepLinkMeal.init(displayName:)),
            environment: environment,
            mealFeature: mealFeature
        )
        controller.title = hall.rawValue.capitalized
        controller.navigationItem.largeTitleDisplayMode = .never
        selectDestination(.hall(hall))
        diningSplit?.showDestination(controller, animated: animated)
    }

}

@MainActor
struct DiningHallListControllerRepresentable: UIViewControllerRepresentable {
    let purchaseManager: PurchaseManager
    let mealJournal: MealJournal
    let environment: DiningMenuEnvironment

    func makeUIViewController(context: Context) -> DiningSplitViewController {
        DiningSplitViewController(
            purchaseManager: purchaseManager,
            mealJournal: mealJournal,
            environment: environment
        )
    }

    func updateUIViewController(
        _ splitController: DiningSplitViewController,
        context: Context
    ) {
        splitController.hallList.updateWeatherHeader()
        splitController.hallList.routePendingLink()
    }
}

private struct DiningWeatherHeader: View {
    @Bindable var purchaseManager: PurchaseManager

    var body: some View {
        WeatherView(
            weather: $purchaseManager.weather,
            liveWeather: $purchaseManager.liveWeather
        )
    }
}
