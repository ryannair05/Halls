import Foundation
@preconcurrency import LinkPresentation
import UIKit

enum MenuShareAppearance: Int, Sendable, Equatable {
    case light
    case dark
}

struct MenuShareConfiguration: Sendable, Equatable {
    var appearance: MenuShareAppearance = .light
    var showsHallName = true
    var showsMealAndDate = true
    var showsItemLabels = true
    var showsBranding = true
    var message: String?
}

struct MenuShareItemIdentifier: Hashable, Sendable {
    let sectionIndex: Int
    let itemIndex: Int
}

struct MenuShareItem: Sendable, Equatable {
    let name: String
    let itemLabels: [String]
}

struct MenuShareSection: Sendable, Equatable {
    let name: String
    let items: [MenuShareItem]
}

private struct MenuSharePalette: Sendable, Equatable {
    let background: UIColor
    let primaryText: UIColor
    let secondaryText: UIColor
    let divider: UIColor
    let accent: UIColor

    static let light = MenuSharePalette(
        background: UIColor(red: 0.985, green: 0.985, blue: 0.992, alpha: 1),
        primaryText: UIColor(red: 0.075, green: 0.082, blue: 0.105, alpha: 1),
        secondaryText: UIColor(red: 0.38, green: 0.40, blue: 0.45, alpha: 1),
        divider: UIColor(red: 0.86, green: 0.87, blue: 0.89, alpha: 1),
        accent: UIColor(red: 0.02, green: 0.38, blue: 0.78, alpha: 1)
    )

    static let dark = MenuSharePalette(
        background: UIColor(red: 0.067, green: 0.071, blue: 0.086, alpha: 1),
        primaryText: UIColor(red: 0.96, green: 0.96, blue: 0.98, alpha: 1),
        secondaryText: UIColor(red: 0.66, green: 0.68, blue: 0.72, alpha: 1),
        divider: UIColor(red: 0.19, green: 0.20, blue: 0.23, alpha: 1),
        accent: UIColor(red: 0.35, green: 0.66, blue: 1, alpha: 1)
    )
}

struct MenuShareComposition: Sendable, Equatable {
    let shareURL: URL?
    let hallName: String
    let mealName: String
    let formattedDate: String
    let sections: [MenuShareSection]
    let configuration: MenuShareConfiguration
    fileprivate let palette: MenuSharePalette

    init(
        snapshot: borrowing MenuDaySnapshot,
        hallName: String,
        period: borrowing MenuMealPeriod,
        selectedItemIDs: Set<MenuShareItemIdentifier>,
        configuration: MenuShareConfiguration,
        localeIdentifier: String = Locale.autoupdatingCurrent.identifier,
        sourceURL: URL? = nil
    ) {
        self.hallName = hallName
        mealName = period.displayName
        if let sourceURL {
            shareURL = sourceURL
        } else {
            shareURL = MeetAndEatURLFactory.staticFallback(
                kind: "hall",
                id: "\(snapshot.key.locationID.provider.rawValue):\(snapshot.key.locationID.rawValue)",
                date: snapshot.key.localDate.description,
                meal: DiningDeepLinkMeal(displayName: period.displayName)?.rawValue
            )
        }

        var normalizedConfiguration = configuration
        normalizedConfiguration.message = configuration.message?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        self.configuration = normalizedConfiguration

        sections = period.sections.enumerated().compactMap { sectionIndex, section in
            let items: [MenuShareItem] = section.items.enumerated().compactMap { itemIndex, item in
                let identifier = MenuShareItemIdentifier(
                    sectionIndex: sectionIndex,
                    itemIndex: itemIndex
                )
                guard selectedItemIDs.contains(identifier) else { return nil }
                return MenuShareItem(
                    name: item.displayName,
                    itemLabels: MenuShareText.cleanedSourceLabels(
                        item.sourceLabels,
                        itemName: item.displayName
                    )
                )
            }
            guard !items.isEmpty else { return nil }
            return MenuShareSection(name: section.displayName, items: items)
        }

        let timeZone = (try? ProviderCalendarContexts.context(
            for: snapshot.key.locationID.provider
        ))?.timeZone ?? .gmt
        let formatters = MenuShareDateFormatters(
            localeIdentifier: localeIdentifier,
            timeZone: timeZone
        )
        formattedDate = formatters.date(snapshot.key.localDate)
        palette = configuration.appearance == .dark ? .dark : .light
    }

    static func allItemIdentifiers(in period: borrowing MenuMealPeriod) -> Set<MenuShareItemIdentifier> {
        Set(period.sections.enumerated().flatMap { sectionIndex, section in
            section.items.indices.map {
                MenuShareItemIdentifier(sectionIndex: sectionIndex, itemIndex: $0)
            }
        })
    }

