//
//  TimelineView.swift
//  Swingline
//
//  Port of src/screens/Timeline.jsx and src/components/TrendChart.jsx.
//
//  This screen is the retention argument. A score or a slow motion tool leaves
//  nothing behind when somebody cancels. What is here instead is a dated,
//  growing, comparative archive of one golfer's own progress, on their own
//  device, free regardless of what they pay. Presented as a diary, not a table.
//

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct TimelineView: View {
    @Environment(AppStore.self) private var store

    @State private var trendDays = 30
    @State private var filterDay: String?
    // When on, the grid shows only starred swings.
    @State private var favouritesOnly = false

    // Bulk delete. Selection is screen state, not part of a swing, so it lives
    // here as a set of ids and is gone the moment the golfer leaves the screen.
    @State private var selectionMode = false
    @State private var selectedIds: Set<String> = []
    @State private var confirmBulkDelete = false

    // Upload footage. PhotosPicker filtered to videos. The selected item is
    // loaded to a temporary file and a placeholder closure runs. Full analysis
    // wiring is intentionally left for a later step.
    @State private var pickedVideo: PhotosPickerItem?
    @State private var importing = false
    @State private var importProgress: Double = 0

    private var visible: [SwingRecord] {
        var list = store.swings
        if let filterDay { list = list.filter { $0.day == filterDay } }
        if favouritesOnly { list = list.filter { $0.favourite } }
        return list
    }

    var body: some View {
        if store.swings.isEmpty {
            emptyState
        } else {
            populated
        }
    }

    // MARK: Empty

    private var emptyState: some View {
        ScreenContainer {
            VStack(alignment: .leading, spacing: Tok.s4) {
                Spacer(minLength: Tok.s7)
                Eyebrow(text: "Nothing here yet")
                Text("Your first swing starts the archive")
                    .font(.serif(TypeScale.title))
                    .foregroundStyle(Tok.bone)
                Text("Every swing you record stays on this device, dated, scored and comparable, for as long as you keep the app. Nothing here is ever taken away from you.")
                    .font(.body(TypeScale.small))
                    .foregroundStyle(Tok.bone2)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    store.go(.capture)
                } label: {
                    Text("Record a swing")
                        .font(.body(TypeScale.small, weight: .medium))
                        .padding(.vertical, 14)
                        .padding(.horizontal, 22)
                        .foregroundStyle(Tok.ink)
                        .background(Capsule().fill(Tok.fairwayLit))
                }
                .buttonStyle(PressScale())
                .padding(.top, Tok.s3)
            }
        }
    }

    // MARK: Populated

    private var populated: some View {
        ScreenContainer {
            Eyebrow(text: "Swing timeline")
                .padding(.bottom, Tok.s3)

            // Two ways in, side by side, almost no words. Everything already
            // recorded on the left, a camera roll import on the right. Those
            // are the only two things this screen is ever opened for.
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Every swing")
                        .font(.serif(TypeScale.title))
                        .foregroundStyle(Tok.bone)
                    Text("\(store.swings.count) saved")
                        .font(.body(TypeScale.micro))
                        .foregroundStyle(Tok.bone3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 16)
                .padding(.horizontal, 14)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Tok.turf800))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Tok.line, lineWidth: 1)
                }

                PhotosPicker(
                    selection: $pickedVideo,
                    matching: .videos,
                    photoLibrary: .shared()
                ) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(uploadButtonTitle)
                            .font(.serif(TypeScale.title))
                        Text(importing ? "Reading the swing, hold on" : "From your camera roll")
                            .font(.body(TypeScale.micro))
                            .opacity(0.72)
                    }
                    .foregroundStyle(Tok.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 16)
                    .padding(.horizontal, 14)
                    .background {
                        RoundedRectangle(cornerRadius: 16, style: .continuous).fill(
                            LinearGradient(
                                colors: [Tok.citrusLit, Tok.citrus, Tok.citrusDeep],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    }
                }
                .buttonStyle(PressScale())
                .disabled(importing)
                .opacity(importing ? 0.7 : 1)
            }
            .fixedSize(horizontal: false, vertical: true)

            GeometryReader { geo in
                Text(swinglineGreeting())
                    .font(.serif(TypeScale.hero(geo.size.width)))
                    .foregroundStyle(Tok.bone)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .frame(height: 76)
            .padding(.top, 10)
            .padding(.bottom, 14)

            Text(summaryLine)
                .font(.body(TypeScale.small))
                .foregroundStyle(Tok.bone2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 22)

            TrendChartView(trend: store.trend(days: trendDays), activeWindow: $trendDays)
                .padding(.bottom, 22)

            shareTodayCard
                .padding(.bottom, 22)

            swingGrid

            Text("These recordings are yours. They live on this device, they work offline, and they stay whether or not anything is ever paid for.")
                .font(.body(TypeScale.micro))
                .foregroundStyle(Tok.bone3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.top, 20)
                .padding(.horizontal, Tok.s3)
        }
        .onChange(of: pickedVideo) { _, item in
            guard let item else { return }
            loadPickedVideo(item)
        }
        // The bottom bar rides in on a slide and opacity, above the safe area so
        // the last card can still be scrolled clear of it rather than sitting
        // under it.
        .safeAreaInset(edge: .bottom) {
            if selectionMode {
                BulkDeleteBar(
                    count: selectedIds.count,
                    onDelete: { confirmBulkDelete = true },
                    onCancel: { exitSelection() }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: selectionMode)
        .alert(bulkDeleteTitle, isPresented: $confirmBulkDelete) {
            Button("Delete \(selectedIds.count)", role: .destructive) {
                store.deleteSwings(ids: selectedIds)
                exitSelection()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes them and their clips for good. It cannot be undone.")
        }
        // Deleting the last swing hides the trash button, so the mode has to go
        // with it or there is no way left to leave a mode with nothing in it.
        .onChange(of: store.swings.count) { _, count in
            if count == 0 && selectionMode { exitSelection() }
        }
        // Leaving the screen ends selection, so coming back is always a clean
        // start rather than a stale set of ticks.
        .onDisappear { exitSelection() }
    }

    // MARK: Selection helpers

    private var bulkDeleteTitle: String {
        let n = selectedIds.count
        return "Delete \(n) swing\(n == 1 ? "" : "s")?"
    }

    private func toggleSelection(_ id: String) {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            if selectedIds.contains(id) {
                selectedIds.remove(id)
            } else {
                selectedIds.insert(id)
            }
        }
    }

    private func exitSelection() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            selectionMode = false
            selectedIds.removeAll()
        }
    }

    // MARK: Upload footage

    private var uploadButtonTitle: String {
        guard importing else { return "Upload footage" }
        let pct = Int((importProgress * 100).rounded())
        return "Analysing \(pct)%"
    }

    /*
      The full upload to analysis pipeline.

      Copies the picked clip to a stable location the app owns, runs the pose and
      analysis pipeline over it off the main actor, saves the resulting swing with
      its video, and opens it in analysis. Every failure along the way is reported
      as a toast rather than swallowed, so a clip the engine cannot read tells the
      golfer why.
    */
    private func loadPickedVideo(_ item: PhotosPickerItem) {
        importing = true
        importProgress = 0

        let hand = DominantHand(rawValue: store.settings.dominantHand) ?? .right

        Task {
            defer {
                Task { @MainActor in
                    importing = false
                    importProgress = 0
                    pickedVideo = nil
                }
            }

            // 1. Pull the clip out of Photos into Documents/Uploads. PickedMovie
            // handles the security scoped read and the copy.
            let movie: PickedMovie?
            do {
                movie = try await item.loadTransferable(type: PickedMovie.self)
            } catch {
                await MainActor.run {
                    store.notify("Could not load that clip. \(error.localizedDescription)", tone: .warn)
                }
                return
            }
            guard let movie else {
                await MainActor.run {
                    store.notify("Could not read that clip. Try another.", tone: .warn)
                }
                return
            }

            // 2 to 5. Extract frames, analyse, build the record.
            do {
                let result = try await UploadProcessor.process(
                    videoURL: movie.url,
                    dominantHand: hand,
                    progress: { fraction in
                        Task { @MainActor in importProgress = fraction }
                    }
                )

                // Save and open on the main actor, since both touch the store and
                // navigation.
                await MainActor.run {
                    // The store moves the video into the swing's own slot, so pass
                    // a copy and leave the Uploads original in place.
                    let videoCopy = duplicateForStore(result.video)
                    // The 4:3 tile the pipeline already cropped from a decoded
                    // frame, so the store does not reopen the asset to make one.
                    store.recordUploadedSwing(
                        result.record,
                        frames: result.frames,
                        video: videoCopy,
                        thumbnail: result.thumbnail
                    )
                    store.openSwing(id: result.record.id)
                }
            } catch {
                await MainActor.run {
                    let message = (error as? LocalizedError)?.errorDescription ?? "That clip could not be analysed."
                    store.notify(message, tone: .warn)
                }
            }
        }
    }

    // The store's save moves the video file into place, so it is handed a
    // throwaway copy while the original stays in Documents/Uploads. A failed copy
    // is not fatal: the swing is still saved and analysed, just without a
    // playable clip.
    private func duplicateForStore(_ url: URL) -> URL? {
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("swingline-store-\(UUID().uuidString).\(url.pathExtension.isEmpty ? "mov" : url.pathExtension)")
        do {
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: url, to: copy)
            return copy
        } catch {
            return nil
        }
    }

    // MARK: Share today

    // A shareable summary of the week, no video, just the seven day shape of the
    // scores as a row of lime squares. The brighter and fuller a square, the
    // higher that day's overall. A copy button puts the text form on the
    // clipboard. Ports the web ShareGrid idea.
    /*
      The most recent swing's ball flight estimates, when there are any. Older
      swings never had them, so this simply does not draw rather than showing
      blanks. Labelled Est. because they are model figures, not measurements.
    */
    @ViewBuilder
    private var latestEstimatesRow: some View {
        let latest = store.swings
            .filter { $0.ballSpeedEstimate != nil }
            .max(by: { $0.createdAt < $1.createdAt })
        if let latest, let ball = latest.ballSpeedEstimate {
            VStack(alignment: .leading, spacing: 6) {
                Text("LATEST SWING (EST.)")
                    .font(.data(TypeScale.nano))
                    .tracking(1)
                    .foregroundStyle(Tok.bone3)
                HStack(spacing: Tok.s4) {
                    estimateStat(label: "BALL", value: String(format: "%.0f mph", ball * 2.237))
                    if let carry = latest.carryDistanceEstimate {
                        estimateStat(label: "CARRY", value: String(format: "%.0f yds", carry * 1.094))
                    }
                    if let launch = latest.launchAngleEstimate {
                        estimateStat(label: "LAUNCH", value: String(format: "%.0f\u{00b0}", launch))
                    }
                }
            }
            .padding(.top, Tok.s2)
        }
    }

    private func estimateStat(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.data(TypeScale.nano))
                .foregroundStyle(Tok.bone3)
            Text(value)
                .font(.data(TypeScale.small))
                .foregroundStyle(Tok.bone)
        }
    }

    private var shareTodayCard: some View {
        let week = lastSevenDays()
        return VStack(alignment: .leading, spacing: Tok.s3) {
            Eyebrow(text: "Share today", color: Tok.citrus)

            Text("No video, just the shape of it")
                .font(.serif(TypeScale.title))
                .foregroundStyle(Tok.bone)

            HStack(spacing: 8) {
                ForEach(week) { day in
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(squareColour(day.score))
                        .frame(height: 40)
                        .frame(maxWidth: .infinity)
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Tok.line, lineWidth: 1)
                        }
                        .overlay(alignment: .bottom) {
                            Text(day.initial)
                                .font(.data(TypeScale.nano))
                                .foregroundStyle(Tok.bone3)
                                .padding(.bottom, 3)
                        }
                }
            }

            latestEstimatesRow

            Button {
                copyShareCard(week)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                    Text("Copy share card")
                        .font(.body(TypeScale.small, weight: .bold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .foregroundStyle(Tok.ink)
                .background(Capsule().fill(Tok.citrus))
            }
            .buttonStyle(PressScale())
            .padding(.top, 2)
        }
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: Tok.rMd, style: .continuous).fill(Tok.turf800)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Tok.rMd, style: .continuous)
                .strokeBorder(Tok.line, lineWidth: 1)
        }
    }

    // One square per day for the last seven. A day with no swing has a nil score
    // and reads as an empty square, which is honest: nothing was recorded.
    private struct DaySquare: Identifiable {
        let id: Int
        let initial: String
        let score: Int?
    }

    private func lastSevenDays() -> [DaySquare] {
        let trend = store.trend(days: 7)
        // Index trend points by their day key for a quick lookup.
        var byDay: [String: Int] = [:]
        for point in trend.points {
            byDay[point.day] = point.overall
        }
        let calendar = Calendar.current
        let initials = ["S", "M", "T", "W", "T", "F", "S"]
        var result: [DaySquare] = []
        for offset in stride(from: 6, through: 0, by: -1) {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: Date()) else { continue }
            let key = Self.dayKey(date)
            let weekday = calendar.component(.weekday, from: date) - 1
            result.append(DaySquare(id: offset, initial: initials[weekday], score: byDay[key]))
        }
        return result
    }

    private static func dayKey(_ date: Date) -> String {
        // Matches the day key format the trend points use, yyyy-MM-dd.
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    // Lime, brighter and more opaque the higher the score. Empty days are a faint
    // outline only.
    private func squareColour(_ score: Int?) -> Color {
        guard let score else { return Tok.turf700 }
        let t = Double(max(0, min(100, score))) / 100
        return Tok.citrus.opacity(0.25 + 0.7 * t)
    }

    private func copyShareCard(_ week: [DaySquare]) {
        // Dummy text form for now: a row of block characters whose density tracks
        // the day's score, plus the day initials. Plain ASCII so it pastes
        // cleanly everywhere. Real share art and a proper caption come later.
        let blocks = week.map { day -> String in
            guard let score = day.score else { return "." }
            switch score {
            case 80...: return "#"
            case 60..<80: return "+"
            case 1..<60: return "-"
            default: return "."
            }
        }.joined(separator: " ")
        let days = week.map(\.initial).joined(separator: " ")
        var text = "Swingline, my week\n\(blocks)\n\(days)\n\(store.swings.count) swings on file"
        if let latest = store.swings.filter({ $0.ballSpeedEstimate != nil }).max(by: { $0.createdAt < $1.createdAt }),
           let ball = latest.ballSpeedEstimate {
            var parts = [String(format: "ball %.0f mph", ball * 2.237)]
            if let carry = latest.carryDistanceEstimate { parts.append(String(format: "carry %.0f yds", carry * 1.094)) }
            if let launch = latest.launchAngleEstimate { parts.append(String(format: "launch %.0f deg", launch)) }
            text += "\nLatest (est.): " + parts.joined(separator: ", ")
        }
        UIPasteboard.general.string = text
        store.notify("Share card copied to the clipboard.", tone: .good)
    }

    private var summaryLine: String {
        let count = store.swings.count
        var line = "\(count) \(count == 1 ? "swing" : "swings") recorded, form score \(store.rating.bandLabel)."
        if !store.quota.unlimited {
            line += " \(store.quota.remaining) free analyses left this month."
        }
        return line
    }

    // MARK: Swing grid

    // Swings gathered under a month heading, most recent month first, most
    // recent swing first within each.
    private struct MonthGroup: Identifiable {
        let id: String     // sort key, yyyy-MM
        let title: String  // display heading, e.g. "August 2026"
        let swings: [SwingRecord]
    }

    private var monthGroups: [MonthGroup] {
        let calendar = Calendar.current
        var buckets: [String: [SwingRecord]] = [:]
        for swing in visible {
            let comps = calendar.dateComponents([.year, .month], from: swing.createdAt)
            let key = String(format: "%04d-%02d", comps.year ?? 0, comps.month ?? 0)
            buckets[key, default: []].append(swing)
        }
        let heading = DateFormatter()
        heading.dateFormat = "LLLL yyyy"  // "August 2026"
        return buckets.keys.sorted(by: >).map { key in
            let items = buckets[key]!.sorted { $0.createdAt > $1.createdAt }
            let title = items.first.map { heading.string(from: $0.createdAt) } ?? key
            return MonthGroup(id: key, title: title, swings: items)
        }
    }

    private var swingGrid: some View {
        VStack(alignment: .leading, spacing: Tok.s4) {
            // Filter bar. A folder glyph flags this as the archive's filter, then
            // the two mutually exclusive scopes: all swings, or only starred ones.
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Tok.bone3)
                filterChip(title: "All swings", active: !favouritesOnly) { favouritesOnly = false }
                filterChip(title: "Favourites", icon: "star.fill", active: favouritesOnly) { favouritesOnly = true }
                Spacer(minLength: 0)
                if filterDay != nil && !selectionMode {
                    Button("Show all") { filterDay = nil }
                        .font(.body(TypeScale.small))
                        .foregroundStyle(Tok.bone2)
                }
                // Far right of the filter bar, the archive's own top nav. Trash
                // enters selection, then becomes Done. Absent, not disabled, when
                // there is nothing to select, since a bulk delete control on an
                // empty archive is an offer that cannot be taken.
                if !store.swings.isEmpty {
                    SelectionTrashButton(selectionMode: $selectionMode, selectedIds: $selectedIds)
                }
            }

            if monthGroups.isEmpty {
                Text(favouritesOnly
                     ? "No starred swings yet. Tap the star on a swing to keep it here."
                     : "Nothing to show.")
                    .font(.body(TypeScale.small))
                    .foregroundStyle(Tok.bone2)
                    .padding(.vertical, 24)
            } else {
                ForEach(monthGroups) { group in
                    VStack(alignment: .leading, spacing: Tok.s3) {
                        Text(group.title)
                            .font(.serif(TypeScale.title))
                            .foregroundStyle(Tok.bone)

                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                            ForEach(group.swings) { swing in
                                SwingTile(
                                    swing: swing,
                                    thumbnailPath: store.thumbnailPath(for: swing.id),
                                    selectionMode: selectionMode,
                                    isSelected: selectedIds.contains(swing.id),
                                    onOpen: { store.openSwing(id: swing.id, sharedId: swing.id) },
                                    onToggleSelect: { toggleSelection(swing.id) },
                                    onDelete: { store.deleteSwing(id: swing.id) }
                                )
                            }
                        }
                    }
                }
            }
        }
        .padding(.top, Tok.s3)
    }

    // A pill toggle for the filter bar. Filled lime when active, hairline
    // outline when not.
    @ViewBuilder
    private func filterChip(title: String, icon: String? = nil, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(title)
                    .font(.body(TypeScale.micro))
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 12)
            .foregroundStyle(active ? Tok.ink : Tok.bone3)
            .background(Capsule().fill(active ? Tok.citrus : Color.clear))
            .overlay { Capsule().strokeBorder(active ? Color.clear : Tok.line, lineWidth: 1) }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Swing tile

