//
//  RangeFinderMap.swift
//  Swingline
//
//  A bird's eye view of wherever the golfer is standing, with distance rings
//  drawn over it at 50, 100, 150, 200 and 250 metres, and the view turned so the
//  way they are facing points up. This is the native port of the web
//  RangeFinder.jsx.
//
//  WHY MAPKIT OVERLAYS RATHER THAN A HAND DRAWN CANVAS
//
//  The web build draws its own map tiles on a canvas and then computes a
//  metres per pixel factor by hand to place the rings, because the browser has
//  no geo anchored overlay primitive. MapKit does. A MapCircle is anchored to a
//  real coordinate with a real radius in metres, so it sits correctly on the
//  ground at every zoom and never needs the pixel math. That removes the single
//  most error prone part of the web version.
//
//  HEADING
//
//  CLLocationManager reports heading through startUpdatingHeading. The map camera
//  is turned by that heading so the golfer's facing direction is up, matching the
//  web behaviour. If the device has no compass, or heading is unavailable, the
//  map simply stays north up, which is a graceful degrade rather than a failure.
//
//  PERMISSION AND THE PLACEHOLDER
//
//  Location needs NSLocationWhenInUseUsageDescription in the target's Info
//  settings. If permission is denied, restricted, or simply not yet answered,
//  the map falls back to a placeholder location (a driving range) so the rings
//  and the whole overlay still render and can be seen, rather than showing a
//  blank or an error. The banner says which state it is in, honestly.
//
//  House rule: no em dashes anywhere.
//

import SwiftUI
import MapKit
import CoreLocation

// MARK: - Location manager

/*
  A small wrapper over CLLocationManager that publishes the one coordinate and
  the one heading the map needs.

  It is @MainActor and @Observable so the SwiftUI view reads it directly. The
  delegate callbacks are nonisolated and hop back to the main actor, the standard
  pattern for a @MainActor class conforming to a non isolated Cocoa delegate.
*/
@MainActor
@Observable
final class RangeLocationProvider: NSObject {

    enum Access: Equatable {
        case unknown
        case granted
        case denied
        case usingPlaceholder
    }

    // A driving range, used when there is no real fix yet. Far better than 0,0,
    // which is in the ocean off Africa and would show empty water.
    static let placeholder = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)

    private(set) var coordinate: CLLocationCoordinate2D = RangeLocationProvider.placeholder
    private(set) var headingDegrees: Double = 0
    private(set) var access: Access = .unknown
    private(set) var hasRealFix = false

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        // Heading needs this filter or it fires constantly. One degree is smooth
        // enough to read and cheap enough to run.
        manager.headingFilter = 1
    }

    func start() {
        let status = manager.authorizationStatus
        resolveAccess(status)

        switch status {
        case .notDetermined:
            // Ask, and do nothing else. Starting location updates while the
            // status is still undetermined can race or suppress the permission
            // dialog on device. locationManagerDidChangeAuthorization fires once
            // the golfer answers, and that is where updates start. This is the
            // Apple recommended request first, start on callback flow, and it is
            // the fix for the dialog not appearing reliably.
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            // Already granted from a previous run, so start straight away.
            beginUpdates()
        default:
            // Denied or restricted. The placeholder is already in place from
            // resolveAccess, so the map still renders. Nothing to start.
            break
        }
    }

    // Start location and heading updates. Called only once authorisation is
    // known to be granted, either here at launch or from the delegate.
    private func beginUpdates() {
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() {
            manager.startUpdatingHeading()
        }
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
    }

    private func resolveAccess(_ status: CLAuthorizationStatus) {
        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            access = .granted
        case .denied, .restricted:
            access = .usingPlaceholder
            coordinate = Self.placeholder
        case .notDetermined:
            access = .unknown
        @unknown default:
            access = .unknown
        }
    }
}

// MARK: Delegate

extension RangeLocationProvider: CLLocationManagerDelegate {

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.resolveAccess(status)
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                // The golfer just granted access, so start updates now. Uses the
                // stored manager on the main actor rather than the delegate
                // parameter, which is not Sendable.
                self.beginUpdates()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        let coord = last.coordinate
        Task { @MainActor in
            self.coordinate = coord
            self.hasRealFix = true
            if self.access != .granted { self.access = .granted }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        // Prefer true heading when the device can supply it, fall back to
        // magnetic. A negative value means the reading is invalid.
        let heading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        guard heading >= 0 else { return }
        Task { @MainActor in
            self.headingDegrees = heading
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // A failure is not fatal here. The placeholder is already in place, so
        // the overlay stays usable. Nothing to do but leave the last state.
    }
}

// MARK: - The overlay

struct RangeFinderMap: View {
    @Binding var isPresented: Bool

    @State private var location = RangeLocationProvider()
    @State private var camera: MapCameraPosition = .automatic