    static func defaultItemIdentifiers(in period: borrowing MenuMealPeriod) -> Set<MenuShareItemIdentifier> {
        var identifiers = Set<MenuShareItemIdentifier>()
        var includedSectionCount = 0
        for sectionIndex in period.sections.indices {
            let section = period.sections[sectionIndex]
            guard !section.items.isEmpty else { continue }
            for itemIndex in section.items.indices {
                identifiers.insert(MenuShareItemIdentifier(
                    sectionIndex: sectionIndex,
                    itemIndex: itemIndex
                ))
            }
            includedSectionCount += 1
            if includedSectionCount == 4 { break }
        }
        return identifiers
    }
}

private struct MenuShareDateFormatters {
    private let dateFormatter: DateFormatter

    init(localeIdentifier: String, timeZone: TimeZone) {
        let locale = Locale(identifier: localeIdentifier)
        let dateFormatter = DateFormatter()
        dateFormatter.locale = locale
        dateFormatter.calendar = Calendar(identifier: .gregorian)
        dateFormatter.timeZone = timeZone
        dateFormatter.dateStyle = .full
        dateFormatter.timeStyle = .none
        self.dateFormatter = dateFormatter
    }

    func date(_ date: DateOnly) -> String {
        guard let value = date.date(in: dateFormatter.timeZone) else {
            return date.description
        }
        return dateFormatter.string(from: value)
    }
}

