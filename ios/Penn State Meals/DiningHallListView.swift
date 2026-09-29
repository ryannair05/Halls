//
//  DiningHallListView.swift
//  Meet and Eat
//
//  Created by Ryan Nair on 5/19/24.
//

import SwiftUI
import MapKit
import WeatherKit


struct WeatherView: View {
    @State private var currentWeather: CurrentWeather?
    @State private var weatherAlerts: [WeatherAlert]?
    @State private var weatherLoadFailed = false
    @Binding var weather: WeatherCondition
    @Binding var liveWeather: Bool
    private let location = CLLocation(latitude: 40.7982, longitude: -77.8599)
    
    var body: some View {
        Group {
            if let weather = currentWeather {
                VStack(alignment: .leading, spacing: 6) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: weather.symbolName)
                                .font(.title3)
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)

                            Text(weather.condition.description)
                                .font(.headline)

                            Spacer(minLength: 8)

                            Text(weather.temperature.formatted(.measurement(
                                width: .abbreviated,
                                usage: .weather,
                                numberFormatStyle: .number.precision(.fractionLength(0))
                            )))
                            .font(.title3.weight(.semibold))
                            .monospacedDigit()
                            .fixedSize()
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Label(weather.condition.description, systemImage: weather.symbolName)
                                .font(.headline)
                                .foregroundStyle(.primary)

                            Text(weather.temperature.formatted(.measurement(
                                width: .abbreviated,
                                usage: .weather,
                                numberFormatStyle: .number.precision(.fractionLength(0))
                            )))
                            .font(.title3.weight(.semibold))
                            .monospacedDigit()
                        }
                    }

                    if let alert = weatherAlerts?.first {
                        Label(alert.summary, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .symbolRenderingMode(.multicolor)
                    }
                }
                .accessibilityElement(children: .combine)
            } else if weatherLoadFailed {
                Label("Campus weather unavailable", systemImage: "cloud.slash")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "cloud.sun")
                        .font(.title3)
                    Text("Campus weather")
                        .font(.headline)
                    Spacer(minLength: 8)
                    Text("72°")
                        .font(.title3.weight(.semibold))
                }
                .redacted(reason: .placeholder)
                .accessibilityLabel("Loading campus weather")
            }
        }
        .task {
            if let date = currentWeather?.date, Calendar.current.isDateInToday(date) {
                return
            }
            await fetchWeather()
        }
        .onChange(of: liveWeather) {
            guard liveWeather, let currentWeather else { return }
            weather = mapWeatherKitToCondition(currentWeather: currentWeather)
        }
    }
    
    /// Fetches weather data and updates the view's state.
    private func fetchWeather() async {
        weatherLoadFailed = false
        do {
            let weatherData = try await WeatherService.shared.weather(for: location)
            guard !Task.isCancelled else { return }
            let currentWeather = weatherData.currentWeather
            
            if liveWeather {
                weather = mapWeatherKitToCondition(currentWeather: currentWeather)
            }
            
            self.currentWeather = weatherData.currentWeather
            self.weatherAlerts = weatherData.weatherAlerts
            
        } catch {
            guard !Task.isCancelled else { return }
            weatherLoadFailed = true
            print("❌ Failed to fetch weather: \(error.localizedDescription)")
        }
    }
}

struct DiningHallListView: View {
    let purchaseManager: PurchaseManager
    let mealJournal: MealJournal
    let environment: DiningMenuEnvironment

    var body: some View {
        DiningHallListControllerRepresentable(
            purchaseManager: purchaseManager,
            mealJournal: mealJournal,
            environment: environment
        )
            // UIKit's split/navigation controllers handle safe areas for every column.
            // Insetting this host as well reserves the trailing system rail twice.
            .ignoresSafeArea(.container)
            .task {
                if purchaseManager.liveWeather && !purchaseManager.hasUnlockedPro {
                    await purchaseManager.updatePurchasedProducts()
                }
            }
    }


}

#Preview {
    DiningHallListView(
        purchaseManager: PurchaseManager(),
        mealJournal: MealJournal(inMemory: true),
        environment: .shared
    )
}
