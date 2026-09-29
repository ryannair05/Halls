import SwiftUI

@MainActor
final class HeaderDatePickerView: UIView {
    let datePicker = UIDatePicker()
    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private static let relativeDayFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        return formatter
    }()

    init(context: ProviderCalendarContext, horizontalInset: CGFloat = 20) {
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 60))
        Self.configure(datePicker, context: context)
        setupView(horizontalInset: horizontalInset)
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 60)
    }

    func show(title: String?, status: String?) {
        setTitle(title)
        setStatus(status)
    }

    required init?(coder: NSCoder) { nil }

    /// Shared PSU date control styling with each provider's own calendar and horizon.
    static func configure(_ picker: UIDatePicker, context: ProviderCalendarContext) {
        picker.datePickerMode = .date
        picker.preferredDatePickerStyle = .compact
        picker.setContentHuggingPriority(.required, for: .horizontal)
        picker.calendar = context.calendar
        picker.timeZone = context.timeZone
        if let range = context.permittedRange(relativeTo: .now) {
            picker.minimumDate = context.date(on: range.lowerBound, minutesAfterMidnight: 0)
            picker.maximumDate = context.date(on: range.upperBound, minutesAfterMidnight: 1_439)
        }
    }

    func remakeView(
        query: DiningQuery,
        selectedMeal: String,
        dayHours: DayHours?,
        hasPublishedItems: Bool
    ) {
        guard hasPublishedItems, !selectedMeal.isEmpty else {
            setTitle(nil)
            setStatus("No menu published")
            return
        }
        guard let dayHours else {
            setTitle(nil)
            setStatus("Hours unavailable")
            return
        }
        let intervals = Self.intervals(
            for: selectedMeal,
            in: dayHours
        )
        guard !intervals.isEmpty else {
            setTitle(nil)
            setStatus("Hours unavailable")
            return
        }
        setTitle(Self.serviceWindowDescription(intervals: intervals, query: query))
        setStatus(Self.status(intervals: intervals, query: query, now: .now))
    }

    private static func intervals(
        for meal: String,
        in hours: DayHours
    ) -> [DiningHoursInterval] {
        hours.intervals.filter { interval in
            interval.label.map {
                DiningServicePeriodNormalizer.menuLabel(meal, matchesHoursLabel: $0)
            } ?? false
        }
    }

    private static func serviceWindowDescription(
        intervals: [DiningHoursInterval],
        query: DiningQuery
    ) -> String? {
        let style = Date.IntervalFormatStyle(
            date: .omitted,
            time: .shortened,
            locale: .current,
            calendar: query.calendarContext.calendar,
            timeZone: query.calendarContext.timeZone
        )
        let descriptions = intervals.compactMap { interval -> String? in
            guard let start = query.calendarContext.date(on: query.localDate, minutesAfterMidnight: interval.startMinutesAfterMidnight),
                  let end = query.calendarContext.date(on: query.localDate, minutesAfterMidnight: interval.endMinutesAfterMidnight),
                  start <= end else { return nil }
            return (start..<end).formatted(style)
        }
        return descriptions.isEmpty ? nil : descriptions.joined(separator: " · ")
    }

    private static func status(
        intervals: [DiningHoursInterval],
        query: DiningQuery,
        now: Date
    ) -> String {
        let today = query.calendarContext.serviceDate(containing: now)
        if query.localDate != today,
           let todayDate = today.date(in: query.calendarContext.timeZone),
           let selectedDate = query.localDate.date(in: query.calendarContext.timeZone) {
            let dayDifference = query.calendarContext.calendar.dateComponents(
                [.day],
                from: todayDate,
                to: selectedDate
            ).day ?? 0
            let relativeDay = relativeDayFormatter.localizedString(
                from: DateComponents(day: dayDifference)
            )
            return query.localDate > today ? "Opens \(relativeDay)" : "Closed \(relativeDay)"
        }
        let concrete = intervals.compactMap { interval -> (Date, Date)? in
            guard let start = query.calendarContext.date(on: query.localDate, minutesAfterMidnight: interval.startMinutesAfterMidnight),
                  let end = query.calendarContext.date(on: query.localDate, minutesAfterMidnight: interval.endMinutesAfterMidnight) else { return nil }
            return (start, end)
        }
        if let active = concrete.first(where: { $0.0 <= now && now < $0.1 }) {
            return "Open · Closes \(relative(active.1, to: now))"
        }
        if let next = concrete.first(where: { now < $0.0 }) {
            return "Opens \(relative(next.0, to: now))"
        }
        return "Closed"
    }

    static func relative(_ event: Date, to now: Date) -> String {
        let minutes = max(1, Int(ceil(event.timeIntervalSince(now) / 60)))
        if minutes < 60 { return "in \(minutes) min" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "in \(hours) hr" : "in \(hours) hr \(remainder) min"
    }

    private func setTitle(_ text: String?) {
        titleLabel.text = text
        titleLabel.isHidden = text?.isEmpty ?? true
    }

    private func setStatus(_ text: String?) {
        statusLabel.text = text
        statusLabel.textColor = if text?.hasPrefix("Open ·") == true {
            .systemGreen
        } else if text?.hasPrefix("Opens") == true {
            .systemOrange
        } else if text?.hasPrefix("Closed") == true {
            .systemRed
        } else {
            .secondaryLabel
        }
        statusLabel.isHidden = text?.isEmpty ?? true
    }

    private func setupView(horizontalInset: CGFloat) {
        let text = UIStackView(arrangedSubviews: [titleLabel, statusLabel])
        text.axis = .vertical
        text.alignment = .leading
        text.spacing = 2
        let spacer = UIView()
        let content = UIStackView(arrangedSubviews: [text, spacer, datePicker])
        content.axis = .horizontal
        content.alignment = .center
        content.spacing = 8

        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.accessibilityIdentifier = "dining-hours-window"
        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.accessibilityIdentifier = "dining-hours-status"
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        spacer.setContentHuggingPriority(.fittingSizeLevel, for: .horizontal)

        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: horizontalInset),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -horizontalInset),
            content.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
}