private enum MenuShareText {
    static func cleanedSourceLabels(_ labels: [String], itemName: String) -> [String] {
        var normalizedLabels = Set<String>()
        return labels.compactMap { sourceLabel in
            let label = sourceLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty,
                  label.localizedCaseInsensitiveCompare(itemName) != .orderedSame else {
                return nil
            }
            let normalized = label.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: nil
            )
            return normalizedLabels.insert(normalized).inserted ? label : nil
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

enum MenuShareRenderError: Error, LocalizedError, Sendable {
    case cancelled
    case emptySelection
    case imageTooTall

    var errorDescription: String? {
        switch self {
        case .cancelled:
            nil
        case .emptySelection:
            "Select at least one menu item to share."
        case .imageTooTall:
            "This menu is too tall for one image. Select fewer dishes and try again."
        }
    }
}

struct MenuShareRenderer {
    static let logicalWidth: CGFloat = 600
    static let exportScale: CGFloat = 2
    private static let maximumPixelDimension: CGFloat = 32_768

    private struct Metrics {
        let contentInset: CGFloat = 42
        let topInset: CGFloat = 36
        let bottomInset: CGFloat = 36
        let titleFont = UIFont.systemFont(ofSize: 31, weight: .bold)
        let contextFont = UIFont.systemFont(ofSize: 17, weight: .semibold)
        let messageFont = UIFont.systemFont(ofSize: 18, weight: .medium)
        let sectionFont = UIFont.systemFont(ofSize: 14, weight: .semibold)
        let itemFont = UIFont.systemFont(ofSize: 18, weight: .regular)
        let sourceFont = UIFont.systemFont(ofSize: 12.5, weight: .regular)
        let sectionSpacing: CGFloat = 25
        let itemTopPadding: CGFloat = 9
        let itemBottomPadding: CGFloat = 10
        let sourceSpacing: CGFloat = 3

        var contentWidth: CGFloat {
            MenuShareRenderer.logicalWidth - contentInset * 2
        }
    }

    private struct ItemLayout {
        let nameRect: CGRect
        let sourceRect: CGRect?
        let separatorY: CGFloat?
    }

    private struct SectionLayout {
        let headingRect: CGRect?
        let items: [ItemLayout]
    }

    private struct FooterLayout {
        let separatorY: CGFloat
        let iconRect: CGRect
        let brandRect: CGRect
        let siteRect: CGRect
    }

    private struct Layout {
        let height: CGFloat
        let hallRect: CGRect?
        let contextRect: CGRect?
        let messageRect: CGRect?
        let messageRuleRect: CGRect?
        let headerSeparatorY: CGFloat?
        let sections: [SectionLayout]
        let footer: FooterLayout?
    }

    @concurrent
    func image(
        for composition: MenuShareComposition
    ) async throws(MenuShareRenderError) -> UIImage {
        try checkCancellation()
        guard composition.sections.contains(where: { !$0.items.isEmpty }) else {
            throw .emptySelection
        }
        let metrics = Metrics()
        let layout = measure(composition, metrics: metrics)
        guard layout.height * Self.exportScale <= Self.maximumPixelDimension else {
            throw .imageTooTall
        }
        try checkCancellation()
        let image = render(composition, layout: layout, metrics: metrics)
        try checkCancellation()
        return image
    }

    private func measure(_ composition: MenuShareComposition, metrics: Metrics) -> Layout {
        let width = metrics.contentWidth
        var y = metrics.topInset
        var hallRect: CGRect?
        var contextRect: CGRect?
        var messageRect: CGRect?
        var messageRuleRect: CGRect?

        if composition.configuration.showsHallName {
            let height = textHeight(composition.hallName, font: metrics.titleFont, width: width)
            hallRect = CGRect(x: metrics.contentInset, y: y, width: width, height: height)
            y += height + 8
        }
        if composition.configuration.showsMealAndDate {
            let context = "\(composition.mealName) · \(composition.formattedDate)"
            let height = textHeight(context, font: metrics.contextFont, width: width)
            contextRect = CGRect(x: metrics.contentInset, y: y, width: width, height: height)
            y += height + 7
        }
        if let message = composition.configuration.message {
            y += 13
            let messageX = metrics.contentInset + 16
            let messageWidth = width - 16
            let height = textHeight(message, font: metrics.messageFont, width: messageWidth)
            messageRuleRect = CGRect(x: metrics.contentInset, y: y + 1, width: 3, height: height + 2)
            messageRect = CGRect(x: messageX, y: y, width: messageWidth, height: height)
            y += height + 15
        }

        let hasHeader = hallRect != nil || contextRect != nil || messageRect != nil
        let headerSeparatorY: CGFloat?
        if hasHeader {
            y += 11
            headerSeparatorY = y
            y += 21
        } else {
            headerSeparatorY = nil
        }

        var sectionLayouts: [SectionLayout] = []
        sectionLayouts.reserveCapacity(composition.sections.count)
        for (sectionIndex, section) in composition.sections.enumerated() {
            if sectionIndex > 0 { y += metrics.sectionSpacing }
            let headingHeight = textHeight(section.name, font: metrics.sectionFont, width: width)
            let headingRect = CGRect(
                x: metrics.contentInset,
                y: y,
                width: width,
                height: headingHeight
            )
            y += headingHeight + 7

            var itemLayouts: [ItemLayout] = []
            itemLayouts.reserveCapacity(section.items.count)
            for (itemIndex, item) in section.items.enumerated() {
                y += metrics.itemTopPadding
                let nameHeight = textHeight(item.name, font: metrics.itemFont, width: width)
                let nameRect = CGRect(
                    x: metrics.contentInset,
                    y: y,
                    width: width,
                    height: nameHeight
                )
                y += nameHeight

                let sourceText = item.itemLabels.joined(separator: " · ")
                let sourceRect: CGRect?
                if composition.configuration.showsItemLabels, !sourceText.isEmpty {
                    y += metrics.sourceSpacing
                    let sourceHeight = textHeight(sourceText, font: metrics.sourceFont, width: width)
                    sourceRect = CGRect(
                        x: metrics.contentInset,
                        y: y,
                        width: width,
                        height: sourceHeight
                    )
                    y += sourceHeight
                } else {
                    sourceRect = nil
                }
                y += metrics.itemBottomPadding

                let separatorY: CGFloat?
                if itemIndex < section.items.count - 1 {
                    separatorY = y
                    y += 1
                } else {
                    separatorY = nil
                }
                itemLayouts.append(ItemLayout(
                    nameRect: nameRect,
                    sourceRect: sourceRect,
                    separatorY: separatorY
                ))
            }
            sectionLayouts.append(SectionLayout(headingRect: headingRect, items: itemLayouts))
        }

        let footer: FooterLayout?
        if composition.configuration.showsBranding {
            y += 31
            let separatorY = y
            y += 18
            let iconRect = CGRect(x: metrics.contentInset, y: y, width: 28, height: 28)
            let brandRect = CGRect(x: iconRect.maxX + 10, y: y + 1, width: 210, height: 17)
            let siteRect = CGRect(x: iconRect.maxX + 10, y: y + 17, width: 210, height: 14)
            footer = FooterLayout(
                separatorY: separatorY,
                iconRect: iconRect,
                brandRect: brandRect,
                siteRect: siteRect
            )
            y = iconRect.maxY + metrics.bottomInset
        } else {
            footer = nil
            y += metrics.bottomInset
        }

        return Layout(
            height: ceil(y),
            hallRect: hallRect,
            contextRect: contextRect,
            messageRect: messageRect,
            messageRuleRect: messageRuleRect,
            headerSeparatorY: headerSeparatorY,
            sections: sectionLayouts,
            footer: footer
        )
    }

    private func render(
        _ composition: MenuShareComposition,
        layout: Layout,
        metrics: Metrics
    ) -> UIImage {
        let palette = composition.palette
        return OpaqueImageRenderer.image(
            size: CGSize(width: Self.logicalWidth, height: layout.height),
            scale: Self.exportScale
        ) { context in
            palette.background.setFill()
            context.fill(CGRect(x: 0, y: 0, width: Self.logicalWidth, height: layout.height))

            if let rect = layout.hallRect {
                draw(composition.hallName, in: rect, font: metrics.titleFont, color: palette.primaryText)
            }
            if let rect = layout.contextRect {
                draw(
                    "\(composition.mealName) · \(composition.formattedDate)",
                    in: rect,
                    font: metrics.contextFont,
                    color: palette.accent
                )
            }
            if let message = composition.configuration.message,
               let messageRect = layout.messageRect,
               let ruleRect = layout.messageRuleRect {
                palette.accent.setFill()
                UIBezierPath(roundedRect: ruleRect, cornerRadius: 1.5).fill()
                draw(message, in: messageRect, font: metrics.messageFont, color: palette.primaryText)
            }
            if let separatorY = layout.headerSeparatorY {
                drawSeparator(y: separatorY, metrics: metrics, color: palette.divider, context: context)
            }

            for (section, sectionLayout) in zip(composition.sections, layout.sections) {
                guard !Task.isCancelled else { break }
                if let headingRect = sectionLayout.headingRect {
                    draw(
                        section.name,
                        in: headingRect,
                        font: metrics.sectionFont,
                        color: palette.secondaryText
                    )
                }
                for (item, itemLayout) in zip(section.items, sectionLayout.items) {
                    draw(
                        item.name,
                        in: itemLayout.nameRect,
                        font: metrics.itemFont,
                        color: palette.primaryText
                    )
                    if let sourceRect = itemLayout.sourceRect {
                        draw(
                            item.itemLabels.joined(separator: " · "),
                            in: sourceRect,
                            font: metrics.sourceFont,
                            color: palette.secondaryText
                        )
                    }
                    if let separatorY = itemLayout.separatorY {
                        drawSeparator(
                            y: separatorY,
                            metrics: metrics,
                            color: palette.divider,
                            context: context
                        )
                    }
                }
            }

            if let footer = layout.footer {
                drawSeparator(
                    y: footer.separatorY,
                    metrics: metrics,
                    color: palette.divider,
                    context: context
                )
                context.saveGState()
                UIBezierPath(roundedRect: footer.iconRect, cornerRadius: 6).addClip()
                UIImage.appIcon.draw(in: footer.iconRect)
                context.restoreGState()
                draw(
                    "Meet & Eat",
                    in: footer.brandRect,
                    font: .systemFont(ofSize: 13, weight: .semibold),
                    color: palette.primaryText
                )
                draw(
                    "swiftbyte.app",
                    in: footer.siteRect,
                    font: .systemFont(ofSize: 10.5, weight: .regular),
                    color: palette.secondaryText
                )
            }
        }
    }

    private func textHeight(_ text: String, font: UIFont, width: CGFloat) -> CGFloat {
        ceil((text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: textAttributes(font: font, color: .black),
            context: nil
        ).height)
    }

    private func draw(_ text: String, in rect: CGRect, font: UIFont, color: UIColor) {
        (text as NSString).draw(
            with: rect,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: textAttributes(font: font, color: color),
            context: nil
        )
    }

    private func textAttributes(font: UIFont, color: UIColor) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        return [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
    }

    private func drawSeparator(
        y: CGFloat,
        metrics: Metrics,
        color: UIColor,
        context: CGContext
    ) {
        color.setFill()
        context.fill(CGRect(x: metrics.contentInset, y: y, width: metrics.contentWidth, height: 1))
    }

    private func checkCancellation() throws(MenuShareRenderError) {
        guard Task.isCancelled else { return }
        throw .cancelled
    }
}

@MainActor
final class MenuShareActivityItemSource: NSObject, @preconcurrency UIActivityItemSource {
    private let item: Any
    private let image: UIImage?
    private let title: String
    private let metadataURL: URL?

    init(image: UIImage, title: String, metadataURL: URL? = nil) {
        item = image
        self.image = image
        self.title = title
        self.metadataURL = metadataURL
    }

    convenience init(image: UIImage, title: String, url: URL) {
        self.init(image: image, title: title, metadataURL: url)
    }

    init(title: String, url: URL) {
        item = url
        image = nil
        self.title = title
        metadataURL = url
    }

    func activityViewControllerPlaceholderItem(
        _ activityViewController: UIActivityViewController
    ) -> Any {
        item
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
        item
    }

    func activityViewControllerLinkMetadata(
        _ activityViewController: UIActivityViewController
    ) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = title
        metadata.originalURL = metadataURL
        metadata.url = metadataURL
        if let image {
            metadata.imageProvider = NSItemProvider(object: image)
        }
        metadata.iconProvider = NSItemProvider(object: UIImage.appIcon)
        return metadata
    }
}

@MainActor
final class MenuShareComposerViewController: UITableViewController, UITextViewDelegate {
    private enum TableSection: Int, CaseIterable {
        case content
        case details
    }

