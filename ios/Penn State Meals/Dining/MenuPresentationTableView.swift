import AppIntents
import UIKit

@MainActor
final class MenuPresentationTableDataSource: UITableViewDiffableDataSource<
    MenuPresentationSectionID,
    MenuPresentationRowID
> {
    var titleProvider: ((Int) -> String?)?

    func apply(
        _ presentation: MenuPresentationSnapshot,
        replacing previousPresentation: MenuPresentationSnapshot?,
        animatingDifferences: Bool,
        reloadData: Bool = false,
        completion: (() -> Void)? = nil
    ) {
        var next = NSDiffableDataSourceSnapshot<
            MenuPresentationSectionID,
            MenuPresentationRowID
        >()
        for section in presentation.sections {
            next.appendSections([section.id])
            next.appendItems(section.rowIDs, toSection: section.id)
        }

        // A full reset skips diffing and does not need retained-row comparisons.
        if reloadData {
            applySnapshotUsingReloadData(next, completion: completion)
            return
        }

        let current = snapshot()
        let currentItemIDs = current.itemIdentifiers
        let nextItemIDs = next.itemIdentifiers
        if let previousPresentation {
            let previousIDs = Set(currentItemIDs)
            let changedRetainedIDs = nextItemIDs.filter { identifier in
                guard previousIDs.contains(identifier),
                      let previousRow = previousPresentation.rowsByID[identifier],
                      let nextRow = presentation.rowsByID[identifier] else {
                    return false
                }
                return previousRow != nextRow
            }
            if !changedRetainedIDs.isEmpty {
                next.reconfigureItems(changedRetainedIDs)
            }
        }

        // A pure reconfiguration is animated by the cell's changed subviews. Asking
        // diffable to animate it as well adds a competing row/layout transition.
        let hasStructuralChanges = current.sectionIdentifiers != next.sectionIdentifiers
            || currentItemIDs != nextItemIDs

        apply(
            next,
            animatingDifferences: animatingDifferences && hasStructuralChanges,
            completion: completion
        )
    }

    func applyEmpty(
        animatingDifferences: Bool,
        completion: (() -> Void)? = nil
    ) {
        apply(
            NSDiffableDataSourceSnapshot<MenuPresentationSectionID, MenuPresentationRowID>(),
            animatingDifferences: animatingDifferences,
            completion: completion
        )
    }

    override func tableView(
        _ tableView: UITableView,
        titleForHeaderInSection section: Int
    ) -> String? {
        titleProvider?(section)
    }
}

@MainActor
final class MenuTraitImageCache {
    private var images: [MenuTraitSymbolDescriptor: UIImage] = [:]

    func prepare(_ descriptors: Set<MenuTraitSymbolDescriptor>) {
        for descriptor in descriptors where images[descriptor] == nil {
            guard let source = UIImage(named: descriptor.assetName) else {
                assertionFailure("Missing dietary indicator asset: \(descriptor.assetName)")
                continue
            }
            images[descriptor] = source.withTintColor(
                descriptor.tintRole.color,
                renderingMode: .alwaysOriginal
            )
        }
    }

    func image(for descriptor: MenuTraitSymbolDescriptor) -> UIImage? {
        images[descriptor]
    }

    func removeAll() {
        images.removeAll(keepingCapacity: false)
    }
}

@MainActor
final class MenuMealItemCell: UITableViewCell {
    static let reuseID = "MenuMealItemCell"

