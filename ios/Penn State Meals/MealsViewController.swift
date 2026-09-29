//
//  MealsViewController.swift
//  Penn State Meals
//
//  Created by Ryan Nair on 5/19/24.
//

import AppIntents
import UIKit
import SafariServices
import FirebaseAnalytics
import FirebaseCore

@MainActor
final class MealsViewController: UIViewController, UITableViewDelegate, UISearchResultsUpdating, UIGestureRecognizerDelegate {
    private enum LoadPresentation: Equatable {
        case automatic
        case refreshControl
        case background
    }

    private enum ViewState: Equatable {
        case loading
        case content
        case empty
        case error(String)
    }

    private enum PresentationReason: Equatable {
        case initial
        case sourceRefresh
        case searchChanged
        case dietaryFilterChanged
        case mealChanged
    }

    private var menuSnapshot: MenuDaySnapshot?
    private var dayHours: DayHours?
    private var stationHours: [String: DayHours] = [:]
    private var loadTask: Task<Void, Never>?
    private var presentationBuildTask: Task<Void, Never>?
    private var presentationSnapshot: MenuPresentationSnapshot?
    private var pendingPresentationKey: MenuPresentationSnapshot.StateKey?
    private var presentationGeneration: UInt = 0
    private var selectedMeal = ""
    private var mealSelectionGeneration: UInt64 = 0
    private var activeQuery: DiningQuery
    private let diningHall: PSUDiningHall
    private let environment: DiningMenuEnvironment
    private let headerDatePickerView: HeaderDatePickerView
    private let headerContainer = UIView()
    private let tableView: UITableView
    private var dataSource: MenuPresentationTableDataSource!
    private let traitImageCache = MenuTraitImageCache()
    private let refreshControl = UIRefreshControl()
    private let menuLoadingIndicator = UIActivityIndicatorView(style: .large)
    private let searchController = UISearchController(searchResultsController: nil)
    private var dietaryFilter: DiningDietaryFilter
    private var filterButton: UIBarButtonItem?
    private let mealControlContainer = DiningMealControl()
    private var mealControlHeight: CGFloat = 0
    private var viewState = ViewState.loading {
        didSet {
            guard viewState != oldValue else { return }
            setNeedsUpdateContentUnavailableConfiguration()
        }
    }
    private var hasAppeared = false
    private var lastObservedCurrentDay: DateOnly
    private var isLoading = false
    private var loadGeneration: UInt = 0
    private var shareButton: UIBarButtonItem?
    private var mealPanGesture: UIPanGestureRecognizer!
    private var feedback = UISelectionFeedbackGenerator()
    private var didScheduleTomorrowPrefetch = false
    private var needsActivationRefresh = false
    private let mealFeature: MealFeatureCoordinator?
    private let editingPlate: PlateDraft?
    private let plateDone: (() -> Void)?
    private var startsPlate: Bool
    private var plateButton: UIButton?

    private var plateContext: PlateContext? {
        guard !selectedMeal.isEmpty else { return nil }
        return PlateContext(hall: diningHall, date: activeQuery.localDate, mealName: selectedMeal)
    }
    private var selectedPlate: PlateDraft? {
        guard mealFeature?.purchaseManager.hasUnlockedPro == true else { return nil }
        return editingPlate ?? mealFeature?.draft
    }