    private enum Toggle: Int {
        case hallName
        case mealAndDate
        case itemLabels
        case addMessage
        case branding
    }

    private let snapshot: MenuDaySnapshot
    private let hallName: String
    private let sourceURL: URL?
    private let period: MenuMealPeriod
    private let allItemIDs: Set<MenuShareItemIdentifier>
    private var selectedItemIDs: Set<MenuShareItemIdentifier>
    private var configuration = MenuShareConfiguration()
    private var isMessageEnabled = false
    private var messageDraft = ""
    private var renderTask: Task<Void, Never>?
    private var shareTask: Task<Void, Never>?
    private var renderGeneration = 0
    private var previewComposition: MenuShareComposition?
    private var previewImage: UIImage?
    private var isGeneratingShare = false

    private let previewHeaderView = UIView()
    private let previewContainer = UIView()
    private let previewScrollView = UIScrollView()
    private let previewImageView = UIImageView()
    private let previewStatusLabel = UILabel()
    private var previewImageHeightConstraint: NSLayoutConstraint!
    private let messageTextView = UITextView()
    private let messagePlaceholderLabel = UILabel()

    init(snapshot: MenuDaySnapshot, hallName: String, period: MenuMealPeriod, sourceURL: URL? = nil) {
        self.snapshot = snapshot
        self.hallName = hallName
        self.sourceURL = sourceURL
        self.period = period
        let allItemIDs = MenuShareComposition.allItemIdentifiers(in: period)
        self.allItemIDs = allItemIDs
        selectedItemIDs = MenuShareComposition.defaultItemIdentifiers(in: period)
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        renderTask?.cancel()
        shareTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Share as Image"
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel,
            target: self,
            action: #selector(close)
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Share",
            style: .done,
            target: self,
            action: #selector(share)
        )
        tableView.keyboardDismissMode = .interactive
        configuration.appearance = traitCollection.userInterfaceStyle == .dark ? .dark : .light
        configurePreview()
        configureMessageTextView()
        updateShareButtonState()
        scheduleRender()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updatePreviewHeaderSize()
        updatePreviewImageHeight()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isBeingDismissed || navigationController?.isBeingDismissed == true else { return }
        renderTask?.cancel()
        shareTask?.cancel()
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        TableSection.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch TableSection(rawValue: section) {
        case .content: 1
        case .details: isMessageEnabled ? 7 : 6
        case nil: 0
        }
    }

