import UIKit

struct NutritionFactsPresentation: Equatable, Sendable {
    enum RowStyle: Equatable, Sendable {
        case parent
        case child
        case addedSugar
        case regular

        var indentation: CGFloat {
            switch self {
            case .parent, .regular: 0
            case .child: 16
            case .addedSugar: 28
            }
        }
    }

    struct Row: Equatable, Sendable {
        let name: String
        let amount: String
        let dailyValue: String?
        let style: RowStyle
        let isPrimary: Bool
    }

    let servingSize: DiningNutritionFact?
    let calories: DiningNutritionFact?
    let rows: [Row]

    init(facts: [DiningNutritionFact]) {
        var servingSize: DiningNutritionFact?
        var calories: DiningNutritionFact?
        var rankedRows: [(rank: Int, sourceOrder: Int, row: Row)] = []

        for (sourceOrder, fact) in facts.enumerated() {
            let normalizedName = DiningTextNormalizer.foldedWords(fact.name)
            if normalizedName == "serving size" {
                servingSize = servingSize ?? fact
                continue
            }
            if normalizedName == "calories" {
                calories = calories ?? fact
                continue
            }
            guard normalizedName != "calories from fat" else { continue }

            let value = Self.splitValue(fact.value)
            let metadata = Self.metadata(for: normalizedName)
            rankedRows.append((
                rank: metadata.rank,
                sourceOrder: sourceOrder,
                row: Row(
                    name: fact.name,
                    amount: value.amount,
                    dailyValue: value.dailyValue,
                    style: metadata.style,
                    isPrimary: metadata.isPrimary
                )
            ))
        }

        self.servingSize = servingSize
        self.calories = calories
        self.rows = rankedRows.sorted {
            ($0.rank, $0.sourceOrder) < ($1.rank, $1.sourceOrder)
        }.map(\.row)
    }

    func displayedRows(expanded: Bool) -> [Row] {
        expanded ? rows : rows.filter(\.isPrimary)
    }

    private static func splitValue(_ value: String) -> (amount: String, dailyValue: String?) {
        guard let separator = value.range(of: " · ", options: .backwards) else {
            return (value, nil)
        }
        let dailyValue = String(value[separator.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard dailyValue.contains("%") else { return (value, nil) }
        let amount = String(value[..<separator.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (amount, dailyValue)
    }

    private static func metadata(
        for normalizedName: String
    ) -> (rank: Int, style: RowStyle, isPrimary: Bool) {
        switch normalizedName {
        case "total fat": (100, .parent, true)
        case "saturated fat", "sat fat": (110, .child, false)
        case "trans fat": (120, .child, false)
        case "cholesterol": (200, .parent, false)
        case "sodium": (300, .parent, false)
        case "total carbohydrate", "total carb": (400, .parent, true)
        case "dietary fiber", "fiber": (410, .child, false)
        case "total sugars", "sugars", "sugar": (420, .child, false)
        case "added sugars", "added sugar": (430, .addedSugar, false)
        case "protein": (500, .parent, true)
        case "vitamin d": (600, .regular, false)
        case "calcium": (610, .regular, false)
        case "iron": (620, .regular, false)
        case "potassium": (630, .regular, false)
        default: (1_000, .regular, false)
        }
    }

}

@MainActor
final class NutritionFactsCardView: UIView {
    private(set) var presentation: NutritionFactsPresentation
    private(set) var isExpanded: Bool
    private let contentStack = UIStackView()

    init(
        facts: [DiningNutritionFact],
        expanded: Bool,
        interfaceStyle: UIUserInterfaceStyle? = nil
    ) {
        self.presentation = NutritionFactsPresentation(facts: facts)
        self.isExpanded = expanded
        super.init(frame: .zero)
        if let interfaceStyle {
            overrideUserInterfaceStyle = interfaceStyle
        }
        setupView()
        rebuildContent()
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func configure(facts: [DiningNutritionFact], expanded: Bool) {
        presentation = NutritionFactsPresentation(facts: facts)
        isExpanded = expanded
        rebuildContent()
    }

    private func setupView() {
        backgroundColor = .systemBackground
        layer.borderWidth = 2
        layer.cornerRadius = 0
        accessibilityIdentifier = "detail-nutrition-facts-card"
        updateResolvedColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
            (card: NutritionFactsCardView, _) in
            card.updateResolvedColors()
        }

        contentStack.axis = .vertical
        contentStack.spacing = 0
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10)
        ])
    }

    private func rebuildContent() {
        for view in contentStack.arrangedSubviews {
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let title = label(
            text: "Nutrition Facts",
            font: .systemFont(ofSize: 32, weight: .heavy),
            color: .label
        )
        title.adjustsFontSizeToFitWidth = true
        title.minimumScaleFactor = 0.75
        title.accessibilityIdentifier = "nutrition-facts-title"
        contentStack.addArrangedSubview(title)

        if let servingSize = presentation.servingSize {
            contentStack.addArrangedSubview(servingSizeRow(servingSize))
        }
        contentStack.addArrangedSubview(divider(height: 1, identifier: "nutrition-divider-serving"))
        contentStack.addArrangedSubview(spacer(height: 5))
        contentStack.addArrangedSubview(divider(height: 9, identifier: "nutrition-divider-calories-top"))
        contentStack.addArrangedSubview(caloriesRow(presentation.calories))
        contentStack.addArrangedSubview(divider(height: 5, identifier: "nutrition-divider-calories-bottom"))

        let dailyValue = label(
            text: "% Daily Value*",
            font: .systemFont(ofSize: 13, weight: .bold),
            color: .label,
            alignment: .right
        )
        dailyValue.accessibilityIdentifier = "nutrition-daily-value-header"
        dailyValue.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: 4,
            leading: 0,
            bottom: 4,
            trailing: 0
        )
        contentStack.addArrangedSubview(dailyValue)
        contentStack.addArrangedSubview(divider(height: 1, identifier: nil))

        for row in presentation.displayedRows(expanded: isExpanded) {
            contentStack.addArrangedSubview(nutrientRow(row))
            contentStack.addArrangedSubview(divider(height: 1, identifier: nil))
        }

        let footnote = label(
            text: "* The % Daily Value (DV) tells you how much a nutrient in a serving of food contributes to a daily diet. 2,000 calories a day is used for general nutrition advice.",
            font: .systemFont(ofSize: 11, weight: .regular),
            color: .label
        )
        footnote.numberOfLines = 0
        footnote.accessibilityIdentifier = "nutrition-daily-value-footnote"
        contentStack.addArrangedSubview(spacer(height: 6))
        contentStack.addArrangedSubview(footnote)
    }

    private func servingSizeRow(_ fact: DiningNutritionFact) -> UIView {
        let name = label(
            text: fact.name,
            font: .systemFont(ofSize: 15, weight: .bold),
            color: .label
        )
        let value = label(
            text: fact.value,
            font: .systemFont(ofSize: 15, weight: .regular),
            color: .label,
            alignment: .right
        )
        value.setContentCompressionResistancePriority(.required, for: .horizontal)
        let stack = UIStackView(arrangedSubviews: [name, value])
        stack.axis = .horizontal
        stack.alignment = .firstBaseline
        stack.spacing = 8
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: 4,
            leading: 0,
            bottom: 5,
            trailing: 0
        )
        stack.accessibilityIdentifier = "nutrition-serving-size"
        return stack
    }