struct SwingTile: View {
    let swing: SwingRecord
    // The thumbnail file path, or nil when the swing has no clip to show.
    var thumbnailPath: String? = nil
    // Selection is driven by the list. In selection mode a tap toggles the tick
    // rather than opening the swing, and the per card bin steps aside.
    var selectionMode: Bool = false
    var isSelected: Bool = false
    let onOpen: () -> Void
    var onToggleSelect: () -> Void = {}
    let onDelete: () -> Void

    @State private var confirmingDelete = false

    var body: some View {
        // The card stays a Button, so it keeps the app's PressScale feel, and its
        // action branches on the mode: open when off, toggle the tick when on.
        // The per card bin below is a separate overlay Button that sits above this
        // one and takes its own taps first, exactly as it did before selection
        // existed.
        Button {
            if selectionMode {
                onToggleSelect()
            } else {
                onOpen()
            }
        } label: {
            tileBody
        }
        .buttonStyle(PressScale())
        .overlay(alignment: .bottomTrailing) {
            // The per card bin is only an affordance when there is no bulk
            // selection running. In selection mode the tick is the delete path, so
            // a second one would just be noise.
            if !selectionMode {
                Button {
                    confirmingDelete = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Tok.rust)
                        .padding(7)
                        .background(Circle().fill(Tok.ink.opacity(0.7)))
                }
                .buttonStyle(.plain)
                .padding(10)
                .transition(.opacity)
            }
        }
        .alert("Delete this swing?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes the recording and its scores from this device, and cannot be undone.")
        }
    }

    private var tileBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                // One fixed 4:3 box for every tile, centre cropped, so the grid
                // stays aligned whatever shape the source clip was. The box also
                // carries the selection tick top trailing when the mode is on.
                SwingThumbBox(
                    path: thumbnailPath,
                    selectionMode: selectionMode,
                    isSelected: isSelected
                )

                // Score, top trailing. Hidden in selection mode so it does not
                // fight the tick, which lives in the same corner. This no longer
                // carries a time label: the date lived here and again below the
                // thumbnail, which read as a duplicate. The single timestamp now
                // lives with the rest of the metadata under the box.
                if !selectionMode, let overall = swing.scores?.overall {
                    Text("\(overall)")
                        .font(.data(TypeScale.small))
                        .foregroundStyle(Tok.citrus)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(Capsule().fill(Tok.ink.opacity(0.7)))
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }

                // A starred swing is legible at a glance across the grid, so past
                // picks are easy to find. Top left, clear of both the score
                // capsules and the selection tick, so it stays visible in either
                // mode.
                if swing.favourite {
                    Image(systemName: "star.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Tok.citrus)
                        .padding(5)
                        .background(Circle().fill(Tok.ink.opacity(0.7)))
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .allowsHitTesting(false)
                }
            }

            // Metadata below the box, always visible, including in selection
            // mode. Club, then the camera angle the swing was filmed from, then
            // one timestamp. This is the single home for the date now, so there
            // is no longer a second one on the thumbnail.
            VStack(alignment: .leading, spacing: 2) {
                Text(swing.club)
                    .font(.body(TypeScale.micro))
                    .foregroundStyle(Tok.bone)

                if let view = cameraViewLabel {
                    Text(view)
                        .font(.data(TypeScale.nano))
                        .foregroundStyle(Tok.bone2)
                }

                Text(timeLabel(swing.createdAt))
                    .font(.data(TypeScale.nano))
                    .foregroundStyle(Tok.bone3)

                // Swing count badge, sitting under the thumbnail with the rest of
                // the metadata. One swing per record today; see swingCountText.
                Text(swingCountText)
                    .font(.data(TypeScale.nano))
                    .foregroundStyle(Tok.ink)
                    .padding(.vertical, 3)
                    .padding(.horizontal, 8)
                    .background(Capsule().fill(Tok.citrus.opacity(0.85)))
                    .padding(.top, 2)

                if !swing.analysed {
                    Text(swing.failure ?? "Not scored")
                        .font(.body(TypeScale.nano))
                        .foregroundStyle(Tok.rust)
                        .lineLimit(1)
                }
            }
            .padding(.top, Tok.s2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /*
      The camera angle the swing was filmed from, in the app's own words, or nil
      when the record does not name one so nothing invented is shown.

      swing.view is the stored raw value that CameraViewKind decodes elsewhere. It
      is matched loosely here, ignoring case and separators, so "faceOn",
      "face-on" and "face on" all read the same, and an unrecognised value is
      shown title cased rather than dropped.
    */
    private var cameraViewLabel: String? {
        guard let raw = swing.view?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return nil
        }
        let key = raw.lowercased().replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
        switch key {
        case "faceon": return "Face on"
        case "downtheline", "dtl": return "Down the line"
        case "unknown", "": return nil
        default: return raw.capitalized
        }
    }

    /*
      The full date and time a swing was recorded, e.g. "Aug 24, 2026 · 7:59 AM".

      The tile used to show a bare abbreviated date, or a relative phrase for
      today, which dropped the time of day entirely. A golfer who records several
      swings in one session needs the clock time to tell them apart, so the stamp
      now always carries both. One shared formatter, since a grid rebuilds these
      labels on every selection tap.
    */
    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d, yyyy '\u{00b7}' h:mm a"
        return f
    }()

    private func timeLabel(_ date: Date) -> String {
        Self.stampFormatter.string(from: date)
    }

    /*
      Swings folded into this tile.

      SwingRecord has no swing count field, so a record is one swing and the badge
      reads "1 swing". If a grouped or multi-swing record type is added later, read
      its count here and the plural handling below carries it.
    */
    private var swingCountText: String {
        let n = 1
        return "\(n) swing\(n == 1 ? "" : "s")"
    }
}