    init(
        diningHall: PSUDiningHall,
        preferredDate: DateOnly? = nil,
        preferredMeal: DiningDeepLinkMeal? = nil,
        environment: DiningMenuEnvironment,
        mealFeature: MealFeatureCoordinator? = nil,
        startsPlate: Bool = false,
        editingPlate: PlateDraft? = nil,
        plateDone: (() -> Void)? = nil
    ) {
        self.diningHall = diningHall
        self.environment = environment
        self.mealFeature = mealFeature
        self.startsPlate = startsPlate
        self.editingPlate = editingPlate
        self.plateDone = plateDone
        self.dietaryFilter = DiningDietaryFilterStore.shared.filter(for: diningHall.providerID)
        let headerDatePickerView = HeaderDatePickerView(context: diningHall.calendarContext)
        self.headerDatePickerView = headerDatePickerView
        self.lastObservedCurrentDay = DateOnly(.now, in: diningHall.calendarContext.timeZone)
        let initialDate = Self.clampedInitialDate(
            preferredDate?.date(in: diningHall.calendarContext.timeZone) ?? .now,
            minimum: headerDatePickerView.datePicker.minimumDate,
            maximum: headerDatePickerView.datePicker.maximumDate
        )
        let initialLocalDate = diningHall.calendarContext.localDate(containing: initialDate)
        let preferredPeriodID = preferredMeal.map {
            DiningServicePeriodNormalizer.normalize($0.displayName).id
        }
        self.activeQuery = DiningQuery(
            hall: diningHall,
            localDate: initialLocalDate,
            servicePeriodID: preferredPeriodID
        )
        self.tableView = UITableView(frame: .zero, style: .plain)
        
        super.init(nibName: nil, bundle: nil)
        self.view.backgroundColor = .systemBackground
        self.headerDatePickerView.datePicker.date = initialDate
        
        self.headerDatePickerView.datePicker.addTarget(self, action: #selector(remakeView), for: .valueChanged)
        let activity = NSUserActivity(activityType: "com.ryannair05.pennstatemeals.view-hall")
        activity.title = "\(diningHall.rawValue.capitalized) Dining Hall"
        // Core Spotlight owns the single searchable hall entry and university gating.
        activity.isEligibleForSearch = false
        // Exact dates belong to Handoff, not recurring menu suggestions.
        activity.isEligibleForPrediction = false
        activity.isEligibleForHandoff = true
        activity.requiredUserInfoKeys = [
            DiningDeepLinkUserInfoKey.provider,
            DiningDeepLinkUserInfoKey.hall
        ]
        var activityUserInfo = [
            DiningDeepLinkUserInfoKey.provider: diningHall.providerID.rawValue,
            DiningDeepLinkUserInfoKey.hall: diningHall.rawValue,
            DiningDeepLinkUserInfoKey.date: initialLocalDate.description
        ]
        if let preferredMeal {
            activityUserInfo[DiningDeepLinkUserInfoKey.meal] = preferredMeal.rawValue
        }
        activity.userInfo = activityUserInfo
        activity.persistentIdentifier = SpotlightStableIdentifier.diningLocation(
            diningHall.locationID
        )
        activity.targetContentIdentifier = activity.persistentIdentifier
        activity.webpageURL = MeetAndEatURLFactory.staticFallback(
            kind: "hall",
            id: "\(diningHall.providerID.rawValue):\(diningHall.rawValue)",
            date: activityUserInfo[DiningDeepLinkUserInfoKey.date],
            meal: preferredMeal?.rawValue
        )
        if FirebaseApp.app() != nil {
            Analytics.logEvent(AnalyticsEventScreenView, parameters: [AnalyticsParameterScreenClass: "MealsViewController"])
        }
        self.userActivity = activity
    }

    required init?(coder: NSCoder) {
        return nil
    }

    static func clampedInitialDate(
        _ requested: Date,
        minimum: Date?,
        maximum: Date?
    ) -> Date {
        if let minimum, requested < minimum { return minimum }
        if let maximum, requested > maximum { return maximum }
        return requested
    }

    static func serviceDayToLoadAfterActivation(
        selectedDay: DateOnly,
        lastObservedCurrentDay: DateOnly,
        currentDay: DateOnly
    ) -> DateOnly? {
        if selectedDay == lastObservedCurrentDay || selectedDay == currentDay {
            return currentDay
        }
        return nil
    }

    deinit {
        loadTask?.cancel()
        presentationBuildTask?.cancel()
    }

    override func updateContentUnavailableConfiguration(
        using state: UIContentUnavailableConfigurationState
    ) {
        super.updateContentUnavailableConfiguration(using: state)

        switch viewState {
        case .loading:
            var configuration = UIContentUnavailableConfiguration.loading()
            configuration.text = "Loading Menu…"
            contentUnavailableConfiguration = configuration
        case .content:
            let normalizedSearchText = DiningTextNormalizer.foldedWords(state.searchText ?? "")
            let isCompletedEmptySearch = !normalizedSearchText.isEmpty
                && presentationSnapshot?.key.normalizedFilter == normalizedSearchText
                && presentationSnapshot?.itemIdentifiers.isEmpty == true
            if isCompletedEmptySearch {
                var configuration = UIContentUnavailableConfiguration.search()
                configuration.text = "No Menu Items Found"
                configuration.secondaryText = "Try a different search term."
                contentUnavailableConfiguration = configuration
            } else {
                contentUnavailableConfiguration = nil
            }
        case .empty:
            var configuration = UIContentUnavailableConfiguration.empty()
            configuration.text = "No Menu Published"
            configuration.secondaryText = if let period = activeQuery.servicePeriodID {
                "No \(period.rawValue.replacingOccurrences(of: "-", with: " ")) menu is published for this date. Choose another meal or date."
            } else {
                "This dining hall hasn’t published items for this date."
            }
            configuration.image = UIImage(systemName: "fork.knife")
            contentUnavailableConfiguration = configuration
        case .error(let message):
            var configuration = UIContentUnavailableConfiguration.empty()
            configuration.text = "Couldn’t Load Menu"
            configuration.secondaryText = message
            configuration.image = UIImage(systemName: "wifi.exclamationmark")
            configuration.button = .tinted()
            configuration.button.title = "Try Again"
            configuration.buttonProperties.primaryAction = UIAction { [weak self] _ in
                self?.remakeView()
            }
            contentUnavailableConfiguration = configuration
        }
    }

    private func render(
        _ snapshot: MenuDaySnapshot,
        query: DiningQuery,
        dayHours resolvedHours: DayHours?,
        isComplete: Bool
    ) async {
        guard !Task.isCancelled, snapshot.key == query.menuDayKey else { return }
        let resolvedStations = await environment.psuHours.stationHours(for: diningHall, on: query.localDate)
        guard !Task.isCancelled, snapshot.key == query.menuDayKey else { return }
        stationHours = resolvedStations
        let evaluationDate = Date.now

        menuSnapshot = snapshot
        dayHours = resolvedHours
        activeQuery = query

        let meals = mealNames
        if let requestedPeriodID = query.servicePeriodID {
            selectedMeal = meals.first {
                DiningServicePeriodNormalizer.normalize($0).id == requestedPeriodID
            } ?? ""
        }
        let hasPublishedItems = snapshot.hasPublishedItems
        if !hasPublishedItems {
            selectedMeal = ""
        } else if query.servicePeriodID == nil, !meals.contains(selectedMeal) {
            let today = diningHall.calendarContext.serviceDate(containing: .now)
            let autoSelectableMeals = meals.filter { DiningServicePeriodNormalizer.normalize($0).id != .lateNight }
            let fallbackMeal = if query.localDate == today {
                PSUServiceSelection.meal(in: snapshot, preference: "automatic", hours: dayHours, now: evaluationDate)?.displayName ?? autoSelectableMeals.last
            } else {
                autoSelectableMeals.first
            }
            selectedMeal = fallbackMeal ?? ""
        }
        let renderedQuery = query.selecting(servicePeriodID: selectedMeal.isEmpty
            ? query.servicePeriodID
            : DiningServicePeriodNormalizer.normalize(selectedMeal).id)
        activeQuery = renderedQuery
        updatePlateControls()
        headerDatePickerView.remakeView(
            query: renderedQuery,
            selectedMeal: selectedMeal,
            dayHours: dayHours,
            hasPublishedItems: snapshot.hasPublishedItems
        )

        rebuildMealButtons()
        schedulePresentationRebuild(
            reason: presentationSnapshot == nil ? .initial : .sourceRefresh
        )
        shareButton?.isEnabled = isComplete && hasPublishedItems && selectedPeriod != nil
        updateUserActivityContext()

        if hasPublishedItems && !selectedMeal.isEmpty {
            viewState = .content
        } else {
            viewState = .empty
        }
        if isComplete {
            await environment.recordSuccessfullyDisplayed(snapshot)
        }
    }

    private func rebuildMealButtons() {
        let meals = menuSnapshot?.hasPublishedItems == true ? mealNames : []
        mealControlContainer.configure(meals: meals, selected: selectedMeal, enabled: editingPlate == nil)
        let height: CGFloat = meals.count > 1 ? 50 : 0
        if mealControlHeight != height {
            mealControlHeight = height
            mealControlContainer.frame.size.height = height
            view.setNeedsLayout()
        }
    }

    private func clearMenuForUnavailableState() {
        menuSnapshot = nil
        dayHours = nil
        selectedMeal = ""
        headerDatePickerView.show(title: nil, status: "No menu published")
        shareButton?.isEnabled = false
        rebuildMealButtons()
        clearPresentation()
        viewState = .error("Check your connection and try again.")
    }

    /// Captures all derived row state exactly once for each source, meal, or filter mutation.
    /// The immutable input values cross to the concurrent builder; UIKit state never does.
    private func schedulePresentationRebuild(reason: PresentationReason) {
        guard let source = menuSnapshot,
              let period = selectedPeriod else {
            clearPresentation()
            return
        }

        let sourceContentHash = DiningContentHasher.semanticFingerprint(for: source)
        let filterQuery = searchController.searchBar.text ?? ""
        let targetKey = MenuPresentationSnapshot.stateKey(
            sourceKey: source.key,
            sourceContentHash: sourceContentHash,
            mealID: period.id,
            filterQuery: filterQuery,
            dietaryFilter: dietaryFilter
        )
        if presentationSnapshot?.key == targetKey {
            presentationGeneration &+= 1
            presentationBuildTask?.cancel()
            presentationBuildTask = nil
            pendingPresentationKey = nil
            return
        }
        guard pendingPresentationKey != targetKey else { return }

        presentationGeneration &+= 1
        let generation = presentationGeneration
        presentationBuildTask?.cancel()
        pendingPresentationKey = targetKey
        let filter = dietaryFilter
        presentationBuildTask = Task { @MainActor [weak self] in
            let built: MenuPresentationSnapshot
            do {
                built = try await MenuPresentationSnapshot.build(
                    sourceKey: source.key,
                    sourceContentHash: sourceContentHash,
                    period: period,
                    filterQuery: filterQuery,
                    dietaryFilter: filter
                )
            } catch is CancellationError {
                return
            } catch {
                assertionFailure("Unexpected presentation build error: \(error)")
                return
            }
            guard let self,
                  !Task.isCancelled,
                  generation == presentationGeneration else {
                return
            }
            pendingPresentationKey = nil
            applyPresentation(built, reason: reason)
        }
    }

    private func clearPresentation() {
        presentationGeneration &+= 1
        presentationBuildTask?.cancel()
        presentationBuildTask = nil
        pendingPresentationKey = nil
        applyEmptyPresentation()
    }

    private func applyEmptyPresentation() {
        menuLoadingIndicator.stopAnimating()
        presentationSnapshot = nil
        setNeedsUpdateContentUnavailableConfiguration()
        guard dataSource != nil else { return }
        dataSource.applyEmpty(animatingDifferences: false)
    }

    private func applyPresentation(
        _ presentation: MenuPresentationSnapshot,
        reason: PresentationReason
    ) {
        traitImageCache.prepare(presentation.symbolDescriptors)

        let previousPresentation = presentationSnapshot
        presentationSnapshot = presentation
        menuLoadingIndicator.stopAnimating()
        updateFilterMenu()
        setNeedsUpdateContentUnavailableConfiguration()

        let canAnimate = viewIfLoaded?.window != nil
            && !UIAccessibility.isReduceMotionEnabled
        let scrollOffset = tableView.contentOffset.y
        let completion = { [weak self] in
            guard let self,
                  presentationSnapshot?.key == presentation.key else { return }
            tableView.layoutIfNeeded()
            preserveScrollPosition(scrollOffset)
            scheduleTomorrowPrefetchIfNeeded()
        }

        switch reason {
        case .sourceRefresh, .searchChanged, .dietaryFilterChanged:
            // Diffable owns the animated row/section batch updates across dates and filters.
            dataSource.apply(
                presentation,
                replacing: previousPresentation,
                animatingDifferences: canAnimate,
                completion: completion
            )
        case .initial, .mealChanged:
            dataSource.apply(
                presentation,
                replacing: previousPresentation,
                animatingDifferences: false,
                reloadData: true,
                completion: completion
            )
        }
    }

    private func preserveScrollPosition(_ targetOffset: CGFloat) {
        // Share the current position across menus; only clamp if the new menu is shorter.
        let minimumOffset = -tableView.adjustedContentInset.top
        let maximumOffset = max(
            minimumOffset,
            tableView.contentSize.height - tableView.bounds.height
                + tableView.adjustedContentInset.bottom
        )
        tableView.setContentOffset(
            CGPoint(
                x: tableView.contentOffset.x,
                y: min(max(targetOffset, minimumOffset), maximumOffset)
            ),
            animated: false
        )
    }

    private func loadAndRender(
        query: DiningQuery,
        forceReload: Bool,
        presentation: LoadPresentation
    ) async {
        var renderedCachedValue = false
        let selectionGeneration = mealSelectionGeneration
        let psuHours = environment.psuHours
        let hoursTask = Task { @concurrent in
            await psuHours.hours(
                for: query.locationID,
                on: query.localDate,
                policy: .revalidateIfNeeded
            )
        }
        defer { hoursTask.cancel() }

        if !forceReload,
           let cached = try? await environment.menu(for: diningHall, query: query, policy: .cacheOnly) {
            guard !Task.isCancelled else { return }
            await render(
                cached,
                query: query,
                dayHours: await psuHours.hours(for: query.locationID, on: query.localDate, policy: .cacheOnly),
                isComplete: true
            )
            guard !Task.isCancelled else { return }
            renderedCachedValue = true
        }

        guard !Task.isCancelled else { return }
        if !renderedCachedValue,
           presentation == .automatic,
           menuSnapshot != nil,
           menuSnapshot?.key != query.menuDayKey {
            menuLoadingIndicator.startAnimating()
        }

        do {
            // Render the complete day so the selected meal and picker arrive together.
            // Hours load concurrently with the menu, but selection waits for both.
            let result = try await environment.menu(
                for: diningHall,
                query: query,
                policy: forceReload ? .reloadDiscardingCache : .revalidateIfStale
            )
            let resolvedHours = await hoursTask.value
            try Task.checkCancellation()
            if query.servicePeriodID == nil, selectionGeneration == mealSelectionGeneration {
                selectedMeal = "" // Re-evaluate automatic selection when the real hours arrive.
            }
            await render(
                result,
                query: selectionGeneration == mealSelectionGeneration ? query : activeQuery,
                dayHours: resolvedHours,
                isComplete: true
            )
        } catch {
            guard !Task.isCancelled else { return }
            let canRetainDisplayedMenu = menuSnapshot?.key == query.menuDayKey
            if !renderedCachedValue, !canRetainDisplayedMenu {
                clearMenuForUnavailableState()
            }
        }
    }


    private func startMenuLoad(
        query: DiningQuery,
        forceReload: Bool,
        presentation: LoadPresentation
    ) {
        loadTask?.cancel()
        presentationGeneration &+= 1
        presentationBuildTask?.cancel()
        presentationBuildTask = nil
        pendingPresentationKey = nil
        menuLoadingIndicator.stopAnimating()
        loadGeneration &+= 1
        let generation = loadGeneration
        isLoading = true

        if presentation == .automatic,
           menuSnapshot == nil {
            viewState = .loading
        }

        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await loadAndRender(
                query: query,
                forceReload: forceReload,
                presentation: presentation
            )
            guard generation == loadGeneration else { return }

            loadTask = nil
            isLoading = false
            if pendingPresentationKey == nil {
                menuLoadingIndicator.stopAnimating()
            }
            if presentation == .refreshControl {
                refreshControl.endRefreshing()
            }
            scheduleTomorrowPrefetchIfNeeded()
        }
    }

