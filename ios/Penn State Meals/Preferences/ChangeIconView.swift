//
//  ChangeIconView.swift
//  Meet and Eat
//
//  Created by Ryan Nair on 10/2/23.
//

import SwiftUI
import Combine

private enum AppIcon: String, CaseIterable, Identifiable {
    case primary = "AppIcon"
    case blushBrunches
    case Glowing
    case GradientIcon
    case Bananas
    case Neon
    case tulipTables
    case purplePals
     
    var id: String { self.rawValue }
    
    var description: String {
        switch self {
        case .primary:
            return "Default"
        case .GradientIcon:
            return "Crimson Campus"
        case .Bananas:
            return "B.A.N.A.N.A.S."
        case .blushBrunches:
            return "Blush Brunches"
        case .Glowing:
            return "Glowing Gourmet"
        case .tulipTables:
            return "Tulip Tables"
        case .Neon:
            return "Neon Nosh"
        case .purplePals:
            return "Purple Pals"
        }
    }
}

@MainActor @Observable private final class ChangeIconViewModel {
    
    private(set) var appIcon: AppIcon

    @MainActor init() {
        if let iconName = UIApplication.shared.alternateIconName {
            appIcon = AppIcon(rawValue: iconName).unsafelyUnwrapped
        } else {
            appIcon = .primary
        }
    }

    @MainActor func updateAppIcon(to icon: AppIcon) {
        
        let iconName: String? = (icon != .primary) ? icon.rawValue : nil

        guard UIApplication.shared.alternateIconName != iconName else { return }

        UIApplication.shared.setAlternateIconName(iconName) { [weak self] error in
            if let error {
                print("Failed request to update the app’s icon: \(error)")
            }
            else {
                Task { @MainActor [weak self] in self?.appIcon = icon }
            }
        }
    }
}

private struct CheckboxView: View {
    let isSelected: Bool
    
    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                ZStack {
                    Image(systemName: "app")
                    if isSelected {
                        Image(systemName: "checkmark.app.fill")
                            .transition(.symbolEffect(.drawOn))
                    }
                }
                .animation(.default, value: isSelected)
            } else {
                Image(systemName: isSelected ? "app.badge.checkmark" : "app")
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .sensoryFeedback(.selection, trigger: isSelected)
    }
}

struct ChangeIconView: View {
    @State private var viewModel = ChangeIconViewModel()
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                ForEach(AppIcon.allCases) { appIcon in
                    HStack(spacing: 16) {
                        Image(appIcon.rawValue)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 50, height: 60)
                            .cornerRadius(12)
                            .hoverEffect(.lift)
                        
                        Text(appIcon.description)
                        
                        Spacer()
                        
                        CheckboxView(isSelected: viewModel.appIcon == appIcon)
                            .font(.system(size: 35))
                    }
                    .padding()
                    .background(Color(uiColor: .systemGroupedBackground))
                    .cornerRadius(20)
                    .onTapGesture {
                        withAnimation {
                            viewModel.updateAppIcon(to: appIcon)
                        }
                    }
                    .hoverEffect(.highlight)
                }
            }
            .padding()
            .navigationTitle("App Icon")
        }
    }
}

#Preview {
    ChangeIconView()
}
