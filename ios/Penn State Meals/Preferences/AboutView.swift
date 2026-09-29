//
//  AboutView.swift
//  Penn State Meals
//
//  Created by Ryan Nair on 2/17/23.
//

import SwiftUI
import StoreKit
import AppIntents

nonisolated(unsafe) private var color: UIColor?
nonisolated(unsafe) private var originalTintColor: IMP?

private enum swizzleColor: CFIndex {
    case pink = 1
    case green = 2
    case teal = 3
    case red = 4
    case purple = 5
    case indigo = 6
    case blue = 0

    var systemColor: UIColor {
        switch self {
        case .pink:
            return .systemPink
        case .green:
            return .systemGreen
        case .teal:
            return .systemTeal
        case .red:
            return .systemRed
        case .purple:
            return .systemPurple
        case .indigo:
            return .systemIndigo
        case .blue:
            return .systemBlue
        }
    }
}

private func customColorFunction(_ self: UIView, _ _cmd: Selector) -> UIColor {
    if self is UIImageView {
        let orig = unsafeBitCast(originalTintColor, to: (@convention(c) (UIView, Selector) -> UIColor).self)
        return orig(self, _cmd)
    }
    return color.unsafelyUnwrapped
}

/// On first call, swizzles [UIView tintColor] to return a custom color selector,
/// which this function assigns by getting the customTintColor integer property
/// from the current application's preferences
func swizzleCustomTintColor(_ num: CFIndex) {
    if originalTintColor == nil {
        let method = class_getInstanceMethod(UIView.self, #selector(getter: UIView.tintColor)).unsafelyUnwrapped
        let newMethodImp = unsafeBitCast(customColorFunction as (@convention(c) (UIView, Selector) -> UIColor), to: IMP.self)
        originalTintColor = method_setImplementation(method, newMethodImp)
    }

    color = swizzleColor(rawValue: num)?.systemColor ?? .systemBlue
}

private struct AboutLabelView: View {

    let labelTitle: String
    let labelImage: String

    var body: some View {
        HStack {
            Text(labelTitle.uppercased())
                .fontWeight(.bold)
            Spacer()
            Image(systemName: labelImage)
        }
    }
}

private struct AboutRowView: View {

    let title: String
    let content: String
    var linkDestination: String?

    var body: some View {
        VStack {
            Divider().padding(.vertical, 4)
            HStack {
                Text(title)
                    .foregroundStyle(.secondary)
                Spacer()
                if let linkDestination, let url = URL(string: linkDestination) {
                    Link(destination: url) {
                        Text(content)
                    }
                } else {
                    Text(content)
                }
            }
        }
    }
}

private extension UIApplication {
    static var appVersion: String {
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }
}

@MainActor
struct AboutView: View {
    @Binding var storedColor: CFIndex
    @Bindable var purchaseManager: PurchaseManager
    @Binding var selectedUniversity: University?
    @State private var showProContent: Bool = false
    
    internal init(storedColor: Binding<CFIndex>, manager: PurchaseManager, selectedUniversity: Binding<University?>) {
        self._storedColor = storedColor
        self.purchaseManager = manager
        self._selectedUniversity = selectedUniversity
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    GroupBox {
                        Divider().padding(.vertical, 4)
                        HStack(alignment: .center, spacing: 10) {
                            AnimatedAppLogo()
                                .frame(width: 100, height: 100)

                            Text("Halls is a better experience for dining, meeting, connecting, and navigating " + selectedUniversity.unsafelyUnwrapped.fullName)
                                .font(.footnote)
                                .padding()
                        }
                        
                        NavigationLink {
                            ChangeIconView()
                        } label: {
                            Label("App Icon", systemImage: "app.dashed")
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(10)
                        
                        Spacer(minLength: 20)
                        
                        Group {
                            Button { showProContent = true } label: {
#if OPEN_SOURCE_BUILD
                                Label("All features included", systemImage: "checkmark.seal.fill")
#else
                                if purchaseManager.hasLifetimePro {
                                    Label("Lifetime Pro Active", systemImage: "checkmark.seal.fill")
                                } else if purchaseManager.hasUnlockedPro {
                                    Label("Halls Pro · Monthly", systemImage: "checkmark.seal.fill")
                                } else {
                                    Label("Halls Pro", systemImage: "star")
                                }
#endif
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.cyan.opacity(0.1))
                        .cornerRadius(10)
                    } label: {
                        HStack {
                            Text("Halls".uppercased())
                                .fontWeight(.bold)
                            Spacer()
                            NavigationLink {
                                InfoView()
                            } label: {
                                Image(systemName: "info.circle")
                            }
                        }
                    }
                    
                    if selectedUniversity == .psu {
                        if #available(iOS 26.0, *) {
                            DiningShortcutsSettings()
                        }
                    }

                    GroupBox {
                        AboutRowView(title: "Developed by", content: "Ryan Nair")
                        AboutRowView(title: "Website", content: "swiftbyte.app", linkDestination: "https://swiftbyte.app")
                        AboutRowView(title: "Instagram", content: "@appmeetandeat", linkDestination: "https://instagram.com/appmeetandeat")
                        AboutRowView(title: "Email", content: "support@swiftbyte.app", linkDestination: "mailto:support@swiftbyte.app")
                        AboutRowView(title: "Version", content: UIApplication.appVersion)

                        Divider().padding(.vertical, 4)
                        HStack {
                            Text("Tint Color")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Picker("", selection: $storedColor) {
                                Text("Red").tag(swizzleColor.red.rawValue)
                                Text("Green").tag(swizzleColor.green.rawValue)
                                Text("Blue").tag(swizzleColor.blue.rawValue)
                                Text("Teal").tag(swizzleColor.teal.rawValue)
                                Text("Pink").tag(swizzleColor.pink.rawValue)
                                Text("Purple").tag(swizzleColor.purple.rawValue)
                                Text("Indigo").tag(swizzleColor.indigo.rawValue)
                            }
                            .onChange(of: storedColor) {
                                color = swizzleColor(rawValue: storedColor)?.systemColor
                            }
                        }
                        
                        if selectedUniversity == .psu {
                            Divider().padding(.vertical, 4)
                            LaunchDestinationSettings(purchaseManager: purchaseManager, showProContent: $showProContent)
                        }

                        Divider().padding(.vertical, 4)
                        ManualWeatherSettings(purchaseManager: purchaseManager, showProContent: $showProContent)

                        Divider().padding(.vertical, 4)
                        Toggle("Live Weather Effects", isOn: $purchaseManager.liveWeather)
                            .foregroundStyle(.secondary)
                            .tint(.accentColor)
                            .onChange(of: purchaseManager.liveWeather) {
                                if purchaseManager.liveWeather && !purchaseManager.hasUnlockedPro {
                                    purchaseManager.liveWeather = false
                                    Task {
                                        await purchaseManager.updatePurchasedProducts()
                                        if purchaseManager.hasUnlockedPro {
                                            purchaseManager.liveWeather = true
                                        } else {
                                            showProContent = true
                                        }
                                    }
                                }
                            }
                        
                        Divider().padding(.vertical, 4)
                        
                        HStack {
                            Text("University").foregroundStyle(.secondary)
                            Spacer()
                            Picker("", selection: $selectedUniversity) {
                                ForEach(University.allCases, id: \.self) {
                                    Text($0.fullName).tag($0)
                                }
                                Text("Contact to add more")
                            }
                        }
                    } label: {
                        AboutLabelView(labelTitle: "Application", labelImage: "apps.iphone")
                    }
                    if purchaseManager.hasUnlockedPro {
                        Text("Thank you for purchasing Halls Pro :)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.bottom)
                    }
                }
            }
            .sheet(isPresented: $showProContent) {
                ProContent(purchaseManager: purchaseManager)
            }
            .onChange(of: purchaseManager.hasUnlockedPro) {
                if purchaseManager.hasUnlockedPro {
                    showProContent = false
                }
            }
            .padding(.horizontal)
            .navigationTitle("Settings")
            .task {
                await purchaseManager.updatePurchasedProducts()
            }
        }
    }
}