    private func cancelMenuLoad() {
        loadGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
        menuLoadingIndicator.stopAnimating()
        refreshControl.endRefreshing()
    }

    @objc func remakeView() {
        self.presentedViewController?.dismiss(animated: false)
        let selectedDate = diningHall.calendarContext.localDate(
            containing: headerDatePickerView.datePicker.date
        )
        guard let query = try? activeQuery.selecting(date: selectedDate, relativeTo: .now) else {
            return
        }
        activeQuery = query
        startMenuLoad(query: query, forceReload: false, presentation: .automatic)
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(dietaryFilterDidChange(_:)),
            name: .diningDietaryFilterChanged,
            object: nil
        )

        setupMealControl()
        setupTableView()
        setupSearch()
        let shareButton = UIBarButtonItem(
            barButtonSystemItem: .action,
            target: self,
            action: #selector(shareCurrentMeal)
        )
        shareButton.isEnabled = false
        self.shareButton = shareButton
        let filterButton = UIBarButtonItem(
            image: UIImage(systemName: "line.3.horizontal.decrease"),
            menu: UIMenu()
        )
        self.filterButton = filterButton
        if mealFeature != nil {
            navigationItem.rightBarButtonItems = [shareButton, filterButton]
            NotificationCenter.default.addObserver(self, selector: #selector(plateChanged), name: .mealPlateDidChange, object: mealFeature)
            var plateConfiguration = UIButton.Configuration.filled()
            plateConfiguration.image = UIImage(systemName: "fork.knife")
            plateConfiguration.imagePadding = 8
            plateConfiguration.cornerStyle = .capsule
            let button = UIButton(configuration: plateConfiguration)
            button.addTarget(self, action: #selector(reviewPlate), for: .touchUpInside)
            button.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(button)
            NSLayoutConstraint.activate([
                button.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
                button.widthAnchor.constraint(greaterThanOrEqualToConstant: 72),
                button.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
                button.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
                button.heightAnchor.constraint(greaterThanOrEqualToConstant: 48)
            ])
            plateButton = button
            updatePlateControls()
        } else {
            navigationItem.rightBarButtonItems = [shareButton, filterButton]
        }
        if editingPlate != nil { headerDatePickerView.datePicker.isEnabled = false }
        updateFilterMenu()
        
        startMenuLoad(
            query: activeQuery,
            forceReload: false,
            presentation: .automatic
        )
        
        if #available(iOS 17.5, *) {
            feedback = UISelectionFeedbackGenerator(view: view)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = tableView.bounds.width
        guard width > 0 else { return }

        let dateHeaderHeight: CGFloat = 60
        let headerHeight = mealControlHeight + dateHeaderHeight
        let headerSize = CGSize(width: width, height: headerHeight)
        let needsHeaderAssignment = tableView.tableHeaderView !== headerContainer
            || headerContainer.frame.size != headerSize

        headerContainer.frame = CGRect(origin: .zero, size: headerSize)
        if needsHeaderAssignment {
            tableView.tableHeaderView = headerContainer
        }
        // UIKit insets the table rows automatically. Its custom header needs to
        // respect the same visible area without insetting the entire table again.
        let safeFrame = headerContainer.convert(view.safeAreaLayoutGuide.layoutFrame, from: view)
        let contentMinX = max(headerContainer.bounds.minX, safeFrame.minX)
        let contentMaxX = min(headerContainer.bounds.maxX, safeFrame.maxX)
        let contentWidth = max(0, contentMaxX - contentMinX)
        mealControlContainer.frame = CGRect(
            x: contentMinX,
            y: 0,
            width: contentWidth,
            height: mealControlHeight
        )
        if headerDatePickerView.superview == nil {
            headerContainer.addSubview(headerDatePickerView)
        }
        headerDatePickerView.frame = CGRect(
            x: contentMinX,
            y: mealControlHeight,
            width: contentWidth,
            height: dateHeaderHeight
        )
        headerContainer.layoutIfNeeded()
        mealControlContainer.layoutIfNeeded()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        hasAppeared = true
        updateUserActivityContext()
        userActivity?.becomeCurrent()
        plateChanged()
        scheduleTomorrowPrefetchIfNeeded()
        guard needsActivationRefresh else { return }
        needsActivationRefresh = false
        refreshVisibleMenuAfterActivation()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        userActivity?.resignCurrent()
        menuPredictionActivity?.resignCurrent()
        let isLeavingMenu = isMovingFromParent
            || isBeingDismissed
            || navigationController?.isBeingDismissed == true
        guard isLeavingMenu else { return }
        cancelMenuLoad()
        traitImageCache.removeAll()
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        guard viewIfLoaded?.window == nil else { return }
        traitImageCache.removeAll()
    }

    @objc private func applicationDidBecomeActive() {
        guard hasAppeared else { return }
        guard navigationController?.topViewController === self else {
            needsActivationRefresh = true
            return
        }
        needsActivationRefresh = false
        refreshVisibleMenuAfterActivation()
    }

    @objc private func dietaryFilterDidChange(_ notification: Notification) {
        guard let provider = notification.object as? DiningProviderID,
              provider == diningHall.providerID else { return }
        let changed = DiningDietaryFilterStore.shared.filter(for: provider)
        guard changed != dietaryFilter else { return }
        dietaryFilter = changed
        updateFilterMenu()
        schedulePresentationRebuild(reason: .dietaryFilterChanged)
    }

    private func updateFilterMenu() {
        guard let filterButton else { return }
        filterButton.image = UIImage(
            systemName: dietaryFilter.isEmpty
                ? "line.3.horizontal.decrease"
                : "line.3.horizontal.decrease.circle.fill"
        )
        let dietaryMenu = DiningDietaryFilterMenu.make(
            filter: dietaryFilter
        ) { [weak self] filter in
            guard let self else { return }
            DiningDietaryFilterStore.shared.set(filter, for: diningHall.providerID)
        }
        var children: [UIMenuElement] = dietaryMenu.children
        if let mealFeature {
            let hasPlate = selectedPlate?.context == plateContext && selectedPlate != nil
            children.append(UIMenu(options: .displayInline, children: [
                UIAction(title: hasPlate ? "View Plate" : "Build Plate", image: UIImage(systemName: "fork.knife"),
                         attributes: plateContext == nil ? .disabled : []) { [weak self] _ in
                    guard let self else { return }
                    if hasPlate { self.reviewPlate() }
                    else if let context = self.plateContext { mealFeature.start(context: context, from: self) }
                },
                UIAction(title: "My Meals", image: UIImage(systemName: "clock.arrow.circlepath")) { _ in mealFeature.openJournal() }
            ]))
        }
        filterButton.menu = UIMenu(children: children)
    }

    private func refreshVisibleMenuAfterActivation() {
        guard viewIfLoaded?.window != nil else { return }
        let selectedDay = activeQuery.localDate
        let currentDay = diningHall.calendarContext.serviceDate(containing: .now)
        let serviceDay = Self.serviceDayToLoadAfterActivation(
            selectedDay: selectedDay,
            lastObservedCurrentDay: lastObservedCurrentDay,
            currentDay: currentDay
        )
        lastObservedCurrentDay = currentDay
        guard let serviceDay else { return }

        let crossedServiceDay = serviceDay != selectedDay
        guard crossedServiceDay || !isLoading else { return }
        if crossedServiceDay {
            headerDatePickerView.datePicker.date = .now
            guard let currentQuery = try? activeQuery.selecting(
                date: currentDay,
                relativeTo: .now
            ) else { return }
            activeQuery = currentQuery
        }
        let query = activeQuery

        startMenuLoad(
            query: query,
            forceReload: false,
            presentation: crossedServiceDay ? .automatic : .background
        )
    }

    private func setupTableView() {
        view.addSubview(tableView)
        menuLoadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        menuLoadingIndicator.hidesWhenStopped = true
        menuLoadingIndicator.accessibilityLabel = "Loading Menu"
        menuLoadingIndicator.backgroundColor = .systemBackground
        menuLoadingIndicator.layer.cornerRadius = 12
        view.addSubview(menuLoadingIndicator)

        tableView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            menuLoadingIndicator.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            menuLoadingIndicator.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            menuLoadingIndicator.widthAnchor.constraint(equalToConstant: 64),
            menuLoadingIndicator.heightAnchor.constraint(equalToConstant: 64),
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        
        tableView.delegate = self
        tableView.refreshControl = refreshControl
        tableView.backgroundColor = .systemBackground
        tableView.keyboardDismissMode = .onDrag
        tableView.estimatedRowHeight = 52
        tableView.rowHeight = UITableView.automaticDimension
        refreshControl.addTarget(self, action: #selector(refreshData), for: .valueChanged)
        tableView.register(MenuMealItemCell.self, forCellReuseIdentifier: MenuMealItemCell.reuseID)
        tableView.sectionHeaderTopPadding = 0
        tableView.sectionHeaderHeight = UITableView.automaticDimension
        tableView.estimatedSectionHeaderHeight = 48

        dataSource = MenuPresentationTableDataSource(tableView: tableView) {
            [weak self] tableView, indexPath, rowID in
            guard let self,
                  let row = presentationSnapshot?.rowsByID[rowID],
                  let cell = tableView.dequeueReusableCell(
                    withIdentifier: MenuMealItemCell.reuseID,
                    for: indexPath
                  ) as? MenuMealItemCell else {
                return nil
            }
            cell.configure(
                row: row,
                images: row.symbolDescriptors.compactMap(traitImageCache.image(for:))
            )
            if #available(iOS 26.0, *),
               let key = presentationSnapshot?.key.sourceKey,
               key.locationID.provider == .pennState,
               PSUDiningHall(rawValue: key.locationID.rawValue) != nil {
                // Identify the rendered row, not a newer selection still loading.
                let reference = PSUFoodReference(
                    hall: key.locationID.rawValue, date: key.localDate,
                    mealID: row.id.sectionID.mealID,
                    sectionID: row.id.sectionID.sourceSectionID, itemID: row.item.id
                )
                cell.appEntityIdentifier = EntityIdentifier(for: PSUFoodEntity.self, identifier: reference.id)
            }
            if let plate = self.selectedPlate, plate.context == self.plateContext {
                cell.configurePlateAction(selected: plate.contains(row.item)) { [weak self] in
                    guard let self, let context = self.plateContext else { return }
                    if let editingPlate = self.editingPlate {
                        if editingPlate.contains(row.item) { editingPlate.remove(row.item.id) }
                        else { editingPlate.add(row.item) }
                        self.mealFeature?.changed()
                    } else {
                        self.mealFeature?.toggle(row.item, context: context)
                    }
                }
            }
            return cell
        }
        dataSource.titleProvider = { [weak self] sectionIndex in
            self?.presentationSnapshot?.section(at: sectionIndex)?.displayName
        }

        setContentScrollView(tableView, for: .top)
        if #available(iOS 26.0, *) {
            tableView.topEdgeEffect.style = .soft
        }
        
        mealPanGesture = UIPanGestureRecognizer(target: self, action: #selector(handleMealPan(_:)))
        mealPanGesture.allowedScrollTypesMask = .continuous
        mealPanGesture.delegate = self
        tableView.panGestureRecognizer.require(toFail: mealPanGesture)
        tableView.addGestureRecognizer(mealPanGesture)
    }

    private func setupSearch() {
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = "Search this menu"
        searchController.searchBar.autocapitalizationType = .none
        searchController.searchBar.returnKeyType = .done
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = true
        navigationItem.preferredSearchBarPlacement = .stacked
        definesPresentationContext = true
    }

    private func setupMealControl() {
        mealControlContainer.autoresizingMask = [.flexibleWidth]
        headerContainer.addSubview(mealControlContainer)
        mealControlContainer.onSelect = { [weak self] meal in self?.selectMeal(meal) }
        mealControlContainer.onShare = { [weak self] meal in self?.presentShareComposer(mealNamed: meal) }
    }

    private var donatedMenuContexts: Set<String> = []
    private var menuPredictionActivity: NSUserActivity?
    private func donateVisibleMenu() {
        guard PSUDiningAccess.isEnabled, viewIfLoaded?.window != nil,
              let selectedPeriod else { return }
        let today = diningHall.calendarContext.serviceDate(containing: .now)
        guard activeQuery.localDate == today,
              !PSUDiningIntentNavigation.isIntentDriven(hall: diningHall.rawValue) else { return }
        let key = "\(activeQuery.localDate):\(selectedPeriod.id)"
        guard donatedMenuContexts.insert(key).inserted else { return }
        let meal = PSUMealPreference(rawValue: selectedPeriod.servicePeriod.id.rawValue) ?? .automatic
        if #available(iOS 26.0, *) {
            // Relative "today" remains useful on the next visit.
            let intent = OpenPSUDiningMenuIntent(hall: diningHall, date: nil, meal: meal)
            Task { await PSUDiningSuggestions.shared.update(intent) }
        } else {
            // Older systems learn the same repeatable action separately from dated Handoff.
            menuPredictionActivity?.resignCurrent()
            let activity = NSUserActivity(activityType: "com.ryannair05.pennstatemeals.view-hall")
            activity.title = "\(diningHall.rawValue.capitalized) Dining Hall"
            activity.isEligibleForSearch = false
            activity.isEligibleForHandoff = false
            activity.isEligibleForPrediction = true
            var info = [
                DiningDeepLinkUserInfoKey.provider: "psu",
                DiningDeepLinkUserInfoKey.hall: diningHall.rawValue
            ]
            if meal != .automatic { info[DiningDeepLinkUserInfoKey.meal] = meal.rawValue }
            activity.userInfo = info
            activity.requiredUserInfoKeys = Set(info.keys)
            activity.persistentIdentifier = "psu-menu:\(diningHall.rawValue):\(meal.rawValue)"
            menuPredictionActivity = activity
            activity.becomeCurrent()
        }
    }

    private func updateUserActivityContext() {
        guard let activity = userActivity else { return }
        var userInfo = [
            DiningDeepLinkUserInfoKey.provider: diningHall.providerID.rawValue,
            DiningDeepLinkUserInfoKey.hall: diningHall.rawValue,
            DiningDeepLinkUserInfoKey.date: activeQuery.localDate.description
        ]
        if let selectedPeriod,
           let meal = DiningDeepLinkMeal(displayName: selectedPeriod.displayName) {
            userInfo[DiningDeepLinkUserInfoKey.meal] = meal.rawValue
        }
        activity.userInfo = userInfo
        activity.webpageURL = MeetAndEatURLFactory.staticFallback(
            kind: "hall",
            id: "\(diningHall.providerID.rawValue):\(diningHall.rawValue)",
            date: activeQuery.localDate.description,
            meal: userInfo[DiningDeepLinkUserInfoKey.meal]
        )
        if #available(iOS 18.2, *) {
            activity.appEntityIdentifier = EntityIdentifier(for: PSUDiningHallEntity(diningHall))
        }
        activity.needsSave = true
        donateVisibleMenu()
    }