    private func caloriesRow(_ fact: DiningNutritionFact?) -> UIView {
        let title = label(
            text: fact?.name ?? "Calories",
            font: .systemFont(ofSize: 18, weight: .bold),
            color: .label
        )
        let amount = label(
            text: fact?.value ?? "—",
            font: .systemFont(ofSize: 36, weight: .heavy),
            color: .label,
            alignment: .right
        )
        amount.adjustsFontSizeToFitWidth = true
        amount.minimumScaleFactor = 0.75
        amount.setContentCompressionResistancePriority(.required, for: .horizontal)
        let stack = UIStackView(arrangedSubviews: [title, amount])
        stack.axis = .horizontal
        stack.alignment = .lastBaseline
        stack.spacing = 8
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: 3,
            leading: 0,
            bottom: 3,
            trailing: 0
        )
        stack.accessibilityIdentifier = "nutrition-calories"
        return stack
    }

    private func nutrientRow(_ row: NutritionFactsPresentation.Row) -> UIView {
        let container = UIView()
        container.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: 4,
            leading: row.style.indentation,
            bottom: 4,
            trailing: 0
        )

        let text = NSMutableAttributedString(
            string: row.name,
            attributes: [
                .font: row.style == .parent
                    ? UIFont.systemFont(ofSize: 15, weight: .bold)
                    : UIFont.systemFont(ofSize: 15, weight: .regular),
                .foregroundColor: UIColor.label
            ]
        )
        if !row.amount.isEmpty {
            text.append(NSAttributedString(
                string: " \(row.amount)",
                attributes: [
                    .font: UIFont.systemFont(ofSize: 15, weight: .regular),
                    .foregroundColor: UIColor.label
                ]
            ))
        }
        let name = UILabel()
        name.attributedText = text
        name.numberOfLines = 0
        name.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(name)

        let dailyValue = label(
            text: row.dailyValue,
            font: .systemFont(ofSize: 15, weight: .bold),
            color: .label,
            alignment: .right
        )
        dailyValue.translatesAutoresizingMaskIntoConstraints = false
        dailyValue.setContentCompressionResistancePriority(.required, for: .horizontal)
        container.addSubview(dailyValue)

        NSLayoutConstraint.activate([
            name.topAnchor.constraint(equalTo: container.layoutMarginsGuide.topAnchor),
            name.leadingAnchor.constraint(equalTo: container.layoutMarginsGuide.leadingAnchor),
            name.bottomAnchor.constraint(equalTo: container.layoutMarginsGuide.bottomAnchor),
            name.trailingAnchor.constraint(lessThanOrEqualTo: dailyValue.leadingAnchor, constant: -8),
            dailyValue.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
            dailyValue.trailingAnchor.constraint(equalTo: container.layoutMarginsGuide.trailingAnchor)
        ])
        container.accessibilityIdentifier = "nutrition-row-\(row.name)"
        container.isAccessibilityElement = true
        container.accessibilityLabel = row.name
        container.accessibilityValue = [row.amount, row.dailyValue]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        return container
    }

    private func label(
        text: String?,
        font: UIFont,
        color: UIColor,
        alignment: NSTextAlignment = .left
    ) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = font
        label.textColor = color
        label.textAlignment = alignment
        label.numberOfLines = 1
        return label
    }

    private func divider(height: CGFloat, identifier: String?) -> UIView {
        let divider = UIView()
        divider.backgroundColor = .label
        divider.accessibilityIdentifier = identifier
        divider.heightAnchor.constraint(equalToConstant: height).isActive = true
        return divider
    }

    private func spacer(height: CGFloat) -> UIView {
        let spacer = UIView()
        spacer.backgroundColor = .clear
        spacer.heightAnchor.constraint(equalToConstant: height).isActive = true
        return spacer
    }

    private func updateResolvedColors() {
        layer.borderColor = UIColor.label.resolvedColor(with: traitCollection).cgColor
    }
}
