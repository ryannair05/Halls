import AppIntents
import UIKit

@MainActor
final class MenuItemDetailViewController: UITableViewController {
    private enum ViewState {
        case loading
        case available(PSUMenuItemDetail)
        case unavailable(URL)
        case parseFailed(URL)
        case transportError(URL)
    }

    private enum Section: Equatable {
        case availability
        case message
        case keyMacros
        case ingredientsAndAllergens
        case detailedNutrition
        case plate
    }

    private let mealFeature: MealFeatureCoordinator?
    private let plateContext: PlateContext?
    private let item: DiningMenuItem
    private let environment: DiningMenuEnvironment
    private let providerID: DiningProviderID
    private let availabilityAggregate: DiningSearchAggregate?
    private let fixedHallOrder: [DiningLocationID]
    private let openHall: (@MainActor (DiningLocationID, DateOnly, String?) -> Void)?
    private let sourceLocationID: DiningLocationID?
    private let sourceDate: DateOnly?
    private let intentFoodRecord: PSUFoodRecord?
    private var detailItem: DiningMenuItem
    private var viewState: ViewState = .loading
    private var loadTask: Task<Void, Never>?
    private var availabilityTask: Task<Void, Never>?
    private var ingredientsExpanded = false
    private weak var traitTooltip: UIViewController?
    private weak var tooltipSourceButton: UIButton?
    private weak var ingredientsLabel: UILabel?
    private weak var ingredientsFadeView: UIView?
    private weak var ingredientsDisclosureButton: UIButton?
    private var ingredientsFadeLayer: CAGradientLayer?
    private let detailRefreshControl = UIRefreshControl()
    private var availabilitySummaries: [DiningHallAvailabilitySummary] = []
    private var availabilityHours: [DiningLocationID: DayHours] = [:]

    private var providerName: String {
        switch providerID {
        case .pennState: "Penn State"
        case .uga: "UGA"
        case .barnard: "Barnard"
        case .columbia: "Columbia"
        default: "The dining provider"
        }
    }