    private func selectMeal(_ meal: String) {
        guard editingPlate == nil else { return }
        let meals = mealNames
        guard meal != selectedMeal,
              meals.contains(meal) else { return }
        feedback.prepare()
        mealSelectionGeneration &+= 1
        selectedMeal = meal
        viewState = .content
        activeQuery = activeQuery.selecting(
            servicePeriodID: DiningServicePeriodNormalizer.normalize(meal).id
        )
        updateUserActivityContext()
        mealControlContainer.select(selectedMeal, animated: true)
        updateHeaderForSelectedMeal()
        updatePlateControls()
        mealControlContainer.scrollSelectedMealIntoView(animated: !UIAccessibility.isReduceMotionEnabled)
        feedback.selectionChanged()
        schedulePresentationRebuild(reason: .mealChanged)
    }

    @objc private func handleMealPan(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .ended, !isLoading else { return }
        let translation = gesture.translation(in: tableView)
        let velocity = gesture.velocity(in: tableView)
        let layoutMultiplier: CGFloat = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
            ? -1
            : 1
        guard let meal = DiningMealControl.mealAfterSwipe(
            meals: mealNames,
            selectedMeal: selectedMeal,
            translationX: translation.x * layoutMultiplier,
            translationY: translation.y,
            velocityX: velocity.x * layoutMultiplier
        ) else { return }
        selectMeal(meal)
    }

