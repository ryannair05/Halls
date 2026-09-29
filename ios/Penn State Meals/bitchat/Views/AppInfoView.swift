import SwiftUI

struct AppInfoView: View {
    @Environment(\.dismiss) var dismiss
    
    private var backgroundColor: Color {
        Color(uiColor: .systemGroupedBackground)
    }
    
    private var textColor: Color {
        Color.accentColor
    }
    
    private var secondaryTextColor: Color {
        Color.accentColor.opacity(0.8)
    }
    
    // MARK: - Constants
    private enum Strings {
        static let appName = "Bit-Chat"
        static let tagline = "Local Groupchat via Bluetooth"
        
        enum Features {
            static let title = "FEATURES"
            static let extendedRange = ("antenna.radiowaves.left.and.right", "extended range", "Messages relay through peers, going the distance")
            static let mentions = ("at", "mentions", "Use @nickname to notify specific people")
            static let favorites = ("star.fill", "favorites", "Get notified when your favorite people join")
        }
        
        enum Privacy {
            static let title = "PRIVACY"
            static let noTracking = ("eye.slash", "no tracking", "No servers, accounts, or data collection")
            static let encryption = ("lock.shield", "end-to-end encryption", "Private messages encrypted with noise protocol")
        }
        
        enum HowToUse {
            static let title = "HOW TO USE"
            static let instructions = [
                "• Set your nickname by tapping it",
                "• Tap people icon for sidebar",
                "• Tap a peer's name to start a DM",
                "• Type / for commands"
            ]
        }
    }
    
    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            // Custom header for macOS
            HStack {
                Spacer()
                Button("DONE") {
                    dismiss()
                }
                .buttonStyle(.plain)
                .foregroundStyle(textColor)
                .padding()
            }
            .background(backgroundColor.opacity(0.95))
            
            ScrollView {
                infoContent
            }
            .background(backgroundColor)
        }
        .frame(width: 600, height: 700)
        #else
        NavigationStack {
            ScrollView {
                infoContent
            }
            .background(backgroundColor)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(textColor)
                    .accessibilityLabel("Close app information")
                }
            }
        }
        #endif
    }
    
    @ViewBuilder
    private var infoContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Header
            VStack(alignment: .center, spacing: 8) {
                Text(Strings.appName)
                    .font(.system(size: 32, weight: .bold, design: .monospaced))
                    .foregroundStyle(textColor)
                
                Text(Strings.tagline)
                    .font(.system(size: 16, design: .monospaced))
                    .foregroundStyle(secondaryTextColor)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical)
            
            // Features
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(Strings.Features.title)
                
                FeatureRow(icon: Strings.Features.extendedRange.0,
                          title: Strings.Features.extendedRange.1,
                          description: Strings.Features.extendedRange.2)
                
                FeatureRow(icon: Strings.Features.favorites.0,
                          title: Strings.Features.favorites.1,
                          description: Strings.Features.favorites.2)
                
                FeatureRow(icon: Strings.Features.mentions.0,
                          title: Strings.Features.mentions.1,
                          description: Strings.Features.mentions.2)
            }
            
            // Privacy
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(Strings.Privacy.title)
                
                FeatureRow(icon: Strings.Privacy.noTracking.0,
                          title: Strings.Privacy.noTracking.1,
                          description: Strings.Privacy.noTracking.2)
                
                FeatureRow(icon: Strings.Privacy.encryption.0,
                          title: Strings.Privacy.encryption.1,
                          description: Strings.Privacy.encryption.2)
                
            }
            
            // How to Use
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(Strings.HowToUse.title)
                
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Strings.HowToUse.instructions, id: \.self) { instruction in
                        Text(instruction)
                    }
                }
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(textColor)
            }
        }
        .padding()
    }
}

struct SectionHeader: View {
    let title: String
    
    private var textColor: Color {
        Color.accentColor
    }
    
    init(_ title: String) {
        self.title = title
    }
    
    var body: some View {
        Text(title)
            .font(.system(size: 16, weight: .bold, design: .monospaced))
            .foregroundStyle(textColor)
            .padding(.top, 8)
    }
}

struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String
    
    private var textColor: Color {
        Color.accentColor
    }
    
    private var secondaryTextColor: Color {
        Color.accentColor.opacity(0.8)
    }
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(textColor)
                .frame(width: 30)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(textColor)
                
                Text(description)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(secondaryTextColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            Spacer()
        }
    }
}

#Preview {
    AppInfoView()
}