    private let nameLabel = UILabel()
    private let providerLabel = UILabel()
    private let textStack = UIStackView()
    private let traitStack = UIStackView()
    private let rowStack = UIStackView()
    private var traitImageViews: [UIImageView] = []
    private var representedRow: MenuPresentationRow?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)

        nameLabel.font = .preferredFont(forTextStyle: .body)
        nameLabel.numberOfLines = 2
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        providerLabel.font = .preferredFont(forTextStyle: .caption1)
        providerLabel.textColor = .secondaryLabel
        providerLabel.numberOfLines = 2
        providerLabel.adjustsFontForContentSizeCategory = true

        textStack.axis = .vertical
        textStack.alignment = .fill
        textStack.spacing = 2
        textStack.addArrangedSubview(nameLabel)
        textStack.addArrangedSubview(providerLabel)
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        traitStack.axis = .horizontal
        traitStack.alignment = .center
        traitStack.spacing = 6
        traitStack.setContentHuggingPriority(.required, for: .horizontal)
        traitStack.setContentCompressionResistancePriority(.required, for: .horizontal)

        rowStack.axis = .horizontal
        rowStack.alignment = .center
        rowStack.spacing = 10
        rowStack.addArrangedSubview(textStack)
        rowStack.addArrangedSubview(traitStack)
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(rowStack)

        NSLayoutConstraint.activate([
            rowStack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            rowStack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            rowStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            rowStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8)
        ])
        updateTextLayout()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (cell: MenuMealItemCell, _: UITraitCollection) in
            cell.updateTextLayout()
        }
    }

    private func updateTextLayout() {
        let accessible = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        rowStack.axis = accessible ? .vertical : .horizontal
        rowStack.alignment = accessible ? .leading : .center
        nameLabel.numberOfLines = accessible ? 0 : 2
        providerLabel.numberOfLines = accessible ? 0 : 2
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        if #available(iOS 26.0, *) { appEntityIdentifier = nil }
        representedRow = nil
        resetUpdateAnimation(on: nameLabel)
        resetUpdateAnimation(on: providerLabel)
        resetUpdateAnimation(on: traitStack)
        nameLabel.text = nil
        providerLabel.text = nil
        providerLabel.isHidden = true
        for imageView in traitImageViews {
            imageView.image = nil
            imageView.isHidden = true
        }
    }

    func configurePlateAction(selected: Bool, action: @escaping () -> Void) {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: selected ? "checkmark.circle.fill" : "plus.circle"), for: .normal)
        button.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        button.accessibilityLabel = "\(selected ? "Remove" : "Add") \(representedRow?.item.displayName ?? "item") \(selected ? "from" : "to") plate"
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        accessoryView = button
        isAccessibilityElement = false
        nameLabel.isAccessibilityElement = true
        nameLabel.accessibilityValue = accessibilityValue
        nameLabel.accessibilityHint = accessibilityHint
        accessibilityElements = [nameLabel, button]
    }

    func configure(row: MenuPresentationRow, images: [UIImage]) {
        if #available(iOS 26.0, *) { appEntityIdentifier = nil }
        accessoryView = nil
        accessibilityElements = nil
        nameLabel.isAccessibilityElement = false
        nameLabel.accessibilityValue = nil
        nameLabel.accessibilityHint = nil
        let previousRow = representedRow
        let isRetainedRow = previousRow?.id == row.id
        let nameChanged = isRetainedRow
            && previousRow?.item.displayName != row.item.displayName
        let providerChanged = isRetainedRow
            && previousRow?.unknownSourceLabels != row.unknownSourceLabels
        let traitsChanged = isRetainedRow
            && previousRow?.symbolDescriptors != row.symbolDescriptors

        representedRow = row
        nameLabel.text = row.item.displayName
        providerLabel.text = row.unknownSourceLabels.joined(separator: " · ")
        providerLabel.isHidden = row.unknownSourceLabels.isEmpty
        ensureTraitImageViewCount(images.count)
        for (index, imageView) in traitImageViews.enumerated() {
            guard images.indices.contains(index) else {
                imageView.image = nil
                imageView.isHidden = true
                continue
            }
            imageView.image = images[index]
            imageView.isHidden = false
        }
        traitStack.isHidden = images.isEmpty
        isAccessibilityElement = true
        let hasDetail = row.item.detailURL != nil || row.item.detailMetadata?.hasPublishedContent == true
        accessoryType = hasDetail ? .disclosureIndicator : .none
        selectionStyle = hasDetail ? .default : .none
        accessibilityLabel = row.item.displayName
        accessibilityValue = row.semantics.isEmpty ? nil : row.semantics.map(\.sourceText).joined(separator: ", ")
        accessibilityHint = hasDetail ? "Shows official ingredients, allergens, and nutrition" : nil
        accessibilityTraits = hasDetail ? .button : .staticText

        animateUpdatedContent(nameLabel, if: nameChanged)
        animateUpdatedContent(providerLabel, if: providerChanged)
        animateUpdatedContent(traitStack, if: traitsChanged)
    }

    private func animateUpdatedContent(_ view: UIView, if changed: Bool) {
        guard changed,
              !view.isHidden,
              window != nil,
              !UIAccessibility.isReduceMotionEnabled else {
            return
        }

        view.layer.removeAllAnimations()
        view.alpha = 0
        view.transform = CGAffineTransform(translationX: 0, y: 5)
            .scaledBy(x: 0.98, y: 0.98)
        UIView.animate(
            springDuration: 0.24,
            bounce: 0,
            initialSpringVelocity: .zero,
            delay: 0,
            options: [.allowUserInteraction, .beginFromCurrentState]
        ) {
            view.alpha = 1
            view.transform = .identity
        }
    }

    private func resetUpdateAnimation(on view: UIView) {
        view.layer.removeAllAnimations()
        view.alpha = 1
        view.transform = .identity
    }

    private func ensureTraitImageViewCount(_ count: Int) {
        guard traitImageViews.count < count else { return }
        for _ in traitImageViews.count..<count {
            let imageView = UIImageView()
            imageView.contentMode = .scaleAspectFit
            imageView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                imageView.widthAnchor.constraint(equalToConstant: 18),
                imageView.heightAnchor.constraint(equalToConstant: 18)
            ])
            traitStack.addArrangedSubview(imageView)
            traitImageViews.append(imageView)
        }
    }
}