    @objc private func shareCurrentMeal() {
        presentShareComposer()
    }

    @objc private func plateChanged() {
        updatePlateControls()
        tableView.reloadData()
    }

    private func updatePlateControls() {
        guard let mealFeature else { return }
        let hasPlate = selectedPlate?.context == plateContext && selectedPlate != nil
        updateFilterMenu()
        let visible = hasPlate && selectedPlate?.context == plateContext
        plateButton?.isHidden = !visible
        let itemCount = selectedPlate?.items.count ?? 0
        plateButton?.configuration?.title = String(itemCount)
        plateButton?.accessibilityLabel = "View Plate"
        plateButton?.accessibilityValue = "\(itemCount) items"
        tableView.contentInset.bottom = visible ? 72 : 0
        tableView.verticalScrollIndicatorInsets.bottom = visible ? 72 : 0
        if startsPlate, let context = plateContext, viewIfLoaded?.window != nil {
            startsPlate = false
            mealFeature.start(context: context, from: self)
        }
    }

    @objc private func reviewPlate() {
        if let plateDone { plateDone() }
        else { mealFeature?.showPlate(from: self) }
    }

    private func presentShareComposer(mealNamed mealName: String? = nil) {
        guard let snapshot = menuSnapshot,
              let period = mealName.flatMap({ selectedName in
                  snapshot.meals.first { $0.displayName == selectedName }
              }) ?? selectedPeriod else {
            return
        }
        let composer = MenuShareComposerViewController(
            snapshot: snapshot,
            hallName: diningHall.rawValue.capitalized,
            period: period
        )
        let navigation = UINavigationController(rootViewController: composer)
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        present(navigation, animated: true)
    }

