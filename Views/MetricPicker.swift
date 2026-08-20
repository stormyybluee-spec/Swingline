//
//  MetricPicker.swift
//  Swingline
//
//  The metric picker. Four sections:
//
//  Always First    the eight locked cards that lead every layout, shown with a
//                  lock and neither movable nor removable.
//  On the bar      the first customisable page. Drag to reorder inside it, or
//                  drag a card onto the other page to move it across.
//  On the bar 2    the second customisable page, same behaviour.
//  Available       everything not placed yet. Tap to add to the end of bar 2,
//                  or drag it onto either page to place it exactly.
//
//  Why this is no longer a List with .onMove. onMove is scoped to the ForEach it
//  is attached to, so it can only ever reorder inside one section, which is the
//  bug being fixed here: a card on On The Bar 2 could not be dragged onto On The
//  Bar. Rows now carry .onDrag and .onDrop with a shared drop delegate that owns
//  both arrays, so a drag that starts in one section can finish in another. The
//  editMode List is gone with it, because an active editMode List swallows the
//  drag gesture before .onDrag ever sees it.
//
//  Two ordered arrays still back the two bars and still persist through
//  AppSettings. The Always First set is fixed and not stored. Available is not
//  stored either: it is whatever is on neither bar, so taking a card off a bar
//  puts it back there with no third array to keep in step.
//
//  Every row also carries an info button on its trailing edge, which opens a
//  sheet explaining what that metric measures. The text lives in
//  MetricInfo.swift, reached through metric.metricInfo. The button only appears
//  when there is something to show, so a metric with no entry in the catalogue
//  simply looks the way it did before.
//
//  House rule: no em dashes anywhere.
//

import SwiftUI
import UniformTypeIdentifiers

// Which list a row lives in. Available is derived rather than stored, so a drop
// there simply means the metric is now on neither bar.
private enum BarSection: Hashable {
    case bar1, bar2, available
}

// The card currently under the finger, and where it sits right now. The section
// is updated as the card is dragged across, so a second move in the same drag
// knows which array to pull it out of.
private struct DraggedMetric: Equatable {
    let id: String
    var section: BarSection
}

struct MetricPicker: View {
    @Binding var bar1: [String]
    @Binding var bar2: [String]
    @Environment(\.dismiss) private var dismiss

    @State private var dragging: DraggedMetric?

    // The metric whose explanation is open. nil means no sheet.
    @State private var infoTarget: SwingMetric?

    private var bar1Metrics: [SwingMetric] { bar1.compactMap { SwingMetrics.metric($0) } }
    private var bar2Metrics: [SwingMetric] { bar2.compactMap { SwingMetrics.metric($0) } }