    init(
        item: DiningMenuItem,
        environment: DiningMenuEnvironment,
        providerID: DiningProviderID,
        availabilityAggregate: DiningSearchAggregate? = nil,
        fixedHallOrder: [DiningLocationID] = [],
        sourceLocationID: DiningLocationID? = nil,
        sourceDate: DateOnly? = nil,
        intentFoodRecord: PSUFoodRecord? = nil,
        openHall: (@MainActor (DiningLocationID, DateOnly, String?) -> Void)? = nil,
        mealFeature: MealFeatureCoordinator? = nil,
        plateContext: PlateContext? = nil
    ) {
        self.mealFeature = mealFeature
        self.plateContext = plateContext
        self.item = item
        self.detailItem = item
        self.environment = environment
        self.providerID = providerID
        self.availabilityAggregate = availabilityAggregate
        self.fixedHallOrder = fixedHallOrder
        self.sourceLocationID = sourceLocationID
        self.sourceDate = sourceDate
        self.intentFoodRecord = intentFoodRecord
        self.openHall = openHall
        self.availabilitySummaries = availabilityAggregate?.hallAvailability ?? []
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    deinit {
        loadTask?.cancel()
        availabilityTask?.cancel()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard #available(iOS 18.2, *), let record = intentFoodRecord else { return }
        let entity = PSUFoodEntity(record)
        let activity = NSUserActivity(activityType: "com.ryannair05.pennstatemeals.view-food")
        activity.title = record.item.displayName
        activity.appEntityIdentifier = EntityIdentifier(for: entity)
        activity.isEligibleForSearch = false
        userActivity = activity
        activity.becomeCurrent()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        userActivity?.resignCurrent()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = item.displayName
        let titleLabel = UILabel()
        titleLabel.text = item.displayName
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 2
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.75
        titleLabel.allowsDefaultTighteningForTruncation = true
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        navigationItem.titleView = titleLabel
        navigationItem.largeTitleDisplayMode = .never

        tableView.accessibilityIdentifier = "menu-item-detail-table"
        tableView.backgroundColor = .systemGroupedBackground
        tableView.separatorStyle = .none
        tableView.estimatedRowHeight = 64
        tableView.rowHeight = UITableView.automaticDimension
        tableView.sectionHeaderTopPadding = 0
        if detailItem.detailURL != nil {
            detailRefreshControl.addTarget(
                self,
                action: #selector(refreshDetail),
                for: .valueChanged
            )
            tableView.refreshControl = detailRefreshControl
        }
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
            (controller: MenuItemDetailViewController, _) in
            controller.updateIngredientsFadeColors()
        }
        if providerID == .pennState {
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                image: UIImage(systemName: "square.and.arrow.up"),
                style: .plain, target: self, action: #selector(shareDish)
            )
            navigationItem.rightBarButtonItem?.accessibilityLabel = "Share dish"
        }
        load()
        loadAvailability()
    }

    @objc private func shareDish() {
        let date = sourceDate ?? ProviderCalendarContexts.pennState.serviceDate(containing: .now)
        guard let url = MeetAndEatURLFactory.staticFallback(
            kind: "dish", id: "\(providerID.rawValue):\(item.id)", date: date.description
        ), MeetAndEatDeepLink(url: url) != nil else { return }
        let activity = UIActivityViewController(activityItems: [item.displayName, url], applicationActivities: nil)
        activity.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
        present(activity, animated: true)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        ingredientsFadeLayer?.frame = ingredientsFadeView?.bounds ?? .zero
    }

    private func load(forceRefresh: Bool = false) {
        if !forceRefresh,
           let metadata = detailItem.detailMetadata,
           (0..<PSUMenuItemDetailRepository.cacheInterval).contains(
               Date.now.timeIntervalSince(metadata.fetchedAt)
           ) {
            apply(.available(PSUMenuItemDetail(itemID: detailItem.id, metadata: metadata)))
            return
        }
        guard let sourceURL = detailItem.detailURL else {
            detailRefreshControl.endRefreshing()
            return
        }
        loadTask?.cancel()
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if !forceRefresh {
                viewState = .loading
                tableView.reloadData()
            }
            defer { detailRefreshControl.endRefreshing() }

            do {
                let repository = try await environment.itemDetailRepository()
                try Task.checkCancellation()
                let loaded = try await repository.detail(
                    for: detailItem.id,
                    displayName: detailItem.displayName,
                    sourceURL: sourceURL,
                    policy: forceRefresh ? .reloadIgnoringCache : .useCache
                )
                try Task.checkCancellation()
                if case .unavailable = loaded,
                   let sourceLocationID,
                   let sourceDate,
                   let refreshedItem = await environment.refreshDetailSource(
                       matching: detailItem,
                       locationID: sourceLocationID,
                       on: sourceDate
                   ),
                   let refreshedURL = refreshedItem.detailURL {
                    detailItem = refreshedItem
                    let retried = try await repository.detail(
                        for: refreshedItem.id,
                        displayName: refreshedItem.displayName,
                        sourceURL: refreshedURL,
                        policy: .reloadIgnoringCache
                    )
                    try Task.checkCancellation()
                    apply(retried)
                } else {
                    apply(loaded)
                }
            } catch {
                guard !Task.isCancelled else { return }
                if forceRefresh {
                    UIAccessibility.post(
                        notification: .announcement,
                        argument: "Item details could not be refreshed"
                    )
                    return
                }
                viewState = .transportError(sourceURL)
                tableView.reloadData()
            }
        }
    }

    @objc private func refreshDetail() {
        load(forceRefresh: true)
    }

    private func loadAvailability() {
        guard availabilityAggregate != nil else { return }
        availabilityTask?.cancel()
        availabilityTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let lastViewed = await environment.lastViewedLocationStore.locationID()
            for summary in availabilitySummaries where !Task.isCancelled {
                availabilityHours[summary.locationID] = await environment.psuHours.hours(
                    for: summary.locationID,
                    on: summary.date,
                    policy: .revalidateIfNeeded
                )
            }
            guard !Task.isCancelled else { return }
            availabilitySummaries = orderedAvailabilitySummaries(lastViewed: lastViewed)
            tableView.reloadSections(
                IndexSet(integer: sections.firstIndex(of: .availability) ?? 0),
                with: .none
            )
        }
    }

    private func orderedAvailabilitySummaries(
        lastViewed: DiningLocationID?
    ) -> [DiningHallAvailabilitySummary] {
        let positions = Dictionary(
            uniqueKeysWithValues: fixedHallOrder.enumerated().map { ($1, $0) }
        )
        return (availabilityAggregate?.hallAvailability ?? []).sorted {
            let lhsLast = $0.locationID == lastViewed
            let rhsLast = $1.locationID == lastViewed
            if lhsLast != rhsLast { return lhsLast }
            return (positions[$0.locationID] ?? Int.max)
                < (positions[$1.locationID] ?? Int.max)
        }
    }

    private func configureAvailabilityCell(_ cell: UITableViewCell, row: Int) {
        guard availabilitySummaries.indices.contains(row) else { return }
        let summary = availabilitySummaries[row]
        var content = cell.defaultContentConfiguration()
        content.text = summary.hallName
        let hoursText = availabilityHoursText(for: summary)
        content.secondaryText = [
            summary.mealNames.joined(separator: ", "),
            summary.sectionNames.joined(separator: ", "),
            hoursText
        ]
        .filter { !$0.isEmpty }
        .joined(separator: " · ")
        content.secondaryTextProperties.color = .secondaryLabel
        content.secondaryTextProperties.numberOfLines = 2
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        cell.selectionStyle = .default
    }

    private func availabilityHoursText(for summary: DiningHallAvailabilitySummary) -> String {
        guard let hours = availabilityHours[summary.locationID] else {
            return "Hours unavailable"
        }
        let matching = hours.intervals.filter { interval in
            guard let label = interval.label else { return false }
            return summary.mealNames.contains {
                DiningServicePeriodNormalizer.menuLabel($0, matchesHoursLabel: label)
            }
        }
        guard !matching.isEmpty else { return "Hours unavailable" }
        let context = ProviderCalendarContexts.pennState
        let formatter = DateFormatter()
        formatter.calendar = context.calendar
        formatter.locale = .current
        formatter.timeZone = context.timeZone
        formatter.setLocalizedDateFormatFromTemplate("jm")
        return matching.compactMap { interval in
            guard let start = context.date(
                on: summary.date,
                minutesAfterMidnight: interval.startMinutesAfterMidnight
            ), let end = context.date(
                on: summary.date,
                minutesAfterMidnight: interval.endMinutesAfterMidnight
            ) else { return nil }
            return "\(formatter.string(from: start))–\(formatter.string(from: end))"
        }.joined(separator: " · ")
    }

    private func apply(_ state: PSUMenuItemDetailState) {
        let nextState: ViewState = switch state {
        case .available(let detail): .available(detail)
        case .unavailable(let sourceURL): .unavailable(sourceURL)
        case .parseFailed(let sourceURL): .parseFailed(sourceURL)
        }

        switch nextState {
        case .available:
            break
        case .loading, .unavailable, .parseFailed, .transportError:
            ingredientsExpanded = false
        }
        viewState = nextState
        reloadTablePreservingScroll()
    }

    private var sections: [Section] {
        let detailSections: [Section] = switch viewState {
        case .loading:
            [.keyMacros, .ingredientsAndAllergens, .detailedNutrition]
        case .transportError:
            [.message]
        case .unavailable, .parseFailed:
            [.message]
        case .available(let detail):
            if let facts = detail.nutrition, !facts.isEmpty {
                [.keyMacros, .ingredientsAndAllergens, .detailedNutrition]
            } else {
                [.ingredientsAndAllergens, .detailedNutrition]
            }
        }
        let content = availabilityAggregate == nil ? detailSections : [.availability] + detailSections
        return mealFeature == nil ? content : content + [.plate]
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        sections.count
    }

    override func tableView(
        _ tableView: UITableView,
        numberOfRowsInSection section: Int
    ) -> Int {
        let section = sections[section]
        switch section {
        case .availability:
            return availabilitySummaries.count
        case .message:
            return switch viewState {
            case .parseFailed, .transportError: 2
            case .loading, .unavailable, .available: 1
            }
        case .plate, .keyMacros, .ingredientsAndAllergens, .detailedNutrition:
            return 1
        }
    }

    override func tableView(
        _ tableView: UITableView,
        titleForHeaderInSection section: Int
    ) -> String? {
        switch sections[section] {
        case .availability: "AVAILABLE AT"
        case .keyMacros: "KEY MACROS"
        case .ingredientsAndAllergens: "INGREDIENTS & ALLERGENS"
        case .detailedNutrition: "DETAILED NUTRITION"
        case .message, .plate: nil
        }
    }

    override func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        cell.backgroundColor = .secondarySystemGroupedBackground

        switch sections[indexPath.section] {
        case .plate:
            configureActionCell(cell, title: mealFeature?.purchaseManager.hasUnlockedPro == true ? "Add to Plate" : "Add to Plate · Pro")
            cell.accessibilityHint = "Build a plate from this menu"
        case .availability:
            configureAvailabilityCell(cell, row: indexPath.row)
        case .message:
            configureMessageCell(cell, row: indexPath.row)
        case .keyMacros:
            configureKeyMacrosCell(cell)
        case .ingredientsAndAllergens:
            configureIngredientsAndAllergensCell(cell)
        case .detailedNutrition:
            configureDetailedNutritionCell(cell)
        }
        return cell
    }

    private func configureMessageCell(_ cell: UITableViewCell, row: Int) {
        if row == 1 {
            let title: String = switch viewState {
            case .transportError, .parseFailed: "Try Again"
            case .unavailable: ""
            case .loading, .available: ""
            }
            configureActionCell(cell, title: title)
            return
        }

        var content = cell.defaultContentConfiguration()
        content.textProperties.font = .preferredFont(forTextStyle: .headline)
        content.textProperties.numberOfLines = 0
        content.secondaryTextProperties.font = .preferredFont(forTextStyle: .body)
        content.secondaryTextProperties.numberOfLines = 0
        switch viewState {
        case .loading:
            content.text = "Loading official details…"
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            spinner.accessibilityLabel = "Loading"
            cell.accessoryView = spinner
        case .unavailable:
            content.image = UIImage(systemName: "doc.text.magnifyingglass")
            content.text = "Details not published"
            content.secondaryText = "\(providerName) does not provide ingredients or nutrition for this item."
        case .parseFailed:
            content.image = UIImage(systemName: "exclamationmark.triangle")
            content.imageProperties.tintColor = .systemOrange
            content.text = "\(providerName) changed this page"
            content.secondaryText = "Halls could not read the official details."
        case .transportError:
            content.image = UIImage(systemName: "wifi.exclamationmark")
            content.imageProperties.tintColor = .systemOrange
            content.text = "Couldn’t reach \(providerName)"
            content.secondaryText = "Check your connection and try again."
        case .available:
            break
        }
        content.imageProperties.maximumSize = CGSize(width: 22, height: 22)
        cell.contentConfiguration = content
    }

    private func configureKeyMacrosCell(_ cell: UITableViewCell) {
        if case .loading = viewState {
            embed(makeKeyMacrosPlaceholder(), in: cell)
            return
        }
        guard case .available(let detail) = viewState else { return }
        guard let facts = detail.nutrition else { return }
        embed(Self.makeKeyMacroMetricsView(facts: facts), in: cell)
    }

    private func configureIngredientsAndAllergensCell(_ cell: UITableViewCell) {
        if case .loading = viewState {
            embed(makeTextPlaceholder(lineCount: 5), in: cell)
            return
        }
        guard case .available(let detail) = viewState else { return }
        let ingredients = detail.ingredients
            ?? "\(providerName) did not provide an ingredient list."
        embed(makeIngredientsAndAllergensView(
            ingredients: ingredients,
            allergenStatement: detail.allergenStatement,
            symbols: traitSymbols(for: detail)
        ), in: cell)
    }

    private func configureDetailedNutritionCell(_ cell: UITableViewCell) {
        if case .loading = viewState {
            embed(makeTextPlaceholder(lineCount: 8), in: cell)
            return
        }
        guard case .available(let detail) = viewState else { return }
        guard let facts = detail.nutrition else {
            var content = cell.defaultContentConfiguration()
            content.text = "\(providerName) did not provide nutrition facts."
            content.textProperties.font = .preferredFont(forTextStyle: .subheadline)
            content.textProperties.numberOfLines = 0
            cell.contentConfiguration = content
            return
        }
        embed(NutritionFactsCardView(facts: facts, expanded: true), in: cell)
    }

    private func embed(_ view: UIView, in cell: UITableViewCell) {
        view.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 16),
            view.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: 16),
            view.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor, constant: -16),
            view.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -16)
        ])
        cell.isAccessibilityElement = false
    }

    private func makeKeyMacrosPlaceholder() -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 10
        row.distribution = .fillEqually
        for _ in 0..<3 {
            let card = placeholderBlock(cornerRadius: 12)
            card.heightAnchor.constraint(equalToConstant: 72).isActive = true
            row.addArrangedSubview(card)
        }
        preparePlaceholder(row)
        return row
    }

    private func makeTextPlaceholder(lineCount: Int) -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 12
        for lineIndex in 0..<lineCount {
            let row = UIStackView()
            row.axis = .horizontal
            let line = placeholderBlock(cornerRadius: 4)
            line.heightAnchor.constraint(equalToConstant: lineIndex == 0 ? 18 : 13).isActive = true
            row.addArrangedSubview(line)
            if lineIndex == lineCount - 1 {
                let spacer = UIView()
                row.addArrangedSubview(spacer)
                spacer.widthAnchor.constraint(
                    equalTo: line.widthAnchor,
                    multiplier: 0.65
                ).isActive = true
            }
            stack.addArrangedSubview(row)
        }
        preparePlaceholder(stack)
        return stack
    }

    private func placeholderBlock(cornerRadius: CGFloat) -> UIView {
        let block = UIView()
        block.backgroundColor = .tertiarySystemFill
        block.layer.cornerRadius = cornerRadius
        return block
    }

    private func preparePlaceholder(_ view: UIView) {
        view.isAccessibilityElement = true
        view.accessibilityLabel = "Loading item details"
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        view.alpha = 0.55
        UIView.animate(
            withDuration: 0.85,
            delay: 0,
            options: [.autoreverse, .repeat, .allowUserInteraction]
        ) {
            view.alpha = 1
        }
    }

    private func makeIngredientsAndAllergensView(
        ingredients: String,
        allergenStatement: String?,
        symbols: [DetailTraitSymbol]
    ) -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 10
        stack.accessibilityIdentifier = "detail-ingredients-card"

        stack.addArrangedSubview(Self.sectionHeading("ALLERGEN WARNINGS"))
        if !symbols.isEmpty {
            let iconRows = UIStackView()
            iconRows.axis = .vertical
            iconRows.spacing = 8
            iconRows.accessibilityIdentifier = "detail-trait-icons"
            for start in stride(from: 0, to: symbols.count, by: 5) {
                let row = UIStackView()
                row.axis = .horizontal
                row.alignment = .center
                row.spacing = 8
                for symbol in symbols[start..<min(start + 5, symbols.count)] {
                    row.addArrangedSubview(makeTraitButton(symbol))
                }
                row.addArrangedSubview(UIView())
                iconRows.addArrangedSubview(row)
            }
            stack.addArrangedSubview(iconRows)
        }

        let warning = UILabel()
        warning.text = allergenStatement
            ?? "No allergen statement was provided. This does not mean the item is allergen-free."
        warning.font = .preferredFont(forTextStyle: .footnote)
        warning.textColor = .secondaryLabel
        warning.numberOfLines = 0
        warning.adjustsFontForContentSizeCategory = true
        warning.accessibilityIdentifier = "detail-allergen-statement"
        stack.addArrangedSubview(warning)
        stack.setCustomSpacing(12, after: warning)

        let divider = UIView()
        divider.backgroundColor = .separator
        divider.heightAnchor.constraint(equalToConstant: 1 / traitCollection.displayScale).isActive = true
        stack.addArrangedSubview(divider)
        stack.setCustomSpacing(12, after: divider)
        stack.addArrangedSubview(Self.sectionHeading("INGREDIENTS"))

        let container = UIView()
        let label = UILabel()
        label.text = ingredients
        label.font = .preferredFont(forTextStyle: .body)
        label.textColor = .label
        label.numberOfLines = ingredientsExpanded ? 0 : 6
        label.adjustsFontForContentSizeCategory = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.accessibilityIdentifier = "detail-ingredients-content"
        container.addSubview(label)
        ingredientsLabel = label

        if Self.shouldCollapseIngredients(ingredients) {
            let fade = UIView()
            fade.isUserInteractionEnabled = false
            fade.translatesAutoresizingMaskIntoConstraints = false
            fade.alpha = ingredientsExpanded ? 0 : 1
            container.addSubview(fade)
            ingredientsFadeView = fade

            let gradient = CAGradientLayer()
            fade.layer.addSublayer(gradient)
            ingredientsFadeLayer = gradient
            updateIngredientsFadeColors()

            var configuration = UIButton.Configuration.tinted()
            configuration.image = UIImage(systemName: "chevron.down")
            configuration.baseForegroundColor = .secondaryLabel
            configuration.baseBackgroundColor = .secondarySystemFill
            configuration.cornerStyle = .capsule
            let disclosure = UIButton(configuration: configuration)
            disclosure.translatesAutoresizingMaskIntoConstraints = false
            disclosure.transform = ingredientsExpanded
                ? CGAffineTransform(rotationAngle: .pi)
                : .identity
            disclosure.accessibilityIdentifier = "detail-ingredients-toggle"
            disclosure.addTarget(self, action: #selector(toggleIngredients(_:)), for: .touchUpInside)
            container.addSubview(disclosure)
            ingredientsDisclosureButton = disclosure
            updateIngredientsDisclosureAccessibility()

            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: container.topAnchor),
                label.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                label.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                fade.leadingAnchor.constraint(equalTo: label.leadingAnchor),
                fade.trailingAnchor.constraint(equalTo: label.trailingAnchor),
                fade.bottomAnchor.constraint(equalTo: label.bottomAnchor),
                fade.heightAnchor.constraint(equalToConstant: 52),
                disclosure.topAnchor.constraint(equalTo: label.bottomAnchor, constant: -8),
                disclosure.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                disclosure.widthAnchor.constraint(equalToConstant: 44),
                disclosure.heightAnchor.constraint(equalToConstant: 36),
                disclosure.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])
        } else {
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: container.topAnchor),
                label.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                label.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                label.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])
        }
        stack.addArrangedSubview(container)
        return stack
    }

    private func makeTraitButton(_ symbol: DetailTraitSymbol) -> UIButton {
        var configuration = UIButton.Configuration.tinted()
        configuration.image = UIImage(named: symbol.assetName)?.withTintColor(
            symbol.tintColor,
            renderingMode: .alwaysOriginal
        )
        configuration.baseBackgroundColor = symbol.tintColor
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: 10,
            leading: 10,
            bottom: 10,
            trailing: 10
        )
        let button = UIButton(configuration: configuration)
        button.accessibilityIdentifier = "detail-trait-\(symbol.id)"
        button.accessibilityLabel = symbol.name
        button.accessibilityHint = "Shows the symbol name"
        button.addTarget(self, action: #selector(showTraitTooltip(_:)), for: .touchUpInside)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 44),
            button.heightAnchor.constraint(equalToConstant: 44)
        ])
        return button
    }

    @objc private func showTraitTooltip(_ sender: UIButton) {
        guard let name = sender.accessibilityLabel else { return }
        presentTraitTooltip(named: name, from: sender)
    }

    @objc private func toggleIngredients(_ sender: UIButton) {
        guard let ingredientsLabel else { return }
        ingredientsExpanded.toggle()
        ingredientsLabel.numberOfLines = ingredientsExpanded ? 0 : 6
        updateIngredientsDisclosureAccessibility()

        if UIAccessibility.isReduceMotionEnabled {
            UIView.performWithoutAnimation {
                self.tableView.beginUpdates()
                self.tableView.endUpdates()
                self.ingredientsFadeView?.alpha = self.ingredientsExpanded ? 0 : 1
                sender.transform = self.ingredientsExpanded ? CGAffineTransform(rotationAngle: .pi) : .identity
                self.tableView.layoutIfNeeded()
            }
            return
        }
        tableView.beginUpdates()
        tableView.endUpdates()
        UIView.animate(
            withDuration: 0.28,
            delay: 0,
            usingSpringWithDamping: 0.82,
            initialSpringVelocity: 0.25,
            options: [.allowUserInteraction, .beginFromCurrentState]
        ) {
            self.ingredientsFadeView?.alpha = self.ingredientsExpanded ? 0 : 1
            sender.transform = self.ingredientsExpanded
                ? CGAffineTransform(rotationAngle: .pi)
                : .identity
            self.tableView.layoutIfNeeded()
        }
    }

    private func updateIngredientsDisclosureAccessibility() {
        ingredientsDisclosureButton?.accessibilityLabel = ingredientsExpanded
            ? "Collapse ingredients"
            : "Show all ingredients"
        ingredientsDisclosureButton?.accessibilityValue = ingredientsExpanded
            ? "Expanded"
            : "Collapsed"
    }

    private func updateIngredientsFadeColors() {
        let background = UIColor.secondarySystemGroupedBackground.resolvedColor(
            with: traitCollection
        )
        ingredientsFadeLayer?.colors = [
            background.withAlphaComponent(0).cgColor,
            background.withAlphaComponent(0.94).cgColor,
            background.cgColor
        ]
        ingredientsFadeLayer?.locations = [0, 0.58, 1]
    }

    private static func sectionHeading(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(
            for: .systemFont(ofSize: 11, weight: .semibold)
        )
        label.textColor = .secondaryLabel
        label.adjustsFontForContentSizeCategory = true
        return label
    }

    static func makeKeyMacroMetricsView(facts: [DiningNutritionFact]) -> UIView {
        let normalized: (String) -> String = { value in
            DiningTextNormalizer.foldedWords(value)
        }
        let factValue: (Set<String>) -> String = { names in
            guard let fact = facts.first(where: { names.contains(normalized($0.name)) }) else {
                return "—"
            }
            return fact.value.components(separatedBy: " · ").first ?? fact.value
        }
        let metrics: [(title: String, value: String, color: UIColor)] = [
            ("CALORIES", factValue(["calories"]), .systemOrange),
            ("FAT", factValue(["total fat"]), .systemPink),
            ("CARBS", factValue(["total carb", "total carbohydrate"]), .systemIndigo),
            ("PROTEIN", factValue(["protein"]), .systemGreen)
        ]

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 10
        stack.accessibilityIdentifier = "detail-key-macros-card"
        if let serving = facts.first(where: { normalized($0.name) == "serving size" }) {
            let servingLabel = UILabel()
            servingLabel.text = "Per serving · \(serving.value)"
            servingLabel.font = .preferredFont(forTextStyle: .footnote)
            servingLabel.textColor = .secondaryLabel
            servingLabel.adjustsFontForContentSizeCategory = true
            stack.addArrangedSubview(servingLabel)
            stack.setCustomSpacing(12, after: servingLabel)
        }

        let columns = UIApplication.shared.preferredContentSizeCategory.isAccessibilityCategory
            ? 2
            : 4
        for start in stride(from: 0, to: metrics.count, by: columns) {
            let row = UIStackView()
            row.axis = .horizontal
            row.distribution = .fillEqually
            row.spacing = 10
            for metric in metrics[start..<min(start + columns, metrics.count)] {
                let title = UILabel()
                title.text = metric.title
                title.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(
                    for: .systemFont(ofSize: 11, weight: .semibold)
                )
                title.textColor = .secondaryLabel
                title.adjustsFontForContentSizeCategory = true
                title.minimumScaleFactor = 0.75
                title.adjustsFontSizeToFitWidth = true

                let value = UILabel()
                value.text = metric.value
                value.font = UIFontMetrics(forTextStyle: .title2).scaledFont(
                    for: .systemFont(ofSize: 22, weight: .bold)
                )
                value.textColor = metric.color
                value.adjustsFontForContentSizeCategory = true
                value.minimumScaleFactor = 0.65
                value.adjustsFontSizeToFitWidth = true

                let tile = UIStackView(arrangedSubviews: [title, value])
                tile.axis = .vertical
                tile.spacing = 3
                tile.isLayoutMarginsRelativeArrangement = true
                tile.directionalLayoutMargins = NSDirectionalEdgeInsets(
                    top: 12,
                    leading: 10,
                    bottom: 12,
                    trailing: 10
                )
                tile.backgroundColor = .tertiarySystemFill
                tile.layer.cornerRadius = 12
                tile.isAccessibilityElement = true
                tile.accessibilityLabel = metric.title.capitalized
                tile.accessibilityValue = metric.value
                row.addArrangedSubview(tile)
            }
            stack.addArrangedSubview(row)
        }
        return stack
    }

    private func configureActionCell(_ cell: UITableViewCell, title: String) {
        var content = cell.defaultContentConfiguration()
        content.text = title
        content.textProperties.color = view.tintColor
        content.textProperties.font = .preferredFont(forTextStyle: .headline)
        content.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: 11,
            leading: 20,
            bottom: 11,
            trailing: 20
        )
        cell.contentConfiguration = content
        cell.selectionStyle = .default
        cell.accessibilityTraits = .button
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch sections[indexPath.section] {
        case .plate:
            addToPlate()
        case .availability:
            guard availabilitySummaries.indices.contains(indexPath.row) else { return }
            let summary = availabilitySummaries[indexPath.row]
            openHall?(
                summary.locationID,
                summary.date,
                summary.mealNames.first
            )
        case .message where indexPath.row == 1:
            switch viewState {
            case .transportError, .parseFailed:
                load()
            case .unavailable:
                break
            case .loading, .available:
                break
            }
        case .message, .keyMacros, .ingredientsAndAllergens, .detailedNutrition:
            break
        }
    }

    private func addToPlate() {
        guard let mealFeature else { return }
        if let plateContext {
            mealFeature.start(context: plateContext, from: self, adding: detailItem)
            return
        }
        guard let aggregate = availabilityAggregate else { return }
        var contexts: [PlateContext] = []
        let appearances = aggregate.appearances.filter { appearance in
            guard let hall = PSUDiningHall(rawValue: appearance.locationID.rawValue) else { return false }
            let context = PlateContext(hall: hall, date: appearance.date, mealName: appearance.mealName)
            guard !contexts.contains(context) else { return false }
            contexts.append(context)
            return true
        }
        func add(_ appearance: MenuAppearance) {
            guard let hall = PSUDiningHall(rawValue: appearance.locationID.rawValue) else { return }
            let item = DiningMenuItem(
                id: appearance.itemID, displayName: appearance.displayName, detailURL: appearance.detailURL,
                sourceOrder: appearance.itemSourceOrder, sourceLabels: appearance.sourceLabels,
                detailMetadata: appearance.detailMetadata
            )
            mealFeature.start(context: PlateContext(hall: hall, date: appearance.date, mealName: appearance.mealName), from: self, adding: item)
        }
        if appearances.count == 1, let appearance = appearances.first { add(appearance); return }
        let chooser = UIAlertController(title: "Choose a Meal", message: "Add this food from a published menu.", preferredStyle: .actionSheet)
        for appearance in appearances {
            chooser.addAction(UIAlertAction(title: "\(appearance.hallName) · \(appearance.mealName) · \(appearance.date)", style: .default) { _ in add(appearance) })
        }
        chooser.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        chooser.popoverPresentationController?.sourceView = tableView
        chooser.popoverPresentationController?.sourceRect = tableView.rectForRow(at: IndexPath(row: 0, section: sections.count - 1))
        present(chooser, animated: true)
    }

    private func traitSymbols(for detail: PSUMenuItemDetail) -> [DetailTraitSymbol] {
        var semantics = MenuSourceLabelSemantic.classify(
            item.sourceLabels,
            itemName: item.displayName
        )
        if let statement = detail.allergenStatement {
            semantics.append(.allergenWarning(statement))
        }

        var seen = Set<String>()
        var result: [DetailTraitSymbol] = []
        for semantic in semantics {
            let descriptors = semantic.symbolDescriptors
            for (index, descriptor) in descriptors.enumerated() {
                guard seen.insert(descriptor.stableID).inserted else { continue }
                let name: String
                if semantic.kind == .allergenWarning,
                   semantic.knownAllergens.indices.contains(index) {
                    name = Self.displayName(for: semantic.knownAllergens[index])
                } else {
                    name = semantic.sourceText
                }
                result.append(DetailTraitSymbol(
                    id: descriptor.stableID,
                    assetName: descriptor.assetName,
                    name: name,
                    tintColor: descriptor.tintRole.color
                ))
            }
        }
        return result
    }

    private static func displayName(
        for allergen: MenuSourceLabelSemantic.KnownAllergen
    ) -> String {
        switch allergen {
        case .milk: "Milk allergen"
        case .egg: "Egg allergen"
        case .fish: "Fish allergen"
        case .shellfish: "Shellfish allergen"
        case .peanut: "Peanut allergen"
        case .treeNut: "Tree nut allergen"
        case .wheat: "Wheat allergen"
        case .soy: "Soy allergen"
        case .sesame: "Sesame allergen"
        }
    }

    private func presentTraitTooltip(named name: String, from button: UIButton) {
        if tooltipSourceButton === button, let traitTooltip {
            traitTooltip.dismiss(animated: true)
            self.traitTooltip = nil
            tooltipSourceButton = nil
            return
        }

        let showTooltip = { [weak self, weak button] in
            guard let self, let button, viewIfLoaded?.window != nil else { return }
            let tooltip = UIViewController()
            let label = UILabel()
            label.text = name
            label.font = .preferredFont(forTextStyle: .subheadline)
            label.textColor = .label
            label.numberOfLines = 0
            label.textAlignment = .center
            label.adjustsFontForContentSizeCategory = true
            label.translatesAutoresizingMaskIntoConstraints = false
            tooltip.view.backgroundColor = .secondarySystemGroupedBackground
            tooltip.view.addSubview(label)
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: tooltip.view.topAnchor, constant: 6),
                label.leadingAnchor.constraint(equalTo: tooltip.view.leadingAnchor, constant: 16),
                label.trailingAnchor.constraint(equalTo: tooltip.view.trailingAnchor, constant: -16),
                label.bottomAnchor.constraint(equalTo: tooltip.view.bottomAnchor, constant: -18),
                label.widthAnchor.constraint(lessThanOrEqualToConstant: 220)
            ])
            let size = label.sizeThatFits(
                CGSize(width: 220, height: CGFloat.greatestFiniteMagnitude)
            )
            tooltip.preferredContentSize = CGSize(
                width: ceil(size.width) + 32,
                height: ceil(size.height) + 24
            )
            tooltip.view.accessibilityViewIsModal = true
            tooltip.modalPresentationStyle = .popover
            guard let popover = tooltip.popoverPresentationController else { return }
            popover.delegate = self
            popover.sourceView = button
            popover.sourceRect = button.bounds
            popover.permittedArrowDirections = [.up, .down]
            popover.backgroundColor = .secondarySystemGroupedBackground
            traitTooltip = tooltip
            tooltipSourceButton = button
            present(tooltip, animated: true) {
                UIAccessibility.post(notification: .announcement, argument: name)
            }
        }

        if let traitTooltip {
            traitTooltip.dismiss(animated: true, completion: showTooltip)
        } else {
            showTooltip()
        }
    }

    private func reloadTablePreservingScroll() {
        let offset = tableView.contentOffset
        UIView.performWithoutAnimation {
            tableView.reloadData()
            tableView.layoutIfNeeded()
            tableView.setContentOffset(offset, animated: false)
        }
    }

    override func tableView(
        _ tableView: UITableView,
        willDisplayHeaderView view: UIView,
        forSection section: Int
    ) {
        guard let header = view as? UITableViewHeaderFooterView else { return }
        header.textLabel?.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(
            for: .systemFont(ofSize: 12, weight: .semibold)
        )
        header.textLabel?.textColor = .secondaryLabel
        header.contentView.backgroundColor = .clear
    }

    override func tableView(
        _ tableView: UITableView,
        heightForHeaderInSection section: Int
    ) -> CGFloat {
        sections[section] == .message ? UITableView.automaticDimension : 28
    }

    override func tableView(
        _ tableView: UITableView,
        heightForFooterInSection section: Int
    ) -> CGFloat {
        1
    }

    static func shouldCollapseIngredients(_ ingredients: String) -> Bool {
        ingredients.count > 180 || ingredients.filter { $0 == "\n" }.count >= 3
    }
}

extension MenuItemDetailViewController: UIPopoverPresentationControllerDelegate {
    func adaptivePresentationStyle(
        for controller: UIPresentationController
    ) -> UIModalPresentationStyle {
        .none
    }
}

@MainActor
private struct DetailTraitSymbol {
    let id: String
    let assetName: String
    let name: String
    let tintColor: UIColor
}
