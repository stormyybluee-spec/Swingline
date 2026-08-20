//
//  AppStore.swift
//  Swingline
//
//  Translation of src/state/store.js.
//
//  Navigation is an explicit stack, not a NavigationStack and not a router.
//  That is a deliberate carry over: the web app owns its own stack so the
//  outgoing and incoming screens are briefly mounted together for the shared
//  element transition, and a router's unmount timing fights that. The same
//  reasoning holds in SwiftUI with matchedGeometryEffect.
//
//  House rule: no em dashes anywhere.
//

import SwiftUI
import Observation
import AVFoundation
import UIKit

// MARK: - Screens

enum Screen: String, Hashable, CaseIterable {
    case home, timeline, capture, upload, analysis, compare, coach, settings, paywall, onboarding
}

// Screens that own the whole viewport and hide the tab bar.
// src/App.jsx CHROME_LESS.
let chromeLessScreens: Set<Screen> = [.onboarding, .paywall, .capture]

struct NavEntry: Hashable {
    var screen: Screen
    var params: NavParams
}

// The web store passes a loose params object. This keeps it typed, since every
// use in the source is one of these four.
struct NavParams: Hashable {
    var swingId: String? = nil
    var focusDrill: String? = nil
    var returnTo: Screen? = nil
    var returnParams: [String: String] = [:]

    static let none = NavParams()
}

// MARK: - Store

@Observable
final class AppStore {

    // Boot state
    var ready = false

    // Navigation
    var screen: Screen = .home
    var params: NavParams = .none
    private(set) var history: [NavEntry] = []

    // The card the golfer tapped, so the thumbnail can expand into the
    // analysis screen rather than hard cutting to it.
    var sharedId: String?

    // Data
    var settings = AppSettings()
    var swings: [SwingRecord] = []
    var quota: Quota = .free
    var rating: Rating = .new()

    // On device persistence for swings and their frames. File based, see
    // SwingDataStore for why not SwiftData.
    private let dataStore = SwingDataStore()

    // True while a full viewport overlay is open, so the tab bar is gated on
    // real state rather than a style rule. This was a real bug on device.
    var viewportOpen = false

    // Transient
    var toast: Toast?
    var storageWarning: String?

    struct Toast: Identifiable, Equatable {
        var id = UUID()
        var message: String
        var tone: Tone = .info
        enum Tone { case info, good, warn }
    }

    private let settingsKey = "swingline.settings"
    private let ratingKey = "swingline.rating"

    /*
      Fill the app with a few fake swings on launch so the populated UI, the
      stat bubbles, the trend chart, the swing grid, can be seen before the
      persistence layer exists.

      Off by default, because a real first run has no swings and the app should
      be honest about that. Flip this to true to preview the full interface, and
      back to false before shipping. Nothing else in the app reads it.
    */
    static let seedSampleData = false

    /*
      The one thumbnail box, 4:3.

      Both producers agree on this: the video grab crops to it, the skeleton
      fallback draws into it, and the card layout clamps its frame to
      thumbAspect. That is the whole fix for the ragged grid. Do not size a
      thumbnail anywhere else.
    */
    static let thumbSize = SwingThumbnail.size
    static let thumbAspect = SwingThumbnail.aspect

    // MARK: Boot

    func boot() {
        loadSettings()
        loadRating()

        // Real swings first. The persistence layer is now wired, so a returning
        // golfer sees their own history on launch.
        let loaded = dataStore.loadAllRecords()
        if !loaded.records.isEmpty {
            swings = loaded.records
        } else if Self.seedSampleData && swings.isEmpty {
            // No stored swings yet. The sample seed is only for previewing the
            // populated interface and stays off for a real first run.
            swings = AppStore.sampleSwings()
            rating = Rating(rating: 64, rd: 5, swings: swings.count, updatedAt: Date().timeIntervalSince1970 * 1000)
        }

        // One unreadable file must never cost the rest of the history. If any
        // were skipped, say so quietly rather than pretending they were never
        // there.
        if !loaded.skipped.isEmpty {
            storageWarning = "\(loaded.skipped.count) saved swing\(loaded.skipped.count == 1 ? "" : "s") could not be read."
        }

        ready = true
        screen = .home
    }

