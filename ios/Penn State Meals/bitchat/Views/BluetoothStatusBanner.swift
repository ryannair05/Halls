import SwiftUI

struct BluetoothStatusBanner: View {
    let presentation: BitchatBluetoothPresentation
    let onAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: presentation.systemImageName)
                    .font(presentation.isBlocking ? .largeTitle : .title2)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 6) {
                    Text(presentation.title)
                        .font(presentation.isBlocking ? .title3.bold() : .headline)
                        .foregroundStyle(.primary)

                    Text(presentation.message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let actionTitle = presentation.actionTitle {
                Button(action: onAction) {
                    Text(actionTitle)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(tint)
                .accessibilityHint("Opens Halls’s settings so you can allow Bluetooth access")
            }
        }
        .padding(presentation.isBlocking ? 20 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(tint.opacity(0.2), lineWidth: 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var tint: Color {
        if presentation.isBlocking { .orange } else { .accentColor }
    }
}