    // Everything not locked and not already on a bar.
    private var available: [SwingMetric] {
        SwingMetrics.all.filter {
            !SwingMetrics.alwaysFirstSet.contains($0.id)
                && !bar1.contains($0.id)
                && !bar2.contains($0.id)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Capsule()
                .fill(Tok.lineStrong)
                .frame(width: 44, height: 4)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Tok.s4)

            Eyebrow(text: "Metrics")
            Text("What to read while you scrub")
                .font(.serif(TypeScale.title))
                .foregroundStyle(Tok.bone)
                .padding(.top, 6)
                .padding(.bottom, 8)

            Text("Hold a card and drag it. Within a page to reorder, onto the other page to move it there, onto Available to take it off the bar. Tap the i on any card to see what it measures. Anything your camera angle cannot measure is hidden automatically.")
                .font(.body(TypeScale.nano))
                .foregroundStyle(Tok.bone3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, Tok.s3)

            ScrollView {
                VStack(alignment: .leading, spacing: Tok.s4) {
                    section("ALWAYS FIRST") {
                        ForEach(SwingMetrics.alwaysFirst) { metric in
                            lockedRow(metric)
                        }
                    }

                    section("ON THE BAR") {
                        ForEach(bar1Metrics) { metric in
                            barRow(metric, in: .bar1)
                        }
                        if dragging != nil || bar1Metrics.isEmpty {
                            dropZone("Drop here", section: .bar1)
                        }
                    }

                    section("ON THE BAR 2") {
                        ForEach(bar2Metrics) { metric in
                            barRow(metric, in: .bar2)
                        }
                        if dragging != nil || bar2Metrics.isEmpty {
                            dropZone("Drop here", section: .bar2)
                        }
                    }

                    if !available.isEmpty || isDraggingFromBar {
                        section("AVAILABLE") {
                            ForEach(available) { metric in
                                availableRow(metric)
                            }
                            if isDraggingFromBar {
                                dropZone("Drop here to take it off the bar", section: .available)
                            }
                        }
                    }
                }
                .padding(.bottom, Tok.s4)
                .animation(.snappy(duration: 0.18), value: bar1)
                .animation(.snappy(duration: 0.18), value: bar2)
            }
            .scrollIndicators(.hidden)

            Button {
                dismiss()
            } label: {
                Text("Done")
                    .font(.body(TypeScale.small))
                    .foregroundStyle(Tok.ink)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        Capsule().fill(
                            LinearGradient(
                                colors: [Tok.citrusLit, Tok.citrus, Tok.citrusDeep],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    )
            }
            .buttonStyle(PressScale())
            .padding(.top, Tok.s3)
            .padding(.bottom, Tok.s5)
        }
        .padding(.horizontal, Tok.s5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tok.turf800.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        // A drag that ends on nothing leaves the card where it last moved to,
        // rather than leaving the picker stuck in its dragging state.
        .onDrop(of: [.plainText], isTargeted: nil) { _ in
            dragging = nil
            return true
        }
        // A sheet on top of a sheet. Reliable on iPhone, unlike a popover, which
        // adapts to a full sheet in compact width anyway.
        .sheet(item: $infoTarget) { metric in
            MetricInfoSheet(metric: metric)
        }
    }

    private var isDraggingFromBar: Bool {
        guard let dragging else { return false }
        return dragging.section == .bar1 || dragging.section == .bar2
    }

    // MARK: Sections

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Tok.s2) {
            Text(title)
                .font(.data(TypeScale.nano))
                .foregroundStyle(Tok.bone3)
            content()
        }
    }

    // MARK: Rows

    private func lockedRow(_ metric: SwingMetric) -> some View {
        HStack(spacing: Tok.s3) {
            Image(systemName: "lock.fill")
                .font(.system(size: 11))
                .foregroundStyle(Tok.bone3)
            Text(metric.label)
                .font(.body(TypeScale.small))
                .foregroundStyle(Tok.bone2)
            Spacer()
            infoButton(metric)
        }
        .modifier(RowChrome())
    }

    // A card on one of the two customisable pages. Draggable anywhere, with the
    // minus button kept as the quick way back to Available.
    private func barRow(_ metric: SwingMetric, in section: BarSection) -> some View {
        HStack(spacing: Tok.s3) {
            Button {
                remove(metric.id)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(Tok.rust)
            }
            .buttonStyle(.plain)
            Text(metric.label)
                .font(.body(TypeScale.small))
                .foregroundStyle(Tok.bone)
            Spacer()
            infoButton(metric)
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 13))
                .foregroundStyle(Tok.bone3)
        }
        .modifier(RowChrome())
        .opacity(dragging?.id == metric.id ? 0.35 : 1)
        .onDrag {
            dragging = DraggedMetric(id: metric.id, section: section)
            return NSItemProvider(object: metric.id as NSString)
        }
        .onDrop(of: [.plainText], delegate: delegate(target: metric.id, section: section))
    }

    // Not yet placed. Tap still adds it to the end of bar 2, drag places it
    // exactly where the golfer wants it on either page.
    //
    // The whole row used to be one Button. It is a tap gesture now, because a
    // Button inside a Button label is not a reliable way to get two separate
    // taps out of one row: the info button would have been swallowed by the add
    // action. The row keeps its tap target because RowChrome sets contentShape.
    private func availableRow(_ metric: SwingMetric) -> some View {
        HStack(spacing: Tok.s3) {
            Image(systemName: "plus.circle")
                .font(.system(size: 17))
                .foregroundStyle(Tok.citrus)
            Text(metric.label)
                .font(.body(TypeScale.small))
                .foregroundStyle(Tok.bone2)
            Spacer()
            infoButton(metric)
        }
        .modifier(RowChrome())
        .opacity(dragging?.id == metric.id ? 0.35 : 1)
        .onTapGesture {
            add(metric.id)
        }
        .onDrag {
            dragging = DraggedMetric(id: metric.id, section: .available)
            return NSItemProvider(object: metric.id as NSString)
        }
        .onDrop(of: [.plainText], delegate: delegate(target: metric.id, section: .available))
    }

    // Small, grey, circular. The padding is there to give it a finger sized
    // target without making the glyph itself any bigger, and contentShape keeps
    // that padding tappable.
    @ViewBuilder
    private func infoButton(_ metric: SwingMetric) -> some View {
        if metric.metricInfo != nil {
            Button {
                infoTarget = metric
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(Tok.bone3)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 5)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("About \(metric.label)")
        }
    }

    // The tail of a section. It gives an empty page something to drop onto and
    // gives a full one a way to say "after the last card", which a row target
    // cannot express on its own.
    private func dropZone(_ label: String, section: BarSection) -> some View {
        HStack {
            Text(label)
                .font(.body(TypeScale.nano))
                .foregroundStyle(Tok.bone3)
            Spacer()
        }
        .padding(.horizontal, Tok.s3)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Tok.rMd, style: .continuous)
                .fill(Tok.turf900.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Tok.rMd, style: .continuous)
                .strokeBorder(Tok.lineStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        )
        .contentShape(RoundedRectangle(cornerRadius: Tok.rMd, style: .continuous))
        .onDrop(of: [.plainText], delegate: delegate(target: nil, section: section))
    }

    private func delegate(target: String?, section: BarSection) -> MetricDropDelegate {
        MetricDropDelegate(
            target: target,
            section: section,
            bar1: $bar1,
            bar2: $bar2,
            dragging: $dragging
        )
    }

    // MARK: Edits that are not drags

    // New metrics land at the end of bar 2, matching the picker's layout order.
    private func add(_ id: String) {
        guard !bar1.contains(id), !bar2.contains(id) else { return }
        bar2.append(id)
    }

    private func remove(_ id: String) {
        bar1.removeAll { $0 == id }
        bar2.removeAll { $0 == id }
    }
}