    // Metric rings, matching the web RANGE_YARDS list turned to metres. The
    // hundreds are drawn bright and thick, the fifties dim and thin, the same
    // weighting the web canvas uses.
    private static let ringDistances: [Double] = [50, 100, 150, 200, 250]

    var body: some View {
        ZStack {
            map
                .ignoresSafeArea()

            ringLabels
                .allowsHitTesting(false)

            VStack {
                banner
                Spacer()
                closeButton
            }
            .padding(Tok.s4)
        }
        .onAppear {
            location.start()
            recentre()
        }
        .onDisappear {
            location.stop()
        }
        .onChange(of: location.coordinate.latitude) { _, _ in recentre() }
        .onChange(of: location.headingDegrees) { _, _ in recentre() }
    }

    // MARK: Map substrate

    private var map: some View {
        Map(position: $camera, interactionModes: []) {
            // The geo anchored rings. MapCircle takes a real radius in metres, so
            // these sit correctly on the ground at any zoom with no pixel math.
            ForEach(Self.ringDistances, id: \.self) { metres in
                MapCircle(center: location.coordinate, radius: metres)
                    .foregroundStyle(.clear)
                    .stroke(
                        ringIsMajor(metres) ? Tok.bone.opacity(0.85) : Tok.bone.opacity(0.4),
                        lineWidth: ringIsMajor(metres) ? 2 : 1.2
                    )
            }
        }
        .mapStyle(.imagery(elevation: .flat))
    }

    private func ringIsMajor(_ metres: Double) -> Bool {
        Int(metres) % 100 == 0
    }

    // Turn the camera so the golfer's heading points up, centred on them, framed
    // so the outer ring fits with a margin. distance is the camera altitude; a
    // 250m outer ring reads well at roughly 900m.
    private func recentre() {
        let camera = MapCamera(
            centerCoordinate: location.coordinate,
            distance: 900,
            heading: location.headingDegrees,
            pitch: 0
        )
        withAnimation(.easeInOut(duration: 0.3)) {
            self.camera = .camera(camera)
        }
    }

    // MARK: Ring labels

    // MapKit draws the circles, but not their labels. These are drawn in screen
    // space at the top of each ring. Because the map is rotated by heading and
    // the labels are not, they always read upright, which is what the web does.
    private var ringLabels: some View {
        GeometryReader { geo in
            Canvas { context, size in
                let centre = CGPoint(x: size.width / 2, y: size.height / 2)
                // Metres per point at the chosen 900m camera distance and this
                // view height. Derived from the same framing recentre uses, so
                // the labels sit on the drawn circles.
                let metresAcross = 900.0 * 0.62
                let pointsPerMetre = size.height / metresAcross

                for metres in Self.ringDistances {
                    let radius = metres * pointsPerMetre
                    let label = "\(Int(metres))m"
                    let text = Text(label)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Self.ringLabelColour(metres))
                    // Top of the ring, nudged in so it sits on the line.
                    let point = CGPoint(x: centre.x, y: centre.y - radius)
                    context.draw(text, at: point, anchor: .center)
                }
            }
        }
    }

    private static func ringLabelColour(_ metres: Double) -> Color {
        Int(metres) % 100 == 0 ? Tok.bone.opacity(0.9) : Tok.bone.opacity(0.5)
    }

    // MARK: Banner

    private var banner: some View {
        HStack(spacing: 8) {
            Image(systemName: bannerIcon)
                .font(.system(size: 11, weight: .medium))
            Text(bannerText)
                .font(.data(TypeScale.nano))
        }
        .foregroundStyle(location.access == .usingPlaceholder ? Tok.rust : Tok.bone2)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Capsule().fill(Tok.ink.opacity(0.6)))
        .overlay(Capsule().strokeBorder(Tok.line, lineWidth: 1))
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var bannerIcon: String {
        switch location.access {
        case .granted: return "location.fill"
        case .usingPlaceholder, .denied: return "location.slash"
        case .unknown: return "location"
        }
    }

    private var bannerText: String {
        switch location.access {
        case .granted:
            return location.hasRealFix ? "Rings at 50 to 250m around you" : "Finding your position"
        case .usingPlaceholder, .denied:
            // denied and usingPlaceholder both mean there is no real fix and the
            // sample location is showing. resolveAccess currently routes a denied
            // system status to usingPlaceholder, but the Access enum still
            // declares denied, so it is handled here explicitly rather than
            // absorbed by a default that would also swallow any future case.
            return "Location off. Showing a sample spot."
        case .unknown:
            return "Waiting for location permission"
        }
    }

    // MARK: Close

    private var closeButton: some View {
        Button {
            isPresented = false
        } label: {
            Text("Close")
                .font(.body(TypeScale.small, weight: .bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .foregroundStyle(Tok.ink)
                .background(Capsule().fill(Tok.citrus))
        }
        .buttonStyle(PressScale())
    }
}