/// The PSU meal selector, shared with secondary campuses without a separate UI implementation.
@MainActor
final class DiningMealControl: UIView {
    private let mealScrollView = UIScrollView()
    private let stackView = UIStackView()
    private let mealSelectionIndicator = UIView()
    private var controlHeightConstraint: NSLayoutConstraint!
    private var renderedMealNames: [String] = []
    private var renderedOptions: [String] = []
    private var selectedMeal = ""
    private var allowsSelection = true
    private var mealSelectionAnimator: UIViewPropertyAnimator?
    private var mealSelectionTargetFrame: CGRect = .zero
    var onSelect: ((String) -> Void)?
    var onShare: ((String) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: renderedOptions.count > 1 ? 50 : 0) }

    func configure(meals: [String], selected: String, enabled: Bool = true) {
        renderedOptions = meals
        selectedMeal = selected
        allowsSelection = enabled
        // Size before installing fixed-height buttons, including the first loading transition.
        controlHeightConstraint.constant = meals.count > 1 ? 50 : 0
        if translatesAutoresizingMaskIntoConstraints {
            frame.size.height = controlHeightConstraint.constant
        }
        rebuildMealButtons()
        for case let button as UIButton in stackView.arrangedSubviews { button.isEnabled = enabled }
    }

    func select(_ meal: String, animated: Bool) {
        selectedMeal = meal
        updateMealSelection(animated: animated)
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        mealSelectionIndicator.backgroundColor = tintColor
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let button = stackView.arrangedSubviews.compactMap({ $0 as? UIButton }).first(where: { $0.configuration?.title == selectedMeal }) {
            positionMealSelectionIndicator(for: button, animated: false)
        }
    }
    private func setup() {
        backgroundColor = .clear
        controlHeightConstraint = heightAnchor.constraint(equalToConstant: 0)
        // Hidden arranged subviews receive a required zero-height constraint.
        controlHeightConstraint.priority = UILayoutPriority(999)
        controlHeightConstraint.isActive = true

        mealScrollView.showsHorizontalScrollIndicator = false
        mealScrollView.isHidden = true
        mealScrollView.translatesAutoresizingMaskIntoConstraints = false
        self.addSubview(mealScrollView)

        mealSelectionIndicator.backgroundColor = tintColor
        mealSelectionIndicator.isHidden = true
        mealSelectionIndicator.isUserInteractionEnabled = false

        stackView.axis = .horizontal
        stackView.distribution = .fillEqually
        stackView.spacing = 10
        stackView.alignment = .center
        stackView.translatesAutoresizingMaskIntoConstraints = false
        // The selection background is a sibling, not a UIStackView-managed subview.
        mealScrollView.addSubview(mealSelectionIndicator)
        mealScrollView.addSubview(stackView)

        let minimumStackWidth = stackView.widthAnchor.constraint(
            greaterThanOrEqualTo: mealScrollView.frameLayoutGuide.widthAnchor,
            constant: -32
        )
        minimumStackWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            mealScrollView.topAnchor.constraint(equalTo: self.topAnchor),
            mealScrollView.bottomAnchor.constraint(equalTo: self.bottomAnchor),
            mealScrollView.leadingAnchor.constraint(equalTo: self.leadingAnchor),
            mealScrollView.trailingAnchor.constraint(equalTo: self.trailingAnchor),

            stackView.topAnchor.constraint(equalTo: mealScrollView.contentLayoutGuide.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: mealScrollView.contentLayoutGuide.bottomAnchor),
            stackView.leadingAnchor.constraint(equalTo: mealScrollView.contentLayoutGuide.leadingAnchor, constant: 16),
            stackView.trailingAnchor.constraint(equalTo: mealScrollView.contentLayoutGuide.trailingAnchor, constant: -16),
            stackView.heightAnchor.constraint(equalTo: mealScrollView.frameLayoutGuide.heightAnchor),
            minimumStackWidth
        ])
    }

    @objc private func buttonTapped(_ sender: UIButton) {
        guard let meal = sender.configuration?.title else { return }
        onSelect?(meal)
    }

    private func rebuildMealButtons() {
        let meals = renderedOptions
        guard meals.count > 1 else {
            renderedMealNames.removeAll(keepingCapacity: true)
            for arrangedSubview in stackView.arrangedSubviews {
                stackView.removeArrangedSubview(arrangedSubview)
                arrangedSubview.removeFromSuperview()
            }
            mealSelectionIndicator.isHidden = true
            mealScrollView.isHidden = true
            isHidden = true
            invalidateIntrinsicContentSize()
            return
        }

        let buttonHeight: CGFloat = 44
        stackView.distribution = .fillEqually
        mealScrollView.isHidden = false
        isHidden = false
        invalidateIntrinsicContentSize()

        if renderedMealNames != meals {
            renderedMealNames = meals
            for arrangedSubview in stackView.arrangedSubviews {
                stackView.removeArrangedSubview(arrangedSubview)
                arrangedSubview.removeFromSuperview()
            }

            for meal in meals {
                var configuration = UIButton.Configuration.filled()
                configuration.title = meal
                configuration.cornerStyle = .capsule
                configuration.baseBackgroundColor = .systemFill
                configuration.contentInsets = NSDirectionalEdgeInsets(
                    top: 8,
                    leading: 16,
                    bottom: 8,
                    trailing: 16
                )

                let button = UIButton(configuration: configuration)
                button.isEnabled = allowsSelection
                button.heightAnchor.constraint(equalToConstant: buttonHeight).isActive = true
                button.accessibilityLabel = meal
                button.addTarget(self, action: #selector(buttonTapped(_:)), for: .touchUpInside)
                button.menu = UIMenu(children: [
                    UIAction(
                        title: "Share as Image",
                        image: UIImage(systemName: "photo")
                    ) { [weak self] _ in
                        self?.onShare?(meal)
                    }
                ])
                stackView.addArrangedSubview(button)
            }
        }

        layoutIfNeeded()
        updateMealSelection(animated: false)
        scrollSelectedMealIntoView(animated: false)
    }

    private func updateMealSelection(animated: Bool) {
        var selectedButton: UIButton?
        UIView.performWithoutAnimation {
            for case let button as UIButton in stackView.arrangedSubviews {
                guard let meal = button.configuration?.title else { continue }
                let isSelected = meal == selectedMeal
                if isSelected { selectedButton = button }
                button.accessibilityHint = isSelected
                    ? "Selected meal"
                    : "Shows the \(meal) menu"
                if isSelected {
                    button.accessibilityTraits.insert(.selected)
                } else {
                    button.accessibilityTraits.remove(.selected)
                }
                var configuration = button.configuration
                configuration?.baseForegroundColor = isSelected ? .white : .label
                configuration?.baseBackgroundColor = isSelected ? .clear : .systemFill
                button.configuration = configuration
            }
        }

        guard let selectedButton else {
            mealSelectionIndicator.isHidden = true
            return
        }
        positionMealSelectionIndicator(for: selectedButton, animated: animated)
    }

    private func positionMealSelectionIndicator(
        for selectedButton: UIButton,
        animated: Bool
    ) {
        mealScrollView.layoutIfNeeded()
        stackView.layoutIfNeeded()
        let targetFrame = selectedButton.convert(selectedButton.bounds, to: mealScrollView)
        mealSelectionIndicator.isHidden = false
        mealSelectionIndicator.layer.cornerRadius = targetFrame.height / 2

        // Repeated layout passes must not snap an in-flight indicator to its destination.
        if mealSelectionAnimator?.isRunning == true, targetFrame == mealSelectionTargetFrame {
            return
        }
        let visibleFrame = mealSelectionIndicator.layer.presentation()?.frame ?? mealSelectionIndicator.frame
        mealSelectionAnimator?.stopAnimation(true)
        mealSelectionAnimator = nil
        mealSelectionTargetFrame = targetFrame
        guard animated,
              window != nil,
              !UIAccessibility.isReduceMotionEnabled else {
            mealSelectionIndicator.frame = targetFrame
            return
        }
        mealSelectionIndicator.frame = visibleFrame
        let animator = UIViewPropertyAnimator(duration: 0.2, curve: .easeInOut) { [weak self] in
            self?.mealSelectionIndicator.frame = targetFrame
        }
        mealSelectionAnimator = animator
        animator.startAnimation()
    }

    func scrollSelectedMealIntoView(animated: Bool) {
        guard let button = stackView.arrangedSubviews
            .compactMap({ $0 as? UIButton })
            .first(where: { $0.configuration?.title == selectedMeal }) else { return }
        scrollMealButtonIntoView(button, animated: animated)
    }

    private func scrollMealButtonIntoView(_ button: UIButton, animated: Bool) {
        mealScrollView.layoutIfNeeded()
        let buttonFrame = button.convert(button.bounds, to: mealScrollView)
        let minimumX = -mealScrollView.adjustedContentInset.left
        let maximumX = max(
            minimumX,
            mealScrollView.contentSize.width
                - mealScrollView.bounds.width
                + mealScrollView.adjustedContentInset.right
        )
        let centeredX = buttonFrame.midX - mealScrollView.bounds.width / 2
        mealScrollView.setContentOffset(
            CGPoint(x: min(max(centeredX, minimumX), maximumX), y: mealScrollView.contentOffset.y),
            animated: animated && !UIAccessibility.isReduceMotionEnabled
        )
    }

    static func mealAfterSwipe(
        meals: [String],
        selectedMeal: String,
        translationX: CGFloat,
        translationY: CGFloat,
        velocityX: CGFloat
    ) -> String? {
        guard abs(translationX) > abs(translationY),
              abs(translationX) >= 44 || abs(velocityX) >= 500,
              let currentIndex = meals.firstIndex(of: selectedMeal) else { return nil }

        let horizontalDirection = abs(translationX) >= 44 ? translationX : velocityX
        let nextIndex = horizontalDirection < 0 ? currentIndex + 1 : currentIndex - 1
        return meals.indices.contains(nextIndex) ? meals[nextIndex] : nil
    }

}