    // A week of fake swings, scored across the four categories, so every screen
    // has something real shaped to draw. Deliberately varied so the trend line
    // is not flat and the weakest category moves between swings.
    private static func sampleSwings() -> [SwingRecord] {
        let calendar = Calendar.current
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let clubs = ["7 iron", "Driver", "Pitching wedge", "5 iron", "9 iron"]
        let overalls = [58, 61, 60, 67, 64, 71, 69]

        return overalls.enumerated().map { index, overall in
            let date = calendar.date(byAdding: .day, value: -(overalls.count - 1 - index), to: Date()) ?? Date()
            let categories: [CategoryKey: Int] = [
                .sequencing: overall - 4 + (index % 3),
                .rotation: overall + 3 - (index % 2) * 5,
                .balance: overall - 2 + (index % 4),
                .finish: overall + 1,
            ]
            let weakest = categories.min { $0.value < $1.value }?.key
            return SwingRecord(
                id: "sample-\(index)",
                createdAt: date,
                day: dayFormatter.string(from: date),
                club: clubs[index % clubs.count],
                analysed: true,
                confidence: 0.8,
                scores: Scores(overall: overall, categoryScores: categories, weakest: weakest),
                diagnosis: DiagnosisResult(
                    headline: "Your chest and hips turned as one block.",
                    detail: "Sample diagnosis for previewing the interface.",
                    category: weakest,
                    drill: "cross-arm-turn",
                    faultId: "no-separation",
                    faults: [],
                    clean: false
                ),
                phases: PhaseSummary(idx: [:], tempoRatio: 2.8 + Double(index % 3) * 0.2, backswingMs: 780, downswingMs: 280)
            )
        }.reversed()
    }

    // MARK: Navigation

    // Onboarding hangs off the first real move rather than gating entry, so a
    // new golfer sees the product before being told about it.
    func go(_ next: Screen, params nextParams: NavParams = .none, sharedId: String? = nil) {
        if !settings.onboarded && next != .onboarding {
            pushHistory()
            screen = .onboarding
            params = NavParams(returnTo: next)
            self.sharedId = nil
            return
        }

        pushHistory()
        screen = next
        params = nextParams
        self.sharedId = sharedId
    }

    // Capped at 12. A stack that grows without limit on a screen a golfer
    // bounces in and out of all session is a slow leak, not a feature.
    private func pushHistory() {
        history.append(NavEntry(screen: screen, params: params))
        if history.count > 12 {
            history.removeFirst(history.count - 12)
        }
    }

    func back() {
        guard let prev = history.popLast() else {
            screen = .home
            params = .none
            sharedId = nil
            return
        }
        screen = prev.screen
        params = prev.params
        sharedId = nil
    }

    // MARK: Settings

    func update(_ mutate: (inout AppSettings) -> Void) {
        var next = settings
        mutate(&next)
        settings = next
        persistSettings()
    }