    private func updateHeaderForSelectedMeal() {
        let localDate = menuSnapshot?.key.localDate
            ?? diningHall.calendarContext.localDate(containing: headerDatePickerView.datePicker.date)
        let query = DiningQuery(
            hall: diningHall,
            localDate: localDate,
            servicePeriodID: selectedMeal.isEmpty
                ? nil
                : DiningServicePeriodNormalizer.normalize(selectedMeal).id,
            sourceVariant: menuSnapshot?.key.sourceVariant ?? MenuDayKey.officialSourceVariant
        )
        headerDatePickerView.remakeView(
            query: query,
            selectedMeal: selectedMeal,
            dayHours: dayHours,
            hasPublishedItems: menuSnapshot?.hasPublishedItems ?? false
        )
    }

    @objc private func refreshData() {
        let currentDay = diningHall.calendarContext.serviceDate(containing: .now)
        if currentDay != lastObservedCurrentDay {
            lastObservedCurrentDay = currentDay
            headerDatePickerView.datePicker.date = .now
            if let currentQuery = try? activeQuery.selecting(
                date: currentDay,
                relativeTo: .now
            ) {
                activeQuery = currentQuery
            }
        }
        let query = activeQuery
        startMenuLoad(
            query: query,
            forceReload: true,
            presentation: .refreshControl
        )
    }

