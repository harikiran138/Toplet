/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 */

import AppKit
import CoreLocation
import Foundation
import MapKit

/// Where this Mac is, for the Clock tab's "Here" map. Permission is asked for only when the user
/// taps "Show my location"; one coarse fix (100 m) is taken per request, never continuous tracking.
@MainActor
final class NotchLocation: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = NotchLocation()

    @Published private(set) var location: CLLocation?
    @Published private(set) var place: String?
    @Published private(set) var status: CLAuthorizationStatus
    @Published private(set) var isLocating = false

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()

    override init() {
        status = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    var isAuthorized: Bool { status == .authorizedAlways || status == .authorized }
    var isDenied: Bool { status == .denied || status == .restricted }

    /// Asks for permission the first time; afterwards takes a fresh fix unless the last one is recent.
    func locate() {
        switch status {
        case .notDetermined:
            isLocating = true
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            break
        default:
            if let location, abs(location.timestamp.timeIntervalSinceNow) < 600 { return }
            isLocating = true
            manager.requestLocation()
        }
    }

    func openInMaps() {
        guard let location else { return }
        let item = MKMapItem(placemark: MKPlacemark(coordinate: location.coordinate))
        item.name = place ?? "My Location"
        item.openInMaps(launchOptions: nil)
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.status = status
            if self.isAuthorized, self.isLocating { self.manager.requestLocation() }
            if self.isDenied { self.isLocating = false }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        Task { @MainActor in
            self.location = latest
            self.isLocating = false
            self.geocoder.reverseGeocodeLocation(latest) { placemarks, _ in
                let mark = placemarks?.first
                let name = [mark?.locality, mark?.administrativeArea ?? mark?.country].compactMap { $0 }.joined(separator: ", ")
                Task { @MainActor in self.place = name.isEmpty ? nil : name }
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.isLocating = false }
    }
}