    override func tableView(
        _ tableView: UITableView,
        titleForHeaderInSection section: Int
    ) -> String? {
        switch TableSection(rawValue: section) {
        case .content: "Content"
        case .details: "Details"
        case nil: nil
        }
    }

    override func tableView(
        _ tableView: UITableView,
        titleForFooterInSection section: Int
    ) -> String? {
        nil
    }

    override func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        switch TableSection(rawValue: indexPath.section) {
        case .content:
            let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
            cell.textLabel?.text = "Menu Items"
            cell.detailTextLabel?.text = selectionSummary
            cell.accessoryType = .disclosureIndicator
            cell.isAccessibilityElement = true
            cell.accessibilityLabel = "Menu Items"
            cell.accessibilityValue = selectionSummary
            cell.accessibilityHint = "Opens menu item selection"
            cell.accessibilityTraits.insert(.button)
            return cell
        case .details:
            if isMessageEnabled, indexPath.row == 4 {
                return messageCell()
            }
            let adjustedRow = isMessageEnabled && indexPath.row > 4
                ? indexPath.row - 1
                : indexPath.row
            let values: [(String, Bool, Toggle)] = [
                ("Hall Name", configuration.showsHallName, .hallName),
                ("Meal & Date", configuration.showsMealAndDate, .mealAndDate),
                ("Item Labels", configuration.showsItemLabels, .itemLabels),
                ("Add Message", isMessageEnabled, .addMessage)
            ]
            if values.indices.contains(adjustedRow) {
                let value = values[adjustedRow]
                return switchCell(title: value.0, isOn: value.1, toggle: value.2)
            }
            if adjustedRow == 4 {
                return segmentedCell(
                    title: "Appearance",
                    items: ["Light", "Dark"],
                    selectedIndex: configuration.appearance.rawValue,
                    tag: 0
                )
            }
            return switchCell(
                title: "Meet & Eat Branding",
                isOn: configuration.showsBranding,
                toggle: .branding
            )
        case nil:
            return UITableViewCell()
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard TableSection(rawValue: indexPath.section) == .content else { return }
        let selector = MenuShareItemSelectionViewController(
            period: period,
            selectedItemIDs: selectedItemIDs
        )
        selector.onSelectionChanged = { [weak self] selection in
            guard let self else { return }
            selectedItemIDs = selection
            tableView.reloadRows(at: [IndexPath(row: 0, section: TableSection.content.rawValue)], with: .none)
            updateShareButtonState()
            scheduleRender()
        }
        navigationController?.pushViewController(selector, animated: true)
    }

    func textViewDidChange(_ textView: UITextView) {
        messageDraft = textView.text
        messagePlaceholderLabel.isHidden = !messageDraft.isEmpty
        configuration.message = normalizedMessage
        scheduleRender()
    }

    @objc private func close() {
        renderTask?.cancel()
        shareTask?.cancel()
        dismiss(animated: true)
    }

    @objc private func toggleChanged(_ sender: UISwitch) {
        guard let toggle = Toggle(rawValue: sender.tag) else { return }
        switch toggle {
        case .hallName: configuration.showsHallName = sender.isOn
        case .mealAndDate: configuration.showsMealAndDate = sender.isOn
        case .itemLabels: configuration.showsItemLabels = sender.isOn
        case .addMessage:
            isMessageEnabled = sender.isOn
            configuration.message = sender.isOn ? normalizedMessage : nil
            tableView.reloadSections(IndexSet(integer: TableSection.details.rawValue), with: .automatic)
        case .branding: configuration.showsBranding = sender.isOn
        }
        scheduleRender()
    }

    @objc private func segmentedControlChanged(_ sender: UISegmentedControl) {
        configuration.appearance = MenuShareAppearance(rawValue: sender.selectedSegmentIndex) ?? .light
        scheduleRender()
    }