// MARK: - Trend chart

// Days with no practice are gaps, never joined through. A line that runs flat
// across a fortnight nobody played is a lie, and it is the kind of lie that
// quietly costs the app trust in every other chart it draws.
struct TrendChartView: View {
    let trend: Trend
    @Binding var activeWindow: Int

    @State private var series: String = "overall"

    private let windows = [10, 30, 90]

    private var seriesColour: Color {
        switch series {
        case "sequencing": return Tok.catSequencing
        case "rotation": return Tok.catRotation
        case "balance": return Tok.catBalance
        case "finish": return Tok.catFinish
        default: return Tok.bone
        }
    }

    private var seriesTitle: String {
        ScoreCategory(rawValue: series)?.label ?? "Form score"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: Tok.s3) {
                VStack(alignment: .leading, spacing: 6) {
                    Eyebrow(text: "Trend")
                    Text(seriesTitle)
                        .font(.serif(TypeScale.title))
                        .foregroundStyle(Tok.bone)
                }
                Spacer()
                HStack(spacing: Tok.s1) {
                    ForEach(windows, id: \.self) { window in
                        Button {
                            activeWindow = window
                        } label: {
                            Text("\(window)d")
                                .font(.data(TypeScale.nano))
                                .padding(.vertical, 6)
                                .padding(.horizontal, 10)
                                .foregroundStyle(activeWindow == window ? Tok.fairwayLit : Tok.bone3)
                                .background(Capsule().fill(activeWindow == window ? Tok.fairwayDim : .clear))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.bottom, 6)

            if trend.points.count > 1 {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(trend.points.last?.value(for: series) ?? 0)")
                        .font(.serif(34))
                        .foregroundStyle(Tok.bone)
                    if let change = trend.change[series] {
                        Text("\(change >= 0 ? "+" : "")\(change) over \(trend.days) days")
                            .font(.data(TypeScale.small))
                            .foregroundStyle(change >= 0 ? Tok.fairwayLit : Tok.rust)
                    }
                }
                .padding(.bottom, Tok.s2)

                line
                    .frame(height: 150)
            } else {
                Text("Two practice days in this window and the line starts drawing itself.")
                    .font(.body(TypeScale.small))
                    .foregroundStyle(Tok.bone2)
                    .padding(.vertical, 28)
            }

            FlowRow(spacing: 6) {
                ForEach(["overall"] + ScoreCategory.allCases.map(\.rawValue), id: \.self) { key in
                    let selected = key == series
                    Button {
                        series = key
                    } label: {
                        Text(ScoreCategory(rawValue: key)?.label ?? "Overall")
                            .font(.body(TypeScale.micro))
                            .padding(.vertical, 8)
                            .padding(.horizontal, 13)
                            .foregroundStyle(selected ? Tok.bone : Tok.bone3)
                            .overlay { Capsule().strokeBorder(selected ? Tok.bone : Tok.line, lineWidth: 1) }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 14)
        }
        .card()
    }

    private var line: some View {
        GeometryReader { geo in
            let points = trend.points
            let w = geo.size.width
            let h = geo.size.height
            let padTop: CGFloat = 14
            let padBottom: CGFloat = 24

            // FIX: Converted the nested functions to local closures so SwiftUI ViewBuilder stops throwing syntax errors
            let x: (Int) -> CGFloat = { i in
                points.count <= 1 ? 0 : CGFloat(i) / CGFloat(points.count - 1) * w
            }
            let y: (Int) -> CGFloat = { value in
                padTop + (1 - CGFloat(value) / 100) * (h - padTop - padBottom)
            }

            ZStack {
                ForEach([25, 50, 75], id: \.self) { gridline in
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: y(gridline)))
                        p.addLine(to: CGPoint(x: w, y: y(gridline)))
                    }
                    .stroke(Tok.line, lineWidth: 1)
                }

                Path { p in
                    for (i, point) in points.enumerated() {
                        let position = CGPoint(x: x(i), y: y(point.value(for: series)))
                        if i == 0 { p.move(to: position) } else { p.addLine(to: position) }
                    }
                    p.addLine(to: CGPoint(x: x(points.count - 1), y: h - padBottom))
                    p.addLine(to: CGPoint(x: x(0), y: h - padBottom))
                    p.closeSubpath()
                }
                .fill(seriesColour.opacity(0.14))

                Path { p in
                    for (i, point) in points.enumerated() {
                        let position = CGPoint(x: x(i), y: y(point.value(for: series)))
                        if i == 0 { p.move(to: position) } else { p.addLine(to: position) }
                    }
                }
                .stroke(seriesColour, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))

                ForEach(Array(points.enumerated()), id: \.element.id) { i, point in
                    Circle()
                        .fill(Tok.ink)
                        .overlay(Circle().strokeBorder(seriesColour, lineWidth: 2))
                        .frame(width: 7, height: 7)
                        .position(x: x(i), y: y(point.value(for: series)))
                }
            }
        }
    }
}

