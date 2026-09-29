//
//  MapLocationsView.swift
//  Meet and Eat
//
//  Created by Ryan Nair on 11/8/24.
//
//

import SwiftUI
import CoreLocation
import Observation
@preconcurrency import MapKit

private struct Restaurant: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let address: String
    let distance: Double
    let coordinate: CLLocationCoordinate2D
    let category: MKPointOfInterestCategory?

    var distanceString: String {
        String(format: "%.1f mi", distance)
    }

    var systemIcon: String {
        switch category {
        case .bakery: return "birthday.cake.fill"
        case .cafe: return "cup.and.saucer.fill"
        case .brewery: return "mug.fill"
        case .nightlife: return "wineglass.fill"
        default: return "fork.knife"
        }
    }

    var color: Color {
        switch category {
        case .bakery: return .pink
        case .cafe: return .brown
        case .brewery: return .orange
        default: return .indigo
        }
    }

    static func == (lhs: Restaurant, rhs: Restaurant) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - 2. MAIN VIEW
struct MapLocationsView: View {
    @State private var viewModel = MapLocationsViewModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    // Manage camera position state
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var selectedRestaurantID: UUID?
    @State private var showSearchButton = false

    @State private var visibleRegionCenter: CLLocationCoordinate2D?

    var body: some View {
        VStack(spacing: 0) {

            // --- MAP LAYER ---
            ZStack(alignment: .bottom) {
                Map(position: $position, selection: $selectedRestaurantID) {
                    UserAnnotation()

                    ForEach(viewModel.restaurants) { restaurant in
                        Marker(restaurant.name, systemImage: restaurant.systemIcon, coordinate: restaurant.coordinate)
                            .tint(restaurant.color)
                            .tag(restaurant.id)
                    }
                }
                .mapControls {
                    MapUserLocationButton()
                    MapCompass()
                }
                .onMapCameraChange(frequency: .onEnd) { context in
                    visibleRegionCenter = context.region.center

                    // Show "Search Here" if moved significantly
                    if let lastSearch = viewModel.lastSearchCoordinate {
                        let distance = context.region.center.distance(to: lastSearch)
                        if distance > 800 { // Show button after moving ~0.5 miles
                            withAnimation(reduceMotion ? nil : .snappy) { showSearchButton = true }
                        }
                    }
                }

                // SEARCH BUTTON
                if showSearchButton {
                    Button {
                        if let center = visibleRegionCenter {
                            Task {
                                if await viewModel.search(at: center) {
                                    withAnimation(reduceMotion ? nil : .snappy) { showSearchButton = false }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise")
                            Text("Search This Area")
                        }
                        .font(.subheadline.bold())
                        .padding(.vertical, 8)
                        .padding(.horizontal, 16)
                        .background(.thinMaterial)
                        .clipShape(Capsule())
                        .shadow(radius: 3)
                    }
                    .disabled(viewModel.isSearching)
                    .padding(.bottom, 20)
                    .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
                }
            }
            .containerRelativeFrame(.vertical) { height, _ in min(420, height * 0.45) }

            // --- LIST LAYER ---
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if viewModel.isLocating || viewModel.isSearching {
                            ProgressView(viewModel.isLocating ? "Finding your location…" : "Finding nearby food…")
                                .frame(maxWidth: .infinity).padding()
                        }
                        if let message = viewModel.statusMessage {
                            VStack(spacing: 12) {
                                Label(message, systemImage: viewModel.needsLocationPermission ? "location.slash" : "wifi.slash")
                                    .font(.subheadline).foregroundStyle(.secondary)
                                if viewModel.needsLocationPermission {
                                    Button("Open Settings") {
                                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                                        UIApplication.shared.open(url)
                                    }
                                } else {
                                    Button("Try Again") {
                                        if let center = viewModel.lastSearchCoordinate ?? visibleRegionCenter,
                                           !viewModel.restaurants.isEmpty {
                                            Task { await viewModel.search(at: center) }
                                        } else { viewModel.checkLocationAuthorization() }
                                    }
                                    .disabled(viewModel.isLocating || viewModel.isSearching)
                                }
                            }.padding()
                        }
                        if viewModel.restaurants.isEmpty {
                            if !viewModel.isLocating && !viewModel.isSearching && viewModel.statusMessage == nil {
                                ContentUnavailableView("No Places Found", systemImage: "fork.knife", description: Text("Try moving the map to a different area."))
                                    .padding(.top, 40)
                            }
                        } else {
                            ForEach(viewModel.restaurants) { restaurant in
                                RestaurantRow(
                                    restaurant: restaurant,
                                    isSelected: selectedRestaurantID == restaurant.id
                                ) {
                                    viewModel.openInMaps(restaurant: restaurant)
                                }
                                .id(restaurant.id)
                                .padding(.horizontal)
                                .padding(.vertical, 8)
                                .background(
                                    selectedRestaurantID == restaurant.id ? Color.indigo.opacity(0.05) : Color.clear
                                )
                            }
                        }
                    }
                    .padding(.vertical)
                }
                .background(Color(.systemGroupedBackground))
                .onChange(of: selectedRestaurantID) {
                    if let selectedRestaurantID {
                        withAnimation(reduceMotion ? nil : .smooth) {
                            proxy.scrollTo(selectedRestaurantID, anchor: .center)
                        }
                    }
                }
            }
        }
        .onAppear { viewModel.checkLocationAuthorization() }
        .onChange(of: scenePhase) {
            if scenePhase == .active { viewModel.checkLocationAuthorization() }
            else { viewModel.stop() }
        }
        .onDisappear { viewModel.stop() }
    }
}