@MainActor
struct CATABusController: UIViewControllerRepresentable {
    let purchaseManager: PurchaseManager
    func makeUIViewController(context: Context) -> UINavigationController {
        let controller = KMLViewerViewController()
        context.coordinator.controller = controller
        controller.proAccessProvider = { [purchaseManager] in purchaseManager.hasUnlockedPro }
        controller.presentPro = { [purchaseManager] presenter, completion in
            let host = TransitProHostingController(rootView: ProContent(purchaseManager: purchaseManager))
            host.onDismiss = { completion(purchaseManager.hasUnlockedPro) }
            presenter.present(host, animated: true)
        }
        return UINavigationController(rootViewController: controller)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func updateUIViewController(_ navigation: UINavigationController, context: Context) {
        context.coordinator.routePendingLink()
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var controller: KMLViewerViewController?
        override init() {
            super.init()
            NotificationCenter.default.addObserver(
                self, selector: #selector(routePendingLink), name: .meetAndEatOpenLink, object: nil
            )
        }

        @objc func routePendingLink() {
            guard let controller,
                  let request = MeetAndEatLinkNavigation.pending,
                  case let .cata(routeID, stopID) = request.route else { return }
            MeetAndEatLinkNavigation.consume(request)
            controller.openLinkedRoute(routeID.map(NSNumber.init(value:)), stop: stopID.map(NSNumber.init(value:)))
        }
    }
}

/// UIKit completion covers both SwiftUI's purchase dismissal and an interactive swipe.
/// There is no transaction subscription or recurring entitlement work on the map.
@MainActor
private final class TransitProHostingController: UIHostingController<ProContent> {
    var onDismiss: (() -> Void)?

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil {
            let completion = onDismiss
            onDismiss = nil
            completion?()
        }
    }
}