    private func scheduleTomorrowPrefetchIfNeeded() {
        guard !didScheduleTomorrowPrefetch,
              !isLoading,
              pendingPresentationKey == nil,
              viewIfLoaded?.window != nil,
              tableView.numberOfSections > 0,
              tableView.numberOfRows(inSection: 0) > 0,
              activeQuery.localDate == diningHall.calendarContext.serviceDate(containing: .now)
        else { return }
        didScheduleTomorrowPrefetch = true
        let environment = environment
        let hall = diningHall
        Task(priority: .utility) { @concurrent in
            await environment.prefetchTomorrow(for: hall)
        }
    }

    private var selectedPeriod: MenuMealPeriod? {
        guard let selectedID = activeQuery.servicePeriodID else { return nil }
        return menuSnapshot?.meals.first {
            DiningServicePeriodNormalizer.normalize($0.displayName).id == selectedID
        }
    }

    private var mealNames: [String] {
        menuSnapshot?.meals.map(\.displayName) ?? []
    }

    func updateSearchResults(for searchController: UISearchController) {
        schedulePresentationRebuild(reason: .searchChanged)
        setNeedsUpdateContentUnavailableConfiguration()
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let rowID = dataSource.itemIdentifier(for: indexPath),
              let item = presentationSnapshot?.rowsByID[rowID]?.item else { return }
        guard canShowDetail(for: item), let navigationController else { return }
        navigationController.pushViewController(makeDetailController(for: item), animated: true)
    }