@MainActor
private struct ManualWeatherSettings: View {
    let purchaseManager: PurchaseManager
    @Binding var showProContent: Bool
    @AppStorage("manualWeatherEffect") private var effect: ManualWeatherEffect = .none

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Weather Effect")
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Weather Effect", selection: Binding(
                    get: { effect },
                    set: { requested in
                        guard !purchaseManager.liveWeather else { return }
                        if requested.requiresPro && !purchaseManager.hasUnlockedPro {
                            showProContent = true
                        } else {
                            effect = requested
                        }
                    }
                )) {
                    ForEach(ManualWeatherEffect.allCases, id: \.self) { option in
                        HStack {
                            if option.requiresPro && !purchaseManager.hasUnlockedPro {
                                Image(systemName: "lock.fill")
                            }
                            Text(option.title)
                        }
                        .tag(option)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .disabled(purchaseManager.liveWeather)
            }
            .disabled(purchaseManager.liveWeather)
            .opacity(purchaseManager.liveWeather ? 0.5 : 1)

            if purchaseManager.liveWeather {
                Text("Live weather overrides your selected effect.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct LaunchDestinationSettings: View {
    let purchaseManager: PurchaseManager
    @Binding var showProContent: Bool
    @AppStorage("proLaunchDestination") private var destination: AppLaunchDestination = .meals
    @State private var selection: AppLaunchDestination = .meals

    var body: some View {
        HStack {
            Text("Launch Destination").foregroundStyle(.secondary)
            Spacer()
            Picker("Launch Destination", selection: $selection) {
                ForEach(AppLaunchDestination.allCases, id: \.self) { option in
                    Text(option.title).tag(option)
                }
            }
            .labelsHidden()
            .onAppear { selection = destination }
            .onChange(of: destination) { selection = destination }
            .onChange(of: selection) { _, requested in
                guard requested != destination else { return }
                guard requested != .meals, !purchaseManager.hasUnlockedPro else {
                    destination = requested
                    return
                }
                selection = destination
                Task {
                    await purchaseManager.updatePurchasedProducts()
                    if purchaseManager.hasUnlockedPro {
                        destination = requested
                    } else {
                        showProContent = true
                    }
                }
            }

        }
    }
}

@available(iOS 26.0, *)
private struct DiningShortcutsSettings: View {
    var body: some View {
        GroupBox {
            HStack() {
                Text("Ask what’s open, check dining hours, find a food, or get a menu and its published nutrition with Siri or Shortcuts.")
                    .font(.subheadline).foregroundStyle(.secondary)
                ShortcutsLink()
            }
            SiriTipView(intent: GetPSUDiningMenuIntent())
        } label: {
            Label("Siri & Shortcuts", systemImage: "square.stack.3d.up")
        }
    }
}


struct AboutView_Previews: PreviewProvider {
    static var previews: some View {
        AboutView(storedColor: .constant(0), manager: PurchaseManager(), selectedUniversity: .constant(.psu))
    }
}