// MARK: - The explanation sheet

// Four blocks in a fixed order, because the same order every time is what makes
// them scannable: what it is, where the number comes from, what good looks
// like, what to do about yours.
private struct MetricInfoSheet: View {
    let metric: SwingMetric
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Capsule()
                .fill(Tok.lineStrong)
                .frame(width: 44, height: 4)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Tok.s4)

            Eyebrow(text: "Metric")
            Text(metric.metricInfo?.title ?? metric.label)
                .font(.serif(TypeScale.title))
                .foregroundStyle(Tok.bone)
                .padding(.top, 6)
                .padding(.bottom, Tok.s3)

            ScrollView {
                VStack(alignment: .leading, spacing: Tok.s4) {
                    if let info = metric.metricInfo {
                        block("WHAT IT MEASURES", info.measures)
                        block("HOW IT IS WORKED OUT", info.calculation)
                        goodRange(info.goodRange)
                        block("HOW TO READ YOURS", info.interpretation)
                    } else {
                        Text("No description for this metric yet.")
                            .font(.body(TypeScale.small))
                            .foregroundStyle(Tok.bone3)
                    }
                }
                .padding(.bottom, Tok.s4)
            }
            .scrollIndicators(.hidden)

            Button {
                dismiss()
            } label: {
                Text("Close")
                    .font(.body(TypeScale.small))
                    .foregroundStyle(Tok.bone)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        Capsule().fill(Tok.turf900)
                    )
                    .overlay(
                        Capsule().strokeBorder(Tok.line, lineWidth: 1)
                    )
            }
            .buttonStyle(PressScale())
            .padding(.top, Tok.s3)
            .padding(.bottom, Tok.s5)
        }
        .padding(.horizontal, Tok.s5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tok.turf800.ignoresSafeArea())
        .presentationDetents([.medium])
        .presentationDragIndicator(.hidden)
    }

    private func block(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: Tok.s2) {
            Text(title)
                .font(.data(TypeScale.nano))
                .foregroundStyle(Tok.bone3)
            Text(body)
                .font(.body(TypeScale.small))
                .foregroundStyle(Tok.bone2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // The one number a golfer is actually looking for, so it gets the card and
    // the accent rather than sitting in the run of plain paragraphs.
    private func goodRange(_ value: String) -> some View {
        VStack(alignment: .leading, spacing: Tok.s2) {
            Text("GOOD RANGE")
                .font(.data(TypeScale.nano))
                .foregroundStyle(Tok.bone3)
            Text(value)
                .font(.data(TypeScale.small))
                .foregroundStyle(Tok.citrus)
                .padding(.horizontal, Tok.s3)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Tok.rMd, style: .continuous)
                        .fill(Tok.turf900)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Tok.rMd, style: .continuous)
                        .strokeBorder(Tok.line, lineWidth: 1)
                )
        }
    }
}