    func tableView(
        _ tableView: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let rowID = dataSource.itemIdentifier(for: indexPath),
              let item = presentationSnapshot?.rowsByID[rowID]?.item else { return nil }
        let hasDetail = canShowDetail(for: item)
        let sourceURL = item.detailURL ?? item.detailMetadata?.sourceURL

        return UIContextMenuConfiguration(
            identifier: indexPath as NSIndexPath,
            previewProvider: { [weak self] in
                guard let self, hasDetail else { return nil }
                let detail = makeDetailController(for: item)
                let navigation = UINavigationController(rootViewController: detail)
                navigation.navigationBar.prefersLargeTitles = true
                let availableSize = view.window?.safeAreaLayoutGuide.layoutFrame.size
                    ?? view.safeAreaLayoutGuide.layoutFrame.size
                // Leave room for the action menu before requesting the preview size.
                // Requesting the entire window height makes UIKit scale both dimensions
                // down to fit, unnecessarily narrowing the preview on wide windows.
                let actionCount: CGFloat = sourceURL == nil ? 1 : 2
                let actionHeight = max(44, UIFont.preferredFont(forTextStyle: .body).lineHeight + 24)
                let menuAndSpacingHeight = actionCount * actionHeight + 80
                let previewSize = CGSize(
                    width: max(1, availableSize.width - 32),
                    height: max(1, availableSize.height - menuAndSpacingHeight)
                )
                detail.preferredContentSize = previewSize
                navigation.preferredContentSize = previewSize
                // Lay out the actual preview at the requested size before UIKit
                // snapshots it, rather than relying on preferredContentSize alone.
                navigation.loadViewIfNeeded()
                navigation.view.frame = CGRect(origin: .zero, size: previewSize)
                navigation.view.setNeedsLayout()
                navigation.view.layoutIfNeeded()
                return navigation
            }
        ) { [weak self] _ in
            var actions: [UIMenuElement] = [
                UIAction(
                    title: "Copy Item Name",
                    image: UIImage(systemName: "doc.on.doc")
                ) { _ in
                    UIPasteboard.general.string = item.displayName
                }
            ]
            if let sourceURL {
                actions.append(UIAction(
                    title: "Open in Safari",
                    image: UIImage(systemName: "safari")
                ) { _ in
                    self?.presentSource(sourceURL)
                })
            }
            return UIMenu(children: actions)
        }
    }

    func tableView(
        _ tableView: UITableView,
        previewForHighlightingContextMenuWithConfiguration configuration: UIContextMenuConfiguration
    ) -> UITargetedPreview? {
        targetedPreview(for: configuration, in: tableView)
    }

    func tableView(
        _ tableView: UITableView,
        previewForDismissingContextMenuWithConfiguration configuration: UIContextMenuConfiguration
    ) -> UITargetedPreview? {
        targetedPreview(for: configuration, in: tableView)
    }

    func tableView(
        _ tableView: UITableView,
        willPerformPreviewActionForMenuWith configuration: UIContextMenuConfiguration,
        animator: any UIContextMenuInteractionCommitAnimating
    ) {
        guard let previewNavigation = animator.previewViewController as? UINavigationController,
              let detail = previewNavigation.viewControllers.first as? MenuItemDetailViewController else { return }
        animator.preferredCommitStyle = .pop
        animator.addCompletion { [weak self] in
            guard let self, let navigationController else { return }
            // Transfer the loaded preview after dismissal, preserving its item and state
            // even if the menu's diffable snapshot changed while it was open.
            previewNavigation.setViewControllers([], animated: false)
            navigationController.pushViewController(detail, animated: false)
        }
    }

    private func makeDetailController(for item: DiningMenuItem) -> MenuItemDetailViewController {
        let record = menuSnapshot.map(PSUFoodRecord.records(in:))?.first {
            $0.reference.mealID == selectedPeriod?.id && $0.item.id == item.id
        }
        return MenuItemDetailViewController(
            item: item,
            environment: environment,
            providerID: diningHall.providerID,
            sourceLocationID: diningHall.locationID,
            sourceDate: activeQuery.localDate,
            intentFoodRecord: record,
            mealFeature: editingPlate == nil ? mealFeature : nil,
            plateContext: plateContext
        )
    }

    private func canShowDetail(for item: DiningMenuItem) -> Bool {
        item.detailURL != nil || item.detailMetadata?.hasPublishedContent == true
    }

    private func targetedPreview(
        for configuration: UIContextMenuConfiguration,
        in tableView: UITableView
    ) -> UITargetedPreview? {
        guard let indexPath = configuration.identifier as? NSIndexPath,
              let cell = tableView.cellForRow(at: indexPath as IndexPath) else { return nil }
        let parameters = UIPreviewParameters()
        parameters.backgroundColor = .clear
        parameters.visiblePath = UIBezierPath(roundedRect: cell.bounds, cornerRadius: 12)
        return UITargetedPreview(view: cell, parameters: parameters)
    }

    private func presentSource(_ url: URL) {
        let browser = SFSafariViewController(url: url)
        browser.dismissButtonStyle = .done
        present(browser, animated: true)
    }
    
    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard let name = presentationSnapshot?.section(at: section)?.displayName else { return nil }
        let header = tableView.dequeueReusableHeaderFooterView(withIdentifier: "PSUStationHeader")
            ?? UITableViewHeaderFooterView(reuseIdentifier: "PSUStationHeader")
        var content = UIListContentConfiguration.groupedHeader()
        content.text = name
        content.textProperties.font = .preferredFont(forTextStyle: .headline)
        content.textProperties.color = .label
        content.textProperties.transform = .none
        content.textProperties.numberOfLines = 0
        content.secondaryTextProperties.font = .preferredFont(forTextStyle: .footnote)
        content.secondaryTextProperties.numberOfLines = 0
        content.directionalLayoutMargins = .init(top: 12, leading: 20, bottom: 8, trailing: 20)
        let key = PSUDiningHours.stationKey(for: name, hall: diningHall)
        if let hours = stationHours[key] {
            if hours.isExplicitlyClosed {
                content.secondaryText = "Closed"
                content.secondaryTextProperties.color = .systemRed
            } else if !hours.intervals.isEmpty {
                let style = Date.FormatStyle(date: .omitted, time: .shortened, timeZone: diningHall.calendarContext.timeZone)
                let windows = hours.intervals.compactMap { interval -> String? in
                    guard let start = diningHall.calendarContext.date(on: activeQuery.localDate, minutesAfterMidnight: interval.startMinutesAfterMidnight),
                          let end = diningHall.calendarContext.date(on: activeQuery.localDate, minutesAfterMidnight: interval.endMinutesAfterMidnight) else { return nil }
                    return start.formatted(style) + "–" + end.formatted(style)
                }
                content.secondaryText = windows.joined(separator: " · ")
                content.secondaryTextProperties.color = .secondaryLabel
            }
        }
        header.contentConfiguration = content
        return header
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === mealPanGesture else { return true }
        let velocity = mealPanGesture.velocity(in: tableView)
        return editingPlate == nil && !isLoading && mealNames.count > 1
            && abs(velocity.x) > abs(velocity.y)
    }
}