// MARK: - Picked movie transferable

// PhotosPicker vends a video as a file whose URL is temporary, security scoped,
// and cleaned up soon after the transfer. Two things have to happen for the copy
// to succeed in the app sandbox:
//
//   1. The received URL is security scoped. It must be wrapped in
//      startAccessingSecurityScopedResource before it can be read, and stopped
//      after. Skipping this is what produces the LaunchServices "process may not
//      map database" error (code -54): the sandbox refuses the read.
//   2. The copy lands in the app's own Documents directory, which is a stable
//      location the app fully owns, rather than a path that could be reclaimed.
//
// The caller then gets a URL to a file the app owns outright and can hand to the
// analysis pipeline.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let source = received.file

            // The received file is security scoped. Take access for the duration
            // of the copy, and always release it.
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }

            // Copy into a dedicated Uploads folder under Documents, which the app
            // owns and which survives well past the transfer.
            let documents = try FileManager.default.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let uploads = documents.appendingPathComponent("Uploads", isDirectory: true)
            try FileManager.default.createDirectory(at: uploads, withIntermediateDirectories: true)

            let ext = source.pathExtension.isEmpty ? "mov" : source.pathExtension
            let destination = uploads.appendingPathComponent("swingline-upload-\(UUID().uuidString).\(ext)")
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: source, to: destination)

            return PickedMovie(url: destination)
        }
    }
}