    private func loadSettings() {
        guard
            let data = UserDefaults.standard.data(forKey: settingsKey),
            let decoded = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return }
        settings = decoded
    }

    private func persistSettings() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: settingsKey)
    }

    private func loadRating() {
        guard
            let data = UserDefaults.standard.data(forKey: ratingKey),
            let decoded = try? JSONDecoder().decode(Rating.self, from: data)
        else { return }
        rating = decoded
    }

    // MARK: Swings

    // A finished swing from capture. Inserted into the live list and written to
    // disk so it survives a restart. Frames are stored alongside the record for
    // later playback, empty for a failed capture that has nothing to replay.
    //
    // A save failure is surfaced quietly rather than thrown: the swing is still
    // in the list for this session, and the golfer is told it may not have been
    // kept, which is more honest than a silent loss or a crash.
    func recordNewSwing(_ record: SwingRecord, frames: [Frame]) {
        swings.insert(record, at: 0)
        // A live swing has no clip, so this draws the tracked figure. Every
        // analysed swing gets a tile that shows itself, not a blank placeholder.
        let thumb = bestThumbnail(video: nil, frames: frames)
        do {
            try dataStore.save(record, frames: frames.isEmpty ? nil : frames, thumbnail: thumb)
        } catch {
            storageWarning = "A swing was recorded but could not be saved to disk."
        }
        if let thumb { try? FileManager.default.removeItem(at: thumb) }

        if record.analysed, let overall = record.scores?.overall {
            notify("Swing saved, \(overall) overall", tone: .good)
        } else {
            notify("Swing saved", tone: .info)
        }
    }

    /*
      Save a swing that came from an uploaded video, keeping the clip so it plays
      back in analysis.

      Same shape as recordNewSwing, with two differences. The frames are always
      kept, because an uploaded swing is worth replaying even when the engine
      could not score it. And the video is passed through to the store, which
      moves it into the swing's own slot, so the timeline thumbnail and the
      analysis player both have a clip to show. The caller hands over a copy it no
      longer needs, since save moves the file.

      thumbnail is the 4:3 tile UploadProcessor already cropped from a frame it
      had decoded anyway. Passing it in avoids opening the asset a second time
      just to grab an image the pipeline already held. It stays optional, so an
      older caller that passes nothing still gets a thumbnail through
      bestThumbnail, and a hand off that failed still falls back to the skeleton.
    */
    func recordUploadedSwing(_ record: SwingRecord, frames: [Frame], video: URL?, thumbnail: URL? = nil) {
        swings.insert(record, at: 0)
        // The handed off tile first, then the clip frame, then the tracked
        // figure, so an uploaded swing whose thumbnail grab fails still shows
        // something real.
        let thumb = thumbnail ?? bestThumbnail(video: video, frames: frames)
        do {
            try dataStore.save(record, frames: frames.isEmpty ? nil : frames, video: video, thumbnail: thumb)
        } catch {
            storageWarning = "The uploaded swing could not be saved to disk."
        }
        if let thumb { try? FileManager.default.removeItem(at: thumb) }

        if record.analysed, let overall = record.scores?.overall {
            notify("Uploaded swing analysed, \(overall) overall", tone: .good)
        } else if record.analysed {
            notify("Uploaded swing analysed", tone: .good)
        } else {
            notify("Uploaded swing saved, but the engine could not score it", tone: .info)
        }
    }

    // Remove a swing from the list and from disk, including its frames, video,
    // thumbnail and annotation.
    //
    // No toast here, on purpose. The single delete paths already tell the golfer
    // what happened by leaving the screen, and a per swing toast would fire once
    // per id during a bulk delete. deleteSwings posts one toast for the batch.
    func deleteSwing(id: String) {
        swings.removeAll { $0.id == id }
        dataStore.delete(id)
    }

    /*
      Delete a selection in one go, with one toast for the whole batch.

      Ids that no longer exist are skipped rather than counted, so a selection
      that went stale while the sheet was open cannot report deleting swings that
      were already gone, and cannot crash. Returns the number actually removed so
      the view can decide what to do next.
    */
    @discardableResult
    func deleteSwings(ids: Set<String>) -> Int {
        var deleted = 0
        for id in ids where swings.contains(where: { $0.id == id }) {
            deleteSwing(id: id)
            deleted += 1
        }
        if deleted > 0 {
            notify(deleted == 1 ? "Deleted 1 swing" : "Deleted \(deleted) swings", tone: .info)
        }
        return deleted
    }

    // Frames for a stored swing, loaded on demand. The timeline never needs
    // these, only playback and overlays do, so they are not held in memory with
    // the record.
    func frames(for id: String) -> [Frame]? {
        dataStore.loadFrames(id)
    }

    func openSwing(id: String, sharedId: String? = nil) {
        guard swings.contains(where: { $0.id == id }) else { return }
        go(.analysis, params: NavParams(swingId: id), sharedId: sharedId ?? id)
    }

    var analysedSwings: [SwingRecord] {
        swings.filter(\.analysed)
    }

    var lastAnalysed: SwingRecord? {
        analysedSwings.max(by: { $0.createdAt < $1.createdAt })
    }

    // MARK: Derived

    // src/storage/swings.js heatmap, current streak only.
    var streak: StreakSummary {
        guard !swings.isEmpty else { return .none }
        let days = Set(swings.map(\.day))
        var current = 0
        var cursor = Calendar.current.startOfDay(for: Date())
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        // One day of grace, so a single missed day does not wipe a run.
        var grace = 1
        while true {
            if days.contains(formatter.string(from: cursor)) {
                current += 1
            } else if grace > 0 {
                grace -= 1
            } else {
                break
            }
            guard let prev = Calendar.current.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        return StreakSummary(current: current, longest: current)
    }

    // src/storage/swings.js trend. Days with no practice are gaps, never
    // joined through, because a flat line across a fortnight nobody played is
    // a lie that costs every other chart its credibility.
    func trend(days: Int) -> Trend {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        let inRange = swings.filter { $0.analysed && $0.createdAt >= cutoff }
        guard !inRange.isEmpty else { return Trend(points: [], days: days, change: [:]) }

        var byDay: [String: [SwingRecord]] = [:]
        for swing in inRange { byDay[swing.day, default: []].append(swing) }

        let points: [TrendPoint] = byDay
            .map { key, group -> TrendPoint in
                let at = group.map(\.createdAt).min() ?? Date()
                let overall = group.compactMap { $0.scores?.overall }
                var categories: [String: Int] = [:]
                for category in ScoreCategory.allCases {
                    let values = group.compactMap { $0.scores?.score(for: category) }
                    if !values.isEmpty {
                        categories[category.rawValue] = Int((Double(values.reduce(0, +)) / Double(values.count)).rounded())
                    }
                }
                return TrendPoint(
                    day: key,
                    at: at,
                    count: group.count,
                    overall: overall.isEmpty ? 0 : Int((Double(overall.reduce(0, +)) / Double(overall.count)).rounded()),
                    categories: categories
                )
            }
            .sorted { $0.at < $1.at }

        var change: [String: Int] = [:]
        if points.count > 1, let first = points.first, let last = points.last {
            change["overall"] = last.overall - first.overall
            for category in ScoreCategory.allCases {
                if let a = first.categories[category.rawValue], let b = last.categories[category.rawValue] {
                    change[category.rawValue] = b - a
                }
            }
        }

        return Trend(points: points, days: days, change: change)
    }

    // MARK: Toast

    func notify(_ message: String, tone: Toast.Tone = .info) {
        let next = Toast(message: message, tone: tone)
        toast = next
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_200_000_000)
            guard let self else { return }
            if self.toast?.id == next.id { self.toast = nil }
        }
    }

    func dismissToast() { toast = nil }

    // MARK: Phase 5 additions (video URL access, edit swap, annotation IO)

    // The on disk video for a swing, if one exists. Views need this to hand a
    // URL to the video editor and to the player. Nil when the capture pipeline
    // has not written a clip yet, which today is most swings.
    /*
      A JPEG thumbnail from a clip, written to a temporary file, or nil if it
      cannot be made. The caller hands the URL to the store, which copies it into
      the swing's slot. Grabbing near the middle of the clip lands close to
      impact for most swings, a more telling frame than the address.
    */
    func generateThumbnail(from videoURL: URL, atFraction fraction: Double) -> URL? {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        // The preferred transform matters before anything else: without it a
        // clip shot in portrait decodes sideways and the centre crop would take
        // the wrong band of the picture.
        generator.appliesPreferredTrackTransform = true
        /*
          Ask for something bigger than the tile, not the tile itself. The cap is
          a bounding box, not a shape, so 640x640 on a portrait clip returned an
          image far narrower than the 4:3 box and left nothing to crop from.
          1280 gives the crop room on either axis and still decodes fast.
        */
        generator.maximumSize = CGSize(width: 1280, height: 1280)

        let seconds = CMTimeGetSeconds(asset.duration)
        let time = (seconds.isFinite && seconds > 0)
            ? CMTime(seconds: seconds * fraction, preferredTimescale: 600)
            : CMTime(seconds: 0, preferredTimescale: 600)

        // Nil on any failure, no video track or a timing that will not resolve,
        // so bestThumbnail falls through to the skeleton rather than writing a
        // tile that is the wrong shape.
        guard let cg = try? generator.copyCGImage(at: time, actualTime: nil) else { return nil }
        return SwingThumbnail.makeFile(from: cg)
    }

    // The stored thumbnail file for a swing, or nil when none was written, for
    // example a live recorded swing that has no clip to grab from yet.
    func thumbnailPath(for id: String) -> String? {
        let url = dataStore.thumbnailURL(id)
        return FileManager.default.fileExists(atPath: url.path) ? url.path : nil
    }

    /*
      A thumbnail for a swing, video frame first, tracked skeleton second.

      A clip gives a real frame. A live swing has no clip yet, so it falls back to
      drawing the tracked figure, which is still the swing's own data rather than a
      generic placeholder. Returns a temp file the store then moves into place.
    */
    private func bestThumbnail(video: URL?, frames: [Frame]) -> URL? {
        if let video, let fromVideo = generateThumbnail(from: video, atFraction: 0.5) {
            return fromVideo
        }
        if !frames.isEmpty {
            return skeletonThumbnail(from: frames)
        }
        return nil
    }

    /*
      Draw the tracked figure from a representative frame as a thumbnail.

      The finish frame is distinctive and recognisable in a grid. Bones then
      joints, in citrus on the app's dark ground, so a live swing reads as itself
      rather than a blank tile.
    */
    private func skeletonThumbnail(from frames: [Frame]) -> URL? {
        guard let frame = frames.last else { return nil }
        // The same 4:3 box the video grab produces, so a live swing and an
        // uploaded one sit in the grid at identical size.
        let size = AppStore.thumbSize
        let landmarks = frame.norm
        let citrus = UIColor(red: 200 / 255, green: 1, blue: 77 / 255, alpha: 1)

        /*
          Normalised landmarks are fractions of their source frame, which for a
          phone clip is portrait. Multiplying x by a landscape width and y by a
          landscape height, as the old 3:4 code effectively did, would squash the
          figure sideways in the new box.

          So the figure is drawn into a 3:4 stage that keeps its proportions,
          scaled to the box height and centred horizontally. Nothing shows around
          it, because the turf fill covers the whole 4:3 tile, so this reads as a
          centred figure rather than as letterboxing.
        */
        let stageHeight = size.height * 0.94
        let stageWidth = stageHeight * 0.75
        let originX = (size.width - stageWidth) / 2
        let originY = (size.height - stageHeight) / 2
        // Joint dots scale with the stage so they do not shrink to pinpricks
        // now that the tile is larger than the old 360x480.
        let jointRadius: CGFloat = max(4, stageHeight / 480 * 4)

        func pt(_ i: Int) -> CGPoint? {
            guard i < landmarks.count else { return nil }
            let l = landmarks[i]
            let vis = l.visibility ?? l.score ?? 1
            guard vis >= 0.35 else { return nil }
            return CGPoint(
                x: originX + CGFloat(l.x) * stageWidth,
                y: originY + CGFloat(l.y) * stageHeight
            )
        }

        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            let c = context.cgContext
            UIColor(red: 8 / 255, green: 13 / 255, blue: 10 / 255, alpha: 1).setFill()
            c.fill(CGRect(origin: .zero, size: size))

            let path = CGMutablePath()
            for (a, b) in Landmarks.BONES {
                if let pa = pt(a), let pb = pt(b) {
                    path.move(to: pa)
                    path.addLine(to: pb)
                }
            }
            c.setStrokeColor(citrus.withAlphaComponent(0.9).cgColor)
            c.setLineWidth(max(2, jointRadius / 2))
            c.setLineCap(.round)
            c.addPath(path)
            c.strokePath()

            citrus.setFill()
            for i in Landmarks.DRAWN_JOINTS {
                if let p = pt(i) {
                    let r = jointRadius
                    c.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
                }
            }
        }

        guard let data = image.jpegData(compressionQuality: 0.72) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    func videoURL(for id: String) -> URL? {
        let url = dataStore.videoURL(id)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // Replace a swing's clip with an edited one and report the outcome. The
    // record itself does not change, so the timeline and scores are untouched.
    /*
      Star or unstar a swing.

      favourite already lives on SwingRecord and already rides along in the JSON
      the store writes, so this is the whole feature: flip the flag on the live
      record, then persist the record so the star survives a restart. Frames and
      video are untouched, so this never rewrites the heavy sidecar files.

      Returns the new state so a caller holding a local copy can update without
      re-reading the list.
    */
    /* Write a record back to disk without touching its frames or video. */
    func persistRecord(_ record: SwingRecord) {
        do {
            try dataStore.save(record)
        } catch {
            storageWarning = "Could not save the swing to disk."
        }
    }

    @discardableResult
    func toggleFavourite(for id: String) -> Bool {
        guard let index = swings.firstIndex(where: { $0.id == id }) else { return false }
        swings[index].favourite.toggle()
        let updated = swings[index]
        do {
            try dataStore.save(updated)
        } catch {
            storageWarning = "Could not save the favourite to disk."
        }
        return updated.favourite
    }

    func isFavourite(_ id: String) -> Bool {
        swings.first { $0.id == id }?.favourite ?? false
    }

    func replaceVideo(for id: String, with newVideo: URL) {
        do {
            try dataStore.replaceVideo(id, with: newVideo)
            notify("Video updated.", tone: .good)
        } catch {
            notify("Could not save the edited video.", tone: .warn)
        }
    }

    // Read and write the freehand annotation for a swing. Data is a PencilKit
    // PKDrawing dataRepresentation; the store keeps it in a sidecar file.
    func annotation(for id: String) -> Data? {
        dataStore.loadAnnotation(id)
    }

    func saveAnnotation(for id: String, data: Data?) {
        dataStore.saveAnnotation(id, data: data)
    }
}

// MARK: - Greeting

// src/screens/Home.jsx and src/screens/Timeline.jsx both use this, identically.
func swinglineGreeting(at date: Date = Date()) -> String {
    let hour = Calendar.current.component(.hour, from: date)
    if hour < 11 { return "Morning range" }
    if hour < 17 { return "Good afternoon" }
    if hour < 21 { return "Evening session" }
    return "Late one"
}