    @objc private func share() {
        guard !selectedItemIDs.isEmpty, !isGeneratingShare else { return }
        let composition = makeComposition()
        shareTask?.cancel()
        isGeneratingShare = true
        updateShareButtonState()
        shareTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                isGeneratingShare = false
                updateShareButtonState()
            }
            do {
                let image: UIImage
                if previewComposition == composition, let previewImage {
                    image = previewImage
                } else {
                    image = try await MenuShareRenderer().image(for: composition)
                }
                guard !Task.isCancelled, viewIfLoaded?.window != nil else { return }
                let source = MenuShareActivityItemSource(
                    image: image,
                    title: "\(composition.hallName) · \(composition.mealName)"
                )
                var activityItems: [Any] = [source]
                if let url = composition.shareURL { activityItems.append(url) }
                let activity = UIActivityViewController(
                    activityItems: activityItems,
                    applicationActivities: nil
                )
                activity.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
                present(activity, animated: true)
            } catch let error as MenuShareRenderError {
                guard error != .cancelled, viewIfLoaded?.window != nil else { return }
                presentRenderError(error)
            } catch {
                assertionFailure("Unexpected menu share render error: \(error)")
            }
        }
    }

    private func configurePreview() {
        previewContainer.backgroundColor = .secondarySystemGroupedBackground
        previewContainer.layer.cornerRadius = 14
        previewContainer.layer.cornerCurve = .continuous
        previewContainer.clipsToBounds = true
        previewContainer.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.heightAnchor.constraint(equalToConstant: 390).isActive = true

        previewScrollView.alwaysBounceVertical = true
        previewScrollView.showsVerticalScrollIndicator = true
        previewScrollView.accessibilityLabel = "Share image preview"
        previewScrollView.accessibilityHint = "Scrolls through the complete image that will be shared"
        previewScrollView.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.addSubview(previewScrollView)

        previewImageView.contentMode = .scaleToFill
        previewImageView.backgroundColor = .secondarySystemGroupedBackground
        previewImageView.isAccessibilityElement = true
        previewImageView.accessibilityLabel = "Generated menu image"
        previewImageView.translatesAutoresizingMaskIntoConstraints = false
        previewScrollView.addSubview(previewImageView)
        previewImageHeightConstraint = previewImageView.heightAnchor.constraint(equalToConstant: 390)

        NSLayoutConstraint.activate([
            previewScrollView.topAnchor.constraint(equalTo: previewContainer.topAnchor),
            previewScrollView.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
            previewScrollView.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
            previewScrollView.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor),
            previewImageView.topAnchor.constraint(equalTo: previewScrollView.contentLayoutGuide.topAnchor),
            previewImageView.leadingAnchor.constraint(equalTo: previewScrollView.contentLayoutGuide.leadingAnchor),
            previewImageView.trailingAnchor.constraint(equalTo: previewScrollView.contentLayoutGuide.trailingAnchor),
            previewImageView.bottomAnchor.constraint(equalTo: previewScrollView.contentLayoutGuide.bottomAnchor),
            previewImageView.widthAnchor.constraint(equalTo: previewScrollView.frameLayoutGuide.widthAnchor),
            previewImageHeightConstraint
        ])

        previewStatusLabel.font = .preferredFont(forTextStyle: .footnote)
        previewStatusLabel.adjustsFontForContentSizeCategory = true
        previewStatusLabel.textColor = .secondaryLabel
        previewStatusLabel.textAlignment = .center
        previewStatusLabel.numberOfLines = 0
        previewStatusLabel.text = "Preparing preview…"

        let stack = UIStackView(arrangedSubviews: [previewContainer, previewStatusLabel])
        stack.axis = .vertical
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false
        previewHeaderView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: previewHeaderView.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: previewHeaderView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: previewHeaderView.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: previewHeaderView.bottomAnchor, constant: -12)
        ])
        tableView.tableHeaderView = previewHeaderView
    }

    private func configureMessageTextView() {
        messageTextView.font = .preferredFont(forTextStyle: .body)
        messageTextView.adjustsFontForContentSizeCategory = true
        messageTextView.backgroundColor = .secondarySystemGroupedBackground
        messageTextView.layer.cornerRadius = 10
        messageTextView.layer.cornerCurve = .continuous
        messageTextView.delegate = self
        messageTextView.accessibilityLabel = "Message"
        messageTextView.translatesAutoresizingMaskIntoConstraints = false

        messagePlaceholderLabel.text = "Add a message…"
        messagePlaceholderLabel.font = .preferredFont(forTextStyle: .body)
        messagePlaceholderLabel.adjustsFontForContentSizeCategory = true
        messagePlaceholderLabel.textColor = .placeholderText
        messagePlaceholderLabel.translatesAutoresizingMaskIntoConstraints = false
        messageTextView.addSubview(messagePlaceholderLabel)
        NSLayoutConstraint.activate([
            messagePlaceholderLabel.topAnchor.constraint(equalTo: messageTextView.topAnchor, constant: 8),
            messagePlaceholderLabel.leadingAnchor.constraint(equalTo: messageTextView.leadingAnchor, constant: 5)
        ])
    }

    private func updatePreviewHeaderSize() {
        let width = tableView.bounds.width
        guard width > 0 else { return }
        previewHeaderView.bounds.size.width = width
        let height = previewHeaderView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        guard abs(previewHeaderView.frame.height - height) > 0.5 else { return }
        previewHeaderView.frame.size = CGSize(width: width, height: height)
        tableView.tableHeaderView = previewHeaderView
    }

    private func updatePreviewImageHeight() {
        guard let image = previewImageView.image, image.size.width > 0 else { return }
        let width = previewScrollView.bounds.width
        guard width > 0 else { return }
        let height = ceil(width * image.size.height / image.size.width)
        if abs(previewImageHeightConstraint.constant - height) > 0.5 {
            previewImageHeightConstraint.constant = height
        }
    }

    private func switchCell(title: String, isOn: Bool, toggle: Toggle) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.text = title
        cell.contentConfiguration = content
        let control = UISwitch()
        control.isOn = isOn
        control.tag = toggle.rawValue
        control.accessibilityLabel = title
        control.addTarget(self, action: #selector(toggleChanged(_:)), for: .valueChanged)
        cell.accessoryView = control
        cell.selectionStyle = .none
        return cell
    }

    private func segmentedCell(
        title: String,
        items: [String],
        selectedIndex: Int,
        tag: Int
    ) -> UITableViewCell {
        let cell = MenuShareSegmentedCell(title: title, items: items)
        cell.segmentedControl.selectedSegmentIndex = selectedIndex
        cell.segmentedControl.tag = tag
        cell.segmentedControl.accessibilityLabel = title
        cell.segmentedControl.addTarget(
            self,
            action: #selector(segmentedControlChanged(_:)),
            for: .valueChanged
        )
        return cell
    }

    private func messageCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        messageTextView.removeFromSuperview()
        cell.contentView.addSubview(messageTextView)
        NSLayoutConstraint.activate([
            messageTextView.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 10),
            messageTextView.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
            messageTextView.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
            messageTextView.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -10),
            messageTextView.heightAnchor.constraint(greaterThanOrEqualToConstant: 96)
        ])
        cell.selectionStyle = .none
        return cell
    }

    private var selectionSummary: String {
        if !allItemIDs.isEmpty, selectedItemIDs == allItemIDs { return "All Items" }
        return selectedItemIDs.count == 1 ? "1 Item" : "\(selectedItemIDs.count) Items"
    }

    private var normalizedMessage: String? {
        messageDraft.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private func makeComposition() -> MenuShareComposition {
        MenuShareComposition(
            snapshot: snapshot,
            hallName: hallName,
            period: period,
            selectedItemIDs: selectedItemIDs,
            configuration: configuration,
            sourceURL: sourceURL
        )
    }

    private func scheduleRender() {
        renderTask?.cancel()
        renderGeneration += 1
        let generation = renderGeneration
        guard !selectedItemIDs.isEmpty else {
            previewComposition = nil
            previewImage = nil
            previewImageView.image = nil
            previewStatusLabel.text = "Select at least one menu item"
            updateShareButtonState()
            return
        }
        previewStatusLabel.text = previewImage == nil ? "Preparing preview…" : "Updating preview…"
        renderTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard let self, !Task.isCancelled, generation == renderGeneration else { return }
            let composition = makeComposition()
            do {
                let image = try await MenuShareRenderer().image(for: composition)
                guard !Task.isCancelled, generation == renderGeneration else { return }
                previewComposition = composition
                previewImage = image
                previewImageView.image = image
                previewStatusLabel.text = "Preview of shared image"
                updatePreviewImageHeight()
            } catch let error as MenuShareRenderError {
                guard error != .cancelled, generation == renderGeneration else { return }
                previewComposition = nil
                previewImage = nil
                previewImageView.image = nil
                previewStatusLabel.text = error.localizedDescription
            } catch {
                assertionFailure("Unexpected menu share preview error: \(error)")
            }
        }
    }

    private func updateShareButtonState() {
        navigationItem.rightBarButtonItem?.isEnabled = !selectedItemIDs.isEmpty && !isGeneratingShare
    }

    private func presentRenderError(_ error: MenuShareRenderError) {
        let alert = UIAlertController(
            title: "Unable to Create Image",
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

@MainActor
private final class MenuShareSegmentedCell: UITableViewCell {
    let segmentedControl: UISegmentedControl

    init(title: String, items: [String]) {
        segmentedControl = UISegmentedControl(items: items)
        super.init(style: .default, reuseIdentifier: nil)

        let label = UILabel()
        label.text = title
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true

        let stack = UIStackView(arrangedSubviews: [label, segmentedControl])
        stack.axis = .vertical
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 11),
            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -11)
        ])
        selectionStyle = .none
    }

    required init?(coder: NSCoder) {
        nil
    }
}

