import SwiftUI

/// The shader clock lives in the overlay so animation never invalidates the menus.
@MainActor
struct WeatherEffectView: View {
    var condition: WeatherCondition

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @State private var start = Date()

    var body: some View {
        Group {
            switch condition {
            case .snowy:
                SnowEmitterView(condition: condition)
            case .clear:
                Color.clear
            case .rainy, .stormy:
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: scenePhase != .active)) { timeline in
                    let elapsed = timeline.date.timeIntervalSince(start)
                    let condition = condition
                    let darkAppearance: Float = colorScheme == .dark ? 1 : 0
                    Rectangle()
                        .fill(.white)
                        .visualEffect { content, geometry in
                            content.colorEffect(Self.shader(condition: condition, size: geometry.size, time: elapsed, darkAppearance: darkAppearance))
                        }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    nonisolated private static func shader(condition: WeatherCondition, size: CGSize, time: TimeInterval, darkAppearance: Float) -> Shader {
        switch condition {
        case .rainy(let windSpeed), .stormy(let windSpeed):
            let storm = if case .stormy = condition { true } else { false }
            // Existing rain/snow values are scaled emitter acceleration (km/h × 5).
            let wind = min(max(Double(windSpeed) / 500, 0), 0.65)
            return ShaderLibrary.Rain(
                .float2(size), .float(time),
                .float(storm ? 0.95 : 0.65), .float(wind),
                .float(storm ? 1.6 : 1), .float(darkAppearance)
            )
        case .clear, .snowy:
            preconditionFailure("Only rain uses a weather shader")
        }
    }
}

#Preview("Snow appearances") {
    VStack(spacing: 0) {
        ZStack {
            Color(white: 0.95)
            WeatherEffectView(condition: .snowy(windSpeed: 5))
        }
        .environment(\.colorScheme, .light)
        ZStack {
            Color(white: 0.08)
            WeatherEffectView(condition: .snowy(windSpeed: 5))
        }
        .environment(\.colorScheme, .dark)
    }
    .ignoresSafeArea()
}