// MARK: - Row chrome

// The rows used to get their background from listRowBackground. Outside a List
// they carry it themselves, and the contentShape matters: without it a drop
// only registers over the text, not across the whole row.
private struct RowChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, Tok.s3)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Tok.rMd, style: .continuous)
                    .fill(Tok.turf900)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Tok.rMd, style: .continuous)
                    .strokeBorder(Tok.line, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: Tok.rMd, style: .continuous))
    }
}

// MARK: - The drop delegate

/*
  One delegate type for every target, which is what makes a cross section drag
  possible: it holds both arrays, so it can pull a card out of one and put it
  into the other in a single edit.

  The move happens on dropEntered rather than on performDrop, so the list
  reorders live under the finger the way a golfer expects. target is the card the
  finger is over, and the dragged card is inserted in front of it; a nil target
  is a section tail, meaning append.
*/
private struct MetricDropDelegate: DropDelegate {
    let target: String?
    let section: BarSection
    @Binding var bar1: [String]
    @Binding var bar2: [String]
    @Binding var dragging: DraggedMetric?

    func validateDrop(info: DropInfo) -> Bool {
        dragging != nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropEntered(info: DropInfo) {
        guard let drag = dragging else { return }
        apply(drag)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let drag = dragging else { return false }
        apply(drag)
        dragging = nil
        return true
    }

    private func apply(_ drag: DraggedMetric) {
        // Nothing to do when the card is already where the finger is.
        guard drag.id != target else { return }

        var one = bar1
        var two = bar2

        // Out of wherever it currently is. Both arrays are cleaned rather than
        // just the source, so a stale id from an older build cannot end up on
        // two pages at once.
        one.removeAll { $0 == drag.id }
        two.removeAll { $0 == drag.id }

        switch section {
        case .bar1: insert(drag.id, into: &one)
        case .bar2: insert(drag.id, into: &two)
        case .available: break   // off both bars is what Available means
        }

        // Only write what actually changed, so a drag inside one page does not
        // churn the other page's persisted order.
        if one != bar1 { bar1 = one }
        if two != bar2 { bar2 = two }

        if drag.section != section {
            dragging = DraggedMetric(id: drag.id, section: section)
        }
    }

    private func insert(_ id: String, into list: inout [String]) {
        if let target, let index = list.firstIndex(of: target) {
            list.insert(id, at: index)
        } else {
            list.append(id)
        }
    }
}
