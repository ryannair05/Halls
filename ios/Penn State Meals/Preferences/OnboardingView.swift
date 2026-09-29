import SwiftUI

@MainActor
struct OnboardingView: View {
    @Binding var selectedUniversity: University?
    @State private var selectedItem: University = .psu
    @State private var showsCollegePicker = false
    @State private var revealStage = 0
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 12) {
                    AnimatedAppLogo()
                        .frame(width: 150, height: 150)
                        .scaleEffect(revealStage == 0 ? 1.3 : 1)
                        .offset(y: revealStage == 0 ? 90 : 0)
                        .accessibilityHidden(true)
                    Text("Halls")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .tracking(-1)
                        .accessibilityAddTraits(.isHeader)
                        .modifier(OnboardingReveal(visible: revealStage >= 1))
                    Text("Your campus day, simplified.")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .modifier(OnboardingReveal(visible: revealStage >= 1))
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("AT PENN STATE")
                        .font(.caption2.weight(.bold))
                        .tracking(2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                        .modifier(OnboardingReveal(visible: revealStage >= 2))
                    LazyVGrid(columns: columns, spacing: 12) {
                        OnboardingFeatureCard(title: "Meals", bullets: ["Dining hall menus", "Search across halls", "Dining hours"], symbol: "fork.knife", color: .blue)
                            .modifier(OnboardingReveal(visible: revealStage >= 2))
                        OnboardingFeatureCard(title: "CATA", bullets: ["Live bus tracking", "Route maps", "Choose your routes"], symbol: "bus.fill", color: .indigo)
                            .modifier(OnboardingReveal(visible: revealStage >= 2))
                        OnboardingFeatureCard(title: "Nutrition", bullets: ["Nutrition facts", "Allergen details", "Dietary filters"], symbol: "leaf.fill", color: .teal)
                            .modifier(OnboardingReveal(visible: revealStage >= 3))
                        OnboardingFeatureCard(title: "Campus Rec", bullets: ["Facility schedules", "Campus activities", "Interactive facility map"], symbol: "figure.run", color: .orange)
                            .modifier(OnboardingReveal(visible: revealStage >= 3))
                    }
                }
            }
            .frame(maxWidth: 480)
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .background {
            ZStack(alignment: .top) {
                Color(uiColor: .systemGroupedBackground)
                RadialGradient(
                    colors: [Color.blue.opacity(colorScheme == .dark ? 0.19 : 0.12), .clear],
                    center: .top, startRadius: 10, endRadius: 480
                )
            }
            .ignoresSafeArea()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 12) {
                Button {
                    showsCollegePicker = true
                } label: {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            collegeLabel
                            Text("·").foregroundStyle(.tertiary)
                            Text("Change").foregroundStyle(.blue)
                        }
                        VStack(spacing: 4) {
                            collegeLabel
                            Text("Change college").foregroundStyle(.blue)
                        }
                    }
                    .font(.subheadline.weight(.medium))
                    .frame(minHeight: 44)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("College: \(selectedItem.fullName)")
                .accessibilityHint("Change your college")
                .accessibilityIdentifier("onboarding-college")

                Button {
                    selectedUniversity = selectedItem
                } label: {
                    HStack {
                        Spacer(minLength: 0)
                        Text("Get Started")
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.right")
                    }
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 18)
                    .background(
                        LinearGradient(colors: [Color(red: 0.04, green: 0.43, blue: 0.85), Color(red: 0.03, green: 0.32, blue: 0.70)], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 20)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("onboarding-get-started")
            }
            .frame(maxWidth: 480)
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity)
            .background(.regularMaterial)
            .modifier(OnboardingReveal(visible: revealStage >= 4))
        }
        .task {
            guard revealStage < 4 else { return }
            do {
                if revealStage == 0 {
                    try await Task.sleep(for: .milliseconds(1550))
                }
                for stage in (revealStage + 1)...4 {
                    try Task.checkCancellation()
                    withAnimation(.easeOut(duration: 0.45)) { revealStage = stage }
                    try await Task.sleep(for: .milliseconds(130))
                }
            } catch {
                // Resume an interrupted entrance if this view appears again.
            }
        }
        .sheet(isPresented: $showsCollegePicker) {
            OnboardingCollegePicker(selection: $selectedItem)
        }
    }

    private var collegeLabel: some View {
        Label(selectedItem.fullName, systemImage: "building.2.crop.circle")
            .foregroundStyle(.primary)
    }
}

@MainActor
private struct OnboardingFeatureCard: View {
    let title: String
    let bullets: [String]
    let symbol: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 36, height: 36)
                .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 13))
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(bullets, id: \.self) { bullet in
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text("•")
                            .foregroundStyle(color)
                            .accessibilityHidden(true)
                        Text(bullet)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22)
                .strokeBorder(.primary.opacity(0.045), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct OnboardingReveal: ViewModifier {
    let visible: Bool

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : 12)
            .allowsHitTesting(visible)
            .accessibilityHidden(!visible)
    }
}

@MainActor
private struct OnboardingCollegePicker: View {
    @Binding var selection: University
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Find your campus")
                            .font(.title2.bold())
                            .accessibilityAddTraits(.isHeader)
                        Text("Make yourself at home")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 44, height: 44)
                            .background(.quaternary, in: Circle())
                    }
                    .accessibilityLabel("Close college picker")
                }
                VStack(spacing: 10) {
                    ForEach(University.allCases, id: \.self) { university in
                        collegeRow(university)
                    }
                }
            }
            .padding(24)
            .padding(.top, 12)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.height(480), .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(32)
    }

    private func collegeRow(_ university: University) -> some View {
        let isSelected = selection == university
        return Button {
            selection = university
            dismiss()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: university == .none ? "globe" : "building.columns.fill")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(isSelected ? .blue : .secondary)
                    .frame(width: 42, height: 42)
                    .background(isSelected ? Color.blue.opacity(0.12) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 13))
                    .accessibilityHidden(true)
                Text(university == .none ? "Other / no college" : university.fullName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.blue : Color.secondary.opacity(0.35))
                    .accessibilityHidden(true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
            .overlay {
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(isSelected ? Color.blue.opacity(0.5) : .clear, lineWidth: 1.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#Preview("Light") {
    OnboardingView(selectedUniversity: .constant(nil))
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    OnboardingView(selectedUniversity: .constant(nil))
        .preferredColorScheme(.dark)
}

#Preview("Accessible") {
    OnboardingView(selectedUniversity: .constant(nil))
        .environment(\.dynamicTypeSize, .accessibility3)
}