@MainActor
private final class MenuShareItemSelectionViewController: UITableViewController {
    private let period: MenuMealPeriod
    private let visibleSectionIndexes: [Int]
    private let allItemIDs: Set<MenuShareItemIdentifier>
    private var selectedItemIDs: Set<MenuShareItemIdentifier>
    var onSelectionChanged: ((Set<MenuShareItemIdentifier>) -> Void)?

    init(period: MenuMealPeriod, selectedItemIDs: Set<MenuShareItemIdentifier>) {
        self.period = period
        visibleSectionIndexes = period.sections.indices.filter { !period.sections[$0].items.isEmpty }
        allItemIDs = MenuShareComposition.allItemIdentifiers(in: period)
        self.selectedItemIDs = selectedItemIDs
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Menu Items"
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(title: "Clear", style: .plain, target: self, action: #selector(clearSelection)),
            UIBarButtonItem(title: "Select All", style: .plain, target: self, action: #selector(selectAllItems))
        ]
        updateBarButtonState()
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        visibleSectionIndexes.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        period.sections[visibleSectionIndexes[section]].items.count
    }

    override func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let sourceSectionIndex = visibleSectionIndexes[indexPath.section]
        let item = period.sections[sourceSectionIndex].items[indexPath.row]
        let identifier = MenuShareItemIdentifier(
            sectionIndex: sourceSectionIndex,
            itemIndex: indexPath.row
        )
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = item.displayName
        let labels = MenuShareText.cleanedSourceLabels(item.sourceLabels, itemName: item.displayName)
        cell.detailTextLabel?.text = labels.isEmpty ? nil : labels.joined(separator: " · ")
        let isSelected = selectedItemIDs.contains(identifier)
        cell.accessoryType = isSelected ? .checkmark : .none
        cell.accessibilityLabel = item.displayName
        cell.accessibilityValue = isSelected ? "Selected" : "Not selected"
        cell.accessibilityHint = "Double tap to toggle this dish"
        if isSelected { cell.accessibilityTraits.insert(.selected) }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let identifier = MenuShareItemIdentifier(
            sectionIndex: visibleSectionIndexes[indexPath.section],
            itemIndex: indexPath.row
        )
        if selectedItemIDs.remove(identifier) == nil {
            selectedItemIDs.insert(identifier)
        }
        selectionDidChange()
        tableView.reloadRows(at: [indexPath], with: .automatic)
        tableView.reloadSections(IndexSet(integer: indexPath.section), with: .none)
    }