// MARK: - 3. PRIVATE ROW COMPONENT
private struct RestaurantRow: View {
    let restaurant: Restaurant
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(restaurant.color.opacity(0.1))
                        .frame(width: 44, height: 44)

                    Image(systemName: restaurant.systemIcon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(restaurant.color)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(restaurant.name)
                        .font(.body)
                        .fontWeight(isSelected ? .bold : .semibold)
                        .foregroundStyle(.primary)

                    Text(restaurant.address)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text(restaurant.distanceString)
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)

                    Image(systemName: "location.circle")
                        .font(.title3)
                        .foregroundStyle(.tint)
                }
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: Color.black.opacity(0.04), radius: 3, x: 0, y: 1)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? restaurant.color : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 4. VIEW MODEL
@Observable @MainActor
private final class MapLocationsViewModel: NSObject {
    var restaurants: [Restaurant] = []
    private(set) var isLocating = true
    private(set) var isSearching = false
    private(set) var statusMessage: String?
    private(set) var needsLocationPermission = false
    @ObservationIgnored private var activeSearch: MKLocalSearch?
    @ObservationIgnored private var searchGeneration = 0

    // We store the last search location to know when to show the "Search Here" button
    @ObservationIgnored var lastSearchCoordinate: CLLocationCoordinate2D?
    private let locationManager = CLLocationManager()

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func checkLocationAuthorization() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            isLocating = true
            locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            if needsLocationPermission { statusMessage = nil }
            needsLocationPermission = false
            guard restaurants.isEmpty, !isSearching else { return }
            statusMessage = nil
            isLocating = true
            locationManager.requestLocation()
        case .denied, .restricted:
            stop()
            needsLocationPermission = true
            statusMessage = "Allow location access to find food near you."
        @unknown default:
            stop()
            statusMessage = "Your location is unavailable. Try again."
        }
    }

    func stop() {
        locationManager.stopUpdatingLocation()
        activeSearch?.cancel()
        activeSearch = nil
        searchGeneration &+= 1
        isLocating = false
        isSearching = false
    }

    @discardableResult
    func search(at coordinate: CLLocationCoordinate2D) async -> Bool {
        activeSearch?.cancel()
        searchGeneration &+= 1
        let generation = searchGeneration
        isSearching = true
        statusMessage = nil
        defer {
            if generation == searchGeneration {
                isSearching = false
                activeSearch = nil
            }
        }

        let request = MKLocalPointsOfInterestRequest(center: coordinate, radius: 3000)
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.restaurant, .bakery, .cafe, .brewery, .nightlife, .foodMarket])

        let search = MKLocalSearch(request: request)
        activeSearch = search

        do {
            let response = try await withTaskCancellationHandler {
                try await search.start()
            } onCancel: {
                Task { @MainActor in search.cancel() }
            }
            guard generation == searchGeneration, !Task.isCancelled else { return false }
            lastSearchCoordinate = coordinate
            self.restaurants = response.mapItems.compactMap { item -> Restaurant? in
                guard let name = item.name,
                      let location = item.placemark.location else { return nil }

                let address = [item.placemark.subThoroughfare, item.placemark.thoroughfare]
                    .compactMap { $0 }
                    .joined(separator: " ")

                let distanceInMeters = location.distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
                let miles = distanceInMeters * 0.000621371

                return Restaurant(name: name,
                                  address: address.isEmpty ? item.placemark.locality ?? "" : address,
                                  distance: miles,
                                  coordinate: location.coordinate,
                                  category: item.pointOfInterestCategory)
            }.sorted { $0.distance < $1.distance }
            return true
        } catch {
            guard generation == searchGeneration, !Task.isCancelled else { return false }
            statusMessage = restaurants.isEmpty
                ? "Nearby food could not be loaded. Try again."
                : "Couldn’t update nearby food. Showing your last results."
            return false
        }
    }

    func openInMaps(restaurant: Restaurant) {
        let mapItem = MKMapItem(placemark: MKPlacemark(coordinate: restaurant.coordinate))
        mapItem.name = restaurant.name
        mapItem.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
    }
}

// Delegate handling
extension MapLocationsViewModel: @preconcurrency CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        checkLocationAuthorization()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard isLocating,
              let location = locations.last(where: { $0.horizontalAccuracy >= 0 }) else { return }
        isLocating = false
        manager.stopUpdatingLocation()
        if restaurants.isEmpty { Task { await search(at: location.coordinate) } }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        guard isLocating else { return }
        isLocating = false
        statusMessage = "Your location is unavailable. Try again."
    }

}

// Helper for distance calculation
extension CLLocationCoordinate2D {
    func distance(to other: CLLocationCoordinate2D) -> CLLocationDistance {
        let loc1 = CLLocation(latitude: latitude, longitude: longitude)
        let loc2 = CLLocation(latitude: other.latitude, longitude: other.longitude)
        return loc1.distance(from: loc2)
    }
}