    override func tableView(
        _ tableView: UITableView,
        viewForHeaderInSection section: Int
    ) -> UIView? {
        let sourceSectionIndex = visibleSectionIndexes[section]
        let menuSection = period.sections[sourceSectionIndex]
        let identifiers = Set(menuSection.items.indices.map {
            MenuShareItemIdentifier(sectionIndex: sourceSectionIndex, itemIndex: $0)
        })
        let allSelected = identifiers.isSubset(of: selectedItemIDs)
        return MenuShareSelectionHeaderView(
            title: menuSection.displayName,
            actionTitle: allSelected ? "Clear" : "Select All"
        ) { [weak self] in
            guard let self else { return }
            if identifiers.isSubset(of: selectedItemIDs) {
                selectedItemIDs.subtract(identifiers)
            } else {
                selectedItemIDs.formUnion(identifiers)
            }
            selectionDidChange()
            tableView.reloadSections(IndexSet(integer: section), with: .automatic)
        }
    }

    override func tableView(
        _ tableView: UITableView,
        heightForHeaderInSection section: Int
    ) -> CGFloat {
        48
    }

    @objc private func selectAllItems() {
        selectedItemIDs = allItemIDs
        selectionDidChange()
        tableView.reloadData()
    }

    @objc private func clearSelection() {
        selectedItemIDs.removeAll(keepingCapacity: true)
        selectionDidChange()
        tableView.reloadData()
    }

    private func selectionDidChange() {
        updateBarButtonState()
        onSelectionChanged?(selectedItemIDs)
    }

    private func updateBarButtonState() {
        navigationItem.rightBarButtonItems?[0].isEnabled = !selectedItemIDs.isEmpty
        navigationItem.rightBarButtonItems?[1].isEnabled = selectedItemIDs != allItemIDs
    }
}

@MainActor
private final class MenuShareSelectionHeaderView: UIView {
    init(title: String, actionTitle: String, action: @escaping () -> Void) {
        super.init(frame: .zero)
        let label = UILabel()
        label.text = title
        label.font = .preferredFont(forTextStyle: .headline)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 2

        var buttonConfiguration = UIButton.Configuration.plain()
        buttonConfiguration.title = actionTitle
        buttonConfiguration.contentInsets = NSDirectionalEdgeInsets(
            top: 8,
            leading: 10,
            bottom: 8,
            trailing: 10
        )
        let button = UIButton(configuration: buttonConfiguration, primaryAction: UIAction { _ in action() })
        button.accessibilityLabel = "\(actionTitle) in \(title)"
        button.setContentHuggingPriority(.required, for: .horizontal)

        let stack = UIStackView(arrangedSubviews: [label, button])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }
}
